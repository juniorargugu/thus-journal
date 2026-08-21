-- MT5 S1 append-only snapshot schema packet
-- Contract source: S1_append_only_snapshot_membership_design.md revision 3
-- Status: executable draft, intentionally UNAPPLIED.
-- Ledger version: mt5_s1_append_only_schema_v1
-- Contract checksum: d72f7c1128226743508c6ea5b9218b7ea5946a13ed2f88de1e8c772550b9c338

begin;

-- Required platform dependencies and Phase 0A shape. These checks reject partial/name-colliding objects.
do $preflight$
declare
  v_bad text;
  v_ledger_existed boolean := to_regclass('public.mt5_schema_migrations') is not null;
  v_staging_count bigint;
  v_staging_checksum text;
  v_staging_pre_grants text;
  v_staging_pre_relacl text;
begin
  perform pg_catalog.set_config('mt5.s1_ledger_preexisting', v_ledger_existed::text, true);

  if to_regprocedure('extensions.digest(bytea,text)') is null then
    raise exception 'MT5_S1_PREFLIGHT: extensions.digest(bytea,text) is required';
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role')
     or not exists (select 1 from pg_catalog.pg_roles where rolname = 'authenticated')
     or not exists (select 1 from pg_catalog.pg_roles where rolname = 'anon') then
    raise exception 'MT5_S1_PREFLIGHT: required Supabase roles are missing';
  end if;
  if to_regclass('public.mt5_import_staging') is null then
    raise exception 'MT5_S1_PREFLIGHT: Phase 0A public.mt5_import_staging is missing';
  end if;
  select count(*),pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
           coalesce(pg_catalog.string_agg(pg_catalog.to_jsonb(s)::text,'' order by s.id),''),'UTF8'),'sha256'),'hex')
    into v_staging_count,v_staging_checksum
    from public.mt5_import_staging s;
  perform pg_catalog.set_config('mt5.s1_staging_count',v_staging_count::text,true);
  perform pg_catalog.set_config('mt5.s1_staging_checksum',v_staging_checksum,true);
  -- ---------------------------------------------------------------------------------------
  -- EXACT pre-S1 privilege provenance for public.mt5_import_staging / service_role.
  -- S1 mutates ONLY service_role's privileges on this one table, so that is the only ACL state
  -- whose exact restoration rollback must guarantee. Two states cannot be faithfully reproduced
  -- by a plain GRANT list, so they are rejected BEFORE any mutation (fail-closed) rather than
  -- being silently approximated:
  --   (a) WITH GRANT OPTION held by service_role
  --   (b) pre-existing explicit COLUMN-level ACLs (S1 installs its own column grants; afterwards a
  --       pre-existing column ACL would be indistinguishable from S1's own)
  -- ---------------------------------------------------------------------------------------
  if exists (
    select 1 from information_schema.role_table_grants p
     where p.table_schema='public' and p.table_name='mt5_import_staging'
       and p.grantee='service_role' and p.is_grantable='YES'
  ) then
    raise exception 'MT5_S1_PREFLIGHT: service_role holds WITH GRANT OPTION on mt5_import_staging; exact rollback restoration is unsupported — refusing to mutate';
  end if;
  if exists (
    select 1 from pg_catalog.pg_attribute a
     where a.attrelid = 'public.mt5_import_staging'::regclass
       and a.attnum > 0 and not a.attisdropped and a.attacl is not null
  ) then
    raise exception 'MT5_S1_PREFLIGHT: mt5_import_staging already carries explicit column-level ACLs; exact rollback restoration is unsupported — refusing to mutate';
  end if;
  -- Exact table-level privilege set (may legitimately be the EMPTY string; rollback must then
  -- restore NOTHING — an empty capture is a real state, never a licence to grant something).
  select coalesce(pg_catalog.string_agg(distinct p.privilege_type,',' order by p.privilege_type),'')
    into v_staging_pre_grants
    from information_schema.role_table_grants p
   where p.table_schema='public' and p.table_name='mt5_import_staging' and p.grantee='service_role';
  perform pg_catalog.set_config('mt5.s1_staging_pre_grants',v_staging_pre_grants,true);
  -- Full raw relacl, recorded for audit/forensics alongside the restorable privilege list.
  select coalesce(pg_catalog.array_to_string(c.relacl,'|'),'')
    into v_staging_pre_relacl
    from pg_catalog.pg_class c where c.oid = 'public.mt5_import_staging'::regclass;
  perform pg_catalog.set_config('mt5.s1_staging_pre_relacl',v_staging_pre_relacl,true);

  select pg_catalog.string_agg(x.expected, ', ' order by x.expected)
    into v_bad
    from (values
      ('id:uuid:NO'), ('user_id:uuid:NO'), ('source_account:text:NO'),
      ('kind:text:NO'), ('position_id:bigint:YES'), ('position_state:text:YES')
    ) x(expected)
   where not exists (
     select 1
       from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name = 'mt5_import_staging'
        and c.column_name = split_part(x.expected, ':', 1)
        and c.data_type = split_part(x.expected, ':', 2)
        and c.is_nullable = split_part(x.expected, ':', 3)
   );
  if v_bad is not null then
    raise exception 'MT5_S1_PREFLIGHT: incompatible staging columns: %', v_bad;
  end if;

  if not exists (
    select 1
      from pg_catalog.pg_index i
      join pg_catalog.pg_class t on t.oid = i.indrelid
      join pg_catalog.pg_namespace n on n.oid = t.relnamespace
     where n.nspname = 'public' and t.relname = 'mt5_import_staging'
       and i.indisunique
       and pg_get_indexdef(i.indexrelid) like '%(user_id, source_account, position_id)%'
       and pg_get_expr(i.indpred, i.indrelid) = '((kind = ''open''::text) AND (position_id IS NOT NULL))'
  ) then
    raise exception 'MT5_S1_PREFLIGHT: exact Phase 0A open-position uniqueness is missing';
  end if;

  if exists (
    select 1 from information_schema.columns c
     where c.table_schema='public' and c.table_name='mt5_import_staging'
       and c.column_name in ('lifecycle_updated_at','missing_since_run_id','last_seen_run_id')
  ) then
    raise exception 'MT5_S1_PREFLIGHT: staging contains an incompatible S1 lifecycle/membership column';
  end if;
  if to_regclass('public.mt5_sync_runs') is not null
     or to_regclass('public.mt5_sync_run_positions') is not null then
    raise exception 'MT5_S1_PREFLIGHT: incompatible pre-existing S1 run object';
  end if;

  if v_ledger_existed then
    if exists (
      select 1
        from (values
          ('version','text','NO'), ('description','text','NO'), ('checksum','text','NO'),
          ('source_artifact_sha256','text','NO'), ('status','text','NO'), ('objects','jsonb','NO'),
          ('applied_at','timestamp with time zone','YES'), ('applied_by','text','NO')
        ) x(column_name,data_type,is_nullable)
       where not exists (
         select 1 from information_schema.columns c
          where c.table_schema='public' and c.table_name='mt5_schema_migrations'
            and c.column_name=x.column_name and c.data_type=x.data_type and c.is_nullable=x.is_nullable
       )
    ) then
      raise exception 'MT5_S1_PREFLIGHT: incompatible mt5_schema_migrations definition';
    end if;
    -- reject an unexpected/extra-column ledger shape (exact column set = the 8 expected columns)
    if (select count(*) from information_schema.columns
         where table_schema='public' and table_name='mt5_schema_migrations') <> 8 then
      raise exception 'MT5_S1_PREFLIGHT: mt5_schema_migrations has an unexpected column set';
    end if;
    -- A pre-existing ledger is REUSED ONLY IF it is already exactly the definition S1 relies on.
    -- S1 must never re-own, re-privilege, or "repair" a foreign object into its own shape, so every
    -- remaining property is validated here and any difference STOPS the migration before mutation.
    -- Because these are validated as already-correct, the static owner/REVOKE/GRANT statements that
    -- follow this preflight are no-ops for a pre-existing ledger.
    if (select pg_get_userbyid(c.relowner) from pg_catalog.pg_class c
         where c.oid='public.mt5_schema_migrations'::regclass) <> 'postgres' then
      raise exception 'MT5_S1_PREFLIGHT: pre-existing mt5_schema_migrations is not postgres-owned — refusing to take ownership';
    end if;
    -- exact default expressions S1 depends on
    if (select pg_catalog.pg_get_expr(d.adbin,d.adrelid) from pg_catalog.pg_attrdef d
         join pg_catalog.pg_attribute a on a.attrelid=d.adrelid and a.attnum=d.adnum
        where d.adrelid='public.mt5_schema_migrations'::regclass and a.attname='objects')
       is distinct from '''{}''::jsonb' then
      raise exception 'MT5_S1_PREFLIGHT: pre-existing ledger objects default differs';
    end if;
    if (select pg_catalog.pg_get_expr(d.adbin,d.adrelid) from pg_catalog.pg_attrdef d
         join pg_catalog.pg_attribute a on a.attrelid=d.adrelid and a.attnum=d.adnum
        where d.adrelid='public.mt5_schema_migrations'::regclass and a.attname='applied_by')
       is distinct from 'CURRENT_USER' then
      raise exception 'MT5_S1_PREFLIGHT: pre-existing ledger applied_by default differs';
    end if;
    -- primary key on (version)
    if not exists (
      select 1 from pg_catalog.pg_constraint k
       where k.conrelid='public.mt5_schema_migrations'::regclass and k.contype='p'
         and pg_catalog.pg_get_constraintdef(k.oid)='PRIMARY KEY (version)'
    ) then
      raise exception 'MT5_S1_PREFLIGHT: pre-existing ledger primary key differs';
    end if;
    -- every CHECK constraint S1 relies on, by name and by definition
    if exists (
      select 1 from (values
        ('mt5_schema_migrations_version_nonblank_chk','CHECK ((btrim(version) <> ''''::text))'),
        ('mt5_schema_migrations_checksum_chk','CHECK ((checksum ~ ''^[0-9a-f]{64}$''::text))'),
        ('mt5_schema_migrations_source_checksum_chk','CHECK ((source_artifact_sha256 ~ ''^[0-9A-F]{64}$''::text))'),
        ('mt5_schema_migrations_status_chk','CHECK ((status = ANY (ARRAY[''applied''::text, ''rolled_back''::text])))'),
        ('mt5_schema_migrations_applied_at_chk','CHECK (((status = ''applied''::text) = (applied_at IS NOT NULL)))')
      ) x(cname,cdef)
      where not exists (
        select 1 from pg_catalog.pg_constraint k
         where k.conrelid='public.mt5_schema_migrations'::regclass
           and k.contype='c' and k.conname=x.cname
           and pg_catalog.pg_get_constraintdef(k.oid)=x.cdef
      )
    ) then
      raise exception 'MT5_S1_PREFLIGHT: pre-existing ledger CHECK constraints differ from the S1 definition';
    end if;
    -- no extra constraints beyond the PK + the 5 S1 CHECKs (a foreign FK/UNIQUE would change semantics)
    if (select count(*) from pg_catalog.pg_constraint k
         where k.conrelid='public.mt5_schema_migrations'::regclass and k.contype in ('c','p','u','f')) <> 6 then
      raise exception 'MT5_S1_PREFLIGHT: pre-existing ledger carries unexpected constraints';
    end if;
    -- privilege state must ALREADY equal S1's target (service_role SELECT only; nothing for anon/authenticated/public)
    if exists (
      select 1 from information_schema.role_table_grants p
       where p.table_schema='public' and p.table_name='mt5_schema_migrations'
         and (p.grantee in ('anon','authenticated','PUBLIC')
              or (p.grantee='service_role' and p.privilege_type<>'SELECT'))
    ) then
      raise exception 'MT5_S1_PREFLIGHT: pre-existing ledger privileges differ from the S1 definition — refusing to re-privilege';
    end if;
  end if;
