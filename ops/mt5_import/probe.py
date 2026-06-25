#!/usr/bin/env python3
"""
MT5 Auto Draft Import — Phase 0C-1 read-only probe.

WHAT THIS IS
    A read-only diagnostic that attaches to the LOCAL, already-running MetaTrader 5
    terminal and prints a redacted summary of account / open positions / recent deals /
    symbol info, plus a timezone diagnostic. It exists to confirm the field shapes the
    later staging-row builder (0C-2) and writer (0C-3) will consume.

WHAT THIS IS NOT (hard guarantees — see ../../artifacts/mt5_auto_draft_import/phase_0c_staging_writer_design.md)
    - It does NOT import or initialize any Supabase client.
    - It does NOT read SUPABASE_URL or SUPABASE_SERVICE_KEY (or any service_role secret).
    - It does NOT write to mt5_import_staging / mt5_import_cursors / mt5_import_groups.
    - It does NOT call mt5_confirm_group / mt5_set_leg_state / mt5_mark_materialized.
    - It does NOT write to trades / products / portfolio / notes / trade_groups / Storage.
    - It does NOT place / modify / close any MT5 order or position (read-only API calls only).
    - It does NOT convert timezones or insert anything; it only *reports* raw time fields.
    - By default it writes NO files (optional --out writes a redacted JSON to an ignored path).

Requires: Windows + Python + the `MetaTrader5` package, with the MT5 terminal running & logged in.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

# --- Self-audit marker (NOT consumed at runtime) ----------------------------------------------
# This is a static grep/self-audit anchor: a CI/grep check (or a human) can confirm these names
# appear ONLY here and never inside an os.getenv/os.environ call — i.e. the probe never *reads* a
# Supabase/service_role secret. Intentionally inert; do not wire any Supabase env into this slice.
_FORBIDDEN_ENV = ("SUPABASE_SERVICE_KEY", "SUPABASE_URL")

MARGIN_MODE_NAMES = {0: "RETAIL_NETTING", 1: "EXCHANGE", 2: "RETAIL_HEDGING"}
POSITION_TYPE_NAMES = {0: "BUY", 1: "SELL"}
DEAL_TYPE_NAMES = {
    0: "BUY", 1: "SELL", 2: "BALANCE", 3: "CREDIT", 4: "CHARGE",
    5: "CORRECTION", 6: "BONUS", 7: "COMMISSION", 8: "COMMISSION_DAILY",
    9: "COMMISSION_MONTHLY", 10: "COMMISSION_AGENT_DAILY", 11: "COMMISSION_AGENT_MONTHLY",
    12: "INTEREST", 13: "BUY_CANCELED", 14: "SELL_CANCELED", 15: "DIVIDEND",
    16: "DIVIDEND_FRANKED", 17: "TAX",
}
DEAL_ENTRY_NAMES = {0: "IN", 1: "OUT", 2: "INOUT", 3: "OUT_BY"}

MAX_REASONABLE_DAYS = 400  # soft cap — warn beyond this; we still refuse "all history".


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def stop(msg: str, code: int = 2):
    """Fail safe: clear message, non-zero exit, no writes, no fabrication."""
    eprint("STOP:", msg)
    sys.exit(code)


SAFE_OUT_PREFIX = "ops/mt5_import/out/"


def _norm_path(p: str) -> str:
    return os.path.normpath(p).replace("\\", "/")


def _git_check_ignore_rc(path: str):
    """git check-ignore exit code: 0 = ignored, 1 = not ignored, None = git unavailable / error."""
    try:
        r = subprocess.run(["git", "check-ignore", "--quiet", path], capture_output=True)
        return r.returncode
    except Exception:
        return None


def is_ignored_output_path(path: str):
    """(allowed, reason). --out is allowed ONLY if the path is git-ignored OR under
    ops/mt5_import/out/. If git is unavailable, fall back to a STRICT prefix-only allowlist so we
    never write account-bearing JSON to a trackable path."""
    norm = _norm_path(path)
    under_prefix = norm == SAFE_OUT_PREFIX.rstrip("/") or norm.startswith(SAFE_OUT_PREFIX)
    rc = _git_check_ignore_rc(path)
    if rc == 0:
        return True, "git-ignored"
    if under_prefix:
        return True, "under ops/mt5_import/out/"
    if rc is None:
        return False, "git unavailable and path is not under ops/mt5_import/out/"
    return False, "path is not git-ignored"


def _parse_date(s: str, flag: str) -> datetime:
    """Parse YYYY-MM-DD or STOP cleanly (no traceback)."""
    try:
        return datetime.strptime(s, "%Y-%m-%d")
    except (ValueError, TypeError):
        stop(f"invalid {flag} {s!r}: use YYYY-MM-DD (e.g. 2026-06-25).")


def mask_login(login, show: bool) -> str:
    if login is None:
        return "(unknown)"
    s = str(login)
    if show or len(s) <= 4:
        return s
    return s[:2] + "*" * (len(s) - 4) + s[-2:]


def rough_instrument_class(path: str | None, symbol: str | None) -> str:
    """HINT ONLY. Derived from symbol_info.path; never authoritative, never coerces mapping."""
    p = (path or "").lower()
    if "single stock future" in p or "\\ssf" in p or "/ssf" in p:
        return "ssf"
    if "future" in p:
        return "futures"
    if "stock" in p or "\\set" in p or "/set" in p or "equity" in p or "share" in p:
        return "stock"
    if "forex" in p or "\\fx" in p or "/fx" in p or "currency" in p:
        return "forex"
    if "crypto" in p:
        return "crypto"
    if "index" in p or "indices" in p:
        return "index"
    if "metal" in p or "commodit" in p:
        return "commodity"
    return "unknown"


def as_dict(obj):
    """MT5 namedtuple-likes expose _asdict(); fall back to attribute scrape."""
    if obj is None:
        return None
    if hasattr(obj, "_asdict"):
        try:
            return dict(obj._asdict())
        except Exception:
            pass
    return {k: getattr(obj, k) for k in dir(obj) if not k.startswith("_") and not callable(getattr(obj, k))}


def fmt_epoch(ts) -> str:
    """Render an MT5 epoch (seconds) as-is. NOTE: MT5 server time behaves as Asia/Bangkok
    wall-clock (+7 vs true UTC). We DO NOT convert here — the writer (0C-3) owns that."""
    try:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + " (raw MT5 wall-clock)"
    except Exception:
        return str(ts)


def parse_args(argv):
    ap = argparse.ArgumentParser(
        description="MT5 read-only probe (Phase 0C-1). No Supabase, no service_role, no writes.",
    )
    ap.add_argument("--days", type=int, default=7,
                    help="Bounded history window in days back from now (default: 7). Must be >= 1.")
    ap.add_argument("--from", dest="date_from", default=None,
                    help="Explicit history start YYYY-MM-DD (overrides --days lower bound).")
    ap.add_argument("--to", dest="date_to", default=None,
                    help="Explicit history end YYYY-MM-DD (default: now).")
    ap.add_argument("--symbols", nargs="*", default=None,
                    help="Extra symbols to force symbol_info on (e.g. DELTAU26 GOU26).")
    ap.add_argument("--show-login", action="store_true",
                    help="Show the full account login (default: masked).")
    ap.add_argument("--out", default=None,
                    help="Optional path to write a REDACTED JSON dump. MUST be a git-ignored path "
                         "(or under ops/mt5_import/out/); trackable paths are refused. "
                         "e.g. ops/mt5_import/out/probe_YYYYMMDD.json. Default: no file written.")
    return ap.parse_args(argv)


def resolve_window(args):
    """Return (from_dt, to_dt) — always finite/bounded. Refuse unbounded 'all history'."""
    now = datetime.now()
    to_dt = _parse_date(args.date_to, "--to") if args.date_to else now
    if args.date_from:
        from_dt = _parse_date(args.date_from, "--from")
    else:
        if args.days < 1:
            stop("history window must be bounded: --days must be >= 1 (refusing unbounded 'all history').")
        from_dt = to_dt - timedelta(days=args.days)
    if from_dt >= to_dt:
        stop(f"invalid window: from ({from_dt:%Y-%m-%d}) must be before to ({to_dt:%Y-%m-%d}).")
    span_days = (to_dt - from_dt).days
    if span_days > MAX_REASONABLE_DAYS:
        eprint(f"WARN: history window is {span_days} days (> {MAX_REASONABLE_DAYS}); large but bounded — proceeding.")
    return from_dt, to_dt


def main(argv):
    args = parse_args(argv)

    # Validate --out FIRST (fail fast; never create a file at a trackable/unsafe path, and never
    # connect to MT5 for a doomed run).
    if args.out:
        ok, reason = is_ignored_output_path(args.out)
        if not ok:
            stop(f"Refusing --out path because it is not git-ignored. Use ops/mt5_import/out/... "
                 f"(path={args.out!r}: {reason}).", code=2)

    # Import guard — fail safe if MetaTrader5 is unavailable. No fabrication.
    try:
        import MetaTrader5 as mt5  # type: ignore
    except Exception as e:  # ImportError or platform error
        stop(f"could not import MetaTrader5 ({e!r}). Install with `pip install MetaTrader5` "
             f"on Windows and ensure the MT5 terminal is running & logged in.", code=2)

    from_dt, to_dt = resolve_window(args)

    # Attach to the already-running / logged-in terminal (no credentials passed).
    if not mt5.initialize():
        err = mt5.last_error()
        stop(f"mt5.initialize() failed: {err}. Is the MT5 terminal running & logged in?", code=3)

    report = {"window": {"from": from_dt.strftime("%Y-%m-%d"), "to": to_dt.strftime("%Y-%m-%d"),
                          "days": (to_dt - from_dt).days}}
    missing_position_key = 0
    missing_deal_key = 0

    try:
        # ---- account ------------------------------------------------------------------
        acct = mt5.account_info()
        if acct is None:
            stop("account_info() returned None — terminal not logged in?", code=3)
        a = as_dict(acct)
        login = a.get("login")
        margin_mode = a.get("margin_mode")
        print("=" * 72)
        print("MT5 READ-ONLY PROBE (0C-1) - no Supabase, no service_role, no writes")
        print("=" * 72)
        print("ACCOUNT")
        print(f"  login (source_account) : {mask_login(login, args.show_login)}")
        print(f"  server                 : {a.get('server')}")
        print(f"  currency               : {a.get('currency')}")
        print(f"  margin_mode            : {margin_mode} ({MARGIN_MODE_NAMES.get(margin_mode, '?')})")
        if margin_mode != 2:
            eprint("WARN: margin_mode is not RETAIL_HEDGING (2). Phase 0C assumes hedging "
                   "(scale-ins = distinct position_ids). Proceeding read-only; the writer slice "
                   "must re-check this before any insert.")
        report["account"] = {"login_masked": mask_login(login, False), "server": a.get("server"),
                             "currency": a.get("currency"), "margin_mode": margin_mode}

        print(f"\nHISTORY WINDOW: {report['window']['from']} .. {report['window']['to']} "
              f"({report['window']['days']} days)  [bounded]")

        # ---- open positions -----------------------------------------------------------
        positions = mt5.positions_get() or ()
        print(f"\nOPEN POSITIONS: {len(positions)}")
        pos_rows = []
        observed_symbols = set()
        for p in positions:
            d = as_dict(p)
            sym = d.get("symbol")
            observed_symbols.add(sym)
            position_id = d.get("identifier") or d.get("ticket")
            if position_id in (None, 0):
                missing_position_key += 1
            pos_rows.append({
                "symbol": sym,
                "ticket": d.get("ticket"),
                "position_id": d.get("identifier"),
                "type": POSITION_TYPE_NAMES.get(d.get("type"), d.get("type")),
                "volume": d.get("volume"),
                "price_open": d.get("price_open"),
                "time": d.get("time"),
                "time_msc": d.get("time_msc"),
            })
            print(f"  - {sym:<12} pos_id={d.get('identifier')} ticket={d.get('ticket')} "
                  f"{POSITION_TYPE_NAMES.get(d.get('type'), d.get('type'))} vol={d.get('volume')} "
                  f"open={d.get('price_open')} time={fmt_epoch(d.get('time'))}")
        report["open_positions"] = pos_rows

        # ---- deals (bounded) ----------------------------------------------------------
        deals = mt5.history_deals_get(from_dt, to_dt)
        if deals is None:
            err = mt5.last_error()
            # MT5 convention: last_error()[0] == 1 (RES_S_OK) means "no error".
            if isinstance(err, (tuple, list)) and err and err[0] == 1:
                eprint(f"WARN: history_deals_get returned None but MT5 reports no error ({err}); "
                       f"treating as zero deals in window.")
                deals = ()
            else:
                stop(f"history_deals_get returned None (MT5 error: {err}) - aborting to avoid "
                     f"misreporting an empty history.", code=3)
        print(f"\nDEALS in window: {len(deals)}")
        deal_rows = []
        for dl in deals:
            d = as_dict(dl)
            sym = d.get("symbol")
            if sym:
                observed_symbols.add(sym)
            deal_id = d.get("ticket")  # in MT5 the deal's `ticket` IS the deal_id
            dtype = d.get("type")
            is_balance = dtype == 2
            if deal_id in (None, 0):
                # balance/credit rows still carry a deal ticket; a truly key-less deal is a STOP-skip later
                missing_deal_key += 1
            deal_rows.append({
                "deal_id": deal_id,
                "position_id": d.get("position_id"),
                "symbol": sym,
                "type": DEAL_TYPE_NAMES.get(dtype, dtype),
                "entry": DEAL_ENTRY_NAMES.get(d.get("entry"), d.get("entry")),
                "reason": d.get("reason"),
                "volume": d.get("volume"),
                "price": d.get("price"),
                "profit": d.get("profit"),
                "commission": d.get("commission"),
                "swap": d.get("swap"),
                "fee": d.get("fee"),
                "time": d.get("time"),
                "time_msc": d.get("time_msc"),
                "is_balance": is_balance,
            })
        # print a capped sample so the terminal stays readable
        for r in deal_rows[:25]:
            print(f"  - deal={r['deal_id']} pos={r['position_id']} {str(r['symbol']):<12} "
                  f"{r['type']}/{r['entry']} vol={r['volume']} px={r['price']} pnl={r['profit']} "
                  f"t={fmt_epoch(r['time'])}")
        if len(deal_rows) > 25:
            print(f"  ... ({len(deal_rows) - 25} more deals not printed; use --out for full redacted JSON)")
        report["deals"] = deal_rows

        # ---- symbol info --------------------------------------------------------------
        for s in (args.symbols or []):
            observed_symbols.add(s)
        observed_symbols.discard(None)
        print(f"\nSYMBOL INFO ({len(observed_symbols)} symbols)")
        sym_rows = []
        for sym in sorted(observed_symbols):
            si = mt5.symbol_info(sym)
            if si is None:
                print(f"  - {sym:<12} (symbol_info unavailable)")
                sym_rows.append({"symbol": sym, "available": False})
                continue
            s = as_dict(si)
            path = s.get("path")
            cls = rough_instrument_class(path, sym)
            csize = s.get("trade_contract_size")
            sym_rows.append({"symbol": sym, "available": True, "path": path,
                            "trade_contract_size": csize, "digits": s.get("digits"),
                            "instrument_class_hint": cls})
            print(f"  - {sym:<12} csize={csize} digits={s.get('digits')} "
                  f"class_hint={cls}  path={path}")
        report["symbols"] = sym_rows

        # ---- timezone diagnostic ------------------------------------------------------
        print("\nTIMEZONE DIAGNOSTIC")
        print("  MT5 time fields above are raw server epochs that behave as Asia/Bangkok")
        print("  wall-clock (+7 vs true UTC). This probe does NOT convert or insert anything.")
        print("  The writer slice (0C-3) will store true UTC (wall - 7h) and keep raw epoch/time_msc.")
        sample_t = (pos_rows[0]["time"] if pos_rows else (deal_rows[0]["time"] if deal_rows else None))
        if sample_t is not None:
            print(f"  sample raw epoch={sample_t}  -> raw wall-clock {fmt_epoch(sample_t)}")

        # ---- safety summary -----------------------------------------------------------
        print("\nSAFETY / KEY AVAILABILITY")
        print(f"  open positions missing a stable position_id/ticket : {missing_position_key}")
        print(f"  deals missing a stable deal_id                     : {missing_deal_key}")
        print("  (the writer will SKIP+log any key-less row; it never blind-inserts - Phase 0A section 11.3)")
        report["key_health"] = {"positions_missing_key": missing_position_key,
                                "deals_missing_key": missing_deal_key}

        # ---- optional redacted out ----------------------------------------------------
        if args.out:
            out_path = args.out
            parent = os.path.dirname(out_path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump(report, f, indent=2, default=str)
            print(f"\nWrote redacted JSON -> {out_path}")
            print("  (login is masked in the JSON; no secrets, no env, no service_role.)")
        else:
            print("\n(No file written. Pass --out <ignored path> to save a redacted JSON.)")

        print("\nDONE. Read-only probe complete - nothing was written to MT5 or any database.")
    finally:
        mt5.shutdown()

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
