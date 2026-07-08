#!/usr/bin/env python3
"""
Offline tests for the MT5 fixture-driven dry-run harness (dry_run.py).

No MT5, no Supabase, no network, no DB. Run:
    python ops/mt5_import/test_dry_run.py
or via the harness:
    python ops/mt5_import/dry_run.py --self-test
Exit code 0 = all pass, 1 = failure(s).
"""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile

import tz
import dry_run


def _main_exit(argv):
    """Invoke dry_run.main(argv) and return the process exit code (catching SystemExit from common.stop)."""
    try:
        rc = dry_run.main(argv)
        return rc if rc is not None else 0
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 1

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.normpath(os.path.join(_HERE, "..", ".."))
FIX_INPUT = os.path.join(_ROOT, "artifacts", "mt5_import", "fixtures", "sample_mt5_probe.json")
FIX_MAP = os.path.join(_ROOT, "artifacts", "mt5_import", "fixtures", "sample_mapping.json")


def _load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def run():
    fails = []

    def check(cond, msg):
        if not cond:
            fails.append(msg)

    fixture = _load(FIX_INPUT)
    mapping = _load(FIX_MAP)
    report, fatal = dry_run.process(fixture, mapping)
    check(fatal is None, f"main fixture unexpectedly fatal: {fatal}")
    check(report is not None, "main fixture produced no report")

    # (1) determinism: same fixture -> byte-identical report + identical idempotency keys
    r2, f2 = dry_run.process(_load(FIX_INPUT), _load(FIX_MAP))
    check(dry_run._canonical(report) == dry_run._canonical(r2), "process() is not deterministic")
    keys1 = set(report["idempotency"]["keys"].keys())
    keys2 = set(r2["idempotency"]["keys"].keys())
    check(keys1 == keys2, "idempotency keys differ across identical runs")

    accepted = report["accepted_rows"]
    needs = report["needs_mapping_rows"]
    rej = report["rejected_rows"]

    # (2) three GOU26 opens -> three distinct rows, same family, separate position_ids (dup collapsed)
    gou_opens = [r for r in accepted if r["symbol_raw"] == "GOU26" and r["kind"] == "open"]
    check(len(gou_opens) == 3, f"expected 3 distinct GOU26 open rows, got {len(gou_opens)}")
    pids = {r["position_id"] for r in gou_opens}
    check(pids == {700000001, 700000002, 700000003}, f"GOU26 position_ids wrong: {pids}")
    check(len({r["idempotency_key"] for r in gou_opens}) == 3, "GOU26 idempotency keys not distinct")
    check(report["summary"]["duplicates_collapsed"] == 1, "duplicate GOU26 #1 did not collapse to 1")

    # (3) deal_id uniqueness preserved
    deal_rows = [r for r in (accepted + needs) if r.get("deal_id") is not None]
    dids = [r["deal_id"] for r in deal_rows]
    check(len(dids) == len(set(dids)), f"deal_id not unique across rows: {dids}")
    check(set(dids) == {800000001, 800000002}, f"unexpected deal_ids: {set(dids)}")

    # (4) every deal must include position_id; missing on a CLOSE deal is warned; missing deal_id rejected
    missing_pid_fx = {
        "account": {"login": "700123456", "margin_mode": 2}, "user_id": fixture["user_id"],
        "observed_at_utc": "2026-07-07T17:00:00Z", "positions": [],
        "deals": [
            {"symbol": "GOU26", "ticket": 800009001, "type": 1, "entry": 1, "position_id": 0,
             "price": 4230.0, "volume": 1.0, "time": 1783424700},                       # close, no position_id
            {"symbol": "GOU26", "type": 1, "entry": 1, "position_id": 700000009, "time": 1783424700},  # no deal_id
        ],
    }
    rep4, fat4 = dry_run.process(missing_pid_fx, mapping)
    check(fat4 is None, f"missing-pid fixture unexpectedly fatal: {fat4}")
    warned = any("close deal missing position_id" in w for w in rep4["warnings"])
    check(warned, "close deal missing position_id did not produce a warning")
    struct = rep4["rejected_rows"]["structural"]
    check(any(s.get("reason") == "missing deal_id" for s in struct), "deal missing deal_id not structurally rejected")

    # (5) DELTAU26 must NOT map to stock DELTA
    du = [r for r in needs if r["symbol_raw"] == "DELTAU26"]
    check(len(du) == 1, f"expected 1 DELTAU26 needs_mapping row, got {len(du)}")
    if du:
        d = du[0]
        check(d["mapping_status"] == "needs_mapping", f"DELTAU26 status wrong: {d['mapping_status']}")
        check(d["product_id_candidate"] is None, "DELTAU26 must have no product_id")
        check(d["product_id_candidate"] != "delta_stock", "DELTAU26 collapsed onto stock DELTA (product)")
        check(d["contract_size"] == 1000, f"DELTAU26 contract_size must be 1000, got {d['contract_size']}")
        check(d["instrument_class"] == "ssf", f"DELTAU26 class must be ssf, got {d['instrument_class']}")
    check(report["delta_guard"]["passed"], f"delta_guard did not pass: {report['delta_guard']}")

    # (6) contract size is class-aware; a product/instrument csize conflict is rejected
    for r in gou_opens:
        check(r["contract_size"] == 300, f"GOU26 contract_size must be 300, got {r['contract_size']}")
    st, pid, reason = dry_run.resolve_mapping("DELTAU26", 1000, {
        "instruments": {"DELTAU26": {"instrument_class": "ssf", "contract_size": 1000,
                                     "product_id": "delta_stock", "product_contract_size": 1}}})
    check(st == "rejected" and pid is None and "contract_size_class_conflict" in reason,
          f"csize conflict not rejected: {(st, pid, reason)}")

    # (7) Asia/Bangkok -> UTC deterministic
    check(tz.selfcheck() == [], f"tz.selfcheck failed: {tz.selfcheck()}")
    gou1 = next((r for r in gou_opens if r["position_id"] == 700000001), None)
    check(gou1 is not None and gou1["mt5_time"] == "2026-07-06T07:30:00Z",
          f"GOU26 #1 UTC wrong: {gou1 and gou1['mt5_time']} (epoch 1783348200 -> want 07:30:00Z)")

    # (8) raw_sha stable for same input, changes for different input
    rec = {"symbol": "GOU26", "identifier": 1, "price_open": 4200.0}
    check(dry_run.raw_sha(rec) == dry_run.raw_sha(copy.deepcopy(rec)), "raw_sha not stable for identical input")
    rec2 = copy.deepcopy(rec); rec2["price_open"] = 4201.0
    check(dry_run.raw_sha(rec) != dry_run.raw_sha(rec2), "raw_sha did not change for changed input")

    # (9) report clearly separates mapped / needs_mapping / rejected
    sm = report["summary"]
    check(sm["accepted_mapped"] == len(accepted), "accepted count mismatch")
    check(sm["needs_mapping"] == len(needs), "needs_mapping count mismatch")
    check(sm["rejected_mapping"] == len(rej["mapping"]), "rejected mapping count mismatch")
    check(sm["rejected_structural"] == len(rej["structural"]), "rejected structural count mismatch")
    check(sm["accepted_mapped"] == 4 and sm["needs_mapping"] == 2, f"unexpected split: {sm}")

    # (bonus) idempotency collision (same position_id, different raw) is FATAL
    collide_fx = {
        "account": {"login": "700123456", "margin_mode": 2}, "user_id": fixture["user_id"],
        "observed_at_utc": "2026-07-07T17:00:00Z", "deals": [],
        "positions": [
            {"symbol": "GOU26", "identifier": 700000055, "ticket": 700000055, "type": 0,
             "volume": 1.0, "price_open": 4200.0, "time": 1783348200},
            {"symbol": "GOU26", "identifier": 700000055, "ticket": 700000055, "type": 0,
             "volume": 1.0, "price_open": 4999.0, "time": 1783348200},   # same key, different raw
        ],
    }
    rep5, fat5 = dry_run.process(collide_fx, mapping)
    check(fat5 is not None and rep5["idempotency"]["collisions"], "collision (same key, diff raw_sha) was not fatal")

    # (11) CLI exit-code contract: invalid JSON -> 2, malformed fixture STRUCTURE -> 2, collision -> 4
    with tempfile.TemporaryDirectory() as td:
        bad_json = os.path.join(td, "notjson.json")
        with open(bad_json, "w", encoding="utf-8") as f:
            f.write("{ not json")
        check(_main_exit(["--input", bad_json, "--mapping", FIX_MAP]) == 2,
              "invalid JSON must exit 2")

        malformed = os.path.join(td, "malformed.json")
        with open(malformed, "w", encoding="utf-8") as f:
            json.dump({"account": 123, "positions": [], "deals": []}, f)  # account not an object
        code_bad = _main_exit(["--input", malformed, "--mapping", FIX_MAP])
        check(code_bad == 2, f"malformed fixture structure must exit 2 (not 4), got {code_bad}")

        collide = os.path.join(td, "collide.json")
        with open(collide, "w", encoding="utf-8") as f:
            json.dump(collide_fx, f)
        code_coll = _main_exit(["--input", collide, "--mapping", FIX_MAP])
        check(code_coll == 4, f"idempotency collision must exit 4, got {code_coll}")

    # (10) no Supabase / MT5 / writer imports or network in the harness
    with open(os.path.join(_HERE, "dry_run.py"), "r", encoding="utf-8") as f:
        src_lines = f.read().splitlines()
    for ln in src_lines:
        st = ln.strip()
        if st.startswith("import ") or st.startswith("from "):
            for bad in ("staging_db", "writer", "MetaTrader5", "supabase", "urllib", "requests", "socket", "http"):
                check(bad not in st, f"harness has a forbidden import: {st!r}")
    for mod in ("MetaTrader5", "staging_db", "writer", "supabase"):
        check(mod not in sys.modules, f"forbidden module loaded into sys.modules: {mod}")

    print("dry_run tests:", "PASS" if not fails else "FAIL", f"({len(fails)} failure(s))")
    for x in fails:
        print("  -", x)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(run())
