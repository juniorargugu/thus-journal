-- ================================================================================================
-- T4A HUMAN DECISION LAYER — OFFLINE VERIFICATION PACKET
--
-- Executable test matrix for the decision RPC, the pending read RPC, immutability and provenance.
-- SEEDS SYNTHETIC ROWS (runs + capture events) as the superuser, so it is OFFLINE-ONLY: it
-- refuses to run unless the session opted in with
--     set t4a.offline_verify_ok = '1';
-- Production must never set that GUC. Run AFTER the schema packet and the rpc packet (which
-- runs the embedded fixture parity itself, pre-commit), in one psql session with
-- ON_ERROR_STOP=1.
--
-- Synthetic ids are fixed here so ordering tests are deterministic; nothing depends on
-- production UUID ordering. Terminology (frozen): "capture event row" / "decision row" /
-- "pending head" — never "first row".
-- ================================================================================================

do $g$ begin
  if coalesce(current_setting('t4a.offline_verify_ok', true), '') <> '1' then
    raise exception 'T4A VERIFICATION is OFFLINE-ONLY: set t4a.offline_verify_ok = ''1'' in a '
      'disposable database first';
  end if;
end $g$;

begin;

-- ------------------------------------------------------------------------------------------------
-- S1: seed helpers (pg_temp: gone with the session).
-- ------------------------------------------------------------------------------------------------
create function pg_temp.t4a_seed_run(p_id uuid, p_user uuid, p_acct text) returns void
language sql as $$
  insert into public.mt5_sync_runs(
    id, user_id, source_account, captured_at, snapshot_status, reconcile_status,
    snapshot_health, run_seq, previous_positions_count, positions_count,
    position_ids_hash, manifest_hash, policy_version, policy_thresholds,
    connector_version, lease_token, lease_expires_at, heartbeat_at, snapshot_completed_at,
    reconciled_at)
  values (
    p_id, p_user, p_acct, timestamptz '2026-08-20 10:00:00+00', 'complete', 'complete',
    'healthy', 1, 0, 1,
    repeat('a', 64), repeat('b', 64), 'seed-policy/1',
    jsonb_build_object('k', 3, 'susp_min_base', 5, 'susp_drop_ratio', 0.5,
                       'freshness_seconds', 900),
    'seed-connector/1', gen_random_uuid(),
    timestamptz '2026-08-20 11:00:00+00', timestamptz '2026-08-20 10:00:30+00',
    timestamptz '2026-08-20 10:00:45+00',
    timestamptz '2026-08-20 10:01:00+00');
$$;

create function pg_temp.t4a_seed_capture(
  p_id uuid, p_user uuid, p_acct text, p_run uuid, p_created timestamptz, p_types text[],
  p_payload_override jsonb default null) returns void
language sql as $$
  insert into public.mt5_capture_events(
    id, created_at, event_key, user_id, source_account, position_id, basis_run_id,
    first_detection_at, last_detection_at, quiet_deadline, quiet_window_seconds,
    detector_version, aggregator_version, payload, payload_fingerprint)
  values (
    p_id, p_created,
    encode(sha256(('key' || p_id::text)::bytea), 'hex'),
    p_user, p_acct, 555001, p_run,
    timestamptz '2026-08-24 15:00:00+00', timestamptz '2026-08-24 15:00:00+00',
    timestamptz '2026-08-24 15:15:00+00', 900,
    'seed-detector/1', 'seed-aggregator/1',
    coalesce(p_payload_override,
             jsonb_build_object(
               'event_types', to_jsonb(p_types),
               'detections',
               (select coalesce(jsonb_agg(jsonb_build_object('seed_ordinal', g)),
                                '[]'::jsonb)
                  from generate_series(1, coalesce(array_length(p_types, 1), 0)) g))),
    encode(sha256(('fp' || p_id::text)::bytea), 'hex'));
$$;