end
$preflight$;

-- The preflight validates an existing ledger before this idempotent creation statement is reached.
create table if not exists public.mt5_schema_migrations (
  version                text primary key,
  description            text not null,
  checksum               text not null,
  source_artifact_sha256 text not null,
  status                 text not null,
  objects                jsonb not null default '{}'::jsonb,
  applied_at             timestamptz,
  applied_by             text not null default current_user,
  constraint mt5_schema_migrations_version_nonblank_chk check (btrim(version) <> ''),
  constraint mt5_schema_migrations_checksum_chk check (checksum ~ '^[0-9a-f]{64}$'),
  constraint mt5_schema_migrations_source_checksum_chk check (source_artifact_sha256 ~ '^[0-9A-F]{64}$'),
  constraint mt5_schema_migrations_status_chk check (status in ('applied','rolled_back')),
  constraint mt5_schema_migrations_applied_at_chk check ((status='applied') = (applied_at is not null))
);
-- These three statements establish the ledger's owner/ACL when S1 CREATED it. When the ledger
-- pre-existed, the preflight above has already proven it is postgres-owned with exactly the
-- service_role-SELECT-only privilege set, so these statements are no-ops and S1 never re-owns or
-- re-privileges a foreign object (it stops instead).
alter table public.mt5_schema_migrations owner to postgres;
revoke all on table public.mt5_schema_migrations from public, anon, authenticated, service_role;
grant select on table public.mt5_schema_migrations to service_role;

