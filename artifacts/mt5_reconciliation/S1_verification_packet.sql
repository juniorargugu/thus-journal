-- MT5 S1 append-only verification packet
-- Contract source: S1_append_only_snapshot_membership_design.md revision 3
-- Requires: mt5_s1_append_only_schema_v1 + mt5_s1_append_only_rpc_v1 applied to a DISPOSABLE database.
-- Status: EXECUTABLE DRAFT — NOT RUN. Every fixture performs real RPC calls and raises on assertion failure.
--
-- Execution model (when eventually run against a throwaway DB by an authorized operator):
--   * The whole file is one transaction that ENDS IN ROLLBACK — it never persists.
--   * Each fixture uses a UNIQUE source_account under one synthetic user, so fixtures are independent.
--   * Assertions RAISE 'MT5_S1_FIXTURE_<n>_FAIL: ...' on any deviation; a clean run reaches the final NOTICE.
--   * RPCs return o_error_code as a column (checked directly); trigger/permission denials RAISE (caught + asserted).
--   * The synthetic user is 00000000-0000-0000-0000-0000000000aa. Lease/run ids use gen_random_uuid().
--   * auth.uid() is simulated via request.jwt.claims for the read-RPC fixtures.
-- Do NOT claim these pass until actually executed against a disposable database.

begin;

set local role postgres;  -- fixtures seed via owner; role-scoped denials set their own role locally

-- ============================================================================================
-- helper: run a full healthy A snapshot (create->append->complete->reconcile) and return run_id
-- Implemented inline per fixture (no shared function) to keep the packet self-contained.
-- ============================================================================================

-- Fixture 1 — partial B preserves A ------------------------------------------------------------
do $f1$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa';
  v_acct text := 'ACC_F1';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid(); v_lb uuid := gen_random_uuid();
  r record; v_snap jsonb;
begin
  -- A: healthy with P1,P2
  select * into r from public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp()-interval '2 min','conn.v1',4200,'srv','s1.v1');
  if not r.o_ok then raise exception 'MT5_S1_FIXTURE_1_FAIL: create A -> %',r.o_error_code; end if;
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2010,"profit":10,"open_time_utc":"2026-07-01T00:00:00Z","source_time_msc":1,"contract_size":10},
      {"position_id":2,"symbol_raw":"GOU26","side":"sell","volume":2,"price_open":2005,"price_current":2004,"profit":2,"open_time_utc":"2026-07-01T00:00:00Z","source_time_msc":2,"contract_size":10}]'::jsonb);
  select * into r from public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,2,array[1,2]::bigint[]);
  if not r.o_ok or r.o_snapshot_health<>'healthy' then raise exception 'MT5_S1_FIXTURE_1_FAIL: complete A -> %',r.o_error_code; end if;
  perform public.mt5_reconcile_snapshot_v1(v_a,v_user,v_acct,v_la);

  -- B: started, appends P1 only, then "crashes" (never completes)
  select * into r from public.mt5_create_run_v1(v_b,v_user,v_acct,v_lb,900,clock_timestamp()-interval '1 min','conn.v1',4200,'srv','s1.v1');
  if r.o_error_code is distinct from null then raise exception 'MT5_S1_FIXTURE_1_FAIL: create B -> %',r.o_error_code; end if;
  perform public.mt5_append_run_positions_v1(v_b,v_user,v_acct,v_lb,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2011,"profit":11,"open_time_utc":"2026-07-01T00:00:00Z","source_time_msc":3,"contract_size":10}]'::jsonb);

  -- current-open still reflects A with A's frozen facts
  perform set_config('request.jwt.claims', json_build_object('sub',v_user::text)::text, true);
  v_snap := public.mt5_get_current_snapshot_v1(v_acct);
  if (v_snap->'snapshot'->>'run_id')::uuid <> v_a then raise exception 'MT5_S1_FIXTURE_1_FAIL: current run is not A'; end if;
  if jsonb_array_length(v_snap->'positions') <> 2 then raise exception 'MT5_S1_FIXTURE_1_FAIL: A must still show 2 positions'; end if;
  if (select count(*) from public.mt5_sync_run_positions p where p.run_id=v_a) <> 2
     or (select count(*) from public.mt5_sync_run_positions p where p.run_id=v_b) <> 1 then
    raise exception 'MT5_S1_FIXTURE_1_FAIL: membership rows not isolated per run';
  end if;
  raise notice 'MT5_S1_FIXTURE_1 PASS (partial B preserves A)';
end $f1$;

-- Fixture 2 — failed B preserves A ------------------------------------------------------------
do $f2$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F2';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid(); v_lb uuid := gen_random_uuid();
  r record; v_snap jsonb;
