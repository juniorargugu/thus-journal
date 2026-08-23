-- ================================================================================================
-- MT5 T2 — CAPTURE EVENT PERSISTENCE, ROLLBACK PACKET
--
-- Status: EXECUTABLE DRAFT — intentionally UNAPPLIED.
-- Packet revision: 5
--   revision 1: initial draft (Codex: CHANGES_REQUESTED).
--   revision 2: ledger authority made EXACT for both packets (version, applied, revision,
--               checksum, source_artifact_sha256).
--   revision 5: gate logic UNCHANGED from revision 3; the pinned identities move to the rev5
--               packet checksums. A rev4 installation is refused by this packet for exactly the
--               reason rev4 refused a rev3 one.
--   revision 4: gate logic UNCHANGED from revision 3; the pinned identities move to the rev4
--               packet checksums. A database still carrying rev3 provenance is not the database
--               this packet was written against, and is refused rather than dropped.
--   revision 3: ONE fail-closed gate. Every destructive statement now lives INSIDE the guarded
--               block, after the gate. Revision 2 still had unconditional DROP statements after
--               the block, so the "nothing to do" early RETURN fell straight through into them
--               and would have removed an unknown same-named function. The gate also inventories
--               EVERY T2-named object — table, guard, all four helper/RPC functions, and both
--               ledger rows — instead of only the table and the guard.
--
-- Removes ONLY the T2 capture-persistence layer:
--   public.mt5_append_capture_event_v1(uuid,text,jsonb)
--   public.mt5_capture_payload_fingerprint_v1(jsonb)
--   public.mt5_capture_event_key_v1(jsonb)
--   public.mt5_capture_keys_match_v1(jsonb,text[])
--   public.mt5_capture_event_guard_v1()          (+ its trigger, dropped with the table)
--   public.mt5_capture_events                    (+ its policy and indexes)
--   the two T2 ledger rows
--
-- It touches NO frozen S1 or S1.1 object.
--
-- NO DROP WITHOUT EXACT APPLY-TIME PROVENANCE, AND NO DROP OUTSIDE THE GATE.
--   * If NOTHING T2-named exists — no objects, no ledger rows — this packet is a safe no-op.
--   * If ANY T2-named object or ledger row exists, the exact apply-time provenance of the
--     packet(s) that own it must be proved BEFORE a single object is touched: the ledger row
--     must exist, be 'applied', and carry this revision, this checksum and this source artifact,
--     and the objects must still be in the exact state the apply left behind.
--   * An unknown same-named function with a missing or mismatched ledger is REFUSED. A name is
--     not provenance.
--
-- DATA LOSS: dropping mt5_capture_events destroys capture evidence. It is safe only because that
-- evidence is derivable again from the immutable S1/S1.1 snapshots by re-running T1 + T2 — the
-- snapshots themselves are never touched here.
-- ================================================================================================

begin;

do $t2_rollback$
declare
  -- The EXACT provenance this packet is written against. Anything else is not ours to drop.
  c_schema_version  constant text := 'mt5_t2_capture_events_schema_v1';
  c_rpc_version     constant text := 'mt5_t2_capture_events_rpc_v1';
  c_revision        constant text := '5';
  c_schema_checksum constant text := '5f8e890c9b5a6dae24233ceb96aab06d3d86e705792fc9ed7556087c945f8282';
  c_rpc_checksum    constant text := 'b5b3edffc21ad064850dcfc9f562322ee8592317c070592d57f1b12769ae00d0';
  c_source_sha      constant text := '20D8A278F326D863299F2AFCE7D0198BFC2579ADD121A3697E5E9AC0BBDCF645';
  c_rpc_functions   constant text[] := array[
    'mt5_capture_keys_match_v1', 'mt5_capture_event_key_v1',
    'mt5_capture_payload_fingerprint_v1', 'mt5_append_capture_event_v1'];

  v_table_present boolean;
  v_guard_present boolean;
  v_fn_present    text;
  v_fn_missing    text;
  v_schema_row    public.mt5_schema_migrations%rowtype;
  v_rpc_row       public.mt5_schema_migrations%rowtype;
  v_schema_ledger boolean;
  v_rpc_ledger    boolean;
  v_schema_side   boolean;
  v_rpc_side      boolean;
  v_inventory     text;
  v_bad           text;
