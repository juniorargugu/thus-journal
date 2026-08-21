-- MT5 S1 append-only rollback packet
-- Contract source: S1_append_only_snapshot_membership_design.md revision 3
-- Reverts mt5_s1_append_only_rpc_v1 + mt5_s1_append_only_schema_v1.
-- Status: EXECUTABLE DRAFT — intentionally UNAPPLIED.
--
-- PREREQUISITE (operational, NOT SQL): the MT5 connector/writer must be stopped first — no run may be
--   in-flight. Ordinary reconciliation failure is NOT a reason to roll back the schema.
--
-- GOVERNING RULE
--   ROLLBACK MAY REMOVE ONLY AN OBJECT IT CAN PROVE IS STILL THE OBJECT S1 OWNS.
--   Every destructive statement below is preceded by provenance verification. If any same-named
--   object has been replaced or materially changed after S1, this packet STOPS and destroys nothing.
--   Absence of an S1 object is a valid partial-install state and is skipped safely.
--
-- PRIVILEGE RULE
--   ROLLBACK NEVER INVENTS A PRIVILEGE THAT DID NOT EXIST BEFORE S1.
--   The exact pre-S1 service_role table privileges were captured by the schema packet into the
--   ledger. An EMPTY captured set restores to EMPTY. There is no default/fallback grant.
--
-- SAFETY: transactional; ledger + checksum guarded; original mt5_import_staging rows and `raw`
--   evidence are UNTOUCHED.
-- WARNING: rollback DISCARDS all S1 run/lifecycle provenance created after S1 (mt5_sync_runs,
--   mt5_sync_run_positions, and the staging lifecycle annotations lifecycle_updated_at/missing_since_run_id).
-- NOTE: public.mt5_s1_test_pre_evidence (created only by the TEST-ONLY preflight packet on a
--   disposable database) is NOT an S1 migration object and is deliberately left untouched.

begin;

-- 0) Ledger identity, checksum compatibility, and privilege/function provenance staging ---------
do $guard$
declare
  v_schema public.mt5_schema_migrations%rowtype;
  v_rpc public.mt5_schema_migrations%rowtype;
  v_pre_grants text;
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

  -- EXACT privilege provenance is mandatory. Its absence means we cannot restore the pre-S1 state,
  -- and guessing is forbidden — so we stop rather than broaden privileges.
  if (v_schema.objects ? 'staging_pre_service_grants') is not true then
    raise exception 'MT5_S1_ROLLBACK: ledger has no staging_pre_service_grants provenance; refusing to guess pre-S1 privileges';
  end if;
  v_pre_grants := coalesce(v_schema.objects->>'staging_pre_service_grants','');
  -- an EMPTY string is a legitimate captured state ("service_role had nothing") and MUST restore to nothing
  if v_pre_grants <> '' and exists (
    select 1 from pg_catalog.regexp_split_to_table(v_pre_grants,',') as g(p)
     where btrim(g.p) not in ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')
  ) then
    raise exception 'MT5_S1_ROLLBACK: unsupported privilege token in captured provenance (%)', v_pre_grants;
  end if;
  perform pg_catalog.set_config('mt5.s1_staging_pre_grants', v_pre_grants, true);
  perform pg_catalog.set_config('mt5.s1_ledger_created_by_s1',
    coalesce((v_schema.objects->>'ledger_created_by_s1'),'false'), true);
  -- function inventory recorded by the RPC packet (absent when the RPC packet never ran)
  perform pg_catalog.set_config('mt5.s1_rpc_functions',
    coalesce((v_rpc.objects->'functions')::text,'[]'), true);
end
$guard$;

