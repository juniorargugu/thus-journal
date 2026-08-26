-- ================================================================================================
-- READ-ONLY PRODUCTION VERIFIER — T4B JOURNAL PROMOTION (packet revision 6)
--
-- Opens a READ ONLY transaction, asserts the deployed security and schema contract, and rolls
-- back. It seeds nothing, calls no promotion, and writes nothing anywhere. Safe to run against
-- production at any time, as often as wanted.
--
-- WHAT CHANGED IN REVISION 2, AND WHY. Revision 1 checked objects by NAME, COUNT and TYPE: "a
-- unique constraint called mt5_cp_position_uk exists", "there is exactly one trigger", "the
-- search_path setting contains search_path=". None of that survives contact with an adversary or
-- with a careless migration — a same-named constraint over the wrong columns, a same-named no-op
-- trigger, or 'search_path=public, pg_temp, evil' all passed. Every check below now pins the
-- EXACT DEPLOYED DEFINITION from the catalog: pg_get_constraintdef, conkey/confkey resolved to
-- column names, pg_get_indexdef, trigger timing/events/enabled-state/function, proargtypes,
-- output column names and types, exact proconfig, and ACL ALLOWLISTS built from aclexplode rather
-- than a denylist of role names somebody remembered to write down.
--
-- This is also the deployed-object drift detector required by the migration contract: the ledger
-- row saying "applied" is not evidence, so a modified constraint, function, trigger or grant fails
-- here even when the ledger row is untouched.
--
-- RUN: psql -v ON_ERROR_STOP=1 -f T4B_promotion_security_verification_packet.sql
-- ================================================================================================

\set ON_ERROR_STOP on

begin transaction read only;

do $sec$
declare
  v_fail   text[] := array[]::text[];
  v_txt    text;
  v_txt2   text;
  v_n      integer;
  v_oid    oid;
  v_rel    oid;

  -- ACL allowlists: object -> the ONLY (grantee, privilege) pairs that may exist. The table owner
  -- is expected to retain its own privileges; PostgreSQL grants them implicitly and removing them
  -- would break the SECURITY DEFINER functions themselves.
  v_owner  text;
  v_acl    text[];
  v_allow  text[];

  procedure_names text[] := array[
    'mt5_promote_capture_decision_v1',
    'mt5_t4b_map_product_v1',
    'mt5_t4b_validate_fulfillment_v1',
    'mt5_t4b_freshness_window_v1'];
  v_fn      text;
  v_ver     text;
  v_want    text[];
  v_have    text[];

  -- EXACT expected migration identities, stamped by T4B_packet_identity.py --write from the
  -- packet bytes on disk. Never hand-edited. This verifier is not itself covered by the canonical
  -- digest, so stamping it introduces no circularity.
  exp_schema_checksum constant text := '307642904e3ba280c8cd555ee09e11ddfd07e3d3f48b1aba5be8181d5aefda2e';  -- T4B_EXPECT_SCHEMA_CHECKSUM
  exp_rpc_checksum    constant text := 'b2bcf6d310f50bc21c6536298543eea4bd080256952ad9c0994608cdc0127d63';  -- T4B_EXPECT_RPC_CHECKSUM
  exp_contract_digest constant text := 'FF3B6F6789A1E5127E11B8C1650BCD745FF375C9A6CB69823D459EAD03084E2B';  -- T4B_EXPECT_CONTRACT_DIGEST
