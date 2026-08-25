-- ================================================================================================
-- T4A HUMAN DECISION LAYER — RPC PACKET (mt5_t4a_decisions_rpc_v1, packet revision 2)
--
-- Server-side T3 kind/action policy + the ONLY decision write path + the canonical pending read.
--
-- DEDICATED EVIDENCE SQLSTATE (frozen): 'MT4E1'.
--   mt5_t3_event_types_v1 / mt5_t3_kind_v1 raise SQLSTATE 'MT4E1' for exactly one condition:
--   stored evidence that is invokable but violates the frozen T3 evidence/state-machine contract
--   (missing/ill-typed event_types, arity mismatch with detections, empty sequence, unknown event
--   type, presence-continuity violation). The decision RPC catches ONLY this SQLSTATE and
--   translates it to ERR_DECISION_EVIDENCE_INVALID. There is deliberately NO "when others"
--   anywhere in this packet: any other fault (coding bug, type error, undefined column) escapes
--   as a system/database failure, which the caller must treat as transport-level uncertainty —
--   never as a domain answer.
--
-- SERVER-DERIVED, NOT CALLER-SUPPLIED: kind and the allowed-action set derive from the persisted
-- payload's event-type sequence. The event_types array's ordinal identity with detections was
-- proven at append time by mt5_append_capture_event_v1 (ERR_CAPTURE_PROVENANCE); the helper still
-- re-asserts arity. The caller can never submit kind, allowed actions, or classification.
--
-- ACTION MATRIX (frozen — identical to Python T3 KIND_ACTIONS, proven AT APPLY TIME by the
-- parity fragment embedded below; T4A_t3_kind_fixture_v1.generated.sql is the standalone review
-- copy of the same fragment; fixture sha
-- 85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355):
--   ENTRY    -> journal_add, already_logged, no_record
--   CHANGE   -> already_logged, no_record
--   ABSENCE  -> already_logged, no_record
--   CONFLICT -> no_record
--
-- ATOMIC PARITY (packet revision 2): the GENERATED T3 fixture parity DO block is EMBEDDED in
-- this packet, inside this transaction, AFTER the grants and BEFORE the migration-ledger insert.
-- The transaction order is frozen: helpers -> decision RPC -> pending RPC -> grants/revokes ->
-- embedded fixture parity -> postflight assertions -> ledger insert -> COMMIT. If any fixture
-- case fails, everything rolls back: no functions installed, no grants applied, no ledger row.
-- There is deliberately NO "run the generated file afterwards" release step — the standalone
-- T4A_t3_kind_fixture_v1.generated.sql is a review/re-verification copy of the same fragment.
--
-- APPLY (offline first), AFTER T4A_decisions_schema_packet.sql:
--   psql -v ON_ERROR_STOP=1 -f T4A_decisions_rpc_packet.sql
-- Production apply is NOT authorized by T4A-0.
-- ================================================================================================

begin;

do $t4a_rpc_pre$
begin
  if to_regclass('public.mt5_capture_decisions') is null then
    raise exception 'MT5_T4A_RPC_PREFLIGHT: apply T4A_decisions_schema_packet.sql first';
  end if;
  if to_regprocedure('public.mt5_record_capture_decision_v1(uuid,uuid,text,text,bigint,bigint)')
     is not null then
    raise exception 'MT5_T4A_RPC_PREFLIGHT: decision RPC already exists — apply once, or run the '
      'rollback packet first';
  end if;
end $t4a_rpc_pre$;

-- ------------------------------------------------------------------------------------------------
-- Helper 1: extract the event-type sequence from a persisted capture payload.
-- SQLSTATE 'MT4E1' on every evidence-shape violation.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_t3_event_types_v1(p_payload jsonb) returns text[]
language plpgsql immutable security definer set search_path = ''
as $fn$
declare
  v_types text[];
  v_n     integer;
begin
  if p_payload is null or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'T3 evidence: payload is not an object' using errcode = 'MT4E1';
  end if;
  if jsonb_typeof(p_payload -> 'event_types') is distinct from 'array' then
    raise exception 'T3 evidence: event_types is not an array' using errcode = 'MT4E1';
  end if;
  if exists (select 1 from jsonb_array_elements(p_payload -> 'event_types') e(v)
              where jsonb_typeof(e.v) is distinct from 'string') then
    raise exception 'T3 evidence: event_types carries a non-string element'
      using errcode = 'MT4E1';
  end if;
  select coalesce(array_agg(e.v order by e.o), array[]::text[]) into v_types
    from jsonb_array_elements_text(p_payload -> 'event_types') with ordinality e(v, o);
  v_n := coalesce(array_length(v_types, 1), 0);
  if v_n = 0 then
    raise exception 'T3 evidence: no contributing detections' using errcode = 'MT4E1';
  end if;
  if jsonb_typeof(p_payload -> 'detections') is distinct from 'array'
     or jsonb_array_length(p_payload -> 'detections') <> v_n then
    raise exception 'T3 evidence: detections/event_types arity mismatch'
      using errcode = 'MT4E1';
  end if;
  return v_types;
