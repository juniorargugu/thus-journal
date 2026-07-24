# 10 — GUGU Subsystem

*The destination chapter. Journal, MT5, Portfolio, Grouping, Mentor, Notes, and Pattern
Library all exist so that this layer can one day reason over trustworthy data. This chapter
describes what GUGU is, what exists today, what stays frozen, and what would have to be true
before any unfreeze question is even askable.*

**Primary source:** [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) — the
read-only cross-repo capture of GUGU v2 from `thus-trading-bot` at `b03758a` (2026-07-10),
with `file:line` evidence. Where this chapter says CONFIRMED, that doc backs it. Where it
says NEEDS VERIFICATION, the bot repo was silent and the fact likely lives in THUS Journal
notes or user memory.

**Scope discipline.** Sections that describe Journal, MT5, Portfolio, Grouping, Mentor,
Notes, and Pattern Library define GUGU's **consumption contract** with those subsystems.
They do not replace the subsystem deep-dive chapters and should not duplicate internals
beyond trust boundaries, epistemic status, and gating. For the internals, see the owning
chapter (07 Journal, 08 Grouping, 09 MT5, 11 Mentor/Knowledge, 15 Operations).

---

## 1. What GUGU is

GUGU is the **AI-native trading copilot / trading operating layer** that is the North Star
of THUS (chapter 02). It is the long-term **primary consumer** of everything the rest of
the system produces.

What GUGU **is not**:

- **Not an auto-trader.** It never places orders. Every trade decision is the human's.
- **Not merely a Telegram bot.** Telegram is one interface. The deployed capture bot is a
  sense/actuator surface, not GUGU's identity (§14).
- **Not a Journal feature.** The Journal is GUGU's memory/data layer, not GUGU itself.

Its operating principle is **propose, not prescribe**: *"this setup looks like X — is there
something you're seeing that I'm not?"* rather than *"do X."* **The human stays in
control.** GUGU may hold opinions, connect dots, and challenge the trader — including
challenging emotional state — but judgment and execution remain human.

### 1.1 Personality / identity

GUGU's personality is a **safety property**, not decoration. The intended character
(`gugu/personality.py`, ~306 lines, 9 hard rules — CONFIRMED it exists in-repo):

- **Direct, dry, low-hype.** No filler, no cheerleading.
- **Confident only when grounded.** Confidence tracks evidence, not tone.
- **Shows receipts.** Claims about the trader's framework cite retrieved memories, not
  fabrications.
- **Preserves uncertainty.** It surfaces conflicts instead of averaging them away; a single
  memory is "tentative," several converging memories are "consistent."
- **Says "teach me?" or asks when it lacks context** instead of inventing an answer.

The through-line is **anti-fabrication as personality, not just a safety rule**. A copilot
that fills gaps with plausible fiction is worse than one that admits ignorance, because the
trader cannot tell the two apart. GUGU is built to prefer "I don't have a memory for that"
over a confident guess.

---

## 2. Why GUGU exists

A trader accumulates, over years, an enormous stream of decisions, emotions, theses,
executions, mistakes, lessons, and observations. Human memory is **lossy**: the reasons
behind a good trade fade, the emotional tell that preceded a bad one is forgotten, the
lesson learned in March is unavailable in September.

Static journaling helps but is **insufficient** — it records, it does not reason. You can
write down a mistake and still repeat it, because a written record does not surface itself
at the moment it is relevant.

GUGU's purpose is to turn **durable memory into better decision quality**: to recall the
right prior at the right time, to compare what the trader predicted against what actually
happened, and to challenge patterns that only feel true. This is why the Journal-hardening
program matters (chapter 02): every durable-write fix, every P/L invariant, every gated
migration removes a way the future AI could be misled. **We harden the Journal now so GUGU
can trust the data later.**

---

## 3. Repo topology and authority

GUGU spans two repositories:

- **`thus-journal`** (this repo) — the Journal / memory-data layer, the production SPA
  (`index.html`), the Supabase-facing artifacts, and the home of this Project Bible.
- **`thus-trading-bot`** (sibling repo) — the **GUGU runtime and active v2 codebase**: the
  agent, memory stream, observation cycle, capture bot, freeze guards, and cost ceiling.

**This chapter documents GUGU's direction and its consumption contract with the other
subsystems.** It is not the authoritative source for the bot's latest sprint state.