-- ------------------------------------------------------------------------------------------------
-- S2: seed scope. U1 = decision-matrix user; U2 = foreign-scope user; U3 = FIFO user;
--     U4 = id-tiebreak user.
-- ------------------------------------------------------------------------------------------------
do $seed$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  u2 constant uuid := '22222222-2222-4222-8222-222222222222';
  u3 constant uuid := '33333333-3333-4333-8333-333333333333';
  u4 constant uuid := '44444444-4444-4444-8444-444444444444';
  r1 constant uuid := 'aaaaaaaa-0000-4000-8000-00000000000a';
  r2 constant uuid := 'aaaaaaaa-0000-4000-8000-00000000000b';
  r3 constant uuid := 'aaaaaaaa-0000-4000-8000-00000000000c';
  r4 constant uuid := 'aaaaaaaa-0000-4000-8000-00000000000d';
  t0 constant timestamptz := timestamptz '2026-08-25 12:00:00+00';
begin
  perform pg_temp.t4a_seed_run(r1, u1, '1001');
  perform pg_temp.t4a_seed_run(r2, u2, '2002');
  perform pg_temp.t4a_seed_run(r3, u3, '3003');
  perform pg_temp.t4a_seed_run(r4, u4, '4004');

  -- U1 matrix captures (one per terminal decision the matrix will record, plus reusables)
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000001', u1, '1001', r1,
    t0, array['NEW_POSITION']);                                             -- ENTRY: journal_add
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000002', u1, '1001', r1,
    t0, array['NEW_POSITION']);                                             -- ENTRY: already_logged
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000003', u1, '1001', r1,
    t0, array['NEW_POSITION']);                                             -- ENTRY: no_record
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000004', u1, '1001', r1,
    t0, array['POSITION_INCREASE']);                                        -- CHANGE: already_logged
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000005', u1, '1001', r1,
    t0, array['POSITION_INCREASE', 'POSITION_DECREASE']);                   -- CHANGE: no_record
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000006', u1, '1001', r1,
    t0, array['POSITION_DISAPPEARED']);                                     -- ABSENCE: already_logged
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000007', u1, '1001', r1,
    t0, array['NEW_POSITION', 'POSITION_DISAPPEARED']);                     -- ABSENCE: no_record
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000008', u1, '1001', r1,
    t0, array['POSITION_IDENTITY_CONFLICT']);                               -- CONFLICT: no_record
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-000000000009', u1, '1001', r1,
    t0, array['NEW_POSITION', 'NEW_POSITION']);                             -- evidence-invalid
  perform pg_temp.t4a_seed_capture('cccccc01-0000-4000-8000-00000000000a', u1, '1001', r1,
    t0, array['NEW_POSITION'],
    jsonb_build_object('detections', '[]'::jsonb));                         -- evidence-shape-invalid

  -- U2 foreign-scope capture
  perform pg_temp.t4a_seed_capture('cccccc02-0000-4000-8000-000000000001', u2, '2002', r2,
    t0, array['NEW_POSITION']);

  -- U3 FIFO captures: CA older than CB
  perform pg_temp.t4a_seed_capture('cccccc03-0000-4000-8000-0000000000ca', u3, '3003', r3,
    t0, array['NEW_POSITION']);
  perform pg_temp.t4a_seed_capture('cccccc03-0000-4000-8000-0000000000cb', u3, '3003', r3,
    t0 + interval '1 minute', array['NEW_POSITION']);

  -- U4 tiebreak captures: SAME created_at, ordered ids
  perform pg_temp.t4a_seed_capture('cccccc04-0000-4000-8000-000000000001', u4, '4004', r4,
    t0, array['NEW_POSITION']);
  perform pg_temp.t4a_seed_capture('cccccc04-0000-4000-8000-000000000002', u4, '4004', r4,
    t0, array['NEW_POSITION']);
end $seed$;

-- ------------------------------------------------------------------------------------------------
-- S3: argument/source validation — every reject happens BEFORE any write.
-- ------------------------------------------------------------------------------------------------
do $s3$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  ce constant uuid := 'cccccc01-0000-4000-8000-000000000001';
  r  record;
