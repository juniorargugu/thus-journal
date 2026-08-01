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

## Hardening pass (2026-08-01) — correctness fixes from adversarial review

The classifier was rebuilt as a self-contained, **fail-closed** core bracketed by
`// ── <RECON-CORE>` / `// ── </RECON-CORE>` markers and exercised by a committed deterministic
harness (`ops/mt5_reconciliation/run_fixtures.mjs`, 34 assertions, PASS). Fixes:

- **Product-key / contract-code matching (§1).** Report rows resolve to base ids (`gold`, `s50`)
  while Journal rows use `gold_next`/`s50_next` — the old `productId===productId` check silently
  produced **zero** candidates. New key order: stored `mt5PositionId` (`EXACT_ID_MATCH`) →
  exact normalized **contract code** (`GOU26===GOU26`) → base-product fallback **only** when a
  contract code is absent (`_reconBaseId` normalizes `_next`). Two present-but-different codes are
  never folded; different-size instruments (SSF csize 1000 vs stock csize 1) are blocked
  (`_reconSizeCompatible`).
- **Order independence (§3).** Two-pass, **no greedy consumption**: Pass 1 computes candidate
  leg-sets without consuming; Pass 2 rejects any leg claimed by >1 uniquely-matched trade
  (`CONFLICT`). Reversing Journal or report order yields identical output (fixtures F6–F8).
- **Fail-closed caps (§4).** Pool > `_RECON_POOL_CAP`, combo cap, and **subset-size** exhaustion
  all → `SEARCH_LIMIT` AMBIGUOUS — never a silent unique pick or silent "no evidence" (F9–F10).
- **Decimal volumes (§5).** `_reconVolEq` uses an epsilon (`0.1+0.2==0.3` matches; nearby-unequal
  does not); TFEX integers unchanged (F11).
- **No-evidence visibility (§6).** Journal-opens with no matching close surface in a `noEvidence`
  group ("ไม่พบหลักฐานปิดในรายงานนี้" — explicitly **not** "ยังเปิดอยู่จริง"), plus an audit summary
  strip (opens examined / confirmed-closed / reconciled / no-evidence / need-check).
- **Freshness truth (§7/§8).** Pure helpers `_reconReportStale` / `_reconSnapshotFresh`
  (missing/invalid timestamp = **stale-safe**, computed from `updated_at`/`created_at`, never
  `mt5_time`). Staging open group flips to "เปิดอยู่ตอน sync ครั้งล่าสุด" + amber dot when the
  snapshot is >24h old; Class B header never uses live present-tense wording on a stale report.
  Report card shows coverage window + a partial-evidence warning when a section is missing.
- **Class-C scope (§9).** Unmatched closes are split: after the earliest Journal date →
  "ปิดแล้ว แต่ยังไม่เคยบันทึก — หลังเริ่มใช้ Journal"; older / no-Journal-date →
  "ประวัติเก่ากว่า Journal / ยังไม่ได้กำหนดขอบเขต" (OUT_OF_SCOPE, not asserted debt).
- **Class-B suppression (§10).** A report open is hidden only when a Journal **open** actually
  matches (id, or exact code/base + equal volume) — not merely same product/direction. DELTAU26
  stays Class B, individually listed, product-scope decision, no create action.
- **Account authority (§11).** Expected-account **set** from distinct staging accounts; report
  account must be a member or classification is blocked. With no known account, an in-session
  React-only confirm ("รายงานนี้เป็นบัญชี … ของพี่ใช่ไหม") gates classification (never persisted).
- **Confidence copy (§12).** Internal enums stay in the model; UI shows plain Thai
  (`_reconConfTh` / `_reconReasonTh`). S50U26 is `EXACT_FIELD_MATCH`, never ID-confirmed.
- **Flag gate (§13).** The whole reconciliation entry point is behind the existing `tj_mt5_inbox`
  user flag.

**Known residual (documented, not silently dropped):** report-evidence → staging cross-suppression
(hiding a staged-open row that the loaded report proves closed) is **not** wired — the two Positions
surfaces read independently, and lifting that state is a separate change. The Class A discrepancy
list already surfaces the same closed-vs-open truth for Journal-open trades. Full parser + **live
Journal** end-to-end (A=2/D=1/B=3) needs an authenticated browser session; the committed harness
proves the classifier against production-shaped fixtures, and the real workbook's Open Positions
section was confirmed = DELTAU26×3 (→ Class B=3).

## Action-first UI layer (2026-08-01) — presentation only, classifier frozen

The reconciliation surface was reshaped from a technical dashboard into a mass-market task inbox.
**No classifier change** — `reconcileMt5Report`, `_reconMatchKind`, `_reconFindSubsets`, tolerances,
and constants are byte-identical to the hardening commit; only pure read-only **selectors** were added
to the core (`_reconHeroState`, `_reconOpenAudit`, `_reconReportSummary`, `_reconContractLabel`,
`_reconShowStagingList`), all covered by the fixture harness (49 assertions PASS, incl. the original
34 classifier ones unchanged).

- **Hero state machine (§5):** error → account-mismatch → Class A → ambiguous → Class B → Class C →
  all-clear. One hero, one dominant yellow CTA, one compact preview, one secondary line, one
  disclosure. `_reconHeroState` is the pure selector (fixtures U1–U5).
- **Class A flow (§1/§2):** red hero "⚠ มี {n} รายการที่ต้องจัดการ", CTA "ตรวจสอบ {n} รายการ" (the only
  saturated control) expands the full evidence list; compact preview rows are plain (no card/chip/
  chevron/confidence/ID). Microcopy "ดูหลักฐานเท่านั้น — ยังไม่มีการแก้ไข Journal".
- **Contract-code labels (§3):** `_reconContractLabel` shows the Journal contract code (GOU26/S50U26)
  → matched report symbol → neutral family name — **never** the generic `currentContract` that
  produced the wrong S50M26/GOM26 (fixtures U6/U7).
- **Class B secondary (§4):** "มีอีก {n} รายการใน MT5 ที่ยังไม่มีใน Journal" + ghost "ดูรายการ";
  grouped summary "DELTAU26 · Long — 3 รายการ · รวม 6 สัญญา"; product-scope warning preserved; no create action.
- **Separate summary scopes (§7):** current-open audit (`_reconOpenAudit`, opens only — excludes
  historical D/C and closed-ambiguous, fixture U8) vs whole-report summary (`_reconReportSummary`),
  both inside the disclosure so no raw counts sit above the fold.
- **Report/staging precedence (§8):** a loaded report is the active surface — the stale staging list is
  hidden (`_reconShowStagingList`, U9/U10) and replaced by a note; clearing the report restores it.
  With no report the stale-safe staging UI is unchanged.
- **Flag (§11):** the whole entry is behind `tj_mt5_inbox`; flag OFF renders nothing (no action, no
  hero, no staging section). No write-gate flag exposed.
- **No write controls:** no "ปิดใน Journal"/"ยืนยัน"/"เพิ่มเข้า Journal", no disabled future actions;
  the only disabled state is the file-picker during load.

## Not in R0.5A (gated, separate `/design`)

No write actions rendered (no "ยืนยันปิด"/"เพิ่มเข้า Journal"/materialize/writer). Class A cannot
be dismissed (correctness discrepancy must stay visible for the session). Phase B — writing a
reconciled Journal trade / storing `mt5PositionId` / closing a trade from reconciliation — creates
Journal data through the existing durable writer and needs its own review.