end
$fn$;

-- ------------------------------------------------------------------------------------------------
-- Helper 2: the frozen T3 kind state machine over ONE ordered event-type sequence.
--
-- Reproduces t3_capture_prompt.py exactly:
--   validation (_validate_presence_continuity): UNKNOWN -> any first event (DISAPPEARED -> ABSENT,
--     else PRESENT); PRESENT refuses openers (NEW_POSITION/REAPPEARANCE), DISAPPEARED -> ABSENT,
--     else PRESENT; ABSENT accepts ONLY REAPPEARANCE (-> PRESENT).
--   classification (render_capture_prompt): any POSITION_IDENTITY_CONFLICT -> CONFLICT; else last
--     element POSITION_DISAPPEARED -> ABSENCE; else an opener after the last closer opened the
--     final presence segment -> ENTRY (NEW -> INCREASE stays ENTRY); else -> CHANGE.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_t3_kind_v1(p_event_types text[]) returns text
language plpgsql immutable security definer set search_path = ''
as $fn$
declare
  v_n            integer := coalesce(array_length(p_event_types, 1), 0);
  v_i            integer;
  v_et           text;
  v_state        text := 'UNKNOWN';
  v_has_conflict boolean := false;
  v_opener_after boolean := false;   -- an opener with no DISAPPEARED after it
begin
  if v_n = 0 then
    raise exception 'T3 evidence: empty event sequence' using errcode = 'MT4E1';
  end if;
  for v_i in 1 .. v_n loop
    v_et := p_event_types[v_i];
    if v_et is null or v_et not in ('NEW_POSITION', 'REAPPEARANCE', 'POSITION_INCREASE',
                                    'POSITION_DECREASE', 'POSITION_DISAPPEARED',
                                    'POSITION_IDENTITY_CONFLICT') then
      raise exception 'T3 evidence: unknown event type %', v_et using errcode = 'MT4E1';
    end if;
    if v_state = 'UNKNOWN' then
      v_state := case when v_et = 'POSITION_DISAPPEARED' then 'ABSENT' else 'PRESENT' end;
    elsif v_state = 'PRESENT' then
      if v_et in ('NEW_POSITION', 'REAPPEARANCE') then
        raise exception 'T3 evidence: % while the position was last observed PRESENT', v_et
          using errcode = 'MT4E1';
      end if;
      v_state := case when v_et = 'POSITION_DISAPPEARED' then 'ABSENT' else 'PRESENT' end;
    else  -- ABSENT
      if v_et <> 'REAPPEARANCE' then
        raise exception 'T3 evidence: % while the position was last observed ABSENT', v_et
          using errcode = 'MT4E1';
      end if;
      v_state := 'PRESENT';
    end if;
    if v_et = 'POSITION_IDENTITY_CONFLICT' then
      v_has_conflict := true;
    end if;
    if v_et = 'POSITION_DISAPPEARED' then
      v_opener_after := false;
    elsif v_et in ('NEW_POSITION', 'REAPPEARANCE') then
      v_opener_after := true;
    end if;
  end loop;
  if v_has_conflict then
    return 'CONFLICT';
  end if;
  if p_event_types[v_n] = 'POSITION_DISAPPEARED' then
    return 'ABSENCE';
  end if;
  if v_opener_after then
    return 'ENTRY';
  end if;
  return 'CHANGE';
end
$fn$;

-- ------------------------------------------------------------------------------------------------
-- Helper 3: the frozen KIND_ACTIONS matrix, order-exact.
-- An unknown kind here is a CODING fault (kind only ever comes from mt5_t3_kind_v1), so it raises
-- a PLAIN exception — deliberately NOT 'MT4E1' — and escapes the decision RPC as a system fault.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_t3_allowed_actions_v1(p_kind text) returns text[]
language plpgsql immutable security definer set search_path = ''
as $fn$
begin
  case p_kind
    when 'ENTRY'    then return array['journal_add', 'already_logged', 'no_record']::text[];
    when 'CHANGE'   then return array['already_logged', 'no_record']::text[];
    when 'ABSENCE'  then return array['already_logged', 'no_record']::text[];
    when 'CONFLICT' then return array['no_record']::text[];
    else
      raise exception 'mt5_t3_allowed_actions_v1: unknown kind % (coding fault)', p_kind;
  end case;
