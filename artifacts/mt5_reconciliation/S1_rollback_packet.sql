-- MT5 S1 append-only rollback packet
-- Contract source: S1_append_only_snapshot_membership_design.md revision 3
-- Reverts mt5_s1_append_only_rpc_v1 + mt5_s1_append_only_schema_v1.
-- Status: EXECUTABLE DRAFT — intentionally UNAPPLIED.
--
-- PREREQUISITE (operational, NOT SQL): the MT5 connector/writer must be stopped first — no run may be
--   in-flight. Ordinary reconciliation failure is NOT a reason to roll back the schema.
--
-- GOVERNING RULE
--   ROLLBACK MAY REMOVE OR RESTORE ONLY STATE IT CAN PROVE S1 OWNS,
--   AND MUST RESTORE PRE-S1 PRIVILEGES EXACTLY.
--
-- AUTHORITY MODEL
--   1. Revalidate the CURRENT migration ledger against the canonical contract (structure, owner,
--      exact ACL) AND against its own apply-time structural fingerprint, BEFORE any row is trusted.
--      Rows copied into a replacement table are not evidence.
--   2. Establish which S1 packets successfully applied, from ledger provenance.
--   3. For every destructive target:
--        packet never successfully applied  -> DO NOT DROP (no mandate; a same-named object is foreign)
--        object absent in a supported state -> safe skip
--        object present                     -> recompute its fingerprint and compare with the
--                                              apply-time value recorded in the ledger
--        mismatch                           -> STOP the entire rollback
--        match                              -> may remove
--   4. Explicitly revoke the column ACLs S1 installed (table-level REVOKE does not remove them),
--      driven by objects->'provenance'->'staging_col_grants'.
--   5. Drop each S1-added staging column only after its recorded column definition matches.
--   6. Restore the captured pre-S1 privilege state EXACTLY (empty restores to empty).
--   7. Exact postflight.
--   No name-only inference. No owner-only inference. No broad fallback restoration.
--
-- PROVENANCE HONESTY (see README "Packet identity vs deployed-object proof")
--   The database cannot read this .sql file, so nothing here claims to verify the packet's file
--   bytes. `checksum` / `source_artifact_sha256` are PACKET IDENTITY METADATA declared by the
--   packets. The DESTRUCTIVE AUTHORITY is the apply-time catalog fingerprints recorded in
--   `objects->'provenance'`, which are derived from the objects that actually exist after apply.
--
-- WARNING: rollback DISCARDS all S1 run/lifecycle provenance created after S1.
-- NOTE: public.mt5_s1_test_pre_evidence (TEST-ONLY preflight, disposable DB) is NOT an S1 object
--   and is deliberately left untouched.

begin;

-- 0a) LEDGER REVALIDATION — the table this rollback draws destructive authority from ------------
--     Rollback must not trust whatever relation happens to be named public.mt5_schema_migrations.
--     Before ANY provenance row is consumed, the CURRENT ledger is revalidated against the exact
--     canonical contract the schema packet enforces at apply time (structure, identity, ACL). A
--     replaced/altered/re-privileged ledger STOPS the rollback before a single destructive statement,
--     because rows copied into a foreign table are not evidence about deployed objects.
do $ledger_valid$
declare
  v_acl text;
