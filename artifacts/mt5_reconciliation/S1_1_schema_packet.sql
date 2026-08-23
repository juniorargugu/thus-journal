-- MT5 S1.1 account observation — schema packet
-- Contract source: S1_1_account_observation_design.md  (FROZEN — CODEX APPROVED, 2026-08-22)
--   frozen source_artifact_sha256 =
--     812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1
--   (SHA-256 of the LF-normalised bytes; see S1_1_executable_packet_readme.md "Frozen design hash".)
-- Ledger version: mt5_s1_1_account_observation_schema_v1
-- Packet revision: 3   (revisions 1-2 were never applied outside the disposable test database)
--
-- PACKET IDENTITY TOKEN (stored in the ledger `checksum` column)
--   6ea73df2d15874d8b458a4d84c5d7d382fb5f35ab07e4ad670fd3a99282e8600
--   = sha256('mt5_s1_1_account_observation_schema_v1|packet-revision-1')
--   A DETERMINISTIC PACKET REVISION TOKEN, reproducible from that literal string. It is NOT a hash
--   of this file and proves nothing about the deployed objects. Destructive authority is the
--   apply-time catalog fingerprints in objects->'provenance', exactly as in S1 revision 5.
--
-- WHAT THIS PACKET DOES
--   Creates ONE new sibling table, one guard function, two immutability triggers, one RLS policy,
--   and the SELECT-only service_role grant. It ALTERS NOTHING that S1 owns.
--
-- WHY A SIBLING TABLE AND NOT COLUMNS ON mt5_sync_runs
--   The frozen S1 rollback recomputes a structural fingerprint over owner + full column list +
--   constraints + indexes and refuses to drop on any difference. Adding a column to mt5_sync_runs
--   would permanently disarm S1 rollback. See design §1(a) and §2.
--
-- ROLLBACK ORDERING (read this before you ever roll anything back)
--   *** S1.1 ROLLBACK MUST RUN BEFORE S1 ROLLBACK. ***
--   S1_rollback_packet.sql ends with `drop table if exists public.mt5_sync_runs;` and uses NO
--   CASCADE. While this packet's FK exists, that statement fails. S1_rollback_packet.sql is FROZEN
--   and must NOT be edited to work around it.

begin;

-- ------------------------------------------------------------------------------------------------
-- Preflight. Rejects a drifted S1, a name collision, and an incompatible platform. Fail closed.
-- ------------------------------------------------------------------------------------------------
do $s11_ledger_present$
begin
  -- Declared in its OWN block on purpose: the block below declares
  -- public.mt5_schema_migrations%rowtype variables, and PL/pgSQL resolves those at COMPILE time.
  -- If the ledger is absent this block must speak first, or the operator only ever sees a raw
  -- "relation does not exist" from the compiler.
  if to_regclass('public.mt5_schema_migrations') is null then
    raise exception 'MT5_S1_1_PREFLIGHT: migration ledger is missing - frozen S1 is not installed on this database. Apply the frozen S1 packets first';
  end if;
end
$s11_ledger_present$;

do $s11_pre$
declare
  v_pg     integer := current_setting('server_version_num')::integer;
  v_schema public.mt5_schema_migrations%rowtype;
  v_prov   jsonb;
  v_bad    text;
