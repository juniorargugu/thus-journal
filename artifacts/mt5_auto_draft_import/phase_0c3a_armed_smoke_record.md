# MT5 Phase 0C-3a — First Armed Smoke Record

**Status:** `PHASE_0C3A_ARMED_SMOKE_PASS`

**Smoke recorded:** 2026-06-26 (recorded from the executed smoke result; the armed writes ran
earlier the same local session — the writer's own `created_at`/`updated_at` on the stored row are
the authoritative timestamps, see *Stored row summary*).

This is a **docs-only** closeout. No SQL, no MT5, no `writer.py`, and no DB mutation were run to
produce this record.

---

## 1. Repo / app state during smoke

| Fact | Value |
|---|---|
| HEAD during smoke | `a85f0bc` (*feat: add MT5 open-only staging writer*) |
| production / origin/main app commit | `09842d7` |
| local main ahead origin/main | by 12 |
| Phase 0A schema/RLS/RPC | APPLIED & VERIFIED |
| push | none |
| deploy | none |
| code changes during smoke | none |
| commit made during smoke | none (smoke was report-only) |

---

## 2. Selected MT5 position

| Field | Value |
|---|---|
| terminal login / source_account | `301102520` |
| server | `PiSecurities-Live` |
| margin mode | `RETAIL_HEDGING` |
| selected position_id | `305830528` |
| symbol | `GOU26` |
| side | BUY |
| volume | `3.0` |
| entry / open price | `4094.97` (approx; exact `4094.9666…`) |

The second live open position `305832434` (GOU26 BUY vol 1.0) was **intentionally not written** —
the smoke targeted exactly one open via `--position-id` + `--max-write-count 1`.

---

## 3. User / RLS owner

- `user_id = b77d0426-355d-4f31-b94a-1afbe8fd49fa`
- Resolved **read-only** as the single distinct `user_id` across all 142 `trades` (single-user app;
  this is the canonical RLS owner uid). Not present in MT5 or local env — derived from the canonical
  source, not guessed.

---

## 4. Dry-run result (mandatory pre-check)

| Field | Value |
|---|---|
| mode | dry-run |
| target | `--position-id=305830528` |
| candidate open rows | 1 |
| ignored out-of-scope (NOT written) | balance: 1, unknown: 20, close: 24 |
| planned write ops | 1 |
| max-write-count | 1 |
| DB client constructed | no |
| nothing written | yes |
| source-account matched terminal | yes (no WARN) |
| candidate state | `needs_mapping` |

Exactly 1 planned open write → preconditions met → proceeded to armed write.

---

## 5. First armed write

| Field | Value |
|---|---|
| mode | armed |
| preflight existing open rows in scope | 0 |
| inserted | 1 |
| patched | 0 |
| skipped_browser_owned | 0 |
| skipped_concurrent | 0 |
| duplicate_race | 0 |
| cursor | not touched |
| deals / balance / unknown | not written |
| groups / trades | not touched |
| exit code | 0 |

---

## 6. Immediate rerun / idempotency

| Field | Value |
|---|---|
| command | same armed command |
| preflight existing open rows in scope | 1 |
| inserted | 0 |
| patched | 1 (only the 6 allow-listed fields) |
| duplicate open row created | no |
| exact key count after rerun | remained 1 |
| exit code | 0 |

The rerun took the **PATCH** path (existing row in writer-owned state `needs_mapping`), updating only
`last_seen_open_at, price, volume, mt5_time, mt5_time_msc, mt5_time_raw_epoch`. No duplicate row.

---

## 7. Verification counts (read-only), Before → After

| Metric | Before | After |
|---|---|---|
| staging exact key for pid `305830528` | 0 | 1 |
| staging open rows (user/account) | 0 | 1 |
| staging all rows (user/account) | 0 | 1 |
| `mt5_import_cursors` (user/account) | 0 | 0 |
| `mt5_import_groups` (user/account) | 0 | 0 |
| trades / products / portfolio_summary / notes / trade_groups | 142 / 1 / 1 / 1 / 0 | 142 / 1 / 1 / 1 / 0 (unchanged) |

---

## 8. Stored row summary (`mt5_import_staging`)

| Column | Value |
|---|---|
| `symbol_raw` | `GOU26` |
| `normalized_symbol` | `GOU26` |
| `position_id` | `305830528` |
| `source_account` | `301102520` |
| `kind` | `open` |
| `state` | `needs_mapping` |
| `position_state` | `open` |
| `contract_size` | `300.0` |
| `instrument_class` | `futures` |
| `product_id_candidate` | `null` |
| `side` | `buy` |
| `volume` | `3.0` |
| `price` | `4094.9666…` |
| `mt5_time` | `2026-06-25T15:51:37+00:00` |
| `open_time` | `2026-06-25T15:51:37+00:00` |
| `mt5_time_raw_epoch` | `1782427897` |

**Timezone conversion confirmed:** MT5 server wall-clock `22:51:37` (Asia/Bangkok) → true UTC
`15:51:37` (wall − 7h); raw epoch preserved. `contract_size=300.0` is the correct GOU26 futures
contract size — **not** the DELTAU26 SSF `1000` (the 1000× P/L trap was avoided).

`updated_at` bumped on the rerun (≈12s after `created_at`), proving the PATCH landed and the
`mt5_set_updated_at()` trigger fired.

---

## 9. Boundary confirmations

- no close rows inserted
- no partial rows inserted
- no balance rows inserted
- no unknown rows inserted
- no cursor row written
- no group row written
- no THUS trade created
- no product / portfolio_summary / note / trade_group change
- no RPC call (`mt5_confirm_group` / `mt5_set_leg_state` / `mt5_mark_materialized` not invoked)
- no Storage touched
- no deploy
- no `index.html` edit

---

## 10. Secret hygiene

- `SUPABASE_SERVICE_KEY` was not printed (read inside Python from the already-exported shell env;
  presence shown only as a length).
- no env dump
- no `.env` created or staged
- no generated JSON / `out/` / pycache / `.pyc` staged (all gitignored)
- working tree remained clean except the known unrelated untracked files

---

## 11. Interpretation

- The 0C-3a open-only writer is **production-safe** for current open staging writes.
- The first service_role writer path inserted exactly one staging open row and proved idempotent
  rerun behavior (no duplicate; PATCH-on-rerun).
- This does **not** create THUS trades.
- This does **not** run MT5 auto-draft / import into the Journal.
- This does **not** complete deal / cursor / reconcile functionality.

---

## 12. Still gated / not done

- second live open `305832434` remains unwritten
- 0C-3b close / partial deal writer
- 0C-3c balance + cursor
- 0C-3d lifecycle reconcile
- 0D Inbox UI
- Phase 1 materialization into THUS trades
- product resolver / mapping
- DELTAU26 product mapping
- screenshots / Storage
- scheduling / automation

---

## 13. Result

**`PHASE_0C3A_ARMED_SMOKE_PASS`** — recorded docs-only. Next gated step is the 0C-3b close/partial
deal writer design, or a deliberate pause to review product mapping / Inbox UI priorities.
