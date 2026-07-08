# Next Safe Task

**Updated (local):** 2026-07-08
**Prod:** **`f01eb33` (v3.23.0)** on thus999.com — **DEPLOYED, in sync** (origin/main == HEAD). Served bundle
byte-identical to HEAD:index.html.

**Just completed:** **v3.23.0 deploy VERIFIED — authenticated visual smoke PASS (2026-07-08)**
([`../g2_grouping/g2_v04_mt5_harness_deploy_closeout.md`](../g2_grouping/g2_v04_mt5_harness_deploy_closeout.md)).
G2 v0.4 + MT5 dry-run harness are live at `f01eb33` / v3.23.0 (byte-identical). Both smoke halves PASS: no-auth
default-off (flags null; 0 `create_trade_group_v1`; 0 `/rest/v1/trades` + 0 `/rest/v1/trade_groups` writes on
load; grouping UI absent; no ⛓ badge) **and** authenticated (Positions/Journal render, P/L + portfolio
unchanged, footer v3.23.0, no ⛓ badge at 0 grouped trades). MT5 harness offline-only. **G2 flags default-off;
write gate NOT enabled.**

---

## Recommended next safe task

**No autopilot-eligible task is pending — the deploy is fully verified.** Every remaining track is a gated
write path or migration; pick one to open when ready (each needs explicit approval + its own reviewed plan):

- **(a) G2 write-gate / real-group path** (Lane B) — enable `tj_trade_group_write_v01` and keep one real group
  to exercise the deployed v0.4 loader end-to-end. **Prereq:** apply the RPC `isMerged` hardening migration
  first (below), and a reviewed enable + rollback plan. Flag enable = user approval.
- **(b) RPC `isMerged` hardening migration** (Lane F) — **PACKAGED, NOT applied**: migration
  [`../../migrations/20260708_g2_create_group_reject_ismerged.sql`](../../migrations/20260708_g2_create_group_reject_ismerged.sql)
  + validation runbook [`../g2_grouping/g2_rpc_ismerged_hardening_validation.sql`](../g2_grouping/g2_rpc_ismerged_hardening_validation.sql)
  (design ChatGPT PASS). **Next gated step:** user-run read-only precheck (expect 0) → review the migration →
  apply in the Supabase SQL Editor (BEGIN/ROLLBACK dry-run via the validation runbook, then COMMIT). SQL apply
  is user-run. Sequenced before write-gate enable.
- **(c) MT5 real staging writer planning** (Lane D) — the dry-run harness is merged/verified; a real writer is
  gated behind reviewed schema/RLS + explicit DB-write approval + role decision + Supabase write tests +
  rollback plan. Design/planning is safe; any DB write is user-gated.
- **(d) G2 v0.5 ungroup UI** (Lane B) — approved-deferred; a new write path, its own adversarial review.

Rationale:
- v3.23.0 is deployed and both smoke halves pass, so there is nothing left to verify. What remains is
  DB/RPC/write-gate work — all user-gated. Design/planning for any of the above is autopilot-safe; execution is not.

---

## Explicitly blocked next steps (need approval — do NOT auto-do)

- **Enable `tj_trade_group_write_v01`** or run a live (non-rollback) create (Lane B) — needs explicit flag-enable approval + a reviewed test/rollback plan.
- **Execute** the G2 write-gate live smoke (Lane B) — planning is safe; running it (a real write) needs approval.
- **Any new production deploy** — prod is `f01eb33` / v3.23.0 (G2 v0.4 + MT5 harness live); a further deploy is a fresh user-gated batch.
- **Keep a real group persistently** (Lane B) — v0.4 loader now deployed; needs flag-enable approval; first real exercise of the loader.
- **G2 v0.5 ungroup UI implementation** (Lane B) — design reviewed + approved-deferred (ChatGPT PASS → IMPLEMENT_AFTER_CURRENT_DEPLOY); a new write path, **NOT part of the current v0.4 batch**. Code only after v0.4 deploys + default-off smoke passes; its code needs its own adversarial review.
- **G2 RPC `isMerged` hardening migration** (Lane F) — design reviewed + approved (ChatGPT PASS; [`../g2_grouping/g2_rpc_ismerged_hardening_design.md`](../g2_grouping/g2_rpc_ismerged_hardening_design.md)). A gated DB/RPC migration (function-body-only `create_trade_group_v1` replace), **sequenced AFTER_V04_DEPLOY, before write-gate enable**. Run the read-only pre-apply precheck (expect 0) first; SQL apply is user-run in the SQL Editor. Not the immediate next task.
- **MT5 auto draft import** (Lane D) — touches import/durable paths.
- **GUGU cadence/cognition** (Lane E) — frozen.
- **RLS/security hardening** (Lane G) — fresh read-only audit first.

---

## Standing gate for Lane B (G2)

Before the write gate is enabled in any real (non-rollback) context, ALL must hold:
1. Batch deploy shipped + user go. — ✅ DONE (`f01eb33` / v3.23.0 live, byte-identical).
2. Explicit approval to enable `tj_trade_group_write_v01`. — pending.
3. Post-deploy browser smoke on the live bundle. — ✅ no-auth default-off smoke on `f01eb33` PASS (2026-07-08); **authenticated visual smoke PENDING** (user browser). Prior write-gate live smoke on `71283c3` PASS WITH ROLLBACK (2026-07-07).
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