begin
  select * into r from public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp()-interval '2 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"S50U26","side":"buy","volume":1,"price_open":900,"price_current":905,"profit":5,"open_time_utc":"2026-07-01T00:00:00Z","source_time_msc":1,"contract_size":200}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,1,array[1]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_a,v_user,v_acct,v_la);

  select * into r from public.mt5_create_run_v1(v_b,v_user,v_acct,v_lb,900,clock_timestamp()-interval '1 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_b,v_user,v_acct,v_lb,
    '[{"position_id":1,"symbol_raw":"S50U26","side":"buy","volume":1,"price_open":900,"price_current":906,"profit":6,"open_time_utc":"2026-07-01T00:00:00Z","source_time_msc":2,"contract_size":200},
      {"position_id":2,"symbol_raw":"S50U26","side":"sell","volume":1,"price_open":901,"price_current":900,"profit":1,"open_time_utc":"2026-07-01T00:00:00Z","source_time_msc":3,"contract_size":200}]'::jsonb);
  select * into r from public.mt5_mark_snapshot_failed_v1(v_b,v_user,v_acct,v_lb,'SEAL_FAILED');
  if not r.o_ok then raise exception 'MT5_S1_FIXTURE_2_FAIL: mark B failed -> %',r.o_error_code; end if;

  perform set_config('request.jwt.claims', json_build_object('sub',v_user::text)::text, true);
  v_snap := public.mt5_get_current_snapshot_v1(v_acct);
  if (v_snap->'snapshot'->>'run_id')::uuid <> v_a then raise exception 'MT5_S1_FIXTURE_2_FAIL: current run is not A'; end if;
  if (select snapshot_status from public.mt5_sync_runs where id=v_b) <> 'failed' then raise exception 'MT5_S1_FIXTURE_2_FAIL: B not failed'; end if;
  if (select count(*) from public.mt5_sync_run_positions where run_id=v_b) <> 2 then raise exception 'MT5_S1_FIXTURE_2_FAIL: failed B rows must remain as diagnostics'; end if;
  raise notice 'MT5_S1_FIXTURE_2 PASS (failed B preserves A)';
end $f2$;

-- Fixture 3 — suspicious B preserves A as stale context; reconcile mutates zero lifecycle -----
do $f3$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F3';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid(); v_lb uuid := gen_random_uuid();
  r record; v_snap jsonb; v_ids bigint[]; v_before jsonb; v_after jsonb; i int;
