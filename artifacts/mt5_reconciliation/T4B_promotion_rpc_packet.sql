-- ================================================================================================
-- PRODUCTION-SAFE APPLY
-- T4B JOURNAL PROMOTION — RPC PACKET (mt5_t4b_promotion_rpc_v1, packet revision 6)
--
-- ONE narrow SECURITY DEFINER entry point that fulfils a durable T4A journal_add decision into
-- exactly one canonical Journal trade, atomically, with immutable lineage.
--
-- THE THREE-WAY JOIN. A capture event does NOT contain the facts a Journal trade needs: it has no
-- price and no real open time. The capture carries basis_run_id; the immutable S1 snapshot row for
-- (basis_run_id, position_id) carries price_open, open_time_utc and contract_size. T4B is
-- therefore decision x capture x S1 — never a projection of the capture alone.
--
-- FROZEN RESULT CONTRACT (six columns, one row, always):
--   o_ok  o_inserted  o_promotion_id  o_trade_id  o_existing_decision_id  o_error_code
--
--   FIRST INSERT                 true   1   promo  trade  null      null
--   SAME-DECISION REPLAY         true   0   promo  trade  null      null
--   bad call shape               false  0   null   null   null      ERR_BAD_INPUT
--   decision does not exist      false  0   null   null   null      ERR_DECISION_NOT_FOUND
--   capture evidence missing     false  0   null   null   null      ERR_EVIDENCE_NOT_FOUND
--   decision is not journal_add  false  0   null   null   null      ERR_NOT_JOURNAL_ADD
--   same MT5 position already
--     promoted by ANOTHER decn   false  0   promo  trade  other_dec ERR_POSITION_ALREADY_PROMOTED
--   basis run/position missing   false  0   null   null   null      ERR_BASIS_NOT_FOUND
--   basis facts unusable (null)  false  0   null   null   null      ERR_BASIS_INCOMPLETE
--   no/unhealthy/stale fresh run false  0   null   null   null      ERR_STALE_EVIDENCE
--   position absent in fresh run false  0   null   null   null      ERR_POSITION_ABSENT
--   basis vs fresh fact drift    false  0   null   null   null      ERR_POSITION_FACT_DRIFT
--   product mapping failure      false  0   null   null   null      ERR_PRODUCT_MAPPING
--   ledger fulfilled, trade gone
--     / re-owned / not the same
--     incarnation                false  0   promo  trade  null      ERR_FULFILLMENT_DRIFT
--   reserved trade id occupied   false  0   null   trade  null      ERR_TRADE_ID_COLLISION
--
--   Thirteen codes, each with exactly one meaning. An unknown uniqueness defect is RE-RAISED, never
--   translated into any of them: a defect that cannot be named must not be reported as a
--   recognised outcome.
--
-- ORDERING IS THE CONTRACT (see the "replay precedence" section). Existing fulfilment is resolved
-- BEFORE any eligibility is re-evaluated, so a decision promoted today stays replayable tomorrow
-- even after the freshness window expires, the position disappears, or the product catalog changes.
--
-- WHAT THE CALLER MAY SUPPLY: a decision id. Nothing else. No symbol, price, volume, product,
-- trade id, kind, user, account, freshness window or field override exists in the signature.
--
-- WHAT T4B NEVER DOES: close/partial-close/realized-P/L inference, disappearance-as-close,
-- volume-drift interpretation, auto-merge with an existing manual trade, grouping, T2 append,
-- MT5 access, or any write outside public.trades + public.mt5_capture_promotions.
--
-- REVISION 2 changes: reserved deterministic trade-id namespace (no wall-clock mint, no retry
-- loop, no global mint lock), incarnation-validated replay, wall-clock eligibility boundary,
-- constraint-aware uniqueness handling, exact product-catalog cardinality.
-- REVISION 3 changes: exact deployed-function digests recorded in the migration ledger, so a body
-- swapped after apply is detectable; the marker column removed from every client role's writable
-- surface (schema packet), which is what actually makes the incarnation unforgeable.
--
-- APPLY (offline first): psql -v ON_ERROR_STOP=1 -f T4B_promotion_rpc_packet.sql
-- Production apply is NOT authorized by T4B-1.
-- ================================================================================================

begin;

