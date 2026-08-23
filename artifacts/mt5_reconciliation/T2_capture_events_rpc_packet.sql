-- ================================================================================================
-- MT5 T2 — CAPTURE EVENT PERSISTENCE, RPC PACKET
--
-- Status: EXECUTABLE DRAFT — NOT RUN AGAINST PRODUCTION.
-- Packet revision: 5
--   revision 1: initial draft (Codex: CHANGES_REQUESTED).
--   revision 2: the RPC validates the actual detection evidence (exact per-event-type key sets,
--               event semantics, ordinal correspondence), validates every referenced run against
--               mt5_sync_runs including the executable T1 adjacency rule, refuses forbidden
--               fields recursively, and appends with an atomic race-safe
--               INSERT .. ON CONFLICT DO NOTHING.
--   revision 3: the server no longer takes the caller's word for WHAT HAPPENED. Every detection
--               is RE-DERIVED from the immutable public.mt5_sync_run_positions membership of its
--               own before/after runs, including the NEW vs REAPPEARANCE decision, which is
--               settled against the whole healthy completed history at PERSISTENCE time. Also:
--               duplicate / contradictory detection sets are refused BEFORE the event key is
--               derived, and the complete quiet-window time invariant is enforced.
--   revision 4: the CANONICAL IDENTITY WIRE FORMAT. The identity tuple is compared and
--     hashed as TEXT, so two spellings of one UUID ("3F1A..." and "3f1a...") were two
--     identities for one observation and could mint two deterministic event keys -- the exact
--     collision the key exists to force. Every UUID-valued identity/provenance field must now
--     be the one canonical spelling and every position_id an actual JSON number, checked
--     BEFORE the set-uniqueness gates and before the key is derived. Aliases are refused, never
--     normalised: rewriting a caller's identity would change what the evidence identifies.
--
--   revision 5: source_account is opaque broker/account identity TEXT, and ->> could not tell
--     the JSON number 301102520 from the JSON string "301102520" -- both render the same text,
--     so the numeric alias passed the scope comparison and reached key derivation. Exact JSON
--     TYPES are now validated for EVERY identity-corresponding field (top level, detection,
--     detection_identity, run_reference) before any ->> comparison, any cast, the set gates and
--     the key. source_account is never parsed numerically and never normalised.
--
-- Depends on: T2_capture_events_schema_packet.sql (revision 5) applied.
--
-- WHAT THIS PACKET ADDS
--   public.mt5_capture_keys_match_v1(jsonb,text[])        internal helper, postgres-only
--   public.mt5_capture_event_key_v1(jsonb)                internal helper, postgres-only
--   public.mt5_capture_payload_fingerprint_v1(jsonb)      internal helper, postgres-only
--   public.mt5_append_capture_event_v1(uuid,text,jsonb)   connector RPC, service_role only
--
-- WHAT IT DELIBERATELY DOES NOT ADD
--   * no update / delete / dismiss / promote RPC — there is no such path, ever
--   * no read RPC for the browser (out of scope; would be separately reviewed)
--   * no new lifecycle table, and no change to any frozen S1 / S1.1 object or to T1
--
-- IDEMPOTENCY CONTRACT (race-safe)
--   new event_key + valid payload                -> insert exactly one row, o_inserted = 1
--   same event_key + identical fingerprint       -> replay success, SAME id, o_inserted = 0
--   same event_key + different fingerprint       -> hard conflict, ERR_CAPTURE_CONFLICT, no write
--   The existing row is NEVER overwritten and NEVER updated to resolve a conflict, and a raw
--   unique_violation is never surfaced as replay behaviour: the INSERT itself carries
--   ON CONFLICT (event_key) DO NOTHING, so two concurrent callers resolve deterministically.
--
-- THE DATABASE IS AUTHORITATIVE AT PERSISTENCE TIME
--   mt5_sync_runs supplies run metadata and adjacency. mt5_sync_run_positions supplies the
--   POSITION FACTS, and the classification is re-derived from them:
--
--     absent -> present   NEW_POSITION, or REAPPEARANCE if that position_id appears in ANY
--                         earlier healthy completed run for this user/account (run_seq strictly
--                         below before_run_seq). A caller that ran T1 over a truncated history
--                         may honestly believe a position is new; the stored history knows
--                         better, and the stored history wins.
--     present -> absent   POSITION_DISAPPEARED (observed membership disappearance ONLY)
--     present -> present  POSITION_IDENTITY_CONFLICT when symbol_raw/side differ, else
--                         POSITION_INCREASE / POSITION_DECREASE by exact numeric volume,
--                         and NO EVENT AT ALL when the volume is unchanged
--     absent  -> absent   no event exists
--
--   The caller's own facts must then EQUAL the persisted row(s) exactly. A detection whose
--   classification or facts disagree with the snapshots is refused, not stored with a caveat.
--
-- ERROR CODES
--   ERR_BAD_INPUT                 null/blank caller scope, or a non-object candidate
--   ERR_CAPTURE_PAYLOAD_KEYS      top-level key set is not exactly the canonical payload
--   ERR_CAPTURE_DOMAIN            domain tag mismatch
--   ERR_CAPTURE_FORBIDDEN_FIELD   a decision-state / account-value field anywhere in the payload
--   ERR_CAPTURE_SCOPE             payload scope disagrees with the caller's explicit scope
--   ERR_CAPTURE_PAYLOAD_INVALID   a typed top-level fact is missing, untyped or out of range
--   ERR_CAPTURE_TIME_ORDER        the quiet-window time invariant is violated (see below)
--   ERR_CAPTURE_WINDOW_MISMATCH   deadline is not last_detection_at + quiet_window_seconds
--   ERR_CAPTURE_PROVENANCE        array arity, ordinal correspondence, or run_reference shape
--   ERR_CAPTURE_IDENTITY          a detection identity is not the frozen in-scope 6-tuple,
--                                 or is not in the canonical identity wire format
--   ERR_CAPTURE_DETECTION         a detection's key set, typing, event semantics, membership
--                                 truth, or the CANDIDATE SET itself (duplicate identity, or two
--                                 classifications of one observation key) is invalid
--   ERR_CAPTURE_BASIS_MISMATCH    basis_run_id is not the after_run_id of the FINAL detection
--   ERR_BASIS_RUN_NOT_FOUND / _SCOPE / _NOT_COMPLETE / _NOT_HEALTHY   basis run is unusable
--   ERR_RUN_NOT_FOUND / ERR_RUN_SCOPE / ERR_RUN_NOT_COMPLETE / ERR_RUN_NOT_HEALTHY
--                                 a referenced before/after run is unusable
--   ERR_RUN_SEQ_MISMATCH          claimed run_seq differs from the STORED run_seq
--   ERR_RUN_NOT_ADJACENT          another completed run sits between the pair
--   ERR_CAPTURE_CONFLICT          same event_key, different payload fingerprint
--   ERR_CAPTURE_RACE              the conflicting inserter kept rolling back (not reachable in
--                                 practice; a bounded retry rather than an unbounded loop)
--
-- QUIET-WINDOW TIME INVARIANT
--   Every instant is finite (+/-infinity is refused explicitly, not merely cast successfully).
--   Detections are chronological; first_detection_at is the FIRST detection's instant and
--   last_detection_at is the LAST one's; each joined detection is within one window of its
--   predecessor; the deadline is last + window; and therefore no detection can lie beyond its
--   own candidate's deadline. Equal instants order by the existing T2 canonical rule
--   (after_run_seq, then the frozen identity tuple) — no new semantic rule is invented here.
-- ================================================================================================

