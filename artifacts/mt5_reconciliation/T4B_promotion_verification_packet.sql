-- ================================================================================================
-- ★★★ OFFLINE-ONLY SYNTHETIC VERIFICATION — THIS PACKET SEEDS DATA. NEVER RUN IN PRODUCTION. ★★★
--
-- It INSERTS synthetic runs, positions, captures, decisions, products and Journal trades, exercises
-- the whole T4B outcome matrix against them, and then ROLLS BACK. It is not, and can never be, a
-- production verifier — the read-only production check is
-- T4B_promotion_security_verification_packet.sql.
--
-- TWO independent safety conditions must hold before the first INSERT: an explicit disposable-
-- environment marker the operator has to type, and the absence of durable rows anywhere in the
-- pipeline.
--
-- RUN (disposable database only):
--   psql -v ON_ERROR_STOP=1 \
--        -c "SET t4b.offline_fixture = 'I_UNDERSTAND_DISPOSABLE';" \
--        -f T4B_promotion_verification_packet.sql
-- Expected tail: "T4B VERIFY: ALL <n> CHECKS PASS" followed by ROLLBACK.
-- ================================================================================================

begin;

do $t4b_ver_guard$
declare
  v_marker text;
  v_tbl    text;
  v_n      bigint;
  v_found  text[] := array[]::text[];
begin
  if to_regclass('public.mt5_capture_promotions') is null then
    raise exception 'T4B_VERIFY: the T4B packets are not applied here';
  end if;

  v_marker := current_setting('t4b.offline_fixture', true);
  if coalesce(v_marker, '') <> 'I_UNDERSTAND_DISPOSABLE' then
    raise exception 'T4B_VERIFY: refusing to run. This packet SEEDS DATA and is for a DISPOSABLE '
      'database only. Set the marker explicitly if that is what you have: '
      'SET t4b.offline_fixture = ''I_UNDERSTAND_DISPOSABLE'';';
  end if;

  foreach v_tbl in array array[
      'public.mt5_sync_runs', 'public.mt5_sync_run_positions', 'public.mt5_capture_events',
      'public.mt5_capture_decisions', 'public.mt5_capture_promotions', 'public.trades',
      'public.products'] loop
    if to_regclass(v_tbl) is not null then
      execute format('select count(*) from %s', v_tbl) into v_n;
      if v_n > 0 then
        v_found := v_found || (v_tbl || '=' || v_n::text);
      end if;
    end if;
  end loop;
  if array_length(v_found, 1) is not null then
    raise exception 'T4B_VERIFY: REFUSING — this database already holds durable rows (%). This '
      'packet SEEDS DATA and is for a disposable database only.', array_to_string(v_found, ', ');
  end if;
end $t4b_ver_guard$;

create temp table t4b_results(n serial, label text, ok boolean, detail text) on commit drop;

create function pg_temp.chk(p_ok boolean, p_label text, p_detail text default null)
returns void language plpgsql as $c$
begin
  insert into t4b_results(label, ok, detail) values (p_label, coalesce(p_ok, false), p_detail);
end $c$;

-- Executable source of a function: prosrc WITHOUT comments. The packet's comments name tokens
-- these assertions hunt for ("no `when others` anywhere"), so a raw substring scan would report a
-- clean function as dirty. Only executable source is ever examined.
create function pg_temp.src(p_name text) returns text
language sql stable as $src$
  select regexp_replace(p.prosrc, '--[^
]*', '', 'g')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = p_name
$src$;

-- The reserved trade id a given decision will always target. Mirrors the RPC's own derivation so
-- the tests can name the address before it is minted.
create function pg_temp.reserved(p_decision uuid) returns text
language sql immutable as $rid$ select 'mt5p_' || replace(p_decision::text, '-', '') $rid$;

-- ---------------------------------------------------------------------------------------------
-- fixture helpers
-- ---------------------------------------------------------------------------------------------
create function pg_temp.mkrun(p_id uuid, p_seq bigint, p_age interval,
                              p_status text default 'complete', p_health text default 'healthy')
returns void language plpgsql as $r$
begin
  insert into public.mt5_sync_runs(
    id, user_id, source_account, captured_at, snapshot_status, reconcile_status, snapshot_health,
    run_seq, previous_positions_count, positions_count, position_ids_hash, manifest_hash,
    policy_version, policy_thresholds, warning_code, error_code, connector_version,
    lease_token, lease_expires_at, heartbeat_at, snapshot_completed_at, snapshot_failed_at,
    reconciled_at)
  values (
    p_id, '11111111-1111-4111-8111-111111111111', '301102520', now() - p_age,
    p_status, case when p_status = 'complete' then 'complete' else 'pending' end,
    case when p_status = 'complete' then p_health else null end,
    case when p_status = 'complete' then p_seq else null end,
    case when p_status = 'complete' then 0 else null end,
    case when p_status = 'complete' then 1 else null end,
    case when p_status = 'complete' then repeat('a', 64) else null end,
    case when p_status = 'complete' then repeat('b', 64) else null end,
    's1-policy/0.1',
    '{"k":3,"susp_min_base":4,"susp_drop_ratio":0.5,"freshness_seconds":900}'::jsonb,
    case when p_status = 'complete' and p_health = 'suspicious' then 'W_TEST' else null end,
    case when p_status = 'failed' then 'E_TEST' else null end,
    's1-connector/0.1',
    gen_random_uuid(), now() + interval '1 hour', now(),
    case when p_status = 'complete' then now() - p_age else null end,
    case when p_status = 'failed' then now() - p_age else null end,
    case when p_status = 'complete' then now() - p_age else null end);
end $r$;

create function pg_temp.mkpos(p_run uuid, p_pos bigint, p_sym text, p_side text, p_vol numeric,
                              p_px numeric, p_open timestamptz, p_csize numeric)
returns void language plpgsql as $p$
begin
  insert into public.mt5_sync_run_positions(
    run_id, user_id, source_account, position_id, symbol_raw, side, volume, price_open,
    price_current, profit, open_time_utc, source_time_msc, contract_size, captured_at,
    row_fingerprint)
  values (p_run, '11111111-1111-4111-8111-111111111111', '301102520', p_pos, p_sym, p_side,
          p_vol, p_px, p_px + 4.3, 4300, p_open, 1787567772245, p_csize,
          (select captured_at from public.mt5_sync_runs where id = p_run),
          md5(p_run::text || p_pos::text) || md5(p_sym || p_side));
end $p$;

create function pg_temp.mkcap(p_id uuid, p_pos bigint, p_basis uuid, p_key text)
returns void language plpgsql as $c2$
begin
  insert into public.mt5_capture_events(
    id, event_key, user_id, source_account, position_id, basis_run_id, first_detection_at,
    last_detection_at, quiet_deadline, quiet_window_seconds, detector_version, aggregator_version,
    payload, payload_fingerprint)
  values (p_id, md5(p_key) || md5(p_key || 'k'), '11111111-1111-4111-8111-111111111111',
          '301102520', p_pos, p_basis,
          now() - interval '3 hours', now() - interval '3 hours', now() - interval '2 hours',
          900, 't1-detector/0.1', 't2-quiet-window/0.1',
          jsonb_build_object('domain','mt5.t2.capture/1','position_id',p_pos),
          md5(p_key) || md5(p_key || 'x'));
end $c2$;

create function pg_temp.mkdec(p_id uuid, p_cap uuid, p_action text)
returns void language plpgsql as $d$
begin
  insert into public.mt5_capture_decisions(id, capture_event_id, action, source,
                                           telegram_chat_id, telegram_message_id)
  values (p_id, p_cap, p_action, 'telegram', 6044856720, 895);
end $d$;

-- An ORDINARY browser save, reproduced exactly: the 13 columns toTradeRow() emits, upserted with
-- onConflict:"id". Note what is absent — mt5_promotion_id — and note that `raw` is rewritten
-- WHOLESALE through the 19-key buildTrade shape, which is what drops raw.mt5PositionId.
create function pg_temp.browser_save(p_id text, p_user uuid, p_raw jsonb)
returns void language plpgsql as $bs$
begin
  insert into public.trades(
    id, user_id, product_id, direction, status, contracts, remaining_contracts,
    entry_price, exit_price, entry_date, exit_date, note, raw)
  values (
    p_id, p_user, p_raw->>'productId', p_raw->>'direction', p_raw->>'status',
    (p_raw->>'contracts')::numeric, (p_raw->>'contracts')::numeric,
    (p_raw->>'entryPrice')::numeric, null, null, null, null, p_raw)
  on conflict (id) do update set
    product_id          = excluded.product_id,
    direction           = excluded.direction,
    status              = excluded.status,
    contracts           = excluded.contracts,
    remaining_contracts = excluded.remaining_contracts,
    entry_price         = excluded.entry_price,
    exit_price          = excluded.exit_price,
    entry_date          = excluded.entry_date,
    exit_date           = excluded.exit_date,
    note                = excluded.note,
    raw                 = excluded.raw;
end $bs$;

-- ---------------------------------------------------------------------------------------------
-- the world
-- ---------------------------------------------------------------------------------------------
do $seed$
declare
  U     constant uuid := '11111111-1111-4111-8111-111111111111';
  OPEN_T constant timestamptz := timestamptz '2026-08-24 03:36:12+00';
