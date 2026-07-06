-- ===========================================================================
-- G2 first-persistence — trade-group RPC/schema migration
--
-- STATUS: APPLIED in the Supabase SQL Editor on 2026-07-05 (prod project).
--   Preflights passed (core sha256 → 64-char hex; public.trades.id = text).
--   V1–V5 verification + negative RPC smoke passed; baseline clean (0 groups,
--   0 grouped trades). Happy-path create/ungroup smoke was deferred: no
--   eligible open same-family / same-direction legs existed at apply time.
--   Full record: artifacts/g2_grouping/g2_schema_apply_closeout.md
--
--   This file is the permanent source-of-truth for exactly what was applied.
--   Only this banner differs from the reviewed artifact; every executable
--   statement below is byte-identical to what ran. §1–§5 are idempotent
--   (IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS) and safe to
--   re-run / re-apply on another environment; the two PREFLIGHT SELECTs are
--   retained for that purpose. Do NOT run the commented ROLLBACK block at the
--   foot of this file except to intentionally remove G2 persistence.
--
-- Builds on G1 (migrations/20260607_g1_trade_groups_schema.sql), which already
-- created public.trade_groups (with archived_at), public.trades.group_id, the
-- simple FK trades.group_id -> trade_groups(id) ON DELETE SET NULL, three
-- indexes, RLS + 4 policies, and grants.
--
-- Lean decisions (locked):
--   * KEEP the existing simple FK. Do NOT add a composite FK.
--   * Ownership enforced by a BEFORE trigger on trades (below).
--   * Do NOT change column grants / do NOT REVOKE UPDATE(group_id) in v1.
--   * Add trade_groups.idempotency_key + a unique ACTIVE partial index.
--   * Add exactly two RPCs: create_trade_group_v1, ungroup_trade_group_v1.
--   * No pgcrypto dependency: the idempotency hash uses core sha256().
--
-- P/L invariant: the RPCs write ONLY the trades.group_id column (+updated_at).
-- The trades.raw jsonb is never touched, so reducers (which walk raw trades[])
-- never see grouping and all P/L totals stay byte-identical.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- PREFLIGHT — RUN THIS FIRST (read-only). If it ERRORS, STOP: do not apply the
-- rest of this packet. The RPCs hash with core sha256() under a locked
-- search_path; this confirms that path resolves in this project.
--
--   SELECT encode(sha256(convert_to('g2-preflight','UTF8')), 'hex');
--
-- Expected: a 64-char hex string (…). If it errors, do NOT continue. Fallback
-- (ONLY after review): CREATE EXTENSION IF NOT EXISTS pgcrypto; and replace the
-- hash with encode(extensions.digest(<text>,'sha256'),'hex'), adding `extensions`
-- to each RPC's search_path.
--
-- PREFLIGHT 2 — RUN THIS FIRST (read-only). This packet keeps p_child_ids as
-- text[] and compares public.trades.id = ANY(v_ids); that is valid ONLY if
-- public.trades.id is of type text.
--
--   SELECT data_type
--   FROM   information_schema.columns
--   WHERE  table_schema = 'public'
--     AND  table_name   = 'trades'
--     AND  column_name  = 'id';
--
-- Required result for this artifact: data_type = 'text'.
-- If the result is NOT 'text': STOP. Do not apply this packet. Return to
-- ChatGPT/Codex for a typed-array variant (e.g. uuid[] / bigint[] to match).
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 1. trade_groups.idempotency_key (nullable; set by create_trade_group_v1 only)
-- ---------------------------------------------------------------------------
ALTER TABLE public.trade_groups
  ADD COLUMN IF NOT EXISTS idempotency_key text;


-- ---------------------------------------------------------------------------
-- 2. Unique ACTIVE membership key: at most one active group per (user,membership)
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS trade_groups_user_idem_active_uidx
  ON public.trade_groups (user_id, idempotency_key)
  WHERE archived_at IS NULL AND idempotency_key IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 3. Ownership-guard trigger on trades
