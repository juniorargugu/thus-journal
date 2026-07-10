# 02 — Vision and North Star

*This is the most important chapter. Its job is to preserve direction across sessions,
models, and contributors. If any future decision seems to contradict this chapter,
surface the contradiction — do not quietly redefine the goal.*

---

## The North Star

**THUS is building an AI-native Trading Operating System.**

Not a trade journal. Not a dashboard. A system whose long-term primary user is an AI
copilot — **GUGU** — that learns one trader's framework over a multi-year horizon and
helps make better decisions.

The original framing, preserved verbatim:

> **"สมองที่เรียนรู้ trade กับ Junior ได้ 3 ปี+ โดยไม่จำกัดการเติบโต"**
> — a brain that learns to trade *with* Junior over 3+ years, without capping its growth.

And the founding decision that produced the current architecture:

> **"ทิ้งของเก่า build ใหม่"** — discard the old, build new. Not rebuild the same
> architecture, but a fundamentally different approach.

## The single sentence that explains all current work

> **"We are hardening the Journal now so that GUGU can trust the data later."**

Every persistence fix, every P/L invariant, every gated migration, every default-off
flag is downstream of that sentence. When a task's value is unclear, ask: *does this make
the data GUGU will one day reason over more trustworthy?* If yes, it belongs. If it just
adds surface area an AI would have to distrust, it probably does not.

---

## The layered model

THUS is organized as layers around GUGU. Each layer has a distinct role, and the roles
must not blur.

| Layer | Role | Status posture |
|---|---|---|
| **Journal** | **Memory / data layer.** The canonical, lossless, durable record of trades, notes, and portfolio state. Source of truth for all P/L. | Actively hardened; mostly LIVE. |
| **MT5** | **Execution / source layer.** Mirrors real broker executions (fills, prices, contract sizes) into the system as trustworthy source facts. Never writes Journal trades directly. | Read-only + gated staging; writer GATED. |
| **Portfolio** | **State / risk layer.** Account balance, equity, high-water mark, exposure — the current risk picture derived from executions. | Partially LIVE; roadmap thin (NEEDS VERIFICATION). |
| **Knowledge / Notes** | **Learning / retrieval layer.** Curated rules, lessons, quotes, hypotheses — the durable, human-shaped knowledge GUGU retrieves and reasons with. | Schema LIVE; activation DEFERRED. |
| **Mentor** | **Reasoning / hypothesis layer.** The layer that forms and tests hypotheses about the trader's framework and performance — the bridge between raw memory and useful judgment. | VISION / backlog (NEEDS VERIFICATION). |
| **GUGU** | **The long-term primary consumer.** Reads across all layers, reasons, proposes, challenges. | Autonomous cognition FROZEN (prod); capture-only live; **v2 build active in `thus-trading-bot`**. |

**Human stays in control.** GUGU is an analyst-apprentice / co-trader, not an autopilot.
It may have opinions, connect dots, and challenge the trader — including challenging
emotional state, because emotion affects trading directly — but **every trade decision is
the human's.** The design principle is **propose, not prescribe**: *"this setup looks like
X — is there something you're seeing that I'm not?"* rather than *"do X."*

**AI should improve decision quality, not blindly automate trading.** The value is better
judgment, better recall, better self-correction — not order execution. Automating the
execution loop is explicitly *not* the goal.

---

## Why the hardening work matters to GUGU

The Journal hardening program is not incidental engineering; each piece removes a way the
future AI could be misled:

- **Durable persistence.** If a close can silently fail to persist (optimistic toast +
  unawaited save), the record GUGU reads is a lie about what the trader did. Single-row
  durable writes mean the trade GUGU consumes is guaranteed-persisted, not a lost
  optimistic UI state. **Durable = trustworthy.**
- **Raw integrity.** All P/L derives from raw executions. If any layer mutates `raw` or
  injects a synthetic "summary" row that gets counted, the numbers GUGU reasons over are
  wrong. Raw stays canonical; everything else is computed at render time.
- **Grouping (not merging).** The old Merge collapsed trades into a synthetic row and
  silently double-counted P/L. Grouping models a trade *idea* as pure metadata over
  canonical executions — so scale-ins, partials, and averaged entries can be understood
  as one thesis **without** corrupting the P/L GUGU will learn from. It also gives GUGU a
  natural unit ("one trade idea") to reason about, and a future hook (`[Insert GUGU
  summary]`) to attach its analysis to.
