-- ================================================================================================
-- T4A SECURITY SURFACE VERIFICATION — STANDALONE, RE-RUNNABLE, READ-ONLY
--
-- Proves the ACTUAL privilege/RLS surface of the T4A objects from the system catalogs, at any
-- time: immediately after a clean apply, or later on an already-applied database. It makes ZERO
-- mutations — the whole packet runs inside a READ ONLY transaction and ends with ROLLBACK, so
-- PostgreSQL itself refuses any write this file could ever accidentally contain.
--
-- WHY NOT information_schema.role_table_grants: that view shows grants held by/granted-to roles
-- the current user is a member of and does NOT surface PUBLIC-derived access completely. This
-- packet reads the raw ACLs — aclexplode(pg_class.relacl), pg_attribute.attacl,
-- aclexplode(pg_proc.proacl) — where a PUBLIC grant is grantee oid 0 and CANNOT hide, plus
-- has_function_privilege() probes (a role with no direct grant inherits only PUBLIC, so
-- anon/authenticated executing anything proves a PUBLIC or direct leak). It still ALSO checks
-- information_schema.table_privileges for the named app roles.
--
-- CRITICAL proacl SEMANTICS: proacl IS NULL means BUILT-IN DEFAULT, which for functions
-- includes EXECUTE for PUBLIC. Every T4A function must therefore have a MATERIALIZED
-- (non-NULL) proacl with an exact, expected grantee list.
--
-- REVISION-LOCKED to the reviewed packets (schema packet revision 1, rpc packet revision 2,
-- fixture t3-kind-fixtures/1). A ledger-checksum mismatch here means packet/verifier drift and
-- must be resolved by an intentional re-pin, never by loosening a check.
--
-- Expected drift detections (each must make this packet FAIL): GRANT SELECT/any table privilege
-- to authenticated/anon, GRANT EXECUTE TO PUBLIC, a column-level grant, an extra/changed RLS
-- policy, a cleared SECURITY DEFINER bit, a changed owner, a changed search_path, a helper or
-- guard executable by any app role, a dropped/extra trigger, an injected function overload.
--
-- Run: psql -v ON_ERROR_STOP=1 -f T4A_security_verification_packet.sql
-- ================================================================================================

begin transaction read only;

-- ------------------------------------------------------------------------------------------------
-- SEC1: objects exist; the table is a plain relation owned by the intended role.
-- Owner convention (project-wide): packets are applied as postgres (Supabase SQL editor /
-- superuser psql), and every pipeline object is owned by postgres. Exact role, not "privileged".
-- ------------------------------------------------------------------------------------------------
do $sec1$
begin
  if to_regclass('public.mt5_capture_decisions') is null then
    raise exception 'T4A SEC1: public.mt5_capture_decisions does not exist';
  end if;
  if to_regclass('public.mt5_schema_migrations') is null then
    raise exception 'T4A SEC1: public.mt5_schema_migrations does not exist';
  end if;
  if not exists (select 1 from pg_catalog.pg_class c
                  where c.oid = 'public.mt5_capture_decisions'::regclass
                    and c.relkind = 'r'
                    and c.relowner::regrole::text = 'postgres') then
    raise exception 'T4A SEC1: mt5_capture_decisions is not a plain table owned by postgres';
  end if;
end $sec1$;

-- ------------------------------------------------------------------------------------------------
-- SEC2: RLS state + the EXACT policy set.
-- relrowsecurity must be TRUE. relforcerowsecurity is pinned FALSE — the reviewed schema packet
-- does not FORCE RLS (the owner-side write path is the SECURITY DEFINER RPC; service_role reads
-- under the policy). Pinning the actual reviewed state means silent drift in EITHER direction
-- fails here and forces an intentional decision.
-- Exactly ONE policy: mt5_cd_service_read_v1, permissive, SELECT, to service_role, USING (true),
-- no WITH CHECK. Any extra policy is a FAIL.
-- ------------------------------------------------------------------------------------------------
do $sec2$
declare
  v_n int;
  v_roles text[];
