-- MT5 S1.1 account observation — RPC packet
-- Contract source: S1_1_account_observation_design.md  (FROZEN — CODEX APPROVED, 2026-08-22)
--   frozen source_artifact_sha256 =
--     812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1
-- Ledger version: mt5_s1_1_account_observation_rpc_v1
-- Packet revision: 3   (revisions 1-2 were never applied outside the disposable test database)
--
-- PACKET IDENTITY TOKEN (stored in the ledger `checksum` column)
--   e4b39fafc55d77c4e9796986e3423681764ba240f35502495cb8e3bbeff2b64b
--   = sha256('mt5_s1_1_account_observation_rpc_v1|packet-revision-3')
--   = 370a41bfe7d8d72d9e3e99aa1d38d2f4bd68c06a95cd1d1a056afa28e365c93a
--   Deterministic revision token, NOT a file hash. Destructive authority is objects->'provenance'.
--
-- WHAT THIS PACKET ADDS
--   public.mt5_account_fingerprint_v1(...)   internal helper, postgres-only
--   public.mt5_append_run_account_v1(...)    connector RPC, service_role only
--
-- WHAT IT DELIBERATELY DOES NOT ADD
--   * no UPDATE / PATCH / correct / delete RPC for an account row -- there is no such path, ever
--   * no exposure/gearing RPC (design §17 -- a separate, separately reviewed artifact)
--   * no change to the frozen mt5_get_current_snapshot_v1(text); raw equity/balance/currency are
--     NOT exposed to `authenticated` in S1.1
--
-- FAILURE-REASON BOUNDARY (design §8, §14)
--   Every error code below is an OPERATIONAL error. None of them may ever be written into the
--   immutable row's failure_reason column, whose only v1 value is 'ACCOUNT_READ_FAILED' and whose
--   only meaning is "the second broker account_info() observation itself failed".

begin;

do $s11_rpc_pre$
declare v_pg integer := current_setting('server_version_num')::integer;
begin
  if v_pg < 170000 or v_pg >= 180000 then
    raise exception 'MT5_S1_1_RPC_PREFLIGHT: server_version_num % is outside the validated 17.x band', v_pg;
  end if;
  if not exists (select 1 from public.mt5_schema_migrations
                  where version='mt5_s1_1_account_observation_schema_v1' and status='applied'
                    and checksum='cf9427c58b916c6f2dd528dd5a23fdb14ed8624fc334e4b9aa0080980276f121') then
    raise exception 'MT5_S1_1_RPC_PREFLIGHT: the S1.1 schema packet (revision 3) is not applied';
  end if;
  if to_regclass('public.mt5_sync_run_account') is null then
    raise exception 'MT5_S1_1_RPC_PREFLIGHT: public.mt5_sync_run_account is missing';
  end if;
  if to_regprocedure('public.mt5_sha256_text_v1(text)') is null then
    raise exception 'MT5_S1_1_RPC_PREFLIGHT: frozen helper public.mt5_sha256_text_v1(text) is missing';
  end if;
  if exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public'
                and p.proname in ('mt5_account_fingerprint_v1','mt5_append_run_account_v1')) then
    raise exception 'MT5_S1_1_RPC_PREFLIGHT: an S1.1 RPC name already exists';
  end if;
  if exists (select 1 from public.mt5_schema_migrations
              where version='mt5_s1_1_account_observation_rpc_v1') then
    raise exception 'MT5_S1_1_RPC_PREFLIGHT: ledger already carries mt5_s1_1_account_observation_rpc_v1';
  end if;
end
$s11_rpc_pre$;