--
-- Any write that SETS trades.group_id NOT NULL must reference an ACTIVE
-- trade_groups row owned by the SAME user_id. The referenced group row is
-- locked FOR KEY SHARE during validation: this conflicts with the FOR UPDATE
-- that ungroup_trade_group_v1 takes on the group, so a group cannot be archived
-- out from under a concurrent attach. (Simple FK retained; no composite FK.)
--
-- Fires on every INSERT (skips when group_id NULL) and only on UPDATEs that
-- name group_id in SET. Normal app saves (toTradeRow OMITS group_id) never
-- fire it; ungroup sets group_id=NULL so the guard skips.
--
-- Concurrency note (accepted lean v1 behavior): a direct PATCH attach vs a
-- concurrent ungroup can deadlock — the direct attach may lock the child then
-- have the trigger wait on the group, while ungroup locks the group then the
-- child. This is consistency-safe under Postgres deadlock detection: one
-- transaction aborts, no corruption. The normal UI never direct-PATCHes
-- group_id (writes go only through create/ungroup RPCs), so this path is not
-- exercised in practice.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trades_group_id_owner_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.group_id IS NOT NULL THEN
    PERFORM 1
      FROM public.trade_groups g
     WHERE g.id = NEW.group_id
       AND g.user_id = NEW.user_id
       AND g.archived_at IS NULL
     FOR KEY SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION
        'trades.group_id % is not an active group owned by user %',
        NEW.group_id, NEW.user_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trades_group_id_owner_guard_trg ON public.trades;
CREATE TRIGGER trades_group_id_owner_guard_trg
  BEFORE INSERT OR UPDATE OF group_id ON public.trades
  FOR EACH ROW
  EXECUTE FUNCTION public.trades_group_id_owner_guard();