begin
  if to_regclass('public.mt5_schema_migrations') is null then
    raise exception 'MT5_S1_ROLLBACK: migration ledger is missing; refusing blind rollback';
  end if;

  -- STRUCTURE: exact column set, types, nullability
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
    raise exception 'MT5_S1_ROLLBACK: current migration ledger definition is incompatible — refusing to trust its rows';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema='public' and table_name='mt5_schema_migrations') <> 8 then
    raise exception 'MT5_S1_ROLLBACK: current migration ledger has an unexpected column set — refusing to trust its rows';
  end if;

  -- exact defaults S1 relies on
  if (select pg_catalog.pg_get_expr(d.adbin,d.adrelid) from pg_catalog.pg_attrdef d
       join pg_catalog.pg_attribute a on a.attrelid=d.adrelid and a.attnum=d.adnum
      where d.adrelid='public.mt5_schema_migrations'::regclass and a.attname='objects')
     is distinct from '''{}''::jsonb' then
    raise exception 'MT5_S1_ROLLBACK: current ledger objects default differs — refusing to trust its rows';
  end if;
  if (select pg_catalog.pg_get_expr(d.adbin,d.adrelid) from pg_catalog.pg_attrdef d
       join pg_catalog.pg_attribute a on a.attrelid=d.adrelid and a.attnum=d.adnum
      where d.adrelid='public.mt5_schema_migrations'::regclass and a.attname='applied_by')
     is distinct from 'CURRENT_USER' then
    raise exception 'MT5_S1_ROLLBACK: current ledger applied_by default differs — refusing to trust its rows';
  end if;

  -- primary key + every CHECK constraint, by name AND definition
  if not exists (
    select 1 from pg_catalog.pg_constraint k
     where k.conrelid='public.mt5_schema_migrations'::regclass and k.contype='p'
       and pg_catalog.pg_get_constraintdef(k.oid)='PRIMARY KEY (version)'
  ) then
    raise exception 'MT5_S1_ROLLBACK: current ledger primary key differs — refusing to trust its rows';
  end if;
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
    raise exception 'MT5_S1_ROLLBACK: current ledger CHECK constraints differ — refusing to trust its rows';
  end if;
  if (select count(*) from pg_catalog.pg_constraint k
       where k.conrelid='public.mt5_schema_migrations'::regclass and k.contype in ('c','p','u','f')) <> 6 then
    raise exception 'MT5_S1_ROLLBACK: current ledger carries unexpected constraints — refusing to trust its rows';
  end if;

  -- IDENTITY: owner
  if (select pg_catalog.pg_get_userbyid(c.relowner) from pg_catalog.pg_class c
       where c.oid='public.mt5_schema_migrations'::regclass) <> 'postgres' then
    raise exception 'MT5_S1_ROLLBACK: current ledger is not postgres-owned — refusing to trust its rows';
  end if;

  -- ACL: EXACT normalized equality (owner's implicit entry excluded), not a subset search. Rejects
  -- missing SELECT, extra privileges, WITH GRANT OPTION, PUBLIC access and unrelated-role grants.
  select coalesce(pg_catalog.string_agg(
           (case when e.grantee=0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(e.grantee) end)
           ||':'||e.privilege_type||':'||e.is_grantable::text, ','
           order by (case when e.grantee=0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(e.grantee) end),
                    e.privilege_type),'')
    into v_acl
    from pg_catalog.pg_class c
    cross join lateral pg_catalog.aclexplode(c.relacl) e
   where c.oid='public.mt5_schema_migrations'::regclass
     and (case when e.grantee=0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(e.grantee) end) <> 'postgres';
  if v_acl is distinct from 'service_role:SELECT:false' then
    raise exception 'MT5_S1_ROLLBACK: current ledger ACL is [%], expected exactly [service_role:SELECT:false] — refusing to trust its rows',
      coalesce(nullif(v_acl,''),'<none>');
  end if;
  if exists (
    select 1 from pg_catalog.pg_attribute a
     where a.attrelid='public.mt5_schema_migrations'::regclass
       and a.attnum>0 and not a.attisdropped and a.attacl is not null
  ) then
    raise exception 'MT5_S1_ROLLBACK: current ledger carries column-level ACLs — refusing to trust its rows';
  end if;
end
$ledger_valid$;

-- 0) Ledger row identity, structural cross-check, and provenance staging ------------------------
--    `record`/scalar variables only: no %ROWTYPE against a relation whose existence is not yet
--    proven, so a missing ledger yields the intended stable guard rather than a compile error.
do $guard$
declare
  v_schema record;
  v_rpc record;
  v_prov jsonb;
  v_pre_grants text;
  v_has_rpc boolean := false;
  v_ledger_now text;
begin
  select m.version, m.status, m.checksum, m.source_artifact_sha256, m.objects into v_schema
    from public.mt5_schema_migrations m where m.version='mt5_s1_append_only_schema_v1';
  if not found or v_schema.status<>'applied'
     or v_schema.checksum<>'7cd1e9783853798e31f907cf567cfdfb0b90071427fa4132d56eb177a948139b' then
    raise exception 'MT5_S1_ROLLBACK: schema ledger entry is missing or is not this packet revision (incompatible objects)';
  end if;
  -- all recorded packet identity metadata is compared, including the frozen-design source hash
  if v_schema.source_artifact_sha256
     <> '9902B301B3E170A7FD5AA348C9892395CEBEE129DF1B5F63FAB9F62D53CA266D' then
    raise exception 'MT5_S1_ROLLBACK: schema ledger source_artifact_sha256 does not match the frozen revision-3 design';
  end if;
  if (v_schema.objects->>'packet_revision') is distinct from '5' then
    raise exception 'MT5_S1_ROLLBACK: schema ledger packet_revision is not 5 — this rollback matches a different packet revision';
  end if;
  if (v_schema.objects ? 'provenance') is not true
     or pg_catalog.jsonb_typeof(v_schema.objects->'provenance') is distinct from 'object' then
    raise exception 'MT5_S1_ROLLBACK: schema ledger carries no apply-time object provenance; refusing destructive rollback';
  end if;
  v_prov := v_schema.objects->'provenance';
  perform pg_catalog.set_config('mt5.s1_prov_schema', v_prov::text, true);

  -- ADDITIONAL LEDGER IDENTITY CHECK: the apply-time structural fingerprint of the ledger itself.
  -- 0a proved the ledger matches the canonical contract; this proves it is still the same relation
  -- S1 recorded, catching an exactly-shaped replacement built to impersonate it.
  if (v_prov->>'ledger_struct') is null then
    raise exception 'MT5_S1_ROLLBACK: provenance carries no ledger structural fingerprint; refusing destructive rollback';
  end if;
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
    into v_ledger_now
    from pg_catalog.pg_class c where c.oid='public.mt5_schema_migrations'::regclass;
  if v_ledger_now is distinct from (v_prov->>'ledger_struct') then
    raise exception 'MT5_S1_ROLLBACK: the current migration ledger is not the relation S1 recorded at apply time — refusing to trust its rows';
  end if;

  -- RPC packet authority: ONLY a successful RPC ledger record authorises dropping RPC functions.
  select m.version, m.status, m.checksum, m.source_artifact_sha256, m.objects into v_rpc
    from public.mt5_schema_migrations m where m.version='mt5_s1_append_only_rpc_v1';
  if found then
    if v_rpc.status<>'applied'
       or v_rpc.checksum<>'65a21a632f3826f661de6ce516cf804272a26ccea35275bde99b3b225953c835'
       or v_rpc.source_artifact_sha256<>'9902B301B3E170A7FD5AA348C9892395CEBEE129DF1B5F63FAB9F62D53CA266D'
       or (v_rpc.objects->>'packet_revision') is distinct from '5' then
      raise exception 'MT5_S1_ROLLBACK: rpc ledger row exists but is not a valid revision-5 application';
    end if;
    if (v_rpc.objects->'provenance') is null then
      raise exception 'MT5_S1_ROLLBACK: rpc ledger carries no apply-time function provenance; refusing to drop RPCs';
    end if;
    v_has_rpc := true;
    perform pg_catalog.set_config('mt5.s1_prov_rpc',(v_rpc.objects->'provenance')::text,true);
  else
    -- schema-only install: S1 has NO mandate over any RPC-packet signature. Same-named survivors
    -- are treated as foreign and are left completely alone.
    perform pg_catalog.set_config('mt5.s1_prov_rpc','{}',true);
  end if;
  perform pg_catalog.set_config('mt5.s1_has_rpc',v_has_rpc::text,true);

  -- exact privilege provenance is mandatory; guessing is forbidden
  if (v_schema.objects ? 'staging_pre_service_grants') is not true then
    raise exception 'MT5_S1_ROLLBACK: ledger has no staging_pre_service_grants provenance; refusing to guess pre-S1 privileges';
  end if;
  v_pre_grants := coalesce(v_schema.objects->>'staging_pre_service_grants','');
  if v_pre_grants <> '' and exists (
    select 1 from pg_catalog.regexp_split_to_table(v_pre_grants,',') as g(p)
     where btrim(g.p) not in ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER')
  ) then
    raise exception 'MT5_S1_ROLLBACK: unsupported privilege token in captured provenance (%)', v_pre_grants;
  end if;
  perform pg_catalog.set_config('mt5.s1_staging_pre_grants', v_pre_grants, true);

  -- S1-installed COLUMN ACLs. The schema packet records these INSIDE the provenance object
  -- (objects->'provenance'->'staging_col_grants'); reading objects->'staging_col_grants' would
  -- silently yield an empty set and leave S1 column privileges behind. Missing/malformed provenance
  -- must STOP: "no key" is not the same statement as "S1 granted nothing". A key that is present and
  -- empty is a valid recorded fact meaning there are zero S1 column grants to revoke.
  if (v_prov ? 'staging_col_grants') is not true
     or pg_catalog.jsonb_typeof(v_prov->'staging_col_grants') is distinct from 'object' then
    raise exception 'MT5_S1_ROLLBACK: provenance has no staging_col_grants object; refusing to guess which column privileges S1 installed';
  end if;
  perform pg_catalog.set_config('mt5.s1_staging_col_grants',
    (v_prov->'staging_col_grants')::text, true);

  -- S1-added staging column definitions, required before either column may be dropped by name
  if (v_prov ? 'staging_columns_def') is not true
     or pg_catalog.jsonb_typeof(v_prov->'staging_columns_def') is distinct from 'object' then
    raise exception 'MT5_S1_ROLLBACK: provenance has no staging_columns_def object; refusing to drop S1 staging columns by name alone';
  end if;
  perform pg_catalog.set_config('mt5.s1_staging_cols_def',
    (v_prov->'staging_columns_def')::text, true);
  perform pg_catalog.set_config('mt5.s1_ledger_created_by_s1',
    coalesce((v_schema.objects->>'ledger_created_by_s1'),'false'), true);
end
$guard$;

-- 0b) PROVENANCE VERIFICATION — recompute every fingerprint and compare with the apply-time value.
--     Runs BEFORE any destructive statement. Any mismatch aborts the whole rollback.
do $provenance$
declare
  v_ps jsonb := current_setting('mt5.s1_prov_schema')::jsonb;
  v_pr jsonb := current_setting('mt5.s1_prov_rpc')::jsonb;
  v_bad text;
begin
  -- the Phase 0A staging table is a hard prerequisite for the annotation/column/ACL checks below
  if to_regclass('public.mt5_import_staging') is null then
    raise exception 'MT5_S1_ROLLBACK: public.mt5_import_staging is missing; cannot verify or restore Phase 0A state';
  end if;

  -- ---- S1 tables: structural fingerprint (owner + columns + constraints + indexes; ACL-free) ---
  select pg_catalog.string_agg(x.rel, ', ' order by x.rel) into v_bad
    from (values ('mt5_sync_runs'),('mt5_sync_run_positions')) x(rel)
   where to_regclass('public.'||x.rel) is not null
     and (v_ps->'tables'->>x.rel) is distinct from (
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
         from pg_catalog.pg_class c where c.oid = to_regclass('public.'||x.rel)
     );
  if v_bad is not null then
    raise exception 'MT5_S1_ROLLBACK: table(s) % no longer match the apply-time S1 definition (replaced or altered) — refusing to drop', v_bad;
  end if;

  -- ---- guard function (schema packet): body-sensitive fingerprint ------------------------------
  if to_regprocedure('public.mt5_run_positions_guard_v1()') is not null
     and (v_ps->'functions'->>'public.mt5_run_positions_guard_v1()') is distinct from (
       select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                pg_catalog.pg_get_functiondef(p.oid)||'|'||
                pg_catalog.pg_get_userbyid(p.proowner)||'|'||p.prosecdef::text||'|'||
                coalesce(pg_catalog.array_to_string(p.proconfig,','),'')
              ,'UTF8'),'sha256'),'hex')
         from pg_catalog.pg_proc p where p.oid='public.mt5_run_positions_guard_v1()'::regprocedure
     ) then
    raise exception 'MT5_S1_ROLLBACK: mt5_run_positions_guard_v1() body/properties differ from apply time (replaced) — refusing to drop';
  end if;

  -- ---- RPC-packet functions: only when a successful RPC ledger record exists -------------------
  if current_setting('mt5.s1_has_rpc')::boolean then
    select pg_catalog.string_agg(k.sig, ', ' order by k.sig) into v_bad
      from pg_catalog.jsonb_object_keys(v_pr) as k(sig)
     where to_regprocedure(k.sig) is not null
       and (v_pr->>k.sig) is distinct from (
         select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                  pg_catalog.pg_get_functiondef(p.oid)||'|'||
                  pg_catalog.pg_get_userbyid(p.proowner)||'|'||p.prosecdef::text||'|'||
                  coalesce(pg_catalog.array_to_string(p.proconfig,','),'')
                ,'UTF8'),'sha256'),'hex')
           from pg_catalog.pg_proc p where p.oid = to_regprocedure(k.sig)
       );
    if v_bad is not null then
      raise exception 'MT5_S1_ROLLBACK: function(s) % have a different body/properties than at apply time (replaced) — refusing to drop', v_bad;
    end if;
  end if;

  -- ---- triggers: full effective definition + enabled state -------------------------------------
  if to_regclass('public.mt5_sync_run_positions') is not null then
    select pg_catalog.string_agg(k.tg, ', ' order by k.tg) into v_bad
      from pg_catalog.jsonb_object_keys(v_ps->'triggers') as k(tg)
     where exists (select 1 from pg_catalog.pg_trigger t
                    where t.tgrelid='public.mt5_sync_run_positions'::regclass
                      and t.tgname=k.tg and not t.tgisinternal)
       and (v_ps->'triggers'->>k.tg) is distinct from (
         select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                  pg_catalog.pg_get_triggerdef(t.oid)||'|'||t.tgenabled::text
                ,'UTF8'),'sha256'),'hex')
           from pg_catalog.pg_trigger t
          where t.tgrelid='public.mt5_sync_run_positions'::regclass
            and t.tgname=k.tg and not t.tgisinternal
       );
    if v_bad is not null then
      raise exception 'MT5_S1_ROLLBACK: trigger(s) % differ from the apply-time definition (replaced/altered) — refusing to drop', v_bad;
    end if;
  end if;

  -- ---- policies: name + command + permissive + roles + USING + WITH CHECK -----------------------
  --      Policy lookups are restricted to the two S1 relations in `public` (to_regclass yields NULL
  --      for an absent relation, which simply matches nothing), so a same-named policy on a
  --      same-named table in another schema can neither satisfy nor false-block this check.
  select pg_catalog.string_agg(k.key, ', ' order by k.key) into v_bad
    from pg_catalog.jsonb_object_keys(v_ps->'policies') as k(key)
   where exists (
     select 1 from pg_catalog.pg_policy pol
      where pol.polrelid in (to_regclass('public.mt5_sync_runs'), to_regclass('public.mt5_sync_run_positions'))
        and ((select c2.relname from pg_catalog.pg_class c2 where c2.oid=pol.polrelid)||'.'||pol.polname) = k.key
   )
     and (v_ps->'policies'->>k.key) is distinct from (
       select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                pol.polname||'|'||pol.polcmd::text||'|'||pol.polpermissive::text||'|'||
                coalesce((select pg_catalog.string_agg(pg_catalog.pg_get_userbyid(r),',' order by pg_catalog.pg_get_userbyid(r))
                          from pg_catalog.unnest(pol.polroles) as r),'')||'|'||
                coalesce(pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),'')||'|'||
                coalesce(pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid),'')
              ,'UTF8'),'sha256'),'hex')
         from pg_catalog.pg_policy pol
        where pol.polrelid in (to_regclass('public.mt5_sync_runs'), to_regclass('public.mt5_sync_run_positions'))
          and ((select c2.relname from pg_catalog.pg_class c2 where c2.oid=pol.polrelid)||'.'||pol.polname) = k.key
     );
  if v_bad is not null then
    raise exception 'MT5_S1_ROLLBACK: policy/policies % differ from the apply-time definition (replaced/altered) — refusing to drop', v_bad;
  end if;

  -- ---- S1 staging annotations (indexes + constraints) dropped by name -------------------------
  --      A same-named foreign index/constraint on the pre-existing Phase-0A table must survive.
  select pg_catalog.string_agg(k.name, ', ' order by k.name) into v_bad
    from pg_catalog.jsonb_object_keys(v_ps->'staging_objects') as k(name)
   where (v_ps->'staging_objects'->>k.name) is distinct from coalesce(
     -- namespace-qualified: a same-named index in another schema must not satisfy (or block) this check
     (select pg_catalog.pg_get_indexdef(i.oid) from pg_catalog.pg_class i
       where i.relnamespace='public'::regnamespace and i.relname=k.name and i.relkind='i'),
     (select pg_catalog.pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint c
       where c.conrelid='public.mt5_import_staging'::regclass and c.conname=k.name),
     -- absent object: treat as "matches" so a supported partial install skips it rather than STOPping
     (v_ps->'staging_objects'->>k.name)
   );
  if v_bad is not null then
    raise exception 'MT5_S1_ROLLBACK: staging annotation(s) % differ from the apply-time definition (replaced/altered) — refusing to drop', v_bad;
  end if;

  -- ---- S1-added staging COLUMNS: full definition fingerprint before any DROP COLUMN -------------
  --      Dropping by name alone would destroy a user/replacement column of the same name. Each
  --      column's current definition must equal the apply-time definition exactly; a column that is
  --      absent is a supported partial-install state and is treated as matching (the DROP below is
  --      `if exists`, so it simply skips).
  select pg_catalog.string_agg(k.col, ', ' order by k.col) into v_bad
    from pg_catalog.jsonb_object_keys(v_ps->'staging_columns_def') as k(col)
   where exists (select 1 from pg_catalog.pg_attribute a
                  where a.attrelid='public.mt5_import_staging'::regclass
                    and a.attname=k.col and a.attnum>0 and not a.attisdropped)
     and (v_ps->'staging_columns_def'->>k.col) is distinct from (
       select 'public.mt5_import_staging|'||a.attname||'|'||
              pg_catalog.format_type(a.atttypid,a.atttypmod)||'|'||
              a.attnotnull::text||'|'||
              coalesce(pg_catalog.pg_get_expr(d.adbin,d.adrelid),'')||'|'||
              a.attidentity::text||'|'||a.attgenerated::text
         from pg_catalog.pg_attribute a
         left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
        where a.attrelid='public.mt5_import_staging'::regclass
          and a.attname=k.col and a.attnum>0 and not a.attisdropped
     );
  if v_bad is not null then
    raise exception 'MT5_S1_ROLLBACK: staging column(s) % differ from the apply-time S1 definition (replaced by a different column) — refusing to drop', v_bad;
  end if;
end
$provenance$;

-- 1) drop RPC-packet functions — ONLY under a successful RPC ledger record ----------------------
--    With no RPC ledger row this block is a complete no-op, so a schema-only install never touches
--    a same-named foreign function. Signatures come from the ledger, not from a hardcoded list.
--    `DROP FUNCTION` also removes each function's ACLs, so no separate REVOKE is needed.
do $drop_rpcs$
declare k text;
begin
  if not current_setting('mt5.s1_has_rpc')::boolean then
    raise notice 'MT5_S1_ROLLBACK: no successful RPC ledger record — RPC/helper functions left untouched';
    return;
  end if;
  for k in select key from pg_catalog.jsonb_object_keys(current_setting('mt5.s1_prov_rpc')::jsonb) as t(key)
  loop
    if to_regprocedure(k) is not null then
      -- Re-render the signature FROM THE CATALOG (regprocedure output is canonical and correctly
      -- quoted), so the executed statement can never be shaped by the ledger string itself.
      execute 'drop function ' || to_regprocedure(k)::regprocedure::text;
    end if;
  end loop;
end
$drop_rpcs$;

-- 2) drop triggers + policies — RELATION-GUARDED -------------------------------------------------
--    `DROP TRIGGER/POLICY ... ON t` errors when `t` is absent, so both are guarded on the parent
--    relation; absence is a supported partial-install state and is skipped.
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

-- 3) revoke the COLUMN ACLs S1 installed, then restore the exact pre-S1 table ACLs ---------------
--    CRITICAL: `REVOKE INSERT/UPDATE ON TABLE ...` does NOT remove independently granted COLUMN
--    privileges. S1 installs column-scoped INSERT/UPDATE grants on mt5_import_staging, so those
--    must be revoked per column or a normal full install would leave S1 ACLs behind.
--    The column list comes from `staging_col_grants`, captured from the catalog at apply time, so
--    exactly the columns S1 granted are revoked and no unrelated column ACL is touched.
do $col_acl$
declare
  v_cols jsonb := current_setting('mt5.s1_staging_col_grants')::jsonb;
  v_col text; v_priv text;
begin
  if to_regclass('public.mt5_import_staging') is null then
    raise exception 'MT5_S1_ROLLBACK: public.mt5_import_staging is missing; cannot restore Phase 0A privileges';
  end if;
  for v_col in select key from pg_catalog.jsonb_object_keys(v_cols) as t(key) loop
    -- only columns that still exist; each recorded privilege revoked individually
    if exists (select 1 from pg_catalog.pg_attribute a
                where a.attrelid='public.mt5_import_staging'::regclass
                  and a.attname=v_col and a.attnum>0 and not a.attisdropped) then
      for v_priv in select btrim(p) from pg_catalog.regexp_split_to_table(v_cols->>v_col, ',') as s(p) loop
        if v_priv not in ('SELECT','INSERT','UPDATE','REFERENCES') then
          raise exception 'MT5_S1_ROLLBACK: unsupported column privilege token % recorded for %', v_priv, v_col;
        end if;
        execute pg_catalog.format('revoke %s (%I) on table public.mt5_import_staging from service_role',
                                  v_priv, v_col);
      end loop;
    end if;
  end loop;
end
$col_acl$;

do $restore$
declare
  v_pre text := coalesce(current_setting('mt5.s1_staging_pre_grants', true), '');
begin
  -- clear ALL table-level privileges, then restore ONLY the captured pre-S1 set.
  -- An EMPTY captured set restores NOTHING. There is deliberately no fallback grant.
  revoke select, insert, update, delete, truncate, references, trigger
    on table public.mt5_import_staging from service_role;
  if v_pre like '%SELECT%'     then grant select     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%INSERT%'     then grant insert     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%UPDATE%'     then grant update     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%DELETE%'     then grant delete     on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%TRUNCATE%'   then grant truncate   on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%REFERENCES%' then grant references on table public.mt5_import_staging to service_role; end if;
  if v_pre like '%TRIGGER%'    then grant trigger    on table public.mt5_import_staging to service_role; end if;
  -- prove the column ACLs are gone BEFORE the columns themselves are dropped
  if exists (select 1 from pg_catalog.pg_attribute a
              where a.attrelid='public.mt5_import_staging'::regclass
                and a.attnum>0 and not a.attisdropped and a.attacl is not null) then
    raise exception 'MT5_S1_ROLLBACK: a column-level ACL survived the S1 column revoke';
  end if;
end
$restore$;

-- 4) drop the S1 staging annotations -------------------------------------------------------------
--    Each of these four names was fingerprinted in 0b (pg_get_indexdef / pg_get_constraintdef); a
--    same-named foreign object would already have STOPped the rollback there.
alter table public.mt5_import_staging drop constraint if exists mt5_staging_missing_since_scope_fk;
alter table public.mt5_import_staging drop constraint if exists mt5_staging_position_state_s1_chk;
drop index if exists public.mt5_staging_lifecycle_open_idx;
drop index if exists public.mt5_staging_missing_since_idx;

-- 4b) drop the S1-ADDED staging columns — each authorised individually by its recorded definition --
--     The column name alone is not a mandate. Immediately before each DROP the current column
--     definition is re-compared with the apply-time fingerprint, so a replacement column that merely
--     reuses the name is never destroyed. Absent column = supported partial install = skip.
do $drop_cols$
declare
  v_defs jsonb := current_setting('mt5.s1_staging_cols_def')::jsonb;
  v_col text;
  v_now text;
begin
  foreach v_col in array array['missing_since_run_id','lifecycle_updated_at'] loop
    select 'public.mt5_import_staging|'||a.attname||'|'||
           pg_catalog.format_type(a.atttypid,a.atttypmod)||'|'||
           a.attnotnull::text||'|'||
           coalesce(pg_catalog.pg_get_expr(d.adbin,d.adrelid),'')||'|'||
           a.attidentity::text||'|'||a.attgenerated::text
      into v_now
      from pg_catalog.pg_attribute a
      left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
     where a.attrelid='public.mt5_import_staging'::regclass
       and a.attname=v_col and a.attnum>0 and not a.attisdropped;

    if v_now is null then
      raise notice 'MT5_S1_ROLLBACK: staging column % is already absent — skipping', v_col;
      continue;
    end if;
    if (v_defs->>v_col) is null then
      raise exception 'MT5_S1_ROLLBACK: staging column % exists but has no apply-time definition provenance — refusing to drop', v_col;
    end if;
    if v_now is distinct from (v_defs->>v_col) then
      raise exception 'MT5_S1_ROLLBACK: staging column % is not the column S1 added (definition differs) — refusing to drop', v_col;
    end if;
    execute pg_catalog.format('alter table public.mt5_import_staging drop column %I', v_col);
  end loop;
end
$drop_cols$;

-- 5) drop the run-position table (indexes drop with it), then its guard function -----------------
drop table if exists public.mt5_sync_run_positions;      -- composite FK to mt5_sync_runs drops with it
drop function if exists public.mt5_run_positions_guard_v1();

-- 6) drop the run table (its partial/unique indexes drop with it) --------------------------------
drop table if exists public.mt5_sync_runs;

-- 7) remove ONLY the S1-owned ledger entries; drop the ledger table only if S1 created it --------
delete from public.mt5_schema_migrations where version in ('mt5_s1_append_only_schema_v1','mt5_s1_append_only_rpc_v1');
do $ledger$
begin
  if current_setting('mt5.s1_ledger_created_by_s1')::boolean
     and not exists (select 1 from public.mt5_schema_migrations) then
    drop table public.mt5_schema_migrations;
  end if;
end
$ledger$;

-- 8) postflight: S1 objects gone; privileges EXACTLY equal to the captured pre-S1 state ----------
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
  if to_regprocedure('public.mt5_run_positions_guard_v1()') is not null then
    raise exception 'MT5_S1_ROLLBACK_POST: the S1 guard function survived';
  end if;
  -- every ledger-recorded RPC function must be gone (only when the RPC packet had applied)
  if current_setting('mt5.s1_has_rpc')::boolean then
    select pg_catalog.string_agg(k.sig, ', ' order by k.sig) into v_left
      from pg_catalog.jsonb_object_keys(current_setting('mt5.s1_prov_rpc')::jsonb) as k(sig)
     where to_regprocedure(k.sig) is not null;
    if v_left is not null then
      raise exception 'MT5_S1_ROLLBACK_POST: S1 function(s) survived: %', v_left;
    end if;
  end if;
  -- table-level privileges must equal EXACTLY what was captured before S1 (empty restores to empty)
  select coalesce(pg_catalog.string_agg(distinct p.privilege_type,',' order by p.privilege_type),'')
    into v_now
    from information_schema.role_table_grants p
   where p.table_schema='public' and p.table_name='mt5_import_staging' and p.grantee='service_role';
  if v_now is distinct from v_pre then
    raise exception 'MT5_S1_ROLLBACK_POST: staging privileges (%) do not match the captured pre-S1 state (%)',
      coalesce(nullif(v_now,''),'<none>'), coalesce(nullif(v_pre,''),'<none>');
  end if;
  -- and no column-level ACL may survive
  if exists (select 1 from pg_catalog.pg_attribute a
              where a.attrelid='public.mt5_import_staging'::regclass
                and a.attnum>0 and not a.attisdropped and a.attacl is not null) then
    raise exception 'MT5_S1_ROLLBACK_POST: an S1 column-level ACL survived on mt5_import_staging';
  end if;
  raise notice 'MT5_S1_ROLLBACK: complete — S1 objects removed, pre-S1 privileges restored exactly (%)',
    coalesce(nullif(v_pre,''),'<none>');
end
$post$;

commit;
