-- MT5 S1 append-only rollback packet
-- Contract source: S1_append_only_snapshot_membership_design.md revision 3
-- Reverts mt5_s1_append_only_rpc_v1 + mt5_s1_append_only_schema_v1.
-- Status: EXECUTABLE DRAFT — intentionally UNAPPLIED.
--
-- PREREQUISITE (operational, NOT SQL): the MT5 connector/writer must be stopped first — no run may be
--   in-flight. Ordinary reconciliation failure is NOT a reason to roll back the schema.
-- SAFETY: transactional; ledger + checksum guarded; IF EXISTS around every optional object; restores the
--   Phase 0A staging privilege state; original mt5_import_staging rows and `raw` evidence are UNTOUCHED.
-- WARNING: rollback DISCARDS all S1 run/lifecycle provenance created after S1 (mt5_sync_runs,
--   mt5_sync_run_positions, and the staging lifecycle annotations lifecycle_updated_at/missing_since_run_id).

begin;

do $guard$
declare
  v_schema public.mt5_schema_migrations%rowtype;
  v_rpc public.mt5_schema_migrations%rowtype;
begin
  if to_regclass('public.mt5_schema_migrations') is null then
    raise exception 'MT5_S1_ROLLBACK: migration ledger is missing; refusing blind rollback';
  end if;
  select m.* into v_schema from public.mt5_schema_migrations m where m.version='mt5_s1_append_only_schema_v1';
  if not found or v_schema.status<>'applied'
     or v_schema.checksum<>'d72f7c1128226743508c6ea5b9218b7ea5946a13ed2f88de1e8c772550b9c338' then
    raise exception 'MT5_S1_ROLLBACK: schema ledger entry is missing or checksum mismatch (incompatible objects)';
  end if;
  select m.* into v_rpc from public.mt5_schema_migrations m where m.version='mt5_s1_append_only_rpc_v1';
  if found and v_rpc.status='applied'
     and v_rpc.checksum<>'97f4e993f407fc49794e4e230d9a5071a138624e196fe7c2ed233727ccc73cd1' then
    raise exception 'MT5_S1_ROLLBACK: rpc ledger checksum mismatch (incompatible objects)';
  end if;
  -- Only proceed against objects owned by postgres (the ones this packet created).
  if to_regclass('public.mt5_sync_runs') is not null
     and (select pg_get_userbyid(c.relowner) from pg_catalog.pg_class c where c.oid='public.mt5_sync_runs'::regclass)<>'postgres' then
    raise exception 'MT5_S1_ROLLBACK: mt5_sync_runs is not postgres-owned (name collision)';
  end if;
  perform pg_catalog.set_config('mt5.s1_ledger_created_by_s1',
    coalesce((v_schema.objects->>'ledger_created_by_s1'),'false'), true);
end
$guard$;

-- 1) revoke + drop RPCs and internal helpers (exact signatures) -------------------------------
revoke all on function public.mt5_get_current_snapshot_v1(text) from authenticated, service_role;
revoke all on function public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text) from service_role;
revoke all on function public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer) from service_role;
revoke all on function public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb) from service_role;
revoke all on function public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[]) from service_role;
revoke all on function public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid) from service_role;
revoke all on function public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text) from service_role;
revoke all on function public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text) from service_role;
revoke all on function public.mt5_expire_stale_run_v1(uuid,uuid,text) from service_role;

drop function if exists public.mt5_get_current_snapshot_v1(text);
drop function if exists public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text);
drop function if exists public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer);
drop function if exists public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb);
drop function if exists public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[]);
drop function if exists public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid);
drop function if exists public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text);
drop function if exists public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text);
drop function if exists public.mt5_expire_stale_run_v1(uuid,uuid,text);
drop function if exists public.mt5_s1_policy_v1(text);
drop function if exists public.mt5_position_fingerprint_v1(bigint,text,text,numeric,numeric,numeric,numeric,timestamptz,bigint,numeric,timestamptz);
drop function if exists public.mt5_sha256_text_v1(text);

-- 2) drop triggers + policies on the run-position table (before the table) --------------------
drop trigger if exists mt5_run_positions_no_mutate_v1 on public.mt5_sync_run_positions;
drop trigger if exists mt5_run_positions_started_only_v1 on public.mt5_sync_run_positions;
drop policy if exists mt5_srp_service_read_v1 on public.mt5_sync_run_positions;
drop policy if exists mt5_sync_runs_service_read_v1 on public.mt5_sync_runs;

-- 3) restore Phase 0A staging privileges + drop the S1 staging lifecycle dependencies ---------
--    (restore BEFORE dropping columns so the grant target still exists; column grants vanish with columns.)
revoke insert, update on table public.mt5_import_staging from service_role;   -- clears the S1 column-scoped grants
grant insert, update on table public.mt5_import_staging to service_role;       -- Phase 0A broad state restored

alter table public.mt5_import_staging drop constraint if exists mt5_staging_missing_since_scope_fk;
alter table public.mt5_import_staging drop constraint if exists mt5_staging_position_state_s1_chk;
drop index if exists public.mt5_staging_lifecycle_open_idx;
drop index if exists public.mt5_staging_missing_since_idx;
alter table public.mt5_import_staging drop column if exists missing_since_run_id;
alter table public.mt5_import_staging drop column if exists lifecycle_updated_at;

-- 4) drop the run-position table (its indexes drop with it), then its guard function ----------
drop table if exists public.mt5_sync_run_positions;      -- composite FK to mt5_sync_runs drops with it
drop function if exists public.mt5_run_positions_guard_v1();

-- 5) drop the run table (its partial/unique indexes drop with it) -----------------------------
drop table if exists public.mt5_sync_runs;

-- 6) remove ONLY the S1-owned ledger entries; drop the ledger table only if S1 created it -----
delete from public.mt5_schema_migrations where version in ('mt5_s1_append_only_schema_v1','mt5_s1_append_only_rpc_v1');
do $ledger$
begin
  if current_setting('mt5.s1_ledger_created_by_s1')::boolean
     and not exists (select 1 from public.mt5_schema_migrations) then
    drop table public.mt5_schema_migrations;
  end if;
end
$ledger$;

-- 7) postflight: prove S1 objects are gone and staging evidence untouched ----------------------
do $post$
begin
  if to_regclass('public.mt5_sync_runs') is not null
     or to_regclass('public.mt5_sync_run_positions') is not null then
    raise exception 'MT5_S1_ROLLBACK_POST: an S1 run table survived';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='mt5_import_staging'
                and column_name in ('lifecycle_updated_at','missing_since_run_id')) then
    raise exception 'MT5_S1_ROLLBACK_POST: an S1 staging column survived';
  end if;
  if not exists (select 1 from information_schema.role_table_grants
                  where table_name='mt5_import_staging' and grantee='service_role' and privilege_type='UPDATE') then
    raise exception 'MT5_S1_ROLLBACK_POST: Phase 0A staging UPDATE grant was not restored';
  end if;
end
$post$;

commit;
