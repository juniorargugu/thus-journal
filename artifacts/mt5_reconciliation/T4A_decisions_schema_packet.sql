-- ================================================================================================
-- T4A HUMAN DECISION LAYER — SCHEMA PACKET (mt5_t4a_decisions_schema_v1, packet revision 1)
--
-- One immutable TERMINAL human workflow decision per capture event. This table is WORKFLOW/AUDIT
-- state about immutable machine evidence — it is NOT machine evidence, NOT a Journal trade, NOT
-- T0 Journal narrative (that exists only inside a future T4B promotion transaction), and it never
-- feeds back into S1/T1/T2/T3 semantics.
--
-- Frozen contract (T4 HUMAN DECISION CONTRACT Revision 3, approved):
--   * exactly one terminal decision per capture_event_id (UNIQUE)
--   * NO redundant user_id column: ownership is canonical on the parent capture row; every scope
--     check derives decision.capture_event_id -> mt5_capture_events.user_id
--   * append-once: never UPDATE, never DELETE (guard trigger below). First-writer provenance is
--     therefore immutable by construction — a same-action replay cannot touch these fields.
--   * executable source/provenance CHECK: 'telegram' requires chat+message ids with message > 0
--     (chat ids may legitimately be negative for groups); 'harness' requires both NULL; any other
--     source value fails the same constraint.
--   * created_at is THE decision instant, server-owned. There is deliberately no second
--     decided_at column.
--   * nothing is copied from the parent row (no symbol/position/event types/volume/run refs/kind).
--
-- Ownership/administrative caveat (same as every ledger table in this pipeline): the table owner
-- (postgres) can still ALTER/DROP/TRUNCATE — PostgreSQL offers no stronger guarantee. The guard
-- blocks the row-mutation paths the application could ever reach.
--
-- APPLY (offline first): psql -v ON_ERROR_STOP=1 -f T4A_decisions_schema_packet.sql
-- Production apply is NOT authorized by T4A-0.
-- ================================================================================================

begin;

-- ------------------------------------------------------------------------------------------------
-- Preflight: the immutable capture table must exist with EXACTLY its 15 frozen columns, the
-- migrations registry must exist, and this packet must not already be applied.
-- ------------------------------------------------------------------------------------------------
do $t4a_pre$
declare
  v_cols text[];
begin
  if to_regclass('public.mt5_capture_events') is null then
    raise exception 'MT5_T4A_PREFLIGHT: public.mt5_capture_events does not exist';
  end if;
  select array_agg(column_name::text order by column_name) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'mt5_capture_events';
  if v_cols is distinct from array[
      'aggregator_version','basis_run_id','created_at','detector_version','event_key',
      'first_detection_at','id','last_detection_at','payload','payload_fingerprint',
      'position_id','quiet_deadline','quiet_window_seconds','source_account','user_id'] then
    raise exception 'MT5_T4A_PREFLIGHT: mt5_capture_events columns are not the frozen 15: %',
      v_cols;
  end if;
  if to_regclass('public.mt5_schema_migrations') is null then
    raise exception 'MT5_T4A_PREFLIGHT: public.mt5_schema_migrations does not exist';
  end if;
  if to_regclass('public.mt5_capture_decisions') is not null then
    raise exception 'MT5_T4A_PREFLIGHT: public.mt5_capture_decisions already exists — apply once, '
      'or run the rollback packet first';
  end if;
end $t4a_pre$;

-- ------------------------------------------------------------------------------------------------
-- The decision table.
-- ------------------------------------------------------------------------------------------------
create table public.mt5_capture_decisions (
  id                   uuid        not null default gen_random_uuid(),

  -- the ONLY link to the evidence. Ownership (user_id / source_account) is canonical on the
  -- parent capture row and is deliberately NOT duplicated here.
  capture_event_id     uuid        not null,

  -- the human's terminal workflow answer, in the frozen T3 action vocabulary
  action               text        not null,

  -- first-writer provenance. Immutable: a replay NEVER updates these.
  source               text        not null,
  telegram_chat_id     bigint,
  telegram_message_id  bigint,

  -- THE decision instant, server-owned. Deliberately the only timestamp.
  created_at           timestamptz not null default now(),

  constraint mt5_capture_decisions_pkey primary key (id),
  constraint mt5_cd_capture_uk unique (capture_event_id),
  constraint mt5_cd_capture_fk foreign key (capture_event_id)
    references public.mt5_capture_events(id),
  constraint mt5_cd_action_chk check (
    action in ('journal_add', 'already_logged', 'no_record')),
  -- vocabulary AND per-source provenance shape in ONE executable constraint: an unrecognized
  -- source matches neither branch and is rejected. telegram_chat_id has NO positivity check —
  -- Telegram group/supergroup chat ids are negative by contract.
  constraint mt5_cd_source_shape_chk check (
    (source = 'telegram'
       and telegram_chat_id is not null
       and telegram_message_id is not null
       and telegram_message_id > 0)
    or
    (source = 'harness'
       and telegram_chat_id is null
       and telegram_message_id is null))
);

