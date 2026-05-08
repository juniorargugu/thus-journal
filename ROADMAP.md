# THUS Journal — Roadmap

This file tracks design decisions and deferred work. It is **not** a feature backlog;
it is the canonical record of *why we chose what we chose* so future work doesn't
re-litigate settled questions.

---

## Current state (2026-05-08)

Single-file React SPA in `index.html`, persisted via Supabase (`trades`, `portfolio`,
`products`, `notes`, `user_data`, `portfolio_summary`, `trade_events`). Persistence
hardening landed in commit `f03ed03` (hydration race fix, optimistic concurrency,
serialized writes per resource, divergence-preserving reconcile-delete).

Two P0 fixes follow that hardening:
- **P0-1** — `db.saveTrades` no longer short-circuits on empty trade arrays, so
  deleting your last trade now persists.
- **P0-2** — old Merge UI disabled (see below).

---

## Future: Trade Grouping / Thesis Grouping

### Why the old Merge was disabled

The previous Merge implementation collapsed multiple closed trades into a single
new "merged" trade row, then tagged the original sub-trades with `_hiddenByMerge:true`.
That flag was **written but never read**. Every reducer that walks `trades` for
P/L — `realizedPL`, `calcCBStatus`, `calcWinningPL`, `reconstructStepHistory`,
`reconstructHWM`, `useEquityHWM`, `buildSummaryPayload`, `buildCanonicalMetrics`,
`Calendar.calData`, `sheetsSync` — counted both the sub-trades **and** the merged
trade. Realised P/L silently doubled for every merge.

### Why we are NOT bringing it back as-is

Two repair options were considered and rejected:

1. **Destructive replacement** — delete sub-trade rows when merging. Smaller diff,
   but irreversibly loses the audit trail of how the merged position was actually
   built up (scale-in price, time spread, partial exits).
2. **Visual-only hidden flag** — make every reducer filter `!t._hiddenByMerge`.
   Wide blast radius; one missed call site silently re-introduces the double count.

Both of these treat one merged row as canonical truth. That is the wrong model.

### Future direction

Model **trade grouping**, not row-collapsing.

- Source executions remain canonical. No row is hidden, no row is deleted by a
  merge action.
- A **group** represents one trade idea / thesis / campaign / scaled position.
- A group is metadata (a `group_id` on each execution, a small `trade_groups`
  table for the thesis name, hypothesis, target, invalidation, post-mortem),
  **not** a trade record itself.
- Dashboard and analytics aggregate raw executions by group. They must either:
  - **A.** aggregate raw executions by group_id (single source of truth: executions), or
  - **B.** show both execution-level and group-level metrics explicitly,
    with a clear UI distinction between "trades" and "trade ideas".
- This avoids double-counting by construction: there is only one set of P/L-bearing
  rows (executions), and the group layer is purely descriptive.
- It also supports scale-in / scale-out / partial exits / averaged entries
  naturally — those are exactly what a group is *for*.

### Implementation gates

Do not start grouping work until **all** of these hold:
1. Core persistence is stable through ≥ 2 weeks of normal usage with no
   `[trades][write] upserted-affected=0/N` events in production logs.
2. Block 5 of the validation protocol (delete-the-last-trade) has passed at
   least once on the deployed build.
3. The `[DIAG] TEMPORARY` console logs have been removed (see "Diagnostic logs"
   below) and the validation protocol still passes without them.
4. Schema changes are designed up-front (one new table `trade_groups`, one new
   column `trades.group_id`), with RLS policies drafted before any code.

### Hard rules

- **Do not re-enable the old Merge button**, in any form, ever.
- **Do not write a flag to existing trade rows** to indicate group membership
  unless it's a real `group_id` foreign key with a referenced `trade_groups` row.
- **Do not introduce hidden rows** in any reducer.

---

## Diagnostic logs (`[DIAG] TEMPORARY`)

Several `[trades] [DIAG] TEMPORARY`-prefixed `console.warn` calls exist throughout
`index.html` (in `db.loadAll`, `db.saveTrades`, the hydrate effect, the trade-save
effect, `addTrade`, `addTrades`, `updateTrade`, `deleteTrade`).

### Keep until: validation passes + 24–48 h of clean production usage

These exist to give us trace-level visibility while validating the P0-1 fix and
the post-`f03ed03` hardening. Removing them prematurely makes it harder to
diagnose any save-path issue that surfaces in the first day after deploy.

### Permanent (do not remove with the rest)

`db.saveTrades` does an `.upsert(rows, {onConflict:"id"}).select()` and checks
`upsertedRows.length` against `rows.length`. The `affected===0` warning is the
only fast tripwire for silent RLS / constraint denials. **Keep this verification
permanently** unless there's a clear, logged reason to remove it (e.g., it
starts misfiring on legitimate saves).

### Removal procedure

When ready:
1. Confirm validation protocol passes on deployed build.
2. Wait 24–48 h of normal usage — no `upserted-affected=0` events, no
   `[trades][hydrate] data.trades==null`, no `[persist] CONFLICT` events
   that didn't resolve on reload.
3. Delete every `console.warn` line whose preceding comment contains the
   string `[DIAG]` and the word `TEMPORARY`.
4. Keep the `if(affected===0){return …}` line and its preceding `affected`
   computation — that's the permanent verifier, not a `[DIAG]`.

---

## Deferred items (do not start without re-confirming priority)

These came out of the audit and are **safe to defer**:

- `uid()` → `crypto.randomUUID()` migration (collision probability ≈ 0 in
  single-user usage).
- `bot_knowledge` realtime subscription `user_id` filter (no risk while user
  count = 1).
- `trade_events.user_id` column (event log is not load-bearing for any
  financial state).
- Sheets-sync auth on the Netlify proxy function (lives outside this repo).
- Playwright suite (manual smoke is sufficient at current scale).
- Magic-link auth (not a fix; a feature).

---

## Pre-existing P1 worth fixing alongside the next deploy *if* trivial

- **P1-4** — Danger Zone "ล้าง Trades" label says "Products และ Settings ยังคงอยู่",
  but the action also deletes `notes` and `user_data` (which holds patterns,
  notif_history, ai_key, tutorial_done, price_history). One-line label fix;
  no code change.

Not part of the current P0 patch pass.