end
$fn$;

-- ------------------------------------------------------------------------------------------------
-- Decision write RPC. The frozen Rev-3 order, verbatim:
--   1 argument/source validation   2 lock+reload capture, prove scope   3 load existing decision
--   4 same action -> idempotent replay      5 different action -> ERR_DECISION_CONFLICT
--   6 derive kind from stored evidence      7 apply the frozen matrix
--   8 ERR_ACTION_NOT_ALLOWED               9 insert immutable decision
--  10 uniqueness race -> ONE bounded reselect (same -> replay, different -> conflict, absent ->
--     ERR_DECISION_RACE). Race-resolved outcomes are shape-identical to their non-race
--     equivalents, o_derived_kind NULL.
--
-- o_derived_kind is non-NULL ONLY when THIS call derived eligibility fresh (first insert and
-- action-not-allowed). Replay/conflict deliberately do NOT re-evaluate policy over historical
-- decisions, so they return NULL — the RPC never pretends a kind was derived when it was not.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_record_capture_decision_v1(
  p_user uuid, p_capture_event_id uuid, p_action text, p_source text,
  p_tg_chat_id bigint default null, p_tg_message_id bigint default null
) returns table(o_ok boolean, o_inserted integer, o_decision_id uuid,
                o_existing_action text, o_derived_kind text, o_error_code text)
language plpgsql security definer set search_path = ''
as $fn$
declare
  v_row_user  uuid;
  v_payload   jsonb;
  v_ex_id     uuid;
  v_ex_action text;
  v_kind      text;
  v_allowed   text[];
  v_new_id    uuid;
begin
  -- 1 ---- argument types + source/provenance metadata --------------------------------------
  if p_user is null or p_capture_event_id is null then
    return query select false, 0, null::uuid, null::text, null::text, 'ERR_BAD_INPUT'; return;
  end if;
  if p_action is null
     or p_action not in ('journal_add', 'already_logged', 'no_record') then
    return query select false, 0, null::uuid, null::text, null::text, 'ERR_BAD_ACTION'; return;
  end if;
  if p_source is null or p_source not in ('telegram', 'harness')
     or (p_source = 'telegram'
         and (p_tg_chat_id is null or p_tg_message_id is null or p_tg_message_id <= 0))
     or (p_source = 'harness'
         and (p_tg_chat_id is not null or p_tg_message_id is not null)) then
    return query select false, 0, null::uuid, null::text, null::text, 'ERR_BAD_SOURCE'; return;
  end if;

  -- 2 ---- lock + reload the capture event; prove the requested scope ------------------------
  -- FOR UPDATE on the parent row serializes every concurrent decision attempt for this event;
  -- p_user is an equality ASSERTION against the persisted row, never a redirection.
  select ce.user_id, ce.payload into v_row_user, v_payload
    from public.mt5_capture_events ce
   where ce.id = p_capture_event_id
   for update;
  if not found then
    return query select false, 0, null::uuid, null::text, null::text, 'ERR_NOT_FOUND'; return;
  end if;
  if v_row_user is distinct from p_user then
    return query select false, 0, null::uuid, null::text, null::text, 'ERR_SCOPE'; return;
  end if;

  -- 3 ---- load any existing decision ---------------------------------------------------------
  select d.id, d.action into v_ex_id, v_ex_action
    from public.mt5_capture_decisions d
   where d.capture_event_id = p_capture_event_id;
  if found then
    -- 4/5 -- existing-decision precedence: a recorded terminal decision is durable workflow
    -- truth, senior to current policy. NO eligibility recomputation on either branch.
    if v_ex_action = p_action then
      return query select true, 0, v_ex_id, v_ex_action, null::text, null::text; return;
    end if;
    return query select false, 0, v_ex_id, v_ex_action, null::text,
                        'ERR_DECISION_CONFLICT'; return;
  end if;

  -- 6 ---- derive the T3 kind from the STORED evidence, never from the caller -----------------
  begin
    v_kind := public.mt5_t3_kind_v1(public.mt5_t3_event_types_v1(v_payload));
  exception
    when sqlstate 'MT4E1' then
      -- the ONLY translated SQLSTATE. Anything else escapes as a system fault.
      return query select false, 0, null::uuid, null::text, null::text,
                          'ERR_DECISION_EVIDENCE_INVALID'; return;
  end;

  -- 7/8 -- the frozen action matrix ------------------------------------------------------------
  v_allowed := public.mt5_t3_allowed_actions_v1(v_kind);
  if not (p_action = any (v_allowed)) then
    return query select false, 0, null::uuid, null::text, v_kind,
                        'ERR_ACTION_NOT_ALLOWED'; return;
  end if;

  -- 9 ---- append-once insert ------------------------------------------------------------------
  insert into public.mt5_capture_decisions(
      capture_event_id, action, source, telegram_chat_id, telegram_message_id)
  values (p_capture_event_id, p_action, p_source, p_tg_chat_id, p_tg_message_id)
  on conflict (capture_event_id) do nothing
  returning id into v_new_id;
  if v_new_id is not null then
    return query select true, 1, v_new_id, null::text, v_kind, null::text; return;
  end if;

  -- 10 --- bounded race reselect (defense in depth: the FOR UPDATE above already serializes
  -- callers, so this branch is reachable only by a writer that bypassed the RPC) --------------
  select d.id, d.action into v_ex_id, v_ex_action
    from public.mt5_capture_decisions d
   where d.capture_event_id = p_capture_event_id;
  if found then
    if v_ex_action = p_action then
      return query select true, 0, v_ex_id, v_ex_action, null::text, null::text; return;
    end if;
    return query select false, 0, v_ex_id, v_ex_action, null::text,
                        'ERR_DECISION_CONFLICT'; return;
  end if;
  return query select false, 0, null::uuid, null::text, null::text, 'ERR_DECISION_RACE';