begin
  -- product catalog: production-shaped. s50 owns S50M26 (active) and S50U26 (next), size 200.
  insert into public.products(user_id, data, updated_at) values (U, jsonb_build_array(
    jsonb_build_object('id','s50','baseSymbol','S50','currentContract','S50M26',
                       'nextContract','S50U26','contractSize',200,'tickSize',0.1,'tickValue',20),
    jsonb_build_object('id','gold','baseSymbol','GO','currentContract','GOM26',
                       'nextContract','GOU26','contractSize',300,'tickSize',0.1,'tickValue',30),
    -- SSF/stock collision decoy: same contract code family, WRONG contract size
    jsonb_build_object('id','delta','baseSymbol','DELTA','currentContract','DELTAM26',
                       'nextContract','DELTAU26','contractSize',1,'tickSize',0.01,'tickValue',0.01),
    -- ambiguity decoy: a second catalog entry claiming AMBIG26
    jsonb_build_object('id','amb1','baseSymbol','AMB','currentContract','AMBIG26',
                       'nextContract','AMBIG27','contractSize',10,'tickSize',0.1,'tickValue',1),
    jsonb_build_object('id','amb2','baseSymbol','AMB','currentContract','AMBIG25',
                       'nextContract','AMBIG26','contractSize',10,'tickSize',0.1,'tickValue',1),
    -- non-numeric contractSize decoy
    jsonb_build_object('id','bads','baseSymbol','BAD','currentContract','BADS26',
                       'nextContract','BADS27','contractSize','not-a-number')
  ), now());

  -- runs: basis 90 min old, fresh 10 min old. Both complete + healthy.
  perform pg_temp.mkrun('aaaaaaaa-0000-4000-8000-000000000001', 3, interval '90 minutes');
  perform pg_temp.mkrun('aaaaaaaa-0000-4000-8000-000000000002', 4, interval '10 minutes');

  -- POS 312261388 — the happy path. Identical in both runs.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 312261388, 'S50U26','buy',5,1067.3,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 312261388, 'S50U26','buy',5,1067.3,OPEN_T,200);

  -- POS 400000001 — present in basis, ABSENT from the fresh run.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000001, 'S50U26','buy',3,1000.0,OPEN_T,200);

  -- POS 400000002 — VOLUME DRIFT (5 -> 7).
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000002, 'S50U26','buy',5,1067.3,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000002, 'S50U26','buy',7,1067.3,OPEN_T,200);

  -- POS 400000003 — PRICE_OPEN DRIFT.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000003, 'S50U26','buy',5,1067.3,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000003, 'S50U26','buy',5,1067.9,OPEN_T,200);

  -- POS 400000004 — SIDE DRIFT.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000004, 'S50U26','buy',5,1067.3,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000004, 'S50U26','sell',5,1067.3,OPEN_T,200);

  -- POS 400000005 — SYMBOL DRIFT.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000005, 'S50U26','buy',5,1067.3,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000005, 'S50M26','buy',5,1067.3,OPEN_T,200);

  -- POS 400000006 — OPEN_TIME DRIFT.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000006, 'S50U26','buy',5,1067.3,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000006, 'S50U26','buy',5,1067.3,OPEN_T + interval '1 minute',200);

  -- POS 400000007 — CONTRACT_SIZE DRIFT.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000007, 'S50U26','buy',5,1067.3,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000007, 'S50U26','buy',5,1067.3,OPEN_T,300);

  -- POS 400000008 — UNMAPPABLE symbol (no catalog entry claims it).
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000008, 'NOPE26','buy',5,10.0,OPEN_T,7);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000008, 'NOPE26','buy',5,10.0,OPEN_T,7);

  -- POS 400000009 — AMBIGUOUS symbol (two catalog entries claim AMBIG26).
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000009, 'AMBIG26','buy',5,10.0,OPEN_T,10);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000009, 'AMBIG26','buy',5,10.0,OPEN_T,10);

  -- POS 400000010 — CONTRACT-SIZE MISMATCH vs catalog (DELTAU26 catalog=1, snapshot=1000).
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000010, 'DELTAU26','buy',2,300.0,OPEN_T,1000);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000010, 'DELTAU26','buy',2,300.0,OPEN_T,1000);

  -- POS 400000011 — basis facts INCOMPLETE (null price_open).
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000011, 'S50U26','buy',5,null,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000011, 'S50U26','buy',5,null,OPEN_T,200);

  -- POS 400000012 — non-numeric catalog contractSize (BADS27 -> 'not-a-number').
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000012, 'BADS27','buy',5,10.0,OPEN_T,5);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000012, 'BADS27','buy',5,10.0,OPEN_T,5);

  -- POS 400000020..22 — spare clean positions for the incarnation / handler sections.
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000020, 'S50U26','buy',4,1050.0,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000020, 'S50U26','buy',4,1050.0,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000021, 'S50U26','buy',6,1051.0,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000021, 'S50U26','buy',6,1051.0,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000022, 'S50U26','buy',7,1052.0,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000022, 'S50U26','buy',7,1052.0,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000001', 400000024, 'S50U26','buy',8,1053.0,OPEN_T,200);
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 400000024, 'S50U26','buy',8,1053.0,OPEN_T,200);

  -- captures + decisions
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000001', 312261388, 'aaaaaaaa-0000-4000-8000-000000000001','k-happy');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001','journal_add');

  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000002', 312261388, 'aaaaaaaa-0000-4000-8000-000000000001','k-reappear');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000002', 'cccccccc-0000-4000-8000-000000000002','journal_add');

  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000003', 312261388, 'aaaaaaaa-0000-4000-8000-000000000001','k-notja');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000003', 'cccccccc-0000-4000-8000-000000000003','already_logged');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000013', 312261388, 'aaaaaaaa-0000-4000-8000-000000000001','k-norec');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000013', 'cccccccc-0000-4000-8000-000000000013','no_record');

  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000004', 400000001, 'aaaaaaaa-0000-4000-8000-000000000001','k-absent');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000004', 'cccccccc-0000-4000-8000-000000000004','journal_add');

  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000005', 400000002, 'aaaaaaaa-0000-4000-8000-000000000001','k-vol');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000005', 'cccccccc-0000-4000-8000-000000000005','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000006', 400000003, 'aaaaaaaa-0000-4000-8000-000000000001','k-px');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000006', 'cccccccc-0000-4000-8000-000000000006','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000007', 400000004, 'aaaaaaaa-0000-4000-8000-000000000001','k-side');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000007', 'cccccccc-0000-4000-8000-000000000007','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000008', 400000005, 'aaaaaaaa-0000-4000-8000-000000000001','k-sym');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000008', 'cccccccc-0000-4000-8000-000000000008','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000009', 400000006, 'aaaaaaaa-0000-4000-8000-000000000001','k-time');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000009', 'cccccccc-0000-4000-8000-000000000009','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000010', 400000007, 'aaaaaaaa-0000-4000-8000-000000000001','k-csize');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000010', 'cccccccc-0000-4000-8000-000000000010','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000011', 400000008, 'aaaaaaaa-0000-4000-8000-000000000001','k-nomap');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000011', 'cccccccc-0000-4000-8000-000000000011','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000012', 400000009, 'aaaaaaaa-0000-4000-8000-000000000001','k-ambig');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000012', 'cccccccc-0000-4000-8000-000000000012','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000014', 400000010, 'aaaaaaaa-0000-4000-8000-000000000001','k-csmis');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000014', 'cccccccc-0000-4000-8000-000000000014','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000015', 400000011, 'aaaaaaaa-0000-4000-8000-000000000001','k-incomplete');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000015', 'cccccccc-0000-4000-8000-000000000015','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000016', 400000012, 'aaaaaaaa-0000-4000-8000-000000000001','k-badsize');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000016', 'cccccccc-0000-4000-8000-000000000016','journal_add');

  -- a capture whose basis run holds NO position row for it
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000017', 499999999, 'aaaaaaaa-0000-4000-8000-000000000001','k-nobasis');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000017', 'cccccccc-0000-4000-8000-000000000017','journal_add');

  -- spares: H (reserved-id collision), I1 (trade-uk handler), I2 (unknown-constraint handler),
  -- J (duplicate catalog)
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000020', 400000020, 'aaaaaaaa-0000-4000-8000-000000000001','k-spare20');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000020', 'cccccccc-0000-4000-8000-000000000020','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000021', 400000021, 'aaaaaaaa-0000-4000-8000-000000000001','k-spare21');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000021', 'cccccccc-0000-4000-8000-000000000021','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000022', 400000022, 'aaaaaaaa-0000-4000-8000-000000000001','k-spare22');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000022', 'cccccccc-0000-4000-8000-000000000022','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000023', 400000023, 'aaaaaaaa-0000-4000-8000-000000000001','k-spare23');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000023', 'cccccccc-0000-4000-8000-000000000023','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000024', 400000024, 'aaaaaaaa-0000-4000-8000-000000000001','k-spare24');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000024', 'cccccccc-0000-4000-8000-000000000024','journal_add');
  perform pg_temp.mkcap('cccccccc-0000-4000-8000-000000000025', 400000025, 'aaaaaaaa-0000-4000-8000-000000000001','k-spare25');
  perform pg_temp.mkdec('dddddddd-0000-4000-8000-000000000025', 'cccccccc-0000-4000-8000-000000000025','journal_add');
