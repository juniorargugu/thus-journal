# G1 — Trade Grouping Schema + RLS Migration Packet

**Status:** `G1_SCHEMA_RLS_PACKET_CREATED — REVIEW PENDING`

Generated 2026-06-07 BKK. SQL drafted only. **No SQL was executed.**
No Supabase write. No app code touched. No deploy. No push. No restart.

This packet is the draft Junior reviews **before** opening the Supabase SQL
Editor. It is intentionally one self-contained migration file plus this
companion review document. Junior is expected to read both end-to-end and
either approve in writing (a follow-up "run G1" task) or send back
revisions.

---

## 1. Executive summary

| Item | Value |
|---|---|
| Migration file created | `migrations/20260607_g1_trade_groups_schema.sql` |
| Migration applied? | **No.** Draft only. |
| App code changes? | **None.** |
| Supabase changes? | **None.** |
| Deploy / push / restart? | **None.** |
| New tables proposed | `public.trade_groups` |
| Altered tables proposed | `public.trades` (one new nullable column `group_id`) |
| New FKs | `trades_group_id_fkey` → `trade_groups(id) ON DELETE SET NULL` |
| New indexes | 3 |
| New policies | 4 (SELECT, INSERT, UPDATE, DELETE) |
| Triggers | **None** (intentional, matches existing conventions) |
| Idempotent? | Yes — every DDL block is guarded by `IF NOT EXISTS` or a `DO`/`DROP POLICY IF EXISTS` block. Safe to re-run. |
| Rollback included? | Yes — commented block at the bottom of the SQL file. |
| Verification queries included? | Yes — 9 SELECT-only blocks inline. |
| Source of truth for the design | `ROADMAP.md:87-210` (commit `05105ce`, 2026-05-20) |

This packet does **only** the minimum the locked design calls for and stops.
Nothing here is exploratory.

---

## 2. Inputs reviewed

Read-only inspection of:

