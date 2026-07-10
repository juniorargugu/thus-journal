# 00 — AI Bootstrap

**Read this before touching THUS.** It is the shortest path to being useful here
without breaking trust or data.

---

## 1. What THUS actually is

- THUS is **not just a journal app.** The Journal (`index.html`, a single-file React
  SPA persisted to Supabase, deployed on Netlify at thus999.com) is the current work
  surface, but it is not the goal.
- The **North Star is GUGU** — an AI-native trading copilot / trading operating system.
  See [`02_VISION_AND_NORTH_STAR.md`](./02_VISION_AND_NORTH_STAR.md).
- The Journal hardening work exists for one reason: **trustworthy AI needs trustworthy
  data.** GUGU will reason over trade history, executions, notes, and portfolio state.
  If those are lossy, double-counted, or silently unsaved, every downstream inference
  is poisoned. So we harden persistence, raw integrity, grouping, and the MT5 pipeline
  *now* so that GUGU can trust the data *later.*

> "We are hardening the Journal now so that GUGU can trust the data later."

---

## 2. How to reason about the project

- **Data integrity is sacred.** The recurring failure class here is *silent* data loss
  (optimistic UI that reports success before the write lands) and *silent* double-
  counting (a synthetic row counted alongside its source rows). Treat any change that
  could re-introduce either as high-risk, regardless of how small the diff looks.
- **Raw is canonical.** The `trades` rows (their `raw` JSONB) are the single source of
  truth for all P/L. Metadata layers (grouping `group_id`, product registry, MT5
  staging) must never mutate `raw` or be counted as trades. All reducers walk raw
  `trades[]`; derived/group/portfolio totals are computed at render time.
- **Prefer the smallest surface.** Fix the actual root cause; do not swap frameworks or
  add a new abstraction layer to solve a local bug. Extend existing paths
  (`db.saveTrade`, `commitUpdateTrade`, the ProductRegistry facade) rather than
  inventing parallel ones.
- **Gated ≠ abandoned.** Many powerful capabilities (MT5 writer, G2 write gate, GUGU
  cognition) are intentionally frozen behind human approval. They are not TODOs you may
  quietly complete. They are decisions the human owns.

---

## 3. How to review

- Reviews are **adversarial by design.** The house style is `/design` (adversarial
  design protocol) and an isolated `@"critic (agent)"` pass before non-trivial code,
  plus external review by Codex and GPT (see §6).
- When reviewing a claim of "done," verify it against **live state and the most recent
  doc**, not against an older closeout. Closeouts are point-in-time; they go stale.
  When two docs disagree, the most recently updated pipeline state wins, and the
  discrepancy should be flagged, not silently resolved.
- Trust `artifacts/pipeline/PIPELINE_STATE.md` and `NEXT_SAFE_TASK.md` as the current
  "where are we" glance — but they are self-reported. For anything money- or data-
  bearing, confirm before asserting.

---

## 4. How to propose work

- Propose the **next safe task**, then **stop and route back with a clear question** if
  the next step touches a gate. A missed safe task costs one round-trip; a silent
  stop-list action costs trust and possibly data.
- Never batch a stop-list action behind a safe one. Split them.
- Every schema change is designed up front (tables + columns + RLS drafted before any
  code), reviewed, and applied manually by the human in the Supabase SQL Editor — never
  by an agent.
- Keep write flags default-off. Ship capabilities dark; enabling them is a separate,
  explicit, human-approved step.

---

## 5. What must never be done silently — the gates

These require **explicit human review + approval every time.** They are drawn from
[`../pipeline/AUTOPILOT_RULES.md`](../pipeline/AUTOPILOT_RULES.md).

| Gate | Rule |
|---|---|
| **DB / schema / RLS / SQL** | No DDL, policy changes, migration applies, `ALTER`, index/trigger/function changes. Migrations are human-run in the SQL Editor. |
| **Supabase / RPC writes** | No `insert`/`update`/`delete`/`upsert`, no write-RPC, no transactions. Read-only SELECT is fine. |
| **G2 write gate** | `tj_trade_group_write_v01` (and any `tj_*` write/feature flag) must never be auto-enabled. |
| **Keeping a real group** | Persisting a real trade group (vs a rollback-only smoke) is user-approved. |
| **MT5 staging writer** | The real MT5 staging→journal writer and any MT5 write path is gated. The dry-run harness is offline-only. |
| **GUGU cognition / runtime** | Cognition and autonomous behavior are **frozen**; capture-only. No cadence/cognition/autonomy change. |
| **Durable save/close/delete/merge/import paths** | The trade persistence surfaces are protected; changes need review. |
| **Deploy / push** | See §5.1 below. |
| **Architecture / product tradeoffs** | Anything that collapses a design debate or picks between approaches. |

**MAY do without approval:** read code and (read-only) schema; summarize state/diffs;
run static checks (grep, esbuild syntax check, pure unit tests, `git diff --check`, the
read-only `scripts/pipeline_snapshot.ps1`); read-only PostgREST SELECTs; low-risk local
docs/UI changes on already-reviewed, default-off scope with a local commit only.

### 5.1 Deploy posture

Default posture: **`git push` and Netlify deploy are user-approved.** Do not push or
deploy on your own initiative. The one nuance: if a **standing user preference** says
deploys are allowed after a clean preflight (build + smoke + no stop-list surface), that
preference governs — but confirm it is current before relying on it, and never treat an
old approval for one batch as approval for the next. When unsure: treat deploy as gated
and ask.

---

## 6. The human's workflow (multi-model review chain)

Work moves through a deliberate, adversarial pipeline. Do not skip stages:

```
GPT (plan)  →  Claude Code (implement + report)  →  Codex (review)
            →  GPT (adversarial review)  →  human deploy + smoke
```

- **GPT** frames the plan / task.
- **Claude Code** implements on a reviewed scope and reports (closeout doc).
- **Codex** reviews the diff/migration/runbook.
- **GPT** does an adversarial second-pass review.
- The **human** runs any migration, enables any flag, and performs the deploy + smoke.

Artifacts in this repo frequently cite "Codex PASS" and "ChatGPT PASS" — those are this
chain's review gates, not decoration. A design that has not cleared them is not ready.

---

## 7. When in doubt

**Stop and ask.** State what you found, what you believe the next step is, and which
gate (if any) it touches. Prefer marking a fact **NEEDS VERIFICATION** over asserting it.
Trust is the scarce resource here; spend a round-trip to protect it.
