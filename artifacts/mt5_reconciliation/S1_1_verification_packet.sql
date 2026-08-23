-- MT5 S1.1 account observation — verification packet (READ-ONLY, NO MUTATION)
-- Contract source: S1_1_account_observation_design.md  (FROZEN — CODEX APPROVED, 2026-08-22)
--   frozen source_artifact_sha256 =
--     812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1
-- Packet revision: 3
--
-- PURPOSE
--   Assert, against live state, everything the frozen design requires of an installed S1.1 that
--   the apply-time postflight cannot cover on its own: object and ACL shape, the completed-run
--   invariant (§13), the historical-run exemption (§14), and -- most importantly -- that the
--   frozen S1 tables are still structurally identical to their apply-time fingerprints, i.e. that
--   S1 rollback is STILL ARMED.
--
-- SAFETY
--   Contains no DDL and no DML. Ends in ROLLBACK. Safe to run repeatedly.
--   Behavioural cases (the 44-case matrix) are executed by the disposable harness, not here:
--   proving that a CHECK rejects a row requires attempting to insert it, which is a mutation.

begin transaction read only;

do $s11_verify$
declare
  v_schema public.mt5_schema_migrations%rowtype;
  v_rpc    public.mt5_schema_migrations%rowtype;
  v_bad    text;
  v_n      integer;
  v_fail   integer := 0;
  v_pass   integer := 0;

  procedure_note text;
