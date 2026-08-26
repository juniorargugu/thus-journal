-- ================================================================================================
-- PRODUCTION-SAFE APPLY
-- T4B JOURNAL PROMOTION — SCHEMA PACKET (mt5_t4b_promotion_schema_v1, packet revision 6)
--
-- One immutable FULFILLMENT record per T4A journal_add decision that became a canonical Journal
-- trade. This table is EXECUTION lineage — it is not a decision (T4A), not machine evidence
-- (S1/T1/T2), and not the Journal trade itself. It is the authoritative provenance store, because
-- the Journal trade's `raw` payload is rewritten wholesale by the browser on every ordinary user
-- edit and therefore cannot be trusted to carry lineage.
--
-- Frozen contract (T4B-1, revision 2):
--   * DUAL exactly-once identity, both DB-enforced:
--       - UNIQUE(decision_id)                          one T4A decision is fulfilled at most once
--       - UNIQUE(user_id, source_account, position_id) one real MT5 position becomes at most one
--                                                      promoted Journal trade, EVEN IF a later
--                                                      REAPPEARANCE capture produces a different
--                                                      capture_event_id and decision_id
--     UNIQUE(decision_id) alone is NOT sufficient: see the cross-decision case in the RPC packet.
--   * UNIQUE(trade_id): a Journal trade is promoted from at most one MT5 position.
--   * RESERVED TRADE-ID NAMESPACE (revision 2). Trade ids are `mt5p_<32 lowercase uuid hex>`,
--     derived deterministically from the decision id. The browser's generator is
--     `let _seq = Date.now(); const uid = () => \`${++_seq}\`` — pure decimal digits — so the two
--     namespaces are DISJOINT BY CONSTRUCTION and a browser save can never mint an id that lands
--     on a promoted row. Revision 1 minted epoch-ms ids in the browser's own namespace and was
--     wrong: db.saveTrade upserts with onConflict:"id" and does not participate in any T4B lock,
--     so a same-millisecond browser write could have overwritten a promoted trade.
--   * TRADE INCARNATION MARKER (revision 2): public.trades.mt5_promotion_id. A promoted row
--     carries the promotion's own id. It proves THIS row is the object T4B created, not merely a
--     row that happens to reuse the id. Ordinary Journal edits preserve it (see the guard below);
--     delete + re-insert cannot regain it. Replay validates it.
--   * SCOPE-SAFE run linkage: basis and fresh runs are referenced by the COMPOSITE key
--     (id, user_id, source_account), the same trick mt5_sync_run_positions uses, so a promotion
--     can never cite a run belonging to a different user or trading account.
--   * NO foreign key to public.trades. Deliberate: a restricting FK would make a promoted trade
--     undeletable through the normal Journal UI, over-constraining ordinary usage; a cascading FK
--     would silently erase provenance, which the contract forbids outright. Instead the promotion
--     row survives independently and a missing trade is DETECTED at replay time as
--     ERR_FULFILLMENT_DRIFT. Lineage outliving the object it describes is the point.
--   * append-once: never UPDATE, never DELETE (guard trigger below).
--   * no mutable trading state is duplicated here — no price, no volume, no symbol, no product.
--
-- Ownership/administrative caveat (same as every ledger table in this pipeline): the table owner
-- (postgres) can still ALTER/DROP/TRUNCATE — PostgreSQL offers no stronger guarantee. The guard
-- blocks the row-mutation paths the application could ever reach.
--
-- APPLY (offline first): psql -v ON_ERROR_STOP=1 -f T4B_promotion_schema_packet.sql
-- Production apply is NOT authorized by T4B-1.
-- ================================================================================================

begin;

-- ------------------------------------------------------------------------------------------------
-- Preflight: every parent this table references must already exist with its frozen shape, the
-- migrations registry must exist, and this packet must not already be applied.
-- ------------------------------------------------------------------------------------------------
do $t4b_pre$
declare
  v_cols text[];
  v_n    integer;