begin;

do $t2_rpc_pre$
begin
  if to_regclass('public.mt5_capture_events') is null then
    raise exception 'MT5_T2_RPC_PREFLIGHT: apply T2_capture_events_schema_packet.sql first';
  end if;
  if to_regclass('public.mt5_sync_run_positions') is null then
    raise exception 'MT5_T2_RPC_PREFLIGHT: public.mt5_sync_run_positions is missing — this RPC re-derives every detection from it';
  end if;
  if not exists (select 1 from public.mt5_schema_migrations
                  where version = 'mt5_t2_capture_events_schema_v1' and status = 'applied'
                    and (objects ->> 'packet_revision') = '5') then
    raise exception 'MT5_T2_RPC_PREFLIGHT: the T2 schema packet revision 5 is not applied';
  end if;
  if exists (select 1 from pg_catalog.pg_proc p
               join pg_catalog.pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('mt5_capture_keys_match_v1',
                                  'mt5_capture_event_key_v1',
                                  'mt5_capture_payload_fingerprint_v1',
                                  'mt5_append_capture_event_v1')) then
    raise exception 'MT5_T2_RPC_PREFLIGHT: a T2 RPC name already exists';
  end if;
  if exists (select 1 from public.mt5_schema_migrations
              where version = 'mt5_t2_capture_events_rpc_v1') then
    raise exception 'MT5_T2_RPC_PREFLIGHT: ledger already carries mt5_t2_capture_events_rpc_v1';
  end if;
end
$t2_rpc_pre$;

-- ------------------------------------------------------------------------------------------------
-- Exact-key-set helper. Both sides are sorted with the SAME explicit collation, so the answer is
-- a pure set comparison and cannot change with the database's default collation.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_capture_keys_match_v1(p_obj jsonb, p_expect text[]) returns boolean
language sql immutable security definer set search_path = ''
as $keys$
  select pg_catalog.jsonb_typeof(p_obj) = 'object'
     and (select pg_catalog.array_agg(k order by k collate "C")
            from pg_catalog.jsonb_object_keys(p_obj) as k)
         is not distinct from
         (select pg_catalog.array_agg(e order by e collate "C")
            from pg_catalog.unnest(p_expect) as e)
$keys$;

-- ------------------------------------------------------------------------------------------------
-- Deterministic logical event key.
--
-- Derived from the domain tag plus the CANONICAL ORDERED contributing detection identities, and
-- nothing else. Sorting makes the key a pure function of the SET of detections, so an ordering
-- quirk upstream can never mint a second key for the same evidence. Each identity already carries
-- user_id / source_account / position_id, so scope is implied rather than restated.
--
-- The key deliberately excludes timestamps and versions: those belong to the FINGERPRINT. A
-- replay of the same evidence must collide on the key so the conflict check can run; if the key
-- absorbed every field, a changed payload would simply become a second row instead of a refusal.
--
-- Duplicate and contradictory detection SETS are refused before this is ever called, so a
-- repeated identity cannot quietly collapse into a key that looks like a smaller, cleaner set.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_capture_event_key_v1(p_candidate jsonb) returns text
language sql stable security definer set search_path = ''
as $key$
  select public.mt5_sha256_text_v1(
    pg_catalog.jsonb_build_array(
      pg_catalog.to_jsonb('mt5.t2.capture/1'::text),
      coalesce(
        (select pg_catalog.jsonb_agg(e.ident order by e.ident::text)
           from pg_catalog.jsonb_array_elements(p_candidate -> 'detection_identities')
                as e(ident)),
        '[]'::jsonb)
    )::text
  )
$key$;

-- ------------------------------------------------------------------------------------------------
-- Fingerprint over the FULL persisted candidate payload. jsonb is already canonical (sorted keys,
-- deduplicated), so its text rendering is deterministic for a given value.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_capture_payload_fingerprint_v1(p_candidate jsonb) returns text
language sql stable security definer set search_path = ''
as $fp$
  select public.mt5_sha256_text_v1(
    pg_catalog.jsonb_build_array(
      pg_catalog.to_jsonb('mt5.t2.capture.payload/1'::text),
      p_candidate
    )::text
  )
$fp$;