**Rule for agents working in `thus-trading-bot`:** read *that* repo's own CLAUDE.md /
handoff / current-state docs **first**, then reconcile back to this Bible. If repo-local
docs conflict with this chapter, **flag and reconcile — do not silently choose one.** This
chapter's GUGU facts were captured read-only at a point in time (`b03758a`); the bot repo
moves independently.

---

## 4. GUGU in the THUS layered model

Each layer has a distinct role, and the roles must not blur (chapter 02):

| Layer | Role for GUGU |
|---|---|
| **Journal** | Memory / data layer — the canonical, durable record GUGU reads as truth. |
| **MT5** | Execution / source layer — ground-truth broker fills, prices, contract sizes. |
| **Portfolio** | State / risk layer — balance, equity, HWM, exposure, concentration. |
| **Notes / Knowledge** | Learning / retrieval layer — curated, human-shaped priors. |
| **Mentor** | Hypothesis / reasoning layer — forms and tests framework hypotheses. |
| **Pattern Library** | Structured market-experience layer — repeated observations as reviewable patterns. |
| **GUGU** | Reasoning / copilot layer **across all of the above**. |

**Data-flow (text diagram):**

```
MT5 executions
   → staging / Inbox                (gated; not yet Journal truth)
   → confirmed Journal trades        (canonical, durable, P/L-bearing)
   → Portfolio state + trade memory  (risk picture derived from executions)
   → Notes / Mentor / Pattern Library (human-shaped priors + hypotheses)
   → GUGU context                    (retrieval over all of the above)
   → observation / reflection / challenge / proposal   (never autonomous action)
```

Reading direction matters: GUGU consumes **downstream** of confirmation. It does not read
staged MT5 rows or optimistic UI state as truth (§13, §19), and it does not turn its own
outputs back into executions.

---

## 5. GUGU v1 autopsy

- **What it was.** The first bot — *"Python = eyes/reflex, Claude = brain"* — with stacked
  hardcoded gates (PreFilter, guardrails, hallucination gate, zone rules) and a monitor
  daemon. **CONFIRMED.**
- **Archived 2026-04-26.** Git tag `v1-final` → `ae39250`; code moved to
  `/opt/archive/gugu-bot-v1-20260426/`; services stopped and disabled
  (`thus-trading-bot` `CLAUDE.md:64-68`). **CONFIRMED.**
- **Cost leak — ~$3/day.** The documented leak was **~$3/day** from monitor cycles that
  mostly produced "NOTHING" (`CLAUDE.md:88`), on a **Haiku-default** monitor path
  (`claude_brain.py:495-497,1082`). **CONFIRMED.** This is *not* the "$5/day" figure — see
  §8 for why that conflation is wrong.
- **Why it failed.** Every feature was hardcoded logic; each fix added more edge cases and
  more patches — a **maintenance death spiral**. The economic runaway (a daemon burning
  money to output "NOTHING") was itself a **system-safety failure**, not just a cost
  annoyance.

**Lessons carried into v2:**

- A **hard cost ceiling** (§8).
- **Fail-closed** behavior everywhere money or autonomy is involved.
- **No silent autonomous runtime** — cognition is frozen by default (§7).
- **Observation before action** — the cycle emits findings, never trades (§12).
- **Memory-stream + reasoning over brittle hardcoded logic** — everything is text; the
  model retrieves and reasons; tools are senses/actuators (§9).

---

## 6. GUGU v2 current state

Grounded in [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md). GUGU v2 is a
**real, built-in-repo** memory-stream co-pilot — **not vision-ware** — but it is currently
**runtime-frozen** (capture-only). "Built" and "running" are different questions.

**CONFIRMED (in-repo at `b03758a`):**

- **Framework:** PydanticAI (`gugu/agent.py`, `cycle_agent.py`). No LangChain/LlamaIndex.
- **Model:** Claude **Sonnet 4.6** (`gugu/agent.py:37` `MODEL = "anthropic:claude-sonnet-4-6"`).
- **Memory stream:** append-only over Supabase **pgvector** with OpenAI
  `text-embedding-3-small` (1536-d) — `gugu/memory.py`, `gugu/README.md`.