begin
  if to_regclass('public.mt5_schema_migrations') is null then
    raise exception 'MT5_T4B_PREFLIGHT: public.mt5_schema_migrations does not exist';
  end if;
  if to_regclass('public.mt5_capture_events') is null then
    raise exception 'MT5_T4B_PREFLIGHT: public.mt5_capture_events does not exist';
  end if;
  if to_regclass('public.mt5_capture_decisions') is null then
    raise exception 'MT5_T4B_PREFLIGHT: public.mt5_capture_decisions does not exist (apply T4A first)';
  end if;
  if to_regclass('public.mt5_sync_runs') is null then
    raise exception 'MT5_T4B_PREFLIGHT: public.mt5_sync_runs does not exist (apply S1 first)';
  end if;
  if to_regclass('public.mt5_sync_run_positions') is null then
    raise exception 'MT5_T4B_PREFLIGHT: public.mt5_sync_run_positions does not exist (apply S1 first)';
  end if;
  if to_regclass('public.trades') is null then
    raise exception 'MT5_T4B_PREFLIGHT: public.trades does not exist';
  end if;
  if to_regclass('public.products') is null then
    raise exception 'MT5_T4B_PREFLIGHT: public.products does not exist';
  end if;

  -- The decision table must still be the frozen T4A seven columns: the promotion RPC reads
  -- action + capture_event_id from it and nothing else.
  select array_agg(column_name::text order by column_name) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'mt5_capture_decisions';
  if v_cols is distinct from array[
      'action','capture_event_id','created_at','id','source','telegram_chat_id',
      'telegram_message_id'] then
    raise exception 'MT5_T4B_PREFLIGHT: mt5_capture_decisions columns are not the frozen 7: %', v_cols;
  end if;

  -- The composite run key this table's FKs depend on must exist.
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conrelid = 'public.mt5_sync_runs'::regclass
       and conname  = 'mt5_sync_runs_id_scope_uniq') then
    raise exception 'MT5_T4B_PREFLIGHT: mt5_sync_runs_id_scope_uniq is missing — the scope-safe '
      'run foreign keys cannot be created';
  end if;

  -- trades.id must be TEXT. The reserved 'mt5p_<hex>' namespace is not representable in a numeric
  -- column at all, so this is now load-bearing rather than merely a comparison-semantics concern.
  -- Independently corroborated: migrations/20260705_g2_trade_group_rpcs.sql carries the same hard
  -- precondition (it passes trade ids as text[] and compares public.trades.id = ANY(...)) and is
  -- applied in production.
  if (select data_type from information_schema.columns
       where table_schema='public' and table_name='trades' and column_name='id') <> 'text' then
    raise exception 'MT5_T4B_PREFLIGHT: public.trades.id is not text — the reserved trade-id '
      'namespace cannot be represented, STOP and re-audit';
  end if;

  -- RESERVED NAMESPACE OCCUPANCY. No pre-existing Journal row may already sit in the T4B
  -- namespace: promotion derives its trade id deterministically and must never collide with,
  -- adopt, or overwrite an unrelated row. Asserted rather than assumed.
  select count(*) into v_n from public.trades t where t.id ~ '^mt5p_';
  if v_n <> 0 then
    raise exception 'MT5_T4B_PREFLIGHT: % existing trades already occupy the reserved mt5p_ '
      'namespace — STOP, the deterministic trade-id contract does not hold', v_n;
  end if;

  -- The trades incarnation marker must not already exist under a different definition.
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='trades'
                and column_name='mt5_promotion_id') then
    raise exception 'MT5_T4B_PREFLIGHT: public.trades.mt5_promotion_id already exists — apply '
      'once, or run the rollback packet first';
  end if;

  -- PRODUCT CATALOG CARDINALITY. The promotion RPC requires exactly one catalog row per user and
  -- enforces that at runtime regardless of schema. This preflight additionally asserts the
  -- structural guarantee the Journal app itself already depends on: db.loadAll reads products with
  -- .maybeSingle(), which errors outright on a second row. A missing constraint here is a latent
  -- application bug, not a T4B assumption, and is surfaced BEFORE any T4B object is created.
  -- If production deliberately lacks it, add it or consciously waive this line — do not weaken the
  -- runtime count=1 rule, which stays mandatory either way.
  select count(*) into v_n
    from pg_catalog.pg_constraint c
   where c.conrelid = 'public.products'::regclass
     and c.contype in ('p','u')
     and c.conkey = array[(select a.attnum from pg_catalog.pg_attribute a
                            where a.attrelid = 'public.products'::regclass
                              and a.attname = 'user_id' and not a.attisdropped)];
  if v_n = 0 then
    raise exception 'MT5_T4B_PREFLIGHT: public.products has no PRIMARY KEY or UNIQUE constraint on '
      '(user_id) — duplicate catalogs are possible; resolve before applying T4B';
  end if;

  if to_regclass('public.mt5_capture_promotions') is not null then
    raise exception 'MT5_T4B_PREFLIGHT: public.mt5_capture_promotions already exists — apply once, '
      'or run the rollback packet first';
  end if;
end $t4b_pre$;

-- ------------------------------------------------------------------------------------------------
-- The promotion ledger.
-- ------------------------------------------------------------------------------------------------
create table public.mt5_capture_promotions (
  id                uuid        not null default gen_random_uuid(),

  -- WORKFLOW fulfillment identity: which human decision this execution fulfilled.
  decision_id       uuid        not null,
  capture_event_id  uuid        not null,

  -- The Journal object created. Text, matching public.trades.id. No FK — see the header.
  trade_id          text        not null,

  -- DURABLE MT5 TRADING identity. Duplicated here ON PURPOSE (unlike T4A, which derives scope
  -- from its parent): this triple is the second uniqueness axis and must be enforceable by a
  -- single table constraint rather than by a join.
  user_id           uuid        not null,
  source_account    text        not null,
  position_id       bigint      not null,

  -- Evidence lineage: where the facts came from, and what proved the position still existed.
  basis_run_id      uuid        not null,
  fresh_run_id      uuid        not null,

  created_at        timestamptz not null default now(),

  constraint mt5_capture_promotions_pkey primary key (id),

  -- DUAL exactly-once.
  constraint mt5_cp_decision_uk unique (decision_id),
  constraint mt5_cp_position_uk unique (user_id, source_account, position_id),
  constraint mt5_cp_trade_uk    unique (trade_id),

  constraint mt5_cp_decision_fk foreign key (decision_id)
    references public.mt5_capture_decisions(id),
  constraint mt5_cp_capture_fk foreign key (capture_event_id)
    references public.mt5_capture_events(id),

  -- Scope-safe run references: the run must belong to THIS user and THIS account.
  constraint mt5_cp_basis_run_fk foreign key (basis_run_id, user_id, source_account)
    references public.mt5_sync_runs(id, user_id, source_account),
  constraint mt5_cp_fresh_run_fk foreign key (fresh_run_id, user_id, source_account)
    references public.mt5_sync_runs(id, user_id, source_account),

  constraint mt5_cp_account_nonblank_chk check (btrim(source_account) <> ''),

  -- THE RESERVED NAMESPACE, enforced by the database and not merely by the minting code:
  -- 'mt5p_' + the decision uuid's 32 lowercase hex digits. Disjoint from the browser's decimal
  -- uid() namespace, disjoint from the demo-trade shape /^m\d+$/ the app refuses to persist, and
  -- deterministic, so no wall clock and no retry loop are involved in choosing it.
  constraint mt5_cp_trade_id_shape_chk check (trade_id ~ '^mt5p_[0-9a-f]{32}$')
);