begin
  if v_pg < 170000 or v_pg >= 180000 then
    raise exception 'MT5_S1_1_PREFLIGHT: server_version_num % is outside the validated 17.x band', v_pg;
  end if;
  if to_regprocedure('extensions.digest(bytea,text)') is null then
    raise exception 'MT5_S1_1_PREFLIGHT: extensions.digest(bytea,text) is required';
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname='service_role')
     or not exists (select 1 from pg_catalog.pg_roles where rolname='authenticated')
     or not exists (select 1 from pg_catalog.pg_roles where rolname='anon') then
    raise exception 'MT5_S1_1_PREFLIGHT: required Supabase roles are missing';
  end if;
  select * into v_schema from public.mt5_schema_migrations
   where version='mt5_s1_append_only_schema_v1' and status='applied';
  if not found then
    raise exception 'MT5_S1_1_PREFLIGHT: applied S1 schema ledger row is missing';
  end if;
  if v_schema.checksum is distinct from '7cd1e9783853798e31f907cf567cfdfb0b90071427fa4132d56eb177a948139b' then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 schema packet identity token is not the expected revision-5 value';
  end if;
  if not exists (select 1 from public.mt5_schema_migrations
                  where version='mt5_s1_append_only_rpc_v1' and status='applied'
                    and checksum='65a21a632f3826f661de6ce516cf804272a26ccea35275bde99b3b225953c835') then
    raise exception 'MT5_S1_1_PREFLIGHT: applied S1 revision-5 RPC ledger row is missing';
  end if;

  if to_regclass('public.mt5_sync_runs') is null
     or to_regclass('public.mt5_sync_run_positions') is null then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 run tables are missing';
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint
                  where conrelid='public.mt5_sync_runs'::regclass
                    and conname='mt5_sync_runs_id_scope_uniq' and contype='u') then
    raise exception 'MT5_S1_1_PREFLIGHT: mt5_sync_runs_id_scope_uniq is missing; the composite FK cannot be created';
  end if;

  -- Rollback-arming proof BEFORE we add the dependency (design §19).
  v_prov := v_schema.objects->'provenance';
  if v_prov is null or pg_catalog.jsonb_typeof(v_prov) is distinct from 'object'
     or (v_prov ? 'tables') is not true then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 schema ledger carries no apply-time table provenance';
  end if;
  select pg_catalog.string_agg(x.rel, ', ' order by x.rel) into v_bad
    from (values ('mt5_sync_runs'),('mt5_sync_run_positions')) x(rel)
   where (v_prov->'tables'->>x.rel) is distinct from (
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
    raise exception 'MT5_S1_1_PREFLIGHT: S1 table(s) % already differ from the apply-time S1 definition; S1 rollback is disarmed — refusing to install S1.1 on drift', v_bad;
  end if;
  perform pg_catalog.set_config('mt5.s11_s1_tables_prov', (v_prov->'tables')::text, true);

  -- Name collisions this packet cannot claim.
  if to_regclass('public.mt5_sync_run_account') is not null then
    raise exception 'MT5_S1_1_PREFLIGHT: public.mt5_sync_run_account already exists';
  end if;
  if to_regprocedure('public.mt5_run_account_guard_v1()') is not null then
    raise exception 'MT5_S1_1_PREFLIGHT: public.mt5_run_account_guard_v1() already exists';
  end if;
  if exists (select 1 from public.mt5_schema_migrations
              where version='mt5_s1_1_account_observation_schema_v1') then
    raise exception 'MT5_S1_1_PREFLIGHT: ledger already carries mt5_s1_1_account_observation_schema_v1';
  end if;
end
$s11_pre$;

-- ------------------------------------------------------------------------------------------------
-- The account observation table. One immutable row per run. Nothing S1 owns is touched.
-- ------------------------------------------------------------------------------------------------
create table public.mt5_sync_run_account (
  -- identity and scope: ALL server-derived by the RPC from the locked parent run (design §9)
  run_id                     uuid        not null,
  user_id                    uuid        not null,
  source_account             text        not null,
  captured_at                timestamptz not null,
  connector_version          text        not null,

  -- the observation
  account_read_at            timestamptz not null,
  account_observation_status text        not null,
  equity                     numeric,
  balance                    numeric,
  currency                   text,
  equity_quality             text        not null,
  balance_quality            text        not null,
  failure_reason             text,

  account_fingerprint        text        not null,
  created_at                 timestamptz not null default now(),

  ------------------------------------------------------------------- identity / scope ----------
  constraint mt5_sra_pk primary key (run_id),
  constraint mt5_sra_run_scope_fk foreign key (run_id,user_id,source_account)
    references public.mt5_sync_runs(id,user_id,source_account) on delete restrict,
  constraint mt5_sra_account_nonblank_chk   check (btrim(source_account) <> ''),
  constraint mt5_sra_connector_nonblank_chk check (btrim(connector_version) <> ''),

  ------------------------------------------------------------------- contemporaneity -----------
  -- 30 s is a FIXED fail-closed bound and is deliberately not configurable in S1.1 v1 (design §5).
  constraint mt5_sra_read_at_window_chk check (
    account_read_at <= captured_at
    and account_read_at >= captured_at - interval '30 seconds'),

  ------------------------------------------------------------------- enumerations --------------
  constraint mt5_sra_status_chk          check (account_observation_status in ('observed','failed')),
  constraint mt5_sra_equity_quality_chk  check (equity_quality  in ('usable','invalid','absent')),
  constraint mt5_sra_balance_quality_chk check (balance_quality in ('usable','invalid','absent')),
  constraint mt5_sra_currency_nonblank_chk check (currency is null or btrim(currency) <> ''),

  ------------------------------------------------------- finite numerics: defence in depth -----
  -- The connector normalises a non-finite broker value to NULL + quality 'invalid' BEFORE it ever
  -- reaches the database (design §7). These constraints exist to reject a payload that FALSELY
  -- carries a non-finite numeric. numeric NaN compares equal to itself in PostgreSQL (unlike
  -- float), which is what makes NOT IN correct here. The `is null or` prefix is deliberate.
  constraint mt5_sra_equity_finite_chk check (
    equity is null
    or equity not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)),
  constraint mt5_sra_balance_finite_chk check (
    balance is null
    or balance not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)),

  ------------------------------------------------------- quality <-> value, DB-enforced --------
  -- 'usable' is a promise the DATABASE keeps, so a connector bug cannot store a lie.
  -- CASE over a NOT NULL discriminator with ELSE false => TOTAL, never NULL. The 'usable' branch
  -- leads with IS NOT NULL, so the later comparisons can never be reached with a NULL operand.
  constraint mt5_sra_equity_quality_shape_chk check (
    case equity_quality
      when 'usable'  then equity is not null
                          and equity not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
                          and equity > 0
      when 'absent'  then equity is null
      when 'invalid' then equity is null or equity <= 0
      else false
    end),
  constraint mt5_sra_balance_quality_shape_chk check (
    case balance_quality
      when 'usable'  then balance is not null
                          and balance not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
      when 'absent'  then balance is null
      when 'invalid' then balance is null
      else false
    end),

  --------------------------------------------- status shape: TOTAL and NULL-proof (HIGH fix) ---
  -- A CHECK passes when its expression is TRUE *or NULL*; only explicit FALSE rejects. The earlier
  -- directional form
  --     account_observation_status <> 'failed' OR (... AND failure_reason = 'ACCOUNT_READ_FAILED')
  -- evaluated to NULL for a failed row whose failure_reason was NULL, and therefore ACCEPTED it.
  -- The CASE below tests IS NOT NULL first; FALSE AND anything is FALSE, so that row is rejected.
  constraint mt5_sra_status_shape_chk check (
    case account_observation_status
      when 'observed' then
        failure_reason is null
      when 'failed' then
        failure_reason is not null
        and failure_reason = 'ACCOUNT_READ_FAILED'
        and equity is null and balance is null and currency is null
        and equity_quality = 'absent' and balance_quality = 'absent'
      else false
    end),

  -- Documents the permitted vocabulary. It CANNOT substitute for the IS NOT NULL requirement
  -- above: `failure_reason is null or ...` passes for a NULL reason by design.
  constraint mt5_sra_failure_reason_allowlist_chk check (
    failure_reason is null or failure_reason = 'ACCOUNT_READ_FAILED'),

  ------------------------------------------------------------------- fingerprint ---------------
  constraint mt5_sra_fingerprint_chk check (account_fingerprint ~ '^[0-9a-f]{64}$')
);