-- ------------------------------------------------------------------------------------------------
-- Domain-separated, NULL-safe, deterministic account fingerprint.
--
-- Mirrors the frozen mt5_position_fingerprint_v1 style: a JSON array rendered to text and hashed,
-- where JSON `null` is a collision-free representation of a missing value. Element 0 is a literal
-- domain tag, which the S1 position fingerprint does not carry.
--
-- Covers every immutable stored evidence field EXCEPT created_at (a server clock artefact) and
-- run_id (it is the primary key; including it would defeat the fingerprint's only job, which is to
-- detect a changed fact for the SAME run).
--
-- No trim_scale() -- deliberate, design §10/§22. to_jsonb(numeric) preserves display scale, so
-- 100.0 and 100.00 render differently. That is harmless for exact replay of the same envelope
-- (identical JSON in -> identical numeric scale -> identical fingerprint), which is the only
-- property the fingerprint claims, and it keeps S1.1 consistent with frozen S1 semantics.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_account_fingerprint_v1(
  p_user uuid,
  p_account text,
  p_captured_at timestamptz,
  p_connector_version text,
  p_account_read_at timestamptz,
  p_status text,
  p_equity numeric,
  p_balance numeric,
  p_currency text,
  p_equity_quality text,
  p_balance_quality text,
  p_failure_reason text
) returns text
language sql stable security definer set search_path=''
as $fingerprint$
  select public.mt5_sha256_text_v1(
    pg_catalog.jsonb_build_array(
      pg_catalog.to_jsonb('mt5.s1_1.account/1'::text),
      pg_catalog.to_jsonb(p_user),
      pg_catalog.to_jsonb(p_account),
      pg_catalog.to_jsonb(extract(epoch from p_captured_at)::numeric),
      pg_catalog.to_jsonb(p_connector_version),
      pg_catalog.to_jsonb(extract(epoch from p_account_read_at)::numeric),
      pg_catalog.to_jsonb(p_status),
      pg_catalog.to_jsonb(p_equity),
      pg_catalog.to_jsonb(p_balance),
      pg_catalog.to_jsonb(p_currency),
      pg_catalog.to_jsonb(p_equity_quality),
      pg_catalog.to_jsonb(p_balance_quality),
      pg_catalog.to_jsonb(p_failure_reason)
    )::text
  )
$fingerprint$;

-- ------------------------------------------------------------------------------------------------
-- Connector RPC: append the one account observation for a run that is still 'started'.
--
-- Signature is deliberately parallel to mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb).
--
-- SERVER-DERIVED (design §9): user_id, source_account, captured_at, connector_version and
-- account_fingerprint come from the LOCKED parent run / are computed here. p_facts carries ONLY
-- observation facts. A caller able to supply captured_at could seal an account sample against a
-- different instant than the membership; a caller able to supply the fingerprint could make a
-- conflicting replay look identical.
-- ------------------------------------------------------------------------------------------------
create function public.mt5_append_run_account_v1(
  p_run_id uuid,p_user uuid,p_account text,p_lease_token uuid,p_facts jsonb
) returns table(o_ok boolean,o_inserted integer,o_error_code text)
language plpgsql security definer set search_path=''
as $fn$
declare
  v_run       public.mt5_sync_runs%rowtype;
  v_now       timestamptz;
  v_keys      text[];
  v_read_at   timestamptz;
  v_status    text;
  v_equity    numeric;
  v_balance   numeric;
  v_currency  text;
  v_eq_q      text;
  v_bal_q     text;
  v_reason    text;
  v_fp        text;
  v_existing  text;
  v_expect_keys constant text[] := array[
    'account_observation_status','account_read_at','balance','balance_quality',
    'currency','equity','equity_quality','failure_reason'];   -- sorted
