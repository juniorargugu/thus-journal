"""
MT5 S1 — pure row mapper, payload validation and envelope canonicalisation.

PURE MODULE. No MetaTrader5 import, no network, no filesystem, no secrets, no clock.
Everything here is exercised by `test_s1_snapshot.py` with fixed inputs.

WHY A SEPARATE MAPPER (do NOT reuse build_rows.map_open_position)
    `build_rows.map_open_position()` emits a **staging-shaped** dict for `mt5_import_staging`
    (43-column Phase-0A table, with `raw`, `normalized_symbol`, `product_id_candidate`, `state`, …).
    The S1 append payload is a *different, narrower* shape: exactly the ten columns that
    `mt5_append_run_positions_v1` reads via `jsonb_to_recordset`. Reusing the staging row would send
    keys S1 never reads and omit `price_current` / `profit`, which the staging mapper never extracts.

S1_ROW_KEYS PROVENANCE (re-derived from the installed rev-5 packet, not from prose)
    artifacts/mt5_reconciliation/S1_rpc_packet.sql, `mt5_append_run_positions_v1`, the three
    identical `jsonb_to_recordset(p_rows) as x(...)` column lists (packet lines 328-330, 341-343,
    360-362):
        position_id bigint, symbol_raw text, side text, volume numeric, price_open numeric,
        price_current numeric, profit numeric, open_time_utc timestamptz, source_time_msc bigint,
        contract_size numeric
    `jsonb_to_recordset` SILENTLY IGNORES keys outside that list and SILENTLY YIELDS NULL for a key
    that is absent or misspelled. A typo therefore becomes a legal NULL, never an error. That is why
    `set(row) == S1_ROW_KEY_SET` is enforced exactly — no missing key, no extra key, no typo.

    `p_rows` is ONE `jsonb` parameter holding a JSON **array** (packet signature
    `mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)`) — it is NOT a PostgreSQL `jsonb[]`.

NEVER SENT PER ROW (server-derived / not S1 columns): captured_at, user_id, source_account,
row_fingerprint, normalized_symbol, product_id_candidate, instrument_class, digits, raw,
account balance / equity / currency (S1.1 — out of scope).
"""

from __future__ import annotations

import hashlib
import json
import math
import re

try:                                     # package mode: python -m ops.mt5_import.s1_snapshot
    from . import common, tz
except ImportError:                      # script mode:  python ops/mt5_import/s1_snapshot.py
    import common
    import tz

# --- exact S1 payload contract ----------------------------------------------------------------
S1_ROW_KEYS = (
    "position_id", "symbol_raw", "side", "volume", "price_open", "price_current",
    "profit", "open_time_utc", "source_time_msc", "contract_size",
)
S1_ROW_KEY_SET = frozenset(S1_ROW_KEYS)

# Columns the S1 DDL declares NOT NULL / CHECK-constrained -> a row missing these is a hard STOP.
S1_REQUIRED_KEYS = frozenset({"position_id", "symbol_raw", "side", "volume"})
# Columns the frozen contract (design B1/B2) explicitly allows to be NULL (NULL is distinct from 0).
S1_NULLABLE_KEYS = frozenset({
    "price_open", "price_current", "profit", "open_time_utc", "source_time_msc", "contract_size",
})
# Numeric columns that must be finite when supplied (PostgreSQL numeric NaN sorts ABOVE any number,
# so `volume > 0` alone would pass NaN -- the packet adds explicit `<> 'NaN'` CHECKs).
S1_NUMERIC_KEYS = ("volume", "price_open", "price_current", "profit", "contract_size")

SIDE_DOMAIN = ("buy", "sell")

# MT5 position attributes we read. `identifier` is POSITION_IDENTIFIER (stable across partial
# fills); `ticket` is the fallback the Phase-0A mapper already uses (build_rows.py:87).
_MT5_PRICE_CURRENT = "price_current"
_MT5_PROFIT = "profit"

_ISO_Z_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

