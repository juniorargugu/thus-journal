-- ================================================================================================
-- MT5 T2 — CAPTURE EVENT PERSISTENCE, SCHEMA PACKET
--
-- Status: EXECUTABLE DRAFT — NOT RUN AGAINST PRODUCTION.
-- Packet revision: 5
--   revision 1: initial draft (Codex: CHANGES_REQUESTED).
--   revision 2: composite run-scope FK instead of the id-only FK; forbidden-field refusal made
--               RECURSIVE over the whole payload instead of top-level keys only.
--   revision 3: table semantics UNCHANGED from revision 2. The identity moves with the packet
--               SET: the RPC, rollback and verification packets changed materially in this
--               revision, and the rollback packet pins one revision for the whole set, so a
--               database carrying rev2 provenance must not be treated as carrying rev3.
--   revision 4: table semantics UNCHANGED from revision 2, again. The RPC gained the canonical
--               identity wire format, so the SET moves to rev4 for the same reason: rev3
--               provenance must not be reused for changed bytes.
--   revision 5: table semantics UNCHANGED from revision 2, again. The RPC gained exact JSON
--               type discipline and the opaque-text source_account contract; the SET moves
--               with it, so rev4 provenance is not reused for changed bytes.
-- Depends on: S1 (frozen, packet revision 5) and S1.1 (applied). Requires
--             public.mt5_sync_runs, its (id,user_id,source_account) unique key, and
--             public.mt5_sha256_text_v1(text).
--
-- WHAT THIS PACKET ADDS
--   public.mt5_capture_events                  immutable T2 capture evidence, append-once
--   public.mt5_capture_event_guard_v1()        immutability trigger function, postgres-only
--
-- WHAT IT DELIBERATELY DOES NOT ADD
--   * no UPDATE / DELETE / correct / dismiss RPC — capture evidence is never edited
--   * no skipped / promoted / ignored / dismissed / confirmed / decision / decision_state /
--     journal_trade_id / materialized_trade_id field ANYWHERE in the payload: those are
--     HUMAN-DECISION state and belong to a later layer that REFERENCES id, never mutates this
--     row. Machine observation != human decision.
--   * no equity / balance / account_equity / account_balance / currency / margin / profit_total
--     field anywhere in the payload. basis_run_id is the reference to the S1/S1.1 machine
--     context; account facts stay authoritative in mt5_sync_run_account.
--   * no browser/authenticated grant of any kind, and no read RPC (out of scope for this task)
--   * no change to ANY frozen S1 or S1.1 object
--
-- WHY THE FORBIDDEN-FIELD CHECKS ARE RECURSIVE
--   A top-level `payload ?| array[...]` check only inspects the outermost object. The payload
--   carries nested objects (run_references, detections) and arrays, so a top-level-only check
--   lets a nested `{"detections":[{"equity":...}]}` through. jsonb_path_exists with the `$.**`
--   recursive accessor inspects every descendant, and is IMMUTABLE, so it is usable directly in
--   a CHECK constraint with no function dependency for pg_dump to get wrong.
--
-- NOT FOR PRODUCTION EXECUTION IN THIS TASK. Local/disposable verification only.
-- ================================================================================================

begin;

-- ------------------------------------------------------------------------------------------------
-- Preflight. Refuse a name collision or a ledger row rather than overwrite an unknown object.
-- ------------------------------------------------------------------------------------------------
do $t2_pre$
begin
  if to_regclass('public.mt5_sync_runs') is null then
    raise exception 'MT5_T2_PREFLIGHT: public.mt5_sync_runs is missing — apply S1 first';
  end if;
  -- The composite run-scope key this packet's FK depends on. An id-only FK would let a capture
  -- row point at a run belonging to a DIFFERENT user/account and still satisfy the database.
  if not exists (
    select 1 from pg_catalog.pg_constraint c
     where c.conrelid = 'public.mt5_sync_runs'::regclass
       and c.contype = 'u'
       and pg_catalog.pg_get_constraintdef(c.oid) = 'UNIQUE (id, user_id, source_account)') then
    raise exception 'MT5_T2_PREFLIGHT: mt5_sync_runs is missing the (id,user_id,source_account) unique key — the composite scope FK cannot be created';
  end if;
  if not exists (select 1 from pg_catalog.pg_proc p
                   join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'mt5_sha256_text_v1') then
    raise exception 'MT5_T2_PREFLIGHT: public.mt5_sha256_text_v1(text) is missing — apply S1 first';
  end if;
  if to_regclass('public.mt5_capture_events') is not null then
    raise exception 'MT5_T2_PREFLIGHT: public.mt5_capture_events already exists';
  end if;
  if exists (select 1 from pg_catalog.pg_proc p
               join pg_catalog.pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'mt5_capture_event_guard_v1') then
    raise exception 'MT5_T2_PREFLIGHT: a T2 capture guard function name already exists';
  end if;
  if exists (select 1 from public.mt5_schema_migrations
              where version = 'mt5_t2_capture_events_schema_v1') then
    raise exception 'MT5_T2_PREFLIGHT: ledger already carries mt5_t2_capture_events_schema_v1';
  end if;