begin
  -- (1) scalar identity arguments -- no payload inspection in this branch.
  if p_run_id is null or p_user is null or p_lease_token is null
     or p_account is null or btrim(p_account)='' then
    return query select false,0,'ERR_BAD_INPUT'; return;
  end if;

  -- (2) payload container shape. STAGED, deliberately not one OR chain: PostgreSQL does not
  --     guarantee left-to-right OR short-circuiting, so jsonb_object_keys() must never share a
  --     boolean expression with the jsonb_typeof() test that makes it safe.
  if p_facts is null then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_KEYS'; return;
  end if;
  if pg_catalog.jsonb_typeof(p_facts) is distinct from 'object' then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_KEYS'; return;
  end if;
  if pg_catalog.octet_length(p_facts::text)>65536 then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_KEYS'; return;
  end if;

  -- (3) EXACT key set. jsonb_to_record silently ignores extra keys and silently yields NULL for
  --     absent or misspelled ones, so a typo would become a NULL equity indistinguishable from a
  --     legitimate 'absent'. Both directions are rejected here, before any extraction.
  select array_agg(k order by k) into v_keys
    from pg_catalog.jsonb_object_keys(p_facts) as k;
  if v_keys is distinct from v_expect_keys then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_KEYS'; return;
  end if;

  -- (4) EXACT JSON types per key, checked before any cast. This is also what makes a raw
  --     non-finite unrepresentable through this RPC: JSON has no NaN/Infinity literal, and the
  --     string "NaN" fails the 'number' test below.
  if pg_catalog.jsonb_typeof(p_facts->'account_read_at') is distinct from 'string'
     or pg_catalog.jsonb_typeof(p_facts->'account_observation_status') is distinct from 'string'
     or pg_catalog.jsonb_typeof(p_facts->'equity_quality') is distinct from 'string'
     or pg_catalog.jsonb_typeof(p_facts->'balance_quality') is distinct from 'string'
     or pg_catalog.jsonb_typeof(p_facts->'equity') not in ('number','null')
     or pg_catalog.jsonb_typeof(p_facts->'balance') not in ('number','null')
     or pg_catalog.jsonb_typeof(p_facts->'currency') not in ('string','null')
     or pg_catalog.jsonb_typeof(p_facts->'failure_reason') not in ('string','null') then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end if;

  -- (5) parent run: lock the scope, then the row, exactly as append_run_positions does.
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
  if v_run.connector_version is null or btrim(v_run.connector_version)='' then
    return query select false,0,'ERR_CONNECTOR_VERSION_INVALID'; return;
  end if;
  -- (5b) S1.1 CONNECTOR NAMESPACE. Enforced HERE, on the locked parent run, because the reviewed
  -- CLI is not the only thing that can hold a service_role key: any foreign client could otherwise
  -- attach account evidence to a run created in the S1-only namespace. Verification V13 (design
  -- section 13) only inspects runs matching this prefix, so such a row would be evidence that NO
  -- invariant ever checks -- and V14 would simultaneously report it as a forbidden backfill.
  -- connector_version is sealed at create_run and immutable, so this can never be "fixed" in place.
  if v_run.connector_version not like 's1.1-oneshot/%' then
    return query select false,0,'ERR_CONNECTOR_NOT_S1_1'; return;
  end if;

  -- (6) extract. Any cast failure is a payload problem, never a server error.
  begin
    v_read_at  := (p_facts->>'account_read_at')::timestamptz;
  exception when others then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end;
  v_status   := p_facts->>'account_observation_status';
  v_equity   := (p_facts->>'equity')::numeric;
  v_balance  := (p_facts->>'balance')::numeric;
  v_currency := p_facts->>'currency';
  v_eq_q     := p_facts->>'equity_quality';
  v_bal_q    := p_facts->>'balance_quality';
  v_reason   := p_facts->>'failure_reason';

  -- (7) value-domain validation. These mirror the table CHECKs so the caller gets a stable code
  --     instead of a raw constraint violation. The CHECKs remain the authority.
  if v_read_at is null
     or v_status not in ('observed','failed')
     or v_eq_q  not in ('usable','invalid','absent')
     or v_bal_q not in ('usable','invalid','absent') then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end if;
  if v_currency is not null and btrim(v_currency)='' then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end if;
  -- defence in depth: a non-finite cannot arrive as JSON, but never assume it
  if v_equity  in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
     or v_balance in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end if;

  -- contemporaneity: fixed 30 s fail-closed bound against the RUN's captured_at
  if v_read_at > v_run.captured_at
     or v_read_at < v_run.captured_at - interval '30 seconds' then
    return query select false,0,'ERR_ACCOUNT_READ_AT_WINDOW'; return;
  end if;

  -- quality <-> value coherence (same total CASE semantics as the table CHECKs)
  if not (case v_eq_q
            when 'usable'  then v_equity is not null and v_equity > 0
            when 'absent'  then v_equity is null
            when 'invalid' then v_equity is null or v_equity <= 0
            else false end) then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end if;
  if not (case v_bal_q
            when 'usable'  then v_balance is not null
            when 'absent'  then v_balance is null
            when 'invalid' then v_balance is null
            else false end) then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end if;

  -- status shape. NOTE the explicit IS NOT NULL on the failed branch: a failed row with a NULL
  -- reason must be rejected, not silently accepted (the three-valued-logic defect, design §14).
  if not (case v_status
            when 'observed' then v_reason is null
            when 'failed'   then v_reason is not null
                                 and v_reason = 'ACCOUNT_READ_FAILED'
                                 and v_equity is null and v_balance is null and v_currency is null
                                 and v_eq_q = 'absent' and v_bal_q = 'absent'
            else false end) then
    return query select false,0,'ERR_ACCOUNT_PAYLOAD_INVALID'; return;
  end if;

  -- (8) fingerprint over SERVER-DERIVED scope + the validated facts.
  v_fp := public.mt5_account_fingerprint_v1(
            v_run.user_id, v_run.source_account, v_run.captured_at, v_run.connector_version,
            v_read_at, v_status, v_equity, v_balance, v_currency, v_eq_q, v_bal_q, v_reason);

  -- (9) exact replay, or refuse. Never an overwrite.
  select a.account_fingerprint into v_existing
    from public.mt5_sync_run_account a where a.run_id=p_run_id;
  if found then
    if v_existing = v_fp then
      return query select true,0,null::text; return;          -- exact idempotent replay
    end if;
    return query select false,0,'ERR_ACCOUNT_CONFLICT'; return;
  end if;

  insert into public.mt5_sync_run_account(
    run_id,user_id,source_account,captured_at,connector_version,
    account_read_at,account_observation_status,equity,balance,currency,
    equity_quality,balance_quality,failure_reason,account_fingerprint)
  values (
    p_run_id,v_run.user_id,v_run.source_account,v_run.captured_at,v_run.connector_version,
    v_read_at,v_status,v_equity,v_balance,v_currency,
    v_eq_q,v_bal_q,v_reason,v_fp);

  return query select true,1,null::text;