- **Chat tools:** exactly **3** — `search_memories`, `append_memory`, `get_price` (§11).
- **Capture bot / Telegram interface:** deployed surface, capture-only (§14).
- **Observation / shadow cycle:** emits falsifiable `CandidateFinding` objects, **no
  memory-write, no trade recommendations** (§12).
- **Cost ceiling:** implemented in code, fail-closed (§8).
- **Runtime / cognition:** **FROZEN** in production (§7).

**Wording rule (do not overstate a frozen system).** The bot's cognitive runtime is not
running in production. So:

- Say the **cost ceiling is implemented in code and fail-closed; it applies whenever the
  runtime runs** — *not* "cost ceiling live" as if it were actively metering a production
  agent right now.
- Say GUGU v2 is **built in-repo but capture-only / frozen** — *not* "GUGU is live."

**Still NEEDS VERIFICATION (do not assert as fact):**

- **"Days 6–8"** as distinct completed days — repo tags stop at **Day 5A.x**.
- **"Adversarial testing"** — no adversarial second-pass *agent* in the runtime path; what
  exists is eval-suite `forbidden_invariants` + a sanitizer re-check (§10).
- **"Locally verified" run logs** — test harnesses exist, but no captured run log; this
  capture executed nothing.
- **Live corpus count** — the DB was not queried; the 78-row cold start is attested, not
  live-counted (§15).
- **VPS provider / OS / pricing** and any **crontab** step — see §21 / chapter 15.

---

## 7. Runtime freeze policy

The freeze is **two-layer and fail-closed** (audit:
`artifacts/gugu_freeze_inventory/gugu_freeze_inventory_report.md`, 2026-06-02;
`freeze_hardening_phase1_report.md`). **CONFIRMED.**

1. **`CAPTURE_ONLY_MODE` — deployed bot defaults to frozen.** `gugu/tg_bot.py:125`
   `_is_capture_only_mode()`; when `CAPTURE_ONLY_MODE` is unset → `True`. Cognition handlers
   (`/gugu_run`, `/gugu_digest`, `/start`, free-text, …) are registered **only** in the
   non-frozen `else` branch — i.e. **not registered while frozen**.
2. **`manual_run_guard` — manual entry points fail-closed.** `gugu/manual_run_guard.py`
   gates `cli`, `shadow_cycle`, `evals/runner`, `evals/real_data_tests`, `test_real_cycle`.
   Unset → frozen; any true-ish value → blocked; even `false/0/no/off` → **still blocked
   unless** `GUGU_ALLOW_COGNITION_MANUAL_RUN == "YES_I_UNDERSTAND"` (exact string). On
   block: prints "GUGU cognition is frozen / No LLM call was made" and `SystemExit(2)`.

**What the freeze forbids:** autonomous cognition running against live/production data, or
producing production behavior, on any repo, without explicit approval. No `/gugu_run`, no
cycle progression, no second shadow cycle unless explicitly approved.

**What the freeze does not forbid:** reviewed GUGU **v2 development** in `thus-trading-bot`
(under its own gates), and **capture-only production behavior** (the check-in bot).

**Production autonomous cognition remains GATED.**

**Policy-vs-guard primacy.** The freeze is a **policy decision first and an infrastructure
guard second.** The guard code (`CAPTURE_ONLY_MODE`, `manual_run_guard`) is
defense-in-depth. **Removing, refactoring, or bypassing the guard code does not end the
freeze** — only an explicit, reviewed human go-ahead does. A green build is not permission.

---

## 8. Cost and economic safety

**Cost safety is a first-class system-safety rule — same rank as "no silent unfreeze."** The
v1 lesson (§5) is that an unbounded agent can burn money producing nothing; economic
runaway is a safety failure.

**v1 leak:** **~$3/day**, Haiku-default monitor cycles that mostly produced "NOTHING"
(`CLAUDE.md:88`). **CONFIRMED.**

**v2 cost ceiling** — implemented in code, fail-closed (`gugu/cost_ceiling.py`, ~420 lines;
covered by `gugu/test_cost_ceiling.py`, ~569 lines). Caps are in **tokens/calls**, not USD:

- `DEFAULT_DAILY_TOKEN_BUDGET = 1_500_000` — **1.5M tokens/day ≈ $5/day at Sonnet 4.6
  blended rate** (the "$5/day" is the **v2 Sonnet ceiling headroom**, a separate thing from
  the v1 leak).