end $seed$;

-- ---------------------------------------------------------------------------------------------
-- A. SUCCESS + exact Journal shape
-- ---------------------------------------------------------------------------------------------
do $case_a$
declare
  r record; t record; raw jsonb; p record;
  DEC constant uuid := 'dddddddd-0000-4000-8000-000000000001';
begin
  select * into r from public.mt5_promote_capture_decision_v1(DEC);
  perform pg_temp.chk(r.o_ok, 'A1 happy path o_ok');
  perform pg_temp.chk(r.o_inserted = 1, 'A2 o_inserted = 1', r.o_inserted::text);
  perform pg_temp.chk(r.o_promotion_id is not null, 'A3 promotion id returned');
  perform pg_temp.chk(r.o_trade_id is not null, 'A4 trade id returned');
  perform pg_temp.chk(r.o_existing_decision_id is null, 'A5 no existing-decision on first insert');
  perform pg_temp.chk(r.o_error_code is null, 'A6 no error code');
  perform pg_temp.chk(r.o_trade_id ~ '^mt5p_[0-9a-f]{32}$',
                      'A7 trade id is in the RESERVED namespace', r.o_trade_id);
  perform pg_temp.chk(r.o_trade_id = pg_temp.reserved(DEC),
                      'A7b trade id is DETERMINISTIC from the decision id', r.o_trade_id);

  select * into t from public.trades where id = r.o_trade_id;
  perform pg_temp.chk(found, 'A8 the Journal row exists');
  perform pg_temp.chk(t.user_id = '11111111-1111-4111-8111-111111111111', 'A9 owner is the capture scope');
  perform pg_temp.chk(t.product_id = 's50_next', 'A10 product mapped to the NEXT series', t.product_id);
  perform pg_temp.chk(t.direction = 'Long', 'A11 buy -> Long', t.direction);
  perform pg_temp.chk(t.status = 'open', 'A12 status open', t.status);
  perform pg_temp.chk(t.contracts = 5, 'A13 contracts = basis volume', t.contracts::text);
  perform pg_temp.chk(t.remaining_contracts = 5, 'A14 remaining = contracts', t.remaining_contracts::text);
  perform pg_temp.chk(t.entry_price = 1067.3, 'A15 entry_price = basis price_open', t.entry_price::text);
  perform pg_temp.chk(t.exit_price is null, 'A16 exit_price null');
  perform pg_temp.chk(t.entry_date is null, 'A17 entry_date NULL (app contract: 0/155 non-null)');
  perform pg_temp.chk(t.exit_date is null, 'A18 exit_date NULL');
  perform pg_temp.chk(t.note is null, 'A19 note NULL');
  perform pg_temp.chk(t.group_id is null, 'A20 group_id NULL — no grouping shortcut');
  perform pg_temp.chk(t.current_price is null, 'A21 legacy current_price column stays NULL');
  perform pg_temp.chk(t.mt5_promotion_id = r.o_promotion_id,
                      'A21b the incarnation marker is the promotion id');

  raw := t.raw;
  perform pg_temp.chk(raw->>'id' = t.id, 'A22 raw.id equals the column id');
  perform pg_temp.chk(raw->>'status' = 'open', 'A23 raw.status open');
  perform pg_temp.chk(raw->>'productId' = 's50_next', 'A24 raw.productId');
  perform pg_temp.chk(raw->>'direction' = 'Long', 'A25 raw.direction');
  perform pg_temp.chk((raw->>'contracts')::numeric = 5, 'A26 raw.contracts');
  perform pg_temp.chk((raw->>'entryPrice')::numeric = 1067.3, 'A27 raw.entryPrice');
  perform pg_temp.chk((raw->>'currentPrice')::numeric = 1067.3,
                      'A28 raw.currentPrice mirrors entryPrice (app default, NOT the S1 mark)');
  perform pg_temp.chk(raw->>'contractCode' = 'S50U26', 'A29 raw.contractCode');
  perform pg_temp.chk(raw->>'mt5PositionId' = '312261388', 'A30 raw.mt5PositionId');
  perform pg_temp.chk(raw->>'openDateTime' = '2026-08-24T10:36',
                      'A31 openDateTime is Bangkok wall time, minute precision', raw->>'openDateTime');
  perform pg_temp.chk(raw->'stopLoss' = 'null'::jsonb, 'A32 stopLoss null');
  perform pg_temp.chk(raw->'takeProfit' = 'null'::jsonb, 'A33 takeProfit null');
  perform pg_temp.chk(raw->>'setupType' = 'Other', 'A34 setupType default');
  perform pg_temp.chk(raw->>'preNote' = '', 'A35 preNote empty');
  perform pg_temp.chk(raw->'preImages' = '[]'::jsonb and raw->'postImages' = '[]'::jsonb,
                      'A36 image arrays empty');
  perform pg_temp.chk(raw->'partialCloses' = '[]'::jsonb, 'A37 partialCloses empty — S2 owns them');
  perform pg_temp.chk(raw->'isMerged' = 'false'::jsonb and raw->'mergedFromIds' = '[]'::jsonb
                      and raw->'subTrades' = '[]'::jsonb, 'A38 merge fields empty');
  perform pg_temp.chk((select count(*) from jsonb_object_keys(raw)) = 20,
                      'A39 raw has EXACTLY the 19 buildTrade keys + mt5PositionId',
                      (select count(*)::text from jsonb_object_keys(raw)));
  -- no lifecycle / P&L leakage anywhere in raw
  perform pg_temp.chk(not (raw ?| array['exitPrice','exitDateTime','profit','brokerProfit',
                                        'commission','swap','fee','realizedPL','closePrice']),
                      'A40 no close/P&L/fee key leaked into raw');
  perform pg_temp.chk(raw::text not like '%1071.6%' and raw::text not like '%4300%',
                      'A41 the S1 price_current / profit marks appear nowhere');
  -- the marker must never leak into the app-visible payload: db.loadAll rehydrates from raw and
  -- toTradeRow writes raw:t, so a marker inside raw would be echoed straight back on the next save
  perform pg_temp.chk(not (raw ? 'mt5_promotion_id') and not (raw ? 'mt5PromotionId'),
                      'A41b the incarnation marker is NOT inside raw — it is a projected column');

  select * into p from public.mt5_capture_promotions where id = r.o_promotion_id;
  perform pg_temp.chk(p.decision_id = DEC, 'A42 ledger decision');
  perform pg_temp.chk(p.capture_event_id = 'cccccccc-0000-4000-8000-000000000001', 'A43 ledger capture');
  perform pg_temp.chk(p.trade_id = t.id, 'A44 ledger trade id');
  perform pg_temp.chk(p.position_id = 312261388 and p.source_account = '301102520',
                      'A45 ledger durable MT5 identity');
  perform pg_temp.chk(p.basis_run_id = 'aaaaaaaa-0000-4000-8000-000000000001', 'A46 ledger basis run');
  perform pg_temp.chk(p.fresh_run_id = 'aaaaaaaa-0000-4000-8000-000000000002', 'A47 ledger fresh run');
  perform pg_temp.chk((select count(*) from public.trades) = 1, 'A48 exactly one Journal row exists');
  perform pg_temp.chk((select count(*) from public.mt5_capture_promotions) = 1,
                      'A49 exactly one promotion row exists');
end $case_a$;

-- ---------------------------------------------------------------------------------------------
-- B. REPLAY — same decision, including after the freshness window would have failed
-- ---------------------------------------------------------------------------------------------
do $case_b$
declare
  r1 record; r2 record; t_before jsonb; t_after jsonb; v_marker uuid;
