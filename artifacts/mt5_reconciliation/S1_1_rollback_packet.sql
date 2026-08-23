-- ================================================================================================
--  *** S1.1 ROLLBACK MUST RUN BEFORE S1 ROLLBACK. ***
--
--  S1_rollback_packet.sql ends with
--        drop table if exists public.mt5_sync_runs;
--  and uses NO CASCADE. While public.mt5_sync_run_account holds its composite foreign key to that
--  table, the S1 rollback FAILS at that statement.
--
--  The correct order is ALWAYS:
--        1. S1_1_rollback_packet.sql   (this file)
--        2. S1_rollback_packet.sql     (frozen -- never edited to work around the dependency)
--
--  S1_rollback_packet.sql is FROZEN: not its logic, not its header, not a comment. Its file
--  SHA-256 must remain unchanged, and that is an acceptance test.
-- ================================================================================================
--
-- MT5 S1.1 account observation — rollback packet
-- Contract source: S1_1_account_observation_design.md  (FROZEN — CODEX APPROVED, 2026-08-22)
--   frozen source_artifact_sha256 =
--     812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1
-- Packet revision: 3   (matches schema/RPC revision 3; authority extended to triggers, policies,
--                       RLS state, table ACL, COLUMN-level ACL, and an absolute RPC-ledger gate)
--
-- WHAT THIS REMOVES  (S1.1-owned objects ONLY)
--   trigger  mt5_run_account_no_mutate_v1     on public.mt5_sync_run_account
--   trigger  mt5_run_account_started_only_v1  on public.mt5_sync_run_account
--   policy   mt5_sra_service_read_v1          on public.mt5_sync_run_account
--   table    public.mt5_sync_run_account      (its index drops with it)
--   function public.mt5_run_account_guard_v1()
--   function public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)
--   function public.mt5_account_fingerprint_v1(...)
--   ledger rows mt5_s1_1_account_observation_schema_v1 / _rpc_v1
--
-- WHAT IT NEVER TOUCHES
--   mt5_sync_runs · mt5_sync_run_positions · mt5_run_positions_guard_v1() · any frozen S1 RPC ·
--   mt5_import_staging · the S1 ledger rows · the ledger table itself (S1 owns that decision)
--
-- WARNING: this DISCARDS all S1.1 account observation evidence. Account facts are immutable
-- contemporaneous evidence and cannot be reconstructed afterwards -- a later observation is a
-- different run. Export before rolling back if the evidence still matters.

begin;

-- ------------------------------------------------------------------------------------------------
-- 0) Ledger identity and destructive authority.
--    NO DROP WITHOUT EXACT APPLY-TIME PROVENANCE.
--    Nothing is dropped until EVERY object class this packet can remove is proven to be the one
--    THIS packet revision created, by comparing live catalog fingerprints against
--    objects->'provenance': table shape, owner/table-ACL/row-security, COLUMN-level ACL, triggers,
--    policies, the guard function, and -- gated on an exact RPC ledger row -- the two RPC
--    functions.
--    Authority is established in ONE transaction before ANY destructive statement, so a refusal
--    leaves every S1.1 object and both ledger rows exactly as they were.
-- ------------------------------------------------------------------------------------------------
do $s11_ledger_present$
begin
  -- Declared in its OWN block on purpose: the block below declares
  -- public.mt5_schema_migrations%rowtype variables, and PL/pgSQL resolves those at COMPILE time.
  -- If the ledger is absent this block must speak first, or the operator only ever sees a raw
  -- "relation does not exist" from the compiler.
  if to_regclass('public.mt5_schema_migrations') is null then
    raise exception 'MT5_S1_1_ROLLBACK: migration ledger is missing - S1.1 is not installed (or S1 was already rolled back, which drops the ledger it created). Nothing to roll back; refusing blind rollback';
  end if;
end
$s11_ledger_present$;

