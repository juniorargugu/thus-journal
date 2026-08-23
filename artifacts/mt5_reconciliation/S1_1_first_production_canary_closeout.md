# MT5 S1.1 — First Production Canary Closeout

**Status:** `S1_1_FIRST_PRODUCTION_CANARY_CLOSED`

**Canary executed:** 2026-08-23T09:02:51Z (UTC, immediately before the first production call).
Exit code 0, one cycle, no retries.

This is a **docs-only** record. No SQL, no MT5, no code and no DB mutation were run to produce it.
Every value below is transcribed from the canary runtime's own output and from the separately
routed read-only verification — nothing here is inferred.

Raw equity and raw balance are deliberately **not** recorded. Only the quality classifications are.

---

## 1. Commits

| Fact | Value |
|---|---|
| Implementation commit | `ef2c17605c7c5acefb5ee2172bc4a200d8ec82e8` — *feat: add S1.1 account observation pipeline* |
| Approval-screen commit | `d145699476db068b22ce36e2d8bb8b067a9edb68` — *fix: make S1.1 approval preview truthful* |
| Branch | `work/mt5-s1-snapshot-lifecycle` |
| Push / deploy as part of the canary | **none** |

The approval-screen fix landed **before** the canary deliberately: the previous screen omitted
`mt5_sync_run_account` from WILL WRITE and asserted the opposite under WILL NOT, so the human
authorisation surface understated the write by a whole table. A canary may not be approved from a
screen that misstates what it does.

## 2. Canary run

| Fact | Value |
|---|---|
| `run_id` | `b8182608-fa6a-4c09-9d5c-b6ae49e4ddf0` |
| `run_seq` | **2** |
| `connector_version` | `s1.1-oneshot/0.1` |
| `policy_version` | `s1.v1` |
| `snapshot_status` | **complete** |
| `snapshot_health` | **healthy** |
| `reconcile_status` | **complete** |
| `positions_count` | **4** |
| Envelope | `ops/mt5_import/out/s1_capture_20260823085528.json` (git-ignored) |
| Approved canonical SHA-256 | `b0691034ed90a51e2d8d8d56f99d863572ca4580367ba3f2f4241164ef2e8cf9` |
| `captured_at` | 2026-08-23T08:55:28Z |
| Envelope age at write | 444 s (ceiling 900 s) |
| Envelope after the run | byte-identical; canonical SHA unchanged |

RPC sequence executed, each exactly once — 5 HTTP attempts for 5 RPCs, i.e. **zero retries**:

```
create_run → append_run_positions → append_run_account → complete_snapshot → reconcile_snapshot → EXIT
```

`APPEND` inserted 4 of 4 and `ACCOUNT` inserted 1 — both genuine first writes, not idempotent
replays. The armed path performed **zero MT5 calls**: it replayed the sealed envelope.

## 3. `mt5_sync_run_account` — the first such row in production

| Fact | Value |
|---|---|
| Rows for this run | **exactly 1** |
| `account_observation_status` | `observed` |
| `equity_quality` | `usable` |
| `balance_quality` | `usable` |
| `currency` | `THB` |
| Account timing window | **valid** — `account_read_at` = `captured_at` = 2026-08-23T08:55:28Z, age 0 s, inside the fixed 30 s contemporaneity window |
| Account fingerprint shape | **valid** |
| `failure_reason` | `null` (correct for `observed`) |

Equity is `usable` and currency is present, so this run satisfies the denominator half of the
§15 exposure-eligibility predicate. That predicate is **not** an exposure implementation — see
[`T1_T2_contract_freeze_addendum.md`](./T1_T2_contract_freeze_addendum.md) Decision 4.

## 4. Membership — exact position IDs

```
306676142
308292939
310290054
311607926
```

Four rows, four distinct IDs, 10/10 fields populated on every row, zero nulls, zero warnings.

## 5. Lifecycle result

Reconcile returned `still_open=0  missing_once=0  not_open_confirmed=2  conflicts=0`.

| Staging position | Transition |
|---|---|
| `305830528` | `missing_once` → **`not_open_confirmed`** |
| `306042718` | `missing_once` → **`not_open_confirmed`** |

Each had exactly one healthy absence before this run and zero healthy presence since baseline;
this snapshot was the second healthy absence, reaching K=2. The runtime reports **counts**, not
IDs — the ID attribution above comes from the read-only lifecycle verification, not from the
canary's stdout.

| Fact | Value |
|---|---|
| Close staging row `305514320` | **untouched** (`kind='close'` rows are never reconcile candidates) |
| Active cycle after the canary | **none** |
| Completed S1.1 runs missing an account row | **0** |
| Final `S1_1_verification_packet.sql` | **PASS** |

## 6. What did NOT happen

- no scheduler
- no continuous writer
- no third snapshot
- no second write attempt, no retry, no manual SQL repair
- no `expire_run`, no resume-account-append
- no browser/authenticated S1.1 consumer — `mt5_sync_run_account` remains `service_role` SELECT only
- no Journal trade, no `trade_groups`/G2, no checkin/capture event, no Telegram
- no push, no deploy as part of the canary

## 7. Standing constraints carried forward

The account row is **immutable and additive**. Production now holds S1.1 account facts that no
later run can amend, and there is no backfill path by design: a completed S1.1 run that lacks an
account row would be a permanent anomaly, not a repairable one. Any follow-up must reason **from**
this row rather than recreate it.

The 30 s account-read contemporaneity window is not configurable in S1.1 v1. `balance` is context
only and is never a gearing fallback for a missing or unusable `equity`.

---

**S1.1 FIRST PRODUCTION CANARY — CLOSED**
