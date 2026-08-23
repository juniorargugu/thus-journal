-- ================================================================================================
-- MT5 T2 — CAPTURE EVENT PERSISTENCE, VERIFICATION PACKET
--
-- Status: EXECUTABLE DRAFT — read-mostly; every fixture write happens inside this transaction and
-- the packet ends in ROLLBACK, so nothing it inserts survives.
-- Packet revision: 5
--   revision 1: initial draft (Codex: CHANGES_REQUESTED).
--   revision 2: three adjacent completed runs plus a second account carrying a SUSPICIOUS
--               completed run, so run provenance and adjacency became executable.
--   revision 3: a third account whose position DISAPPEARS and comes back, so NEW vs REAPPEARANCE
--               is settled against real stored history; candidate-SET uniqueness; and the
--               complete quiet-window time invariant.
--   revision 4: the canonical identity wire format — UUID spelling aliases and position_id type
--               aliases, and the direct proof that an alias WOULD have minted a second
--               deterministic event key for one observation had it not been refused first.
--   revision 5: exact JSON type discipline for every identity-corresponding field, and the
--               source_account text contract: a JSON NUMBER that renders as the right account
--               string is refused everywhere it can appear, including when the whole candidate
--               is consistently numeric and nothing disagrees with anything.
--
-- Asserts the append-once / replay-safe / fail-closed contract against the INSTALLED objects.
-- Run AFTER T2_capture_events_schema_packet.sql and T2_capture_events_rpc_packet.sql.
--
-- NOT COVERED HERE, BY CONSTRUCTION
--   Concurrency (two sessions racing on one event_key) and rollback authority cannot be observed
--   from inside a single transaction that rolls back. Those are proved by separate disposable-DB
--   scripts; see the task report.
-- ================================================================================================

begin;

-- ------------------------------------------------------------------------------------------------
-- Test-only candidate builders. pg_temp is session-local and this transaction rolls back, so they
-- leave nothing behind. They exist so that several dozen fail-closed variants stay readable.
--
-- Every builder produces a TIME-COHERENT candidate by construction: first_detection_at IS the
-- first detection's instant, last_detection_at IS the last one's, and the deadline is derived
-- from the window. A test that wants to break one of those does so explicitly.
-- ------------------------------------------------------------------------------------------------

-- one detection carrying BOTH volumes: POSITION_INCREASE / POSITION_DECREASE
create function pg_temp.t2v_cand(
  p_user uuid, p_account text, p_pos bigint, p_etype text,
  p_before uuid, p_after uuid, p_bseq integer, p_aseq integer,
  p_bvol numeric, p_avol numeric, p_basis uuid,
  p_symbol text default 'DELTAU26', p_side text default 'buy',
  p_at   text default '2026-08-23T09:00:00.000000Z',
  p_dead text default '2026-08-23T09:05:00.000000Z',
  p_win  numeric default 300.0
) returns jsonb language sql as $cand$
  select jsonb_build_object(
    'domain','mt5.t2.capture/1',
    'user_id', p_user::text,
    'source_account', p_account,
    'position_id', p_pos,
    'basis_run_id', p_basis::text,
    'first_detection_at', p_at,
    'last_detection_at', p_at,
    'quiet_deadline', p_dead,
    'quiet_window_seconds', p_win,
    'detector_version','t1-detector/0.1',
    'aggregator_version','t2-quiet-window/0.1',
    'detection_identities', jsonb_build_array(
      jsonb_build_array(p_user::text, p_account, p_etype, p_pos, p_before::text, p_after::text)),
    'event_types', jsonb_build_array(p_etype),
    'run_references', jsonb_build_array(jsonb_build_object(
      'before_run_id', p_before::text, 'after_run_id', p_after::text,
      'before_run_seq', p_bseq, 'after_run_seq', p_aseq)),
    'detections', jsonb_build_array(jsonb_build_object(
      'event_type', p_etype, 'position_id', p_pos,
      'before_run_id', p_before::text, 'after_run_id', p_after::text,
      'before_run_seq', p_bseq, 'after_run_seq', p_aseq,
      'user_id', p_user::text, 'source_account', p_account,
      'symbol_raw', p_symbol, 'side', p_side,
      'before_volume', p_bvol, 'after_volume', p_avol,
      'detected_at', p_at)))
$cand$;

-- one detection carrying ONE volume: NEW_POSITION / REAPPEARANCE (after) or DISAPPEARED (before)
create function pg_temp.t2v_cand1(
  p_user uuid, p_account text, p_pos bigint, p_etype text,
  p_before uuid, p_after uuid, p_bseq integer, p_aseq integer,
  p_vol numeric, p_basis uuid,
  p_symbol text default 'S50U26', p_side text default 'buy',
  p_at   text default '2026-08-23T09:00:00.000000Z',
  p_dead text default '2026-08-23T09:05:00.000000Z',
  p_win  numeric default 300.0
) returns jsonb language sql as $cand1$
  select jsonb_build_object(
    'domain','mt5.t2.capture/1',
    'user_id', p_user::text,
    'source_account', p_account,
    'position_id', p_pos,
    'basis_run_id', p_basis::text,
    'first_detection_at', p_at,
    'last_detection_at', p_at,
    'quiet_deadline', p_dead,
    'quiet_window_seconds', p_win,
    'detector_version','t1-detector/0.1',
    'aggregator_version','t2-quiet-window/0.1',
    'detection_identities', jsonb_build_array(
      jsonb_build_array(p_user::text, p_account, p_etype, p_pos, p_before::text, p_after::text)),
    'event_types', jsonb_build_array(p_etype),
    'run_references', jsonb_build_array(jsonb_build_object(
      'before_run_id', p_before::text, 'after_run_id', p_after::text,
      'before_run_seq', p_bseq, 'after_run_seq', p_aseq)),
    'detections', jsonb_build_array(
      jsonb_build_object(
        'event_type', p_etype, 'position_id', p_pos,
        'before_run_id', p_before::text, 'after_run_id', p_after::text,
        'before_run_seq', p_bseq, 'after_run_seq', p_aseq,
        'user_id', p_user::text, 'source_account', p_account,
        'symbol_raw', p_symbol, 'side', p_side,
        'detected_at', p_at)
      || case when p_etype = 'POSITION_DISAPPEARED'
              then jsonb_build_object('before_volume', p_vol)
              else jsonb_build_object('after_volume', p_vol) end))
$cand1$;

-- a candidate assembled from complete detection objects; the parallel arrays are DERIVED from
-- them, so a test that wants them misaligned has to misalign them on purpose
create function pg_temp.t2v_multi(
  p_user uuid, p_account text, p_pos bigint, p_basis uuid, p_dets jsonb,
  p_first text, p_last text, p_dead text, p_win numeric default 300.0
) returns jsonb language sql as $multi$
  select jsonb_build_object(
    'domain','mt5.t2.capture/1',
    'user_id', p_user::text, 'source_account', p_account,
    'position_id', p_pos, 'basis_run_id', p_basis::text,
    'first_detection_at', p_first, 'last_detection_at', p_last,
    'quiet_deadline', p_dead, 'quiet_window_seconds', p_win,
    'detector_version','t1-detector/0.1', 'aggregator_version','t2-quiet-window/0.1',
    'detection_identities', (select jsonb_agg(jsonb_build_array(
        d ->> 'user_id', d ->> 'source_account', d ->> 'event_type', (d ->> 'position_id')::bigint,
        d ->> 'before_run_id', d ->> 'after_run_id') order by ord)
       from jsonb_array_elements(p_dets) with ordinality as t(d, ord)),
    'event_types', (select jsonb_agg(d ->> 'event_type' order by ord)
       from jsonb_array_elements(p_dets) with ordinality as t(d, ord)),
    'run_references', (select jsonb_agg(jsonb_build_object(
        'before_run_id', d ->> 'before_run_id', 'after_run_id', d ->> 'after_run_id',
        'before_run_seq', (d ->> 'before_run_seq')::integer,
        'after_run_seq', (d ->> 'after_run_seq')::integer) order by ord)
       from jsonb_array_elements(p_dets) with ordinality as t(d, ord)),
    'detections', p_dets)
$multi$;

