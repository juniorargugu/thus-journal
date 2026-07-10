# TODO — Roadmap & Chapter Capture

This phase created the **foundation** of the Bible (README + chapters 00–03 +
SOURCE_INVENTORY). This file lists the remaining chapters and, for each, what must be
captured — so nothing disappears just because it is not implemented yet.

**Rule:** roadmap items are tagged, never dropped. Use the status vocabulary from
[`README.md`](./README.md): **DONE · LIVE · DESIGNED · REVIEWED · DEFERRED · GATED ·
RESEARCH · VISION · NEEDS VERIFICATION.** When a source is missing, capture the item as
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

---

## Remaining chapters to write

### `04_COMPLETE_ROADMAP.md` — **BLOCKED_BY cross-repo + user-memory capture**
The single consolidated, tagged roadmap across all subsystems — the master list so no
track is lost.

**Do not write this yet as a single authoritative master roadmap.** GUGU, Mentor,
Pattern/Lesson, and Portfolio are still thin (see [`SOURCE_INVENTORY.md`](./SOURCE_INVENTORY.md) §7).
**BLOCKED_BY:** (1) cross-repo GUGU v2 reconciliation from `thus-trading-bot`; (2)
user-memory capture for Mentor / Pattern-Lesson / Portfolio.

**Preferred sequencing (Approach A):** run those capture passes *first*, then write
chapter 04 whole. **If** chapter 04 is written before capture completes, it **must be
explicitly partial** — carry a banner ("Journal-side roadmap; GUGU / Mentor / Pattern /
Portfolio pending capture"), or split into `04A_JOURNAL_SIDE_ROADMAP.md` +
`04B_GUGU_SIDE_ROADMAP.md` with **04A clearly labeled as *not* the whole roadmap.**

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
GUGU proper: the v2 memory-stream + reasoning architecture, personality, tools, the
capture bot, the cognition **freeze** policy, and the path to unfreeze. **Largest capture
gap** — most detail lives in the separate `thus-trading-bot` repo + user memory. Capture
deliberately; mark **NEEDS VERIFICATION** everywhere until confirmed against the current
GUGU design. *Sources:* `thus-trading-bot` CLAUDE.md, memory index, user.

### `11_MENTOR_AND_KNOWLEDGE.md`
The Notes/Knowledge layer (taxonomy, activation trigger, bulk-import gate) and the Mentor
reasoning/hypothesis layer (currently VISION). How curated knowledge feeds GUGU retrieval;
why bulk-dumping is forbidden. *Sources:* `docs/notes_taxonomy.md`, `ROADMAP.md` (Notes
§). **Mentor design = NEEDS VERIFICATION.**

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
runbooks, `pipeline_snapshot.ps1`. *Sources:* `AUTOPILOT_RULES.md`, `RESOURCE_AUDIT.md`,
`ops/*`, runbooks.

### `16_REJECTED_IDEAS.md`
What was considered and rejected, with reasons — so they aren't re-litigated: destructive
merge replacement; visual-only `_hiddenByMerge` flag; full-array writer; Mem0 fact-
extraction; pre-adding embedding columns to Notes; auto-importing check-ins into Notes;
outcome-based Trader Style Profiler; GUGU v1 hardcoded-gate architecture. *Sources:*
`ROADMAP.md`, audits, GUGU v2 vision.

### `17_RISKS_AND_TECH_DEBT.md`
The live risk register: silent data-loss (residual non-durable writers), silent double-
count regression, single-file SPA scale + `57014`, GUGU echo-chamber / premature unfreeze,
**GUGU economic runaway (no cost ceiling / token-cost leak — v1 ~$5/day lesson)**, docs
drift, backup-retention of sensitive data, RLS gaps pending audit, `[DIAG]`/deferred
cleanups. Each with severity + mitigation + owner-gate. *Sources:* chapters 01/03,
closeouts, `RESOURCE_AUDIT.md`.

### `18_FUTURE_VISION.md`
The long-horizon (3-year) picture: GUGU as mature co-trader (track record, self-
correction, compound learning, two-mind adversarial debate), the full layered OS, and the
guardrails that must survive (human-in-control, no auto-execution, no silent unfreeze).
*Sources:* GUGU v2 vision, chapter 02.

---

## Cross-cutting capture tasks (independent of any single chapter)

1. **Reconcile with the `thus-trading-bot` repo.** GUGU, Capture Bot, and the memory-
   stream architecture are documented there, not here. A dedicated pass should pull the
   current (not just v2-era) design into chapters 10/11/13. **NEEDS VERIFICATION.**
2. **Confirm migration apply-state against live Supabase** (read-only): `20260512`
   trade_events lockdown especially. Grouping migrations are settled — G1 (`20260607`)
   and G2 RPCs (`20260705`) applied, and the G2 RPC `isMerged` hardening (`20260708`) is
   **DONE / APPLIED + VERIFIED** in prod (2026-07-10, precheck 0, BEGIN/ROLLBACK PASS,
   recorded `b94f7fd`). MT5 migrations reported applied. (Read-only SELECTs only — never
   write.)
3. **Consolidate the memory index** (`.claude/.../memory/MEMORY.md` in the trading-bot
   project) into the history/ADR chapters; it holds dozens of milestone pointers.
4. **Portfolio + Pattern/Lesson + Mentor** are the thinnest-sourced areas — schedule
   explicit user-memory capture sessions before writing chapters 03-expansion/11.
5. **Keep `14_CURRENT_STATE.md` and `PIPELINE_STATE.md` in sync** — one is the durable
   Bible snapshot, the other the working glance.
6. **Capture the GUGU cost/economics guardrail as a first-class lane.** A hard cost
   ceiling + per-cycle token/cost logging are release-gating for v2 (v1 reportedly leaked
   ~$5/day on a Haiku daemon; **NEEDS VERIFICATION**). Track it alongside the safety gates
   and in `17_RISKS_AND_TECH_DEBT.md`, not as an afterthought.
7. **Capture the existing knowledge corpus.** The knowledge layer is not zero-start:
   reported mentor-PDF → NotebookLM → `bot_knowledge` pipeline, ~70 items / 17 categories,
   candlestick / Wyckoff artifacts, codified rules (range boundaries, no-falling-knife,
   S50 gap rule). Reconcile from `thus-trading-bot` + user memory before the Notes/Mentor
   chapters. **NEEDS VERIFICATION.**
8. **Cross-repo GUGU v2 reconciliation is a prerequisite for chapter 04** (see the 04
   entry's BLOCKED_BY). Do not let chapter 04 ship as a single authoritative roadmap
   before it.

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