do $s11_rb_auth$
declare
  v_schema public.mt5_schema_migrations%rowtype;
  v_rpc    public.mt5_schema_migrations%rowtype;
  v_prov   jsonb;
  v_rprov  jsonb;
  v_bad    text;
  v_cols   text;
  -- Everything this packet is capable of DROPPING from the RPC packet. Each must be individually
  -- authorised by an exact apply-time fingerprint before any destructive statement runs.
  v_rpc_funcs constant text[] := array[
    'public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)',
    'public.mt5_account_fingerprint_v1(uuid,text,timestamptz,text,timestamptz,text,numeric,numeric,text,text,text,text)'
  ];
begin
  select * into v_schema from public.mt5_schema_migrations
   where version='mt5_s1_1_account_observation_schema_v1';
  if not found then
    raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger row is missing; refusing blind rollback';
  end if;
  if v_schema.status is distinct from 'applied' then
    raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger status is [%], expected applied', v_schema.status;
  end if;
  if v_schema.checksum is distinct from 'cf9427c58b916c6f2dd528dd5a23fdb14ed8624fc334e4b9aa0080980276f121' then
    raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger is not this packet revision';
  end if;
  if (v_schema.objects->>'packet_revision') is distinct from '3' then
    raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema packet_revision is [%], expected 3',
      v_schema.objects->>'packet_revision';
  end if;
  if v_schema.source_artifact_sha256 is distinct from '812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1' then
    raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger does not match the frozen design hash';
  end if;
  v_prov := v_schema.objects->'provenance';
  if v_prov is null or pg_catalog.jsonb_typeof(v_prov) is distinct from 'object' then
    raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger carries no apply-time provenance; refusing destructive rollback';
  end if;

  -- table structural fingerprint
  if to_regclass('public.mt5_sync_run_account') is not null
     and (v_prov->'tables'->>'mt5_sync_run_account') is distinct from (
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
         from pg_catalog.pg_class c where c.oid='public.mt5_sync_run_account'::regclass) then
    raise exception 'MT5_S1_1_ROLLBACK: public.mt5_sync_run_account no longer matches the apply-time S1.1 definition (replaced or altered) — refusing to drop';
  end if;

  -- guard function body fingerprint
  -- Must recompute EXACTLY what the schema packet recorded, ACL component included, or this
  -- refuses on every database -- including a pristine one.
  if to_regprocedure('public.mt5_run_account_guard_v1()') is not null
     and (v_prov->'functions'->>'public.mt5_run_account_guard_v1()') is distinct from (
       select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                pg_catalog.pg_get_functiondef(p.oid)||'|'||
                pg_catalog.pg_get_userbyid(p.proowner)||'|'||p.prosecdef::text||'|'||
                coalesce(pg_catalog.array_to_string(p.proconfig,','),'')||'|'||
                coalesce((select pg_catalog.string_agg(z.acl::text,',' order by z.acl::text)
                            from pg_catalog.unnest(p.proacl) as z(acl)),'<default>')
              ,'UTF8'),'sha256'),'hex')
         from pg_catalog.pg_proc p where p.oid='public.mt5_run_account_guard_v1()'::regprocedure) then
    raise exception 'MT5_S1_1_ROLLBACK: mt5_run_account_guard_v1() no longer matches its apply-time definition — refusing to drop';
  end if;

  -- ---------------------------------------------------------------------------------------
  -- TRIGGER authority. The immutability triggers ARE the append-only guarantee; a same-name
  -- trigger rebound to a different function, retimed, re-evented or disabled is a DIFFERENT
  -- object wearing the packet's name. pg_get_triggerdef covers timing/events/function/WHEN, and
  -- tgenabled covers the disabled-but-present case.
  -- Both directions: every recorded trigger must still match, and no UNRECORDED trigger may
  -- exist on the table (an added trigger changes behaviour without touching a recorded one).
  -- ---------------------------------------------------------------------------------------
  if to_regclass('public.mt5_sync_run_account') is not null then
    if (v_prov ? 'triggers') is not true then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger carries no apply-time trigger provenance; refusing destructive rollback';
    end if;
    select pg_catalog.string_agg(x.tgname,', ' order by x.tgname) into v_bad
      from pg_catalog.jsonb_each_text(v_prov->'triggers') as x(tgname,fp)
     where x.fp is distinct from (
       select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                pg_catalog.pg_get_triggerdef(t.oid)||'|'||t.tgenabled::text
              ,'UTF8'),'sha256'),'hex')
         from pg_catalog.pg_trigger t
        where t.tgrelid='public.mt5_sync_run_account'::regclass and t.tgname=x.tgname
          and not t.tgisinternal);
    if v_bad is not null then
      raise exception 'MT5_S1_1_ROLLBACK: trigger(s) % no longer match their apply-time definition (replaced, retimed, rebound or disabled) — refusing to drop', v_bad;
    end if;
    select pg_catalog.string_agg(t.tgname,', ' order by t.tgname) into v_bad
      from pg_catalog.pg_trigger t
     where t.tgrelid='public.mt5_sync_run_account'::regclass and not t.tgisinternal
       and (v_prov->'triggers'->>t.tgname) is null;
    if v_bad is not null then
      raise exception 'MT5_S1_1_ROLLBACK: unrecorded trigger(s) % exist on mt5_sync_run_account; this is not the object this packet applied — refusing to drop', v_bad;
    end if;

    -- ---------------------------------------------------------------------------------------
    -- POLICY / RLS authority. The fingerprint covers USING, WITH CHECK, command, permissive and
    -- ROLES: a same-name policy re-pointed at `authenticated` is a materially different security
    -- contract and must never be silently destroyed. Row-security enabled/forced state is part of
    -- the table's own security fingerprint below.
    -- ---------------------------------------------------------------------------------------
    if (v_prov ? 'policies') is not true or (v_prov ? 'security') is not true then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger carries no apply-time policy/security provenance; refusing destructive rollback';
    end if;
    select pg_catalog.string_agg(x.polname,', ' order by x.polname) into v_bad
      from pg_catalog.jsonb_each_text(v_prov->'policies') as x(polname,fp)
     where x.fp is distinct from (
       select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                coalesce(pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),'')||'|'||
                pol.polcmd::text||'|'||pol.polpermissive::text||'|'||
                coalesce(pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid),'')||'|'||
                coalesce((select pg_catalog.string_agg(
                            case when z.r=0 then 'public'
                                 else pg_catalog.pg_get_userbyid(z.r) end, ',' order by
                            case when z.r=0 then 'public'
                                 else pg_catalog.pg_get_userbyid(z.r) end)
                          from pg_catalog.unnest(pol.polroles) as z(r)),'')
              ,'UTF8'),'sha256'),'hex')
         from pg_catalog.pg_policy pol
        where pol.polrelid='public.mt5_sync_run_account'::regclass and pol.polname=x.polname);
    if v_bad is not null then
      raise exception 'MT5_S1_1_ROLLBACK: policy(ies) % no longer match their apply-time definition (USING, WITH CHECK, command, permissive or ROLES changed) — refusing to drop', v_bad;
    end if;
    select pg_catalog.string_agg(pol.polname,', ' order by pol.polname) into v_bad
      from pg_catalog.pg_policy pol
     where pol.polrelid='public.mt5_sync_run_account'::regclass
       and (v_prov->'policies'->>pol.polname) is null;
    if v_bad is not null then
      raise exception 'MT5_S1_1_ROLLBACK: unrecorded policy(ies) % exist on mt5_sync_run_account — refusing to drop', v_bad;
    end if;

    -- ---------------------------------------------------------------------------------------
    -- COLUMN-LEVEL ACL authority. This check exists because the table-level one CANNOT see it:
    --     GRANT SELECT (equity) ON public.mt5_sync_run_account TO authenticated;
    -- writes pg_attribute.attacl and leaves pg_class.relacl byte-identical. Without this the
    -- fingerprint below still matches and rollback would drop a table whose security contract
    -- changed after apply -- destroying the evidence of the change along with the data.
    --
    -- Recomputed with EXACTLY the algorithm the schema packet recorded (aclexplode, entries and
    -- columns both sorted), so a match means identity, not coincidence.
    -- ---------------------------------------------------------------------------------------
    if (v_prov ? 'column_acl') is not true
       or (v_prov->'column_acl'->>'fingerprint') is null then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 schema ledger carries no apply-time column-ACL provenance; refusing destructive rollback';
    end if;
    v_cols := (select pg_catalog.string_agg(
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
            and c2.attnum>0 and not c2.attisdropped);
    if (v_prov->'column_acl'->>'fingerprint') is distinct from (
         select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                  coalesce(v_cols,'')
                ,'UTF8'),'sha256'),'hex')) then
      -- Name the drifted columns. Reporting only; the refusal itself is total and already decided.
      select pg_catalog.string_agg(x.col,', ' order by x.col) into v_bad
        from (select pg_catalog.split_part(t.cur,':',2) as col
                from pg_catalog.unnest(
                       pg_catalog.string_to_array(coalesce(v_cols,''),'|')) as t(cur)
               where t.cur is distinct from (
                 select w.was
                   from pg_catalog.unnest(pg_catalog.string_to_array(
                          coalesce(v_prov->'column_acl'->>'normalised',''),'|')) as w(was)
                  where pg_catalog.split_part(w.was,':',1)
                        = pg_catalog.split_part(t.cur,':',1))) x;
      raise exception 'MT5_S1_1_ROLLBACK: column-level ACL state changed since apply on column(s) % (pg_attribute.attacl differs while pg_class.relacl may not) — refusing to drop', coalesce(v_bad,'<unknown>');
    end if;

    -- ---------------------------------------------------------------------------------------
    -- OWNER / ACL / ROW-SECURITY authority. These change through commands that leave the column,
    -- constraint and index shape untouched, so the structural fingerprint above cannot see them.
    -- A table whose grants were widened to `authenticated`, or whose RLS was switched off, is a
    -- materially different object; erasing it under the packet's name would destroy evidence of
    -- the change along with the data.
    -- ---------------------------------------------------------------------------------------
    if (v_prov->'security'->>'mt5_sync_run_account') is distinct from (
      select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
               pg_catalog.pg_get_userbyid(c.relowner)||'|'||
               c.relrowsecurity::text||'|'||c.relforcerowsecurity::text||'|'||
               coalesce((select pg_catalog.string_agg(z.acl::text,',' order by z.acl::text)
                           from pg_catalog.unnest(c.relacl) as z(acl)),'<default>')
             ,'UTF8'),'sha256'),'hex')
        from pg_catalog.pg_class c where c.oid='public.mt5_sync_run_account'::regclass) then
      raise exception 'MT5_S1_1_ROLLBACK: mt5_sync_run_account owner, grants or row-security state changed after apply — refusing to drop';
    end if;
  end if;

  -- RPC packet, when it was applied
  select * into v_rpc from public.mt5_schema_migrations
   where version='mt5_s1_1_account_observation_rpc_v1';
  if not found then
    -- ABSOLUTE GATE. A missing RPC ledger is NOT permission to drop by name. Either this is a
    -- partial install (the RPC packet never ran, so nothing of its is here and there is nothing to
    -- authorise), or something else owns those signatures now -- and this packet cannot tell the
    -- difference from the name alone. `drop function if exists` on a foreign same-name function
    -- would destroy someone else's object under cover of a rollback.
    select pg_catalog.string_agg(t.sig,', ' order by t.sig) into v_bad
      from pg_catalog.unnest(v_rpc_funcs) as t(sig) where to_regprocedure(t.sig) is not null;
    if v_bad is not null then
      raise exception 'MT5_S1_1_ROLLBACK: function(s) % exist but the S1.1 RPC ledger row is MISSING, so nothing authorises dropping them. Ownership is NOT inferred from a name or signature — refusing to drop', v_bad;
    end if;
    raise notice 'MT5_S1_1_ROLLBACK: no S1.1 RPC ledger and no S1.1 RPC functions present — partial install, nothing to authorise';
  else
    if v_rpc.status is distinct from 'applied' then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 RPC ledger status is [%], expected applied', v_rpc.status;
    end if;
    if v_rpc.checksum is distinct from '370a41bfe7d8d72d9e3e99aa1d38d2f4bd68c06a95cd1d1a056afa28e365c93a' then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 RPC ledger is not this packet revision';
    end if;
    if v_rpc.source_artifact_sha256 is distinct from '812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1' then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 RPC ledger does not match the frozen design hash';
    end if;
    if (v_rpc.objects->>'packet_revision') is distinct from '3' then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 RPC packet_revision is [%], expected 3',
        v_rpc.objects->>'packet_revision';
    end if;
    v_rprov := v_rpc.objects->'provenance';
    if v_rprov is null or (v_rprov ? 'functions') is not true then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 RPC ledger carries no apply-time provenance';
    end if;

    -- (a) every recorded function that still exists must be byte-identical to what apply created.
    select pg_catalog.string_agg(x.sig,', ' order by x.sig) into v_bad
      from pg_catalog.jsonb_each_text(v_rprov->'functions') as x(sig,fp)
     where to_regprocedure(x.sig) is not null
       and x.fp is distinct from (
         select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
                  pg_catalog.pg_get_functiondef(p.oid)||'|'||
                  pg_catalog.pg_get_userbyid(p.proowner)||'|'||p.prosecdef::text||'|'||
                  coalesce(pg_catalog.array_to_string(p.proconfig,','),'')||'|'||
                  coalesce((select pg_catalog.string_agg(z.acl::text,',' order by z.acl::text)
                              from pg_catalog.unnest(p.proacl) as z(acl)),'<default>')
                ,'UTF8'),'sha256'),'hex')
           from pg_catalog.pg_proc p where p.oid = to_regprocedure(x.sig));
    if v_bad is not null then
      raise exception 'MT5_S1_1_ROLLBACK: S1.1 function(s) % no longer match their apply-time definition (body, owner, security, config or grants changed) — refusing to drop', v_bad;
    end if;

    -- (b) and the converse, which (a) alone cannot give: every function this packet would DROP
    --     must be POSITIVELY authorised by a recorded fingerprint. Matched by OID, so the recorded
    --     regprocedure text and the drop-target text need not be spelled identically.
    select pg_catalog.string_agg(t.sig,', ' order by t.sig) into v_bad
      from pg_catalog.unnest(v_rpc_funcs) as t(sig)
     where to_regprocedure(t.sig) is not null
       and not exists (select 1
                         from pg_catalog.jsonb_each_text(v_rprov->'functions') as e(rsig,rfp)
                        where to_regprocedure(e.rsig) = to_regprocedure(t.sig));
    if v_bad is not null then
      raise exception 'MT5_S1_1_ROLLBACK: function(s) % occupy an S1.1 signature but are NOT recorded in the apply-time provenance — refusing to drop', v_bad;
    end if;
  end if;

  -- The frozen S1 objects must still be present and unchanged. S1.1 rollback exists to RESTORE
  -- S1's ability to roll back, so a drifted S1 here means something else already broke it and a
  -- silent success would be misleading.
  if to_regclass('public.mt5_sync_runs') is null then
    raise exception 'MT5_S1_1_ROLLBACK: public.mt5_sync_runs is missing; S1 state is not what S1.1 was installed against';
  end if;
  if (v_prov ? 's1_tables_at_apply') is true then
    select pg_catalog.string_agg(x.rel,', ' order by x.rel) into v_bad
      from (values ('mt5_sync_runs'),('mt5_sync_run_positions')) x(rel)
     where to_regclass('public.'||x.rel) is not null
       and (v_prov->'s1_tables_at_apply'->>x.rel) is distinct from (
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
      raise exception 'MT5_S1_1_ROLLBACK: frozen S1 table(s) % drifted after S1.1 apply; S1 rollback is already disarmed and removing S1.1 will not restore it — refusing to proceed silently', v_bad;
    end if;
  end if;

  raise notice 'MT5_S1_1_ROLLBACK: authority established — S1.1 objects match their apply-time provenance';
end
$s11_rb_auth$;

-- ------------------------------------------------------------------------------------------------
-- 1) Drop S1.1-owned objects. Order: triggers/policy, then table, then functions.
--    `if exists` throughout, so a partially-applied install rolls back cleanly.
-- ------------------------------------------------------------------------------------------------
do $s11_rb_drop_deps$
begin
  if to_regclass('public.mt5_sync_run_account') is not null then
    drop trigger if exists mt5_run_account_no_mutate_v1    on public.mt5_sync_run_account;
    drop trigger if exists mt5_run_account_started_only_v1 on public.mt5_sync_run_account;
    drop policy  if exists mt5_sra_service_read_v1         on public.mt5_sync_run_account;
  end if;