- `ROADMAP.md` lines 85-211 — locked G0 design ("Trade Grouping Design
  Locked — 2026-05-20") and the pre-G1 gate list.
- `artifacts/merge_grouping/merge_grouping_reentry_audit.md` (commit
  `a332f14`) — re-entry audit. §4 ("Current trade persistence model"),
  §6 ("Non-destructive grouping data model — options"), §7
  ("Recommended v0.1 design"), §14 ("Recommended next step").
- `artifacts/merge_grouping/merge_grouping_gate_1_2_evidence.md`
  (commit `d2c5c28`) — gate evidence review.
- `artifacts/merge_grouping/gate_1_2_junior_attestation_20260605.md`
  (commit `c796db3`) — Junior attestation: Gate 1 **PASS**, Gate 2
  **PASS**, "G1 schema / RLS may proceed: YES".
- `migrations/20260512_archive_trade_events_v1_lockdown.sql` — the only
  prior migration in this repo. Used to anchor file naming, header
  style, verification/rollback layout, and `REVOKE ALL FROM anon` style.
- `index.html:185-227` (`db.loadAll`) and `index.html:228-273`
  (`db.saveTrades`) — confirmed the trades persistence shape: columnar
  fields + `raw` JSONB mirror, `onConflict:"id"` upsert, reconcile-delete
  bounded by `knownIds`, and the permanent `affected===0` tripwire.
- Repository search confirming no `trade_groups` / `group_id`
  references exist in current app code (zero readers, zero writers —
  appropriate for G1).
- Memory: `reference_thus_journal_trades_pk` — `trades_pkey` is
  compound `(id, user_id)`, but a separate `UNIQUE(id)` exists, so
  `onConflict:"id"` works and `trade_groups(id)` (a simple `uuid
  PRIMARY KEY`) can be referenced by `trades.group_id` without
  compound-FK gymnastics.

No production database was queried while authoring this packet.

---

## 3. Locked design requirements (verbatim summary)

From `ROADMAP.md:87-210`:

### Tables

- **`trade_groups`** with columns:
  `id uuid PK, user_id uuid, label text NOT NULL, group_pre_note text,
  group_post_note text, created_at, updated_at, archived_at nullable`.
- **`trades`** adds column:
  `group_id uuid REFERENCES trade_groups(id) ON DELETE SET NULL`.

### RLS

- `trade_groups` RLS rule mirrors trades: `user_id = auth.uid()`.

### Indexes

1. `trade_groups(user_id)`
2. `trade_groups(user_id) WHERE archived_at IS NULL`
3. `trades(group_id) WHERE group_id IS NOT NULL`

### Invariants the migration must preserve

- **`trades` rows remain the canonical execution records.** No data
  rewrite, no row creation, no row deletion.
- **`trade_groups` is metadata + group-level notes**, never a trade.
- **No synthetic group row ever inserted into `trades[]`.**
- **P/L invariant:** all reducers walk raw `trades[]` and ignore
  `group_id`. The migration enforces this implicitly by leaving
  `group_id` NULL on every row and writing zero rows to `trade_groups`.

### Non-goals for G1

> "G1 — Schema + RLS only. SQL applied via Supabase SQL Editor. No app
> reads or writes against the new table." (ROADMAP.md:191)

---

## 4. Migration file created

Path:

```
migrations/20260607_g1_trade_groups_schema.sql
```

Naming convention: `YYYYMMDD_<purpose>.sql`, matching the existing
`migrations/20260512_archive_trade_events_v1_lockdown.sql`. No
`supabase/migrations/` subdirectory is used in this repo, so the file
sits next to the existing precedent for discoverability.

The file is ~280 lines of heavily commented SQL. Every DDL block is
preceded by a comment block explaining what it does and why.

The file contains, in order:

| Section | Content |
|---|---|
| Header | DO-NOT-RUN-AUTOMATICALLY notice, gates satisfied, inputs reviewed, idempotency goal. |
| §0 Extensions | `CREATE EXTENSION IF NOT EXISTS pgcrypto` (for `gen_random_uuid()`). |
| §1 Table | `CREATE TABLE IF NOT EXISTS public.trade_groups (...)`. |
| §2 Column | `ALTER TABLE public.trades ADD COLUMN IF NOT EXISTS group_id uuid`. |
| §3 FK | `DO $$ ... ALTER TABLE ... ADD CONSTRAINT trades_group_id_fkey ... ON DELETE SET NULL ...`. |
| §4 Indexes | Three `CREATE INDEX IF NOT EXISTS`, two of which are partial. |
| §5 RLS enable | `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`. |
| §6 Policies | Four policies, each `DROP POLICY IF EXISTS` then `CREATE POLICY`. |
| §7 GRANTs | `GRANT ... TO authenticated, service_role`; `REVOKE ALL FROM anon`. |
| §8 Comments | `COMMENT ON TABLE public.trade_groups`, `COMMENT ON COLUMN public.trades.group_id`. |
| Verification | Nine inline SELECT-only blocks (V1–V9). |
| Rollback | Commented-out block to drop FK, indexes, policies, table, column. |

---

## 5. Schema details

### 5.1 `public.trade_groups`

```sql
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
```

Decisions and their reasons:

- `id uuid PRIMARY KEY` — simple PK (no compound) so `trades.group_id`
  can reference it without compound-FK gymnastics. Matches locked
  design.
- `user_id ... ON DELETE CASCADE` — mirrors the implicit behaviour for
  user-owned rows. Deleting a user removes their group metadata.
  Children (`trades.group_id`) get nulled separately via
  `trades_group_id_fkey ON DELETE SET NULL`. (Aligns with non-destructive
  rule: dropping the *group* should not drop the *trades*.)
- `label NOT NULL` — locked design says the label is auto-suggested on
  create, never empty. Forcing NOT NULL at the schema level prevents a
  buggy client from creating a labelless group.
- `group_pre_note` / `group_post_note` nullable — used in G4. G1 leaves
  them NULL.
- `created_at` / `updated_at` `DEFAULT now()` — keeps INSERT cheap.
  `updated_at` is app-managed for v0.1 (mirrors the existing convention
  in `portfolio` / `notes` / `products` / `user_data`, which also have
  no DB-side `updated_at` trigger).
- `archived_at` nullable — `IS NULL` means "active group". Ungroup sets
  this to `now()`. Non-destructive recovery is the explicit goal.

### 5.2 `public.trades` — new column only

```sql
ALTER TABLE public.trades
  ADD COLUMN IF NOT EXISTS group_id uuid;

-- (FK added separately via a DO block so the migration is re-run safe.)
ALTER TABLE public.trades
  ADD CONSTRAINT trades_group_id_fkey
  FOREIGN KEY (group_id)
  REFERENCES public.trade_groups(id)
  ON DELETE SET NULL;
```

Decisions:

- Column is nullable; default NULL. **No backfill.**
- FK uses `ON DELETE SET NULL` — dropping a group row clears children's
  `group_id` without cascading deletion. Matches the locked
  non-destructive ungroup semantics.
- No other column on `public.trades` is altered. No indexes on existing
  columns are touched. No data is moved.

### 5.3 Indexes

```sql
CREATE INDEX IF NOT EXISTS trade_groups_user_id_idx
  ON public.trade_groups (user_id);

CREATE INDEX IF NOT EXISTS trade_groups_user_active_idx
  ON public.trade_groups (user_id)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS trades_group_id_idx
  ON public.trades (user_id, group_id)
  WHERE group_id IS NOT NULL;
```

Decisions:

- `trade_groups_user_id_idx` — supports the per-user batch read folded
  into a future `loadAll` extension.
- `trade_groups_user_active_idx` — partial, mirrors the locked design
  ("active groups for this user"). Narrow index → small.
- `trades_group_id_idx` — composite `(user_id, group_id)` with a
  partial predicate. Leading `user_id` aligns with the per-user query
  pattern used everywhere else in the schema, and the partial clause
  keeps the index small (the vast majority of rows will have
  `group_id IS NULL` for a long time after G1 lands).

Naming follows existing Postgres conventions: `<table>_<columns>_idx`.

---

## 6. RLS and grants

### 6.1 Policies

`trade_groups` follows the standard Supabase pattern: one policy per
verb, each gated on `user_id = auth.uid()`, all granted to
`authenticated`.

```sql
ALTER TABLE public.trade_groups ENABLE ROW LEVEL SECURITY;

-- SELECT
CREATE POLICY trade_groups_select_own_rows
  ON public.trade_groups
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- INSERT
CREATE POLICY trade_groups_insert_own_rows
  ON public.trade_groups
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- UPDATE
CREATE POLICY trade_groups_update_own_rows
  ON public.trade_groups
  FOR UPDATE
  TO authenticated
  USING      (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- DELETE
CREATE POLICY trade_groups_delete_own_rows
  ON public.trade_groups
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());
```

Notes:

- `UPDATE` uses **both** `USING` and `WITH CHECK` so a row owner cannot
  flip `user_id` to another user mid-update.
- All policies idempotent via `DROP POLICY IF EXISTS` immediately
  before each `CREATE POLICY`.
- Naming pattern `<table>_<verb>_own_rows` is consistent across the
  four policies and greppable.

### 6.2 Grants

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON public.trade_groups TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.trade_groups TO service_role;
REVOKE ALL                            ON public.trade_groups FROM anon;
```

Decisions:

- `authenticated` gets the full CRUD set, gated by the policies above.
- `service_role` gets explicit CRUD even though it bypasses RLS by
  default. Two reasons:
  1. Self-documenting — anyone reading the migration sees the intended
     access set.
  2. Future-proofs against any Supabase change to default privileges.
- `anon` is explicitly revoked. This mirrors the v1 `trade_events`
  lockdown style and makes the lockdown visible.

No sequence grants are needed — the `id` column uses `gen_random_uuid()`,
which does not back a sequence.

### 6.3 No triggers

The locked design does not require any DB-side trigger, and the
existing tables (`portfolio`, `products`, `notes`, `user_data`) do
not use one. `updated_at` is set by `db.saveTradeGroups` in the same
way the existing app code sets `updated_at` on the other writable
tables. Adding a trigger now would be incidental, would couple the
schema to an internal naming convention that may not be desired
later, and would diverge from existing convention.

---

## 7. Idempotency notes

| Object | Idempotency mechanism |
|---|---|
| `CREATE EXTENSION pgcrypto` | `IF NOT EXISTS`. |
| `CREATE TABLE trade_groups` | `IF NOT EXISTS`. If the table exists with a divergent schema, this DDL will silently do nothing — see "open question #1" below. |
| `ALTER TABLE trades ADD COLUMN group_id` | `IF NOT EXISTS`. |
| `ADD CONSTRAINT trades_group_id_fkey` | Wrapped in a `DO` block that checks `pg_constraint` first. Postgres has no `ADD CONSTRAINT IF NOT EXISTS`. |
| Indexes | `CREATE INDEX IF NOT EXISTS`. |
| `ENABLE ROW LEVEL SECURITY` | No-op if already enabled. |
| Policies | `DROP POLICY IF EXISTS` immediately before each `CREATE POLICY`. |
| GRANT / REVOKE | Idempotent by definition (regranting the same set is a no-op). |
| `COMMENT ON` | Overwrites any prior comment idempotently. |

Re-running the entire migration in the SQL Editor produces zero errors
and zero new objects after the first successful run.

---

## 8. Verification SQL

All nine verification queries are inline in the migration file, kept as
comments so they do not execute as DDL. They are **SELECT-only** and
safe to run from the Supabase SQL Editor at any time after the
migration applies.

| # | Checks |
|---|---|
| V1 | `trade_groups` columns / types / defaults / nullability |
| V2 | `trades.group_id` exists and is nullable |
| V3 | FK `trades_group_id_fkey` exists with the right definition |
| V4 | Three indexes exist (the two partial ones include `WHERE`) |
| V5 | RLS is enabled on `trade_groups` |
| V6 | Four policies exist on `trade_groups`, all gated on `auth.uid()` |
| V7 | GRANTs are as expected (anon = false; authenticated + service_role = true) |
| V8 | `COUNT(*)` is 0 on `trade_groups`; 0 on `trades WHERE group_id IS NOT NULL` |
| V9 | `COUNT(*)` on `trades` is unchanged from the pre-migration baseline (Junior records BEFORE and AFTER values manually). |

V9 is the load-bearing "did the migration touch trade data?" check. If
the count moves, stop and investigate before doing anything else.

---

## 9. Rollback SQL

Rollback is **included only as a commented block** at the end of the
migration file. It is informational. Running it requires uncommenting
and executing manually in the SQL Editor.

Order of operations (the SQL file has the same order):

1. `ALTER TABLE public.trades DROP CONSTRAINT IF EXISTS trades_group_id_fkey;`
2. `DROP INDEX IF EXISTS public.trade_groups_user_id_idx;`
3. `DROP INDEX IF EXISTS public.trade_groups_user_active_idx;`
4. `DROP INDEX IF EXISTS public.trades_group_id_idx;`
5. `DROP POLICY IF EXISTS trade_groups_select_own_rows ON public.trade_groups;`
6. `DROP POLICY IF EXISTS trade_groups_insert_own_rows ON public.trade_groups;`
7. `DROP POLICY IF EXISTS trade_groups_update_own_rows ON public.trade_groups;`
8. `DROP POLICY IF EXISTS trade_groups_delete_own_rows ON public.trade_groups;`
9. `DROP TABLE IF EXISTS public.trade_groups;` (no `CASCADE` — fail
   loud if anything unexpected references it)
10. `ALTER TABLE public.trades DROP COLUMN IF EXISTS group_id;`

The whole block is wrapped in `BEGIN; ... COMMIT;` in the file so an
operator can dry-run with `BEGIN; ... ROLLBACK;` first if desired.

**Important warning, repeated in the file:** rollback is **safe only
before any group data is created**. Once the app starts inserting into
`trade_groups`, rollback destroys `label` / `group_pre_note` /
`group_post_note` / `archived_at` history. Export before rolling back,
or accept the loss.

---

## 10. Risks / open questions

### 10.1 Pre-existing schema mismatch (if `trade_groups` already exists)

**Risk:** `CREATE TABLE IF NOT EXISTS` is silent when the table already
exists, even if its columns / nullability / defaults differ from this
migration's definition.

**Mitigation in the file:** verification query V1 prints the actual
columns. Junior should compare the V1 output against the expected list
in the comment block. If anything diverges, stop and reconcile.

**Likelihood:** Low. The audit confirmed zero app-side references to
`trade_groups` or `group_id` exist today. But Supabase projects can be
mutated outside the app; verifying V1 covers the case.

### 10.2 Sequencing of policies vs grants

PostgreSQL allows GRANT before policies exist; the grants just have no
effect until a policy gates them. The migration creates policies in §6
and grants in §7, which is the conventional Supabase ordering and the
order Junior will see in the file.

**Mitigation:** No special handling needed; ordering is correct.

### 10.3 service_role explicit GRANT

`service_role` bypasses RLS by default. Granting CRUD to it is
strictly belt-and-braces and documents intent. **No risk identified.**

### 10.4 `ON DELETE CASCADE` on `trade_groups.user_id`

Mirrors the implicit user-deletion behaviour expected for user-owned
rows. **Confirm the existing `trades` table uses the same pattern**
before approving — V1 verification does not check this. If `trades`
uses `ON DELETE RESTRICT` or no FK at all, Junior may want to align
both behaviours in a follow-up migration. **Open question for Junior
to confirm**: does the existing `public.trades.user_id` FK use
`ON DELETE CASCADE`? This packet assumes mirrored behaviour.

### 10.5 `auth.users` FK requires extension access

`REFERENCES auth.users(id)` requires the role running the migration to
have privileges on the `auth` schema. In the Supabase SQL Editor the
default editor role has this privilege, so this is fine in practice.
Documented here so it is not a surprise.

### 10.6 `label NOT NULL` rigidity

Locked design says label is always auto-suggested on create. If the G3
UI ever needs an "untitled group" path (no auto-suggest possible), the
NOT NULL becomes a constraint to revisit. **Not blocking G1**, but
worth flagging now so G3 design knows the schema constraint exists.

### 10.7 Concurrent live writes during migration

The migration does not lock `public.trades` for long: it does one
`ADD COLUMN IF NOT EXISTS group_id` (cheap, nullable, default NULL —
no full table rewrite) and one `ADD CONSTRAINT ... NOT VALID? Actually
not used here — the constraint is added in `VALID` mode by default,
which scans existing rows. With `group_id` defaulting to NULL and no
existing row referencing anything, the scan is trivial.

**Optional hardening:** if the `trades` table is very large or Junior
wants extra caution, the FK could be added in two steps:
`ADD CONSTRAINT ... NOT VALID;` followed later by
`VALIDATE CONSTRAINT`. Not required at current data volumes; flagging
the option here.

### 10.8 Repo policy on uncommitted local SQL files

This packet creates a new SQL file at
`migrations/20260607_g1_trade_groups_schema.sql`. The repo's
convention (one prior migration) is to commit the SQL alongside the
companion lockdown note. **This packet does not commit anything** —
per the explicit instruction. Junior decides whether to commit the SQL
file separately from this report after reviewing.

### 10.9 No automated CI for migrations in this repo

There is no migration runner here — the only existing migration in
`migrations/` is also "run manually in Supabase SQL Editor". So no CI
gate breaks if the file format is suboptimal. Reviewer attention is
the only check. This matches the existing operating model.

---

## 11. Exact instructions for Junior to review before Supabase SQL Editor

Do these in order. Each step is read-only until step 12.

1. **Read the SQL file end-to-end** at
   `migrations/20260607_g1_trade_groups_schema.sql`. Time budget:
   ~10 minutes. The file is self-explanatory; the comment blocks
   should make every DDL obvious.
2. **Read §3 ("Locked design requirements") of this packet** and
   confirm the file matches the locked design verbatim. If anything
   diverges, stop.
3. **Confirm open question #10.4** — verify `public.trades` user_id FK
   uses `ON DELETE CASCADE`. Run the helper query below in the
   Supabase SQL Editor (read-only, safe):
   ```sql
   SELECT conname, confdeltype
   FROM   pg_constraint
   WHERE  conrelid = 'public.trades'::regclass
     AND  contype  = 'f'
     AND  pg_get_constraintdef(oid) LIKE '%REFERENCES auth.users%';
   ```
   Expected: `confdeltype = 'c'` (cascade). If anything else, decide
   whether to align `trade_groups` to match the existing pattern.
4. **Take a baseline COUNT for V9.** In Supabase SQL Editor:
   ```sql
   SELECT COUNT(*) AS trades_rows_before FROM public.trades;
   ```
   Record the number somewhere (a sticky note is fine).
5. **Optional: snapshot the existing `trades` row sample** to confirm
   nothing rewrites:
   ```sql
   SELECT id, user_id, product_id, status FROM public.trades LIMIT 5;
   ```
6. **Decide whether to run the migration in a transaction.** Supabase
   SQL Editor allows wrapping any statement in `BEGIN; ... COMMIT;`.
   This migration is safe to run in one transaction. If you prefer to
   commit partial work (e.g., create the table, verify, then add the
   FK), split it manually.
7. **Open the SQL Editor.** Paste the file contents from §0 through
   §8 (everything **above** the `VERIFICATION QUERIES` divider).
   Verification queries and rollback are commented; pasting them is
   harmless but you don't need them yet.
8. **Run.** Expected output: a series of "Success. No rows returned"
   notices, one per DDL block. No errors.
9. **Run each of V1–V8 individually** from the verification block
   inside the file. Each should match its expected result. If V1
   prints unexpected columns, stop and investigate.
10. **Run V9.** Compare to the baseline from step 4. The two numbers
    must match.
11. **Smoke the app.** Reload thus999.com in the browser. The app
    should load identically — no UI change, no extra requests, no
    new console warnings. (G1 does not touch the app yet, so any
    diff would be a regression unrelated to G1.)
12. **Record G1 done.** A follow-up task will:
    - Update `ROADMAP.md` "Phase order" to mark G1 ✅.
    - Open the G2 design task (read-only `GroupCard` display).
    - Take the Gate 5 P/L snapshot baseline *before* any G2 code
      writes.

If anything in steps 8–10 produces an unexpected result, **do not
proceed to step 11.** Either roll back (using the commented block at
the bottom of the SQL file) or leave the partial state and open a
"G1 hot fix" task. Either is safer than continuing.

---

## 12. Non-goals

This packet is explicitly **not** any of the following. Each is
called out so reviewers can spot scope creep.

- ❌ App code changes (no `db.saveTradeGroups`, no `GroupCard`, no
  loader update).
- ❌ Backfill of any kind.
- ❌ G2 UI (read-only display) work.
- ❌ G3 UI (`[+ Group]` button) work.
- ❌ G3.5 closed-trade retroactive grouping.
- ❌ G4 group pre/post notes wiring.
- ❌ G5 GUGU summary integration.
- ❌ G6 legacy `isMerged` cleanup.
- ❌ Deletion of dead `handleMerge` / `mergeSelected` /
  `_hiddenByMerge` code from `index.html` (planned for G3 PR).
- ❌ ROADMAP edits.
- ❌ Deploy, push, or restart.
- ❌ Schema execution. **Junior runs the SQL.**
- ❌ Localstorage / `tj_trades` envelope changes.
- ❌ GUGU / Capture Bot / Telegram / Task Scheduler / price_pusher
  touches.

---

## 13. Recommended next step

After Junior reviews this packet:

1. **If approved**, open a follow-up "Run G1 — Apply Trade Groups
   Schema" task. That task is the manual SQL Editor session
   described in §11 plus a `ROADMAP.md` update.
2. **If changes needed**, open a "Revise G1 packet" task pointing at
   the specific section(s) that need rework.

After G1 is applied:

- A separate task drafts the **Gate 5 P/L snapshot baseline** before
  any G2 code change. Output is a JSON dump of
  `{ realizedPL_total, unrealizedPL_total, winRate, hwm,
    dashboardSummary, calendarDailyPLs, perProductRealizedPL,
    excelExportRows.length }` from the current live data set, stored
  under `artifacts/merge_grouping/g2_baseline_<date>.json`. Re-snap
  after the first end-to-end G3 group/ungroup cycle. Byte-equality
  diff is the runtime guard against the P0-2 double-count class.

Then, separately and only after both Gate 5 and the migration are
done, the G2 design task can begin.

Stop after packet.