alter table public.mt5_capture_promotions owner to postgres;

comment on table public.mt5_capture_promotions is
  'T4B: one immutable fulfillment record per T4A journal_add decision that became a canonical '
  'Journal trade. Authoritative EXECUTION provenance — the Journal trade raw payload is rewritten '
  'by the browser on every user edit and cannot carry lineage. Dual exactly-once: UNIQUE '
  '(decision_id) and UNIQUE(user_id, source_account, position_id). No FK to trades: a promoted '
  'trade stays user-deletable and a missing trade surfaces as ERR_FULFILLMENT_DRIFT. This table is '
  'also the AUTHORITATIVE S2 attachment map: (user_id, source_account, position_id) -> trade_id.';
comment on column public.mt5_capture_promotions.basis_run_id is
  'The S1 run whose immutable position row supplied entry price / open time / contract size. '
  'Contemporaneous with the capture; never re-read from a newer run.';
comment on column public.mt5_capture_promotions.fresh_run_id is
  'The newest completed+healthy S1 run that proved the position still existed at promotion time. '
  'Presence evidence only — no fact is taken from it.';
comment on column public.mt5_capture_promotions.trade_id is
  'Reserved namespace mt5p_<32 hex>, derived deterministically from decision_id. Disjoint from the '
  'browser uid() decimal namespace by construction.';

-- ------------------------------------------------------------------------------------------------
-- Ledger immutability guard. Mirrors the proven mt5_capture_decision_guard_v1() shape.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_capture_promotion_guard_v1() returns trigger
language plpgsql security definer set search_path = ''
as $guard$
begin
  -- A promotion is terminal execution lineage. If a fulfilled trade is later deleted or corrected,
  -- that is reconciled by a FUTURE explicit contract, never by editing or deleting this record.
  raise exception 'MT5_T4B_IMMUTABLE_ROW' using errcode = 'P0001';
end
$guard$;
alter function public.mt5_capture_promotion_guard_v1() owner to postgres;
revoke all on function public.mt5_capture_promotion_guard_v1()
  from public, anon, authenticated, service_role;

create trigger mt5_capture_promotion_no_mutate_v1
  before update or delete on public.mt5_capture_promotions
  for each row execute function public.mt5_capture_promotion_guard_v1();

-- ------------------------------------------------------------------------------------------------
-- THE TRADE INCARNATION MARKER (revision 2).
--
-- The problem it solves: a promotion ledger row names a trade id. If the user deletes that trade
-- and any same-owner row is later created carrying the same id, an id+owner replay check would
-- report a clean replay against an unrelated object. The marker makes "is this the row T4B
-- created?" a fact rather than an inference.
--
-- Why a nullable column and not a hash of the row: the user must remain free to edit a promoted
-- trade in every ordinary way. Nothing about the trade's CONTENT is constrained — only its
-- identity as an incarnation.
--
-- How ordinary Journal writes keep working, unchanged:
--   * db.saveTrade builds its payload from toTradeRow(), which emits 13 columns and NOT this one.
--     PostgREST upsert compiles to INSERT ... ON CONFLICT (id) DO UPDATE SET <payload columns>;
--     a column absent from the SET list keeps its stored value, so an edit PRESERVES the marker.
--   * The exact same mechanism already carries trades.group_id, a projected column the browser
--     reads but toTradeRow has never written. This is a proven pattern in this schema, not a new
--     assumption.
--   * db.loadAll selects (raw, group_id) and rehydrates trades from `raw`, so the marker never
--     enters the app's in-memory trade object and can never be echoed back into `raw`.
--   * A DELETE followed by a fresh INSERT takes the INSERT path, where the marker defaults to
--     NULL — which is precisely the drift signal we want.
--
-- WHY THE TRIGGER ALONE IS NOT ENOUGH (revision 3). The table-level INSERT privilege the Journal
-- app already holds extends to any column added later, including this one. An authenticated owner
-- could therefore read their own marker, delete the trade, and re-insert the SAME
-- (id, user_id, mt5_promotion_id) tuple — which the guard accepts, because that tuple genuinely
-- matches its ledger row. The guard cannot tell a restoration from the original write, so the
-- privilege has to go: the column is removed from every client role's writable surface below, and
-- the marker becomes writable only by the table owner, i.e. only by the SECURITY DEFINER RPC.
-- ------------------------------------------------------------------------------------------------
alter table public.trades add column mt5_promotion_id uuid;

comment on column public.trades.mt5_promotion_id is
  'T4B incarnation marker: the mt5_capture_promotions.id that created THIS row. NULL for every '
  'ordinary Journal trade. Immutable once set; unforgeable (a matching ledger row must already '
  'exist). Ordinary edits preserve it because toTradeRow never emits this column.';

-- One Journal row per promotion. Partial, so the overwhelming majority of rows (marker NULL) are
-- not indexed at all and ordinary Journal writes pay nothing.
create unique index mt5_trades_promotion_uk
  on public.trades (mt5_promotion_id)
  where mt5_promotion_id is not null;

