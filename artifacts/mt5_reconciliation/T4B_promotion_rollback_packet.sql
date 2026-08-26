-- ================================================================================================
-- PRODUCTION-SAFE APPLY (conditional)
-- T4B JOURNAL PROMOTION — ROLLBACK PACKET (packet revision 6)
--
-- Drops the T4B objects and REMOVES both migration ledger rows, matching S1/S1.1/T2/T4A.
--
-- IT REFUSES TO RUN IF ANY DURABLE PROMOTION EXISTS. A promotion row means a real Journal trade
-- was created from a real human decision; dropping the ledger would erase the only authoritative
-- record that it happened, leaving an unexplained trade in the user's book. After the first real
-- promotion, un-installing T4B is a RECONCILIATION TASK with its own gate, not a rollback.
--
-- This packet NEVER deletes or updates a Journal trade. It deletes no row, changes no price, and
-- clears no mt5PositionId. Journal rows created by T4B are the user's data and outlive T4B.
--
-- Revision 2 additionally removes the trades incarnation marker (column, partial unique index and
-- guard trigger) and the shared fulfilment validator. Dropping the COLUMN is a schema change to
-- public.trades, so it is deliberately gated twice: the no-promotions refusal above, and an
-- explicit check that no surviving trade row carries a marker. Both must hold, because a marker on
-- a live row would mean a promotion existed and its ledger row went missing.
--
-- Revision 3 restores each grantee's TABLE-level INSERT/UPDATE on public.trades (the schema packet
-- narrowed those to column lists excluding the marker) and DELETES the two ledger rows instead of
-- flagging them, so the documented rollback-then-reapply sequence actually works.
--
-- APPLY: psql -v ON_ERROR_STOP=1 -f T4B_promotion_rollback_packet.sql
-- ================================================================================================

begin;

do $t4b_rb_pre$
declare
  v_n bigint;
begin
  if to_regclass('public.mt5_capture_promotions') is null then
    raise exception 'MT5_T4B_ROLLBACK: public.mt5_capture_promotions does not exist — nothing to '
      'roll back';
  end if;
  select count(*) into v_n from public.mt5_capture_promotions;
  if v_n <> 0 then
    raise exception 'MT5_T4B_ROLLBACK: REFUSING — % durable promotion row(s) exist. Real Journal '
      'trades were created from real decisions; removing the ledger would erase the only record '
      'of why they exist. Open a reconciliation gate instead.', v_n;
  end if;

  -- No live Journal row may still claim an incarnation. If one does, the ledger and the Journal
  -- disagree and that must be reconciled by a human before any schema is dropped.
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='trades'
                and column_name='mt5_promotion_id') then
    select count(*) into v_n from public.trades where mt5_promotion_id is not null;
    if v_n <> 0 then
      raise exception 'MT5_T4B_ROLLBACK: REFUSING — % Journal trade(s) still carry an incarnation '
        'marker while the promotion ledger is empty. That disagreement is a reconciliation task, '
        'not a rollback.', v_n;
    end if;
  end if;

  -- Likewise nothing may be squatting in the reserved namespace.
  select count(*) into v_n from public.trades where id ~ '^mt5p_';
  if v_n <> 0 then
    raise exception 'MT5_T4B_ROLLBACK: REFUSING — % Journal trade(s) occupy the reserved mt5p_ '
      'namespace with no promotion behind them.', v_n;
  end if;
end $t4b_rb_pre$;

drop function if exists public.mt5_promote_capture_decision_v1(uuid);
drop function if exists public.mt5_t4b_map_product_v1(uuid, text, numeric);
drop function if exists public.mt5_t4b_validate_fulfillment_v1(uuid, text, uuid);
drop function if exists public.mt5_t4b_freshness_window_v1();

-- The trades incarnation stack. The trigger goes before the column it guards; dropping the column
-- takes its partial unique index with it.
drop trigger  if exists mt5_trades_incarnation_guard_v1 on public.trades;
drop function if exists public.mt5_trades_incarnation_guard_v1();
drop index    if exists public.mt5_trades_promotion_uk;
alter table public.trades drop column if exists mt5_promotion_id;

