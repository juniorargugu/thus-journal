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

### `--out` only accepts git-ignored / local paths
The probe **refuses** to write to a trackable path. Before writing, it validates the path with
`git check-ignore` (plus a strict `ops/mt5_import/out/` prefix fallback if git is unavailable):
- ✅ `--out ops/mt5_import/out/probe_<date>.json` — recommended (the dir is git-ignored).
- ✅ any path matching the 0C-0 ignore rules (e.g. `artifacts/mt5_auto_draft_import/0c_local_*.json`).
- ❌ `--out probe.json` at the repo root, or any other **trackable** path → STOP, **no file created**:
  `Refusing --out path because it is not git-ignored. Use ops/mt5_import/out/...`

Generated output is **local and account-bearing** (positions, deals, P/L) even though the login is
masked — **do not paste or share it** unless it has been reviewed/redacted.

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
- `--out` path is **not git-ignored** (trackable) → STOP **before any MT5 connect**, no file created (exit 2).
- invalid `--from` / `--to` (not `YYYY-MM-DD`) → STOP with a clear CLI message, **no traceback** (exit 2).
- `MetaTrader5` import fails / not on Windows → STOP (exit 2).
- `mt5.initialize()` fails (terminal not running/logged in) → STOP (exit 3).
- `account_info()` returns `None` → STOP (exit 3).
- `history_deals_get()` returns `None` **with** an MT5 error → STOP (exit 3); returns `None` with
  `RES_S_OK` → WARN + treat as zero deals (never silently misreport an empty history).
- `--days < 1` (unbounded "all history") → STOP (exit 2).
- `from >= to` → STOP (exit 2).
- `margin_mode != 2` (not hedging) → **WARN** and continue (read-only; the writer slice must re-check
  before any insert).

## Secrets / logging warning
- The probe needs **no secrets** (it attaches to the running terminal). Do **not** add Supabase or
  service_role env to this slice.
- Account login is **masked by default**; `--out` JSON also masks it.
- Never paste full `--show-login` output or raw account dumps into shared transcripts/issues.

## `build_rows.py` — 0C-2 DRY-RUN staging row builder

**Purpose:** read MT5 (read-only) and transform open positions / deals / `symbol_info` into
dictionaries shaped for `public.mt5_import_staging`, then **print** a redacted dry-run summary and
optionally write a **redacted JSON** to a git-ignored path. **Builds row dicts in memory only —
no Supabase, no DB write, no RPC.** Modules: `build_rows.py` + `common.py` (shared helpers) +
`tz.py` (Bangkok→UTC).

**Identity (CLI, NOT `.env`):** rows need `user_id` + `source_account`, so a live run requires:
- `--user-id <uuid>` — the THUS auth uid (UUID-validated); stamps `staging.user_id` for browser RLS.
- `--source-account <text>` — the MT5 login / source_account (non-empty). The run **warns** if it
  doesn't match the terminal login (the writer slice will hard-STOP on a mismatch).

```sh
# pure-logic self-tests (no MT5, no DB): tz conversion, UUID, --out guard, DELTAU26 guard, skips
python ops/mt5_import/build_rows.py --self-test
python ops/mt5_import/tz.py            # tz self-check only

# live dry-run (prints staging rows summary; no file written)
python ops/mt5_import/build_rows.py --days 7 --user-id <uuid> --source-account <mt5_login>

# force symbol_info + write a REDACTED JSON to the ignored out/ dir
python ops/mt5_import/build_rows.py --days 7 --user-id <uuid> --source-account <mt5_login> \
    --symbols DELTAU26 GOU26 S50U26 --out ops/mt5_import/out/rows_smoke.json
```

**Mapping rules (this slice):**
- **Open rows** (`kind='open'`) come only from `positions_get`; **require `position_id`** (else skip+count).
- **Deal rows** require `deal_id` (else skip+count): `BALANCE`→`balance` (position_id may be 0);
  trade `OUT`/`OUT_BY`→`close` (**partial-vs-full deferred** — `deal_id` keys both identically);
  trade `IN`/`INOUT` and non-trade types→`unknown` (opens are sourced from `positions_get`, not deals).
- **True-UTC conversion** in `tz.py`: stores `wall − 7h` UTC and preserves `mt5_time_raw_epoch` +
  `mt5_time_msc` + `raw`.
- **`state` — 0C-2 resolves NO products.** `state='new'` is **reserved** for rows with a reviewed,
  non-null product resolution; since `product_id_candidate` is always `null` here, **every row is
  `needs_mapping`** (DELTA *stock* included — not just futures/SSF). `state='new'` only appears once a
  future reviewed resolver supplies a safe candidate.
- **`product_id_candidate` is always `null`** in this slice (no product resolution).
- **Writer eligibility (dry-run meta, NOT staging columns):** each row carries `writer_eligible` +
  `writer_skip_reason`. Phase 0A unique indexes protect `open`(position_id), `close`/`partial`(deal_id),
  `balance`(deal_id) — but **not** `kind='unknown'`. So **`unknown` rows are dry-run inspection ONLY**
  (`writer_eligible=false`, reason `kind_unknown_not_idempotent_under_phase_0a`); a **0C-3 writer MUST
  skip them** unless a reviewed idempotency strategy / schema patch exists, and MUST drop the
  `writer_*` meta keys before any insert.
- **DELTAU26 guard:** must appear as `contract_size 1000`, class `ssf`, `state='needs_mapping'`,
  `product_id_candidate=None` — it must **never** collapse onto the DELTA stock preset (csize 1).

`--out` uses the same safe-path guard as `probe.py` (git-ignored / `ops/mt5_import/out/` only;
trackable paths refused). The dump is a **secret-free, login-masked, account-bearing local JSON** —
do not paste/share it unredacted.

## Next gates (NOT in this slice)
- **0C-3** — gated **writer**: idempotent upserts to `mt5_import_staging` + `mt5_import_cursors`
  **only**, behind `MT5_WRITE=1`. The writer **must**:
  - **hard-STOP** if `--source-account` ≠ the terminal login (cross-account guard; 0C-2 only WARNs);
  - use an **explicit field-level update allowlist** for existing open rows (`position_state`,
    `last_seen_open_at`, `price`, `volume`, `updated_at`) — **never** broad-upsert/replace an open row
    (never touch `state`/`confirmed_group_id`/`dismissed_at`/`materialized_*`);
  - **skip `writer_eligible=false` (unknown) rows** and drop the `writer_*` meta keys.
  Requires the `.env`/service_role secrets slice (protected by the 0C-0 `.gitignore` rules).