begin
  -- seed the 20 open staging candidate rows the writer would have inserted (lifecycle targets)
  insert into public.mt5_import_staging(user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
    select v_user,v_acct,'open','GOU26','buy',1,g,'open','new' from generate_series(1,20) g;
  -- A healthy with 20 positions
  select array_agg(g) into v_ids from generate_series(1,20) g;
  select * into r from public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp()-interval '4 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    (select jsonb_agg(jsonb_build_object('position_id',g,'symbol_raw','GOU26','side','buy','volume',1,
       'price_open',2000,'price_current',2000,'profit',0,'open_time_utc','2026-07-01T00:00:00Z','source_time_msc',g,'contract_size',10))
     from generate_series(1,20) g));
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,20,v_ids);
  perform public.mt5_reconcile_snapshot_v1(v_a,v_user,v_acct,v_la);

  -- lifecycle snapshot BEFORE B's reconcile (must be non-empty, else the comparison is vacuous)
  select jsonb_agg(jsonb_build_object('pid',s.position_id,'st',s.position_state,'b',s.missing_since_run_id) order by s.position_id)
    into v_before from public.mt5_import_staging s where s.user_id=v_user and s.source_account=v_acct and s.kind='open';
  if v_before is null or jsonb_array_length(v_before)<>20 then raise exception 'MT5_S1_FIXTURE_3_FAIL: expected 20 seeded lifecycle rows (non-vacuous)'; end if;
  if exists (select 1 from jsonb_array_elements(v_before) e where e->>'st'<>'still_open') then
    raise exception 'MT5_S1_FIXTURE_3_FAIL: healthy A must have set all 20 rows to still_open';
  end if;

  -- B completes with ZERO positions -> suspicious (prev 20, cur 0)
  select * into r from public.mt5_create_run_v1(v_b,v_user,v_acct,v_lb,900,clock_timestamp()-interval '1 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_b,v_user,v_acct,v_lb,'[]'::jsonb);
  select * into r from public.mt5_complete_snapshot_v1(v_b,v_user,v_acct,v_lb,0,array[]::bigint[]);
  if not r.o_ok or r.o_snapshot_health<>'suspicious' then raise exception 'MT5_S1_FIXTURE_3_FAIL: B must be suspicious -> %/%',r.o_ok,r.o_snapshot_health; end if;
  perform public.mt5_reconcile_snapshot_v1(v_b,v_user,v_acct,v_lb);

  select jsonb_agg(jsonb_build_object('pid',s.position_id,'st',s.position_state,'b',s.missing_since_run_id) order by s.position_id)
    into v_after from public.mt5_import_staging s where s.user_id=v_user and s.source_account=v_acct and s.kind='open';
  if v_before is distinct from v_after then raise exception 'MT5_S1_FIXTURE_3_FAIL: suspicious reconcile mutated lifecycle'; end if;

  -- read RPC: suspicious -> metadata only, no trusted positions
  perform set_config('request.jwt.claims', json_build_object('sub',v_user::text)::text, true);
  v_snap := public.mt5_get_current_snapshot_v1(v_acct);
  if (v_snap->>'freshness_state')<>'suspicious' or jsonb_array_length(v_snap->'positions')<>0 then
    raise exception 'MT5_S1_FIXTURE_3_FAIL: suspicious read must return zero trusted positions';
  end if;
  -- A remains fully reconstructable
  if (select count(*) from public.mt5_sync_run_positions where run_id=v_a) <> 20 then raise exception 'MT5_S1_FIXTURE_3_FAIL: A snapshot not reconstructable'; end if;
  raise notice 'MT5_S1_FIXTURE_3 PASS (suspicious B preserves A; zero lifecycle mutation)';
end $f3$;

-- Fixture 4 — healthy C atomically replaces A -------------------------------------------------
do $f4$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F4';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid(); v_lc uuid := gen_random_uuid();
  r record; v_snap jsonb; v_state text;
begin
  -- seed the open staging candidate rows for positions 1 and 2 (lifecycle targets)
  insert into public.mt5_import_staging(user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
  values (v_user,v_acct,'open','GOU26','buy',1,1,'open','new'),
         (v_user,v_acct,'open','GOU26','buy',1,2,'open','new');
  select * into r from public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp()-interval '4 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2000,"profit":0,"source_time_msc":1,"contract_size":10},
      {"position_id":2,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2001,"price_current":2001,"profit":0,"source_time_msc":2,"contract_size":10}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,2,array[1,2]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_a,v_user,v_acct,v_la);

  select * into r from public.mt5_create_run_v1(v_c,v_user,v_acct,v_lc,900,clock_timestamp()-interval '1 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_c,v_user,v_acct,v_lc,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2020,"profit":20,"source_time_msc":9,"contract_size":10}]'::jsonb);
  select * into r from public.mt5_complete_snapshot_v1(v_c,v_user,v_acct,v_lc,1,array[1]::bigint[]);
  if not r.o_ok then raise exception 'MT5_S1_FIXTURE_4_FAIL: complete C -> %',r.o_error_code; end if;
  perform public.mt5_reconcile_snapshot_v1(v_c,v_user,v_acct,v_lc);

  perform set_config('request.jwt.claims', json_build_object('sub',v_user::text)::text, true);
  v_snap := public.mt5_get_current_snapshot_v1(v_acct);
  if (v_snap->'snapshot'->>'run_id')::uuid <> v_c then raise exception 'MT5_S1_FIXTURE_4_FAIL: current must be C'; end if;
  if jsonb_array_length(v_snap->'positions')<>1 then raise exception 'MT5_S1_FIXTURE_4_FAIL: C must show 1 position'; end if;
  -- position 2 absent in C -> missing_once (row MUST exist first, else the check would be vacuous)
  select position_state into v_state from public.mt5_import_staging
   where user_id=v_user and source_account=v_acct and kind='open' and position_id=2;
  if not found then raise exception 'MT5_S1_FIXTURE_4_FAIL: staging row for position 2 missing (vacuous)'; end if;
  if v_state <> 'missing_once' then raise exception 'MT5_S1_FIXTURE_4_FAIL: absent position 2 must be missing_once, got %',v_state; end if;
  -- position 1 observed in C -> still_open
  select position_state into v_state from public.mt5_import_staging
   where user_id=v_user and source_account=v_acct and kind='open' and position_id=1;
  if v_state <> 'still_open' then raise exception 'MT5_S1_FIXTURE_4_FAIL: observed position 1 must be still_open, got %',v_state; end if;
  raise notice 'MT5_S1_FIXTURE_4 PASS (healthy C atomically replaces A)';
end $f4$;

-- Fixture 5 — delayed older capture -> ERR_SUPERSEDED -----------------------------------------
do $f5$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F5';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid(); v_lb uuid := gen_random_uuid();
  r record;
begin
  select * into r from public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp()-interval '2 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2000,"profit":0,"source_time_msc":1,"contract_size":10}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,1,array[1]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_a,v_user,v_acct,v_la);

  -- B captured EARLIER than A (delayed stale capture)
  select * into r from public.mt5_create_run_v1(v_b,v_user,v_acct,v_lb,900,clock_timestamp()-interval '30 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_b,v_user,v_acct,v_lb,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":1999,"profit":-1,"source_time_msc":2,"contract_size":10}]'::jsonb);
  select * into r from public.mt5_complete_snapshot_v1(v_b,v_user,v_acct,v_lb,1,array[1]::bigint[]);
  if r.o_error_code <> 'ERR_SUPERSEDED' then raise exception 'MT5_S1_FIXTURE_5_FAIL: expected ERR_SUPERSEDED got %',r.o_error_code; end if;
  if (select snapshot_status from public.mt5_sync_runs where id=v_b) = 'complete' then raise exception 'MT5_S1_FIXTURE_5_FAIL: superseded run must not be complete'; end if;
  raise notice 'MT5_S1_FIXTURE_5 PASS (delayed older capture -> ERR_SUPERSEDED)';
end $f5$;

-- Fixture 6 — live active cycle -> ERR_RUN_ACTIVE ---------------------------------------------
do $f6$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F6';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid(); v_lb uuid := gen_random_uuid();
  r record;
begin
  select * into r from public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  if not r.o_ok then raise exception 'MT5_S1_FIXTURE_6_FAIL: create A -> %',r.o_error_code; end if;
  select * into r from public.mt5_create_run_v1(v_b,v_user,v_acct,v_lb,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  if r.o_error_code <> 'ERR_RUN_ACTIVE' then raise exception 'MT5_S1_FIXTURE_6_FAIL: expected ERR_RUN_ACTIVE got %',r.o_error_code; end if;
  raise notice 'MT5_S1_FIXTURE_6 PASS (live active cycle blocks create)';
end $f6$;

-- Fixture 7 — exact append replay is idempotent success --------------------------------------
do $f7$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F7';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_rows jsonb := '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2005,"profit":5,"source_time_msc":1,"contract_size":10}]'::jsonb;
  r record;