do $t4b_rpc_pre$
begin
  if to_regclass('public.mt5_capture_promotions') is null then
    raise exception 'MT5_T4B_RPC_PREFLIGHT: public.mt5_capture_promotions does not exist — apply '
      'the schema packet first';
  end if;
  if not exists (select 1 from public.mt5_schema_migrations
                  where version = 'mt5_t4b_promotion_schema_v1' and status = 'applied') then
    raise exception 'MT5_T4B_RPC_PREFLIGHT: schema packet is not recorded as applied';
  end if;
  if exists (select 1 from public.mt5_schema_migrations
              where version = 'mt5_t4b_promotion_rpc_v1' and status = 'applied') then
    raise exception 'MT5_T4B_RPC_PREFLIGHT: this RPC packet is already applied';
  end if;
  -- The incarnation marker the replay validator depends on must exist.
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='trades'
                    and column_name='mt5_promotion_id') then
    raise exception 'MT5_T4B_RPC_PREFLIGHT: public.trades.mt5_promotion_id is missing — the schema '
      'packet at revision 2 or later has not been applied';
  end if;
end $t4b_rpc_pre$;

-- ------------------------------------------------------------------------------------------------
-- Helper 1: the SERVER-OWNED freshness window. A function, not a literal sprinkled through the
-- body, so the value has exactly one definition and the verifier can assert it. No caller can
-- supply, widen or bypass it — the promotion RPC takes no interval argument at all.
--
-- FROZEN BOUNDARY: evidence age in [0 seconds, 7200 seconds] INCLUSIVE is fresh. Exactly 7200 is
-- allowed; anything strictly greater is ERR_STALE_EVIDENCE; a negative age (future-dated capture,
-- i.e. clock skew) is refused rather than treated as maximally fresh.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_t4b_freshness_window_v1() returns interval
language sql immutable security definer set search_path = public, pg_temp
as $win$ select interval '7200 seconds' $win$;
alter function public.mt5_t4b_freshness_window_v1() owner to postgres;
revoke all on function public.mt5_t4b_freshness_window_v1()
  from public, anon, authenticated, service_role;

-- ------------------------------------------------------------------------------------------------
-- Helper 2: THE SHARED FULFILMENT VALIDATOR.
--
-- Exactly one definition of "this ledger row is still fulfilled by that Journal row", used by BOTH
-- the ordinary replay path and the uniqueness-race path. Revision 1 validated id + owner only and
-- had a real defect: delete the promoted trade, let any same-owner row be created reusing the id,
-- and replay reported success against an unrelated object. The incarnation marker closes it.
--
-- What it does NOT do: hash the row, compare contents, or constrain editing in any way. A promoted
-- trade may be edited freely for as long as it remains the same incarnation.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_t4b_validate_fulfillment_v1(
  p_promotion uuid, p_trade text, p_user uuid
) returns boolean
language sql stable security definer set search_path = public, pg_temp
as $val$
  select exists (
    select 1 from public.trades t
     where t.id              =  p_trade
       and t.user_id         =  p_user
       -- a NULL marker yields NULL, never true: a re-inserted row is NOT this incarnation
       and t.mt5_promotion_id = p_promotion
  )
$val$;
alter function public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid) owner to postgres;
revoke all on function public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid)
  from public, anon, authenticated, service_role;

-- ------------------------------------------------------------------------------------------------
-- Helper 3: strict product mapping. EXACT contract-code match against the user's product catalog,
-- never a base-symbol prefix. The Journal registry expands each futures product into an Active
-- series (id) and a Next series (id || '_next'); this reproduces that mapping server-side.
--
-- Returns exactly one row: (product_id, error_code). error_code is null on success.
-- Ambiguity (more than one catalog entry claims the contract code) is a FAILURE, never a pick.
-- Ambiguity of the CATALOG ITSELF (zero or several rows for the user) is likewise a failure:
-- revision 1 used a non-STRICT SELECT INTO, which would have let PostgreSQL pick an arbitrary
-- catalog row if products ever held duplicates for one user.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_t4b_map_product_v1(
  p_user uuid, p_symbol text, p_contract_size numeric
) returns table (product_id text, error_code text)
language plpgsql stable security definer set search_path = public, pg_temp
as $map$
declare
  v_products jsonb;
  v_rows     integer;
  v_n        integer;
  v_pid      text;
  v_csize    text;
