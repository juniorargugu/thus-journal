# Next Safe Task

**Updated (local):** 2026-07-07
**Prod:** `71283c3` (v3.22.0) on thus999.com. **Local** ahead of prod by docs-only commits
(pipeline/closeout records; not served).

**Just completed:** **G2 v0.5 ungroup UI design — reviewed + APPROVED-DEFERRED (ChatGPT PASS → IMPLEMENT_AFTER_CURRENT_DEPLOY)**
([`../g2_grouping/g2_v05_ungroup_design_closeout.md`](../g2_grouping/g2_v05_ungroup_design_closeout.md)). Prior in this stack:
v0.4 loader/render implemented + Codex PASS (`ba9e780`+`9a07fdc`, OK_FOR_FUTURE_BATCH), and the v0.4
deploy-batch **preflight** returned **READY_FOR_DEPLOY_PROMPT** (index.html byte-clean, esbuild EXIT 0, flags
read-only/default-off, 10/10 candidate harness) — pending user go + a version bump `3.22.0`→`3.23.0`.
**Unpushed; prod still `71283c3` / v3.22.0; batch ON HOLD; G2 flags default-off, write gate NOT enabled.**

---

## Recommended next safe task

**(a) Hold / wait — no autopilot-eligible task is pending.** The v0.4 loader/render code is implemented,
Codex-PASSed, and preflighted (**READY_FOR_DEPLOY_PROMPT**); the v0.5 ungroup design is reviewed and
**approved-deferred**. Every remaining step is user-gated.

When the user is ready, in order (each separately gated — do NOT auto-do):
- **(b) User-approved v0.4 deploy prompt:** bump `APP_VERSION` `3.22.0`→`3.23.0` (first step), push the
  committed stack, monitor Netlify, verify the served bundle is byte-identical to HEAD. Push/deploy = user approval.
- **(c) Post-deploy default-off smoke:** app mounts, grouping UI absent, 0 create RPC on load, no ⛓ badge
  without flags/groups. Read-only. **Runbook prepared:** [`../g2_grouping/g2_v04_post_deploy_smoke_runbook.md`](../g2_grouping/g2_v04_post_deploy_smoke_runbook.md).
- **(d) Later, separately gated:** enable `tj_trade_group_write_v01` / keep a real group persistently /
  **implement G2 v0.5 ungroup UI**. Each needs explicit approval + its own reviewed plan. **The v0.5 ungroup
  implementation is NOT part of the current v0.4 deploy batch** (new write path; IMPLEMENT_AFTER_CURRENT_DEPLOY).

Rationale:
- Everything design/preflight-able is done; shipping is the user's call. The v0.5 ungroup UI only has a real
  group to act on after deploy + write-flag enable, so it is deliberately last and kept out of this batch.

---

## Explicitly blocked next steps (need approval — do NOT auto-do)

- **Enable `tj_trade_group_write_v01`** or run a live (non-rollback) create (Lane B) — needs explicit flag-enable approval + a reviewed test/rollback plan.
- **Execute** the G2 write-gate live smoke (Lane B) — planning is safe; running it (a real write) needs approval.
- **Any new production deploy** — the current batch is live; a further deploy is a fresh user-gated batch (now includes the unpushed G2 v0.4 loader/render code `ba9e780`+`9a07fdc`).
- **Keep a real group persistently** (Lane B) — needs deploy + flag-enable approval; first real exercise of the v0.4 loader.
- **G2 v0.5 ungroup UI implementation** (Lane B) — design reviewed + approved-deferred (ChatGPT PASS → IMPLEMENT_AFTER_CURRENT_DEPLOY); a new write path, **NOT part of the current v0.4 batch**. Code only after v0.4 deploys + default-off smoke passes; its code needs its own adversarial review.
- **G2 RPC `isMerged` hardening migration** (Lane F) — design reviewed + approved (ChatGPT PASS; [`../g2_grouping/g2_rpc_ismerged_hardening_design.md`](../g2_grouping/g2_rpc_ismerged_hardening_design.md)). A gated DB/RPC migration (function-body-only `create_trade_group_v1` replace), **sequenced AFTER_V04_DEPLOY, before write-gate enable**. Run the read-only pre-apply precheck (expect 0) first; SQL apply is user-run in the SQL Editor. Not the immediate next task.
- **MT5 auto draft import** (Lane D) — touches import/durable paths.
- **GUGU cadence/cognition** (Lane E) — frozen.
- **RLS/security hardening** (Lane G) — fresh read-only audit first.

---

## Standing gate for Lane B (G2)

Before the write gate is enabled in any real (non-rollback) context, ALL must hold:
1. Batch deploy shipped + user go. — ✅ DONE (`71283c3` live).
2. Explicit approval to enable `tj_trade_group_write_v01`. — pending.
3. Post-deploy browser flag-matrix smoke on the live bundle. — ✅ DONE 2026-07-07, PASS WITH ROLLBACK.
4. Reducers/P&L re-confirmed to ignore `group_id`. — ✅ confirmed live (`raw` byte-identical across create).
5. Adversarial review of any follow-up code. — ✅ DONE for the v0.4 loader/render (`ba9e780`+`9a07fdc`, Codex **PASS → OK_FOR_FUTURE_BATCH**). v0.5 ungroup **design** reviewed (ChatGPT **PASS**, approved-deferred) — its **code** review is still pending (write it only after v0.4 deploys). RPC `raw->>'isMerged'` guard still needs its own review.
6. **`isMerged` exclusion (ROADMAP #184).** — UI/candidate layer ✅ DONE + deployed (`b1f8e7d`).
   Remaining: defense-in-depth `raw->>'isMerged'` reject in `create_trade_group_v1` (separate
   schema change, its own review).

---

## How to refresh this file

After any completed task, update the "Recommended next safe task" and the blocked list
to match [`PIPELINE_STATE.md`](./PIPELINE_STATE.md). Keep it short — one recommendation +
the blocked list. Never enable a flag or push as part of "refreshing" it.
