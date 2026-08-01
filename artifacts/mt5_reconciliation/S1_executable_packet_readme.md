# MT5 S1 Append-Only Executable Packet — README

**Status:** `EXECUTABLE DRAFT — UNAPPLIED / NOT RUN`. Review artifacts only. No SQL was applied, no RPC invoked, no
Supabase write, no MT5 writer run, no schedule, no deploy.
**Contract source (frozen):** `S1_append_only_snapshot_membership_design.md` — Revision 3 · SHA-256
`9902B301B3E170A7FD5AA348C9892395CEBEE129DF1B5F63FAB9F62D53CA266D` (33,189 B / 500 lines). Every SQL file records this
source hash in its migration-ledger row.
**Branch / base:** `work/mt5-s1-snapshot-lifecycle` off `origin/main = f37a0ef` (clean worktree
`C:\Users\Junior\Desktop\thus-journal-mt5-s1`).

## Files

| File | Purpose | Ledger version |
|---|---|---|
| `S1_append_only_snapshot_membership_design.md` | frozen rev-3 relational contract (copied verbatim) | — |
| `S1_schema_packet.sql` | transactional schema + Phase-0A privilege narrowing | `mt5_s1_append_only_schema_v1` |
| `S1_rpc_packet.sql` | 8 connector RPCs + 1 browser RPC + 3 internal helpers | `mt5_s1_append_only_rpc_v1` |
| `S1_verification_packet.sql` | 26 rollback-wrapped fixtures (executable, **NOT RUN**) | — |
| `S1_rollback_packet.sql` | ledger-guarded transactional revert | — |
| `S1_executable_packet_readme.md` | this file | — |

**Apply order (future, approval-gated, disposable DB first):** schema packet → RPC packet → verification packet (must
reach the final PASS notice) → only then a production apply. The RPC packet's preflight refuses to run unless the schema
ledger row exists with the exact recorded checksum + source hash.

## Migration ledger & exact-definition strategy

`public.mt5_schema_migrations` (version PK, description, checksum, `source_artifact_sha256`, status, `objects` jsonb,
`applied_at`, `applied_by`). It is **created before it is queried**, records **separate** schema/RPC versions, and each
packet **records success only at the very end** (the ledger `insert ... 'applied'` is the last statement before
`commit`). Compatibility is proven by **exact catalog checks**, never name/substring markers:

- staging column names+types+nullability (`information_schema.columns`), the exact Phase-0A open-position partial-unique
  predicate (`pg_get_expr(indpred)`), absence of `last_seen_run_id`/lifecycle columns, absence of pre-existing S1 run
  tables, and — if the ledger pre-exists — its exact column shape.
- RPC preflight re-verifies the schema ledger row's exact checksum + source hash and that no S1 function name pre-exists.
- Postflights assert table ownership (`postgres`), zero application write grants on the run tables, zero `service_role`
  lifecycle-column UPDATE, function `prosecdef` + owner + `search_path=""`, all 9 exact function signatures present, and
  that staging row-count + a non-lifecycle-column checksum are unchanged across the migration.

## Schema summary

- **`mt5_sync_runs`** — uuid `id`; `(user_id, source_account)` scope; immutable `captured_at`; three dimensions
  `snapshot_status`/`reconcile_status`/`snapshot_health`; `run_seq`; `previous_positions_count`/`positions_count`;
  `position_ids_hash` + **`manifest_hash`** (full-payload aggregate); sealed `policy_version`/`policy_thresholds`;
  DB-time lease trio; audit timestamps; `warning_code`/`error_code`. Constraints: `UNIQUE (id,user_id,source_account)`
  (composite-FK target), one-active-cycle partial unique index, `run_seq` per-account unique, complete/failed/reconcile
  shape biconditionals, warning↔suspicious binding, active-state lease-non-null, hex-hash format. Indexes:
  latest-complete + healthy-history (both `run_seq DESC`, partial). RPC-only writes; `service_role` read-only SELECT;
  authenticated **no direct grant**.
