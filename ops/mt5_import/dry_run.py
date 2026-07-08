#!/usr/bin/env python3
"""
MT5 Auto Draft Import — fixture-driven OFFLINE DRY-RUN harness (v0.1, local bridge).

WHAT THIS IS
    A deterministic, offline dry-run. Reads a JSON *fixture* (MT5 positions/deals + account block) and
    a class-aware *mapping fixture*, reuses the reviewed pure mappers in `build_rows.py` to shape
    staging-style rows (same field names, same Asia/Bangkok->UTC conversion), then layers on:
      - class-aware product mapping (mapped / needs_mapping / rejected) from the mapping fixture ONLY
        (never inferred from a symbol prefix),
      - a deterministic raw_sha per raw record,
      - a deterministic idempotency_key per row (open -> position_id, deal -> deal_id; mirrors the
        Phase 0A unique-index semantics),
    and emits a deterministic JSON + Markdown report.

WHAT THIS IS NOT (hard guarantees)
    - Not the 0C staging writer. It NEVER imports `staging_db`/`writer`, NEVER constructs a Supabase
      client, NEVER reads SUPABASE_* / service_role, NEVER calls an RPC, NEVER writes any DB/Storage.
    - No live MT5. It never imports `MetaTrader5` (unlike build_rows.main, whose MT5 import is lazy).
    - No network. Only local file writes, and ONLY to the report paths passed via --out/--summary.
    See artifacts/mt5_import/README.md for what must happen before a real staging writer.

RUN (offline, no MT5, no DB):
    python ops/mt5_import/dry_run.py \
      --input   artifacts/mt5_import/fixtures/sample_mt5_probe.json \
      --mapping artifacts/mt5_import/fixtures/sample_mapping.json \
      --out     artifacts/mt5_import/reports/mt5_dry_run_report.json \
      --summary artifacts/mt5_import/reports/mt5_dry_run_report.md
    python ops/mt5_import/dry_run.py --self-test
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

import common          # reused pure helpers (no Supabase; subprocess only for git check-ignore)
import tz              # reused Asia/Bangkok(+7) -> true-UTC conversion (0B invariant)
import build_rows      # reused reviewed pure mappers (MT5 import is lazy in build_rows.main only)

# Static self-audit: modules this harness must NEVER import (asserted by test via source scan).
_FORBIDDEN_IMPORTS = ("staging_db", "writer", "MetaTrader5", "supabase", "urllib.request")
_DEFAULT_OBSERVED_AT = "1970-01-01T00:00:00Z"   # deterministic fallback if fixture omits observed_at_utc


# ---------------------------------------------------------------------------------------------
# Deterministic hashing / ids (pure)
# ---------------------------------------------------------------------------------------------
def _canonical(obj) -> str:
    """Stable JSON encoding for hashing: sorted keys, no whitespace, str-coerced leftovers."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)


def _sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def raw_sha(raw_record) -> str:
    """Content hash of a raw MT5 record — changes iff the raw input changes."""
    return _sha256_hex(_canonical(raw_record))


def account_fingerprint(login) -> str:
    """Non-reversible account tag (never stores the raw login in the fingerprint)."""
    return "mt5:" + _sha256_hex("mt5|acct|" + str(login))[:16]


def idempotency_key(row: dict) -> str:
    """Natural-key idempotency string mirroring Phase 0A unique indexes:
      open  -> unique on position_id ; deal (close/partial/balance/unknown) -> unique on deal_id.
    Same fixture -> same key (position_id/deal_id are stable), so re-runs collapse."""
    acct = row.get("source_account")
    if row.get("kind") == "open":
        return f"mt5:{acct}:pos:{row.get('position_id')}"
    return f"mt5:{acct}:deal:{row.get('deal_id')}"


def _direction(side) -> str | None:
    """buy -> Long, sell -> Short (staging `side` is lower-case; keep both)."""
    if side == "buy":
        return "Long"
    if side == "sell":
        return "Short"
    return None


def _position_state_for_deal(kind: str) -> str:
    return {"close": "closed", "balance": "n/a"}.get(kind, "unknown")


def _strip_annotations(rec):
    """Drop underscore-prefixed fixture annotations (e.g. _note/_comment) so `raw` and raw_sha
    reflect only real MT5 fields — a duplicate that differs only in annotations collapses idempotently."""
    if not isinstance(rec, dict):
        return rec
    return {k: v for k, v in rec.items() if not (isinstance(k, str) and k.startswith("_"))}