create function public.mt5_trades_incarnation_guard_v1() returns trigger
language plpgsql security definer set search_path = ''
as $inc$
begin
  if tg_op = 'INSERT' then
    -- A marker may only be written by an INSERT that a real, already-recorded promotion backs.
    -- The ledger is service_role-SELECT-only, has no INSERT grant to any client role, and is
    -- append-once, so a client cannot manufacture the row this check requires. Role names are
    -- deliberately NOT consulted: the authority is the ledger itself.
    if new.mt5_promotion_id is not null
       and not exists (select 1 from public.mt5_capture_promotions p
                        where p.id = new.mt5_promotion_id
                          and p.trade_id = new.id
                          and p.user_id = new.user_id) then
      raise exception 'MT5_T4B_FORGED_INCARNATION' using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- UPDATE: the marker is immutable in every direction — it cannot be set, cleared or replaced by
  -- an update from any caller. Ordinary edits never mention the column, so this trigger does not
  -- even fire for them (it is declared UPDATE OF mt5_promotion_id).
  if new.mt5_promotion_id is distinct from old.mt5_promotion_id then
    raise exception 'MT5_T4B_IMMUTABLE_INCARNATION' using errcode = 'P0001';
  end if;
  return new;
end
$inc$;
alter function public.mt5_trades_incarnation_guard_v1() owner to postgres;
revoke all on function public.mt5_trades_incarnation_guard_v1()
  from public, anon, authenticated, service_role;

-- DELETE is deliberately NOT guarded: a promoted trade stays deletable through the normal UI, and
-- the ledger survives the deletion (that is what makes ERR_FULFILLMENT_DRIFT observable).
create trigger mt5_trades_incarnation_guard_v1
  before insert or update of mt5_promotion_id on public.trades
  for each row execute function public.mt5_trades_incarnation_guard_v1();

-- ------------------------------------------------------------------------------------------------
-- REMOVE THE MARKER FROM EVERY CLIENT ROLE'S WRITABLE SURFACE.
--
-- This is the ONLY place T4B narrows the Journal's existing writer surface, and it narrows it by
-- exactly one column. Each grantee that currently holds table-level INSERT or UPDATE on
-- public.trades keeps that privilege on every OTHER column, expressed as column-level grants, so
-- nothing the app writes today stops working. SELECT and DELETE are left completely alone.
--
-- The column list is derived from the live catalog rather than hardcoded, so this cannot silently
-- drop a column the production table has and the offline substrate does not. WITH GRANT OPTION is
-- preserved where it exists.
--
-- SCOPE OF THE CONTRACT: an owner-granted write surface. If any INSERT/UPDATE privilege on
-- public.trades was granted by someone other than the owner — which is what an EXERCISED grant
-- option looks like in the catalog — this refuses rather than half-migrating a delegation chain
-- it cannot faithfully rebuild. See the grantor preflight below.
--
-- SELECT on the marker is deliberately NOT revoked. Once the column cannot be written by a client,
-- knowing its value buys an attacker nothing, and db.loadAll reads named columns
-- (`select("raw,group_id")`) rather than `*` — but a future `select *` would break, and that is a
-- real cost for no security gain.
-- ------------------------------------------------------------------------------------------------
do $t4b_narrow$
declare
  v_cols    text;
  v_grantee text;
  v_role    text;
  v_snap    jsonb;
  v_owner   oid;
  v_me      oid;
  v_super   boolean;
  v_bad     text;
  v_merge   jsonb;
  e         jsonb;
  r         record;