begin
  -- ============================================================================================
  -- SEC1 — the objects exist at all
  -- ============================================================================================
  if to_regclass('public.mt5_capture_promotions') is null then
    raise exception 'SEC1 FAIL: public.mt5_capture_promotions does not exist — T4B is not deployed';
  end if;
  v_rel := 'public.mt5_capture_promotions'::regclass;

  select pg_get_userbyid(c.relowner)::text into v_owner
    from pg_catalog.pg_class c where c.oid = v_rel;
  if v_owner is distinct from 'postgres' then
    v_fail := v_fail || format('SEC1: promotion ledger owner is %s, expected postgres', v_owner);
  end if;
  if not (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = v_rel) then
    v_fail := v_fail || 'SEC1: row level security is not enabled on the promotion ledger'::text;
  end if;

  -- ============================================================================================
  -- SEC2 — EXACT column set of the ledger (10 frozen columns, exact types, exact nullability)
  -- ============================================================================================
  select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
                    || case when a.attnotnull then ' NOT NULL' else ' NULL' end, ', '
                    order by a.attnum)
    into v_txt
    from pg_catalog.pg_attribute a
   where a.attrelid = v_rel and a.attnum > 0 and not a.attisdropped;
  if v_txt is distinct from
     'id uuid NOT NULL, decision_id uuid NOT NULL, capture_event_id uuid NOT NULL, '
     'trade_id text NOT NULL, user_id uuid NOT NULL, source_account text NOT NULL, '
     'position_id bigint NOT NULL, basis_run_id uuid NOT NULL, fresh_run_id uuid NOT NULL, '
     'created_at timestamp with time zone NOT NULL' then
    v_fail := v_fail || format('SEC2: ledger columns are not the frozen shape: %s', v_txt);
  end if;

  -- ============================================================================================
  -- SEC3 — EXACT constraint definitions. A same-named constraint over the wrong columns FAILS.
  -- ============================================================================================
  -- The complete constraint inventory, definition by definition. Nothing extra may exist either:
  -- an added constraint is as much a contract change as a removed one.
  select string_agg(c.conname || ' := ' || pg_get_constraintdef(c.oid), E'\n        '
                    order by c.conname)
    into v_txt
    from pg_catalog.pg_constraint c where c.conrelid = v_rel;
  if v_txt is distinct from
     'mt5_capture_promotions_pkey := PRIMARY KEY (id)' || E'\n        ' ||
     'mt5_cp_account_nonblank_chk := CHECK ((btrim(source_account) <> ''''::text))' || E'\n        ' ||
     'mt5_cp_basis_run_fk := FOREIGN KEY (basis_run_id, user_id, source_account) '
       'REFERENCES mt5_sync_runs(id, user_id, source_account)' || E'\n        ' ||
     'mt5_cp_capture_fk := FOREIGN KEY (capture_event_id) REFERENCES mt5_capture_events(id)'
       || E'\n        ' ||
     'mt5_cp_decision_fk := FOREIGN KEY (decision_id) REFERENCES mt5_capture_decisions(id)'
       || E'\n        ' ||
     'mt5_cp_decision_uk := UNIQUE (decision_id)' || E'\n        ' ||
     'mt5_cp_fresh_run_fk := FOREIGN KEY (fresh_run_id, user_id, source_account) '
       'REFERENCES mt5_sync_runs(id, user_id, source_account)' || E'\n        ' ||
     'mt5_cp_position_uk := UNIQUE (user_id, source_account, position_id)' || E'\n        ' ||
     'mt5_cp_trade_id_shape_chk := CHECK ((trade_id ~ ''^mt5p_[0-9a-f]{32}$''::text))'
       || E'\n        ' ||
     'mt5_cp_trade_uk := UNIQUE (trade_id)' then
    v_fail := v_fail || format('SEC3: ledger constraint definitions differ from the frozen '
                               'contract:%s        %s', E'\n', v_txt);
  end if;

  -- SEC3b — the same facts again through conkey/confkey resolved to column NAMES, so a definition
  -- string that merely renders identically cannot hide a different underlying column set.
  select string_agg(c.conname || ' local(' || l.cols || ') -> ' || c.confrelid::regclass::text
                    || '(' || f.cols || ')', E'\n        ' order by c.conname)
    into v_txt
    from pg_catalog.pg_constraint c
    cross join lateral (
      select string_agg(a.attname, ',' order by k.ord) as cols
        from unnest(c.conkey) with ordinality k(attnum, ord)
        join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) l
    cross join lateral (
      select string_agg(a.attname, ',' order by k.ord) as cols
        from unnest(c.confkey) with ordinality k(attnum, ord)
        join pg_catalog.pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) f
   where c.conrelid = v_rel and c.contype = 'f';
  if v_txt is distinct from
     'mt5_cp_basis_run_fk local(basis_run_id,user_id,source_account) -> '
       'mt5_sync_runs(id,user_id,source_account)' || E'\n        ' ||
     'mt5_cp_capture_fk local(capture_event_id) -> mt5_capture_events(id)' || E'\n        ' ||
     'mt5_cp_decision_fk local(decision_id) -> mt5_capture_decisions(id)' || E'\n        ' ||
     'mt5_cp_fresh_run_fk local(fresh_run_id,user_id,source_account) -> '
       'mt5_sync_runs(id,user_id,source_account)' then
    v_fail := v_fail || format('SEC3b: foreign-key column mapping differs:%s        %s',
                               E'\n', v_txt);
  end if;

  -- SEC3c — and the unique axes resolved to column names, in order.
  select string_agg(c.conname || '(' || l.cols || ')', ' ' order by c.conname) into v_txt
    from pg_catalog.pg_constraint c
    cross join lateral (
      select string_agg(a.attname, ',' order by k.ord) as cols
        from unnest(c.conkey) with ordinality k(attnum, ord)
        join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) l
   where c.conrelid = v_rel and c.contype = 'u';
  if v_txt is distinct from
     'mt5_cp_decision_uk(decision_id) mt5_cp_position_uk(user_id,source_account,position_id) '
     'mt5_cp_trade_uk(trade_id)' then
    v_fail := v_fail || format('SEC3c: uniqueness axes are not over the exact promised columns '
                               'in the exact promised order: %s', v_txt);
  end if;

  -- SEC3d — NO foreign key to public.trades, in either direction of intent.
  if exists (select 1 from pg_catalog.pg_constraint
              where conrelid = v_rel and contype = 'f'
                and confrelid = 'public.trades'::regclass) then
    v_fail := v_fail || 'SEC3d: a foreign key to public.trades exists — it would either block '
                        'ordinary trade deletion or cascade away provenance'::text;
  end if;

  -- ============================================================================================
  -- SEC4 — EXACT index definitions. A same-named index over a different expression FAILS.
  -- ============================================================================================
  select string_agg(pg_get_indexdef(i.indexrelid), E'\n        '
                    order by i.indexrelid::regclass::text)
    into v_txt
    from pg_catalog.pg_index i where i.indrelid = v_rel;
  if v_txt is distinct from
     'CREATE UNIQUE INDEX mt5_capture_promotions_pkey ON public.mt5_capture_promotions '
       'USING btree (id)' || E'\n        ' ||
     'CREATE UNIQUE INDEX mt5_cp_decision_uk ON public.mt5_capture_promotions USING btree '
       '(decision_id)' || E'\n        ' ||
     'CREATE UNIQUE INDEX mt5_cp_position_uk ON public.mt5_capture_promotions USING btree '
       '(user_id, source_account, position_id)' || E'\n        ' ||
     'CREATE UNIQUE INDEX mt5_cp_trade_uk ON public.mt5_capture_promotions USING btree (trade_id)'
  then
    v_fail := v_fail || format('SEC4: ledger indexes differ from the frozen set:%s        %s',
                               E'\n', v_txt);
  end if;

  -- The incarnation index on public.trades, pinned exactly including its partial predicate.
  if to_regclass('public.mt5_trades_promotion_uk') is null then
    v_fail := v_fail || 'SEC4b: mt5_trades_promotion_uk does not exist'::text;
  else
    select pg_get_indexdef('public.mt5_trades_promotion_uk'::regclass) into v_txt;
    if v_txt is distinct from
       'CREATE UNIQUE INDEX mt5_trades_promotion_uk ON public.trades USING btree '
       '(mt5_promotion_id) WHERE (mt5_promotion_id IS NOT NULL)' then
      v_fail := v_fail || format('SEC4b: mt5_trades_promotion_uk is not the promised partial '
                                 'unique index: %s', v_txt);
    end if;
  end if;

  -- ============================================================================================
  -- SEC5 — EXACT trigger definitions. A no-op replacement with the same name FAILS.
  -- ============================================================================================
  -- Ledger immutability guard.
  select string_agg(t.tgname || ' [' || t.tgenabled::text || '] := ' || pg_get_triggerdef(t.oid),
                    E'\n        ' order by t.tgname)
    into v_txt
    from pg_catalog.pg_trigger t where t.tgrelid = v_rel and not t.tgisinternal;
  if v_txt is distinct from
     'mt5_capture_promotion_no_mutate_v1 [O] := CREATE TRIGGER '
     'mt5_capture_promotion_no_mutate_v1 BEFORE DELETE OR UPDATE ON '
     'public.mt5_capture_promotions FOR EACH ROW EXECUTE FUNCTION '
     'mt5_capture_promotion_guard_v1()' then
    v_fail := v_fail || format('SEC5: ledger immutability trigger is not the frozen definition '
                               '(or is disabled): %s', v_txt);
  end if;

  -- Trades incarnation guard.
  select string_agg(t.tgname || ' [' || t.tgenabled::text || '] := ' || pg_get_triggerdef(t.oid),
                    E'\n        ' order by t.tgname)
    into v_txt
    from pg_catalog.pg_trigger t
   where t.tgrelid = 'public.trades'::regclass and not t.tgisinternal
     and t.tgname = 'mt5_trades_incarnation_guard_v1';
  if v_txt is distinct from
     'mt5_trades_incarnation_guard_v1 [O] := CREATE TRIGGER mt5_trades_incarnation_guard_v1 '
     'BEFORE INSERT OR UPDATE OF mt5_promotion_id ON public.trades FOR EACH ROW EXECUTE '
     'FUNCTION mt5_trades_incarnation_guard_v1()' then
    v_fail := v_fail || format('SEC5b: trades incarnation guard is not the frozen definition '
                               '(or is disabled): %s', v_txt);
  end if;

  -- A trigger whose FUNCTION BODY was replaced by a no-op keeps its definition string. Pin the
  -- behaviour too: both guard bodies must still raise.
  select regexp_replace(p.prosrc, '--[^
]*', '', 'g') into v_txt from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'mt5_capture_promotion_guard_v1';
  if v_txt is null or v_txt not like '%MT5_T4B_IMMUTABLE_ROW%' or v_txt not like '%raise exception%'
  then
    v_fail := v_fail || 'SEC5c: mt5_capture_promotion_guard_v1 no longer raises '
                        'MT5_T4B_IMMUTABLE_ROW — a same-named no-op would pass a name-only check'::text;
  end if;
  select regexp_replace(p.prosrc, '--[^
]*', '', 'g') into v_txt from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'mt5_trades_incarnation_guard_v1';
  if v_txt is null
     or v_txt not like '%MT5_T4B_FORGED_INCARNATION%'
     or v_txt not like '%MT5_T4B_IMMUTABLE_INCARNATION%'
     or v_txt not like '%mt5_capture_promotions%' then
    v_fail := v_fail || 'SEC5d: mt5_trades_incarnation_guard_v1 no longer enforces both the '
                        'forge check and the immutability check'::text;
  end if;

  -- ============================================================================================
  -- SEC6 — the incarnation COLUMN on public.trades: exact type, nullability, no default
  -- ============================================================================================
  select a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
         || case when a.attnotnull then ' NOT NULL' else ' NULL' end
         || ' default=' || coalesce(pg_get_expr(d.adbin, d.adrelid), '<none>')
    into v_txt
    from pg_catalog.pg_attribute a
    left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = 'public.trades'::regclass and a.attname = 'mt5_promotion_id'
     and not a.attisdropped;
  if v_txt is distinct from 'mt5_promotion_id uuid NULL default=<none>' then
    v_fail := v_fail || format('SEC6: trades.mt5_promotion_id is not the frozen definition: %s',
                               coalesce(v_txt, '<missing>'));
  end if;

  -- ============================================================================================
  -- SEC7 — EXACT function contracts: single overload, owner, security, volatility, argument
  --        types, output column names AND types, and the EXACT search_path.
  -- ============================================================================================
  foreach v_fn in array procedure_names loop
    select count(*) into v_n
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_n <> 1 then
      v_fail := v_fail || format('SEC7: %s has %s overloads, expected exactly 1 — a wider variant '
                                 'may have been smuggled alongside it', v_fn, v_n);
      continue;
    end if;

    select p.oid,
           pg_get_userbyid(p.proowner)::text || '|'
           || case when p.prosecdef then 'DEFINER' else 'INVOKER' end || '|'
           || p.provolatile::text || '|'
           || coalesce(array_to_string(p.proconfig, ';'), '<none>') || '|'
           || coalesce((select string_agg(t.typname, ',' order by k.ord)
                          from unnest(p.proargtypes) with ordinality k(oid, ord)
                          join pg_catalog.pg_type t on t.oid = k.oid), '<none>')
      into v_oid, v_txt
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;

    v_txt2 := case v_fn
      -- owner | security | volatility | proconfig | IN argument types
      when 'mt5_promote_capture_decision_v1'  then 'postgres|DEFINER|v|search_path=public, pg_temp|uuid'
      when 'mt5_t4b_map_product_v1'           then 'postgres|DEFINER|s|search_path=public, pg_temp|uuid,text,numeric'
      when 'mt5_t4b_validate_fulfillment_v1'  then 'postgres|DEFINER|s|search_path=public, pg_temp|uuid,text,uuid'
      when 'mt5_t4b_freshness_window_v1'      then 'postgres|DEFINER|i|search_path=public, pg_temp|<none>'
    end;
    if v_txt is distinct from v_txt2 then
      v_fail := v_fail || format('SEC7: %s contract drift%s          deployed %s%s          frozen   %s',
                                 v_fn, E'\n', v_txt, E'\n', v_txt2);
    end if;
  end loop;

  -- SEC7b — the promotion RPC's OUTPUT columns: exact names, exact types, exact order. The result
  -- contract is as much a security boundary as the input one; a renamed or added output column
  -- would silently change what a caller reads.
  select string_agg(n.name || ' ' || t.typname, ', ' order by n.ord) into v_txt
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace ns on ns.oid = p.pronamespace
   cross join lateral unnest(p.proargnames) with ordinality n(name, ord)
   cross join lateral unnest(p.proallargtypes) with ordinality a(oid, ord2)
    join pg_catalog.pg_type t on t.oid = a.oid
   where ns.nspname = 'public' and p.proname = 'mt5_promote_capture_decision_v1'
     and n.ord = a.ord2
     and p.proargmodes[n.ord] = 't';
  if v_txt is distinct from
     'o_ok bool, o_inserted int4, o_promotion_id uuid, o_trade_id text, '
     'o_existing_decision_id uuid, o_error_code text' then
    v_fail := v_fail || format('SEC7b: promotion RPC result columns are not the frozen six: %s',
                               coalesce(v_txt, '<none>'));
  end if;

  -- SEC7c — the freshness window value itself is part of the contract.
  if public.mt5_t4b_freshness_window_v1() <> interval '7200 seconds' then
    v_fail := v_fail || 'SEC7c: the freshness window is not the frozen 7200 seconds'::text;
  end if;

  -- ============================================================================================
  -- SEC7i — EXACT DEPLOYED BODIES.
  --
  -- Everything above this point is metadata, and metadata says nothing about behaviour. A
  -- validator replaced by `select true`, a product mapper returning an arbitrary product, or a
  -- guard whose raise now sits in an unreachable branch would keep its signature, owner, security
  -- flag, volatility, search_path and ACLs — and pass every other check in SEC7. The apply packets
  -- record sha256(pg_get_functiondef()) for all six T4B functions in the migration ledger, keyed
  -- by full identity signature; this asserts each version's EXACT inventory, resolves every key
  -- through to_regprocedure, and demands exact digest equality.
  --
  -- (A PostgreSQL major-version upgrade can re-render pg_get_functiondef. If that ever fires after
  -- an upgrade with no other evidence of tampering, re-verify the packet identity and re-record.)
  -- ============================================================================================
  -- The INVENTORY first, per version, as an EXACT set. A count is not an inventory: replacing a
  -- required key with an unrelated deployed function and recording ITS correct digest keeps the
  -- total at six, and the T4B body that was dropped out of the set then goes unverified forever.
  -- Each name is a full identity signature, so a same-named overload is a different key.
  for v_ver, v_want in
    select * from (values
      ('mt5_t4b_promotion_schema_v1',
       array['public.mt5_capture_promotion_guard_v1()',
             'public.mt5_trades_incarnation_guard_v1()']),
      ('mt5_t4b_promotion_rpc_v1',
       array['public.mt5_promote_capture_decision_v1(uuid)',
             'public.mt5_t4b_freshness_window_v1()',
             'public.mt5_t4b_map_product_v1(uuid, text, numeric)',
             'public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid)'])
    ) as t(ver, want)
  loop
    select coalesce(array_agg(k order by k), array[]::text[]) into v_have
      from public.mt5_schema_migrations m,
           lateral jsonb_object_keys(m.objects->'function_digests') k
     where m.version = v_ver;
    if v_have is distinct from (select array_agg(w order by w) from unnest(v_want) w) then
      v_fail := v_fail || format('SEC7i: %s records the wrong function inventory%s'
                                 '          recorded %s%s          expected %s',
                                 v_ver, E'\n', v_have::text, E'\n', v_want::text);
    end if;

    -- ...then the body of each REQUIRED function, resolved through to_regprocedure so the digest
    -- is compared against the exact overload the contract names rather than whatever happens to
    -- share its bare proname. The loop walks the EXPECTED list, never the recorded keys: a
    -- required function whose key was renamed or removed then reports a missing digest here as
    -- well as an inventory mismatch above, and no ledger-supplied text is ever fed to
    -- to_regprocedure (a malformed key would raise rather than report).
    foreach v_fn in array v_want
    loop
      v_oid := to_regprocedure(v_fn);
      select m.objects->'function_digests'->>v_fn into v_txt2
        from public.mt5_schema_migrations m where m.version = v_ver;
      if v_oid is null then
        v_fail := v_fail || format('SEC7i: %s is required by %s but is not deployed', v_fn, v_ver);
      elsif v_txt2 is null then
        v_fail := v_fail || format('SEC7i: %s has no recorded body digest in %s', v_fn, v_ver);
      else
        select encode(sha256(convert_to(pg_get_functiondef(v_oid), 'UTF8')), 'hex') into v_txt;
        if v_txt is distinct from v_txt2 then
          v_fail := v_fail || format('SEC7i: %s BODY has changed since it was applied%s'
                                     '          deployed %s%s          recorded %s',
                                     v_fn, E'\n', v_txt, E'\n', v_txt2);
        end if;
      end if;
    end loop;
  end loop;

  -- SEC7d — the promotion body must still be the shape the contract describes: wall-clock
  -- eligibility, constraint-aware uniqueness, no blanket handler, reserved namespace minting.
  -- COMMENTS STRIPPED FIRST. prosrc carries them, and this packet's own disclaimer names the
  -- very token SEC7f looks for; a raw substring scan would fail against a perfectly clean
  -- function. Only executable source is examined.
  select regexp_replace(p.prosrc, '--[^
]*', '', 'g') into v_txt
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'mt5_promote_capture_decision_v1';
  if v_txt is null then
    v_fail := v_fail || 'SEC7d: the promotion RPC body could not be read'::text;
  else
    if v_txt not like '%clock_timestamp()%' then
      v_fail := v_fail || 'SEC7d: the promotion RPC no longer captures a wall-clock eligibility '
                          'instant — transaction-start time survives a long lock wait'::text;
    end if;
    if v_txt not like '%get stacked diagnostics%' then
      v_fail := v_fail || 'SEC7e: the promotion RPC no longer reads CONSTRAINT_NAME — a blanket '
                          'unique_violation handler guesses'::text;
    end if;
    if v_txt ilike '%when others%' then
      v_fail := v_fail || 'SEC7f: a `when others` handler appeared in the promotion RPC'::text;
    end if;
    if v_txt not like '%mt5p_%' then
      v_fail := v_fail || 'SEC7g: the promotion RPC no longer mints into the reserved namespace'::text;
    end if;
    if v_txt not like '%mt5_t4b_validate_fulfillment_v1%' then
      v_fail := v_fail || 'SEC7h: the promotion RPC no longer routes replay through the shared '
                          'incarnation validator'::text;
    end if;
  end if;

  -- ============================================================================================
  -- SEC8 — ACL ALLOWLISTS. Every grantee actually present is enumerated and compared against the
  --        explicit allowlist. An UNEXPECTED role fails, whether or not anybody predicted it.
  -- ============================================================================================
  -- Table: only the owner and service_role-SELECT.
  select coalesce(array_agg(g || ':' || p order by g, p), array[]::text[]) into v_acl
    from (select case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as g,
                 a.privilege_type as p
            from pg_catalog.pg_class c,
                 lateral aclexplode(c.relacl) a
           where c.oid = v_rel) x;
  v_allow := array['postgres:DELETE','postgres:INSERT','postgres:MAINTAIN','postgres:REFERENCES',
                   'postgres:SELECT','postgres:TRIGGER','postgres:TRUNCATE','postgres:UPDATE',
                   'service_role:SELECT'];
  select coalesce(array_agg(e order by e), array[]::text[]) into v_acl
    from unnest(v_acl) e where e <> all (v_allow);
  if array_length(v_acl, 1) is not null then
    v_fail := v_fail || format('SEC8: promotion ledger carries grants outside the allowlist: %s',
                               array_to_string(v_acl, ', '));
  end if;
  -- A NULL relacl means "owner defaults" and is acceptable; an explicitly PUBLIC-granted table is
  -- not, and is caught above because PUBLIC is not on the allowlist.

  -- COLUMN-level grants live in pg_attribute.attacl, NOT in relacl, so a table-ACL allowlist alone
  -- cannot see `grant select (trade_id) ... to authenticated`. attacl is NULL on every column of a
  -- table nobody has column-granted, which is the only acceptable state here.
  select coalesce(array_agg(a.attname || '.' || g || ':' || p order by a.attname, g, p),
                  array[]::text[])
    into v_acl
    from pg_catalog.pg_attribute a,
         lateral aclexplode(a.attacl) x,
         lateral (select case when x.grantee = 0 then 'PUBLIC'
                              else x.grantee::regrole::text end as g,
                         x.privilege_type as p) y
   where a.attrelid = v_rel and a.attnum > 0 and not a.attisdropped
     and y.g <> 'postgres';
  if array_length(v_acl, 1) is not null then
    v_fail := v_fail || format('SEC8e: the promotion ledger carries COLUMN-level grants: %s',
                               array_to_string(v_acl, ', '));
  end if;

  -- and the same for the incarnation column on public.trades: the Journal's existing table-level
  -- grants are deliberately left alone, but nobody may be column-granted on the marker.
  select coalesce(array_agg(g || ':' || p order by g, p), array[]::text[]) into v_acl
    from pg_catalog.pg_attribute a,
         lateral aclexplode(a.attacl) x,
         lateral (select case when x.grantee = 0 then 'PUBLIC'
                              else x.grantee::regrole::text end as g,
                         x.privilege_type as p) y
   where a.attrelid = 'public.trades'::regclass and a.attname = 'mt5_promotion_id'
     and y.g <> 'postgres';
  if array_length(v_acl, 1) is not null then
    v_fail := v_fail || format('SEC8f: trades.mt5_promotion_id carries COLUMN-level grants: %s',
                               array_to_string(v_acl, ', '));
  end if;

  -- Functions: helpers are executable by the owner only; the promotion RPC adds service_role.
  foreach v_fn in array procedure_names loop
    select p.oid into v_oid
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_oid is null then
      continue;
    end if;

    -- A NULL proacl is NOT "no grants" — it is the default, which is EXECUTE to PUBLIC.
    if (select p.proacl is null from pg_catalog.pg_proc p where p.oid = v_oid) then
      v_fail := v_fail || format('SEC8b: %s has a NULL proacl, i.e. EXECUTE to PUBLIC by default',
                                 v_fn);
      continue;
    end if;

    select coalesce(array_agg(g || ':' || p order by g, p), array[]::text[]) into v_acl
      from (select case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as g,
                   a.privilege_type as p
              from pg_catalog.pg_proc pr, lateral aclexplode(pr.proacl) a
             where pr.oid = v_oid) x;

    v_allow := case when v_fn = 'mt5_promote_capture_decision_v1'
                    then array['postgres:EXECUTE', 'service_role:EXECUTE']
                    else array['postgres:EXECUTE'] end;
    select coalesce(array_agg(e order by e), array[]::text[]) into v_acl
      from unnest(v_acl) e where e <> all (v_allow);
    if array_length(v_acl, 1) is not null then
      v_fail := v_fail || format('SEC8c: %s carries EXECUTE grants outside the allowlist: %s',
                                 v_fn, array_to_string(v_acl, ', '));
    end if;
  end loop;

  -- SEC8-REQUIRED — the allowlist checks above are one-sided: they reject grants outside the
  -- allowlist but say nothing about grants that went MISSING. Revoking service_role's SELECT on
  -- the ledger, or its EXECUTE on the promotion RPC, leaves a strict subset of the allowlist and
  -- would have passed. These are effective-privilege assertions (has_*_privilege resolves role
  -- membership and PUBLIC), which is also why they are not simple set equality: the owner's own
  -- implicit privilege set differs between PostgreSQL majors and is not part of the contract.
  if to_regrole('service_role') is not null then
    if not has_table_privilege('service_role', 'public.mt5_capture_promotions', 'SELECT') then
      v_fail := v_fail || 'SEC8g: service_role has LOST SELECT on the promotion ledger'::text;
    end if;
    if not has_function_privilege('service_role',
           'public.mt5_promote_capture_decision_v1(uuid)', 'EXECUTE') then
      v_fail := v_fail || 'SEC8h: service_role has LOST EXECUTE on the promotion RPC — no caller '
                          'can promote'::text;
    end if;
  else
    v_fail := v_fail || 'SEC8g: the service_role role does not exist'::text;
  end if;
  -- The definer must retain EXECUTE on its own helpers, or the RPC cannot call them.
  foreach v_fn in array procedure_names loop
    if not has_function_privilege(v_owner, format('public.%I', v_fn) ||
         case v_fn when 'mt5_promote_capture_decision_v1'  then '(uuid)'
                   when 'mt5_t4b_map_product_v1'           then '(uuid, text, numeric)'
                   when 'mt5_t4b_validate_fulfillment_v1'  then '(uuid, text, uuid)'
                   else '()' end, 'EXECUTE') then
      v_fail := v_fail || format('SEC8i: the owner has LOST EXECUTE on %s — the definer chain is '
                                 'broken', v_fn);
    end if;
  end loop;

  -- SEC8j — THE INCARNATION MARKER MUST NOT BE CLIENT-WRITABLE.
  --
  -- This is the privilege that actually makes the marker unforgeable. The guard trigger cannot do
  -- it alone: an owner who can write the column can delete their promoted trade and re-insert the
  -- SAME (id, user_id, mt5_promotion_id) tuple, which the guard legitimately accepts because that
  -- tuple really does match its ledger row. has_column_privilege is used deliberately instead of
  -- reading attacl: only the effective check resolves role membership, inherited grants and
  -- PUBLIC. Superusers are excluded — they bypass privilege checks by definition — and so are
  -- PostgreSQL's predefined administrative roles (reserved pg_ prefix; pg_write_all_data holds
  -- INSERT/UPDATE on every table by design). The threat model is the Journal's client roles.
  for v_fn in
    select rolname from pg_catalog.pg_roles
     where not rolsuper and rolname not like 'pg\_%' and rolname <> v_owner
  loop
    if has_column_privilege(v_fn, 'public.trades', 'mt5_promotion_id', 'INSERT') then
      v_fail := v_fail || format('SEC8j: role %s can INSERT trades.mt5_promotion_id — the '
                                 'incarnation marker is forgeable', v_fn);
    end if;
    if has_column_privilege(v_fn, 'public.trades', 'mt5_promotion_id', 'UPDATE') then
      v_fail := v_fail || format('SEC8k: role %s can UPDATE trades.mt5_promotion_id', v_fn);
    end if;
  end loop;

  -- ...while the columns the Journal app actually writes must STILL be writable, or T4B has
  -- broken the app it is supposed to leave alone.
  if to_regrole('authenticated') is not null then
    foreach v_txt in array array['id', 'user_id', 'product_id', 'direction', 'status', 'contracts',
                                 'remaining_contracts', 'entry_price', 'exit_price', 'entry_date',
                                 'exit_date', 'note', 'raw'] loop
      if not has_column_privilege('authenticated', 'public.trades', v_txt, 'INSERT')
         or not has_column_privilege('authenticated', 'public.trades', v_txt, 'UPDATE') then
        v_fail := v_fail || format('SEC8l: authenticated has LOST write access to trades.%s — the '
                                   'narrowing was too wide', v_txt);
      end if;
    end loop;
  end if;

  -- The two trigger guard functions are never called directly by anyone.
  foreach v_fn in array array['mt5_capture_promotion_guard_v1',
                              'mt5_trades_incarnation_guard_v1'] loop
    select p.oid into v_oid
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_oid is null then
      v_fail := v_fail || format('SEC8d: %s is missing', v_fn);
      continue;
    end if;
    if (select p.proacl is null from pg_catalog.pg_proc p where p.oid = v_oid) then
      v_fail := v_fail || format('SEC8d: %s has a NULL proacl (EXECUTE to PUBLIC)', v_fn);
      continue;
    end if;
    select coalesce(array_agg(g || ':' || p order by g, p), array[]::text[]) into v_acl
      from (select case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as g,
                   a.privilege_type as p
              from pg_catalog.pg_proc pr, lateral aclexplode(pr.proacl) a
             where pr.oid = v_oid) x;
    select coalesce(array_agg(e order by e), array[]::text[]) into v_acl
      from unnest(v_acl) e where e <> all (array['postgres:EXECUTE']);
    if array_length(v_acl, 1) is not null then
      v_fail := v_fail || format('SEC8d: %s carries EXECUTE grants outside the allowlist: %s',
                                 v_fn, array_to_string(v_acl, ', '));
    end if;
  end loop;

  -- ============================================================================================
  -- SEC8m — OWNER ATTRIBUTION on public.trades. T4B narrows this table's write surface by
  -- revoking and re-granting as the owner, and its rollback restores it the same way. Both are
  -- only possible while every non-owner INSERT/UPDATE entry is owner-granted: PostgreSQL refuses
  -- to revoke a grant whose option has been exercised, and a grant rooted in another grantor
  -- cannot be rebuilt by a packet running as the owner. This is the production-side assertion of
  -- the invariant the apply preflight enforces at install time.
  select string_agg(d.txt, ', ' order by d.txt) into v_txt from (
    select format('%s -> %s (%s)', x.grantor::regrole::text,
                  case when x.grantee = 0 then 'PUBLIC' else x.grantee::regrole::text end,
                  x.privilege_type) as txt
      from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
     where c.oid = 'public.trades'::regclass
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> c.relowner and x.grantor <> c.relowner
    union
    select format('%s -> %s (%s on column %s)', x.grantor::regrole::text,
                  case when x.grantee = 0 then 'PUBLIC' else x.grantee::regrole::text end,
                  x.privilege_type, a.attname) as txt
      from pg_catalog.pg_attribute a, lateral aclexplode(a.attacl) x
     where a.attrelid = 'public.trades'::regclass and a.attnum > 0 and not a.attisdropped
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> (select c.relowner from pg_catalog.pg_class c
                          where c.oid = 'public.trades'::regclass)
       and x.grantor <> (select c.relowner from pg_catalog.pg_class c
                          where c.oid = 'public.trades'::regclass)
  ) d;
  if v_txt is not null then
    v_fail := v_fail || format('SEC8m: public.trades carries INSERT/UPDATE privileges granted by '
                               'someone other than its owner (%s) — the T4B rollback could not '
                               'revoke them', v_txt);
  end if;

  -- SEC9 — RLS policy inventory: exactly one policy, exactly as promised.
  -- ============================================================================================
  select string_agg(pol.polname || '|' || pol.polcmd::text || '|'
                    || coalesce((select string_agg(r.rolname, ',' order by r.rolname)
                                   from unnest(pol.polroles) pr
                                   join pg_catalog.pg_roles r on r.oid = pr), 'PUBLIC')
                    || '|' || coalesce(pg_get_expr(pol.polqual, pol.polrelid), '<none>'),
                    E'\n        ' order by pol.polname)
    into v_txt
    from pg_catalog.pg_policy pol where pol.polrelid = v_rel;
  if v_txt is distinct from 'mt5_cp_service_read_v1|r|service_role|true' then
    v_fail := v_fail || format('SEC9: RLS policies on the promotion ledger are not the frozen '
                               'single service_role SELECT policy: %s', coalesce(v_txt, '<none>'));
  end if;

  -- ============================================================================================
  -- SEC10 — migration provenance and deployed-object agreement
  -- ============================================================================================
  select count(*) into v_n from public.mt5_schema_migrations
   where version in ('mt5_t4b_promotion_schema_v1', 'mt5_t4b_promotion_rpc_v1')
     and status = 'applied';
  if v_n <> 2 then
    v_fail := v_fail || format('SEC10: expected both T4B ledger rows applied, found %s', v_n);
  end if;
  -- The ledger rows must claim revision 6 objects. A row from an earlier revision beside
  -- revision-6 objects (or the reverse) is exactly the drift this section exists to catch: each
  -- revision changed what the ledger records, not merely how the packet is worded.
  select string_agg(version || '=' || (objects->>'packet_revision'), ', ' order by version)
    into v_txt
    from public.mt5_schema_migrations
   where version in ('mt5_t4b_promotion_schema_v1', 'mt5_t4b_promotion_rpc_v1');
  if v_txt is distinct from 'mt5_t4b_promotion_rpc_v1=6, mt5_t4b_promotion_schema_v1=6' then
    v_fail := v_fail || format('SEC10b: T4B ledger rows do not both record packet revision 6: %s',
                               coalesce(v_txt, '<none>'));
  end if;
  -- SEC10c/d/e — THE EXACT EXPECTED IDENTITIES, not merely "two different values that are not
  -- the old T3 one". Comparing shapes rather than values let any pair of arbitrary hashes pass,
  -- which made the whole identity scheme decorative at the point where it is read back.
  select checksum into v_txt from public.mt5_schema_migrations
   where version = 'mt5_t4b_promotion_schema_v1';
  if v_txt is distinct from exp_schema_checksum then
    v_fail := v_fail || format('SEC10c: schema packet checksum mismatch%s          ledger   %s%s'
                               '          expected %s', E'\n', coalesce(v_txt, '<none>'), E'\n',
                               exp_schema_checksum);
  end if;
  select checksum into v_txt from public.mt5_schema_migrations
   where version = 'mt5_t4b_promotion_rpc_v1';
  if v_txt is distinct from exp_rpc_checksum then
    v_fail := v_fail || format('SEC10d: RPC packet checksum mismatch%s          ledger   %s%s'
                               '          expected %s', E'\n', coalesce(v_txt, '<none>'), E'\n',
                               exp_rpc_checksum);
  end if;
  select string_agg(distinct source_artifact_sha256, ', ') into v_txt
    from public.mt5_schema_migrations
   where version in ('mt5_t4b_promotion_schema_v1', 'mt5_t4b_promotion_rpc_v1');
  if v_txt is distinct from exp_contract_digest then
    v_fail := v_fail || format('SEC10e: source artifact digest is not the frozen contract '
                               'digest%s          ledger   %s%s          expected %s',
                               E'\n', coalesce(v_txt, '<none>'), E'\n', exp_contract_digest);
  end if;
  -- and the self-referential revision-1 token must be gone for good
  if exists (select 1 from public.mt5_schema_migrations
              where version = 'mt5_t4b_promotion_schema_v1'
                and checksum = encode(sha256(
                      'mt5_t4b_promotion_schema_v1|packet-revision-1'::bytea), 'hex')) then
    v_fail := v_fail || 'SEC10f: the schema checksum is still the self-referential '
                        'sha256(version|revision) token, which cannot detect SQL drift'::text;
  end if;

  -- ============================================================================================
  -- SEC11 — data-shape invariants that must hold for whatever is already promoted
  -- ============================================================================================
  -- Every promoted trade that still exists must carry its marker: a row in the reserved namespace
  -- with a NULL marker means somebody recreated it outside T4B.
  select count(*) into v_n
    from public.mt5_capture_promotions p
    join public.trades t on t.id = p.trade_id
   where t.mt5_promotion_id is distinct from p.id;
  if v_n <> 0 then
    v_fail := v_fail || format('SEC11: %s promoted trade(s) exist whose incarnation marker does '
                               'not match their promotion — replay would report drift', v_n);
  end if;
  -- No row may sit in the reserved namespace without a promotion behind it.
  select count(*) into v_n
    from public.trades t
   where t.id ~ '^mt5p_'
     and not exists (select 1 from public.mt5_capture_promotions p where p.trade_id = t.id);
  if v_n <> 0 then
    v_fail := v_fail || format('SEC11b: %s trade(s) occupy the reserved mt5p_ namespace with no '
                               'promotion behind them', v_n);
  end if;

  -- ============================================================================================
  -- SEC12 — the product catalog cardinality guarantee the mapping helper depends on
  -- ============================================================================================
  select count(*) into v_n
    from pg_catalog.pg_constraint c
   where c.conrelid = 'public.products'::regclass
     and c.contype in ('p','u')
     and c.conkey = array[(select a.attnum from pg_catalog.pg_attribute a
                            where a.attrelid = 'public.products'::regclass
                              and a.attname = 'user_id' and not a.attisdropped)];
  if v_n = 0 then
    v_fail := v_fail || 'SEC12: public.products has no PRIMARY KEY or UNIQUE constraint on '
                        '(user_id) — duplicate catalogs are structurally possible'::text;
  end if;

  -- ============================================================================================
  if array_length(v_fail, 1) is not null then
    raise exception E'T4B SECURITY VERIFICATION FAILED (% finding(s)):\n  - %',
      array_length(v_fail, 1), array_to_string(v_fail, E'\n  - ');
  end if;
  raise notice 'T4B SECURITY VERIFICATION: ALL SECTIONS PASS (SEC1-SEC12)';
end $sec$;

rollback;