begin
  if p_user is null or coalesce(btrim(p_symbol), '') = '' or p_contract_size is null then
    return query select null::text, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;

  -- EXACTLY ONE catalog row for this user. Enforced at runtime and independent of whether the
  -- products table happens to carry a uniqueness constraint.
  select count(*) into v_rows from public.products pr where pr.user_id = p_user;
  if v_rows <> 1 then
    return query select null::text, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;

  select pr.data into v_products from public.products pr where pr.user_id = p_user;
  if v_products is null or jsonb_typeof(v_products) <> 'array' then
    return query select null::text, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;

  with cand as (
    -- Active series: the catalog id verbatim.
    select e->>'id' as pid, e->>'contractSize' as csize
      from jsonb_array_elements(v_products) e
     where jsonb_typeof(e) = 'object' and e->>'currentContract' = p_symbol
    union all
    -- Next series: the synthetic '<id>_next' the registry emits for futures.
    select (e->>'id') || '_next', e->>'contractSize'
      from jsonb_array_elements(v_products) e
     where jsonb_typeof(e) = 'object' and e->>'nextContract' = p_symbol
  )
  select count(*), min(pid), min(csize) into v_n, v_pid, v_csize from cand;

  -- 0 matches or 2+ matches are both failures. Never guess, never prefer one slot.
  if v_n <> 1 then
    return query select null::text, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;
  if coalesce(btrim(v_pid), '') = '' or v_pid like '\_next' then
    return query select null::text, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;
  -- contractSize must be present and numeric...
  if v_csize is null or v_csize !~ '^[0-9]+(\.[0-9]+)?$' then
    return query select null::text, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;
  -- ...and must AGREE with the contract size the exchange snapshot recorded. This is the guard
  -- that stops an SSF/stock catalog collision (contract size 1000 vs 1) from silently producing a
  -- position 1000x the real one.
  if v_csize::numeric is distinct from p_contract_size then
    return query select null::text, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;

  return query select v_pid, null::text;
end
$map$;
alter function public.mt5_t4b_map_product_v1(uuid, text, numeric) owner to postgres;
revoke all on function public.mt5_t4b_map_product_v1(uuid, text, numeric)
  from public, anon, authenticated, service_role;

-- ------------------------------------------------------------------------------------------------
-- THE PROMOTION RPC.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_promote_capture_decision_v1(p_decision uuid)
returns table (
  o_ok                    boolean,
  o_inserted              integer,
  o_promotion_id          uuid,
  o_trade_id              text,
  o_existing_decision_id  uuid,
  o_error_code            text
)
language plpgsql security definer set search_path = public, pg_temp
as $promote$
declare
  v_action        text;
  v_capture       uuid;
  v_user          uuid;
  v_account       text;
  v_position      bigint;
  v_basis_run     uuid;

  v_promo_id      uuid;
  v_trade_id      text;
  v_other_dec     uuid;

  v_basis         public.mt5_sync_run_positions%rowtype;
  v_fresh         public.mt5_sync_run_positions%rowtype;
  v_fresh_run     public.mt5_sync_runs%rowtype;

  v_product_id    text;
  v_map_error     text;

  v_direction     text;
  v_open_local    text;
  v_raw           jsonb;

  v_now           timestamptz;
  v_age           interval;
  v_constraint    text;
