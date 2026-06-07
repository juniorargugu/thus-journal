-- 20260607: G1 — non-destructive trade grouping schema + RLS
--
-- DO NOT RUN AUTOMATICALLY. Junior runs this manually in the Supabase SQL
-- Editor after reviewing each block. This migration is the G1 step of the
-- non-destructive trade-grouping rollout locked in ROADMAP.md:87-210
-- (commit 05105ce, 2026-05-20). G1 is SCHEMA + RLS ONLY. It does not change
-- application behaviour. No app code reads or writes group_id yet.
--
-- ---------------------------------------------------------------------------
-- Gates satisfied before this packet was drafted (see
-- artifacts/merge_grouping/gate_1_2_junior_attestation_20260605.md, commit
-- c796db3):
--
--   Gate 1 — clean persistence logs (>=14 days, no upserted-affected=0/N) — PASS
--   Gate 2 — Block 5 delete-the-last-trade behaviour                       — PASS
--             (via deployed-source code-path reasoning over
--             index.html:230-247; no destructive smoke)
--
-- Gates still pending after this migration is applied:
--
--   Gate 4 — Junior reviews migration SQL in Supabase SQL Editor
--             before running (THIS DOCUMENT)
--   Gate 5 — P/L snapshot baseline captured before G2 UI work begins
--
-- ---------------------------------------------------------------------------
-- What this migration does
--
--   1. CREATE TABLE public.trade_groups (idempotent).
--   2. ALTER TABLE public.trades ADD COLUMN group_id (idempotent).
--   3. Add FK trades.group_id -> trade_groups.id ON DELETE SET NULL
--      (idempotent via DO block — Postgres has no ADD CONSTRAINT IF NOT EXISTS).
--   4. Create three indexes (idempotent via CREATE INDEX IF NOT EXISTS).
--   5. ENABLE RLS on trade_groups.
--   6. Drop+create four policies (SELECT/INSERT/UPDATE/DELETE) gated on
--      user_id = auth.uid(). Idempotent via DROP POLICY IF EXISTS.
--   7. GRANT SELECT/INSERT/UPDATE/DELETE to authenticated and service_role.
--      REVOKE ALL from anon (explicit, even though anon has no default access).
--   8. COMMENT ON TABLE for future readers.
--
-- What this migration deliberately does NOT do
--
--   - No data backfill. No INSERT into trade_groups. No UPDATE to trades.
--   - No app-visible behaviour change. group_id stays NULL on every row.
--   - No triggers. updated_at is app-managed for v0.1, mirroring the
--     existing portfolio / notes / products / user_data convention (which
--     also has no DB-side updated_at trigger).
--   - No changes to public.trades column set, constraints, indexes, or RLS
--     beyond adding the single group_id column + FK + composite index.
--   - No changes to any other table.
--   - No GUGU / Capture Bot tables touched.
--
-- Idempotency goal: this entire migration can be safely re-run in the
-- Supabase SQL Editor without raising errors and without producing
-- duplicate objects.
--
-- ---------------------------------------------------------------------------
-- Inputs reviewed while authoring this migration
--
--   ROADMAP.md:87-210                              — locked G0 design
--   artifacts/merge_grouping/merge_grouping_reentry_audit.md       (a332f14)
--   artifacts/merge_grouping/merge_grouping_gate_1_2_evidence.md   (d2c5c28)
--   artifacts/merge_grouping/gate_1_2_junior_attestation_20260605.md (c796db3)
--   migrations/20260512_archive_trade_events_v1_lockdown.sql   — style precedent
--   index.html:228-273                              — db.saveTrades shape
--   index.html:185-227                              — db.loadAll shape
--   memory: reference_thus_journal_trades_pk        — trades_pkey is compound
--                                                     (id, user_id) with a
--                                                     separate UNIQUE(id);
--                                                     trade_groups uses its own
--                                                     simple uuid PRIMARY KEY,
--                                                     so the FK does not need
--                                                     any compound-FK shape.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0. Required extensions
--
-- gen_random_uuid() lives in pgcrypto. Supabase enables pgcrypto by default,
-- but make the dependency explicit and idempotent.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. CREATE TABLE public.trade_groups
--
-- Columns per ROADMAP.md:95.
--
-- - id              uuid PK, default gen_random_uuid()
-- - user_id         uuid NOT NULL, FK auth.users(id), cascade delete on user
--                    deletion (same shape as the existing trades table user
--                    relationship)
-- - label           text NOT NULL — auto-suggested on create, user-editable.
--                    Display-only metadata; no reducer reads it (locked
--                    P/L invariant).
-- - group_pre_note  text NULL — used in G4. Stays NULL in v0.1.
-- - group_post_note text NULL — used in G4. Stays NULL in v0.1.
-- - created_at      timestamptz NOT NULL DEFAULT now()
-- - updated_at      timestamptz NOT NULL DEFAULT now()
--                    App-managed in client writes (mirrors portfolio/notes/
--                    products/user_data which all carry an app-set updated_at).
-- - archived_at     timestamptz NULL — non-destructive ungroup sets this.
--                    archived_at IS NULL means "active group".
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trade_groups (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label           text        NOT NULL,
  group_pre_note  text,
  group_post_note text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  archived_at     timestamptz
);

