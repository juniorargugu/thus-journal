-- ================================================================================================
-- T4A OFFLINE BOOTSTRAP — disposable-database substrate ONLY. NEVER run in production.
-- VERBATIM extractions from the committed S1 packets (S1_schema_packet.sql lines 236-250,
-- 270-345, 362-393; S1_rpc_packet.sql lines 70-74): the migrations ledger, mt5_sync_runs,
-- mt5_sync_run_positions and mt5_sha256_text_v1 — the exact objects the T2 packets preflight.
-- The S1 packets themselves preflight Phase-0A production state that has no offline meaning,
-- so a disposable database gets the prerequisite DDL directly instead.
-- Prereqs (cluster): roles anon/authenticated/service_role; schema extensions + pgcrypto.
-- ================================================================================================
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
create function public.mt5_sha256_text_v1(p_value text) returns text
language sql immutable security definer set search_path=''
as $sha$
  select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_value,'UTF8'),'sha256'),'hex')
$sha$;