begin
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  select * into r from public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,v_rows);
  if not r.o_ok or r.o_inserted<>1 then raise exception 'MT5_S1_FIXTURE_7_FAIL: first append'; end if;
  select * into r from public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,v_rows);
  if not r.o_ok or r.o_inserted<>0 then raise exception 'MT5_S1_FIXTURE_7_FAIL: replay must insert 0 and succeed'; end if;
  if (select count(*) from public.mt5_sync_run_positions where run_id=v_a)<>1 then raise exception 'MT5_S1_FIXTURE_7_FAIL: replay duplicated a row'; end if;
  raise notice 'MT5_S1_FIXTURE_7 PASS (exact append replay)';
end $f7$;

-- Fixture 8 — conflicting immutable payload -> ERR_POSITION_CONFLICT --------------------------
do $f8$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F8';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); r record;
begin
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2005,"profit":5,"source_time_msc":1,"contract_size":10}]'::jsonb);
  -- same id, different price_current -> conflict; and a NULL-vs-value conflict
  select * into r from public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2006,"profit":5,"source_time_msc":1,"contract_size":10}]'::jsonb);
  if r.o_error_code <> 'ERR_POSITION_CONFLICT' then raise exception 'MT5_S1_FIXTURE_8_FAIL: value diff expected ERR_POSITION_CONFLICT got %',r.o_error_code; end if;
  select * into r from public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":null,"price_current":2005,"profit":5,"source_time_msc":1,"contract_size":10}]'::jsonb);
  if r.o_error_code <> 'ERR_POSITION_CONFLICT' then raise exception 'MT5_S1_FIXTURE_8_FAIL: NULL-vs-value expected ERR_POSITION_CONFLICT got %',r.o_error_code; end if;
  raise notice 'MT5_S1_FIXTURE_8 PASS (conflicting immutable payload)';
end $f8$;

-- Fixture 9 — append after seal -> ERR_RUN_SEALED (before any lease error) --------------------
do $f9$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F9';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); r record;
begin
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2000,"profit":0,"source_time_msc":1,"contract_size":10}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,1,array[1]::bigint[]);
  -- force lease expiry so we also prove status precedence over ERR_LEASE_EXPIRED
  update public.mt5_sync_runs set lease_expires_at=clock_timestamp()-interval '1 h' where id=v_a;
  select * into r from public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":2,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2001,"price_current":2001,"profit":0,"source_time_msc":2,"contract_size":10}]'::jsonb);
  if r.o_error_code <> 'ERR_RUN_SEALED' then raise exception 'MT5_S1_FIXTURE_9_FAIL: expected ERR_RUN_SEALED (not lease) got %',r.o_error_code; end if;
  raise notice 'MT5_S1_FIXTURE_9 PASS (append after seal -> ERR_RUN_SEALED, status precedence)';
end $f9$;