- `DEFAULT_CYCLE_TOKEN_BUDGET = 60_000` — **60k tokens/cycle**.
- `DEFAULT_MAX_CALLS_PER_CYCLE = 25` — **25 calls/cycle**.
- Env-overridable; `guard_pre_call()` raises `CostCeilingExceeded` **before** the API call;
  corrupt/invalid config or ledger also raises (**fail-closed**). Day boundary Asia/Bangkok.
  Wired into `agent.py`, `cycle_agent.py`, `memory.embed`.

**Per-cycle accounting — PARTIAL.** Tokens + calls are counted per cycle (`contextvars`) and
persisted per day to `logs/gugu_usage_ledger.json`, with a `blocked` counter on cap hits.
But there is **no human-facing per-cycle cost *log line*** and **no `/cost` command** in v2
(`/cost` existed only in archived v1). So: **counted + persisted, not printed.**

*Operational logging/alerting details (dashboards, thresholds, monitoring) belong to
chapter 15 (Operations), not here.* This section fixes only the **safety rank** and the
**source-backed numbers**.

---

## 9. Memory architecture

- **Memory stream.** Everything is **text** in an append-only stream — no hardcoded
  importance scores, no event-type classification. The model retrieves relevant memories
  and reasons over them.
- **pgvector memory.** Supabase pgvector with OpenAI `text-embedding-3-small` (1536-d);
  `embed` / `append` / `recall` via a `match_memories` RPC (`gugu/memory.py`). **CONFIRMED.**
- **Cold start.** `gugu/cold_start.py` imported from the Supabase `bot_knowledge` table;
  **78 rows** attested (`gugu/README.md`, `personality.py`, `CLAUDE.md:290`), across the
  **7** `bot_knowledge` categories. Live count NEEDS VERIFICATION (DB not queried). See §15
  for the cold-start-vs-bad-bulk-import disambiguation.
- **Raw memory vs curated knowledge vs notes vs extracted facts.** GUGU's stream is **raw,
  lossless observation** — deliberately *not* Mem0-style fact extraction. Fact extraction was
  rejected because it is lossy (loses time, magnitude, cross-asset context) and costs an LLM
  call per append; trading needs lossless, temporal, exact observations. **CONFIRMED as a
  design decision** (chapter 12 ADR; `DECISIONS.md`). Curated Notes/Knowledge are the
  human-shaped priors (chapter 11); they are a different corpus from the raw stream.

**Epistemic status labels.** Any captured knowledge should carry its status, and GUGU must
preserve it rather than flatten it:

`fact` · `note` · `hypothesis` · `lesson` · `candidate pattern` · `confirmed pattern` ·
`rejected / cancelled pattern`.

**Self-correction / prediction-outcome tracking (design intent).** GUGU should not just
remember — it should **compare predictions to outcomes** when such data exists.
Prediction-outcome pairs feed self-correction and future pattern review, and **candidate
patterns should mature from observed prediction/outcome evidence, not vibes.** This is the
intended behavior; a dedicated self-correction loop over stored predictions is design intent
(Phase 2+), not a confirmed running feature.

**Relationship to THUS Journal raw data.** The Journal's raw executions are the canonical
substrate; GUGU's memory stream is observation *about* that substrate, not a competing
source of P/L truth (§13).

---

## 10. Adversarial second pass / echo-chamber defense

A trader + AI pair can **mutually reinforce a wrong thesis** — the trader wants
confirmation, the model obliges, and both grow more confident in an error. Chapter 02 names
this the **#1 risk** of the pairing.

The intended defense is an **adversarial second pass** that challenges each finding **before
it reaches Junior**, asking:

- What would **invalidate** this?
- What evidence **contradicts** it?
- Is this a **repeated pattern or a one-off**?
- Is the model **overfitting** one case?
- Is the user **seeking confirmation**?

**Epistemic status: DESIGN INTENT.** As of the reconciliation, there is **no adversarial
second-pass *agent*** in the runtime path. What exists today is adversarial-*style* test
invariants: the eval suite's `forbidden_invariants` (`gugu/models.py`,
`gugu/evals/runner.py`) and a sanitizer re-check in `shadow_cycle.py`. Do not describe the
adversarial pass as implemented.