begin
  select c.relowner into v_owner
    from pg_catalog.pg_class c where c.oid = 'public.trades'::regclass;

  -- ------------------------------------------------------------------------------------------
  -- GRANTOR PREFLIGHT. PostgreSQL records every ACL entry against the role that GRANTED it, and
  -- a REVOKE only removes entries the current user granted. The narrowing below revokes and
  -- re-grants as the owner, so it is only lossless while every non-owner INSERT/UPDATE entry was
  -- granted BY the owner.
  --
  -- If a grant option has actually been exercised — the app writer granted INSERT onward to some
  -- child role — then two separate things go wrong: the child's entry carries a grantor this
  -- packet cannot act as, and PostgreSQL refuses `REVOKE ... FROM <writer>` outright because
  -- dependent privileges exist. Replaying such a chain would need the packet to become each
  -- grantor in turn, which it cannot and should not do.
  --
  -- So T4B narrows its contract instead of guessing: it handles an owner-granted write surface,
  -- and refuses loudly on anything else rather than half-migrating a delegation chain.
  -- ------------------------------------------------------------------------------------------
  -- WHO MAY RUN THIS. PostgreSQL pins a GRANT's grantor to the object owner deterministically in
  -- exactly two cases: the executor IS the owner, or the executor is a superuser (select_best_
  -- grantor's fast path). For anyone else — including a role that merely INHERITS the owner —
  -- the server searches the roles the executor belongs to for one holding the needed grant
  -- options, and the documentation states the choice among candidates is unspecified. A grantor
  -- this packet did not intend is a grantor the rollback cannot revoke, so membership is not
  -- good enough: pg_has_role(..., 'USAGE') was too weak a test.
  select q.oid, q.rolsuper into v_me, v_super
    from pg_catalog.pg_roles q where q.rolname = current_user;
  if v_me is distinct from v_owner and not coalesce(v_super, false) then
    raise exception 'MT5_T4B_NARROW_PREFLIGHT: REFUSING — this packet must run as %, the owner of '
      'public.trades, or as a superuser; current_user is %. Any other executor leaves the grantor '
      'PostgreSQL records unspecified, and a grantor this packet did not choose is one the '
      'rollback cannot revoke.', v_owner::regrole::text, current_user;
  end if;

  select string_agg(d.txt, ', ' order by d.txt) into v_bad from (
    select format('%s -> %s (%s, granted by %s)',
                  x.grantor::regrole::text,
                  case when x.grantee = 0 then 'PUBLIC' else x.grantee::regrole::text end,
                  x.privilege_type, x.grantor::regrole::text) as txt
      from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
     where c.oid = 'public.trades'::regclass
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> v_owner and x.grantor <> v_owner
    union
    select format('%s -> %s (%s on column %s, granted by %s)',
                  x.grantor::regrole::text,
                  case when x.grantee = 0 then 'PUBLIC' else x.grantee::regrole::text end,
                  x.privilege_type, a.attname, x.grantor::regrole::text) as txt
      from pg_catalog.pg_attribute a, lateral aclexplode(a.attacl) x
     where a.attrelid = 'public.trades'::regclass and a.attnum > 0 and not a.attisdropped
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> v_owner and x.grantor <> v_owner
  ) d;
  if v_bad is not null then
    raise exception 'MT5_T4B_NARROW_PREFLIGHT: REFUSING — public.trades carries INSERT/UPDATE '
      'privileges granted by someone other than its owner: %. T4B revokes and re-grants as the '
      'owner, which cannot reproduce a grant chain rooted in another grantor, and PostgreSQL '
      'refuses to revoke a grant whose option has been exercised. Revoke the delegated grants (or '
      're-issue them from the owner) and re-run.', v_bad;
  end if;

  -- ------------------------------------------------------------------------------------------
  -- SNAPSHOT FIRST. The rollback cannot rediscover this afterwards, because the narrowing below
  -- removes exactly these entries from pg_class.relacl. A rollback that reads relacl at rollback
  -- time therefore finds NO non-owner INSERT/UPDATE grantee and restores nothing: today's writes
  -- keep working through the column grants T4B left behind, so a naive "can the app still
  -- insert?" probe passes, while the table-level privilege and its grant options stay gone and
  -- every column added AFTER T4B is unwritable. Revision 3's first cut shipped exactly that.
  --
  -- Column-level entries are captured too. A table-level REVOKE removes that grantee's matching
  -- column privileges along with the table one, but it says nothing about column-only grantees or
  -- about privileges no table entry covers — so the rollback still has to know which column grants
  -- predated T4B and which ones T4B itself created.
  -- ------------------------------------------------------------------------------------------
  --
  -- IDENTITY IS THE OID, NOT THE NAME. A role can be renamed (same principal, new name) or
  -- dropped and recreated under the same name (new principal, same name). Recording only the name
  -- gets both cases wrong in the dangerous direction: the rename looks like a disappearance, and
  -- the recreation looks like the original — so a rollback would hand the replacement role the
  -- privileges of the one it replaced. The name is kept alongside for human readers only.
  --
  -- The grantor is recorded as well. The preflight above already refuses anything not granted by
  -- the owner, so this is a fact the rollback re-checks rather than a chain it has to replay.
    select coalesce(jsonb_agg(j order by j->>'scope', j->>'grantee_oid', j->>'priv',
                                 coalesce(j->>'column', '')), '[]'::jsonb)
      into v_snap
      from (
        select jsonb_build_object(
                 'scope', 'table',
                 'grantee_oid', x.grantee::bigint,
                 'grantee', case when x.grantee = 0 then 'public'
                                 else (select q.rolname from pg_catalog.pg_roles q
                                        where q.oid = x.grantee) end,
                 'grantor_oid', x.grantor::bigint,
                 'grantor', (select q.rolname from pg_catalog.pg_roles q
                              where q.oid = x.grantor),
                 'priv', x.privilege_type,
                 'grantable', x.is_grantable) as j
          from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
         where c.oid = 'public.trades'::regclass
           and x.privilege_type in ('INSERT', 'UPDATE')
           and x.grantee <> c.relowner
        union
        select jsonb_build_object(
                 'scope', 'column',
                 'grantee_oid', x.grantee::bigint,
                 'grantee', case when x.grantee = 0 then 'public'
                                 else (select q.rolname from pg_catalog.pg_roles q
                                        where q.oid = x.grantee) end,
                 'grantor_oid', x.grantor::bigint,
                 'grantor', (select q.rolname from pg_catalog.pg_roles q
                              where q.oid = x.grantor),
                 'priv', x.privilege_type,
                 'grantable', x.is_grantable,
                 'column', a.attname) as j
          from pg_catalog.pg_attribute a, lateral aclexplode(a.attacl) x
         where a.attrelid = 'public.trades'::regclass
           and a.attnum > 0 and not a.attisdropped
           and x.privilege_type in ('INSERT', 'UPDATE')
           and x.grantee <> (select c.relowner from pg_catalog.pg_class c
                              where c.oid = 'public.trades'::regclass)
      ) s;
  perform set_config('t4b.trades_prior_write_acl', v_snap::text, true);

  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols
    from pg_catalog.pg_attribute a
   where a.attrelid = 'public.trades'::regclass and a.attnum > 0
     and not a.attisdropped and a.attname <> 'mt5_promotion_id';
  if v_cols is null then
    raise exception 'MT5_T4B_NARROW: public.trades has no writable columns besides the marker';
  end if;

  -- ------------------------------------------------------------------------------------------
  -- MERGE THE TABLE AND COLUMN SURFACES BEFORE TOUCHING EITHER.
  --
  -- A table-level REVOKE also removes that grantee's corresponding COLUMN privileges — PostgreSQL
  -- revokes them "on each column of the table, as well". So re-granting from the TABLE entry's
  -- is_grantable alone silently downgrades any column that carried a grant option the table entry
  -- did not: table UPDATE without grant option, plus UPDATE(raw) WITH GRANT OPTION, comes back as
  -- plain column UPDATE. That narrows more than the marker, which is the one thing this block is
  -- not allowed to do.
  --
  -- So the replay surface is computed per (grantee, privilege, column) as
  --   table.is_grantable OR bool_or(matching column grant's is_grantable)
  -- and grouped back into one GRANT per distinct grantability. Both reads happen here, before the
  -- first REVOKE, because the REVOKE is what destroys the column entries.
  -- ------------------------------------------------------------------------------------------
  select coalesce(jsonb_agg(jsonb_build_object(
           'grantee_oid', g.grantee::bigint,
           'grantee', case when g.grantee = 0 then 'public'
                           else quote_ident(g.rolname) end,
           'priv', g.privilege_type,
           'grantable', g.grantable,
           'cols', g.cols)), '[]'::jsonb)
    into v_merge
    from (
      select m.grantee, m.rolname, m.privilege_type, m.grantable,
             string_agg(quote_ident(m.attname), ', ' order by m.attnum) as cols
        from (
          select tg.grantee, tg.rolname, tg.privilege_type, a.attnum, a.attname,
                 (tg.is_grantable
                  or coalesce((select bool_or(cx.is_grantable)
                                 from pg_catalog.pg_attribute ca,
                                      lateral aclexplode(ca.attacl) cx
                                where ca.attrelid = 'public.trades'::regclass
                                  and ca.attnum = a.attnum
                                  and cx.grantee = tg.grantee
                                  and cx.privilege_type = tg.privilege_type), false)) as grantable
            from (select distinct x.grantee,
                         (select rr.rolname from pg_catalog.pg_roles rr
                           where rr.oid = x.grantee) as rolname,
                         x.privilege_type, x.is_grantable
                    from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
                   where c.oid = 'public.trades'::regclass
                     and x.privilege_type in ('INSERT', 'UPDATE')
                     and x.grantee <> c.relowner) tg
            cross join pg_catalog.pg_attribute a
           where a.attrelid = 'public.trades'::regclass and a.attnum > 0
             and not a.attisdropped and a.attname <> 'mt5_promotion_id'
        ) m
       group by m.grantee, m.rolname, m.privilege_type, m.grantable
    ) g;

  -- Now revoke, once per (grantee, privilege). quote_ident on the raw rolname: regrole::text
  -- self-quotes when it needs to, so quoting THAT would double-quote any role name that is not a
  -- bare identifier.
  for r in
    select distinct x.grantee,
                    (select rr.rolname from pg_catalog.pg_roles rr where rr.oid = x.grantee)
                      as rolname,
                    x.privilege_type
      from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
     where c.oid = 'public.trades'::regclass
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> c.relowner
  loop
    v_grantee := case when r.grantee = 0 then 'public' else quote_ident(r.rolname) end;
    execute format('revoke %s on table public.trades from %s', r.privilege_type, v_grantee);
  end loop;

  -- ...and replay the merged surface.
  for e in select x from jsonb_array_elements(v_merge) x
  loop
    execute format('grant %s (%s) on table public.trades to %s%s',
                   e->>'priv', e->>'cols', e->>'grantee',
                   case when (e->>'grantable')::boolean then ' with grant option' else '' end);
  end loop;

  -- EFFECTIVE-privilege assertion, not an ACL inspection. has_column_privilege resolves role
  -- membership, inherited grants and PUBLIC, which reading attacl alone does not. Superusers are
  -- excluded because they bypass every privilege check by definition, and so are PostgreSQL's
  -- predefined administrative roles (the reserved pg_ prefix — pg_write_all_data holds INSERT and
  -- UPDATE on every table by design). The threat model is the Journal's own client roles.
  for v_role in
    select rolname from pg_catalog.pg_roles
     where not rolsuper
       and rolname not like 'pg\_%'
       and rolname <> (select pg_get_userbyid(relowner)
                         from pg_catalog.pg_class
                        where oid = 'public.trades'::regclass)
  loop
    if has_column_privilege(v_role, 'public.trades', 'mt5_promotion_id', 'INSERT')
       or has_column_privilege(v_role, 'public.trades', 'mt5_promotion_id', 'UPDATE') then
      raise exception 'MT5_T4B_NARROW: role % can still write trades.mt5_promotion_id', v_role;
    end if;
  end loop;
end $t4b_narrow$;

-- ------------------------------------------------------------------------------------------------
-- RLS and ACLs. authenticated/anon get NOTHING. service_role gets SELECT only; the write path is
-- the SECURITY DEFINER promotion RPC and nothing else.
--
-- NOTE on public.trades: T4B narrows the Journal's existing writer surface by EXACTLY ONE COLUMN
-- (see the narrowing block above). Every other column stays writable by exactly the roles that
-- could write it before, and SELECT/DELETE and the RLS policies are untouched.
-- ------------------------------------------------------------------------------------------------
alter table public.mt5_capture_promotions enable row level security;

create policy mt5_cp_service_read_v1 on public.mt5_capture_promotions
  for select to service_role using (true);

revoke all on table public.mt5_capture_promotions from public, anon, authenticated, service_role;
grant select on table public.mt5_capture_promotions to service_role;

-- ------------------------------------------------------------------------------------------------
-- Index note: both uniqueness axes are already backed by their unique indexes, and every RPC
-- lookup is by decision_id or by the (user_id, source_account, position_id) triple. The only
-- additional index is the partial unique index on the incarnation marker. Revisit with EXPLAIN
-- evidence if a promotion-history view is ever added.
-- ------------------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------------------
-- Postflight: our own shape and nothing but our shape.
-- ------------------------------------------------------------------------------------------------
do $t4b_post$
declare
  v_bad text;
  v_n   integer;
  v_cols text[];
begin
  select array_agg(column_name::text order by column_name) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'mt5_capture_promotions';
  if v_cols is distinct from array[
      'basis_run_id','capture_event_id','created_at','decision_id','fresh_run_id','id',
      'position_id','source_account','trade_id','user_id'] then
    raise exception 'MT5_T4B_POSTFLIGHT: promotion table columns are not the frozen 10: %', v_cols;
  end if;

  if not exists (select 1 from pg_catalog.pg_class
                  where oid = 'public.mt5_capture_promotions'::regclass and relrowsecurity) then
    raise exception 'MT5_T4B_POSTFLIGHT: row level security is not enabled';
  end if;

  select string_agg(grantee || ':' || privilege_type, ', ') into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'mt5_capture_promotions'
     and (grantee in ('anon', 'authenticated', 'PUBLIC')
          or (grantee = 'service_role' and privilege_type <> 'SELECT'));
  if v_bad is not null then
    raise exception 'MT5_T4B_POSTFLIGHT: unexpected table grant(s) on the promotion table: %', v_bad;
  end if;

  select count(*) into v_n from pg_catalog.pg_trigger
   where tgrelid = 'public.mt5_capture_promotions'::regclass and not tgisinternal;
  if v_n <> 1 then
    raise exception 'MT5_T4B_POSTFLIGHT: expected exactly one immutability trigger, found %', v_n;
  end if;

  -- Both uniqueness axes must be real constraints over the EXACT columns promised, not merely
  -- same-named constraints. conkey is resolved to column names so a reordered or re-scoped
  -- constraint fails here rather than silently weakening exactly-once.
  if (select pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint c
       where c.conrelid = 'public.mt5_capture_promotions'::regclass
         and c.conname = 'mt5_cp_decision_uk')
     is distinct from 'UNIQUE (decision_id)' then
    raise exception 'MT5_T4B_POSTFLIGHT: mt5_cp_decision_uk is not UNIQUE (decision_id)';
  end if;
  if (select pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint c
       where c.conrelid = 'public.mt5_capture_promotions'::regclass
         and c.conname = 'mt5_cp_position_uk')
     is distinct from 'UNIQUE (user_id, source_account, position_id)' then
    raise exception 'MT5_T4B_POSTFLIGHT: mt5_cp_position_uk is not UNIQUE '
      '(user_id, source_account, position_id)';
  end if;
  if (select pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint c
       where c.conrelid = 'public.mt5_capture_promotions'::regclass
         and c.conname = 'mt5_cp_trade_uk')
     is distinct from 'UNIQUE (trade_id)' then
    raise exception 'MT5_T4B_POSTFLIGHT: mt5_cp_trade_uk is not UNIQUE (trade_id)';
  end if;

  -- and there must be NO foreign key to trades (see header).
  if exists (select 1 from pg_catalog.pg_constraint
              where conrelid = 'public.mt5_capture_promotions'::regclass
                and contype = 'f' and confrelid = 'public.trades'::regclass) then
    raise exception 'MT5_T4B_POSTFLIGHT: a foreign key to public.trades exists — this would either '
      'block ordinary trade deletion or cascade away provenance';
  end if;

  -- The incarnation marker: exact type, nullable, no default, indexed exactly once, guarded.
  if (select format_type(a.atttypid, a.atttypmod) from pg_catalog.pg_attribute a
       where a.attrelid = 'public.trades'::regclass and a.attname = 'mt5_promotion_id'
         and not a.attisdropped) is distinct from 'uuid' then
    raise exception 'MT5_T4B_POSTFLIGHT: trades.mt5_promotion_id is not uuid';
  end if;
  if (select a.attnotnull from pg_catalog.pg_attribute a
       where a.attrelid = 'public.trades'::regclass and a.attname = 'mt5_promotion_id') then
    raise exception 'MT5_T4B_POSTFLIGHT: trades.mt5_promotion_id must be nullable — every ordinary '
      'Journal trade has no marker';
  end if;
  if (select pg_get_indexdef(i.indexrelid) from pg_catalog.pg_index i
       where i.indrelid = 'public.trades'::regclass
         and i.indexrelid = 'public.mt5_trades_promotion_uk'::regclass)
     is distinct from 'CREATE UNIQUE INDEX mt5_trades_promotion_uk ON public.trades '
                      'USING btree (mt5_promotion_id) WHERE (mt5_promotion_id IS NOT NULL)' then
    raise exception 'MT5_T4B_POSTFLIGHT: mt5_trades_promotion_uk is not the promised partial '
      'unique index';
  end if;
  if not exists (select 1 from pg_catalog.pg_trigger
                  where tgrelid = 'public.trades'::regclass
                    and tgname = 'mt5_trades_incarnation_guard_v1' and not tgisinternal) then
    raise exception 'MT5_T4B_POSTFLIGHT: the trades incarnation guard trigger is missing';
  end if;

  -- OWNER ATTRIBUTION, asserted on the live catalog rather than inferred from who ran this. If
  -- any INSERT/UPDATE grant this packet just wrote landed under a grantor other than the owner,
  -- the rollback could not revoke it — so fail now, inside the transaction, while it costs
  -- nothing.
  if exists (
    select 1 from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
     where c.oid = 'public.trades'::regclass
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> c.relowner and x.grantor <> c.relowner
    union all
    select 1 from pg_catalog.pg_attribute a, lateral aclexplode(a.attacl) x
     where a.attrelid = 'public.trades'::regclass and a.attnum > 0 and not a.attisdropped
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> (select c.relowner from pg_catalog.pg_class c
                          where c.oid = 'public.trades'::regclass)
       and x.grantor <> (select c.relowner from pg_catalog.pg_class c
                          where c.oid = 'public.trades'::regclass)) then
    raise exception 'MT5_T4B_POSTFLIGHT: an INSERT/UPDATE grant on public.trades is attributed to '
      'a grantor other than the table owner — the rollback could not revoke it';
  end if;
end $t4b_post$;

insert into public.mt5_schema_migrations(
  version, description, checksum, source_artifact_sha256, status, objects, applied_at, applied_by
) values (
  'mt5_t4b_promotion_schema_v1',
  'T4B immutable Journal promotion ledger with dual exactly-once identity (decision + MT5 '
  'position), reserved trade-id namespace and trades incarnation marker',
  -- CANONICAL PACKET DIGEST — sha256 of THIS FILE with its own digest field normalised to 64
  -- zeros and line endings normalised to LF. Generated and verified by T4B_packet_identity.py;
  -- never hand-edited. Changing one byte of executable SQL changes this value even when the
  -- version and packet revision stay constant.
  '307642904e3ba280c8cd555ee09e11ddfd07e3d3f48b1aba5be8181d5aefda2e',  -- T4B_CANONICAL_DIGEST_V1
  -- SOURCE ARTIFACT — sha256 (LF-normalised, uppercase per the ledger's own check constraint) of
  -- artifacts/mt5_reconciliation/T4B_1_promotion_contract_v1.md, the frozen T4B contract this
  -- packet implements. Revision 1 carried the unrelated T3 kind-fixture digest here, which bound
  -- the ledger row to an artifact T4B does not implement.
  'FF3B6F6789A1E5127E11B8C1650BCD745FF375C9A6CB69823D459EAD03084E2B',  -- T4B_CONTRACT_DIGEST_V1
  'applied',
  jsonb_build_object(
    'packet_revision', '6',
    'tables', jsonb_build_array('public.mt5_capture_promotions'),
    'columns', jsonb_build_array('public.trades.mt5_promotion_id'),
    'indexes', jsonb_build_array('public.mt5_trades_promotion_uk'),
    'triggers', jsonb_build_array(
      'mt5_capture_promotion_no_mutate_v1 on public.mt5_capture_promotions',
      'mt5_trades_incarnation_guard_v1 on public.trades'
    ),
    'functions', jsonb_build_array(
      'public.mt5_capture_promotion_guard_v1()',
      'public.mt5_trades_incarnation_guard_v1()'
    ),
    -- EXACT DEPLOYED BODIES. Metadata (signature, security, volatility, search_path) says nothing
    -- about what a function DOES: a guard could be replaced by `begin return new; end` and keep
    -- every one of those properties. The digest of pg_get_functiondef() is recorded here at apply
    -- time and re-derived by the read-only verifier, so any post-apply body change is detected
    -- while the ledger row itself is untouched. (A PostgreSQL major-version upgrade can re-render
    -- pg_get_functiondef; re-verify and re-record after one.)
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
         and p.proname in ('mt5_capture_promotion_guard_v1',
                           'mt5_trades_incarnation_guard_v1')),
    -- The pre-T4B non-owner INSERT/UPDATE privilege shape of public.trades, captured before the
    -- narrowing block touched it. This is the rollback's ONLY source of truth for restoring it.
    'trades_prior_write_acl', current_setting('t4b.trades_prior_write_acl')::jsonb,
    'trade_id_namespace', 'mt5p_<32 lowercase uuid hex>'
  ),
  now(),
  current_user
);

-- The ledger row must actually exist and be ours. The four sibling rollback packets DELETE their
-- ledger rows rather than flagging them, so a reapply after rollback inserts cleanly; this
-- assertion is what makes that a fact rather than an assumption.
do $t4b_ledger_post$
begin
  if not exists (select 1 from public.mt5_schema_migrations
                  where version = 'mt5_t4b_promotion_schema_v1' and status = 'applied'
                    and (objects->>'packet_revision') = '6'
                    and objects ? 'function_digests'
                    and objects ? 'trades_prior_write_acl') then
    raise exception 'MT5_T4B_POSTFLIGHT: the schema ledger row was not recorded as applied';
  end if;

  -- The recorded inventory must be EXACTLY this packet's two functions. A count would let a
  -- required key be swapped for an unrelated deployed function carrying its own correct digest,
  -- leaving the removed T4B body unverified while the total still looked right.
  if (select array_agg(k order by k)
        from public.mt5_schema_migrations m,
             lateral jsonb_object_keys(m.objects->'function_digests') k
       where m.version = 'mt5_t4b_promotion_schema_v1')
     is distinct from array['public.mt5_capture_promotion_guard_v1()',
                            'public.mt5_trades_incarnation_guard_v1()'] then
    raise exception 'MT5_T4B_POSTFLIGHT: the schema ledger row records the wrong function '
      'inventory';
  end if;
end $t4b_ledger_post$;

commit;