begin
  if not exists (select 1 from pg_catalog.pg_class c
                  where c.oid = 'public.mt5_capture_decisions'::regclass
                    and c.relrowsecurity and not c.relforcerowsecurity) then
    raise exception 'T4A SEC2: RLS flags drifted (expect enabled=true, forced=false)';
  end if;
  select count(*) into v_n
    from pg_catalog.pg_policy where polrelid = 'public.mt5_capture_decisions'::regclass;
  if v_n <> 1 then
    raise exception 'T4A SEC2: expected exactly 1 policy, found %', v_n;
  end if;
  select array_agg(r.rolname::text order by r.rolname) into v_roles
    from pg_catalog.pg_policy p
    cross join lateral unnest(p.polroles) u(roleoid)
    join pg_catalog.pg_roles r on r.oid = u.roleoid
   where p.polrelid = 'public.mt5_capture_decisions'::regclass
     and p.polname = 'mt5_cd_service_read_v1';
  if not exists (select 1 from pg_catalog.pg_policy p
                  where p.polrelid = 'public.mt5_capture_decisions'::regclass
                    and p.polname = 'mt5_cd_service_read_v1'
                    and p.polcmd = 'r'
                    and p.polpermissive
                    and pg_catalog.pg_get_expr(p.polqual, p.polrelid) = 'true'
                    and p.polwithcheck is null)
     or v_roles is distinct from array['service_role'] then
    raise exception 'T4A SEC2: policy mt5_cd_service_read_v1 drifted '
      '(expect permissive SELECT to service_role USING (true), no WITH CHECK; roles=%)', v_roles;
  end if;
end $sec2$;

-- ------------------------------------------------------------------------------------------------
-- SEC3: table ACL, from the raw relacl. Grantees must be EXACTLY {postgres, service_role};
-- service_role's privileges must be EXACTLY {SELECT}, not grantable; PUBLIC (grantee oid 0),
-- anon and authenticated must be absent. A NULL relacl would also fail (it would mean the
-- explicit service_role SELECT grant is gone). information_schema.table_privileges is checked
-- as well for the named app roles.
-- ------------------------------------------------------------------------------------------------
do $sec3$
declare
  v_who   text[];
  v_privs text[];
  v_bad   text;
begin
  select array_agg(distinct who order by who) into v_who
    from (select case when a.grantee = 0 then 'PUBLIC'
                      else a.grantee::regrole::text end as who
            from pg_catalog.pg_class c
            cross join lateral pg_catalog.aclexplode(c.relacl) a
           where c.oid = 'public.mt5_capture_decisions'::regclass) t;
  if v_who is distinct from array['postgres', 'service_role'] then
    raise exception 'T4A SEC3: table ACL grantees drifted: % (expect exactly '
      'postgres + service_role)', v_who;
  end if;
  select array_agg(distinct a.privilege_type order by a.privilege_type),
         max(case when a.is_grantable then 'yes' else 'no' end)
    into v_privs, v_bad
    from pg_catalog.pg_class c
    cross join lateral pg_catalog.aclexplode(c.relacl) a
   where c.oid = 'public.mt5_capture_decisions'::regclass
     and a.grantee::regrole::text = 'service_role';
  if v_privs is distinct from array['SELECT'] or v_bad = 'yes' then
    raise exception 'T4A SEC3: service_role table privileges drifted: % grantable=% '
      '(expect exactly SELECT, not grantable)', v_privs, v_bad;
  end if;
  select string_agg(p.grantee || '/' || p.privilege_type, ', ') into v_bad
    from information_schema.table_privileges p
   where p.table_schema = 'public' and p.table_name = 'mt5_capture_decisions'
     and (p.grantee in ('PUBLIC', 'anon', 'authenticated')
          or (p.grantee = 'service_role' and p.privilege_type <> 'SELECT'));
  if v_bad is not null then
    raise exception 'T4A SEC3: information_schema.table_privileges shows unexpected '
      'grants: %', v_bad;
  end if;
end $sec3$;

-- ------------------------------------------------------------------------------------------------
-- SEC4: column surface. Exactly the 7 frozen columns, and NO column-level ACL anywhere
-- (pg_attribute.attacl must be NULL for every live column — a column-level GRANT bypasses
-- table-level revocation and would hide from table-grant views).
-- ------------------------------------------------------------------------------------------------
do $sec4$
declare
  v_cols text[];
  v_bad  text;
begin
  select array_agg(a.attname::text order by a.attnum) into v_cols
    from pg_catalog.pg_attribute a
   where a.attrelid = 'public.mt5_capture_decisions'::regclass
     and a.attnum > 0 and not a.attisdropped;
  if v_cols is distinct from array[
      'id', 'capture_event_id', 'action', 'source',
      'telegram_chat_id', 'telegram_message_id', 'created_at'] then
    raise exception 'T4A SEC4: column set drifted: %', v_cols;
  end if;
  select string_agg(a.attname::text, ', ') into v_bad
    from pg_catalog.pg_attribute a
   where a.attrelid = 'public.mt5_capture_decisions'::regclass
     and a.attnum > 0 and not a.attisdropped
     and a.attacl is not null;
  if v_bad is not null then
    raise exception 'T4A SEC4: column-level ACL present on: % (expect none)', v_bad;
  end if;
end $sec4$;

-- ------------------------------------------------------------------------------------------------
-- SEC5: the immutability trigger, exactly one, exactly as created.
-- tgtype 27 = ROW(1) + BEFORE(2) + DELETE(8) + UPDATE(16). tgenabled 'O' = enabled (origin).
-- ------------------------------------------------------------------------------------------------
do $sec5$
declare
  v_n int;