-- ------------------------------------------------------------------------------------------------
-- Connector RPC: append one capture event for a timer-closed quiet-window candidate.
--
-- SERVER-DERIVED and NOT forgeable by the caller: id, created_at, event_key, payload_fingerprint.
-- A caller able to supply the key or the fingerprint could make a conflicting replay look
-- identical, which is precisely the check that must not be forgeable.
--
-- The caller supplies explicit user/account scope (the trusted-writer model the rest of the MT5
-- pipeline uses); the RPC independently re-validates that the payload agrees with that scope.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_append_capture_event_v1(
  p_user uuid, p_account text, p_candidate jsonb
) returns table(o_ok boolean, o_inserted integer, o_event_id uuid, o_event_key text,
                o_error_code text)
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_expect_keys  constant text[] := array[
    'aggregator_version','basis_run_id','detection_identities','detections','detector_version',
    'domain','event_types','first_detection_at','last_detection_at','position_id',
    'quiet_deadline','quiet_window_seconds','run_references','source_account','user_id'];
  -- the fields EVERY t1_detector.py detection carries, plus T2's injected instant
  v_det_base     constant text[] := array[
    'event_type','position_id','before_run_id','after_run_id','before_run_seq','after_run_seq',
    'user_id','source_account','detected_at'];
  v_ref_keys     constant text[] := array[
    'before_run_id','after_run_id','before_run_seq','after_run_seq'];
  v_types        constant text[] := array[
    'NEW_POSITION','REAPPEARANCE','POSITION_INCREASE','POSITION_DECREASE',
    'POSITION_DISAPPEARED','POSITION_IDENTITY_CONFLICT'];
  v_sides        constant text[] := array['buy','sell'];
  -- THE canonical textual spelling of a uuid, and the only one accepted on the wire. Postgres
  -- renders uuid values in exactly this form: 32 lowercase hex digits in 8-4-4-4-12 groups. It
  -- also ACCEPTS braces, a urn:uuid: prefix, missing hyphens and uppercase hex, so a successful
  -- ::uuid cast proves the value is a uuid, never that it is the canonical spelling of one.
  v_uuid_re      constant text :=
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  -- Forbidden ANYWHERE in the payload, not just at the top level. Mirrors the two recursive
  -- CHECK constraints on the table; the verification packet proves both layers agree.
  v_forbidden    constant text := '$.** ? (exists(@."skipped") || exists(@."promoted") || exists(@."ignored") || exists(@."dismissed") || exists(@."confirmed") || exists(@."decision") || exists(@."decision_state") || exists(@."journal_trade_id") || exists(@."materialized_trade_id") || exists(@."equity") || exists(@."balance") || exists(@."account_equity") || exists(@."account_balance") || exists(@."currency") || exists(@."equity_quality") || exists(@."balance_quality") || exists(@."margin") || exists(@."profit_total"))';

  v_want         text[];
  v_position     bigint;
  v_basis        uuid;
  v_first        timestamptz;
  v_last         timestamptz;
  v_deadline     timestamptz;
  v_window       numeric;
  v_interval     interval;
  v_n_ident      integer;
  v_i            integer;
  v_det          jsonb;
  v_ident        jsonb;
  v_ref          jsonb;
  v_etype        text;
  v_before_txt   text;
  v_after_txt    text;
  v_before_uuid  uuid;
  v_after_uuid   uuid;
  v_bseq         numeric;
  v_aseq         numeric;
  v_bvol         numeric;
  v_avol         numeric;
  v_at           timestamptz;
  v_prev_at      timestamptz;
  v_prev_aseq    numeric;
  v_tie          text;
  v_prev_tie     text;
  v_run_before   public.mt5_sync_runs%rowtype;
  v_run_after    public.mt5_sync_runs%rowtype;
  v_basis_run    public.mt5_sync_runs%rowtype;
  v_pos_before   public.mt5_sync_run_positions%rowtype;
  v_pos_after    public.mt5_sync_run_positions%rowtype;
  v_in_before    boolean;
  v_in_after     boolean;
  v_derived      text;
  v_seen_earlier boolean;
  v_key          text;
  v_fp           text;
  v_new_id       uuid;
  v_existing_id  uuid;
  v_existing_fp  text;
  v_attempt      integer;
  v_bad          text;
