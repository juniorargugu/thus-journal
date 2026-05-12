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

  *Fixed 2026-05-12: label updated to list trades, transactions, notes, daily notes,
  patterns, user_data; Products preserved.*

---

## Pivot patch (2026-05-12) — legacy archive + UI cleanup

Companion to `migrations/20260512_archive_trade_events_v1_lockdown.sql`. Applied
in one batch by request; runs entirely inside `index.html` plus one new
migration file.

### What changed

- **`tradeEvents` writer (~L333)**: converted to no-op stub. Legacy GUGU v1
  `public.trade_events` schema is `(id, created_at, event_type, symbol, tier,
  detail, message_sent, error, junior_feedback)` — has neither `user_id` nor
  `trade_id`, so every prior INSERT was a schema-mismatched failure swallowed by
  try/catch. Callers at `addTrade` / `updateTrade` retained — they now no-op.
- **`bot_knowledge_rt` realtime subscription** removed. Legacy v1 channel; the
  archived table has 80 rows, RLS on with zero policies, so DB access is already
  denied by default. No DB lockdown needed; `COMMENT ON TABLE` SQL is in the
  migration file as report-only.
- **Journal AI-mentor-note route deprecated**. `NoteFormModal` "✨ ให้ AI ช่วย"
  button removed; `apiKey` forced to `""` so dead branches in the surrounding
  state remain dead; `aiProcessNote()` annotated DEPRECATED. PageSettings dead
  `aiKey` state replaced with one-time `localStorage.removeItem("tj_ai_key")`
  on mount. Cloud-side `loadAll → ls.set("tj_ai_key", …)` hydration disabled.
  `data.aiKey` still returned by `db.loadAll` for one release — ignore.
- **HWM Equity Layer 2** Dashboard card hidden. `useEquityHWM()` definition and
  Yahoo fetch path left in place, no longer rendered. No Yahoo network call
  fires from any visible UI.
- **Trader Style Profiler** Dashboard card hidden. `traderStyle` useMemo left in
  place. Outcome-based label; revisit only with a process-based redesign.
- **Google Sheets Sync** Settings UI hidden; auto-fire on trade save disabled.
  `sheetsSync` object and Settings state remain for one release; `tj_sheets_url`
  localStorage value preserved (no involuntary delete).
- **PageNotes**: empty-state copy clarifies role (mentor lessons / rules /
  framework observations / hypotheses / quotes); `notesDidMountRef` added to
  skip the first-fire redundant write (ROADMAP P3).
- **Danger Zone "ล้าง Trades"** label corrected (P1-4 above).

### What did NOT change

- `db.saveTrades`, `db.loadAll`, `dbReady` gates, `savingRef.*` serialization,
  the `affected===0` tripwire, reconcile-delete logic.
- Persistence shape of any user-owned table.
- Capture Bot v0.1 (`checkin_events` / `checkin_tags` / `checkin_user_prefs`) is
  untouched. Journal still does not read or write any check-in table.
- `[DIAG] TEMPORARY` console.warn logs — kept until 24–48 h of clean prod
  usage as defined above.
- Merge feature — still disabled.
- No schema added for accounts / portfolios / oil / multi-market.
- No `trade_id` / `user_id` / backfill on `public.trade_events`.

### DB migration timing

`migrations/20260512_archive_trade_events_v1_lockdown.sql` is prepared but
NOT run. Run order:

1. Deploy this `index.html` patch first. Confirm trade open / close on
   production no longer produces a `[trade_events] insert failed` warning
   in DevTools.
2. THEN apply the migration in the Supabase SQL Editor.
3. Verification snippets are inline in the migration.
4. After ≥ 7 stable days and explicit approval, optionally drop
   `public.trade_events_backup_20260512` (snapshot, RLS-locked, 3066 rows).

Running the migration before step 1 risks breaking the still-deployed prior
build, which would attempt INSERTs against the now-revoked grants.

---

## Notes — future LLM retrieval design *(deferred)*

The Notes data shape (`{type, content, source, tags[], createdAt, reviewCount,
lastReviewed}`) is intentionally simple. Junior is currently underusing Notes,
so re-designing for LLM retrieval (embeddings, semantic search, structured
extraction) is **deferred** until there is real content to design around.