begin
  select count(*) into v_n from pg_catalog.pg_trigger
   where tgrelid = 'public.mt5_capture_decisions'::regclass and not tgisinternal;
  if v_n <> 1 then
    raise exception 'T4A SEC5: expected exactly one non-internal trigger, found %', v_n;
  end if;
  if not exists (select 1 from pg_catalog.pg_trigger t
                  where t.tgrelid = 'public.mt5_capture_decisions'::regclass
                    and not t.tgisinternal
                    and t.tgname = 'mt5_capture_decision_no_mutate_v1'
                    and t.tgenabled = 'O'
                    and t.tgtype = 27
                    and t.tgfoid = to_regprocedure(
                          'public.mt5_capture_decision_guard_v1()')) then
    raise exception 'T4A SEC5: immutability trigger drifted (name/enabled/type/function)';
  end if;
end $sec5$;

-- ------------------------------------------------------------------------------------------------
-- SEC6: function inventory + definition security bits. For every T4A function, classified:
--   PUBLIC RPC   : mt5_record_capture_decision_v1 (volatile), mt5_next_pending_capture_v1
--                  (stable) — the ONLY service_role-executable surface
--   INTERNAL     : mt5_t3_event_types_v1 / mt5_t3_kind_v1 / mt5_t3_allowed_actions_v1
--                  (immutable helpers), mt5_capture_decision_guard_v1 (volatile trigger guard)
-- Each must be: present with EXACTLY this identity, the ONLY overload of its name (an injected
-- overload with different arguments is an attack, not a variant), owned by postgres,
-- SECURITY DEFINER, expected volatility, and proconfig EXACTLY {search_path=""} — the catalog
-- representation of `set search_path = ''` (pinned from the live catalog, not guessed).
-- ------------------------------------------------------------------------------------------------
do $sec6$
declare
  r record;
  v_oid oid;
  v_n int;
begin
  for r in
    select * from (values
      ('mt5_t3_event_types_v1',          'public.mt5_t3_event_types_v1(jsonb)',          'i'),
      ('mt5_t3_kind_v1',                 'public.mt5_t3_kind_v1(text[])',                'i'),
      ('mt5_t3_allowed_actions_v1',      'public.mt5_t3_allowed_actions_v1(text)',       'i'),
      ('mt5_record_capture_decision_v1',
       'public.mt5_record_capture_decision_v1(uuid,uuid,text,text,bigint,bigint)',       'v'),
      ('mt5_next_pending_capture_v1',    'public.mt5_next_pending_capture_v1(uuid)',     's'),
      ('mt5_capture_decision_guard_v1',  'public.mt5_capture_decision_guard_v1()',       'v')
    ) t(fname, fsig, fvol)
  loop
    v_oid := to_regprocedure(r.fsig);
    if v_oid is null then
      raise exception 'T4A SEC6: % does not exist', r.fsig;
    end if;
    select count(*) into v_n
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.fname;
    if v_n <> 1 then
      raise exception 'T4A SEC6: % has % overloads in public (expect exactly 1 — an extra '
        'overload is an injected function)', r.fname, v_n;
    end if;
    if not exists (select 1 from pg_catalog.pg_proc p
                    where p.oid = v_oid
                      and p.prosecdef
                      and p.provolatile = r.fvol
                      and p.proowner::regrole::text = 'postgres'
                      and p.proconfig is not distinct from array['search_path=""']) then
      raise exception 'T4A SEC6: % drifted (expect SECURITY DEFINER, volatility "%", owner '
        'postgres, proconfig exactly {search_path=""})', r.fsig, r.fvol;
    end if;
  end loop;
  select count(*) into v_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'mt5\_t3\_%';
  if v_n <> 3 then
    raise exception 'T4A SEC6: expected exactly 3 mt5_t3_* helpers in public, found %', v_n;
  end if;
end $sec6$;

-- ------------------------------------------------------------------------------------------------
-- SEC7: function ACLs, from the raw proacl, plus PUBLIC-derived execution probes.
-- proacl must be MATERIALIZED (non-NULL) on all six — NULL would silently re-grant EXECUTE to
-- PUBLIC. Grantees: the two RPCs exactly {postgres, service_role} with service_role privilege
-- exactly EXECUTE (not grantable); the three helpers and the guard exactly {postgres}.
-- has_function_privilege() then proves the derived truth per app role: a role with no direct
-- grant can execute only via PUBLIC, so anon/authenticated must be FALSE on all six, and
-- service_role TRUE on exactly the two RPCs.
-- ------------------------------------------------------------------------------------------------
do $sec7$
declare
  r record;
  v_oid oid;
  v_who text[];
  v_privs text[];
  v_grantable text;