-- Fixture 10 — UPDATE/DELETE of immutable rows denied by trigger -----------------------------
do $f10$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F10';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); v_caught boolean;
begin
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2000,"profit":0,"source_time_msc":1,"contract_size":10}]'::jsonb);
  v_caught:=false;
  begin update public.mt5_sync_run_positions set profit=999 where run_id=v_a; exception when others then v_caught:=true; end;
  if not v_caught then raise exception 'MT5_S1_FIXTURE_10_FAIL: UPDATE of immutable row was allowed'; end if;
  v_caught:=false;
  begin delete from public.mt5_sync_run_positions where run_id=v_a; exception when others then v_caught:=true; end;
  if not v_caught then raise exception 'MT5_S1_FIXTURE_10_FAIL: DELETE of immutable row was allowed'; end if;
  raise notice 'MT5_S1_FIXTURE_10 PASS (immutable UPDATE/DELETE denied)';
end $f10$;

-- Fixture 11 — valid zero snapshot (first ever) ----------------------------------------------
do $f11$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F11';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); r record; v_snap jsonb;
begin
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,'[]'::jsonb);
  select * into r from public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,0,array[]::bigint[]);
  if not r.o_ok or r.o_snapshot_health<>'healthy' then raise exception 'MT5_S1_FIXTURE_11_FAIL: first zero snapshot must be healthy -> %/%',r.o_ok,r.o_error_code; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_user::text)::text, true);
  v_snap := public.mt5_get_current_snapshot_v1(v_acct);
  if (v_snap->>'freshness_state')<>'fresh' or jsonb_array_length(v_snap->'positions')<>0 or (v_snap->'snapshot'->>'positions_count')<>'0' then
    raise exception 'MT5_S1_FIXTURE_11_FAIL: healthy-empty read must be fresh with 0 positions';
  end if;
  raise notice 'MT5_S1_FIXTURE_11 PASS (valid zero snapshot)';
end $f11$;

-- Fixture 12/13 — completion exact replay success + replay conflict --------------------------
do $f12$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F12';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); r record; v_caught boolean;
begin
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"price_open":2000,"price_current":2000,"profit":0,"source_time_msc":1,"contract_size":10}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,1,array[1]::bigint[]);
  -- exact replay -> stable success
  select * into r from public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,1,array[1]::bigint[]);
  if not r.o_ok then raise exception 'MT5_S1_FIXTURE_12_FAIL: exact completion replay must succeed got %',r.o_error_code; end if;
  -- replay an ALREADY-complete run with a set that diverges from the sealed children -> ERR_REPLAY_CONFLICT
  -- (p_expected_count matches the claimed id array, so pre-fetch count validation passes; the sealed-evidence
  --  recompute in the complete-branch is what must reject it.)
  select * into r from public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,2,array[1,2]::bigint[]);
  if r.o_error_code <> 'ERR_REPLAY_CONFLICT' then
    raise exception 'MT5_S1_FIXTURE_13_FAIL: divergent completion replay must be ERR_REPLAY_CONFLICT, got %',r.o_error_code;
  end if;
  raise notice 'MT5_S1_FIXTURE_12/13 PASS (completion replay success + conflict)';
end $f12$;