alter table public.mt5_sync_run_account owner to postgres;

comment on table public.mt5_sync_run_account is
  'MT5 S1.1: immutable one-to-one account observation for an S1 run. Historical contemporaneous evidence; never corrected, never backfilled. equity is the exposure denominator; balance is context only.';

create index mt5_sra_scope_idx
  on public.mt5_sync_run_account(user_id,source_account,captured_at desc);

-- ------------------------------------------------------------------------------------------------
-- Immutability guard. Mirrors the proven mt5_run_positions_guard_v1().
-- ------------------------------------------------------------------------------------------------
create function public.mt5_run_account_guard_v1() returns trigger
language plpgsql security definer set search_path = ''
as $guard$
declare
  v_status  text;
  v_capture timestamptz;
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'MT5_S1_1_IMMUTABLE_ROW' using errcode='P0001';
  end if;
  select r.snapshot_status, r.captured_at
    into v_status, v_capture
    from public.mt5_sync_runs r
   where r.id = new.run_id
   for share;
  if not found or v_status is distinct from 'started' then
    raise exception 'MT5_S1_1_RUN_NOT_STARTED' using errcode='P0001';
  end if;
  if new.captured_at is distinct from v_capture then
    raise exception 'MT5_S1_1_CAPTURE_CONFLICT' using errcode='P0001';
  end if;
  return new;
