-- ===========================================================================
-- G2 RPC isMerged hardening — VALIDATION SQL / runbook (read-only precheck + BEGIN/ROLLBACK tests)
-- Pairs with migration: ../../migrations/20260708_g2_create_group_reject_ismerged.sql
--
-- ⚠ DO NOT COMMIT ANYTHING FROM THIS FILE. Section B runs entirely inside BEGIN ... ROLLBACK,
--   so NO production data (and no function change) persists. The real apply of the migration is a
--   SEPARATE, USER-RUN step in the Supabase SQL Editor (BEGIN ... paste migration ... COMMIT) and
--   only after Section A returns 0.
-- ⚠ This file is documentation/runbook — running it is the USER's decision. Nothing here is executed
--   by the assistant. No writes, no COMMIT.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- SECTION A — MANDATORY read-only precheck (run FIRST, standalone). EXPECT 0.
-- If this returns > 0, STOP and review before applying the migration: the merged
-- check is unconditional (runs before idempotency), so a pre-existing active-grouped
-- merged child would flip that group's re-click from already_exists -> merged_child_not_allowed.
-- ---------------------------------------------------------------------------
SELECT count(*) AS active_merged_grouped_children
  FROM public.trades t
  JOIN public.trade_groups g
    ON g.id = t.group_id AND g.archived_at IS NULL
 WHERE t.group_id IS NOT NULL
   AND lower(btrim(coalesce(t.raw->>'isMerged',''))) = 'true';
-- EXPECT: active_merged_grouped_children = 0  (current known DB state: 0 active groups / 0 grouped).


-- ---------------------------------------------------------------------------
-- SECTION B — BEGIN/ROLLBACK behavior tests (no persistence).
--
-- HOW TO RUN (Supabase SQL Editor), as a NO-PERSIST dry-run of the NEW function:
--   1. Type  BEGIN;
--   2. Paste the entire CREATE OR REPLACE FUNCTION public.create_trade_group_v1(...) $$ ... $$;
--      block from ../../migrations/20260708_g2_create_group_reject_ismerged.sql  (this makes the
--      NEW behavior active INSIDE the transaction; the ROLLBACK at the end reverts it).
--   3. Run the test statements below.
--   4. End with  ROLLBACK;   (reverts the function change AND all test rows — nothing persists).
--
-- (If you instead already COMMITted the migration, you may skip step 2 and just run BEGIN; <tests>; ROLLBACK;
--  against the installed function.)
--
-- NOTE ON TEST ROWS: the INSERTs below set the columns the RPC reads (id, user_id, product_id,
--   direction, status, raw) plus contracts/remaining_contracts. If your public.trades has additional
--   NOT NULL columns without defaults, add them to the INSERTs (values are irrelevant to these tests).
-- ---------------------------------------------------------------------------

BEGIN;

-- (dry-run only) PASTE the migration's CREATE OR REPLACE FUNCTION block here so the new
-- merged_child_not_allowed behavior is active within this transaction. Omit if already applied.

-- Simulate an authenticated user (transaction-local; auth.uid() reads request.jwt.claims->>'sub').
SELECT set_config('request.jwt.claims',
                  json_build_object('sub','00000000-0000-0000-0000-0000000000aa')::text, true);

-- Synthetic owned OPEN trades, all same family (GOU26) + direction (Long):
INSERT INTO public.trades (id, user_id, product_id, direction, status, contracts, remaining_contracts, raw) VALUES
  ('g2v_merged', '00000000-0000-0000-0000-0000000000aa', 'GOU26', 'Long', 'open', 1, 1,
     '{"id":"g2v_merged","isMerged":true}'::jsonb),          -- legacy merged (boolean true) -> must reject
  ('g2v_plain1', '00000000-0000-0000-0000-0000000000aa', 'GOU26', 'Long', 'open', 1, 1,
     '{"id":"g2v_plain1","isMerged":false}'::jsonb),         -- isMerged false -> allowed
  ('g2v_plain2', '00000000-0000-0000-0000-0000000000aa', 'GOU26', 'Long', 'open', 1, 1,
     '{"id":"g2v_plain2"}'::jsonb),                          -- isMerged key absent -> allowed
  ('g2v_plain3', '00000000-0000-0000-0000-0000000000aa', 'GOU26', 'Long', 'open', 1, 1,
     '{"id":"g2v_plain3","isMerged":null}'::jsonb);          -- isMerged null -> allowed

