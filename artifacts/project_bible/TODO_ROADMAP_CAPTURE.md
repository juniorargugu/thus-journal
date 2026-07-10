# TODO — Roadmap & Chapter Capture

This phase created the **foundation** of the Bible (README + chapters 00–03 +
SOURCE_INVENTORY). This file lists the remaining chapters and, for each, what must be
captured — so nothing disappears just because it is not implemented yet.

**Rule:** roadmap items are tagged, never dropped. Use the status vocabulary from
[`README.md`](./README.md): **DONE · LIVE · APPLIED · DESIGNED · REVIEWED · DEFERRED ·
GATED · RESEARCH · VISION · NEEDS VERIFICATION** (VERIFIED is a pairing, e.g.
*APPLIED + VERIFIED*; README is authoritative for the set/order). When a source is missing, capture the item as
**NEEDS VERIFICATION** rather than inventing detail.

---

## Foundation created in this phase

- ✅ `README.md`
- ✅ `00_AI_BOOTSTRAP.md`
- ✅ `01_EXECUTIVE_SUMMARY.md`
- ✅ `02_VISION_AND_NORTH_STAR.md`
- ✅ `03_PRODUCT_MAP.md`
- ✅ `SOURCE_INVENTORY.md`
- ✅ `TODO_ROADMAP_CAPTURE.md` (this file)
- ✅ `GLOSSARY.md`
- ✅ `GUGU_V2_RECONCILIATION.md` (cross-repo capture, 2026-07-10)
- ✅ `USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md` (user-memory capture, 2026-07-10)

---

## Remaining chapters to write

### `04_COMPLETE_ROADMAP.md` — **capture complete; ready to draft (tags must be preserved)**
The single consolidated, tagged roadmap across all subsystems — the master list so no
track is lost. **(Not written in this task.)**

**Status update (2026-07-10):** both capture prerequisites are now **DONE** — the cross-repo
GUGU v2 reconciliation ([`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md)) **and**
the Portfolio / Mentor / Pattern-Library / S50 user-memory capture
([`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md)).
Chapter 04 is **no longer blocked by a lack of capture** and is ready to draft.

**Constraints when drafting (do not lose these):** every item must carry its confidence
tag. The captured layers are **not** repo-verified: Portfolio = `VISION` / `NEEDS_REPO_SOURCE`;
Mentor = `DESIGNED` / `VISION`; Pattern Library = `DESIGNED` / `VISION`; corrected S50
gap-down rule = `CONFIRMED_FROM_USER_MEMORY` / `NEEDS_MARKET_DATA_SOURCE`; cancelled S50
false rule = `REJECTED`. If market-data grounding for S50 is unavailable, keep it
user-memory + `NEEDS_MARKET_DATA_SOURCE` — do not upgrade to fact. Residual NEEDS
VERIFICATION (VPS provider/pricing, Days 6–8) stays tagged.

Must fold in: ROADMAP.md deferred items, PIPELINE_STATE Lanes A–I, the G0–G6 grouping
phases, the MT5 0A→materializer phases, the Notes activation trigger, the GUGU v2 sprint +
cost-ceiling lane, and every GATED/DEFERRED item from chapter 03. Cross-reference each to
its subsystem and status tag. *Sources:* `ROADMAP.md`, `artifacts/pipeline/*`, chapter 03,

Must fold in: ROADMAP.md deferred items, PIPELINE_STATE Lanes A–I, the G0–G6 grouping
phases, the MT5 0A→materializer phases, the Notes activation trigger, the GUGU v2 sprint +
cost-ceiling lane, and every GATED/DEFERRED item from chapter 03. Cross-reference each to
its subsystem and status tag. *Sources:* `ROADMAP.md`, `artifacts/pipeline/*`, chapter 03,
`thus-trading-bot`, user memory. **Primary gap:** GUGU, Mentor, Pattern/Lesson, Portfolio
roadmaps — **NEEDS VERIFICATION**.

### `05_SYSTEM_ARCHITECTURE.md`
The technical architecture: single-file React SPA (`index.html`), Supabase (tables
`trades`, `portfolio`, `products`, `notes`, `user_data`, `portfolio_summary`,
`trade_events`[archived], `trade_groups`, MT5 staging tables, Capture Bot `checkin_*`),
RLS model, Storage (`trade-images`), Netlify deploy, local MT5 tooling, the Capture Bot.
Data-flow diagrams: save path (`db.saveTrade`/`commitUpdateTrade`), load/hydration,
grouping RPCs, MT5 staging. *Sources:* migrations, closeouts, `RESOURCE_AUDIT.md`.

