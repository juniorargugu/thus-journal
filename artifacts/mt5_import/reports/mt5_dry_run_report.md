# MT5 Dry-Run Import Report

**Dry-run only** — no MT5, no Supabase, no DB writes. Reuses `ops/mt5_import/build_rows.py` pure mappers.

- account (masked): `70*****56` · fingerprint `mt5:b10289f3c6a59115` · margin_mode 2 · RETAIL_HEDGING=True
- distinct rows: **6** (accepted/mapped **4**, needs_mapping **2**, rejected mapping **0**, rejected structural **0**)
- duplicates collapsed (idempotent): **1** · distinct idempotency keys: **6** · collisions: **0**
- by kind: `{'open': 4, 'close': 1, 'balance': 1}` · by mapping_status: `{'mapped': 4, 'needs_mapping': 2}`
- contract sizes: `{'DELTA': 1, 'DELTAU26': 1000, 'GOM26': 300, 'GOU26': 300}`
- **DELTAU26 guard**: PASS (csize=1000 class=ssf needs_mapping=True no_product_hint=True)

## Mapping decisions

| symbol | kind | pos_id | deal_id | status | product_id | class | csize | reason |
|---|---|---|---|---|---|---|---|---|
| GOU26 | open | 700000001 | None | **mapped** | gold_next | futures | 300 | explicit_symbol_mapping |
| GOU26 | open | 700000002 | None | **mapped** | gold_next | futures | 300 | explicit_symbol_mapping |
| GOU26 | open | 700000003 | None | **mapped** | gold_next | futures | 300 | explicit_symbol_mapping |
| GOU26 | close | 700000001 | 800000001 | **mapped** | gold_next | futures | 300 | explicit_symbol_mapping |
| DELTAU26 | open | 700000010 | None | **needs_mapping** | None | ssf | 1000 | no_reviewed_ssf_product_yet |
| None | balance | 0 | 800000002 | **needs_mapping** | None | unknown | None | no_mapping_entry_for_symbol |

## Timezone (Asia/Bangkok +7 → true UTC)

| raw_epoch | wall-clock (BKK) | stored UTC |
|---|---|---|
| 1783348200 | 2026-07-06 14:30:00 | 2026-07-06T07:30:00Z |
| 1783350300 | 2026-07-06 15:05:00 | 2026-07-06T08:05:00Z |
| 1783354800 | 2026-07-06 16:20:00 | 2026-07-06T09:20:00Z |
| 1783332900 | 2026-07-06 10:15:00 | 2026-07-06T03:15:00Z |
| 1783424700 | 2026-07-07 11:45:00 | 2026-07-07T04:45:00Z |

---
_Not the 0C staging writer. Before any real staging write: reviewed schema/RLS, explicit DB-write approval, service-vs-user role decision, Supabase write tests, rollback plan._
