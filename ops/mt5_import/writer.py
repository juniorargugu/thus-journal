#!/usr/bin/env python3
"""
MT5 Auto Draft Import — Phase 0C-3a OPEN-ONLY staging writer.

Writes eligible `kind='open'` rows to `mt5_import_staging` ONLY. Dry-run by default; a real write
requires a THREE-key gate (`--write` + `--confirm WRITE_STAGING` + env `MT5_WRITE=1`) plus local
`SUPABASE_URL`/`SUPABASE_SERVICE_KEY`, a matching `--source-account`, and a `--max-write-count` cap.

HARD GUARANTEES (design: ../../artifacts/mt5_auto_draft_import/phase_0c3_writer_design.md)
  - DRY-RUN constructs NO Supabase client and reads NO `SUPABASE_*` / service_role env.
  - Writes ONLY `kind='open'` rows, ONLY to `mt5_import_staging` (via the allow-listed staging_db).
  - NO deals/balance/unknown writes, NO cursor, NO lifecycle reconcile, NO groups, NO RPCs,
    NO trades/products/portfolio/notes/trade_groups, NO Storage, NO upsert, NO DELETE.
  - Reuses the 0C-2 pure mappers from build_rows.py (build_rows.py is NOT modified).
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone

import common
import staging_db
import tz
from build_rows import map_deal, map_open_position, resolve_window  # 0C-2 pure mappers (reused)

MAX_WRITE_DEFAULT = 3
PATCH_ALLOWLIST = ("last_seen_open_at", "price", "volume", "mt5_time", "mt5_time_msc", "mt5_time_raw_epoch")
SKIP_EXISTING_STATES = frozenset({"materialized", "dismissed", "grouped"})  # browser/RPC-owned
WRITE_REQUIRED = ("user_id", "source_account", "kind", "position_id", "state")

# 0C-3b close/partial deals. The 0C-2 mapper currently emits only 'close' (partial deferred — deal_id
# keys both identically); 'partial' is accepted STRUCTURALLY for forward-compat. Deals are insert-once
# IMMUTABLE (NO PATCH). Idempotency key = (user_id, source_account, deal_id), kind in DEAL_KINDS.
DEAL_KINDS = ("close", "partial")
DEAL_WRITE_REQUIRED = ("user_id", "source_account", "kind", "deal_id", "state")


# ---------------------------------------------------------------------------------------------
# Pure helpers (no MT5, no DB) — exercised by --self-test
# ---------------------------------------------------------------------------------------------
def gate_status(write: bool, confirm, mt5_write_env):
    """('dry-run'|'armed', None) or ('stop', reason). Reads ONLY the passed values — the caller
    must NOT read MT5_WRITE/SUPABASE_* until this returns 'armed'."""
    if not write:
        return "dry-run", None
    if confirm != "WRITE_STAGING":
        return "stop", "--write requires --confirm WRITE_STAGING (exact literal). Refusing to arm."
    if mt5_write_env != "1":
        return "stop", "--write requires env MT5_WRITE=1. Refusing to arm."
    return "armed", None


def sanitize_open_for_insert(row: dict) -> dict:
    """Project a 0C-2 open row onto the exact staging columns; strip dry-run meta / non-schema keys;
    assert open + writer-eligible + required fields present."""
    if row.get("writer_eligible") is not True:
        raise ValueError("refusing to insert a writer-ineligible row")
    if row.get("kind") != "open":
        raise ValueError(f"refusing to insert a non-open row (kind={row.get('kind')!r})")
    clean = {k: v for k, v in row.items()
             if k in staging_db.STAGING_COLUMNS and k not in staging_db.INSERT_SKIP}
    for req in WRITE_REQUIRED:
        if clean.get(req) in (None, ""):
            raise ValueError(f"sanitized open row missing required field {req!r}")
    return clean


def build_patch(row: dict) -> dict:
    """Only the allow-listed fields may update an existing open row (never state/instrument/etc)."""
    return {k: row[k] for k in PATCH_ALLOWLIST if k in row}


def should_skip_existing(existing_state) -> bool:
    return existing_state in SKIP_EXISTING_STATES


# --- 0C-3b deal helpers (pure; exercised by --self-test) --------------------------------------
def sanitize_deal_for_insert(row: dict) -> dict:
    """Project a 0C-2 close/partial deal row onto the exact staging columns; strip dry-run meta /
    non-schema keys; assert close|partial + writer-eligible + required fields. `raw` is PRESERVED
    (Phase 0A column; lossless; the 0D-0 Inbox never selects it). Deals are insert-once immutable."""
    if row.get("writer_eligible") is not True:
        raise ValueError("refusing to insert a writer-ineligible deal row")
    if row.get("kind") not in DEAL_KINDS:
        raise ValueError(f"refusing to insert a non-close/partial row (kind={row.get('kind')!r})")
    clean = {k: v for k, v in row.items()
             if k in staging_db.STAGING_COLUMNS and k not in staging_db.INSERT_SKIP}
    for req in DEAL_WRITE_REQUIRED:
        if clean.get(req) in (None, ""):
            raise ValueError(f"sanitized deal row missing required field {req!r}")
    return clean


def deal_armed_guard(mode, deal_id, position_id):
    """Pure guard for armed --scope deals: require --deal-id, forbid --position-id (one position has
    many deals). ('ok', None) or ('stop', reason). Dry-run never constrains targeting."""
    if mode != "armed":
        return "ok", None
    if not deal_id:
        return "stop", "armed --scope deals requires --deal-id (single-deal targeting)."
    if position_id is not None:
        return "stop", "armed --scope deals must NOT use --position-id (one position has many deals); use --deal-id."
    return "ok", None


def deal_candidate_filter(deal_rows, open_rows):
    """Pure: split deal_rows into (candidates, counters). candidates = kind in DEAL_KINDS + writer_eligible
    + deal_id present. Opens (from open_rows) are out of deal scope and only counted."""
    counters = {"ignored_open": sum(1 for r in (open_rows or []) if r.get("kind") == "open"),
                "ignored_balance": 0, "ignored_unknown": 0,
                "ignored_ineligible": 0, "skipped_missing_deal_id": 0}
    candidates = []
    for r in deal_rows or []:
        kind = r.get("kind")
        if kind not in DEAL_KINDS:
            if kind == "balance":
                counters["ignored_balance"] += 1
            else:
                counters["ignored_unknown"] += 1   # unknown / any non-close-partial deal kind
            continue
        if r.get("writer_eligible") is not True:
            counters["ignored_ineligible"] += 1
            continue
        if not r.get("deal_id"):
            counters["skipped_missing_deal_id"] += 1
            continue
        candidates.append(r)
    return candidates, counters


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------
def parse_args(argv):
    ap = argparse.ArgumentParser(
        description="MT5 staging writer — 0C-3a opens (--scope open) + 0C-3b close/partial deals "
                    "(--scope deals). Dry-run default; 3-key write gate.")
    ap.add_argument("--scope", choices=("open", "deals"), default="open",
                    help="What to write: 'open' (0C-3a, default — unchanged) or 'deals' (0C-3b close/partial).")
    ap.add_argument("--user-id", dest="user_id", default=None, help="THUS auth uid (UUID).")
    ap.add_argument("--source-account", dest="source_account", default=None, help="MT5 login / source_account.")
    ap.add_argument("--days", type=int, default=7, help="Bounded deal-history window (for ignored-count only).")
    ap.add_argument("--from", dest="date_from", default=None, help="Explicit start YYYY-MM-DD.")
    ap.add_argument("--to", dest="date_to", default=None, help="Explicit end YYYY-MM-DD.")
    ap.add_argument("--symbols", nargs="*", default=None, help="Extra symbols to force symbol_info on.")
    ap.add_argument("--position-id", dest="position_id", default=None,
                    help="Open scope: target a single open position_id. Deals scope: dry-run/report-only "
                         "narrowing (may match MANY deals; forbidden for armed deal writes).")
    ap.add_argument("--deal-id", dest="deal_id", default=None,
                    help="Deals scope: target a single close/partial deal_id (REQUIRED for armed --scope deals).")
    ap.add_argument("--write", action="store_true", help="Key 1/3 to arm a write (default: dry-run).")
    ap.add_argument("--confirm", default=None, help="Key 2/3: must be exactly WRITE_STAGING.")
    ap.add_argument("--max-write-count", dest="max_write_count", type=int, default=MAX_WRITE_DEFAULT,
                    help=f"Refuse if planned writes exceed this (default {MAX_WRITE_DEFAULT}).")
    ap.add_argument("--self-test", action="store_true", help="Run pure-logic self-tests (no MT5, no DB).")
    return ap.parse_args(argv)


# ---------------------------------------------------------------------------------------------
# MT5 read (read-only) — reuses 0C-2 mappers; build_rows.py untouched
# ---------------------------------------------------------------------------------------------
def collect(mt5, args, user_id, source_account):
    acct = common.as_dict(mt5.account_info())
    if acct is None:
        common.stop("account_info() returned None - terminal not logged in?", code=3)
    positions = mt5.positions_get() or ()
    from_dt, to_dt = resolve_window(args)
    deals = mt5.history_deals_get(from_dt, to_dt)
    if deals is None:
        err = mt5.last_error()
        if isinstance(err, (tuple, list)) and err and err[0] == 1:
            common.eprint(f"WARN: history_deals_get None but MT5 reports no error ({err}); treating as 0 deals.")
            deals = ()
        else:
            common.stop(f"history_deals_get returned None (MT5 error: {err}) - aborting.", code=3)

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
        symbols_meta[s] = {"path": path, "instrument_class": common.rough_instrument_class(path, s),
                           "contract_size": si.get("trade_contract_size"), "digits": si.get("digits")}

    now_iso = tz.utc_iso(datetime.now(timezone.utc))
    open_rows, deal_rows = [], []
    for p in positions:
        row, _ = map_open_position(common.as_dict(p), user_id, source_account, now_iso, symbols_meta)
        if row:
            open_rows.append(row)
    for d in deals:
        row, _ = map_deal(common.as_dict(d), user_id, source_account, symbols_meta)
        if row:
            deal_rows.append(row)
    return acct, open_rows, deal_rows, symbols_meta


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
def main(argv):
    args = parse_args(argv)
    if args.self_test:
        return self_test()

    # Identity required in BOTH modes (rows are stamped with these).
    if not common.is_uuid(args.user_id):
        common.stop(f"--user-id must be a UUID (got {args.user_id!r}); not read from .env.")
    if not (args.source_account and str(args.source_account).strip()):
        common.stop("--source-account must be a non-empty string (the MT5 login / source_account).")
    user_id = args.user_id.strip()
    source_account = str(args.source_account).strip()

    # THREE-key gate (reads ONLY MT5_WRITE here, and only when --write is set).
    mode, reason = gate_status(args.write, args.confirm, os.environ.get("MT5_WRITE") if args.write else None)
    if mode == "stop":
        common.stop(reason)

    # Armed: verify service_role env presence BEFORE any MT5 read or client construction.
    sb_url = sb_key = None
    if mode == "armed":
        sb_url = os.environ.get("SUPABASE_URL")
        sb_key = os.environ.get("SUPABASE_SERVICE_KEY")
        if not sb_url or not sb_key:
            common.stop("armed write requires local SUPABASE_URL + SUPABASE_SERVICE_KEY env "
                        "(values never logged). Refusing to write.", code=2)

    # MT5 read (read-only) — both modes.
    try:
        import MetaTrader5 as mt5  # type: ignore
    except Exception as e:
        common.stop(f"could not import MetaTrader5 ({e!r}). Run on Windows with the terminal up.", code=2)
    if not mt5.initialize():
        common.stop(f"mt5.initialize() failed: {mt5.last_error()}. Terminal running & logged in?", code=3)

    try:
        acct, open_rows, deal_rows, symbols_meta = collect(mt5, args, user_id, source_account)

        # Source-account guard (shared by both scopes).
        login = str(acct.get("login"))
        if login != source_account:
            msg = (f"--source-account {source_account!r} != terminal login {common.mask_login(acct.get('login'))}")
            if mode == "armed":
                common.stop(f"{msg}. HARD-STOP in write mode (cross-account guard).", code=2)
            common.eprint(f"WARN: {msg}. (Dry-run continues; WRITE mode would HARD-STOP.)")

        if args.scope == "open":
            return _run_open_scope(mode, args, user_id, source_account, open_rows, deal_rows, sb_url, sb_key)
        return _run_deals_scope(mode, args, user_id, source_account, open_rows, deal_rows, sb_url, sb_key)
    finally:
        mt5.shutdown()


def _run_open_scope(mode, args, user_id, source_account, open_rows, deal_rows, sb_url, sb_key):
    """0C-3a OPEN-ONLY path (UNCHANGED). Writes eligible kind='open' rows; SELECT->INSERT/PATCH."""
    # Candidate set = eligible opens with a position_id (defensive filter).
    candidates = [r for r in open_rows if r.get("kind") == "open"
                  and r.get("writer_eligible") is True and r.get("position_id")]
    if args.position_id is not None:
        candidates = [r for r in candidates if str(r.get("position_id")) == str(args.position_id)]
        if not candidates:
            common.stop(f"--position-id {args.position_id!r} not found among eligible open rows.")

    # Defensive: nothing non-open / ineligible may reach the write payload.
    for r in candidates:
        if r.get("kind") != "open" or r.get("writer_eligible") is not True:
            common.stop("internal: a non-open / writer-ineligible row reached the write candidate set.", code=2)

    ignored = _count_by_kind(deal_rows)  # close/partial/balance/unknown — out of 0C-3a scope
    planned = len(candidates)

    _print_plan(mode, args, planned, ignored, candidates)

    if mode == "dry-run":
        print("\nDRY-RUN: no Supabase client constructed, no service_role env read, nothing written.")
        print("DONE (dry-run). Re-run with --write --confirm WRITE_STAGING and MT5_WRITE=1 to arm.")
        return 0

    # ---- armed write (opens only) -------------------------------------------------------
    if planned > args.max_write_count:
        common.stop(f"planned writes ({planned}) exceed --max-write-count ({args.max_write_count}). "
                    f"Refusing. Use --position-id to target, or raise the cap deliberately.", code=2)

    db = staging_db.StagingDB(sb_url, sb_key)
    pre_scope = db.count_open_by_scope(user_id, source_account)
    print(f"\nPREFLIGHT: existing open rows in scope (user/account) = {pre_scope}")

    inserted = patched = skipped_state = skipped_concurrent = dup_race = 0
    for r in candidates:
        pid = r["position_id"]
        existing = db.select_open_by_key(user_id, source_account, pid)
        if existing is None:
            try:
                db.insert_open(sanitize_open_for_insert(r))
                inserted += 1
                print(f"  INSERT open position_id={pid} state={r['state']}")
            except staging_db.DuplicateInsert:
                dup_race += 1
                again = db.select_open_by_key(user_id, source_account, pid)
                if again is not None and not should_skip_existing(again.get("state")):
                    db.patch_open_allowlisted(user_id, source_account, pid, build_patch(r))
                print(f"  DUPLICATE-RACE open position_id={pid} -> re-selected, patched-if-eligible")
        elif should_skip_existing(existing.get("state")):
            skipped_state += 1
            print(f"  SKIP open position_id={pid} (existing state={existing.get('state')!r} is browser/RPC-owned)")
        else:
            n = db.patch_open_allowlisted(user_id, source_account, pid, build_patch(r))
            if n == 0:
                skipped_concurrent += 1
                print(f"  SKIP open position_id={pid} (PATCH affected 0 rows - state changed concurrently)")
            else:
                patched += 1
                print(f"  PATCH open position_id={pid} fields={list(build_patch(r))}")

    print("\nARMED WRITE RESULT (mt5_import_staging, opens only):")
    print(f"  inserted={inserted} patched={patched} skipped_browser_owned={skipped_state} "
          f"skipped_concurrent={skipped_concurrent} duplicate_race={dup_race}")
    print("  cursor: NOT touched (deferred). deals/balance/unknown: NOT written. groups/trades: NOT touched.")
    print("DONE (armed write, opens only).")
    return 0


def _run_deals_scope(mode, args, user_id, source_account, open_rows, deal_rows, sb_url, sb_key):
    """0C-3b CLOSE/PARTIAL DEAL path. Writes eligible kind in ('close','partial') rows; SELECT->INSERT,
    insert-once IMMUTABLE (NO PATCH). Armed requires --deal-id; --position-id is dry-run/report-only."""
    g_status, g_reason = deal_armed_guard(mode, args.deal_id, args.position_id)
    if g_status == "stop":
        common.stop(g_reason + " Refusing.", code=2)

    candidates, counters = deal_candidate_filter(deal_rows, open_rows)

    if args.deal_id is not None:
        candidates = [r for r in candidates if str(r.get("deal_id")) == str(args.deal_id)]
        if not candidates:
            common.stop(f"--deal-id {args.deal_id!r} not found among eligible close/partial rows.")
    elif args.position_id is not None:
        # Dry-run/report-only narrowing (armed already STOPped). May match MULTIPLE deals.
        candidates = [r for r in candidates if str(r.get("position_id")) == str(args.position_id)]
        common.eprint(f"NOTE: --position-id {args.position_id} may match MANY deals "
                      f"({len(candidates)} matched). Report-only; use --deal-id to target exactly one.")

    # Defensive: nothing non-close/partial / ineligible / key-less may reach the write payload.
    for r in candidates:
        if r.get("kind") not in DEAL_KINDS or r.get("writer_eligible") is not True or not r.get("deal_id"):
            common.stop("internal: a non-close/partial / ineligible / key-less row reached the deal payload.", code=2)

    planned = len(candidates)
    _print_deal_plan(mode, args, planned, counters, candidates)

    if mode == "dry-run":
        print("\nDRY-RUN: no Supabase client constructed, no service_role env read, nothing written.")
        print("DONE (dry-run, deals). Arm with --write --confirm WRITE_STAGING, MT5_WRITE=1 and --deal-id.")
        return 0

    if planned > args.max_write_count:
        common.stop(f"planned deal writes ({planned}) exceed --max-write-count ({args.max_write_count}). "
                    f"Refusing. Use --deal-id to target exactly one.", code=2)

    db = staging_db.StagingDB(sb_url, sb_key)
    pre_scope = db.count_deal_by_scope(user_id, source_account)
    print(f"\nPREFLIGHT: existing close/partial deal rows in scope (user/account) = {pre_scope}")

    inserted = duplicate_existing = duplicate_race = duplicate_kind_mismatch = 0
    for r in candidates:
        did = r["deal_id"]
        kind = r["kind"]
        existing = db.select_deals_by_key(user_id, source_account, did)
        if existing:
            if any(e.get("kind") != kind for e in existing):
                duplicate_kind_mismatch += 1
                common.stop(f"deal_id={did} already staged as kind={existing[0].get('kind')!r} but incoming "
                            f"kind={kind!r} -> close/partial mismatch. Refusing (immutable historical fact).", code=2)
            duplicate_existing += 1
            print(f"  DUPLICATE-EXISTING deal_id={did} kind={kind} -> no-op (immutable)")
            continue
        try:
            db.insert_deal(sanitize_deal_for_insert(r))
            inserted += 1
            print(f"  INSERT deal_id={did} kind={kind} state={r['state']}")
        except staging_db.DuplicateInsert:
            again = db.select_deals_by_key(user_id, source_account, did)
            if any(e.get("kind") != kind for e in again):
                duplicate_kind_mismatch += 1
                common.stop(f"deal_id={did} race -> now staged as kind={again[0].get('kind')!r} != incoming "
                            f"{kind!r} -> mismatch. Refusing.", code=2)
            duplicate_race += 1
            print(f"  DUPLICATE-RACE deal_id={did} kind={kind} -> re-selected, no-op (immutable)")

    print("\nARMED WRITE RESULT (mt5_import_staging, close/partial deals only):")
    print(f"  planned_deal_writes={planned} inserted={inserted} duplicate_existing={duplicate_existing} "
          f"duplicate_race={duplicate_race} duplicate_kind_mismatch={duplicate_kind_mismatch}")
    print(f"  ignored: {counters}")
    print("  cursor: NOT touched (deferred 0C-3c). open/balance/unknown: NOT written. "
          "groups/trades: NOT touched. NO PATCH (deals immutable).")
    print("DONE (armed write, close/partial deals only).")
    return 0


def _count_by_kind(rows):
    out = {}
    for r in rows:
        out[r.get("kind")] = out.get(r.get("kind"), 0) + 1
    return out


def _print_plan(mode, args, planned, ignored, candidates):
    print("=" * 72)
    print(f"MT5 0C-3a OPEN-ONLY STAGING WRITER  [mode={mode}]")
    print("=" * 72)
    print(f"target table        : mt5_import_staging (opens only)")
    print(f"candidate open rows : {planned}" + (f"  (--position-id={args.position_id})" if args.position_id else ""))
    print(f"ignored (out-of-scope, NOT written) by kind : {ignored or '{}'} "
          f"(close/partial/balance/unknown -> later sub-slices)")
    print(f"planned write ops   : {planned}  (max-write-count={args.max_write_count})")
    print(f"db client constructed: {'(armed) yes' if mode == 'armed' else 'no'}")
    for r in candidates[:10]:
        print(f"  - open position_id={r.get('position_id')} {r.get('symbol_raw')} side={r.get('side')} "
              f"vol={r.get('volume')} state={r.get('state')} -> SELECT then INSERT-or-PATCH")
    if planned > args.max_write_count:
        print(f"  !! planned ({planned}) > max-write-count ({args.max_write_count}) "
              f"-> WRITE mode would STOP. Use --position-id to target.")


def _print_deal_plan(mode, args, planned, counters, candidates):
    print("=" * 72)
    print(f"MT5 0C-3b CLOSE/PARTIAL DEAL STAGING WRITER  [mode={mode}]")
    print("=" * 72)
    print("target table         : mt5_import_staging (close/partial deals only)")
    if args.deal_id:
        tgt = f"  (--deal-id={args.deal_id})"
    elif args.position_id:
        tgt = f"  (--position-id={args.position_id}, report-only, may match MANY deals)"
    else:
        tgt = ""
    print(f"candidate deal rows  : {planned}{tgt}")
    print(f"ignored (NOT written): {counters}")
    print(f"planned write ops    : {planned}  (max-write-count={args.max_write_count})")
    print(f"db client constructed: {'(armed) yes' if mode == 'armed' else 'no'}")
    for r in candidates[:10]:
        print(f"  - deal_id={r.get('deal_id')} kind={r.get('kind')} {r.get('symbol_raw')} side={r.get('side')} "
              f"vol={r.get('volume')} px={r.get('price')} pos={r.get('position_id')} state={r.get('state')} "
              f"-> SELECT then INSERT (immutable, no PATCH)")
    if planned > args.max_write_count:
        print(f"  !! planned ({planned}) > max-write-count ({args.max_write_count}) "
              f"-> WRITE mode would STOP. Use --deal-id to target exactly one.")


# ---------------------------------------------------------------------------------------------
# Self-test (no MT5, no DB)
# ---------------------------------------------------------------------------------------------
def self_test():
    fails = []

    # gate: dry-run by default; all three keys required to arm; any missing -> stop
    if gate_status(False, None, None) != ("dry-run", None):
        fails.append("no --write should be dry-run")
    if gate_status(True, "WRITE_STAGING", "1") != ("armed", None):
        fails.append("all three keys should arm")
    if gate_status(True, "nope", "1")[0] != "stop":
        fails.append("wrong --confirm should stop")
    if gate_status(True, "WRITE_STAGING", None)[0] != "stop":
        fails.append("missing MT5_WRITE should stop")
    if gate_status(True, "WRITE_STAGING", "0")[0] != "stop":
        fails.append("MT5_WRITE!=1 should stop")

    # sanitize: strips meta, keeps schema, asserts open + eligible + required
    row = {"user_id": "u", "source_account": "a", "kind": "open", "position_id": 5, "state": "needs_mapping",
           "symbol_raw": "GOU26", "price": 1.0, "volume": 2.0, "raw": {"x": 1},
           "writer_eligible": True, "writer_skip_reason": None, "bogus_key": "drop me"}
    clean = sanitize_open_for_insert(row)
    if "writer_eligible" in clean or "writer_skip_reason" in clean or "bogus_key" in clean:
        fails.append("sanitize did not strip meta/non-schema keys")
    if clean.get("kind") != "open" or "raw" not in clean:
        fails.append("sanitize dropped a real schema field")
    try:
        sanitize_open_for_insert({**row, "writer_eligible": False})
        fails.append("sanitize accepted a writer-ineligible row")
    except ValueError:
        pass
    try:
        sanitize_open_for_insert({**row, "kind": "close"})
        fails.append("sanitize accepted a non-open row")
    except ValueError:
        pass
    try:
        sanitize_open_for_insert({k: v for k, v in row.items() if k != "position_id"})
        fails.append("sanitize accepted a row missing position_id")
    except ValueError:
        pass

    # patch allowlist: only the 6 fields, never state/instrument/etc
    patch = build_patch({**row, "state": "new", "contract_size": 1000, "instrument_class": "ssf",
                         "confirmed_group_id": "x", "last_seen_open_at": "t", "mt5_time": "t2"})
    for forbidden in ("state", "contract_size", "instrument_class", "confirmed_group_id", "symbol_raw",
                      "kind", "first_seen_open_at", "raw", "product_id_candidate"):
        if forbidden in patch:
            fails.append(f"patch allowlist leaked forbidden field {forbidden!r}")
    for ok in ("last_seen_open_at", "mt5_time"):
        if ok not in patch:
            fails.append(f"patch allowlist dropped allowed field {ok!r}")

    # skip grouped/materialized/dismissed
    for st in ("materialized", "dismissed", "grouped"):
        if not should_skip_existing(st):
            fails.append(f"{st} existing row should be skipped")
    for st in ("needs_mapping", "new", "group_suggested"):
        if should_skip_existing(st):
            fails.append(f"{st} existing row should NOT be skipped")

    # staging_db allowlist is structural
    if staging_db.ALLOWED_TABLES != frozenset({"mt5_import_staging"}):
        fails.append("staging_db allowlist drifted from {mt5_import_staging}")

    # ---- 0C-3b deal scope ---------------------------------------------------------------
    # default scope is open; deals scope parses
    if parse_args([]).scope != "open":
        fails.append("default --scope must be 'open' (0C-3a back-compat)")
    if parse_args(["--scope", "deals"]).scope != "deals":
        fails.append("--scope deals should parse")
    # open scope must NOT require --deal-id (armed-guard only applies to deals)
    if deal_armed_guard("armed", None, None)[0] != "stop":
        fails.append("armed deals without --deal-id should stop")
    if deal_armed_guard("armed", "42", "777")[0] != "stop":
        fails.append("armed deals with --position-id should stop")
    if deal_armed_guard("armed", "42", None) != ("ok", None):
        fails.append("armed deals with --deal-id and no --position-id should be ok")
    if deal_armed_guard("dry-run", None, "777") != ("ok", None):
        fails.append("dry-run deals must not constrain targeting (position-id allowed report-only)")

    # sanitize_deal: accepts close AND synthetic partial; strips meta; preserves raw; required fields
    dbase = {"user_id": "u", "source_account": "a", "kind": "close", "deal_id": 42, "state": "needs_mapping",
             "symbol_raw": "GOU26", "price": 1.0, "volume": 1.0, "broker_profit": 5.0, "raw": {"x": 1},
             "writer_eligible": True, "writer_skip_reason": None, "bogus_key": "drop me"}
    dc = sanitize_deal_for_insert(dbase)
    if "writer_eligible" in dc or "writer_skip_reason" in dc or "bogus_key" in dc:
        fails.append("sanitize_deal did not strip meta/non-schema keys")
    if "raw" not in dc or dc.get("kind") != "close" or dc.get("deal_id") != 42:
        fails.append("sanitize_deal dropped a real schema field (raw/kind/deal_id)")
    if sanitize_deal_for_insert({**dbase, "kind": "partial"}).get("kind") != "partial":
        fails.append("sanitize_deal should accept a SYNTHETIC partial row (forward-compat)")
    for bad_kind in ("open", "balance", "unknown"):
        try:
            sanitize_deal_for_insert({**dbase, "kind": bad_kind})
            fails.append(f"sanitize_deal accepted a {bad_kind} row")
        except ValueError:
            pass
    try:
        sanitize_deal_for_insert({k: v for k, v in dbase.items() if k != "deal_id"})
        fails.append("sanitize_deal accepted a row missing deal_id")
    except ValueError:
        pass
    try:
        sanitize_deal_for_insert({**dbase, "writer_eligible": False})
        fails.append("sanitize_deal accepted a writer-ineligible row")
    except ValueError:
        pass

    # candidate filter: close/partial kept; balance/unknown/ineligible/missing-deal-id excluded; opens counted
    drows = [
        {"kind": "close", "writer_eligible": True, "deal_id": 1},
        {"kind": "partial", "writer_eligible": True, "deal_id": 2},
        {"kind": "balance", "writer_eligible": True, "deal_id": 3},
        {"kind": "unknown", "writer_eligible": False, "deal_id": 4},
        {"kind": "close", "writer_eligible": False, "deal_id": 5},   # ineligible
        {"kind": "close", "writer_eligible": True, "deal_id": None},  # missing key
    ]
    cands, ctr = deal_candidate_filter(drows, [{"kind": "open"}])
    if [c["deal_id"] for c in cands] != [1, 2]:
        fails.append(f"deal_candidate_filter kept wrong rows: {[c['deal_id'] for c in cands]}")
    if (ctr["ignored_balance"] != 1 or ctr["ignored_unknown"] != 1 or ctr["ignored_ineligible"] != 1
            or ctr["skipped_missing_deal_id"] != 1 or ctr["ignored_open"] != 1):
        fails.append(f"deal_candidate_filter counters wrong: {ctr}")

    # immutability + boundary: NO patch_deal; deal helpers exist; table allowlist unchanged; no upsert path
    if hasattr(staging_db.StagingDB, "patch_deal"):
        fails.append("staging_db must NOT expose patch_deal (deals are immutable)")
    for needed in ("select_deals_by_key", "count_deal_by_scope", "count_deal_by_key", "insert_deal"):
        if not hasattr(staging_db.StagingDB, needed):
            fails.append(f"staging_db missing deal helper {needed}")
    if staging_db.ALLOWED_TABLES != frozenset({"mt5_import_staging"}):
        fails.append("staging_db allowlist must remain {mt5_import_staging} after 0C-3b")

    print("writer self-test:", "PASS" if not fails else "FAIL")
    for x in fails:
        print("  -", x)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
