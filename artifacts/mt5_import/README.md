# MT5 Fixture Dry-Run Harness (v0.1)

A deterministic, **offline** bridge that converts MT5 probe/export-style input into staging-style
payloads + a validation report — **without** touching Supabase, MT5, the network, or any production
code. It is the safe rehearsal step before any real 0C staging writer.

- **Code:** [`ops/mt5_import/dry_run.py`](../../ops/mt5_import/dry_run.py),
  tests [`ops/mt5_import/test_dry_run.py`](../../ops/mt5_import/test_dry_run.py).
- **Fixtures:** [`fixtures/sample_mt5_probe.json`](./fixtures/sample_mt5_probe.json),
  [`fixtures/sample_mapping.json`](./fixtures/sample_mapping.json).
- **Sample outputs:** [`reports/mt5_dry_run_report.json`](./reports/mt5_dry_run_report.json),
  [`reports/mt5_dry_run_report.md`](./reports/mt5_dry_run_report.md).

## What it is / is NOT

- **Is:** a fixture-driven dry-run. It reuses the reviewed pure mappers in
  [`ops/mt5_import/build_rows.py`](../../ops/mt5_import/build_rows.py) (`map_open_position`, `map_deal`,
  `delta_guard`) and the Bangkok→UTC conversion in [`ops/mt5_import/tz.py`](../../ops/mt5_import/tz.py),
  then layers on class-aware product mapping, a per-record `raw_sha`, and a per-row `idempotency_key`.
- **Is NOT** the 0C staging writer. It **never** imports `staging_db`/`writer`, **never** constructs a
  Supabase client, **never** reads `SUPABASE_*`/service_role, **never** calls an RPC, **never** writes any
  DB/Storage, and **never** imports `MetaTrader5`. The only files it writes are the local report paths you
  pass via `--out`/`--summary`.

## Run

```
python ops/mt5_import/dry_run.py \
  --input   artifacts/mt5_import/fixtures/sample_mt5_probe.json \
  --mapping artifacts/mt5_import/fixtures/sample_mapping.json \
  --out     artifacts/mt5_import/reports/mt5_dry_run_report.json \
  --summary artifacts/mt5_import/reports/mt5_dry_run_report.md

python ops/mt5_import/dry_run.py --self-test      # offline tests (also: python ops/mt5_import/test_dry_run.py)
```

Requires only Python 3 stdlib (uses `zoneinfo`-free fixed +7 offset via `tz.py`). No third-party deps.

## Inputs

- **Probe fixture** (`--input`): `{ user_id, observed_at_utc, account:{login,margin_mode}, positions:[…], deals:[…] }`
  in MT5 field names (`identifier`/`ticket`, `type`, `volume`, `price_open`, `time` epoch, …). Underscore-
  prefixed keys (`_note`, `_comment`) are fixture annotations and are stripped before hashing/mapping.
- **Mapping fixture** (`--mapping`): `{ instruments: { <EXACT_SYMBOL>: {instrument_class, contract_size,
  product_id, product_contract_size, path, …} } }`. Mapping is **exact-symbol only** — the harness never
  infers a product from a symbol prefix.

## Outputs (report meaning)

- `summary` — counts: `accepted_mapped` / `needs_mapping` / `rejected_mapping` / `rejected_structural`,
  `duplicates_collapsed`, `distinct_idempotency_keys`, `by_kind`, `by_mapping_status`, `contract_sizes`.
- `mapping_decisions` — one row per record: `mapping_status` (`mapped` | `needs_mapping` | `rejected`),
  `product_id`, `instrument_class`, `contract_size`, `reason`, `idempotency_key`, `raw_sha`.
- `idempotency` — `keys` (each → its distinct `raw_sha`s), `duplicates_collapsed`, and `collisions`
  (a key mapping to >1 distinct `raw_sha` = the underlying record changed → **fatal**, CLI exit 4).
- `timezone` — Bangkok wall-clock → true UTC samples (store UTC, keep raw epoch + msc).
- `delta_guard` — proves `DELTAU26` (SSF, contract_size 1000) stays `needs_mapping` and never collapses
  onto the `DELTA` stock preset (contract_size 1).
- `accepted_rows` / `needs_mapping_rows` / `rejected_rows{mapping,structural}` — the routed rows.

## Determinism & safety rules encoded

- Same `(input, mapping)` → byte-identical report (no wall-clock/`now()` in output).
- `open` rows key idempotency on **position_id**; `deal` rows on **deal_id** (mirrors Phase 0A unique
  indexes). Identical re-runs collapse; genuine key/raw conflicts are fatal.
- Class-aware contract size: a product whose `product_contract_size` disagrees with the instrument's
  `contract_size` is **rejected** (`contract_size_class_conflict`).
- Trade **close** deals must carry a `position_id` (a **warning** if missing; balance deals legitimately
  have `position_id = 0`). Records missing their natural key (position_id / deal_id) are structurally rejected.

## CLI exit codes

- `0` — ran; report written (needs_mapping / rejects are reported, not fatal, unless `--strict`).
- `2` — bad/missing JSON or missing required fixture structure.
- `4` — idempotency_key collision (same key, different `raw_sha`).
- `5` — `--strict` and one or more rejects present.

## Before a real staging writer (must all happen first)

1. **Reviewed schema/RLS** for `mt5_import_staging` (Phase 0A is applied; re-confirm columns/indexes).
2. **Explicit DB-write approval** from Junior (this harness never writes).
3. **Service-role vs user-role decision** for the writer path (and how `user_id` is stamped for RLS).
4. **Supabase write tests** (idempotent insert, re-run no-op, conflict handling) under `BEGIN/ROLLBACK`.
5. **Rollback plan** for the writer slice.

Until then this stays a **dry-run rehearsal only**.