### `06_ENGINEERING_PRINCIPLES.md`
The hard-won rules: raw is canonical / P/L invariant; durable save-first (no optimistic
success); smallest-surface fixes (don't swap frameworks for a bug); default-off flags;
schema designed up-front + human-applied; adversarial review; "when in doubt STOP."
Include the lessons behind them (silent loss, double-count, `57014` timeouts, single-file
scale). *Sources:* `AUTOPILOT_RULES.md`, `ROADMAP.md`, persistence closeouts, memory index.

### `07_JOURNAL_SUBSYSTEM.md`
Deep-dive on the Journal: data model, the durable-write architecture (P0/P1/P2), closed-
trade correction, image externalization at the render layer, the `[DIAG]`/`affected===0`
tripwire, deferred cleanups (navigation, PageSteps, uid()). *Sources:*
`artifacts/close_position_journal_bug/*`, `artifacts/p2_deploy_readiness/*`,
`artifacts/ui/*`, `ROADMAP.md`.

### `08_MERGE_AND_GROUPING.md`
Deep-dive on grouping: why Merge was disabled (P0-2 double-count), the metadata model,
P/L invariant, phases G0–G6, the write-gate/RPC gating, the `isMerged` guard, and the G5
GUGU-summary hook. *Sources:* `artifacts/g2_grouping/*`, `artifacts/merge_grouping/*`,
`ROADMAP.md`, grouping migrations.

### `09_MT5_SUBSYSTEM.md`
Deep-dive on MT5: the 3-table staging schema + RPCs, the local Python writer, cross-
account gate, `needs_mapping`, idempotency (`position_id`/`deal_id`/`raw_sha`), the
read-only Inbox, the dry-run harness, and the gated path to materialization. *Sources:*
`artifacts/mt5_auto_draft_import/*`, `artifacts/mt5_import/*`, `ops/mt5_import/*`.

### `10_GUGU_SUBSYSTEM.md`
GUGU proper: the v2 memory-stream + reasoning architecture (PydanticAI + Claude Sonnet 4.6,
pgvector memory, 3 chat tools), personality, the observation/shadow cycle, the capture bot,
the cognition **freeze** policy (`CAPTURE_ONLY_MODE` + `manual_run_guard`), the live cost
ceiling, and the path to unfreeze. **Now substantially sourced** —
[`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) is the primary capture (built
in-repo but runtime-frozen). Residual NEEDS VERIFICATION: Days 6–8, "adversarial testing"
wording, live corpus count. *Sources:* `GUGU_V2_RECONCILIATION.md`, `thus-trading-bot`
`gugu/*` + `CLAUDE.md`, user.

### `11_MENTOR_AND_KNOWLEDGE.md`
The Notes/Knowledge layer (taxonomy, activation trigger, bulk-import gate) and the Mentor
reasoning/hypothesis layer. How curated knowledge feeds GUGU retrieval; why bulk-dumping is
forbidden. **Now partly sourced:** the bot-side `bot_knowledge` keyword store (7 categories)
+ **78-row** cold-start into `gugu_memory`, and the real shipped **Note Activation v0.1**
(6 deterministic, no-LLM during-trade mentor reminders) — see
[`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) §9–10. Residual NEEDS
VERIFICATION: the NotebookLM/mentor-PDF pipeline, Wyckoff/candlestick curriculum (likely
THUS Journal notes / user memory). The **Mentor View** structure, **Market Pattern Library**
design, and **S50 rules** are captured (user-memory, tags preserved) in
[`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md)
§3–5 — `NEEDS_REPO_SOURCE` / `NEEDS_MARKET_DATA_SOURCE`. *Sources:* `docs/notes_taxonomy.md`,
`ROADMAP.md` (Notes §), `GUGU_V2_RECONCILIATION.md`,
`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`, user.

### `12_MAJOR_DECISIONS_ADR.md`
Architecture Decision Records: disable-Merge-not-repair; grouping-as-metadata (Option B);
single-row durable writes over full-array; image externalization to Storage; product
registry as a facade; MT5 gated-staging-not-auto-materialize; GUGU cognition freeze;
Mem0 rejection / raw-memory over extracted facts (from GUGU v2). One ADR per decision:
context → decision → consequences → status. *Sources:* audits, design docs, `ROADMAP.md`.

### `13_HISTORY_AND_EVOLUTION.md`
The narrative timeline: GUGU v1 (hardcoded architecture) → abandonment → GUGU v2 vision →
Journal-hardening phase (persistence P0/P1/P2, images, product registry, grouping G0–G6,
MT5 0A→0D-1). Ties the memory-index milestones into one story. *Sources:* memory index,
closeouts, `ROADMAP.md`, `thus-trading-bot` handoff.

### `14_CURRENT_STATE.md`
A precise snapshot: prod bundle + version, HEAD/origin, what's live vs gated per lane,
open smoke/verification status, DB cleanliness. Essentially a durable expansion of
`PIPELINE_STATE.md` at a point in time, updated on each major change. *Sources:*
`PIPELINE_STATE.md`, `NEXT_SAFE_TASK.md`.

### `15_OPERATIONS.md`
How to operate safely: the gate model, deploy/smoke discipline, migrations-by-human,
review chain, backup handling (sensitive image/base64 backups outside git), resource/cost
hygiene, RLS/security-hardening (Lane G, needs read-only audit first), the MT5 operator
runbooks, `pipeline_snapshot.ps1`. **Also capture the GUGU VPS host** (reported, **NEEDS
VERIFICATION**: DigitalOcean Ubuntu 24.04, IP `168.144.35.127`, resized to $6/mo while the
bot is offline, expected resize to $12/mo + restore crontab/Flask on deploy) — only after
verification against `thus-trading-bot` + user memory. *Sources:* `AUTOPILOT_RULES.md`,
`RESOURCE_AUDIT.md`, `ops/*`, runbooks, `thus-trading-bot`.

### `16_REJECTED_IDEAS.md`
What was considered and rejected, with reasons — so they aren't re-litigated: destructive
merge replacement; visual-only `_hiddenByMerge` flag; full-array writer; Mem0 fact-
extraction; pre-adding embedding columns to Notes; auto-importing check-ins into Notes;
outcome-based Trader Style Profiler; GUGU v1 hardcoded-gate architecture; **the cancelled
S50 "gap up 2 days → sell-off" rule** (`REJECTED` false pattern — captured in
[`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md)
§5.3; record here as searchable rejected knowledge so it is not re-derived;
`NEEDS_MARKET_DATA_SOURCE` if formalized). *Sources:* `ROADMAP.md`, audits, GUGU v2 vision,
`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`, user memory.

### `17_RISKS_AND_TECH_DEBT.md`
The live risk register: silent data-loss (residual non-durable writers), silent double-
count regression, single-file SPA scale + `57014`, GUGU echo-chamber / premature unfreeze,
**GUGU economic runaway (v1 ~$3/day monitor-cycle leak; mitigated in v2 by the live
fail-closed cost ceiling)**, **false-pattern re-derivation / overfitting from one historical
case** (GUGU treating a candidate pattern as a confirmed rule; a cancelled pattern being
re-derived — see `USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md` §4.6/5.3), Portfolio
roadmap thinness, mentor hypothesis lifecycle not yet implemented, docs
drift, backup-retention of sensitive data, RLS gaps pending audit, `[DIAG]`/deferred
cleanups. Each with severity + mitigation + owner-gate. *Sources:* chapters 01/03,
closeouts, `RESOURCE_AUDIT.md`, `USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`.

### `18_FUTURE_VISION.md`
The long-horizon (3-year) picture: GUGU as mature co-trader (track record, self-
correction, compound learning, two-mind adversarial debate), the full layered OS, and the
guardrails that must survive (human-in-control, no auto-execution, no silent unfreeze).
*Sources:* GUGU v2 vision, chapter 02.

---

## Cross-cutting capture tasks (independent of any single chapter)

1. **Reconcile with the `thus-trading-bot` repo — DONE (2026-07-10).** A read-only
   cross-repo pass captured GUGU v2 architecture, freeze, cost ceiling, observation cycle,
   Capture Bot, and knowledge/pattern facts into
   [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md); it feeds chapters
   10/11/13/15/16/17. Residual items there remain **NEEDS VERIFICATION** (VPS
   provider/pricing, Days 6–8, pattern-library / S50 — likely THUS Journal notes / user
   memory).
2. **Confirm migration apply-state against live Supabase** (read-only): `20260512`
   trade_events lockdown especially. Grouping migrations are settled — G1 (`20260607`)
   and G2 RPCs (`20260705`) applied, and the G2 RPC `isMerged` hardening (`20260708`) is
   **DONE / APPLIED + VERIFIED** in prod (2026-07-10, precheck 0, BEGIN/ROLLBACK PASS,
   recorded `b94f7fd`). MT5 migrations reported applied. (Read-only SELECTs only — never
   write.)
3. **Consolidate the memory index** (`.claude/.../memory/MEMORY.md` in the trading-bot
   project) into the history/ADR chapters; it holds dozens of milestone pointers.
4. **Portfolio + Mentor + Pattern-Library + S50 — user-memory capture DONE (2026-07-10).**
   Captured in
   [`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md).
   Carry its confidence tags into every chapter that consumes it; still **ground against
   repo / market-data source** before treating as authoritative. Placement: Portfolio +
   Mentor + Pattern + S50 → **ch04** roadmap; Mentor/Pattern/Knowledge detail → **ch11**;
   cancelled S50 false rule → **ch16**; false-pattern re-derivation + overfitting risks →
   **ch17**.
5. **Keep `14_CURRENT_STATE.md` and `PIPELINE_STATE.md` in sync** — one is the durable
   Bible snapshot, the other the working glance.
6. **GUGU cost/economics guardrail — largely VERIFIED (2026-07-10).** The hard, fail-closed
   cost ceiling is LIVE in `thus-trading-bot` `gugu/cost_ceiling.py` (1.5M tok/day ≈$5/day
   Sonnet, 60k/cycle, 25 calls/cycle); v1's leak was ~$3/day (not $5). Residual: a
   human-facing per-cycle token/cost **log line** / `/cost` command is not yet implemented
   (usage is persisted to a ledger). Keep it a first-class lane in
   `17_RISKS_AND_TECH_DEBT.md`. See [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) §5.
7. **Existing knowledge corpus — partially corrected (2026-07-10).** Verified: a
   `bot_knowledge` keyword store (**7** categories) + a **78-row** cold-start into
   `gugu_memory` (not ~70 / 17). **Not found** in `thus-trading-bot`: the mentor-PDF →
   NotebookLM pipeline and a candlestick/Wyckoff curriculum — these remain **NEEDS
   VERIFICATION** (likely THUS Journal notes / user memory). See
   [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) §9.
8. **Cross-repo GUGU v2 reconciliation is a prerequisite for chapter 04** (see the 04
   entry's BLOCKED_BY). Do not let chapter 04 ship as a single authoritative roadmap
   before it.
9. **GUGU VPS host — partially corrected (2026-07-10)** for chapter 15. Verified in-repo:
   IP `168.144.35.127` + a systemd deploy (`gugu/DEPLOY.md`, `gugu-telegram.service`,
   `/opt/gugu`, `python -m gugu.tg_bot` polling). **NEEDS VERIFICATION** (not in repo):
   DigitalOcean, Ubuntu 24.04, $6→$12 pricing/offline-online. **Flask on deploy is REFUTED**
   for v2 (polling, not webhook); crontab is v1-only. See
   [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) §6.
10. **S50 pattern items — NOT FOUND in `thus-trading-bot` (2026-07-10); capture from user
    memory / THUS Journal.** No "Market Pattern Library" (trigger+lesson+action) exists in
    the bot repo; the closest shipped feature is **Note Activation v0.1** (6 deterministic
    during-trade mentor reminders). The cancelled "gap up 2 days → sell-off" rule (→ chapter
    16) and the corrected S50 gap-down / `S50H26` 1029→942 case (→ Pattern/Lesson, chapter
    11) are **NOT** in either repo — **NEEDS VERIFICATION**. See
    [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) §10.

> **Provenance note (updated 2026-07-10):** the cross-repo reconciliation (task 1) has
> replaced much of the Fable/ChatGPT provenance with primary `thus-trading-bot` sources —
> see [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) for what is now CONFIRMED
> vs still NEEDS VERIFICATION. Remaining unverified items (VPS provider/pricing, Days 6–8,
> pattern-library / S50) likely live in THUS Journal notes / user memory; do not assert
> them as verified until captured.

---

## Do-not-forget list (the gates, restated)

Even while *documenting*, never let a later chapter's author quietly do any of these —
they are human-gated regardless of how the docs read:

- Enable `tj_trade_group_write_v01` or any `tj_*` write flag.
- Keep a real (non-rollback) trade group.
- Apply any SQL/RLS/schema/migration, or run any write-RPC.
- Run further MT5→staging writes, or run the (unbuilt) staging→trades materializer.
- Unfreeze GUGU cognition / autonomy.
- Push or deploy (unless a *current* standing user preference authorizes deploy-after-
  clean-preflight — confirm it's current).
- Touch durable save/close/delete/merge/import paths.
