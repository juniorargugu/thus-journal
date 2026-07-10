# GUGU v2 — Cross-Repo Reconciliation

**Date:** 2026-07-10 · **Type:** read-only capture from the sibling `thus-trading-bot`
repo, reconciled into the THUS Project Bible. **Docs-only.** No code run, no runtime
touched, no files in `thus-trading-bot` modified.

## Purpose

The Project Bible foundation (pushed at `d198f91`) carried GUGU/Mentor/Pattern/Portfolio
details sourced only from a Fable/ChatGPT review + user-memory attestation, marked
**NEEDS VERIFICATION**. This pass reads the **primary** GUGU sources in `thus-trading-bot`
and reconciles them, so the Bible neither (a) treats GUGU as dormant vision-ware nor
(b) asserts unverified attestation as fact. Every claim below is tagged against primary
files with `file:line` evidence, or marked NEEDS VERIFICATION where the repo is silent.

**Headline:** GUGU v2 is a **real, built-in-repo** memory-stream trading co-pilot — **not**
vision-ware — but it is currently **runtime-frozen** behind a capture-only mode. "Built"
and "running" are different questions; this doc keeps them separate.

---

## 1. `thus-trading-bot` repo snapshot (at capture time)

- **Branch:** `main`
- **HEAD:** `b03758a` — "docs: add note activation v0.1 design"
- **`origin/main`:** `a9218fb` — "feat(gugu): add hard cost ceiling for v2 calls" (local
  `main` is ~4 commits ahead of its origin; observed read-only, not acted on)
- **Working tree:** clean
- **Recent commits:** `b03758a` note-activation design → `d20c2a5` deterministic note
  activation → `f9c5951` GUGU freeze inventory audit → `2025ad5` guard manual GUGU
  cognition entrypoints → `a9218fb` hard cost ceiling for v2 calls.

**Important files found (primary sources):**

| Area | Files |
|---|---|
| Handoff / architecture | `CLAUDE.md` (the "GUGU V2 Complete Handoff"), `ARCHITECTURE.md`, `DECISIONS.md`, `gugu-bot-architecture.md`, `CLAUDE_V1_ARCHIVED.md` |
| Agent core | `gugu/agent.py`, `gugu/agent_tools.py`, `gugu/real_tools.py`, `gugu/personality.py`, `gugu/models.py`, `gugu/cli.py` |
| Memory | `gugu/memory.py`, `gugu/cold_start.py`, `gugu/README.md` |
| Observation cycle | `gugu/cycle_agent.py`, `gugu/cycle_prompt.py`, `gugu/shadow_cycle.py`, `gugu/market_data.py`, `gugu/models.py` |
| Freeze | `gugu/manual_run_guard.py`, `artifacts/gugu_freeze_inventory/gugu_freeze_inventory_report.md`, `.../freeze_hardening_phase1_report.md`, `tests/test_manual_run_guard.py` |
| Cost | `gugu/cost_ceiling.py`, `gugu/test_cost_ceiling.py`, `logs/gugu_usage_ledger.json` (runtime ledger) |
| Telegram / Capture Bot | `gugu/tg_bot.py`, `gugu/price_context.py`, `gugu/checkin_*.py`, `gugu/note_activation.py`, `gugu/test_day3*.py` |
| Deploy | `gugu/DEPLOY.md`, `gugu/RUNBOOK.md`, `gugu/gugu-telegram.service` |
| Knowledge (v1) | `knowledge.py`, `knowledge_audit.py` |
| Pattern/gap (v1) | `behavior_scanner.py`, `gap_followup_store.py`, `indicators.py` |
| Note activation | `artifacts/note_activation/note_activation_v0_1_design.md`, `.../build_report.md`, `.../approval_packet.md` |

---

## 2. GUGU v1 — summary

- **What it was:** the first bot ("Python = eyes/reflex, Claude = brain") with stacked
  hardcoded gates (PreFilter, guardrails, hallucination gate, zone rules) and a monitor
  daemon (`awareness_daemon.py`).
