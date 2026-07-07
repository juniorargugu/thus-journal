# Next Safe Task

**Updated (local):** 2026-07-07
**Current HEAD:** merge/grouping boundary audit commit (this commit); ahead of `origin/main` ~11.

**Just completed:** Merge ↔ grouping boundary audit (read-only) →
[`../g2_grouping/merge_grouping_boundary_audit.md`](../g2_grouping/merge_grouping_boundary_audit.md).
Verdict **CLEAR_FOR_BATCH_DEPLOY_AS_IS**: legacy Merge is disabled/unreachable (sole `🔗`
entry `disabled`, no onClick), G2 grouping is default-off + write-gated, no merge path writes
`group_id`, durable paths preserve `group_id` by omission. One data-safe gap (F7) is a
**pre-write-gate** stop-gate, not a deploy blocker.

---

## Recommended next safe task

**Option D — Hold and line up the batch deploy (user-gated).**
The boundary audit confirms the stack is deploy-safe, and the ahead stack is now ~11 commits.
The highest-value next move is the **batch deploy itself**, which only you can trigger. Until
then autopilot holds — no more feature commits that grow the unpushed stack.

Rationale:
- The audit removed the last "is the boundary safe to ship?" question → **CLEAR_FOR_BATCH_DEPLOY_AS_IS**.
- Growing the ahead stack further raises deploy risk without adding deploy value.
- The natural pre-write-gate follow-up (`isMerged` exclusion, below) is best done **after**
  deploy, alongside the other Lane B write-gate gates.

If you'd rather keep moving locally instead of holding: the next safe docs/design task is a
design packet for the **`isMerged`-exclusion** guard (ROADMAP #184) — design only, no code.

---

## Explicitly blocked next steps (need approval — do NOT auto-do)

- **Deploy the unpushed stack** (Lane A) — user said wait for batch deploy.
- **Enable `tj_trade_group_write_v01`** or run a live (non-rollback) create (Lane B) — needs deploy + explicit flag-enable approval.
- **G2 browser write-gate smoke on the live bundle** (Lane B) — after deploy + approval only.
- **group_id-aware loader / grouped render / ungroup UI v0.4** (Lane B) — design review first.
- **MT5 auto draft import** (Lane D) — touches import/durable paths.
- **GUGU cadence/cognition** (Lane E) — frozen.
- **RLS/security hardening** (Lane G) — fresh read-only audit first.

---

## Standing gate for Lane B (G2)

Before the write gate is enabled in any real (non-rollback) context, ALL must hold:
1. Batch deploy shipped + user go.
2. Explicit approval to enable `tj_trade_group_write_v01`.
3. Post-deploy browser flag-matrix smoke on the live bundle.
4. Reducers/P&L re-confirmed to ignore `group_id`.
5. Adversarial review of any follow-up code.
6. **`isMerged` exclusion (ROADMAP #184)** — `buildGroupingPreview` (and the create path)
   must exclude legacy merged rows; add a `raw->>'isMerged'` reject in `create_trade_group_v1`.
   From the merge/grouping boundary audit (data-safe gap, pre-write-gate).

---

## How to refresh this file

After any completed task, update the "Recommended next safe task" and the blocked list
to match [`PIPELINE_STATE.md`](./PIPELINE_STATE.md). Keep it short — one recommendation +
the blocked list. Never enable a flag or push as part of "refreshing" it.
