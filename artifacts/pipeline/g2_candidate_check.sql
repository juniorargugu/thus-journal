-- ===========================================================================
-- G2 candidate check — READ-ONLY diagnostics (SELECT only)
--
-- Purpose: confirm whether an eligible G2 grouping candidate exists, and verify
-- the raw-vs-projected invariant, WITHOUT writing anything.
--
-- AUTOPILOT: do NOT run SQL. Hand these queries to Junior / the Supabase SQL
-- Editor, or run the eligible-candidate logic read-only via PostgREST. These are
-- SELECTs only — no BEGIN/commit, no writes, no RPC.
--
-- IMPORTANT MODEL NOTE:
--   G2 groups **Journal rows** (each public.trades row = one Journal position),
--   NOT contracts inside a single row. A single trade row holding N contracts is
--   ONE leg. A group needs >= 2 separate open Journal rows of the same product
--   family + direction. Do not confuse "3 contracts" (one row) with "3 legs".
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Eligible candidate query
--    Groups open, ungrouped rows by (user, product family, direction).
--    family_key strips the "_next" suffix so e.g. gold_next collapses to gold.
--    A candidate needs >= 2 legs. smoke_child_ids = first two ids (for a smoke).
-- ---------------------------------------------------------------------------
WITH candidates AS (
  SELECT
    user_id,
    regexp_replace(product_id, '_next$', '') AS family_key,
    direction,
    array_agg(id ORDER BY id)          AS child_ids,
    count(*)                            AS leg_count,
    array_agg(product_id ORDER BY id)  AS product_ids,
    array_agg(contracts ORDER BY id)   AS contracts
  FROM public.trades
  WHERE status = 'open'
    AND group_id IS NULL
    AND product_id IS NOT NULL
    AND btrim(product_id) <> ''
    AND direction IS NOT NULL
    AND btrim(direction) <> ''
  GROUP BY user_id, regexp_replace(product_id, '_next$', ''), direction
  HAVING count(*) >= 2
)
SELECT
  user_id,
  family_key,
  direction,
  child_ids[1:2] AS smoke_child_ids,
  product_ids,
  contracts,
  leg_count
FROM candidates
ORDER BY leg_count DESC, family_key, direction;


-- ---------------------------------------------------------------------------
-- 2. Raw-vs-projected diagnostic
--    Confirms group_id lives ONLY in the projected column and NOT in raw jsonb,
--    so reducers (which walk trades.raw) never see grouping and P/L stays exact.
--    Expected: raw_has_group_id = false for every row; projected product_id /
--    direction / status agree with the raw values.
--    (Edit the family_key / direction filter to match the candidate of interest.)
-- ---------------------------------------------------------------------------
SELECT
  id,
  product_id,
  direction,
  status,
  group_id,
  (raw ? 'group_id')  AS raw_has_group_id,   -- expected: false
  raw->>'productId'   AS raw_product_id,
  raw->>'direction'   AS raw_direction,
  raw->>'status'      AS raw_status
FROM public.trades
WHERE status = 'open'
  AND regexp_replace(product_id, '_next$', '') = 'gold'
  AND direction = 'Long'
ORDER BY id;


-- ---------------------------------------------------------------------------
-- 3. Baseline sanity (should be 0 / 0 until a real create is committed)
-- ---------------------------------------------------------------------------
SELECT
  (SELECT count(*) FROM public.trade_groups)                             AS trade_groups_count,
  (SELECT count(*) FROM public.trades WHERE group_id IS NOT NULL)        AS grouped_trades_count;
