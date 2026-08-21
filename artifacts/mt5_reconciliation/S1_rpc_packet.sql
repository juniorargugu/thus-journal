-- MT5 S1 append-only RPC packet
-- Contract source: S1_append_only_snapshot_membership_design.md revision 3
-- Status: executable draft, intentionally UNAPPLIED.
-- Requires successful mt5_s1_append_only_schema_v1.
-- Ledger version: mt5_s1_append_only_rpc_v1
-- Contract checksum: 97f4e993f407fc49794e4e230d9a5071a138624e196fe7c2ed233727ccc73cd1

begin;

do $preflight$
declare
  v_schema public.mt5_schema_migrations%rowtype;
  v_name text;
begin
  select m.* into v_schema
    from public.mt5_schema_migrations m
   where m.version='mt5_s1_append_only_schema_v1';
  if not found or v_schema.status <> 'applied'
     or v_schema.checksum <> 'd72f7c1128226743508c6ea5b9218b7ea5946a13ed2f88de1e8c772550b9c338'
     or v_schema.source_artifact_sha256 <> '9902B301B3E170A7FD5AA348C9892395CEBEE129DF1B5F63FAB9F62D53CA266D' then
    raise exception 'MT5_S1_RPC_PREFLIGHT: exact schema ledger entry is missing';
  end if;
  if exists (select 1 from public.mt5_schema_migrations m where m.version='mt5_s1_append_only_rpc_v1') then
    raise exception 'MT5_S1_RPC_PREFLIGHT: RPC ledger version already exists';
  end if;
  if to_regclass('public.mt5_sync_runs') is null
     or to_regclass('public.mt5_sync_run_positions') is null then
    raise exception 'MT5_S1_RPC_PREFLIGHT: required schema objects are missing';
  end if;
  foreach v_name in array array[
    'mt5_s1_policy_v1','mt5_sha256_text_v1','mt5_position_fingerprint_v1',
    'mt5_create_run_v1','mt5_heartbeat_run_v1','mt5_append_run_positions_v1',
    'mt5_complete_snapshot_v1','mt5_reconcile_snapshot_v1',
    'mt5_mark_snapshot_failed_v1','mt5_mark_reconcile_failed_v1',
    'mt5_expire_stale_run_v1','mt5_get_current_snapshot_v1'
  ] loop
    if exists (
      select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=v_name
    ) then
      raise exception 'MT5_S1_RPC_PREFLIGHT: incompatible function name already exists: %',v_name;
    end if;
  end loop;
end
$preflight$;

-- Internal policy and canonical-audit helpers. They are not application RPCs.
create function public.mt5_s1_policy_v1(p_version text) returns jsonb
language sql stable security definer set search_path=''
as $policy$
  select case p_version
    when 's1.v1' then pg_catalog.jsonb_build_object(
      'k',2,
      'susp_min_base',3,
      'susp_drop_ratio',0.80,
      'freshness_seconds',1800
    )
    else null::jsonb
  end
$policy$;

create function public.mt5_sha256_text_v1(p_value text) returns text
language sql immutable security definer set search_path=''
as $sha$
  select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_value,'UTF8'),'sha256'),'hex')
$sha$;

create function public.mt5_position_fingerprint_v1(
  p_position_id bigint,
  p_symbol_raw text,
  p_side text,
  p_volume numeric,
  p_price_open numeric,
  p_price_current numeric,
  p_profit numeric,
  p_open_time_utc timestamptz,
  p_source_time_msc bigint,
  p_contract_size numeric,
  p_captured_at timestamptz
) returns text
language sql stable security definer set search_path=''
as $fingerprint$
  select public.mt5_sha256_text_v1(
    pg_catalog.jsonb_build_array(
      pg_catalog.to_jsonb(p_position_id),
      pg_catalog.to_jsonb(p_symbol_raw),
      pg_catalog.to_jsonb(p_side),
      pg_catalog.to_jsonb(p_volume),
      pg_catalog.to_jsonb(p_price_open),
      pg_catalog.to_jsonb(p_price_current),
      pg_catalog.to_jsonb(p_profit),
      pg_catalog.to_jsonb(case when p_open_time_utc is null then null else
        extract(epoch from p_open_time_utc)::numeric end),
      pg_catalog.to_jsonb(p_source_time_msc),
      pg_catalog.to_jsonb(p_contract_size),
      pg_catalog.to_jsonb(extract(epoch from p_captured_at)::numeric)
    )::text
  )
$fingerprint$;