begin
  select * into r1 from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(r1.o_ok and r1.o_inserted = 0, 'B1 replay: ok, inserted 0');
  perform pg_temp.chk(r1.o_error_code is null, 'B2 replay has no error code');
  perform pg_temp.chk((select count(*) from public.trades) = 1, 'B3 replay created no second trade');
  perform pg_temp.chk((select count(*) from public.mt5_capture_promotions) = 1,
                      'B4 replay created no second promotion');

  -- age BOTH runs far past the window, and delete the position from the fresh run: a first
  -- promotion would now fail every eligibility gate. Replay must still succeed.
  update public.mt5_sync_runs set captured_at = now() - interval '30 days';
  delete from public.mt5_sync_run_positions
   where run_id = 'aaaaaaaa-0000-4000-8000-000000000002' and position_id = 312261388;
  select raw into t_before from public.trades limit 1;
  select * into r2 from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(r2.o_ok and r2.o_inserted = 0,
                      'B5 replay still succeeds after the evidence goes stale AND the position vanishes');
  perform pg_temp.chk(r2.o_trade_id = r1.o_trade_id and r2.o_promotion_id = r1.o_promotion_id,
                      'B6 replay returns the SAME promotion and trade identity');
  select raw into t_after from public.trades limit 1;
  perform pg_temp.chk(t_before = t_after, 'B7 replay mutated nothing on the trade');

  -- a user edit must NOT break replay: replay checks incarnation and ownership, never contents
  update public.trades set raw = raw || jsonb_build_object('preNote','edited by the human',
                                                           'entryPrice', 999),
                           entry_price = 999;
  select * into r2 from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(r2.o_ok and r2.o_inserted = 0 and r2.o_error_code is null,
                      'B8 replay survives ordinary user edits to the trade');

  -- B9/B10: THE ORDINARY BROWSER SAVE. raw is rewritten wholesale through the 19-key buildTrade
  -- shape, which DROPS raw.mt5PositionId, and mt5_promotion_id is not in the payload at all.
  select mt5_promotion_id into v_marker from public.trades limit 1;
  perform pg_temp.browser_save(
    r1.o_trade_id, '11111111-1111-4111-8111-111111111111',
    (select raw - 'mt5PositionId' || jsonb_build_object('preNote','rewritten by the app')
       from public.trades limit 1));
  perform pg_temp.chk(not ((select raw from public.trades limit 1) ? 'mt5PositionId'),
                      'B9 an ordinary browser save drops raw.mt5PositionId, as the app really does');
  perform pg_temp.chk((select mt5_promotion_id from public.trades limit 1) = v_marker,
                      'B10 ...but the incarnation marker SURVIVES the upsert (not in the SET list)');
  select * into r2 from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(r2.o_ok and r2.o_inserted = 0 and r2.o_error_code is null,
                      'B11 replay still clean after a full browser rewrite of raw');

  -- B12: S2 ATTACHMENT AUTHORITY. With raw.mt5PositionId gone, the durable MT5 identity must
  -- still resolve to the exact trade — through the LEDGER, which no user action can rewrite.
  perform pg_temp.chk(
    (select p.trade_id from public.mt5_capture_promotions p
      where p.user_id = '11111111-1111-4111-8111-111111111111'
        and p.source_account = '301102520' and p.position_id = 312261388) = r1.o_trade_id,
    'B12 S2 join (user, account, position) -> trade_id resolves via the ledger, not via raw');

  -- restore the world for the remaining cases
  update public.trades set raw = t_before, entry_price = 1067.3;
  update public.mt5_sync_runs set captured_at = now() - interval '90 minutes'
   where id = 'aaaaaaaa-0000-4000-8000-000000000001';
  update public.mt5_sync_runs set captured_at = now() - interval '10 minutes'
   where id = 'aaaaaaaa-0000-4000-8000-000000000002';
  perform pg_temp.mkpos('aaaaaaaa-0000-4000-8000-000000000002', 312261388,
                        'S50U26','buy',5,1067.3, timestamptz '2026-08-24 03:36:12+00',200);
end $case_b$;

-- ---------------------------------------------------------------------------------------------
-- C. DUAL IDENTITY — a different decision for the SAME durable MT5 position
-- ---------------------------------------------------------------------------------------------
do $case_c$
declare r record;
begin
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000002');
  perform pg_temp.chk(not r.o_ok, 'C1 second decision for the same position is refused');
  perform pg_temp.chk(r.o_inserted = 0, 'C2 nothing inserted');
  perform pg_temp.chk(r.o_error_code = 'ERR_POSITION_ALREADY_PROMOTED', 'C3 dedicated error code',
                      r.o_error_code);
  perform pg_temp.chk(r.o_existing_decision_id = 'dddddddd-0000-4000-8000-000000000001',
                      'C4 names the decision that DID fulfil it');
  perform pg_temp.chk(r.o_promotion_id is not null and r.o_trade_id is not null,
                      'C5 names the existing promotion and trade');
  perform pg_temp.chk((select count(*) from public.trades) = 1, 'C6 still exactly ONE Journal row');
  perform pg_temp.chk((select count(*) from public.mt5_capture_promotions) = 1,
                      'C7 still exactly ONE promotion');
  perform pg_temp.chk(not exists (select 1 from public.mt5_capture_promotions
                                   where decision_id = 'dddddddd-0000-4000-8000-000000000002'),
                      'C8 the refused decision is NOT recorded as fulfilled');
  -- and the reserved address of the refused decision was never occupied
  perform pg_temp.chk(not exists (select 1 from public.trades
                                   where id = pg_temp.reserved('dddddddd-0000-4000-8000-000000000002')),
                      'C9 the refused decision never minted its reserved trade id');
end $case_c$;

-- ---------------------------------------------------------------------------------------------
-- D. REJECTIONS
-- ---------------------------------------------------------------------------------------------
do $case_d$
declare
  r record;
  v_trades_before bigint;
  cases constant text[][] := array[
    ['dddddddd-0000-4000-8000-000000000003','ERR_NOT_JOURNAL_ADD','already_logged decision'],
    ['dddddddd-0000-4000-8000-000000000013','ERR_NOT_JOURNAL_ADD','no_record decision'],
    ['dddddddd-0000-4000-8000-000000000004','ERR_POSITION_ABSENT','position absent from the fresh run'],
    ['dddddddd-0000-4000-8000-000000000005','ERR_POSITION_FACT_DRIFT','volume drift'],
    ['dddddddd-0000-4000-8000-000000000006','ERR_POSITION_FACT_DRIFT','price_open drift'],
    ['dddddddd-0000-4000-8000-000000000007','ERR_POSITION_FACT_DRIFT','side drift'],
    ['dddddddd-0000-4000-8000-000000000008','ERR_POSITION_FACT_DRIFT','symbol drift'],
    ['dddddddd-0000-4000-8000-000000000009','ERR_POSITION_FACT_DRIFT','open_time drift'],
    ['dddddddd-0000-4000-8000-000000000010','ERR_POSITION_FACT_DRIFT','contract_size drift'],
    ['dddddddd-0000-4000-8000-000000000011','ERR_PRODUCT_MAPPING','no catalog match'],
    ['dddddddd-0000-4000-8000-000000000012','ERR_PRODUCT_MAPPING','ambiguous catalog match'],
    ['dddddddd-0000-4000-8000-000000000014','ERR_PRODUCT_MAPPING','catalog contract-size mismatch'],
    ['dddddddd-0000-4000-8000-000000000016','ERR_PRODUCT_MAPPING','non-numeric catalog contractSize'],
    ['dddddddd-0000-4000-8000-000000000015','ERR_BASIS_INCOMPLETE','basis price_open is null'],
    ['dddddddd-0000-4000-8000-000000000017','ERR_BASIS_NOT_FOUND','no basis position row']
  ];
  i int;
begin
  select count(*) into v_trades_before from public.trades;
  for i in 1 .. array_length(cases, 1) loop
    select * into r from public.mt5_promote_capture_decision_v1(cases[i][1]::uuid);
    perform pg_temp.chk(not r.o_ok and r.o_inserted = 0 and r.o_error_code = cases[i][2],
                        'D' || i || ' ' || cases[i][3] || ' -> ' || cases[i][2],
                        coalesce(r.o_error_code, '(null)'));
    perform pg_temp.chk(r.o_trade_id is null and r.o_promotion_id is null,
                        'D' || i || 'b ' || cases[i][3] || ': no identities returned');
    perform pg_temp.chk(not exists (select 1 from public.trades
                                     where id = pg_temp.reserved(cases[i][1]::uuid)),
                        'D' || i || 'c ' || cases[i][3] || ': reserved address left free');
  end loop;
  perform pg_temp.chk((select count(*) from public.trades) = v_trades_before,
                      'D-total: no rejection created a Journal row');
  perform pg_temp.chk((select count(*) from public.mt5_capture_promotions) = 1,
                      'D-total: no rejection created a promotion row');

  -- unknown decision / null input
  select * into r from public.mt5_promote_capture_decision_v1('00000000-0000-4000-8000-000000000000');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_DECISION_NOT_FOUND',
                      'D16 unknown decision id', r.o_error_code);
  select * into r from public.mt5_promote_capture_decision_v1(null);
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_BAD_INPUT', 'D17 null decision id',
                      r.o_error_code);
end $case_d$;

