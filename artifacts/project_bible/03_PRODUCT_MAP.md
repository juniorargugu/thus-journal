# 03 — Product Map

*A map of every THUS subsystem, so later roadmap capture does not drop anything. Each
entry follows the same shape: **Purpose · Current state · Relationship to GUGU · Known
roadmap · Gates / risks · Source docs · Missing context.** Status tags per
[`README.md`](./README.md).*

---

## 1. Journal

- **Purpose.** The memory/data layer: the canonical, durable record of every trade
  (open/close, entries, exits, notes, images) and the source of truth for all P/L. A
  single-file React SPA (`index.html`) persisted to Supabase, deployed on Netlify
  (thus999.com).
- **Current state.** **LIVE**, hardened. Every trade mutation (open/add, close, edit,
  price/meta update) is single-row durable via `db.saveTrade` / `commitUpdateTrade`; the
  data-losing full-array writer is retired; autosave narrowed to ids-only reconcile.
  Closed-trade exitPrice/exitDateTime correction shipped. Prod bundle `f01eb33` /
  v3.23.0.
- **Relationship to GUGU.** This is *the* dataset GUGU reasons over. Durability + raw
  integrity here are the precondition for trustworthy AI inference.
- **Known roadmap.** Residual non-durable writers (delete/duplicate/import/legacy-merge)
  to make save-first (P2 residual). Navigation/URL-state audit (**DEFERRED**). `[DIAG]
  TEMPORARY` log removal (mostly done; permanent `affected===0` tripwire stays).
  `PageSteps` dead-prop cleanup (**DEFERRED**). `uid()` → `crypto.randomUUID()`
  (**DEFERRED**).
- **Gates / risks.** Durable save/close/delete/merge/import paths are protected — changes
  need review. Single-file SPA scale; large `raw` payloads caused PostgREST `57014`
  timeouts. Silent data-loss is the historical bug class.
- **Source docs.** `ROADMAP.md`; `artifacts/close_position_journal_bug/*`;
  `artifacts/p2_deploy_readiness/*`; `artifacts/ui/*`.
- **Missing context.** Full durable-persistence history is scattered across the memory
  index and closeouts — chapter 07 must consolidate it. Delete/duplicate/import durability
  status **NEEDS VERIFICATION**.

## 2. Portfolio

- **Purpose.** State/risk layer: account balance, equity, unrealized/realized P/L,
  high-water mark (HWM), exposure — the current risk picture derived from executions.
- **Current state.** Partially **LIVE**. `portfolio` and `portfolio_summary` tables
  persist; a resource audit fixed a costly `portfolio_summary` write-every-5–60s loop
  (Patch A, applied 2026-05-11). HWM Equity "Layer 2" Dashboard card and a Trader Style
  Profiler card were **hidden** in the 2026-05-12 pivot (code retained, not rendered).
- **Relationship to GUGU.** Gives GUGU the risk/state context for any proposal (position
  sizing, exposure, drawdown awareness). Portfolio totals must be derived, never counted
  as trades.
- **Known roadmap.** A coherent Portfolio roadmap (risk model, multi-account, exposure,
  re-enabling or redesigning HWM/style cards) is **not consolidated anywhere**.
- **Gates / risks.** P/L invariant applies — portfolio aggregates are render-time
  derivations over raw `trades[]`. Hidden cards are outcome-based; the style profiler
  needs a process-based redesign before revival.
- **Source docs.** `ROADMAP.md` (pivot patch, PageSteps); `RESOURCE_AUDIT.md` (untracked).
- **Missing context.** **Portfolio roadmap — NEEDS VERIFICATION / capture from user
  memory.** This is one of the thinnest-documented subsystems.

## 3. Products / Symbol Registry

- **Purpose.** A registry mapping tradeable products to their semantics: family, symbol
  series (current/`_next`), asset kind (futures/stock/…), currency, contract size, price
  source, and P/L basis. Lets the system reason about heterogeneous instruments
  correctly.
- **Current state.** **LIVE** foundation (`2c2c8d2`, 2026-06-19): a `ProductRegistry`
  facade, price-source badge, runtime kind inference, kind-aware expansion/labels, and
  the first non-futures product **DELTA** (`assetKind:"stock"`, THB, manual-price, single
  expansion, gross P/L). Explicitly no schema/P&L/durable-path change. MT5 Inbox preview
  and trade-open picker now show family-level name/contract-size display strings.
- **Relationship to GUGU.** Gives GUGU accurate per-product semantics (kind, currency,
  P/L basis, contract size) so it interprets executions correctly across instruments.
- **Known roadmap.** Additional non-futures kinds (FX/CFD, crypto) deferred; order
  review-summary "Contract Size" row is optional polish (**DEFERRED**).