create function public.mt5_create_run_v1(
  p_run_id uuid,
  p_user uuid,
  p_account text,
  p_lease_token uuid,
  p_lease_seconds integer,
  p_captured_at timestamptz,
  p_connector_version text,
  p_terminal_build integer,
  p_terminal_server text,
  p_policy_version text
) returns table(o_ok boolean,o_run_id uuid,o_lease_expires_at timestamptz,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare
  v_run public.mt5_sync_runs%rowtype;
  v_active public.mt5_sync_runs%rowtype;
  v_policy jsonb;
  v_now timestamptz;
begin
  if p_run_id is null or p_user is null or p_lease_token is null or p_captured_at is null
     or p_account is null or btrim(p_account)=''
     or p_connector_version is null or btrim(p_connector_version)=''
     or p_policy_version is null or btrim(p_policy_version)=''
     or p_lease_seconds is null or p_lease_seconds not between 30 and 3600 then
    return query select false,null::uuid,null::timestamptz,'ERR_BAD_INPUT'; return;
  end if;
  v_policy := public.mt5_s1_policy_v1(p_policy_version);
  if v_policy is null then
    return query select false,null::uuid,null::timestamptz,'ERR_POLICY_UNSUPPORTED'; return;
  end if;
  v_now := clock_timestamp();
  if p_captured_at > v_now + interval '5 minutes' then
    return query select false,null::uuid,null::timestamptz,'ERR_CAPTURE_TIME_INVALID'; return;
  end if;

  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if found then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
    v_now := clock_timestamp();  -- refresh AFTER lock wait: lease decisions must use live DB time
    select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
    if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
      return query select false,null::uuid,null::timestamptz,'ERR_RUN_CONFLICT'; return;
    end if;
    if p_captured_at is distinct from v_run.captured_at
       or p_connector_version is distinct from v_run.connector_version
       or p_terminal_build is distinct from v_run.terminal_build
       or p_terminal_server is distinct from v_run.terminal_server
       or p_policy_version is distinct from v_run.policy_version
       or v_policy is distinct from v_run.policy_thresholds then
      return query select false,null::uuid,null::timestamptz,'ERR_RUN_CONFLICT'; return;
    end if;
    if v_run.snapshot_status='complete' then
      return query select false,p_run_id,v_run.lease_expires_at,'ERR_RUN_SEALED'; return;
    elsif v_run.snapshot_status='failed' then
      return query select false,p_run_id,v_run.lease_expires_at,'ERR_RUN_FAILED'; return;
    end if;
    if p_lease_token is distinct from v_run.lease_token then
      return query select false,p_run_id,v_run.lease_expires_at,'ERR_LEASE_MISMATCH'; return;
    end if;
    if v_run.lease_expires_at <= v_now then
      return query select false,p_run_id,v_run.lease_expires_at,'ERR_LEASE_EXPIRED'; return;
    end if;
    update public.mt5_sync_runs r
       set heartbeat_at=v_now,
           lease_expires_at=v_now+pg_catalog.make_interval(secs=>p_lease_seconds),
           updated_at=now()
     where r.id=p_run_id
     returning r.* into v_run;
    return query select true,p_run_id,v_run.lease_expires_at,null::text; return;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_user::text||':'||p_account,0));
  v_now := clock_timestamp();  -- refresh AFTER lock wait: lease/expiry decisions must use live DB time
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if found then
    return query select false,null::uuid,null::timestamptz,'ERR_RUN_CONFLICT'; return;
  end if;
  select r.* into v_active
    from public.mt5_sync_runs r
   where r.user_id=p_user and r.source_account=p_account
     and (r.snapshot_status='started' or (r.snapshot_status='complete' and r.reconcile_status='pending'))
   for update;
  if found then
    if v_active.lease_expires_at <= v_now then
      return query select false,v_active.id,v_active.lease_expires_at,'ERR_RUN_EXPIRED'; return;
    end if;
    return query select false,v_active.id,v_active.lease_expires_at,'ERR_RUN_ACTIVE'; return;
  end if;

  begin
    insert into public.mt5_sync_runs(
      id,user_id,source_account,captured_at,snapshot_status,reconcile_status,
      policy_version,policy_thresholds,connector_version,terminal_build,terminal_server,
      lease_token,lease_expires_at,heartbeat_at,created_at,updated_at
    ) values (
      p_run_id,p_user,p_account,p_captured_at,'started','pending',
      p_policy_version,v_policy,p_connector_version,p_terminal_build,p_terminal_server,
      p_lease_token,v_now+pg_catalog.make_interval(secs=>p_lease_seconds),v_now,now(),now()
    ) returning * into v_run;
  exception when unique_violation then
    return query select false,null::uuid,null::timestamptz,'ERR_RUN_CONFLICT'; return;
  end;
  return query select true,v_run.id,v_run.lease_expires_at,null::text;
end
$fn$;