begin
  -- ================================================================================
  -- 1. INVENTORY — everything this packet could possibly own
  -- ================================================================================
  v_table_present := to_regclass('public.mt5_capture_events') is not null;
  v_guard_present := exists (
    select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mt5_capture_event_guard_v1');

  select string_agg(x.name, ', ' order by x.name) filter (where x.present),
         string_agg(x.name, ', ' order by x.name) filter (where not x.present)
    into v_fn_present, v_fn_missing
    from (select f.name,
                 exists (select 1 from pg_catalog.pg_proc p
                           join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = f.name) as present
            from unnest(c_rpc_functions) as f(name)) x;

  select * into v_schema_row from public.mt5_schema_migrations where version = c_schema_version;
  v_schema_ledger := found;
  select * into v_rpc_row from public.mt5_schema_migrations where version = c_rpc_version;
  v_rpc_ledger := found;

  select string_agg(s, ', ') into v_inventory from (
    select 'table public.mt5_capture_events' as s where v_table_present
    union all select 'public.mt5_capture_event_guard_v1()' where v_guard_present
    union all select 'function(s) ' || v_fn_present where v_fn_present is not null
    union all select 'ledger row ' || c_schema_version where v_schema_ledger
    union all select 'ledger row ' || c_rpc_version where v_rpc_ledger
  ) t;

  -- ================================================================================
  -- 2. SAFE NO-OP — and only when literally nothing T2-named is present
  -- ================================================================================
  if v_inventory is null then
    raise notice 'MT5_T2_ROLLBACK: nothing to do (no T2 objects and no T2 ledger rows)';
    return;
  end if;

  -- Which packet(s) must now prove themselves. The RPC packet cannot exist without the schema
  -- packet (its own preflight requires it), so anything RPC-side pulls the schema side in too.
  v_schema_side := v_table_present or v_guard_present or v_schema_ledger;
  v_rpc_side    := (v_fn_present is not null) or v_rpc_ledger;
  if v_rpc_side then
    v_schema_side := true;
  end if;

  -- ================================================================================
  -- 3. SCHEMA-SIDE PROVENANCE — exact, or nothing is touched
  -- ================================================================================
  if v_schema_side then
    if not v_schema_ledger then
      raise exception 'MT5_T2_ROLLBACK: T2-named object(s) exist (%) but the T2 SCHEMA ledger row is MISSING — ownership is never inferred from a name; refusing to drop anything', v_inventory;
    end if;
    if v_schema_row.status is distinct from 'applied' then
      raise exception 'MT5_T2_ROLLBACK: the T2 schema ledger row is "%", not applied — a non-applied row proves nothing about what is installed (present: %)',
        coalesce(v_schema_row.status,'<null>'), v_inventory;
    end if;
    if (v_schema_row.objects ->> 'packet_revision') is distinct from c_revision then
      raise exception 'MT5_T2_ROLLBACK: ledger records schema packet_revision %, this packet rolls back revision %',
        coalesce(v_schema_row.objects ->> 'packet_revision','<null>'), c_revision;
    end if;
    if v_schema_row.checksum is distinct from c_schema_checksum then
      raise exception 'MT5_T2_ROLLBACK: the T2 schema ledger checksum is not the one this packet was written against — refusing';
    end if;
    if v_schema_row.source_artifact_sha256 is distinct from c_source_sha then
      raise exception 'MT5_T2_ROLLBACK: the T2 schema ledger source_artifact_sha256 is not the one this packet was written against — refusing';
    end if;
    if not v_table_present then
      raise exception 'MT5_T2_ROLLBACK: the schema ledger row is applied but public.mt5_capture_events does not exist — refusing to act on an inconsistent installation';
    end if;
    if not v_guard_present then
      raise exception 'MT5_T2_ROLLBACK: the schema ledger row is applied but public.mt5_capture_event_guard_v1() does not exist — refusing to act on an inconsistent installation';
    end if;

    -- exact column shape at apply time
    select string_agg(a.attname || ':' || pg_catalog.format_type(a.atttypid, a.atttypmod), '|'
                      order by a.attnum)
      into v_bad
      from pg_catalog.pg_attribute a
     where a.attrelid = 'public.mt5_capture_events'::regclass
       and a.attnum > 0 and not a.attisdropped;
    if v_bad is distinct from
       'id:uuid|created_at:timestamp with time zone|event_key:text|user_id:uuid|'
       'source_account:text|position_id:bigint|basis_run_id:uuid|'
       'first_detection_at:timestamp with time zone|last_detection_at:timestamp with time zone|'
       'quiet_deadline:timestamp with time zone|quiet_window_seconds:numeric|'
       'detector_version:text|aggregator_version:text|payload:jsonb|payload_fingerprint:text' then
      raise exception 'MT5_T2_ROLLBACK: mt5_capture_events no longer matches the apply-time column shape — refusing to drop a table that has been altered since apply. Actual: %', v_bad;
    end if;

    -- owner / RLS / grants must be what this packet left behind
    if not exists (select 1 from pg_catalog.pg_class c
                     join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                    where n.nspname='public' and c.relname='mt5_capture_events'
                      and c.relrowsecurity
                      and pg_catalog.pg_get_userbyid(c.relowner) = 'postgres') then
      raise exception 'MT5_T2_ROLLBACK: owner or row-security state changed since apply — refusing';
    end if;
    select string_agg(grantee || '/' || privilege_type, ',' order by grantee || privilege_type)
      into v_bad
      from information_schema.table_privileges
     where table_schema='public' and table_name='mt5_capture_events'
       and grantee <> 'postgres';
    if v_bad is distinct from 'service_role/SELECT' then
      raise exception 'MT5_T2_ROLLBACK: table grants changed since apply (now: %) — refusing',
        coalesce(v_bad,'<none>');
    end if;
    if exists (select 1 from pg_catalog.pg_attribute a
                where a.attrelid='public.mt5_capture_events'::regclass
                  and a.attnum>0 and not a.attisdropped and a.attacl is not null) then
      raise exception 'MT5_T2_ROLLBACK: column-level ACL state changed since apply — refusing';
    end if;

    -- exactly the trigger and policy this packet created, and no foreign additions
    select string_agg(t.tgname, ',' order by t.tgname) into v_bad
      from pg_catalog.pg_trigger t
     where t.tgrelid = 'public.mt5_capture_events'::regclass and not t.tgisinternal;
    if v_bad is distinct from 'mt5_capture_event_no_mutate_v1' then
      raise exception 'MT5_T2_ROLLBACK: unrecorded trigger on mt5_capture_events (now: %) — refusing',
        coalesce(v_bad,'<none>');
    end if;
    select string_agg(p.polname, ',' order by p.polname) into v_bad
      from pg_catalog.pg_policy p
     where p.polrelid = 'public.mt5_capture_events'::regclass;
    if v_bad is distinct from 'mt5_ce_service_read_v1' then
      raise exception 'MT5_T2_ROLLBACK: unrecorded policy on mt5_capture_events (now: %) — refusing',
        coalesce(v_bad,'<none>');
    end if;

    -- nothing outside T2 may depend on the table
    select string_agg(distinct c.relname, ', ') into v_bad
      from pg_catalog.pg_constraint con
      join pg_catalog.pg_class c on c.oid = con.conrelid
     where con.confrelid = 'public.mt5_capture_events'::regclass;
    if v_bad is not null then
      raise exception 'MT5_T2_ROLLBACK: table(s) % have a foreign key onto mt5_capture_events — a later layer already references this evidence; refusing to drop it', v_bad;
    end if;
  end if;

  -- ================================================================================
  -- 4. RPC-SIDE PROVENANCE — exact, or nothing is touched
  -- ================================================================================
  if v_rpc_side then
    if not v_rpc_ledger then
      raise exception 'MT5_T2_ROLLBACK: T2 RPC/helper function(s) % exist but the T2 RPC ledger row is MISSING — ownership is NOT inferred from a name or signature; refusing to drop', v_fn_present;
    end if;
    if v_rpc_row.status is distinct from 'applied' then
      raise exception 'MT5_T2_ROLLBACK: the T2 RPC ledger row is "%", not applied — refusing to drop on unproven provenance (present: %)',
        coalesce(v_rpc_row.status,'<null>'), v_inventory;
    end if;
    if (v_rpc_row.objects ->> 'packet_revision') is distinct from c_revision then
      raise exception 'MT5_T2_ROLLBACK: the T2 RPC ledger row records packet_revision %, not % — refusing',
        coalesce(v_rpc_row.objects ->> 'packet_revision','<null>'), c_revision;
    end if;
    if v_rpc_row.checksum is distinct from c_rpc_checksum then
      raise exception 'MT5_T2_ROLLBACK: the T2 RPC ledger checksum is not the one this packet was written against — refusing';
    end if;
    if v_rpc_row.source_artifact_sha256 is distinct from c_source_sha then
      raise exception 'MT5_T2_ROLLBACK: the T2 RPC ledger source_artifact_sha256 is not the one this packet was written against — refusing';
    end if;
    if v_fn_missing is not null then
      raise exception 'MT5_T2_ROLLBACK: the T2 RPC ledger row is applied but function(s) % are absent — the installation does not match the ledger; refusing', v_fn_missing;
    end if;
  end if;

  raise notice 'MT5_T2_ROLLBACK: authority established from apply-time provenance; proceeding (present: %)',
    v_inventory;

  -- ================================================================================
  -- 5. DESTRUCTIVE SECTION — reachable ONLY from here. Nothing above has modified anything,
  --    and there is no destructive statement anywhere outside this block.
  -- ================================================================================
  execute 'drop function if exists public.mt5_append_capture_event_v1(uuid, text, jsonb)';
  execute 'drop function if exists public.mt5_capture_payload_fingerprint_v1(jsonb)';
  execute 'drop function if exists public.mt5_capture_event_key_v1(jsonb)';
  execute 'drop function if exists public.mt5_capture_keys_match_v1(jsonb, text[])';
  execute 'drop table if exists public.mt5_capture_events';   -- takes trigger, policy, indexes
  execute 'drop function if exists public.mt5_capture_event_guard_v1()';

  delete from public.mt5_schema_migrations
   where version in (c_schema_version, c_rpc_version);

  -- ================================================================================
  -- 6. POSTFLIGHT
  -- ================================================================================
  if to_regclass('public.mt5_capture_events') is not null then
    raise exception 'MT5_T2_ROLLBACK: the capture table survived the drop';
  end if;
  if exists (select 1 from pg_catalog.pg_proc p
               join pg_catalog.pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and (p.proname = any (c_rpc_functions)
                     or p.proname = 'mt5_capture_event_guard_v1')) then
    raise exception 'MT5_T2_ROLLBACK: a T2 function survived the drop';
  end if;
  -- the frozen S1/S1.1 objects must be exactly as they were
  if to_regclass('public.mt5_sync_runs') is null
     or to_regclass('public.mt5_sync_run_positions') is null then
    raise exception 'MT5_T2_ROLLBACK: a frozen S1 table was harmed by this rollback';
  end if;
  if not exists (select 1 from public.mt5_schema_migrations
                  where version like 'mt5_s1%' and status = 'applied') then
    raise exception 'MT5_T2_ROLLBACK: the frozen S1/S1.1 ledger rows were harmed by this rollback';
  end if;
  raise notice 'MT5_T2_ROLLBACK: T2 capture persistence removed; S1/S1.1 untouched';
end
$t2_rollback$;

commit;