-- ---------------------------------------------------------------------------------------------
-- E. FRESHNESS — the newest run rules, whatever its state; wall-clock boundary
-- ---------------------------------------------------------------------------------------------
do $case_e$
declare r record; v_dec constant uuid := 'dddddddd-0000-4000-8000-000000000005';
begin
  -- make the volume-drift position clean so ONLY freshness is under test
  update public.mt5_sync_run_positions set volume = 5
   where run_id = 'aaaaaaaa-0000-4000-8000-000000000002' and position_id = 400000002;
  select * into r from public.mt5_promote_capture_decision_v1(v_dec);
  perform pg_temp.chk(r.o_ok and r.o_inserted = 1, 'E1 control: the cleaned case promotes');
  perform pg_temp.chk((select count(*) from public.trades) = 2, 'E2 a second POSITION may promote');
  perform pg_temp.chk((select count(*) from public.mt5_capture_promotions) = 2, 'E3 two promotions');

  -- E4: a NEWER run that is 'started' must NOT be skipped in favour of the older healthy one
  perform pg_temp.mkrun('aaaaaaaa-0000-4000-8000-000000000003', 5, interval '1 minute', 'started');
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000006');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_STALE_EVIDENCE',
                      'E4 newer INCOMPLETE run is not skipped for an older healthy one',
                      r.o_error_code);
  delete from public.mt5_sync_runs where id = 'aaaaaaaa-0000-4000-8000-000000000003';

  -- E5: a NEWER complete-but-SUSPICIOUS run likewise blocks
  perform pg_temp.mkrun('aaaaaaaa-0000-4000-8000-000000000004', 6, interval '1 minute',
                        'complete', 'suspicious');
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000006');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_STALE_EVIDENCE',
                      'E5 newer SUSPICIOUS run blocks promotion', r.o_error_code);
  delete from public.mt5_sync_run_positions where run_id = 'aaaaaaaa-0000-4000-8000-000000000004';
  delete from public.mt5_sync_runs where id = 'aaaaaaaa-0000-4000-8000-000000000004';

  -- E6/E6b: THE 7200-SECOND BOUNDARY, measured against the same wall clock the RPC uses.
  -- The rule is `age > window -> stale`, so age = 7200s exactly is fresh. Exact equality is not
  -- observable from a test (any statement takes time), so the boundary is pinned from both sides
  -- at 100 ms: just inside is fresh, just outside is stale. BOTH runs are aged — ageing only the
  -- newer one would simply make the older basis run the newest, and that one is healthy and
  -- in-window, so the call would legitimately succeed and prove nothing about staleness.
  update public.mt5_sync_runs set captured_at = clock_timestamp() - interval '4 hours'
   where id = 'aaaaaaaa-0000-4000-8000-000000000001';
  update public.mt5_sync_runs
     set captured_at = clock_timestamp() - interval '7200 seconds' + interval '100 milliseconds'
   where id = 'aaaaaaaa-0000-4000-8000-000000000002';
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000006');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_POSITION_FACT_DRIFT',
                      'E6 100ms INSIDE the 7200s boundary is FRESH (fails later, on drift)',
                      r.o_error_code);
  update public.mt5_sync_runs
     set captured_at = clock_timestamp() - interval '7200 seconds' - interval '100 milliseconds'
   where id = 'aaaaaaaa-0000-4000-8000-000000000002';
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000006');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_STALE_EVIDENCE',
                      'E6b 100ms OUTSIDE the 7200s boundary is STALE', r.o_error_code);
  -- E6c: the operator is `>` and not `>=`, so exactly 7200s is admitted by construction
  perform pg_temp.chk(
    pg_temp.src('mt5_promote_capture_decision_v1')
      like '%v_age > public.mt5_t4b_freshness_window_v1()%',
    'E6c the boundary comparison is strictly `>`, so age = 7200s exactly is fresh');

  -- E7: a future-dated run (clock skew) is refused, never treated as maximally fresh
  update public.mt5_sync_runs set captured_at = now() + interval '10 minutes'
   where id = 'aaaaaaaa-0000-4000-8000-000000000002';
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000006');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_STALE_EVIDENCE',
                      'E7 future-dated run is refused', r.o_error_code);
  update public.mt5_sync_runs set captured_at = now() - interval '90 minutes'
   where id = 'aaaaaaaa-0000-4000-8000-000000000001';
  update public.mt5_sync_runs set captured_at = now() - interval '10 minutes'
   where id = 'aaaaaaaa-0000-4000-8000-000000000002';

  -- E9: with the world restored, the same decision now reaches the drift gate — proving E6b/E7
  -- failed on freshness and not on some unrelated permanent condition.
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000006');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_POSITION_FACT_DRIFT',
                      'E9 control: back in-window, the price-drift case fails on DRIFT, not staleness',
                      r.o_error_code);

  -- E8: window value is exactly 2h and is not a caller input
  perform pg_temp.chk(public.mt5_t4b_freshness_window_v1() = interval '7200 seconds',
                      'E8 freshness window is the frozen 7200 seconds');
  -- E10: the eligibility clock is wall clock, not transaction-start time
  perform pg_temp.chk(
    pg_temp.src('mt5_promote_capture_decision_v1') like '%v_now := clock_timestamp();%',
    'E10 eligibility uses clock_timestamp(), which survives a long lock wait');
end $case_e$;

-- ---------------------------------------------------------------------------------------------
-- F. FULFILLMENT DRIFT — the ledger says fulfilled but the object is not the same incarnation
-- ---------------------------------------------------------------------------------------------
do $case_f$
declare
  r record; v_trade text; v_raw jsonb; v_t record; v_before bigint; v_promo uuid;
  U constant uuid := '11111111-1111-4111-8111-111111111111';
begin
  select count(*) into v_before from public.trades;
  select trade_id, id into v_trade, v_promo from public.mt5_capture_promotions
   where decision_id = 'dddddddd-0000-4000-8000-000000000001';
  select * into v_t from public.trades where id = v_trade;
  v_raw := v_t.raw;
  delete from public.trades where id = v_trade;

  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_FULFILLMENT_DRIFT',
                      'F1 deleted fulfilled trade -> ERR_FULFILLMENT_DRIFT', r.o_error_code);
  perform pg_temp.chk(r.o_trade_id = v_trade and r.o_promotion_id is not null,
                      'F2 drift result still names the lost identity');
  perform pg_temp.chk(not exists (select 1 from public.trades where id = v_trade),
                      'F3 the deleted trade was NOT silently recreated');
  perform pg_temp.chk((select count(*) from public.trades) = v_before - 1,
                      'F4 no second trade was created either — only the deleted one is missing',
                      (select count(*)::text from public.trades));

  -- F5: THE REVERSED EXPECTATION. Revision 1 asserted that re-creating a row with the same id
  -- restored a clean replay — which was the defect: any same-owner row reusing the address was
  -- accepted as the fulfilled object. It must now be DRIFT, because the recreated row carries no
  -- incarnation authority.
  perform pg_temp.browser_save(v_trade, U, v_raw);
  perform pg_temp.chk((select mt5_promotion_id from public.trades where id = v_trade) is null,
                      'F5 a recreated row has NO incarnation marker (insert path, default NULL)');
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_FULFILLMENT_DRIFT',
                      'F6 delete + re-insert of the SAME id by the SAME owner is DRIFT, not replay',
                      r.o_error_code);
  perform pg_temp.chk((select count(*) from public.trades) = v_before,
                      'F7 the drift verdict created no new trade');
  perform pg_temp.chk((select count(*) from public.mt5_capture_promotions) = 2,
                      'F8 the drift verdict created no new promotion');

  -- F9: ownership drift. A row owned by somebody else cannot even carry the marker (the insert
  -- guard requires p.user_id = new.user_id), so a foreign row is drift on two independent counts.
  delete from public.trades where id = v_trade;
  insert into public.trades(id, user_id, raw) values (v_trade, gen_random_uuid(), v_raw);
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_FULFILLMENT_DRIFT',
                      'F9 trade owned by another user -> drift', r.o_error_code);
  delete from public.trades where id = v_trade;

  -- F10/F11: THE FORGERY, AND WHY IT NO LONGER WORKS.
  --
  -- Writing the marker back restores a clean replay — that is unavoidable and correct, because a
  -- row carrying the right marker IS the right incarnation. What must not be possible is a CLIENT
  -- doing it: an authenticated owner who can write the column could read their own marker, delete
  -- the trade, re-insert the same (id, user_id, mt5_promotion_id) tuple, and manufacture a clean
  -- replay against a row T4B never created. The guard trigger cannot distinguish that from the
  -- original write, so the marker is simply not in any client role's writable column set.
  --
  -- First: prove the client cannot do it.
  if to_regrole('authenticated') is not null then
    perform pg_temp.chk(
      not has_column_privilege('authenticated', 'public.trades', 'mt5_promotion_id', 'INSERT'),
      'F10 an authenticated client cannot INSERT trades.mt5_promotion_id');
    perform pg_temp.chk(
      not has_column_privilege('authenticated', 'public.trades', 'mt5_promotion_id', 'UPDATE'),
      'F11 an authenticated client cannot UPDATE trades.mt5_promotion_id');
    perform pg_temp.chk(
      has_column_privilege('authenticated', 'public.trades', 'raw', 'INSERT')
      and has_column_privilege('authenticated', 'public.trades', 'raw', 'UPDATE')
      and has_column_privilege('authenticated', 'public.trades', 'entry_price', 'UPDATE'),
      'F12 ...while every column the app actually writes stays writable');
  end if;

  -- Then: as the TABLE OWNER — which is what the SECURITY DEFINER RPC is, and what no client can
  -- become — restoring the original incarnation restores clean replay.
  insert into public.trades(id, user_id, product_id, direction, status, contracts,
                            remaining_contracts, entry_price, raw, mt5_promotion_id)
  values (v_trade, U, 's50_next', 'Long', 'open', 5, 5, 1067.3, v_raw, v_promo);
  select * into r from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-000000000001');
  perform pg_temp.chk(r.o_ok and r.o_inserted = 0,
                      'F13 an owner-restored original incarnation replays cleanly');
end $case_f$;