begin
  select * into r from public.mt5_record_capture_decision_v1(null, ce, 'no_record', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, null::text, 'ERR_BAD_INPUT'::text) then
    raise exception 'S3 null user: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, null, 'no_record', 'harness');
  if r.o_error_code is distinct from 'ERR_BAD_INPUT' then
    raise exception 'S3 null capture: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'promote_now', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, null::text, 'ERR_BAD_ACTION'::text) then
    raise exception 'S3 bad action: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'no_record', 'web');
  if r.o_error_code is distinct from 'ERR_BAD_SOURCE' then
    raise exception 'S3 unknown source: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'no_record', 'telegram',
                                                             null, 77);
  if r.o_error_code is distinct from 'ERR_BAD_SOURCE' then
    raise exception 'S3 telegram without chat: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'no_record', 'telegram',
                                                             -100123, null);
  if r.o_error_code is distinct from 'ERR_BAD_SOURCE' then
    raise exception 'S3 telegram without message: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'no_record', 'telegram',
                                                             -100123, 0);
  if r.o_error_code is distinct from 'ERR_BAD_SOURCE' then
    raise exception 'S3 telegram message_id 0: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'no_record', 'harness',
                                                             -100123, null);
  if r.o_error_code is distinct from 'ERR_BAD_SOURCE' then
    raise exception 'S3 harness with chat: %', r; end if;
  if (select count(*) from public.mt5_capture_decisions) <> 0 then
    raise exception 'S3 wrote a decision row during argument rejection';
  end if;
  raise notice 'S3 argument/source validation: PASS';
end $s3$;

-- ------------------------------------------------------------------------------------------------
-- S4: scope proof — missing capture, foreign user.
-- ------------------------------------------------------------------------------------------------
do $s4$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  r  record;
begin
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'dddddddd-0000-4000-8000-00000000dead', 'no_record', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, null::text, 'ERR_NOT_FOUND'::text) then
    raise exception 'S4 missing capture: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc02-0000-4000-8000-000000000001', 'no_record', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, null::text, 'ERR_SCOPE'::text) then
    raise exception 'S4 foreign scope: %', r; end if;
  if (select count(*) from public.mt5_capture_decisions) <> 0 then
    raise exception 'S4 wrote a decision row during scope rejection';
  end if;
  raise notice 'S4 scope proof: PASS';
end $s4$;

-- ------------------------------------------------------------------------------------------------
-- S5: the frozen matrix REJECTS — derived kind is returned, nothing is written.
-- ------------------------------------------------------------------------------------------------
do $s5$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  r  record;
begin
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000004', 'journal_add', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, 'CHANGE'::text,
                            'ERR_ACTION_NOT_ALLOWED'::text) then
    raise exception 'S5 CHANGE journal_add: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000006', 'journal_add', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, 'ABSENCE'::text,
                            'ERR_ACTION_NOT_ALLOWED'::text) then
    raise exception 'S5 ABSENCE journal_add: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000008', 'journal_add', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, 'CONFLICT'::text,
                            'ERR_ACTION_NOT_ALLOWED'::text) then
    raise exception 'S5 CONFLICT journal_add: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000008', 'already_logged', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, 'CONFLICT'::text,
                            'ERR_ACTION_NOT_ALLOWED'::text) then
    raise exception 'S5 CONFLICT already_logged: %', r; end if;
  if (select count(*) from public.mt5_capture_decisions) <> 0 then
    raise exception 'S5 wrote a decision row during matrix rejection';
  end if;
  raise notice 'S5 action-matrix rejects: PASS';
end $s5$;

-- ------------------------------------------------------------------------------------------------
-- S6: evidence-invalid — the dedicated SQLSTATE is translated, and ONLY it.
-- ------------------------------------------------------------------------------------------------
do $s6$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  r  record;
begin
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000009', 'no_record', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, null::text,
                            'ERR_DECISION_EVIDENCE_INVALID'::text) then
    raise exception 'S6 continuity-invalid: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-00000000000a', 'no_record', 'harness');
  if r is distinct from row(false, 0, null::uuid, null::text, null::text,
                            'ERR_DECISION_EVIDENCE_INVALID'::text) then
    raise exception 'S6 shape-invalid: %', r; end if;
  if (select count(*) from public.mt5_capture_decisions) <> 0 then
    raise exception 'S6 wrote a decision row on invalid evidence';
  end if;
  raise notice 'S6 evidence-invalid translation: PASS';