do $ledger_guard$
begin
  if exists (
    select 1 from public.mt5_schema_migrations m
     where m.version in ('mt5_s1_append_only_schema_v1','mt5_s1_append_only_rpc_v1')
  ) then
    raise exception 'MT5_S1_PREFLIGHT: an S1 schema/RPC ledger version already exists';
  end if;
end
$ledger_guard$;

create table public.mt5_sync_runs (
  id                       uuid primary key,
  user_id                  uuid not null,
  source_account           text not null,
  captured_at              timestamptz not null,
  snapshot_status          text not null default 'started',
  reconcile_status         text not null default 'pending',
  snapshot_health          text,
  run_seq                  bigint,
  previous_positions_count integer,
  positions_count          integer,
  position_ids_hash        text,
  manifest_hash            text,
  policy_version           text not null,
  policy_thresholds        jsonb not null,
  warning_code             text,
  error_code               text,
  connector_version        text not null,
  terminal_build           integer,
  terminal_server          text,
  lease_token              uuid not null,
  lease_expires_at         timestamptz not null,
  heartbeat_at             timestamptz not null,
  snapshot_completed_at    timestamptz,
  snapshot_failed_at       timestamptz,
  reconciled_at            timestamptz,
  reconcile_failed_at      timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint mt5_sync_runs_id_scope_uniq unique (id,user_id,source_account),
  constraint mt5_sync_runs_account_nonblank_chk check (btrim(source_account) <> ''),
  constraint mt5_sync_runs_connector_nonblank_chk check (btrim(connector_version) <> ''),
  constraint mt5_sync_runs_policy_nonblank_chk check (btrim(policy_version) <> ''),
  constraint mt5_sync_runs_snapshot_status_chk check (snapshot_status in ('started','complete','failed')),
  constraint mt5_sync_runs_reconcile_status_chk check (reconcile_status in ('pending','complete','failed')),
  constraint mt5_sync_runs_health_chk check (snapshot_health is null or snapshot_health in ('healthy','suspicious')),
  constraint mt5_sync_runs_seq_chk check (run_seq is null or run_seq >= 1),
  constraint mt5_sync_runs_counts_chk check (
    (previous_positions_count is null or previous_positions_count >= 0)
    and (positions_count is null or positions_count >= 0)
  ),
  constraint mt5_sync_runs_hashes_chk check (
    (position_ids_hash is null or position_ids_hash ~ '^[0-9a-f]{64}$')
    and (manifest_hash is null or manifest_hash ~ '^[0-9a-f]{64}$')
  ),
  constraint mt5_sync_runs_policy_shape_chk check (
    jsonb_typeof(policy_thresholds)='object'
    and policy_thresholds ?& array['k','susp_min_base','susp_drop_ratio','freshness_seconds']
  ),
  constraint mt5_sync_runs_complete_shape_chk check (
    (snapshot_status='complete') =
    (snapshot_completed_at is not null and snapshot_health is not null and run_seq is not null
      and previous_positions_count is not null and positions_count is not null
      and position_ids_hash is not null and manifest_hash is not null)
  ),
  constraint mt5_sync_runs_failed_shape_chk check (
    (snapshot_status='failed') = (snapshot_failed_at is not null)
  ),
  constraint mt5_sync_runs_reconcile_shape_chk check (
    (reconcile_status='complete') = (reconciled_at is not null)
    and (reconcile_status='failed') = (reconcile_failed_at is not null)
    and (reconcile_status not in ('complete','failed') or snapshot_status='complete')
  ),
  constraint mt5_sync_runs_warning_health_chk check (
    (snapshot_health='suspicious') = (warning_code is not null)
  ),
  constraint mt5_sync_runs_error_shape_chk check (
    (snapshot_status='failed' or reconcile_status='failed') = (error_code is not null)
  ),
  constraint mt5_sync_runs_active_lease_chk check (
    not (snapshot_status='started' or (snapshot_status='complete' and reconcile_status='pending'))
    or (lease_token is not null and lease_expires_at is not null and heartbeat_at is not null)
  )
);
alter table public.mt5_sync_runs owner to postgres;