### Trigger to revisit

Whenever **either** of these is true:
- Junior has ≥ 20–30 real notes written by hand.
- Phase 2 review-loop work starts and needs structured Notes input.

### Don't pre-design

Specifically do not:
- add an `embedding` column or vector index on the bare assumption that semantic
  search will be needed.
- replicate the `gugu_memory` schema into Notes without a concrete consumer.
- import Capture Bot `checkin_events` into Notes automatically. Notes is for
  curated knowledge; check-ins are time-series behavioral captures.

---

## Capture Bot Day 4 prep *(reminder only — do NOT patch in Journal)*

When Capture Bot Day 4 wires `context.price_symbol` resolution for
`during_trade` check-ins, the symbol mapping for currently open Journal
positions is:

- `gold`    → TFEX gold futures (current contract code, e.g. `GOM26`),
              `market_type='futures_th'`, currency THB.
- `silver`  → TFEX silver futures (e.g. `SVFM26`), `market_type='futures_th'`, THB.
- `usdjpy`  → TFEX USDJPY futures (e.g. `USDJPYM26`), `market_type='futures_th'`, THB.
- `s50`     → TFEX SET50 futures (e.g. `S50M26`), `market_type='futures_th'`, THB.

Capture Bot must NOT alias these to spot / CFD `XAUUSD` / `XAGUSD` / spot
`USDJPY` on `live_prices`. The TFEX futures contract has its own price series;
using a spot symbol would compute a wrong unrealized P/L. When/if Junior opens
a spot / CFD trade on a Forex broker, that trade goes to a future
`trades_capture` (or equivalent) table — not to the frozen Journal `trades`
table — and Capture Bot resolves its symbol through the same future mapping.

This is purely a Capture Bot concern; no Journal change is required.

---

## Navigation / URL State Audit — *deferred*

Junior observed that changing THUS Journal menu tabs does not change the
browser URL and sometimes state feels remembered in a confusing way.

### Current understanding

- The app likely uses internal React page/tab state (a `page` state + `navItems`
  with `setActiveTab`-style handlers) rather than URL routes.
- This is acceptable for the current single-file SPA. It is fast and simple,
  but has trade-offs:
  - No direct `/settings` or `/journal` deep links.
  - Browser back/forward may not match app navigation.
  - Refresh may reset to the default page.
  - Local component state can reset on tab changes (mount/unmount).
  - localStorage + Supabase hydration timing may make state feel stale/weird
    on revisit.
  - Cross-tab state can desync (two tabs open, different `page` state).

### Deferred audit trigger

- Run **only after** the pivot cleanup patch is deployed and stable for
  ≥ 3 days.
- Prefer around **2026-05-18 — 2026-05-19**, after Capture Bot Day 4 planning
  is settled.

### Future audit scope

- Active `page` / tab state, where it lives, and how it changes.
- `navItems` and `setActiveTab` handlers.
- Whether active tab is persisted in localStorage.
- Page mount/unmount behavior and what state resets.
- `useEffect` hooks in Dashboard / Positions / Journal / Calendar / Notes /
  Settings, especially any that depend on `page` or fire on mount.
- Supabase hydration timing and any race against page mount.
- localStorage cache behavior and any "stale on revisit" cases.
- Browser back/forward behavior.
- Whether **hash routing** (`#settings`, `#journal`) is a safe Level 1
  improvement (no Netlify config needed).
- Whether **full path routing** (`/settings`, `/journal`) would require
  Netlify redirects (`_redirects` or `netlify.toml`).

### Hard rule

- Audit first.
- **Do not implement routing without a separate audit and patch plan.**

---

## PageSteps dead props — *deferred cleanup*

After HWM Equity Layer 2 was hidden (2026-05-12 pivot patch), PageSteps still
receives unused Layer 2 props from `App`:

```
equityHWM, dailyPoints, l2Loading, l2Error, l2Fetched, fetchLayer2
```

This wiring is harmless (props are passed in but never read inside
`PageSteps`) and intentionally deferred.

Clean this up **only** when removing the quarantined `useEquityHWM` code,
after ≥ one stable release. Bundle: drop the hook definition, the App-level
destructure, and trim both the PageSteps and PageDashboard prop lists in one
pass.