-- ---------------------------------------------------------------------------------------------
-- H. TRADE-ID NAMESPACE + INCARNATION AUTHORITY
-- ---------------------------------------------------------------------------------------------
do $case_h$
declare
  r record; v_browser text; v_reserved text; v_ok boolean; v_marker uuid; v_raw jsonb;
  v_role text; v_leaks text[] := array[]::text[];
  U constant uuid := '11111111-1111-4111-8111-111111111111';
  SPARE constant uuid := 'dddddddd-0000-4000-8000-000000000020';
begin
  -- H1: the browser's generator, run at this very millisecond, cannot produce a reserved id.
  v_browser := (extract(epoch from clock_timestamp()) * 1000)::bigint::text;
  v_reserved := pg_temp.reserved(SPARE);
  perform pg_temp.chk(v_browser ~ '^[0-9]{13,}$',
                      'H1 the browser uid() shape is decimal digits only', v_browser);
  perform pg_temp.chk(v_reserved ~ '^mt5p_[0-9a-f]{32}$',
                      'H2 the reserved shape is mt5p_ + 32 hex', v_reserved);
  perform pg_temp.chk(v_browser <> v_reserved and v_reserved !~ '^[0-9]',
                      'H3 the two namespaces are DISJOINT at the same millisecond');
  -- H4: the app refuses to persist demo trades whose ids match /^m\d+$/. A reserved id must not
  -- be mistaken for one — this is why the prefix is not, say, "m5" or "mt5".
  perform pg_temp.chk(v_reserved !~ '^m[0-9]+$',
                      'H4 a reserved id does not match the app demo-trade guard /^m\d+$/');
  -- and a browser-minted row can coexist with promoted rows without any interaction
  perform pg_temp.browser_save(v_browser, U, jsonb_build_object('id', v_browser, 'status','open'));
  perform pg_temp.chk(exists (select 1 from public.trades where id = v_browser)
                      and exists (select 1 from public.trades where id ~ '^mt5p_'),
                      'H5 a browser-minted trade coexists with promoted trades');
  perform pg_temp.chk((select mt5_promotion_id from public.trades where id = v_browser) is null,
                      'H6 an ordinary browser trade carries no incarnation marker');

  -- H7: THE RESERVED ADDRESS IS OCCUPIED by an unrelated row before promotion. Fail closed —
  -- never overwrite, never adopt, never treat as replay, never pick a nearby id.
  perform pg_temp.browser_save(v_reserved, U,
    jsonb_build_object('id', v_reserved, 'status','open','preNote','a pre-existing stranger'));
  select * into r from public.mt5_promote_capture_decision_v1(SPARE);
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_TRADE_ID_COLLISION',
                      'H7 an occupied reserved address is ERR_TRADE_ID_COLLISION', r.o_error_code);
  perform pg_temp.chk(r.o_trade_id = v_reserved, 'H8 the collision names the address');
  perform pg_temp.chk(
    (select raw->>'preNote' from public.trades where id = v_reserved) = 'a pre-existing stranger',
    'H9 the occupying row was NOT overwritten');
  perform pg_temp.chk(not exists (select 1 from public.mt5_capture_promotions
                                   where decision_id = SPARE),
                      'H10 no promotion was recorded for the colliding decision');
  delete from public.trades where id = v_reserved;

  -- H11: with the address freed, the same decision promotes to exactly that address.
  select * into r from public.mt5_promote_capture_decision_v1(SPARE);
  perform pg_temp.chk(r.o_ok and r.o_trade_id = v_reserved,
                      'H11 once free, the decision promotes to its deterministic address');
  v_marker := r.o_promotion_id;

  -- H12: THE MARKER IS IMMUTABLE. It cannot be changed...
  begin
    update public.trades set mt5_promotion_id = gen_random_uuid() where id = v_reserved;
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_IMMUTABLE_INCARNATION%');
  end;
  perform pg_temp.chk(v_ok, 'H12 the incarnation marker cannot be REPLACED by an update');
  -- ...nor cleared...
  begin
    update public.trades set mt5_promotion_id = null where id = v_reserved;
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_IMMUTABLE_INCARNATION%');
  end;
  perform pg_temp.chk(v_ok, 'H13 the incarnation marker cannot be CLEARED by an update');
  -- ...nor granted to an ordinary trade that never had one.
  begin
    update public.trades set mt5_promotion_id = v_marker where id = v_browser;
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_IMMUTABLE_INCARNATION%');
  end;
  perform pg_temp.chk(v_ok, 'H14 a marker cannot be ADDED to an existing row by an update');

  -- H15: THE MARKER IS UNFORGEABLE ON INSERT — no ledger row, no marker.
  begin
    insert into public.trades(id, user_id, raw, mt5_promotion_id)
    values ('forged-1', U, '{}'::jsonb, gen_random_uuid());
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_FORGED_INCARNATION%');
  end;
  perform pg_temp.chk(v_ok, 'H15 an invented marker is rejected on INSERT');
  -- H16: even a REAL promotion id cannot be attached to a different trade id...
  begin
    insert into public.trades(id, user_id, raw, mt5_promotion_id)
    values ('forged-2', U, '{}'::jsonb, v_marker);
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_FORGED_INCARNATION%');
  end;
  perform pg_temp.chk(v_ok, 'H16 a real marker cannot be attached to a different trade id');
  -- H17: ...nor to a different owner.
  delete from public.trades where id = v_reserved;
  select raw into v_raw from public.trades limit 1;
  begin
    insert into public.trades(id, user_id, raw, mt5_promotion_id)
    values (v_reserved, gen_random_uuid(), coalesce(v_raw,'{}'::jsonb), v_marker);
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_FORGED_INCARNATION%');
  end;
  perform pg_temp.chk(v_ok, 'H17 a real marker cannot be attached under a different owner');

  -- H18: ordinary Journal writes are entirely unaffected by the guard.
  begin
    perform pg_temp.browser_save('ordinary-1', U, jsonb_build_object('id','ordinary-1'));
    update public.trades set note = 'edited freely', entry_price = 42 where id = 'ordinary-1';
    delete from public.trades where id = 'ordinary-1';
    v_ok := true;
  exception when others then v_ok := false;
  end;
  perform pg_temp.chk(v_ok, 'H18 insert/update/delete of an ordinary trade is untouched');

  -- H19: a promoted trade remains DELETABLE — the guard never blocks deletion.
  perform pg_temp.chk(not exists (select 1 from public.trades where id = v_reserved),
                      'H19 a promoted trade was deleted normally (H17 setup), no guard fired');
  perform pg_temp.chk(exists (select 1 from public.mt5_capture_promotions where id = v_marker),
                      'H20 ...and its ledger row survived the deletion');
  delete from public.trades where id = v_browser;

  -- H21-H24: THE PRIVILEGE that makes the marker unforgeable, asserted as an EFFECTIVE privilege.
  -- Reading attacl is not enough: only has_column_privilege resolves role membership, inherited
  -- grants and PUBLIC, and only the effective answer says whether a real session could write it.
  -- Superusers and PostgreSQL's predefined administrative roles (reserved pg_ prefix) are out of
  -- scope: pg_write_all_data can write every table by design, and that is what it is for.
  for v_role in select rolname from pg_roles
                 where not rolsuper and rolname not like 'pg\_%' and rolname <> current_user loop
    if has_column_privilege(v_role, 'public.trades', 'mt5_promotion_id', 'INSERT')
       or has_column_privilege(v_role, 'public.trades', 'mt5_promotion_id', 'UPDATE') then
      v_leaks := v_leaks || v_role;
    end if;
  end loop;
  perform pg_temp.chk(array_length(v_leaks, 1) is null,
                      'H21 NO non-superuser role can write trades.mt5_promotion_id',
                      array_to_string(v_leaks, ', '));
  perform pg_temp.chk(
    to_regrole('authenticated') is null
    or has_column_privilege('authenticated', 'public.trades', 'raw', 'INSERT'),
    'H22 the app can still INSERT trades.raw');
  perform pg_temp.chk(
    to_regrole('authenticated') is null
    or has_column_privilege('authenticated', 'public.trades', 'status', 'UPDATE'),
    'H23 the app can still UPDATE trades.status');
  perform pg_temp.chk(
    to_regrole('authenticated') is null
    or (has_table_privilege('authenticated', 'public.trades', 'SELECT')
        and has_table_privilege('authenticated', 'public.trades', 'DELETE')),
    'H24 SELECT and DELETE on trades are untouched by the narrowing');

  -- H25 — WITH GRANT OPTION survives the narrowing. The offline substrate deliberately contains a
  -- writer that holds INSERT with grant option; converting its table grant to column grants must
  -- carry that flag across, or the rollback could never restore the shape it found.
  perform pg_temp.chk(
    to_regrole('t4b_app_writer') is null
    or exists (select 1 from pg_attribute a, lateral aclexplode(a.attacl) x
                where a.attrelid = 'public.trades'::regclass and a.attname = 'raw'
                  and x.grantee = to_regrole('t4b_app_writer')::oid
                  and x.privilege_type = 'INSERT' and x.is_grantable),
    'H25 WITH GRANT OPTION is preserved when a table grant becomes column grants');
  -- H28 — the option that lived ONLY on the column entry survives too. Table UPDATE without a
  -- grant option plus UPDATE(raw) WITH GRANT OPTION must come back as UPDATE on every non-marker
  -- column with the option still on raw — not as a blanket, and not flattened to plain UPDATE.
  perform pg_temp.chk(
    to_regrole('t4b_app_writer') is null
    or exists (select 1 from pg_attribute a, lateral aclexplode(a.attacl) x
                where a.attrelid = 'public.trades'::regclass and a.attname = 'raw'
                  and x.grantee = to_regrole('t4b_app_writer')::oid
                  and x.privilege_type = 'UPDATE' and x.is_grantable),
    'H28 a grant option carried only by a COLUMN entry survives the narrowing');
  perform pg_temp.chk(
    to_regrole('t4b_app_writer') is null
    or exists (select 1 from pg_attribute a, lateral aclexplode(a.attacl) x
                where a.attrelid = 'public.trades'::regclass and a.attname = 'status'
                  and x.grantee = to_regrole('t4b_app_writer')::oid
                  and x.privilege_type = 'UPDATE' and not x.is_grantable),
    'H29 ...and is NOT spread to columns that never carried it');
  -- H26 — and that writer cannot reach the marker either. H21 already sweeps every role; this
  -- names the one that holds a grant option, because a grantable privilege is the one an attacker
  -- would use to widen the surface again.
  perform pg_temp.chk(
    to_regrole('t4b_app_writer') is null
    or not (has_column_privilege('t4b_app_writer', 'public.trades', 'mt5_promotion_id', 'INSERT')
            or has_column_privilege('t4b_app_writer', 'public.trades', 'mt5_promotion_id',
                                    'UPDATE')),
    'H26 the WITH GRANT OPTION writer cannot reach the marker either');
  -- H27 — the live invariant behind the grantor preflight: after the narrowing, every non-owner
  -- INSERT/UPDATE entry on public.trades is still owner-granted. If one were not, the rollback
  -- could not revoke it and no replay could rebuild its chain.
  perform pg_temp.chk(
    not exists (
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
                            where c.oid = 'public.trades'::regclass)),
    'H27 every non-owner INSERT/UPDATE grant on trades is still owner-granted');
