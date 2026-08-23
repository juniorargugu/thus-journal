#!/usr/bin/env python3
"""
MT5 S1 — ONE-SHOT append-only snapshot adapter (preview / armed write / expiry recovery).

WHAT THIS IS
    The minimum safe path for a SINGLE S1 observation cycle:
        create_run -> append_run_positions -> complete_snapshot -> reconcile_snapshot -> exit.
    It runs once and exits. There is no loop, no daemon, no scheduler, no timer, no retry-forever.

THREE MODES (default is read-only preview)
    --preview (default)  attach to MT5, capture ONE observation, print it for human approval and
                         seal it into a local git-ignored envelope. NO database call whatsoever.
    --write              replay the APPROVED envelope's canonical payload. ZERO MT5 calls.
    --expire-run <uuid>  deliberate recovery for a crashed cycle. Calls ONLY mt5_expire_stale_run_v1.

WHY PREVIEW AND WRITE ARE SPLIT BY A FILE
    The frozen replay identity (design Part C) compares every immutable fact field-by-field,
    including NULL-vs-value. If the armed run re-read MT5 it would observe different prices and a
    retry would earn ERR_POSITION_CONFLICT -- and, worse, Junior would be approving one observation
    while a different one got sealed. The envelope makes the written payload identical to the
    previewed one, and makes every retry an exact idempotent replay.

THE STRICT BROKER READ (the reason this adapter exists)
    Phase-0A does `mt5.positions_get() or ()` (writer.py:188, probe.py:249, build_rows.py:299),
    which collapses a FAILED read into "zero open positions". Harmless for a mutable staging inbox;
    catastrophic for S1, because a first snapshot can never be flagged suspicious
    (previous_positions_count = 0, and the packet needs `v_prev >= susp_min_base(3)`), so a
    fabricated empty read would be sealed as healthy, fresh, authoritative truth and would then
    walk every open staging row toward missing_once. `read_positions_strict()` below never collapses
    the two states -- see its docstring. probe.py is OPTIONAL diagnostic context only and is NOT the
    safety authority, because it carries the same collapse.

HARD GUARANTEES
    - PREVIEW constructs NO Supabase client and reads NO SUPABASE_* / service_role env.
    - WRITE imports/derives NOTHING from MetaTrader5 (the import lives inside `_mt5_connect`, which
      only the preview path calls) -- see `--self-test` / test_s1_snapshot.py for the enforced proof.
    - Only the six allow-listed connector RPCs are reachable (s1_client.ALLOWED_RPCS).
    - NO Journal trades / trade_groups / capture_events / Telegram / scheduler.
    - S1.1 account observation is OPT-IN via --with-account-facts. Without that flag this adapter
      captures and sends NO account balance, equity or currency, and speaks envelope v1 only.
      With it, it captures the T1.5 financial sample, emits envelope v2, and appends exactly one
      immutable account row per run. The two envelope formats are mutually exclusive at the write
      gate: the S1.1 path REFUSES v1 and the S1-only path REFUSES v2.
    - No staging INSERT/PATCH: this adapter never touches the Phase-0A writer path.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone

try:                                     # package mode: python -m ops.mt5_import.s1_snapshot
    from . import common, s1_client, s1_rows, tz
except ImportError:                      # script mode:  python ops/mt5_import/s1_snapshot.py
    import common
    import s1_client
    import s1_rows
    import tz

CONNECTOR_VERSION_S1_DEFAULT = "s1-oneshot/0.1"
CONNECTOR_VERSION_DEFAULT = CONNECTOR_VERSION_S1_DEFAULT   # legacy alias (S1-only mode)
POLICY_VERSION_DEFAULT = "s1.v1"          # the ONLY version mt5_s1_policy_v1 allowlists today
LEASE_SECONDS_DEFAULT = 300               # one cycle finishes far inside this; a crash self-clears
                                          # in 5 min (a 3600s lease would block the account for 1h)
MAX_ENVELOPE_AGE_DEFAULT = 900            # 15 min of the 1800s S1 freshness window
# A preview stamps captured_at from the local clock, so a NEGATIVE age can only mean the clock moved
# (NTP step, DST-adjacent skew). A couple of seconds is normal and must not brittle-fail an approved
# observation; anything beyond that is a real anomaly and stops. The server has its own, looser
# guard (`p_captured_at > now + 5 minutes` -> ERR_CAPTURE_TIME_INVALID); this is the tighter local one.
CLOCK_SKEW_TOLERANCE_SECONDS = 5
MAX_POSITIONS_DEFAULT = 200               # sanity cap; the server caps a payload at 10000
EXPECTED_MARGIN_MODE = 2                  # MARGIN_MODE_RETAIL_HEDGING (scale-ins = distinct ids)

CONFIRM_WRITE = "WRITE_S1_SNAPSHOT"
CONFIRM_EXPIRE = "EXPIRE_STALE_RUN"
WRITE_ENV = "MT5_S1_WRITE"

STAGE_CREATE = "create_run"
STAGE_APPEND = "append"
STAGE_COMPLETE = "complete"
STAGE_RECONCILE = "reconcile"
# Cleanup reason per stage. `reconcile` is ABSENT on purpose: a failed reconcile leaves an
# authoritative complete snapshot and the contract says retry may be safe, so the adapter must
# never auto-terminalise it (mt5_mark_reconcile_failed_v1 is not even in the client allowlist).
STAGE_ACCOUNT = "append_account"                  # S1.1, between append and complete

# S1.1 reuses APPEND_FAILED deliberately: it is already the S1 reason code for the append stage,
# and an account append IS an append. No new terminal vocabulary is introduced.
STAGE_FAILED_REASON = {STAGE_APPEND: "APPEND_FAILED", STAGE_COMPLETE: "SEAL_FAILED",
                       STAGE_ACCOUNT: "APPEND_FAILED"}

# S1.1 connector namespace. The completed-run invariant (design section 13) is keyed off this
# prefix: a completed run whose connector matches 's1.1-oneshot/%' MUST carry exactly one account
# row, including when the broker account read failed.
CONNECTOR_VERSION_S11_DEFAULT = "s1.1-oneshot/0.1"


def resolve_connector_version(explicit, *, with_account_facts):
    """Resolve --connector-version BY MODE, then validate. Returns the resolved string.

    One argparse default cannot serve both modes: it silently applies the S1 namespace to an S1.1
    capture, and verification V13 would then never see the run at all (design section 13 keys the
    "completed S1.1 run MUST carry an account row" invariant off the S1.1 prefix). So the flag
    defaults to None and the DEFAULT is chosen here, after the mode is known.

    An explicitly supplied value is validated, never rewritten: correcting it silently would hide
    which mode actually ran. Called before the terminal/credential/transport is touched.
    """
    if explicit is None or not str(explicit).strip():
        return CONNECTOR_VERSION_S11_DEFAULT if with_account_facts else CONNECTOR_VERSION_S1_DEFAULT
    value = str(explicit).strip()
    err = s1_rows.connector_namespace_error(value, s11=bool(with_account_facts))
    if err:
        common.stop(err[1], code=2)
    return value

# When reconcile_status is already 'failed', mt5_reconcile_snapshot_v1 echoes the STORED error code
# rather than a live refusal (packet line 579: `coalesce(v_run.error_code,'ERR_RECONCILE_FAILED')`).
# Those codes therefore mean TERMINAL, not "pending, try again":
#   - LIFECYCLE_INVARIANT / BASELINE_INVALID / RECONCILE_FAILED / OPERATOR_CANCELLED
#       -> written by mt5_mark_reconcile_failed_v1 (packet line 733 allowlist)
#   - RECONCILE_LEASE_EXPIRED -> written by mt5_expire_stale_run_v1 (packet line 799)
#   - ERR_RECONCILE_FAILED    -> the coalesce fallback when error_code is NULL
# Every LIVE refusal from reconcile is ERR_-prefixed and distinct from these (e.g.
# ERR_BASELINE_INVALID is a live refusal; BASELINE_INVALID is the stored terminal state).
RECONCILE_TERMINAL_CODES = frozenset({
    "LIFECYCLE_INVARIANT", "BASELINE_INVALID", "RECONCILE_FAILED", "OPERATOR_CANCELLED",
    "RECONCILE_LEASE_EXPIRED", "ERR_RECONCILE_FAILED",
})

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class BrokerReadFailure(Exception):
    """The broker read did not positively establish current membership. NEVER an empty snapshot."""


# =============================================================================================
# Pure helpers (no MT5, no DB, no clock unless passed in) -- exercised by test_s1_snapshot.py
# =============================================================================================
def arming_status(*, write, confirm, envelope, envelope_sha256, write_env):
    """('preview'|'armed', None) or ('stop', reason). Reads ONLY the passed values -- the caller
    must NOT read MT5_S1_WRITE / SUPABASE_* until this returns 'armed'."""
    if not write:
        return "preview", None
    if confirm != CONFIRM_WRITE:
        return "stop", f"--write requires --confirm {CONFIRM_WRITE} (exact literal). Refusing to arm."
    if write_env != "1":
        return "stop", f"--write requires env {WRITE_ENV}=1. Refusing to arm."
    if not envelope:
        return "stop", "--write requires --envelope <path> (the approved observation). Refusing to arm."
    if not envelope_sha256:
        return "stop", ("--write requires --envelope-sha256 <full 64-hex hash> exactly as printed by "
                        "the preview. Refusing to arm.")
    if not _SHA256_RE.match(str(envelope_sha256).strip().lower()):
        return "stop", "--envelope-sha256 must be the full 64-character lowercase hex hash."
    return "armed", None


def expire_arming_status(*, confirm, write_env):
    """('armed', None) or ('stop', reason) for the recovery mode."""
    if confirm != CONFIRM_EXPIRE:
        return "stop", f"--expire-run requires --confirm {CONFIRM_EXPIRE} (exact literal)."
    if write_env != "1":
        return "stop", f"--expire-run requires env {WRITE_ENV}=1."
    return "armed", None


def parse_iso_z(value):
    """'YYYY-MM-DDTHH:MM:SSZ' -> aware UTC datetime, or None."""
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def envelope_age_seconds(captured_at, now):
    """Age in seconds of a sealed capture. None if captured_at is unparseable."""
    dt = parse_iso_z(captured_at)
    if dt is None:
        return None
    return (now - dt).total_seconds()


def hash_matches(expected_hex, actual_hex) -> bool:
    return hmac.compare_digest(str(expected_hex).strip().lower(), str(actual_hex).strip().lower())


def field_completeness(rows):
    """{s1_key: 'present/total'} over the ten S1 columns -- what the preview shows the operator."""
    total = len(rows)
    out = {}
    for key in s1_rows.S1_ROW_KEYS:
        present = sum(1 for r in rows if r.get(key) is not None)
        out[key] = f"{present}/{total}"
    return out


def collect_warnings(rows, missing_by_pid, symbols_meta):
    """Operator-facing warnings. These NEVER block a write on their own -- they exist so a human
    can refuse. Hard blockers live in s1_rows.validate_rows()."""
    warnings = []
    for row in rows:
        pid = row.get("position_id")
        sym = row.get("symbol_raw")
        for key in sorted(missing_by_pid.get(pid, ())):
            warnings.append(f"position {pid} ({sym}): MT5 did not supply {key} -> NULL")
        meta = symbols_meta.get(sym) or {}
        if not meta:
            warnings.append(f"position {pid} ({sym}): symbol_info unavailable -> contract_size NULL "
                            f"(NOT defaulted to 1)")
        csize = row.get("contract_size")
        cls = meta.get("instrument_class")
        if csize is not None and csize <= 0:
            warnings.append(f"position {pid} ({sym}): contract_size {csize!r} is not positive")
        if csize == 1 and cls in ("ssf", "futures"):
            warnings.append(f"position {pid} ({sym}): contract_size 1 on a {cls} path -- this is the "
                            f"SSF->stock collapse signature. VERIFY BEFORE APPROVING.")
    return warnings


def side_effect_preview(n_positions: int, *, s11: bool = False) -> str:
    """The human write-approval surface. It must name every table the LATER ARMED WRITE touches,
    in the mode this envelope was actually captured in.

    The two modes have different write sets, so one summary cannot serve both. Shown the S1 text,
    an S1.1 envelope under-states the write by a whole table (mt5_sync_run_account) and then
    asserts the opposite under WILL NOT -- the one thing an approval screen may never do.

    The S1 branch is a separate literal returned verbatim rather than a shared template
    with holes: adding S1.1 must not be able to perturb the S1 approval surface at all.

    DISPLAY ONLY. Nothing here participates in capture, the envelope, its canonical SHA, arming,
    or the RPC sequence.
    """
    if s11:
        # create_run -> append_run_positions -> append_run_account -> complete_snapshot ->
        # reconcile_snapshot. The account row lands BEFORE completion, so the same completion
        # seals membership and account facts together.
        return (
            "WILL WRITE  (S1.1 -- account facts ENABLED):\n"
            "  - 1 row in mt5_sync_runs (this observation)\n"
            f"  - {n_positions} immutable row(s) in mt5_sync_run_positions\n"
            "  - 1 immutable row in mt5_sync_run_account (equity / balance / currency)\n"
            "  - complete the snapshot (one completion seals membership AND the account row)\n"
            "  - reconcile the snapshot: bounded mt5_import_staging lifecycle annotation\n"
            "      (kind='open' rows for this user/account only: position_state, missing_since_run_id,\n"
            "       lifecycle_updated_at. kind='close' rows are never candidates.)\n"
            "WILL NOT:\n"
            "  - create Journal trades\n"
            "  - create trade_groups (G2)\n"
            "  - create checkin / capture events\n"
            "  - send Telegram\n"
            "  - schedule, loop or start another cycle\n"
        )
    return (
        "WILL WRITE:\n"
        "  - 1 row in mt5_sync_runs (this observation)\n"
        f"  - {n_positions} immutable row(s) in mt5_sync_run_positions\n"
        "  - bounded mt5_import_staging lifecycle annotation during reconcile\n"
        "      (kind='open' rows for this user/account only: position_state, missing_since_run_id,\n"
        "       lifecycle_updated_at. kind='close' rows are never candidates.)\n"
        "WILL NOT:\n"
        "  - create Journal trades\n"
        "  - create trade_groups (G2)\n"
        "  - create checkin / capture events\n"
        "  - send Telegram\n"
        "  - run S1.1 (no account balance / equity / currency)\n"
        "  - schedule, loop or start another cycle\n"
    )


# =============================================================================================
# Strict broker read -- the safety authority
# =============================================================================================
def read_positions_strict(mt5):
    """Return the open-position tuple ONLY when the broker read positively succeeded.

    `mt5.positions_get()` returns `()` for a genuinely flat account and `None` on error. The
    Phase-0A `or ()` idiom cannot tell those apart. Here:

      - None  -> capture `last_error()` IMMEDIATELY (before any other MT5 API call, which would
                 overwrite it) and raise BrokerReadFailure. This INCLUDES None + RES_S_OK: an
                 ambiguous empty read is exactly the fabrication risk, and unlike the deal stream
                 (writer.py:190-197, which may warn and continue) an S1 membership set has no
                 second source of truth.
      - tuple/list, including an EMPTY tuple -> the only path eligible to represent zero positions.

    Failure is an exception; success is a value. The two states therefore cannot share an internal
    representation, and no caller can accidentally treat one as the other.
    """
    positions = mt5.positions_get()
    if positions is None:
        try:
            err = mt5.last_error()
        except Exception as e:                                  # pragma: no cover - defensive
            err = f"<last_error() unavailable: {e!r}>"
        raise BrokerReadFailure(
            f"positions_get() returned None (mt5.last_error()={err!r}). Current open positions "
            f"COULD NOT BE DETERMINED. This is a hard stop even when MT5 reports RES_S_OK -- an "
            f"ambiguous read must never be sealed as a healthy empty snapshot.")
    if not isinstance(positions, (tuple, list)):
        raise BrokerReadFailure(
            f"positions_get() returned {type(positions).__name__}, expected a tuple/list. "
            f"Refusing to interpret an unknown shape as membership truth.")
    return tuple(positions)


# =============================================================================================
# Capture (PREVIEW ONLY -- the entire MetaTrader5 surface of this module lives here)
# =============================================================================================
def _mt5_connect():
    """Import + initialize MetaTrader5. Called ONLY from capture_observation(), which is called
    ONLY from the preview path. The armed write path never reaches this function."""
    try:
        import MetaTrader5 as mt5  # type: ignore
    except Exception as e:
        common.stop(f"could not import MetaTrader5 ({e!r}). Run on Windows with the terminal up.", code=2)
    if not mt5.initialize():
        common.stop(f"mt5.initialize() failed: {mt5.last_error()}. Terminal running & logged in?", code=3)
    return mt5


def capture_observation(mt5, *, user_id, source_account, lease_seconds, connector_version,
                        policy_version, max_positions, with_account_facts=False):
    """One ordered capture. Returns (envelope, missing_by_pid, symbols_meta, account_facts).

    ORDER IS PART OF THE CONTRACT:
      1 initialize (caller)  2 account_info  3 account match  4 margin mode
      5 STRICT positions_get  6 captured_at  7 per-symbol enrichment
    `captured_at` describes the successful membership observation -- never the later human approval.
    """
    acct = common.as_dict(mt5.account_info())
    if acct is None:
        raise BrokerReadFailure("account_info() returned None -- terminal not logged in? "
                                "Account identity could not be verified.")

    login = acct.get("login")
    if str(login) != str(source_account):
        raise BrokerReadFailure(
            f"--source-account {source_account!r} != terminal login "
            f"{common.mask_login(login)}. HARD STOP (cross-account guard).")

    margin_mode = acct.get("margin_mode")
    if margin_mode != EXPECTED_MARGIN_MODE:
        raise BrokerReadFailure(
            f"margin_mode is {margin_mode!r} "
            f"({common.MARGIN_MODE_NAMES.get(margin_mode, '?')}), expected "
            f"{EXPECTED_MARGIN_MODE} (RETAIL_HEDGING). S1 assumes hedging so that scale-ins are "
            f"distinct position_ids. Refusing to capture.")

    positions = read_positions_strict(mt5)                      # step 5 -- may raise

    # step 5.5 (S1.1) -- the FINANCIAL account sample, deliberately AFTER the membership read so
    # equity is measured as close to captured_at as the API allows. The step-2 read above is for
    # IDENTITY only and must stay before the membership read so the cross-account guard fires first.
    account_block = None
    if with_account_facts:
        try:
            acct2 = common.as_dict(mt5.account_info())
        except Exception:                                       # a raising read is a failed read
            acct2 = None
        account_read_at = tz.utc_iso(datetime.now(timezone.utc))    # stamped IMMEDIATELY
        if acct2 is not None:
            login2 = acct2.get("login")
            if str(login2) != str(source_account):
                # IDENTITY DRIFT -- the ONLY account condition that blocks membership. If the
                # terminal's login changed between step 2 and now, the positions read at step 5
                # happened under an unknown identity, so the MEMBERSHIP itself is untrustworthy.
                # This is not about gearing.
                raise BrokerReadFailure(
                    f"ACCOUNT_IDENTITY_DRIFT - terminal login changed mid-capture: step 2 saw "
                    f"{common.mask_login(login)}, step 5.5 sees {common.mask_login(login2)} "
                    f"(--source-account {source_account}). The position set was read under an "
                    f"unknown identity. HARD STOP: nothing is written and no run is created.")
        # A failed second read is a VALUE-observation failure, not observed identity drift: it is
        # recorded as status='failed' and the membership snapshot still proceeds.
        account_block = s1_rows.build_account_block(acct2, account_read_at=account_read_at)

    captured_at = tz.utc_iso(datetime.now(timezone.utc))        # step 6 -- the observation instant

    if len(positions) > max_positions:
        raise BrokerReadFailure(
            f"{len(positions)} open positions exceeds --max-positions {max_positions}. Refusing to "
            f"capture a payload this size without a deliberate cap change.")

    # step 7 -- enrichment. Never allowed to change the membership set decided above.
    raw_positions = [common.as_dict(p) for p in positions]
    symbols = sorted({p.get("symbol") for p in raw_positions if p.get("symbol")})
    symbols_meta = {}
    for sym in symbols:
        si = common.as_dict(mt5.symbol_info(sym))
        if si is None:
            symbols_meta[sym] = {}                              # -> contract_size stays NULL
            continue
        path = si.get("path")
        symbols_meta[sym] = {
            "path": path,
            "instrument_class": common.rough_instrument_class(path, sym),
            "contract_size": si.get("trade_contract_size"),
            "digits": si.get("digits"),
        }

    terminal_build = None
    try:
        tinfo = common.as_dict(mt5.terminal_info())
        if tinfo:
            terminal_build = tinfo.get("build")
    except Exception:                                           # pragma: no cover - defensive
        terminal_build = None
    if isinstance(terminal_build, bool) or not isinstance(terminal_build, int):
        terminal_build = None

    rows, missing_by_pid = [], {}
    for raw in raw_positions:
        row, missing = s1_rows.map_s1_position(raw, symbols_meta)
        rows.append(row)
        missing_by_pid[row.get("position_id")] = missing

    envelope = s1_rows.build_envelope(
        run_id=str(uuid.uuid4()),
        lease_token=str(uuid.uuid4()),
        user_id=user_id,
        source_account=str(source_account),
        captured_at=captured_at,
        lease_seconds=lease_seconds,
        connector_version=connector_version,
        terminal_build=terminal_build,
        terminal_server=acct.get("server"),
        policy_version=policy_version,
        account=account_block,
        rows=rows,
    )
    account_facts = {"login": login, "server": acct.get("server"), "margin_mode": margin_mode,
                     "terminal_build": terminal_build, "account_block": account_block}
    return envelope, missing_by_pid, symbols_meta, account_facts


# =============================================================================================
# Envelope file I/O
# =============================================================================================
def default_envelope_path(captured_at: str) -> str:
    stamp = re.sub(r"[^0-9]", "", captured_at)
    return f"{common.SAFE_OUT_PREFIX}s1_capture_{stamp}.json"


def write_envelope_atomic(path: str, envelope: dict):
    """Write to <path>.tmp then os.replace -- a reader never observes a half-written envelope."""
    ok, reason = common.is_ignored_output_path(path)
    if not ok:
        common.stop(f"refusing to write the envelope to a trackable path ({path!r}: {reason}). "
                    f"Use {common.SAFE_OUT_PREFIX}...", code=2)
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(envelope, f, indent=2, ensure_ascii=False, allow_nan=False, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def load_envelope(path: str):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        common.stop(f"envelope not found: {path!r}. Generate one with --preview.", code=2)
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        common.stop(f"envelope is not valid JSON ({path!r}): {e}", code=2)
    except OSError as e:
        common.stop(f"could not read envelope ({path!r}): {e.strerror}", code=2)


# =============================================================================================
# Preview
# =============================================================================================
def _print_account_facts(block, captured_at=None):
    """Preview rendering of the S1.1 account block. FULL VALUES ARE LOCAL-ONLY: the design requires
    equity/balance to be masked or omitted in any report routed to an external reviewer, which needs
    the quality classification, not the account size."""
    if block is None:
        return
    print("-" * 78)
    print("ACCOUNT OBSERVATION (S1.1)   [local display only -- mask equity/balance in any report]")
    print(f"  account_read_at      : {block['account_read_at']}"
          + (f"   (captured_at {captured_at})" if captured_at else ""))
    print(f"  status               : {block['account_observation_status']}")
    if block["account_observation_status"] == s1_rows.ACCOUNT_STATUS_FAILED:
        print(f"  failure_reason       : {block['failure_reason']}")
        print("  The second account_info() read FAILED. This is a VALUE-observation failure, not "
              "identity drift:")
        print("  the membership snapshot is still valid and the cycle proceeds. Exposure will be "
              "unavailable for this run.")
    else:
        print(f"  equity               : {block['equity']!r}   [{block['equity_quality']}]")
        print(f"  balance              : {block['balance']!r}   [{block['balance_quality']}]")
        print(f"  currency             : {block['currency']!r}")
        if block["equity_quality"] != s1_rows.QUALITY_USABLE:
            print("  equity is NOT usable as an exposure denominator; balance is NEVER a fallback.")
        elif block["currency"] is None:
            print("  equity is stored usable, but currency is absent -> NOT exposure-eligible "
                  "(the unit cannot be proven).")
    print("-" * 78)


def print_preview(envelope, missing_by_pid, symbols_meta, account_facts, *, envelope_path, sha256):
    rows = envelope["rows"]
    n = len(rows)
    # Mode is resolved from the SEALED envelope, not from argv: the screen must describe the
    # artefact the armed write would actually replay.
    _v2 = envelope["envelope_format"] == s1_rows.ENVELOPE_FORMAT_V2
    print("=" * 78)
    print("MT5 S1.1 SNAPSHOT - PROPOSED OBSERVATION  [PREVIEW: NOTHING WRITTEN]" if _v2 else
          "MT5 S1 FIRST SNAPSHOT - PROPOSED OBSERVATION  [PREVIEW: NOTHING WRITTEN]")
    print("=" * 78)
    print("broker read            : HEALTHY (positions_get returned a tuple)")
    print(f"account (source)       : {common.mask_login(account_facts.get('login'))}")
    print(f"account guard          : --source-account MATCHES terminal login")
    print(f"server                 : {account_facts.get('server')}")
    print(f"terminal build         : {account_facts.get('terminal_build')}")
    _print_account_facts(account_facts.get("account_block"), envelope.get("captured_at"))
    print(f"margin_mode            : {account_facts.get('margin_mode')} "
          f"({common.MARGIN_MODE_NAMES.get(account_facts.get('margin_mode'), '?')}) [required: "
          f"{EXPECTED_MARGIN_MODE} RETAIL_HEDGING]")
    print(f"captured_at (UTC)      : {envelope['captured_at']}")
    print(f"envelope age at capture: 0 s   (must be < --max-envelope-age-seconds at write time)")
    print(f"proposed run_id        : {envelope['run_id']}")
    print(f"policy_version         : {envelope['policy_version']}")
    print(f"lease_seconds          : {envelope['lease_seconds']}")
    print(f"connector_version      : {envelope['connector_version']}   "
          f"[resolved for {'S1.1 (--with-account-facts)' if _v2 else 'S1-only'} mode; namespace "
          f"{s1_rows.CONNECTOR_NAMESPACE_S11 if _v2 else s1_rows.CONNECTOR_NAMESPACE_S1!r}]")
    print(f"envelope_format        : {envelope['envelope_format']}")

    if n == 0:
        print("\nOPEN POSITIONS OBSERVED: 0")
        print("broker read HEALTHY - positions_get returned an empty tuple")
        print("  (this is a GENUINE flat account, not a failed read; a failed read cannot reach")
        print("   this screen at all -- it exits before an envelope is created)")
    else:
        print(f"\nOPEN POSITIONS OBSERVED: {n}")
        print(f"  {'position_id':<12} {'symbol':<12} {'side':<5} {'volume':>8} {'price_open':>12} "
              f"{'price_curr':>12} {'profit':>12} {'csize':>8}  class")
        for r in rows:
            meta = symbols_meta.get(r["symbol_raw"]) or {}
            print(f"  {r['position_id']:<12} {str(r['symbol_raw']):<12} {str(r['side']):<5} "
                  f"{_fmt(r['volume']):>8} {_fmt(r['price_open']):>12} {_fmt(r['price_current']):>12} "
                  f"{_fmt(r['profit']):>12} {_fmt(r['contract_size']):>8}  "
                  f"{meta.get('instrument_class', 'unknown')}")

    print("\nFIELD COMPLETENESS     :")
    comp = field_completeness(rows)
    for key in s1_rows.S1_ROW_KEYS:
        print(f"  {key:<18} {comp[key]}")

    print(f"\nDUPLICATE-ID CHECK     : PASS ({n} row(s), {len(envelope['expected_ids'])} distinct id(s))")
    print("PAYLOAD KEY CHECK      : PASS (every row carries exactly the 10 S1 columns)")
    print("JOURNAL MAPPING        : NOT REQUIRED for S1 membership "
          "(mt5_sync_run_positions has no product_id / normalized_symbol)")

    warnings = collect_warnings(rows, missing_by_pid, symbols_meta)
    print(f"\nWARNINGS               : {len(warnings)}")
    for w in warnings:
        print(f"  ! {w}")
    if not warnings:
        print("  (none)")

    print()
    print(side_effect_preview(n, s11=_v2))
    print(f"ENVELOPE               : {envelope_path}")
    print(f"ENVELOPE SHA-256       : {sha256}")
    print()
    print(">>> APPROVE? Nothing has been written. To arm the single write cycle, run:")
    print(f"      set {WRITE_ENV}=1")
    # The armed command MUST carry the same mode flag that produced this envelope. Without it the
    # S1-only write path refuses a v2 envelope (ENVELOPE_FORMAT_NOT_S1), so a displayed command
    # missing the flag is simply not executable -- and adding the flag to a v1 command is equally
    # wrong (the S1.1 path refuses v1 with ENVELOPE_FORMAT_NOT_S1_1).
    _mode_flag = " --with-account-facts" if _v2 else ""
    print(f"      python ops/mt5_import/s1_snapshot.py{_mode_flag} --write "
          f"--confirm {CONFIRM_WRITE} \\")
    print(f"        --envelope {envelope_path} \\")
    print(f"        --envelope-sha256 {sha256}")
    print(">>> The armed run performs ZERO MT5 calls; it replays this envelope's canonical write")
    print(">>> payload. Reformatting the JSON is harmless; changing any write-relevant value is not.")


def _fmt(v):
    if v is None:
        return "NULL"
    return f"{v}"


def run_preview(args):
    if not common.is_uuid(args.user_id):
        common.stop(f"--user-id must be a UUID (got {args.user_id!r}); not read from .env.")
    if not (args.source_account and str(args.source_account).strip()):
        common.stop("--source-account must be a non-empty string (the MT5 login / source_account).")
    if not (s1_rows.LEASE_SECONDS_MIN <= args.lease_seconds <= s1_rows.LEASE_SECONDS_MAX):
        common.stop(f"--lease-seconds must be between {s1_rows.LEASE_SECONDS_MIN} and "
                    f"{s1_rows.LEASE_SECONDS_MAX} (server contract).")

    # Mode resolution happens FIRST: before the terminal is initialised, before any credential is
    # read, before any transport exists. A mode/namespace mismatch must cost nothing.
    s11 = bool(getattr(args, "with_account_facts", False))
    connector_version = resolve_connector_version(args.connector_version, with_account_facts=s11)

    mt5 = _mt5_connect()
    try:
        envelope, missing_by_pid, symbols_meta, account_facts = capture_observation(
            mt5,
            user_id=args.user_id.strip(),
            source_account=str(args.source_account).strip(),
            lease_seconds=args.lease_seconds,
            connector_version=connector_version,
            policy_version=args.policy_version,
            max_positions=args.max_positions,
            with_account_facts=s11,
        )
    except BrokerReadFailure as e:
        print("=" * 78)
        print("BROKER READ FAILED - current positions COULD NOT BE DETERMINED.")
        print("No S1 write is possible.")
        print("=" * 78)
        common.eprint(f"reason: {e}")
        common.eprint("No envelope was created. There is no arm instruction. "
                      "Fix the terminal/account condition and re-run --preview.")
        return 3
    finally:
        mt5.shutdown()

    # The envelope is created ONLY after the entire capture validates.
    errors = s1_rows.validate_envelope(envelope)
    if errors:
        print("=" * 78)
        print("CAPTURE REJECTED - the observation is not a valid S1 payload. No envelope written.")
        print("=" * 78)
        for err in errors:
            common.eprint(f"  ! {err}")
        common.eprint("A malformed broker position is NEVER skipped: skipping one row would seal "
                      "immutable membership that misrepresents the account.")
        return 4

    sha = s1_rows.envelope_sha256(envelope)
    path = args.envelope or default_envelope_path(envelope["captured_at"])
    write_envelope_atomic(path, envelope)
    print_preview(envelope, missing_by_pid, symbols_meta, account_facts,
                  envelope_path=path, sha256=sha)
    return 0


# =============================================================================================
# Armed write -- replays the approved envelope. ZERO MT5 calls.
# =============================================================================================
def _fail(stage, code, detail=""):
    common.eprint(f"STAGE {stage} FAILED: {code}{(' - ' + detail) if detail else ''}")


def _reconcile_guidance(status, run_id, *, code, extra):
    """Build one operator message for a reconcile outcome that needs review.

    Shared tail, because it is true of EVERY reconcile-failure branch: the snapshot is complete, so
    a same-envelope re-run now fails closed at create_run, and nothing here is auto-recoverable.
    """
    head = f"{status} - run_id={run_id}"
    if code:
        head += f" reconcile error_code={code!r}"
    return (
        f"{head}\n"
        f"  {extra}\n"
        f"  The adapter did NOT call mt5_mark_reconcile_failed_v1 (it is not in the client "
        f"allowlist) and did NOT expire anything.\n"
        f"  Re-running this envelope is NOT the recovery path: the snapshot is sealed, so "
        f"create_run answers ERR_RUN_SEALED and this adapter stops with "
        f"SEALED_RUN_REVIEW_REQUIRED.\n"
        f"  Inspect the run READ-ONLY first (snapshot_status, reconcile_status, snapshot_health, "
        f"lease_expires_at, error_code, and the staging lifecycle columns for this account). "
        f"Never recover with manual SQL.")


def run_write(args, *, now=None, client_factory=None):
    now = now or datetime.now(timezone.utc)

    envelope = load_envelope(args.envelope)
    errors = s1_rows.validate_envelope(envelope)
    if errors:
        common.eprint(f"envelope {args.envelope!r} is structurally invalid:")
        for err in errors:
            common.eprint(f"  ! {err}")
        common.stop("refusing to replay an invalid envelope.", code=2)

    # (0) ENVELOPE FORMAT GATE -- bidirectional, BEFORE any DB call.
    #     v1 is S1-only and unchanged forever; v2 carries the canonical account block. Feeding a v1
    #     envelope to the S1.1 path would seal an S1.1-versioned run with no account row, i.e. it
    #     would manufacture S1_1_ACCOUNT_ROW_MISSING_ANOMALY. Feeding a v2 envelope to the S1-only
    #     path would SILENTLY DISCARD approved account facts. Both are refused.
    fmt = envelope["envelope_format"]
    s11 = bool(getattr(args, "with_account_facts", False))
    if s11 and fmt != s1_rows.ENVELOPE_FORMAT_V2:
        common.stop(f"ENVELOPE_FORMAT_NOT_S1_1 - the S1.1 write path requires "
                    f"{s1_rows.ENVELOPE_FORMAT_V2!r}, got {fmt!r}. A v1 envelope carries no account "
                    f"block and must never be reinterpreted as S1.1-capable.", code=2)
    if not s11 and fmt != s1_rows.ENVELOPE_FORMAT_V1:
        common.stop(f"ENVELOPE_FORMAT_NOT_S1 - the S1-only write path requires "
                    f"{s1_rows.ENVELOPE_FORMAT_V1!r}, got {fmt!r}. Replaying a v2 envelope here "
                    f"would silently discard the approved account observation. Re-run with "
                    f"--with-account-facts.", code=2)

    # (1) approval binding -- BEFORE any DB call.
    actual = s1_rows.envelope_sha256(envelope)
    if not hash_matches(args.envelope_sha256, actual):
        common.eprint(f"  approved (--envelope-sha256): {str(args.envelope_sha256).strip().lower()}")
        common.eprint(f"  actual   (recomputed)       : {actual}")
        common.stop("ENVELOPE HASH MISMATCH - the canonical write payload in this file is not the "
                    "observation that was approved. Refusing before any database call. "
                    "Re-run --preview.", code=2)

    # (2) age -- BEFORE any DB call.
    age = envelope_age_seconds(envelope["captured_at"], now)
    if age is None:
        common.stop("envelope captured_at is unparseable.", code=2)
    if age < -CLOCK_SKEW_TOLERANCE_SECONDS:
        common.stop(f"envelope captured_at is {abs(age):.0f}s in the FUTURE (tolerance "
                    f"{CLOCK_SKEW_TOLERANCE_SECONDS}s). A capture instant cannot be in the future - "
                    f"refusing before any database call. Check the clock and re-run --preview.",
                    code=2)
    if age > args.max_envelope_age_seconds:
        common.stop(f"envelope is {age:.0f}s old (> --max-envelope-age-seconds "
                    f"{args.max_envelope_age_seconds}). The approved observation is no longer fresh "
                    f"enough to seal. Generate a NEW preview -- captured_at is never refreshed "
                    f"silently.", code=2)

    # (3) optional operator identity cross-check.
    if args.user_id and args.user_id.strip() != envelope["user_id"]:
        common.stop(f"--user-id does not match the envelope ({envelope['user_id']}).", code=2)
    if args.source_account and str(args.source_account).strip() != envelope["source_account"]:
        common.stop(f"--source-account does not match the envelope "
                    f"({envelope['source_account']!r}).", code=2)

    sb_url = os.environ.get("SUPABASE_URL")
    sb_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not sb_url or not sb_key:
        common.stop("armed write requires local SUPABASE_URL + SUPABASE_SERVICE_KEY env "
                    "(values never logged). Refusing to write.", code=2)

    run_id = envelope["run_id"]
    user_id = envelope["user_id"]
    account = envelope["source_account"]
    lease_token = envelope["lease_token"]

    print("=" * 78)
    print("MT5 S1 ONE-SHOT ARMED WRITE  [replaying the approved envelope; ZERO MT5 calls]")
    print("=" * 78)
    print(f"envelope        : {args.envelope}")
    print(f"sha256          : {actual}  (canonical write payload MATCHES approval)")
    print(f"captured_at     : {envelope['captured_at']}  (age {age:.0f}s)")
    print(f"run_id          : {run_id}")
    print(f"account         : {common.mask_login(account)}   positions: {envelope['expected_count']}")
    print()

    factory = client_factory or (lambda: s1_client.S1Client(sb_url, sb_key, log=print))
    client = factory()

    # ---- stage 1: create ---------------------------------------------------------------------
    try:
        res = client.create_run(
            run_id=run_id, user_id=user_id, source_account=account, lease_token=lease_token,
            lease_seconds=envelope["lease_seconds"], captured_at=envelope["captured_at"],
            connector_version=envelope["connector_version"],
            terminal_build=envelope["terminal_build"], terminal_server=envelope["terminal_server"],
            policy_version=envelope["policy_version"])
    except s1_client.S1ClientError as e:
        # create_run did NOT succeed -> NO mark_* call. We must never terminalise a run that may
        # belong to another invocation's active cycle, and a lost ACK is recoverable by replaying
        # this same envelope (identical parameters -> idempotent).
        _fail(STAGE_CREATE, "TRANSPORT_FAILED", str(e))
        common.eprint("RUN_STATE_UNKNOWN - no cleanup was attempted (create_run did not return). "
                      "Re-running this SAME envelope replays identically; if the account is blocked "
                      "by ERR_RUN_ACTIVE, wait for the lease then use --expire-run.")
        return 5
    if not res.get("o_ok"):
        code = res.get("o_error_code")
        _fail(STAGE_CREATE, code)
        if code == "ERR_RUN_SEALED":
            # FAIL CLOSED. A run with this identity is already sealed, but ERR_RUN_SEALED proves
            # only that run_id, user, account, captured_at, connector/build/server and policy match.
            # It proves NOTHING about the immutable per-position facts (symbol_raw, side, volume,
            # price_open, price_current, profit, open_time_utc, source_time_msc, contract_size):
            # a different envelope can keep the same ids and count while changing any of them, and
            # would carry its own perfectly valid canonical SHA-256. Neither completion replay nor
            # the stored manifest closes that gap at this boundary -- both are recomputed from the
            # ALREADY-SEALED rows, so they can only prove the database agrees with itself.
            # Reconciling here would apply lifecycle mutations on the authority of facts this
            # invocation cannot verify. There is no reviewed fact-complete comparison in the S1 API,
            # so the adapter stops and hands the decision to a human.
            common.eprint(
                f"SEALED_RUN_REVIEW_REQUIRED - a snapshot with run identity {run_id} is ALREADY "
                f"SEALED.\n"
                f"  This invocation CANNOT prove that the approved canonical envelope facts are "
                f"identical to the immutable sealed rows: ERR_RUN_SEALED only matches run identity "
                f"and create metadata, not the per-position facts.\n"
                f"  NO reconciliation was attempted. No append, no complete, no reconcile, no "
                f"mark_*, no expire.\n"
                f"  Run read-only recovery inspection of this run and its membership BEFORE "
                f"deciding whether to: (a) accept the sealed run as-is, (b) after the lease has "
                f"actually expired, deliberately expire/terminalize an unreconciled stale cycle "
                f"with --expire-run, or (c) capture a NEW observation when the S1 contract allows "
                f"it.\n"
                f"  Do NOT simply re-run this envelope.")
            return 10
        if code == "ERR_RUN_ACTIVE":
            common.eprint(f"another cycle is active for this account (run_id={res.get('o_run_id')}, "
                          f"lease_expires_at={res.get('o_lease_expires_at')}). Report-and-stop only: "
                          f"this invocation will NOT touch a run it does not own.")
        elif code == "ERR_RUN_EXPIRED":
            common.eprint(f"an expired cycle is blocking this account (run_id={res.get('o_run_id')}). "
                          f"Recover deliberately: --expire-run {res.get('o_run_id')}")
        common.eprint("no mark_* cleanup attempted (create_run did not succeed).")
        return 6

    print(f"  CREATE   ok  run_id={run_id} lease_expires_at={res.get('o_lease_expires_at')}")

    # ---- stages 2-3: append + complete (this invocation owns the run) -------------------------
    # Reached ONLY after create_run returned o_ok=true, i.e. the run is 'started' and this
    # invocation holds the lease. A sealed run can never arrive here (it returned 10 above).
    stages = [
        (STAGE_APPEND, lambda: client.append_run_positions(
            run_id=run_id, user_id=user_id, source_account=account,
            lease_token=lease_token, rows=envelope["rows"])),
    ]
    if s11:
        # S1.1: the account observation must land while the parent run is still 'started', so it
        # goes BEFORE complete_snapshot. The same completion then seals membership AND account
        # facts, with no change to any frozen S1 RPC.
        stages.append((STAGE_ACCOUNT, lambda: client.append_run_account(
            run_id=run_id, user_id=user_id, source_account=account,
            lease_token=lease_token, facts=envelope["account"])))
    stages.append(
        (STAGE_COMPLETE, lambda: client.complete_snapshot(
            run_id=run_id, user_id=user_id, source_account=account, lease_token=lease_token,
            expected_count=envelope["expected_count"], expected_ids=envelope["expected_ids"])))

    for stage, call in tuple(stages):
        try:
            res = call()
        except s1_client.S1ClientError as e:
            # Outcome UNKNOWN. Do NOT auto-terminalise: the call may have landed. The correct
            # advice differs by stage, because only the COMPLETE stage can have sealed the run.
            _fail(stage, "TRANSPORT_FAILED", str(e))
            if stage == STAGE_APPEND:
                common.eprint(
                    f"RUN_STATE_UNKNOWN - run {run_id} is still 'started'; the append may or may "
                    f"not have landed. No cleanup attempted. Re-running this SAME envelope replays "
                    f"idempotently (create_run extends the lease, append is "
                    f"on-conflict-do-nothing + field-identical). If the lease has since expired, "
                    f"inspect read-only and then use --expire-run {run_id}.")
            elif stage == STAGE_ACCOUNT:
                # CLASS C -- outcome unknown. The account append MAY have committed despite the
                # lost response. Terminalising here could destroy a recoverable exact-replay path,
                # and sealing could permanently create S1_1_ACCOUNT_ROW_MISSING_ANOMALY.
                common.eprint(
                    f"ACCOUNT_APPEND_RESULT_UNKNOWN - run {run_id} is still 'started'; the account "
                    f"append may or may not have landed.\n"
                    f"  NO complete_snapshot. NO mark_snapshot_failed. NO expire. NO reconcile.\n"
                    f"  While the run is still 'started' AND the lease is live, an operator may "
                    f"replay THIS SAME v2 envelope with --resume-account-append (same run_id, same "
                    f"approved SHA, no MT5 re-read). append_run_account compares the FULL account "
                    f"fingerprint, so an identical observation replays as inserted=0 and a changed "
                    f"one is refused with ERR_ACCOUNT_CONFLICT.\n"
                    f"  If the lease has expired, do NOT resume: inspect read-only and use the "
                    f"reviewed stale-run recovery instead.")
            else:
                common.eprint(
                    f"RUN_STATE_UNKNOWN - the completion for run {run_id} MAY have been applied. "
                    f"No cleanup attempted.\n"
                    f"  Do NOT assume a re-run works: if the seal landed, create_run answers "
                    f"ERR_RUN_SEALED and this adapter stops with SEALED_RUN_REVIEW_REQUIRED.\n"
                    f"  Inspect the run READ-ONLY (snapshot_status / reconcile_status / "
                    f"lease_expires_at) before choosing any recovery action.")
            return 5
        if not res.get("o_ok"):
            code = res.get("o_error_code")
            _fail(stage, code)
            if stage == STAGE_ACCOUNT:
                # CLASS B (or a seal race) -- identical handling to --resume-account-append.
                return handle_account_refusal(client, envelope, code)
            reason = STAGE_FAILED_REASON[stage]
            print(f"  cleanup  : marking run {run_id} failed (reason={reason})")
            try:
                cl = client.mark_snapshot_failed(
                    run_id=run_id, user_id=user_id, source_account=account,
                    lease_token=lease_token, reason_code=reason)
                if cl.get("o_ok"):
                    print(f"  cleanup  ok  run marked failed ({reason})")
                else:
                    common.eprint(f"  cleanup FAILED: {cl.get('o_error_code')} "
                                  f"(the ORIGINAL failure above is still {code})")
            except s1_client.S1ClientError as e:
                common.eprint(f"  cleanup FAILED: {e} (the ORIGINAL failure above is still {code})")
            common.eprint(f"ORIGINAL FAILURE: stage={stage} code={code}")
            return 7
        if stage == STAGE_APPEND:
            print(f"  APPEND   ok  inserted={res.get('o_inserted')} "
                  f"(of {envelope['expected_count']}; 0 means an exact idempotent replay)")
        elif stage == STAGE_ACCOUNT:
            acct = envelope["account"]
            print(f"  ACCOUNT  ok  inserted={res.get('o_inserted')} "
                  f"(0 means an exact idempotent replay)  "
                  f"status={acct['account_observation_status']} "
                  f"equity_quality={acct['equity_quality']} "
                  f"balance_quality={acct['balance_quality']}")
        else:
            print(f"  COMPLETE ok  run_seq={res.get('o_run_seq')} "
                  f"health={res.get('o_snapshot_health')}")
            completed = res

    # ---- stage 4: reconcile ------------------------------------------------------------------
    # NOTE ON EVERY BRANCH BELOW: the snapshot is now COMPLETE, so a re-run of this same envelope
    # will hit ERR_RUN_SEALED at create_run and correctly fail closed. "Retry the same envelope" is
    # therefore NEVER valid recovery advice from here on. Every branch routes to read-only
    # inspection first, and none of them changes state automatically.
    try:
        res = client.reconcile_snapshot(run_id=run_id, user_id=user_id,
                                        source_account=account, lease_token=lease_token)
    except s1_client.S1ClientError as e:
        # (D) The request may or may not have been applied -- a transport failure cannot tell us.
        _fail(STAGE_RECONCILE, "TRANSPORT_FAILED", str(e))
        common.eprint(_reconcile_guidance("RECONCILE_RESULT_UNKNOWN", run_id, code=None, extra=(
            "The reconcile request did not return, so it MAY or MAY NOT have been applied. The "
            "snapshot itself is COMPLETE and already authoritative broker evidence; the lifecycle "
            "annotation is in an UNKNOWN state.\n"
            "  No mark_*, no expire, no retry loop.")))
        return 8
    if not res.get("o_ok"):
        code = res.get("o_error_code")
        _fail(STAGE_RECONCILE, code)
        # DELIBERATE in all branches: no mt5_mark_reconcile_failed_v1. That RPC is not even in the
        # client allowlist -- terminalising a reconcile is an operator decision, never a default.
        if code == "ERR_LEASE_EXPIRED":
            # (B) The lease died while the run sat complete + pending.
            status, extra = "RECONCILE_LEASE_EXPIRED_REVIEW_REQUIRED", (
                "The run's lease expired before the lifecycle annotation was applied. "
                "snapshot_status=complete is preserved; reconcile_status is still pending.\n"
                "  A normal --write will NOT renew a sealed run's lease: create_run answers "
                "ERR_RUN_SEALED and this adapter fails closed. Do NOT retry in a loop and do NOT "
                "auto-expire.\n"
                "  After confirming the run and lease state READ-ONLY, --expire-run may be used as "
                "a deliberate operator action. For a complete + reconcile-pending run that leaves "
                "snapshot_status=complete with reconcile_status=failed "
                "(error_code=RECONCILE_LEASE_EXPIRED): the broker snapshot survives as evidence, "
                "but lifecycle reconciliation is TERMINAL for this run. A subsequent observation "
                "then needs a NEW cycle.")
        elif code in RECONCILE_TERMINAL_CODES:
            # (C) reconcile_status is already 'failed'; the RPC echoed the STORED error code.
            status, extra = "RECONCILE_TERMINAL_REVIEW_REQUIRED", (
                f"reconcile_status for this run is already FAILED and terminal (stored "
                f"error_code={code!r}). It is NOT pending and it will not become pending again.\n"
                "  The completed snapshot remains broker evidence. Lifecycle reconciliation for "
                "this run is over. Do NOT retry this envelope. Inspect read-only, then capture a "
                "NEW observation when the S1 contract allows it.")
        else:
            # (A) Live contract refusal; the run stays complete + pending and nothing was mutated.
            status, extra = "RECONCILE_PENDING_REVIEW_REQUIRED", (
                "The reconcile RPC refused; this invocation changed nothing. snapshot_status="
                "complete is preserved and reconcile_status is still pending.\n"
                "  Perform a READ-ONLY run-state inspection before ANY recovery action. Do not "
                "assume a plain --write retry works: create_run will answer ERR_RUN_SEALED.")
        common.eprint(_reconcile_guidance(status, run_id, code=code, extra=extra))
        return 8

    print(f"  RECONCILE ok still_open={res.get('o_still_open')} "
          f"missing_once={res.get('o_missing_once')} "
          f"not_open_confirmed={res.get('o_not_open_confirmed')} conflicts={res.get('o_conflicts')}")

    creates = client.stage_calls.get(s1_client.RPC_CREATE_RUN, 0)
    if creates != 1:                                            # pragma: no cover - defensive
        common.eprint(f"INTERNAL: expected exactly 1 create_run stage, counted {creates}")
        return 9

    print()
    print("ONE CYCLE COMPLETE. Exiting - no scheduler, no loop, no second cycle.")
    print(f"  run_seq={completed.get('o_run_seq')} health={completed.get('o_snapshot_health')} "
          f"positions={envelope['expected_count']}")
    print(f"  rpc stages: {dict(sorted(client.stage_calls.items()))} "
          f"(http attempts incl. retries: {client.http_attempts})")
    return 0


# =============================================================================================
# Expiry recovery
# =============================================================================================
def run_resume_account_append(args, *, client_factory=None):
    """S1.1 CLASS-C RECOVERY -- one bounded account-append replay. Never automatic.

    Reached only after ACCOUNT_APPEND_RESULT_UNKNOWN, where the append MAY have committed but the
    response was lost. It issues EXACTLY ONE mt5_append_run_account_v1 call with the SAME approved
    v2 envelope, and then STOPS. It never calls create_run, complete_snapshot, reconcile_snapshot
    or expire, and it never touches MT5.

    Why this resume is safe where the rejected ERR_RUN_SEALED resume was not: that one relied on a
    refusal proving only run identity and create metadata, never the per-position facts. Here the
    run is NOT sealed and append_run_account compares the FULL account fingerprint, so an identical
    observation replays as inserted=0 and ANY changed fact is refused with ERR_ACCOUNT_CONFLICT.
    The comparison is fact-complete, not identity-only.

    No local envelope-age gate: the run's captured_at is already sealed server-side and this call
    cannot change it, so freshness is not the question. The LEASE is the authority and the server
    enforces it (a 300 s lease is far tighter than the 900 s preview bound anyway).
    """
    envelope = load_envelope(args.envelope)
    errors = s1_rows.validate_envelope(envelope)
    if errors:
        common.eprint(f"envelope {args.envelope!r} is structurally invalid:")
        for err in errors:
            common.eprint(f"  ! {err}")
        common.stop("refusing to resume with an invalid envelope.", code=2)

    if envelope["envelope_format"] != s1_rows.ENVELOPE_FORMAT_V2:
        common.stop(f"ENVELOPE_FORMAT_NOT_S1_1 - --resume-account-append requires "
                    f"{s1_rows.ENVELOPE_FORMAT_V2!r}, got {envelope['envelope_format']!r}.", code=2)

    actual = s1_rows.envelope_sha256(envelope)
    if not hash_matches(args.envelope_sha256, actual):
        common.eprint(f"  approved (--envelope-sha256): {str(args.envelope_sha256).strip().lower()}")
        common.eprint(f"  actual   (recomputed)       : {actual}")
        common.stop("ENVELOPE HASH MISMATCH - this is not the approved observation. Refusing "
                    "before any database call.", code=2)

    sb_url = os.environ.get("SUPABASE_URL")
    sb_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not sb_url or not sb_key:
        common.stop("resume requires local SUPABASE_URL + SUPABASE_SERVICE_KEY env "
                    "(values never logged). Refusing to call.", code=2)

    run_id = envelope["run_id"]
    acct_block = envelope["account"]

    print("=" * 78)
    print("MT5 S1.1 ACCOUNT-APPEND RESUME  [ONE bounded replay; ZERO MT5 calls]")
    print("=" * 78)
    print(f"envelope        : {args.envelope}")
    print(f"sha256          : {actual}  (canonical write payload MATCHES approval)")
    print(f"run_id          : {run_id}")
    print(f"account status  : {acct_block['account_observation_status']}  "
          f"equity_quality={acct_block['equity_quality']} "
          f"balance_quality={acct_block['balance_quality']}")
    print()

    factory = client_factory or (lambda: s1_client.S1Client(sb_url, sb_key, log=print))
    client = factory()
    try:
        res = client.append_run_account(
            run_id=run_id, user_id=envelope["user_id"],
            source_account=envelope["source_account"], lease_token=envelope["lease_token"],
            facts=acct_block)
    except s1_client.S1ClientError as e:
        _fail(STAGE_ACCOUNT, "TRANSPORT_FAILED", str(e))
        common.eprint("ACCOUNT_APPEND_RESULT_UNKNOWN - still unknown after this bounded replay. "
                      "NO complete, NO mark_*, NO expire, NO reconcile. Inspect READ-ONLY "
                      "(snapshot_status, lease_expires_at, and whether an account row exists for "
                      "this run) before any further action.")
        return 5

    if res.get("o_ok"):
        inserted = res.get("o_inserted")
        print(f"  ACCOUNT  ok  inserted={inserted}")
        if inserted == 0:
            print("  The account row ALREADY existed and is FACT-IDENTICAL to the approved "
                  "envelope (full-fingerprint match). The earlier append had landed.")
        else:
            print("  The account row did NOT exist; it has now been written from the approved "
                  "envelope.")
        print()
        print("SAFE TO CONTINUE. Re-run the SAME armed command "
              "(--write --with-account-facts --envelope ... --envelope-sha256 ...) to finish the "
              "cycle: every stage replays idempotently (create_run extends the lease, both appends "
              "are field-identical no-ops, then complete + reconcile).")
        print("Nothing else was called. STOP here until a human decides to continue.")
        return 0

    # EVERY returned refusal goes through the SAME classifier as the armed write. There is no
    # "unexpected code" fall-through here any more: an unrecognised deterministic refusal is still
    # deterministic, and leaving the run 'started' with no cleanup was the defect.
    code = res.get("o_error_code")
    _fail(STAGE_ACCOUNT, code)
    return handle_account_refusal(client, envelope, code)


# --- shared deterministic account-append refusal contract -------------------------------------
# THREE outcome classes, and only these three, for a returned o_ok=false:
#   sealed        -- ERR_RUN_SEALED. NEVER a terminalisation opportunity (design section 11): the
#                    run is already sealed, account facts can no longer be attached, and
#                    mark_snapshot_failed on a sealed run is both refused and wrong to attempt.
#   deterministic -- every other contract/integrity refusal. The server DECIDED; the outcome is
#                    known. The run must not be sealed, so it is terminalised with APPEND_FAILED
#                    and the ORIGINAL refusal stays primary.
#   (transport)   -- not reachable here at all: an exception never produces a code, and an unknown
#                    outcome must never be terminalised. Handled by the callers as class C.
#
# A LEASE refusal is deterministic, not unknown, so it takes the cleanup ATTEMPT (design section
# 11 + review section 26). That attempt will usually be refused by the frozen S1 RPC for the very
# same reason -- which is fine, and is reported as a SECONDARY cleanup failure. It is never
# converted into an auto-expire.
ACCOUNT_REFUSAL_SEALED = "sealed"
ACCOUNT_REFUSAL_DETERMINISTIC = "deterministic"

# Distinct exit codes only where the operator's next action genuinely differs.
ACCOUNT_EXIT_SEALED = 10
ACCOUNT_EXIT_LEASE = 8      # authority lost -- stale-run recovery, NOT a retry
ACCOUNT_EXIT_REFUSED = 7    # contract/integrity refusal -- read-only inspection

ACCOUNT_LEASE_CODES = ("ERR_LEASE_EXPIRED", "ERR_LEASE_MISMATCH")


def classify_account_refusal(code):
    """Map a returned o_ok=false account-append code to its handling class. ONE definition."""
    if code == "ERR_RUN_SEALED":
        return ACCOUNT_REFUSAL_SEALED
    return ACCOUNT_REFUSAL_DETERMINISTIC


def _account_refusal_guidance(code, run_id):
    """(exit_code, operator guidance) for one deterministic refusal."""
    if code in ACCOUNT_LEASE_CODES:
        return ACCOUNT_EXIT_LEASE, (
            f"ACCOUNT_APPEND_LEASE_EXPIRED_REVIEW_REQUIRED - the lease for run {run_id} is no "
            f"longer held ({code}), so this invocation has NO authority over the run. Do NOT "
            f"resume and do NOT auto-expire.\n"
            f"  The cleanup attempt below is expected to be refused for the same reason; that "
            f"changes nothing and does not replace the original refusal. Inspect read-only, then "
            f"use the reviewed stale-run recovery. A new observation is a NEW run.")
    if code == "ERR_ACCOUNT_CONFLICT":
        return ACCOUNT_EXIT_REFUSED, (
            "ERR_ACCOUNT_CONFLICT - an account row exists for this run whose facts differ from the "
            "approved envelope. It was NOT overwritten. This is a persistence/integrity failure, "
            "not a broker value problem. Inspect read-only before deciding anything.")
    if code == "ERR_CONNECTOR_NOT_S1_1":
        return ACCOUNT_EXIT_REFUSED, (
            f"ERR_CONNECTOR_NOT_S1_1 - the server refused because run {run_id} was created with a "
            f"connector_version OUTSIDE the {s1_rows.CONNECTOR_NAMESPACE_S11!r} namespace, so it "
            f"is not an S1.1 run and must not carry account evidence.\n"
            f"  Verification V13 only inspects runs in that namespace: attaching an account row to "
            f"a run outside it would create evidence no invariant ever checks. Capture a NEW "
            f"observation with --with-account-facts; connector_version is sealed at create_run and "
            f"cannot be changed on an existing run.")
    return ACCOUNT_EXIT_REFUSED, (
        f"The server REFUSED the account append ({code}). This is a deterministic S1.1 account "
        f"PERSISTENCE/INTEGRITY failure, not a broker value problem: a bad or unavailable equity "
        f"is stored as a valid degraded row and would NOT stop the cycle.\n"
        f"  The account evidence for run {run_id} is in an unknown or contradictory state, so the "
        f"run must NOT be sealed. Inspect read-only before deciding anything.")


def handle_account_refusal(client, envelope, code):
    """Shared terminal handling for a RETURNED account-append refusal. Returns the exit code.

    Used by BOTH the armed write and --resume-account-append so the two paths cannot drift. Never
    reached for a transport exception (outcome unknown -> class C, handled by the caller).

    Precedence is fixed and asserted: the ORIGINAL refusal is printed LAST, after any cleanup
    outcome, so a cleanup failure can never be mistaken for the reason the cycle stopped.
    """
    run_id = envelope["run_id"]
    kind = classify_account_refusal(code)

    if kind == ACCOUNT_REFUSAL_SEALED:
        # NO cleanup, NO retry, NO backfill. Deliberately identical to the S1 create_run seal rule.
        common.eprint(
            f"SEALED_RUN_REVIEW_REQUIRED - run {run_id} is already sealed, so an account append can "
            f"no longer be attached (the guard requires snapshot_status='started'). NO cleanup was "
            f"attempted: mark_snapshot_failed on a sealed run is both refused and wrong to ask "
            f"for. NO complete, NO reconcile, NO expire.\n"
            f"  If this run is in the S1.1 connector namespace and has no account row it is "
            f"S1_1_ACCOUNT_ROW_MISSING_ANOMALY -- hand it to review; do NOT backfill.")
        common.eprint(f"ORIGINAL FAILURE: stage={STAGE_ACCOUNT} code={code}")
        return ACCOUNT_EXIT_SEALED

    exit_code, guidance = _account_refusal_guidance(code, run_id)
    common.eprint(guidance)
    common.eprint("  NO complete_snapshot and NO reconcile were attempted.")
    _attempt_append_failed_cleanup(client, envelope, code)     # SECONDARY -- never masks the above
    common.eprint(f"ORIGINAL FAILURE: stage={STAGE_ACCOUNT} code={code}")
    return exit_code


def _attempt_append_failed_cleanup(client, envelope, original_code):
    """Class-B cleanup: attempt mt5_mark_snapshot_failed_v1(APPEND_FAILED) and report the outcome
    SEPARATELY. A cleanup failure must NEVER hide or replace the original error."""
    run_id = envelope["run_id"]
    reason = STAGE_FAILED_REASON[STAGE_ACCOUNT]
    print(f"  cleanup  : marking run {run_id} failed (reason={reason})")
    try:
        cl = client.mark_snapshot_failed(
            run_id=run_id, user_id=envelope["user_id"],
            source_account=envelope["source_account"], lease_token=envelope["lease_token"],
            reason_code=reason)
        if cl.get("o_ok"):
            print(f"  cleanup  ok  run marked failed ({reason})")
        else:
            common.eprint(f"  cleanup FAILED: {cl.get('o_error_code')} "
                          f"(the ORIGINAL failure above is still {original_code})")
    except s1_client.S1ClientError as e:
        common.eprint(f"  cleanup FAILED: {e} (the ORIGINAL failure above is still {original_code})")


def run_expire(args, *, client_factory=None):
    """Deliberate operator recovery after a crash / ERR_RUN_ACTIVE. Calls ONLY
    mt5_expire_stale_run_v1. No broker read, no create/append/complete/reconcile, no loop."""
    if not common.is_uuid(args.expire_run):
        common.stop(f"--expire-run must be a run UUID (got {args.expire_run!r}).")
    if not common.is_uuid(args.user_id):
        common.stop("--expire-run requires --user-id <uuid>.")
    if not (args.source_account and str(args.source_account).strip()):
        common.stop("--expire-run requires --source-account <account>.")

    sb_url = os.environ.get("SUPABASE_URL")
    sb_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not sb_url or not sb_key:
        common.stop("--expire-run requires local SUPABASE_URL + SUPABASE_SERVICE_KEY env.", code=2)

    print("=" * 78)
    print("MT5 S1 EXPIRED-RUN RECOVERY  [mt5_expire_stale_run_v1 ONLY; no broker read]")
    print("=" * 78)
    print(f"run_id  : {args.expire_run}")
    print(f"account : {common.mask_login(str(args.source_account).strip())}")

    factory = client_factory or (lambda: s1_client.S1Client(sb_url, sb_key, log=print))
    client = factory()
    try:
        res = client.expire_stale_run(run_id=args.expire_run.strip(), user_id=args.user_id.strip(),
                                      source_account=str(args.source_account).strip())
    except s1_client.S1ClientError as e:
        common.eprint(f"expire_stale_run transport failure: {e}")
        return 5
    if not res.get("o_ok"):
        code = res.get("o_error_code")
        common.eprint(f"EXPIRE REFUSED: {code}")
        if code == "ERR_LEASE_NOT_EXPIRED":
            common.eprint("the lease has NOT expired yet - the cycle may still be running. Wait for "
                          "lease_expires_at and retry. Never recover with manual SQL.")
        return 6
    print("  EXPIRE   ok  the stale cycle is now terminal; a new run may be created.")
    return 0


# =============================================================================================
# CLI
# =============================================================================================
def parse_args(argv):
    ap = argparse.ArgumentParser(
        description="MT5 S1 one-shot snapshot adapter. Preview is the default and writes nothing; "
                    "an armed write replays an approved envelope and performs ZERO MT5 calls.")
    ap.add_argument("--user-id", dest="user_id", default=None, help="THUS auth uid (UUID).")
    ap.add_argument("--source-account", dest="source_account", default=None,
                    help="MT5 login / source_account.")
    ap.add_argument("--envelope", default=None,
                    help="Preview: where to seal the observation (default: "
                         f"{common.SAFE_OUT_PREFIX}s1_capture_<ts>.json). Write: the approved file.")
    ap.add_argument("--envelope-sha256", dest="envelope_sha256", default=None,
                    help="Write: the full 64-hex hash printed by the preview. Binds approval to the "
                         "canonical write payload (reformatting is harmless; any write-relevant "
                         "value change is not).")
    ap.add_argument("--max-envelope-age-seconds", dest="max_envelope_age_seconds", type=int,
                    default=MAX_ENVELOPE_AGE_DEFAULT,
                    help=f"Write: refuse a capture older than this (default {MAX_ENVELOPE_AGE_DEFAULT}s; "
                         f"the S1 freshness window is 1800s).")
    ap.add_argument("--lease-seconds", dest="lease_seconds", type=int, default=LEASE_SECONDS_DEFAULT,
                    help=f"Preview: sealed lease length (default {LEASE_SECONDS_DEFAULT}).")
    ap.add_argument("--connector-version", dest="connector_version", default=None,
                    help="Preview only. Default is resolved BY MODE (S1-only -> "
                         f"{CONNECTOR_VERSION_S1_DEFAULT}; --with-account-facts -> "
                         f"{CONNECTOR_VERSION_S11_DEFAULT}). An explicit value must belong to the "
                         "selected mode's namespace; it is validated, never rewritten.")
    ap.add_argument("--policy-version", dest="policy_version", default=POLICY_VERSION_DEFAULT)
    ap.add_argument("--max-positions", dest="max_positions", type=int, default=MAX_POSITIONS_DEFAULT)
    ap.add_argument("--with-account-facts", dest="with_account_facts", action="store_true",
                    help="S1.1: capture the T1.5 account sample (equity/balance/currency), emit "
                         "envelope v2, and append one immutable account row. Required on BOTH the "
                         "preview and the matching --write, and rejects a v1 envelope.")
    ap.add_argument("--resume-account-append", dest="resume_account_append", action="store_true",
                    help="S1.1 class-C recovery ONLY: replay the SAME approved v2 envelope's "
                         "account append after an unknown transport outcome, while the run is "
                         "still 'started' and the lease is live. No MT5 read, no recapture, one "
                         "bounded request. Never automatic.")
    ap.add_argument("--write", action="store_true", help="Key 1/4 to arm the single write cycle.")
    ap.add_argument("--confirm", default=None,
                    help=f"Key 2/4: exactly {CONFIRM_WRITE} (or {CONFIRM_EXPIRE} for --expire-run).")
    ap.add_argument("--expire-run", dest="expire_run", default=None,
                    help="DELIBERATE TERMINAL RECOVERY (not a retry): expire ONE stale run_id via "
                         "mt5_expire_stale_run_v1 only. Use ONLY after the lease has actually "
                         "expired and the run state has been inspected read-only. On a "
                         "complete+reconcile-pending run this leaves snapshot_status=complete with "
                         "reconcile_status=failed - the snapshot survives as broker evidence but "
                         "lifecycle reconcile is TERMINAL and a NEW cycle is required.")
    ap.add_argument("--self-test", action="store_true", help="Run the pure test suite (no MT5, no DB).")
    return ap.parse_args(argv)


def main(argv):
    args = parse_args(argv)

    if args.self_test:
        try:
            from . import test_s1_snapshot
        except ImportError:
            import test_s1_snapshot
        return test_s1_snapshot.main()

    if args.resume_account_append:
        if args.expire_run:
            common.stop("--resume-account-append and --expire-run are mutually exclusive modes.")
        if not args.with_account_facts:
            common.stop("--resume-account-append is an S1.1 recovery mode; pass "
                        "--with-account-facts so the v2 envelope contract is explicit.")
        status, reason = arming_status(
            write=True, confirm=args.confirm, envelope=args.envelope,
            envelope_sha256=args.envelope_sha256, write_env=os.environ.get(WRITE_ENV))
        if status == "stop":
            common.stop(reason)
        return run_resume_account_append(args)

    if args.expire_run:
        if args.write:
            common.stop("--expire-run and --write are mutually exclusive modes.")
        status, reason = expire_arming_status(
            confirm=args.confirm, write_env=os.environ.get(WRITE_ENV))
        if status == "stop":
            common.stop(reason)
        return run_expire(args)

    mode, reason = arming_status(
        write=args.write, confirm=args.confirm, envelope=args.envelope,
        envelope_sha256=args.envelope_sha256,
        write_env=os.environ.get(WRITE_ENV) if args.write else None)
    if mode == "stop":
        common.stop(reason)
    if mode == "preview":
        return run_preview(args)
    return run_write(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
