# User-Memory Capture — Portfolio · Mentor · Pattern / S50

**Date:** 2026-07-10 · **Type:** user-memory capture (from ChatGPT/user context), **not**
repo- or live-verified. **Base:** Project Bible at `e106dfd`.

> **Provenance warning.** Everything in this document is captured from user/project memory.
> It is **not** grounded in repo files or market data. Carry the per-item confidence tags
> into any chapter that consumes this; do not silently upgrade a `CONFIRMED_FROM_USER_MEMORY`
> or `NEEDS_MARKET_DATA_SOURCE` item to fact. This artifact exists so Chapter 04 does not
> become a Journal/G2-heavy roadmap that underweights the layers that eventually feed GUGU.

## North Star reminder

> THUS is **not** building a better trading journal. THUS is building an **AI-native Trading
> Operating System** whose long-term primary consumer is **GUGU**.

Layer roles: **Journal** = memory/data · **Portfolio** = state/risk · **Mentor** =
hypothesis/reasoning · **Pattern Library** = experience-to-rule · **GUGU** consumes all.

---

## 1. Confidence tags (capture-local)

These tags are used **within this capture packet**. They map to the Bible's
`NEEDS VERIFICATION` family until grounded — see [`README.md`](./README.md) status
vocabulary. Do not treat them as `CONFIRMED`/`LIVE`.

| Tag | Meaning |
|---|---|
| `CONFIRMED_FROM_USER_MEMORY` | Confirmed by user/project memory, **not** yet grounded in repo files. |
| `NEEDS_REPO_SOURCE` | Verify against an existing/future repo artifact before it becomes authoritative. |
| `NEEDS_MARKET_DATA_SOURCE` | Trading-pattern claim to be grounded against chart/market data or captured screenshots. |
| `VISION` | Long-term direction, not scheduled. |
| `DESIGNED` | Shape/design exists conceptually, ready to become a repo doc. |
| `DEFERRED` | Intentionally postponed. |
| `GATED` | Requires explicit human approval before runtime/write/autonomous behavior. |
| `REJECTED` | Explicitly cancelled; must not be re-derived. |

---

## 2. Portfolio roadmap

### 2.1 Role
Portfolio is the **state/risk layer**. It answers: what is the trader exposed to; total
risk across open positions; realized vs unrealized P/L; how the current trade interacts
with equity, drawdown, and available risk; is the trader adding risk in the wrong emotional
or market state. It is **not** the source of trade truth — trade rows remain canonical;
Portfolio **derives** and must never invent or double-count. `CONFIRMED_FROM_USER_MEMORY`

### 2.2 What is live / known
- `portfolio` and `portfolio_summary` exist in THUS Journal.
- `portfolio_summary` had a frequent-write resource/cost issue, patched in the resource audit.
- HWM Equity / Trader Style Profiler dashboard cards were **hidden** during a pivot (not
  yet reliable enough to drive product direction).
- Portfolio is thinner than Journal/G2 in the current Bible and needs a consolidated roadmap.
  `CONFIRMED_FROM_USER_MEMORY` + `NEEDS_REPO_SOURCE`

### 2.3 Intentionally hidden / deferred (not abandoned)
Hidden because the Journal durability foundation wasn't stable enough; analytics on
unreliable trade state would mislead both user and GUGU; outcome-based "style profiling"
risks overfitting unless redesigned around process, plan-following, risk behavior, and
thesis quality. `CONFIRMED_FROM_USER_MEMORY`

### 2.4 Future roadmap
- **Risk & exposure** — exposure by product/asset-class/direction; total open risk;
  concentration; correlated exposure; futures contract-size-aware; currency-aware; real
  execution risk vs UI summaries. `VISION` / `NEEDS_REPO_SOURCE`
- **Drawdown & equity state** — balance, equity, HWM, drawdown-from-HWM, recovery progress,
  risk regime by drawdown state. `VISION` / `NEEDS_REPO_SOURCE`
- **Position sizing & risk behavior** — size vs plan; rational vs emotional scale-in; risk
  added during weak thesis; open risk vs account state. `VISION`
- **Performance attribution** — P/L by product / thesis type / mentor hypothesis / behavior
  tag / pattern-rule / plan-following vs violation. `VISION`
- **GUGU-facing context** — enable GUGU to say things like "this trade is individually
  valid, but total exposure is already high," "you're adding while the thesis is
  weakening," "realized P/L is positive but open risk is asymmetric," "this resembles prior
  drawdown behavior." `VISION`

### 2.5 Relationship to GUGU
Portfolio gives GUGU **situational awareness** (state), not just memory: total risk,
exposure, drawdown, account pressure, concentration, risk escalation, emotional risk-taking
during open positions. `CONFIRMED_FROM_USER_MEMORY`

### 2.6 Risks / gates
Raw trade rows canonical; totals derived not invented; no synthetic rows; no P/L
double-count; no hidden writes that mutate trade truth; persistence/reducer changes need
review; any GUGU risk recommendation stays **propose, not prescribe**.
`CONFIRMED_FROM_USER_MEMORY`