end
$fn$;

-- ------------------------------------------------------------------------------------------------
-- Canonical pending read RPC. ONE SQL statement = ONE snapshot: the selected head and the count
-- can never disagree. o_capture_event is built from EXACTLY the 15 frozen capture columns —
-- never to_jsonb(row), never decision metadata — so the T3 renderer consumes it unchanged.
-- Pending = capture event with NO terminal decision (anti-join). FIFO: created_at ASC, id ASC.
-- The RPC returns the oldest pending row REGARDLESS of later renderability: a row the renderer
-- refuses is a blocking incident for the operator, never a server-side skip.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_next_pending_capture_v1(p_user uuid)
returns table(o_capture_event jsonb, o_pending_count bigint)
language plpgsql stable security definer set search_path = ''
as $fn$
begin
  if p_user is null then
    raise exception 'mt5_next_pending_capture_v1: p_user is required';
  end if;
  return query
  with pending as (
    select ce.*
      from public.mt5_capture_events ce
     where ce.user_id = p_user
       and not exists (select 1 from public.mt5_capture_decisions d
                        where d.capture_event_id = ce.id)
  )
  select (select jsonb_build_object(
              'id',                   p.id,
              'created_at',           p.created_at,
              'event_key',            p.event_key,
              'user_id',              p.user_id,
              'source_account',       p.source_account,
              'position_id',          p.position_id,
              'basis_run_id',         p.basis_run_id,
              'first_detection_at',   p.first_detection_at,
              'last_detection_at',    p.last_detection_at,
              'quiet_deadline',       p.quiet_deadline,
              'quiet_window_seconds', p.quiet_window_seconds,
              'detector_version',     p.detector_version,
              'aggregator_version',   p.aggregator_version,
              'payload',              p.payload,
              'payload_fingerprint',  p.payload_fingerprint)
            from pending p
           order by p.created_at asc, p.id asc
           limit 1),
         (select count(*) from pending);
end
$fn$;

-- ------------------------------------------------------------------------------------------------
-- Owners, ACLs. The two RPCs are service_role-only; the helpers and guard are owner-only.
-- ------------------------------------------------------------------------------------------------
alter function public.mt5_t3_event_types_v1(jsonb) owner to postgres;
alter function public.mt5_t3_kind_v1(text[]) owner to postgres;
alter function public.mt5_t3_allowed_actions_v1(text) owner to postgres;
alter function public.mt5_record_capture_decision_v1(uuid, uuid, text, text, bigint, bigint)
  owner to postgres;
alter function public.mt5_next_pending_capture_v1(uuid) owner to postgres;