-- ---------------------------------------------------------------------------
-- 2. ALTER TABLE public.trades — add the dormant group_id column
--
-- Column is nullable; default NULL. No backfill. Existing rows continue to
-- behave identically. db.saveTrades will only start writing this field once
-- a G2/G3 PR opts in.
-- ---------------------------------------------------------------------------
ALTER TABLE public.trades
  ADD COLUMN IF NOT EXISTS group_id uuid;

-- ---------------------------------------------------------------------------
-- 3. ADD CONSTRAINT trades_group_id_fkey
--
-- Postgres lacks ALTER TABLE ... ADD CONSTRAINT IF NOT EXISTS. Use a DO
-- block guarded on pg_constraint so the migration is re-run safe.
--
-- ON DELETE SET NULL: dropping a trade_groups row clears every child's
-- group_id without cascading deletion to trades. Matches the locked
-- non-destructive ungroup semantics.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class      r ON r.oid = c.conrelid
    JOIN pg_namespace  n ON n.oid = r.relnamespace
    WHERE c.conname = 'trades_group_id_fkey'
      AND n.nspname = 'public'
      AND r.relname = 'trades'
  ) THEN
    ALTER TABLE public.trades
      ADD CONSTRAINT trades_group_id_fkey
      FOREIGN KEY (group_id)
      REFERENCES public.trade_groups(id)
      ON DELETE SET NULL;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Indexes
--
-- - trade_groups_user_id_idx
--     Per-user reads (loadAll batch). Mirrors the implicit per-user access
--     pattern of trades.
--
-- - trade_groups_user_active_idx
--     Partial index for the most common UI query: "active groups for this
--     user" (archived_at IS NULL). Keeps the index narrow.
--
-- - trades_group_id_idx
--     Partial index on (user_id, group_id) where group_id IS NOT NULL.
--     Supports "fetch children of group g for current user" without
--     scanning the entire trades table or indexing rows that will never
--     match the predicate. user_id is included as the leading column to
--     align with the per-user query pattern used everywhere else.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS trade_groups_user_id_idx
  ON public.trade_groups (user_id);

CREATE INDEX IF NOT EXISTS trade_groups_user_active_idx
  ON public.trade_groups (user_id)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS trades_group_id_idx
  ON public.trades (user_id, group_id)
  WHERE group_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Enable RLS
--
-- Idempotent — re-enabling RLS is a no-op if it is already on. Without any
-- policy and with RLS on, no role except service_role can access rows.
-- ---------------------------------------------------------------------------
ALTER TABLE public.trade_groups ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 6. Policies
--
-- Mirror of the existing trades policy (user_id = auth.uid()).
-- INSERT uses WITH CHECK; SELECT/UPDATE/DELETE use USING; UPDATE also uses
-- WITH CHECK to block flipping user_id to another user.
--
-- Idempotency: DROP POLICY IF EXISTS first, then CREATE POLICY. Safe to
-- re-run. Naming: <table>_<verb>_own_rows so future audits can grep cleanly.
-- ---------------------------------------------------------------------------