- **Why archived:** hardcoded-architecture maintenance spiral + cost. Archived **2026-04-26**
  (`CLAUDE.md:64-68`: git tag `v1-final` → `ae39250`; code to `/opt/archive/gugu-bot-v1-20260426/`;
  services stopped + disabled).
- **Cost-leak evidence (CORRECTS the Bible):** the documented v1 leak is **~$3/day**, not
  $5/day — `CLAUDE.md:88` "**$3/day API cost from monitor cycles that mostly produced
  'NOTHING'**". The monitor path defaulted to **Haiku** (`claude_brain.py:495-497,1082`),
  so "Haiku-default monitor daemon" is fair by inference. The "**$5/day**" figure in the
  Bible was a **conflation** — it actually describes the *v2 Sonnet* cost-ceiling headroom
  (`gugu/cost_ceiling.py:110-111`: 1.5M tokens/day "≈$5/day at Sonnet 4.6 blended rate"),
  a separate thing. **Confirmed.**

## 3. GUGU v2 — current sprint status

The build is real and in-repo; the sprint framing in the attestation is only partly
accurate. **Correction: the project pivoted to "Capture Bot v0.1" (capture-only, LLM-free);
the cognitive agent is built but frozen.**

| Sprint claim | Verdict | Evidence |
|---|---|---|
| Days 1–4 complete (memory, cold start, agent/tools, tg_bot) — code exists | **CONFIRMED (in-repo)** | `gugu/memory.py`, `gugu/cold_start.py`, `gugu/agent.py`, `gugu/agent_tools.py`, `gugu/tg_bot.py`; single baseline commit "Day 1-4 baseline (pre-P0)". |
| "Locally verified" | **NEEDS VERIFICATION** | Test harnesses exist (`gugu/test_memory.py`, etc.) but "verified" is a process claim; no captured run log, and this pass did not execute anything. |
| Day 5 = observation cycle + cost monitoring | **CONFIRMED** | `gugu/cycle_agent.py`, `gugu/cycle_prompt.py`, `gugu/shadow_cycle.py`; `gugu/cost_ceiling.py` wired into `agent.py`, `cycle_agent.py`, `memory.py`. Sprint tags run to "Day 5A.18". |
| "Days 6–8" as distinct completed days | **NEEDS VERIFICATION** | Repo shows **Day 5A.x only**; no Day 6/7/8 markers. |
| "Adversarial testing" | **PARTIAL / reconcile wording** | No adversarial/second-pass/critic **agent** in the runtime path. What exists: the eval suite's `forbidden_invariants` (`gugu/models.py`, `gugu/evals/runner.py`) + a sanitizer re-check in `shadow_cycle.py`. Adversarial-*style* test invariants, not an adversarial agent. |
| VPS deployment planned at Day 8 | **PARTIAL** | `gugu/DEPLOY.md` documents a real VPS deploy; "Day 8" as the trigger is not stated in-repo → NEEDS VERIFICATION. |

**Runtime status (critical):** the cognitive agent is **frozen**, not running (see §4). Any
Bible sentence implying GUGU v2 is "live/running" must read **"built in-repo; deployment
currently capture-only / frozen."**

### 3.1 Agent architecture (what's actually built)

- **Framework:** PydanticAI (`gugu/agent.py:19-23` imports `from pydantic_ai import Agent`;
  same in `cycle_agent.py`). No LangChain/LlamaIndex. **Confirmed** — matches the Bible's
  "PydanticAI chosen" decision.
- **Model:** Claude **Sonnet 4.6** — `gugu/agent.py:37` `MODEL = "anthropic:claude-sonnet-4-6"`.
- **Memory stream:** append-only over Supabase **pgvector** with OpenAI `text-embedding-3-small`
  (1536-d) — `gugu/memory.py` (`embed`/`append`/`recall` via `match_memories` RPC),
  `gugu/README.md`. **Confirmed.**
