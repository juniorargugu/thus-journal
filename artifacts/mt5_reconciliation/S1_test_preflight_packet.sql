-- MT5 S1 — TEST-ONLY pre-migration evidence capture
-- Contract source: S1_append_only_snapshot_membership_design.md revision 3
-- Status: EXECUTABLE DRAFT — NOT RUN.
--
-- PURPOSE
--   Records an INDEPENDENT observation of the pre-migration `mt5_import_staging` evidence
--   (row count + non-lifecycle content checksum) BEFORE S1_schema_packet.sql runs, so that
--   verification fixture 25 can prove the ledger-captured provenance equals a reference that
--   was physically observed *before* the migration — rather than recomputing both values from
--   the same post-migration state (which would prove nothing).
--
-- EXECUTION ORDER (disposable database only):
--   1. THIS FILE                      <- must run FIRST
--   2. S1_schema_packet.sql
--   3. S1_rpc_packet.sql
--   4. S1_verification_packet.sql     (fixture 25 consumes this file's output)
--   5. S1_rollback_packet.sql         (optional; see README rollback matrix)
--
-- SCOPE / SAFETY
--   * TEST-ONLY. This file MUST NOT be run against production. It creates one test table and
--     seeds synthetic staging rows purely so the fixture-25 comparison is non-vacuous.
--   * It is NOT part of the S1 migration, is NOT recorded in the migration ledger, and the S1
--     rollback packet deliberately does NOT drop it (it is not an S1-owned object).
--   * Drop the disposable database afterwards; that is the intended cleanup.

begin;

-- Guard: this must run BEFORE the schema packet, on a Phase 0A database.
do $pre$
begin
  if to_regclass('public.mt5_import_staging') is null then
    raise exception 'MT5_S1_TEST_PREFLIGHT: Phase 0A public.mt5_import_staging is missing';
  end if;
  if exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='mt5_import_staging'
       and column_name in ('lifecycle_updated_at','missing_since_run_id')
  ) then
    raise exception 'MT5_S1_TEST_PREFLIGHT: S1 schema packet has already run — pre-migration evidence cannot be observed';
  end if;
  if to_regclass('public.mt5_sync_runs') is not null then
    raise exception 'MT5_S1_TEST_PREFLIGHT: S1 run objects already exist — run this file first';
  end if;
end
$pre$;

create table public.mt5_s1_test_pre_evidence (
  id               integer primary key,
  staging_count    bigint      not null,
  staging_checksum text        not null,
  observed_at      timestamptz not null default now(),
  constraint mt5_s1_test_pre_evidence_checksum_chk check (staging_checksum ~ '^[0-9a-f]{64}$')
);
comment on table public.mt5_s1_test_pre_evidence is
  'TEST-ONLY (disposable DB): independent pre-migration staging evidence consumed by S1 verification fixture 25. Not an S1 migration object.';

-- Seed representative pre-migration staging rows so the fixture-25 comparison is NON-VACUOUS.
-- (On an empty database both sides would be count=0 with the empty-string checksum, which would
--  compare equal without proving anything.) A dedicated account keeps these rows distinct from
-- every fixture's own seed data.
insert into public.mt5_import_staging
  (user_id,source_account,kind,symbol_raw,side,volume,position_id,position_state,state)
values
  ('00000000-0000-0000-0000-0000000000aa','ACC_PRE','open','GOU26','buy', 1,9001,'open','new'),
  ('00000000-0000-0000-0000-0000000000aa','ACC_PRE','open','S50U26','sell',2,9002,'open','new'),
  ('00000000-0000-0000-0000-0000000000aa','ACC_PRE','open','SVFU26','buy', 3,9003,'open','new');

-- Independent observation, using the SAME expression the schema preflight will use. Because the
-- lifecycle columns do not exist yet, to_jsonb(s) here cannot contain them; after the migration the
-- schema postflight subtracts those two keys, which makes the two values directly comparable.
insert into public.mt5_s1_test_pre_evidence (id,staging_count,staging_checksum)
select 1,
       count(*),
       pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
         coalesce(pg_catalog.string_agg(pg_catalog.to_jsonb(s)::text,'' order by s.id),''),'UTF8'),'sha256'),'hex')
  from public.mt5_import_staging s;

do $post$
declare v_c bigint; v_k text;
begin
  select staging_count,staging_checksum into v_c,v_k from public.mt5_s1_test_pre_evidence where id=1;
  if not found then raise exception 'MT5_S1_TEST_PREFLIGHT: evidence row was not recorded'; end if;
  if v_c < 3 then
    raise exception 'MT5_S1_TEST_PREFLIGHT: expected at least the 3 seeded staging rows, got %',v_c;
  end if;
  raise notice 'MT5_S1_TEST_PREFLIGHT: pre-migration evidence recorded (count=%, checksum=%)',v_c,left(v_k,12)||'...';
end
$post$;

commit;
