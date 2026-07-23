# 04 — Complete Roadmap

*The single consolidated roadmap across all THUS subsystems. Nothing is dropped just
because it is not implemented. Every item carries its status tag, so the reader knows what
is live, what is planned, what is gated, and what still needs verification.*

*This chapter **must preserve the North Star**: THUS is building an AI-native Trading
Operating System. Journal is the memory/data layer. **GUGU is the destination and long-term
primary consumer.***

---

## How to Read This Chapter

### Status vocabulary (quick recap)

| Tag | Meaning | Example |
|---|---|---|
| **DONE** | Completed and closed out; may be local-only (not deployed). | P/L baseline snapshot taken |
| **LIVE** | Shipped to production app bundle and verified. | Journal durable mutations shipped at v3.23.0 |
| **APPLIED** | DB/RPC/schema/migration executed against live Supabase. | G2 `isMerged` guard applied+verified in prod 2026-07-10 |
| **DESIGNED** | Design written and reviewed; no code/apply yet. | v0.5 ungroup UI approved, deferred |
| **REVIEWED** | Passed adversarial/static review pass. | MT5 0A schema audit REVIEWED |
| **DEFERRED** | Deliberately postponed with a documented trigger. | Notes LLM-retrieval ← wait for ≥20–30 real items |
| **GATED** | Blocked behind explicit human approval. | MT5→trades materializer hard-gated |
| **RESEARCH** | Under investigation; conclusions not settled. | *(none open at present — all major unknowns are tagged NEEDS VERIFICATION)* |
| **VISION** | Long-horizon intent; not scheduled. | Portfolio risk-model roadmap |
| **NEEDS VERIFICATION** | Asserted somewhere but not confirmed against current state. | VPS provider/pricing; Pattern-Library in THUS Journal notes |

**Confidence qualifiers** — read them as part of the tag:
- **NEEDS VERIFICATION / NEEDS_REPO_SOURCE / NEEDS_MARKET_DATA_SOURCE** — grounded elsewhere or in user memory, not yet in this repo.
- **CONFIRMED_FROM_USER_MEMORY** — user/project memory, tagged but not repo-grounded.
- **REJECTED** — explicitly cancelled; must not be re-derived.

---

## The North Star (preserved)

> **THUS is building an AI-native Trading Operating System.**
>
> Not a trade journal. Not a dashboard. A system whose long-term primary user is an AI
> copilot — **GUGU** — that learns one trader's framework over a multi-year horizon and
> helps make better decisions.
>
> **"We are hardening the Journal now so that GUGU can trust the data later."**

Every item in this roadmap traces back to this sentence. When in doubt about priorities, ask:
*does this make the data GUGU will one day reason over more trustworthy?*

---

## Strategic Tracks

THUS work organizes into **parallel tracks**, each with its own sprint/gate discipline.
No track is abandoned just because another is the current focus.

| Track | Focus | Status | Owner |
|---|---|---|---|
| **Journal Hardening** | Durable persistence, P/L invariant, data integrity, image externalization, product registry | **LIVE + residual P2** | code |
| **Grouping (G0–G6)** | Metadata model, non-destructive scaling, P/L invariant, write gate, GUGU hook | **LIVE (default-off); G5 hook designed** | code |
| **MT5 Import** | Execution/source layer, gated staging writer, future materializer, Inbox UI | **LIVE (read-only + gated writer); 0D-1 UI shipped; 0D-2+ deferred** | code |
| **GUGU v2 Build** | Memory-stream agent, freeze policy, cost ceiling, Capture Bot, observation cycle | **BUILT (runtime-frozen); Days 1–5A CONFIRMED in-repo; Days 6–8+ NEEDS VERIFICATION** | bot repo |
| **Knowledge / Mentor / Pattern** | Curated rules, hypothesis layer, structured patterns, S50 rules | **Schema/taxonomy LIVE; retrieval/activation deferred; Mentor/Pattern user-memory captured** | design |
| **Portfolio & Analytics** | State/risk layer, exposure, HWM, performance attribution | **Partially LIVE; roadmap captured from user memory; cards hidden pending redesign** | backlog |

---

## 1. Journal Subsystem

### Purpose
The **memory/data layer**: the canonical, durable, trustworthy record of every trade
(open/close, entries, exits, notes, images) and the source of truth for all P/L.

### Current State
**LIVE + P2 residual.** Production SPA (`index.html`) at v3.23.0 (`f01eb33`), Netlify
(thus999.com). Every trade mutation (open/add, close, edit, price/meta update) is
**single-row durable** via `db.saveTrade` / `commitUpdateTrade` **LIVE (2026-06-23,
deployed `2c2c8d2..ba532be`)**.

- **P0: Durable close path** — **LIVE** (`2026-06-18`, `69531ef`; design addendum
  `close_save_durability_design_timeout_addendum` 2026-06-15): single-row bounded RETURNING,
  post-hydration autosave suppression. Durable close-persist bug (confirmed 2026-06-09 on
  trade `1781008993915`) fixed.
- **P1: Durable update path** — **LIVE** (`2026-06-18`, `30d5a1d`): edit/price/note+meta
  save-first durable via `commitUpdateTrade`.
- **P2: Full stack** — **LIVE** (`2026-06-23`, `2c2c8d2..ba532be`): every mutation single-row,
  autosave ids-only reconcile, full-array writer retired, images externalized.
- **Closed-trade correction** — **LIVE** (`2026-06-25`, `09842d7`): manually correct
  exitPrice/exitDateTime on eligible standalone closed trades via durable update path.
- **Image externalization** — **LIVE** (storage policy applied `2026-06-22`; externalize-on-save
  shipped with P2 `2026-06-23`; one-time backfill `2026-06-23`, local-only/not pushed): base64
  images → Storage bucket signed-URLs (16.6 MB → 0.15 MB, 112×); backfill 18 rows / 37 images,
  0 orphans past retention.

### Gates / Risks
- **P/L invariant applies.** All aggregates ignore `group_id` and walk raw `trades[]` —
  no synthetic P/L-bearing rows. `CONFIRMED`.
- **Durable-save mutations protected** — changes to close/edit/delete/import/merge paths
  need review.
- **Single-file SPA scale** — large `raw` payloads caused PostgREST `57014` timeouts;
  externalization fixed. Any new mutable feature needs size review.
- **Silent data-loss is the historical bug class.** Residual non-durable writers (delete /
  duplicate / import / legacy-merge) are **P2 residual, NEEDS VERIFICATION**; see open questions.

### Known Roadmap
**Residual non-durable writers** (delete/duplicate/import/legacy-merge) to make save-first
— **DEFERRED (P2 residual)**.

**Navigation / URL-state audit** — **DEFERRED**. `PageSteps` dead-prop cleanup, `uid()` →
`crypto.randomUUID()` — **DEFERRED**.