end $s6$;

-- ------------------------------------------------------------------------------------------------
-- S7: first inserts across the whole ACCEPT matrix — full six-field shape each time.
-- ------------------------------------------------------------------------------------------------
do $s7$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  r  record;
begin
  -- ENTRY journal_add over telegram, with a NEGATIVE group chat id (allowed by contract)
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000001', 'journal_add', 'telegram', -1001234, 42);
  if not (r.o_ok and r.o_inserted = 1 and r.o_decision_id is not null
          and r.o_existing_action is null and r.o_derived_kind = 'ENTRY'
          and r.o_error_code is null) then
    raise exception 'S7 ENTRY journal_add: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000002', 'already_logged', 'harness');
  if not (r.o_ok and r.o_inserted = 1 and r.o_derived_kind = 'ENTRY') then
    raise exception 'S7 ENTRY already_logged: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000003', 'no_record', 'harness');
  if not (r.o_ok and r.o_inserted = 1 and r.o_derived_kind = 'ENTRY') then
    raise exception 'S7 ENTRY no_record: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000004', 'already_logged', 'harness');
  if not (r.o_ok and r.o_inserted = 1 and r.o_derived_kind = 'CHANGE') then
    raise exception 'S7 CHANGE already_logged: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000005', 'no_record', 'harness');
  if not (r.o_ok and r.o_inserted = 1 and r.o_derived_kind = 'CHANGE') then
    raise exception 'S7 CHANGE no_record: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000006', 'already_logged', 'harness');
  if not (r.o_ok and r.o_inserted = 1 and r.o_derived_kind = 'ABSENCE') then
    raise exception 'S7 ABSENCE already_logged: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000007', 'no_record', 'harness');
  if not (r.o_ok and r.o_inserted = 1 and r.o_derived_kind = 'ABSENCE') then
    raise exception 'S7 ABSENCE no_record: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, 'cccccc01-0000-4000-8000-000000000008', 'no_record', 'harness');
  if not (r.o_ok and r.o_inserted = 1 and r.o_derived_kind = 'CONFLICT') then
    raise exception 'S7 CONFLICT no_record: %', r; end if;
  if (select count(*) from public.mt5_capture_decisions) <> 8 then
    raise exception 'S7 expected exactly 8 decision rows';
  end if;
  raise notice 'S7 first-insert matrix: PASS (8 decisions)';
end $s7$;

-- ------------------------------------------------------------------------------------------------
-- S8: same-action replay — same id, inserted=0, derived_kind NULL, first-writer provenance
--     untouched from EVERY provenance (same message, another message, harness).
-- ------------------------------------------------------------------------------------------------
do $s8$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  ce constant uuid := 'cccccc01-0000-4000-8000-000000000001';
  before_row public.mt5_capture_decisions;
  after_row  public.mt5_capture_decisions;
  r  record;
begin
  select * into before_row from public.mt5_capture_decisions where capture_event_id = ce;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, ce, 'journal_add', 'telegram', -1001234, 42);
  if r is distinct from row(true, 0, before_row.id, 'journal_add'::text, null::text, null::text) then
    raise exception 'S8 replay same message: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(
    u1, ce, 'journal_add', 'telegram', 555, 4242);
  if r is distinct from row(true, 0, before_row.id, 'journal_add'::text, null::text, null::text) then
    raise exception 'S8 replay other message: %', r; end if;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'journal_add', 'harness');
  if r is distinct from row(true, 0, before_row.id, 'journal_add'::text, null::text, null::text) then
    raise exception 'S8 replay harness: %', r; end if;
  select * into after_row from public.mt5_capture_decisions where capture_event_id = ce;
  if after_row is distinct from before_row then
    raise exception 'S8 replay mutated the decision row: % -> %', before_row, after_row;
  end if;
  if after_row.source <> 'telegram' or after_row.telegram_chat_id <> -1001234
     or after_row.telegram_message_id <> 42 then
    raise exception 'S8 first-writer provenance is not intact: %', after_row;
  end if;
  if (select count(*) from public.mt5_capture_decisions) <> 8 then
    raise exception 'S8 replay changed the decision-row count';
  end if;
  raise notice 'S8 same-action replay + immutable provenance: PASS';