begin
  for r in
    select * from (values
      ('public.mt5_t3_event_types_v1(jsonb)',                                      false),
      ('public.mt5_t3_kind_v1(text[])',                                            false),
      ('public.mt5_t3_allowed_actions_v1(text)',                                   false),
      ('public.mt5_record_capture_decision_v1(uuid,uuid,text,text,bigint,bigint)', true),
      ('public.mt5_next_pending_capture_v1(uuid)',                                 true),
      ('public.mt5_capture_decision_guard_v1()',                                   false)
    ) t(fsig, svc_exec)
  loop
    v_oid := to_regprocedure(r.fsig);
    if (select p.proacl is null from pg_catalog.pg_proc p where p.oid = v_oid) then
      raise exception 'T4A SEC7: % has NULL proacl — the built-in default grants EXECUTE '
        'to PUBLIC', r.fsig;
    end if;
    select array_agg(distinct who order by who) into v_who
      from (select case when a.grantee = 0 then 'PUBLIC'
                        else a.grantee::regrole::text end as who
              from pg_catalog.pg_proc p
              cross join lateral pg_catalog.aclexplode(p.proacl) a
             where p.oid = v_oid) t;
    if r.svc_exec then
      if v_who is distinct from array['postgres', 'service_role'] then
        raise exception 'T4A SEC7: % ACL grantees drifted: % (expect exactly postgres + '
          'service_role)', r.fsig, v_who;
      end if;
      select array_agg(distinct a.privilege_type order by a.privilege_type),
             max(case when a.is_grantable then 'yes' else 'no' end)
        into v_privs, v_grantable
        from pg_catalog.pg_proc p
        cross join lateral pg_catalog.aclexplode(p.proacl) a
       where p.oid = v_oid and a.grantee::regrole::text = 'service_role';
      if v_privs is distinct from array['EXECUTE'] or v_grantable = 'yes' then
        raise exception 'T4A SEC7: % service_role privileges drifted: % grantable=%',
          r.fsig, v_privs, v_grantable;
      end if;
    else
      if v_who is distinct from array['postgres'] then
        raise exception 'T4A SEC7: internal % ACL grantees drifted: % (expect exactly '
          'postgres — helpers/guard are owner-only)', r.fsig, v_who;
      end if;
    end if;
    if pg_catalog.has_function_privilege('anon', v_oid, 'EXECUTE')
       or pg_catalog.has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      raise exception 'T4A SEC7: anon/authenticated can execute % (direct or '
        'PUBLIC-derived)', r.fsig;
    end if;
    if pg_catalog.has_function_privilege('service_role', v_oid, 'EXECUTE')
       is distinct from r.svc_exec then
      raise exception 'T4A SEC7: service_role execute on % is % (expect %)',
        r.fsig, not r.svc_exec, r.svc_exec;
    end if;
  end loop;
end $sec7$;

-- ------------------------------------------------------------------------------------------------
-- SEC8: migration-ledger truth for both T4A versions. Checksums are the packet identity tokens
-- (sha256('<version>|packet-revision-N')); source_artifact_sha256 is the UPPERCASE canonical
-- fixture digest. A row recorded 'applied' with a different checksum means the applied packet
-- and this verifier disagree about the revision — that is drift, not a loosening opportunity.
-- ------------------------------------------------------------------------------------------------
do $sec8$
begin
  if not exists (select 1 from public.mt5_schema_migrations m
                  where m.version = 'mt5_t4a_decisions_schema_v1' and m.status = 'applied'
                    and m.checksum =
                        '66cbfaadfbf759fe66dd4392833b44d6043d69750a55205c5cfcef21b4931012'
                    and m.source_artifact_sha256 =
                        '85C076D09738D4F3189E54E2B33F6348ADA205304291FD59B4801A8F2E629355') then
    raise exception 'T4A SEC8: ledger row for mt5_t4a_decisions_schema_v1 missing or drifted';
  end if;
  if not exists (select 1 from public.mt5_schema_migrations m
                  where m.version = 'mt5_t4a_decisions_rpc_v1' and m.status = 'applied'
                    and m.checksum =
                        '3f4fbed1176f607b2697e0ea98c2a078d0e8dd8229b6505fd54c398561801853'
                    and m.source_artifact_sha256 =
                        '85C076D09738D4F3189E54E2B33F6348ADA205304291FD59B4801A8F2E629355') then
    raise exception 'T4A SEC8: ledger row for mt5_t4a_decisions_rpc_v1 missing or drifted '
      '(expect packet revision 2 identity token)';
  end if;
  raise notice 'T4A SECURITY SURFACE VERIFICATION: ALL SECTIONS PASS';
end $sec8$;

rollback;
