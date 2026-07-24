# Quick Capture — design stub (NOT implemented)

**Status:** DESIGN STUB only. **Not built in this task.** Needs a separate `/design` review
before any implementation. Recorded here so the idea is not lost and is not silently
half-built.

## Problem

Mobile entry friction: opening the full app + full trade modal is heavy for logging a trade
on the go. A minimal one-screen draft flow could lower that friction.

## Proposed (to be reviewed, not enacted)

A single-screen **4-field draft** capture:

1. **Product** (from the existing product registry)
2. **Direction** (long / short)
3. **Contracts** (size)
4. **Entry** (price)

Behavior:

- Saves as a **Draft** trade **through the existing durable save path** (`db.saveTrade` /
  the same single-row durable writer used elsewhere) — **no new persistence path**, **no
  optimistic fake success**, **no synthetic rows**.
- A draft is not a position until executed through the normal flow; P/L semantics unchanged.
- No auto-execute, no MT5 involvement, no grouping.

## Hard constraints for any future build

- **Must reuse the durable save path** — no new writer, no full-array write, no optimistic
  toast without a confirmed write.
- **Raw stays canonical**; no P/L drift; no synthetic trade rows.
- Must go through **`/design`** (hot-path, silent-failure potential) before coding.
- Does **not** authorize Telegram→Journal writes, MT5 materialization, or any flag enable.

## Explicitly out of scope here

This stub does **not** implement Quick Capture, does not add UI, and does not change any
save semantics. It is a placeholder for a later, separately-reviewed design.
