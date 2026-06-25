#!/usr/bin/env python3
"""
MT5 Auto Draft Import — Phase 0C-2 DRY-RUN staging row builder.

WHAT THIS IS
    Reads MT5 (read-only, same boundaries as probe.py) and transforms observed open positions /
    deals / symbol_info into dictionaries shaped for `public.mt5_import_staging`. It prints a
    redacted dry-run summary and (optionally) writes a redacted JSON to a git-ignored local path.

WHAT THIS IS NOT (hard guarantees — design: ../../artifacts/mt5_auto_draft_import/phase_0c_staging_writer_design.md)
    - It does NOT import/initialize any Supabase client; it does NOT read SUPABASE_URL/SERVICE_KEY.
    - It does NOT write to mt5_import_staging / mt5_import_cursors / mt5_import_groups, or call the RPCs.
    - It does NOT write to trades/products/portfolio/notes/trade_groups, Storage, or any DB.
    - It does NOT place/modify/close any MT5 order or position (read-only API calls only).
    - It builds row *dicts* in memory and prints/optionally-dumps them. Nothing is persisted to a DB.

Requires (for a live run): Windows + Python + `MetaTrader5`, terminal running & logged in.
The conversion/mapping logic is pure and unit-tested via `--self-test` (no MT5 needed).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

import common
import tz

# Static self-audit marker (NOT consumed at runtime; see common.py / probe.py).
_FORBIDDEN_ENV = ("SUPABASE_SERVICE_KEY", "SUPABASE_URL")

MAX_REASONABLE_DAYS = 400
NEEDS_MAPPING_CLASSES = ("ssf", "futures", "unknown")  # no THUS product exists for these yet


# ---------------------------------------------------------------------------------------------
# Pure mapping helpers (no MT5, no I/O) — these are what `--self-test` exercises.
# ---------------------------------------------------------------------------------------------
def initial_state(instrument_class: str) -> str:
    """Unmapped futures/SSF/ambiguous -> 'needs_mapping' (gated out of grouping until a human maps);
    mapped/common instruments -> 'new'. No THUS products are resolved in this slice."""
    return "needs_mapping" if (instrument_class or "unknown") in NEEDS_MAPPING_CLASSES else "new"


def _side(type_code) -> str | None:
    name = common.POSITION_TYPE_NAMES.get(type_code)
    return name.lower() if name else None


def _iso(dt) -> str | None:
    return tz.utc_iso(dt)


def classify_deal_kind(dtype, entry) -> str:
    """Classify an MT5 deal into a staging `kind`. deal_id keys close/partial/balance identically,
    so partial-vs-full is DEFERRED (treated as 'close'). Opening executions (entry=IN) and other
    non-trade deal types are 'unknown' — opens are sourced from positions_get, not the deal stream."""
    if dtype == 2:            # DEAL_TYPE_BALANCE
        return "balance"
    if dtype in (0, 1):       # BUY / SELL trade deal
        if entry in (1, 3):   # OUT / OUT_BY -> closes/reduces a position
            return "close"    # partial deferred (deal_id keys both identically)
        return "unknown"      # IN (opening) / INOUT -> opens come from positions_get
    return "unknown"          # credit/charge/dividend/commission/etc (rare here)


def map_open_position(p: dict, user_id: str, source_account: str, now_iso: str, symbols_meta: dict):
    """(row, None) or (None, skip). Open rows REQUIRE a stable position_id (identifier|ticket)."""
    symbol = p.get("symbol")
    position_id = p.get("identifier") or p.get("ticket")
    if not position_id:  # None or 0 -> never fabricate a key
        return None, {"kind": "open", "symbol": symbol, "reason": "missing position_id/ticket"}
    meta = symbols_meta.get(symbol, {})
    icls = meta.get("instrument_class", "unknown")
    raw_epoch = p.get("time")
    row = {
        "user_id": user_id,
        "source_account": source_account,
        "kind": "open",
        "symbol_raw": symbol,
        "normalized_symbol": symbol,            # no normalization rule yet -> verbatim
        "instrument_path": meta.get("path"),
        "instrument_class": icls,
        "contract_size": meta.get("contract_size"),
        "digits": meta.get("digits"),
        "product_id_candidate": None,           # no safe/unambiguous hint in this slice
        "side": _side(p.get("type")),
        "volume": p.get("volume"),
        "price": p.get("price_open"),
        "open_time": _iso(tz.bkk_epoch_to_utc(raw_epoch)),
        "mt5_time": _iso(tz.bkk_epoch_to_utc(raw_epoch)),
        "mt5_time_msc": p.get("time_msc"),
        "mt5_time_raw_epoch": raw_epoch,
        "server_tz": tz.SERVER_TZ_LABEL,
        "position_id": position_id,
        "ticket": p.get("ticket"),
        "position_state": "open",
        "first_seen_open_at": now_iso,
        "last_seen_open_at": now_iso,
        "state": initial_state(icls),
        "raw": p,
    }
    return row, None


def map_deal(d: dict, user_id: str, source_account: str, symbols_meta: dict):
    """(row, None) or (None, skip). Deal rows REQUIRE a stable deal_id (the deal `ticket`).
    Balance rows may have position_id == 0; that is fine as long as deal_id exists."""
    deal_id = d.get("ticket")
    if not deal_id:  # None or 0 -> never fabricate a key
        return None, {"kind": "deal", "symbol": d.get("symbol"), "reason": "missing deal_id"}
    symbol = d.get("symbol")
    meta = symbols_meta.get(symbol, {})
    icls = meta.get("instrument_class", "unknown")
    kind = classify_deal_kind(d.get("type"), d.get("entry"))
    raw_epoch = d.get("time")
    row = {
        "user_id": user_id,
        "source_account": source_account,
        "kind": kind,
        "symbol_raw": symbol,
        "normalized_symbol": symbol,
        "instrument_path": meta.get("path"),
        "instrument_class": icls,
        "contract_size": meta.get("contract_size"),
        "digits": meta.get("digits"),
        "product_id_candidate": None,
        "side": _side(d.get("type")),
        "volume": d.get("volume"),
        "price": d.get("price"),
        "close_time": _iso(tz.bkk_epoch_to_utc(raw_epoch)),
        "mt5_time": _iso(tz.bkk_epoch_to_utc(raw_epoch)),
        "mt5_time_msc": d.get("time_msc"),
        "mt5_time_raw_epoch": raw_epoch,
        "server_tz": tz.SERVER_TZ_LABEL,
        "position_id": d.get("position_id"),
        "deal_id": deal_id,
        "order_id": d.get("order"),
        "ticket": deal_id,
        "external_id": d.get("external_id"),
        "commission": d.get("commission"),
        "swap": d.get("swap"),
        "fee": d.get("fee"),
        "broker_profit": d.get("profit"),
        "state": initial_state(icls),
        "raw": d,
    }
    return row, None


def delta_guard(symbols_meta: dict, rows: list):
    """Verify DELTAU26 (TFEX single-stock-future) never collapses onto the DELTA stock preset."""
    sym = "DELTAU26"
    meta = symbols_meta.get(sym)
    if not meta:
        return {"observed": False}
    drows = [r for r in rows if r.get("symbol_raw") == sym]
    csize_1000 = meta.get("contract_size") == 1000
    class_ok = meta.get("instrument_class") in ("ssf", "futures")
    if drows:
        state_ok = all(r.get("state") == "needs_mapping" for r in drows)
        no_hint = all(r.get("product_id_candidate") is None for r in drows)
    else:
        state_ok = initial_state(meta.get("instrument_class")) == "needs_mapping"
        no_hint = True
    return {
        "observed": True,
        "contract_size": meta.get("contract_size"),
        "class_hint": meta.get("instrument_class"),
        "csize_1000": csize_1000,
        "class_ok": class_ok,
        "state_needs_mapping": state_ok,
        "no_product_hint": no_hint,
        "passed": bool(csize_1000 and class_ok and state_ok and no_hint),
    }


# ---------------------------------------------------------------------------------------------
# CLI / window
# ---------------------------------------------------------------------------------------------
def parse_args(argv):
    ap = argparse.ArgumentParser(
        description="MT5 Phase 0C-2 DRY-RUN staging row builder. No Supabase, no DB writes.",
    )
    ap.add_argument("--user-id", dest="user_id", default=None,
                    help="THUS auth uid (UUID) to stamp on staging rows. Required for a live run.")
    ap.add_argument("--source-account", dest="source_account", default=None,
                    help="MT5 login / source_account (text). Required for a live run.")
    ap.add_argument("--days", type=int, default=7,
                    help="Bounded history window in days back from now (default: 7). Must be >= 1.")
    ap.add_argument("--from", dest="date_from", default=None, help="Explicit start YYYY-MM-DD.")
    ap.add_argument("--to", dest="date_to", default=None, help="Explicit end YYYY-MM-DD (default: now).")
    ap.add_argument("--symbols", nargs="*", default=None,
                    help="Extra symbols to force symbol_info on (e.g. DELTAU26 GOU26 S50U26).")
    ap.add_argument("--out", default=None,
                    help="Optional REDACTED JSON dump. MUST be git-ignored (or under "
                         "ops/mt5_import/out/); trackable paths are refused. Default: no file.")
    ap.add_argument("--self-test", action="store_true",
                    help="Run pure-logic self-tests (no MT5, no DB) and exit.")
    return ap.parse_args(argv)


def resolve_window(args):
    """(from_dt, to_dt) — always finite/bounded. Refuse unbounded 'all history'."""
    now = datetime.now()
    to_dt = _parse_ymd(args.date_to, "--to") if args.date_to else now
    if args.date_from:
        from_dt = _parse_ymd(args.date_from, "--from")
    else:
        if args.days < 1:
            common.stop("history window must be bounded: --days must be >= 1 (refusing unbounded 'all history').")
        from_dt = to_dt - timedelta(days=args.days)
    if from_dt >= to_dt:
        common.stop(f"invalid window: from ({from_dt:%Y-%m-%d}) must be before to ({to_dt:%Y-%m-%d}).")
    if (to_dt - from_dt).days > MAX_REASONABLE_DAYS:
        common.eprint(f"WARN: history window is {(to_dt - from_dt).days} days (> {MAX_REASONABLE_DAYS}); "
                      f"large but bounded - proceeding.")
    return from_dt, to_dt


def _parse_ymd(s, flag):
    try:
        return datetime.strptime(s, "%Y-%m-%d")
    except (ValueError, TypeError):
        common.stop(f"invalid {flag} {s!r}: use YYYY-MM-DD (e.g. 2026-06-25).")


# ---------------------------------------------------------------------------------------------
# Main (live, read-only)
# ---------------------------------------------------------------------------------------------
def main(argv):
    args = parse_args(argv)

    if args.self_test:
        return self_test()

    # Validate --out FIRST (fail fast; never create a file at a trackable path, never connect MT5).
    if args.out:
        ok, reason = common.is_ignored_output_path(args.out)
        if not ok:
            common.stop(f"Refusing --out path because it is not git-ignored. Use ops/mt5_import/out/... "
                        f"(path={args.out!r}: {reason}).")

    # Identity required for real rows (NOT read from .env; never a Supabase secret).
    if not common.is_uuid(args.user_id):
        common.stop(f"--user-id must be a UUID (got {args.user_id!r}). This stamps staging.user_id "
                    f"so browser RLS SELECT-own works; it is not read from .env.")
    if not (args.source_account and str(args.source_account).strip()):
        common.stop("--source-account must be a non-empty string (the MT5 login / source_account).")
    user_id = args.user_id.strip()
    source_account = str(args.source_account).strip()

    try:
        import MetaTrader5 as mt5  # type: ignore
    except Exception as e:
        common.stop(f"could not import MetaTrader5 ({e!r}). Install with `pip install MetaTrader5` "
                    f"on Windows and ensure the MT5 terminal is running & logged in.", code=2)

    from_dt, to_dt = resolve_window(args)
    now_iso = tz.utc_iso(datetime.now(timezone.utc))

    if not mt5.initialize():
        common.stop(f"mt5.initialize() failed: {mt5.last_error()}. Is the terminal running & logged in?", code=3)

    try:
        acct = common.as_dict(mt5.account_info())
        if acct is None:
            common.stop("account_info() returned None - terminal not logged in?", code=3)
        if str(acct.get("login")) != source_account:
            common.eprint(f"WARN: --source-account {source_account!r} != terminal login "
                          f"{common.mask_login(acct.get('login'))}. The writer slice will STOP on this; "
                          f"dry-run continues for inspection.")
        if acct.get("margin_mode") != 2:
            common.eprint("WARN: margin_mode is not RETAIL_HEDGING (2); the writer must re-check before insert.")

        positions = mt5.positions_get() or ()
        deals = mt5.history_deals_get(from_dt, to_dt)
        if deals is None:
            err = mt5.last_error()
            if isinstance(err, (tuple, list)) and err and err[0] == 1:
                common.eprint(f"WARN: history_deals_get returned None but MT5 reports no error ({err}); "
                              f"treating as zero deals.")
                deals = ()
            else:
                common.stop(f"history_deals_get returned None (MT5 error: {err}) - aborting.", code=3)

        # Build symbol metadata (read-only) for every observed/requested symbol.
        symbols = set(args.symbols or [])
        for p in positions:
            symbols.add(common.as_dict(p).get("symbol"))
        for d in deals:
            s = common.as_dict(d).get("symbol")
            if s:
                symbols.add(s)
        symbols.discard(None)
        symbols.discard("")
        symbols_meta = {}
        for s in sorted(symbols):
            si = common.as_dict(mt5.symbol_info(s))
            if si is None:
                symbols_meta[s] = {}
                continue
            path = si.get("path")
            symbols_meta[s] = {
                "path": path,
                "instrument_class": common.rough_instrument_class(path, s),
                "contract_size": si.get("trade_contract_size"),
                "digits": si.get("digits"),
            }

        # Map -> staging rows (pure).
        rows, skipped = [], []
        for p in positions:
            row, skip = map_open_position(common.as_dict(p), user_id, source_account, now_iso, symbols_meta)
            (rows if row else skipped).append(row or skip)
        for d in deals:
            row, skip = map_deal(common.as_dict(d), user_id, source_account, symbols_meta)
            (rows if row else skipped).append(row or skip)

        report = _build_report(args, user_id, source_account, from_dt, to_dt,
                               rows, skipped, symbols_meta, acct)
        _print_summary(report, rows, symbols_meta)

        if args.out:
            parent = os.path.dirname(args.out)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(args.out, "w", encoding="utf-8") as f:
                json.dump(report, f, indent=2, default=str)
            print(f"\nWrote redacted JSON -> {args.out}")
            print("  (login masked; user_id/source_account as provided; no secrets, no env, no service_role.)")
        else:
            print("\n(No file written. Pass --out <git-ignored path> to save a redacted JSON.)")

        print("\nDONE. DRY-RUN only - built row dicts in memory; nothing written to MT5 or any database.")
    finally:
        mt5.shutdown()
    return 0


def _build_report(args, user_id, source_account, from_dt, to_dt, rows, skipped, symbols_meta, acct):
    kind_counts = {}
    for r in rows:
        kind_counts[r["kind"]] = kind_counts.get(r["kind"], 0) + 1
    return {
        "metadata": {
            "slice": "0C-2 dry-run staging row builder",
            "user_id": user_id,
            "source_account": source_account,
            "terminal_login_masked": common.mask_login(acct.get("login")) if acct else None,
            "margin_mode": acct.get("margin_mode") if acct else None,
            "dry_run": True,
            "wrote_to_db": False,
        },
        "window": {"from": from_dt.strftime("%Y-%m-%d"), "to": to_dt.strftime("%Y-%m-%d"),
                   "days": (to_dt - from_dt).days, "bounded": True},
        "summary": {
            "open_rows": kind_counts.get("open", 0),
            "deal_rows_by_kind": {k: v for k, v in kind_counts.items() if k != "open"},
            "rows_total": len(rows),
            "skipped_total": len(skipped),
            "missing_position_key": sum(1 for s in skipped if s.get("kind") == "open"),
            "missing_deal_key": sum(1 for s in skipped if s.get("kind") == "deal"),
            "symbols": sorted(symbols_meta.keys()),
            "contract_sizes": {s: m.get("contract_size") for s, m in sorted(symbols_meta.items())},
        },
        "delta_guard": delta_guard(symbols_meta, rows),
        "timezone_diagnostics": {
            "note": "MT5 epochs are Asia/Bangkok wall-clock (+7); rows store true UTC (wall-7h) and "
                    "preserve mt5_time_raw_epoch + mt5_time_msc.",
            "server_tz_label": tz.SERVER_TZ_LABEL,
            "samples": [
                {"raw_epoch": r.get("mt5_time_raw_epoch"),
                 "raw_wallclock": str(tz.raw_wallclock(r.get("mt5_time_raw_epoch"))),
                 "utc": r.get("mt5_time")}
                for r in rows[:3]
            ],
        },
        "rows": rows,
        "skipped": skipped,
    }


def _print_summary(report, rows, symbols_meta):
    s = report["summary"]
    print("=" * 72)
    print("MT5 DRY-RUN STAGING ROW BUILDER (0C-2) - no Supabase, no DB writes")
    print("=" * 72)
    w = report["window"]
    print(f"window: {w['from']} .. {w['to']} ({w['days']} days) [bounded]")
    print(f"open rows         : {s['open_rows']}")
    print(f"deal rows by kind : {s['deal_rows_by_kind']}")
    print(f"rows total        : {s['rows_total']}")
    print(f"skipped (no key)  : {s['skipped_total']} "
          f"(open missing position_id={s['missing_position_key']}, deal missing deal_id={s['missing_deal_key']})")
    for sk in report["skipped"][:10]:
        print(f"  - SKIP {sk.get('kind')} {sk.get('symbol')}: {sk.get('reason')}")
    print(f"symbols           : {', '.join(s['symbols']) or '(none)'}")
    print(f"contract_sizes    : {s['contract_sizes']}")
    g = report["delta_guard"]
    if g.get("observed"):
        print(f"DELTAU26 guard    : {'PASS' if g['passed'] else 'FAIL'} "
              f"(csize={g['contract_size']} class={g['class_hint']} "
              f"needs_mapping={g['state_needs_mapping']} no_product_hint={g['no_product_hint']})")
    else:
        print("DELTAU26 guard    : (not observed/requested)")
    print("UTC conversion samples (raw wall-clock -> true UTC):")
    for smp in report["timezone_diagnostics"]["samples"]:
        print(f"  - epoch={smp['raw_epoch']} wall={smp['raw_wallclock']} -> {smp['utc']}")


# ---------------------------------------------------------------------------------------------
# Self-test (no MT5, no DB)
# ---------------------------------------------------------------------------------------------
def self_test():
    fails = []
    fails += [f"tz: {x}" for x in tz.selfcheck()]

    # UUID validation
    if not common.is_uuid("123e4567-e89b-12d3-a456-426614174000"):
        fails.append("is_uuid rejected a valid uuid")
    if common.is_uuid("not-a-uuid") or common.is_uuid("") or common.is_uuid(None):
        fails.append("is_uuid accepted an invalid value")

    # --out guard
    ok_root, _ = common.is_ignored_output_path("rows.json")
    ok_out, _ = common.is_ignored_output_path("ops/mt5_import/out/x.json")
    if ok_root:
        fails.append("is_ignored_output_path allowed a root trackable path")
    if not ok_out:
        fails.append("is_ignored_output_path blocked the safe out/ path")

    # DELTAU26 mapping guard on a synthetic symbol_info-like input
    symbols_meta = {
        "DELTAU26": {"path": "TFEX\\Single Stock Futures\\DELTAU26",
                     "instrument_class": common.rough_instrument_class("TFEX\\Single Stock Futures\\DELTAU26"),
                     "contract_size": 1000, "digits": 2},
        "DELTA": {"path": "TFEX\\SET\\DELTA",
                  "instrument_class": common.rough_instrument_class("TFEX\\SET\\DELTA"),
                  "contract_size": 1, "digits": 2},
    }
    open_pos = {"symbol": "DELTAU26", "identifier": 999, "ticket": 999, "type": 1,
                "volume": 1.0, "price_open": 336.5, "time": 1782420725, "time_msc": 1782420725000}
    row, skip = map_open_position(open_pos, "123e4567-e89b-12d3-a456-426614174000", "3000020",
                                  "2026-06-25T00:00:00Z", symbols_meta)
    if skip or not row:
        fails.append("DELTAU26 open mapping unexpectedly skipped")
    else:
        if row["instrument_class"] != "ssf":
            fails.append(f"DELTAU26 class hint should be 'ssf', got {row['instrument_class']!r}")
        if row["contract_size"] != 1000:
            fails.append(f"DELTAU26 contract_size should be 1000, got {row['contract_size']!r}")
        if row["state"] != "needs_mapping":
            fails.append(f"DELTAU26 state should be 'needs_mapping', got {row['state']!r}")
        if row["product_id_candidate"] is not None:
            fails.append("DELTAU26 product_id_candidate must be None (no stock DELTA hint)")
    g = delta_guard(symbols_meta, [row] if row else [])
    if not g.get("passed"):
        fails.append(f"delta_guard did not pass: {g}")

    # A DELTA stock row must be 'new' (mapped/common path), proving the SSF/stock split.
    stock = {"symbol": "DELTA", "identifier": 1000, "ticket": 1000, "type": 0,
             "volume": 100.0, "price_open": 70.0, "time": 1782420725, "time_msc": 1782420725000}
    srow, _ = map_open_position(stock, "123e4567-e89b-12d3-a456-426614174000", "3000020",
                                "2026-06-25T00:00:00Z", symbols_meta)
    if srow and srow["state"] != "new":
        fails.append(f"DELTA stock state should be 'new', got {srow['state']!r}")

    # missing-key skips
    _, sk_open = map_open_position({"symbol": "GOU26", "identifier": 0, "ticket": 0}, "u", "a", "t", {})
    if not sk_open:
        fails.append("open with no position_id was not skipped")
    _, sk_deal = map_deal({"symbol": "GOU26", "ticket": 0}, "u", "a", {})
    if not sk_deal:
        fails.append("deal with no deal_id was not skipped")

    # deal kind classification
    if classify_deal_kind(2, 0) != "balance":
        fails.append("balance deal misclassified")
    if classify_deal_kind(1, 1) != "close":
        fails.append("OUT trade deal not classified as close")
    if classify_deal_kind(0, 0) != "unknown":
        fails.append("IN trade deal not classified as unknown")

    # balance deal keyed by deal_id with position_id 0 must still build
    brow, bskip = map_deal({"symbol": None, "ticket": 555, "type": 2, "entry": 0,
                            "position_id": 0, "profit": -0.57, "time": 1782420725}, "u", "a", {})
    if bskip or not brow or brow["kind"] != "balance" or brow["deal_id"] != 555:
        fails.append("balance deal (position_id=0, deal_id present) did not build correctly")

    print("build_rows self-test:", "PASS" if not fails else "FAIL")
    for x in fails:
        print("  -", x)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
