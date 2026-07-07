# Next Safe Task

**Updated (local):** 2026-07-07
**Prod:** `71283c3` (v3.22.0) on thus999.com. **Local** ahead of prod by docs-only commits
(pipeline/closeout records; not served).

**Just completed:** **G2 v0.4 group-aware loader/render — IMPLEMENTED LOCALLY + Codex PASS**
([`../g2_grouping/g2_v04_loader_render_closeout.md`](../g2_grouping/g2_v04_loader_render_closeout.md)).
`db.loadAll` now selects `raw,group_id` into a SEPARATE `id→group_id` map (`tradeGroupIds`); `trades[]`
stays raw-only and `group_id` never touches `raw`/trade objects (`toTradeRow` unchanged → P/L invariant
preserved). Grouped rows suppressed from candidates before bucketing + distinct green ⛓ badge; no
collapse/nesting/reorder. Stale-map reset on hydration/auth transitions + failure/catch paths. Commits
`ba9e780` (loader/render) + `9a07fdc` (reset fix); Codex verdict **PASS → OK_FOR_FUTURE_BATCH**.
**Unpushed; prod still `71283c3` / v3.22.0; G2 flags default-off, write gate NOT enabled.**

---

## Recommended next safe task

**(a) Future deploy-batch preflight — local stack, non-write validation only.**
Verify the unpushed local stack (`origin/main..HEAD` = `ba9e780`, `9a07fdc` code + `a555414`, `f45416e`,
this closeout docs) is deploy-clean **without pushing**: `index.html` byte-shape / esbuild EXIT 0,
default-off flag posture (no code path sets `tj_trade_group_*`), no untracked files staged, LF endings.
Produce a go/no-go preflight note. **The push/deploy itself stays user-gated.** → inside the MAY list.

Then, in order (each separately gated — do NOT auto-do):
- **(b) After a user-approved deploy:** default-off visual smoke on the live bundle — app mounts, grouping
  UI absent, 0 create RPC on load, no ⛓ grouped badge without flags/groups. Read-only.
- **(c) Later, separately gated:** keep a real group persistently / enable `tj_trade_group_write_v01` /
  build ungroup UI. Each needs explicit approval + its own reviewed plan.

Rationale:
- The loader/render code is implemented and Codex-PASSed (`ba9e780`+`9a07fdc`, OK_FOR_FUTURE_BATCH); the
  remaining value is shipping it (user-gated) then verifying live — not more design.
- Keeping a real persistent group is the first thing that actually exercises the new loader, so it is
  deliberately gated behind a deploy + flag-enable.

---

## Explicitly blocked next steps (need approval — do NOT auto-do)

- **Enable `tj_trade_group_write_v01`** or run a live (non-rollback) create (Lane B) — needs explicit flag-enable approval + a reviewed test/rollback plan.
- **Execute** the G2 write-gate live smoke (Lane B) — planning is safe; running it (a real write) needs approval.
- **Any new production deploy** — the current batch is live; a further deploy is a fresh user-gated batch (now includes the unpushed G2 v0.4 loader/render code `ba9e780`+`9a07fdc`).
- **Keep a real group persistently** (Lane B) — needs deploy + flag-enable approval; first real exercise of the v0.4 loader.
- **G2 ungroup UI v0.4** (Lane B) — separate task (a write path), needs its own review before code.
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
5. Adversarial review of any follow-up code. — ✅ DONE for the v0.4 loader/render (`ba9e780`+`9a07fdc`, Codex **PASS → OK_FOR_FUTURE_BATCH**). Future follow-ups (ungroup UI, RPC `raw->>'isMerged'` guard) still need their own review.
6. **`isMerged` exclusion (ROADMAP #184).** — UI/candidate layer ✅ DONE + deployed (`b1f8e7d`).
   Remaining: defense-in-depth `raw->>'isMerged'` reject in `create_trade_group_v1` (separate
   schema change, its own review).

---

## How to refresh this file

After any completed task, update the "Recommended next safe task" and the blocked list
to match [`PIPELINE_STATE.md`](./PIPELINE_STATE.md). Keep it short — one recommendation +
the blocked list. Never enable a flag or push as part of "refreshing" it.