do $t2_verify$
declare
  v_pass      integer := 0;
  v_fail      integer := 0;
  v_user      uuid := extensions.gen_random_uuid();
  v_account   text := 'T2VERIFY-901';
  v_account2  text := 'T2VERIFY-902';
  v_account3  text := 'T2VERIFY-903';
  -- 904's account NAME is numeric-looking on purpose: the JSON number 301102520 renders to
  -- exactly this text, so the scope comparison cannot tell them apart and the type rule is the
  -- only thing left that can.
  v_account4  text := '301102520';
  v_pos       bigint := 306676142;
  v_pos2      bigint := 400000001;
  v_nn        bigint := 600000001;      -- lives in the numeric-looking account
  v_p         bigint := 500000001;      -- disappears and comes back
  v_q         bigint := 500000002;      -- genuinely new, later
  v_run_a     uuid;
  v_run_b     uuid;
  v_run_c     uuid;
  v_run_d     uuid;
  v_started   uuid;
  v_s1        uuid;
  v_s2        uuid;
  v_s3        uuid;
  v_w1        uuid;
  v_w2        uuid;
  v_w3        uuid;
  v_n1        uuid;
  v_n2        uuid;
  v_lease     uuid;
  v_candidate jsonb;
  v_two       jsonb;
  v_ncand     jsonb;
  v_variant   jsonb;
  v_d_ab      jsonb;
  v_d_bc      jsonb;
  v_d_cd      jsonb;
  v_ok        boolean;
  v_ins       integer;
  v_id        uuid;
  v_id2       uuid;
  v_key       text;
  v_key2      text;
  v_err       text;
  v_txt       text;
  v_forbidden text;
  v_all_ok    boolean;

  function_missing boolean;

  -- one assertion
  procedure_note text;