begin
  if p_user is null or p_account is null or btrim(p_account) = '' then
    return query select false, 0, null::uuid, null::text, 'ERR_BAD_INPUT'; return;
  end if;
  if p_candidate is null or pg_catalog.jsonb_typeof(p_candidate) <> 'object' then
    return query select false, 0, null::uuid, null::text, 'ERR_BAD_INPUT'; return;
  end if;

  -- ---- exact key set -----------------------------------------------------------------------
  if not public.mt5_capture_keys_match_v1(p_candidate, v_expect_keys) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_KEYS'; return;
  end if;

  -- ---- domain ------------------------------------------------------------------------------
  if p_candidate ->> 'domain' is distinct from 'mt5.t2.capture/1' then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DOMAIN'; return;
  end if;

  -- ---- forbidden fields, RECURSIVELY -------------------------------------------------------
  -- Machine evidence may not carry human/workflow state or account money at ANY depth. A nested
  -- object or array must not be able to smuggle what the top level forbids.
  if pg_catalog.jsonb_path_exists(p_candidate, v_forbidden::jsonpath) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_FORBIDDEN_FIELD'; return;
  end if;

  -- ---- exact JSON TYPES of the top-level facts --------------------------------------------
  -- FIRST, before any ->> comparison or cast. ->> renders the JSON number 301102520 and the
  -- JSON string "301102520" identically, so a text comparison cannot tell an opaque account
  -- identifier from a number that happens to look like one; the type is the only thing that
  -- can. Same for '101' and 101. A cast that succeeds says nothing about which one arrived.
  --
  -- source_account is opaque broker/account identity TEXT: a JSON string, nonblank, preserved
  -- exactly. It is never parsed numerically and never normalised, so "0301102520" stays a
  -- distinct account from "301102520" instead of collapsing into the same integer.
  if pg_catalog.jsonb_typeof(p_candidate -> 'user_id') <> 'string'
     or pg_catalog.jsonb_typeof(p_candidate -> 'source_account') <> 'string'
     or btrim(coalesce(p_candidate ->> 'source_account', '')) = ''
     or pg_catalog.jsonb_typeof(p_candidate -> 'position_id') <> 'number'
     or pg_catalog.jsonb_typeof(p_candidate -> 'quiet_window_seconds') <> 'number'
     or pg_catalog.jsonb_typeof(p_candidate -> 'basis_run_id') <> 'string'
     or pg_catalog.jsonb_typeof(p_candidate -> 'first_detection_at') <> 'string'
     or pg_catalog.jsonb_typeof(p_candidate -> 'last_detection_at') <> 'string'
     or pg_catalog.jsonb_typeof(p_candidate -> 'quiet_deadline') <> 'string'
     or pg_catalog.jsonb_typeof(p_candidate -> 'detector_version') <> 'string'
     or pg_catalog.jsonb_typeof(p_candidate -> 'aggregator_version') <> 'string' then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_INVALID'; return;
  end if;

  -- ---- canonical UUID TEXT, top level ------------------------------------------------------
  -- basis_run_id is compared as text against the final identity's after_run_id, and that text
  -- is part of what the deterministic key is derived from. An equivalent spelling is refused
  -- here rather than silently absorbed downstream by the ::uuid cast.
  if (p_candidate ->> 'basis_run_id') !~ v_uuid_re then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_INVALID'; return;
  end if;

  -- position_id must be a WHOLE number before it is narrowed to bigint: 101.0 is a number and
  -- casts cleanly, but renders '101.0', which is a different identity text from '101'.
  if (p_candidate ->> 'position_id')::numeric
       is distinct from trunc((p_candidate ->> 'position_id')::numeric) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_INVALID'; return;
  end if;

  -- ---- scope consistency: the payload must agree with the caller's explicit scope ----------
  -- Both operands are now known to be JSON strings, so this is a comparison of the values that
  -- actually arrived rather than of how they happen to render.
  if (p_candidate ->> 'user_id') is distinct from p_user::text
     or (p_candidate ->> 'source_account') is distinct from p_account then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_SCOPE'; return;
  end if;

  -- ---- typed facts -------------------------------------------------------------------------
  begin
    v_position := (p_candidate ->> 'position_id')::bigint;
    v_basis    := (p_candidate ->> 'basis_run_id')::uuid;
    v_first    := (p_candidate ->> 'first_detection_at')::timestamptz;
    v_last     := (p_candidate ->> 'last_detection_at')::timestamptz;
    v_deadline := (p_candidate ->> 'quiet_deadline')::timestamptz;
    v_window   := (p_candidate ->> 'quiet_window_seconds')::numeric;
  exception when others then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_INVALID'; return;
  end;
  if v_position is null or v_position <= 0
     or v_basis is null or v_first is null or v_last is null or v_deadline is null
     or v_window is null or v_window <> v_window or v_window <= 0 or v_window >= 86400 then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_INVALID'; return;
  end if;
  if btrim(coalesce(p_candidate ->> 'detector_version', '')) = ''
     or btrim(coalesce(p_candidate ->> 'aggregator_version', '')) = '' then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_INVALID'; return;
  end if;

  -- 'infinity' and '-infinity' are legal timestamptz values, so a successful cast proves
  -- nothing. An infinite window boundary is not an observation.
  if not (isfinite(v_first) and isfinite(v_last) and isfinite(v_deadline)) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
  end if;

  -- ---- timestamp order, and the TIMER really closed the window -----------------------------
  if not (v_first <= v_last and v_last < v_deadline) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
  end if;
  v_interval := make_interval(secs => v_window::double precision);
  if v_deadline is distinct from v_last + v_interval then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_WINDOW_MISMATCH'; return;
  end if;

  -- ---- provenance arrays -------------------------------------------------------------------
  if pg_catalog.jsonb_typeof(p_candidate -> 'detection_identities') <> 'array'
     or pg_catalog.jsonb_typeof(p_candidate -> 'event_types') <> 'array'
     or pg_catalog.jsonb_typeof(p_candidate -> 'run_references') <> 'array'
     or pg_catalog.jsonb_typeof(p_candidate -> 'detections') <> 'array' then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PAYLOAD_INVALID'; return;
  end if;
  v_n_ident := pg_catalog.jsonb_array_length(p_candidate -> 'detection_identities');
  if v_n_ident < 1
     or pg_catalog.jsonb_array_length(p_candidate -> 'event_types') <> v_n_ident
     or pg_catalog.jsonb_array_length(p_candidate -> 'run_references') <> v_n_ident
     or pg_catalog.jsonb_array_length(p_candidate -> 'detections') <> v_n_ident then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PROVENANCE'; return;
  end if;

  -- ---- THE CANONICAL IDENTITY WIRE FORMAT -------------------------------------------------
  -- Three passes, in this order, because each one makes the next one safe to perform:
  --
  --   (1) exact JSON types    - nothing is read through ->> until its type is known, so no cast
  --                             can throw, and no cast can quietly rescue a wrong-typed value;
  --   (2) canonical UUID text - the one spelling Postgres itself renders; and
  --   (3) typed identity values - scope, vocabulary, and the numeric facts.
  --
  -- All three run BEFORE the set-uniqueness gates and before the key is derived. Otherwise the
  -- same observation could arrive under two spellings and mint two different deterministic
  -- event keys, which is exactly the collision the key exists to force.

  -- (1) exact JSON types of every identity element
  select string_agg(x.ident::text, ' | ') into v_bad
    from pg_catalog.jsonb_array_elements(p_candidate -> 'detection_identities') as x(ident)
   where pg_catalog.jsonb_typeof(x.ident) <> 'array'
      or pg_catalog.jsonb_array_length(x.ident) <> 6
      or pg_catalog.jsonb_typeof(x.ident -> 0) <> 'string'
      or pg_catalog.jsonb_typeof(x.ident -> 1) <> 'string'
      or pg_catalog.jsonb_typeof(x.ident -> 2) <> 'string'
      or pg_catalog.jsonb_typeof(x.ident -> 3) <> 'number'
      or pg_catalog.jsonb_typeof(x.ident -> 4) <> 'string'
      or pg_catalog.jsonb_typeof(x.ident -> 5) <> 'string';
  if v_bad is not null then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_IDENTITY'; return;
  end if;

  -- (2) canonical UUID text for both run references. Every element is known to be a string,
  --     so this is a pure spelling test and nothing here can raise.
  select string_agg(x.ident::text, ' | ') into v_bad
    from pg_catalog.jsonb_array_elements(p_candidate -> 'detection_identities') as x(ident)
   where (x.ident ->> 4) !~ v_uuid_re
      or (x.ident ->> 5) !~ v_uuid_re;
  if v_bad is not null then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_IDENTITY'; return;
  end if;

  -- (3) every identity is the frozen 6-tuple and is inside the candidate's own scope. Each
  --     element is known to be the right JSON type, so these comparisons and the numeric cast
  --     are now well defined.
  select string_agg(x.ident::text, ' | ') into v_bad
    from pg_catalog.jsonb_array_elements(p_candidate -> 'detection_identities') as x(ident)
   where (x.ident ->> 0) is distinct from p_user::text
      or (x.ident ->> 1) is distinct from p_account
      or (x.ident ->> 3)::numeric is distinct from trunc((x.ident ->> 3)::numeric)
      or (x.ident ->> 3) is distinct from v_position::text
      or not ((x.ident ->> 2) = any (v_types))
      or (x.ident ->> 4) = (x.ident ->> 5);
  if v_bad is not null then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_IDENTITY'; return;
  end if;

  -- ---- exact JSON TYPES of every DETECTION and RUN_REFERENCE identity field ---------------
  -- Hoisted out of the per-detection loop, which runs AFTER the key is derived. Every field
  -- that corresponds to an identity is typed here, so no ->> comparison downstream can be
  -- satisfied by a value that merely renders the right way.
  select string_agg(x.det::text, ' | ') into v_bad
    from pg_catalog.jsonb_array_elements(p_candidate -> 'detections') as x(det)
   where pg_catalog.jsonb_typeof(x.det) <> 'object'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'user_id'), '') <> 'string'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'source_account'), '') <> 'string'
      or btrim(coalesce(x.det ->> 'source_account', '')) = ''
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'event_type'), '') <> 'string'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'position_id'), '') <> 'number'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'before_run_id'), '') <> 'string'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'after_run_id'), '') <> 'string'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'before_run_seq'), '') <> 'number'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'after_run_seq'), '') <> 'number'
      or coalesce(pg_catalog.jsonb_typeof(x.det -> 'detected_at'), '') <> 'string'
      or (x.det ->> 'before_run_id') !~ v_uuid_re
      or (x.det ->> 'after_run_id') !~ v_uuid_re;
  if v_bad is not null then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
  end if;

  select string_agg(x.ref::text, ' | ') into v_bad
    from pg_catalog.jsonb_array_elements(p_candidate -> 'run_references') as x(ref)
   where pg_catalog.jsonb_typeof(x.ref) <> 'object'
      or coalesce(pg_catalog.jsonb_typeof(x.ref -> 'before_run_id'), '') <> 'string'
      or coalesce(pg_catalog.jsonb_typeof(x.ref -> 'after_run_id'), '') <> 'string'
      or coalesce(pg_catalog.jsonb_typeof(x.ref -> 'before_run_seq'), '') <> 'number'
      or coalesce(pg_catalog.jsonb_typeof(x.ref -> 'after_run_seq'), '') <> 'number'
      or (x.ref ->> 'before_run_id') !~ v_uuid_re
      or (x.ref ->> 'after_run_id') !~ v_uuid_re;
  if v_bad is not null then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PROVENANCE'; return;
  end if;

  -- ---- THE CANDIDATE SET ITSELF, before any key is derived --------------------------------
  -- (A) the frozen identity must not repeat. Duplicate evidence is not stronger evidence, and
  --     silently de-duplicating it here would let one candidate manufacture the deterministic
  --     event_key of a different, smaller set.
  if (select count(*) from pg_catalog.jsonb_array_elements(
                             p_candidate -> 'detection_identities') as e(ident))
     is distinct from
     (select count(distinct e.ident) from pg_catalog.jsonb_array_elements(
                             p_candidate -> 'detection_identities') as e(ident)) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
  end if;
  -- (B) one observation key = one classification. `ident - 2` drops event_type, leaving the
  --     secondary key (user, account, position_id, before_run_id, after_run_id). Two rows under
  --     it means the same run pair was classified twice — impossible evidence, not a merge.
  if (select count(*) from pg_catalog.jsonb_array_elements(
                             p_candidate -> 'detection_identities') as e(ident))
     is distinct from
     (select count(distinct (e.ident - 2)) from pg_catalog.jsonb_array_elements(
                             p_candidate -> 'detection_identities') as e(ident)) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
  end if;

  -- ---- THE DETERMINISTIC KEY ---------------------------------------------------------------
  -- Derived here, with nothing between it and the gates above: the identities are known to be
  -- in the canonical wire format, and the SET is known to carry no duplicate and no
  -- contradiction. Nothing that follows can influence it, so an alias can never mint a second
  -- key for one observation and a replay of the same evidence always collides on the same one.
  v_key := public.mt5_capture_event_key_v1(p_candidate);

  -- basis_run_id is the after_run_id of the FINAL contributing detection (the frozen rule)
  if v_basis::text is distinct from
       ((p_candidate -> 'detection_identities' -> (v_n_ident - 1)) ->> 5) then
    return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_BASIS_MISMATCH'; return;
  end if;

  -- ---- the basis run must be a COMPLETED, HEALTHY run in the SAME scope --------------------
  select * into v_basis_run from public.mt5_sync_runs r where r.id = v_basis;
  if not found then
    return query select false, 0, null::uuid, null::text, 'ERR_BASIS_RUN_NOT_FOUND'; return;
  end if;
  if v_basis_run.user_id is distinct from p_user
     or v_basis_run.source_account is distinct from p_account then
    return query select false, 0, null::uuid, null::text, 'ERR_BASIS_RUN_SCOPE'; return;
  end if;
  if v_basis_run.snapshot_status is distinct from 'complete' then
    return query select false, 0, null::uuid, null::text, 'ERR_BASIS_RUN_NOT_COMPLETE'; return;
  end if;
  if v_basis_run.snapshot_health is distinct from 'healthy' then
    return query select false, 0, null::uuid, null::text, 'ERR_BASIS_RUN_NOT_HEALTHY'; return;
  end if;

  -- ---- EVERY detection: real evidence, ordinally aligned, on real adjacent runs, and
  --      RE-DERIVED from the immutable snapshot membership ----------------------------------
  for v_i in 0 .. v_n_ident - 1 loop
    v_det   := p_candidate -> 'detections' -> v_i;
    v_ident := p_candidate -> 'detection_identities' -> v_i;
    v_ref   := p_candidate -> 'run_references' -> v_i;

    if pg_catalog.jsonb_typeof(v_det) <> 'object' then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end if;

    v_etype := v_det ->> 'event_type';
    if v_etype is null or not (v_etype = any (v_types)) then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end if;

    -- exact key set FOR THIS EVENT TYPE: a detection carrying a field T1 does not emit for that
    -- event type is malformed, exactly as S1 treats its ten-column position payload.
    v_want := case v_etype
      when 'NEW_POSITION'        then v_det_base || array['symbol_raw','side','after_volume']
      when 'REAPPEARANCE'        then v_det_base || array['symbol_raw','side','after_volume']
      when 'POSITION_DISAPPEARED' then v_det_base || array['symbol_raw','side','before_volume']
      when 'POSITION_INCREASE'   then v_det_base || array['symbol_raw','side',
                                                          'before_volume','after_volume']
      when 'POSITION_DECREASE'   then v_det_base || array['symbol_raw','side',
                                                          'before_volume','after_volume']
      else v_det_base || array['before_symbol_raw','after_symbol_raw','before_side','after_side',
                               'before_volume','after_volume']
    end;
    if not public.mt5_capture_keys_match_v1(v_det, v_want) then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end if;
    if not public.mt5_capture_keys_match_v1(v_ref, v_ref_keys) then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PROVENANCE'; return;
    end if;

    -- scope: the detection is about THIS capture's user / account / position. Every operand
    -- was typed in the hoisted pass above, so these compare arrived values, not renderings.
    if (v_det ->> 'user_id') is distinct from p_user::text
       or (v_det ->> 'source_account') is distinct from p_account
       or (v_det ->> 'position_id') is distinct from v_position::text then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end if;

    -- run identifiers. Both are known to be canonical uuid TEXT (hoisted pass), so all that
    -- is left to check is that a delta really names two different runs.
    v_before_txt := v_det ->> 'before_run_id';
    v_after_txt  := v_det ->> 'after_run_id';
    if v_before_txt = v_after_txt then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end if;

    -- claimed sequence numbers: positive integers, strictly increasing. Typed in the hoisted
    -- pass, so the casts below cannot raise.
    v_bseq := (v_det ->> 'before_run_seq')::numeric;
    v_aseq := (v_det ->> 'after_run_seq')::numeric;
    if v_bseq <> trunc(v_bseq) or v_aseq <> trunc(v_aseq)
       or v_bseq < 1 or v_aseq < 1 or v_bseq >= v_aseq then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end if;

    -- ---- the quiet-window time invariant ---------------------------------------------------
    begin
      v_at := (v_det ->> 'detected_at')::timestamptz;
    exception when others then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end;
    if v_at is null or not isfinite(v_at) then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
    end if;
    if v_i = 0 then
      -- first_detection_at is not a free-standing claim: it IS the first detection's instant
      if v_at is distinct from v_first then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
      end if;
    else
      if v_at < v_prev_at then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
      end if;
      -- a joined detection RESTARTS the window, so it must land within one window of its
      -- predecessor; a larger gap means these detections belong to two different candidates
      if v_at > v_prev_at + v_interval then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
      end if;
      if v_at = v_prev_at then
        -- the EXISTING T2 canonical order for equal instants: after_run_seq, then the frozen
        -- identity tuple. chr(1) sorts below every character these fields can contain, so the
        -- concatenation orders exactly as the tuple does.
        v_tie := ((v_ident ->> 2) || chr(1) || (v_ident ->> 4) || chr(1)
                  || (v_ident ->> 5)) collate "C";
        if v_aseq < v_prev_aseq or (v_aseq = v_prev_aseq and v_tie <= v_prev_tie) then
          return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
        end if;
      end if;
    end if;
    if v_i = v_n_ident - 1 and v_at is distinct from v_last then
      -- ...and last_detection_at IS the last detection's instant
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
    end if;
    if v_at >= v_deadline then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_TIME_ORDER'; return;
    end if;
    v_prev_at   := v_at;
    v_prev_aseq := v_aseq;
    v_prev_tie  := ((v_ident ->> 2) || chr(1) || (v_ident ->> 4) || chr(1)
                    || (v_ident ->> 5)) collate "C";

    -- ---- event semantics, exactly as t1_detector.py emits them ----------------------------
    if v_etype = 'POSITION_IDENTITY_CONFLICT' then
      if btrim(coalesce(v_det ->> 'before_symbol_raw', '')) = ''
         or btrim(coalesce(v_det ->> 'after_symbol_raw', '')) = ''
         or not ((v_det ->> 'before_side') = any (v_sides))
         or not ((v_det ->> 'after_side') = any (v_sides))
         or pg_catalog.jsonb_typeof(v_det -> 'before_volume') <> 'number'
         or pg_catalog.jsonb_typeof(v_det -> 'after_volume') <> 'number' then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
      if (v_det ->> 'before_volume')::numeric <= 0
         or (v_det ->> 'after_volume')::numeric <= 0 then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
      -- a conflict must actually conflict
      if (v_det ->> 'before_symbol_raw') = (v_det ->> 'after_symbol_raw')
         and (v_det ->> 'before_side') = (v_det ->> 'after_side') then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
    else
      if btrim(coalesce(v_det ->> 'symbol_raw', '')) = ''
         or not ((v_det ->> 'side') = any (v_sides)) then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
      v_bvol := null; v_avol := null;
      if v_det ? 'before_volume' then
        if pg_catalog.jsonb_typeof(v_det -> 'before_volume') <> 'number' then
          return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
        end if;
        v_bvol := (v_det ->> 'before_volume')::numeric;
      end if;
      if v_det ? 'after_volume' then
        if pg_catalog.jsonb_typeof(v_det -> 'after_volume') <> 'number' then
          return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
        end if;
        v_avol := (v_det ->> 'after_volume')::numeric;
      end if;
      -- Exact numeric semantics: these are stored snapshot facts, not estimates, so there is
      -- no tolerance. 1000000000.0 -> 1000000000.5 IS an increase.
      if v_etype in ('NEW_POSITION','REAPPEARANCE') then
        if v_avol is null or v_avol <= 0 then
          return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
        end if;
      elsif v_etype = 'POSITION_DISAPPEARED' then
        if v_bvol is null or v_bvol <= 0 then
          return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
        end if;
      elsif v_etype = 'POSITION_INCREASE' then
        if v_bvol is null or v_avol is null or v_bvol <= 0 or v_avol <= v_bvol then
          return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
        end if;
      else   -- POSITION_DECREASE
        if v_bvol is null or v_avol is null or v_bvol <= 0 or v_avol <= 0 or v_avol >= v_bvol then
          return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
        end if;
      end if;
    end if;

    -- ---- ordinal correspondence: detection[i] <-> identity[i] <-> run_reference[i] ---------
    if (v_ident ->> 0) is distinct from (v_det ->> 'user_id')
       or (v_ident ->> 1) is distinct from (v_det ->> 'source_account')
       or (v_ident ->> 2) is distinct from v_etype
       or (v_ident ->> 3) is distinct from (v_det ->> 'position_id')
       or (v_ident ->> 4) is distinct from v_before_txt
       or (v_ident ->> 5) is distinct from v_after_txt then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PROVENANCE'; return;
    end if;
    if (v_ref ->> 'before_run_id') is distinct from v_before_txt
       or (v_ref ->> 'after_run_id') is distinct from v_after_txt
       or (v_ref ->> 'before_run_seq')::numeric is distinct from v_bseq
       or (v_ref ->> 'after_run_seq')::numeric is distinct from v_aseq then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PROVENANCE'; return;
    end if;
    if (p_candidate -> 'event_types' ->> v_i) is distinct from v_etype then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_PROVENANCE'; return;
    end if;

    -- ---- authoritative run provenance: the runs must really be what the payload claims ----
    begin
      v_before_uuid := v_before_txt::uuid;
      v_after_uuid  := v_after_txt::uuid;
    exception when others then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end;

    select * into v_run_before from public.mt5_sync_runs r where r.id = v_before_uuid;
    if not found then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_NOT_FOUND'; return;
    end if;
    select * into v_run_after from public.mt5_sync_runs r where r.id = v_after_uuid;
    if not found then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_NOT_FOUND'; return;
    end if;

    if v_run_before.user_id is distinct from p_user
       or v_run_before.source_account is distinct from p_account
       or v_run_after.user_id is distinct from p_user
       or v_run_after.source_account is distinct from p_account then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_SCOPE'; return;
    end if;
    if v_run_before.snapshot_status is distinct from 'complete'
       or v_run_after.snapshot_status is distinct from 'complete' then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_NOT_COMPLETE'; return;
    end if;
    -- Only healthy completed observations are trusted evidence. A completed SUSPICIOUS run
    -- emits nothing and breaks continuity (frozen T1 rule).
    if v_run_before.snapshot_health is distinct from 'healthy'
       or v_run_after.snapshot_health is distinct from 'healthy' then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_NOT_HEALTHY'; return;
    end if;
    -- The STORED run_seq is authority. Caller-supplied sequence numbers are never trusted.
    if v_run_before.run_seq is distinct from v_bseq::bigint
       or v_run_after.run_seq is distinct from v_aseq::bigint then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_SEQ_MISMATCH'; return;
    end if;
    if v_run_before.run_seq >= v_run_after.run_seq then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_SEQ_MISMATCH'; return;
    end if;

    -- Executable T1 adjacency: CONSECUTIVE completed observations. Any completed run between
    -- them (healthy or suspicious) means this pair is not a legal delta.
    if exists (select 1 from public.mt5_sync_runs r
                where r.user_id = p_user and r.source_account = p_account
                  and r.snapshot_status = 'complete'
                  and r.run_seq > v_run_before.run_seq
                  and r.run_seq < v_run_after.run_seq) then
      return query select false, 0, null::uuid, null::text, 'ERR_RUN_NOT_ADJACENT'; return;
    end if;

    -- ---- MEMBERSHIP TRUTH: re-derive the classification from the immutable snapshots -------
    select * into v_pos_before from public.mt5_sync_run_positions p
     where p.run_id = v_before_uuid and p.position_id = v_position
       and p.user_id = p_user and p.source_account = p_account;
    v_in_before := found;
    select * into v_pos_after from public.mt5_sync_run_positions p
     where p.run_id = v_after_uuid and p.position_id = v_position
       and p.user_id = p_user and p.source_account = p_account;
    v_in_after := found;

    if v_in_before and v_in_after then
      if v_pos_before.symbol_raw is distinct from v_pos_after.symbol_raw
         or v_pos_before.side is distinct from v_pos_after.side then
        v_derived := 'POSITION_IDENTITY_CONFLICT';
      elsif v_pos_after.volume > v_pos_before.volume then
        v_derived := 'POSITION_INCREASE';
      elsif v_pos_after.volume < v_pos_before.volume then
        v_derived := 'POSITION_DECREASE';
      else
        v_derived := null;              -- unchanged: there is no event here
      end if;
    elsif (not v_in_before) and v_in_after then
      -- NEW vs REAPPEARANCE is settled by the STORED history, not by whatever history the
      -- caller's T1 run happened to see. Truncated caller history cannot mint a NEW_POSITION.
      select exists (
        select 1
          from public.mt5_sync_run_positions p
          join public.mt5_sync_runs r on r.id = p.run_id
         where p.position_id = v_position
           and p.user_id = p_user and p.source_account = p_account
           and r.user_id = p_user and r.source_account = p_account
           and r.snapshot_status = 'complete' and r.snapshot_health = 'healthy'
           and r.run_seq < v_run_before.run_seq)
        into v_seen_earlier;
      v_derived := case when v_seen_earlier then 'REAPPEARANCE' else 'NEW_POSITION' end;
    elsif v_in_before and (not v_in_after) then
      -- observed membership disappearance ONLY: never "closed", no close price, no realised P/L
      v_derived := 'POSITION_DISAPPEARED';
    else
      v_derived := null;                -- absent from both: there is no event here
    end if;

    if v_derived is distinct from v_etype then
      return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
    end if;

    -- ...and the caller's own facts must EQUAL the persisted membership exactly
    if v_etype = 'POSITION_IDENTITY_CONFLICT' then
      if (v_det ->> 'before_symbol_raw') is distinct from v_pos_before.symbol_raw
         or (v_det ->> 'before_side') is distinct from v_pos_before.side
         or (v_det ->> 'before_volume')::numeric is distinct from v_pos_before.volume
         or (v_det ->> 'after_symbol_raw') is distinct from v_pos_after.symbol_raw
         or (v_det ->> 'after_side') is distinct from v_pos_after.side
         or (v_det ->> 'after_volume')::numeric is distinct from v_pos_after.volume then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
    elsif v_etype = 'POSITION_DISAPPEARED' then
      if (v_det ->> 'symbol_raw') is distinct from v_pos_before.symbol_raw
         or (v_det ->> 'side') is distinct from v_pos_before.side
         or (v_det ->> 'before_volume')::numeric is distinct from v_pos_before.volume then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
    elsif v_etype in ('NEW_POSITION','REAPPEARANCE') then
      if (v_det ->> 'symbol_raw') is distinct from v_pos_after.symbol_raw
         or (v_det ->> 'side') is distinct from v_pos_after.side
         or (v_det ->> 'after_volume')::numeric is distinct from v_pos_after.volume then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
    else   -- POSITION_INCREASE / POSITION_DECREASE: identity is stable, so it must match BOTH
      if (v_det ->> 'symbol_raw') is distinct from v_pos_before.symbol_raw
         or (v_det ->> 'symbol_raw') is distinct from v_pos_after.symbol_raw
         or (v_det ->> 'side') is distinct from v_pos_before.side
         or (v_det ->> 'side') is distinct from v_pos_after.side
         or (v_det ->> 'before_volume')::numeric is distinct from v_pos_before.volume
         or (v_det ->> 'after_volume')::numeric is distinct from v_pos_after.volume then
        return query select false, 0, null::uuid, null::text, 'ERR_CAPTURE_DETECTION'; return;
      end if;
    end if;
  end loop;

  -- ---- the payload fingerprint (the key itself was derived before the run checks) ----------
  v_fp := public.mt5_capture_payload_fingerprint_v1(p_candidate);

  -- ---- append-once, replay-safe, RACE-safe -------------------------------------------------
  -- The uniqueness decision is made by the index inside the INSERT, so two concurrent callers
  -- cannot both believe they are the first. DO NOTHING (never DO UPDATE): stored capture
  -- evidence is never rewritten, and the immutability trigger would refuse it anyway.
  for v_attempt in 1 .. 3 loop
    v_new_id := null;
    insert into public.mt5_capture_events(
      event_key, user_id, source_account, position_id, basis_run_id,
      first_detection_at, last_detection_at, quiet_deadline, quiet_window_seconds,
      detector_version, aggregator_version, payload, payload_fingerprint)
    values (
      v_key, p_user, p_account, v_position, v_basis,
      v_first, v_last, v_deadline, v_window,
      p_candidate ->> 'detector_version', p_candidate ->> 'aggregator_version',
      p_candidate, v_fp)
    on conflict (event_key) do nothing
    returning id into v_new_id;

    if v_new_id is not null then
      return query select true, 1, v_new_id, v_key, null::text; return;
    end if;

    select c.id, c.payload_fingerprint into v_existing_id, v_existing_fp
      from public.mt5_capture_events c
     where c.event_key = v_key;
    if found then
      if v_existing_fp = v_fp then
        -- exact idempotent replay: SAME id, nothing written, nothing overwritten
        return query select true, 0, v_existing_id, v_key, null::text; return;
      end if;
      -- hard conflict. The stored evidence is never updated to resolve this.
      return query select false, 0, v_existing_id, v_key, 'ERR_CAPTURE_CONFLICT'; return;
    end if;
    -- The conflicting inserter rolled back between our INSERT and our SELECT. Retry, bounded.
  end loop;

  return query select false, 0, null::uuid, v_key, 'ERR_CAPTURE_RACE';