begin
  ----------------------------------------------------------------------------------- V1 ledger --
  select * into v_schema from public.mt5_schema_migrations
   where version='mt5_s1_1_account_observation_schema_v1';
  if not found or v_schema.status<>'applied'
     or v_schema.checksum<>'cf9427c58b916c6f2dd528dd5a23fdb14ed8624fc334e4b9aa0080980276f121'
     or v_schema.source_artifact_sha256<>'812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1' then
    v_fail:=v_fail+1; raise warning 'V1 FAIL: S1.1 schema ledger row missing or not this revision';
  else v_pass:=v_pass+1; end if;

  select * into v_rpc from public.mt5_schema_migrations
   where version='mt5_s1_1_account_observation_rpc_v1';
  if not found or v_rpc.status<>'applied'
     or v_rpc.checksum<>'370a41bfe7d8d72d9e3e99aa1d38d2f4bd68c06a95cd1d1a056afa28e365c93a'
     or v_rpc.source_artifact_sha256<>'812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1' then
    v_fail:=v_fail+1; raise warning 'V2 FAIL: S1.1 RPC ledger row missing or not this revision';
  else v_pass:=v_pass+1; end if;

  ------------------------------------------------------------------------------- V3 table shape --
  if to_regclass('public.mt5_sync_run_account') is null then
    v_fail:=v_fail+1; raise warning 'V3 FAIL: public.mt5_sync_run_account is missing';
  else
    select pg_catalog.string_agg(x.want,', ' order by x.want) into v_bad
      from (values ('run_id'),('user_id'),('source_account'),('captured_at'),('connector_version'),
                   ('account_read_at'),('account_observation_status'),('equity'),('balance'),
                   ('currency'),('equity_quality'),('balance_quality'),('failure_reason'),
                   ('account_fingerprint'),('created_at')) x(want)
     where not exists (select 1 from pg_catalog.pg_attribute a
                        where a.attrelid='public.mt5_sync_run_account'::regclass
                          and a.attname=x.want and a.attnum>0 and not a.attisdropped);
    if v_bad is not null then
      v_fail:=v_fail+1; raise warning 'V3 FAIL: missing column(s) %',v_bad;
    else v_pass:=v_pass+1; end if;
  end if;

  --------------------------------------------------------------------------- V4 required CHECKs --
  select pg_catalog.string_agg(x.want,', ' order by x.want) into v_bad
    from (values ('mt5_sra_pk'),('mt5_sra_run_scope_fk'),('mt5_sra_read_at_window_chk'),
                 ('mt5_sra_status_chk'),('mt5_sra_equity_quality_chk'),('mt5_sra_balance_quality_chk'),
                 ('mt5_sra_currency_nonblank_chk'),('mt5_sra_equity_finite_chk'),
                 ('mt5_sra_balance_finite_chk'),('mt5_sra_equity_quality_shape_chk'),
                 ('mt5_sra_balance_quality_shape_chk'),('mt5_sra_status_shape_chk'),
                 ('mt5_sra_failure_reason_allowlist_chk'),('mt5_sra_fingerprint_chk')) x(want)
   where not exists (select 1 from pg_catalog.pg_constraint
                      where conrelid='public.mt5_sync_run_account'::regclass and conname=x.want);
  if v_bad is not null then
    v_fail:=v_fail+1; raise warning 'V4 FAIL: missing constraint(s) %',v_bad;
  else v_pass:=v_pass+1; end if;

  ------------------------------------------------ V5 status-shape CHECK is the TOTAL CASE form --
  -- Guards against a future "simplification" back into the nullable directional form that let a
  -- failed row with failure_reason IS NULL pass (design §14).
  select pg_catalog.pg_get_constraintdef(oid) into procedure_note
    from pg_catalog.pg_constraint
   where conrelid='public.mt5_sync_run_account'::regclass and conname='mt5_sra_status_shape_chk';
  if procedure_note is null
     or procedure_note !~ 'CASE'
     or procedure_note !~ 'failure_reason IS NOT NULL'
     or procedure_note !~ 'ELSE false' then
    v_fail:=v_fail+1;
    raise warning 'V5 FAIL: mt5_sra_status_shape_chk is not the total CASE/IS NOT NULL/ELSE false form: %',
      coalesce(procedure_note,'<missing>');
  else v_pass:=v_pass+1; end if;

  ------------------------------------------------------------------------ V6 immutability triggers --
  select count(*) into v_n from pg_catalog.pg_trigger t
   where t.tgrelid='public.mt5_sync_run_account'::regclass and not t.tgisinternal and t.tgenabled='O';
  if v_n<>2 then
    v_fail:=v_fail+1; raise warning 'V6 FAIL: expected 2 enabled immutability triggers, found %',v_n;
  else v_pass:=v_pass+1; end if;

  ----------------------------------------------------------------------------- V7 RLS and ACLs --
  if not (select relrowsecurity from pg_catalog.pg_class
           where oid='public.mt5_sync_run_account'::regclass) then
    v_fail:=v_fail+1; raise warning 'V7 FAIL: RLS is not enabled on mt5_sync_run_account';
  else v_pass:=v_pass+1; end if;

  select count(*) into v_n from information_schema.table_privileges p
   where p.table_schema='public' and p.table_name='mt5_sync_run_account'
     and p.grantee in ('anon','authenticated','service_role')
     and p.privilege_type in ('INSERT','UPDATE','DELETE');
  if v_n<>0 then
    v_fail:=v_fail+1; raise warning 'V8 FAIL: % application write grant(s) exist on the account table',v_n;
  else v_pass:=v_pass+1; end if;

  select count(*) into v_n from information_schema.table_privileges p
   where p.table_schema='public' and p.table_name='mt5_sync_run_account'
     and p.grantee in ('anon','authenticated');
  if v_n<>0 then
    v_fail:=v_fail+1; raise warning 'V9 FAIL: anon/authenticated hold % privilege(s) on the account table',v_n;
  else v_pass:=v_pass+1; end if;

  --------------------------------------------------------------------------- V10 RPC grant shape --
  if to_regprocedure('public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)') is null then
    v_fail:=v_fail+1; raise warning 'V10 FAIL: append_run_account RPC is missing';
  elsif has_function_privilege('authenticated','public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)'::regprocedure,'EXECUTE')
     or has_function_privilege('anon','public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)'::regprocedure,'EXECUTE') then
    v_fail:=v_fail+1; raise warning 'V10 FAIL: append_run_account is executable by anon/authenticated';
  elsif not has_function_privilege('service_role','public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)'::regprocedure,'EXECUTE') then
    v_fail:=v_fail+1; raise warning 'V10 FAIL: service_role cannot execute append_run_account';
  else v_pass:=v_pass+1; end if;

  ------------------------------------------------------------- V11 no UPDATE/PATCH RPC was added --
  select count(*) into v_n from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and (p.proname like 'mt5%account%patch%' or p.proname like 'mt5%patch%account%'
       or p.proname like 'mt5%update%run_account%' or p.proname like 'mt5%correct%account%');
  if v_n<>0 then
    v_fail:=v_fail+1; raise warning 'V11 FAIL: % account mutation RPC(s) exist; the design forbids any UPDATE/PATCH path',v_n;
  else v_pass:=v_pass+1; end if;

  ------------------------------------------------------- V12 frozen browser RPC still untouched --
  if to_regprocedure('public.mt5_get_current_snapshot_v1(text)') is null then
    v_fail:=v_fail+1; raise warning 'V12 FAIL: frozen mt5_get_current_snapshot_v1(text) is missing';
  elsif pg_catalog.pg_get_functiondef('public.mt5_get_current_snapshot_v1(text)'::regprocedure) ~* 'mt5_sync_run_account'
     or pg_catalog.pg_get_functiondef('public.mt5_get_current_snapshot_v1(text)'::regprocedure) ~* '\mequity\M'
     or pg_catalog.pg_get_functiondef('public.mt5_get_current_snapshot_v1(text)'::regprocedure) ~* '\mbalance\M' then
    v_fail:=v_fail+1; raise warning 'V12 FAIL: the frozen browser RPC now references account data';
  else v_pass:=v_pass+1; end if;

  ---------------------------------------------- V13 COMPLETED S1.1 RUN INVARIANT (design §13) ----
  -- A completed run whose connector is in the S1.1 namespace MUST have exactly one account row,
  -- including when the broker account read failed (that row has status='failed').
  select count(*) into v_n
    from public.mt5_sync_runs r
    left join public.mt5_sync_run_account a on a.run_id=r.id
   where r.snapshot_status='complete'
     and r.connector_version like 's1.1-oneshot/%'
     and a.run_id is null;
  if v_n<>0 then
    v_fail:=v_fail+1;
    raise warning 'V13 FAIL: S1_1_ACCOUNT_ROW_MISSING_ANOMALY — % completed S1.1 run(s) have no account row',v_n;
    for v_bad in
      select r.id::text||' (run_seq='||coalesce(r.run_seq::text,'?')||', connector='||r.connector_version||')'
        from public.mt5_sync_runs r
        left join public.mt5_sync_run_account a on a.run_id=r.id
       where r.snapshot_status='complete' and r.connector_version like 's1.1-oneshot/%'
         and a.run_id is null
       order by r.run_seq
    loop raise warning '  anomalous run: %',v_bad; end loop;
  else v_pass:=v_pass+1; end if;

  --------------------------------------- V14 HISTORICAL EXEMPTION (design §14) — never backfill --
  -- An S1-era run with no account row is EXPECTED, not an anomaly. This assertion exists so a
  -- future "fix" that backfills historical runs is caught: a pre-S1.1 connector must NOT have one.
  select count(*) into v_n
    from public.mt5_sync_runs r
    join public.mt5_sync_run_account a on a.run_id=r.id
   where r.connector_version not like 's1.1-oneshot/%';
  if v_n<>0 then
    v_fail:=v_fail+1;
    raise warning 'V14 FAIL: % pre-S1.1 run(s) carry an account row — evidence appears to have been backfilled',v_n;
  else v_pass:=v_pass+1; end if;

  ------------------------------------------------------ V15 one row per run, scope and window ----
  select count(*) into v_n from (
    select a.run_id from public.mt5_sync_run_account a group by a.run_id having count(*)>1) d;
  if v_n<>0 then
    v_fail:=v_fail+1; raise warning 'V15 FAIL: % run(s) carry more than one account row',v_n;
  else v_pass:=v_pass+1; end if;

  select count(*) into v_n
    from public.mt5_sync_run_account a join public.mt5_sync_runs r on r.id=a.run_id
   where a.captured_at is distinct from r.captured_at
      or a.user_id is distinct from r.user_id
      or a.source_account is distinct from r.source_account
      or a.connector_version is distinct from r.connector_version;
  if v_n<>0 then
    v_fail:=v_fail+1; raise warning 'V16 FAIL: % account row(s) disagree with their parent run scope/instant',v_n;
  else v_pass:=v_pass+1; end if;

  select count(*) into v_n from public.mt5_sync_run_account a
   where a.account_read_at > a.captured_at
      or a.account_read_at < a.captured_at - interval '30 seconds';
  if v_n<>0 then
    v_fail:=v_fail+1; raise warning 'V17 FAIL: % account row(s) fall outside the 30 s contemporaneity window',v_n;
  else v_pass:=v_pass+1; end if;

  ----------------------------------------------- V18 stored fingerprints still recompute exactly --
  select count(*) into v_n from public.mt5_sync_run_account a
   where a.account_fingerprint is distinct from public.mt5_account_fingerprint_v1(
           a.user_id,a.source_account,a.captured_at,a.connector_version,a.account_read_at,
           a.account_observation_status,a.equity,a.balance,a.currency,
           a.equity_quality,a.balance_quality,a.failure_reason);
  if v_n<>0 then
    v_fail:=v_fail+1; raise warning 'V18 FAIL: % account row(s) do not recompute to their stored fingerprint',v_n;
  else v_pass:=v_pass+1; end if;

  ------------------------------------- V19 ROLLBACK ARMING: frozen S1 tables still fingerprint --
  if (v_schema.objects->'provenance' ? 's1_tables_at_apply') is true then
    select pg_catalog.string_agg(x.rel,', ' order by x.rel) into v_bad
      from (values ('mt5_sync_runs'),('mt5_sync_run_positions')) x(rel)
     where (v_schema.objects->'provenance'->'s1_tables_at_apply'->>x.rel) is distinct from (
       select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                pg_catalog.pg_get_userbyid(c.relowner)||'|'||
                coalesce((select pg_catalog.string_agg(
                            a.attname||':'||pg_catalog.format_type(a.atttypid,a.atttypmod)||':'||
                            a.attnotnull::text||':'||
                            coalesce(pg_catalog.pg_get_expr(d.adbin,d.adrelid),'')||':'||
                            a.attidentity::text||':'||a.attgenerated::text, ',' order by a.attnum)
                          from pg_catalog.pg_attribute a
                          left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
                         where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped),'')||'|'||
                coalesce((select pg_catalog.string_agg(k.conname||':'||pg_catalog.pg_get_constraintdef(k.oid),
                            ',' order by k.conname)
                          from pg_catalog.pg_constraint k where k.conrelid=c.oid),'')||'|'||
                coalesce((select pg_catalog.string_agg(pg_catalog.pg_get_indexdef(i.indexrelid),
                            ',' order by pg_catalog.pg_get_indexdef(i.indexrelid))
                          from pg_catalog.pg_index i where i.indrelid=c.oid),'')
              ,'UTF8'),'sha256'),'hex')
         from pg_catalog.pg_class c where c.oid = to_regclass('public.'||x.rel));
    if v_bad is not null then
      v_fail:=v_fail+1;
      raise warning 'V19 FAIL: frozen S1 table(s) % drifted since S1.1 apply — S1 ROLLBACK IS DISARMED',v_bad;
    else v_pass:=v_pass+1; end if;
  else
    v_fail:=v_fail+1; raise warning 'V19 FAIL: S1.1 ledger recorded no s1_tables_at_apply fingerprints';
  end if;

  ------------------------------------------------- V20 RPC S1.1 CONNECTOR NAMESPACE GATE (§6) ----
  -- A source-level assertion, like V5. The gate is a REFUSAL, so a database with no S1-namespace
  -- run cannot demonstrate it behaviourally, and its absence would be invisible until a foreign
  -- client attached account evidence to a run V13 never inspects.
  if to_regprocedure('public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)') is null then
    v_fail:=v_fail+1; raise warning 'V20 FAIL: mt5_append_run_account_v1 is missing';
  else
    select pg_catalog.pg_get_functiondef(
             'public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)'::regprocedure)
      into procedure_note;
    if procedure_note not like '%ERR_CONNECTOR_NOT_S1_1%'
       or procedure_note not like '%s1.1-oneshot/%%' then
      v_fail:=v_fail+1;
      raise warning 'V20 FAIL: the S1.1 connector-namespace gate is absent from mt5_append_run_account_v1 — a run outside the S1.1 namespace could be given account evidence that V13 never inspects';
    else v_pass:=v_pass+1; end if;
  end if;

  --------------------------------------------- V21 APPLY-TIME PROVENANCE COMPLETENESS (§11-§17) ---
  -- Rollback's destructive authority is exactly what apply recorded. If a class is missing here,
  -- rollback cannot check it, and a materially changed object would be dropped under its old name.
  if v_schema.objects is null or (v_schema.objects->'provenance') is null then
    v_fail:=v_fail+1; raise warning 'V21 FAIL: S1.1 schema ledger carries no provenance';
  else
    select pg_catalog.string_agg(x.want,', ' order by x.want) into v_bad
      from (values ('tables'),('security'),('column_acl'),('functions'),('triggers'),
                   ('policies'),('s1_tables_at_apply')) x(want)
     where (v_schema.objects->'provenance' ? x.want) is not true;
    if v_bad is not null then
      v_fail:=v_fail+1;
      raise warning 'V21 FAIL: apply-time provenance is missing class(es) % — S1.1 rollback cannot establish authority over them',v_bad;
    elsif (select count(*) from pg_catalog.jsonb_object_keys(
             v_schema.objects->'provenance'->'triggers')) <> 2
       or (select count(*) from pg_catalog.jsonb_object_keys(
             v_schema.objects->'provenance'->'policies')) <> 1 then
      v_fail:=v_fail+1;
      raise warning 'V21 FAIL: apply-time provenance does not describe exactly 2 triggers and 1 policy';
    else v_pass:=v_pass+1; end if;
  end if;

  ------------------------------------------------------- V22 ONE NAMESPACE DEFINITION (§8) --------
  -- V13/V14 above key off 's1.1-oneshot/%'. The RPC gate and the adapter must use the SAME prefix,
  -- or a run could be accepted by one layer and invisible to the other.
  if not exists (select 1 from public.mt5_sync_runs r
                  where r.connector_version like 's1.1-oneshot/%')
     and not exists (select 1 from public.mt5_sync_runs) then
    v_pass:=v_pass+1;   -- empty database: nothing to contradict, and V20 already proved the prefix
  else
    select count(*) into v_n from public.mt5_sync_run_account a
      join public.mt5_sync_runs r on r.id=a.run_id
     where r.connector_version not like 's1.1-oneshot/%';
    if v_n<>0 then
      v_fail:=v_fail+1;
      raise warning 'V22 FAIL: % account row(s) belong to a run OUTSIDE the S1.1 connector namespace — the RPC gate was bypassed or the namespace definition drifted',v_n;
    else v_pass:=v_pass+1; end if;
  end if;

  ------------------------------------------------------ V23 NO COLUMN-LEVEL PRIVILEGE EXISTS -----
  -- Table privileges are NOT sufficient: `GRANT SELECT (equity) ... TO authenticated` grants real
  -- read access to broker equity while every table-level privilege check still passes.
  if to_regclass('public.mt5_sync_run_account') is null then
    v_fail:=v_fail+1; raise warning 'V23 FAIL: account table is missing';
  else
    select pg_catalog.string_agg(a.attname,', ' order by a.attnum) into v_bad
      from pg_catalog.pg_attribute a
     where a.attrelid='public.mt5_sync_run_account'::regclass
       and a.attnum>0 and not a.attisdropped and a.attacl is not null;
    if v_bad is not null then
      v_fail:=v_fail+1;
      raise warning 'V23 FAIL: unexpected column-level ACL on column(s) % — a column grant is real access that no table-privilege check can see',v_bad;
    else v_pass:=v_pass+1; end if;
  end if;

  --------------------------------------------- V24 COLUMN-ACL PROVENANCE STILL REPRODUCES --------
  -- The live column-ACL state must still equal what apply recorded. This is the same comparison
  -- rollback makes, so a V24 failure is advance warning that rollback will (correctly) refuse.
  if v_schema.objects is null
     or (v_schema.objects->'provenance'->'column_acl'->>'fingerprint') is null then
    v_fail:=v_fail+1;
    raise warning 'V24 FAIL: the schema ledger carries no apply-time column-ACL provenance — rollback cannot establish authority over it';
  elsif (v_schema.objects->'provenance'->'column_acl'->>'fingerprint') is distinct from (
          select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                   coalesce((select pg_catalog.string_agg(
             c2.attnum::text||':'||c2.attname||':'||
             case when c2.attacl is null then 'NULL'
                  else 'ACL['||coalesce((
                         select pg_catalog.string_agg(e.ent,',' order by e.ent)
                           from (select (case when x.grantee=0 then 'PUBLIC'
                                              else pg_catalog.pg_get_userbyid(x.grantee) end)
                                        ||'/'||
                                        (case when x.grantor=0 then 'PUBLIC'
                                              else pg_catalog.pg_get_userbyid(x.grantor) end)
                                        ||'/'||x.privilege_type
                                        ||'/'||x.is_grantable::text as ent
                                   from pg_catalog.aclexplode(c2.attacl) as x) e),'')||']'
             end, '|' order by c2.attnum)
           from pg_catalog.pg_attribute c2
          where c2.attrelid='public.mt5_sync_run_account'::regclass
            and c2.attnum>0 and not c2.attisdropped),'')
                 ,'UTF8'),'sha256'),'hex')) then
    v_fail:=v_fail+1;
    raise warning 'V24 FAIL: column-ACL state has drifted from apply-time provenance — S1.1 rollback will refuse until this is explained';
  else v_pass:=v_pass+1; end if;

  -------------------------------------------------------------------------------------- summary --
  raise notice '=========================================================';
  raise notice 'MT5 S1.1 VERIFICATION: % passed, % failed',v_pass,v_fail;
  raise notice '=========================================================';
  if v_fail<>0 then
    raise exception 'MT5_S1_1_VERIFICATION: % assertion(s) FAILED',v_fail;
  end if;
end
$s11_verify$;

rollback;