-- 0b) PROVENANCE VERIFICATION — prove EVERY surviving S1 object is still S1's, before any DROP ---
--     Any same-named object that has been replaced or materially altered aborts the whole rollback.
do $provenance$
declare v_bad text;
begin
  -- ---- tables -------------------------------------------------------------------------------
  select pg_catalog.string_agg(x.rel, ', ' order by x.rel) into v_bad
    from (values ('public.mt5_sync_runs'),('public.mt5_sync_run_positions')) x(rel)
   where to_regclass(x.rel) is not null
     and not exists (
       select 1 from pg_catalog.pg_class c
        where c.oid = to_regclass(x.rel)
          and c.relkind = 'r'
          and pg_catalog.pg_get_userbyid(c.relowner) = 'postgres'
     );
  if v_bad is not null then
    raise exception 'MT5_S1_ROLLBACK: refusing to drop replaced/foreign table(s): %', v_bad;
  end if;

  -- ---- functions ----------------------------------------------------------------------------
  -- Every S1 function (RPCs, helpers, and the trigger guard) shares one property fingerprint:
  -- postgres-owned, prokind='f', SECURITY DEFINER, proconfig pinning search_path="". A surviving
  -- object at an S1 signature that does not match all four is treated as a foreign replacement.
  select pg_catalog.string_agg(x.sig, ', ' order by x.sig) into v_bad
    from (values
      ('public.mt5_get_current_snapshot_v1(text)'),
      ('public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text)'),
      ('public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer)'),
      ('public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)'),
      ('public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[])'),
      ('public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid)'),
      ('public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text)'),
      ('public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text)'),
      ('public.mt5_expire_stale_run_v1(uuid,uuid,text)'),
      ('public.mt5_s1_policy_v1(text)'),
      ('public.mt5_position_fingerprint_v1(bigint,text,text,numeric,numeric,numeric,numeric,timestamptz,bigint,numeric,timestamptz)'),
      ('public.mt5_sha256_text_v1(text)'),
      ('public.mt5_run_positions_guard_v1()')
    ) x(sig)
   where to_regprocedure(x.sig) is not null
     and not exists (
       select 1 from pg_catalog.pg_proc p
        where p.oid = to_regprocedure(x.sig)
          and pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
          and p.prokind = 'f'
          and p.prosecdef
          and (coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""'])
     );
  if v_bad is not null then
    raise exception 'MT5_S1_ROLLBACK: refusing to drop replaced/foreign function(s): %', v_bad;
  end if;

  -- the guard function must additionally still be a trigger function
  if to_regprocedure('public.mt5_run_positions_guard_v1()') is not null
     and (select p.prorettype from pg_catalog.pg_proc p
           where p.oid='public.mt5_run_positions_guard_v1()'::regprocedure) <> 'pg_catalog.trigger'::regtype then
    raise exception 'MT5_S1_ROLLBACK: mt5_run_positions_guard_v1() is no longer a trigger function (replaced)';
  end if;

  -- cross-check against ledger-recorded provenance when the RPC packet ran: every function the
  -- ledger claims S1 created must either be absent (partial install) or match the fingerprint above.
  if pg_catalog.jsonb_array_length(current_setting('mt5.s1_rpc_functions')::jsonb) > 0 then
    select pg_catalog.string_agg(f.sig, ', ' order by f.sig) into v_bad
      from pg_catalog.jsonb_array_elements_text(current_setting('mt5.s1_rpc_functions')::jsonb) as f(sig)
     where to_regprocedure(f.sig) is not null
       and not exists (
         select 1 from pg_catalog.pg_proc p
          where p.oid = to_regprocedure(f.sig)
            and pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
            and p.prosecdef
            and (coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""'])
       );
    if v_bad is not null then
      raise exception 'MT5_S1_ROLLBACK: ledger-recorded function(s) no longer match S1 provenance: %', v_bad;
    end if;
  end if;

  -- ---- triggers and policies (relation-scoped; parent may legitimately be absent) -------------
  if to_regclass('public.mt5_sync_run_positions') is not null then
    select pg_catalog.string_agg(x.tg, ', ' order by x.tg) into v_bad
      from (values ('mt5_run_positions_no_mutate_v1'),('mt5_run_positions_started_only_v1')) x(tg)
     where exists (
       select 1 from pg_catalog.pg_trigger t
        where t.tgrelid='public.mt5_sync_run_positions'::regclass and t.tgname=x.tg and not t.tgisinternal
     )
     and not exists (
       select 1 from pg_catalog.pg_trigger t
        where t.tgrelid='public.mt5_sync_run_positions'::regclass and t.tgname=x.tg and not t.tgisinternal
          and t.tgfoid = to_regprocedure('public.mt5_run_positions_guard_v1()')
     );
    if v_bad is not null then
      raise exception 'MT5_S1_ROLLBACK: trigger(s) % no longer point at the S1 guard function (replaced)', v_bad;
    end if;
  end if;
end
$provenance$;

-- 1) drop RPCs and internal helpers (exact signatures, provenance proven above) -----------------
--    No explicit REVOKE: DROP FUNCTION IF EXISTS removes each function AND all its ACLs, and is a
--    no-op when the RPC packet was never (fully) applied — so rollback is safe for a partial install.
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

-- 2) drop triggers + policies — RELATION-GUARDED ------------------------------------------------
--    `DROP TRIGGER IF EXISTS x ON t` / `DROP POLICY IF EXISTS p ON t` still ERROR when `t` itself
--    does not exist, so a partial install (RPC packet applied, tables absent) would abort here.
--    Guarding on the parent relation makes both a valid, skippable partial-install state.
do $rel_scoped$
begin
  if to_regclass('public.mt5_sync_run_positions') is not null then
    drop trigger if exists mt5_run_positions_no_mutate_v1 on public.mt5_sync_run_positions;
    drop trigger if exists mt5_run_positions_started_only_v1 on public.mt5_sync_run_positions;
    drop policy  if exists mt5_srp_service_read_v1 on public.mt5_sync_run_positions;
  end if;
  if to_regclass('public.mt5_sync_runs') is not null then
    drop policy if exists mt5_sync_runs_service_read_v1 on public.mt5_sync_runs;
  end if;