# ---------------------------------------------------------------------------------------------
# Class-aware mapping resolver (mapping fixture ONLY — never prefix-inferred)
# ---------------------------------------------------------------------------------------------
def build_symbols_meta(mapping: dict) -> dict:
    """symbols_meta shape build_rows expects: {symbol: {path, instrument_class, contract_size, digits}}."""
    out = {}
    for sym, e in (mapping.get("instruments") or {}).items():
        out[sym] = {
            "path": e.get("path"),
            "instrument_class": e.get("instrument_class", "unknown"),
            "contract_size": e.get("contract_size"),
            "digits": e.get("digits", 2),
        }
    return out


def resolve_mapping(symbol_raw, contract_size, mapping: dict):
    """(mapping_status, product_id, reason). ONLY an explicit exact-symbol entry with a non-null
    product_id maps. A product whose declared contract_size disagrees with the instrument's is a
    class conflict -> rejected (this is what stops DELTAU26/1000 ever collapsing onto DELTA/1)."""
    entry = (mapping.get("instruments") or {}).get(symbol_raw)
    if entry is None:
        return "needs_mapping", None, "no_mapping_entry_for_symbol"
    pid = entry.get("product_id")
    if pid is None:
        return "needs_mapping", None, entry.get("note") or "no_reviewed_product_for_symbol"
    prod_cs = entry.get("product_contract_size", entry.get("contract_size"))
    if prod_cs is not None and contract_size is not None and prod_cs != contract_size:
        return ("rejected", None,
                f"contract_size_class_conflict: instrument={contract_size} product={prod_cs}")
    return "mapped", pid, "explicit_symbol_mapping"


def _enrich(row: dict, mapping: dict, warnings: list) -> dict:
    """Layer harness fields onto a build_rows staging row. Deterministic; no I/O."""
    row["source_system"] = "mt5"
    row["account_fingerprint"] = account_fingerprint(row.get("source_account"))
    row["direction"] = _direction(row.get("side"))
    row["raw_sha"] = raw_sha(row.get("raw"))

    status, pid, reason = resolve_mapping(row.get("symbol_raw"), row.get("contract_size"), mapping)
    row["mapping_status"] = status
    row["product_id_candidate"] = pid                     # keep build_rows' field coherent...
    row["state"] = build_rows.initial_state(pid)          # ...so state is 'new' iff a product resolved
    row["mapping_reason"] = reason

    if row.get("kind") != "open":
        row["position_state"] = _position_state_for_deal(row.get("kind"))
        # Domain rule: a trade CLOSE deal must carry a position_id (balance legitimately has 0).
        if row.get("kind") == "close" and not row.get("position_id"):
            row.setdefault("warnings", []).append("close_deal_missing_position_id")
            warnings.append(
                f"deal {row.get('deal_id')} ({row.get('symbol_raw')}): close deal missing position_id")

    row["idempotency_key"] = idempotency_key(row)
    return row