create unique index mt5_sync_runs_seq_uniq
  on public.mt5_sync_runs(user_id,source_account,run_seq)
  where run_seq is not null;
create unique index mt5_sync_runs_one_active_uniq
  on public.mt5_sync_runs(user_id,source_account)
  where snapshot_status='started' or (snapshot_status='complete' and reconcile_status='pending');
create index mt5_sync_runs_latest_complete_idx
  on public.mt5_sync_runs(user_id,source_account,run_seq desc)
  include (id,captured_at,snapshot_completed_at,snapshot_health,reconcile_status,positions_count,warning_code)
  where snapshot_status='complete';
create index mt5_sync_runs_healthy_history_idx
  on public.mt5_sync_runs(user_id,source_account,run_seq desc)
  include (id,captured_at,positions_count)
  where snapshot_status='complete' and snapshot_health='healthy';

create table public.mt5_sync_run_positions (
  run_id          uuid not null,
  user_id         uuid not null,
  source_account  text not null,
  position_id     bigint not null,
  symbol_raw      text not null,
  side            text not null,
  volume          numeric not null,
  price_open      numeric,
  price_current   numeric,
  profit          numeric,
  open_time_utc   timestamptz,
  source_time_msc bigint,
  contract_size   numeric,
  captured_at     timestamptz not null,
  row_fingerprint text not null,
  created_at      timestamptz not null default now(),

  constraint mt5_srp_pk primary key (run_id,position_id),
  constraint mt5_srp_run_scope_fk foreign key (run_id,user_id,source_account)
    references public.mt5_sync_runs(id,user_id,source_account) on delete restrict,
  constraint mt5_srp_account_nonblank_chk check (btrim(source_account) <> ''),
  constraint mt5_srp_symbol_nonblank_chk check (btrim(symbol_raw) <> ''),
  constraint mt5_srp_side_chk check (side in ('buy','sell')),
  constraint mt5_srp_volume_chk check (volume > 0 and volume <> 'NaN'::numeric),
  constraint mt5_srp_price_open_chk check (price_open is null or price_open <> 'NaN'::numeric),
  constraint mt5_srp_price_current_chk check (price_current is null or price_current <> 'NaN'::numeric),
  constraint mt5_srp_profit_chk check (profit is null or profit <> 'NaN'::numeric),
  constraint mt5_srp_contract_size_chk check (contract_size is null or contract_size <> 'NaN'::numeric),
  constraint mt5_srp_fingerprint_chk check (row_fingerprint ~ '^[0-9a-f]{64}$')
);
alter table public.mt5_sync_run_positions owner to postgres;
create index mt5_srp_scope_position_run_idx
  on public.mt5_sync_run_positions(user_id,source_account,position_id,run_id);

