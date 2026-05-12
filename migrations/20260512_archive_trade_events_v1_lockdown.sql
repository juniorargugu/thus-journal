-- 20260512: archive-in-place lockdown for legacy GUGU v1 public.trade_events
--
-- DO NOT RUN AUTOMATICALLY. Junior runs this manually in the Supabase SQL
-- Editor AFTER the app patch that disables Journal writes to trade_events is
-- deployed and verified. Running before deploy can break the still-deployed
-- old build that may try to INSERT.
--
-- ---------------------------------------------------------------------------
-- Context (2026-05-12)
--
-- Inspection of public.trade_events schema:
--   id              uuid
--   created_at      timestamptz
--   event_type      text
--   symbol          text
--   tier            text
--   detail          jsonb
--   message_sent    text
--   error           text
--   junior_feedback text
--
-- No user_id, no trade_id columns. This is NOT the Journal trade-lifecycle
-- audit shape that the SPA's `tradeEvents.insert(...)` writer assumed. It is
-- the legacy GUGU v1 bot event/feedback log.
--
-- A snapshot was already taken:
--   public.trade_events_backup_20260512 (3066 rows, RLS-locked, anon/auth
--   revoked). Keep for >=7 stable days, then drop only on explicit Junior
--   approval.
--
-- This migration:
--   - PRESERVES the table and all rows (no drop, no rename, no truncate)
--   - REMOVES any permissive RLS policies if present (idempotent)
--   - REVOKES anon/authenticated grants so service role is the only way in
--   - DOCUMENTS the archive status in COMMENT ON TABLE
--
-- This migration does NOT:
--   - drop public.trade_events
--   - drop public.trade_events_backup_20260512
--   - rename either table
--   - delete any rows
--   - add user_id, trade_id, or backfill anything
--   - touch public.trades, public.checkin_events, or any active table
-- ---------------------------------------------------------------------------

-- 1. Remove permissive policies if any were ever created. Names are best-effort
--    guesses for the v1 era; DROP POLICY IF EXISTS is a no-op for missing ones.
DROP POLICY IF EXISTS anon_insert_only      ON public.trade_events;
DROP POLICY IF EXISTS anon_update_feedback  ON public.trade_events;
DROP POLICY IF EXISTS trade_events_own_rows ON public.trade_events;
DROP POLICY IF EXISTS trade_events_read     ON public.trade_events;
DROP POLICY IF EXISTS trade_events_write    ON public.trade_events;

-- 2. Make sure RLS is on. With no surviving policies and RLS on, anon and
--    authenticated cannot read or write the table; only service_role bypasses.
ALTER TABLE public.trade_events ENABLE ROW LEVEL SECURITY;

-- 3. Revoke direct grants from the PostgREST-exposed roles. This is the
--    primary lockdown — even if a policy is added later by accident, the role
--    has no privilege to act on the table without an explicit re-GRANT.
REVOKE ALL ON public.trade_events FROM anon;
REVOKE ALL ON public.trade_events FROM authenticated;

-- 4. Documentation. Future readers should see why this table is frozen.
COMMENT ON TABLE public.trade_events IS
  'Archived GUGU v1 event/feedback log (as of 2026-05-12). Schema = '
  '(id uuid, created_at timestamptz, event_type text, symbol text, tier text, '
  'detail jsonb, message_sent text, error text, junior_feedback text). '
  'Preserved for historical reference only. THUS Journal must NOT write here; '
  'the in-app `tradeEvents.insert()` writer is converted to a no-op stub in '
  'index.html as of the same date. Capture Bot v0.1 uses checkin_events, not '
  'this table. Access only via service role / admin. Snapshot copy: '
  'public.trade_events_backup_20260512 (3066 rows, RLS-locked).';

-- ---------------------------------------------------------------------------
-- Verification (run after the above):
--
--   SELECT COUNT(*) FROM public.trade_events;
--     -- expect 3066 (or higher if old build wrote a few more before deploy)
--
--   SELECT polname FROM pg_policies WHERE schemaname='public' AND tablename='trade_events';
--     -- expect 0 rows
--
--   SELECT has_table_privilege('anon','public.trade_events','SELECT');
--   SELECT has_table_privilege('authenticated','public.trade_events','INSERT');
--     -- both expect f (false)
--
-- ---------------------------------------------------------------------------
-- Backup cleanup reminder (DO NOT RUN until >=7 stable days AND Junior asks):
--
--   DROP TABLE public.trade_events_backup_20260512;
--
-- ---------------------------------------------------------------------------
-- Rollback (re-open the table — only if a legitimate consumer is identified):
--
--   GRANT SELECT, INSERT, UPDATE, DELETE ON public.trade_events TO authenticated;
--   GRANT SELECT                          ON public.trade_events TO anon;
--   -- Define explicit, scoped policies BEFORE granting. Do not re-open
--   -- without a written reason and a policy review.
--
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- Optional DB documentation for public.bot_knowledge (report-only — Junior
-- can run if desired; not required because RLS is already on with zero
-- policies, so anon/authenticated access is already denied by default).
-- ===========================================================================
--
-- COMMENT ON TABLE public.bot_knowledge IS
--   'Archived GUGU v1 knowledge base (as of 2026-05-12). 80 historical rows '
--   'preserved. RLS is enabled with zero policies, so anon/authenticated '
--   'access is already denied by default. THUS Journal realtime subscription '
--   'on this table was removed in the same patch. Capture Bot v0.1 uses '
--   'checkin_events for similar surfaces. Access only via service role / admin.';