-- SELECT
DROP POLICY IF EXISTS trade_groups_select_own_rows ON public.trade_groups;
CREATE POLICY trade_groups_select_own_rows
  ON public.trade_groups
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- INSERT
DROP POLICY IF EXISTS trade_groups_insert_own_rows ON public.trade_groups;
CREATE POLICY trade_groups_insert_own_rows
  ON public.trade_groups
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- UPDATE
DROP POLICY IF EXISTS trade_groups_update_own_rows ON public.trade_groups;
CREATE POLICY trade_groups_update_own_rows
  ON public.trade_groups
  FOR UPDATE
  TO authenticated
  USING      (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- DELETE
DROP POLICY IF EXISTS trade_groups_delete_own_rows ON public.trade_groups;
CREATE POLICY trade_groups_delete_own_rows
  ON public.trade_groups
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 7. GRANTs
--
-- Supabase exposes anon, authenticated, and service_role via PostgREST.
--
-- - authenticated: SELECT/INSERT/UPDATE/DELETE, gated by the policies above.
-- - service_role : SELECT/INSERT/UPDATE/DELETE; service_role bypasses RLS
--                   by default, so this is mostly explicit documentation,
--                   plus future-proofing in case the default changes.
-- - anon         : no access. Explicit REVOKE ALL so the lockdown is visible
--                   to anyone reading the migration. Mirrors the v1
--                   trade_events lockdown style.
--
-- Sequence grants: not needed. id uses gen_random_uuid(); no sequence.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.trade_groups TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.trade_groups TO service_role;
REVOKE ALL ON public.trade_groups FROM anon;

-- ---------------------------------------------------------------------------
-- 8. Documentation
-- ---------------------------------------------------------------------------
COMMENT ON TABLE public.trade_groups IS
  'Non-destructive trade grouping (G1, 2026-06-07). Each row is a logical '
  'grouping of one or more child trades that share product family and '
  'direction. trades.group_id references trade_groups.id ON DELETE SET NULL. '
  'Group totals (qty, weighted entry, P/L, status) are derived at render '
  'time from the child rows; no totals are stored here. Ungroup sets '
  'archived_at = now() and clears children group_id. Locked design lives '
  'in ROADMAP.md (commit 05105ce). v0.1 = schema + RLS only; no app code '
  'reads or writes group_id at the time this migration is run.';

COMMENT ON COLUMN public.trades.group_id IS
  'Optional reference to public.trade_groups(id). NULL = ungrouped (the '
  'default). Set on group create; cleared on ungroup or when the parent '
  'trade_groups row is deleted (ON DELETE SET NULL). Reducers MUST ignore '
  'this column — all P/L totals walk raw trades[] and never read group_id. '
  'See ROADMAP.md "P/L invariant" (commit 05105ce).';

-- ===========================================================================
-- VERIFICATION QUERIES (SELECT-only — safe to run; re-run anytime)
--
-- Run each block in the Supabase SQL Editor after the migration completes,
-- and confirm the expected result before declaring G1 done.
-- ===========================================================================

-- V1. trade_groups table exists with expected columns
--
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM   information_schema.columns
-- WHERE  table_schema = 'public' AND table_name = 'trade_groups'
-- ORDER  BY ordinal_position;
--
-- Expected rows:
--   id              uuid        NO  gen_random_uuid()
--   user_id         uuid        NO  (null)
--   label           text        NO  (null)
--   group_pre_note  text        YES (null)
--   group_post_note text        YES (null)
--   created_at      timestamptz NO  now()
--   updated_at      timestamptz NO  now()
--   archived_at     timestamptz YES (null)

-- V2. trades.group_id column exists and is nullable
--
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM   information_schema.columns
-- WHERE  table_schema = 'public' AND table_name = 'trades' AND column_name = 'group_id';
--
-- Expected: one row, data_type = uuid, is_nullable = YES, column_default = NULL.

-- V3. FK constraint exists with the expected target and rule
--
-- SELECT conname,
--        pg_get_constraintdef(c.oid) AS definition
-- FROM   pg_constraint c
-- JOIN   pg_class      r ON r.oid = c.conrelid
-- JOIN   pg_namespace  n ON n.oid = r.relnamespace
-- WHERE  n.nspname = 'public'
--   AND  r.relname = 'trades'
--   AND  c.conname = 'trades_group_id_fkey';
--
-- Expected: one row whose definition includes
-- 'FOREIGN KEY (group_id) REFERENCES trade_groups(id) ON DELETE SET NULL'.

-- V4. Indexes exist
--
-- SELECT indexname, indexdef
-- FROM   pg_indexes
-- WHERE  schemaname = 'public'
--   AND  indexname IN (
--          'trade_groups_user_id_idx',
--          'trade_groups_user_active_idx',
--          'trades_group_id_idx'
--        )
-- ORDER  BY indexname;
--
-- Expected: 3 rows. trade_groups_user_active_idx and trades_group_id_idx
-- both include a 'WHERE' partial clause.

-- V5. RLS is enabled on trade_groups
--
-- SELECT relname, relrowsecurity, relforcerowsecurity
-- FROM   pg_class
-- WHERE  oid = 'public.trade_groups'::regclass;
--
-- Expected: relrowsecurity = t (true).

-- V6. Four policies exist on trade_groups
--
-- SELECT polname, polcmd, pg_get_expr(polqual, polrelid)      AS using_clause,
--                          pg_get_expr(polwithcheck, polrelid) AS check_clause
-- FROM   pg_policy
-- WHERE  polrelid = 'public.trade_groups'::regclass
-- ORDER  BY polname;
--
-- Expected: 4 rows named *_select_own_rows / *_insert_own_rows /
-- *_update_own_rows / *_delete_own_rows. All clauses reference
-- (user_id = auth.uid()).

-- V7. GRANTs as expected
--
-- SELECT has_table_privilege('anon',          'public.trade_groups', 'SELECT') AS anon_select,
--        has_table_privilege('anon',          'public.trade_groups', 'INSERT') AS anon_insert,
--        has_table_privilege('authenticated', 'public.trade_groups', 'SELECT') AS auth_select,
--        has_table_privilege('authenticated', 'public.trade_groups', 'INSERT') AS auth_insert,
--        has_table_privilege('authenticated', 'public.trade_groups', 'UPDATE') AS auth_update,
--        has_table_privilege('authenticated', 'public.trade_groups', 'DELETE') AS auth_delete,
--        has_table_privilege('service_role',  'public.trade_groups', 'SELECT') AS svc_select;
--
-- Expected: anon_*=false; all auth_* and svc_select = true.

-- V8. No data was written
--
-- SELECT COUNT(*) AS trade_groups_rows FROM public.trade_groups;
-- -- Expected: 0
--
-- SELECT COUNT(*) AS trades_with_group FROM public.trades WHERE group_id IS NOT NULL;
-- -- Expected: 0

-- V9. trades row count unchanged
--
-- Capture COUNT(*) FROM public.trades BEFORE running this migration, then
-- run the same query AFTER. Both numbers must match. If they differ, stop
-- and investigate immediately — the migration must not move trade rows.
--
-- SELECT COUNT(*) AS trades_rows FROM public.trades;

-- ===========================================================================
-- ROLLBACK (commented; do NOT run unless you intend to remove G1 entirely)
--
-- Safe only when:
--   * no trade row has group_id IS NOT NULL
--   * no trade_groups rows exist
--   * no deployed app build is reading or writing group_id / trade_groups
--
-- If groups have already been created in production, this rollback will
-- delete those group metadata rows (label, group_pre_note, group_post_note,
-- archived_at). Export them first or skip the rollback.
-- ===========================================================================
--
-- BEGIN;
--
-- -- Drop FK first so the column can be removed cleanly.
-- ALTER TABLE public.trades       DROP CONSTRAINT IF EXISTS trades_group_id_fkey;
--
-- -- Drop indexes.
-- DROP INDEX IF EXISTS public.trade_groups_user_id_idx;
-- DROP INDEX IF EXISTS public.trade_groups_user_active_idx;
-- DROP INDEX IF EXISTS public.trades_group_id_idx;
--
-- -- Drop policies (DROP POLICY IF EXISTS is idempotent).
-- DROP POLICY IF EXISTS trade_groups_select_own_rows ON public.trade_groups;
-- DROP POLICY IF EXISTS trade_groups_insert_own_rows ON public.trade_groups;
-- DROP POLICY IF EXISTS trade_groups_update_own_rows ON public.trade_groups;
-- DROP POLICY IF EXISTS trade_groups_delete_own_rows ON public.trade_groups;
--
-- -- Drop the table. CASCADE not used; we want failure if any unexpected
-- -- dependent object exists (forces operator to inspect before destroying).
-- DROP TABLE IF EXISTS public.trade_groups;
--
-- -- Finally drop the now-orphan column on trades.
-- ALTER TABLE public.trades DROP COLUMN IF EXISTS group_id;
--
-- COMMIT;
--
-- ===========================================================================
