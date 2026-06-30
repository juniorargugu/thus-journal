# MT5 Phase 0C-3b — First Armed Close-Deal Smoke Record

**Status:** `PHASE_0C3B_ARMED_CLOSE_DEAL_SMOKE_PASS`

**Smoke recorded:** 2026-06-30 (recorded from the executed smoke result; the writer's own
`created_at`/`updated_at` on the stored row are the authoritative timestamps).

This is a **docs-only** closeout. No SQL, no MT5, no `writer.py`, and no DB mutation were run to
produce this record.

---

## 1. Repo / app state during smoke

| Fact | Value |
|---|---|
| HEAD during smoke | `3d0d497` (*fix: hard-stop unconfirmed MT5 deal duplicate race*) |
| origin/main during smoke | `803f138` |
| local main ahead origin/main | by 2 (`d678c80` feat + `3d0d497` fix) |
| push | none |
| deploy | none |
| commit made during smoke | none (smoke was report-only) |

---

## 2. Source-account / terminal

| Field | Value |
|---|---|
| required source_account | `301102520` |
| terminal login confirmed | `301102520` |
| server | `PiSecurities-Live` |
| margin mode | `RETAIL_HEDGING` |

Two prior armed-smoke attempts were correctly **STOPPED** by the cross-account gate when the terminal
was logged into `302099170` (required `301102520`) — no write occurred on those attempts. The
source-account guard worked as designed.

---

## 3. Selected close deal

| Field | Value |
|---|---|
| deal_id | `2141744` |
| symbol | `GOU26` |
| kind | `close` |
| side | SELL |
| volume | `1.0` |
| price | `4209.6` |
| position_id | `305514320` |
| broker_profit | `480` |
| source_account | `301102520` |

Deal `2194614` was **not** used — it belonged to account `302099170` (discovered during the prior
mismatched-terminal attempts).

---

## 4. Dry-run (mandatory pre-check)

| Field | Value |
|---|---|
| mode | dry-run |
| target | `--deal-id=2141744` |
| planned writes | 1 |
| candidate kind | close |
| state | needs_mapping |
| ignored (NOT written) | open: 3, balance: 1, unknown: 40, ineligible: 0, missing_deal_id: 0 |
| DB client constructed | no |
| service_role env read | no |
| nothing written | yes |
| source-account warning | none (terminal login matched) |

Exactly 1 planned close write → preconditions met → proceeded to armed write.

---

## 5. First armed write

| Field | Value |
|---|---|
| preflight close/partial scope | 0 |
| action | INSERT deal_id `2141744`, kind=close, state=needs_mapping |
| inserted | 1 |
| duplicate_existing | 0 |
| duplicate_race | 0 |
| duplicate_kind_mismatch | 0 |
| PATCH | none |
| cursor | not touched |
| open / balance / unknown | not written |
| groups / trades | not touched |
| exit code | 0 |

---

## 6. Immediate rerun / idempotency

| Field | Value |
|---|---|
| command | same armed command |
| preflight close/partial scope | 1 |
| action | DUPLICATE-EXISTING no-op for deal_id `2141744` |
| inserted | 0 |
| duplicate_existing | 1 |
| duplicate_race | 0 |
| duplicate_kind_mismatch | 0 |
| duplicate row created | no |
| PATCH | none |
| exact key count after rerun | remained 1 |
| exit code | 0 |

Deals are **insert-once immutable**: the rerun took the duplicate-existing no-op (pre-insert SELECT
found the same-kind row) — no PATCH, no second row.

---

## 7. Verification counts (read-only), Before → After

| Metric | Before | After |
|---|---|---|
| exact deal key `2141744` | 0 | 1 |
| deal-scope rows (close/partial) | 0 | 1 |
| staging all rows (user/account) | 1 | 2 |
| existing open row `305830528` | 1 | 1 |
| `mt5_import_cursors` | 0 | 0 |
| `mt5_import_groups` | 0 | 0 |
| trades / products / portfolio_summary / notes / trade_groups | 151 / 1 / 1 / 1 / 0 | 151 / 1 / 1 / 1 / 0 (unchanged) |

---

## 8. Stored deal row summary (no raw)

| Column | Value |
|---|---|
| `symbol_raw` | `GOU26` |
| `kind` | `close` |
| `deal_id` | `2141744` |
| `position_id` | `305514320` |
| `source_account` | `301102520` |
| `state` | `needs_mapping` |
| `contract_size` | `300.0` |
| `instrument_class` | `futures` |
| `product_id_candidate` | `null` |
| `side` | `sell` |
| `volume` | `1.0` |
| `price` | `4209.6` |
| `close_time` | `2026-06-23T02:59:11+00:00` |
| `mt5_time` | `2026-06-23T02:59:11+00:00` |
| `mt5_time_raw_epoch` | `1782208751` |
| `broker_profit` | `480.0` |
| `commission` | `-55.0` |
| `swap` | `0.0` |
| `fee` | `-3.85` |
| `order_id` | `305604099` |

**Timezone conversion confirmed:** MT5 server wall-clock `09:59:11` (Asia/Bangkok) → true UTC
`02:59:11` (wall − 7h); raw epoch preserved. `contract_size=300.0` is the correct GOU26 futures
size — **not** the DELTAU26 SSF `1000`. **`created_at == updated_at`** confirms no PATCH on the rerun
(deal immutable).

---

## 9. Boundary confirmations

- no open row written by `--scope deals`
- no balance row inserted
- no unknown row inserted
- no cursor row written
- no group row written
- no THUS trade created
- no product / portfolio_summary / note / trade_group change
- no RPC call (`mt5_confirm_group` / `mt5_set_leg_state` / `mt5_mark_materialized` not invoked)
- no Storage touched
- no deploy
- no `index.html` edit

---

## 10. Secret / raw hygiene

- `SUPABASE_SERVICE_KEY` was not printed
- no env dump
- no `raw` payload printed (verification selects excluded `raw`)
- no `.env` created or staged
- `MT5_WRITE=1` used inline for the armed command(s) only

---

## 11. Interpretation

- The 0C-3b deal writer is **production-safe** for max-1 close/partial staging writes.
- It inserted exactly one close deal row and proved idempotent duplicate-existing (no-op, immutable)
  behavior.
- Deals remain **inert staging facts**: no THUS trade, no materialization, no product mapping, no
  cursor. This is **not** a continuous importer yet (cursor deferred to 0C-3c).

---

## 12. Still gated / not done

- 0C-3c balance + cursor (`mt5_import_cursors`)
- 0C-3d lifecycle reconcile
- 0D-1 Inbox actions (confirm/dismiss/group via RPCs)
- product resolver / mapping, DELTAU26 mapping
- Phase 1 materialization into THUS trades
- screenshots / Storage
- scheduling / automation
- second open `305832434` remains unwritten

---

## 13. Result

**`PHASE_0C3B_ARMED_CLOSE_DEAL_SMOKE_PASS`** — recorded docs-only. Production `mt5_import_staging` now
holds 2 rows (open `305830528` + close `2141744`). The 0C-3b implementation + duplicate-race fix +
this closeout are ready to push as a stack when authorized.