- **Gates / risks.** Display-only changes so far; any change to `productId`
  selection/persistence or `live_prices`/`contractToLiveKey` mapping is higher-risk.
  Contract-size correctness matters (e.g. `DELTAU26` SSF csize 1000 must never collapse
  onto the DELTA stock preset csize 1).
- **Source docs.** `artifacts/product_symbol_live_price/product_symbol_live_price_foundation_closeout.md`;
  MT5 Inbox preview notes in `PIPELINE_STATE.md` (Lane C).
- **Missing context.** Full product-registry roadmap (kinds, spot/CFD trades routing to a
  future `trades_capture` table) **NEEDS VERIFICATION**.

## 4. Merge / Grouping

- **Purpose.** Associate multiple executions that form one trade idea / thesis / scaled
  position, **without** collapsing them into a synthetic row. Replaces the retired,
  data-losing "Merge."
- **Current state.** **LIVE (default-off).** G1 schema+RLS applied (2026-06-08); G2 RPCs
  + ownership trigger applied (2026-07-05); v0.3 create-only UI + v0.4 group-aware
  loader/render deployed default-off at v3.23.0; RPC `isMerged` defense-in-depth guard
  (`20260708`) **APPLIED + VERIFIED in prod (2026-07-10, `b94f7fd`)** — precheck 0,
  new `create_trade_group_v1` installed, BEGIN/ROLLBACK validation passed (merged child →
  `merged_child_not_allowed`), nothing persisted. DB clean: 0 active groups, **no real
  group kept** (1 archived by design from the earlier rollback smoke). Write gate **not
  enabled**.
- **Relationship to GUGU.** Gives GUGU a natural unit ("one trade idea") to analyze, and
  a designed hook — **G5 `[Insert GUGU summary]`** reading `checkin_events` — to attach
  its analysis. Grouping protects the P/L GUGU learns from against double-counting.
- **Known roadmap.** Phases G0 (design, done) → G1 (schema) → G2 (display/persistence) →
  G3 (create/ungroup UI + delete dead merge handlers) → G3.5 (closed-trade grouping) →
  G4 (group notes) → G5 (GUGU summary) → G6 (legacy `isMerged` cleanup). **v0.5 ungroup
  UI** design approved, **DEFERRED**.
- **Gates / risks.** Enabling `tj_trade_group_write_v01` and keeping a real group are
  user-gated. Hard rules: never re-enable old Merge; never write a membership flag that
  isn't a real `group_id` FK; never introduce hidden rows; all reducers ignore
  `group_id` (P/L invariant, snapshot byte-identical).
- **Source docs.** `ROADMAP.md` (G0 lock); `artifacts/g2_grouping/*`;
  `artifacts/merge_grouping/*`; `migrations/20260607`, `20260705`, `20260708`;
  `artifacts/pipeline/g2_candidate_check.sql`.
- **Missing context.** G5/GUGU readiness depends on Capture Bot Day 4 — re-confirm.
  (The `20260708` isMerged migration is settled: applied + verified 2026-07-10; older
  design/validation closeouts that read "apply pending" are superseded.)

## 5. MT5 Import

- **Purpose.** Execution/source layer: mirror MetaTrader 5 executions (open positions,
  close deals) into a gated staging area, then (future) materialize confirmed rows into
  Journal trades. Nothing auto-materializes; the human confirms.
- **Current state.** **LIVE (read-only + gated).** 0A schema/RLS/RPCs applied + verified
  (2026-06-25): staging/groups/cursors tables, browser SELECT-own only, 3 SECURITY
  DEFINER RPCs. Local Python writer performed first armed open write (GOU26 open
  `305830528`) and first close-deal write (`deal_id 2141744`), both idempotent. Read-only
  **MT5 Inbox** UI shipped behind default-off `tj_mt5_inbox` (`7088473`), with clarity
  sectioning + safety labels. Offline **dry-run harness** merged (no network/Supabase/MT5).
- **Relationship to GUGU.** Supplies ground-truth fills/prices/contract sizes — the raw
  material for honest performance analysis — while keeping human confirmation so nothing
  auto-enters the Journal.
- **Known roadmap.** 0C-3c (balance + cursor), 0C-3d (lifecycle reconcile), 0D-1 Inbox
  write actions, Phase 1 materialization into `trades`. Optional review-summary contract-
  size row.
- **Gates / risks.** The real staging writer and any materialization are **GATED** behind
  reviewed schema/RLS + explicit DB-write approval + role decision + write tests +
  rollback plan. Cross-account gate hard-STOPs unless terminal login == `301102520`.
  `needs_mapping` for unmapped instruments; idempotency via `position_id` (PATCH) /
  `deal_id` (insert-once immutable) / `raw_sha`.
