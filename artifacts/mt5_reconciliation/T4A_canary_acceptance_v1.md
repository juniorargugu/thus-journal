# T4A-2 Production Decision Canary — Acceptance Contract (v1)

Frozen by the T4 Rev-3 contract. This file records the assertions the future T4A-2 gate must
prove. **T4A-0 does NOT execute this canary.** The canary decision is TERMINAL and REAL: it must
be a decision Junior genuinely intends for that capture event — never synthetic.

## Terminology (frozen)

Say exactly **"capture event row"**, **"decision row"**, or **"pending head"** — never
"first row". This lexicon binds implementation tests and operator reports alike.

## Initial state (verified read-only at the gate, never assumed)

- `pending_count = 2`
- pending head = capture **A**, second pending = capture **B**, where A/B are whichever of the
  two real capture events has the earlier `(created_at, id)` — production UUID ordering is
  asserted at the gate's read-only preflight, not assumed in advance.

## After ONE terminal decision for A (via the decision RPC, source `harness`)

**A. Capture event row A unchanged** — `id`, `created_at`, `event_key`, `payload_fingerprint`
and the payload identity fields byte-equal to the pre-canary read. Zero capture mutation.

**B. Exactly one decision row for A** — `capture_event_id = A`, the selected action, exact
first-writer provenance (source and Telegram fields per the CHECK), server `created_at`,
decision id stable across re-reads.

**C. `pending_count` 2 → 1** (via `mt5_next_pending_capture_v1`).

**D. Pending head advances A → B** — the read RPC must return B. Continuing to return A is a
canary FAIL: the anti-join did not consume the decision.

**E. Same-action replay** — same decision id, `o_inserted = 0`, `o_derived_kind` NULL,
decision-row count still 1, capture event row A still unchanged, `pending_count` still 1,
pending head still B, first-writer provenance unchanged.

**F. Different-action replay** — `ERR_DECISION_CONFLICT` with the existing decision id/action,
zero mutation anywhere, pending state unchanged. (Safe in production: the conflict path writes
nothing.)

## Hard NO at the gate

No Journal write, no T4B, no bot-callback activation, no second decision, no capture mutation,
no retry after uncertainty (an uncertain RPC outcome ends the gate with evidence preserved).
