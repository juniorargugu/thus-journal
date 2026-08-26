-- ================================================================================================
-- OFFLINE-ONLY SYNTHETIC SUBSTRATE — NEVER RUN IN PRODUCTION.
-- T4B OFFLINE BOOTSTRAP: the Journal-app tables the T4B packets preflight and write.
--
-- Run AFTER T4A_offline_bootstrap.sql (which supplies mt5_schema_migrations, mt5_sync_runs,
-- mt5_sync_run_positions and mt5_sha256_text_v1) and AFTER the T2 + T4A packets.
--
-- public.trades and public.products are Journal application tables. No MT5 packet creates them, so
-- a disposable database gets a faithful stand-in here. Shapes are taken from the production
-- read-only audit (2026-08-26): 155 trade rows, 21 columns, id TEXT (a non-numeric filter returns
-- rows, not 22P02), products a single JSON blob per user. Legacy projection columns
-- (current_price, setup, tags, target, invalidation, entry_date, exit_date, note) are NULL in
-- 155/155 production rows; they are declared permissively here because T4B only ever writes NULL
-- to them and their exact production types are not observable through PostgREST.
--
-- INVOCATION (both are required — the marker alone is not enough):
--
--   psql -v ON_ERROR_STOP=1 \
--        -c "SET t4b.offline_fixture = 'I_UNDERSTAND_DISPOSABLE';" \
--        -f T4B_offline_bootstrap.sql
--
-- ...or, in one session, run the SET immediately before the \i. The marker is a session GUC: it
-- cannot be inherited from a config file this packet ships, cannot survive a reconnect, and has to
-- be typed by whoever runs the command.
-- ================================================================================================

-- ------------------------------------------------------------------------------------------------
-- HARD SAFETY GUARD.
--
-- Revision 1 checked only whether public.trades / the promotion ledger already existed, which is
-- no protection at all: a database holding real S1 snapshots, real T2 captures and real T4A
-- decisions — but no Journal tables, exactly the shape of the MT5 pipeline's own database — sailed
-- straight through and got a synthetic Journal grafted onto it.
--
-- Two independent conditions now have to hold.
--   1. An explicit session marker the operator must type.
--   2. NO durable rows anywhere in the pipeline. Every table is probed dynamically, so an absent
--      table is simply skipped rather than masking the check.
-- ------------------------------------------------------------------------------------------------
do $t4b_guard$
declare
  v_marker text;
  v_tbl    text;
  v_n      bigint;
  v_found  text[] := array[]::text[];
begin
  -- 1. the explicit disposable-environment marker
  v_marker := current_setting('t4b.offline_fixture', true);
  if coalesce(v_marker, '') <> 'I_UNDERSTAND_DISPOSABLE' then
    raise exception 'T4B_OFFLINE_BOOTSTRAP: refusing to run. This packet creates a SYNTHETIC '
      'Journal substrate and is for a DISPOSABLE database only. Set the marker explicitly if that '
      'is what you have: SET t4b.offline_fixture = ''I_UNDERSTAND_DISPOSABLE'';';
  end if;

  -- 2. no durable pipeline or Journal data may exist, marker or not
  foreach v_tbl in array array[
      'public.mt5_sync_runs',
      'public.mt5_sync_run_positions',
      'public.mt5_capture_events',
      'public.mt5_capture_decisions',
      'public.mt5_capture_promotions',
      'public.trades',
      'public.products'] loop
    if to_regclass(v_tbl) is not null then
      execute format('select count(*) from %s', v_tbl) into v_n;
      if v_n > 0 then
        v_found := v_found || (v_tbl || '=' || v_n::text);
      end if;
    end if;
  end loop;

  if array_length(v_found, 1) is not null then
    raise exception 'T4B_OFFLINE_BOOTSTRAP: refusing to run — this database already holds durable '
      'rows (%). That is not a disposable fixture database.', array_to_string(v_found, ', ');
  end if;

  -- 3. and our own objects must not already be here
  if to_regclass('public.trades') is not null or to_regclass('public.products') is not null then
    raise exception 'T4B_OFFLINE_BOOTSTRAP: refusing to run — public.trades and/or public.products '
      'already exist. Re-running this substrate would fight whatever created them.';
  end if;
end $t4b_guard$;

create table public.trades (
  id                  text not null,
  user_id             uuid not null,
  product_id          text,
  direction           text,
  status              text,
  contracts           numeric,
  remaining_contracts numeric,
  entry_price         numeric,
  exit_price          numeric,
  entry_date          timestamptz,
  exit_date           timestamptz,
  note                text,
  raw                 jsonb,
  group_id            uuid,
  current_price       numeric,
  setup               text,
  tags                text,
  target              numeric,
  invalidation        numeric,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint trades_pkey primary key (id, user_id),
  constraint trades_id_key unique (id)
);

-- user_id is the PRIMARY KEY here, matching what the Journal app already depends on: db.loadAll
-- reads the catalog with .maybeSingle(), which errors outright on a second row for one user.
create table public.products (
  user_id    uuid primary key,
  data       jsonb,
  updated_at timestamptz
);

-- The Journal app's own writer surface, reproduced so the T4B schema packet's column-level
-- narrowing has something real to narrow and the privilege probes have a role to run as. Without
-- these grants the substrate would be strictly more locked down than production and would hide
-- exactly the defect the narrowing exists to close.
do $t4b_app_grants$
begin
  if to_regrole('authenticated') is not null then
    grant select, insert, update, delete on public.trades   to authenticated;
    grant select, insert, update, delete on public.products to authenticated;
  end if;

  -- A second writer whose privilege shape is deliberately adversarial:
  --
  --   INSERT      table  WITH GRANT OPTION      -- option on the table entry
  --   UPDATE      table  no grant option        -- and...
  --   UPDATE(raw) column WITH GRANT OPTION      -- ...an option only the COLUMN entry carries
  --
  -- The third line is the trap. A table-level REVOKE takes the matching column privileges with
  -- it, so a narrowing that re-grants from the TABLE entry's is_grantable alone hands back plain
  -- UPDATE(raw) and quietly destroys a grant option — narrowing more than the marker. Nothing
  -- else in this substrate would notice.
  if to_regrole('t4b_app_writer') is null then
    create role t4b_app_writer nologin;
  end if;
  grant insert on table public.trades to t4b_app_writer with grant option;
  grant update on table public.trades to t4b_app_writer;
  grant update (raw) on table public.trades to t4b_app_writer with grant option;
end $t4b_app_grants$;