end
$guard$;
alter function public.mt5_run_account_guard_v1() owner to postgres;
revoke all on function public.mt5_run_account_guard_v1() from public,anon,authenticated,service_role;

create trigger mt5_run_account_no_mutate_v1
  before update or delete on public.mt5_sync_run_account
  for each row execute function public.mt5_run_account_guard_v1();
create trigger mt5_run_account_started_only_v1
  before insert on public.mt5_sync_run_account
  for each row execute function public.mt5_run_account_guard_v1();

-- ------------------------------------------------------------------------------------------------
-- RLS and ACLs. authenticated gets NOTHING; service_role gets SELECT only. Writes are RPC-only.
-- ------------------------------------------------------------------------------------------------
alter table public.mt5_sync_run_account enable row level security;

create policy mt5_sra_service_read_v1 on public.mt5_sync_run_account
  for select to service_role using (true);

revoke all on table public.mt5_sync_run_account from public,anon,authenticated,service_role;
grant select on table public.mt5_sync_run_account to service_role;

-- ------------------------------------------------------------------------------------------------
-- Postflight. Proves (a) our own object shape, (b) no application write grant, and (c) that the
-- frozen S1 tables are byte-for-byte structurally unchanged, i.e. S1 rollback is STILL armed.
-- ------------------------------------------------------------------------------------------------
do $s11_post$
declare
  v_bad   text;
  v_count integer;