`[DIAG] TEMPORARY` log removal (mostly done; permanent `affected===0` tripwire stays).

### Open Questions
- Delete/duplicate/import durability status — **NEEDS VERIFICATION**.
- Is the `20260512` trade-events archive-lockdown actually applied in prod? — **NEEDS
  VERIFICATION (manual-run, not confirmed here).**

---

## 2. Grouping (G0–G6) — Non-Destructive Multi-Entry Scaling

### Purpose
Associate multiple executions that form one trade idea / thesis / scaled position, **without**
collapsing them into a synthetic row. A non-destructive replacement for the disabled
row-collapsing "Merge."

### Current State: **LIVE (default-off); DB clean**

| Phase | Status | Evidence | Date |
|---|---|---|---|
| **G0** — Design lock | **DONE** | Reentry audit locked Option B (metadata model); no Merge revival; raw integrity preserved | 2026-06-03 |
| **G1** — Schema + RLS | **APPLIED + VERIFIED** | Applied in SQL Editor at `79140c6`; `trade_groups` table, `trades.group_id` FK; V1–V9 PASS; app smoke PASS; 0 rows mutated | 2026-06-08 |
| **G2** — RPCs + ownership | **APPLIED + VERIFIED** | Applied `2026-07-05` (`migrations/20260705_...`); `idempotency_key` + unique-active index, ownership-guard trigger, create/ungroup SECURITY DEFINER RPCs writing only `group_id`+`updated_at` (group metadata, never raw trade data) | 2026-07-05 |
| **G2-rpc-isMerged** — Defense-in-depth | **APPLIED + VERIFIED** | `20260708` function-body replace adds `merged_child_not_allowed` reject; precheck=0, BEGIN/ROLLBACK validation **PASSED** 2026-07-10; recorded `b94f7fd` | 2026-07-10 |
| **G3** — UI delete-merge + create | **LIVE (create-only, v0.3)** + **LIVE (v0.4 group-aware load/render, default-off)** | v0.3 rollback smoke PASS; v0.4 deployed v3.23.0 (`f01eb33`); ⛓ badge, `tradeGroupIds` map | 2026-07-06/07/08 |
| **G3.5** — Closed-trade grouping | *Not scheduled yet* | — | — |
| **G4** — Group notes | *Not scheduled yet* | — | — |
| **G5** — **GUGU summary hook** | **DESIGNED (not built)** | Designed to read `checkin_events` and attach GUGU analysis to a group; the natural GUGU unit for reasoning | *future* |
| **G6** — Legacy Merge cleanup | *Not scheduled yet* | — | — |

### Design Intent
- **P/L invariant:** all reducers ignore `group_id`; totals derived, never synthetic.
- **Write gate:** `tj_trade_group_write_v01` hardcoded in AUTOPILOT_RULES.md as **MUST STOP**.
- **"No real group kept":** DB clean (1 archived by design from earlier rollback smoke; 0
  active groups).

### UI: v0.5 Ungroup — **DESIGNED / DEFERRED**
A detail-modal ungroup affordance (ChatGPT PASS, approved-deferred): a typed `UNGROUP`
confirmation calls **exactly one** `ungroup_trade_group_v1` RPC; **no raw trade mutation**, and
**no forced refresh** unless a future review decides one is needed. Design only — no code.
Source: `artifacts/g2_grouping/g2_v05_ungroup_design_closeout.md`. (Also listed under §14 DESIGNED.)

### Open Questions
- Is G5 (GUGU summary hook) ready to unblock, or does it wait on Capture Bot Day 4?
- Should G3.5 (closed-trade grouping) ship before open-position grouping is user-tested?
- When should G6 (legacy Merge cleanup) run?

---

## 3. MT5 Import — Execution/Source Layer (Gated)

### Purpose
Mirror MetaTrader 5 executions (open positions, close deals) into a gated staging area.
Nothing auto-materializes into Journal trades; the human confirms every entry.

### Terminology (keep distinct)
- **MT5→staging writer** — exists (local Python). Has run armed under a three-key gate.
  Further writes still gated.
- **staging→trades materializer** — **not started; hard-gated**. Armed staging smokes are
  **not precedent** for automatic materialization.

### Current State: **LIVE (read-only + gated writer); staging has 2 rows**

| Phase | Status | Evidence |
|---|---|---|
| **0A** — Schema/RLS/RPCs | **APPLIED + VERIFIED (2026-06-25)** | 3 tables (`staging_mt5_positions`, `staging_mt5_deals`, `staging_mt5_cursors`), 10 indexes, 3 triggers, 3 SECURITY DEFINER RPCs; browser SELECT-own only; V1–V5 PASS; cross-account gate (terminal `301102520`); `needs_mapping` placeholder |
| **0B** — Probe findings | **DONE** | Hedging (avg-down detection), DELTAU26 contract-size csize=1000 guard, Bangkok TZ, idempotency via `position_id`/`deal_id`/`raw_sha` |
| **0C-1** — Dry-run harness | **DONE** | Offline fixture harness (`dry_run.py`); pure mappers + TZ; never touches Supabase/MT5/network; 6-row sample (4 mapped, 2 needs_mapping) |
| **0C-3a** — First armed open write | **DONE** | GOU26 open `305830528` inserted 2026-06-26 (MT5 exec 2026-06-25); idempotent rerun→PATCH; tz + contract_size=300 verified; three-key gate PASS |
| **0C-3b** — First armed close-deal write | **DONE** | GOU26 close `deal_id=2141744` inserted 2026-06-30; insert-once immutable (rerun=DUPLICATE-EXISTING no-op); cross-account gate STOPPED wrong-terminal attempts; PASS |
| **0D-0** — Read-only Inbox UI | **LIVE (default-off `tj_mt5_inbox`)** | Settings MT5 Inbox shipped v3.23.0 (`8864e73`) 2026-06-30; SELECT-only, no write buttons; positions ↔ deals read-back verify |
| **0D-1** — Inbox clarity | **LIVE** | Sections (open/closed/other), summary strip, per-row safety labels, read-only position↔deal hint; shipped 2026-06-30 (`7088473`) |
| **0D-2+** — Write actions (future) | **DEFERRED** | Enable-button / rebalance / staged-commit UI; blocked until Phase 1 materializer designed |

### Gates & Risks
**Hard gates on both paths:**
1. **MT5→staging writer:** further writes behind three-key approval + write test + rollback plan.
2. **staging→trades materializer:** not started; requires reviewed design + Phase-1 approval +
   full role decision. *Do not auto-materialize.*

**Other guardrails:**
- `needs_mapping` for unmapped instruments (hard-STOP on unknown symbol).
- Cross-account gate (terminal `301102520`); wrong login = reject.
- Idempotency via `position_id` (PATCH for updates), `deal_id` (insert-once for closes),
  `raw_sha` (corruption detect).