end
$fn$;

alter function public.mt5_capture_keys_match_v1(jsonb, text[]) owner to postgres;
alter function public.mt5_capture_event_key_v1(jsonb) owner to postgres;
alter function public.mt5_capture_payload_fingerprint_v1(jsonb) owner to postgres;
alter function public.mt5_append_capture_event_v1(uuid, text, jsonb) owner to postgres;

revoke all on function public.mt5_capture_keys_match_v1(jsonb, text[])
  from public, anon, authenticated, service_role;
revoke all on function public.mt5_capture_event_key_v1(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.mt5_capture_payload_fingerprint_v1(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.mt5_append_capture_event_v1(uuid, text, jsonb)
  from public, anon, authenticated, service_role;

-- the ONLY application-visible entry point, and only for the trusted writer
grant execute on function public.mt5_append_capture_event_v1(uuid, text, jsonb) to service_role;

insert into public.mt5_schema_migrations(
  version, description, checksum, source_artifact_sha256, status, objects, applied_at, applied_by
) values (
  'mt5_t2_capture_events_rpc_v1',
  'MT5 T2 append-once capture-event RPC with deterministic event key and replay equality',
  -- packet identity token = sha256('mt5_t2_capture_events_rpc_v1|packet-revision-5')
  'b5b3edffc21ad064850dcfc9f562322ee8592317c070592d57f1b12769ae00d0',
  '20D8A278F326D863299F2AFCE7D0198BFC2579ADD121A3697E5E9AC0BBDCF645',
  'applied',
  jsonb_build_object(
    'packet_revision', '5',
    'functions', jsonb_build_array(
      'public.mt5_capture_keys_match_v1(jsonb,text[])',
      'public.mt5_capture_event_key_v1(jsonb)',
      'public.mt5_capture_payload_fingerprint_v1(jsonb)',
      'public.mt5_append_capture_event_v1(uuid,text,jsonb)')
  ),
  now(),
  current_user
);

commit;