end
$fn$;

-- ------------------------------------------------------------------------------------------------
-- Ownership and ACLs. The helper stays postgres-only; the connector RPC is service_role only.
-- `authenticated` receives NOTHING from this packet.
-- ------------------------------------------------------------------------------------------------
alter function public.mt5_account_fingerprint_v1(uuid,text,timestamptz,text,timestamptz,text,numeric,numeric,text,text,text,text) owner to postgres;
alter function public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb) owner to postgres;

revoke all on function public.mt5_account_fingerprint_v1(uuid,text,timestamptz,text,timestamptz,text,numeric,numeric,text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb) from public,anon,authenticated,service_role;

grant execute on function public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb) to service_role;

-- ------------------------------------------------------------------------------------------------
-- Postflight + provenance.
-- ------------------------------------------------------------------------------------------------
do $s11_rpc_post$
declare v jsonb; v_bad text;
begin
  if to_regprocedure('public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)') is null then
    raise exception 'MT5_S1_1_RPC_POSTFLIGHT: the connector RPC was not created';
  end if;
  -- the internal helper must NOT be callable by any application role
  if exists (
    select 1 from pg_catalog.pg_proc p
     where p.oid='public.mt5_account_fingerprint_v1(uuid,text,timestamptz,text,timestamptz,text,numeric,numeric,text,text,text,text)'::regprocedure
       and (has_function_privilege('service_role',p.oid,'EXECUTE')
         or has_function_privilege('authenticated',p.oid,'EXECUTE')
         or has_function_privilege('anon',p.oid,'EXECUTE'))) then
    raise exception 'MT5_S1_1_RPC_POSTFLIGHT: the fingerprint helper is executable by an application role';
  end if;
  -- authenticated/anon must not reach the connector RPC
  if has_function_privilege('authenticated','public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)'::regprocedure,'EXECUTE')
     or has_function_privilege('anon','public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)'::regprocedure,'EXECUTE') then
    raise exception 'MT5_S1_1_RPC_POSTFLIGHT: append_run_account must not be executable by anon/authenticated';
  end if;
  if not has_function_privilege('service_role','public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)'::regprocedure,'EXECUTE') then
    raise exception 'MT5_S1_1_RPC_POSTFLIGHT: service_role cannot execute append_run_account';
  end if;
  -- the frozen browser RPC must still exist, unchanged in its grant shape
  if to_regprocedure('public.mt5_get_current_snapshot_v1(text)') is null then
    raise exception 'MT5_S1_1_RPC_POSTFLIGHT: frozen mt5_get_current_snapshot_v1(text) is missing';
  end if;
  if not has_function_privilege('authenticated','public.mt5_get_current_snapshot_v1(text)'::regprocedure,'EXECUTE') then
    raise exception 'MT5_S1_1_RPC_POSTFLIGHT: frozen browser RPC grant was disturbed';
  end if;

  v := pg_catalog.jsonb_build_object(
    'functions', (
      select pg_catalog.jsonb_object_agg(x.sig,x.fp) from (
        select p.oid::regprocedure::text as sig,
               pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                 pg_catalog.pg_get_functiondef(p.oid)||'|'||
                 pg_catalog.pg_get_userbyid(p.proowner)||'|'||p.prosecdef::text||'|'||
                 coalesce(pg_catalog.array_to_string(p.proconfig,','),'')||'|'||
                 -- ACL, sorted so grant ORDER can never masquerade as a change and a real grant
                 -- change can never hide. NULL proacl (owner-default) is distinct from '{}'.
                 coalesce((select pg_catalog.string_agg(z.acl::text,',' order by z.acl::text)
                             from pg_catalog.unnest(p.proacl) as z(acl)),'<default>')
               ,'UTF8'),'sha256'),'hex') as fp
          from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public'
           and p.proname in ('mt5_account_fingerprint_v1','mt5_append_run_account_v1')
      ) x));
  if (select count(*) from pg_catalog.jsonb_object_keys(v->'functions')) <> 2 then
    raise exception 'MT5_S1_1_PROVENANCE: expected exactly two S1.1 function fingerprints';
  end if;
  perform pg_catalog.set_config('mt5.s11_rpc_provenance', v::text, true);
  raise notice 'MT5_S1_1_RPC_POSTFLIGHT: PASS — connector RPC installed service_role-only, frozen browser RPC untouched';