### Known Roadmap
- **0C-3c:** cursor/balance sync
- **0C-3d:** lifecycle reconcile (trade lifetime tracking)
- **Phase 1 materialization:** staging → `trades` with human confirm step
- Optional contract-size display row in order review summary (**DEFERRED, polish**)

---

## 4. GUGU v2 — The Destination (Built, Runtime-Frozen)

### Headline
**GUGU v2 is a real, built-in-repo memory-stream trading co-pilot — not vision-ware — but
it is currently runtime-frozen behind a capture-only mode.** "Built" and "running" are
different questions; this section keeps them separate.

**Source:** [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) (cross-repo
primary-source capture, 2026-07-10).

### Architecture — **CONFIRMED**

- **Framework:** PydanticAI (no LangChain/LlamaIndex).
- **Model:** Claude **Sonnet 4.6** (not Haiku; cost-ceiling aware).
- **Memory stream:** Append-only over Supabase **pgvector** with OpenAI `text-embedding-3-small`
  (1536-d). **RPC:** `match_memories(query_embedding, filter_symbol, filter_source, match_count)`.
- **Chat tools:** exactly **3** — `search_memories`, `append_memory`, `get_price`. Observation
  cycle adds two **read-only** tools; `get_ohlcv` deferred.
- **Observation/shadow cycle:** emits `CandidateFinding` objects with **no memory-write and
  no trade recommendations** — falsifiable, not prescriptive.
- **Cold start:** 78 rows imported from Supabase `bot_knowledge` table (`7` categories).
- **Personality:** Tony Stark-style co-trader; `gugu/personality.py` (~306 lines) + 9 hard
  rules + search-first discipline.

### Freeze Policy — **CONFIRMED (two-layer, fail-closed)**

1. **Deployed Telegram bot defaults frozen.** `CAPTURE_ONLY_MODE` unset → `True`. Cognition
   handlers (`/gugu_run`, `/gugu_digest`, free-text) register **only** when unfrozen (else
   branch unreachable).
2. **Manual entry points fail-closed.** `gugu/manual_run_guard.py`: unset/falsy →
   **blocked**; any `true`-ish → still blocked unless `GUGU_ALLOW_COGNITION_MANUAL_RUN ==
   "YES_I_UNDERSTAND"` (exact string). On block: exits `SystemExit(2)`, no LLM call made.

**Policy matches the Bible:** production autonomous cognition frozen on any repo; reviewed
v2 development allowed; observation-only before action; no production cognition without
explicit approval; capture-only production behavior (check-ins, notes) stays allowed.

### Cost Ceiling — **CONFIRMED (LIVE-in-repo, fail-closed)**

Hard caps (not suggestive):
- **Daily:** 1.5M tokens ≈ $5/day at Sonnet 4.6 blended rate (`cost_ceiling.py:110-114`)
- **Per-cycle:** 60k tokens (`:115`)
- **Per-cycle:** 25 calls (`:116`)

**Env-overridable** (`:128-132`); `guard_pre_call()` raises `CostCeilingExceeded` **before**
the API call. Day boundary Asia/Bangkok. Wired into `agent.py`, `cycle_agent.py`, `memory.embed`.

**v1 correction:** the v1 leak was **~$3/day** (Haiku-default monitor cycles), **not $5/day**.
The $5/day is the v2 Sonnet ceiling headroom — a separate thing. **CONFIRMED.**

**Gap:** no human-facing per-cycle token/cost **log line** and no `/cost` command in v2.
Persisted to `logs/gugu_usage_ledger.json` (ledger exists, not visible). **PARTIAL.**

### Sprint Status

| Claim | Verdict | Evidence |
|---|---|---|
| Days 1–5A complete (memory, cold start, agent/tools, tg_bot, observation cycle, cost ceiling) | **CONFIRMED (in-repo)** | Code all in-repo at `b03758a` (`gugu/memory.py`, `cold_start.py`, `agent.py`, `agent_tools.py`, `tg_bot.py`, `cycle_agent.py`, `cost_ceiling.py`); the "locally verified" run logs remain **NEEDS VERIFICATION** |
| "Days 6–8" as distinct completed days | **NEEDS VERIFICATION** | Repo shows **Day 5A.x only**; no Day 6/7/8 markers; no captured run logs |
| "Adversarial testing" | **PARTIAL / reconcile** | No adversarial-**agent** in runtime path. What exists: eval suite's `forbidden_invariants` + sanitizer re-check in `shadow_cycle.py`. Adversarial-*style* invariants, not a second-pass agent. |
| Deployment at Day 8 | **PARTIAL** | `gugu/DEPLOY.md` documents real VPS deploy; "Day 8" as trigger not stated in-repo → NEEDS VERIFICATION. |

**Runtime status:** GUGU v2 agent is **frozen, not running** for production cognition. Capture
Bot (check-ins, notes) is LIVE and unfrozen. Any Bible sentence saying GUGU is "running" must
read: **"built in-repo; deployment currently capture-only / frozen."**

### Telegram Bot (Capture-Only)

**LIVE.** `tg_bot.py` — **1158 lines** (corrects prior "~331") — Python 3.14 async polling +
SIGTERM graceful shutdown. Capture-only commands registered:

`/start_checkin`, `/whoami`, `/status`, `/review_today`, `/checkin`, `/checkin_trade`,
`/snooze`, `/resume`, `/off`, `/note`, `/undo_note`, `/delete_last_note`,
`/daily_on|off`, `/during_on|off`, `/frequency`, `/help`.

Cognition handlers register **only when unfrozen.**

### VPS Deployment — **PARTIAL; mostly NEEDS VERIFICATION**

| Sub-claim | Verdict | Evidence |
|---|---|---|
| IP `168.144.35.127` | **CONFIRMED** | `CLAUDE.md:412`, `gugu/DEPLOY.md:24,65,83,85,89` |
| systemd deploy on `/opt/gugu` via `gugu-telegram.service` | **CONFIRMED** | Unit runs `python -m gugu.tg_bot`; venv + pip install documented |
| DigitalOcean | **NEEDS VERIFICATION** | Zero in-repo hits |
| Ubuntu 24.04 | **NEEDS VERIFICATION** | Zero hits |
| $6/mo offline → $12/mo pricing | **NEEDS VERIFICATION** | Zero hits |
| Restore **crontab** on deploy | **NEEDS VERIFICATION** | Only in-repo crontab is a v1 `watchdog.sh`; v2 uses systemd (no crontab step). Whether a crontab is *restored on deploy* is unconfirmed |
| Restore **Flask** on deploy | **REFUTED for v2** | Flask is v1-only; v2 uses python-telegram-bot polling, not webhook |