The adversarial pass, when built, **challenges conclusions — it does not authorize
autonomous decisions.** It is a quality gate on what GUGU tells the human, not a license to
act.

---

## 11. Tools and senses

Tools are GUGU's **senses and actuators — not permission to act autonomously.** Any write or
runtime action remains gated (§22).

**Exist today (CONFIRMED) — 3 chat tools** (`gugu/agent_tools.py`, wired at
`gugu/agent.py:42`):

- `search_memories` — semantic recall over the memory stream.
- `append_memory` — write an observation to the stream (chat path only; **the observation
  cycle cannot write memory**, §12).
- `get_price` — live price lookup (never invent a price).

The observation cycle adds **2 read-only** tools (`fetch_price_snapshot_tool`,
`recall_memories_tool`; `gugu/cycle_agent.py`) and cannot write.

**Intentionally limited / deferred:** `get_ohlcv` is deferred (`gugu/symbols.py`). There is
no order tool, no Journal-write tool, no Portfolio-write tool, no MT5-write tool in GUGU's
runtime.

**Future read paths (design intent, gated):** Journal read path, MT5 read path, Portfolio
read path, and broader market-data awareness. Each is a *sense* to be added under review;
none implies a write or an autonomous action.

---

## 12. Observation cycle

The cycle is **observation-only before action** — the echo-chamber-safe posture in code
(`gugu/cycle_prompt.py`, `gugu/models.py` validators, `gugu/shadow_cycle.py` read-back
verify; "L2c locked"). **CONFIRMED.**

- **No memory-write during the constrained cycle** — the cycle's tools are read-only.
- **No trade recommendations** — findings are structured, falsifiable `CandidateFinding`
  objects.

**Allowed outputs:** context summaries · candidate concerns · questions · non-actionable
insight.

**Forbidden outputs:** trade commands · autonomous decisions · recommendations framed as
instructions · writes to Journal / Portfolio / MT5.

The hardcoded element is *when* the cycle runs (a deterministic timer); *what* it thinks is
emergent from memories + situation. Frozen in production (§7), the cycle does not run against
live data without approval.

---

## 13. Relationship to Journal

- **Journal is GUGU's memory/data layer.** Raw trade rows are **canonical**; all P/L derives
  from raw executions (chapter 02, chapter 07).
- **GUGU reads only durable-persisted data as truth.** **Optimistic UI state is not truth** —
  a close that only reached a toast but not the database did not happen, as far as GUGU is
  concerned. Durable single-row writes (P0/P1/P2) are precisely what make the Journal
  trustworthy for this.
- **GUGU must not write the Journal** unless a future, explicitly-approved write path exists.
  The **G5 GUGU-summary hook** (`[Insert GUGU summary]`) is **future / designed, not active**
  (§20).
- **Human and AI views must agree** because both derive from the same raw walk.

**Trust conditions GUGU depends on:** durable write path · no raw mutation · P/L invariant ·
no synthetic P/L-bearing rows · provenance retained.

---

## 14. Telegram / Capture Bot

**Telegram is an interface, not GUGU's identity.** The deployed surface is **capture-only**
(§7): it records behavioral data; it does not run cognition.

- **Current capture-only commands (CONFIRMED, `tg_bot.py:1025-1051`):** `/start_checkin`,
  `/whoami`, `/status`, `/review_today`, `/checkin`, `/checkin_trade`, `/snooze`, `/resume`,
  `/off`, `/note`, `/undo_note`, `/delete_last_note`, `/daily_on|off`, `/during_on|off`,
  `/frequency`, `/help`. Cognition commands register **only** when unfrozen.
- **Capture data model:** `checkin_events` / `checkin_tags` / preferences — a **behavioral
  time-series** of the trader's state, holdings, and reflections.
- **Scheduled holding prompts** and a **weekend/holiday cadence reduction** preference are
  part of the capture design.
- **Future (design intent, gated):** group-aware check-ins and market-aware cadence.

The capture bot is a **sense** feeding GUGU's future context; it is not GUGU reasoning.
(Do not confuse the capture bot with GUGU itself — §23.)

---

## 15. Note Activation and Knowledge

