# MT5 Telegram Pipeline — T1/T2 Contract Freeze Addendum

**STATUS: FROZEN — CODEX APPROVED**

Approval date: 2026-08-23

**Created:** 2026-08-23
**Baseline commit:** `d145699476db068b22ce36e2d8bb8b067a9edb68`
**Depends on:** S1 append-only snapshot membership (frozen), S1.1 account observation
(frozen, first production canary **CLOSED** — see
[`S1_1_first_production_canary_closeout.md`](./S1_1_first_production_canary_closeout.md))

This addendum freezes **only** the load-bearing decisions that must be settled before T1 can be
implemented without painting T2–T6 into a corner. It is deliberately not an architecture
document: one paragraph per decision, then the T1 boundary.

Nothing here authorises implementation. T1 and T2 are **not** built in this task.

> **Naming collision, read this first.** The S1.1 design uses `T0 / T1 / T1.5 / T2 / T3` for the
> *timing stages inside a single broker observation* (identity guard → membership read → account
> read → capture seal → enrichment). This document uses `T1…T6` for *pipeline tasks*. They are
> unrelated numbering schemes. Where ambiguity is possible, this file says "pipeline T1" or
> "observation stage T1".

---

## Pipeline sequence

```
S1    append-only snapshot membership          DONE
S1.1  contemporaneous account observation      DONE — first production canary CLOSED
T1    trusted position-change detector         NEXT (after this freeze is reviewed)
T2    quiet window + capture_event             after T1
T3    Telegram interaction                     after T2
T4    atomic Journal promotion                 after T3
S2    deal reconstruction                      prerequisite of T6
T6    Close Report                             downstream of S2
```

---

## Decision 1 — Promotion idempotency

`capture_event.id` is the durable promotion idempotency key, and human promotion is
**promote-once**. A duplicate Telegram callback, a double tap, a retried delivery or a replayed
update must all return the *same canonical result* — never a second Journal trade and never a
second group. The durable success acknowledgement is sent only **after** the server-side
transaction commits; an optimistic acknowledgement that precedes the commit is exactly the
failure mode that produced the earlier close-position persistence bug, and it is prohibited here.
Because the key is the event rather than the message, idempotency survives Telegram-side retries
that this system neither controls nor observes.

## Decision 2 — Manual-journal dedup

MT5 **position identity** is the machine↔Journal convergence key. If a position was already
journaled manually, promotion **links** to the existing canonical Journal representation instead
of creating a duplicate. This must not be solved by symbol/time heuristics: a heuristic match is
a guess, and a wrong guess silently merges two different trade ideas or silently double-counts
one. Implementation dependency: `mt5PositionId` needs a real indexed, durable storage path before
**T4** promotion can link reliably — today it lives only inside `raw`. That dependency is a T4
prerequisite and **does not block T1 detection**, which never touches the Journal at all.

## Decision 3 — "รวม Position เดิม" availability

**No product-family schema is invented here.** T1 does not need product-family grouping at all —
it detects position-set changes and stops.

"รวม Position เดิม" is **unavailable** until the detected position has an **authoritative resolved
product / family mapping**. Family must never be inferred from a raw-symbol prefix alone: a prefix
match is a guess, and `DELTAU26` sharing four characters with another symbol is not evidence that
they are the same position idea.

Where a mapping *is* already resolved, the eligibility-count UX rule applies unchanged: exactly one
eligible open group for the same resolved family and direction → **auto-select**; more than one →
**explicit picker**, no guessing; zero → **do not show the option at all**, rather than offering an
action that cannot succeed.

The exact T3/T4 group eligibility and picker implementation is **deferred to the promotion
contract, written before T4** — not settled here.

## Decision 4 — Exposure / notional currency rule

**This supersedes the older FX-at-event proposal. MVP does not implement FX conversion.** S1.1
stores contemporaneous account `equity` / `balance` / `currency`; exposure and gearing are usable
**only** when every one of these holds: the required position facts are valid, `contract_size` is
valid, the chosen price basis is valid, account equity is `usable` and `> 0`, the notional
currency is known, and the notional currency **exactly matches** the account currency. If the
currencies differ, the result is `EXPOSURE_UNAVAILABLE_CURRENCY_MISMATCH` — no FX lookup, no
approximate conversion, no fallback. For **aggregate portfolio gross exposure**, every included
position must satisfy the predicate; if one required position cannot be validated, portfolio gross
is unavailable, because a partial sum understates gearing and a confidently-wrong gearing number
is more dangerous than no number. Per-position exposure may still be available independently
wherever its own predicate passes. **No exposure computation is implemented in this task**; this
restates and narrows the eligibility predicate in S1.1 design §15.