> **On "REFUTED"** (not part of the README status vocabulary): it marks a claim carried in an
> earlier draft that was **contradicted by a primary `thus-trading-bot` source** during the
> 2026-07-10 reconciliation — e.g. "restore Flask on deploy," a v1-only artifact (v2 uses
> polling). It is a provenance verdict from reconciliation, not a roadmap status.

### Open Questions / Next Phases

**Days 6–8:** What do they contain? Are they Capture Bot enhancements, retrieval optimization,
adversarial testing, or phases not yet named?

**Adversarial second-pass:** The Bible names adversarial challenge as the #1 echo-chamber
defense. The repo has invariant-based eval testing but no deployed adversarial-agent layer.
When does this ship?

**Unfreeze plan:** The freeze is policy, not infrastructure. What is the reviewed, phased
plan to unfreeze cognition once the knowledge corpus and data trust are ready?

---

## 5. Portfolio — State/Risk Layer (User-Memory Captured)

**Source:** [`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md) §2.
**Status:** `VISION` / `NEEDS_REPO_SOURCE` (designed intent; live pieces exist, roadmap not consolidated).

### Role
Portfolio is the **state/risk layer** — account balance, equity, unrealized/realized P/L,
high-water mark (HWM), exposure, drawdown. It answers: what is the trader exposed to; total
risk across open positions; how the current trade interacts with account state. **It is not
the source of trade truth** — trades remain canonical; Portfolio derives and must never invent
or double-count.

### What is Live (with caveats)
- `portfolio` and `portfolio_summary` tables persist via hardened save path.
- `portfolio_summary` had a costly write-every-5–60s loop (patched 2026-05-11,
  `RESOURCE_AUDIT.md`).
- HWM Equity dashboard card + Trader Style Profiler card were **hidden** in the 2026-05-12
  pivot (code retained, not rendered).

### Intentionally Deferred (not abandoned)
Hidden because:
1. The Journal durability foundation wasn't stable enough.
2. Analytics on unreliable trade state would mislead both user and GUGU.
3. Outcome-based "style profiling" risks overfitting unless redesigned around **process**,
   **plan-following**, **risk behavior**, and **thesis quality**.

### Future Roadmap (`VISION` / `NEEDS_REPO_SOURCE`)

**Risk & exposure** — exposure by product/asset-class/direction; total open risk;
concentration; correlated exposure; futures contract-size-aware; currency-aware; real
execution risk vs UI summaries.

**Drawdown & equity state** — balance, equity, HWM, drawdown-from-HWM, recovery progress,
risk regime by drawdown state.

**Position sizing & risk behavior** — size vs plan; rational vs emotional scale-in; risk
added during weak thesis; open risk vs account state.

**Performance attribution** — P/L by product / thesis type / mentor hypothesis / behavior
tag / pattern-rule / plan-following vs violation.

**GUGU-facing context** — enable GUGU to say: *"this trade is individually valid, but total
exposure is already high"*; *"you're adding while the thesis is weakening"*; *"realized P/L
is positive but open risk is asymmetric"*; *"this resembles prior drawdown behavior."*

### Open Questions
- Should HWM return or stay hidden?
- Should Trader Style Profiler be redesigned or rejected?
- Which metric first for GUGU context (exposure / drawdown / sizing / concentration / risk
  behavior)?
- Multi-account support — how?
- How does MT5 balance/equity sync into Portfolio?

### Risk / Guardrails
- Raw trade rows canonical; totals derived not invented.
- No synthetic rows; no P/L double-count.
- No hidden writes that mutate trade truth.
- Any GUGU risk recommendation stays **propose, not prescribe**.

---

## 6. Mentor — Hypothesis/Reasoning Layer (User-Memory Designed)

**Source:** [`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md) §3.
**Status:** `DESIGNED` / `VISION` (design seed exists; not implemented in-repo).

> **Not a first attempt.** An earlier in-repo **AI mentor note route** existed and was
> **deprecated/hidden in the 2026-05-12 pivot** ([`SOURCE_INVENTORY.md`](./SOURCE_INVENTORY.md) §7).
> Mentor was *partially attempted, then shelved* — the structured hypothesis layer below is the
> redesign, not a first pass. Provenance is thin; specifics `NEEDS VERIFICATION`.

### Role
Mentor is the **hypothesis/reasoning layer** — capture market views, theses, invalidation
points, observations, and lessons **without** prematurely converting them into permanent
rules. Mentor content is not a trade row, a final lesson, a market rule, a bot command, or
a backlog item — it starts as a hypothesis to be observed, tested, confirmed, invalidated,
or retired.

### Why It Exists
The trader does weekly forward-testing / mentor-style learning. The value is **preserving**:
- What was believed at the time
- What would prove it wrong (invalidation condition)
- What to observe next
- How it played out
- Whether it became a lesson, a false pattern, or a useful rule

This way, **GUGU learns the trader's evolving framework, not static textbook rules.**

### Mentor View Structure (`DESIGNED`)

At minimum:
```
MENTOR_VIEW
symbol:
view:
horizon:
anchor:             # reason for the view
observe:            # what to watch for
invalidation:       # condition that proves the view wrong
```

### Storage Approach (`DESIGNED`)
Fit existing note/taxonomy mechanics first (avoid new complex UI):
- **Type:** mentor view / market hypothesis / lesson / rule (by maturity)
- **Content:** structured body (symbol, view, observe, invalidation)
- **Source:** `mentor`
- **Tags:** symbol/market/timeframe/hypothesis/invalidation/status

**Do not auto-promote** a mentor observation into a permanent rule.

### Hypothesis Capture Lifecycle (`CONFIRMED_FROM_USER_MEMORY`)

**Pre-trade:** thesis A/B/C, plan, entry reason, invalidation, expected behavior, risk
scenario, mentor view if relevant.

**During-trade:** emotional state, thesis health, contradiction evidence, urge to
exit-early / add / force-narrative, whether market behaves as expected.

**Post-trade:** exit reason, plan-followed?, mistakes, fixes, price action after exit,
mentor hypothesis confirmed or invalidated.

### How GUGU Uses Mentor (`CONFIRMED_FROM_USER_MEMORY`)

GUGU should **surface, not assert:**
- *"This setup resembles a mentor hypothesis you were tracking — still valid?"*
- *"The invalidation condition may have triggered."*
- *"This was captured as a hypothesis, not a proven rule — review?"*
- *"The view said observe X, but the market is doing Y."*

**GUGU preserves uncertainty and review status.** It does not graduate a hypothesis to rule.

### Known Roadmap (`VISION` / `DESIGNED`)

Mentor note template → hypothesis capture → hypothesis review → link views to trades →
link views to Pattern Library → track confirmed/invalidated/cancelled → GUGU recall in
context → weekly mentor review summary → mentor performance stats.

### Risks
- Treating views as permanent truth too early.
- Losing invalidation conditions.
- Mixing market hypothesis with behavior lesson.
- GUGU over-weighting unverified observations.
- Duplicating knowledge across Journal/Notes/bot memory/GUGU memory.