end $case_h$;

-- ---------------------------------------------------------------------------------------------
-- I. THE CONSTRAINT-AWARE UNIQUE HANDLER
-- ---------------------------------------------------------------------------------------------
do $case_i$
declare
  r record; v_ok boolean; v_msg text;
  SPARE22 constant uuid := 'dddddddd-0000-4000-8000-000000000022';
  SPARE24 constant uuid := 'dddddddd-0000-4000-8000-000000000024';
  SPARE25 constant uuid := 'dddddddd-0000-4000-8000-000000000025';
  U constant uuid := '11111111-1111-4111-8111-111111111111';
begin
  -- I1: mt5_cp_trade_uk. An ORPHAN ledger row already claims SPARE22's reserved address while no
  -- trade row exists there, so every pre-check misses and the ledger INSERT is what conflicts.
  -- This reaches the handler for real rather than inspecting the source for a branch.
  -- (The orphan is never removed: the ledger is append-once and its guard blocks DELETE. Nothing
  -- later depends on SPARE22 or on position 499999998.)
  insert into public.mt5_capture_promotions(
    decision_id, capture_event_id, trade_id, user_id, source_account, position_id,
    basis_run_id, fresh_run_id)
  values ('dddddddd-0000-4000-8000-000000000023', 'cccccccc-0000-4000-8000-000000000023',
          pg_temp.reserved(SPARE22), U, '301102520', 499999998,
          'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002');
  select * into r from public.mt5_promote_capture_decision_v1(SPARE22);
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_TRADE_ID_COLLISION',
                      'I1 mt5_cp_trade_uk violation -> ERR_TRADE_ID_COLLISION (handler reached)',
                      r.o_error_code);
  perform pg_temp.chk(not exists (select 1 from public.trades where id = pg_temp.reserved(SPARE22)),
                      'I2 the failed attempt left no Journal row behind');
  perform pg_temp.chk(not exists (select 1 from public.mt5_capture_promotions
                                   where decision_id = SPARE22),
                      'I3 the failed attempt left no promotion behind');

  -- I4: AN UNKNOWN UNIQUE CONSTRAINT MUST RE-RAISE, never be translated into a frozen outcome.
  -- A second orphan occupies the predicate first, then a uniqueness rule T4B knows nothing about
  -- is added, and an otherwise-valid promotion trips it. A bare unique INDEX is used deliberately:
  -- it is not in pg_constraint at all, so it also exercises the "not a trades constraint either"
  -- fall-through to the final re-raise.
  insert into public.mt5_capture_promotions(
    decision_id, capture_event_id, trade_id, user_id, source_account, position_id,
    basis_run_id, fresh_run_id)
  values (SPARE25, 'cccccccc-0000-4000-8000-000000000025', pg_temp.reserved(SPARE25),
          U, '301102520', 499999997,
          'aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002');
  execute 'create unique index mt5_cp_unknown_test_uk on public.mt5_capture_promotions '
          '(source_account) where position_id in (499999997, 400000024)';
  begin
    select * into r from public.mt5_promote_capture_decision_v1(SPARE24);
    v_ok := false; v_msg := coalesce(r.o_error_code, '(no error code — it returned a result)');
  exception when unique_violation then
    v_ok := true;
    get stacked diagnostics v_msg = constraint_name;
  end;
  perform pg_temp.chk(v_ok, 'I4 an UNKNOWN unique violation propagates instead of being translated',
                      v_msg);
  perform pg_temp.chk(v_msg = 'mt5_cp_unknown_test_uk',
                      'I5 the re-raised error still names the real constraint', v_msg);
  execute 'drop index mt5_cp_unknown_test_uk';
  perform pg_temp.chk(not exists (select 1 from public.trades where id = pg_temp.reserved(SPARE24)),
                      'I5b the re-raised failure created no Journal row');

  -- I6-I9: structural properties of the handler, asserted against EXECUTABLE source only.
  perform pg_temp.chk(
    pg_temp.src('mt5_promote_capture_decision_v1')
      like '%get stacked diagnostics v_constraint = constraint_name;%',
    'I6 the handler reads CONSTRAINT_NAME from the diagnostics');
  perform pg_temp.chk(
    pg_temp.src('mt5_promote_capture_decision_v1') not ilike '%when others%',
    'I7 there is no `when others` anywhere in the executable promotion body');
  -- I8: the decision-uniqueness branch must call the shared validator, not a shallow lookup —
  -- otherwise the incarnation defect returns through the exception path.
  perform pg_temp.chk(
    (length(pg_temp.src('mt5_promote_capture_decision_v1'))
     - length(replace(pg_temp.src('mt5_promote_capture_decision_v1'),
                      'mt5_t4b_validate_fulfillment_v1', '')))
    / length('mt5_t4b_validate_fulfillment_v1') = 2,
    'I8 BOTH the replay path and the unique-race path call the shared incarnation validator',
    ((length(pg_temp.src('mt5_promote_capture_decision_v1'))
      - length(replace(pg_temp.src('mt5_promote_capture_decision_v1'),
                       'mt5_t4b_validate_fulfillment_v1', '')))
     / length('mt5_t4b_validate_fulfillment_v1'))::text);
  -- I9: ERR_PROMOTION_RACE is gone — an unknown defect is no longer given a known-looking name.
  perform pg_temp.chk(
    pg_temp.src('mt5_promote_capture_decision_v1') not like '%ERR_PROMOTION_RACE%',
    'I9 ERR_PROMOTION_RACE no longer exists');
end $case_i$;

-- ---------------------------------------------------------------------------------------------
-- J. PRODUCT CATALOG CARDINALITY
-- ---------------------------------------------------------------------------------------------
do $case_j$
declare
  r record;
  SPARE21 constant uuid := 'dddddddd-0000-4000-8000-000000000021';
  U constant uuid := '11111111-1111-4111-8111-111111111111';
  v_data jsonb;
begin
  -- J1: a duplicate catalog row for the user must FAIL CLOSED, never let PostgreSQL pick one.
  -- The PK is dropped only to make the adversarial state reachable at all.
  select data into v_data from public.products where user_id = U;
  execute 'alter table public.products drop constraint products_pkey';
  insert into public.products(user_id, data, updated_at)
  values (U, jsonb_build_array(jsonb_build_object('id','evil','baseSymbol','S50',
            'currentContract','S50M26','nextContract','S50U26','contractSize',999)), now());
  perform pg_temp.chk((select count(*) from public.products where user_id = U) = 2,
                      'J1 two catalog rows now exist for one user');
  select * into r from public.mt5_promote_capture_decision_v1(SPARE21);
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_PRODUCT_MAPPING',
                      'J2 a duplicated catalog is ERR_PRODUCT_MAPPING, not an arbitrary pick',
                      r.o_error_code);
  perform pg_temp.chk(not exists (select 1 from public.trades where id = pg_temp.reserved(SPARE21)),
                      'J3 no trade was created from an ambiguous catalog');

  -- J4: zero catalog rows is likewise a failure, not a null-product trade.
  delete from public.products where user_id = U;
  select * into r from public.mt5_promote_capture_decision_v1(SPARE21);
  perform pg_temp.chk(not r.o_ok and r.o_error_code = 'ERR_PRODUCT_MAPPING',
                      'J4 an absent catalog is ERR_PRODUCT_MAPPING', r.o_error_code);

  -- restore, and confirm the control: with exactly one catalog row the same call succeeds.
  insert into public.products(user_id, data, updated_at) values (U, v_data, now());
  execute 'alter table public.products add constraint products_pkey primary key (user_id)';
  select * into r from public.mt5_promote_capture_decision_v1(SPARE21);
  perform pg_temp.chk(r.o_ok and r.o_inserted = 1,
                      'J5 control: with exactly one catalog row the same decision promotes',
                      coalesce(r.o_error_code, 'ok'));

  -- J6: the structural guarantee the app already relies on is asserted, not assumed.
  perform pg_temp.chk(
    exists (select 1 from pg_constraint c
             where c.conrelid = 'public.products'::regclass and c.contype in ('p','u')
               and c.conkey = array[(select a.attnum from pg_attribute a
                                      where a.attrelid='public.products'::regclass
                                        and a.attname='user_id' and not a.attisdropped)]),
    'J6 products(user_id) carries a PK/UNIQUE constraint');