begin
  create temporary table if not exists t2_v(res text, label text) on commit drop;

  -- ---- V1: objects exist with the expected shape ------------------------------------------
  if to_regclass('public.mt5_capture_events') is not null then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V1 table exists');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V1 table exists');
  end if;

  select not exists (select 1 from pg_catalog.pg_proc p
                       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                      where n.nspname='public' and p.proname='mt5_append_capture_event_v1')
    into function_missing;
  if function_missing then
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V2 append RPC exists');
  else
    v_pass := v_pass + 1; insert into t2_v values('PASS','V2 append RPC exists');
  end if;

  -- ---- V3: RLS on, no application write grant, no column ACL ------------------------------
  if exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n
                  on n.oid=c.relnamespace
              where n.nspname='public' and c.relname='mt5_capture_events' and c.relrowsecurity)
     and not exists (select 1 from information_schema.table_privileges
                      where table_schema='public' and table_name='mt5_capture_events'
                        and (grantee in ('anon','authenticated','PUBLIC')
                             or (grantee='service_role' and privilege_type<>'SELECT')))
     and not exists (select 1 from pg_catalog.pg_attribute a
                      where a.attrelid='public.mt5_capture_events'::regclass
                        and a.attnum>0 and not a.attisdropped and a.attacl is not null) then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V3 RLS on, SELECT-only service_role, no column ACL');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V3 RLS on, SELECT-only service_role, no column ACL');
  end if;

  -- ---- V4: no UPDATE/DELETE RPC exists at all ---------------------------------------------
  if not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n
                      on n.oid=p.pronamespace
                  where n.nspname='public'
                    and p.proname ~ 'capture'
                    and p.proname ~ '(update|delete|dismiss|promote|skip|correct)') then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V4 no update/delete/promote capture RPC');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V4 no update/delete/promote capture RPC');
  end if;

  -- ---- V4b: the basis FK is the COMPOSITE run-scope FK, not an id-only FK ------------------
  select pg_catalog.pg_get_constraintdef(c.oid) into v_txt
    from pg_catalog.pg_constraint c
   where c.conrelid='public.mt5_capture_events'::regclass
     and c.conname='mt5_capture_events_basis_run_fk';
  if v_txt like 'FOREIGN KEY (basis_run_id, user_id, source_account) REFERENCES mt5_sync_runs(id, user_id, source_account)%' then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V4b basis_run FK is the composite run-scope FK');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V4b basis_run FK is the composite run-scope FK: '||coalesce(v_txt,'<missing>'));
  end if;

  -- ================================================================================
  -- FIXTURE — built through the REAL S1 RPCs, so it cannot drift from how a run
  -- actually comes to exist and cannot fight S1's shape constraints.
  --
  -- 901: a(seq1, pos vol 2) -> b(seq2, vol 4) -> c(seq3, vol 6), all complete+healthy,
  --      plus one run left 'started'.
  -- 902: s1(seq1, 3 positions) -> s2(seq2, 0 positions => SUSPICIOUS) -> s3(seq3, 3).
  -- 903: w1(seq1, [P]) -> w2(seq2, []) -> w3(seq3, [P, Q]).
  --      P disappears and comes back; Q appears for the first time in w3.
  -- ================================================================================
  v_run_a := extensions.gen_random_uuid();
  v_run_b := extensions.gen_random_uuid();
  v_run_c := extensions.gen_random_uuid();
  v_run_d := extensions.gen_random_uuid();
  v_started := extensions.gen_random_uuid();
  v_s1 := extensions.gen_random_uuid();
  v_s2 := extensions.gen_random_uuid();
  v_s3 := extensions.gen_random_uuid();
  v_w1 := extensions.gen_random_uuid();
  v_w2 := extensions.gen_random_uuid();
  v_w3 := extensions.gen_random_uuid();
  v_n1 := extensions.gen_random_uuid();
  v_n2 := extensions.gen_random_uuid();

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_run_a, v_user, v_account, v_lease, 300,
    now() - interval '30 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_run_a, v_user, v_account, v_lease,
    jsonb_build_array(jsonb_build_object(
      'position_id', v_pos, 'symbol_raw','DELTAU26','side','buy','volume',2.0,
      'price_open',310.0,'price_current',262.59,'profit',-94820.0,
      'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300090,
      'contract_size',1000.0)));
  perform public.mt5_complete_snapshot_v1(v_run_a, v_user, v_account, v_lease, 1,
    array[v_pos]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_run_a, v_user, v_account, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_run_b, v_user, v_account, v_lease, 300,
    now() - interval '20 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_run_b, v_user, v_account, v_lease,
    jsonb_build_array(jsonb_build_object(
      'position_id', v_pos, 'symbol_raw','DELTAU26','side','buy','volume',4.0,
      'price_open',310.0,'price_current',262.59,'profit',-94820.0,
      'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300090,
      'contract_size',1000.0)));
  perform public.mt5_complete_snapshot_v1(v_run_b, v_user, v_account, v_lease, 1,
    array[v_pos]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_run_b, v_user, v_account, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_run_c, v_user, v_account, v_lease, 300,
    now() - interval '10 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_run_c, v_user, v_account, v_lease,
    jsonb_build_array(jsonb_build_object(
      'position_id', v_pos, 'symbol_raw','DELTAU26','side','buy','volume',6.0,
      'price_open',310.0,'price_current',262.59,'profit',-94820.0,
      'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300090,
      'contract_size',1000.0)));
  perform public.mt5_complete_snapshot_v1(v_run_c, v_user, v_account, v_lease, 1,
    array[v_pos]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_run_c, v_user, v_account, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_run_d, v_user, v_account, v_lease, 300,
    now() - interval '5 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_run_d, v_user, v_account, v_lease,
    jsonb_build_array(jsonb_build_object(
      'position_id', v_pos, 'symbol_raw','DELTAU26','side','buy','volume',8.0,
      'price_open',310.0,'price_current',262.59,'profit',-94820.0,
      'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300090,
      'contract_size',1000.0)));
  perform public.mt5_complete_snapshot_v1(v_run_d, v_user, v_account, v_lease, 1,
    array[v_pos]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_run_d, v_user, v_account, v_lease);

  perform public.mt5_create_run_v1(v_started, v_user, v_account,
    extensions.gen_random_uuid(), 300, now() - interval '2 minutes',
    's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');

  -- 902
  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_s1, v_user, v_account2, v_lease, 300,
    now() - interval '30 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_s1, v_user, v_account2, v_lease,
    jsonb_build_array(
      jsonb_build_object('position_id', v_pos2, 'symbol_raw','S50U26','side','buy','volume',1.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300090),
      jsonb_build_object('position_id', v_pos2+1, 'symbol_raw','S50U26','side','buy','volume',1.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300091),
      jsonb_build_object('position_id', v_pos2+2, 'symbol_raw','S50U26','side','buy','volume',1.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300092)));
  perform public.mt5_complete_snapshot_v1(v_s1, v_user, v_account2, v_lease, 3,
    array[v_pos2, v_pos2+1, v_pos2+2]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_s1, v_user, v_account2, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_s2, v_user, v_account2, v_lease, 300,
    now() - interval '20 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_complete_snapshot_v1(v_s2, v_user, v_account2, v_lease, 0,
    array[]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_s2, v_user, v_account2, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_s3, v_user, v_account2, v_lease, 300,
    now() - interval '10 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_s3, v_user, v_account2, v_lease,
    jsonb_build_array(
      jsonb_build_object('position_id', v_pos2, 'symbol_raw','S50U26','side','buy','volume',1.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300190),
      jsonb_build_object('position_id', v_pos2+1, 'symbol_raw','S50U26','side','buy','volume',1.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300191),
      jsonb_build_object('position_id', v_pos2+2, 'symbol_raw','S50U26','side','buy','volume',1.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300192)));
  perform public.mt5_complete_snapshot_v1(v_s3, v_user, v_account2, v_lease, 3,
    array[v_pos2, v_pos2+1, v_pos2+2]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_s3, v_user, v_account2, v_lease);

  -- 903: the history that decides NEW vs REAPPEARANCE
  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_w1, v_user, v_account3, v_lease, 300,
    now() - interval '30 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_w1, v_user, v_account3, v_lease,
    jsonb_build_array(jsonb_build_object(
      'position_id', v_p, 'symbol_raw','S50U26','side','buy','volume',1.0,
      'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300500)));
  perform public.mt5_complete_snapshot_v1(v_w1, v_user, v_account3, v_lease, 1,
    array[v_p]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_w1, v_user, v_account3, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_w2, v_user, v_account3, v_lease, 300,
    now() - interval '20 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_complete_snapshot_v1(v_w2, v_user, v_account3, v_lease, 0,
    array[]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_w2, v_user, v_account3, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_w3, v_user, v_account3, v_lease, 300,
    now() - interval '10 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_w3, v_user, v_account3, v_lease,
    jsonb_build_array(
      jsonb_build_object('position_id', v_p, 'symbol_raw','S50U26','side','buy','volume',1.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300600),
      jsonb_build_object('position_id', v_q, 'symbol_raw','S50U26','side','buy','volume',2.0,
        'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300601)));
  perform public.mt5_complete_snapshot_v1(v_w3, v_user, v_account3, v_lease, 2,
    array[v_p, v_q]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_w3, v_user, v_account3, v_lease);

  -- 904: two adjacent healthy runs in an account whose name is all digits
  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_n1, v_user, v_account4, v_lease, 300,
    now() - interval '30 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_n1, v_user, v_account4, v_lease,
    jsonb_build_array(jsonb_build_object(
      'position_id', v_nn, 'symbol_raw','S50U26','side','buy','volume',2.0,
      'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300700)));
  perform public.mt5_complete_snapshot_v1(v_n1, v_user, v_account4, v_lease, 1,
    array[v_nn]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_n1, v_user, v_account4, v_lease);

  v_lease := extensions.gen_random_uuid();
  perform public.mt5_create_run_v1(v_n2, v_user, v_account4, v_lease, 300,
    now() - interval '20 minutes', 's1-oneshot/0.1', 6090, 'PiSecurities-Live', 's1.v1');
  perform public.mt5_append_run_positions_v1(v_n2, v_user, v_account4, v_lease,
    jsonb_build_array(jsonb_build_object(
      'position_id', v_nn, 'symbol_raw','S50U26','side','buy','volume',4.0,
      'open_time_utc','2026-07-14T02:45:00Z','source_time_msc',1784022300701)));
  perform public.mt5_complete_snapshot_v1(v_n2, v_user, v_account4, v_lease, 1,
    array[v_nn]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_n2, v_user, v_account4, v_lease);

  -- `is distinct from` (not `<>`) so a run that failed to be created reads as a MISMATCH rather
  -- than NULL — a NULL here would silently disable the guard.
  if (select snapshot_status||'/'||snapshot_health||'/'||run_seq
        from public.mt5_sync_runs where id=v_run_a) is distinct from 'complete/healthy/1'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_run_b) is distinct from 'complete/healthy/2'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_run_c) is distinct from 'complete/healthy/3'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_run_d) is distinct from 'complete/healthy/4'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_n1) is distinct from 'complete/healthy/1'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_n2) is distinct from 'complete/healthy/2'
     or (select snapshot_status from public.mt5_sync_runs where id=v_started)
          is distinct from 'started'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_s1) is distinct from 'complete/healthy/1'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_s2) is distinct from 'complete/suspicious/2'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_s3) is distinct from 'complete/healthy/3'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_w1) is distinct from 'complete/healthy/1'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_w2) is distinct from 'complete/healthy/2'
     or (select snapshot_status||'/'||snapshot_health||'/'||run_seq
           from public.mt5_sync_runs where id=v_w3) is distinct from 'complete/healthy/3' then
    raise exception 'MT5_T2_VERIFICATION: fixture runs are not in the expected states';
  end if;
  if (select count(*) from public.mt5_sync_run_positions
       where run_id = v_w3 and position_id in (v_p, v_q)) <> 2
     or exists (select 1 from public.mt5_sync_run_positions where run_id = v_w2) then
    raise exception 'MT5_T2_VERIFICATION: the 903 membership fixture is not as expected';
  end if;

  -- the canonical valid candidate: POSITION_INCREASE 2.0 -> 4.0 across the adjacent pair a,b
  v_candidate := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                  v_run_a, v_run_b, 1, 2, 2.0, 4.0, v_run_b);

  -- ---- V5: first insert -------------------------------------------------------------------
  select o_ok,o_inserted,o_event_id,o_event_key,o_error_code
    into v_ok,v_ins,v_id,v_key,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account, v_candidate);
  if v_ok and v_ins = 1 and v_id is not null and v_key ~ '^[0-9a-f]{64}$' and v_err is null then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V5 first append inserts exactly one row');
  else
    v_fail := v_fail + 1;
    insert into t2_v values('FAIL','V5 first append inserts exactly one row: ok='||coalesce(v_ok::text,'?')
      ||' ins='||coalesce(v_ins::text,'?')||' err='||coalesce(v_err,'-'));
  end if;

  -- ---- V6: exact replay -> same id, inserted 0 --------------------------------------------
  select o_ok,o_inserted,o_event_id,o_event_key,o_error_code
    into v_ok,v_ins,v_id2,v_key2,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account, v_candidate);
  if v_ok and v_ins = 0 and v_id2 = v_id and v_key2 = v_key and v_err is null
     and (select count(*) from public.mt5_capture_events where event_key = v_key) = 1 then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V6 exact replay returns the SAME id, inserted=0, still one row');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V6 exact replay returns the SAME id, inserted=0, still one row');
  end if;

  -- ---- V7: same key + different payload -> hard conflict, nothing written -----------------
  v_variant := jsonb_set(v_candidate, '{detector_version}', '"t1-detector/0.2"'::jsonb);
  select o_ok,o_inserted,o_event_key,o_error_code into v_ok,v_ins,v_key2,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  select payload_fingerprint into v_txt from public.mt5_capture_events where event_key = v_key;
  if (not v_ok) and v_ins = 0 and v_err = 'ERR_CAPTURE_CONFLICT' and v_key2 = v_key
     and (select count(*) from public.mt5_capture_events where event_key = v_key) = 1
     and v_txt = (select payload_fingerprint from public.mt5_capture_events where id = v_id) then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V7 same key + changed payload = ERR_CAPTURE_CONFLICT, row untouched');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V7 same key + changed payload = ERR_CAPTURE_CONFLICT, row untouched: err='||coalesce(v_err,'-'));
  end if;

  -- ---- V8: contradictory event semantics is an expected REJECTION -------------------------
  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_DECREASE',
                                v_run_a, v_run_b, 1, 2, 2.0, 4.0, v_run_b);
  select o_ok,o_inserted,o_error_code into v_ok,v_ins,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if (not v_ok) and v_ins = 0 and v_err = 'ERR_CAPTURE_DETECTION' then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V8 DECREASE claiming 2.0 -> 4.0 is REJECTED (contradictory evidence)');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V8 DECREASE claiming 2.0 -> 4.0 is REJECTED: err='||coalesce(v_err,'-'));
  end if;

  -- ---- V8b: a genuinely different detection set -> a different event, new row -------------
  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_b, v_run_c, 2, 3, 4.0, 6.0, v_run_c);
  select o_ok,o_inserted,o_event_key,o_error_code into v_ok,v_ins,v_key2,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_ok and v_ins = 1 and v_key2 <> v_key and v_err is null then
    v_pass := v_pass + 1; insert into t2_v values('PASS','V8b different detection set -> different event_key, new row');
  else
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V8b different detection set -> different event_key, new row: err='||coalesce(v_err,'-'));
  end if;

  -- ---- V9 / V10: stored evidence is IMMUTABLE ---------------------------------------------
  begin
    update public.mt5_capture_events set payload = '{}'::jsonb where id = v_id;
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V9 UPDATE is refused');
  exception when others then
    if sqlerrm like '%MT5_T2_IMMUTABLE_ROW%' then
      v_pass := v_pass + 1; insert into t2_v values('PASS','V9 UPDATE is refused (MT5_T2_IMMUTABLE_ROW)');
    else
      v_fail := v_fail + 1; insert into t2_v values('FAIL','V9 UPDATE refused with the WRONG error: '||sqlerrm);
    end if;
  end;
  begin
    delete from public.mt5_capture_events where id = v_id;
    v_fail := v_fail + 1; insert into t2_v values('FAIL','V10 DELETE is refused');
  exception when others then
    if sqlerrm like '%MT5_T2_IMMUTABLE_ROW%' then
      v_pass := v_pass + 1; insert into t2_v values('PASS','V10 DELETE is refused (MT5_T2_IMMUTABLE_ROW)');
    else
      v_fail := v_fail + 1; insert into t2_v values('FAIL','V10 DELETE refused with the WRONG error: '||sqlerrm);
    end if;
  end;

  -- ---- V11..V17: fail-closed validation ---------------------------------------------------
  select o_error_code into v_err from public.mt5_append_capture_event_v1(
    extensions.gen_random_uuid(), v_account, v_candidate);
  if v_err = 'ERR_CAPTURE_SCOPE' then v_pass := v_pass+1; insert into t2_v values('PASS','V11 caller/payload user mismatch refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V11 caller/payload user mismatch refused: '||coalesce(v_err,'-')); end if;

  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_a, v_started, 1, 2, 2.0, 4.0, v_started);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_BASIS_RUN_NOT_COMPLETE' then v_pass := v_pass+1; insert into t2_v values('PASS','V12 non-completed basis run refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V12 non-completed basis run refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{basis_run_id}', to_jsonb(v_run_a::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_BASIS_MISMATCH' then v_pass := v_pass+1; insert into t2_v values('PASS','V13 basis_run_id != final after_run_id refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V13 basis_run_id != final after_run_id refused: '||coalesce(v_err,'-')); end if;

  select o_error_code into v_err from public.mt5_append_capture_event_v1(
    v_user, v_account, v_candidate || '{"promoted":true}'::jsonb);
  if v_err = 'ERR_CAPTURE_PAYLOAD_KEYS' then v_pass := v_pass+1; insert into t2_v values('PASS','V14 top-level human-decision key in payload refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V14 top-level human-decision key in payload refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{detections,0}',
                 (v_candidate -> 'detections' -> 0) || '{"equity": 123456.0}'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_FORBIDDEN_FIELD' then v_pass := v_pass+1; insert into t2_v values('PASS','V14b NESTED forbidden field refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V14b NESTED forbidden field refused: '||coalesce(v_err,'-')); end if;

  v_all_ok := true;
  foreach v_forbidden in array array['skipped','promoted','ignored','dismissed','confirmed',
                                     'decision','decision_state','journal_trade_id',
                                     'materialized_trade_id','equity','balance','account_equity',
                                     'account_balance','currency','equity_quality',
                                     'balance_quality','margin','profit_total'] loop
    v_variant := jsonb_set(v_candidate, '{run_references,0}',
                   (v_candidate -> 'run_references' -> 0)
                     || jsonb_build_object(v_forbidden, 'x'));
    select o_error_code into v_err
      from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
    if v_err is distinct from 'ERR_CAPTURE_FORBIDDEN_FIELD' then
      v_all_ok := false;
      insert into t2_v values('FAIL','V14c nested "'||v_forbidden||'" refused: '||coalesce(v_err,'-'));
    end if;
  end loop;
  if v_all_ok then
    v_pass := v_pass+1; insert into t2_v values('PASS','V14c every forbidden vocabulary key is refused when NESTED');
  else
    v_fail := v_fail+1;
  end if;

  v_variant := jsonb_set(v_candidate, '{quiet_deadline}', '"2026-08-23T09:30:00.000000Z"'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_WINDOW_MISMATCH' then v_pass := v_pass+1; insert into t2_v values('PASS','V15 deadline not derived from the window refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V15 deadline not derived from the window refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{event_types,0}', '"POSITION_DECREASE"'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PROVENANCE' then v_pass := v_pass+1; insert into t2_v values('PASS','V16 event_types disagreeing with identities refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V16 event_types disagreeing with identities refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{detection_identities,0,3}', '999'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_IDENTITY' then v_pass := v_pass+1; insert into t2_v values('PASS','V17 identity for another position refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V17 identity for another position refused: '||coalesce(v_err,'-')); end if;

  -- ---- V18 / V19 / V20 / V21 ---------------------------------------------------------------
  select payload::text into v_txt from public.mt5_capture_events where id = v_id;
  if v_txt !~* '"(equity|balance|currency|equity_quality|balance_quality|margin|profit_total)"'
     and v_txt !~* '"(skipped|promoted|ignored|dismissed|confirmed|decision|decision_state|journal_trade_id|materialized_trade_id)"' then
    v_pass := v_pass+1; insert into t2_v values('PASS','V18 stored payload has no account facts and no decision state');
  else
    v_fail := v_fail+1; insert into t2_v values('FAIL','V18 stored payload has no account facts and no decision state');
  end if;

  if (select basis_run_id from public.mt5_capture_events where id = v_id) = v_run_b
     and (select payload -> 'run_references' -> 0 ->> 'before_run_id'
            from public.mt5_capture_events where id = v_id) = v_run_a::text
     and (select payload -> 'run_references' -> 0 ->> 'after_run_id'
            from public.mt5_capture_events where id = v_id) = v_run_b::text
     and (select jsonb_array_length(payload -> 'detection_identities')
            from public.mt5_capture_events where id = v_id) = 1 then
    v_pass := v_pass+1; insert into t2_v values('PASS','V19 basis_run_id and full before/after provenance preserved');
  else
    v_fail := v_fail+1; insert into t2_v values('FAIL','V19 basis_run_id and full before/after provenance preserved');
  end if;

  v_two := jsonb_build_object('detection_identities', jsonb_build_array(
      jsonb_build_array(v_user::text, v_account, 'POSITION_INCREASE', v_pos,
                        v_run_a::text, v_run_b::text),
      jsonb_build_array(v_user::text, v_account, 'POSITION_INCREASE', v_pos,
                        v_run_b::text, v_run_c::text)));
  v_variant := jsonb_build_object('detection_identities', jsonb_build_array(
      jsonb_build_array(v_user::text, v_account, 'POSITION_INCREASE', v_pos,
                        v_run_b::text, v_run_c::text),
      jsonb_build_array(v_user::text, v_account, 'POSITION_INCREASE', v_pos,
                        v_run_a::text, v_run_b::text)));
  if public.mt5_capture_event_key_v1(v_two) = public.mt5_capture_event_key_v1(v_variant)
     and public.mt5_capture_event_key_v1(v_two) <> public.mt5_capture_event_key_v1(v_candidate) then
    v_pass := v_pass+1; insert into t2_v values('PASS','V20 event key is order-invariant over the identity SET');
  else
    v_fail := v_fail+1; insert into t2_v values('FAIL','V20 event key is order-invariant over the identity SET');
  end if;

  if (select count(*) from public.mt5_schema_migrations
       where version like 'mt5_s1%' and status = 'applied') >= 1 then
    v_pass := v_pass+1; insert into t2_v values('PASS','V21 frozen S1/S1.1 ledger rows still applied');
  else
    v_fail := v_fail+1; insert into t2_v values('FAIL','V21 frozen S1/S1.1 ledger rows still applied');
  end if;

  -- ---- V22..V27: AUTHORITATIVE RUN PROVENANCE ---------------------------------------------
  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                extensions.gen_random_uuid(), v_run_b, 1, 2, 2.0, 4.0, v_run_b);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_RUN_NOT_FOUND' then v_pass := v_pass+1; insert into t2_v values('PASS','V22 nonexistent before_run refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V22 nonexistent before_run refused: '||coalesce(v_err,'-')); end if;

  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_s1, v_run_b, 1, 2, 2.0, 4.0, v_run_b);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_RUN_SCOPE' then v_pass := v_pass+1; insert into t2_v values('PASS','V23 out-of-scope before_run refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V23 out-of-scope before_run refused: '||coalesce(v_err,'-')); end if;

  v_variant := pg_temp.t2v_cand(v_user, v_account2, v_pos2, 'POSITION_INCREASE',
                                v_s2, v_s3, 2, 3, 1.0, 2.0, v_s3, 'S50U26');
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account2, v_variant);
  if v_err = 'ERR_RUN_NOT_HEALTHY' then v_pass := v_pass+1; insert into t2_v values('PASS','V24 suspicious completed run refused as evidence');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V24 suspicious completed run refused as evidence: '||coalesce(v_err,'-')); end if;

  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_a, v_run_b, 5, 6, 2.0, 4.0, v_run_b);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_RUN_SEQ_MISMATCH' then v_pass := v_pass+1; insert into t2_v values('PASS','V25 falsified run_seq refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V25 falsified run_seq refused: '||coalesce(v_err,'-')); end if;

  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_a, v_run_c, 1, 3, 2.0, 6.0, v_run_c);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_RUN_NOT_ADJACENT' then v_pass := v_pass+1; insert into t2_v values('PASS','V26 non-adjacent completed pair refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V26 non-adjacent completed pair refused: '||coalesce(v_err,'-')); end if;

  v_variant := pg_temp.t2v_cand(v_user, v_account2, v_pos2, 'POSITION_INCREASE',
                                v_s1, v_s2, 1, 2, 1.0, 2.0, v_s2, 'S50U26');
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account2, v_variant);
  if v_err = 'ERR_BASIS_RUN_NOT_HEALTHY' then v_pass := v_pass+1; insert into t2_v values('PASS','V27 suspicious basis run refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V27 suspicious basis run refused: '||coalesce(v_err,'-')); end if;

  -- ---- V28..V31: detection shape / correspondence ------------------------------------------
  -- two real, time-coherent detections, then the IDENTITIES misaligned against them
  v_d_ab := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE', v_run_a, v_run_b,
                             1, 2, 2.0, 4.0, v_run_b, 'DELTAU26', 'buy',
                             '2026-08-23T09:00:00.000000Z') -> 'detections' -> 0;
  v_d_bc := jsonb_set(
              pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE', v_run_b, v_run_c,
                               2, 3, 4.0, 6.0, v_run_c, 'DELTAU26', 'buy',
                               '2026-08-23T09:02:00.000000Z') -> 'detections' -> 0,
              '{detected_at}', '"2026-08-23T09:02:00.000000Z"'::jsonb);
  v_d_cd := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE', v_run_c, v_run_d,
                             3, 4, 6.0, 8.0, v_run_d, 'DELTAU26', 'buy',
                             '2026-08-23T09:04:00.000000Z') -> 'detections' -> 0;
  v_two := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_c,
             jsonb_build_array(v_d_ab, v_d_bc),
             '2026-08-23T09:00:00.000000Z','2026-08-23T09:02:00.000000Z',
             '2026-08-23T09:07:00.000000Z', 300.0);
  -- sanity: the aligned two-detection candidate is accepted
  select o_ok,o_inserted,o_error_code into v_ok,v_ins,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account, v_two);
  if v_ok and v_ins = 1 then
    v_pass := v_pass+1; insert into t2_v values('PASS','V28a a coalesced two-detection candidate is accepted');
  else
    v_fail := v_fail+1; insert into t2_v values('FAIL','V28a a coalesced two-detection candidate is accepted: err='||coalesce(v_err,'-'));
  end if;
  -- ...and the same detections with the identity array reversed are not
  v_variant := jsonb_set(v_two, '{detection_identities}', jsonb_build_array(
      v_two -> 'detection_identities' -> 1, v_two -> 'detection_identities' -> 0));
  v_variant := jsonb_set(v_variant, '{basis_run_id}',
      to_jsonb((v_variant -> 'detection_identities' -> 1 ->> 5)));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PROVENANCE' then v_pass := v_pass+1; insert into t2_v values('PASS','V28 identities misaligned against detections refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V28 identities misaligned against detections refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{detections,0}',
                 (v_candidate -> 'detections' -> 0) || '{"price_open": 310.0}'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','V29 detection with an extra field refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V29 detection with an extra field refused: '||coalesce(v_err,'-')); end if;

  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_a, v_run_b, 0, 2, 2.0, 4.0, v_run_b);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','V30 run_seq 0 refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V30 run_seq 0 refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_build_object(
    'domain','mt5.t2.capture/1','user_id', v_user::text,'source_account', v_account,
    'position_id', v_pos,'basis_run_id', v_run_b::text,
    'first_detection_at','2026-08-23T09:00:00.000000Z',
    'last_detection_at','2026-08-23T09:00:00.000000Z',
    'quiet_deadline','2026-08-23T09:05:00.000000Z','quiet_window_seconds',300.0,
    'detector_version','t1-detector/0.1','aggregator_version','t2-quiet-window/0.1',
    'detection_identities', jsonb_build_array(jsonb_build_array(
      v_user::text, v_account,'POSITION_IDENTITY_CONFLICT', v_pos, v_run_a::text, v_run_b::text)),
    'event_types', jsonb_build_array('POSITION_IDENTITY_CONFLICT'),
    'run_references', jsonb_build_array(jsonb_build_object(
      'before_run_id', v_run_a::text,'after_run_id', v_run_b::text,
      'before_run_seq',1,'after_run_seq',2)),
    'detections', jsonb_build_array(jsonb_build_object(
      'event_type','POSITION_IDENTITY_CONFLICT','position_id', v_pos,
      'before_run_id', v_run_a::text,'after_run_id', v_run_b::text,
      'before_run_seq',1,'after_run_seq',2,
      'user_id', v_user::text,'source_account', v_account,
      'before_symbol_raw','DELTAU26','after_symbol_raw','DELTAU26',
      'before_side','buy','after_side','buy',
      'before_volume',2.0,'after_volume',4.0,
      'detected_at','2026-08-23T09:00:00.000000Z')));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','V31 IDENTITY_CONFLICT with no actual conflict refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','V31 IDENTITY_CONFLICT with no actual conflict refused: '||coalesce(v_err,'-')); end if;

  -- ---- V32: the TABLE refuses a nested forbidden field even without the RPC ----------------
  begin
    insert into public.mt5_capture_events(
      event_key, user_id, source_account, position_id, basis_run_id,
      first_detection_at, last_detection_at, quiet_deadline, quiet_window_seconds,
      detector_version, aggregator_version, payload, payload_fingerprint)
    values (repeat('a',64), v_user, v_account, v_pos, v_run_b,
      now(), now(), now() + interval '5 minutes', 300,
      't1-detector/0.1','t2-quiet-window/0.1',
      '{"detections":[{"nested":{"equity":1}}]}'::jsonb, repeat('b',64));
    v_fail := v_fail+1; insert into t2_v values('FAIL','V32 CHECK constraint refuses a nested forbidden field');
  exception when check_violation then
    v_pass := v_pass+1; insert into t2_v values('PASS','V32 CHECK constraint refuses a nested forbidden field');
  when others then
    v_fail := v_fail+1; insert into t2_v values('FAIL','V32 refused with the WRONG error: '||sqlerrm);
  end;

  -- ================================================================================
  -- M: MEMBERSHIP TRUTH — the stored snapshots decide what happened
  -- ================================================================================
  -- M1: a real reappearance, with older healthy history, is ACCEPTED
  v_variant := pg_temp.t2v_cand1(v_user, v_account3, v_p, 'REAPPEARANCE',
                                 v_w2, v_w3, 2, 3, 1.0, v_w3);
  select o_ok,o_inserted,o_error_code into v_ok,v_ins,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_ok and v_ins = 1 then v_pass := v_pass+1; insert into t2_v values('PASS','M1 correct REAPPEARANCE with older healthy history is accepted');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M1 correct REAPPEARANCE with older healthy history is accepted: err='||coalesce(v_err,'-')); end if;

  -- M2: the same evidence called NEW_POSITION is refused — the stored history knows better
  v_variant := pg_temp.t2v_cand1(v_user, v_account3, v_p, 'NEW_POSITION',
                                 v_w2, v_w3, 2, 3, 1.0, v_w3);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','M2 NEW_POSITION refused when an earlier healthy observation holds that position');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M2 NEW_POSITION refused when an earlier healthy observation holds that position: '||coalesce(v_err,'-')); end if;

  -- M3: a position with no earlier history really is NEW, and is ACCEPTED
  v_variant := pg_temp.t2v_cand1(v_user, v_account3, v_q, 'NEW_POSITION',
                                 v_w2, v_w3, 2, 3, 2.0, v_w3);
  select o_ok,o_inserted,o_error_code into v_ok,v_ins,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_ok and v_ins = 1 then v_pass := v_pass+1; insert into t2_v values('PASS','M3 genuine NEW_POSITION is accepted');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M3 genuine NEW_POSITION is accepted: err='||coalesce(v_err,'-')); end if;

  -- M4: ...and calling it a reappearance is refused
  v_variant := pg_temp.t2v_cand1(v_user, v_account3, v_q, 'REAPPEARANCE',
                                 v_w2, v_w3, 2, 3, 2.0, v_w3);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','M4 REAPPEARANCE refused when there is no earlier history');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M4 REAPPEARANCE refused when there is no earlier history: '||coalesce(v_err,'-')); end if;

  -- M5: a real disappearance is ACCEPTED
  v_variant := pg_temp.t2v_cand1(v_user, v_account3, v_p, 'POSITION_DISAPPEARED',
                                 v_w1, v_w2, 1, 2, 1.0, v_w2);
  select o_ok,o_inserted,o_error_code into v_ok,v_ins,v_err
    from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_ok and v_ins = 1 then v_pass := v_pass+1; insert into t2_v values('PASS','M5 real POSITION_DISAPPEARED is accepted');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M5 real POSITION_DISAPPEARED is accepted: err='||coalesce(v_err,'-')); end if;

  -- M6: fake NEW where the position was already PRESENT in the before run
  v_variant := pg_temp.t2v_cand1(v_user, v_account3, v_p, 'NEW_POSITION',
                                 v_w1, v_w2, 1, 2, 1.0, v_w2);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','M6 fake NEW_POSITION refused: the position was present in the before run');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M6 fake NEW_POSITION refused: the position was present in the before run: '||coalesce(v_err,'-')); end if;

  -- M7: fake DISAPPEARED where the position is still PRESENT in the after run
  v_variant := pg_temp.t2v_cand1(v_user, v_account3, v_p, 'POSITION_DISAPPEARED',
                                 v_w2, v_w3, 2, 3, 1.0, v_w3);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','M7 fake POSITION_DISAPPEARED refused: still present after');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M7 fake POSITION_DISAPPEARED refused: still present after: '||coalesce(v_err,'-')); end if;

  -- M8: the caller's volume must equal the persisted membership
  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_a, v_run_b, 1, 2, 3.0, 4.0, v_run_b);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','M8 caller volume differing from persisted membership refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M8 caller volume differing from persisted membership refused: '||coalesce(v_err,'-')); end if;

  -- M9: ...and so must the symbol
  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_a, v_run_b, 1, 2, 2.0, 4.0, v_run_b, 'XAUUSD');
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','M9 caller symbol_raw differing from persisted membership refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M9 caller symbol_raw differing from persisted membership refused: '||coalesce(v_err,'-')); end if;

  -- M10: ...and the side
  v_variant := pg_temp.t2v_cand(v_user, v_account, v_pos, 'POSITION_INCREASE',
                                v_run_a, v_run_b, 1, 2, 2.0, 4.0, v_run_b, 'DELTAU26', 'sell');
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','M10 caller side differing from persisted membership refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','M10 caller side differing from persisted membership refused: '||coalesce(v_err,'-')); end if;

  -- ================================================================================
  -- S: CANDIDATE-SET UNIQUENESS — refused before any key is derived
  -- ================================================================================
  -- S1: the exact same detection twice
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_b,
                 jsonb_build_array(v_d_ab, v_d_ab),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:00:00.000000Z',
                 '2026-08-23T09:05:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','S1 duplicate detection identity refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','S1 duplicate detection identity refused: '||coalesce(v_err,'-')); end if;

  -- S2: INCREASE and DECREASE for the SAME observation key
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_b,
                 jsonb_build_array(v_d_ab,
                   jsonb_set(jsonb_set(v_d_ab, '{event_type}', '"POSITION_DECREASE"'::jsonb),
                             '{after_volume}', '1.0'::jsonb)),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:00:00.000000Z',
                 '2026-08-23T09:05:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','S2 INCREASE + DECREASE for one observation key refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','S2 INCREASE + DECREASE for one observation key refused: '||coalesce(v_err,'-')); end if;

  -- S3: NEW and REAPPEARANCE for the SAME observation key
  v_two := pg_temp.t2v_cand1(v_user, v_account3, v_p, 'NEW_POSITION',
                             v_w2, v_w3, 2, 3, 1.0, v_w3) -> 'detections' -> 0;
  v_variant := pg_temp.t2v_multi(v_user, v_account3, v_p, v_w3,
                 jsonb_build_array(v_two,
                   jsonb_set(v_two, '{event_type}', '"REAPPEARANCE"'::jsonb)),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:00:00.000000Z',
                 '2026-08-23T09:05:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account3, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','S3 NEW + REAPPEARANCE for one observation key refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','S3 NEW + REAPPEARANCE for one observation key refused: '||coalesce(v_err,'-')); end if;

  -- S4: an otherwise well-formed multi-detection candidate with one pair duplicated
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_c,
                 jsonb_build_array(v_d_ab, v_d_ab, v_d_bc),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:02:00.000000Z',
                 '2026-08-23T09:07:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then v_pass := v_pass+1; insert into t2_v values('PASS','S4 a duplicated pair inside a larger candidate refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','S4 a duplicated pair inside a larger candidate refused: '||coalesce(v_err,'-')); end if;

  -- ================================================================================
  -- T: THE QUIET-WINDOW TIME INVARIANT
  -- ================================================================================
  -- T1: reversed chronology
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_b,
                 jsonb_build_array(v_d_bc, v_d_ab),
                 '2026-08-23T09:02:00.000000Z','2026-08-23T09:00:00.000000Z',
                 '2026-08-23T09:05:00.000000Z', 300.0);
  v_variant := jsonb_set(v_variant, '{basis_run_id}', to_jsonb(v_run_b::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T1 reversed chronology refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T1 reversed chronology refused: '||coalesce(v_err,'-')); end if;

  -- T2: an internal gap larger than the quiet window — these are two candidates, not one
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_c,
                 jsonb_build_array(v_d_ab,
                   jsonb_set(v_d_bc, '{detected_at}', '"2026-08-23T09:20:00.000000Z"'::jsonb)),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:20:00.000000Z',
                 '2026-08-23T09:25:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T2 internal gap larger than the quiet window refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T2 internal gap larger than the quiet window refused: '||coalesce(v_err,'-')); end if;

  -- T3: first_detection_at is not the first detection's instant
  v_variant := jsonb_set(v_candidate, '{first_detection_at}',
                         '"2026-08-23T08:59:00.000000Z"'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T3 first_detection_at mismatch refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T3 first_detection_at mismatch refused: '||coalesce(v_err,'-')); end if;

  -- T4: last_detection_at is not the final detection's instant
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_c,
                 jsonb_build_array(v_d_ab, v_d_bc),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:03:00.000000Z',
                 '2026-08-23T09:08:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T4 last_detection_at mismatch refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T4 last_detection_at mismatch refused: '||coalesce(v_err,'-')); end if;

  -- T5 / T6 / T7: infinity is a legal timestamptz, so a successful cast proves nothing
  v_variant := jsonb_set(v_candidate, '{last_detection_at}', '"infinity"'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T5 +infinity last_detection_at refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T5 +infinity last_detection_at refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{first_detection_at}', '"-infinity"'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T6 -infinity first_detection_at refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T6 -infinity first_detection_at refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{detections,0,detected_at}', '"infinity"'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T7 +infinity nested detected_at refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T7 +infinity nested detected_at refused: '||coalesce(v_err,'-')); end if;

  -- T9: a MIDDLE detection that runs backwards. first_detection_at and last_detection_at are
  -- both still correct, so nothing but the chronology rule can refuse this.
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_c,
                 jsonb_build_array(v_d_ab, v_d_cd, v_d_bc),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:02:00.000000Z',
                 '2026-08-23T09:07:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T9 a middle detection running backwards refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T9 a middle detection running backwards refused: '||coalesce(v_err,'-')); end if;

  -- T10: two detections share an instant but are in the WRONG T2 canonical order
  -- (after_run_seq 4 before after_run_seq 3). Everything else about the candidate is correct.
  v_variant := pg_temp.t2v_multi(v_user, v_account, v_pos, v_run_c,
                 jsonb_build_array(v_d_ab,
                   jsonb_set(v_d_cd, '{detected_at}', '"2026-08-23T09:02:00.000000Z"'::jsonb),
                   v_d_bc),
                 '2026-08-23T09:00:00.000000Z','2026-08-23T09:02:00.000000Z',
                 '2026-08-23T09:07:00.000000Z', 300.0);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_TIME_ORDER' then v_pass := v_pass+1; insert into t2_v values('PASS','T10 equal instants out of the T2 canonical order refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','T10 equal instants out of the T2 canonical order refused: '||coalesce(v_err,'-')); end if;

  -- T8: the consequence — every stored detection lies strictly before its own deadline.
  -- With first == d[0], last == d[-1], chronology and deadline == last + window all enforced,
  -- "a detection after the deadline" is unreachable rather than merely unobserved.
  if not exists (
    select 1 from public.mt5_capture_events c,
                  lateral jsonb_array_elements(c.payload -> 'detections') as d
     where (d ->> 'detected_at')::timestamptz >= c.quiet_deadline
        or (d ->> 'detected_at')::timestamptz < c.first_detection_at
        or (d ->> 'detected_at')::timestamptz > c.last_detection_at) then
    v_pass := v_pass+1; insert into t2_v values('PASS','T8 every stored detection lies within [first, last] and before the deadline');
  else
    v_fail := v_fail+1; insert into t2_v values('FAIL','T8 every stored detection lies within [first, last] and before the deadline');
  end if;

  -- ---- C1..C13: THE CANONICAL IDENTITY WIRE FORMAT ---------------------------------------
  -- The identity tuple is compared and hashed as TEXT. Postgres's uuid type ACCEPTS uppercase
  -- hex, braces, a urn:uuid: prefix and missing hyphens, and renders exactly one of them back,
  -- so a successful ::uuid cast proves nothing about the spelling that arrived. Two spellings
  -- of one run pair are two identities, hence two event keys, for a single observation.

  -- C1: only the SPELLING differs — identity, detection and run_reference all agree, so nothing
  -- but the wire-format rule can refuse this. o_event_key must come back NULL: the candidate is
  -- refused before any key can be derived from it.
  v_variant := jsonb_set(jsonb_set(jsonb_set(v_candidate,
                 '{detection_identities,0,4}', to_jsonb(upper(v_run_a::text))),
                 '{detections,0,before_run_id}', to_jsonb(upper(v_run_a::text))),
                 '{run_references,0,before_run_id}', to_jsonb(upper(v_run_a::text)));
  select o_error_code, o_event_key into v_err, v_key2
    from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_IDENTITY' and v_key2 is null then
    v_pass := v_pass+1; insert into t2_v values('PASS','C1 an UPPERCASE run uuid is refused and mints no key');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C1 an UPPERCASE run uuid is refused and mints no key: '||coalesce(v_err,'-')||'/'||coalesce(v_key2,'null')); end if;

  -- C2: identities stay canonical and only the DETECTION is respelled. Since revision 5 the
  -- detection arrays carry the spelling rule in their own right, so this is refused as a
  -- DETECTION defect rather than as a correspondence failure; correspondence remains the
  -- backstop behind it.
  v_variant := jsonb_set(v_candidate,
                 '{detections,0,before_run_id}', to_jsonb(upper(v_run_a::text)));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C2 a respelled detection run id is refused in its own right');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C2 a respelled detection run id is refused in its own right: '||coalesce(v_err,'-')); end if;

  -- C2b: the same respelling in a run_reference, which is refused as a PROVENANCE defect
  v_variant := jsonb_set(v_candidate,
                 '{run_references,0,before_run_id}', to_jsonb(upper(v_run_a::text)));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PROVENANCE' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C2b a respelled run_reference run id is refused in its own right');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C2b a respelled run_reference run id is refused in its own right: '||coalesce(v_err,'-')); end if;

  -- C3: the position inside an identity, spelled as a STRING. ->> renders '306676142' either
  -- way, so a text comparison alone would accept it; the JSON TYPE is what separates them.
  v_variant := jsonb_set(v_candidate, '{detection_identities,0,3}', to_jsonb(v_pos::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_IDENTITY' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C3 a STRING position_id inside an identity is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C3 a STRING position_id inside an identity is refused: '||coalesce(v_err,'-')); end if;

  -- C4: a fractional-typed position. It is a JSON number and casts cleanly, but renders
  -- '306676142.0' — a different identity text.
  v_variant := jsonb_set(v_candidate, '{detection_identities,0,3}',
                         to_jsonb((v_pos::text || '.0')::numeric));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_IDENTITY' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C4 a FRACTIONAL-typed position_id inside an identity is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C4 a FRACTIONAL-typed position_id inside an identity is refused: '||coalesce(v_err,'-')); end if;

  -- C5 / C6: the same two aliases at the top level, where position_id is the scope of the row
  v_variant := jsonb_set(v_candidate, '{position_id}', to_jsonb(v_pos::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C5 a STRING top-level position_id is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C5 a STRING top-level position_id is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{position_id}', to_jsonb((v_pos::text || '.0')::numeric));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C6 a FRACTIONAL top-level position_id is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C6 a FRACTIONAL top-level position_id is refused: '||coalesce(v_err,'-')); end if;

  -- C7..C9: the three uuid spellings Postgres would happily have absorbed on basis_run_id
  v_variant := jsonb_set(v_candidate, '{basis_run_id}', to_jsonb(upper(v_run_b::text)));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C7 an UPPERCASE basis_run_id is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C7 an UPPERCASE basis_run_id is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{basis_run_id}', to_jsonb('{' || v_run_b::text || '}'));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C8 a BRACED basis_run_id is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C8 a BRACED basis_run_id is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_candidate, '{basis_run_id}',
                         to_jsonb(replace(v_run_b::text, '-', '')));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C9 an UNHYPHENATED basis_run_id is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C9 an UNHYPHENATED basis_run_id is refused: '||coalesce(v_err,'-')); end if;

  -- C10: the window as a JSON STRING. '300.0'::numeric succeeds, so before the type gate this
  -- payload was accepted and stored a string where every other replay stores a number — same
  -- key, different fingerprint, i.e. a manufactured conflict.
  v_variant := jsonb_set(v_candidate, '{quiet_window_seconds}', to_jsonb('300.0'::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','C10 a STRING quiet_window_seconds is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C10 a STRING quiet_window_seconds is refused: '||coalesce(v_err,'-')); end if;

  -- C11: the blocker itself, stated as evidence. The alias is not merely untidy: it derives a
  -- DIFFERENT deterministic key for the same observation. Refusing it before derivation is the
  -- only thing standing between one observation and two capture rows.
  v_variant := jsonb_set(jsonb_set(v_candidate,
                 '{detection_identities,0,4}', to_jsonb(upper(v_run_a::text))),
                 '{detection_identities,0,5}', to_jsonb(upper(v_run_b::text)));
  if public.mt5_capture_event_key_v1(v_variant)
       is distinct from public.mt5_capture_event_key_v1(v_candidate) then
    v_pass := v_pass+1; insert into t2_v values('PASS','C11 a uuid spelling alias really WOULD mint a second event key');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C11 a uuid spelling alias really WOULD mint a second event key'); end if;

  -- C12: and it may not ride along beside its own canonical identity either. The wire-format
  -- gate fires before the set gates, which is the required order: a duplicate that is not even
  -- well spelled must never reach the point where a key could be derived from it.
  v_variant := jsonb_set(jsonb_set(jsonb_set(jsonb_set(v_candidate,
      '{detection_identities}', (v_candidate -> 'detection_identities')
        || jsonb_build_array(jsonb_build_array(
             v_user::text, v_account, 'POSITION_INCREASE', v_pos,
             upper(v_run_a::text), upper(v_run_b::text)))),
      '{event_types}', (v_candidate -> 'event_types') || '["POSITION_INCREASE"]'::jsonb),
      '{run_references}', (v_candidate -> 'run_references')
        || jsonb_build_array(jsonb_build_object(
             'before_run_id', upper(v_run_a::text), 'after_run_id', upper(v_run_b::text),
             'before_run_seq', 1, 'after_run_seq', 2))),
      '{detections}', (v_candidate -> 'detections')
        || jsonb_build_array(jsonb_set(jsonb_set(v_candidate -> 'detections' -> 0,
             '{before_run_id}', to_jsonb(upper(v_run_a::text))),
             '{after_run_id}', to_jsonb(upper(v_run_b::text)))));
  select o_error_code, o_event_key into v_err, v_key2
    from public.mt5_append_capture_event_v1(v_user, v_account, v_variant);
  if v_err = 'ERR_CAPTURE_IDENTITY' and v_key2 is null then
    v_pass := v_pass+1; insert into t2_v values('PASS','C12 an alias may not coexist with its canonical identity');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C12 an alias may not coexist with its canonical identity: '||coalesce(v_err,'-')||'/'||coalesce(v_key2,'null')); end if;

  -- C13: the canonical candidate is untouched by all of this — same key on replay, and it is
  -- the key already stored for the row V1 inserted.
  select o_ok, o_inserted, o_event_key into v_ok, v_ins, v_key2
    from public.mt5_append_capture_event_v1(v_user, v_account, v_candidate);
  if v_ok and v_ins = 0
     and v_key2 = public.mt5_capture_event_key_v1(v_candidate)
     and v_key2 = (select event_key from public.mt5_capture_events
                    where user_id = v_user and source_account = v_account
                      and position_id = v_pos and basis_run_id = v_run_b) then
    v_pass := v_pass+1; insert into t2_v values('PASS','C13 the canonical candidate replays to the SAME stored key');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','C13 the canonical candidate replays to the SAME stored key'); end if;

  -- ---- N1..N17: source_account IS OPAQUE TEXT ---------------------------------------------
  -- Account 904 is named '301102520'. The JSON number 301102520 renders to exactly that text,
  -- so `(p_candidate ->> 'source_account') = p_account` is TRUE for the numeric alias: the
  -- scope comparison cannot refuse it, and before revision 5 it reached key derivation. Only
  -- the JSON TYPE separates an opaque account identifier from a number that looks like one.
  v_ncand := pg_temp.t2v_cand(v_user, v_account4, v_nn, 'POSITION_INCREASE', v_n1, v_n2,
                              1, 2, 2.0, 4.0, v_n2, 'S50U26', 'buy');

  -- N1: the canonical STRING account is accepted
  select o_ok, o_inserted, o_error_code into v_ok, v_ins, v_err
    from public.mt5_append_capture_event_v1(v_user, v_account4, v_ncand);
  if v_ok and v_ins = 1 then
    v_pass := v_pass+1; insert into t2_v values('PASS','N1 an all-digit account NAME is valid as a string');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N1 an all-digit account NAME is valid as a string: '||coalesce(v_err,'-')); end if;

  -- N2..N6: the same account as a NUMBER, a float, a bool, JSON null, and blank
  v_variant := jsonb_set(v_ncand, '{source_account}', to_jsonb(301102520::bigint));
  select o_error_code, o_event_key into v_err, v_key2
    from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' and v_key2 is null then
    v_pass := v_pass+1; insert into t2_v values('PASS','N2 a NUMERIC source_account is refused and mints no key');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N2 a NUMERIC source_account is refused and mints no key: '||coalesce(v_err,'-')||'/'||coalesce(v_key2,'null')); end if;

  v_variant := jsonb_set(v_ncand, '{source_account}', to_jsonb(301102520.0::numeric));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N3 a FRACTIONAL source_account is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N3 a FRACTIONAL source_account is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_ncand, '{source_account}', 'true'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N4 a BOOLEAN source_account is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N4 a BOOLEAN source_account is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_ncand, '{source_account}', 'null'::jsonb);
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N5 a JSON-null source_account is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N5 a JSON-null source_account is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_ncand, '{source_account}', to_jsonb('   '::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N6 a BLANK source_account is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N6 a BLANK source_account is refused: '||coalesce(v_err,'-')); end if;

  -- N7: a leading zero is a DIFFERENT account, not the same one respelled. Nothing here reads
  -- the account as a number, so the two never collapse onto each other.
  v_variant := jsonb_set(v_ncand, '{source_account}', to_jsonb('0' || v_account4));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_SCOPE' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N7 "0301102520" is a different account, not a normalised one');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N7 "0301102520" is a different account, not a normalised one: '||coalesce(v_err,'-')); end if;

  -- N8 / N9: the account nested inside a detection, and inside an identity
  v_variant := jsonb_set(v_ncand, '{detections,0,source_account}', to_jsonb(301102520::bigint));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N8 a NUMERIC source_account inside a detection is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N8 a NUMERIC source_account inside a detection is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_ncand, '{detection_identities,0,1}', to_jsonb(301102520::bigint));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_IDENTITY' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N9 a NUMERIC source_account inside an identity is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N9 a NUMERIC source_account inside an identity is refused: '||coalesce(v_err,'-')); end if;

  -- N10: CONSISTENTLY numeric. Nothing disagrees with anything, and every rendering matches the
  -- caller's scope exactly, so no correspondence or scope check can make this test vacuous.
  v_variant := jsonb_set(jsonb_set(jsonb_set(v_ncand,
                 '{source_account}', to_jsonb(301102520::bigint)),
                 '{detections,0,source_account}', to_jsonb(301102520::bigint)),
                 '{detection_identities,0,1}', to_jsonb(301102520::bigint));
  select o_error_code, o_event_key into v_err, v_key2
    from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' and v_key2 is null then
    v_pass := v_pass+1; insert into t2_v values('PASS','N10 a CONSISTENTLY numeric source_account is still refused, with no key');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N10 a CONSISTENTLY numeric source_account is still refused, with no key: '||coalesce(v_err,'-')||'/'||coalesce(v_key2,'null')); end if;

  -- N11: and it really would have been a different identity text, hence a different key
  if public.mt5_capture_event_key_v1(v_variant)
       is distinct from public.mt5_capture_event_key_v1(v_ncand) then
    v_pass := v_pass+1; insert into t2_v values('PASS','N11 a numeric account alias really WOULD mint a second event key');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N11 a numeric account alias really WOULD mint a second event key'); end if;

  -- N12 / N13: user_id of the wrong JSON type, top level and nested, refused BEFORE any uuid
  -- text comparison could rescue it
  v_variant := jsonb_set(v_ncand, '{user_id}', to_jsonb(12345::bigint));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PAYLOAD_INVALID' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N12 a NUMERIC top-level user_id is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N12 a NUMERIC top-level user_id is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_ncand, '{detections,0,user_id}', to_jsonb(12345::bigint));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N13 a NUMERIC user_id inside a detection is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N13 a NUMERIC user_id inside a detection is refused: '||coalesce(v_err,'-')); end if;

  -- N14 / N15: a run_reference run id that is not a string, and a sequence number that is
  v_variant := jsonb_set(v_ncand, '{run_references,0,before_run_id}', to_jsonb(1::bigint));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PROVENANCE' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N14 a NUMERIC run_reference run id is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N14 a NUMERIC run_reference run id is refused: '||coalesce(v_err,'-')); end if;

  v_variant := jsonb_set(v_ncand, '{detections,0,before_run_seq}', to_jsonb('1'::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_DETECTION' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N15 a STRING run sequence number is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N15 a STRING run sequence number is refused: '||coalesce(v_err,'-')); end if;

  -- N16: a run_reference sequence number as a STRING. '1'::numeric = 1, so every downstream
  -- comparison agrees with it; the JSON type is the only thing that does not.
  v_variant := jsonb_set(v_ncand, '{run_references,0,before_run_seq}', to_jsonb('1'::text));
  select o_error_code into v_err from public.mt5_append_capture_event_v1(v_user, v_account4, v_variant);
  if v_err = 'ERR_CAPTURE_PROVENANCE' then
    v_pass := v_pass+1; insert into t2_v values('PASS','N16 a STRING run_reference sequence number is refused');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N16 a STRING run_reference sequence number is refused: '||coalesce(v_err,'-')); end if;

  -- N17: the canonical candidate is untouched — same key, replay-safe, still one row
  select o_ok, o_inserted, o_event_key into v_ok, v_ins, v_key2
    from public.mt5_append_capture_event_v1(v_user, v_account4, v_ncand);
  if v_ok and v_ins = 0 and v_key2 = public.mt5_capture_event_key_v1(v_ncand)
     and (select count(*) from public.mt5_capture_events where source_account = v_account4) = 1 then
    v_pass := v_pass+1; insert into t2_v values('PASS','N17 the canonical candidate replays to the SAME key, one row');
  else v_fail := v_fail+1; insert into t2_v values('FAIL','N17 the canonical candidate replays to the SAME key, one row'); end if;

  for v_txt in select res || ' ' || label from t2_v loop
    raise notice '  %', v_txt;
  end loop;
  raise notice 'MT5 T2 CAPTURE VERIFICATION: % passed, % failed (EXECUTABLE DRAFT — this run is ROLLED BACK)',
    v_pass, v_fail;
  if v_fail > 0 then
    raise exception 'MT5_T2_VERIFICATION: % assertion(s) failed', v_fail;
  end if;
end
$t2_verify$;

rollback;