- **Source docs.** `artifacts/mt5_auto_draft_import/*`; `artifacts/mt5_import/*`;
  `ops/mt5_import/*` (README + Python tooling).
- **Missing context.** Full MT5 roadmap through materialization **NEEDS VERIFICATION**;
  live prod object inventory + current `origin/main` vs `7088473` self-reported only.

## 6. GUGU Capture Bot

- **Purpose.** The capture-only front of GUGU: time-series behavioral check-ins
  (`/status`, `/checkin`, `/checkin_trade`, `/review_today`, scheduled + during-trade
  prompts) recorded to `checkin_events` / `checkin_tags` / `checkin_user_prefs`.
- **Current state.** **LIVE (capture-only).** The Journal does not read or write any
  check-in table. Cognition/autonomous behavior is **FROZEN**.
- **Relationship to GUGU.** This *is* GUGU's data-capture arm today; check-ins are the
  behavioral time-series GUGU cognition would later consume (e.g. via the grouping G5
  hook).
- **Known roadmap (backlog).** Market-aware cadence, `review_week`, `review_position`,
  snooze, group-aware check-ins. All **GATED** (cognition/autonomy = STOP).
- **Gates / risks.** No second shadow cycle; no `cycle_agent` progression; no
  `/gugu_run` registration; no `CAPTURE_ONLY_MODE=false`. The freeze is a policy
  decision; check-ins continue normally under it.
- **Source docs.** `ROADMAP.md` (GUGU cognition freeze §; Capture Bot Day 4 prep);
  `PIPELINE_STATE.md` (Lane E). Most detail lives **outside this repo** (the trading-bot
  repo).
- **Missing context.** **Full Capture Bot capabilities + GUGU cognition roadmap live in a
  separate repo / user memory — NEEDS VERIFICATION and capture in chapter 10.**

## 7. Mentor System

- **Purpose.** Reasoning/hypothesis layer: form and test hypotheses about the trader's
  framework and performance — the bridge from raw memory to useful judgment.
- **Current state.** **VISION / backlog** (Lane I "Mentor / GUGU notes" = backlog only).
  The Journal historically had an "AI mentor note" route; it was **deprecated** in the
  2026-05-12 pivot (button removed, `apiKey` forced empty, `aiProcessNote` annotated
  DEPRECATED).
- **Relationship to GUGU.** The mentor layer is where GUGU's reasoning about the trader
  would live; closely tied to the Notes/Knowledge layer as its input.
- **Known roadmap.** Not concretely designed in-repo.
- **Gates / risks.** Any revival is cognition-adjacent → treat as gated.
- **Source docs.** `ROADMAP.md` (pivot patch — AI-mentor-note deprecation);
  `PIPELINE_STATE.md` (Lane I).
- **Missing context.** **The Mentor system is essentially undocumented as a forward
  design — NEEDS VERIFICATION / capture from user memory (chapter 11).**

## 8. Notes / Knowledge Engine

- **Purpose.** Learning/retrieval layer: curated, hand-shaped knowledge — quotes, rules,
  lessons, ideas/hypotheses — that GUGU retrieves and reasons with.
- **Current state.** **LIVE schema, activation DEFERRED.** `notes` persists via the
  hardened save path; a 4-type taxonomy (`quote`/`rule`/`lesson`/`idea`) + tag
  conventions is documented. LLM-retrieval redesign (embeddings/semantic search) is
  **deferred** until there is real content.
- **Relationship to GUGU.** These are the human-shaped priors GUGU retrieves — the most
  direct "teach GUGU the framework" surface. Kept deliberately small and curated to avoid
  polluting retrieval.
- **Known roadmap.** Revisit trigger: ≥ 20–30 real notes (typed or reviewed-bulk-import)
  **and** Phase-2 review-loop needs structured input. A future "Session B" designs the
  minimal schema (tag conventions first, columns only if proven needed), then a separate
  gated session may unfreeze GUGU cognition for a second shadow cycle.
- **Gates / risks.** Do **not** pre-add an `embedding` column / vector index on
  assumption; do **not** bulk-dump raw notes into `notes.freeform`/`tj_notes`; do **not**
  auto-import Capture Bot check-ins into Notes. Bulk import must go through a reviewed
  `import_preview.json` and the normal app save path, with backups first.
