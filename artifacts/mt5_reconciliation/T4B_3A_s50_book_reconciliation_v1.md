# T4B-3A — S50 book overlap reconciliation

Status: LOCAL, UNCOMMITTED. Production read-only forensic audit. No write of any kind.
Audit run: 2026-08-26 (database `now()` 2026-08-26 13:38:35 UTC).
Source repo HEAD at audit time: a8bface04eeda090326dcef334b6d3109a66c7ac (clean).

## Question

What relationship, if any, does the open Journal `s50_next` 15-contract trade
`1783047455562` have to MT5 S50U26 positions 311607926, 312261388, 312265597?

## Subject Journal row (exact, production)

| field | value |
|---|---|
| id | `1783047455562` |
| user_id | `b77d0426-355d-4f31-b94a-1afbe8fd49fa` |
| product_id / raw.contractCode | `s50_next` / `S50U26` |
| direction / status | Long / open |
| contracts / remaining_contracts | 15 / 15 |
| entry_price | 1069.9 |
| entry_date / exit_date / note / group_id | NULL (all) |
| raw.openDateTime (user-entered) | `2026-07-03T12:00` |
| created_at (server) | `2026-07-03 05:01:38.105901+00` |
| updated_at (server) | `2026-07-03 05:01:38.105901+00` — **identical, delta 0.000000 s** |
| raw.mt5PositionId | **absent** |
| raw.setupType / preNote / preImages | `Run-Trend` / Thai free text / 1 image |
| raw.fee / commission / swap / brokerProfit | absent (all four) |
| raw.isMerged / mergedFromIds / subTrades / partialCloses | false / [] / [] / [] |

## MT5 position facts (immutable, `mt5_sync_run_positions`)

| position | symbol | side | vol | price_open | MT5 open_time_utc | first observed | runs |
|---|---|---|---|---|---|---|---|
| 311607926 | S50U26 | buy | 10.0 | 1077.5 | 2026-08-14 06:45:00+00 | run_seq 1 @ 2026-08-22 12:30:00+00 | 1,2,3,4 |
| 312261388 | S50U26 | buy | 5.0 | 1067.3 | 2026-08-24 03:36:12+00 | run_seq 3 @ 2026-08-24 15:49:06+00 | 3,4 |
| 312265597 | S50U26 | buy | 5.0 | 1069.4 | 2026-08-24 04:51:15+00 | run_seq 3 @ 2026-08-24 15:49:06+00 | 3,4 |

Detection time is NOT open time. 311607926 was executed 8 days before S1 first saw it
(S1 run 1 is the first run that ever existed). All four runs are `complete/complete/healthy`.

## Decisive evidence

The Journal row was written once on 2026-07-03 05:01:38 UTC and has never been modified
(`created_at = updated_at`, delta 0 s; no trade in the database has been created or
updated since 2026-07-07 10:31:42 UTC). The earliest of the three MT5 positions was
executed 2026-08-14 06:45:00 UTC — 42 days later. A record written and frozen before an
execution occurred cannot be a record of that execution.

## Corroboration (independent, none load-bearing on its own)

1. **Price.** No single leg and no combination equals 1069.9:
   10@1077.5=1077.50 · 5@1067.3=1067.30 · 5@1069.4=1069.40 ·
   (10+5)=1074.10 · (10+5)=1074.80 · (5+5)=1068.35 · (10+5+5)=1072.925.
   Both volume-15 combinations fail on price. Volume equality is not evidence.
2. **Position-id monotonicity.** 130 observations across three independent sources
   (Journal import cohort, `mt5_import_staging`, `mt5_sync_run_positions`) are
   monotone in (position_id, open time) with 0 ordering violations. A 2026-07-03
   execution falls between 306042718 (2026-06-30) and 306676142 (2026-07-14).
   All three candidates are ≥ 311607926.
3. **Convention.** 121 of 155 Journal trades carry `raw.mt5PositionId` (one import batch,
   2026-05-08, all closed, max id 296428724). The subject row carries none, and **no**
   Journal trade references any of the three ids anywhere in `raw`.
4. **Manual-creation markers.** Thai `preNote`, `setupType`, a pre-image, and the absence
   of all four import-only keys (fee/commission/swap/brokerProfit) match hand entry,
   1m38s after the stated 12:00 open.
5. **Staging.** `mt5_import_staging` holds 3 rows, all GOU26; zero rows for any S50 symbol
   and zero for any of the three positions. `mt5_import_groups` and `mt5_import_cursors`
   are empty. The subject row did not come through the import path.

## Classification

| position | classification | minimum evidence |
|---|---|---|
| 311607926 | PROVEN_DISTINCT | open_time_utc 2026-08-14 > frozen Journal row write 2026-07-03; price 1077.5 ≠ 1069.9; volume 10 ≠ 15 |
| 312261388 (capture A) | PROVEN_DISTINCT | open_time_utc 2026-08-24 > frozen Journal row write 2026-07-03; price 1067.3 ≠ 1069.9; volume 5 ≠ 15 |
| 312265597 (capture B) | PROVEN_DISTINCT | open_time_utc 2026-08-24 > frozen Journal row write 2026-07-03; price 1069.4 ≠ 1069.9; volume 5 ≠ 15 |

## Answer

Would promoting capture A / position 312261388 as a new canonical Journal trade knowingly
duplicate Journal trade 1783047455562?

**NO** — durable evidence proves they are distinct executions.

## Book interpretation (NOT an exposure claim)

Two separately-sourced facts, deliberately not summed:

- Recorded Journal exposure: 1 open `s50_next` trade, 15 remaining contracts (frozen 2026-07-03).
- Observed MT5 execution positions, last durable snapshot run_seq 4 @ 2026-08-24 16:06:10 UTC
  (stale): 3 open S50U26 positions totalling 20 lots.

The 15-lot Journal row has no MT5 counterpart among any position S1 has ever observed, and
311607926 (10 lots, 2026-08-14) has never been recorded in the Journal. Those are
book-completeness questions for the operator; they are not duplication and this audit does
not adjudicate them.

## Scope discipline

No generic rule is proposed or encoded. Same product does not block promotion; same volume
does not mean duplicate. The generic duplicate guarantee remains the T4B durable MT5
identity constraints (`mt5_cp_position_uk`, `mt5_cp_decision_uk`, `mt5_cp_trade_uk`,
`mt5_trades_promotion_uk`), which are installed and verified.

## Independent gate still open

Capture A's basis run is run_seq 3 (captured 2026-08-24 15:49:06 UTC); the newest run in the
database is run_seq 4 (2026-08-24 16:06:10 UTC). Evidence is ~2 days old. Book-overlap
clearance and current-presence freshness are independent gates; this audit clears only the
former.

## Write accounting

Reads only, every connection `set_session(readonly=True)`, every statement guarded and every
transaction rolled back. Post-audit counts equal the T4B-2B baseline exactly:
migrations 10 · promotions 0 · trades 155 · trade_groups 1 · capture_events 2 ·
capture_decisions 1 · sync_runs 4 · sync_run_positions 20 · import_staging 3.
No T4B function was invoked, including the read-only helpers.