end $s8$;

-- ------------------------------------------------------------------------------------------------
-- S9: different-action conflict — existing id/action surfaced, nothing mutated.
-- ------------------------------------------------------------------------------------------------
do $s9$
declare
  u1 constant uuid := '11111111-1111-4111-8111-111111111111';
  ce constant uuid := 'cccccc01-0000-4000-8000-000000000001';
  ex uuid;
  r  record;
begin
  select id into ex from public.mt5_capture_decisions where capture_event_id = ce;
  select * into r from public.mt5_record_capture_decision_v1(u1, ce, 'no_record', 'harness');
  if r is distinct from row(false, 0, ex, 'journal_add'::text, null::text,
                            'ERR_DECISION_CONFLICT'::text) then
    raise exception 'S9 conflict: %', r; end if;
  if (select count(*) from public.mt5_capture_decisions) <> 8 then
    raise exception 'S9 conflict wrote or removed a row';
  end if;
  raise notice 'S9 different-action conflict: PASS';
end $s9$;

-- ------------------------------------------------------------------------------------------------
-- S10: immutability — UPDATE and DELETE are structurally refused.
-- ------------------------------------------------------------------------------------------------
do $s10$
declare
  ce constant uuid := 'cccccc01-0000-4000-8000-000000000001';
begin
  begin
    update public.mt5_capture_decisions set action = 'no_record' where capture_event_id = ce;
    raise exception 'S10 UPDATE was not refused';
  exception when raise_exception then
    if sqlerrm <> 'MT5_T4A_IMMUTABLE_ROW' then
      raise exception 'S10 UPDATE refused with the wrong error: %', sqlerrm;
    end if;
  end;
  begin
    delete from public.mt5_capture_decisions where capture_event_id = ce;
    raise exception 'S10 DELETE was not refused';
  exception when raise_exception then
    if sqlerrm <> 'MT5_T4A_IMMUTABLE_ROW' then
      raise exception 'S10 DELETE refused with the wrong error: %', sqlerrm;
    end if;
  end;
  raise notice 'S10 immutability guard: PASS';
end $s10$;

-- ------------------------------------------------------------------------------------------------
-- S11: pending read RPC — envelope, FIFO, anti-join advancement (frozen canary shape).
-- ------------------------------------------------------------------------------------------------
do $s11$
declare
  u3 constant uuid := '33333333-3333-4333-8333-333333333333';
  u_none constant uuid := '99999999-9999-4999-8999-999999999999';
  ca constant uuid := 'cccccc03-0000-4000-8000-0000000000ca';
  cb constant uuid := 'cccccc03-0000-4000-8000-0000000000cb';
  cap_before public.mt5_capture_events;
  cap_after  public.mt5_capture_events;
  env record;
  dec record;
  r   record;