# ---------------------------------------------------------------------------------------------
# Core processing (pure given fixture dicts)
# ---------------------------------------------------------------------------------------------
def process(fixture: dict, mapping: dict):
    """Returns (report_dict, fatal_or_None). No I/O. Deterministic for a given (fixture, mapping)."""
    if not isinstance(fixture, dict):
        return None, "input fixture must be a JSON object"
    account = fixture.get("account")
    positions = fixture.get("positions")
    deals = fixture.get("deals")
    if not isinstance(account, dict):
        return None, "fixture.account must be an object (login/margin_mode)"
    if not isinstance(positions, list) or not isinstance(deals, list):
        return None, "fixture.positions and fixture.deals must both be arrays"

    user_id = fixture.get("user_id") or "00000000-0000-0000-0000-000000000000"
    source_account = str(account.get("login") or "unknown")
    observed_at = fixture.get("observed_at_utc") or _DEFAULT_OBSERVED_AT
    warnings: list = []
    if not fixture.get("observed_at_utc"):
        warnings.append(f"fixture omitted observed_at_utc; using deterministic fallback {observed_at}")
    if account.get("margin_mode") != 2:
        warnings.append("account.margin_mode is not RETAIL_HEDGING (2) — a real writer must re-check")

    symbols_meta = build_symbols_meta(mapping)

    mapped_rows, structural_rejects = [], []
    for p in positions:
        if not isinstance(p, dict):
            structural_rejects.append({"kind": "open", "symbol": None, "reason": "position is not an object",
                                       "reason_class": "malformed_record"})
            continue
        p = _strip_annotations(p)
        row, skip = build_rows.map_open_position(p, user_id, source_account, observed_at, symbols_meta)
        if skip:
            skip["reason_class"] = "structural_missing_key"
            structural_rejects.append(skip)
            continue
        mapped_rows.append(_enrich(row, mapping, warnings))
    for d in deals:
        if not isinstance(d, dict):
            structural_rejects.append({"kind": "deal", "symbol": None, "reason": "deal is not an object",
                                       "reason_class": "malformed_record"})
            continue
        d = _strip_annotations(d)
        row, skip = build_rows.map_deal(d, user_id, source_account, symbols_meta)
        if skip:
            skip["reason_class"] = "structural_missing_key"
            structural_rejects.append(skip)
            continue
        mapped_rows.append(_enrich(row, mapping, warnings))

    # Idempotent dedup + collision detection.
    seen: dict = {}
    idem_index: dict = {}
    collisions: list = []
    duplicates_collapsed = 0
    deduped: list = []
    for row in mapped_rows:
        k, s = row["idempotency_key"], row["raw_sha"]
        idem_index.setdefault(k, set()).add(s)
        if k in seen:
            if seen[k]["raw_sha"] != s:
                collisions.append({"idempotency_key": k, "raw_sha_a": seen[k]["raw_sha"], "raw_sha_b": s})
            else:
                duplicates_collapsed += 1                 # identical re-run of the same natural key
            continue
        seen[k] = row
        deduped.append(row)

    # Route deduped rows by the harness mapping decision.
    accepted = [r for r in deduped if r["mapping_status"] == "mapped"]
    needs = [r for r in deduped if r["mapping_status"] == "needs_mapping"]
    mapping_rejects = [r for r in deduped if r["mapping_status"] == "rejected"]

    report = _build_report(account, source_account, observed_at, symbols_meta,
                           accepted, needs, mapping_rejects, structural_rejects,
                           deduped, idem_index, duplicates_collapsed, collisions, warnings)

    if collisions:
        return report, (f"idempotency_key collision(s): {len(collisions)} key(s) map to >1 distinct "
                        f"raw_sha (the underlying record changed). See report.idempotency.collisions.")
    return report, None


def _count_by(rows, key):
    out = {}
    for r in rows:
        out[r.get(key)] = out.get(r.get(key), 0) + 1
    return out


def _decision(r):
    return {
        "symbol": r.get("symbol_raw"),
        "kind": r.get("kind"),
        "position_id": r.get("position_id"),
        "deal_id": r.get("deal_id"),
        "mapping_status": r.get("mapping_status"),
        "product_id": r.get("product_id_candidate"),
        "instrument_class": r.get("instrument_class"),
        "contract_size": r.get("contract_size"),
        "reason": r.get("mapping_reason"),
        "idempotency_key": r.get("idempotency_key"),
        "raw_sha": r.get("raw_sha"),
    }


