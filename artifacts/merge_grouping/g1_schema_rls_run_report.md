# G1 Schema + RLS Migration — Run Report

**Status:** `G1_SCHEMA_RLS_APPLIED_VERIFIED`

Generated 2026-06-08 BKK. Migration applied manually by Junior in the
Supabase SQL Editor; verified with V1–V9; app smoked read-only.
**No app code touched. No deploy. No push. No restart. No GUGU /
Capture Bot touch. No localStorage manual edit. No rollback.**

---

## 1. Date / time

- Date: 2026-06-08 (BKK)
- Run completed: same-day session

## 2. HEAD SHA at time of run

```
79140c6915289d50645debcf456050f83ec92ab9
  docs: add merge grouping G1 schema packet
```

(`79140c6` is the packet commit; G1 SQL is `migrations/20260607_g1_trade_groups_schema.sql` inside that commit.)

## 3. Open question #10.4 result

**RESOLVED — `confdeltype = 'c'`.**

Junior's SELECT-only check in Supabase SQL Editor returned:

```
[ { "conname": "trades_user_id_fkey", "confdeltype": "c" } ]
```

Interpretation: existing `public.trades.user_id` FK is `ON DELETE
CASCADE`, matching the new `trade_groups.user_id ON DELETE CASCADE`
rule in the migration. User-delete behaviour is consistent across both
tables. No SQL revision required.

## 4. Human readiness gates (Part 2)

All four gates **PASS**, confirmed by Junior at start of session:

| Gate | Junior's answer |
|---|---|
| Off-hours / low-risk window | Yes — off-hours, low risk |
| Single-purpose session for G1 | Yes — single-purpose |
| THUS Journal tabs closed except Supabase SQL Editor | Yes — only Supabase SQL Editor open |
| Ready to stop immediately on any anomaly; no blind retry / auto-rollback | Yes — will stop on any anomaly |

## 5. Pre-apply baseline

```sql
SELECT COUNT(*) AS trades_rows_before FROM public.trades;
-- result: 133
```

## 6. Migration applied

- Method: **Manual paste** into Supabase SQL Editor by Junior.
- Source: full apply block (§0 extensions through §8 documentation)
  from `migrations/20260607_g1_trade_groups_schema.sql`.
- Run count: **one paste, one Run**.
- SQL Editor response: `Success. No rows returned.` (standard DDL).
- No rerun, no retry, no rollback.

DDL statements that executed:

1. `CREATE EXTENSION IF NOT EXISTS pgcrypto`
2. `CREATE TABLE IF NOT EXISTS public.trade_groups (8 columns)`
3. `ALTER TABLE public.trades ADD COLUMN IF NOT EXISTS group_id uuid`
4. `ALTER TABLE public.trades ADD CONSTRAINT trades_group_id_fkey
   FOREIGN KEY (group_id) REFERENCES public.trade_groups(id)
   ON DELETE SET NULL` (inside DO block guarded on `pg_constraint`)
5. Three `CREATE INDEX IF NOT EXISTS` (two partial)
6. `ALTER TABLE public.trade_groups ENABLE ROW LEVEL SECURITY`
7. Four `DROP POLICY IF EXISTS ... CREATE POLICY ...` blocks
8. Two `GRANT` + one `REVOKE` on `public.trade_groups`
9. Two `COMMENT ON` (table + new column)

DML executed: **none.** No `INSERT`, no `UPDATE`, no `DELETE` against
any existing data.

## 7. Verification (V1–V9) — all PASS

### V1 — `trade_groups` columns

Returned 8 rows, every column matches the packet's expected schema
byte-for-byte:

```
id              | uuid                       | NO  | gen_random_uuid()
user_id         | uuid                       | NO  | null
label           | text                       | NO  | null
group_pre_note  | text                       | YES | null
group_post_note | text                       | YES | null
created_at      | timestamp with time zone   | NO  | now()
updated_at      | timestamp with time zone   | NO  | now()
archived_at     | timestamp with time zone   | YES | null
```

**V1 PASS.**

### V2 — `trades.group_id` column

```
group_id | uuid | YES | null
```

Nullable, no default, type `uuid`. **V2 PASS.**

### V3 — FK definition