begin
  -- zero-pending user
  select * into env from public.mt5_next_pending_capture_v1(u_none);
  if env.o_capture_event is not null or env.o_pending_count <> 0 then
    raise exception 'S11 zero-pending envelope: %', env; end if;

  -- two pending: head must be CA (older), count 2, and the object must carry EXACTLY the
  -- 15 frozen capture keys — no decision metadata.
  select * into env from public.mt5_next_pending_capture_v1(u3);
  if env.o_pending_count <> 2 then
    raise exception 'S11 pending_count expected 2: %', env.o_pending_count; end if;
  if (env.o_capture_event ->> 'id')::uuid is distinct from ca then
    raise exception 'S11 pending head expected capture CA: %', env.o_capture_event ->> 'id';
  end if;
  if (select count(*) from jsonb_object_keys(env.o_capture_event)) <> 15
     or not (env.o_capture_event ?& array[
       'id', 'created_at', 'event_key', 'user_id', 'source_account', 'position_id',
       'basis_run_id', 'first_detection_at', 'last_detection_at', 'quiet_deadline',
       'quiet_window_seconds', 'detector_version', 'aggregator_version', 'payload',
       'payload_fingerprint']) then
    raise exception 'S11 envelope keys are not exactly the frozen 15: %',
      (select array_agg(k order by k) from jsonb_object_keys(env.o_capture_event) k);
  end if;

  -- decide the head (genuine terminal decision), then the head must ADVANCE
  select * into cap_before from public.mt5_capture_events where id = ca;
  select * into r from public.mt5_record_capture_decision_v1(u3, ca, 'no_record', 'harness');
  if not (r.o_ok and r.o_inserted = 1) then raise exception 'S11 decide CA: %', r; end if;
  select * into env from public.mt5_next_pending_capture_v1(u3);
  if env.o_pending_count <> 1 or (env.o_capture_event ->> 'id')::uuid is distinct from cb then
    raise exception 'S11 after decision: count %, head % (expected 1, CB)',
      env.o_pending_count, env.o_capture_event ->> 'id';
  end if;

  -- same-action replay: pending unchanged, decision row count unchanged
  select * into dec from public.mt5_capture_decisions where capture_event_id = ca;
  select * into r from public.mt5_record_capture_decision_v1(u3, ca, 'no_record', 'harness');
  if not (r.o_ok and r.o_inserted = 0 and r.o_decision_id = dec.id) then
    raise exception 'S11 replay: %', r; end if;
  select * into env from public.mt5_next_pending_capture_v1(u3);
  if env.o_pending_count <> 1 or (env.o_capture_event ->> 'id')::uuid is distinct from cb then
    raise exception 'S11 replay moved the pending state'; end if;

  -- different-action conflict: pending unchanged
  select * into r from public.mt5_record_capture_decision_v1(u3, ca, 'already_logged', 'harness');
  if r.o_error_code is distinct from 'ERR_DECISION_CONFLICT' then
    raise exception 'S11 conflict: %', r; end if;
  select * into env from public.mt5_next_pending_capture_v1(u3);
  if env.o_pending_count <> 1 or (env.o_capture_event ->> 'id')::uuid is distinct from cb then
    raise exception 'S11 conflict moved the pending state'; end if;

  -- the capture event row is untouched by all of the above
  select * into cap_after from public.mt5_capture_events where id = ca;
  if cap_after is distinct from cap_before then
    raise exception 'S11 capture event row CA mutated';
  end if;
  raise notice 'S11 pending FIFO + advancement: PASS';
end $s11$;

-- ------------------------------------------------------------------------------------------------
-- S12: FIFO id tiebreak — equal created_at resolves by id ASC, deterministically.
-- ------------------------------------------------------------------------------------------------
do $s12$
declare
  u4 constant uuid := '44444444-4444-4444-8444-444444444444';
  env record;
begin
  select * into env from public.mt5_next_pending_capture_v1(u4);
  if env.o_pending_count <> 2
     or (env.o_capture_event ->> 'id') <> 'cccccc04-0000-4000-8000-000000000001' then
    raise exception 'S12 tiebreak head: % (count %)',
      env.o_capture_event ->> 'id', env.o_pending_count;
  end if;
  raise notice 'S12 (created_at, id) tiebreak: PASS';
end $s12$;

-- ------------------------------------------------------------------------------------------------
-- S13: the capture table gained no workflow state and lost nothing.
-- ------------------------------------------------------------------------------------------------
do $s13$
begin
  if (select count(*) from public.mt5_capture_events) <> 15 then
    raise exception 'S13 capture-event row count changed: %',
      (select count(*) from public.mt5_capture_events);
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'mt5_capture_events') <> 15 then
    raise exception 'S13 capture table column set changed';
  end if;
  raise notice 'S13 capture table untouched: PASS';
end $s13$;

commit;

do $done$ begin
  raise notice 'T4A OFFLINE VERIFICATION: ALL SECTIONS PASS';
end $done$;