begin
  -- 0. CALL SHAPE ---------------------------------------------------------------------------
  if p_decision is null then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_BAD_INPUT'::text;
    return;
  end if;

  -- 1. SERIALIZE SAME-DECISION EXECUTIONS ---------------------------------------------------
  -- Transaction-scoped; released at commit/rollback. Two concurrent calls for the same decision
  -- run strictly one after the other, so the loser observes the winner's promotion row in step 3
  -- and returns the deterministic replay result instead of racing to the unique constraint.
  perform pg_advisory_xact_lock(hashtextextended('mt5_t4b_decision:' || p_decision::text, 0));

  -- 2. DECISION AND SCOPE -------------------------------------------------------------------
  -- Ownership is NOT taken from the caller: user_id / source_account / position_id / basis_run_id
  -- all come from the immutable capture row the decision points at.
  select d.action, d.capture_event_id into v_action, v_capture
    from public.mt5_capture_decisions d
   where d.id = p_decision;
  if not found then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_DECISION_NOT_FOUND'::text;
    return;
  end if;

  select c.user_id, c.source_account, c.position_id, c.basis_run_id
    into v_user, v_account, v_position, v_basis_run
    from public.mt5_capture_events c
   where c.id = v_capture;
  if not found or v_user is null or coalesce(btrim(v_account), '') = ''
     or v_position is null or v_basis_run is null then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_EVIDENCE_NOT_FOUND'::text;
    return;
  end if;

  -- 3. REPLAY PRECEDENCE --------------------------------------------------------------------
  -- Existing fulfilment is resolved BEFORE any eligibility is re-evaluated. A decision promoted
  -- while the evidence was fresh must stay replayable after the window closes, after the position
  -- disappears, and after the product catalog is edited. Nothing below this block may run for an
  -- already-fulfilled decision.
  select p.id, p.trade_id into v_promo_id, v_trade_id
    from public.mt5_capture_promotions p
   where p.decision_id = p_decision;
  if found then
    -- The user may freely EDIT the promoted trade; replay never compares its contents. What must
    -- still hold is that the row IS the incarnation this promotion created — same id, same owner,
    -- same marker. A deleted-and-recreated row fails here, which is the point.
    if public.mt5_t4b_validate_fulfillment_v1(v_promo_id, v_trade_id, v_user) then
      return query select true, 0, v_promo_id, v_trade_id, null::uuid, null::text;
      return;
    end if;
    -- Fulfilled, but the object is gone, is owned by somebody else, or is a different incarnation
    -- reusing the id. Never silently recreate it and never create a second one: this is an
    -- incident for a human.
    return query select false, 0, v_promo_id, v_trade_id, null::uuid, 'ERR_FULFILLMENT_DRIFT'::text;
    return;
  end if;

  -- 4. ELIGIBILITY: THE DECISION MUST BE journal_add -----------------------------------------
  if v_action is distinct from 'journal_add' then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_NOT_JOURNAL_ADD'::text;
    return;
  end if;

  -- 5. DURABLE MT5 IDENTITY ALREADY FULFILLED BY ANOTHER DECISION ----------------------------
  -- A REAPPEARANCE capture for the same real position produces a different capture_event_id and a
  -- different decision_id. UNIQUE(decision_id) alone would happily create a SECOND Journal trade
  -- for one real position; this is the check that prevents it. The result names the existing
  -- promotion, trade and decision so an operator can see what already happened, and claims
  -- nothing about THIS decision (it is not fulfilled, and o_ok is false).
  perform pg_advisory_xact_lock(hashtextextended(
    'mt5_t4b_pos:' || v_user::text || '|' || v_account || '|' || v_position::text, 0));

  select p.id, p.trade_id, p.decision_id into v_promo_id, v_trade_id, v_other_dec
    from public.mt5_capture_promotions p
   where p.user_id = v_user and p.source_account = v_account and p.position_id = v_position;
  if found then
    return query select false, 0, v_promo_id, v_trade_id, v_other_dec,
                        'ERR_POSITION_ALREADY_PROMOTED'::text;
    return;
  end if;

  -- 5b. THE ELIGIBILITY CLOCK -----------------------------------------------------------------
  -- WALL CLOCK, captured HERE: after every lock this call must wait on, and before the first
  -- freshness comparison. now() is transaction-start time, so revision 1 could enter the
  -- transaction while the evidence was fresh, block behind another writer for longer than the
  -- window, and then promote against evidence that had gone stale while it waited.
  --
  -- One instant is captured and reused for BOTH freshness comparisons, so they cannot disagree
  -- with each other; clock_timestamp() is deliberately not called twice.
  v_now := clock_timestamp();

  -- 6. BASIS FACTS (immutable, contemporaneous with the capture) ------------------------------
  select * into v_basis
    from public.mt5_sync_run_positions
   where run_id = v_basis_run and position_id = v_position;
  if not found or v_basis.user_id is distinct from v_user
     or v_basis.source_account is distinct from v_account then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_BASIS_NOT_FOUND'::text;
    return;
  end if;
  -- S1 permits nulls on these columns. A Journal trade cannot be built from a null entry price,
  -- open time or contract size, and no other source may substitute for them.
  if v_basis.price_open is null or v_basis.open_time_utc is null
     or v_basis.contract_size is null or v_basis.volume is null
     or coalesce(btrim(v_basis.symbol_raw), '') = '' or v_basis.side is null then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_BASIS_INCOMPLETE'::text;
    return;
  end if;

  -- 7. FRESHNESS: THE NEWEST RUN FOR THIS SCOPE, WHATEVER ITS STATE ---------------------------
  -- Deliberately NOT "the newest healthy run": skipping a newer failed/incomplete/suspicious run
  -- in favour of an older healthy one would promote against evidence we have reason to doubt.
  -- The newest run is selected first and then required to be complete, healthy and inside the
  -- server-owned window.
  select * into v_fresh_run
    from public.mt5_sync_runs
   where user_id = v_user and source_account = v_account
   order by captured_at desc, run_seq desc nulls last, id desc
   limit 1;
  if not found then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_STALE_EVIDENCE'::text;
    return;
  end if;
  v_age := v_now - v_fresh_run.captured_at;
  if v_fresh_run.snapshot_status is distinct from 'complete'
     or v_fresh_run.snapshot_health is distinct from 'healthy'
     -- a future-dated capture (clock skew) yields a negative age and is refused, not trusted
     or v_age < interval '0'
     -- frozen boundary: age = 7200s is fresh, age > 7200s is not
     or v_age > public.mt5_t4b_freshness_window_v1() then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_STALE_EVIDENCE'::text;
    return;
  end if;

  -- 8. THE POSITION MUST STILL BE THERE -------------------------------------------------------
  -- Absence is NOT a close. It is simply a refusal to assert "open" today. S2 owns lifecycle.
  select * into v_fresh
    from public.mt5_sync_run_positions
   where run_id = v_fresh_run.id and position_id = v_position;
  if not found then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_POSITION_ABSENT'::text;
    return;
  end if;

  -- 9. STRICT SEVEN-FIELD BASIS/FRESH EQUALITY ------------------------------------------------
  -- Exact canonical semantics (`is distinct from`, numeric equality by value — no tolerance, no
  -- rounding, no epsilon). VOLUME IS INCLUDED AND LOAD-BEARING: a changed volume may mean a
  -- scale-in, a partial close, or a net lifecycle change, and S2 is not available to tell them
  -- apart. We do not promote the reduced volume, the increased volume, an average, or the latest.
  -- We refuse.
  if v_fresh.position_id    is distinct from v_basis.position_id
     or v_fresh.symbol_raw    is distinct from v_basis.symbol_raw
     or v_fresh.side          is distinct from v_basis.side
     or v_fresh.price_open    is distinct from v_basis.price_open
     or v_fresh.open_time_utc is distinct from v_basis.open_time_utc
     or v_fresh.contract_size is distinct from v_basis.contract_size
     or v_fresh.volume        is distinct from v_basis.volume then
    return query select false, 0, null::uuid, null::text, null::uuid,
                        'ERR_POSITION_FACT_DRIFT'::text;
    return;
  end if;

  -- 10. PRODUCT MAPPING (exact contract code, fail closed) -------------------------------------
  select m.product_id, m.error_code into v_product_id, v_map_error
    from public.mt5_t4b_map_product_v1(v_user, v_basis.symbol_raw, v_basis.contract_size) m;
  if v_map_error is not null or v_product_id is null then
    return query select false, 0, null::uuid, null::text, null::uuid, 'ERR_PRODUCT_MAPPING'::text;
    return;
  end if;

  -- 11. THE RESERVED TRADE ID ------------------------------------------------------------------
  -- DETERMINISTIC, derived from the decision id: 'mt5p_' + its 32 lowercase hex digits. The
  -- browser's generator (`let _seq = Date.now(); uid = () => \`${++_seq}\``) emits decimal digits
  -- only, so the two namespaces cannot intersect at any millisecond, under any clock, ever. There
  -- is no wall-clock component, no collision retry loop and no global id-mint lock — the same
  -- decision always targets the same trade id.
  --
  -- Revision 1 minted epoch-ms ids inside the browser's own namespace, which was the defect: the
  -- browser's db.saveTrade upserts with onConflict:"id" and takes no T4B lock, so a same-
  -- millisecond browser write could have overwritten a promoted row.
  v_trade_id := 'mt5p_' || replace(p_decision::text, '-', '');

  -- The reserved id must be free. Step 3 already proved this decision has no promotion, so an
  -- occupant is NOT a replay — it is an unrelated row sitting on our deterministic address. Fail
  -- closed: never overwrite it, never upsert into it, never adopt it, never pick a nearby id.
  if exists (select 1 from public.trades t where t.id = v_trade_id) then
    return query select false, 0, null::uuid, v_trade_id, null::uuid,
                        'ERR_TRADE_ID_COLLISION'::text;
    return;
  end if;

  -- 12. THE CANONICAL JOURNAL TRADE -------------------------------------------------------------
  v_direction  := case v_basis.side when 'buy' then 'Long' else 'Short' end;
  -- The app stores openDateTime as a datetime-local string in Bangkok wall time, minute precision
  -- (e.g. "2026-07-03T12:00"). Not ISO-UTC: the UI binds it straight to <input type=datetime-local>.
  v_open_local := to_char(v_basis.open_time_utc at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI');

  -- Exactly the 19 keys the UI's buildTrade() emits for a new open trade, plus mt5PositionId (the
  -- established MT5 identity key already carried by 121 production rows). No extra key, no missing
  -- key. currentPrice mirrors entryPrice exactly as buildTrade does for a fresh trade — it is the
  -- app's own default, NOT the S1 price_current mark, and no floating profit is persisted anywhere.
  --
  -- mt5PositionId here is COMPATIBILITY AND DISPLAY metadata, not the durable attachment
  -- authority: an ordinary Journal edit rewrites `raw` wholesale through the 19-key buildTrade
  -- shape and drops it. The authoritative S2 join is the promotion ledger,
  -- (user_id, source_account, position_id) -> trade_id, which no user action can rewrite.
  v_raw := jsonb_build_object(
    'id',            v_trade_id,
    'status',        'open',
    'productId',     v_product_id,
    'direction',     v_direction,
    'contracts',     v_basis.volume,
    'entryPrice',    v_basis.price_open,
    'currentPrice',  v_basis.price_open,
    'stopLoss',      null,
    'takeProfit',    null,
    'openDateTime',  v_open_local,
    'setupType',     'Other',
    'preNote',       '',
    'preImages',     '[]'::jsonb,
    'postImages',    '[]'::jsonb,
    'partialCloses', '[]'::jsonb,
    'isMerged',      false,
    'mergedFromIds', '[]'::jsonb,
    'subTrades',     '[]'::jsonb,
    'contractCode',  v_basis.symbol_raw,
    'mt5PositionId', v_position::text
  );

  -- Projected columns exactly as the browser's toTradeRow() writes them. entry_date, exit_date and
  -- note are NULL in all 155 production rows because no trade object has ever carried entryDate /
  -- exitDate / note keys — writing anything else here would make T4B rows structurally unlike
  -- every other row in the table. group_id is left to its default NULL: grouping is a separate
  -- concern and T4B never calls create_trade_group_v1.
  begin
    -- LINEAGE FIRST. The trades incarnation guard requires a matching ledger row to already
    -- exist, which is what makes the marker unforgeable by any client: the ledger has no INSERT
    -- grant to any role and is append-once. Both inserts are in one block, so there is no state
    -- in which either exists without the other.
    insert into public.mt5_capture_promotions (
      decision_id, capture_event_id, trade_id, user_id, source_account, position_id,
      basis_run_id, fresh_run_id
    ) values (
      p_decision, v_capture, v_trade_id, v_user, v_account, v_position,
      v_basis_run, v_fresh_run.id
    ) returning id into v_promo_id;

    insert into public.trades (
      id, user_id, product_id, direction, status, contracts, remaining_contracts,
      entry_price, exit_price, entry_date, exit_date, note, raw, mt5_promotion_id
    ) values (
      v_trade_id, v_user, v_product_id, v_direction, 'open', v_basis.volume, v_basis.volume,
      v_basis.price_open, null, null, null, null, v_raw, v_promo_id
    );
  exception
    -- CONSTRAINT-AWARE. Revision 1 caught every unique_violation and guessed by re-querying,
    -- which meant an unrelated uniqueness defect could be reported as a recognised outcome. The
    -- violated constraint is now read from the diagnostics and only explicitly known constraints
    -- are handled; anything else is RE-RAISED unchanged. There is deliberately no `when others`
    -- anywhere in this packet.
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;

      if v_constraint = 'mt5_cp_decision_uk' then
        -- Someone else fulfilled this decision. Route through the SAME validator the replay path
        -- uses — a shallow "a row exists, call it replay" here would reintroduce the very defect
        -- the incarnation marker fixes.
        select p.id, p.trade_id into v_promo_id, v_trade_id
          from public.mt5_capture_promotions p where p.decision_id = p_decision;
        if not found then
          raise;   -- the constraint says it exists and we cannot see it: do not invent an answer
        end if;
        if public.mt5_t4b_validate_fulfillment_v1(v_promo_id, v_trade_id, v_user) then
          return query select true, 0, v_promo_id, v_trade_id, null::uuid, null::text;
          return;
        end if;
        return query select false, 0, v_promo_id, v_trade_id, null::uuid,
                            'ERR_FULFILLMENT_DRIFT'::text;
        return;

      elsif v_constraint = 'mt5_cp_position_uk' then
        select p.id, p.trade_id, p.decision_id into v_promo_id, v_trade_id, v_other_dec
          from public.mt5_capture_promotions p
         where p.user_id = v_user and p.source_account = v_account and p.position_id = v_position;
        if not found then
          raise;
        end if;
        return query select false, 0, v_promo_id, v_trade_id, v_other_dec,
                            'ERR_POSITION_ALREADY_PROMOTED'::text;
        return;

      elsif v_constraint = 'mt5_cp_trade_uk' then
        -- Another promotion already claims this reserved trade id.
        return query select false, 0, null::uuid, v_trade_id, null::uuid,
                            'ERR_TRADE_ID_COLLISION'::text;
        return;

      elsif v_constraint = 'mt5_trades_promotion_uk' then
        -- Two promotions carrying the same incarnation marker. gen_random_uuid() collided, or the
        -- ledger was tampered with. Neither is a recognised outcome; surface it as the defect it
        -- is rather than dressing it up as a promotion result.
        raise;

      elsif exists (select 1 from pg_catalog.pg_constraint c
                     where c.conname = v_constraint
                       and c.conrelid = 'public.trades'::regclass) then
        -- Any uniqueness on public.trades itself (its primary key, or the UNIQUE(id) the browser's
        -- onConflict:"id" upsert depends on). Matched by RELATION, not by a hardcoded constraint
        -- name, because that name differs between the production table and the offline substrate.
        return query select false, 0, null::uuid, v_trade_id, null::uuid,
                            'ERR_TRADE_ID_COLLISION'::text;
        return;

      else
        -- An unknown uniqueness defect. Fail closed and loudly: never translate it into one of the
        -- thirteen frozen outcomes.
        raise;
      end if;
  end;

  return query select true, 1, v_promo_id, v_trade_id, null::uuid, null::text;
  return;
