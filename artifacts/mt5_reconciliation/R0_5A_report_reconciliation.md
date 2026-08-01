# R0.5A — MT5 ↔ Journal report reconciliation preview

**Date:** 2026-08-01 · **Branch:** `work/mt5-phase-a-positions-review` · **Type:** read-only,
client-side preview. **No** Supabase/Journal/products/portfolio writes, **no** import commit,
**no** MT5 writer/materializer, **nothing persisted**. Every match is confirm-gated (Phase B).

## What it does

On Positions, "ตรวจทานกับรายงาน MT5" lets the user pick an MT5 `ReportHistory*.xlsx`. The app
parses it **in the browser** (SheetJS) by reusing the existing pure section parsers
(`parseMT5Positions`, `parseMT5OpenPositions`) **without** the import modal's side effects, then
compares report evidence against the already-loaded Journal `trades[]` and renders a
reconciliation preview.

## Side-effect isolation

The parsers `parseMT5Positions`/`parseMT5OpenPositions` are already pure `(rows, products) →
{trades, errors}`. The write side effects (`onProductsChange` commission auto-tune, `onImport`,
portfolio/deposit flows) live **only** in `ExcelImportModal.processMT5File`, which is untouched.
The new `parseMt5ReportForReconciliation(file, products)` calls the pure parsers directly, so the
existing Excel Import flow (preview, dedup, commission step, balance handling, commit) is
unchanged. No fragile mode flags were threaded through the importer.

## Evidence model (in-memory only)

Report closed positions + open positions are parsed into the parser trade shape
(`mt5PositionId`, `productId` [resolved, may be null], `contractCode`, `direction`, `contracts`,
`entryPrice`, `exitPrice`, `openDateTime`, `exitDateTime`, `brokerProfit`, `commission`,
`status`). Broker figures stay separate (`brokerProfit`/`commission`) and are **never** converted
to Journal canonical P/L. Provenance (account, generated time) is parsed from the report header
rows; nothing is persisted.

## Product classes (× confidence)

- **Class A — JOURNAL_OPEN_MT5_CLOSED** — Journal says open, report proves matching position(s)
  closed. Highest urgency (red), always expanded.
- **Class B — MT5_OPEN_MISSING_JOURNAL** — report open positions with no matching Journal open.
  Freshness-qualified (stale report → "เปิดอยู่ตอนออกรายงาน"). Unresolved SSF (DELTAU26) → product-scope decision, never mapped to the DELTA stock preset.
- **Class C — MT5_CLOSED_MISSING_JOURNAL** — historical closes with no Journal record. Collapsed.
- **Class D — RECONCILED** — matches an already-closed Journal trade. Count only by default.
- Cross-cutting: **AMBIGUOUS** ("ต้องตรวจเอง"), **CONFLICT**, **STALE_SOURCE** (staging, not report).

Confidence taxonomy: `EXACT_ID_MATCH` (unavailable — Journal stores no `mt5PositionId`),
`EXACT_FIELD_MATCH`, `EXACT_AGGREGATE_MATCH`, `HIGH/LOW_CONFIDENCE_CANDIDATE`, `CONFLICT`,
`UNMATCHED`. **All matches require human confirmation before any future write.**

## Matching algorithm (per Journal trade — NOT global window grouping)

For each Journal trade, candidate pool = report closed positions with same `productId` +
`direction`, not already consumed, and `|entry − journalEntry| ≤ band`:

1. **Single exact:** one candidate with `contracts == journal.contracts` and entry within `tol` →
   `EXACT_FIELD_MATCH`.
2. **Aggregate:** bounded subset search (subset size ≤ 8, ≤ 200k combos) for subsets summing to
   `journal.contracts` with **weighted entry within `tol`** and **close-window cohesion ≤ 15 min**.
   Unique subset → `EXACT_AGGREGATE_MATCH`; >1 → **AMBIGUOUS** (never auto-chosen).
3. Matched position ids are **consumed** (in-memory) so they can't be reused by another match.

Tolerances: `tol = max(0.5, 0.05% of price)`; `band = max(2, 0.75% of price)`. The entry-band +
close-cohesion is what keeps overlapping-close-window groups separate (e.g. the GOU26 3-lot @4222
vs the 5-lot @4156, both closed 2026-07-08 21:37).

## Fixture validation (against `ReportHistory-301102520.xlsx`, verbatim ported logic)

| Fixture | Journal | Result | Confidence |
|---|---|---|---|
| S50U26 pos 306282129 | Long 15 @1069.9 open | **Class A** | EXACT_FIELD_MATCH (1 leg, exit 1095.00) |
| GOU26 306282734/306283898/306310942 | Long 3 @4222.73 open | **Class A** | EXACT_AGGREGATE_MATCH (3 legs, wexit 4098.10) |
| GOU26 306157499/306161085/306161739 | Long 5 @4156.26 closed | **Class D** | EXACT_AGGREGATE_MATCH (3 legs; separate from the 3-lot) |
| DELTAU26 306676142/308292939/310290054 | — (no Journal) | **Class B** | UNMATCHED open (product-scope decision) |

Leftover historical closes → Class C (177). Ambiguous: 0. Validation was run in node with the
exact in-app pure functions; the in-app path additionally passed a full Babel compile.

## Not in R0.5A (gated, separate `/design`)

No write actions rendered (no "ยืนยันปิด"/"เพิ่มเข้า Journal"/materialize/writer). Class A cannot
be dismissed (correctness discrepancy must stay visible for the session). Phase B — writing a
reconciled Journal trade / storing `mt5PositionId` / closing a trade from reconciliation — creates
Journal data through the existing durable writer and needs its own review.