create function public.mt5_run_positions_guard_v1() returns trigger
language plpgsql security definer set search_path = ''
as $guard$
declare
  v_status text;
  v_capture timestamptz;
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'MT5_S1_IMMUTABLE_ROW' using errcode='P0001';
  end if;
  select r.snapshot_status, r.captured_at
    into v_status, v_capture
    from public.mt5_sync_runs r
   where r.id=new.run_id
   for share;
  if not found or v_status is distinct from 'started' then
    raise exception 'MT5_S1_RUN_NOT_STARTED' using errcode='P0001';
  end if;
  if new.captured_at is distinct from v_capture then
    raise exception 'MT5_S1_CAPTURE_CONFLICT' using errcode='P0001';
  end if;
  return new;
end
$guard$;
alter function public.mt5_run_positions_guard_v1() owner to postgres;
revoke all on function public.mt5_run_positions_guard_v1() from public,anon,authenticated,service_role;

create trigger mt5_run_positions_no_mutate_v1
before update or delete on public.mt5_sync_run_positions
for each row execute function public.mt5_run_positions_guard_v1();
create trigger mt5_run_positions_started_only_v1
before insert on public.mt5_sync_run_positions
for each row execute function public.mt5_run_positions_guard_v1();

alter table public.mt5_import_staging
  add column lifecycle_updated_at timestamptz,
  add column missing_since_run_id uuid;
