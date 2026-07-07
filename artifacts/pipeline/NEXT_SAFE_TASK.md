# Next Safe Task

**Updated (local):** 2026-07-07
**Current HEAD:** `85e5116`

**Just completed:** Lane C — Product/MT5 preview UX cleanup, MT5 Inbox Mapping preview
surface (`85e5116`). Display-string helpers only; no persisted-path change.

---

## Recommended next safe task

**Option A — Trade-open picker contract-size audit/design ONLY (docs, no code).**
Audit and design (no implementation) how to surface contract size in the trade-open
form's per-series product picker (`expandProducts` cards + edit dropdown), the piece
deferred out of Lane C.

Rationale (why A over B/C):
- **Highest leverage + continuity** — it directly continues the just-finished UX thread
  and closes the remaining "contract size buried" gap on the surface users actually use
  to open trades.
- **Safest framing** — restricted to audit/design, it produces a reviewable packet with
  **zero code** and zero stop-list touch, even though the eventual implementation touches
  the `productId`-driving picker (which is exactly why it needs a design + review first).
- **B (GUGU market-aware cadence)** sits behind the **cognition freeze** (Lane E) and is
  architecture-heavy — lower urgency (bot is capture-only) and higher review weight.
- **C (merge/grouping boundary audit)** is a valid read-only audit but lower urgency —
  destructive merge is already disabled; no active pressure on that boundary.

Deliverable: a short design packet (surface inventory, proposed label/placement, fallback
rules, explicit "no productId/registry/persistence change" boundary) → route for review
before any code.

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