- **`mt5_sync_run_positions`** — immutable facts `run_id,user_id,source_account,position_id,symbol_raw,side,volume,
  price_open,price_current,profit,open_time_utc,source_time_msc,contract_size,captured_at,row_fingerprint,created_at`;
  `PRIMARY KEY (run_id,position_id)`; **composite scope FK** `(run_id,user_id,source_account)→mt5_sync_runs
  (id,user_id,source_account) ON DELETE RESTRICT`; non-blank symbol/account, `side ∈ {buy,sell}`, `volume>0 AND <>NaN`,
  nullable numerics NULL-distinct-from-zero and `<>NaN`, `row_fingerprint` sha256-hex NOT NULL. **Immutability triggers:**
  `BEFORE UPDATE OR DELETE → raise`; `BEFORE INSERT → reject unless target run is 'started' AND row.captured_at =
  run.captured_at`. No UPDATE/DELETE grant to any role; INSERT only via the append RPC.
- **`mt5_import_staging`** — adds only `lifecycle_updated_at`, `missing_since_run_id` (composite-scope FK,
  `ON DELETE RESTRICT`); tolerant `position_state` S1 CHECK (`NOT VALID`); lifecycle + missing-since indexes. **No
  `last_seen_run_id`.**

## RPC inventory & exact signatures

| # | Function → returns |
|---|---|
| 1 | `mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text)` → `(o_ok,o_run_id,o_lease_expires_at,o_error_code)` |
| 2 | `mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer)` → `(o_ok,o_lease_expires_at,o_error_code)` |
| 3 | `mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)` → `(o_ok,o_inserted,o_error_code)` |
| 4 | `mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[])` → `(o_ok,o_run_seq,o_snapshot_health,o_error_code)` |
| 5 | `mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid)` → `(o_ok,o_still_open,o_missing_once,o_not_open_confirmed,o_conflicts,o_error_code)` |
| 6 | `mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text)` → `(o_ok,o_error_code)` |
| 7 | `mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text)` → `(o_ok,o_error_code)` |
| 8 | `mt5_expire_stale_run_v1(uuid,uuid,text)` → `(o_ok,o_error_code)` |
| 9 | `mt5_get_current_snapshot_v1(text)` → `jsonb` (browser read) |
| — | helpers `mt5_s1_policy_v1(text)`, `mt5_sha256_text_v1(text)`, `mt5_position_fingerprint_v1(...)` — postgres-only, no grant |

All `SECURITY DEFINER`, `set search_path=''`, owner `postgres`, no dynamic SQL, allowlist `{mt5_sync_runs,
mt5_sync_run_positions, mt5_import_staging}` (no Journal/product/Portfolio writes). Connector RPCs 1–8 EXECUTE →
`service_role` only; the read RPC 9 EXECUTE → `authenticated` only. Shared existing-run protocol: reject null → fetch by
`run_id` → advisory-lock on **stored** identity → re-fetch `FOR UPDATE` → `IS DISTINCT FROM` identity → terminal-state
precedence → DB-time lease → act. Identical lock key `hashtextextended(user||':'||account,0)` everywhere; every column
table-aliased; `o_`-prefixed result columns.

## Read-RPC response contract

`mt5_get_current_snapshot_v1(source_account)` returns a single JSONB envelope: `{ok, error_code, freshness_state,
snapshot:{run_id, source_account, snapshot_status, reconcile_status, snapshot_health, snapshot_completed_at,
positions_count, warning_code, freshness_state}, positions:[{position_id, symbol_raw, side, volume, price_open,
price_current, profit, open_time_utc, source_time_msc, contract_size, captured_at}]}`. Identity from `auth.uid()` (no
caller `user_id`); latest completed observation by `run_seq DESC` then health+freshness (`clock_timestamp() -
captured_at` vs sealed `freshness_seconds`); **positions only when healthy+fresh**; `freshness_state` ∈ `fresh /
suspicious / stale / no_snapshot`; **no** lease/hashes/raw errors/policy internals/terminal internals exposed. Never
falls back to staging `kind='open'`.