- **MT5 pipeline.** Human-entered trades are incomplete and error-prone. A gated,
  idempotent mirror of real broker executions gives GUGU ground truth about fills, exact
  prices, and contract sizes — the raw material for honest performance analysis — while
  keeping the human confirmation step so nothing auto-materializes.
- **Image externalization.** Screenshots as inline base64 bloated rows and caused load
  timeouts. Externalizing them keeps `raw` lean, hydration reliable, and the dataset
  clean and loadable — a precondition for GUGU consuming history at scale.
- **Notes/Knowledge.** Curated lessons and rules are the human-shaped priors GUGU
  retrieves. Deliberately kept small and hand-shaped (not bulk-dumped) so retrieval
  surfaces real framework knowledge, not stale arithmetic. (An earlier bulk import of 78
  rows into a memory store showed what unfiltered dumping does: it floods retrieval with
  stale zones and biases the model.)

---

## What GUGU is meant to be (GUGU v2 design intent)

The following is the GUGU v2 **design intent**. GUGU v2 is an **active build** in the
sibling `thus-trading-bot` repo (see [`01_EXECUTIVE_SUMMARY.md`](./01_EXECUTIVE_SUMMARY.md)),
not a stale or abandoned vision. The detail lives in that repo, so treat specifics below
as **NEEDS VERIFICATION** against its current state before building — but do not read this
as historical.

- **Memory-stream + reasoning, not hardcoded logic.** The v2 direction rejected the v1
  architecture of stacked hardcoded gates (prefilters, zone rules, hallucination checks,
  format rules) in favor of: everything is text in a memory stream; the model retrieves
  relevant memories and reasons; tools are its senses and actuators. The lesson that
  drove this: *stacked hardcoded logic → endless edge cases → maintenance death spiral.*
- **Personality with judgment.** A direct, dry, confident-when-grounded co-trader that
  shows receipts (retrieved memories, not fabrications), never invents prices or
  memories, and says "I don't have a memory for that — teach me?" when it doesn't know.
- **Self-correction and dot-connecting.** It records predictions and outcomes and
  revisits them; idle reflection surfaces patterns; it shares findings without hard
  calls.
- **Echo-chamber prevention.** The #1 risk of a trader+AI pair is mutual reinforcement.
  The intended defense is an **adversarial second pass** that challenges each finding
  before it reaches the human.

## Guardrails on the vision (hard rules)

- **Do not automate trade execution.** Ever, without an explicit, separate, human
  decision. The system proposes; the human executes.
- **Do not unfreeze GUGU cognition silently.** The freeze is a *policy* decision, not an
  infrastructure state. It forbids **autonomous cognition running against live/production
  data, or producing production behavior, on any repo** without explicit approval — and it
  ends only via an explicit, reviewed go-ahead after a real, reviewed data/knowledge
  corpus exists. It does **not** forbid reviewed GUGU **v2 development** in
  `thus-trading-bot`, which proceeds under its own gates: observation-only before action, a
  hard cost ceiling, per-cycle token/cost logging, and no production autonomous cognition
  without approval. Capture-only production behavior remains allowed.
- **No economic runaway.** GUGU's cost must never run away. (GUGU v1 had a token/cost-leak
  lesson — reportedly a ~$5/day Haiku monitor daemon; **NEEDS VERIFICATION**.) v2
  deployment **requires a hard cost ceiling and per-cycle token/cost logging** before it
  runs autonomously. This is a first-class system-safety rule — **same rank as "no silent
  unfreeze."**
- **Do not let a metadata layer become a trade.** No synthetic P/L-bearing rows. No
  reducer reading group/portfolio totals as truth. Raw executions are the only P/L-
  bearing rows.
- **Do not sacrifice data integrity for a feature.** A feature that risks silent loss or
  double-count is not worth shipping until the risk is designed out.

---

## Open questions (to resolve in later chapters)

- The precise, current GUGU capability roadmap and where its runtime lives relative to
  this repo (chapter 10). **NEEDS VERIFICATION.**
- The Mentor layer's concrete design — how hypotheses are formed, stored, and tested
  (chapter 11). **NEEDS VERIFICATION.**
- The Portfolio layer's long-term roadmap (risk model, multi-account, exposure) beyond
  the current summary/HWM pieces (chapter 03 / a future chapter). **NEEDS VERIFICATION.**
- How Journal grouping, Capture Bot check-ins, and GUGU memory reconcile into one
  retrieval surface (chapters 08, 10, 11).