alter table public.mt5_import_staging
  add constraint mt5_staging_missing_since_scope_fk
  foreign key (missing_since_run_id,user_id,source_account)
  references public.mt5_sync_runs(id,user_id,source_account) on delete restrict;
alter table public.mt5_import_staging
  add constraint mt5_staging_position_state_s1_chk
  check (position_state is null or position_state in (
    'seen_open','open','still_open','missing_once','not_open_confirmed','unknown',
    'partial','closed_confirmed','closed','gone'
  )) not valid;
create index mt5_staging_lifecycle_open_idx
  on public.mt5_import_staging(user_id,source_account,position_state,position_id)
  where kind='open' and position_id is not null;
create index mt5_staging_missing_since_idx
  on public.mt5_import_staging(missing_since_run_id)
  where missing_since_run_id is not null;

-- Narrow the Phase 0A ingestion credential to its inspected implementation surface.
revoke insert,update on table public.mt5_import_staging from service_role;
grant insert (
  user_id,source_account,kind,symbol_raw,normalized_symbol,instrument_path,instrument_class,
  contract_size,digits,product_id_candidate,side,volume,price,open_time,close_time,mt5_time,
  mt5_time_msc,mt5_time_raw_epoch,server_tz,position_id,deal_id,order_id,ticket,external_id,
  commission,swap,fee,broker_profit,position_state,first_seen_open_at,last_seen_open_at,state,
  import_group_key,confirmed_group_id,materialized_trade_id,materialized_at,dismissed_at,
  error_message,screenshot_url,raw
) on public.mt5_import_staging to service_role;
grant update (
  last_seen_open_at,price,volume,mt5_time,mt5_time_msc,mt5_time_raw_epoch
) on public.mt5_import_staging to service_role;

alter table public.mt5_sync_runs enable row level security;
alter table public.mt5_sync_run_positions enable row level security;
create policy mt5_sync_runs_service_read_v1 on public.mt5_sync_runs
  for select to service_role using (true);
create policy mt5_srp_service_read_v1 on public.mt5_sync_run_positions
  for select to service_role using (true);