## Phase-0A staging privilege matrix (before → after) — derived from the real writer

Ground truth: `ops/mt5_import/writer.py` `PATCH_ALLOWLIST = ("last_seen_open_at","price","volume","mt5_time",
"mt5_time_msc","mt5_time_raw_epoch")`; `grep position_state ops/mt5_import/writer.py` → **no matches** (the writer never
writes lifecycle columns). So the narrowing is exact, not guessed, and cannot break ingestion.

| Grant on `mt5_import_staging` to `service_role` | Before (Phase 0A) | After (S1) |
|---|---|---|
| INSERT | all columns (broad) | column-scoped: the 40 non-`id/created_at/updated_at` columns (incl. initial `position_state`) |
| UPDATE | **all columns (broad)** | **only** `last_seen_open_at, price, volume, mt5_time, mt5_time_msc, mt5_time_raw_epoch` |
| UPDATE `position_state` / `lifecycle_updated_at` / `missing_since_run_id` | allowed (broad) | **DENIED** — lifecycle writes only via `mt5_reconcile_snapshot_v1` (definer) |
| DELETE | none | none |
| Browser (`authenticated`) lifecycle writes | none | none |

The rollback packet restores the broad Phase-0A `INSERT, UPDATE` grant. The existing 0A workflow RPCs
(`mt5_confirm_group`, etc.) are `SECURITY DEFINER` and run as `postgres`, so the UPDATE narrowing does not affect them.

## Key implementation notes (mapped to rev-3)

- **Append/seal atomicity** — append is insert-only under the shared lock; **terminal-state precedence before lease**
  (`complete→ERR_RUN_SEALED`, `failed→ERR_RUN_FAILED`, then lease); field-by-field replay via `IS DISTINCT FROM`
  (any diff, incl. NULL↔value → `ERR_POSITION_CONFLICT`); `captured_at` stamped from the run (and re-checked by the
  INSERT trigger); bounded payload (≤10k rows / ≤8 MB). Completion recomputes the ID set/count/`manifest_hash` from the
  **stored children** (client count/hash never trusted), checks scope + child-fingerprint integrity, allocates `run_seq`
  under the lock, and re-verifies all sealed evidence on replay (`ERR_REPLAY_CONFLICT`).
- **Captured-at supersession** — completion compares the run's immutable `captured_at` with the latest completed
  observation under the lock; older-or-equal → `ERR_SUPERSEDED` (never gets `run_seq`/current status).
- **Consecutive-absence K** — a set-wise CTE computes `last_present_seq` from **actual `mt5_sync_run_positions`
  membership** across eligible healthy completed runs, and `streak = count(eligible absent with run_seq >
  last_present_seq)`. A later membership presence resets the streak **even if that run's reconcile failed** (H1/H2/H3,
  fixture 15). K comes only from the run's sealed policy. Single original-state CASE (no conflict-then-promote).
- **Lifecycle** — reconcile mutates only staging `position_state`/`lifecycle_updated_at`/`missing_since_run_id`; suspicious
  runs mutate zero rows; grouped/materialized/dismissed open rows remain eligible; a duplicate open identity →
  `ERR_STAGING_INVARIANT`; a baseline pointing at a non-healthy-complete run → `ERR_BASELINE_INVALID`.

## Verification fixtures (executable, NOT RUN)