revoke all on function public.mt5_t3_event_types_v1(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.mt5_t3_kind_v1(text[])
  from public, anon, authenticated, service_role;
revoke all on function public.mt5_t3_allowed_actions_v1(text)
  from public, anon, authenticated, service_role;
revoke all on function public.mt5_record_capture_decision_v1(uuid, uuid, text, text, bigint, bigint)
  from public, anon, authenticated, service_role;
revoke all on function public.mt5_next_pending_capture_v1(uuid)
  from public, anon, authenticated, service_role;

grant execute on function
  public.mt5_record_capture_decision_v1(uuid, uuid, text, text, bigint, bigint) to service_role;
grant execute on function public.mt5_next_pending_capture_v1(uuid) to service_role;

-- ------------------------------------------------------------------------------------------------
-- EMBEDDED FIXTURE PARITY — release-critical, runs INSIDE this transaction, BEFORE the ledger
-- insert. Generated from the single repository fixture authority
-- (ops/mt5_import/fixtures/t3_kind_fixtures_v1.json) by gen_t4a_fixture_sql.py --write; its
-- staleness is refused by gen_t4a_fixture_sql.py --check and test_t3_kind_fixture.py (byte
-- comparison against a fresh generation, never a hash-literal match). A parity failure here
-- aborts the whole packet: the RPC surface is never live-and-recorded unproven.
-- ------------------------------------------------------------------------------------------------
-- BEGIN GENERATED T4A T3 PARITY FIXTURE t3-kind-fixtures/1 sha256:85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355
-- Generated from ops/mt5_import/fixtures/t3_kind_fixtures_v1.json — DO NOT EDIT.
-- Regenerate + re-embed with: python -X utf8 ops/mt5_import/gen_t4a_fixture_sql.py --write
-- A valid case failing raises; an invalid case must raise SQLSTATE MT4E1.
do $t4a_fixture$
declare
  v_kind    text;
  v_actions text[];
begin
  -- entry_new
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_new: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_new: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_reappearance
  v_kind := public.mt5_t3_kind_v1(array['REAPPEARANCE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_reappearance: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_reappearance: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_new_increase
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_new_increase: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_new_increase: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_new_decrease
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_new_decrease: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_new_decrease: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_absence_then_reappearance
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'REAPPEARANCE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_absence_then_reappearance: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_absence_then_reappearance: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_change_absence_reappearance
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_DISAPPEARED', 'REAPPEARANCE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_change_absence_reappearance: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_change_absence_reappearance: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_full_life_reentry
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_INCREASE', 'POSITION_DISAPPEARED', 'REAPPEARANCE', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_full_life_reentry: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_full_life_reentry: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_reappearance_changes
  v_kind := public.mt5_t3_kind_v1(array['REAPPEARANCE', 'POSITION_INCREASE', 'POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_reappearance_changes: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_reappearance_changes: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- change_increase
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_increase: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_increase: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- change_decrease
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_decrease: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_decrease: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- change_mixed
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_DECREASE', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_mixed: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_mixed: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- change_double_decrease
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DECREASE', 'POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_double_decrease: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_double_decrease: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_terminal
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_terminal: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_terminal: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_after_new
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_after_new: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_after_new: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_after_increase
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_after_increase: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_after_increase: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_after_reentry
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'REAPPEARANCE', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_after_reentry: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_after_reentry: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_full_entry_life
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_INCREASE', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_full_entry_life: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_full_entry_life: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- conflict_alone
  v_kind := public.mt5_t3_kind_v1(array['POSITION_IDENTITY_CONFLICT']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_alone: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_alone: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_after_new
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_IDENTITY_CONFLICT']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_after_new: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_after_new: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_then_disappeared
  v_kind := public.mt5_t3_kind_v1(array['POSITION_IDENTITY_CONFLICT', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_then_disappeared: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_then_disappeared: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_between_changes
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_IDENTITY_CONFLICT', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_between_changes: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_between_changes: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_after_reentry
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'REAPPEARANCE', 'POSITION_IDENTITY_CONFLICT']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_after_reentry: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_after_reentry: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- invalid_empty (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array[]::text[]);
    raise exception 'T4A FIXTURE invalid_empty: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_new_while_present (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NEW_POSITION', 'NEW_POSITION']::text[]);
    raise exception 'T4A FIXTURE invalid_new_while_present: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_reappearance_while_present (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NEW_POSITION', 'REAPPEARANCE']::text[]);
    raise exception 'T4A FIXTURE invalid_reappearance_while_present: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_new_after_reappearance (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['REAPPEARANCE', 'NEW_POSITION']::text[]);
    raise exception 'T4A FIXTURE invalid_new_after_reappearance: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_new_after_absence (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'NEW_POSITION']::text[]);
    raise exception 'T4A FIXTURE invalid_new_after_absence: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_increase_after_absence (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'POSITION_INCREASE']::text[]);
    raise exception 'T4A FIXTURE invalid_increase_after_absence: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_double_disappearance (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'POSITION_DISAPPEARED']::text[]);
    raise exception 'T4A FIXTURE invalid_double_disappearance: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_conflict_after_absence (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'POSITION_IDENTITY_CONFLICT']::text[]);
    raise exception 'T4A FIXTURE invalid_conflict_after_absence: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_unknown_type (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NOT_A_TYPE']::text[]);
    raise exception 'T4A FIXTURE invalid_unknown_type: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_unknown_after_new (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NEW_POSITION', 'NOT_A_TYPE']::text[]);
    raise exception 'T4A FIXTURE invalid_unknown_after_new: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  raise notice 'T4A fixture verification: % valid + % invalid cases PASS (sha 85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355)', 22, 10;
