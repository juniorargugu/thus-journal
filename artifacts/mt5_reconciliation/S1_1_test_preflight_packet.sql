-- MT5 S1.1 — pre-migration fail-closed preflight (READ-ONLY, NO MUTATION)
-- Contract source: S1_1_account_observation_design.md  (FROZEN — CODEX APPROVED, 2026-08-22)
--   frozen source_artifact_sha256 =
--     812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1
--   The hash is over the LF-normalised bytes, i.e. exactly what
--     git show <rev>:artifacts/mt5_reconciliation/S1_1_account_observation_design.md | sha256sum
--   prints. The repo has core.autocrlf=true and no .gitattributes, so a Windows working-copy
--   checkout may hold CRLF and hash differently; the git blob is the authority.
-- Status: EXECUTABLE DRAFT — NOT RUN AGAINST PRODUCTION.
-- Packet revision: 3
--   Unlike the schema/RPC packets this file writes NO ledger row (it is read-only and ends in
--   `rollback;`), so it carries no ledger identity token. Its only checksum is its file SHA-256.
--   Generations in this worktree: 1 = original (pinned the superseded revision-1 S1.1 tokens);
--   2 = tokens re-pinned to revision 3; 3 = exact-replay predicate split into two independent
--   per-version exact tuples. Revisions 1-2 carried no explicit marker.
--
-- PURPOSE
--   Refuse to install S1.1 onto anything other than an intact, frozen S1 revision-5 database.
--   S1.1 depends on S1 in ways a name check cannot see: it takes a composite FK to
--   mt5_sync_runs, and its INSERT guard reads that run's snapshot_status and captured_at. If S1
--   has drifted, S1.1 would either fail confusingly at apply time or, worse, install against a
--   shape it does not actually match.
--
--   It ALSO proves S1's own rollback is still armed BEFORE S1.1 adds an FK dependency on it,
--   so that a later F5/F6 failure can never be blamed on pre-existing S1 drift.
--
-- EXECUTION ORDER (disposable database only):
--   1. Phase-0A baseline
--   2. S1_test_preflight_packet.sql
--   3. S1_schema_packet.sql        (frozen, unchanged)
--   4. S1_rpc_packet.sql           (frozen, unchanged)
--   5. THIS FILE                   <- must pass before any S1.1 packet
--   6. S1_1_schema_packet.sql
--   7. S1_1_rpc_packet.sql
--   8. S1_1_verification_packet.sql
--   9. S1_1_rollback_packet.sql    (MUST run before S1_rollback_packet.sql)
--
-- SAFETY
--   * Contains NO DDL and NO DML. It is a single read-only DO block plus a NOTICE.
--   * It is NOT recorded in the migration ledger and owns no objects.
--   * It never edits, drops or mutates any frozen S1 object.

begin;

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

do $s11_preflight$
declare
  v_pg        integer := current_setting('server_version_num')::integer;
  v_schema    public.mt5_schema_migrations%rowtype;
  v_rpc       public.mt5_schema_migrations%rowtype;
  v_prov      jsonb;
  v_bad       text;
  -- Two INDEPENDENT exactness predicates. Never one EXISTS spanning both versions: that proves
  -- neither that each version carries ITS OWN identity token, nor that BOTH rows are present.
  v_schema_exact boolean;
  v_rpc_exact    boolean;
  v_expect_design constant text :=
    '812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1';
  v_expect_s1_schema constant text :=
    '7cd1e9783853798e31f907cf567cfdfb0b90071427fa4132d56eb177a948139b';
  v_expect_s1_rpc constant text :=
    '65a21a632f3826f661de6ce516cf804272a26ccea35275bde99b3b225953c835';