def _build_report(account, source_account, observed_at, symbols_meta, accepted, needs,
                  mapping_rejects, structural_rejects, deduped, idem_index,
                  duplicates_collapsed, collisions, warnings):
    all_rows = accepted + needs + mapping_rejects
    tz_samples = [
        {"raw_epoch": r.get("mt5_time_raw_epoch"),
         "raw_wallclock_bkk": str(tz.raw_wallclock(r.get("mt5_time_raw_epoch"))),
         "utc": r.get("mt5_time")}
        for r in deduped[:5] if r.get("mt5_time_raw_epoch") is not None
    ]
    return {
        "metadata": {
            "harness": "mt5 fixture-driven dry-run",
            "version": "v0.1",
            "dry_run": True,
            "wrote_to_db": False,
            "source_system": "mt5",
            "reused_mappers": "ops/mt5_import/build_rows.py (map_open_position, map_deal, delta_guard)",
        },
        "account": {
            "login_masked": common.mask_login(account.get("login")),
            "account_fingerprint": account_fingerprint(source_account),
            "margin_mode": account.get("margin_mode"),
            "retail_hedging": account.get("margin_mode") == 2,
        },
        "summary": {
            "positions_and_deals_mapped": len(all_rows) + duplicates_collapsed,
            "distinct_rows": len(deduped),
            "accepted_mapped": len(accepted),
            "needs_mapping": len(needs),
            "rejected_mapping": len(mapping_rejects),
            "rejected_structural": len(structural_rejects),
            "duplicates_collapsed": duplicates_collapsed,
            "distinct_idempotency_keys": len(idem_index),
            "idempotency_collisions": len(collisions),
            "by_kind": _count_by(deduped, "kind"),
            "by_mapping_status": _count_by(deduped, "mapping_status"),
            "by_state": _count_by(deduped, "state"),
            "symbols": sorted(symbols_meta.keys()),
            "contract_sizes": {s: m.get("contract_size") for s, m in sorted(symbols_meta.items())},
        },
        "mapping_decisions": [_decision(r) for r in all_rows],
        "idempotency": {
            "keys": {k: {"raw_shas": sorted(v), "distinct_raw_sha": len(v)} for k, v in sorted(idem_index.items())},
            "duplicates_collapsed": duplicates_collapsed,
            "collisions": collisions,
        },
        "timezone": {
            "server_tz": tz.SERVER_TZ_LABEL,
            "note": "MT5 epochs are Asia/Bangkok wall-clock (+7, no DST); rows store true UTC (wall-7h) "
                    "and preserve mt5_time_raw_epoch + mt5_time_msc.",
            "samples": tz_samples,
        },
        "delta_guard": build_rows.delta_guard(symbols_meta, deduped),
        "warnings": warnings,
        "accepted_rows": accepted,
        "needs_mapping_rows": needs,
        "rejected_rows": {"mapping": mapping_rejects, "structural": structural_rejects},
    }