```
trades_group_id_fkey |
  FOREIGN KEY (group_id) REFERENCES trade_groups(id) ON DELETE SET NULL
```

Exact match for the locked design's non-destructive ungroup semantics.
**V3 PASS.**

### V4 — Indexes

Three indexes, all created:

- `trade_groups_user_active_idx` — `BTREE (user_id) WHERE (archived_at IS NULL)` (partial)
- `trade_groups_user_id_idx`     — `BTREE (user_id)`                              (full)
- `trades_group_id_idx`          — `BTREE (user_id, group_id) WHERE (group_id IS NOT NULL)` (partial, composite)

Both partial predicates serialise correctly. **V4 PASS.**

### V5 — RLS on `trade_groups`

```
relrowsecurity = true
relforcerowsecurity = false
```

RLS enabled. `FORCE` not required (matches the convention for the
other user-scoped tables). **V5 PASS.**

### V6 — Four policies on `trade_groups`

```
trade_groups_delete_own_rows | d | (user_id = auth.uid()) | null
trade_groups_insert_own_rows | a | null                   | (user_id = auth.uid())
trade_groups_select_own_rows | r | (user_id = auth.uid()) | null
trade_groups_update_own_rows | w | (user_id = auth.uid()) | (user_id = auth.uid())
```

UPDATE carries both `USING` and `WITH CHECK` — confirms `user_id`
cannot be flipped to another user mid-update. All four policy bodies
match `(user_id = auth.uid())`. **V6 PASS.**

### V7 — GRANTs

```
anon_select  = false   anon_insert = false
auth_select  = true    auth_insert = true
auth_update  = true    auth_delete = true
svc_select   = true
```

Anon is explicitly locked out. Authenticated has CRUD (gated by the
policies). Service role has SELECT (and implicitly the other verbs
per the GRANT block). **V7 PASS.**

### V8 — Zero data written

```
trade_groups_rows = 0
trades_with_group = 0
```

Confirms migration wrote zero rows to `trade_groups` and zero `trades`
rows have a non-NULL `group_id`. **V8 PASS.**

### V9 — `trades` row count unchanged

```
trades_rows_after  = 133
trades_rows_before = 133
```

Migration did not move a single existing trade row. **V9 PASS.**

### V1–V9 summary

| V# | Result |
|---|---|
| V1 | PASS |
| V2 | PASS |
| V3 | PASS |
| V4 | PASS |
| V5 | PASS |
| V6 | PASS |
| V7 | PASS |
| V8 | PASS |
| V9 | PASS |

## 8. App-level smoke (Part D)

**Result: PASS** (with one pre-existing optimistic-concurrency note,
unrelated to the migration — see "Pre-existing note" below).

### Trade write path — healthy

Junior opened thus999.com in normal browser with DevTools console
open. Three successful trade-save batches observed:

```
[trades][write] upserted-affected=131/131  ids=...
[trades][write] upserted-affected=132/132  ids=..., 1780888169970
[trades][write] upserted-affected=133/133  ids=..., 1780888169970, 1780888169973   (×4 React StrictMode re-renders)
```

Critical: `affected == sent` on every single save. The permanent
`affected===0` tripwire (the same tripwire that backed Gate 1) did
**not** fire on any save. The newly-added `group_id` column did not
break the per-row upsert path. No `column ... does not exist`. No
RLS denial. No `[trades][write] upsert-error`.