create function public.mt5_heartbeat_run_v1(
  p_run_id uuid,p_user uuid,p_account text,p_lease_token uuid,p_lease_seconds integer
) returns table(o_ok boolean,o_lease_expires_at timestamptz,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare v_run public.mt5_sync_runs%rowtype; v_now timestamptz;
begin
  if p_run_id is null or p_user is null or p_lease_token is null
     or p_account is null or btrim(p_account)=''
     or p_lease_seconds is null or p_lease_seconds not between 30 and 3600 then
    return query select false,null::timestamptz,'ERR_BAD_INPUT'; return;
  end if;
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if not found then return query select false,null::timestamptz,'ERR_RUN_NOT_FOUND'; return; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
    return query select false,null::timestamptz,'ERR_RUN_CONFLICT'; return;
  end if;
  if v_run.snapshot_status='failed' then
    return query select false,v_run.lease_expires_at,'ERR_RUN_FAILED'; return;
  elsif v_run.snapshot_status='complete' and v_run.reconcile_status='complete' then
    return query select false,v_run.lease_expires_at,'ERR_NOT_ACTIVE'; return;
  elsif v_run.snapshot_status='complete' and v_run.reconcile_status='failed' then
    return query select false,v_run.lease_expires_at,'ERR_RECONCILE_FAILED'; return;
  end if;
  if p_lease_token is distinct from v_run.lease_token then
    return query select false,v_run.lease_expires_at,'ERR_LEASE_MISMATCH'; return;
  end if;
  v_now:=clock_timestamp();
  if v_run.lease_expires_at <= v_now then
    return query select false,v_run.lease_expires_at,'ERR_LEASE_EXPIRED'; return;
  end if;
  update public.mt5_sync_runs r
     set heartbeat_at=v_now,lease_expires_at=v_now+pg_catalog.make_interval(secs=>p_lease_seconds),updated_at=now()
   where r.id=p_run_id returning r.lease_expires_at into v_run.lease_expires_at;
  return query select true,v_run.lease_expires_at,null::text;
end
$fn$;

create function public.mt5_append_run_positions_v1(
  p_run_id uuid,p_user uuid,p_account text,p_lease_token uuid,p_rows jsonb
) returns table(o_ok boolean,o_inserted integer,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare v_run public.mt5_sync_runs%rowtype; v_now timestamptz; v_inserted integer:=0;
begin
  -- (1) scalar identity arguments — no payload inspection in this branch.
  if p_run_id is null or p_user is null or p_lease_token is null
     or p_account is null or btrim(p_account)='' then
    return query select false,0,'ERR_BAD_INPUT'; return;
  end if;
  -- (2) payload container shape — STAGED, deliberately NOT one OR chain. PostgreSQL does not
  --     guarantee left-to-right OR short-circuiting, so jsonb_array_length() must never share a
  --     boolean expression with the jsonb_typeof() test that makes it safe. Each check below runs
  --     only after the previous one has positively established the shape it depends on. Every
  --     payload-shape rejection maps to the single stable code ERR_BAD_PAYLOAD.
  if p_rows is null then                                            -- SQL NULL payload
    return query select false,0,'ERR_BAD_PAYLOAD'; return;
  end if;
  if pg_catalog.jsonb_typeof(p_rows) is distinct from 'array' then  -- wrong JSON type (object/scalar/json null)
    return query select false,0,'ERR_BAD_PAYLOAD'; return;
  end if;
  if pg_catalog.octet_length(p_rows::text)>8388608 then             -- safe for any jsonb
    return query select false,0,'ERR_BAD_PAYLOAD'; return;
  end if;
  if pg_catalog.jsonb_array_length(p_rows)>10000 then               -- SAFE: type proven 'array' above
    return query select false,0,'ERR_BAD_PAYLOAD'; return;
  end if;
  -- (3) every element must itself be a JSON object, otherwise jsonb_to_recordset would raise a raw
  --     "argument must be an array of objects" error later. Empty array passes (0 elements) and keeps
  --     the frozen Revision-3 valid-empty-snapshot semantics unchanged.
  if exists (
    select 1 from pg_catalog.jsonb_array_elements(p_rows) as e
     where pg_catalog.jsonb_typeof(e) is distinct from 'object'
  ) then
    return query select false,0,'ERR_BAD_PAYLOAD'; return;
  end if;
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if not found then return query select false,0,'ERR_RUN_NOT_FOUND'; return; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
    return query select false,0,'ERR_RUN_CONFLICT'; return;
  end if;
  if v_run.snapshot_status='complete' then return query select false,0,'ERR_RUN_SEALED'; return;
  elsif v_run.snapshot_status='failed' then return query select false,0,'ERR_RUN_FAILED'; return;
  elsif v_run.snapshot_status<>'started' then return query select false,0,'ERR_NOT_STARTED'; return;
  end if;
  if p_lease_token is distinct from v_run.lease_token then
    return query select false,0,'ERR_LEASE_MISMATCH'; return;
  end if;
  v_now:=clock_timestamp();
  if v_run.lease_expires_at<=v_now then return query select false,0,'ERR_LEASE_EXPIRED'; return; end if;
  if v_run.captured_at is null then return query select false,0,'ERR_CAPTURE_TIME_INVALID'; return; end if;

  begin
    if exists (
      select 1 from pg_catalog.jsonb_to_recordset(p_rows) as x(position_id bigint)
       where x.position_id is null
    ) or exists (
      select 1 from pg_catalog.jsonb_to_recordset(p_rows) as x(position_id bigint)
       group by x.position_id having count(*)>1
    ) then
      return query select false,0,'ERR_NULL_OR_DUP_ID'; return;
    end if;
    if exists (
      select 1
        from pg_catalog.jsonb_to_recordset(p_rows) as x(
          position_id bigint,symbol_raw text,side text,volume numeric,price_open numeric,
          price_current numeric,profit numeric,open_time_utc timestamptz,source_time_msc bigint,contract_size numeric)
       where x.symbol_raw is null or btrim(x.symbol_raw)=''
          or x.side is null or x.side not in ('buy','sell')
          or x.volume is null or not (x.volume>0 and x.volume<>'NaN'::numeric)
          or x.price_open='NaN'::numeric or x.price_current='NaN'::numeric
          or x.profit='NaN'::numeric or x.contract_size='NaN'::numeric
    ) then
      return query select false,0,'ERR_MISSING_FACT'; return;
    end if;
    if exists (
      select 1
        from pg_catalog.jsonb_to_recordset(p_rows) as x(
          position_id bigint,symbol_raw text,side text,volume numeric,price_open numeric,
          price_current numeric,profit numeric,open_time_utc timestamptz,source_time_msc bigint,contract_size numeric)
        join public.mt5_sync_run_positions p on p.run_id=p_run_id and p.position_id=x.position_id
       where p.symbol_raw is distinct from x.symbol_raw
          or p.side is distinct from x.side
          or p.volume is distinct from x.volume
          or p.price_open is distinct from x.price_open
          or p.price_current is distinct from x.price_current
          or p.profit is distinct from x.profit
          or p.open_time_utc is distinct from x.open_time_utc
          or p.source_time_msc is distinct from x.source_time_msc
          or p.contract_size is distinct from x.contract_size
          or p.captured_at is distinct from v_run.captured_at
    ) then
      return query select false,0,'ERR_POSITION_CONFLICT'; return;
    end if;

    with src as (
      select x.* from pg_catalog.jsonb_to_recordset(p_rows) as x(
        position_id bigint,symbol_raw text,side text,volume numeric,price_open numeric,
        price_current numeric,profit numeric,open_time_utc timestamptz,source_time_msc bigint,contract_size numeric)
    ), ins as (
      insert into public.mt5_sync_run_positions(
        run_id,user_id,source_account,position_id,symbol_raw,side,volume,price_open,price_current,
        profit,open_time_utc,source_time_msc,contract_size,captured_at,row_fingerprint,created_at
      )
      select p_run_id,v_run.user_id,v_run.source_account,s.position_id,s.symbol_raw,s.side,s.volume,
             s.price_open,s.price_current,s.profit,s.open_time_utc,s.source_time_msc,s.contract_size,
             v_run.captured_at,
             public.mt5_position_fingerprint_v1(s.position_id,s.symbol_raw,s.side,s.volume,s.price_open,
               s.price_current,s.profit,s.open_time_utc,s.source_time_msc,s.contract_size,v_run.captured_at),
             now()
        from src s
      on conflict (run_id,position_id) do nothing
      returning 1
    ) select count(*)::integer into v_inserted from ins;
  exception when others then
    -- any payload parse/shape/cast failure inside this tightly scoped block -> stable contract error
    return query select false,0,'ERR_BAD_PAYLOAD'; return;
  end;
  return query select true,v_inserted,null::text;
end
$fn$;

create function public.mt5_complete_snapshot_v1(
  p_run_id uuid,p_user uuid,p_account text,p_lease_token uuid,
  p_expected_count integer,p_expected_ids bigint[]
) returns table(o_ok boolean,o_run_seq bigint,o_snapshot_health text,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare
  v_run public.mt5_sync_runs%rowtype;
  v_latest public.mt5_sync_runs%rowtype;
  v_policy jsonb;
  v_ids bigint[];
  v_expected_ids bigint[];
  v_count integer;
  v_expected_n integer;
  v_ids_hash text;
  v_manifest text;
  v_prev integer;
  v_seq bigint;
  v_health text;
  v_warning text;
  v_k integer;
  v_base integer;
  v_ratio numeric;
  v_now timestamptz;
begin
  if p_run_id is null or p_user is null or p_lease_token is null
     or p_account is null or btrim(p_account)=''
     or p_expected_count is null or p_expected_count<0 or p_expected_ids is null then
    return query select false,null::bigint,null::text,'ERR_BAD_INPUT'; return;
  end if;
  if exists(select 1 from unnest(p_expected_ids) x where x is null) then
    return query select false,null::bigint,null::text,'ERR_NULL_OR_DUP_ID'; return;
  end if;
  select coalesce(array_agg(q.id order by q.id),array[]::bigint[]),count(*)::integer
    into v_expected_ids,v_expected_n
    from (select distinct x.id from unnest(p_expected_ids) x(id)) q;
  if v_expected_n<>coalesce(array_length(p_expected_ids,1),0) then
    return query select false,null::bigint,null::text,'ERR_NULL_OR_DUP_ID'; return;
  end if;
  if p_expected_count<>v_expected_n then
    return query select false,null::bigint,null::text,'ERR_COUNT_MISMATCH'; return;
  end if;

  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if not found then return query select false,null::bigint,null::text,'ERR_RUN_NOT_FOUND'; return; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
    return query select false,null::bigint,null::text,'ERR_RUN_CONFLICT'; return;
  end if;

  select coalesce(array_agg(p.position_id order by p.position_id),array[]::bigint[]),
         count(*)::integer,
         public.mt5_sha256_text_v1(coalesce('['||string_agg(
           public.mt5_position_fingerprint_v1(p.position_id,p.symbol_raw,p.side,p.volume,p.price_open,
             p.price_current,p.profit,p.open_time_utc,p.source_time_msc,p.contract_size,p.captured_at),
           ',' order by p.position_id)||']','[]'))
    into v_ids,v_count,v_manifest
    from public.mt5_sync_run_positions p
   where p.run_id=p_run_id and p.user_id=v_run.user_id and p.source_account=v_run.source_account;
  v_ids_hash:=public.mt5_sha256_text_v1(pg_catalog.to_jsonb(v_ids)::text);

  if exists (
    select 1 from public.mt5_sync_run_positions p
     where p.run_id=p_run_id
       and (p.user_id is distinct from v_run.user_id or p.source_account is distinct from v_run.source_account)
  ) then return query select false,null::bigint,null::text,'ERR_SCOPE_CORRUPT'; return; end if;
  if exists (
    select 1 from public.mt5_sync_run_positions p
     where p.run_id=p_run_id and p.row_fingerprint is distinct from
       public.mt5_position_fingerprint_v1(p.position_id,p.symbol_raw,p.side,p.volume,p.price_open,
         p.price_current,p.profit,p.open_time_utc,p.source_time_msc,p.contract_size,p.captured_at)
  ) then return query select false,null::bigint,null::text,'ERR_CHILD_CORRUPT'; return; end if;

  v_policy:=public.mt5_s1_policy_v1(v_run.policy_version);
  if v_policy is null or v_policy is distinct from v_run.policy_thresholds then
    return query select false,null::bigint,null::text,'ERR_POLICY_INVALID'; return;
  end if;
  begin
    v_k:=(v_policy->>'k')::integer;
    v_base:=(v_policy->>'susp_min_base')::integer;
    v_ratio:=(v_policy->>'susp_drop_ratio')::numeric;
    if v_k not between 1 and 10 or v_base<1 or v_ratio<=0 or v_ratio>1
       or (v_policy->>'freshness_seconds')::integer<1 then
      return query select false,null::bigint,null::text,'ERR_POLICY_INVALID'; return;
    end if;
  exception when others then
    return query select false,null::bigint,null::text,'ERR_POLICY_INVALID'; return;
  end;

  if v_run.snapshot_status='complete' then
    select coalesce(r.positions_count,0) into v_prev
      from public.mt5_sync_runs r
     where r.user_id=v_run.user_id and r.source_account=v_run.source_account
       and r.snapshot_status='complete' and r.snapshot_health='healthy'
       and r.run_seq<v_run.run_seq
     order by r.run_seq desc limit 1;
    v_prev:=coalesce(v_prev,0);
    if v_prev>=v_base and (v_count=0 or (v_prev-v_count)::numeric/nullif(v_prev,0)>=v_ratio) then
      v_health:='suspicious';
    else v_health:='healthy'; end if;
    if v_ids is distinct from v_expected_ids or v_count<>p_expected_count
       or v_ids_hash is distinct from v_run.position_ids_hash
       or v_manifest is distinct from v_run.manifest_hash
       or v_prev is distinct from v_run.previous_positions_count
       or v_health is distinct from v_run.snapshot_health then
      return query select false,null::bigint,null::text,'ERR_REPLAY_CONFLICT'; return;
    end if;
    return query select true,v_run.run_seq,v_run.snapshot_health,null::text; return;
  elsif v_run.snapshot_status='failed' then
    return query select false,null::bigint,null::text,'ERR_RUN_FAILED'; return;
  elsif v_run.snapshot_status<>'started' then
    return query select false,null::bigint,null::text,'ERR_NOT_STARTED'; return;
  end if;
  if p_lease_token is distinct from v_run.lease_token then
    return query select false,null::bigint,null::text,'ERR_LEASE_MISMATCH'; return;
  end if;
  v_now:=clock_timestamp();
  if v_run.lease_expires_at<=v_now then
    return query select false,null::bigint,null::text,'ERR_LEASE_EXPIRED'; return;
  end if;
  if v_ids is distinct from v_expected_ids then
    return query select false,null::bigint,null::text,'ERR_SET_MISMATCH'; return;
  end if;
  if v_count<>p_expected_count then
    return query select false,null::bigint,null::text,'ERR_COUNT_MISMATCH'; return;
  end if;

  select r.* into v_latest from public.mt5_sync_runs r
   where r.user_id=v_run.user_id and r.source_account=v_run.source_account
     and r.snapshot_status='complete'
   order by r.run_seq desc,r.snapshot_completed_at desc,r.id desc limit 1;
  if found and v_run.captured_at<=v_latest.captured_at then
    return query select false,null::bigint,null::text,'ERR_SUPERSEDED'; return;
  end if;
  select coalesce(r.positions_count,0) into v_prev from public.mt5_sync_runs r
   where r.user_id=v_run.user_id and r.source_account=v_run.source_account
     and r.snapshot_status='complete' and r.snapshot_health='healthy'
   order by r.run_seq desc limit 1;
  v_prev:=coalesce(v_prev,0);
  if v_prev>=v_base and (v_count=0 or (v_prev-v_count)::numeric/nullif(v_prev,0)>=v_ratio) then
    v_health:='suspicious';
    v_warning:=case when v_count=0 then 'SUSPICIOUS_ZERO_DROP' else 'SUSPICIOUS_LARGE_DROP' end;
  else v_health:='healthy'; v_warning:=null; end if;
  select coalesce(max(r.run_seq),0)+1 into v_seq from public.mt5_sync_runs r
   where r.user_id=v_run.user_id and r.source_account=v_run.source_account
     and r.snapshot_status='complete';
  update public.mt5_sync_runs r set
    snapshot_status='complete',snapshot_health=v_health,run_seq=v_seq,
    previous_positions_count=v_prev,positions_count=v_count,
    position_ids_hash=v_ids_hash,manifest_hash=v_manifest,warning_code=v_warning,
    snapshot_completed_at=now(),updated_at=now()
   where r.id=p_run_id;
  return query select true,v_seq,v_health,null::text;
end
$fn$;

create function public.mt5_reconcile_snapshot_v1(
  p_run_id uuid,p_user uuid,p_account text,p_lease_token uuid
) returns table(
  o_ok boolean,o_still_open integer,o_missing_once integer,o_not_open_confirmed integer,
  o_conflicts integer,o_error_code text
)
language plpgsql security definer set search_path=''
as $fn$
declare
  v_run public.mt5_sync_runs%rowtype;
  v_k integer;
  v_now timestamptz;
  v_still integer:=0; v_missing integer:=0; v_confirmed integer:=0; v_conflicts integer:=0;
begin
  if p_run_id is null or p_user is null or p_lease_token is null
     or p_account is null or btrim(p_account)='' then
    return query select false,0,0,0,0,'ERR_BAD_INPUT'; return;
  end if;
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if not found then return query select false,0,0,0,0,'ERR_RUN_NOT_FOUND'; return; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
    return query select false,0,0,0,0,'ERR_RUN_CONFLICT'; return;
  end if;
  if exists(select 1 from public.mt5_sync_runs x
     where x.user_id=v_run.user_id and x.source_account=v_run.source_account
       and x.snapshot_status='complete' and x.run_seq>v_run.run_seq) then
    return query select false,0,0,0,0,'ERR_SUPERSEDED'; return;
  end if;
  if v_run.snapshot_status<>'complete' then
    return query select false,0,0,0,0,'ERR_NOT_COMPLETE'; return;
  elsif v_run.reconcile_status='complete' then
    return query select true,0,0,0,0,null::text; return;
  elsif v_run.reconcile_status='failed' then
    return query select false,0,0,0,0,coalesce(v_run.error_code,'ERR_RECONCILE_FAILED'); return;
  end if;
  if p_lease_token is distinct from v_run.lease_token then
    return query select false,0,0,0,0,'ERR_LEASE_MISMATCH'; return;
  end if;
  v_now:=clock_timestamp();
  if v_run.lease_expires_at<=v_now then
    return query select false,0,0,0,0,'ERR_LEASE_EXPIRED'; return;
  end if;
  if v_run.snapshot_health='suspicious' then
    update public.mt5_sync_runs r set reconcile_status='complete',reconciled_at=now(),updated_at=now()
     where r.id=p_run_id;
    return query select true,0,0,0,0,null::text; return;
  elsif v_run.snapshot_health<>'healthy' then
    return query select false,0,0,0,0,'ERR_HEALTH_INVALID'; return;
  end if;
  begin
    v_k:=(v_run.policy_thresholds->>'k')::integer;
    if v_k not between 1 and 10 or public.mt5_s1_policy_v1(v_run.policy_version) is distinct from v_run.policy_thresholds then
      return query select false,0,0,0,0,'ERR_POLICY_INVALID'; return;
    end if;
  exception when others then
    return query select false,0,0,0,0,'ERR_POLICY_INVALID'; return;
  end;
  if exists (
    select 1 from public.mt5_import_staging s
    left join public.mt5_sync_runs b
      on b.id=s.missing_since_run_id and b.user_id=s.user_id and b.source_account=s.source_account
   where s.user_id=v_run.user_id and s.source_account=v_run.source_account
     and s.kind='open' and s.missing_since_run_id is not null
     and (b.id is null or b.snapshot_status<>'complete' or b.snapshot_health<>'healthy')
  ) then return query select false,0,0,0,0,'ERR_BASELINE_INVALID'; return; end if;
  if exists (
    select 1 from public.mt5_import_staging s
     where s.user_id=v_run.user_id and s.source_account=v_run.source_account
       and s.kind='open' and s.position_id is not null
     group by s.position_id having count(*)>1
  ) then return query select false,0,0,0,0,'ERR_STAGING_INVARIANT'; return; end if;

  with candidates as materialized (
    select s.id,s.position_id,s.position_state as old_state,s.missing_since_run_id as old_baseline
      from public.mt5_import_staging s
     where s.user_id=v_run.user_id and s.source_account=v_run.source_account
       and s.kind='open' and s.position_id is not null
  ), eligible as materialized (
    select r.id,r.run_seq
      from public.mt5_sync_runs r
     where r.user_id=v_run.user_id and r.source_account=v_run.source_account
       and r.snapshot_status='complete' and r.snapshot_health='healthy'
       and r.run_seq<=v_run.run_seq
  ), membership_stats as materialized (
    select c.id,c.position_id,c.old_state,c.old_baseline,
           pg_catalog.bool_or(e.id=p_run_id and p.position_id is not null) as observed_now,
           max(e.run_seq) filter(where p.position_id is not null) as last_present_seq
      from candidates c cross join eligible e
      left join public.mt5_sync_run_positions p
        on p.run_id=e.id and p.position_id=c.position_id
     group by c.id,c.position_id,c.old_state,c.old_baseline
  ), absence_stats as materialized (
    select m.id,m.position_id,m.old_state,m.old_baseline,m.observed_now,m.last_present_seq,
           count(*) filter(where p.position_id is null and e.run_seq>coalesce(m.last_present_seq,-1))::integer as streak,
           (array_agg(e.id order by e.run_seq)
             filter(where p.position_id is null and e.run_seq>coalesce(m.last_present_seq,-1)))[1] as first_absent_run_id
      from membership_stats m cross join eligible e
      left join public.mt5_sync_run_positions p
        on p.run_id=e.id and p.position_id=m.position_id
     group by m.id,m.position_id,m.old_state,m.old_baseline,m.observed_now,m.last_present_seq
  ), decisions as materialized (
    select a.*,
      case
        when a.observed_now and a.old_state in ('seen_open','open','unknown','missing_once','still_open') then 'still_open'
        when a.observed_now and a.old_state in ('not_open_confirmed','partial','closed_confirmed','closed','gone') then 'unknown'
        when not a.observed_now and a.old_state in ('still_open','seen_open','open') then 'missing_once'
        when not a.observed_now and a.old_state='missing_once' and a.streak>=v_k then 'not_open_confirmed'
        when not a.observed_now and a.old_state='missing_once' then 'missing_once'
        else a.old_state
      end as new_state,
      case
        when a.observed_now then null::uuid
        when not a.observed_now and a.old_state in ('still_open','seen_open','open') then p_run_id
        when not a.observed_now and a.old_state='missing_once' then a.first_absent_run_id
        else a.old_baseline
      end as new_baseline,
      (a.observed_now or a.old_state in ('still_open','seen_open','open','missing_once')) as mutate
    from absence_stats a
  ), updated as (
    update public.mt5_import_staging s
       set position_state=d.new_state,
           missing_since_run_id=d.new_baseline,
           lifecycle_updated_at=now()
      from decisions d
     where s.id=d.id and d.mutate
    returning d.new_state,d.observed_now,d.old_state
  )
  select count(*) filter(where u.new_state='still_open')::integer,
         count(*) filter(where u.new_state='missing_once')::integer,
         count(*) filter(where u.new_state='not_open_confirmed')::integer,
         count(*) filter(where u.new_state='unknown' and u.observed_now
           and u.old_state in ('not_open_confirmed','partial','closed_confirmed','closed','gone'))::integer
    into v_still,v_missing,v_confirmed,v_conflicts
    from updated u;

  update public.mt5_sync_runs r set reconcile_status='complete',reconciled_at=now(),updated_at=now()
   where r.id=p_run_id;
  return query select true,coalesce(v_still,0),coalesce(v_missing,0),coalesce(v_confirmed,0),
                      coalesce(v_conflicts,0),null::text;
end
$fn$;

create function public.mt5_mark_snapshot_failed_v1(
  p_run_id uuid,p_user uuid,p_account text,p_lease_token uuid,p_reason_code text
) returns table(o_ok boolean,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare v_run public.mt5_sync_runs%rowtype; v_now timestamptz;
begin
  if p_run_id is null or p_user is null or p_lease_token is null or p_account is null or btrim(p_account)=''
     or p_reason_code is null
     or p_reason_code not in ('CAPTURE_FAILED','VALIDATION_FAILED','APPEND_FAILED','SEAL_FAILED',
       'UNSUPPORTED_MARGIN_MODE','OPERATOR_CANCELLED') then
    return query select false,'ERR_BAD_INPUT'; return;
  end if;
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if not found then return query select false,'ERR_RUN_NOT_FOUND'; return; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
    return query select false,'ERR_RUN_CONFLICT'; return;
  end if;
  if v_run.snapshot_status='failed' then
    if v_run.error_code=p_reason_code then return query select true,null::text;
    else return query select false,'ERR_REPLAY_CONFLICT'; end if; return;
  elsif v_run.snapshot_status='complete' then return query select false,'ERR_RUN_SEALED'; return;
  end if;
  if p_lease_token is distinct from v_run.lease_token then return query select false,'ERR_LEASE_MISMATCH'; return; end if;
  v_now:=clock_timestamp();
  if v_run.lease_expires_at<=v_now then return query select false,'ERR_LEASE_EXPIRED'; return; end if;
  update public.mt5_sync_runs r set snapshot_status='failed',snapshot_failed_at=now(),error_code=p_reason_code,updated_at=now()
   where r.id=p_run_id;
  return query select true,null::text;
end
$fn$;

create function public.mt5_mark_reconcile_failed_v1(
  p_run_id uuid,p_user uuid,p_account text,p_lease_token uuid,p_reason_code text
) returns table(o_ok boolean,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare v_run public.mt5_sync_runs%rowtype; v_now timestamptz;
begin
  if p_run_id is null or p_user is null or p_lease_token is null or p_account is null or btrim(p_account)=''
     or p_reason_code is null
     or p_reason_code not in ('LIFECYCLE_INVARIANT','BASELINE_INVALID','RECONCILE_FAILED','OPERATOR_CANCELLED') then
    return query select false,'ERR_BAD_INPUT'; return;
  end if;
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if not found then return query select false,'ERR_RUN_NOT_FOUND'; return; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
    return query select false,'ERR_RUN_CONFLICT'; return;
  end if;
  if exists(select 1 from public.mt5_sync_runs x where x.user_id=v_run.user_id
    and x.source_account=v_run.source_account and x.snapshot_status='complete' and x.run_seq>v_run.run_seq) then
    return query select false,'ERR_SUPERSEDED'; return;
  end if;
  if v_run.snapshot_status<>'complete' then return query select false,'ERR_NOT_COMPLETE'; return; end if;
  if v_run.reconcile_status='failed' then
    if v_run.error_code=p_reason_code then return query select true,null::text;
    else return query select false,'ERR_REPLAY_CONFLICT'; end if; return;
  elsif v_run.reconcile_status='complete' then return query select false,'ERR_ALREADY_RECONCILED'; return;
  end if;
  if p_lease_token is distinct from v_run.lease_token then return query select false,'ERR_LEASE_MISMATCH'; return; end if;
  v_now:=clock_timestamp();
  if v_run.lease_expires_at<=v_now then return query select false,'ERR_LEASE_EXPIRED'; return; end if;
  update public.mt5_sync_runs r set reconcile_status='failed',reconcile_failed_at=now(),error_code=p_reason_code,updated_at=now()
   where r.id=p_run_id;
  return query select true,null::text;
end
$fn$;

create function public.mt5_expire_stale_run_v1(
  p_run_id uuid,p_user uuid,p_account text
) returns table(o_ok boolean,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare v_run public.mt5_sync_runs%rowtype; v_now timestamptz;
begin
  if p_run_id is null or p_user is null or p_account is null or btrim(p_account)='' then
    return query select false,'ERR_BAD_INPUT'; return;
  end if;
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id;
  if not found then return query select false,'ERR_RUN_NOT_FOUND'; return; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_run.user_id::text||':'||v_run.source_account,0));
  select r.* into v_run from public.mt5_sync_runs r where r.id=p_run_id for update;
  if p_user is distinct from v_run.user_id or p_account is distinct from v_run.source_account then
    return query select false,'ERR_RUN_CONFLICT'; return;
  end if;
  if v_run.snapshot_status='failed' and v_run.error_code='LEASE_EXPIRED' then
    return query select true,null::text; return;
  elsif v_run.snapshot_status='complete' and v_run.reconcile_status='failed'
        and v_run.error_code='RECONCILE_LEASE_EXPIRED' then
    return query select true,null::text; return;
  elsif v_run.snapshot_status='failed' then return query select false,'ERR_RUN_FAILED'; return;
  elsif v_run.snapshot_status='complete' and v_run.reconcile_status='complete' then
    return query select false,'ERR_ALREADY_RECONCILED'; return;
  elsif v_run.snapshot_status='complete' and v_run.reconcile_status='failed' then
    return query select false,'ERR_RECONCILE_FAILED'; return;
  end if;
  v_now:=clock_timestamp();
  if v_run.lease_expires_at>v_now then return query select false,'ERR_LEASE_NOT_EXPIRED'; return; end if;
  if v_run.snapshot_status='started' then
    update public.mt5_sync_runs r set snapshot_status='failed',snapshot_failed_at=now(),error_code='LEASE_EXPIRED',updated_at=now()
     where r.id=p_run_id;
  elsif v_run.snapshot_status='complete' and v_run.reconcile_status='pending' then
    update public.mt5_sync_runs r set reconcile_status='failed',reconcile_failed_at=now(),
      error_code='RECONCILE_LEASE_EXPIRED',updated_at=now() where r.id=p_run_id;
  else return query select false,'ERR_NOT_ACTIVE'; return;
  end if;
  return query select true,null::text;
end
$fn$;

create function public.mt5_get_current_snapshot_v1(p_source_account text) returns jsonb
language plpgsql security definer set search_path=''
as $fn$
declare
  v_uid uuid;
  v_run public.mt5_sync_runs%rowtype;
  v_freshness_seconds integer;
  v_age_seconds numeric;
  v_state text;
  v_positions jsonb:='[]'::jsonb;
begin
  v_uid:=auth.uid();
  if v_uid is null then
    return pg_catalog.jsonb_build_object('ok',false,'error_code','ERR_UNAUTHENTICATED');
  end if;
  if p_source_account is null or btrim(p_source_account)='' then
    return pg_catalog.jsonb_build_object('ok',false,'error_code','ERR_BAD_INPUT');
  end if;
  select r.* into v_run from public.mt5_sync_runs r
   where r.user_id=v_uid and r.source_account=p_source_account and r.snapshot_status='complete'
   order by r.run_seq desc,r.snapshot_completed_at desc,r.id desc limit 1;
  if not found then
    return pg_catalog.jsonb_build_object('ok',true,'error_code',null,'freshness_state','no_snapshot',
      'snapshot',null,'positions','[]'::jsonb);
  end if;
  begin
    v_freshness_seconds:=(v_run.policy_thresholds->>'freshness_seconds')::integer;
    if v_freshness_seconds<1 or public.mt5_s1_policy_v1(v_run.policy_version) is distinct from v_run.policy_thresholds then
      return pg_catalog.jsonb_build_object('ok',false,'error_code','ERR_POLICY_INVALID');
    end if;
  exception when others then
    return pg_catalog.jsonb_build_object('ok',false,'error_code','ERR_POLICY_INVALID');
  end;
  v_age_seconds:=greatest(0,extract(epoch from clock_timestamp()-v_run.captured_at));
  if v_run.snapshot_health='suspicious' then v_state:='suspicious';
  elsif v_age_seconds>v_freshness_seconds then v_state:='stale';
  else v_state:='fresh'; end if;
  if v_run.snapshot_health='healthy' and v_state='fresh' then
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'position_id',p.position_id,'symbol_raw',p.symbol_raw,'side',p.side,'volume',p.volume,
      'price_open',p.price_open,'price_current',p.price_current,'profit',p.profit,
      'open_time_utc',p.open_time_utc,'source_time_msc',p.source_time_msc,
      'contract_size',p.contract_size,'captured_at',p.captured_at
    ) order by p.position_id),'[]'::jsonb) into v_positions
    from public.mt5_sync_run_positions p
    where p.run_id=v_run.id and p.user_id=v_uid and p.source_account=p_source_account;
  end if;
  return pg_catalog.jsonb_build_object(
    'ok',true,'error_code',null,'freshness_state',v_state,
    'snapshot',pg_catalog.jsonb_build_object(
      'run_id',v_run.id,'source_account',v_run.source_account,'snapshot_status',v_run.snapshot_status,
      'reconcile_status',v_run.reconcile_status,'snapshot_health',v_run.snapshot_health,
      'snapshot_completed_at',v_run.snapshot_completed_at,'positions_count',v_run.positions_count,
      'warning_code',v_run.warning_code,'freshness_state',v_state
    ),'positions',v_positions
  );
end
$fn$;

-- Ownership and ACLs. Internal helpers remain postgres-only.
alter function public.mt5_s1_policy_v1(text) owner to postgres;
alter function public.mt5_sha256_text_v1(text) owner to postgres;
alter function public.mt5_position_fingerprint_v1(bigint,text,text,numeric,numeric,numeric,numeric,timestamptz,bigint,numeric,timestamptz) owner to postgres;
alter function public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text) owner to postgres;
alter function public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer) owner to postgres;
alter function public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb) owner to postgres;
alter function public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[]) owner to postgres;
alter function public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid) owner to postgres;
alter function public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text) owner to postgres;
alter function public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text) owner to postgres;
alter function public.mt5_expire_stale_run_v1(uuid,uuid,text) owner to postgres;
alter function public.mt5_get_current_snapshot_v1(text) owner to postgres;

