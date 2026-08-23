# Next Safe Task

**Updated (local):** 2026-08-23
**Active branch:** `work/mt5-s1-snapshot-lifecycle` @ `d145699` (lane **J**, unpushed — no bundle change, no deploy).
**Current worktree HEAD:** `d145699476db068b22ce36e2d8bb8b067a9edb68` (branch `work/mt5-s1-snapshot-lifecycle`).
**Current local `origin/main`:** `f37a0ef593b78791b0b1f00096106735b4c59ab3`.
**Historical production/browser baseline:** `042aeed` — the commit at which the lane A–I production facts below were captured (2026-07-10). It is **not** current HEAD and **not** current `origin/main`. Docs/migration commits after `f01eb33` do not touch `index.html`.
**Production bundle:** **`f01eb33` / v3.23.0** on thus999.com — unchanged. `index.html` is byte-identical to
`f01eb33` through `042aeed`, so prod still serves the `f01eb33` bundle.

**Just completed (lane J, 2026-08-23):** **MT5 S1.1 first production canary — CLOSED.** `run_id=b8182608…`, `run_seq=2`, complete/healthy/reconciled, 4 membership rows + **the first `mt5_sync_run_account` row** (`observed`, equity+balance `usable`, THB), lifecycle `not_open_confirmed=2`, verification packet PASS. One cycle, zero retries, zero MT5 calls on the armed path, no scheduler, no push, no deploy. See [`../mt5_reconciliation/S1_1_first_production_canary_closeout.md`](../mt5_reconciliation/S1_1_first_production_canary_closeout.md).

**Previously completed (lane F):** **RPC `isMerged` hardening migration `20260708` APPLIED + VERIFIED in prod Supabase
(2026-07-10)** — user-run precheck returned 0; `create_trade_group_v1` replaced (function-body-only); BEGIN/ROLLBACK
behavior test confirmed `merged_child_not_allowed` on a merged child (false/null/absent allowed; ungroup unchanged;
nothing persisted). (Earlier: **v3.23.0 deploy VERIFIED — no-auth default-off + authenticated visual smoke PASS,
2026-07-08**; G2 v0.4 + MT5 dry-run harness live at `f01eb33` / v3.23.0, byte-identical.) MT5 harness offline-only.
**G2 flags default-off; write gate NOT enabled.**

---

## Recommended next safe task

**Lane J — Codex review of the T1/T2 contract freeze.** Docs-only and autopilot-safe:
[`../mt5_reconciliation/T1_T2_contract_freeze_addendum.md`](../mt5_reconciliation/T1_T2_contract_freeze_addendum.md) is `DRAFT FOR CODEX REVIEW` and freezes the seven load-bearing decisions T1/T2 depend on (promotion idempotency · manual-journal dedup · group-target selection · **no-FX exposure rule** · **equity as the one denominator** · Close Report scope · skip-vs-unconfirmed visibility), plus the machine-context timing rule and the T1 detection-only boundary. After that review passes:

1. **T1 — trusted position-change detector** (detection only: no Journal mutation, no Telegram, no quiet-window persistence, no scheduler).
2. **T2 — quiet window + `capture_event`** (does not itself promote to Journal).

The THUS Journal lanes below are unchanged and still user-gated.

**No autopilot-eligible task is pending — the deploy is fully verified.** Every remaining track is a gated
write path or migration; pick one to open when ready (each needs explicit approval + its own reviewed plan):

- **(a) G2 write-gate / real-group path** (Lane B) — **now unblocked of its migration prereq**: the RPC `isMerged`
  hardening is applied + verified in prod. Remaining before a real (non-rollback) create: explicit approval to
  enable `tj_trade_group_write_v01` + a reviewed enable/rollback plan, then keep one real group to exercise the
  deployed v0.4 loader end-to-end. Flag enable = user approval.
- **(b) RPC `isMerged` hardening migration** (Lane F) — ✅ **DONE (applied + verified in prod Supabase 2026-07-10)**:
  migration [`../../migrations/20260708_g2_create_group_reject_ismerged.sql`](../../migrations/20260708_g2_create_group_reject_ismerged.sql)
  live; precheck 0; behavior test confirmed `merged_child_not_allowed`. No further action.
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
- ~~**G2 RPC `isMerged` hardening migration** (Lane F)~~ — ✅ **DONE: applied + verified in prod Supabase 2026-07-10** (precheck 0; `merged_child_not_allowed` confirmed). No longer blocked.
- **MT5 auto draft import** (Lane D) — touches import/durable paths.
- **GUGU cadence/cognition** (Lane E) — frozen.
- **RLS/security hardening** (Lane G) — fresh read-only audit first.

**Lane J — NOT AUTHORIZED / NOT ACTIVE** (each needs its own operator gate + adversarial review):
- **Continuous MT5 writer** — S1/S1.1 are one-shot, envelope-replay only.
- **Scheduler / automatic polling** — no timer, no loop, no daemon.
- **A third production snapshot** — the canary was one cycle; another needs fresh approval.
- **T4 Journal promotion** — and it additionally needs a durable indexed `mt5PositionId` path first (contract freeze, Decision 2).
- **FX workstream** — MVP does not convert currencies; a mismatch is `EXPOSURE_UNAVAILABLE_CURRENCY_MISMATCH` (Decision 4).
- **Browser-facing S1.1 exposure consumer** — `mt5_sync_run_account` stays `service_role` SELECT only; any read RPC is a new, separately reviewed surface.
- **Implementing T1 or T2** — blocked until the contract freeze review passes.

---

## Standing gate for Lane B (G2)

Before the write gate is enabled in any real (non-rollback) context, ALL must hold:
1. Batch deploy shipped + user go. — ✅ DONE (`f01eb33` / v3.23.0 live, byte-identical).
2. Explicit approval to enable `tj_trade_group_write_v01`. — pending.
3. Post-deploy browser smoke on the live bundle. — ✅ no-auth default-off smoke on `f01eb33` PASS (2026-07-08) **and authenticated visual smoke PASS (user browser, 2026-07-08)** → v3.23.0 deploy verification COMPLETE. Prior write-gate live smoke on `71283c3` PASS WITH ROLLBACK (2026-07-07).
4. Reducers/P&L re-confirmed to ignore `group_id`. — ✅ confirmed live (`raw` byte-identical across create).
5. Adversarial review of any follow-up code. — ✅ DONE for the v0.4 loader/render (`ba9e780`+`9a07fdc`, Codex **PASS → OK_FOR_FUTURE_BATCH**). RPC `raw->>'isMerged'` guard migration/runbook reviewed (`5d418e7`, Codex **PASS**) and **applied + verified in prod (2026-07-10)**. v0.5 ungroup **design** reviewed (ChatGPT **PASS**, approved-deferred) — its **code** review is still pending (write it only after v0.4 deploys).
6. **`isMerged` exclusion (ROADMAP #184).** — UI/candidate layer ✅ DONE + deployed (`b1f8e7d`).
   Defense-in-depth `raw->>'isMerged'` reject in `create_trade_group_v1` = ✅ **APPLIED + VERIFIED in prod
   Supabase 2026-07-10** (precheck 0; `merged_child_not_allowed` confirmed via BEGIN/ROLLBACK test).

---

## How to refresh this file

After any completed task, update the "Recommended next safe task" and the blocked list
to match [`PIPELINE_STATE.md`](./PIPELINE_STATE.md). Keep it short — one recommendation +
the blocked list. Never enable a flag or push as part of "refreshing" it.