# ---------------------------------------------------------------------------------------------
# Markdown summary
# ---------------------------------------------------------------------------------------------
def render_markdown(report: dict) -> str:
    s = report["summary"]
    a = report["account"]
    L = []
    L.append("# MT5 Dry-Run Import Report")
    L.append("")
    L.append("**Dry-run only** — no MT5, no Supabase, no DB writes. "
             "Reuses `ops/mt5_import/build_rows.py` pure mappers.")
    L.append("")
    L.append(f"- account (masked): `{a['login_masked']}` · fingerprint `{a['account_fingerprint']}` · "
             f"margin_mode {a['margin_mode']} · RETAIL_HEDGING={a['retail_hedging']}")
    L.append(f"- distinct rows: **{s['distinct_rows']}** "
             f"(accepted/mapped **{s['accepted_mapped']}**, needs_mapping **{s['needs_mapping']}**, "
             f"rejected mapping **{s['rejected_mapping']}**, rejected structural **{s['rejected_structural']}**)")
    L.append(f"- duplicates collapsed (idempotent): **{s['duplicates_collapsed']}** · "
             f"distinct idempotency keys: **{s['distinct_idempotency_keys']}** · "
             f"collisions: **{s['idempotency_collisions']}**")
    L.append(f"- by kind: `{s['by_kind']}` · by mapping_status: `{s['by_mapping_status']}`")
    L.append(f"- contract sizes: `{s['contract_sizes']}`")
    g = report["delta_guard"]
    if g.get("observed"):
        L.append(f"- **DELTAU26 guard**: {'PASS' if g['passed'] else 'FAIL'} "
                 f"(csize={g['contract_size']} class={g['class_hint']} "
                 f"needs_mapping={g['state_needs_mapping']} no_product_hint={g['no_product_hint']})")
    L.append("")
    L.append("## Mapping decisions")
    L.append("")
    L.append("| symbol | kind | pos_id | deal_id | status | product_id | class | csize | reason |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for d in report["mapping_decisions"]:
        L.append(f"| {d['symbol']} | {d['kind']} | {d['position_id']} | {d['deal_id']} | "
                 f"**{d['mapping_status']}** | {d['product_id']} | {d['instrument_class']} | "
                 f"{d['contract_size']} | {d['reason']} |")
    L.append("")
    L.append("## Timezone (Asia/Bangkok +7 → true UTC)")
    L.append("")
    L.append("| raw_epoch | wall-clock (BKK) | stored UTC |")
    L.append("|---|---|---|")
    for smp in report["timezone"]["samples"]:
        L.append(f"| {smp['raw_epoch']} | {smp['raw_wallclock_bkk']} | {smp['utc']} |")
    L.append("")
    if report["warnings"]:
        L.append("## Warnings")
        L.append("")
        for w in report["warnings"]:
            L.append(f"- {w}")
        L.append("")
    rj = report["rejected_rows"]
    if rj["structural"] or rj["mapping"]:
        L.append("## Rejected")
        L.append("")
        for r in rj["structural"]:
            L.append(f"- structural: {r.get('kind')} {r.get('symbol')} — {r.get('reason')}")
        for r in rj["mapping"]:
            L.append(f"- mapping: {r.get('symbol_raw')} — {r.get('mapping_reason')}")
        L.append("")
    L.append("---")
    L.append("_Not the 0C staging writer. Before any real staging write: reviewed schema/RLS, explicit "
             "DB-write approval, service-vs-user role decision, Supabase write tests, rollback plan._")
    L.append("")
    return "\n".join(L)


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------
def _load_json(path, label):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        common.stop(f"{label} not found: {path}", code=2)
    except json.JSONDecodeError as e:
        common.stop(f"{label} is not valid JSON ({path}): {e}", code=2)


def parse_args(argv):
    ap = argparse.ArgumentParser(
        description="MT5 fixture-driven OFFLINE dry-run harness. No MT5, no Supabase, no DB writes.")
    ap.add_argument("--input", help="MT5 probe-style fixture JSON (positions/deals/account).")
    ap.add_argument("--mapping", help="Class-aware mapping fixture JSON.")
    ap.add_argument("--out", default=None, help="Write the JSON report here (under artifacts/mt5_import/reports/).")
    ap.add_argument("--summary", default=None, help="Write the Markdown summary here.")
    ap.add_argument("--strict", action="store_true",
                    help="Exit non-zero if any structural/mapping rejects exist (collisions are always fatal).")
    ap.add_argument("--self-test", action="store_true", help="Run offline self-tests and exit.")
    return ap.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    if args.self_test:
        import test_dry_run
        return test_dry_run.run()
    if not args.input or not args.mapping:
        common.stop("both --input and --mapping are required (or use --self-test).", code=2)

    fixture = _load_json(args.input, "input fixture")
    mapping = _load_json(args.mapping, "mapping fixture")
    report, fatal = process(fixture, mapping)

    # Malformed fixture STRUCTURE: process() built no report -> exit 2 (same class as bad/missing JSON).
    # This MUST be checked before the collision branch, whose fatal always comes WITH a report.
    if report is None:
        common.stop(fatal or "could not build a report from the input fixture.", code=2)

    # A report exists — emit it (a collision report is still worth saving), then classify fatals.
    if args.out:
        _write(args.out, json.dumps(report, indent=2, ensure_ascii=False, default=str))
    if args.summary:
        _write(args.summary, render_markdown(report))
    _print_console(report)

    if fatal:
        common.stop(fatal, code=4)          # idempotency_key collision (report built, but unsafe to accept)

    rj = report["rejected_rows"]
    n_rej = len(rj["structural"]) + len(rj["mapping"])
    if args.strict and n_rej:
        common.stop(f"--strict: {n_rej} rejected row(s) present.", code=5)
    return 0


def _write(path, text):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text if text.endswith("\n") else text + "\n")
    print(f"wrote {path}")


def _print_console(report):
    s = report["summary"]
    print("=" * 72)
    print("MT5 FIXTURE DRY-RUN — no MT5, no Supabase, no DB writes")
    print("=" * 72)
    print(f"distinct rows     : {s['distinct_rows']}")
    print(f"  accepted/mapped : {s['accepted_mapped']}")
    print(f"  needs_mapping   : {s['needs_mapping']}")
    print(f"  rejected map    : {s['rejected_mapping']}")
    print(f"  rejected struct : {s['rejected_structural']}")
    print(f"duplicates collapsed: {s['duplicates_collapsed']}  "
          f"(distinct idem keys={s['distinct_idempotency_keys']}, collisions={s['idempotency_collisions']})")
    print(f"by kind           : {s['by_kind']}")
    print(f"by mapping_status : {s['by_mapping_status']}")
    print(f"contract_sizes    : {s['contract_sizes']}")
    g = report["delta_guard"]
    if g.get("observed"):
        print(f"DELTAU26 guard    : {'PASS' if g['passed'] else 'FAIL'} "
              f"(csize={g['contract_size']} class={g['class_hint']})")
    for w in report["warnings"]:
        print(f"WARN: {w}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