### 2.7 Unknowns
Priority order; whether HWM returns; whether Trader Style Profiler is redesigned or
rejected; MT5 account-state integration; multi-account support; the exact risk model GUGU
should use. `NEEDS_REPO_SOURCE` / needs user confirmation.

---

## 3. Mentor design

### 3.1 Role
Mentor is the **hypothesis/reasoning layer**: capture market views, theses, invalidation
points, observations, and lessons **without** prematurely converting them into permanent
rules. Mentor content is not a trade row, a final lesson, a market rule, a bot command, or
a backlog item — it starts as a hypothesis to be observed, tested, confirmed, invalidated,
or retired. `CONFIRMED_FROM_USER_MEMORY`

### 3.2 Why it exists
The user does weekly forward-testing / mentor-style learning. The value is preserving what
was believed at the time, what would prove it wrong, what to observe next, how it played
out, and whether it became a lesson, a false pattern, or a useful rule — so GUGU learns the
trader's evolving framework, not static textbook rules. `CONFIRMED_FROM_USER_MEMORY`

### 3.3 Mentor View structure `DESIGNED`
Preserve at least: symbol/market, direction/view, horizon, anchor/reason, what to observe,
invalidation, confidence/review status, source, date, later review outcome. Compact shape:

```text
MENTOR_VIEW
symbol:
view:
horizon:
anchor:
observe:
invalidation:
```

### 3.4 Storage approach `DESIGNED`
Fit existing note/taxonomy mechanics first (avoid a new complex UI): type = mentor
view/market hypothesis/lesson/rule (by maturity); content = structured body (symbol, view,
observe, invalidation); source = `mentor`; tags = symbol/market/timeframe/hypothesis/
invalidation/status. **Do not auto-promote a mentor observation into a permanent rule.**

### 3.5 Pre / during / post-trade capture `CONFIRMED_FROM_USER_MEMORY`
- **Pre:** thesis A/B/C, plan, entry reason, invalidation, expected behavior, risk scenario,
  mentor view if relevant.
- **During:** emotional state, thesis health, contradiction evidence, urge to exit-early /
  add / force-narrative, whether market behaves as expected.
- **Post:** exit reason, plan-followed?, mistakes, fixes, price action after exit, mentor
  hypothesis confirmed or invalidated.

### 3.6 Mentor → GUGU
GUGU should surface, not assert: "this setup resembles a mentor hypothesis you were
tracking — still valid?"; "the invalidation condition may have triggered"; "this was
captured as a hypothesis, not a proven rule — review?"; "the view said observe X, but the
market is doing Y." GUGU preserves uncertainty and review status.
`CONFIRMED_FROM_USER_MEMORY`

### 3.7 Roadmap `VISION` / `DESIGNED`
Mentor note template → hypothesis capture → hypothesis review → link views to trades → link
views to Pattern Library → track confirmed/invalidated/cancelled → GUGU recall in context →
weekly mentor review summary → mentor performance stats.

### 3.8 Risks
Treating views as permanent truth too early; losing invalidation conditions; mixing market
hypothesis with behavior lesson; GUGU over-weighting unverified observations; duplicating
knowledge across Journal/Notes/bot memory/GUGU memory. **Guardrail:** mentor content must
retain its epistemic status — hypothesis, observation, rule, lesson, rejected pattern, or
confirmed pattern. `CONFIRMED_FROM_USER_MEMORY`

---

## 4. Market Pattern Library

### 4.1 Purpose
Turn repeated market observations into structured, reviewable patterns — not free text.
Capture trigger, lesson, action, invalidation/exceptions, examples, status, source,
confidence, review history. `CONFIRMED_FROM_USER_MEMORY`

### 4.2 Entry structure `DESIGNED`
```text
PATTERN
name:
market:
timeframe:
trigger:
context:
lesson:
action:
invalidation:
example:
status:
source:
tags:
```
Minimal: `trigger:` / `lesson:` / `action:`.

### 4.3 Pattern statuses `VISION` / `DESIGNED`
`candidate` · `watch` · `confirmed` · `invalidated` · `cancelled` · `rejected` · `needs more samples`.

### 4.4 Auto-warn behavior `VISION`
Feeds GUGU + Note Activation to warn before/during trades — e.g. pre-entry "this resembles
a pattern where you got trapped; requires confirmation, don't catch the falling knife";
during-hold "the invalidation condition may be appearing; this resembles the S50 gap-down
continuation case"; post-trade "this trade may update an existing pattern — review whether
it was confirmed or invalidated."

### 4.5 Relationship to Notes / Knowledge / GUGU
Notes capture observations; Pattern Library structures repeatable market lessons; Mentor
captures hypotheses + invalidation; GUGU retrieves patterns when context matches. GUGU must
**not** invent a rule from one example — it surfaces candidates and asks for review.
`CONFIRMED_FROM_USER_MEMORY`