- **Note Activation v0.1 (CONFIRMED shipped, `gugu/note_activation.py`).** Deterministic,
  tag-gated, **no-LLM** during-trade **mentor reminders** — **6** hardcoded reminders keyed
  to emotion tags (`fear_giveback`, `want_exit_early`, `want_add_position`, `force_narrative`,
  `plan_drift`, `size_too_big`); explicitly **"not a signal/action"**
  (`note_activation.py:38`). Design: `artifacts/note_activation/note_activation_v0_1_design.md`.
  This is the closest shipped thing to a "mentor warning" — it is **not** a Market Pattern
  Library (§17).
- **Relationship to `bot_knowledge` / cold start.** The `bot_knowledge` keyword store (**7**
  categories, no embeddings) is the v1-era curated knowledge; the **78-row** cold start
  seeded `gugu_memory` from it (§9). **CONFIRMED** (7 categories / 78 rows — *not* the
  "~70 items / 17 categories" some earlier notes claimed).

**Disambiguation — cold-start corpus vs "bad bulk import" (relationship: NEEDS
VERIFICATION).** Two framings of a 78-row import appear in the sources and must not be
collapsed:

- The **reconciliation** treats the **78-row cold start** as a *working* corpus — "not
  zero-start," 78 real imported memories, retrieval passed the spike test.
- Chapter 02 (line 91–93) uses a **"bulk import of 78 rows"** as a *cautionary tale* — an
  example of how unfiltered dumping floods retrieval with stale zones and biases the model,
  and why Knowledge is deliberately kept small and hand-shaped.

These **may be the same 78 rows described from two angles** (the cold-start import is also
the object lesson in why not to bulk-dump), or two separate events. **No source settles
this**, so the relationship is tagged **NEEDS VERIFICATION**. Critically: **do not invert
the cautionary warning into a "great corpus" claim, or vice-versa, without a source.** Both
framings stand as written until verified.

- **NotebookLM / mentor-PDF pipeline** and a **Wyckoff / candlestick curriculum** are
  **NOT FOUND** in `thus-trading-bot` (the only `.pdf` is the SET holiday calendar; Wyckoff
  appears only in a personality example dialogue) → **NEEDS VERIFICATION** (likely THUS
  Journal notes / user memory).
- **Principle:** knowledge must not become a noisy bulk import; **retrieval should surface
  useful framework context, not stale zones or arithmetic.**

---

## 16. Relationship to Mentor

- **Mentor is the hypothesis / reasoning layer** (chapter 11). A **Mentor View** is a
  captured market **hypothesis** (symbol, view, horizon, anchor, what-to-observe,
  invalidation, review status) spanning **pre / during / post** capture, with
  **invalidation** and **verification**, and **cancelled** hypotheses retained.
- **GUGU recalls mentor hypotheses as *uncertain context*, not truth.** A hypothesis is a
  bet about the framework, not a fact about it.
- **Mentor content must retain epistemic status** (§9) through capture and recall — a
  hypothesis must never be silently promoted to a permanent rule.

