# Next Safe Task

**Updated (local):** 2026-07-06
**Current HEAD:** `27fc357`

---

## Recommended next safe task

**Lane C — Product/MT5 preview UX cleanup (UI-only, reviewed scope).**
A small, default-off / no-behavior-change UI cleanup is the lowest-risk forward step
while the deploy batch (Lane A) and the G2 write-enable (Lane B) both wait on explicit
user approval. Draft the scope, get it reviewed, then implement locally.

Rationale: it moves a lane forward without touching any stop-list surface (no DB, no
flags enabled, no durable paths, no deploy).

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