end $case_j$;

-- ---------------------------------------------------------------------------------------------
-- G. IMMUTABILITY + CALL SHAPE
-- ---------------------------------------------------------------------------------------------
do $case_g$
declare v_ok boolean; v_id uuid;
begin
  select id into v_id from public.mt5_capture_promotions limit 1;
  begin
    update public.mt5_capture_promotions set trade_id = 'mt5p_ffffffffffffffffffffffffffffffff'
     where id = v_id;
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_IMMUTABLE_ROW%');
  end;
  perform pg_temp.chk(v_ok, 'G1 UPDATE on a promotion row is blocked by the guard');
  begin
    delete from public.mt5_capture_promotions where id = v_id;
    v_ok := false;
  exception when others then v_ok := (sqlerrm like '%MT5_T4B_IMMUTABLE_ROW%');
  end;
  perform pg_temp.chk(v_ok, 'G2 DELETE on a promotion row is blocked by the guard');

  -- the RPC has exactly one argument: no override of symbol/price/volume/product/trade id exists
  perform pg_temp.chk(
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname='public' and p.proname='mt5_promote_capture_decision_v1'
               and p.pronargs = 1
               and (select t.typname from pg_type t where t.oid = p.proargtypes[0]) = 'uuid'),
    'G3 promotion RPC takes exactly one uuid argument — no caller-supplied facts');
  perform pg_temp.chk(
    (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='mt5_promote_capture_decision_v1') = 1,
    'G4 exactly one overload exists');

  -- G5: every promoted trade that still exists carries its own promotion's marker
  perform pg_temp.chk(
    not exists (select 1 from public.mt5_capture_promotions p
                  join public.trades t on t.id = p.trade_id
                 where t.mt5_promotion_id is distinct from p.id),
    'G5 every surviving promoted trade carries the matching incarnation marker');
  -- G6: nothing squats in the reserved namespace without a promotion behind it
  perform pg_temp.chk(
    not exists (select 1 from public.trades t
                 where t.id ~ '^mt5p_'
                   and not exists (select 1 from public.mt5_capture_promotions p
                                    where p.trade_id = t.id)),
    'G6 no unbacked row occupies the reserved namespace');

  -- G7/G8/G9: the apply packets record the EXACT deployed body of every T4B function, so the
  -- read-only verifier can detect a body swapped after apply. Metadata alone cannot: a validator
  -- replaced by `select true` keeps its signature, security, volatility and search_path.
  --
  -- G7 is an INVENTORY, not a count. Six-of-something would accept a required key swapped for an
  -- unrelated deployed function carrying its own correct digest; the dropped T4B body would then
  -- be verified by nothing while the total still read six.
  perform pg_temp.chk(
    (select array_agg(k order by k)
       from public.mt5_schema_migrations m,
            lateral jsonb_object_keys(m.objects->'function_digests') k
      where m.version = 'mt5_t4b_promotion_schema_v1')
      = array['public.mt5_capture_promotion_guard_v1()',
              'public.mt5_trades_incarnation_guard_v1()'],
    'G7 the schema ledger records EXACTLY its two function signatures',
    (select coalesce((select array_agg(k order by k)
                        from public.mt5_schema_migrations m,
                             lateral jsonb_object_keys(m.objects->'function_digests') k
                       where m.version = 'mt5_t4b_promotion_schema_v1'),
                     array[]::text[])::text));
  perform pg_temp.chk(
    (select array_agg(k order by k)
       from public.mt5_schema_migrations m,
            lateral jsonb_object_keys(m.objects->'function_digests') k
      where m.version = 'mt5_t4b_promotion_rpc_v1')
      = array['public.mt5_promote_capture_decision_v1(uuid)',
              'public.mt5_t4b_freshness_window_v1()',
              'public.mt5_t4b_map_product_v1(uuid, text, numeric)',
              'public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid)'],
    'G7a the RPC ledger records EXACTLY its four function signatures',
    (select coalesce((select array_agg(k order by k)
                        from public.mt5_schema_migrations m,
                             lateral jsonb_object_keys(m.objects->'function_digests') k
                       where m.version = 'mt5_t4b_promotion_rpc_v1'),
                     array[]::text[])::text));
  -- Resolved by full signature through to_regprocedure, so a same-named overload cannot stand in
  -- for the real function.
  perform pg_temp.chk(
    not exists (
      select 1 from public.mt5_schema_migrations m,
                   lateral jsonb_each_text(m.objects->'function_digests') d(fn, dig)
       where m.version in ('mt5_t4b_promotion_schema_v1', 'mt5_t4b_promotion_rpc_v1')
         and (to_regprocedure(d.fn) is null
              or dig is distinct from encode(sha256(convert_to(
                   pg_get_functiondef(to_regprocedure(d.fn)), 'UTF8')), 'hex'))),
    'G8 every recorded digest resolves by signature and matches the deployed body');
  -- G9: the rollback's only source of truth for restoring public.trades' write privileges.
  perform pg_temp.chk(
    (select jsonb_typeof(m.objects->'trades_prior_write_acl')
       from public.mt5_schema_migrations m
      where m.version = 'mt5_t4b_promotion_schema_v1') = 'array',
    'G9 the schema ledger carries the pre-T4B trades write-ACL snapshot');
  -- ...and it must actually describe the surface T4B narrowed: the app's table-level INSERT and
  -- UPDATE, recorded BEFORE the narrowing replaced them with column grants. A rollback that reads
  -- relacl at rollback time instead finds nothing here to disagree with, which is exactly how the
  -- first revision-3 cut restored nothing while looking correct.
  perform pg_temp.chk(
    to_regrole('authenticated') is null
    or (select count(*)
          from public.mt5_schema_migrations m,
               lateral jsonb_array_elements(m.objects->'trades_prior_write_acl') e
         where m.version = 'mt5_t4b_promotion_schema_v1'
           and e->>'scope' = 'table' and e->>'grantee' = 'authenticated'
           and e->>'priv' in ('INSERT', 'UPDATE')) = 2,
    'G9a the snapshot records the app''s pre-T4B TABLE-level INSERT and UPDATE');
  -- G9b — every entry carries a ROLE OID, because a name is not an identity: a role can be
  -- renamed (same principal, new name) or dropped and recreated (new principal, same name), and
  -- name-based restoration gets both wrong in the dangerous direction.
  perform pg_temp.chk(
    not exists (
      select 1 from public.mt5_schema_migrations m,
                   lateral jsonb_array_elements(m.objects->'trades_prior_write_acl') e
       where m.version = 'mt5_t4b_promotion_schema_v1'
         and (not (e ? 'grantee_oid') or not (e ? 'grantor_oid'))),
    'G9b every snapshot entry records a grantee AND grantor role oid');
  -- G9c — and every recorded grantor is the table owner, which is the precondition that makes a
  -- revoke-and-re-grant-as-owner narrowing lossless in the first place.
  perform pg_temp.chk(
    not exists (
      select 1 from public.mt5_schema_migrations m,
                   lateral jsonb_array_elements(m.objects->'trades_prior_write_acl') e
       where m.version = 'mt5_t4b_promotion_schema_v1'
         and (e->>'grantor_oid')::oid
             is distinct from (select c.relowner from pg_catalog.pg_class c
                                where c.oid = 'public.trades'::regclass)),
    'G9c every snapshot grant was made BY the table owner');
end $case_g$;

-- ---------------------------------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------------------------------
do $summary$
declare v_all bigint; v_bad bigint; v_list text;
begin
  select count(*), count(*) filter (where not ok) into v_all, v_bad from t4b_results;
  if v_bad > 0 then
    select string_agg('  - ' || label || coalesce(' [' || detail || ']', ''), e'\n' order by n)
      into v_list from t4b_results where not ok;
    raise exception E'T4B VERIFY: % of % CHECKS FAILED:\n%', v_bad, v_all, v_list;
  end if;
  raise notice 'T4B VERIFY: ALL % CHECKS PASS', v_all;
end $summary$;

rollback;