**Guardrail:** mentor content must **retain its epistemic status** — hypothesis, observation,
rule, lesson, rejected pattern, or confirmed pattern. **CONFIRMED_FROM_USER_MEMORY.**

---

## 7. Notes / Knowledge Engine (Schema Live, Activation Deferred)

### Purpose
The **learning/retrieval layer** — curated, hand-shaped knowledge: quotes, rules, lessons,
ideas/hypotheses that GUGU retrieves and reasons with.

### Current State
**LIVE schema, activation DEFERRED.**

- `notes` table persists via hardened save path.
- 4-type taxonomy: `quote`, `rule`, `lesson`, `idea` (documented in `docs/notes_taxonomy.md`).
- Tag conventions documented (confidence, applies-to, invalidation, source).
- LLM-retrieval redesign (embeddings/semantic search) is **deferred** until ≥20–30 real
  content exists.

### Design Intent
Deliberately kept small and hand-shaped (not bulk-dumped) so retrieval surfaces real
framework knowledge, not stale or noisy data.

### Known Roadmap
- **Revisit trigger:** when there are ≥20–30 real notes (typed or reviewed-bulk-import)
  **and** Phase-2 review-loop needs structured input.
- A future "Session B" designs minimal schema (tag conventions first, columns only if proven
  needed).
- Possible separate gated session may unfreeze GUGU cognition for a second shadow cycle
  (depends on unfreeze readiness).

### Gates / Risks
- **Do NOT** pre-add an `embedding` column / vector index on assumption.
- **Do NOT** bulk-dump raw notes into `notes.freeform` / `tj_notes`.
- **Do NOT** auto-import Capture Bot check-ins into Notes.
- Bulk import must go through a reviewed `import_preview.json` and the normal app save path,
  with backups first.

---

## 8. Market Pattern Library — Structured Learning (User-Memory Designed)