revoke all on function public.mt5_s1_policy_v1(text) from public,anon,authenticated,service_role;
revoke all on function public.mt5_sha256_text_v1(text) from public,anon,authenticated,service_role;
revoke all on function public.mt5_position_fingerprint_v1(bigint,text,text,numeric,numeric,numeric,numeric,timestamptz,bigint,numeric,timestamptz) from public,anon,authenticated,service_role;
revoke all on function public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text) from public,anon,authenticated,service_role;
revoke all on function public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[]) from public,anon,authenticated,service_role;
revoke all on function public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.mt5_expire_stale_run_v1(uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.mt5_get_current_snapshot_v1(text) from public,anon,authenticated,service_role;

grant execute on function public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text) to service_role;
grant execute on function public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer) to service_role;
grant execute on function public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb) to service_role;
grant execute on function public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[]) to service_role;
grant execute on function public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid) to service_role;
grant execute on function public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text) to service_role;
grant execute on function public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text) to service_role;
grant execute on function public.mt5_expire_stale_run_v1(uuid,uuid,text) to service_role;
grant execute on function public.mt5_get_current_snapshot_v1(text) to authenticated;

do $postflight$
declare
  v_expected text[]:=array[
    'mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamp with time zone,text,integer,text,text)',
    'mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer)',
    'mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)',
    'mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[])',
    'mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid)',
    'mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text)',
    'mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text)',
    'mt5_expire_stale_run_v1(uuid,uuid,text)',
    'mt5_get_current_snapshot_v1(text)'
  ];
  v_sig text;