end
$s11_rb_drop_deps$;

-- the FK on mt5_sync_runs disappears with this table; mt5_sync_runs itself is NOT touched
drop table if exists public.mt5_sync_run_account;

drop function if exists public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb);
drop function if exists public.mt5_account_fingerprint_v1(uuid,text,timestamptz,text,timestamptz,text,numeric,numeric,text,text,text,text);
drop function if exists public.mt5_run_account_guard_v1();

-- ------------------------------------------------------------------------------------------------
-- 2) Remove ONLY the S1.1-owned ledger rows. The ledger table and every S1 row stay.
-- ------------------------------------------------------------------------------------------------
delete from public.mt5_schema_migrations
 where version in ('mt5_s1_1_account_observation_schema_v1','mt5_s1_1_account_observation_rpc_v1');

-- ------------------------------------------------------------------------------------------------
-- 3) Postflight: prove S1.1 is gone AND that frozen S1 survived intact, i.e. S1 rollback is armed.
-- ------------------------------------------------------------------------------------------------
do $s11_rb_post$
declare v_bad text;
begin
  select pg_catalog.string_agg(x.obj,', ' order by x.obj) into v_bad
    from (
      select 'table public.mt5_sync_run_account' as obj
       where to_regclass('public.mt5_sync_run_account') is not null
      union all
      select 'function public.mt5_run_account_guard_v1()'
       where to_regprocedure('public.mt5_run_account_guard_v1()') is not null
      union all
      select 'function '||p.oid::regprocedure::text
        from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public'
         and p.proname in ('mt5_account_fingerprint_v1','mt5_append_run_account_v1')
      union all
      select 'ledger row '||m.version from public.mt5_schema_migrations m
       where m.version in ('mt5_s1_1_account_observation_schema_v1','mt5_s1_1_account_observation_rpc_v1')
    ) x;
  if v_bad is not null then
    raise exception 'MT5_S1_1_ROLLBACK_POSTFLIGHT: S1.1 object(s) survived rollback: %', v_bad;
  end if;

  -- S1 must be entirely intact
  select pg_catalog.string_agg(x.obj,', ' order by x.obj) into v_bad
    from (
      select 'table public.mt5_sync_runs' as obj where to_regclass('public.mt5_sync_runs') is null
      union all
      select 'table public.mt5_sync_run_positions' where to_regclass('public.mt5_sync_run_positions') is null
      union all
      select 'function public.mt5_run_positions_guard_v1()'
       where to_regprocedure('public.mt5_run_positions_guard_v1()') is null
      union all
      select 'function public.mt5_get_current_snapshot_v1(text)'
       where to_regprocedure('public.mt5_get_current_snapshot_v1(text)') is null
      union all
      select 'ledger row mt5_s1_append_only_schema_v1'
       where not exists (select 1 from public.mt5_schema_migrations
                          where version='mt5_s1_append_only_schema_v1' and status='applied')
      union all
      select 'ledger row mt5_s1_append_only_rpc_v1'
       where not exists (select 1 from public.mt5_schema_migrations
                          where version='mt5_s1_append_only_rpc_v1' and status='applied')
    ) x;
  if v_bad is not null then
    raise exception 'MT5_S1_1_ROLLBACK_POSTFLIGHT: frozen S1 object(s) missing after S1.1 rollback: %', v_bad;
  end if;

  raise notice 'MT5_S1_1_ROLLBACK: PASS — S1.1 removed, frozen S1 intact. S1 rollback may now run.';
end
$s11_rb_post$;

commit;