26 fixtures in `S1_verification_packet.sql`, one transaction ending in `ROLLBACK`, unique account per fixture:
1 partial-B-preserves-A · 2 failed-B-preserves-A · 3 suspicious-B (stale context + zero lifecycle mutation) · 4 healthy-C
atomic replace · 5 delayed-older-capture `ERR_SUPERSEDED` · 6 `ERR_RUN_ACTIVE` · 7 exact append replay · 8
`ERR_POSITION_CONFLICT` (value + NULL↔value) · 9 append-after-seal `ERR_RUN_SEALED` before lease · 10 immutable
UPDATE/DELETE denied · 11 valid zero · 12/13 completion replay success + conflict · 14 cross-account append denied ·
15/16 H1/H2/H3 consecutive absence + one credit · 17 conflict-not-promoted · 18 suspicious zero-mutation (via 3) · 19
previous-count-ignores-suspicious · 20 freshness-uses-captured_at · 21/22 healthy-empty + stale/suspicious no trusted
positions (via 11/3/20) · 23 direct authenticated table reads denied · 24 ingestion cannot write lifecycle columns
(value columns still writable) · 25 staging additions minimal / `last_seen_run_id` never exists · 26 expiry only on
DB-time-expired lease.

**Tests executed vs drafted:** **0 executed** — all 26 are drafted and marked executable-but-NOT-RUN. They require a
disposable Postgres with the schema+RPC packets applied and are approval-gated (no DB run authorized in this phase).

## Rollback summary

`S1_rollback_packet.sql`: operational writer-disable prerequisite (comment) → ledger + exact-checksum + owner guard →
revoke/drop the 9 RPCs + 3 helpers (exact signatures) → drop triggers/policies → **restore Phase-0A broad staging
INSERT/UPDATE** then drop the S1 staging FK/CHECK/indexes/columns → drop `mt5_sync_run_positions` (composite FK drops
with it) + guard function → drop `mt5_sync_runs` → delete only the two S1 ledger rows (drop the ledger table only if S1
created it and it is now empty) → postflight proving S1 objects gone + Phase-0A grant restored. Original staging rows and
`raw` evidence untouched. `IF EXISTS` throughout; reconciliation failure is explicitly **not** a rollback reason.

## Remaining risks / open decisions (for review)

- **`extensions.digest` dependency** — fingerprints/manifest use sha256 via `extensions.digest`; preflight requires it.
  Confirm pgcrypto lives in `extensions` on the target project (Supabase default). If not, swap to `pgcrypto` schema or
  a `digest` wrapper.
- **`reconcile_status` default `'pending'`** — the schema models `reconcile_status` as NOT NULL default `'pending'` from
  create (vs rev-4's NULL-until-complete). Internally consistent with all CHECKs and the one-active-cycle predicate;
  flagged for reviewer acceptance.
- **`mark_snapshot_failed` reason vocabulary** — implemented as `CAPTURE_FAILED/VALIDATION_FAILED/APPEND_FAILED/
  SEAL_FAILED/UNSUPPORTED_MARGIN_MODE/OPERATOR_CANCELLED` (allowlisted). rev-3 named `positions_none/identifier_invalid/
  membership_verification_failed/…`; semantically equivalent, reviewer may want the exact rev-3 strings.
- **`missing_since_run_id` for a first-miss `still_open` row** — recorded as the current run (`p_run_id`), i.e. "missing
  since first recorded", not `first_absent_run_id`. In steady operation these coincide; they diverge only after a skipped
  reconcile. K is unaffected (streak uses actual membership). Open decision: adopt `first_absent_run_id` for strict
  rev-3 §H1 provenance, or keep the "first recorded" semantics.
- **Advisory-lock hash collisions** — two accounts sharing a 64-bit key serialize needlessly (not incorrect).
- **Contract self-checksums** (`d72f7c…`, `97f4e99…`) are declared provenance constants recorded in the ledger; they are
  not recomputed from file bytes at apply time (they cannot self-contain their own hash). The **source-artifact** hash
  `9902B301…` is the authoritative gate.
- **No execution performed** — correctness of the 26 fixtures is unproven until run against a disposable database.