-- Fixture 14 — cross-account append denied ---------------------------------------------------
do $f14$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F14';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); r record;
begin
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  select * into r from public.mt5_append_run_positions_v1(v_a,v_user,'ACC_OTHER',v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":1}]'::jsonb);
  if r.o_error_code <> 'ERR_RUN_CONFLICT' then raise exception 'MT5_S1_FIXTURE_14_FAIL: cross-account append expected ERR_RUN_CONFLICT got %',r.o_error_code; end if;
  raise notice 'MT5_S1_FIXTURE_14 PASS (cross-account append denied)';
end $f14$;

-- Fixture 15/16/17 — H1/H2/H3 consecutive absence; first absence one credit; conflict-not-promoted
do $f15$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F15';
  v_h1 uuid := gen_random_uuid(); v_l1 uuid := gen_random_uuid();
  v_h2 uuid := gen_random_uuid(); v_l2 uuid := gen_random_uuid();
  v_h3 uuid := gen_random_uuid(); v_l3 uuid := gen_random_uuid();
  r record; v_state text;
begin
  -- seed staging open row for position 7 (as ingestion would), initial state 'open'
  insert into public.mt5_import_staging(user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
  values (v_user,v_acct,'open','GOU26','buy',1,7,'open','new');
  -- also a baseline present position 8 so runs are healthy (prev base >=3 avoided: keep small, health stays healthy)
  insert into public.mt5_import_staging(user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
  values (v_user,v_acct,'open','GOU26','buy',1,8,'open','new');

  -- H1: position 7 ABSENT (only 8 present)
  perform public.mt5_create_run_v1(v_h1,v_user,v_acct,v_l1,900,clock_timestamp()-interval '3 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_h1,v_user,v_acct,v_l1,
    '[{"position_id":8,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":1}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_h1,v_user,v_acct,v_l1,1,array[8]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_h1,v_user,v_acct,v_l1);
  select position_state into v_state from public.mt5_import_staging where user_id=v_user and source_account=v_acct and position_id=7;
  if v_state<>'missing_once' then raise exception 'MT5_S1_FIXTURE_16_FAIL: H1 first absence must be missing_once got %',v_state; end if;

  -- H2: position 7 PRESENT again, but reconcile FAILS
  perform public.mt5_create_run_v1(v_h2,v_user,v_acct,v_l2,900,clock_timestamp()-interval '2 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_h2,v_user,v_acct,v_l2,
    '[{"position_id":7,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":2},
      {"position_id":8,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":3}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_h2,v_user,v_acct,v_l2,2,array[7,8]::bigint[]);
  perform public.mt5_mark_reconcile_failed_v1(v_h2,v_user,v_acct,v_l2,'RECONCILE_FAILED');  -- H2 reconcile fails

  -- H3: position 7 ABSENT again -> streak must be 1 (H2 presence reset it), NOT >= K
  perform public.mt5_create_run_v1(v_h3,v_user,v_acct,v_l3,900,clock_timestamp()-interval '1 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_h3,v_user,v_acct,v_l3,
    '[{"position_id":8,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":4}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_h3,v_user,v_acct,v_l3,1,array[8]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_h3,v_user,v_acct,v_l3);
  select position_state into v_state from public.mt5_import_staging where user_id=v_user and source_account=v_acct and position_id=7;
  if v_state<>'missing_once' then raise exception 'MT5_S1_FIXTURE_15_FAIL: H3 effective streak must be 1 (missing_once), got %',v_state; end if;
  raise notice 'MT5_S1_FIXTURE_15/16 PASS (H1/H2/H3 consecutive absence resets on membership presence)';
end $f15$;

-- Fixture 17 — conflict (reappearing terminal) not promoted to still_open in same reconcile ---
do $f17$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F17';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); r record; v_state text;
begin
  -- seed a position already in a terminal-ish state
  insert into public.mt5_import_staging(user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
  values (v_user,v_acct,'open','GOU26','buy',1,5,'closed_confirmed','new');
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":5,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":1}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,1,array[5]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_a,v_user,v_acct,v_la);
  select position_state into v_state from public.mt5_import_staging where user_id=v_user and source_account=v_acct and position_id=5;
  if v_state<>'unknown' then raise exception 'MT5_S1_FIXTURE_17_FAIL: reappearing closed_confirmed must be unknown, not still_open, got %',v_state; end if;
  raise notice 'MT5_S1_FIXTURE_17 PASS (conflict not promoted)';
end $f17$;

-- Fixture 18 — (covered by fixture 3: suspicious mutates zero lifecycle) ----------------------
do $f18$ begin raise notice 'MT5_S1_FIXTURE_18 PASS (asserted in fixture 3: suspicious zero lifecycle mutation)'; end $f18$;

-- Fixture 19 — previous count ignores suspicious observation ----------------------------------
do $f19$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F19';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid(); v_lb uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid(); v_lc uuid := gen_random_uuid();
  r record; v_prev integer;
begin
  -- A healthy with 5 positions
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp()-interval '3 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    (select jsonb_agg(jsonb_build_object('position_id',g,'symbol_raw','GOU26','side','buy','volume',1,'source_time_msc',g)) from generate_series(1,5) g));
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,5,array[1,2,3,4,5]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_a,v_user,v_acct,v_la);
  -- B suspicious (0 positions, prev 5)
  perform public.mt5_create_run_v1(v_b,v_user,v_acct,v_lb,900,clock_timestamp()-interval '2 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_b,v_user,v_acct,v_lb,'[]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_b,v_user,v_acct,v_lb,0,array[]::bigint[]);
  perform public.mt5_reconcile_snapshot_v1(v_b,v_user,v_acct,v_lb);
  -- C healthy with 4 positions: previous_positions_count must come from A(5), NOT suspicious B(0)
  perform public.mt5_create_run_v1(v_c,v_user,v_acct,v_lc,900,clock_timestamp()-interval '1 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_c,v_user,v_acct,v_lc,
    (select jsonb_agg(jsonb_build_object('position_id',g,'symbol_raw','GOU26','side','buy','volume',1,'source_time_msc',g)) from generate_series(1,4) g));
  perform public.mt5_complete_snapshot_v1(v_c,v_user,v_acct,v_lc,4,array[1,2,3,4]::bigint[]);
  select previous_positions_count into v_prev from public.mt5_sync_runs where id=v_c;
  if v_prev<>5 then raise exception 'MT5_S1_FIXTURE_19_FAIL: previous_positions_count must be 5 (healthy A), got %',v_prev; end if;
  raise notice 'MT5_S1_FIXTURE_19 PASS (previous count ignores suspicious)';
end $f19$;

-- Fixture 20 — freshness uses captured_at (not completion time) -------------------------------
do $f20$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F20';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid(); v_snap jsonb;
begin
  -- captured 60 min ago (freshness_seconds=1800) but completed now -> must read STALE
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp()-interval '60 min','conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_a,v_user,v_acct,v_la,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":1}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_a,v_user,v_acct,v_la,1,array[1]::bigint[]);
  perform set_config('request.jwt.claims', json_build_object('sub',v_user::text)::text, true);
  v_snap := public.mt5_get_current_snapshot_v1(v_acct);
  if (v_snap->>'freshness_state')<>'stale' or jsonb_array_length(v_snap->'positions')<>0 then
    raise exception 'MT5_S1_FIXTURE_20_FAIL: old captured_at must read stale with 0 trusted positions got %',v_snap->>'freshness_state';
  end if;
  raise notice 'MT5_S1_FIXTURE_20 PASS (freshness uses captured_at)';
end $f20$;

-- Fixture 21/22 — healthy-empty result + stale/suspicious return no trusted positions ---------
do $f21$ begin raise notice 'MT5_S1_FIXTURE_21/22 PASS (asserted in fixtures 11, 3, 20)'; end $f21$;

-- Fixture 23 — direct authenticated table reads denied ----------------------------------------
do $f23$
declare v_caught boolean;
begin
  set local role authenticated;
  v_caught:=false;
  begin perform 1 from public.mt5_sync_runs limit 1; exception when insufficient_privilege then v_caught:=true; when others then v_caught:=true; end;
  if not v_caught then reset role; raise exception 'MT5_S1_FIXTURE_23_FAIL: authenticated could SELECT mt5_sync_runs'; end if;
  v_caught:=false;
  begin perform 1 from public.mt5_sync_run_positions limit 1; exception when insufficient_privilege then v_caught:=true; when others then v_caught:=true; end;
  reset role;
  if not v_caught then raise exception 'MT5_S1_FIXTURE_23_FAIL: authenticated could SELECT mt5_sync_run_positions'; end if;
  raise notice 'MT5_S1_FIXTURE_23 PASS (direct authenticated table reads denied)';
end $f23$;

-- Fixture 24 — ingestion credential cannot update lifecycle columns ---------------------------
do $f24$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F24'; v_caught boolean;
begin
  insert into public.mt5_import_staging(user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
  values (v_user,v_acct,'open','GOU26','buy',1,1,'open','new');
  set local role service_role;
  -- allowed value-column update must succeed
  update public.mt5_import_staging set price=1 where user_id=v_user and source_account=v_acct and position_id=1;
  -- lifecycle-column update must be denied
  v_caught:=false;
  begin update public.mt5_import_staging set position_state='still_open' where user_id=v_user and source_account=v_acct and position_id=1;
  exception when insufficient_privilege then v_caught:=true; when others then v_caught:=true; end;
  reset role;
  if not v_caught then raise exception 'MT5_S1_FIXTURE_24_FAIL: service_role updated position_state'; end if;
  raise notice 'MT5_S1_FIXTURE_24 PASS (ingestion cannot write lifecycle columns; value columns still writable)';
end $f24$;

-- Fixture 25 — migration preserved staging row count + non-lifecycle checksum -----------------
-- (Structural note: enforced by S1_schema_packet.sql postflight $postflight$ using mt5.s1_staging_* GUCs.
--  Re-asserted here read-only: no rows were deleted and the two new columns are the only additions.)
do $f25$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F25';
  v_lifecycle_cols integer; v_c1 bigint; v_c2 bigint; v_k1 text; v_k2 text;
begin
  -- structural: exactly the 2 S1 additions, and last_seen_run_id never exists
  select count(*) into v_lifecycle_cols from information_schema.columns
   where table_schema='public' and table_name='mt5_import_staging'
     and column_name in ('lifecycle_updated_at','missing_since_run_id');
  if v_lifecycle_cols<>2 then raise exception 'MT5_S1_FIXTURE_25_FAIL: expected exactly the 2 S1 staging additions'; end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='mt5_import_staging' and column_name='last_seen_run_id') then
    raise exception 'MT5_S1_FIXTURE_25_FAIL: last_seen_run_id must never exist';
  end if;
  -- the schema packet must have captured pre-migration staging evidence in the ledger
  if not exists (select 1 from public.mt5_schema_migrations m where m.version='mt5_s1_append_only_schema_v1'
       and (m.objects->>'staging_pre_count') is not null and (m.objects->>'staging_pre_checksum') is not null) then
    raise exception 'MT5_S1_FIXTURE_25_FAIL: schema ledger did not record staging pre-migration evidence';
  end if;

  -- independently recompute the SAME non-lifecycle evidence checksum the schema postflight uses, over a
  -- known seeded row-set, and prove a LIFECYCLE-COLUMN-ONLY mutation changes neither the count nor the
  -- checksum (the exact exclusion the postflight relies on to certify migration data-preservation).
  insert into public.mt5_import_staging(user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
  values (v_user,v_acct,'open','GOU26','buy',1,101,'open','new'),
         (v_user,v_acct,'open','GOU26','buy',1,102,'open','new'),
         (v_user,v_acct,'open','GOU26','buy',1,103,'open','new');
  select count(*), pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
           coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(s)-'lifecycle_updated_at'-'missing_since_run_id')::text,
             '' order by s.id),''),'UTF8'),'sha256'),'hex')
    into v_c1, v_k1 from public.mt5_import_staging s where s.user_id=v_user and s.source_account=v_acct;
  update public.mt5_import_staging set lifecycle_updated_at=now()
   where user_id=v_user and source_account=v_acct and position_id=101;   -- lifecycle column ONLY
  select count(*), pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
           coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(s)-'lifecycle_updated_at'-'missing_since_run_id')::text,
             '' order by s.id),''),'UTF8'),'sha256'),'hex')
    into v_c2, v_k2 from public.mt5_import_staging s where s.user_id=v_user and s.source_account=v_acct;
  if v_c1<>3 or v_c2<>3 then raise exception 'MT5_S1_FIXTURE_25_FAIL: seeded staging count drifted'; end if;
  if v_k1 is distinct from v_k2 then raise exception 'MT5_S1_FIXTURE_25_FAIL: non-lifecycle evidence checksum changed under a lifecycle-only mutation'; end if;
  raise notice 'MT5_S1_FIXTURE_25 PASS (additions minimal; evidence count+checksum invariant under lifecycle-only change; ledger captured pre-evidence)';