**Epistemic status:** the Mentor layer is captured from **user memory** (tags preserved in
[`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md)
§3) — `DESIGNED` / `VISION`, `NEEDS_REPO_SOURCE`.

---

## 17. Relationship to Pattern Library / S50

- **Pattern Library = `trigger` + `lesson` + `action`** (+ invalidation, example, status) —
  the planned layer that turns repeated observations into structured, reviewable patterns. It
  is meant to feed **contextual warnings, not mechanical signals.**
- **Framing rule: use "would / planned," not present-tense active cognition.** A named
  Market Pattern Library with `trigger…lesson…action` entries was **NOT FOUND** in
  `thus-trading-bot`; it is a **design seed** (`DESIGNED` / `VISION`).
- **Corrected S50 gap-down rule** — *in an uptrend, if S50 gaps down and does not recover
  intraday, exit immediately (next day can gap down again → cascade)*; a specific case of
  "no falling knife," worked example `S50H26` 1029→942 (Mar 2026). This is
  **`CONFIRMED_FROM_USER_MEMORY` / `NEEDS_MARKET_DATA_SOURCE`** — the case is not in either
  repo. Do not upgrade it to a repo-verified fact.
- **Archived spike-seed nuance:** the only *encoded* gap-down text is **archived spike seed**
  (`archive/spike-20260427/test_retrieval.py`), not a live library entry and not labelled
  "corrected."
- **Cancelled "gap up 2 days → sell-off" rule** — explicitly **REJECTED** as a false pattern
  (captured user-memory §5.3; recorded as searchable rejected knowledge in chapter 16).
  **GUGU must not re-derive this cancelled pattern.**
- **Candidate patterns are not confirmed rules.** Maturity comes from prediction/outcome
  evidence (§9), not from one striking case (§23 overfitting risk).

---

## 18. Relationship to Portfolio

- **Portfolio gives GUGU risk / state context:** exposure, drawdown / HWM, sizing behavior,
  concentration risk, account pressure.
- **GUGU would use Portfolio to *challenge* risk escalation, not to force trades** — e.g.
  "you're adding into a position while drawdown and concentration are both rising — is that
  the plan?" It proposes; it never sizes or executes.
- **Epistemic status:** the Portfolio roadmap beyond current summary/HWM pieces is
  **user-memory / `NEEDS_REPO_SOURCE`** (chapter 02 open questions; captured tags in the
  user-memory doc).

---

## 19. Relationship to MT5

- **MT5 gives GUGU ground-truth execution facts** — fills, exact prices, contract sizes.
- **MT5 → staging writer exists and is per-run gated** (`needs_mapping`, cross-account gate,
  idempotency on `position_id` / `deal_id` / `raw_sha`). **The staging → trades materializer
  is NOT started and remains GATED** (chapter 09).
- **GUGU must not treat staged rows as confirmed Journal truth** until they are materialized
  and confirmed. Staged ≠ real (§4 data-flow, §13 trust conditions).
- **Contract size / mapping correctness matters** — a mis-mapped contract corrupts P/L, and
  GUGU would learn from corrupt data.
- **No auto-materialization.** The human confirmation step stays in the loop.

---

## 20. Relationship to Grouping

- **Grouping gives GUGU its unit of analysis:** one **trade idea / thesis** over canonical
  executions, so scale-ins, partials, and averaged entries read as a single thesis **without
  corrupting P/L** (chapter 08).
- **G5 `[Insert GUGU summary]` hook** is a **future / designed** attachment point for GUGU's
  analysis — **not active.**
- **G2 status (current):**
  - **v0.3 create-only UI** (local) **+ v0.4 group-aware loader/render deployed
    default-off** at v3.23.0 (`f01eb33`).
  - RPC **`isMerged` hardening APPLIED + VERIFIED** (2026-07-10, `merged_child_not_allowed`).
  - **Write gate `tj_trade_group_write_v01` NOT enabled.**
  - **No real group kept.**
- The GUGU group-summary is **future / designed, not active.**

---

## 21. Preconditions for any future unfreeze decision

> **This section is non-authorizing.** Completing these stages does **not** entitle an
> unfreeze; it only makes the question *askable*. Every stage remains **GATED** by explicit
> user approval. This is deliberately **not** titled "Roadmap to unfreeze."

For each stage: **required evidence · gate · allowed scope · forbidden scope.**

1. **Capture-only current state.** *Evidence:* deployed bot frozen (`CAPTURE_ONLY_MODE`
   unset), check-ins flowing. *Gate:* none to *stay* here. *Allowed:* capture, notes.
   *Forbidden:* any cognition handler registration.
2. **Offline evaluation.** *Evidence:* eval suite (hard/soft/forbidden invariants) run
   locally, no live data. *Gate:* human review of results. *Allowed:* mocked/offline runs.
   *Forbidden:* live Journal/Portfolio/MT5 reads, any write.
3. **Observation-only shadow cycle.** *Evidence:* `shadow_cycle` producing falsifiable
   findings, read-back verified, no writes. *Gate:* explicit approval to run a shadow cycle.
   *Allowed:* read-only cycle, findings to a review surface. *Forbidden:* memory-write,
   recommendations, a second/parallel cycle.
4. **Adversarial / safety evaluation.** *Evidence:* the §10 adversarial pass exists and is
   exercised. *Gate:* review of challenge quality. *Allowed:* challenge findings.
   *Forbidden:* autonomous decisions.
5. **Cost-ceiling verification.** *Evidence:* fail-closed ceiling demonstrated under load;
   ideally a human-facing per-cycle cost line (the §8 PARTIAL gap closed). *Gate:* cost
   review. *Allowed:* metered runs. *Forbidden:* uncapped runs.
6. **Limited user-visible summaries.** *Evidence:* summaries reviewed for accuracy and
   epistemic honesty. *Gate:* approval per surface. *Allowed:* read-only summaries to Junior.
   *Forbidden:* instructions, trade framing.
7. **User-approved production observation.** *Evidence:* stages 1–6 signed off. *Gate:*
   explicit production-observation approval. *Allowed:* observation against live data.
   *Forbidden:* writes, actions, recommendations-as-instructions.
8. **Later cognition proposal.** *Evidence:* an accumulated, reviewed track record. *Gate:*
   explicit review of a written cognition proposal. *Allowed:* proposing scope.
   *Forbidden:* enacting it.
9. **Possible unfreeze decision.** *Evidence:* all above. *Gate:* an explicit, reviewed
   human go-ahead. *Allowed:* whatever that decision scopes. *Forbidden:* anything beyond it.

No stage authorizes the next; each is its own gate.

---

## 22. Non-authorizations

**This chapter does not authorize** any of the following — they remain human-gated
regardless of how this chapter reads:

- Production autonomous cognition.
- Auto-trading / order placement.
- GUGU runtime **unfreeze** (`CAPTURE_ONLY_MODE` / `manual_run_guard` override).
- Cost-ceiling bypass.
- MT5 staging → trades **materialization**.
- Journal writes (including the G5 GUGU-summary hook).
- Supabase writes of any kind.
- Enabling any `tj_*` write / feature flag.
- The G2 **write gate** (`tj_trade_group_write_v01`).
- Keeping a **first real group** (non-rollback).
- Deploy / push.
- **Upgrading user-memory patterns into confirmed rules** (S50, Pattern Library, Mentor,
  Portfolio all stay tagged until repo/market-data-sourced).

---

## 23. Risks and failure modes

- **Economic runaway** — an unbounded agent burning money (mitigated by the §8 fail-closed
  ceiling; same rank as no-silent-unfreeze).
- **Hallucinated market rules** — inventing a rule the framework never had.
- **Overfitting one case into a rule** — treating one striking case as a confirmed pattern.
- **Echo-chamber / confirmation loop** between trader and AI (§10) — the #1 risk.
- **Noisy warning fatigue** — too many low-value warnings train the trader to ignore them.
- **Confusing the capture bot with GUGU itself** — the interface is not the cognition.
- **Treating staged MT5 rows as confirmed trades** (§19).
- **Treating mentor hypotheses as facts** (§16).
- **Re-deriving cancelled rules** — e.g. the rejected S50 "gap up 2 days → sell-off" (§17).
- **Losing epistemic status** — flattening hypothesis/candidate/rejected into "fact."
- **Autonomous behavior without approval** — any cognition escaping the freeze.
- **Cost logs missing** — the §8 PARTIAL gap (no human-facing per-cycle line) hiding drift.
- **Memory pollution** — bulk-dumping stale knowledge into retrieval (§15).
- **Stale context retrieval** — surfacing old zones/arithmetic instead of live framework.
- **Prediction/outcome drift not reviewed** — self-correction data collected but never used
  (§9).

Each risk carries into chapter 17 with severity + mitigation + owner-gate.

---

## 24. What future chapters should expand

- **Chapter 11 — Mentor / Knowledge / Pattern deep dive:** `bot_knowledge` taxonomy, Note
  Activation v0.1, the Mentor View lifecycle, the Pattern Library design, and the S50 rules
  (user-memory, tags preserved).
- **Chapter 14 — Current State snapshot:** the durable point-in-time expansion of
  `PIPELINE_STATE.md` — prod bundle, HEAD/origin, live-vs-gated per lane, GUGU freeze state.
- **Chapter 15 — Operations:** the real deploy path (`gugu/DEPLOY.md`, systemd
  `gugu-telegram.service`, `/opt/gugu`, IP `168.144.35.127`), cost monitoring, and the
  **NEEDS VERIFICATION** VPS provider/OS/pricing/crontab details.
- **Chapter 16 — Rejected Ideas:** GUGU v1 hardcoded-gate architecture, Mem0 fact-extraction,
  and the cancelled S50 "gap up 2 days → sell-off" rule (kept searchable so it is not
  re-derived).
- **Chapter 17 — Risks / Tech Debt:** the §23 register as a live, owner-gated risk list.