- **Chat tools:** exactly **3** — `search_memories`, `append_memory`, `get_price`
  (`gugu/agent.py:42`, defined in `gugu/agent_tools.py`). The observation cycle adds two
  **read-only** tools (`fetch_price_snapshot_tool`, `recall_memories_tool`,
  `gugu/cycle_agent.py`) and **cannot** write memory. `get_ohlcv` is deferred
  (`gugu/symbols.py`). **Confirmed** (bounds the Bible's "etc.").
- **Personality:** `gugu/personality.py` (~306 lines) — the Tony-Stark co-trader prompt,
  9 hard rules, references "78 imported memories".
- **Observation/shadow cycle:** emits structured, falsifiable `CandidateFinding` objects
  with **no memory-write and no trade recommendations** ("L2c locked") — `gugu/cycle_prompt.py`,
  `gugu/models.py` validators, `gugu/shadow_cycle.py` read-back verify. This is the
  echo-chamber-safe "observation-only before action" posture in code.
- **Cold start:** `gugu/cold_start.py` imports from the Supabase **`bot_knowledge` table**
  (not a code file); attested **78** rows (`gugu/README.md`, `personality.py`, `CLAUDE.md:290`).
  Live count NEEDS VERIFICATION (DB not queried).

## 4. Runtime / cognition freeze policy — **CONFIRMED**

Two-layer, fail-closed freeze (audit: `artifacts/gugu_freeze_inventory/gugu_freeze_inventory_report.md`,
2026-06-02, + `freeze_hardening_phase1_report.md`):

1. **Deployed Telegram bot defaults to frozen.** `gugu/tg_bot.py:125` `_is_capture_only_mode()`;
   `CAPTURE_ONLY_MODE` unset → `True`. Cognition handlers (`/gugu_run`, `/gugu_digest`,
   `/start`, free-text, etc.) are registered **only** in the non-frozen `else` branch
   (`gugu/tg_bot.py:1101-1119`) — i.e. not registered while frozen.
2. **Manual entry points fail-closed.** `gugu/manual_run_guard.py` gates `cli`,
   `shadow_cycle`, `evals/runner`, `evals/real_data_tests`, `test_real_cycle`. Policy
   (`manual_run_guard.py:20-24`): `CAPTURE_ONLY_MODE` unset → frozen; any true-ish → blocked;
   even `false/0/no/off` → **still blocked unless** `GUGU_ALLOW_COGNITION_MANUAL_RUN ==
   "YES_I_UNDERSTAND"` (exact string). On block: prints "GUGU cognition is frozen / No LLM
   call was made" and `SystemExit(2)`.

This maps exactly to the Bible's freeze-scope rules: **production autonomous cognition is
frozen on any repo; reviewed v2 development is allowed; observation-only before action;
no production autonomous cognition without explicit approval (the exact-string override);
capture-only production behavior stays allowed.** The Bible's freeze claim can move from
NEEDS VERIFICATION → **CONFIRMED**.

## 5. Cost / economics — **CONFIRMED (ceiling); PARTIAL (logging)**

- **Hard cost ceiling is LIVE-in-repo**, fail-closed: `gugu/cost_ceiling.py` (420 lines),
  three caps in **tokens/calls** (not USD):
  - `DEFAULT_DAILY_TOKEN_BUDGET = 1_500_000` (`:114`; "≈$5/day at Sonnet 4.6 blended rate", `:110-111`)
  - `DEFAULT_CYCLE_TOKEN_BUDGET = 60_000` (`:115`)
  - `DEFAULT_MAX_CALLS_PER_CYCLE = 25` (`:116`)
  - Env-overridable (`:128-132`); `guard_pre_call()` raises `CostCeilingExceeded` **before**
    the API call; corrupt/invalid config or ledger also raises (fail-closed). Day boundary
    Asia/Bangkok. Wired into `agent.py`, `cycle_agent.py`, `memory.embed`. Covered by
    `gugu/test_cost_ceiling.py` (569 lines).
- **Per-cycle accounting:** tokens + calls persisted per day to `logs/gugu_usage_ledger.json`;
  per-cycle counters in `contextvars`; a `blocked` counter increments on cap hit.
- **Gap:** there is **no human-facing per-cycle token/cost *log line*** and **no `/cost`
  command** in v2 (`/cost` exists only in the archived v1 `api_budget.py`). So "per-cycle
  token/cost **logging**" is **PARTIAL** — counted + persisted, not printed. NEEDS a small
  follow-up if a visible per-cycle cost line is wanted.

## 6. VPS / deployment — **PARTIAL; mostly NEEDS VERIFICATION**

| Sub-claim | Verdict | Evidence |
|---|---|---|
| IP `168.144.35.127` | **CONFIRMED** | `CLAUDE.md:412`, `gugu/DEPLOY.md:24,65,83,85,89`, `RULES.md:18` |
| systemd deploy on `/opt/gugu` via `gugu-telegram.service` | **CONFIRMED** | `gugu/DEPLOY.md` (ssh → venv → `pip install -r gugu/requirements.txt` → `systemctl enable/start gugu-telegram`); unit runs `python -m gugu.tg_bot`. |
| DigitalOcean | **NEEDS VERIFICATION** | zero in-repo hits |
| Ubuntu 24.04 | **NEEDS VERIFICATION** | zero hits; DEPLOY.md only requires Python 3.10+ |
| $6/mo offline → $12/mo pricing | **NEEDS VERIFICATION** | zero `$6`/`$12`/resize hits |
| Restore **crontab** on deploy | **NEEDS VERIFICATION** | only crontab is `watchdog.sh` (a **v1** gugu-daemon watchdog); v2 uses systemd, no crontab step |
| Restore **Flask** on deploy | **REFUTED for v2** | Flask is v1-only (`telegram_bot.py`, `requirements.txt`). v2 `tg_bot.py` uses python-telegram-bot **polling** (`tg_bot.py:1140`), not Flask/webhook. |

## 7. Telegram bot — **MOSTLY CONFIRMED; one number corrected**

- **`tg_bot.py` line count: `1158`, NOT ~331** (`wc -l`). **Correct the Bible.**
- **Python 3.14 async workaround: CONFIRMED** — `gugu/tg_bot.py:969-972` (PTB 21.x
  `run_polling` vs 3.14 removed auto event-loop; drives `initialize/start/updater`
  explicitly).
- **SIGTERM graceful shutdown: CONFIRMED** — `gugu/tg_bot.py:1123-1129` (SIGINT/SIGTERM →
  `stop_event.set`, Windows `NotImplementedError` fallback).
- **"Local test verified": PARTIAL** — procedure documented (`DEPLOY.md`, `RUNBOOK.md`) but
  no captured run log → NEEDS VERIFICATION.
- **Capture-only commands registered** (`tg_bot.py:1025-1051`): `/start_checkin`, `/whoami`,
  `/status`, `/review_today`, `/checkin`, `/checkin_trade`, `/snooze`, `/resume`, `/off`,
  `/note`, `/undo_note`, `/delete_last_note`, `/daily_on|off`, `/during_on|off`,
  `/frequency`, `/help`. Cognition commands register only when unfrozen.

## 8. Tools / agent architecture (recap)

- **Memory:** `gugu/memory.py` (append/recall over pgvector). **Cold start:** `gugu/cold_start.py`
  (bot_knowledge → gugu_memory, ~78). **Chat tools:** 3 (`agent_tools.py`). **Cycle tools:**
  2 read-only (`cycle_agent.py`). **Observation cycle:** `shadow_cycle.py` + `cycle_prompt.py`
  (falsifiable findings, no writes, no recommendations). **Eval harness:** `gugu/evals/*`
  (~10 mocked cases, hard/soft/forbidden invariants). All built; agent path frozen.

## 9. Knowledge corpus — **CORRECTS the Bible**

| Attestation | Verdict | Evidence |
|---|---|---|
| `bot_knowledge` store exists (keyword, no embeddings) | **CONFIRMED** | `knowledge.py:1-2,28-29`; used in `macd_levels.py`, `gugu_mcp.py`, `ARCHITECTURE.md:38` |
| "mentor-PDF → NotebookLM → bot_knowledge" pipeline | **NOT FOUND** | zero hits for `notebooklm`/`mentor pdf`/`curriculum` (the only `.pdf` is the SET holiday calendar) → **NEEDS VERIFICATION / likely inaccurate** |
| "~70 items" | **CORRECTED → 78** | cold-start imported **78** rows (`CLAUDE.md:290`, `gugu/README.md`, `personality.py`); "~70" not stated anywhere |
| "17 categories" | **CORRECTED → 7** | `knowledge.py:10-18` defines **7** categories (`indicator_sr, market_rule, alert_preference, pattern_note, personality, symbol_behavior, general`); nothing enumerates 17 |
| "candlestick / Wyckoff curriculum" | **NOT FOUND** | Wyckoff appears only in a personality **example dialogue** (`personality.py:286-296`); candlestick once as an observation line — no curriculum → **NEEDS VERIFICATION** |
| "codified rules" | **PARTIAL** | real codified knowledge exists (MACD S/R levels → `bot_knowledge`, `market_rule`/`pattern_note` categories), but not a candlestick/Wyckoff body |

**Net:** the knowledge layer is **not zero-start** (78 real imported memories + a keyword
store), but the attestation's *specifics* (NotebookLM pipeline, ~70/17, Wyckoff curriculum)
are unconfirmed or wrong in this repo. They may live in THUS Journal notes or user memory.

## 10. Market Pattern Library + S50 — **CORRECTS the Bible**

| Attestation | Verdict | Evidence |
|---|---|---|
| A named "Market Pattern Library" with `trigger+lesson+action` entries | **NOT FOUND** | zero hits for `pattern library` / `trigger…lesson…action` |
| "auto-warn before/during trade" | **NOT FOUND (closest ≠ this)** | The real shipped feature is **Note Activation v0.1** (`gugu/note_activation.py`): deterministic, tag-gated, **no-LLM**, during-trade *mentor reminder* — **6** hardcoded reminders keyed to emotion tags (`fear_giveback`, `want_exit_early`, `want_add_position`, `force_narrative`, `plan_drift`, `size_too_big`); explicitly "not a signal/action" (`note_activation.py:38`). Design: `artifacts/note_activation/note_activation_v0_1_design.md`. |
| real S50 gap detection | **PARTIAL** | `behavior_scanner.py:69-83,526-539` detects `gap_up`, `gap_up_after_selloff`, `gap_down`, `gap_down_after_rally` as **tags** (no attached lesson/action); `gap_followup_store.py` schedules 16:30/08:30 BKK follow-up checks. |
| "corrected S50 gap-down rule" | **PARTIAL / not labeled "corrected"** | The only encoded gap-down rule is **archived spike seed text** ("S50 gap down without intraday recovery = exit immediately") in `archive/spike-20260427/test_retrieval.py:7,15,22` — not a live library entry, not labeled "corrected". |
| "Mar 2026 S50H26 1029→942 case" | **NOT FOUND** | zero hits for `1029`, `942`, `S50H26` in the repo → **NEEDS VERIFICATION** (likely a THUS Journal note / user memory) |
| old "gap up 2 days → sell-off" rule "explicitly cancelled as false pattern" | **NOT FOUND** | no cancellation record; `behavior_scanner` has the opposite-direction `gap_up_after_selloff` detector as a *live* label → **NEEDS VERIFICATION** (likely Journal/user memory, not this repo) |

## 11. Implications for the Project Bible

**Now VERIFIED (safe to state as fact, with the corrections above):**
- GUGU v2 is a real, built-in-repo PydanticAI + Claude Sonnet 4.6 memory-stream agent —
  **not** dormant vision-ware — but **runtime-frozen (capture-only)**.
- The two-layer fail-closed **freeze** (CAPTURE_ONLY_MODE default + `manual_run_guard`
  exact-string override) is real and matches the Bible's freeze-scope policy.
- The **hard cost ceiling** is LIVE-in-repo (fail-closed, 1.5M tok/day ≈ $5/day Sonnet,
  60k/cycle, 25 calls/cycle).
- v1 was archived **2026-04-26**; its cost leak was **~$3/day** (Haiku-default monitor
  cycles) — **the Bible's "$5/day Haiku" is wrong** (the $5/day is the v2 Sonnet ceiling
  headroom).