-- ------------------------------------------------------------------------------------------------
-- RESTORE public.trades' pre-T4B INSERT/UPDATE privilege shape from the snapshot the schema packet
-- recorded at apply time, under objects->'trades_prior_write_acl'.
--
-- It has to come from the snapshot. The first revision-3 cut rediscovered the grantees by reading
-- pg_class.relacl at rollback time — but the apply REVOKED precisely those entries, so the loop
-- found no non-owner INSERT/UPDATE grantee and restored nothing at all. The column-level grants
-- T4B left behind kept today's writes working, which is why a "can the app still insert?" probe
-- passed; the table-level privilege and its grant options stayed gone, and every column added
-- after T4B would have been unwritable.
--
-- Ordering: the column is dropped FIRST, so any grant mentioning the marker is already gone and
-- the replay cannot resurrect one.
-- ------------------------------------------------------------------------------------------------
do $t4b_restore_acl$
declare
  v_snap     jsonb;
  v_want     jsonb;
  v_have     jsonb;
  v_want_cmp jsonb;
  v_have_cmp jsonb;
  v_lost     text[];
  v_owner    oid;
  v_me       oid;
  v_super    boolean;
  v_bad      text;
  v_grantee  text;
  e          jsonb;
  r          record;
begin
  if not exists (select 1 from public.mt5_schema_migrations
                  where version = 'mt5_t4b_promotion_schema_v1') then
    -- The schema packet never completed, or this rollback already ran. Nothing of ours is in the
    -- ACL, and inventing a restore would be worse than performing none.
    return;
  end if;

  select m.objects->'trades_prior_write_acl' into v_snap
    from public.mt5_schema_migrations m
   where m.version = 'mt5_t4b_promotion_schema_v1';
  if v_snap is null or jsonb_typeof(v_snap) <> 'array' then
    raise exception 'MT5_T4B_ROLLBACK: the schema ledger row carries no trades_prior_write_acl '
      'snapshot — refusing to guess at the pre-T4B privilege shape of public.trades';
  end if;

  select c.relowner into v_owner
    from pg_catalog.pg_class c where c.oid = 'public.trades'::regclass;
  -- The same executor restriction the apply enforces. PostgreSQL pins a GRANT's grantor to the
  -- object owner deterministically only for the owner itself or a superuser; for any other
  -- executor — a role that merely INHERITS the owner included — the containing grantor it selects
  -- is unspecified, and a grantor this packet did not choose is one nothing here can revoke.
  select q.oid, q.rolsuper into v_me, v_super
    from pg_catalog.pg_roles q where q.rolname = current_user;
  if v_me is distinct from v_owner and not coalesce(v_super, false) then
    raise exception 'MT5_T4B_ROLLBACK: REFUSING — this packet must run as %, the owner of '
      'public.trades, or as a superuser; current_user is %.',
      v_owner::regrole::text, current_user;
  end if;

  -- The same grantor constraint the apply enforced, re-checked at rollback time. If a grant
  -- option has been exercised since the apply, the REVOKEs below would fail on PostgreSQL's
  -- dependent-privilege rule, and no replay can rebuild a chain rooted in another grantor.
  select string_agg(d.txt, ', ' order by d.txt) into v_bad from (
    select format('%s -> %s (%s)', x.grantor::regrole::text,
                  case when x.grantee = 0 then 'PUBLIC' else x.grantee::regrole::text end,
                  x.privilege_type) as txt
      from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
     where c.oid = 'public.trades'::regclass
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> v_owner and x.grantor <> v_owner
    union
    select format('%s -> %s (%s on column %s)', x.grantor::regrole::text,
                  case when x.grantee = 0 then 'PUBLIC' else x.grantee::regrole::text end,
                  x.privilege_type, a.attname) as txt
      from pg_catalog.pg_attribute a, lateral aclexplode(a.attacl) x
     where a.attrelid = 'public.trades'::regclass and a.attnum > 0 and not a.attisdropped
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> v_owner and x.grantor <> v_owner
  ) d;
  if v_bad is not null then
    raise exception 'MT5_T4B_ROLLBACK: REFUSING — public.trades carries INSERT/UPDATE privileges '
      'granted by someone other than its owner: %. A grant option has been exercised since T4B '
      'was applied; revoke the delegated grants and re-run.', v_bad;
  end if;

  -- WHO can still be restored, decided by ROLE OID and never by name. A rename keeps the oid, so
  -- the principal is still there and simply answers to something else. A drop-and-recreate gives
  -- a NEW oid, so the name now belongs to a different principal — one that must NOT inherit the
  -- privileges of the role it replaced. Name-based matching gets both of those backwards.
  select coalesce(jsonb_agg(x order by x->>'scope', x->>'grantee_oid', x->>'priv',
                            coalesce(x->>'column', '')), '[]'::jsonb)
    into v_want
    from jsonb_array_elements(v_snap) x
   where (x->>'grantee_oid')::oid = 0
      or exists (select 1 from pg_catalog.pg_roles q
                  where q.oid = (x->>'grantee_oid')::oid);
  if v_want <> v_snap then
    select array_agg(distinct format('%s (oid %s)%s', x->>'grantee', x->>'grantee_oid',
             case when exists (select 1 from pg_catalog.pg_roles q
                                where q.rolname = x->>'grantee')
                  then ' — that NAME now belongs to a different role, which is deliberately NOT '
                       'being granted the original privileges'
                  else '' end))
      into v_lost
      from jsonb_array_elements(v_snap) x
     where (x->>'grantee_oid')::oid <> 0
       and not exists (select 1 from pg_catalog.pg_roles q
                        where q.oid = (x->>'grantee_oid')::oid);
    raise notice 'MT5_T4B_ROLLBACK: pre-T4B grant(s) on public.trades cannot be restored — the '
      'grantee no longer exists under its original oid: %', v_lost;
  end if;

  -- Clear the CURRENT non-owner INSERT/UPDATE surface, table AND column level. A table-level
  -- REVOKE does take that grantee's matching column privileges with it, but it reaches only the
  -- grantees and privileges that HAVE a table entry — T4B's own narrowing leaves column-only
  -- grantees behind by construction. The second pass is what clears those, so the replayed shape
  -- carries no residue.
  for r in
    select x.privilege_type as priv,
           case when x.grantee = 0 then 'public'
                else quote_ident((select q.rolname from pg_catalog.pg_roles q
                                   where q.oid = x.grantee)) end as g
      from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
     where c.oid = 'public.trades'::regclass
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> c.relowner
  loop
    execute format('revoke %s on table public.trades from %s', r.priv, r.g);
  end loop;
  for r in
    select x.privilege_type as priv, a.attname as col,
           case when x.grantee = 0 then 'public'
                else quote_ident((select q.rolname from pg_catalog.pg_roles q
                                   where q.oid = x.grantee)) end as g
      from pg_catalog.pg_attribute a, lateral aclexplode(a.attacl) x
     where a.attrelid = 'public.trades'::regclass
       and a.attnum > 0 and not a.attisdropped
       and x.privilege_type in ('INSERT', 'UPDATE')
       and x.grantee <> (select c.relowner from pg_catalog.pg_class c
                          where c.oid = 'public.trades'::regclass)
  loop
    execute format('revoke %s (%I) on table public.trades from %s', r.priv, r.col, r.g);
  end loop;

  -- Replay the snapshot exactly: table-level and column-level alike, WITH GRANT OPTION preserved.
  -- The grantee name is re-derived from the recorded OID, so a renamed role is granted under its
  -- CURRENT name and still ends up as the same principal in the catalog.
  for e in select x from jsonb_array_elements(v_want) x
  loop
    -- These strings become dynamic SQL. They came from our own ledger row, but the ledger is a
    -- table: validate rather than trust.
    if (e->>'priv') not in ('INSERT', 'UPDATE') then
      raise exception 'MT5_T4B_ROLLBACK: snapshot carries an unexpected privilege %', e->>'priv';
    end if;
    if (e->>'scope') not in ('table', 'column') then
      raise exception 'MT5_T4B_ROLLBACK: snapshot carries an unexpected scope %', e->>'scope';
    end if;
    if (e->>'grantor_oid')::oid <> v_owner then
      raise exception 'MT5_T4B_ROLLBACK: snapshot entry was granted by %, not by the owner — this '
        'packet cannot replay a grant rooted in another grantor', e->>'grantor';
    end if;
    v_grantee := case when (e->>'grantee_oid')::oid = 0 then 'public'
                      else quote_ident((select q.rolname from pg_catalog.pg_roles q
                                         where q.oid = (e->>'grantee_oid')::oid)) end;
    if (e->>'scope') = 'table' then
      execute format('grant %s on table public.trades to %s%s', e->>'priv', v_grantee,
                     case when (e->>'grantable')::boolean then ' with grant option' else '' end);
    else
      execute format('grant %s (%I) on table public.trades to %s%s',
                     e->>'priv', e->>'column', v_grantee,
                     case when (e->>'grantable')::boolean then ' with grant option' else '' end);
    end if;
  end loop;

  -- EXACT restoration, not "the app can still write". Recomputing the same expression the schema
  -- packet used and demanding equality covers grantee, grantor, privilege, scope, column AND
  -- grant option.
  select coalesce(jsonb_agg(j order by j->>'scope', j->>'grantee_oid', j->>'priv',
                               coalesce(j->>'column', '')), '[]'::jsonb)
    into v_have
    from (
      select jsonb_build_object(
               'scope', 'table',
               'grantee_oid', x.grantee::bigint,
               'grantee', case when x.grantee = 0 then 'public'
                               else (select q.rolname from pg_catalog.pg_roles q
                                      where q.oid = x.grantee) end,
               'grantor_oid', x.grantor::bigint,
               'grantor', (select q.rolname from pg_catalog.pg_roles q
                            where q.oid = x.grantor),
               'priv', x.privilege_type,
               'grantable', x.is_grantable) as j
        from pg_catalog.pg_class c, lateral aclexplode(c.relacl) x
       where c.oid = 'public.trades'::regclass
         and x.privilege_type in ('INSERT', 'UPDATE')
         and x.grantee <> c.relowner
      union
      select jsonb_build_object(
               'scope', 'column',
               'grantee_oid', x.grantee::bigint,
               'grantee', case when x.grantee = 0 then 'public'
                               else (select q.rolname from pg_catalog.pg_roles q
                                      where q.oid = x.grantee) end,
               'grantor_oid', x.grantor::bigint,
               'grantor', (select q.rolname from pg_catalog.pg_roles q
                            where q.oid = x.grantor),
               'priv', x.privilege_type,
               'grantable', x.is_grantable,
               'column', a.attname) as j
        from pg_catalog.pg_attribute a, lateral aclexplode(a.attacl) x
       where a.attrelid = 'public.trades'::regclass
         and a.attnum > 0 and not a.attisdropped
         and x.privilege_type in ('INSERT', 'UPDATE')
         and x.grantee <> (select c.relowner from pg_catalog.pg_class c
                            where c.oid = 'public.trades'::regclass)
    ) s;
  -- Compared with the NAMES projected out: identity is the oid, and a role renamed between apply
  -- and rollback is correctly the same principal under a different label.
  select coalesce(jsonb_agg((x - 'grantee' - 'grantor')
                            order by x->>'scope', x->>'grantee_oid', x->>'priv',
                                     coalesce(x->>'column', '')), '[]'::jsonb)
    into v_want_cmp from jsonb_array_elements(v_want) x;
  select coalesce(jsonb_agg((x - 'grantee' - 'grantor')
                            order by x->>'scope', x->>'grantee_oid', x->>'priv',
                                     coalesce(x->>'column', '')), '[]'::jsonb)
    into v_have_cmp from jsonb_array_elements(v_have) x;
  if v_have_cmp is distinct from v_want_cmp then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: the restored INSERT/UPDATE privilege shape of '
      'public.trades does not match the pre-T4B snapshot — recorded %, restored %',
      v_want_cmp::text, v_have_cmp::text;
  end if;

  -- ...and the same claim as an EFFECTIVE privilege, which is what actually governs a write.
  -- PUBLIC is skipped because has_table_privilege takes a role and PUBLIC is not one; the exact
  -- shape comparison above already covers it.
  for e in select x from jsonb_array_elements(v_want) x
            where x->>'scope' = 'table' and (x->>'grantee_oid')::oid <> 0
  loop
    if not has_table_privilege((e->>'grantee_oid')::oid, 'public.trades'::regclass,
                               e->>'priv') then
      raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: role % did not get table-level % back on '
        'public.trades', (e->>'grantee_oid')::oid::regrole::text, e->>'priv';
    end if;
  end loop;
