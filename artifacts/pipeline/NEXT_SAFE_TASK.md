# Next Safe Task

**Updated (local):** 2026-07-07
**Current HEAD / prod:** `71283c3` — `origin/main` == HEAD, **deployed** to thus999.com (v3.22.0).

**Just completed:** **Batch deploy + version hotfix.** Pushed `f5290f7..b1f8e7d` (12-commit G2
stack) then `b1f8e7d..71283c3` (version fix 3.21.0 → **3.22.0** via single-source `APP_VERSION`).
Prod serves index.html byte-identical to `71283c3`; boot smoke PASS (app mounts, grouping UI
absent by default, flags null, 0 create RPC on load). G2 flags remain **default-off**; write gate
NOT enabled. Signed-in footer visual confirm is user-side (hard-refresh to bust cache).

---

## Recommended next safe task

**Draft the Lane B post-deploy write-gate browser-smoke PLAN (docs/design only — NOT execution).**
Write a reviewable test + rollback plan for the eventual live grouping test, without running it.

Rationale:
- The deploy is complete and the G2 SQL/RPC rollback smoke already PASSED; UI create-only is live
  default-off. The remaining unknown is the **live** create — which is a real DB write, so it needs
  an explicit, reviewed test plan **before** anyone enables `tj_trade_group_write_v01`.
- A plan is docs-only (no flag enable, no write, no deploy) → safely inside the MAY list.

Plan should cover: enabling `tj_trade_group_ui_v01`+`tj_trade_group_write_v01` in one browser only;
picking a real ≥2-leg non-merged candidate; the exact confirm-string create; expected `data.ok`/
`created`; post-create verification (group row + attach + `raw` untouched + P/L byte-identical);
then `ungroup`/cleanup or a documented rollback; and the abort conditions. Route for review before
execution.

---

## Explicitly blocked next steps (need approval — do NOT auto-do)

- **Enable `tj_trade_group_write_v01`** or run a live (non-rollback) create (Lane B) — needs explicit flag-enable approval + a reviewed test/rollback plan.
- **Execute** the G2 write-gate live smoke (Lane B) — planning is safe; running it (a real write) needs approval.
- **Any new production deploy** — the current batch is live; a further deploy is a fresh user-gated batch.
- **group_id-aware loader / grouped render / ungroup UI v0.4** (Lane B) — design review first.
- **MT5 auto draft import** (Lane D) — touches import/durable paths.
- **GUGU cadence/cognition** (Lane E) — frozen.
- **RLS/security hardening** (Lane G) — fresh read-only audit first.

---

## Standing gate for Lane B (G2)

Before the write gate is enabled in any real (non-rollback) context, ALL must hold:
1. Batch deploy shipped + user go. — ✅ DONE (`71283c3` live).
2. Explicit approval to enable `tj_trade_group_write_v01`. — pending.
3. Post-deploy browser flag-matrix smoke on the live bundle. — plan first (recommended task above), then run on approval.
4. Reducers/P&L re-confirmed to ignore `group_id`. — pending (part of the smoke).
5. Adversarial review of any follow-up code. — pending.
6. **`isMerged` exclusion (ROADMAP #184).** — UI/candidate layer ✅ DONE + deployed (`b1f8e7d`).
   Remaining: defense-in-depth `raw->>'isMerged'` reject in `create_trade_group_v1` (separate
   schema change, its own review).

---

## How to refresh this file

After any completed task, update the "Recommended next safe task" and the blocked list
to match [`PIPELINE_STATE.md`](./PIPELINE_STATE.md). Keep it short — one recommendation +
the blocked list. Never enable a flag or push as part of "refreshing" it.