## Decision 5 — One denominator

The single denominator for MVP is **account equity**, never balance, taken as the contemporaneous
S1.1 equity from the relevant machine observation. Balance remains context only and is never a
gearing fallback when equity is missing or unusable — an unusable equity means *no* gearing, not
*balance-based* gearing. The same denominator definition must be used consistently for position
gearing, portfolio gross gearing, and portfolio-impact percentage wherever that metric applies, so
that two numbers on the same screen are never divided by two different things. Never substitute
current or today's equity for a historical event's denominator: the event's own observation is the
denominator, which is precisely why S1.1 stores it contemporaneously and immutably.

## Decision 6 — Close Report scope

A Close Report is generated **only** for human-confirmed / journaled position groups. Machine-only
unconfirmed detections never silently become Journal narrative — the Journal is the human's record,
and a detector must not author entries in it. T6 remains downstream of **S2 deal reconstruction**,
because a truthful close report needs deal evidence (close price, realised P/L, partial-close
structure) that snapshot membership alone cannot supply. **T1 and T2 must not depend on T6**, and
must not be designed as if T6 already existed.

## Decision 7 — Unconfirmed / skip visibility

Machine observation and Journal truth are **separate fact classes**. A `capture_event` may exist
with no promotion at all, and the state model must distinguish *explicitly skipped* ("ไม่ต้องจด" —
the human decided) from *unconfirmed* (no human decision has happened yet). Collapsing these two
into one "not journaled" state destroys the difference between a decision and a gap. Unconfirmed
machine truth must stay visible in reconciliation / inbox surfaces so the Journal can never look
complete while MT5 knows otherwise. Unconfirmed machine observations must **not** be stored as
narrative decision events — an observation is evidence, not a choice the human made.

---

## Cross-cutting rule — machine context timing

> **Store what time makes unrecoverable; derive everything else.**

T2 and T4 must preserve the machine-context references and facts that will be needed later by the
Close Report, at the moment they are still true. The S1.1 account observation is now the
authoritative contemporaneous denominator source, and it is immutable and never backfilled — so a
context reference that is not captured at event time cannot be reconstructed afterwards at any
price. Do **not** wait until T6 to begin preserving machine context. Equally, do not duplicate
values that remain derivable from an immutable reference: prefer referencing the observation over
copying its fields, and copy only what a later change of state would otherwise destroy.

---

## NEXT: T1 — trusted position-change detector

**Goal.** Detect trusted position-set changes between *healthy completed* S1/S1.1 snapshots.

**T1 is DETECTION ONLY.**

Conceptual event classes in scope:

- `NEW_POSITION`
- `POSITION_INCREASE`
- `POSITION_DECREASE`
- `POSITION_DISAPPEARED` / no-longer-open evidence, as the S1 lifecycle already permits
- `REAPPEARANCE` / conflict, where applicable

Do **not** invent event semantics that require S2 deal evidence. Specifically out of scope for T1:

- no close-price reconstruction
- no realised P/L reconstruction
- no partial-close certainty derived from inference alone
- no Journal mutation of any kind
- no Telegram prompt
- no quiet-window persistence
- no scheduler enablement

### T1 source of truth — frozen

**Source = the sealed observation fields from completed `mt5_sync_runs`, together with the
immutable `mt5_sync_run_positions` membership rows. Nothing else.**

The membership rows are immutable; a `mt5_sync_runs` row is **not** immutable as a whole — its
lifecycle/reconcile fields are written as the run progresses. What T1 may rely on is the subset
**sealed at completion** (the observation identity, `captured_at`, `run_seq`, snapshot status and
health), never the mutable operational fields.

`mt5_import_staging.position_state` is **NOT** T1's replay source and must never be treated as
historical or replayable evidence. It is a *current* operational annotation that reconcile
overwrites in place, so it carries no history: reading it as a timeline would silently invent one.
Staging lifecycle annotations may still be used for **current operational display and
diagnostics** — that is all.

### Adjacency and gaps — frozen executable rule

**T1 operates ONLY on completed runs.**

A normal delta is derived between **two consecutive completed observations** for the same
user/account, when **BOTH are healthy**.

