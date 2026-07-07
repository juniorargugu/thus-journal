# Next Safe Task

**Updated (local):** 2026-07-07
**Current HEAD:** `3a0b258`

**Just completed:** Lane C — trade-open product picker card contract-size display
(`3a0b258`, display-only `_csizeFrag`, `productId`/persistence unchanged). Lane C is now
DONE for both surfaces (MT5 Inbox preview + trade-open picker cards).

---

## Recommended next safe task

**Option A — Merge/grouping boundary audit (read-only, docs only).**
Audit and document the boundary between the legacy **destructive Merge** (double-counted
P/L historically; now disabled) and the new **non-destructive G2 grouping** (`group_id`,
reducers ignore it), so the two are not confused when the G2 stack ships.

Rationale (why A now):
- **Pre-deploy clarity + highest leverage** — the 9-commit ahead stack includes the G2
  grouping UI; documenting how grouping differs from the old Merge *before* that batch
  deploys reduces the risk of user/reviewer confusion at deploy time.
- **Safest framing** — read-only audit (code + git history + prior docs); no code, no DB,
  no stop-list touch. Produces a reviewable boundary note.
- **B (GUGU market-aware cadence)** stays behind the **cognition freeze** (Lane E) — lower
  urgency (bot is capture-only), heavier review.
- **C (review-summary "Contract Size" row)** is polish only — selection-time visibility is
  already solved by `3a0b258`; low leverage.
- **D (hold until batch deploy)** is reasonable if you'd rather pause — the ahead stack is
  at 9. Say the word and autopilot holds.

Deliverable: a short boundary note (what Merge did vs what grouping does, current disabled
state of Merge, where each lives in code, migration/UI implications) → route for review.

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

---

## How to refresh this file

After any completed task, update the "Recommended next safe task" and the blocked list
to match [`PIPELINE_STATE.md`](./PIPELINE_STATE.md). Keep it short — one recommendation +
the blocked list. Never enable a flag or push as part of "refreshing" it.
