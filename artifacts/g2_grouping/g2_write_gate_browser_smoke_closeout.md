# G2 Write-Gate Browser Smoke Closeout

**Date (local):** 2026-07-07
**Result:** **PASS WITH ROLLBACK** (decision path B — create then ungroup/revert).
**Executed by:** Junior, manually, in the signed-in production browser (`thus999.com`, v3.22.0).
**Plan followed:** the reviewed "G2 post-deploy write-gate browser smoke PLAN" (READY_FOR_USER_EXECUTION).

> This was the first **live** (non-rollback-SQL) exercise of the deployed G2 write path
> through the real UI + authenticated `create_trade_group_v1` RPC. It created one real group,
> verified it, then ungrouped it. Net DB effect: no active groups, no grouped trades; one
> archived group row remains **by design** (ungroup archives, never deletes).

---

## Environment

- Production: `71283c3` / **v3.22.0** (byte-identical served bundle).
- Flags enabled **in one browser session only** for the test: `tj_trade_group_ui_v01=1`,
  `tj_trade_group_write_v01=1`. Both **cleared** afterward; grouping UI absent again.
- Candidate (gold/Long, both open, `group_id` NULL, `isMerged` false, owned):
  - `1782833054555` (5 contracts)
  - `1783351013452` (3 contracts)
- UID `b77d0426-355d-4f31-b94a-1afbe8fd49fa`.

---

## What happened

1. **Pre-smoke (read-only):** candidate valid; baseline `trade_groups=0`, `grouped=0`; raw fingerprints captured.
2. **Flags on + reload:** grouping UI appeared only after the flags; Create button gated on the exact `CREATE GROUP` confirmation.
3. **Create (one click):**
   - Network (user-reported): exactly one `create_trade_group_v1` call; **no** direct `/rest/v1/trades` or `/rest/v1/trade_groups` writes.
   - UI: success toast, modal closed, candidate suppressed for the session.
   - Group created:
     - `group_id` = `f49056fa-aab4-4e5f-95d0-7992b1e7f138`
     - `label` = **gold Long** (server-derived family + direction)
     - `idempotency_key` = `2f3c68b807df72351c01fcac57ee609dee064d4fe9ffbae01e055366b31c2c6b`
4. **Post-create verification (read-only):**
   - Both child rows carried the **same non-null** `group_id`.
   - `raw` **unchanged** (fingerprints matched pre-snapshot):
     - `1782833054555` → `3fde2d2b0d994c06162ae03b49f70b054b6d2a56b52bc425d1acf0c3aae27a77`
     - `1783351013452` → `30ffa2bd0d6da9dbaab43359927b1038df4f3fe5aea22c267ffbc1477d2855db`
   - `active_groups_for_key = 1` (no duplicate), `active_groups = 1`, `grouped_trades_count = 2`.
5. **Rollback (decision B — ungroup):**
   - `active_groups = 0`, `grouped_trades_count = 0`, both child rows `group_id` NULL.
   - `total_groups = 1` — the group row is **archived, not deleted** (expected; `ungroup_trade_group_v1` archives).
6. **Cleanup:** both flags removed from the browser; grouping UI absent.

---

## Independent read-only cross-check (this closeout)

Confirmed via read-only REST at closeout time — matches the reported result exactly:

| Check | Value |
|---|---|
| `trade_groups` total | 1 |
| active groups (`archived_at IS NULL`) | 0 |
| `grouped_trades_count` (`group_id NOT NULL`) | 0 |
| group `f49056fa` | present, **archived** (`archived_at = 2026-07-07T10:31:42Z`, label `gold Long`) |
| child rows `group_id` | both NULL |

**Current DB state is SAFE:** no active groups, no grouped trades; one archived group row by design.

---

## What this proves

- The deployed, write-gated UI create path works end-to-end against the real authenticated RPC:
  one RPC call, no direct table writes, correct group + membership, idempotent key set.
- **P/L invariant held live:** the RPC wrote only `trades.group_id`; `raw` was byte-identical
  before and after (reducers walk `raw`, so P/L is untouched).
- `ungroup_trade_group_v1` cleanly reverted: children detached, group archived (not deleted).
- Flags are session-scoped and reversible; default-off posture restored.

## Known residuals / notes

- One **archived** `trade_groups` row (`f49056fa`) persists — expected; ungroup never deletes.
  Its `idempotency_key` is on an **archived** row, so the unique-active partial index does not
  block re-creating the same membership later.
- Defense-in-depth **RPC-side `raw->>'isMerged'` reject** remains a separate, pre-write-gate
  schema follow-up (the UI/candidate exclusion already shipped in `b1f8e7d`).
- Before groups are kept **persistently** (decision A in future), the app needs a
  **group-aware loader/render** — today `db.loadAll` selects only `raw` and does not load
  `group_id`, so a kept group would not be visible/rendered in the app.

---

## Next recommended step

**G2 group-aware loader/render design (design only, no code)** — decide how `group_id` is
loaded and grouped state is rendered, without breaking the P/L invariant (reducers must keep
ignoring `group_id`; `raw` must stay the reducer input). Required before any real group is kept.