ENVELOPE_FORMAT = "mt5.s1.oneshot.envelope/1"
# EVERY key below is write-relevant and is covered by the canonical SHA-256. The hash is
# deliberately NOT stored inside the envelope: the operator carries it on the command line, so
# approval is bound to the CANONICAL WRITE PAYLOAD (a self-stored hash proves nothing).
# The guarantee is semantic, not file-level: any write-relevant change to the envelope content
# changes the hash, while insignificant JSON whitespace or key-order differences do not.
ENVELOPE_KEYS = (
    "envelope_format", "run_id", "lease_token", "user_id", "source_account", "captured_at",
    "lease_seconds", "connector_version", "terminal_build", "terminal_server", "policy_version",
    "rows", "expected_count", "expected_ids",
)
ENVELOPE_KEY_SET = frozenset(ENVELOPE_KEYS)

LEASE_SECONDS_MIN = 30      # packet: p_lease_seconds not between 30 and 3600 -> ERR_BAD_INPUT
LEASE_SECONDS_MAX = 3600


# --- small pure helpers -----------------------------------------------------------------------
def _is_real_number(v) -> bool:
    """True for a finite int/float. Rejects bool (bool is an int subclass), NaN and +/-inf."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    return math.isfinite(v)


def _is_position_id(v) -> bool:
    """A stable MT5 position key: a positive integer. Rejects bool, float, 0 and negatives."""
    return isinstance(v, int) and not isinstance(v, bool) and v > 0


def side_from_type(type_code):
    """MT5 POSITION_TYPE -> the exact S1 domain 'buy'|'sell' (packet CHECK side in ('buy','sell')).
    Anything else -> None, which validation rejects. Never guesses."""
    name = common.POSITION_TYPE_NAMES.get(type_code)
    if name is None:
        return None
    low = name.lower()
    return low if low in SIDE_DOMAIN else None


def _epoch_to_iso_z(epoch_s):
    """MT5 epoch (Bangkok wall-clock mislabelled UTC) -> true-UTC RFC3339 'Z', or None.
    Epoch 0/None is treated as ABSENT, never as 1970 -- a fabricated timestamp is worse than NULL."""
    if epoch_s in (None, "", 0):
        return None
    try:
        return tz.utc_iso(tz.bkk_epoch_to_utc(epoch_s))
    except (TypeError, ValueError, OverflowError, OSError):
        return None


# --- mapper -----------------------------------------------------------------------------------
def map_s1_position(p: dict, symbols_meta: dict):
    """(row, missing_fields).

    `row` always carries EXACTLY S1_ROW_KEYS (validation is a separate step -- the mapper never
    drops or invents a key). `missing_fields` lists S1 keys the *MT5 structure itself* did not
    supply, so the preview can warn the operator (e.g. a terminal build without `price_current`).

    contract_size comes only from symbol_info; when symbol_info is unavailable it stays None.
    It is NEVER defaulted to 1 -- that is exactly the DELTAU26 (SSF, csize 1000) -> DELTA (stock,
    csize 1) collapse the Phase-0C delta_guard exists to prevent.
    """
    if not isinstance(p, dict):
        raise TypeError("map_s1_position expects the MT5 position as a dict (common.as_dict)")
    missing = []

    symbol = p.get("symbol")
    meta = symbols_meta.get(symbol) or {}

    pid = p.get("identifier") or p.get("ticket")

    for mt5_key, s1_key in ((_MT5_PRICE_CURRENT, "price_current"), (_MT5_PROFIT, "profit")):
        if mt5_key not in p or p.get(mt5_key) is None:
            missing.append(s1_key)

    open_time_utc = _epoch_to_iso_z(p.get("time"))
    if open_time_utc is None:
        missing.append("open_time_utc")
    if p.get("time_msc") in (None, "", 0):
        missing.append("source_time_msc")
    if meta.get("contract_size") is None:
        missing.append("contract_size")
    if p.get("price_open") is None:
        missing.append("price_open")

    row = {
        "position_id":     pid,
        "symbol_raw":      symbol,
        "side":            side_from_type(p.get("type")),
        "volume":          p.get("volume"),
        "price_open":      p.get("price_open"),
        "price_current":   p.get(_MT5_PRICE_CURRENT),
        "profit":          p.get(_MT5_PROFIT),
        "open_time_utc":   open_time_utc,
        "source_time_msc": p.get("time_msc") if p.get("time_msc") not in ("", 0) else None,
        "contract_size":   meta.get("contract_size"),
    }
    return row, missing


def sort_rows(rows):
    """Deterministic order for the sealed envelope: ascending position_id. Rows whose id is not a
    usable integer sort last but are KEPT -- validation must see and reject them, never silence."""
    return sorted(rows, key=lambda r: (0, r["position_id"]) if _is_position_id(r.get("position_id"))
                  else (1, 0))


def expected_ids_from_rows(rows):
    """Sorted, de-duplicated position ids for mt5_complete_snapshot_v1(p_expected_ids bigint[]).
    Call only on rows that already passed validate_rows() (which rejects duplicates outright)."""
    return sorted({r["position_id"] for r in rows})


# --- validation -------------------------------------------------------------------------------
def validate_rows(rows):
    """Return a list of hard errors ([] == valid). ANY error is a WHOLE-SNAPSHOT stop.

    A malformed broker position is NEVER skipped. Phase-0A could skip a key-less row
    (build_rows.py:88-89) because staging is a mutable inbox; S1 membership is immutable and
    exact, so a silently dropped row would seal a snapshot that misrepresents the account.
    """
    errors = []
    if not isinstance(rows, list):
        return ["payload is not a JSON array (list) of row objects"]

    seen = {}
    for i, row in enumerate(rows):
        loc = f"row[{i}]"
        if not isinstance(row, dict):
            errors.append(f"{loc}: not an object")
            continue

        keys = set(row.keys())
        if keys != S1_ROW_KEY_SET:
            miss = sorted(S1_ROW_KEY_SET - keys)
            extra = sorted(keys - S1_ROW_KEY_SET)
            errors.append(f"{loc}: key set mismatch (missing={miss}, unexpected={extra})")
            continue  # every other check below assumes the exact key set

        pid = row["position_id"]
        if not _is_position_id(pid):
            errors.append(f"{loc}: position_id must be a positive integer (got {pid!r})")
        else:
            if pid in seen:
                errors.append(f"{loc}: duplicate position_id {pid} (also {seen[pid]})")
            seen[pid] = loc

        sym = row["symbol_raw"]
        if not isinstance(sym, str) or not sym.strip():
            errors.append(f"{loc}: symbol_raw must be a non-blank string (got {sym!r})")

        side = row["side"]
        if side not in SIDE_DOMAIN:
            errors.append(f"{loc}: side must be exactly 'buy' or 'sell' (got {side!r})")

        vol = row["volume"]
        if not _is_real_number(vol):
            errors.append(f"{loc}: volume must be a finite number (got {vol!r})")
        elif vol <= 0:
            errors.append(f"{loc}: volume must be > 0 (got {vol!r})")

        for key in S1_NUMERIC_KEYS:
            if key == "volume":
                continue                       # already checked above (required, > 0)
            val = row[key]
            if val is None:
                continue                       # NULL is contractually allowed (design B2)
            if not _is_real_number(val):
                errors.append(f"{loc}: {key} must be a finite number or null (got {val!r})")

        msc = row["source_time_msc"]
        if msc is not None and not (isinstance(msc, int) and not isinstance(msc, bool)):
            errors.append(f"{loc}: source_time_msc must be an integer or null (got {msc!r})")

        ots = row["open_time_utc"]
        if ots is not None and not (isinstance(ots, str) and _ISO_Z_RE.match(ots)):
            errors.append(f"{loc}: open_time_utc must be 'YYYY-MM-DDTHH:MM:SSZ' or null (got {ots!r})")

    return errors


# --- envelope ---------------------------------------------------------------------------------
def build_envelope(*, run_id, lease_token, user_id, source_account, captured_at, lease_seconds,
                   connector_version, terminal_build, terminal_server, policy_version, rows):
    """Assemble the sealed observation. Rows are sorted by position_id for determinism.
    Carries NO secret, NO access token, NO .env content and NO raw MT5 object dump."""
    ordered = sort_rows(rows)
    return {
        "envelope_format":   ENVELOPE_FORMAT,
        "run_id":            run_id,
        "lease_token":       lease_token,
        "user_id":           user_id,
        "source_account":    source_account,
        "captured_at":       captured_at,
        "lease_seconds":     lease_seconds,
        "connector_version": connector_version,
        "terminal_build":    terminal_build,
        "terminal_server":   terminal_server,
        "policy_version":    policy_version,
        "rows":              ordered,
        "expected_count":    len(ordered),
        "expected_ids":      expected_ids_from_rows(ordered) if not validate_rows(ordered) else [],
    }


def canonical_envelope_bytes(env: dict) -> bytes:
    """Canonical serialisation of the WRITE-RELEVANT payload, for the SHA-256 approval binding.

    The envelope is PARSED and re-serialised canonically before hashing -- this is a hash of the
    canonical write payload, NOT of the file's raw bytes. Consequently reformatting the JSON
    (indentation, key order, trailing newline) does NOT change the hash, while ANY write-relevant
    semantic change (an id, a count, a price, captured_at, lease_seconds, ...) always does.

    Canonicalisation: exactly ENVELOPE_KEYS, recursively key-sorted, no whitespace, UTF-8.
    `allow_nan=False` makes a NaN/Infinity anywhere raise instead of emitting invalid JSON that
    PostgREST would then reject (or worse, coerce).
    """
    missing = [k for k in ENVELOPE_KEYS if k not in env]
    if missing:
        raise ValueError(f"envelope missing key(s) for hashing: {missing}")
    payload = {k: env[k] for k in ENVELOPE_KEYS}
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def envelope_sha256(env: dict) -> str:
    return hashlib.sha256(canonical_envelope_bytes(env)).hexdigest()


def validate_envelope(env):
    """Return a list of hard errors ([] == valid). Structural only -- age and hash are checked by
    the caller (they need a clock and the operator-supplied hash respectively)."""
    errors = []
    if not isinstance(env, dict):
        return ["envelope is not a JSON object"]

    keys = set(env.keys())
    if keys != ENVELOPE_KEY_SET:
        miss = sorted(ENVELOPE_KEY_SET - keys)
        extra = sorted(keys - ENVELOPE_KEY_SET)
        errors.append(f"envelope key set mismatch (missing={miss}, unexpected={extra})")
        return errors

    if env["envelope_format"] != ENVELOPE_FORMAT:
        errors.append(f"unsupported envelope_format {env['envelope_format']!r} "
                      f"(this build writes/reads {ENVELOPE_FORMAT!r})")

    for key in ("run_id", "lease_token", "user_id"):
        if not common.is_uuid(env[key]):
            errors.append(f"{key} must be a UUID")

    acct = env["source_account"]
    if not isinstance(acct, str) or not acct.strip():
        errors.append("source_account must be a non-blank string")

    cap = env["captured_at"]
    if not (isinstance(cap, str) and _ISO_Z_RE.match(cap)):
        errors.append("captured_at must be 'YYYY-MM-DDTHH:MM:SSZ'")

    lease = env["lease_seconds"]
    if not (isinstance(lease, int) and not isinstance(lease, bool)
            and LEASE_SECONDS_MIN <= lease <= LEASE_SECONDS_MAX):
        errors.append(f"lease_seconds must be an integer in [{LEASE_SECONDS_MIN},{LEASE_SECONDS_MAX}]")

    for key in ("connector_version", "policy_version"):
        val = env[key]
        if not isinstance(val, str) or not val.strip():
            errors.append(f"{key} must be a non-blank string")

    build = env["terminal_build"]
    if build is not None and not (isinstance(build, int) and not isinstance(build, bool)):
        errors.append("terminal_build must be an integer or null")
    server = env["terminal_server"]
    if server is not None and not isinstance(server, str):
        errors.append("terminal_server must be a string or null")

    rows = env["rows"]
    row_errors = validate_rows(rows)
    errors.extend(row_errors)
    if row_errors:
        return errors                       # counts/ids below are meaningless on invalid rows

    if env["expected_count"] != len(rows):
        errors.append(f"expected_count {env['expected_count']!r} != len(rows) {len(rows)}")
    want_ids = expected_ids_from_rows(rows)
    if env["expected_ids"] != want_ids:
        errors.append("expected_ids does not match the sorted unique position ids of rows")
    if [r["position_id"] for r in rows] != want_ids:
        errors.append("rows are not in ascending position_id order (envelope must be deterministic)")

    return errors
