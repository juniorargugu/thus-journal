# Next Safe Task

**Updated (local):** 2026-07-07
**Prod:** `71283c3` (v3.22.0) on thus999.com. **Local** ahead of prod by docs-only commits
(pipeline/closeout records; not served).

**Just completed:** **G2 write-gate live browser smoke — PASS WITH ROLLBACK**
([`../g2_grouping/g2_write_gate_browser_smoke_closeout.md`](../g2_grouping/g2_write_gate_browser_smoke_closeout.md)).
Real UI create (group `f49056fa`, label `gold Long`) → one `create_trade_group_v1` call, no direct
table writes, both children grouped, `raw` byte-identical (P/L invariant held live) → ungrouped.
DB now safe: 0 active groups / 0 grouped trades; one **archived** group row by design. Flags cleared;
grouping UI absent again; write gate NOT enabled.

---

## Recommended next safe task

**G2 group-aware loader/render design (design only — no code, no DB).**
Design how `group_id` gets loaded and grouped state rendered, so a **kept** real group is actually
visible in the app — the prerequisite before anyone keeps a group persistently (decision A).

Rationale:
- The write path is proven end-to-end (create + ungroup), but `db.loadAll` selects only `raw`, so
  `group_id` is not loaded and a kept group would be invisible. That's the real next gap.
- Design-only: no `loadAll` change, no reducer change, no flag/DB touch → inside the MAY list.

Must preserve the P/L invariant: reducers keep walking `raw` and ignoring `group_id`; `raw` stays the
reducer input; grouped state is render-time only (a projected `group_id` read kept separate from `raw`).
Route the design for review before any loader/render code.

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
3. Post-deploy browser flag-matrix smoke on the live bundle. — ✅ DONE 2026-07-07, PASS WITH ROLLBACK.
4. Reducers/P&L re-confirmed to ignore `group_id`. — ✅ confirmed live (`raw` byte-identical across create).
5. Adversarial review of any follow-up code. — pending.
6. **`isMerged` exclusion (ROADMAP #184).** — UI/candidate layer ✅ DONE + deployed (`b1f8e7d`).
   Remaining: defense-in-depth `raw->>'isMerged'` reject in `create_trade_group_v1` (separate
   schema change, its own review).

---

## How to refresh this file

After any completed task, update the "Recommended next safe task" and the blocked list
to match [`PIPELINE_STATE.md`](./PIPELINE_STATE.md). Keep it short — one recommendation +
the blocked list. Never enable a flag or push as part of "refreshing" it.