> *Consecutive completed observations* means: there is **no other completed run** for that
> user/account with a `run_seq` between them.

If an intervening completed observation is non-healthy or suspicious, then across that gap T1
must derive **no** event and must suppress **all** T1 classes:

- `NEW_POSITION`
- `POSITION_INCREASE`
- `POSITION_DECREASE`
- `POSITION_DISAPPEARED`
- `REAPPEARANCE`
- any conflict / reappearance-derived event named separately

The next **healthy completed** observation becomes a **fresh baseline**, and delta detection
resumes from the **following healthy completed** observation.

**Failed, started or unsealed attempts** are **not** authoritative observations: they have no
completed `run_seq`, they do **not** participate in T1 adjacency, and they do **not** themselves
create a detection gap. Only a *completed but non-healthy* observation creates a gap — because
only it asserts a position set while failing to vouch for it.

An **entirely missing attempt** has no persisted evidence and therefore has no T1 semantics at
all: nothing was observed, nothing is claimed, nothing is suppressed.

A gap means the position set moved while an untrustworthy observation stood in the way, so any
delta computed across it would be a fabrication with the shape of evidence — the one failure mode
a trusted detector may not have. A fresh baseline loses information; a bridged gap invents it.

**No new append-only lifecycle table and no additional ordering column or table are introduced.**
`run_seq` on completed runs is the ordering. If more is ever needed, it is its own design with its
own review.

Reuse existing reconciliation primitives wherever that is safe rather than re-deriving lifecycle
semantics in a second place.

A `POSITION_DECREASE` observed between two adjacent healthy snapshots is evidence that volume
fell, **not** a partial close with a known price. Naming it a partial close would be exactly the
S2-dependent semantics this boundary excludes.

## T2 preview boundary

Recorded only so T1 does not foreclose it. T2 will coalesce burst changes through a quiet window,
persist `capture_event`, attach or reference contemporaneous machine context (Decision 4/5 and the
cross-cutting rule), and distinguish skip from unconfirmed (Decision 7). **T2 does not itself
promote to Journal.** T3 is the Telegram interaction; T4 is the atomic Journal promotion.

### Detection and quiet-window provenance — frozen

A quiet window can span several detections, so "the machine context" is ambiguous unless one run
is named. The provenance rules below are frozen; **no schema design beyond them is added here.**

**Every T1 detection preserves `before_run_id` and `after_run_id`.** Those two run references are
the **authoritative change evidence** — the pair of observations between which the change was
seen.

**A T2 `capture_event` that coalesces multiple detections preserves all contributing detection /
run references.** That set is the audit trail.

**`basis_run_id` = the `after_run_id` of the FINAL detection included in the quiet-window event.**
It may point to **either an S1 run or an S1.1 run** — S1.1 is opt-in per observation, so a basis
run legitimately may carry no account facts at all.

**The quiet-window TIMER closes the event.** The basis run is simply the last contributing
observation before the timer closes; **the snapshot itself does not close the window**. A snapshot
arriving after the timer belongs to the next event, not this one.

**`basis_run_id` governs final event-level portfolio / machine context:**

- if `basis_run_id` has a **usable** `mt5_sync_run_account` row → use **that run's** account facts
  for event-level equity / balance / currency;
- if it has **no** account row, or the account facts are **unusable** → the `capture_event` still
  exists (detection is not conditional on a denominator), and exposure / gearing are
  **unavailable**. **Never borrow account facts from another run.**

**For `POSITION_INCREASE` / `POSITION_DECREASE` / `POSITION_DISAPPEARED`, `before_run_id` remains
valid authoritative evidence for the prior position facts.** `basis_run_id` governs the
event-level context; it does **not** erase or replace the before-run evidence. The two answer
different questions — *what changed* is answered by the before/after pair, *what the portfolio
looked like when the event closed* is answered by the basis run.

Event-level context is drawn from one run precisely so the numerator and the denominator are
contemporaneous with each other. Mixing one run's positions with another run's equity produces a
gearing figure that was never true at any instant, which Decision 5 already forbids at the
denominator level and this contract forbids at the event level.

---

## Not authorised / not active

Continuous MT5 writer · scheduler · third snapshot · automatic polling · T4 Journal promotion ·
FX workstream · browser-facing S1.1 exposure consumer.

Each needs its own explicit operator gate and its own adversarial review.