-- T1 (negative) merged + plain -> merged_child_not_allowed
SELECT 'T1 merged+plain -> reject' AS test,
       public.create_trade_group_v1(ARRAY['g2v_merged','g2v_plain1']) AS result;
-- EXPECT: {"ok":false,"error":"merged_child_not_allowed"}

-- T2 (negative) mixed merged + 2 plain -> merged_child_not_allowed (single code, not per-child)
SELECT 'T2 merged+plain+plain -> reject' AS test,
       public.create_trade_group_v1(ARRAY['g2v_merged','g2v_plain1','g2v_plain2']) AS result;
-- EXPECT: {"ok":false,"error":"merged_child_not_allowed"}

-- T3 (allowed) false + absent isMerged -> creates a group
SELECT 'T3 plain1+plain2 -> create' AS test,
       public.create_trade_group_v1(ARRAY['g2v_plain1','g2v_plain2']) AS result;
-- EXPECT: {"ok":true,...,"created":true,...}

-- T4 (regression) already_grouped is UNAFFECTED: plain1 now grouped, plain3 not; both non-merged so the
-- merged check passes and control reaches the already_grouped gate.
SELECT 'T4 plain1(grouped)+plain3 -> already_grouped' AS test,
       public.create_trade_group_v1(ARRAY['g2v_plain1','g2v_plain3']) AS result;
-- EXPECT: {"ok":false,"error":"already_grouped",...}

-- T5 (regression) duplicate_child_ids still fires FIRST (§0), before the merged check
SELECT 'T5 dup ids -> duplicate_child_ids' AS test,
       public.create_trade_group_v1(ARRAY['g2v_plain3','g2v_plain3']) AS result;
-- EXPECT: {"ok":false,"error":"duplicate_child_ids"}

-- T6 (regression) ungroup is UNCHANGED by this migration: dissolve the T3 group.
SELECT 'T6 ungroup T3 group' AS test,
       public.ungroup_trade_group_v1(
         (SELECT id FROM public.trade_groups
           WHERE user_id = '00000000-0000-0000-0000-0000000000aa' AND archived_at IS NULL
           ORDER BY created_at DESC LIMIT 1)) AS result;
-- EXPECT: {"ok":true,...,"archived":true,"cleared":2,...}; children group_id back to NULL.

-- Confirm nothing is left grouped in-transaction (sanity):
SELECT 'post-ungroup grouped count' AS check,
       count(*) FILTER (WHERE group_id IS NOT NULL) AS grouped
  FROM public.trades WHERE user_id = '00000000-0000-0000-0000-0000000000aa';
-- EXPECT: grouped = 0

ROLLBACK;   -- reverts ALL test rows + (if pasted) the function change. NOTHING PERSISTS.

-- ---------------------------------------------------------------------------
-- SUMMARY OF EXPECTED RESULTS
--   Section A precheck            : 0
--   T1 merged+plain               : merged_child_not_allowed
--   T2 merged+plain+plain         : merged_child_not_allowed
--   T3 plain1+plain2              : ok / created  (false + absent isMerged allowed; null also allowed via T4/T5 setup)
--   T4 plain1(grouped)+plain3     : already_grouped   (merged check does not shadow it for non-merged)
--   T5 dup ids                    : duplicate_child_ids  (fires before the merged check)
--   T6 ungroup                    : ok / archived / cleared 2   (ungroup RPC unchanged)
--   post-ungroup grouped          : 0
-- If all match, the migration is safe to apply (COMMIT) in a SEPARATE user-run step.
-- ---------------------------------------------------------------------------
