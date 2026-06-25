# MT5 Import — `ops/mt5_import/` (Phase 0C)

Local, **read-only-first** tooling for the MT5 Auto Draft Import pipeline. Runs **on Junior's
Windows PC only**, against the local MetaTrader 5 terminal. Design of record:
[`../../artifacts/mt5_auto_draft_import/phase_0c_staging_writer_design.md`](../../artifacts/mt5_auto_draft_import/phase_0c_staging_writer_design.md).

> ⚠️ **service_role and `.env` never get committed or shipped.** The Phase 0C-0 `.gitignore`
> rules protect `.env`, key material (`*.key`/`*.pem`/`*.p12`/`*.pfx`), `*service_role*`, and
> local account-bearing dumps (`ops/mt5_import/out/`, `ops/mt5_import/*.json`). Only `*.env.example`
> (value-free) is trackable.

## Current slice: `probe.py` — 0C-1 read-only probe

**Purpose:** attach to the running MT5 terminal and print a **redacted** summary of account /
open positions / recent deals / symbol info + a timezone diagnostic, to confirm the field shapes
the later staging builder/writer will consume.

**Hard guarantees (read-only):**
- **No Supabase** — does not import/initialize any Supabase client.
- **No Supabase env** — never reads `SUPABASE_URL` or `SUPABASE_SERVICE_KEY`.
- **No service_role.** **No DB writes.** Does not touch `mt5_import_staging` / `mt5_import_cursors` /
  `mt5_import_groups`, the RPCs, `trades`/`products`/`portfolio`/`notes`/`trade_groups`, or Storage.
- **No MT5 mutation** — read-only API calls only (no order/position placed, modified, or closed).
- **No timezone conversion, no insert** — it only *reports* raw MT5 time fields.
- **No file writes by default** — optional `--out` writes a **redacted** JSON to an **ignored** path.

## Requirements
- **Windows** + **Python 3** + the **`MetaTrader5`** package (`pip install MetaTrader5`).
- The **MT5 terminal must be running and logged in** (the probe attaches with no credentials).
- If the package is missing or the terminal isn't connected, the probe **STOPs with a clear
  message and a non-zero exit** — it never fabricates data.

## Run
```sh
# default: last 7 days of deal history (bounded)
python ops/mt5_import/probe.py --days 7

# force symbol_info on specific instruments (e.g. the TFEX single-stock-future + index future)
python ops/mt5_import/probe.py --days 7 --symbols DELTAU26 GOU26

# explicit bounded window
python ops/mt5_import/probe.py --from 2026-06-01 --to 2026-06-25

# save a REDACTED JSON to an ignored local path (login masked; no secrets)
python ops/mt5_import/probe.py --days 7 --out ops/mt5_import/out/probe_20260625.json
```

## Expected output
- **ACCOUNT:** login (masked by default; `--show-login` to reveal), server, currency, `margin_mode`
  (expects `2 = RETAIL_HEDGING`).
- **HISTORY WINDOW:** the actual bounded from/to/day-count used.
- **OPEN POSITIONS:** count + per-position symbol, `ticket`, `position_id` (`identifier`), side,
  volume, `price_open`, raw time.
- **DEALS (bounded):** count + per-deal (capped sample) `deal_id`, `position_id`, symbol, type/entry,
  volume, price, profit, raw time/`time_msc`.
- **SYMBOL INFO:** symbol, `path`, `trade_contract_size`, `digits`, and a rough `instrument_class`
  **hint** (never authoritative). e.g. `DELTAU26` should show **csize 1000** (SSF), not stock csize 1.
- **TIMEZONE DIAGNOSTIC:** notes that MT5 server time = Asia/Bangkok wall-clock (+7 vs UTC); the
  writer (0C-3) converts `wall - 7h` → true UTC and keeps raw epoch/`time_msc`. The probe converts nothing.
- **SAFETY / KEY AVAILABILITY:** counts of open positions missing `position_id`/`ticket` and deals
  missing `deal_id`.

## STOP conditions
- `MetaTrader5` import fails / not on Windows → STOP (exit 2).
- `mt5.initialize()` fails (terminal not running/logged in) → STOP (exit 3).
- `account_info()` returns `None` → STOP (exit 3).
- `--days < 1` (unbounded "all history") → STOP (exit 2).
- `from >= to` → STOP (exit 2).
- `margin_mode != 2` (not hedging) → **WARN** and continue (read-only; the writer slice must re-check
  before any insert).

## Secrets / logging warning
- The probe needs **no secrets** (it attaches to the running terminal). Do **not** add Supabase or
  service_role env to this slice.
- Account login is **masked by default**; `--out` JSON also masks it.
- Never paste full `--show-login` output or raw account dumps into shared transcripts/issues.

## Next gates (NOT in this slice)
- **0C-2** — dry-run staging **row builder**: MT5 reads → exact `mt5_import_staging` row dicts
  (true-UTC conversion, idempotency keys, normalization), **printed only / no DB write**.
- **0C-3** — gated **writer**: idempotent upserts to `mt5_import_staging` + `mt5_import_cursors`
  **only**, behind `MT5_WRITE=1`, with a field-level update allowlist. Requires the `.env`/service_role
  secrets slice (protected by the 0C-0 `.gitignore` rules).