revoke all on table public.mt5_sync_runs from public,anon,authenticated,service_role;
revoke all on table public.mt5_sync_run_positions from public,anon,authenticated,service_role;
grant select on table public.mt5_sync_runs to service_role;
grant select on table public.mt5_sync_run_positions to service_role;

-- Exact postflight: object ownership, key constraints, grants, and lifecycle denial.
do $postflight$
declare
  v_count integer;
  v_staging_count bigint;
  v_staging_checksum text;
begin
  if (select pg_get_userbyid(c.relowner) from pg_catalog.pg_class c
       where c.oid='public.mt5_sync_runs'::regclass) <> 'postgres'
     or (select pg_get_userbyid(c.relowner) from pg_catalog.pg_class c
       where c.oid='public.mt5_sync_run_positions'::regclass) <> 'postgres' then
    raise exception 'MT5_S1_POSTFLIGHT: incorrect table owner';
  end if;
  select count(*) into v_count
    from information_schema.table_privileges p
   where p.table_schema='public' and p.table_name in ('mt5_sync_runs','mt5_sync_run_positions')
     and p.grantee in ('anon','authenticated','service_role')
     and p.privilege_type in ('INSERT','UPDATE','DELETE');
  if v_count <> 0 then
    raise exception 'MT5_S1_POSTFLIGHT: application write grant exists on immutable run tables';
  end if;
  select count(*) into v_count
    from information_schema.column_privileges p
   where p.table_schema='public' and p.table_name='mt5_import_staging'
     and p.grantee='service_role'
     and p.column_name in ('position_state','lifecycle_updated_at','missing_since_run_id')
     and p.privilege_type='UPDATE';
  if v_count <> 0 then
    raise exception 'MT5_S1_POSTFLIGHT: service_role retains lifecycle UPDATE';
  end if;
  select count(*),pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
           coalesce(pg_catalog.string_agg((pg_catalog.to_jsonb(s)-'lifecycle_updated_at'-'missing_since_run_id')::text,
             '' order by s.id),''),'UTF8'),'sha256'),'hex')
    into v_staging_count,v_staging_checksum
    from public.mt5_import_staging s;
  if v_staging_count<>current_setting('mt5.s1_staging_count')::bigint
     or v_staging_checksum<>current_setting('mt5.s1_staging_checksum') then
    raise exception 'MT5_S1_POSTFLIGHT: staging evidence changed during schema migration';
  end if;
end
$postflight$;

insert into public.mt5_schema_migrations(
  version,description,checksum,source_artifact_sha256,status,objects,applied_at,applied_by
) values (
  'mt5_s1_append_only_schema_v1',
  'MT5 S1 append-only snapshot schema and Phase 0A lifecycle privilege narrowing',
  'd72f7c1128226743508c6ea5b9218b7ea5946a13ed2f88de1e8c772550b9c338',
  '9902B301B3E170A7FD5AA348C9892395CEBEE129DF1B5F63FAB9F62D53CA266D',
  'applied',
  pg_catalog.jsonb_build_object(
    'ledger_created_by_s1', not current_setting('mt5.s1_ledger_preexisting')::boolean,
    'tables', array['mt5_sync_runs','mt5_sync_run_positions'],
    'staging_columns', array['lifecycle_updated_at','missing_since_run_id'],
    'staging_pre_count', current_setting('mt5.s1_staging_count')::bigint,
    'staging_pre_checksum', current_setting('mt5.s1_staging_checksum'),
    -- exact restorable table-level privilege list for service_role (may be the EMPTY string,
    -- which rollback MUST restore as "no privileges" rather than substituting a default)
    'staging_pre_service_grants', current_setting('mt5.s1_staging_pre_grants'),
    -- full raw pre-S1 relacl, audit/forensics only (never used to synthesize a GRANT)
    'staging_pre_relacl', current_setting('mt5.s1_staging_pre_relacl'),
    'source_revision', 3
  ),
  now(),current_user
);

commit;