- PydanticAI framework choice, 3 chat tools, observation-only cycle, 78-row cold start.

**Still NEEDS VERIFICATION (keep tagged; not in this repo):**
- "Days 6–8" as distinct days; "adversarial testing" wording; "locally verified" run logs.
- VPS provider/OS/pricing (DigitalOcean, Ubuntu 24.04, $6→$12), crontab/Flask on deploy
  (Flask **refuted** for v2 — polling).
- Knowledge corpus specifics: NotebookLM/mentor-PDF pipeline, "17 categories" (actual 7),
  "~70 items" (actual 78), candlestick/Wyckoff curriculum.
- Market Pattern Library structure; corrected S50 gap-down rule; `S50H26` 1029→942 case;
  the cancelled "gap up 2 days → sell-off" pattern — **none in `thus-trading-bot`; likely
  in THUS Journal notes / user memory.**

**Chapter routing:**
- **Chapter 10 (GUGU):** agent architecture, freeze, cost ceiling, observation cycle,
  capture-only pivot — now well-sourced from `thus-trading-bot`.
- **Chapter 11 (Mentor / Knowledge):** the `bot_knowledge` keyword store + 78-row cold
  start + **Note Activation v0.1** (the real "mentor reminder" feature). Pattern-library /
  S50 specifics remain user-memory capture.