end
$promote$;

alter function public.mt5_promote_capture_decision_v1(uuid) owner to postgres;

-- ------------------------------------------------------------------------------------------------
-- ACLs. Only the bot (service_role) may promote. The browser has no reason to: a promotion is a
-- server-side fulfilment of a server-side decision, and exposing it to `authenticated` would add a
-- second, weaker path to Journal creation. Helpers stay callable only by the definer.
-- ------------------------------------------------------------------------------------------------
revoke all on function public.mt5_promote_capture_decision_v1(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.mt5_promote_capture_decision_v1(uuid) to service_role;

do $t4b_rpc_post$
declare
  v_bad text;
begin
  -- Every T4B function must be SECURITY DEFINER with the EXACT frozen search_path. A path that
  -- merely starts with 'search_path=' is not accepted: 'search_path=public, pg_temp, evil' would
  -- satisfy that and change resolution.
  select string_agg(p.proname, ', ') into v_bad
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('mt5_promote_capture_decision_v1', 'mt5_t4b_map_product_v1',
                       'mt5_t4b_freshness_window_v1', 'mt5_t4b_validate_fulfillment_v1')
     and (not p.prosecdef
          or p.proconfig is distinct from array['search_path=public, pg_temp']);
  if v_bad is not null then
    raise exception 'MT5_T4B_RPC_POSTFLIGHT: not SECURITY DEFINER with the exact frozen '
      'search_path (public, pg_temp): %', v_bad;
  end if;

  -- the freshness window is the frozen 7200 seconds
  if public.mt5_t4b_freshness_window_v1() <> interval '7200 seconds' then
    raise exception 'MT5_T4B_RPC_POSTFLIGHT: freshness window is not the frozen 7200 seconds';
  end if;

  -- The promotion RPC takes exactly ONE input argument and it is a uuid: no symbol, price,
  -- volume, product, trade id or freshness override can be passed by any caller. Asserted on
  -- proargtypes (the IN types) rather than on the identity string, which also carries parameter
  -- NAMES and would break on a rename that changes nothing about the surface. Exactly one
  -- overload may exist, so no wider variant can be smuggled in alongside it.
  if (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n
                             on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'mt5_promote_capture_decision_v1') <> 1 then
    raise exception 'MT5_T4B_RPC_POSTFLIGHT: promotion RPC is not a single overload';
  end if;
  if not exists (
      select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'mt5_promote_capture_decision_v1'
         and p.pronargs = 1
         and (select t.typname from pg_catalog.pg_type t where t.oid = p.proargtypes[0]) = 'uuid')
  then
    raise exception 'MT5_T4B_RPC_POSTFLIGHT: promotion RPC does not take exactly one uuid argument';
  end if;

  -- helpers must NOT be executable by any client role
  if has_function_privilege('service_role',
       'public.mt5_t4b_map_product_v1(uuid, text, numeric)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.mt5_t4b_freshness_window_v1()', 'EXECUTE')
     or has_function_privilege('service_role',
          'public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid)', 'EXECUTE')
     or has_function_privilege('authenticated',
          'public.mt5_promote_capture_decision_v1(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.mt5_promote_capture_decision_v1(uuid)', 'EXECUTE')
  then
    raise exception 'MT5_T4B_RPC_POSTFLIGHT: executable surface is wider than the single '
      'service_role promotion RPC';
  end if;
end $t4b_rpc_post$;

insert into public.mt5_schema_migrations(
  version, description, checksum, source_artifact_sha256, status, objects, applied_at, applied_by
) values (
  'mt5_t4b_promotion_rpc_v1',
  'T4B three-way-join promotion RPC: decision x capture x S1 basis, 2h newest-run wall-clock '
  'freshness, strict seven-field basis/fresh equality, exact product mapping, reserved '
  'deterministic trade-id namespace, incarnation-validated replay, dual exactly-once fulfilment',
  -- CANONICAL PACKET DIGEST — see the schema packet's note. Generated by T4B_packet_identity.py.
  'b2bcf6d310f50bc21c6536298543eea4bd080256952ad9c0994608cdc0127d63',  -- T4B_CANONICAL_DIGEST_V1
  'FF3B6F6789A1E5127E11B8C1650BCD745FF375C9A6CB69823D459EAD03084E2B',  -- T4B_CONTRACT_DIGEST_V1
  'applied',
  jsonb_build_object(
    'packet_revision', '6',
    'functions', jsonb_build_array(
      'public.mt5_promote_capture_decision_v1(uuid)',
      'public.mt5_t4b_map_product_v1(uuid, text, numeric)',
      'public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid)',
      'public.mt5_t4b_freshness_window_v1()'
    ),
    -- EXACT DEPLOYED BODIES — see the schema packet's note. Without this, a validator replaced by
    -- `select true` or a product mapper replaced by an arbitrary result keeps its signature,
    -- security, volatility and search_path, and every metadata check still passes.
    -- Keyed by FULL IDENTITY SIGNATURE (schema-qualified name plus argument TYPES), not by bare
    -- proname: a same-named overload is a different function, and the verifier resolves each key
    -- back through to_regprocedure so it can only ever land on the exact function recorded here.
    -- Built from proargtypes rather than pg_get_function_identity_arguments, which renders
    -- parameter names too and would produce a string regprocedure cannot parse.
    'function_digests', (
      select jsonb_object_agg(
               format('%s.%s(%s)', n.nspname, p.proname,
                      coalesce((select string_agg(format_type(u.t, null), ', ' order by u.ord)
                                  from unnest(p.proargtypes) with ordinality u(t, ord)), '')),
               encode(sha256(convert_to(pg_get_functiondef(p.oid), 'UTF8')), 'hex'))
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('mt5_promote_capture_decision_v1', 'mt5_t4b_map_product_v1',
                           'mt5_t4b_validate_fulfillment_v1', 'mt5_t4b_freshness_window_v1')),
    'freshness_window_seconds', 7200,
    'freshness_boundary', 'age <= 7200s fresh; age > 7200s stale; negative age refused',
    'freshness_clock', 'clock_timestamp() captured after all pre-eligibility locks',
    'trade_id_namespace', 'mt5p_<32 lowercase uuid hex> derived from decision_id',
    'result_columns', jsonb_build_array(
      'o_ok', 'o_inserted', 'o_promotion_id', 'o_trade_id', 'o_existing_decision_id', 'o_error_code'
    )
  ),
  now(),
  current_user
);

do $t4b_rpc_ledger_post$
begin
  if not exists (select 1 from public.mt5_schema_migrations
                  where version = 'mt5_t4b_promotion_rpc_v1' and status = 'applied'
                    and (objects->>'packet_revision') = '6'
                    and objects ? 'function_digests')
  then
    raise exception 'MT5_T4B_RPC_POSTFLIGHT: the RPC ledger row was not recorded as applied';
  end if;

  -- The recorded inventory must be EXACTLY this packet's four functions, by full signature. A
  -- count of four would happily accept a required key swapped for an unrelated deployed function
  -- carrying its own correct digest, leaving the removed T4B body unverified.
  if (select array_agg(k order by k)
        from public.mt5_schema_migrations m,
             lateral jsonb_object_keys(m.objects->'function_digests') k
       where m.version = 'mt5_t4b_promotion_rpc_v1')
     is distinct from array['public.mt5_promote_capture_decision_v1(uuid)',
                            'public.mt5_t4b_freshness_window_v1()',
                            'public.mt5_t4b_map_product_v1(uuid, text, numeric)',
                            'public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid)'] then
    raise exception 'MT5_T4B_RPC_POSTFLIGHT: the RPC ledger row records the wrong function '
      'inventory';
  end if;
end $t4b_rpc_ledger_post$;

commit;