begin
  ----------------------------------------------------------------------------------------------
  -- 1) Platform
  ----------------------------------------------------------------------------------------------
  -- S1.1 relies on numeric NaN/Infinity/-Infinity literals and on numeric NaN comparing equal to
  -- itself. Both are PostgreSQL 14+ behaviour; the design was validated on 17.6, so the accepted
  -- band is 17.x. A wider band would be an untested claim.
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

  ----------------------------------------------------------------------------------------------
  -- 2) The frozen S1 ledger rows must exist, be applied, and be revision 5
  ----------------------------------------------------------------------------------------------
  select * into v_schema from public.mt5_schema_migrations
   where version='mt5_s1_append_only_schema_v1';
  if not found then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 schema ledger row is missing';
  end if;
  if v_schema.status is distinct from 'applied' then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 schema ledger status is [%], expected applied', v_schema.status;
  end if;
  if v_schema.checksum is distinct from v_expect_s1_schema then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 schema packet identity token is not the expected revision-5 value';
  end if;
  if (v_schema.objects->>'packet_revision') is distinct from '5' then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 schema packet_revision is [%], expected 5',
      v_schema.objects->>'packet_revision';
  end if;

  select * into v_rpc from public.mt5_schema_migrations
   where version='mt5_s1_append_only_rpc_v1';
  if not found then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 RPC ledger row is missing';
  end if;
  if v_rpc.status is distinct from 'applied' then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 RPC ledger status is [%], expected applied', v_rpc.status;
  end if;
  if v_rpc.checksum is distinct from v_expect_s1_rpc then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 RPC packet identity token is not the expected revision-5 value';
  end if;
  if (v_rpc.objects->>'packet_revision') is distinct from '5' then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 RPC packet_revision is [%], expected 5',
      v_rpc.objects->>'packet_revision';
  end if;

  ----------------------------------------------------------------------------------------------
  -- 3) The S1 tables must exist in their expected shape
  ----------------------------------------------------------------------------------------------
  if to_regclass('public.mt5_sync_runs') is null then
    raise exception 'MT5_S1_1_PREFLIGHT: public.mt5_sync_runs is missing';
  end if;
  if to_regclass('public.mt5_sync_run_positions') is null then
    raise exception 'MT5_S1_1_PREFLIGHT: public.mt5_sync_run_positions is missing';
  end if;
  if to_regclass('public.mt5_import_staging') is null then
    raise exception 'MT5_S1_1_PREFLIGHT: Phase 0A public.mt5_import_staging is missing';
  end if;

  -- The exact columns S1.1's FK and guard depend on.
  select pg_catalog.string_agg(x.want, ', ' order by x.want) into v_bad
    from (values ('id'),('user_id'),('source_account'),('captured_at'),('snapshot_status'),
                 ('connector_version')) x(want)
   where not exists (
     select 1 from pg_catalog.pg_attribute a
      where a.attrelid='public.mt5_sync_runs'::regclass
        and a.attname=x.want and a.attnum>0 and not a.attisdropped);
  if v_bad is not null then
    raise exception 'MT5_S1_1_PREFLIGHT: mt5_sync_runs is missing column(s) %', v_bad;
  end if;

  -- The composite unique key S1.1's FK must reference.
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conrelid='public.mt5_sync_runs'::regclass
       and conname='mt5_sync_runs_id_scope_uniq' and contype='u') then
    raise exception 'MT5_S1_1_PREFLIGHT: mt5_sync_runs_id_scope_uniq is missing; the S1.1 composite FK cannot be created';
  end if;

  -- The immutability triggers S1.1 mirrors must still be present on the positions table.
  if (select count(*) from pg_catalog.pg_trigger t
       where t.tgrelid='public.mt5_sync_run_positions'::regclass and not t.tgisinternal) <> 2 then
    raise exception 'MT5_S1_1_PREFLIGHT: mt5_sync_run_positions does not carry exactly its two S1 immutability triggers';
  end if;

  ----------------------------------------------------------------------------------------------
  -- 4) ROLLBACK-ARMING PROOF (before S1.1 adds any dependency)
  --    Recompute the structural fingerprints of both S1 tables and require them to equal the
  --    apply-time values in the S1 ledger provenance. This is the same expression the frozen S1
  --    rollback uses as its destructive authority, so a match here proves S1 rollback is armed
  --    RIGHT NOW -- i.e. before S1.1 exists, a later F5/F6 result is attributable to S1.1 alone.
  ----------------------------------------------------------------------------------------------
  if (v_schema.objects ? 'provenance') is not true
     or pg_catalog.jsonb_typeof(v_schema.objects->'provenance') is distinct from 'object' then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 schema ledger carries no apply-time provenance';
  end if;
  v_prov := v_schema.objects->'provenance';
  if (v_prov ? 'tables') is not true then
    raise exception 'MT5_S1_1_PREFLIGHT: S1 provenance carries no table fingerprints';
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
    raise exception 'MT5_S1_1_PREFLIGHT: S1 table(s) % no longer match the apply-time S1 definition; S1 rollback is ALREADY disarmed — refusing to install S1.1 on top of drift', v_bad;
  end if;

  ----------------------------------------------------------------------------------------------
  -- 5) No S1.1 name collision, unless an exact replay of THIS packet revision proves ownership
  ----------------------------------------------------------------------------------------------
  -- EXACT SCHEMA TUPLE. Every element bound to the SCHEMA version specifically: its own
  -- identity token (equality, never `checksum in (...)`, so the RPC token can never satisfy it),
  -- its own packet_revision, applied status, and the frozen design hash.
  --
  -- `version` is the ledger's PRIMARY KEY, so at most ONE row can satisfy this predicate and
  -- EXISTS therefore means EXACTLY one. That is why `v_schema_exact and v_rpc_exact` is a
  -- sufficient proof that BOTH rows exist -- no count(*) is needed.
  select exists (
    select 1 from public.mt5_schema_migrations m
     where m.version = 'mt5_s1_1_account_observation_schema_v1'
       and m.status = 'applied'
       and m.checksum = 'cf9427c58b916c6f2dd528dd5a23fdb14ed8624fc334e4b9aa0080980276f121'
       and m.source_artifact_sha256 = v_expect_design
       and (m.objects->>'packet_revision') = '3')
    into v_schema_exact;

  -- EXACT RPC TUPLE. Same shape, bound to the RPC version and the RPC token.
  select exists (
    select 1 from public.mt5_schema_migrations m
     where m.version = 'mt5_s1_1_account_observation_rpc_v1'
       and m.status = 'applied'
       and m.checksum = '370a41bfe7d8d72d9e3e99aa1d38d2f4bd68c06a95cd1d1a056afa28e365c93a'
       and m.source_artifact_sha256 = v_expect_design
       and (m.objects->>'packet_revision') = '3')
    into v_rpc_exact;

  -- The ONLY green replay signal. Both, independently, or none: there is deliberately no
  -- optimistic partial-replay path, because a partially-current installation is precisely the
  -- state an operator most needs told about.
  if v_schema_exact and v_rpc_exact then
    raise notice 'MT5_S1_1_PREFLIGHT: an exact replay of this S1.1 packet revision is already applied (idempotent path)';
  else
    select pg_catalog.string_agg(x.obj, ', ' order by x.obj) into v_bad
      from (
        select 'table public.mt5_sync_run_account' as obj
         where to_regclass('public.mt5_sync_run_account') is not null
        union all
        select 'function public.mt5_run_account_guard_v1()'
         where to_regprocedure('public.mt5_run_account_guard_v1()') is not null
        union all
        select 'function public.mt5_account_fingerprint_v1(...)'
         where exists (select 1 from pg_catalog.pg_proc p
                        join pg_catalog.pg_namespace n on n.oid=p.pronamespace
                       where n.nspname='public' and p.proname='mt5_account_fingerprint_v1')
        union all
        select 'function public.mt5_append_run_account_v1(...)'
         where exists (select 1 from pg_catalog.pg_proc p
                        join pg_catalog.pg_namespace n on n.oid=p.pronamespace
                       where n.nspname='public' and p.proname='mt5_append_run_account_v1')
        union all
        select 'ledger row '||m.version
          from public.mt5_schema_migrations m
         where m.version in ('mt5_s1_1_account_observation_schema_v1',
                             'mt5_s1_1_account_observation_rpc_v1')
      ) x;
    if v_bad is not null then
      -- Name WHICH exactness failed. Claiming "exact replay" and leaving the next packet to catch
      -- the problem would make the operator's first gate the least trustworthy one.
      raise exception 'MT5_S1_1_PREFLIGHT: NOT an exact replay of the current S1.1 packet revision (schema_exact=%, rpc_exact=%) — S1.1 object/ledger collision (%) that this packet revision cannot claim. Stale or missing provenance, or an object of unknown origin; refusing to overwrite it',
        v_schema_exact, v_rpc_exact, v_bad;
    end if;
  end if;

  raise notice 'MT5_S1_1_PREFLIGHT: PASS — frozen S1 revision 5 intact, rollback armed, no unclaimed S1.1 collision (pg=%)', v_pg;
end
$s11_preflight$;

rollback;   -- read-only by construction; end the transaction without leaving any trace