end $t4a_fixture$;
-- END GENERATED T4A T3 PARITY FIXTURE t3-kind-fixtures/1 sha256:85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355

-- ------------------------------------------------------------------------------------------------
-- Postflight: the EXACT execute surface — service_role on the two RPCs, nothing else, nobody else.
-- ------------------------------------------------------------------------------------------------
do $t4a_rpc_post$
declare
  v_bad text;
begin
  select string_agg(distinct p.grantee || '->' || p.routine_name, ', ') into v_bad
    from information_schema.routine_privileges p
   where p.specific_schema = 'public'
     and p.routine_name in ('mt5_t3_event_types_v1', 'mt5_t3_kind_v1',
                            'mt5_t3_allowed_actions_v1', 'mt5_record_capture_decision_v1',
                            'mt5_next_pending_capture_v1')
     and p.grantee in ('PUBLIC', 'anon', 'authenticated')
     or (p.specific_schema = 'public' and p.grantee = 'service_role'
         and p.routine_name in ('mt5_t3_event_types_v1', 'mt5_t3_kind_v1',
                                'mt5_t3_allowed_actions_v1'));
  if v_bad is not null then
    raise exception 'MT5_T4A_RPC_POSTFLIGHT: unexpected function grant(s): %', v_bad;
  end if;
  if not exists (select 1 from information_schema.routine_privileges p
                  where p.specific_schema = 'public' and p.grantee = 'service_role'
                    and p.routine_name = 'mt5_record_capture_decision_v1') then
    raise exception 'MT5_T4A_RPC_POSTFLIGHT: service_role cannot execute the decision RPC';
  end if;
  if not exists (select 1 from information_schema.routine_privileges p
                  where p.specific_schema = 'public' and p.grantee = 'service_role'
                    and p.routine_name = 'mt5_next_pending_capture_v1') then
    raise exception 'MT5_T4A_RPC_POSTFLIGHT: service_role cannot execute the pending RPC';
  end if;
end $t4a_rpc_post$;

insert into public.mt5_schema_migrations(
  version, description, checksum, source_artifact_sha256, status, objects, applied_at, applied_by
) values (
  'mt5_t4a_decisions_rpc_v1',
  'T4A server-side T3 kind/action policy, decision write RPC and FIFO pending read RPC',
  -- packet identity token = sha256('mt5_t4a_decisions_rpc_v1|packet-revision-2')
  '3f4fbed1176f607b2697e0ea98c2a078d0e8dd8229b6505fd54c398561801853',
  -- canonical {version,cases} digest of ops/mt5_import/fixtures/t3_kind_fixtures_v1.json
  -- (ledger requires UPPERCASE hex for source_artifact_sha256)
  '85C076D09738D4F3189E54E2B33F6348ADA205304291FD59B4801A8F2E629355',
  'applied',
  jsonb_build_object(
    'packet_revision', '2',
    'evidence_sqlstate', 'MT4E1',
    'parity_fixture', jsonb_build_object(
      'version', 't3-kind-fixtures/1',
      'sha256', '85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355',
      'embedded_pre_commit', true),
    'functions', jsonb_build_array(
      'public.mt5_t3_event_types_v1(jsonb)',
      'public.mt5_t3_kind_v1(text[])',
      'public.mt5_t3_allowed_actions_v1(text)',
      'public.mt5_record_capture_decision_v1(uuid,uuid,text,text,bigint,bigint)',
      'public.mt5_next_pending_capture_v1(uuid)')
  ),
  now(),
  current_user
);

commit;