-- ---------------------------------------------------------------------------
-- 4. create_trade_group_v1
--
-- Single authenticated RPC (no client insert+update). SECURITY DEFINER with a
-- locked search_path; all public tables fully qualified; uid = auth.uid().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_trade_group_v1(
  p_child_ids text[],
  p_label     text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid          uuid := auth.uid();
  v_raw_n        int;
  v_distinct_n   int;
  v_ids          text[];
  v_n            int;
  v_found        int;
  v_open         int;
  v_grouped      int;
  v_missing_prod int;
  v_missing_dir  int;
  v_fam          int;
  v_dir          int;
  v_family       text;
  v_direction    text;
  v_key          text;
  v_existing     uuid;
  v_match        int;
  v_group_id     uuid;
  v_label        text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- 0. invalid-input gates ----------------------------------------------------
  IF p_child_ids IS NULL OR array_length(p_child_ids, 1) IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'invalid_child_ids');   -- null / empty array
  END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(p_child_ids) AS u(child_id)
     WHERE u.child_id IS NULL OR btrim(u.child_id) = ''
  ) THEN
    RETURN json_build_object('ok', false, 'error', 'invalid_child_ids');   -- null / empty element
  END IF;
  SELECT count(*), count(DISTINCT u.child_id)
    INTO v_raw_n, v_distinct_n
    FROM unnest(p_child_ids) AS u(child_id);
  IF v_raw_n <> v_distinct_n THEN
    RETURN json_build_object('ok', false, 'error', 'duplicate_child_ids');
  END IF;

  -- canonical sorted ids (already distinct + valid) → lock order + idempotency
  SELECT array_agg(u.child_id ORDER BY u.child_id) INTO v_ids
    FROM unnest(p_child_ids) AS u(child_id);
  v_n := array_length(v_ids, 1);
  IF v_n IS NULL OR v_n < 2 THEN
    RETURN json_build_object('ok', false, 'error', 'too_few_children');
  END IF;

  -- 1. deterministic lock of the owned children, in sorted id order ----------
  --    (sorted order avoids deadlocks between calls with overlapping sets)
  PERFORM 1
    FROM public.trades
   WHERE user_id = v_uid AND id = ANY(v_ids)
   ORDER BY id
   FOR UPDATE;

  -- 2. aggregate over the now-locked owned rows ------------------------------
  SELECT count(*),
         count(*) FILTER (WHERE status = 'open'),
         count(*) FILTER (WHERE group_id IS NOT NULL),
         count(*) FILTER (WHERE product_id IS NULL OR btrim(product_id) = ''
                             OR btrim(regexp_replace(product_id, '_next$', '')) = ''),
         count(*) FILTER (WHERE direction  IS NULL OR btrim(direction)  = ''),
         count(DISTINCT regexp_replace(product_id, '_next$', '')),
         count(DISTINCT direction),
         min(regexp_replace(product_id, '_next$', '')),
         min(direction)
    INTO v_found, v_open, v_grouped, v_missing_prod, v_missing_dir,
         v_fam, v_dir, v_family, v_direction
    FROM public.trades
   WHERE user_id = v_uid AND id = ANY(v_ids);

  -- 3. unconditional validations (apply to BOTH re-click and create paths) ---
  IF v_found        <> v_n THEN RETURN json_build_object('ok',false,'error','child_not_found');   END IF;
  IF v_open         <> v_n THEN RETURN json_build_object('ok',false,'error','not_open');           END IF;
  IF v_missing_prod <> 0   THEN RETURN json_build_object('ok',false,'error','missing_product');     END IF;
  IF v_missing_dir  <> 0   THEN RETURN json_build_object('ok',false,'error','missing_direction');   END IF;
  IF v_fam          <> 1   THEN RETURN json_build_object('ok',false,'error','family_mismatch');     END IF;
  IF v_dir          <> 1   THEN RETURN json_build_object('ok',false,'error','direction_mismatch');  END IF;

  -- 4. membership-based idempotency key (core sha256; no pgcrypto) -----------
  v_key := encode(
             sha256(convert_to('g2:v1|' || v_uid::text || '|' || array_to_string(v_ids, ','), 'UTF8')),
             'hex');

  -- 5. is there already an ACTIVE group for this exact membership? -----------
  SELECT id INTO v_existing
    FROM public.trade_groups
   WHERE user_id = v_uid AND idempotency_key = v_key AND archived_at IS NULL
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    -- idempotent re-click: children are already validated owned/open/same
    -- family+direction above; they must ALL already point at this group.
    SELECT count(*) INTO v_match
      FROM public.trades
     WHERE user_id = v_uid AND id = ANY(v_ids) AND group_id = v_existing;

    IF v_match = v_n THEN
      RETURN json_build_object('ok',true,'group_id',v_existing,
                               'created',false,'already_exists',true,'child_ids',v_ids);
    ELSE
      RETURN json_build_object('ok',false,'error','inconsistent_group_state',
                               'group_id',v_existing);   -- do NOT mutate
    END IF;
  END IF;

  -- 6. CREATE path (no active membership group) ------------------------------
  IF v_grouped <> 0 THEN
    RETURN json_build_object('ok',false,'error','already_grouped');   -- grouped in another active group
  END IF;

  v_label := COALESCE(NULLIF(btrim(p_label), ''), v_family || ' ' || v_direction);

  INSERT INTO public.trade_groups (user_id, label, idempotency_key, created_at, updated_at)
  VALUES (v_uid, v_label, v_key, now(), now())
  ON CONFLICT (user_id, idempotency_key) WHERE archived_at IS NULL AND idempotency_key IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_group_id;

  IF v_group_id IS NULL THEN               -- lost a race → re-read the active row
    SELECT id INTO v_group_id FROM public.trade_groups
     WHERE user_id = v_uid AND idempotency_key = v_key AND archived_at IS NULL LIMIT 1;
  END IF;

  -- defensive: if we still have no group id (insert did nothing AND re-read
  -- found nothing), STOP before touching any child row.
  IF v_group_id IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'group_create_race_lost');
  END IF;

  -- set ONLY group_id + updated_at; raw jsonb untouched (P/L invariant).
  -- trigger validates each child references this active, owned group.
  UPDATE public.trades
     SET group_id = v_group_id, updated_at = now()
   WHERE user_id = v_uid AND id = ANY(v_ids);

  RETURN json_build_object('ok',true,'group_id',v_group_id,
                           'created',true,'already_exists',false,'child_ids',v_ids);
END $$;