end $f25$;

-- Fixture 26 — expiry: DB-time-expired lease only; started->failed, complete/pending->reconcile failed
do $f26$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000aa'; v_acct text := 'ACC_F26';
  v_a uuid := gen_random_uuid(); v_la uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid(); v_lb uuid := gen_random_uuid(); r record;
begin
  -- (a) started + live lease -> ERR_LEASE_NOT_EXPIRED
  perform public.mt5_create_run_v1(v_a,v_user,v_acct,v_la,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  select * into r from public.mt5_expire_stale_run_v1(v_a,v_user,v_acct);
  if r.o_error_code<>'ERR_LEASE_NOT_EXPIRED' then raise exception 'MT5_S1_FIXTURE_26_FAIL: live lease expected ERR_LEASE_NOT_EXPIRED got %',r.o_error_code; end if;
  -- (b) started + expired lease -> started->failed
  update public.mt5_sync_runs set lease_expires_at=clock_timestamp()-interval '1 h' where id=v_a;
  select * into r from public.mt5_expire_stale_run_v1(v_a,v_user,v_acct);
  if not r.o_ok or (select snapshot_status from public.mt5_sync_runs where id=v_a)<>'failed' then
    raise exception 'MT5_S1_FIXTURE_26_FAIL: expired started run must become failed got %',r.o_error_code;
  end if;
  -- (c) complete+pending + expired lease -> reconcile failed; snapshot stays complete (authority intact)
  perform public.mt5_create_run_v1(v_b,v_user,v_acct,v_lb,900,clock_timestamp(),'conn.v1',4200,'srv','s1.v1');
  perform public.mt5_append_run_positions_v1(v_b,v_user,v_acct,v_lb,
    '[{"position_id":1,"symbol_raw":"GOU26","side":"buy","volume":1,"source_time_msc":1}]'::jsonb);
  perform public.mt5_complete_snapshot_v1(v_b,v_user,v_acct,v_lb,1,array[1]::bigint[]);   -- now complete+pending
  update public.mt5_sync_runs set lease_expires_at=clock_timestamp()-interval '1 h' where id=v_b;
  select * into r from public.mt5_expire_stale_run_v1(v_b,v_user,v_acct);
  if not r.o_ok then raise exception 'MT5_S1_FIXTURE_26_FAIL: expire complete/pending -> %',r.o_error_code; end if;
  if (select snapshot_status from public.mt5_sync_runs where id=v_b)<>'complete'
     or (select reconcile_status from public.mt5_sync_runs where id=v_b)<>'failed' then
    raise exception 'MT5_S1_FIXTURE_26_FAIL: expired complete/pending must be complete + reconcile failed';
  end if;
  raise notice 'MT5_S1_FIXTURE_26 PASS (expiry: live->NOT_EXPIRED; started->failed; complete/pending->reconcile failed)';
end $f26$;

-- ============================================================================================
do $done$ begin raise notice 'MT5 S1 VERIFICATION PACKET: all fixtures asserted (EXECUTABLE DRAFT — this run is ROLLED BACK).'; end $done$;

rollback;  -- nothing persists; run against a disposable database only.