- **Chapter 15 (Operations):** the real deploy path (`gugu/DEPLOY.md`, systemd
  `gugu-telegram.service`, `/opt/gugu`, IP `168.144.35.127`); VPS provider/pricing/crontab
  = NEEDS VERIFICATION.
- **Chapter 16 (Rejected Ideas):** v1 hardcoded architecture + $3/day monitor leak
  (archived 2026-04-26); the cancelled "gap up 2 days → sell-off" rule (NEEDS VERIFICATION,
  likely Journal).
- **Chapter 17 (Risks / Tech Debt):** echo-chamber (mitigated by observation-only + no-write
  cycle + forbidden-invariant evals, but **no adversarial second-pass agent yet**); cost
  runaway (mitigated by the live ceiling); premature unfreeze.

**Chapter 04 recommendation (report only — not written here):** the **GUGU side is now
substantially unblocked** by this reconciliation. The remaining blockers are **Portfolio,
Mentor, and the Pattern-Library/S50 rules**, which are **not** in either repo and need
user-memory capture. Recommendation: Chapter 04 may be written **with the GUGU side sourced
from this doc**, provided the Portfolio / Pattern-Library / VPS-detail sections stay
explicitly **partial / NEEDS VERIFICATION** until user-memory capture completes.

## 12. Provenance note

This doc is primary-source-derived from `thus-trading-bot` at `b03758a` (read-only). Where
it says CONFIRMED, a `file:line` citation is given. Where it says NEEDS VERIFICATION, the
repo was silent and the fact likely lives in THUS Journal notes or user memory. No code was
executed; the live Supabase state (e.g. current `bot_knowledge`/`gugu_memory` row counts)
was **not** queried.