The local row count progression (131 → 132 → 133) reflects normal
reconcile-on-hydration as the browser cache caught up to the server's
authoritative 133 (per V9). The two new visible IDs
(`1780888169970`, `1780888169973`) align with V9's `trades_rows_after
= 133`.

### Read/display surfaces — healthy

App rendered normally. No schema-related errors thrown by the loader,
the open-positions surface, the closed-trades surface, or the
Dashboard. The migration's new objects are dormant from the app's
perspective (no app code references `trade_groups` or `group_id`
yet), which is the intended G1 end-state.

### Browser extension noise (ignored)

```
injected.js:1 Provider initialised
injected.js:1 TronLink initiated
```

Wallet browser extension probing the page. Unrelated to the app and
to the migration.

### Pre-existing note — portfolio optimistic-concurrency conflict

A single `406 Not Acceptable` and CONFLICT log appeared during the
smoke:

```
POST .../rest/v1/portfolio?user_id=eq.<uid>&updated_at=eq.2026-06-08T03:19:54.626Z&select=updated_at
→ 406
[db] savePortfolio CONFLICT — server moved past expected_updated_at; refusing to overwrite
[persist] portfolio CONFLICT — local change rejected; reload to merge
```

This is the existing post-`f03ed03` divergence-preserving safety net
working exactly as designed: the app issued a guarded UPDATE with
`.eq("updated_at", expectedTimestamp)`, the server had moved past
that timestamp, PostgREST returned 406 (filter matched 0 rows), and
the app correctly refused to overwrite.

**Confirmed unrelated to the G1 migration:**

| Check | Result |
|---|---|
| Did the migration touch `public.portfolio`? | No — only `public.trade_groups` + `public.trades` referenced in the SQL. |
| Could `group_id` on `trades` side-effect `portfolio` reads? | No — different table, different code path. |
| `pgcrypto` extension impact on portfolio? | None — `IF NOT EXISTS`, already enabled prior. |
| Error shape: RLS denial (401/403) or OC conflict (406)? | 406 — OC conflict, not RLS. |
| Is `savePortfolio` code path unchanged since this morning? | Yes — last `savePortfolio` change is commit `f03ed03` (2026-05-07), not touched by this turn or the G1 SQL. |

**Recommended action for the operator (not for G1):** reload
thus999.com once. The next portfolio save will use the fresh
`updated_at` and the CONFLICT will not recur unless another tab/device
races again. This does not affect G1's verified state.

## 9. Confirmations

| Item | Value |
|---|---|
| App code touched? | **No** — `index.html` unchanged in this session. |
| UI implementation? | **No** — no `GroupCard`, no `[+ Group]` button, no schema-consumer code added. |
| Deploy? | **No.** |
| `git push`? | **No.** |
| Restart? | **No.** |
| GUGU / Capture Bot touched? | **No.** |
| localStorage manual edit? | **No.** |
| Rollback executed? | **No.** |
| Migration executed automatically by Claude Code? | **No** — manual paste by Junior into Supabase SQL Editor only. |
| New objects in Supabase | 1 table (`public.trade_groups`, 0 rows), 1 column (`public.trades.group_id`, 0 non-NULL of 133), 1 FK, 3 indexes, RLS enabled, 4 policies, 2 GRANTs, 1 REVOKE, 2 COMMENTs |
| Existing rows mutated | **0** (V9 confirms 133 → 133 unchanged) |

## 10. Next step

**Recommended sequence (each as a separate task):**

1. **Junior reviews this report.** If accurate, request "commit the G1
   run report" as a docs-only commit
   (`artifacts/merge_grouping/g1_schema_rls_run_report.md`). Suggested
   message: `docs: add G1 trade groups run report`. **Do not start UI
   implementation in that task.**
2. **Reload thus999.com once** to clear the cosmetic portfolio
   CONFLICT (operator action; no code change).
3. **Separate task:** capture the **Gate 5 P/L snapshot baseline**
   from the live data — JSON dump of `{realizedPL_total,
   unrealizedPL_total, winRate, hwm, dashboardSummary,
   calendarDailyPLs, perProductRealizedPL, excelExportRows.length}`
   stored under `artifacts/merge_grouping/g2_baseline_<date>.json`.
   This is the runtime guard that G2 byte-equality-diffs against
   after the first group/ungroup cycle.
4. **Separate task:** open the **G2 read-only `GroupCard` design**
   doc. Design only, no implementation in that task. Implementation
   is its own follow-up.

Out of scope for this report:

- ❌ G2 / G3 / G3.5 / G4 / G5 / G6 UI implementation
- ❌ Deletion of dead `handleMerge` / `mergeSelected` / `_hiddenByMerge`
  code (deferred to G3 PR per ROADMAP)
- ❌ ROADMAP "Phase order" tick-mark update (defer to G2 commit or
  later — keep ROADMAP unchanged in this commit)
- ❌ Any portfolio code change (the CONFLICT note is operator-resolved
  via reload)

Stop after report. Commit only when explicitly asked.
