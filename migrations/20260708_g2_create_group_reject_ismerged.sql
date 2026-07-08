-- ===========================================================================
-- G2 RPC-side isMerged hardening — create_trade_group_v1 defense-in-depth
-- Migration: 20260708_g2_create_group_reject_ismerged.sql
--
-- WHAT THIS DOES
--   Function-body-only CREATE OR REPLACE of public.create_trade_group_v1(text[], text).
--   Adds ONE new business error, `merged_child_not_allowed`, so the RPC rejects any child
--   whose raw jsonb has `isMerged` truthy (legacy merged rows must never be grouped). The UI
--   already excludes isMerged candidates (b1f8e7d, ROADMAP #184); this closes the gap at the DB.
--
--   Exactly three additions vs migrations/20260705_g2_trade_group_rpcs.sql (§4):
--     1. DECLARE  v_merged int;
--     2. §2 locked-row aggregate: one extra FILTER counting isMerged-truthy rows -> v_merged,
--        using a crash-safe text compare: lower(btrim(coalesce(raw->>'isMerged',''))) = 'true'
--        (null raw / missing key / 'false' -> allowed; boolean true or string "true" -> rejected;
--         never throws, unlike (raw->>'isMerged')::boolean on legacy non-boolean text).
--     3. §3 unconditional validations: reject when v_merged <> 0 (BEFORE idempotency/already_grouped).
--   Everything else is byte-identical to the reviewed 20260705 body.
--
-- WHAT THIS DOES NOT TOUCH
--   - Signature, RETURNS json, LANGUAGE plpgsql, SECURITY DEFINER, SET search_path = public, pg_temp.
--   - Grants (the REVOKE/GRANT below re-assert the existing authenticated-only EXECUTE, unchanged).
--   - No schema / table / column / index change. ungroup_trade_group_v1 is NOT modified.
--   - `raw` is still never mutated by the RPC (P/L invariant preserved).
--
-- SEQUENCING / SAFETY (design: ../artifacts/g2_grouping/g2_rpc_ismerged_hardening_design.md, ChatGPT PASS)
--   - Apply AFTER the v0.4 deploy (done: prod f01eb33 / v3.23.0) and BEFORE enabling the write gate.
--   - MANDATORY read-only precheck FIRST — it must return 0. See
--     ../artifacts/g2_grouping/g2_rpc_ismerged_hardening_validation.sql (Section A):
--       0 active grouped children with raw->>'isMerged' truthy. If > 0, STOP and review (the merged
--       check is unconditional/before idempotency, so a pre-existing active-grouped merged child would
--       change that group's re-click from already_exists to merged_child_not_allowed).
--   - Recommended apply: run the validation transaction (BEGIN ... tests ... ROLLBACK) first to dry-run,
--     then apply this file standalone and COMMIT. SQL apply is USER-RUN in the Supabase SQL Editor.
--     THIS FILE IS NOT AUTO-APPLIED.
--
-- ROLLBACK
--   Function-body-only; no data/schema touched. To revert, re-apply the prior create_trade_group_v1
--   body verbatim from migrations/20260705_g2_trade_group_rpcs.sql (lines 137–290) with CREATE OR
--   REPLACE. Instant, zero data risk (no rows touched by the definition change).
-- ===========================================================================

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
  v_merged       int;                                   -- ADDED (isMerged hardening): count of legacy merged children
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
         count(*) FILTER (WHERE lower(btrim(coalesce(raw->>'isMerged',''))) = 'true'),  -- ADDED: legacy merged rows
         count(*) FILTER (WHERE product_id IS NULL OR btrim(product_id) = ''
                             OR btrim(regexp_replace(product_id, '_next$', '')) = ''),
         count(*) FILTER (WHERE direction  IS NULL OR btrim(direction)  = ''),
         count(DISTINCT regexp_replace(product_id, '_next$', '')),
         count(DISTINCT direction),
         min(regexp_replace(product_id, '_next$', '')),
         min(direction)
    INTO v_found, v_open, v_grouped, v_merged, v_missing_prod, v_missing_dir,
         v_fam, v_dir, v_family, v_direction
    FROM public.trades
   WHERE user_id = v_uid AND id = ANY(v_ids);

  -- 3. unconditional validations (apply to BOTH re-click and create paths) ---
  IF v_found        <> v_n THEN RETURN json_build_object('ok',false,'error','child_not_found');   END IF;
  IF v_open         <> v_n THEN RETURN json_build_object('ok',false,'error','not_open');           END IF;
  IF v_merged       <> 0   THEN RETURN json_build_object('ok',false,'error','merged_child_not_allowed'); END IF;  -- ADDED: reject legacy merged rows (defense-in-depth; before idempotency/already_grouped)
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

-- Grants unchanged from 20260705 — re-asserted for a self-contained migration (authenticated-only).
REVOKE ALL     ON FUNCTION public.create_trade_group_v1(text[], text) FROM public, anon;
GRANT  EXECUTE ON FUNCTION public.create_trade_group_v1(text[], text) TO authenticated;