alter table public.mt5_capture_decisions owner to postgres;

comment on table public.mt5_capture_decisions is
  'T4A: one immutable TERMINAL human workflow decision per mt5_capture_events row. Workflow/audit '
  'state only — never machine evidence, never a Journal trade, never T0 narrative. journal_add is '
  'a durable REQUEST: it does NOT mean Journal promotion happened (that is T4B). No user_id here: '
  'scope derives from the parent capture row. Append-once; first-writer provenance is immutable.';
comment on column public.mt5_capture_decisions.created_at is
  'THE decision instant, server-owned (there is deliberately no separate decided_at).';

-- ------------------------------------------------------------------------------------------------
-- Immutability guard. Mirrors the proven mt5_capture_event_guard_v1() shape.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_capture_decision_guard_v1() returns trigger
language plpgsql security definer set search_path = ''
as $guard$
begin
  -- A decision is terminal workflow truth. A wrong decision is corrected by a FUTURE explicit
  -- supersede contract, never by editing or deleting the recorded one.
  raise exception 'MT5_T4A_IMMUTABLE_ROW' using errcode = 'P0001';
end
$guard$;
alter function public.mt5_capture_decision_guard_v1() owner to postgres;
revoke all on function public.mt5_capture_decision_guard_v1()
  from public, anon, authenticated, service_role;

create trigger mt5_capture_decision_no_mutate_v1
  before update or delete on public.mt5_capture_decisions
  for each row execute function public.mt5_capture_decision_guard_v1();

-- ------------------------------------------------------------------------------------------------
-- RLS and ACLs. authenticated/anon get NOTHING. service_role gets SELECT only; the write path is
-- the SECURITY DEFINER decision RPC and nothing else.
-- ------------------------------------------------------------------------------------------------
alter table public.mt5_capture_decisions enable row level security;

create policy mt5_cd_service_read_v1 on public.mt5_capture_decisions
  for select to service_role using (true);

revoke all on table public.mt5_capture_decisions from public, anon, authenticated, service_role;
grant select on table public.mt5_capture_decisions to service_role;

-- ------------------------------------------------------------------------------------------------
-- Index note (decided with EXPLAIN evidence in the offline verification, see the packet readme):
-- the pending FIFO query filters by parent user_id, anti-joins THIS table through
-- mt5_cd_capture_uk, and orders by (created_at, id) on the CAPTURE table. At realistic per-user
-- volumes (hundreds to a few thousand rows) the planner's filter+sort is trivially cheap and the
-- anti-join probe is fully served by mt5_cd_capture_uk, so NO additional index is created here.
-- Revisit with fresh EXPLAIN evidence before any future volume jump.
-- ------------------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------------------
-- Postflight: our own shape and nothing but our shape.
-- ------------------------------------------------------------------------------------------------
do $t4a_post$
declare
  v_bad text;
  v_n   integer;
begin
  if not exists (select 1 from pg_catalog.pg_class c
                  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relname = 'mt5_capture_decisions'
                   and c.relrowsecurity) then
    raise exception 'MT5_T4A_POSTFLIGHT: row level security is not enabled';
  end if;
  select string_agg(grantee || '/' || privilege_type, ',') into v_bad
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'mt5_capture_decisions'
     and (grantee in ('anon', 'authenticated', 'PUBLIC')
          or (grantee = 'service_role' and privilege_type <> 'SELECT'));
  if v_bad is not null then
    raise exception 'MT5_T4A_POSTFLIGHT: unexpected table grant(s) on the decision table: %',
      v_bad;
  end if;
  select count(*) into v_n from pg_catalog.pg_trigger
   where tgrelid = 'public.mt5_capture_decisions'::regclass and not tgisinternal;
  if v_n <> 1 then
    raise exception 'MT5_T4A_POSTFLIGHT: expected exactly one immutability trigger, found %', v_n;
  end if;
end $t4a_post$;

insert into public.mt5_schema_migrations(
  version, description, checksum, source_artifact_sha256, status, objects, applied_at, applied_by
) values (
  'mt5_t4a_decisions_schema_v1',
  'T4A immutable terminal human decision table for mt5_capture_events (one per capture event)',
  -- packet identity token = sha256('mt5_t4a_decisions_schema_v1|packet-revision-1')
  '66cbfaadfbf759fe66dd4392833b44d6043d69750a55205c5cfcef21b4931012',
  -- canonical {version,cases} digest of ops/mt5_import/fixtures/t3_kind_fixtures_v1.json
  -- (ledger requires UPPERCASE hex for source_artifact_sha256)
  '85C076D09738D4F3189E54E2B33F6348ADA205304291FD59B4801A8F2E629355',
  'applied',
  jsonb_build_object(
    'packet_revision', '1',
    'tables', jsonb_build_array('public.mt5_capture_decisions'),
    'functions', jsonb_build_array('public.mt5_capture_decision_guard_v1()')
  ),
  now(),
  current_user
);

commit;