- **Source docs.** `docs/notes_taxonomy.md`; `ROADMAP.md` ("Notes — future LLM retrieval
  design"; bulk-import gate).
- **Missing context.** Concrete retrieval design (once content exists) — chapter 11.

## 9. Pattern / Lesson Engine

- **Purpose.** Extract recurring patterns and lessons from accumulated trade history +
  notes + check-ins — the compounding-learning engine.
- **Current state.** **VISION.** Not implemented. Adjacent primitives exist (the `idea`/
  `lesson` note types; the hidden Trader Style Profiler; the GUGU v2 "connect dots" /
  "self-correction" goals) but there is no pattern/lesson engine in-repo.
- **Relationship to GUGU.** This is much of GUGU's *value* — turning memory into learned
  patterns and self-correction over years.
- **Known roadmap.** Not designed in-repo; conceptually part of the GUGU v2 compound-
  learning phases.
- **Gates / risks.** Cognition-adjacent → gated. High echo-chamber risk (adversarial
  second-pass is the intended defense).
- **Source docs.** `docs/notes_taxonomy.md` (idea/lesson types); GUGU v2 vision (separate
  repo).
- **Missing context.** **Entirely NEEDS VERIFICATION / capture from user memory.**

## 10. Review / Analytics

- **Purpose.** Dashboards and analytics over trade history: realized/unrealized P/L, win
  rate, HWM, calendar daily P/L, journal totals, exports (Excel/Sheets).
- **Current state.** **LIVE** (core dashboard/analytics render in the SPA). Google Sheets
  Sync UI was **hidden** and auto-fire disabled in the 2026-05-12 pivot (object retained).
  Weekly summary logic exists (per the memory index).
- **Relationship to GUGU.** Analytics are render-time derivations GUGU can also compute
  from raw; they must stay consistent with the P/L invariant so human and AI views agree.
- **Known roadmap.** Process-based (vs outcome-based) redesign for style profiling;
  re-enable/redesign hidden cards; review-loop (Phase 2) structured input.
- **Gates / risks.** All aggregates must ignore `group_id` and walk raw `trades[]`.
- **Source docs.** `ROADMAP.md`; `RESOURCE_AUDIT.md`; memory index (weekly summary).
- **Missing context.** Analytics roadmap + review-loop design **NEEDS VERIFICATION**.

## 11. Automation / AI

- **Purpose.** The AI/automation surface: GUGU cognition/runtime, the multi-model review
  chain, and any autonomous cadence.
- **Current state.** GUGU cognition/runtime **FROZEN/GATED**; capture-only. The
  autopilot layer for *engineering* work (safe forward motion under strict gates) is
  documented and active.
- **Relationship to GUGU.** This is the layer that becomes GUGU. It is deliberately
  gated so capability ships dark and is enabled only by explicit human decision.
- **Known roadmap.** GUGU v2 phased plan (memory stream → agent+tools → proactive →
  adversarial → compound learning) lives in the separate trading-bot repo.
- **Gates / risks.** GUGU cognition/autonomy = **STOP**. Do not unfreeze silently;
  echo-chamber is the #1 risk.
- **Source docs.** `artifacts/pipeline/AUTOPILOT_RULES.md`; `ROADMAP.md` (GUGU freeze);
  GUGU v2 vision (separate repo).
- **Missing context.** **AI-automation roadmap — NEEDS VERIFICATION (chapter 10).**

## 12. Operations / Deployment / Review Process

- **Purpose.** How work ships safely: the gate model, the multi-model review chain, the
  deploy/smoke discipline, migrations-by-human, and resource/cost hygiene.
- **Current state.** **LIVE process.** Pipeline state tracked in
  `artifacts/pipeline/PIPELINE_STATE.md` + `NEXT_SAFE_TASK.md`; autopilot governed by
  `AUTOPILOT_RULES.md` (MAY / MUST STOP / MUST NOT). Deploys are user-gated; migrations
  are human-run in the Supabase SQL Editor; write flags default-off. Review chain: GPT
  plan → Claude Code implement/report → Codex review → GPT adversarial → human deploy/smoke.
- **Relationship to GUGU.** The discipline that keeps the dataset trustworthy is itself a
  precondition for trusting GUGU; the same gate philosophy will govern GUGU's unfreeze.
- **Known roadmap.** Backup-retention decision for sensitive image backups (holds
  base64/account data) — **DEFERRED**. RLS/security hardening — needs a fresh read-only
  audit (Lane G, **GATED**).
- **Gates / risks.** DB/SQL/RLS, Supabase/RPC writes, push/deploy, flag enables, MT5
  writer, GUGU cognition, durable paths, failed validation, architecture tradeoffs = STOP.
- **Source docs.** `artifacts/pipeline/*`; `scripts/pipeline_snapshot.ps1`;
  `RESOURCE_AUDIT.md`; `ops/*`.
- **Missing context.** RLS/security hardening scope (chapter 15). Where Netlify/Supabase
  credentials + deploy mechanics are documented **NEEDS VERIFICATION**.