end
$t2_pre$;

-- ------------------------------------------------------------------------------------------------
-- The table. Every column is either server-owned or a validated fact about the closed candidate.
-- ------------------------------------------------------------------------------------------------
create table public.mt5_capture_events (
  -- server-owned identity
  id                    uuid        not null default extensions.gen_random_uuid(),
  created_at            timestamptz not null default now(),

  -- deterministic logical identity of the coalesced evidence (derived by the RPC)
  event_key             text        not null,

  -- scope
  user_id               uuid        not null,
  source_account        text        not null,
  position_id           bigint      not null,

  -- machine context reference. NOT a copy of account facts.
  basis_run_id          uuid        not null,

  -- the quiet window that produced this candidate
  first_detection_at    timestamptz not null,
  last_detection_at     timestamptz not null,
  quiet_deadline        timestamptz not null,
  quiet_window_seconds  numeric     not null,

  -- provenance of the producing code
  detector_version      text        not null,
  aggregator_version    text        not null,

  -- the canonical closed candidate: contributing identities, event types, before/after run
  -- provenance and the detections needed to explain what changed
  payload               jsonb       not null,
  payload_fingerprint   text        not null,

  constraint mt5_capture_events_pkey primary key (id),
  constraint mt5_capture_events_event_key_uk unique (event_key),

  -- COMPOSITE scope FK: the basis run must belong to the SAME user and account as this capture
  -- event. The id-only form would be satisfied by any run in the table.
  constraint mt5_capture_events_basis_run_fk
    foreign key (basis_run_id, user_id, source_account)
    references public.mt5_sync_runs(id, user_id, source_account),

  constraint mt5_ce_account_chk check (btrim(source_account) <> ''),
  constraint mt5_ce_position_chk check (position_id > 0),
  constraint mt5_ce_window_chk check (quiet_window_seconds > 0 and quiet_window_seconds < 86400),
  constraint mt5_ce_order_chk check (first_detection_at <= last_detection_at
                                     and last_detection_at < quiet_deadline),
  constraint mt5_ce_versions_chk check (btrim(detector_version) <> ''
                                        and btrim(aggregator_version) <> ''),
  constraint mt5_ce_key_chk check (event_key ~ '^[0-9a-f]{64}$'),
  constraint mt5_ce_fingerprint_chk check (payload_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint mt5_ce_payload_object_chk check (jsonb_typeof(payload) = 'object'),

  -- RECURSIVE structural refusal of human-decision state, at ANY depth. If a future layer needs
  -- "skipped" or "promoted", it gets its OWN table referencing id — this row can never carry it.
  constraint mt5_ce_no_decision_state_chk check (
    not jsonb_path_exists(payload, '$.** ? (exists(@."skipped") || exists(@."promoted") || exists(@."ignored") || exists(@."dismissed") || exists(@."confirmed") || exists(@."decision") || exists(@."decision_state") || exists(@."journal_trade_id") || exists(@."materialized_trade_id"))')),

  -- RECURSIVE structural refusal of copied account money, at ANY depth. basis_run_id is the
  -- reference; the facts live in mt5_sync_run_account.
  constraint mt5_ce_no_account_facts_chk check (
    not jsonb_path_exists(payload, '$.** ? (exists(@."equity") || exists(@."balance") || exists(@."account_equity") || exists(@."account_balance") || exists(@."currency") || exists(@."equity_quality") || exists(@."balance_quality") || exists(@."margin") || exists(@."profit_total"))'))
);

alter table public.mt5_capture_events owner to postgres;

comment on table public.mt5_capture_events is
  'MT5 T2: immutable capture evidence for a timer-closed quiet-window candidate. Machine observation, NOT a human decision and NOT a Journal trade: append-once, never updated, never deleted. basis_run_id references the S1/S1.1 machine context in the SAME user/account scope; account facts stay in mt5_sync_run_account.';

create index mt5_ce_scope_idx
  on public.mt5_capture_events(user_id, source_account, position_id, last_detection_at desc);
create index mt5_ce_basis_run_idx on public.mt5_capture_events(basis_run_id);

-- ------------------------------------------------------------------------------------------------
-- Immutability guard. Mirrors the proven mt5_run_account_guard_v1() shape.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_capture_event_guard_v1() returns trigger
language plpgsql security definer set search_path = ''
as $guard$
begin
  -- Capture evidence is never corrected. A wrong capture is superseded by a NEW observation,
  -- never edited into a different claim about the past.
  raise exception 'MT5_T2_IMMUTABLE_ROW' using errcode = 'P0001';
end
$guard$;
alter function public.mt5_capture_event_guard_v1() owner to postgres;
revoke all on function public.mt5_capture_event_guard_v1()
  from public, anon, authenticated, service_role;

create trigger mt5_capture_event_no_mutate_v1
  before update or delete on public.mt5_capture_events
  for each row execute function public.mt5_capture_event_guard_v1();

-- ------------------------------------------------------------------------------------------------
-- RLS and ACLs. authenticated/anon get NOTHING. service_role gets SELECT only; the write path is
-- the SECURITY DEFINER RPC and nothing else.
-- ------------------------------------------------------------------------------------------------
alter table public.mt5_capture_events enable row level security;

create policy mt5_ce_service_read_v1 on public.mt5_capture_events
  for select to service_role using (true);

revoke all on table public.mt5_capture_events from public, anon, authenticated, service_role;
grant select on table public.mt5_capture_events to service_role;

-- ------------------------------------------------------------------------------------------------
-- Postflight: our own shape, no application write grant, and the frozen S1/S1.1 tables untouched.
-- ------------------------------------------------------------------------------------------------
do $t2_post$
declare
  v_bad text;
begin
  if not exists (select 1 from pg_catalog.pg_class c
                   join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relname = 'mt5_capture_events'
                    and c.relrowsecurity) then
    raise exception 'MT5_T2_POSTFLIGHT: row level security is not enabled';
  end if;

  -- the FK must be the COMPOSITE scope FK, not an id-only one
  select pg_catalog.pg_get_constraintdef(c.oid) into v_bad
    from pg_catalog.pg_constraint c
   where c.conrelid = 'public.mt5_capture_events'::regclass
     and c.conname = 'mt5_capture_events_basis_run_fk';
  if v_bad is null or v_bad not like 'FOREIGN KEY (basis_run_id, user_id, source_account) REFERENCES mt5_sync_runs(id, user_id, source_account)%' then
    raise exception 'MT5_T2_POSTFLIGHT: basis_run FK is not the composite run-scope FK (got: %)',
      coalesce(v_bad, '<missing>');
  end if;

  select string_agg(grantee || '/' || privilege_type, ',')
    into v_bad
    from information_schema.table_privileges
   where table_schema = 'public' and table_name = 'mt5_capture_events'
     and (grantee in ('anon','authenticated','PUBLIC')
          or (grantee = 'service_role' and privilege_type <> 'SELECT'));
  if v_bad is not null then
    raise exception 'MT5_T2_POSTFLIGHT: unexpected table grant(s) on the immutable capture table: %',
      v_bad;
  end if;

  -- column-level ACLs must be absent too (a column grant leaves pg_class.relacl unchanged)
  if exists (select 1 from pg_catalog.pg_attribute a
              where a.attrelid = 'public.mt5_capture_events'::regclass
                and a.attnum > 0 and not a.attisdropped and a.attacl is not null) then
    raise exception 'MT5_T2_POSTFLIGHT: a column-level ACL exists on the immutable capture table';
  end if;

  if (select count(*) from pg_catalog.pg_trigger
       where tgrelid = 'public.mt5_capture_events'::regclass and not tgisinternal) <> 1 then
    raise exception 'MT5_T2_POSTFLIGHT: expected exactly one immutability trigger';
  end if;

  -- the recursive forbidden-field refusals must actually be recursive
  if exists (select 1 from pg_catalog.pg_constraint c
              where c.conrelid = 'public.mt5_capture_events'::regclass
                and c.conname in ('mt5_ce_no_decision_state_chk','mt5_ce_no_account_facts_chk')
                and pg_catalog.pg_get_constraintdef(c.oid) not like '%$.**%') then
    raise exception 'MT5_T2_POSTFLIGHT: a forbidden-field CHECK is not recursive';
  end if;

  -- the frozen S1/S1.1 tables must be structurally untouched by this additive packet
  if to_regclass('public.mt5_sync_run_positions') is null
     or to_regclass('public.mt5_sync_runs') is null then
    raise exception 'MT5_T2_POSTFLIGHT: a frozen S1 table disappeared';
  end if;
end
$t2_post$;

-- ------------------------------------------------------------------------------------------------
-- Ledger.
-- ------------------------------------------------------------------------------------------------
insert into public.mt5_schema_migrations(
  version, description, checksum, source_artifact_sha256, status, objects, applied_at, applied_by
) values (
  'mt5_t2_capture_events_schema_v1',
  'MT5 T2 immutable capture-event evidence table for timer-closed quiet-window candidates',
  -- packet identity token = sha256('mt5_t2_capture_events_schema_v1|packet-revision-5')
  '5f8e890c9b5a6dae24233ceb96aab06d3d86e705792fc9ed7556087c945f8282',
  -- SHA-256 of the FROZEN T1/T2 contract addendum's LF-normalised bytes. Upper-case hex per
  -- the ledger CHECK. Recomputed and pinned at apply time by the operator.
  '20D8A278F326D863299F2AFCE7D0198BFC2579ADD121A3697E5E9AC0BBDCF645',
  'applied',
  jsonb_build_object(
    'packet_revision', '5',
    'tables', jsonb_build_array('public.mt5_capture_events'),
    'functions', jsonb_build_array('public.mt5_capture_event_guard_v1()'),
    'triggers', jsonb_build_array('mt5_capture_event_no_mutate_v1'),
    'policies', jsonb_build_array('mt5_ce_service_read_v1')
  ),
  now(),
  current_user
);

commit;