**Source:** [`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md) §4–5.
**Status:** `DESIGNED` / `VISION` (design seed + S50 concrete examples). **No formal Pattern
Library is established in either repo** — the closest is an archived GUGU spike seed for the
S50 gap-down idea (see "Known Roadmap" below).

### Purpose
Turn repeated market observations into structured, reviewable patterns — not free text.
Capture trigger, lesson, action, invalidation/exceptions, examples, status, source,
confidence, review history.

### Entry Structure (`DESIGNED`)

Minimal shape:
```
PATTERN
name:                 # e.g. "S50 gap-down failure to recover"
market:               # symbol / timeframe
trigger:              # market condition that activates the pattern
lesson:               # what this pattern teaches
action:               # what to do if triggered
invalidation:         # conditions that contradict the pattern
example:              # a real historical case
status:               # candidate / watch / confirmed / invalidated / cancelled / rejected
source:               # where it came from
tags:                 # symbol/market/timeframe/hypothesis/invalidation/status
```

### Pattern Statuses (`VISION` / `DESIGNED`)
`candidate` · `watch` · `confirmed` · `invalidated` · `cancelled` · `rejected` ·
`needs more samples`.

### Auto-Warn Behavior (`VISION`)
Feeds GUGU + Note Activation to warn before/during trades — e.g.:
- **Pre-entry:** *"This resembles a pattern where you got trapped; requires confirmation,
  don't catch the falling knife."*
- **During-hold:** *"The invalidation condition may be appearing; this resembles the S50
  gap-down continuation case."*
- **Post-trade:** *"This trade may update an existing pattern — review whether it was
  confirmed or invalidated."*

### Relationship to Notes / Knowledge / GUGU (`CONFIRMED_FROM_USER_MEMORY`)
- **Notes** capture observations.
- **Pattern Library** structures repeatable market lessons.
- **Mentor** captures hypotheses + invalidation.
- **GUGU** retrieves patterns when context matches and surfaces candidates.

**GUGU must NOT invent a rule from one example** — it surfaces candidates and asks for review.

### Known Roadmap
Not concretely implemented in-repo. The closest shipped feature is **Note Activation v0.1**
(`gugu/note_activation.py`, `thus-trading-bot`): 6 deterministic, tag-gated, **no-LLM**
during-trade mentor reminders keyed to emotion tags (`fear_giveback`, `want_exit_early`,
`want_add_position`, `force_narrative`, `plan_drift`, `size_too_big`). Explicitly "not a
signal/action"; a reminder to review.

**A formal "Market Pattern Library"** (trigger+lesson+action auto-warn) is **not established in
either repo.** The closest in `thus-trading-bot` is an **archived spike seed** — the text
"S50 gap down without intraday recovery = exit immediately" in
`archive/spike-20260427/test_retrieval.py` (not a live library entry, not labeled "corrected") —
plus `behavior_scanner.py` gap **tags** with no attached lesson/action. The corrected S50 rule
and the `S50H26` 1029→942 case remain **user-memory / `NEEDS_MARKET_DATA_SOURCE`** until grounded
in THUS Journal notes / chart data; the cancelled "gap up 2 days → sell-off" rule remains
**`REJECTED` / user-memory** (see §9). Source: [`GUGU_V2_RECONCILIATION.md`](./GUGU_V2_RECONCILIATION.md) §10.

### Risks
- Overfitting one event into a rule.
- Keeping false rules alive.
- Forgetting cancelled patterns.
- Mixing market-structure lessons with emotional-behavior lessons.
- Noisy over-triggering.
- **GUGU treating candidates as confirmed truth.**

**Guardrail:** a **cancelled pattern must remain searchable as rejected knowledge** so it
isn't re-derived. `CONFIRMED_FROM_USER_MEMORY`.

---

## 9. S50 Market Rules — Concrete Pattern Examples (User-Memory Captured)

**Source:** [`USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md`](./USER_MEMORY_CAPTURE_PORTFOLIO_MENTOR_PATTERN.md) §5.
**Status:** `CONFIRMED_FROM_USER_MEMORY` / `NEEDS_MARKET_DATA_SOURCE` (user-memory; not yet in
repo or formalized as pattern).

### Corrected S50 Gap-Down Rule (`CONFIRMED_FROM_USER_MEMORY` / `NEEDS_MARKET_DATA_SOURCE`)

```text
[market_rule/s50_gap_rule]
In an uptrend, if S50 gaps down and does not recover intraday, exit immediately.
The next day can gap down again and become a cascade sell-off.
```

**Worked example:** Mar 2026 `S50H26`: 1029 → 942. **Interpretation:** the danger is not
merely a "gap" — it is **gap-down + failure to recover intraday**; waiting for a rebound
can be dangerous because the next session can gap down again. **Action:** immediate exit /
risk reduction, not averaging down.

**Relationship to "no falling knife":** `Strong drop = do not catch falling knife.` The S50
gap-down rule is a more specific version of the same risk principle; it should trigger
caution when the user is tempted to hold/add during a fast downside continuation.

### Cancelled False S50 Rule (`REJECTED` / `NEEDS_MARKET_DATA_SOURCE`)

**Explicitly cancelled false rule:**
```text
REJECTED_PATTERN
name: S50 gap-up two-days sell-off
old_rule: gap up 2 days → sell-off
status: cancelled / false pattern
reason: explicitly cancelled by user; do not use as a market rule
replacement: corrected S50 gap-down failure-to-recover rule
```

**Do not use.** Record in [`16_REJECTED_IDEAS.md`](./16_REJECTED_IDEAS.md) and/or the Pattern
Library as a rejected pattern so **future AI does not re-derive it.** `REJECTED`.

### How GUGU Should Use S50 Rules (`CONFIRMED_FROM_USER_MEMORY`)

**Contextual warning, not a mechanical signal.**

**Correct:** *"This resembles the S50 gap-down failure-to-recover risk — is the market
recovering intraday or failing?"; "This is not the cancelled gap-up rule — don't confuse
them"; "If the gap-down failure is confirmed, risk reduction may matter more than waiting
for a rebound."*

**Incorrect:** *"Every gap means exit"; "Gap up two days means sell"; "Automatically close
the trade"; "Turn one historical case into a universal signal."*

### Open Questions
- Is the Mar 2026 `S50H26` 1029→942 case already in THUS Journal notes with screenshots?
- Chart/screenshot evidence for the corrected rule?
- Exact intraday-recovery condition for "does not recover"?
- S50 futures only, or broader Thai index futures?
- How should a cancelled pattern be tagged in the Pattern Library so it doesn't resurrect?

---

## 10. Products / Symbol Registry (Live Foundation)

### Purpose
A registry mapping tradeable products to their semantics: family, symbol series
(current/`_next`), asset kind (futures/stock/…), currency, contract size, price source,
and P/L basis. Lets the system reason about heterogeneous instruments correctly.

### Current State
**LIVE foundation** (`2026-06-19`, `2c2c8d2`): `ProductRegistry` facade, price-source badge,
runtime kind inference, kind-aware expansion/labels, and the first non-futures product
**DELTA** (`assetKind:"stock"`, THB, manual-price, single expansion, gross P/L).

MT5 Inbox preview and trade-open picker now show family-level name/contract-size display
strings.

**Explicitly no schema/P&L/durable-path change.**

### Known Roadmap
- Additional non-futures kinds (FX/CFD, crypto) **DEFERRED**.
- Order review-summary "Contract Size" row is optional polish (**DEFERRED**).
- Product-registry roadmap (kinds, spot/CFD trades routing to a future `trades_capture`
  table) **NEEDS VERIFICATION** — likely in user memory or VPS-side design.

### Gates / Risks
- Display-only changes so far.
- Any change to `productId` selection/persistence or `live_prices` / `contractToLiveKey`
  mapping is higher-risk and needs review.
- Contract-size correctness matters (e.g. `DELTAU26` SSF csize 1000 must never collapse
  onto the DELTA stock preset csize 1).

---

## 11. Review / Analytics (Live; Deferred Redesign)

### Purpose
Dashboards and analytics over trade history: realized/unrealized P/L, win rate, HWM,
calendar daily P/L, journal totals, exports (Excel/Sheets).

### Current State
**LIVE** (core dashboard/analytics render in the SPA). Google Sheets Sync UI was **hidden**
and auto-fire disabled in the 2026-05-12 pivot (object retained).

### Design Intent
Analytics are render-time derivations GUGU can also compute from raw; they must stay
consistent with the P/L invariant so human and AI views agree.

### Known Roadmap
- **Process-based redesign** for style profiling (vs outcome-based, which overfit easily).
- **Re-enable/redesign hidden cards** (HWM Equity, Trader Style Profiler).
- **Phase 2 review-loop** structured input.

### Risks
All aggregates must ignore `group_id` and walk raw `trades[]`. This is a **P/L invariant**
rule — violations silently double-count.

---

## 12. Operations / Deployment / Review Process (Live Process)

### Purpose
How work ships safely: the gate model, the multi-model review chain, the deploy/smoke
discipline, migrations-by-human, and resource/cost hygiene.

### Current State — **LIVE process**

- **Pipeline state:** tracked in `artifacts/pipeline/PIPELINE_STATE.md` +
  `NEXT_SAFE_TASK.md`.
- **Autopilot governed** by `AUTOPILOT_RULES.md` (MAY / MUST STOP / MUST NOT).
- **Deploys:** user-gated; migrations: human-run in the Supabase SQL Editor; write flags
  default-off.
- **Review chain:** GPT plan → Claude Code implement/report → Codex review → GPT adversarial
  → human deploy/smoke.

### Gates & Risks (the "MUST STOP" list)

These are **human-gated** regardless of how the docs read — never let them slip silently:

- **DB/SQL/RLS:** any migration, RPC write, schema change, permission change.
- **Supabase/RPC writes:** any `write-RPC` execution, flag enable, `journal` trigger change.
- **Push/deploy:** any branch push or app deploy.
- **Flag enables:** any `tj_*` feature flag set to `true`.
- **MT5 writer:** further MT5→staging writes.
- **GUGU cognition:** any unfreeze or production cognition without explicit approval.
- **Durable paths:** any change to save/close/delete/merge/import writers.
- **Failed validation:** any Codex fail → STOP, investigate, do not force-push.
- **Architecture tradeoffs:** single-file SPA, `57014` scale, P/L invariant, raw integrity.

### Known Roadmap

**Backup-retention decision** for sensitive image backups (holds base64/account data) —
**DEFERRED**.

**RLS/security hardening** — needs a fresh read-only audit (**GATED**).

---

## 13. Cost / Economics (Hard Ceiling, Partial Logging)

**GUGU v2 cost ceiling is LIVE-in-repo, fail-closed.** Distinct from v1 ($3/day leak).

### Hard Caps (Sonnet 4.6)
- **Daily:** 1.5M tokens ≈ $5/day blended rate
- **Per-cycle:** 60k tokens
- **Per-cycle:** 25 calls

Env-overridable; `guard_pre_call()` raises `CostCeilingExceeded` **before** the API call.
Day boundary Asia/Bangkok. Wired into agent, cycle, memory layers.

### v1 vs v2

| | v1 Leak | v2 Ceiling |
|---|---|---|
| Amount | ~$3/day | ≈$5/day Sonnet |
| Source | Haiku-default monitor cycles that mostly produced "NOTHING" | Sonnet cost-ceiling headroom |
| Status | Archived 2026-04-26 | LIVE fail-closed |
| Mitigations | None — led to v2 rebuild decision | Frozen cognition + per-cycle guards + cost invariant |

**The Bible's "$5/day Haiku" was a conflation** — it actually described the v2 Sonnet ceiling
headroom. **CONFIRMED.**

### Logging Gap
Per-cycle accounting persisted to `logs/gugu_usage_ledger.json` but **no human-facing per-cycle
token/cost log line** and **no `/cost` command** in v2. **PARTIAL.** A small follow-up if
visible per-cycle cost line is wanted.

### Risks
- **Economic runaway** — mitigated by hard fail-closed ceiling; same rank as "no silent
  unfreeze."
- **Monitoring blind spot** — accounting exists, not visible; consider adding to ledger or
  `/cost` UI.

---

## 14. Roadmap by Status — Cross-Subsystem View

*Tag semantics (from README): **LIVE** = shipped to the production app bundle; **APPLIED +
VERIFIED** = a DB/RPC/schema migration executed against live Supabase and validated; **DONE** =
completed local/docs/tooling/closed-out work that is not itself a production-app-live bundle.
DB migrations live under APPLIED (not LIVE); the app features that depend on them live under
LIVE. No item is listed under two categories except where a subsystem genuinely has distinct
parts (e.g. image externalization: code=LIVE, storage policy=APPLIED, one-time backfill=DONE).*

### LIVE (Production app bundle, shipped)
- Journal core persistence — P0/P1/P2 durable mutations + closed-trade correction (v3.23.0)
- Journal image externalization — externalize-on-save (shipped with P2)
- Product / symbol registry foundation (`2c2c8d2`, 2026-06-19)
- Grouping G3 loader/render + create-only UI (default-off, v3.23.0)
- MT5 0D-0 / 0D-1 read-only Inbox UI (default-off `tj_mt5_inbox`)
- Notes 4-type taxonomy / feature
- Review / Analytics core dashboards (Sheets Sync hidden)
- Capture Bot — check-in commands, notes, tagging (`thus-trading-bot`, capture-only)
- *(the DB migrations these depend on are under APPLIED; armed staging writes under DONE)*

### APPLIED + VERIFIED (Schema/DB executed against live Supabase and validated)
- Grouping G1 schema/RLS (2026-06-08)
- Grouping G2 RPCs (2026-07-05)
- Grouping G2-rpc-isMerged defense-in-depth (2026-07-10, recorded `b94f7fd`)
- MT5 0A schema/RLS/RPCs (2026-06-25)
- Image externalization storage policy + RLS (2026-06-22)

### DONE (Completed local/docs/tooling/closed-out; not necessarily production-app-live)
- Image backfill — 18 rows / 37 images, browser-side, **local-only commit (not pushed)**
- Grouping G2 v0.3 create-only UI rollback smoke (local)
- Grouping G2 write-gate browser smoke (2026-07-07; rolled back → 0 active / 1 archived)
- MT5 0C-3a / 0C-3b armed staging writes (real prod-Supabase side effects; report-only, no commit)
- P/L baseline snapshots (G2, 2026-07-02)

### DESIGNED (Design written, reviewed, not built)
- Grouping G5 (GUGU summary hook)
- Grouping v0.5 (ungroup UI)
- Mentor View structure
- Market Pattern Library entry structure
- MT5 staging→trades materializer
- Portfolio roadmap (state/risk layers)
- Note Activation v0.1 (real feature, shipped as-is)

### DEFERRED (Postponed with known trigger)
- Notes LLM-retrieval redesign (wait for ≥20–30 real items + Phase-2 trigger)
- Grouping G3.5 (closed-trade grouping)
- Grouping G4 (group notes)
- Grouping G6 (legacy Merge cleanup)
- MT5 0D-2+ (write actions)
- Portfolio HWM/style profiling (wait for durability, then redesign)
- Navigation/URL audit (Journal residual)
- PageSteps cleanup, `uid()` migration (Journal residual)
- Backup-retention decision (sensitive data)
- RLS/security audit (gated, needs fresh read-only pass)

### NEEDS VERIFICATION (Asserted but unconfirmed)
- Journal P2 residual durability (delete/duplicate/import)
- Journal `20260512` trade_events archive-lockdown actually applied in prod
- GUGU Days 6–8, "adversarial testing" wording, "locally verified" run logs
- GUGU VPS provider/OS/pricing (DigitalOcean, Ubuntu 24.04, $6→$12)
- GUGU human-facing per-cycle cost line
- Knowledge corpus specifics (NotebookLM, 17 categories, candlestick/Wyckoff)
- Market Pattern Library existence and S50 rules (likely THUS Journal notes)
- Portfolio roadmap priority order
- MT5 full roadmap through materialization
- Product-registry roadmap (FX/CFD/crypto kinds, spot-trade routing)

### GATED (Blocked behind explicit human approval)
- MT5 further staging writes (three-key approval)
- MT5 staging→trades materializer (reviewed design + Phase-1 approval)
- GUGU autonomous cognition unfreeze (explicit approval + knowledge corpus review)
- `tj_trade_group_write_v01` flag enable (hardcoded MUST STOP in AUTOPILOT_RULES.md)
- Merge/old-grouping revival (hard-forbidden)
- RLS/security overhaul (blocked until audit complete)
- Grouping write paths (P/L-invariant guardrails protect)
- Durable-save path mutations (review required)

### VISION (Long-horizon, not scheduled)
- Portfolio full risk model (exposure, drawdown, attribution, GUGU context)
- Mentor hypothesis lifecycle (form, test, confirm, invalidate, retire)
- Market Pattern Library auto-warn (before/during/after trade)
- Pattern / lesson engine (compound learning over years)
- GUGU as mature co-trader (track record, self-correction, adversarial debate)
- Two-mind debate for echo-chamber prevention (adversarial second-pass agent)
- Full layered OS (all 6 layers mature and integrated)

### RESEARCH (Under investigation)
- None at present; all major unknowns flagged as NEEDS VERIFICATION.

---

## 15. Explicit Non-Authorizations (What Must Never Happen)

These are **policy decisions**, not infrastructure states. They are protected by gates, but
the gates exist to **enforce** policy, not to suggest it is optional.

- **Do not automate trade execution.** Ever, without an explicit, separate, human decision.
  The system proposes; the human executes.
- **Do not unfreeze GUGU cognition silently.** The freeze forbids autonomous cognition
  running against live/production data, or producing production behavior, on any repo
  without explicit approval. It ends only via an explicit, reviewed go-ahead.
- **Do not let metadata become a trade.** No synthetic P/L-bearing rows; no reducer reading
  group totals as truth; raw executions are the only P/L-bearing rows.
- **Do not sacrifice data integrity for a feature.** A feature that risks silent loss or
  double-count is not worth shipping until the risk is designed out.
- **Do not merge executions destructively.** The old Merge row-collapsing is permanently
  disabled. Grouping (metadata model) is the replacement. Do not revive the old path.
- **Do not bulk-dump knowledge into memory.** Notes, patterns, and knowledge are
  deliberately kept small and curated. Bulk import must go through reviewed preview +
  normal save path + backups.
- **Do not auto-import check-ins into Notes.** Capture Bot time-series (check-ins) and
  Notes (curated knowledge) serve different purposes.
- **Do not pre-add embedding columns on assumption.** Embeddings are deferred until
  retrieval design is proven necessary.

---

## 16. Next Recommended Work (by track)

### Immediate (unblocked, high value)

**Journal Track:**
- Verify P2 residual durability (delete/duplicate/import paths).
- Confirm `20260512` trade_events archive-lockdown applied in prod.

**Grouping Track:**
- Test G5 (GUGU summary hook) readiness against Capture Bot Day 4.
- Decide: is G3.5 (closed-trade grouping) worth shipping before real groups are user-tested?

**Operations Track:**
- Write [`14_CURRENT_STATE.md`](./14_CURRENT_STATE.md) (not yet created) from the latest
  [`PIPELINE_STATE.md`](../pipeline/PIPELINE_STATE.md).

### Medium (unblocked, design ready)

**MT5 Track:**
- Design 0C-3c (cursor/balance sync).
- Design 0C-3d (lifecycle reconcile).

**GUGU Track:**
- Verify "Days 6–8" from bot repo / user memory.
- Implement human-facing per-cycle token/cost log line (small follow-up).
- Start unfreeze-readiness review: knowledge corpus size, data trust assessment, adversarial
  testing gaps.

**Knowledge/Pattern Track:**
- Gather real ≥20–30 mentor observations and patterns from THUS Journal notes / user memory.
- Formalize the corrected S50 gap-down rule + the cancelled "gap up 2 days" pattern as
  rejected knowledge (with market-data evidence).

### Longer-term (design / strategic)

**Portfolio Track:**
- Design Portfolio roadmap (state/risk layers) at the priority level from user memory.
- Decide: HWM Equity return or redesign? Trader Style Profiler or reject?

**Mentor Track:**
- Implement Mentor View note type / structured capture.
- Design hypothesis lifecycle tracking (confirm/invalidate/retire).

**Pattern Library Track:**
- Implement pattern entry structure (trigger/lesson/action/status).
- Design GUGU auto-warn behavior before/during/after trades.

**GUGU Unfreeze Track:**
- Review knowledge corpus (size, quality, GUGU retrieval accuracy).
- Design and test adversarial second-pass agent.
- Draft explicit unfreeze SOP (gates, review, rollback plan).
- Plan when cognition unfreeze proposal goes to user.

---

## 17. Risks & Tech Debt (Live Register)

### Active Mitigations
- **Silent data-loss** — mitigated by single-row durable writes (P0/P1/P2 LIVE); residual
  non-durable writers on backlog (P2 residual NEEDS VERIFICATION).
- **Silent double-count** — mitigated by P/L invariant (reducers ignore `group_id`, raw is
  canonical); guarded by grouping RPCs + `isMerged` defense-in-depth.
- **Single-file SPA scale** — mitigated by image externalization (16.6 MB → 0.15 MB);
  `57014` timeout risk persists on large `raw` payloads (needs size review for new features).
- **GUGU echo-chamber** — mitigated by observation-only cycle (no memory-write, no
  recommendations); `forbidden_invariants` eval testing; partial (no adversarial second-pass
  agent yet — **this is a known gap**).
- **GUGU economic runaway** — v1 leaked ~$3/day; v2 mitigated by hard fail-closed cost
  ceiling (1.5M tok/day ≈$5/day Sonnet, 60k/cycle, 25 calls/cycle); same rank as "no
  silent unfreeze."
- **False-pattern re-derivation** — **HIGH RISK**, depends on Mentor + Pattern Library
  implementation. Overfitting from one case (e.g. S50 Mar 2026) into a universal rule; old
  cancelled patterns being re-derived (e.g. the false "gap up 2 days → sell-off"). Mitigated
  by rejected-knowledge records + pattern status field + GUGU hypothesis-preservation.

### Residual Risks
- **Portfolio roadmap thinness** — state/risk layer roadmap not consolidated; HWM/style cards
  hidden pending redesign; no guidance on priority metrics for GUGU context.
- **Mentor hypothesis lifecycle not implemented** — capture structure designed but not wired;
  no tracking of hypothesis → outcome → lesson flow.
- **Pattern Library not formalized in repo** — Market Pattern Library design + S50 rules not
  in either repo; only Note Activation v0.1 (deterministic reminders, not adaptive patterns).
- **Notes LLM-retrieval deferred** — activation waits for ≥20–30 real items; until then,
  Knowledge/Mentor/Pattern layers have no semantic retrieval.
- **GUGU adversarial second-pass not yet built** — evaluation invariants exist but no
  deployed second-pass agent to challenge findings before they reach the user. **High
  echo-chamber risk.**
- **GUGU unfreeze plan not explicit** — freeze is fail-closed (good), but the reviewed,
  phased unfreeze pathway is not documented.
- **Docs drift** — this Bible is a point-in-time snapshot; repo will change; sync discipline
  is needed (see [`14_CURRENT_STATE.md`](./14_CURRENT_STATE.md) *(once written)* +
  [`PIPELINE_STATE.md`](../pipeline/PIPELINE_STATE.md)).
- **RLS/security gaps** — pending read-only audit (Lane G, GATED).
- **Backup-retention** — sensitive image backups (base64/account data) need retention
  decision (**DEFERRED**).
- **`[DIAG]` / deferred cleanups** — navigation audit, PageSteps dead prop, `uid()` migration
  still deferred (Journal residual).

---

## Conclusion

**This roadmap is a live, tagged inventory so no work disappears.** The North Star remains:
THUS is building an AI-native Trading Operating System. Journal is the memory/data layer.
**GUGU is the destination and long-term primary consumer.**

Every item in this roadmap traces back to that mission. Some items are LIVE (Journal, core
MT5, GUGU v2 built). Some are DESIGNED (Mentor, Pattern Library, Portfolio roadmap). Some
are DEFERRED with known triggers (Notes retrieval, Portfolio redesign). Some are GATED
(MT5 materializer, GUGU unfreeze). Some are VISION (full layered OS, compound learning over
years).

**The key commitment:** nothing is dropped silently just because it is not implemented today.
The tags make that visible. The freeze on GUGU cognition is explicit and has a reviewed
unfreeze path (still to be documented). The cost ceiling is fail-closed and wired live. The
P/L invariant is guarded by tests and gates. The data is durably persisted.

**Next step:** use this roadmap to plan Chapter 05+ (architecture, deep-dives per subsystem,
operations manual, ADRs, history, and the unfreeze SOP). All lanes now have a home.