### 4.6 Risks
Overfitting one event into a rule; keeping false rules alive; forgetting cancelled patterns;
mixing market-structure lessons with emotional-behavior lessons; noisy over-triggering;
GUGU treating candidates as confirmed truth. **Guardrail:** a cancelled pattern must remain
searchable as **rejected knowledge** so it isn't re-derived. `CONFIRMED_FROM_USER_MEMORY`

---

## 5. S50 rules

### 5.1 Corrected S50 gap-down rule `CONFIRMED_FROM_USER_MEMORY` / `NEEDS_MARKET_DATA_SOURCE`
```text
[market_rule/s50_gap_rule]
In an uptrend, if S50 gaps down and does not recover intraday, exit immediately.
The next day can gap down again and become a cascade sell-off.
```
Worked example: `Mar 2026 S50H26: 1029 → 942`. Interpretation: the danger is not merely a
"gap" — it is **gap-down + failure to recover intraday**; waiting for a rebound can be
dangerous because the next session can gap down again; action is **immediate exit / risk
reduction**, not averaging down.

### 5.2 Relationship to no-falling-knife `CONFIRMED_FROM_USER_MEMORY`
`Strong drop = do not catch falling knife.` The S50 gap-down rule is a more specific version
of the same risk principle; it should trigger caution when the user is tempted to hold/add
during a fast downside continuation.

### 5.3 Cancelled false S50 rule `REJECTED` / `NEEDS_MARKET_DATA_SOURCE`
Explicitly cancelled false rule: `"gap up 2 days → sell-off"`. **Do not use.** Capture in
[`16_REJECTED_IDEAS.md`] (and/or the Pattern Library as a rejected pattern) so future AI
does not re-derive it:
```text
REJECTED_PATTERN
name: S50 gap-up two-days sell-off
old_rule: gap up 2 days → sell-off
status: cancelled / false pattern
reason: explicitly cancelled by user; do not use as a market rule
replacement: corrected S50 gap-down failure-to-recover rule
```

### 5.4 How GUGU should use the S50 rule `CONFIRMED_FROM_USER_MEMORY`
Contextual warning, **not** a mechanical signal. Correct: "this resembles the S50 gap-down
failure-to-recover risk — is the market recovering intraday or failing?"; "this is not the
cancelled gap-up rule — don't confuse them"; "if the gap-down failure is confirmed, risk
reduction may matter more than waiting for a rebound." Incorrect: "every gap means exit";
"gap up two days means sell"; "automatically close the trade"; "turn one historical case
into a universal signal."

---

## 6. Chapter placement

- **Chapter 04 (Complete Roadmap):** Portfolio (state/risk), Mentor (hypothesis/reasoning),
  Pattern Library (pattern/rule), S50 corrected rule + rejected false rule as concrete
  examples — each with its tag: Portfolio = `VISION`/`NEEDS_REPO_SOURCE`; Mentor =
  `DESIGNED`/`VISION`; Pattern Library = `DESIGNED`/`VISION`; S50 corrected =
  `CONFIRMED_FROM_USER_MEMORY`/`NEEDS_MARKET_DATA_SOURCE`; S50 false = `REJECTED`.
- **Chapter 11 (Mentor & Knowledge):** Mentor View structure; pre/during/post capture;
  hypothesis lifecycle; retrieval; Pattern Library structure; S50 as pattern-maturation
  example; the cancelled false pattern as rejected-knowledge example.
- **Chapter 15 (Operations):** Portfolio risk state feeds decision quality; pattern warnings
  must avoid noisy over-triggering; GUGU preserves epistemic status; autonomous action stays
  gated.
- **Chapter 16 (Rejected Ideas):** cancelled S50 "gap up 2 days → sell-off"; outcome-based
  style profiling if permanently rejected/redesigned; mentor hypotheses that later become
  false patterns.
- **Chapter 17 (Risks & Tech Debt):** Portfolio roadmap thinness; mentor hypothesis
  lifecycle not implemented; Pattern Library not formalized in repo; GUGU treating candidate
  patterns as confirmed rules; old false patterns being re-derived; overfitting from one
  historical case.

---

## 7. Open questions

**Portfolio:** HWM Equity return or stay hidden?; redesign Trader Style Profiler around
process?; which metric first for GUGU (exposure / drawdown / sizing / concentration / risk
behavior)?; multi-account?; how MT5 balance/equity syncs into Portfolio.

**Mentor:** Note type vs separate table vs structured note content?; review cadence?; link
hypotheses to trades?; how invalidated views are retained?; should GUGU proactively remind
of invalidations during open positions?

**Pattern Library:** inside Notes first or its own table?; minimum viable pattern entry?;
examples required before candidate → confirmed?; how cancelled patterns are shown so they
don't become active warnings?; warn on open positions only, or also before entries?

**S50:** is the Mar 2026 `S50H26` 1029→942 case already in THUS Notes?; is there
chart/screenshot evidence linked?; exact intraday-recovery condition for "does not
recover"?; S50 futures only or broader Thai index futures?; what tag marks the cancelled
gap-up false pattern?