begin
  if (select pg_catalog.pg_get_userbyid(relowner) from pg_catalog.pg_class
       where oid='public.mt5_sync_run_account'::regclass) <> 'postgres' then
    raise exception 'MT5_S1_1_POSTFLIGHT: incorrect table owner';
  end if;
  if not (select relrowsecurity from pg_catalog.pg_class
           where oid='public.mt5_sync_run_account'::regclass) then
    raise exception 'MT5_S1_1_POSTFLIGHT: row level security is not enabled';
  end if;

  -- (b) no INSERT/UPDATE/DELETE for any application role. The frozen S1 postflight is scoped by
  --     table name and does NOT cover this table, which is why S1.1 carries its own (design §19).
  select count(*) into v_count
    from information_schema.table_privileges p
   where p.table_schema='public' and p.table_name='mt5_sync_run_account'
     and p.grantee in ('anon','authenticated','service_role')
     and p.privilege_type in ('INSERT','UPDATE','DELETE');
  if v_count <> 0 then
    raise exception 'MT5_S1_1_POSTFLIGHT: application write grant exists on the immutable account table';
  end if;
  if exists (select 1 from information_schema.table_privileges p
              where p.table_schema='public' and p.table_name='mt5_sync_run_account'
                and p.grantee in ('anon','authenticated')) then
    raise exception 'MT5_S1_1_POSTFLIGHT: anon/authenticated must have no privilege on the account table';
  end if;
  if exists (select 1 from pg_catalog.pg_attribute a
              where a.attrelid='public.mt5_sync_run_account'::regclass
                and a.attnum>0 and not a.attisdropped and a.attacl is not null) then
    raise exception 'MT5_S1_1_POSTFLIGHT: unexpected column-level ACL on the account table';
  end if;

  -- both immutability triggers present and enabled
  if (select count(*) from pg_catalog.pg_trigger t
       where t.tgrelid='public.mt5_sync_run_account'::regclass
         and not t.tgisinternal and t.tgenabled='O') <> 2 then
    raise exception 'MT5_S1_1_POSTFLIGHT: expected exactly two enabled immutability triggers';
  end if;

  -- (c) ROLLBACK ARMING PROOF: S1 tables unchanged by this apply.
  select pg_catalog.string_agg(x.rel, ', ' order by x.rel) into v_bad
    from (values ('mt5_sync_runs'),('mt5_sync_run_positions')) x(rel)
   where (current_setting('mt5.s11_s1_tables_prov')::jsonb->>x.rel) is distinct from (
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
    raise exception 'MT5_S1_1_POSTFLIGHT: S1 table(s) % changed during S1.1 apply — S1 rollback would be disarmed', v_bad;
  end if;

  raise notice 'MT5_S1_1_POSTFLIGHT: PASS — account table installed, no app write grant, frozen S1 fingerprints unchanged';
end
$s11_post$;

-- ------------------------------------------------------------------------------------------------
-- Apply-time provenance for THIS packet's objects. This is rollback's destructive authority.
-- ------------------------------------------------------------------------------------------------
do $s11_prov$
declare v jsonb;
begin
  v := pg_catalog.jsonb_build_object(
    'tables', (
      select pg_catalog.jsonb_object_agg(x.rel,x.fp) from (
        select 'mt5_sync_run_account' as rel,
               pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
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
               ,'UTF8'),'sha256'),'hex') as fp
          from pg_catalog.pg_class c where c.oid='public.mt5_sync_run_account'::regclass
      ) x),
    'functions', (
      select pg_catalog.jsonb_object_agg(x.sig,x.fp) from (
        select 'public.mt5_run_account_guard_v1()' as sig,
               pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                 pg_catalog.pg_get_functiondef(p.oid)||'|'||
                 pg_catalog.pg_get_userbyid(p.proowner)||'|'||p.prosecdef::text||'|'||
                 coalesce(pg_catalog.array_to_string(p.proconfig,','),'')||'|'||
                 coalesce((select pg_catalog.string_agg(z.acl::text,',' order by z.acl::text)
                             from pg_catalog.unnest(p.proacl) as z(acl)),'<default>')
               ,'UTF8'),'sha256'),'hex') as fp
          from pg_catalog.pg_proc p
         where p.oid='public.mt5_run_account_guard_v1()'::regprocedure
      ) x),
    'triggers', (
      select pg_catalog.jsonb_object_agg(x.tgname,x.fp) from (
        select t.tgname,
               pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                 pg_catalog.pg_get_triggerdef(t.oid)||'|'||t.tgenabled::text
               ,'UTF8'),'sha256'),'hex') as fp
          from pg_catalog.pg_trigger t
         where t.tgrelid='public.mt5_sync_run_account'::regclass and not t.tgisinternal
      ) x),
    'policies', (
      select pg_catalog.jsonb_object_agg(x.polname,x.fp) from (
        select pol.polname,
               pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                 coalesce(pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),'')||'|'||
                 pol.polcmd::text||'|'||pol.polpermissive::text||'|'||
                 coalesce(pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid),'')||'|'||
                 -- ROLES matter most of all: `to service_role` vs `to authenticated` is the whole
                 -- security contract, and role order is not meaningful, so it is sorted.
                 coalesce((select pg_catalog.string_agg(
                             case when z.r=0 then 'public'
                                  else pg_catalog.pg_get_userbyid(z.r) end, ',' order by
                             case when z.r=0 then 'public'
                                  else pg_catalog.pg_get_userbyid(z.r) end)
                           from pg_catalog.unnest(pol.polroles) as z(r)),'')
               ,'UTF8'),'sha256'),'hex') as fp
          from pg_catalog.pg_policy pol
         where pol.polrelid='public.mt5_sync_run_account'::regclass
      ) x),
    -- Owner + ACL + RLS state. Deliberately its OWN fingerprint class rather than folded into
    -- 'tables': grants and row security are the security contract, they change through commands
    -- that leave the column/constraint/index shape untouched, and rollback must be able to name
    -- WHICH dimension drifted. A rollback that erased a table whose grants had been widened to
    -- `authenticated` would be destroying a materially different object under its old name.
    'security', (
      select pg_catalog.jsonb_object_agg(x.rel,x.fp) from (
        select 'mt5_sync_run_account' as rel,
               pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                 pg_catalog.pg_get_userbyid(c.relowner)||'|'||
                 c.relrowsecurity::text||'|'||c.relforcerowsecurity::text||'|'||
                 coalesce((select pg_catalog.string_agg(z.acl::text,',' order by z.acl::text)
                             from pg_catalog.unnest(c.relacl) as z(acl)),'<default>')
               ,'UTF8'),'sha256'),'hex') as fp
          from pg_catalog.pg_class c where c.oid='public.mt5_sync_run_account'::regclass
      ) x),
    -- COLUMN-LEVEL ACL. Its OWN class, not folded into 'security', because
    -- `GRANT SELECT (equity) ... TO authenticated` writes pg_attribute.attacl and leaves
    -- pg_class.relacl COMPLETELY UNCHANGED -- so the 'security' fingerprint above reproduces
    -- byte-identically while the table's real security contract has changed. Without this class
    -- rollback would establish false authority and destroy a table it no longer owns the shape of.
    --
    -- Stored as the readable normalised text (15 short entries) AND its fingerprint: the text lets
    -- rollback name WHICH column drifted, the fingerprint makes the comparison total and cheap.
    'column_acl', pg_catalog.jsonb_build_object(
      'normalised', (select pg_catalog.string_agg(
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
            and c2.attnum>0 and not c2.attisdropped),
      'fingerprint', (
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
               ,'UTF8'),'sha256'),'hex'))
    ),
    -- the S1 fingerprints this apply PROVED unchanged; rollback re-proves them before it drops
    's1_tables_at_apply', current_setting('mt5.s11_s1_tables_prov')::jsonb
  );
  -- Every class rollback will later demand MUST be present now. Provenance recorded incompletely
  -- is worse than none: rollback would silently skip whichever class was missing.
  if (v->'tables'->>'mt5_sync_run_account') is null
     or (v->'security'->>'mt5_sync_run_account') is null
     or (v->'column_acl'->>'fingerprint') is null
     or (v->'column_acl'->>'normalised') is null
     or (v->'functions'->>'public.mt5_run_account_guard_v1()') is null
     or (select count(*) from pg_catalog.jsonb_object_keys(v->'triggers')) <> 2
     or (select count(*) from pg_catalog.jsonb_object_keys(v->'policies')) <> 1 then
    raise exception 'MT5_S1_1_PROVENANCE: incomplete apply-time object provenance';
  end if;

  -- Every live user column must be REPRESENTED, and the apply-time contract is that every one of
  -- them has attacl IS NULL. A representation that silently omitted a column would be a hole of
  -- exactly the kind this class exists to close.
  if (select count(*) from pg_catalog.pg_attribute a
       where a.attrelid='public.mt5_sync_run_account'::regclass
         and a.attnum>0 and not a.attisdropped)
     <> (select pg_catalog.array_length(
                  pg_catalog.string_to_array(v->'column_acl'->>'normalised','|'),1)) then
    raise exception 'MT5_S1_1_PROVENANCE: recorded column-ACL provenance does not cover every live user column';
  end if;
  if (v->'column_acl'->>'normalised') like '%:ACL[%' then
    raise exception 'MT5_S1_1_PROVENANCE: a column-level ACL exists at apply time; the apply-time contract is attacl IS NULL on every column';
  end if;
  -- ...and the recorded value must REPRODUCE with the same algorithm, or rollback's later
  -- recomputation could never match and every legitimate teardown would be refused.
  if (v->'column_acl'->>'fingerprint') is distinct from (
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
    raise exception 'MT5_S1_1_PROVENANCE: the recorded column-ACL fingerprint does not reproduce';
  end if;
  perform pg_catalog.set_config('mt5.s11_provenance', v::text, true);
end
$s11_prov$;

insert into public.mt5_schema_migrations(
  version,description,checksum,source_artifact_sha256,status,objects,applied_at,applied_by
) values (
  'mt5_s1_1_account_observation_schema_v1',
  'MT5 S1.1 immutable one-to-one account observation table for an S1 run',
  -- packet identity token = sha256('mt5_s1_1_account_observation_schema_v1|packet-revision-3')
  -- revision 2: apply-time provenance extended to owner/ACL/RLS state, policy roles + WITH CHECK,
  -- and guard-function ACL.
  -- revision 3: apply-time provenance extended to the COLUMN-level ACL state (pg_attribute.attacl).
  -- A column grant leaves pg_class.relacl unchanged, so revision 2's 'security' fingerprint could
  -- not see it and rollback could establish false authority.
  'cf9427c58b916c6f2dd528dd5a23fdb14ed8624fc334e4b9aa0080980276f121',
  -- SHA-256 of the FROZEN design document's LF-normalised bytes (a real, externally verifiable
  -- file hash). The ledger CHECK requires upper-case hex.
  '812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1',
  'applied',
  pg_catalog.jsonb_build_object(
    'packet_revision', 3,
    'depends_on', array['mt5_s1_append_only_schema_v1','mt5_s1_append_only_rpc_v1'],
    'tables', array['mt5_sync_run_account'],
    'alters_s1_tables', false,
    'rollback_order', 'S1.1 rollback MUST run before S1 rollback',
    'provenance', current_setting('mt5.s11_provenance')::jsonb
  ),
  now(),current_user
);

commit;