end
$s11_rpc_post$;

insert into public.mt5_schema_migrations(
  version,description,checksum,source_artifact_sha256,status,objects,applied_at,applied_by
) values (
  'mt5_s1_1_account_observation_rpc_v1',
  'MT5 S1.1 account observation append RPC and fingerprint helper',
  -- packet identity token = sha256('mt5_s1_1_account_observation_rpc_v1|packet-revision-3')
  -- revision 2: ERR_CONNECTOR_NOT_S1_1 namespace gate on the locked parent run, and ACL added to
  -- the apply-time function fingerprint so rollback can prove the grant shape too.
  -- revision 3: NO RPC behaviour change. Mechanical dependency bump only -- this packet VALIDATES
  -- the schema packet's identity token, and that token advanced to revision 3.
  '370a41bfe7d8d72d9e3e99aa1d38d2f4bd68c06a95cd1d1a056afa28e365c93a',
  '812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1',
  'applied',
  pg_catalog.jsonb_build_object(
    'packet_revision', 3,
    'connector_rpcs', 1,
    'browser_rpcs', 0,
    'internal_helpers', 1,
    'modifies_frozen_s1_rpcs', false,
    'rollback_order', 'S1.1 rollback MUST run before S1 rollback',
    'provenance', current_setting('mt5.s11_rpc_provenance')::jsonb
  ),
  now(),current_user
);

commit;