begin
  foreach v_sig in array v_expected loop
    if to_regprocedure('public.'||v_sig) is null then
      raise exception 'MT5_S1_RPC_POSTFLIGHT: missing exact function %',v_sig;
    end if;
  end loop;
  if exists (
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname=any(array[
       'mt5_create_run_v1','mt5_heartbeat_run_v1','mt5_append_run_positions_v1',
       'mt5_complete_snapshot_v1','mt5_reconcile_snapshot_v1','mt5_mark_snapshot_failed_v1',
       'mt5_mark_reconcile_failed_v1','mt5_expire_stale_run_v1','mt5_get_current_snapshot_v1'])
       and (not p.prosecdef or pg_get_userbyid(p.proowner)<>'postgres'
         or not (coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""']))
  ) then raise exception 'MT5_S1_RPC_POSTFLIGHT: owner/security/search_path mismatch'; end if;
end
$postflight$;

insert into public.mt5_schema_migrations(
  version,description,checksum,source_artifact_sha256,status,objects,applied_at,applied_by
) values (
  'mt5_s1_append_only_rpc_v1','MT5 S1 rewritten connector and browser RPCs',
  '97f4e993f407fc49794e4e230d9a5071a138624e196fe7c2ed233727ccc73cd1',
  '9902B301B3E170A7FD5AA348C9892395CEBEE129DF1B5F63FAB9F62D53CA266D',
  'applied',
  pg_catalog.jsonb_build_object(
    'connector_rpcs',8,'browser_rpcs',1,'internal_helpers',3,'source_revision',3,
    -- exact signatures S1 owns. Rollback drops ONLY signatures listed here, and only after proving
    -- each surviving object still matches the S1 property fingerprint (owner/kind/definer/search_path).
    'functions', array[
      'public.mt5_get_current_snapshot_v1(text)',
      'public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamp with time zone,text,integer,text,text)',
      'public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer)',
      'public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)',
      'public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[])',
      'public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid)',
      'public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text)',
      'public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text)',
      'public.mt5_expire_stale_run_v1(uuid,uuid,text)',
      'public.mt5_s1_policy_v1(text)',
      'public.mt5_position_fingerprint_v1(bigint,text,text,numeric,numeric,numeric,numeric,timestamp with time zone,bigint,numeric,timestamp with time zone)',
      'public.mt5_sha256_text_v1(text)'
    ]),
  now(),current_user
);

commit;