end $t4b_restore_acl$;

drop trigger if exists mt5_capture_promotion_no_mutate_v1 on public.mt5_capture_promotions;
drop table  if exists public.mt5_capture_promotions;
drop function if exists public.mt5_capture_promotion_guard_v1();

-- REMOVE the ledger rows, matching S1, S1.1, T2 and T4A — all four sibling rollback packets do
-- exactly this. Revision 2 flagged them 'rolled_back' instead, which left both versions
-- unreapplyable: the apply packets INSERT into a version-primary-key ledger, so the documented
-- rollback-then-reapply sequence died on a duplicate key and took the whole apply transaction with
-- it. Deleting the row is the pipeline's contract; the applied/rolled_back history lives in the
-- packet's own audit trail, not in a tombstone that blocks reinstallation.
delete from public.mt5_schema_migrations
 where version in ('mt5_t4b_promotion_schema_v1', 'mt5_t4b_promotion_rpc_v1');

do $t4b_rb_post$
declare
  v_n bigint;
begin
  if to_regclass('public.mt5_capture_promotions') is not null then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: the promotion table still exists';
  end if;
  if exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n
               on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('mt5_promote_capture_decision_v1', 'mt5_t4b_map_product_v1',
                                  'mt5_t4b_validate_fulfillment_v1',
                                  'mt5_t4b_freshness_window_v1',
                                  'mt5_capture_promotion_guard_v1',
                                  'mt5_trades_incarnation_guard_v1')) then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: a T4B function survived the rollback';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='trades'
                and column_name='mt5_promotion_id') then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: the incarnation column survived the rollback';
  end if;
  if to_regclass('public.mt5_trades_promotion_uk') is not null then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: the incarnation index survived the rollback';
  end if;
  if exists (select 1 from pg_catalog.pg_trigger
              where tgrelid = 'public.trades'::regclass
                and tgname = 'mt5_trades_incarnation_guard_v1' and not tgisinternal) then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: the incarnation trigger survived the rollback';
  end if;

  -- The Journal must be untouched: this packet has no statement that could delete or update a
  -- trade, and the assertions make that testable rather than merely stated.
  if to_regclass('public.trades') is null then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: public.trades is gone — the rollback must never '
      'touch the Journal';
  end if;
  if exists (select 1 from public.mt5_schema_migrations
              where version in ('mt5_t4b_promotion_schema_v1', 'mt5_t4b_promotion_rpc_v1')) then
    raise exception 'MT5_T4B_ROLLBACK_POSTFLIGHT: a T4B ledger row survived — reapplying the '
      'packets would fail on the version primary key';
  end if;

  select count(*) into v_n from public.trades;
  raise notice 'MT5_T4B_ROLLBACK: complete. public.trades still holds % row(s), none deleted.', v_n;
end $t4b_rb_post$;

commit;