end
$rel_scoped$;

-- 3) restore the EXACT pre-S1 staging privileges + drop the S1 staging lifecycle dependencies ----
--    Clear ALL S1-era service_role staging privileges (table- and column-scoped), then restore ONLY
--    the privileges captured before S1. Restore BEFORE dropping columns so the grant target still
--    exists; any residual column grants vanish with the columns.
--    An EMPTY captured set restores NOTHING. There is deliberately no fallback grant.
do $restore$
declare
  v_pre text := coalesce(current_setting('mt5.s1_staging_pre_grants', true), '');
begin
  if to_regclass('public.mt5_import_staging') is null then
    raise exception 'MT5_S1_ROLLBACK: public.mt5_import_staging is missing; cannot restore Phase 0A privileges';
  end if;
  revoke select, insert, update, delete, truncate, references, trigger
    on table public.mt5_import_staging from service_role;
  if v_pre like '%SELECT%'     then grant select     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%INSERT%'     then grant insert     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%UPDATE%'     then grant update     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%DELETE%'     then grant delete     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%TRUNCATE%'   then grant truncate   on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%REFERENCES%' then grant references on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%TRIGGER%'    then grant trigger    on table public.mt5_import_staging to service_role; end if;
end
$restore$;

alter table public.mt5_import_staging drop constraint if exists mt5_staging_missing_since_scope_fk;
alter table public.mt5_import_staging drop constraint if exists mt5_staging_position_state_s1_chk;
drop index if exists public.mt5_staging_lifecycle_open_idx;
drop index if exists public.mt5_staging_missing_since_idx;
alter table public.mt5_import_staging drop column if exists missing_since_run_id;
alter table public.mt5_import_staging drop column if exists lifecycle_updated_at;

-- 4) drop the run-position table (its indexes drop with it), then its guard function ------------
drop table if exists public.mt5_sync_run_positions;      -- composite FK to mt5_sync_runs drops with it
drop function if exists public.mt5_run_positions_guard_v1();

-- 5) drop the run table (its partial/unique indexes drop with it) -------------------------------
drop table if exists public.mt5_sync_runs;

-- 6) remove ONLY the S1-owned ledger entries; drop the ledger table only if S1 created it -------
delete from public.mt5_schema_migrations where version in ('mt5_s1_append_only_schema_v1','mt5_s1_append_only_rpc_v1');
do $ledger$
begin
  if current_setting('mt5.s1_ledger_created_by_s1')::boolean
     and not exists (select 1 from public.mt5_schema_migrations) then
    drop table public.mt5_schema_migrations;
  end if;
end
$ledger$;

-- 7) postflight: prove S1 objects are gone and privileges match the captured pre-S1 state --------
do $post$
declare
  v_pre text := coalesce(current_setting('mt5.s1_staging_pre_grants', true), '');
  v_now text;
  v_left text;
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
  -- every S1 function must be gone
  select pg_catalog.string_agg(x.sig, ', ' order by x.sig) into v_left
    from (values
      ('public.mt5_get_current_snapshot_v1(text)'),
      ('public.mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text)'),
      ('public.mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer)'),
      ('public.mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)'),
      ('public.mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[])'),
      ('public.mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid)'),
      ('public.mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text)'),
      ('public.mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text)'),
      ('public.mt5_expire_stale_run_v1(uuid,uuid,text)'),
      ('public.mt5_s1_policy_v1(text)'),
      ('public.mt5_position_fingerprint_v1(bigint,text,text,numeric,numeric,numeric,numeric,timestamptz,bigint,numeric,timestamptz)'),
      ('public.mt5_sha256_text_v1(text)'),
      ('public.mt5_run_positions_guard_v1()')
    ) x(sig)
   where to_regprocedure(x.sig) is not null;
  if v_left is not null then
    raise exception 'MT5_S1_ROLLBACK_POST: S1 function(s) survived: %', v_left;
  end if;
  -- privileges must equal EXACTLY what was captured before S1 (empty restores to empty)
  select coalesce(pg_catalog.string_agg(distinct p.privilege_type,',' order by p.privilege_type),'')
    into v_now
    from information_schema.role_table_grants p
   where p.table_schema='public' and p.table_name='mt5_import_staging' and p.grantee='service_role';
  if v_now is distinct from v_pre then
    raise exception 'MT5_S1_ROLLBACK_POST: staging privileges (%) do not match the captured pre-S1 state (%)', v_now, v_pre;
  end if;
  -- S1 must not have left any explicit column-level ACL behind
  if exists (select 1 from pg_catalog.pg_attribute a
              where a.attrelid='public.mt5_import_staging'::regclass
                and a.attnum>0 and not a.attisdropped and a.attacl is not null) then
    raise exception 'MT5_S1_ROLLBACK_POST: an S1 column-level ACL survived on mt5_import_staging';
  end if;
end
$post$;

commit;