REVOKE ALL     ON FUNCTION public.create_trade_group_v1(text[], text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.create_trade_group_v1(text[], text) TO authenticated;


-- ---------------------------------------------------------------------------
-- 5. ungroup_trade_group_v1  (unchanged lean design)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ungroup_trade_group_v1(p_group_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_archived timestamptz;
  v_ids      text[];
  v_cleared  int;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  -- lock the group row; ownership enforced by the WHERE (conflicts with the
  -- attach trigger's FOR KEY SHARE, serializing create-attach vs ungroup)
  SELECT archived_at INTO v_archived
    FROM public.trade_groups
   WHERE id = p_group_id AND user_id = v_uid
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'group_not_found');
  END IF;

  IF v_archived IS NOT NULL THEN           -- idempotent no-op
    RETURN json_build_object('ok',true,'group_id',p_group_id,'archived',false,
                             'already_archived',true,'cleared',0,'child_ids',ARRAY[]::text[]);
  END IF;

  -- lock + collect the children currently in this group (sorted)
  SELECT array_agg(id ORDER BY id) INTO v_ids
    FROM (SELECT id FROM public.trades
           WHERE user_id = v_uid AND group_id = p_group_id
           ORDER BY id
           FOR UPDATE) s;
  v_ids := COALESCE(v_ids, ARRAY[]::text[]);

  -- clear children (raw untouched); guard skips because NEW.group_id -> NULL
  UPDATE public.trades
     SET group_id = NULL, updated_at = now()
   WHERE user_id = v_uid AND group_id = p_group_id;
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  -- archive (preserve) the group row — never deleted
  UPDATE public.trade_groups
     SET archived_at = now(), updated_at = now()
   WHERE id = p_group_id AND user_id = v_uid;

  RETURN json_build_object('ok',true,'group_id',p_group_id,'archived',true,
                           'already_archived',false,'cleared',v_cleared,'child_ids',v_ids);
END $$;

REVOKE ALL     ON FUNCTION public.ungroup_trade_group_v1(uuid) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.ungroup_trade_group_v1(uuid) TO authenticated;


-- ===========================================================================
-- VERIFICATION QUERIES (SELECT-only — safe to run; read-only)
-- ===========================================================================
-- VP. Preflight (must succeed before applying §4/§5):
--   SELECT encode(sha256(convert_to('g2-preflight','UTF8')), 'hex');
--
-- V1. idempotency_key column exists:
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--   WHERE table_schema='public' AND table_name='trade_groups' AND column_name='idempotency_key';
--
-- V2. unique ACTIVE partial index exists:
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname='public' AND indexname='trade_groups_user_idem_active_uidx';
--   -- indexdef must include WHERE (archived_at IS NULL AND idempotency_key IS NOT NULL) and UNIQUE.
--
-- V3. trigger present with the right event:
--   SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger
--   WHERE tgrelid='public.trades'::regclass AND tgname='trades_group_id_owner_guard_trg';
--   -- must be BEFORE INSERT OR UPDATE OF group_id.
--
-- V4. functions are SECURITY DEFINER with locked search_path + auth-only EXECUTE:
--   SELECT p.proname, p.prosecdef, p.proconfig,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_exec,
--          has_function_privilege('anon',          p.oid, 'EXECUTE') AS anon_exec
--   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--   WHERE n.nspname='public' AND p.proname IN ('create_trade_group_v1','ungroup_trade_group_v1');
--   -- Expected: prosecdef=t; proconfig includes search_path=public, pg_temp; auth_exec=t; anon_exec=f.
--
-- V5. baseline still clean before first use:
--   SELECT count(*) FROM public.trade_groups;                          -- 0 until first create
--   SELECT count(*) FROM public.trades WHERE group_id IS NOT NULL;     -- 0 until first create


-- ===========================================================================
-- ROLLBACK — drops ONLY the new G2 objects. Commented; run only to remove G2
-- persistence. Leaves G1 (trade_groups table, group_id column, simple FK, RLS)
-- intact. The optional data clear is DESTRUCTIVE — DO NOT RUN without review.
-- ===========================================================================
-- BEGIN;
--   DROP FUNCTION IF EXISTS public.create_trade_group_v1(text[], text);
--   DROP FUNCTION IF EXISTS public.ungroup_trade_group_v1(uuid);
--   DROP TRIGGER  IF EXISTS trades_group_id_owner_guard_trg ON public.trades;
--   DROP FUNCTION IF EXISTS public.trades_group_id_owner_guard();
--   DROP INDEX    IF EXISTS public.trade_groups_user_idem_active_uidx;
--   ALTER TABLE   public.trade_groups DROP COLUMN IF EXISTS idempotency_key;
-- COMMIT;
--
-- -- OPTIONAL, DESTRUCTIVE — DO NOT RUN without review (clears G2 grouping data):
-- --   UPDATE public.trades SET group_id = NULL WHERE group_id IS NOT NULL;
-- --   DELETE FROM public.trade_groups WHERE idempotency_key IS NOT NULL;
-- ===========================================================================
