#!/usr/bin/env python3
"""
MT5 S1 one-shot adapter — deterministic PURE tests.

No MetaTrader5, no Supabase, no network, no real clock, no secrets. Every MT5 interaction is a
fixed fake; every clock is injected. Run:

    python ops/mt5_import/test_s1_snapshot.py
    python ops/mt5_import/s1_snapshot.py --self-test      (same suite)

The suite also carries the two STRUCTURAL proofs the reviewed design depends on:
  - `--write` performs ZERO MetaTrader5 access (a poisoned module raises on any attribute touch),
  - one process issues at most ONE create_run stage and never a second cycle.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import io
import json
import math
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone

try:                                     # package mode
    from . import s1_client, s1_rows, s1_snapshot
except ImportError:                      # script mode
    import s1_client
    import s1_rows
    import s1_snapshot

FAILS = []
CHECKS = [0]


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


def expect_stop(fn, label):
    """A hard stop is common.stop() -> SystemExit(non-zero). Returns the exit code."""
    CHECKS[0] += 1
    buf_o, buf_e = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(buf_o), contextlib.redirect_stderr(buf_e):
            fn()
    except SystemExit as e:
        if e.code in (None, 0):
            FAILS.append(f"{label}: exited 0, expected a hard stop")
        return e.code
    except s1_snapshot.BrokerReadFailure:
        return "BrokerReadFailure"
    FAILS.append(f"{label}: did NOT stop")
    return None


def quiet(fn):
    buf_o, buf_e = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf_o), contextlib.redirect_stderr(buf_e):
        rc = fn()
    return rc, buf_o.getvalue(), buf_e.getvalue()


# =============================================================================================
# Fakes
# =============================================================================================
RES_S_OK = (1, "Success")
RES_FAIL = (-10004, "No IPC connection")


class FakePosition:
    """Mimics the MT5 TradePosition namedtuple surface used by common.as_dict()."""

    def __init__(self, **fields):
        self._fields = dict(fields)

    def _asdict(self):
        return dict(self._fields)


def pos(ticket=306676142, identifier=None, symbol="DELTAU26", type_=0, volume=2.0,
        price_open=54.25, price_current=53.75, profit=-1000.0, time_=1781000000,
        time_msc=1781000000123, drop=()):
    f = {
        "ticket": ticket,
        "identifier": ticket if identifier is None else identifier,
        "symbol": symbol,
        "type": type_,
        "volume": volume,
        "price_open": price_open,
        "price_current": price_current,
        "profit": profit,
        "time": time_,
        "time_msc": time_msc,
    }
    for k in drop:
        f.pop(k, None)
    return FakePosition(**f)


class FakeSymbolInfo:
    def __init__(self, path, csize, digits=2):
        self._f = {"path": path, "trade_contract_size": csize, "digits": digits}

    def _asdict(self):
        return dict(self._f)


class FakeAccount:
    def __init__(self, login=301102520, server="Test-Server", margin_mode=2, currency="THB"):
        self._f = {"login": login, "server": server, "margin_mode": margin_mode, "currency": currency}

    def _asdict(self):
        return dict(self._f)


class FakeTerminal:
    def __init__(self, build=4885):
        self._f = {"build": build}

    def _asdict(self):
        return dict(self._f)


NO_ACCOUNT = object()          # sentinel: account_info() must return a real None


class FakeMT5:
    def __init__(self, *, positions=(), account=None, last_error=RES_S_OK, symbols=None,
                 terminal=None):
        self._positions = positions
        self._account = FakeAccount() if account is None else (
            None if account is NO_ACCOUNT else account)
        self._last_error = last_error
        self._symbols = symbols if symbols is not None else {
            "DELTAU26": FakeSymbolInfo("TFEX\\Single Stock Future\\DELTAU26", 1000.0),
        }
        self._terminal = FakeTerminal() if terminal is None else terminal
        self.calls = []

    def account_info(self):
        self.calls.append("account_info")
        return self._account

    def positions_get(self):
        self.calls.append("positions_get")
        return self._positions

    def last_error(self):
        self.calls.append("last_error")
        return self._last_error

    def symbol_info(self, sym):
        self.calls.append(f"symbol_info:{sym}")
        return self._symbols.get(sym)

    def terminal_info(self):
        self.calls.append("terminal_info")
        return self._terminal

    def shutdown(self):
        self.calls.append("shutdown")


class StubClient:
    """Mirrors the S1Client surface run_write() consumes. Scripted, records every call."""

    def __init__(self, script=None):
        self.script = script or {}
        self.calls = []
        self.stage_calls = {}
        self.http_attempts = 0

    def _answer(self, name, default):
        self.stage_calls[name] = self.stage_calls.get(name, 0) + 1
        self.http_attempts += 1
        val = self.script.get(name, default)
        if isinstance(val, Exception):
            raise val
        return val

    def create_run(self, **kw):
        self.calls.append(("create_run", kw))
        return self._answer(s1_client.RPC_CREATE_RUN,
                            {"o_ok": True, "o_run_id": kw["run_id"],
                             "o_lease_expires_at": "2026-08-22T09:19:02Z", "o_error_code": None})

    def append_run_positions(self, **kw):
        self.calls.append(("append", kw))
        return self._answer(s1_client.RPC_APPEND_ROWS,
                            {"o_ok": True, "o_inserted": len(kw["rows"]), "o_error_code": None})

    def complete_snapshot(self, **kw):
        self.calls.append(("complete", kw))
        return self._answer(s1_client.RPC_COMPLETE,
                            {"o_ok": True, "o_run_seq": 1, "o_snapshot_health": "healthy",
                             "o_error_code": None})

    def reconcile_snapshot(self, **kw):
        self.calls.append(("reconcile", kw))
        return self._answer(s1_client.RPC_RECONCILE,
                            {"o_ok": True, "o_still_open": 2, "o_missing_once": 0,
                             "o_not_open_confirmed": 0, "o_conflicts": 0, "o_error_code": None})

    def mark_snapshot_failed(self, **kw):
        self.calls.append(("mark_snapshot_failed", kw))
        return self._answer(s1_client.RPC_MARK_SNAPSHOT_FAILED, {"o_ok": True, "o_error_code": None})

    def expire_stale_run(self, **kw):
        self.calls.append(("expire_stale_run", kw))
        return self._answer(s1_client.RPC_EXPIRE_STALE_RUN, {"o_ok": True, "o_error_code": None})


def names(client):
    return [c[0] for c in client.calls]


# =============================================================================================
# Fixtures
# =============================================================================================
UID = "b77d0426-1111-4222-8333-444455556666"
ACCT = "301102520"
NOW = datetime(2026, 8, 22, 9, 15, 0, tzinfo=timezone.utc)


def capture(mt5, **over):
    # connector_version is resolved BY MODE, mirroring resolve_connector_version() in the real CLI.
    # A v2 capture stamped with the S1 namespace is invalid (verification V13 would never see the
    # run), so a fixture must not be able to build one by accident.
    kw = {"user_id": UID, "source_account": ACCT, "lease_seconds": 300,
          "policy_version": "s1.v1", "max_positions": 200}
    kw.update(over)
    kw.setdefault("connector_version", s1_snapshot.resolve_connector_version(
        None, with_account_facts=bool(kw.get("with_account_facts"))))
    return s1_snapshot.capture_observation(mt5, **kw)


def good_envelope(rows=None):
    rows = rows if rows is not None else [{
        "position_id": 306676142, "symbol_raw": "DELTAU26", "side": "buy", "volume": 2.0,
        "price_open": 54.25, "price_current": 53.75, "profit": -1000.0,
        "open_time_utc": "2026-06-25T00:00:00Z", "source_time_msc": 1781000000123,
        "contract_size": 1000.0,
    }]
    return s1_rows.build_envelope(
        run_id="11111111-2222-4333-8444-555555555555",
        lease_token="99999999-8888-4777-8666-555555555555",
        user_id=UID, source_account=ACCT, captured_at="2026-08-22T09:14:00Z", lease_seconds=300,
        connector_version="s1-oneshot/0.1", terminal_build=4885, terminal_server="Test-Server",
        policy_version="s1.v1", rows=rows)


def write_args(path, sha, **over):
    ns = argparse.Namespace(
        envelope=path, envelope_sha256=sha, max_envelope_age_seconds=900,
        user_id=None, source_account=None, write=True, confirm=s1_snapshot.CONFIRM_WRITE,
        expire_run=None, self_test=False, lease_seconds=300, max_positions=200,
        connector_version="s1-oneshot/0.1", policy_version="s1.v1")
    for k, v in over.items():
        setattr(ns, k, v)
    return ns


@contextlib.contextmanager
def fake_supabase_env():
    """Placeholder values only. The client is always injected, so these are never used to connect."""
    old = {k: os.environ.get(k) for k in ("SUPABASE_URL", "SUPABASE_SERVICE_KEY")}
    os.environ["SUPABASE_URL"] = "http://127.0.0.1:1/not-used-by-tests"
    os.environ["SUPABASE_SERVICE_KEY"] = "placeholder-not-a-real-key"
    try:
        yield
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


@contextlib.contextmanager
def envelope_file(env):
    d = tempfile.mkdtemp(prefix="s1env_")
    path = os.path.join(d, "envelope.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(env, f, sort_keys=True)
    try:
        yield path
    finally:
        with contextlib.suppress(OSError):
            os.remove(path)
        with contextlib.suppress(OSError):
            os.rmdir(d)


# =============================================================================================
# Tests
# =============================================================================================
def t_strict_read():
    # healthy non-empty tuple
    ok = s1_snapshot.read_positions_strict(FakeMT5(positions=(pos(),)))
    check(isinstance(ok, tuple) and len(ok) == 1, "strict read: healthy non-empty tuple")

    # genuine empty tuple -> the ONLY eligible zero path
    empty = s1_snapshot.read_positions_strict(FakeMT5(positions=()))
    check(empty == (), "strict read: genuine empty tuple accepted")

    # None + real error -> hard stop
    m = FakeMT5(positions=None, last_error=RES_FAIL)
    try:
        s1_snapshot.read_positions_strict(m)
        FAILS.append("strict read: None+error did not raise")
    except s1_snapshot.BrokerReadFailure as e:
        check("COULD NOT BE DETERMINED" in str(e), "strict read: None+error message")
    CHECKS[0] += 1
    # last_error() must be captured IMMEDIATELY, before any other MT5 API call
    check(m.calls == ["positions_get", "last_error"], "strict read: last_error captured immediately")

    # None + RES_S_OK -> STILL a hard stop (the ambiguous case)
    try:
        s1_snapshot.read_positions_strict(FakeMT5(positions=None, last_error=RES_S_OK))
        FAILS.append("strict read: None+RES_S_OK did not raise")
    except s1_snapshot.BrokerReadFailure as e:
        check("RES_S_OK" in str(e), "strict read: None+RES_S_OK is still a hard stop")
    CHECKS[0] += 1

    # unknown shape
    try:
        s1_snapshot.read_positions_strict(FakeMT5(positions={"a": 1}))
        FAILS.append("strict read: dict shape accepted")
    except s1_snapshot.BrokerReadFailure:
        CHECKS[0] += 1

    # failure and success cannot share a representation: one raises, the other returns
    check(s1_snapshot.read_positions_strict(FakeMT5(positions=())) is not None,
          "strict read: empty returns a value, failure raises")


def t_capture_guards():
    expect_stop(lambda: capture(FakeMT5(positions=(pos(),), account=NO_ACCOUNT)),
                "capture: account_info None")
    expect_stop(lambda: capture(FakeMT5(positions=(pos(),)), source_account="999999"),
                "capture: source-account mismatch")
    expect_stop(lambda: capture(FakeMT5(positions=(pos(),), account=FakeAccount(margin_mode=0))),
                "capture: unsupported margin_mode (netting)")
    expect_stop(lambda: capture(FakeMT5(positions=(pos(),), account=FakeAccount(margin_mode=1))),
                "capture: unsupported margin_mode (exchange)")
    expect_stop(lambda: capture(FakeMT5(positions=tuple(pos(ticket=i) for i in range(1, 6))),
                                max_positions=3),
                "capture: max-positions cap")

    # identity guards run BEFORE the broker read: a mismatched account never even reads positions
    m = FakeMT5(positions=(pos(),))
    with contextlib.suppress(s1_snapshot.BrokerReadFailure):
        capture(m, source_account="999999")
    check("positions_get" not in m.calls, "capture: account guard precedes positions_get")


def t_capture_mapping():
    m = FakeMT5(positions=(pos(), pos(ticket=308292939, price_current=53.80, profit=-900.0)))
    env, missing, meta, facts = capture(m)
    rows = env["rows"]
    check(len(rows) == 2, "capture: two rows")
    check([r["position_id"] for r in rows] == [306676142, 308292939], "capture: rows sorted by id")
    check(all(set(r) == s1_rows.S1_ROW_KEY_SET for r in rows), "capture: exact 10-key payload")
    check(rows[0]["price_current"] == 53.75, "capture: price_current EXTRACTED")
    check(rows[0]["profit"] == -1000.0, "capture: profit EXTRACTED")
    check(rows[0]["contract_size"] == 1000.0, "capture: DELTAU26 contract_size 1000 preserved")
    check(rows[0]["side"] == "buy", "capture: side domain buy/sell")
    check(rows[0]["open_time_utc"].endswith("Z"), "capture: open_time_utc is ISO Z")
    check(env["expected_count"] == 2 and env["expected_ids"] == [306676142, 308292939],
          "capture: expected_count/ids derived from rows")
    check(facts["terminal_build"] == 4885, "capture: terminal build captured")
    for forbidden in ("captured_at", "user_id", "source_account", "row_fingerprint", "raw",
                      "normalized_symbol", "product_id_candidate", "instrument_class"):
        check(forbidden not in rows[0], f"capture: row must not carry {forbidden}")

    # genuine empty capture is a valid envelope with zero rows
    env0, _, _, _ = capture(FakeMT5(positions=()))
    check(env0["rows"] == [] and env0["expected_count"] == 0 and env0["expected_ids"] == [],
          "capture: genuine empty capture is a valid zero-row envelope")
    check(s1_rows.validate_envelope(env0) == [], "capture: empty envelope validates")


def t_contract_size():
    # symbol_info unavailable -> contract_size NULL, never 1
    m = FakeMT5(positions=(pos(symbol="MYSTERY"),), symbols={})
    env, missing, meta, _ = capture(m)
    check(env["rows"][0]["contract_size"] is None, "csize: symbol_info None -> NULL")
    check(env["rows"][0]["contract_size"] != 1, "csize: never defaulted to 1")
    check("contract_size" in missing[env["rows"][0]["position_id"]], "csize: missing-field recorded")

    # a stock-sized SSF is surfaced as a warning, not silently accepted
    m2 = FakeMT5(positions=(pos(),),
                 symbols={"DELTAU26": FakeSymbolInfo("TFEX\\Single Stock Future\\DELTAU26", 1.0)})
    env2, miss2, meta2, _ = capture(m2)
    warns = s1_snapshot.collect_warnings(env2["rows"], miss2, meta2)
    check(any("SSF->stock collapse" in w for w in warns), "csize: SSF csize=1 raises a warning")


def t_missing_optional_fields():
    m = FakeMT5(positions=(pos(drop=("price_current", "profit")),))
    env, missing, meta, _ = capture(m)
    row = env["rows"][0]
    check(row["price_current"] is None and row["profit"] is None,
          "optional: absent MT5 fields become NULL")
    check(set(row) == s1_rows.S1_ROW_KEY_SET, "optional: key set still exact")
    miss = missing[row["position_id"]]
    check("price_current" in miss and "profit" in miss, "optional: missing fields reported")
    warns = s1_snapshot.collect_warnings(env["rows"], missing, meta)
    check(any("price_current" in w for w in warns) and any("profit" in w for w in warns),
          "optional: preview warns about missing price_current/profit")
    check(s1_rows.validate_rows(env["rows"]) == [], "optional: NULL optionals are contractually valid")


def t_row_validation():
    base = good_envelope()["rows"][0]

    def bad(**over):
        r = dict(base)
        r.update(over)
        return r

    check(s1_rows.validate_rows([base]) == [], "validate: good row passes")
    check(s1_rows.validate_rows([bad(position_id=None)]), "validate: null position_id rejected")
    check(s1_rows.validate_rows([bad(position_id=0)]), "validate: zero position_id rejected")
    check(s1_rows.validate_rows([bad(position_id=-5)]), "validate: negative position_id rejected")
    check(s1_rows.validate_rows([bad(position_id=1.5)]), "validate: float position_id rejected")
    check(s1_rows.validate_rows([bad(position_id=True)]), "validate: bool position_id rejected")
    check(s1_rows.validate_rows([base, dict(base)]), "validate: duplicate position_id rejected")
    check(s1_rows.validate_rows([bad(symbol_raw="")]), "validate: blank symbol rejected")
    check(s1_rows.validate_rows([bad(symbol_raw="   ")]), "validate: whitespace symbol rejected")
    check(s1_rows.validate_rows([bad(side="BUY")]), "validate: uppercase side rejected")
    check(s1_rows.validate_rows([bad(side="long")]), "validate: invalid side rejected")
    check(s1_rows.validate_rows([bad(volume=0)]), "validate: zero volume rejected")
    check(s1_rows.validate_rows([bad(volume=-1)]), "validate: negative volume rejected")
    check(s1_rows.validate_rows([bad(volume=float("nan"))]), "validate: NaN volume rejected")
    check(s1_rows.validate_rows([bad(volume=float("inf"))]), "validate: inf volume rejected")
    check(s1_rows.validate_rows([bad(volume=None)]), "validate: null volume rejected")
    check(s1_rows.validate_rows([bad(price_current=float("nan"))]), "validate: NaN price_current rejected")
    check(s1_rows.validate_rows([bad(profit=float("-inf"))]), "validate: -inf profit rejected")
    check(s1_rows.validate_rows([bad(contract_size=float("nan"))]), "validate: NaN contract_size rejected")
    check(s1_rows.validate_rows([bad(price_open=None, price_current=None, profit=None,
                                     open_time_utc=None, source_time_msc=None,
                                     contract_size=None)]) == [],
          "validate: every nullable column may be NULL")
    check(s1_rows.validate_rows([bad(open_time_utc="2026-06-25 00:00:00")]),
          "validate: non-ISO-Z open_time_utc rejected")
    check(s1_rows.validate_rows([bad(source_time_msc="123")]), "validate: string source_time_msc rejected")

    # exact key set: extra, misspelled and missing all rejected
    extra = dict(base); extra["captured_at"] = "2026-08-22T09:14:00Z"
    check(s1_rows.validate_rows([extra]), "validate: extra key rejected")
    typo = dict(base); typo["price_curent"] = typo.pop("price_current")
    check(s1_rows.validate_rows([typo]), "validate: misspelled key rejected (would be a silent NULL)")
    short = dict(base); short.pop("profit")
    check(s1_rows.validate_rows([short]), "validate: missing key rejected")
    check(s1_rows.validate_rows("not-a-list"), "validate: non-list payload rejected")

    # a malformed row is NEVER skipped -- the whole snapshot stops
    errs = s1_rows.validate_rows([base, bad(position_id=308292939, side="nope")])
    check(len(errs) >= 1 and any("row[1]" in e for e in errs),
          "validate: malformed row fails the whole snapshot (never skipped)")


def t_envelope_hash():
    env = good_envelope()
    h1 = s1_rows.envelope_sha256(env)
    check(len(h1) == 64 and all(c in "0123456789abcdef" for c in h1), "hash: 64-hex")

    # stable across a JSON round-trip and key reordering
    round_tripped = json.loads(json.dumps(env, sort_keys=True))
    check(s1_rows.envelope_sha256(round_tripped) == h1, "hash: stable across JSON round-trip")
    reordered = {k: env[k] for k in reversed(list(env.keys()))}
    check(s1_rows.envelope_sha256(reordered) == h1, "hash: independent of key order")

    # any write-relevant mutation changes it
    for key, val in (("run_id", "00000000-0000-4000-8000-000000000000"),
                     ("captured_at", "2026-08-22T09:14:01Z"),
                     ("lease_seconds", 301),
                     ("source_account", "999999"),
                     ("policy_version", "s1.v2"),
                     ("expected_count", 2)):
        mutated = copy.deepcopy(env)
        mutated[key] = val
        check(s1_rows.envelope_sha256(mutated) != h1, f"hash: mutating {key} changes the hash")
    mutated = copy.deepcopy(env)
    mutated["rows"][0]["volume"] = 3.0
    check(s1_rows.envelope_sha256(mutated) != h1, "hash: mutating a row value changes the hash")

    # NaN can never be hashed into an envelope
    nan_env = copy.deepcopy(env)
    nan_env["rows"][0]["profit"] = float("nan")
    try:
        s1_rows.envelope_sha256(nan_env)
        FAILS.append("hash: NaN was hashed")
    except ValueError:
        CHECKS[0] += 1

    check(s1_rows.validate_envelope(env) == [], "envelope: good envelope validates")
    bad_fmt = copy.deepcopy(env); bad_fmt["envelope_format"] = "other/9"
    check(s1_rows.validate_envelope(bad_fmt), "envelope: unknown format rejected")
    bad_lease = copy.deepcopy(env); bad_lease["lease_seconds"] = 10
    check(s1_rows.validate_envelope(bad_lease), "envelope: lease below server minimum rejected")
    bad_lease2 = copy.deepcopy(env); bad_lease2["lease_seconds"] = 7200
    check(s1_rows.validate_envelope(bad_lease2), "envelope: lease above server maximum rejected")
    bad_ids = copy.deepcopy(env); bad_ids["expected_ids"] = [1]
    check(s1_rows.validate_envelope(bad_ids), "envelope: expected_ids mismatch rejected")
    bad_cnt = copy.deepcopy(env); bad_cnt["expected_count"] = 5
    check(s1_rows.validate_envelope(bad_cnt), "envelope: expected_count mismatch rejected")
    extra_key = copy.deepcopy(env); extra_key["sha256"] = "deadbeef"
    check(s1_rows.validate_envelope(extra_key),
          "envelope: an extra key (e.g. a self-stored hash) is rejected")


def t_arming_matrix():
    A = s1_snapshot.arming_status
    check(A(write=False, confirm=None, envelope=None, envelope_sha256=None,
            write_env=None)[0] == "preview", "arming: default is preview")
    good = dict(write=True, confirm=s1_snapshot.CONFIRM_WRITE, envelope="e.json",
                envelope_sha256="a" * 64, write_env="1")
    check(A(**good)[0] == "armed", "arming: all four keys + env arms")
    for over, label in (
        ({"confirm": None}, "missing --confirm"),
        ({"confirm": "write_s1_snapshot"}, "wrong-case --confirm"),
        ({"confirm": "WRITE_STAGING"}, "the Phase-0A literal is not accepted"),
        ({"write_env": None}, "missing MT5_S1_WRITE"),
        ({"write_env": "0"}, "MT5_S1_WRITE=0"),
        ({"envelope": None}, "missing --envelope"),
        ({"envelope_sha256": None}, "missing --envelope-sha256"),
        ({"envelope_sha256": "abc"}, "truncated hash"),
        ({"envelope_sha256": "a" * 63}, "63-char hash"),
        ({"envelope_sha256": "z" * 64}, "non-hex hash"),
    ):
        kw = dict(good); kw.update(over)
        check(A(**kw)[0] == "stop", f"arming: {label} refuses to arm")

    # An uppercase/whitespace-padded paste of the SAME hash is accepted: it is normalised on both
    # sides of the comparison, so it approves the same canonical payload, not a weaker check.
    kw = dict(good); kw["envelope_sha256"] = "  " + ("A" * 64) + " "
    check(A(**kw)[0] == "armed", "arming: uppercase/padded paste of the same hash arms")
    check(s1_snapshot.hash_matches("  " + "AB" * 32 + " ", "ab" * 32), "arming: hash compare normalises")
    check(not s1_snapshot.hash_matches("a" * 64, "b" * 64), "arming: different hashes never match")

    E = s1_snapshot.expire_arming_status
    check(E(confirm=s1_snapshot.CONFIRM_EXPIRE, write_env="1")[0] == "armed", "arming: expire arms")
    check(E(confirm=None, write_env="1")[0] == "stop", "arming: expire needs --confirm")
    check(E(confirm=s1_snapshot.CONFIRM_EXPIRE, write_env=None)[0] == "stop", "arming: expire needs env")
    check(E(confirm=s1_snapshot.CONFIRM_WRITE, write_env="1")[0] == "stop",
          "arming: expire rejects the write literal")


def t_envelope_age():
    env = good_envelope()
    age = s1_snapshot.envelope_age_seconds(env["captured_at"], NOW)
    check(abs(age - 60) < 1, "age: 60s computed correctly")
    check(s1_snapshot.envelope_age_seconds("nonsense", NOW) is None, "age: unparseable -> None")

    sha = s1_rows.envelope_sha256(env)
    with fake_supabase_env(), envelope_file(env) as path:
        # fresh -> proceeds
        client = StubClient()
        rc, _, _ = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: client))
        check(rc == 0, "age: fresh envelope proceeds")

        # 901s old -> hard stop BEFORE any DB call
        late = datetime(2026, 8, 22, 9, 14, 0, tzinfo=timezone.utc) + timedelta(seconds=901)
        blocked = StubClient()
        expect_stop(lambda: s1_snapshot.run_write(write_args(path, sha), now=late,
                                                  client_factory=lambda: blocked),
                    "age: >900s stops")
        check(blocked.calls == [], "age: expired envelope made ZERO db calls")

        # captured far in the future -> stop (a capture instant cannot precede its own clock)
        early = datetime(2026, 8, 22, 9, 10, 0, tzinfo=timezone.utc)
        fut = StubClient()
        expect_stop(lambda: s1_snapshot.run_write(write_args(path, sha), now=early,
                                                  client_factory=lambda: fut),
                    "age: far-future captured_at stops")
        check(fut.calls == [], "age: future envelope made ZERO db calls")

        # a couple of seconds of negative age is ordinary NTP skew and must NOT brittle-fail
        skewed = datetime(2026, 8, 22, 9, 13, 57, tzinfo=timezone.utc)   # age -3s
        tol = StubClient()
        rc, _, _ = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=skewed, client_factory=lambda: tol))
        check(rc == 0, "age: -3s clock skew is tolerated")
        beyond = datetime(2026, 8, 22, 9, 13, 50, tzinfo=timezone.utc)   # age -10s > tolerance
        tol2 = StubClient()
        expect_stop(lambda: s1_snapshot.run_write(write_args(path, sha), now=beyond,
                                                  client_factory=lambda: tol2),
                    "age: skew beyond tolerance stops")
        check(tol2.calls == [], "age: out-of-tolerance skew made ZERO db calls")
        check(s1_snapshot.CLOCK_SKEW_TOLERANCE_SECONDS == 5, "age: tolerance is 5s")


def t_hash_binding():
    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)
    with fake_supabase_env(), envelope_file(env) as path:
        # wrong hash supplied -> stop, zero DB calls
        c1 = StubClient()
        expect_stop(lambda: s1_snapshot.run_write(write_args(path, "b" * 64), now=NOW,
                                                  client_factory=lambda: c1),
                    "hash-binding: wrong hash stops")
        check(c1.calls == [], "hash-binding: wrong hash made ZERO db calls")

    # file mutated after approval -> recomputed hash no longer matches the approved one
    tampered = copy.deepcopy(env)
    tampered["rows"][0]["volume"] = 99.0
    tampered["expected_ids"] = s1_rows.expected_ids_from_rows(tampered["rows"])
    with fake_supabase_env(), envelope_file(tampered) as path:
        c2 = StubClient()
        expect_stop(lambda: s1_snapshot.run_write(write_args(path, sha), now=NOW,
                                                  client_factory=lambda: c2),
                    "hash-binding: mutated file stops")
        check(c2.calls == [], "hash-binding: mutated file made ZERO db calls")

    # identity cross-check
    with fake_supabase_env(), envelope_file(env) as path:
        c3 = StubClient()
        expect_stop(lambda: s1_snapshot.run_write(
            write_args(path, sha, source_account="999999"), now=NOW, client_factory=lambda: c3),
            "hash-binding: --source-account mismatch stops")
        check(c3.calls == [], "hash-binding: identity mismatch made ZERO db calls")


def t_write_never_touches_mt5():
    """STRUCTURAL PROOF: any MetaTrader5 attribute access during --write raises."""

    class Poisoned:
        def __getattr__(self, name):
            raise AssertionError(f"--write touched MetaTrader5.{name}")

    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)
    old_mod = sys.modules.get("MetaTrader5")
    old_connect = s1_snapshot._mt5_connect
    sys.modules["MetaTrader5"] = Poisoned()

    def boom():
        raise AssertionError("--write called _mt5_connect()")

    s1_snapshot._mt5_connect = boom
    try:
        with fake_supabase_env(), envelope_file(env) as path:
            client = StubClient()
            rc, _, _ = quiet(lambda: s1_snapshot.run_write(
                write_args(path, sha), now=NOW, client_factory=lambda: client))
            check(rc == 0, "write: full cycle succeeds with MetaTrader5 poisoned")
            check(names(client) == ["create_run", "append", "complete", "reconcile"],
                  "write: exactly the four cycle stages, in order")
    finally:
        s1_snapshot._mt5_connect = old_connect
        if old_mod is None:
            sys.modules.pop("MetaTrader5", None)
        else:
            sys.modules["MetaTrader5"] = old_mod

    # And statically: the only real `import MetaTrader5` STATEMENT lives inside _mt5_connect
    # (string mentions in messages/docstrings are not imports and are excluded by design).
    src = open(s1_snapshot.__file__, "r", encoding="utf-8").read()
    stmts = [ln for ln in src.splitlines() if ln.strip().startswith("import MetaTrader5")]
    check(len(stmts) == 1, f"write: exactly one MetaTrader5 import statement (found {len(stmts)})")
    body = src.split("def _mt5_connect", 1)[1].split("\ndef ", 1)[0]
    check(any(ln in body for ln in stmts), "write: that import statement is inside _mt5_connect")
    # _mt5_connect is reachable only from run_preview
    call_sites = [ln for ln in src.splitlines()
                  if "_mt5_connect()" in ln and not ln.strip().startswith("def ")]
    check(len(call_sites) == 1, f"write: _mt5_connect() has exactly one call site "
                                f"(found {len(call_sites)}: {call_sites})")
    preview_body = src.split("def run_preview", 1)[1].split("\ndef ", 1)[0]
    check("_mt5_connect()" in preview_body, "write: the only _mt5_connect() call is in run_preview")
    write_body = src.split("def run_write", 1)[1].split("\ndef ", 1)[0]
    for token in ("_mt5_connect", "MetaTrader5", "positions_get", "account_info", "symbol_info",
                  "terminal_info", "initialize"):
        check(token not in write_body, f"write: run_write body contains no {token!r}")


def t_one_cycle_only():
    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)
    with fake_supabase_env(), envelope_file(env) as path:
        client = StubClient()
        rc, out, _ = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: client))
        check(rc == 0, "one-cycle: success")
        check(client.stage_calls.get(s1_client.RPC_CREATE_RUN) == 1,
              "one-cycle: exactly ONE create_run stage")
        check(len(client.calls) == 4, "one-cycle: exactly four RPC calls total")
        check(names(client).count("create_run") == 1, "one-cycle: no second cycle")
        check("no scheduler, no loop, no second cycle" in out, "one-cycle: exit banner")

    # no scheduler / loop constructs anywhere in the adapter
    for mod in (s1_snapshot, s1_client, s1_rows):
        src = open(mod.__file__, "r", encoding="utf-8").read()
        low = src.lower()
        for token in ("schtasks", "while true", "apscheduler", "crontab", "threading.timer",
                      "subprocess."):
            check(token not in low, f"no-scheduler: {mod.__name__} contains no {token!r}")


def t_failure_terminalization():
    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)

    # A. create_run contract failure -> NO mark_* at all
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_CREATE_RUN: {
            "o_ok": False, "o_run_id": "aaaaaaaa-1111-4111-8111-111111111111",
            "o_lease_expires_at": "2026-08-22T09:20:00Z", "o_error_code": "ERR_RUN_ACTIVE"}})
        rc, _, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 6, "fail-A: create_run failure exits non-zero")
        check(names(c) == ["create_run"], "fail-A: no mark_* after a failed create_run")
        check("ERR_RUN_ACTIVE" in err and "will NOT touch a run it does not own" in err,
              "fail-A: ERR_RUN_ACTIVE is report-and-stop")

    # A2. create_run TRANSPORT failure -> still no mark_*
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_CREATE_RUN: s1_client.S1TransportError("boom")})
        rc, _, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 5 and names(c) == ["create_run"], "fail-A2: transport create failure -> no cleanup")
        check("RUN_STATE_UNKNOWN" in err, "fail-A2: reports RUN_STATE_UNKNOWN")

    # B. append contract failure -> mark_snapshot_failed(APPEND_FAILED); original preserved
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_APPEND_ROWS: {
            "o_ok": False, "o_inserted": 0, "o_error_code": "ERR_MISSING_FACT"}})
        rc, _, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 7, "fail-B: append failure exits non-zero")
        check(names(c) == ["create_run", "append", "mark_snapshot_failed"], "fail-B: cleanup attempted")
        check(c.calls[-1][1]["reason_code"] == "APPEND_FAILED", "fail-B: reason APPEND_FAILED")
        check("ORIGINAL FAILURE" in err and "ERR_MISSING_FACT" in err,
              "fail-B: original failure preserved")

    # B2. complete contract failure -> SEAL_FAILED
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_COMPLETE: {
            "o_ok": False, "o_run_seq": None, "o_snapshot_health": None,
            "o_error_code": "ERR_SET_MISMATCH"}})
        rc, _, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 7 and c.calls[-1][1]["reason_code"] == "SEAL_FAILED", "fail-B2: reason SEAL_FAILED")

    # B3. cleanup failure must NOT hide the original failure
    class CleanupFails(StubClient):
        def mark_snapshot_failed(self, **kw):
            self.calls.append(("mark_snapshot_failed", kw))
            raise s1_client.S1TransportError("cleanup network down")

    with fake_supabase_env(), envelope_file(env) as path:
        c = CleanupFails({s1_client.RPC_APPEND_ROWS: {
            "o_ok": False, "o_inserted": 0, "o_error_code": "ERR_LEASE_EXPIRED"}})
        rc, _, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 7, "fail-B3: still exits on the original failure")
        check("cleanup FAILED" in err and "ERR_LEASE_EXPIRED" in err,
              "fail-B3: cleanup failure logged WITHOUT hiding the original")

    # B4. append TRANSPORT failure -> outcome unknown -> NO auto-terminalise (replay stays possible)
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_APPEND_ROWS: s1_client.S1TransportError("lost ack")})
        rc, _, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 5, "fail-B4: transport append failure exits non-zero")
        check(names(c) == ["create_run", "append"], "fail-B4: NO mark_* on an unknown outcome")
        check("replays idempotently" in err and "still 'started'" in err,
              "fail-B4: points at idempotent replay and names the run state")


def t_sealed_fails_closed():
    """HIGH finding: ERR_RUN_SEALED must FAIL CLOSED.

    It proves only that run identity + create metadata match. A different envelope can keep the same
    ids and count while changing any per-position fact, and would carry its own perfectly valid
    canonical SHA-256 -- so neither the hash gate nor a completion replay can catch it here.
    Nothing after create_run may run.
    """
    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)
    sealed = {"o_ok": False, "o_run_id": env["run_id"], "o_lease_expires_at": None,
              "o_error_code": "ERR_RUN_SEALED"}

    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_CREATE_RUN: sealed})
        rc, out, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 10, f"sealed: exits non-zero with the dedicated code (rc={rc})")
        check(names(c) == ["create_run"], f"sealed: ONLY create_run was called ({names(c)})")
        for forbidden in ("append", "complete", "reconcile", "mark_snapshot_failed",
                          "expire_stale_run"):
            check(forbidden not in names(c), f"sealed: {forbidden} was NOT called")
        check(c.stage_calls.get(s1_client.RPC_APPEND_ROWS, 0) == 0, "sealed: 0 append stages")
        check(c.stage_calls.get(s1_client.RPC_COMPLETE, 0) == 0, "sealed: 0 complete stages")
        check(c.stage_calls.get(s1_client.RPC_RECONCILE, 0) == 0, "sealed: 0 reconcile stages")
        check("SEALED_RUN_REVIEW_REQUIRED" in err, "sealed: SEALED_RUN_REVIEW_REQUIRED reported")
        check("CANNOT prove" in err, "sealed: explains the unprovable fact gap")
        check("NO reconciliation was attempted" in err, "sealed: says no reconciliation happened")
        check("Do NOT simply re-run this envelope" in err,
              "sealed: does NOT advise retrying the same envelope")

    # A FACT-MUTATED envelope keeps run_id/user/account/captured_at/ids/count and is fully valid
    # with its OWN hash -- the sealed guard, not the hash gate, is what must stop it.
    mutated = copy.deepcopy(env)
    mutated["rows"][0]["price_current"] = 999.99
    check(s1_rows.validate_envelope(mutated) == [], "sealed: fact-mutated envelope is itself valid")
    mutated_sha = s1_rows.envelope_sha256(mutated)
    check(mutated_sha != sha, "sealed: fact mutation changes the canonical hash")
    check(mutated["run_id"] == env["run_id"] and mutated["captured_at"] == env["captured_at"]
          and mutated["expected_ids"] == env["expected_ids"]
          and mutated["expected_count"] == env["expected_count"],
          "sealed: mutated envelope keeps identity, captured_at, ids and count")
    with fake_supabase_env(), envelope_file(mutated) as path:
        c = StubClient({s1_client.RPC_CREATE_RUN: sealed})
        rc, out, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, mutated_sha), now=NOW, client_factory=lambda: c))
        check(rc == 10 and names(c) == ["create_run"],
              "sealed: a fact-mutated envelope with a VALID hash is still stopped at create_run")
        check("SEALED_RUN_REVIEW_REQUIRED" in err, "sealed: fact-mutated envelope also reviews")

    # ERR_RUN_FAILED stays a plain create failure (distinct code, still nothing after create_run)
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_CREATE_RUN: {
            "o_ok": False, "o_run_id": env["run_id"], "o_lease_expires_at": None,
            "o_error_code": "ERR_RUN_FAILED"}})
        rc, out, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 6 and names(c) == ["create_run"], "sealed: ERR_RUN_FAILED is a distinct stop")
        check("SEALED_RUN_REVIEW_REQUIRED" not in err,
              "sealed: ERR_RUN_FAILED is not the sealed status")

    # STRUCTURAL: no resume path survives anywhere in the orchestrator
    src = open(s1_snapshot.__file__, "r", encoding="utf-8").read()
    for token in ("resume_sealed", "replay-verified", "resuming at completion-replay",
                  "COMPLETION REPLAY MISMATCH"):
        check(token not in src, f"sealed: no {token!r} resume remnant remains")


def t_reconcile_status_matrix():
    """MEDIUM finding: each reconcile outcome gets its own accurate status and guidance."""
    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)

    def answer(code):
        return {"o_ok": False, "o_still_open": 0, "o_missing_once": 0, "o_not_open_confirmed": 0,
                "o_conflicts": 0, "o_error_code": code}

    def run(reconcile_answer):
        with fake_supabase_env(), envelope_file(env) as path:
            c = StubClient({s1_client.RPC_RECONCILE: reconcile_answer})
            rc, out, err = quiet(lambda: s1_snapshot.run_write(
                write_args(path, sha), now=NOW, client_factory=lambda: c))
            return rc, out, err, c

    # (A) live contract refusal -> pending, review required
    rc, out, err, c = run(answer("ERR_BASELINE_INVALID"))
    check(rc == 8, "reconcile-A: exits 8")
    check(names(c) == ["create_run", "append", "complete", "reconcile"], "reconcile-A: no mark_*")
    check("RECONCILE_PENDING_REVIEW_REQUIRED" in err, "reconcile-A: PENDING_REVIEW_REQUIRED")
    check("still pending" in err, "reconcile-A: states the run is still pending")
    check("READ-ONLY run-state inspection" in err, "reconcile-A: routes to read-only inspection")

    # (B) lease expired -> its own status, no auto-expire, no loop
    rc, out, err, c = run(answer("ERR_LEASE_EXPIRED"))
    check(rc == 8, "reconcile-B: exits 8")
    check("RECONCILE_LEASE_EXPIRED_REVIEW_REQUIRED" in err, "reconcile-B: LEASE_EXPIRED status")
    check("will NOT renew a sealed run" in err, "reconcile-B: says --write cannot renew the lease")
    check("do NOT auto-expire" in err, "reconcile-B: says it did not auto-expire")
    check("reconcile_status=failed" in err, "reconcile-B: explains what expiry would leave")
    check("NEW cycle" in err, "reconcile-B: says a new cycle is then required")
    check("expire_stale_run" not in names(c), "reconcile-B: expire was NOT called")

    # (C) already terminal -> must NOT claim pending
    for code in sorted(s1_snapshot.RECONCILE_TERMINAL_CODES):
        rc, out, err, c = run(answer(code))
        check(rc == 8, f"reconcile-C[{code}]: exits 8")
        check("RECONCILE_TERMINAL_REVIEW_REQUIRED" in err, f"reconcile-C[{code}]: TERMINAL status")
        check("already FAILED and terminal" in err, f"reconcile-C[{code}]: says terminal")
        check("RECONCILE_PENDING_REVIEW_REQUIRED" not in err,
              f"reconcile-C[{code}]: does NOT claim pending")
        check("mark_snapshot_failed" not in names(c), f"reconcile-C[{code}]: no mark_*")

    # (D) transport -> outcome unknown
    rc, out, err, c = run(s1_client.S1TransportError("down"))
    check(rc == 8, "reconcile-D: exits 8")
    check("RECONCILE_RESULT_UNKNOWN" in err, "reconcile-D: RESULT_UNKNOWN status")
    check("MAY or MAY NOT have been applied" in err, "reconcile-D: states the outcome is unknown")
    check(names(c) == ["create_run", "append", "complete", "reconcile"],
          "reconcile-D: no mark_*, no expire")

    # No branch may advise a same-envelope retry, and every branch says the retry fails closed.
    for ans in (answer("ERR_BASELINE_INVALID"), answer("ERR_LEASE_EXPIRED"),
                answer("RECONCILE_FAILED"), s1_client.S1TransportError("down")):
        _, _, err, _ = run(ans)
        check("RETRY_REQUIRED" not in err, "reconcile: no branch says RETRY_REQUIRED")
        check("Re-running this envelope is NOT the recovery path" in err,
              "reconcile: every branch says a re-run fails closed")
        check("SEALED_RUN_REVIEW_REQUIRED" in err,
              "reconcile: every branch names the fail-closed outcome of a re-run")
        check("mt5_mark_reconcile_failed_v1" in err,
              "reconcile: every branch states it did not call mark_reconcile_failed")

    # complete-stage transport failure must NOT promise an idempotent re-run either
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_COMPLETE: s1_client.S1TransportError("down")})
        rc, out, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 5, "reconcile: complete transport failure exits 5")
        check("Do NOT assume a re-run works" in err and "SEALED_RUN_REVIEW_REQUIRED" in err,
              "reconcile: complete transport failure warns the seal may have landed")

    # ...while an append-stage transport failure still may be replayed (run is still 'started')
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_APPEND_ROWS: s1_client.S1TransportError("down")})
        rc, out, err = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 5, "reconcile: append transport failure exits 5")
        check("still 'started'" in err, "reconcile: append transport failure names the run state")
        check("replays" in err, "reconcile: append transport failure still offers idempotent replay")

    # STRUCTURAL: the adapter cannot auto-fail a reconcile
    check("mt5_mark_reconcile_failed_v1" not in s1_client.ALLOWED_RPCS,
          "reconcile: mark_reconcile_failed is NOT in the client allowlist")
    check(not hasattr(s1_client.S1Client, "mark_reconcile_failed"),
          "reconcile: S1Client exposes no mark_reconcile_failed method")
    src = open(s1_snapshot.__file__, "r", encoding="utf-8").read()
    check(".mark_reconcile_failed(" not in src,
          "reconcile: orchestrator never calls mark_reconcile_failed")
    check(s1_snapshot.STAGE_RECONCILE not in s1_snapshot.STAGE_FAILED_REASON,
          "reconcile: no cleanup reason is mapped for the reconcile stage")


def t_canonical_payload_wording():
    """LOW finding: the SHA binds the CANONICAL WRITE PAYLOAD, not the raw file bytes."""
    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)

    # Reformatting the file must NOT change the hash -- that is the semantics we now claim.
    reformatted = json.dumps(env, indent=4, sort_keys=False) + "\n\n"
    check(s1_rows.envelope_sha256(json.loads(reformatted)) == sha,
          "canonical: reformatted JSON keeps the same hash")

    # ...and a reformatted file is accepted by the write path with the SAME approved hash.
    d = tempfile.mkdtemp(prefix="s1fmt_")
    path = os.path.join(d, "envelope.json")
    with open(path, "w", encoding="utf-8") as f:
        f.write(reformatted)
    try:
        with fake_supabase_env():
            c = StubClient()
            rc, _, err = quiet(lambda: s1_snapshot.run_write(
                write_args(path, sha), now=NOW, client_factory=lambda: c))
            check(rc == 0, f"canonical: reformatted file still matches approval ({err[:150]})")
    finally:
        with contextlib.suppress(OSError):
            os.remove(path)
        with contextlib.suppress(OSError):
            os.rmdir(d)

    # A write-relevant semantic change ALWAYS changes the hash (the guarantee we do claim).
    for key, val in (("lease_seconds", 301), ("captured_at", "2026-08-22T09:14:01Z")):
        m = copy.deepcopy(env)
        m[key] = val
        check(s1_rows.envelope_sha256(m) != sha, f"canonical: changing {key} changes the hash")

    # No source or doc may claim raw-byte binding.
    readme = os.path.join(os.path.dirname(s1_snapshot.__file__), "README.md")
    for path in (s1_rows.__file__, s1_client.__file__, s1_snapshot.__file__, readme):
        text = open(path, "r", encoding="utf-8").read().lower()
        for claim in ("exact bytes", "byte-identical", "byte-for-byte", "exact file"):
            check(claim not in text, f"canonical: {os.path.basename(path)} has no {claim!r} claim")


def t_idempotent_replay():
    """Lost-ACK behaviour: a replayed append reports 0 inserted and is still a success."""
    env = good_envelope()
    sha = s1_rows.envelope_sha256(env)
    with fake_supabase_env(), envelope_file(env) as path:
        c = StubClient({s1_client.RPC_APPEND_ROWS: {
            "o_ok": True, "o_inserted": 0, "o_error_code": None}})
        rc, out, _ = quiet(lambda: s1_snapshot.run_write(
            write_args(path, sha), now=NOW, client_factory=lambda: c))
        check(rc == 0, "replay: 0-inserted append is a success")
        check("inserted=0" in out and "idempotent replay" in out, "replay: banner explains 0 inserted")

    # every retry sends identical parameters and never regenerates identity
    calls = []

    class Flaky(s1_client.S1Client):
        def _post_rpc(self, name, params):
            calls.append(copy.deepcopy(params))
            self.http_attempts += 1
            if len(calls) < 3:
                raise s1_client.S1TransportError("transient")
            return [{"o_ok": True, "o_error_code": None}]

    cli = Flaky("http://x", "k", sleeper=lambda s: None)
    res = cli.expire_stale_run(run_id="r", user_id="u", source_account="a")
    check(res["o_ok"] and len(calls) == 3, "retry: 2 retries then success (3 attempts)")
    check(calls[0] == calls[1] == calls[2], "retry: parameters identical across attempts")
    check(cli.stage_calls[s1_client.RPC_EXPIRE_STALE_RUN] == 1, "retry: still ONE logical stage")

    # exhausted retries raise, and a contract answer is never retried
    calls.clear()

    class AlwaysDown(s1_client.S1Client):
        def _post_rpc(self, name, params):
            calls.append(params)
            raise s1_client.S1TransportError("down")

    cli2 = AlwaysDown("http://x", "k", sleeper=lambda s: None)
    try:
        cli2.expire_stale_run(run_id="r", user_id="u", source_account="a")
        FAILS.append("retry: exhausted retries did not raise")
    except s1_client.S1TransportError:
        CHECKS[0] += 1
    check(len(calls) == 3, "retry: bounded at 3 attempts (2 retries)")


def t_client_surface():
    check(s1_client.ALLOWED_RPCS == frozenset({
        "mt5_create_run_v1", "mt5_append_run_positions_v1", "mt5_complete_snapshot_v1",
        "mt5_reconcile_snapshot_v1", "mt5_mark_snapshot_failed_v1", "mt5_expire_stale_run_v1",
        "mt5_append_run_account_v1"}),
        "client: allowlist is exactly the seven connector RPCs (six S1 + one S1.1)")
    check("mt5_get_current_snapshot_v1" not in s1_client.ALLOWED_RPCS,
          "client: browser read RPC is not reachable from service_role")

    cli = s1_client.S1Client("http://x", "k")
    try:
        cli._post_rpc("mt5_confirm_group", {})
        FAILS.append("client: non-allowlisted RPC accepted")
    except s1_client.S1ClientError:
        CHECKS[0] += 1
    try:
        cli.mark_snapshot_failed(run_id="r", user_id="u", source_account="a",
                                 lease_token="t", reason_code="NOT_A_REASON")
        FAILS.append("client: non-allowlisted reason accepted")
    except s1_client.S1ClientError:
        CHECKS[0] += 1

    # the key never appears in an error message
    class Boom(s1_client.S1Client):
        def _post_rpc(self, name, params):
            raise s1_client.S1ClientError(f"HTTP 400 on rpc {name}: detail")

    b = Boom("http://x", "super-secret-key")
    try:
        b.expire_stale_run(run_id="r", user_id="u", source_account="a")
    except s1_client.S1ClientError as e:
        check("super-secret-key" not in str(e), "client: service key absent from error text")

    src = open(s1_client.__file__, "r", encoding="utf-8").read()
    check("/rest/v1/rpc/" in src, "client: reaches only the /rest/v1/rpc/ path")
    check("/rest/v1/{table}" not in src and 'f"{self.base}/rest/v1/{' not in src,
          "client: no table URL is ever constructed")
    check("def rpc(" not in src, "client: no generic public rpc() method")
    check(src.count('method="POST"') == 1 and 'method="DELETE"' not in src
          and 'method="PATCH"' not in src and 'method="GET"' not in src,
          "client: POST is the only HTTP method")


def t_side_effects_declared():
    text = s1_snapshot.side_effect_preview(3)
    for token in ("mt5_sync_runs", "mt5_sync_run_positions", "mt5_import_staging lifecycle",
                  "Journal trades", "trade_groups", "checkin", "Telegram", "S1.1",
                  "schedule, loop or start another cycle"):
        check(token in text, f"side-effects: preview declares {token!r}")

    # S1.1 fields can never be captured or sent: they are not S1 columns and not envelope keys,
    # and the exact-key-set rule rejects them if anything ever tried.
    for token in ("account_balance", "equity", "currency", "balance"):
        check(token not in s1_rows.S1_ROW_KEY_SET, f"no-S1.1: {token!r} is not an S1 row key")
        check(token not in s1_rows.ENVELOPE_KEY_SET, f"no-S1.1: {token!r} is not an envelope key")
    env = good_envelope()
    check(all(set(r) == s1_rows.S1_ROW_KEY_SET for r in env["rows"]),
          "no-S1.1: sealed rows carry exactly the ten S1 columns")
    smuggled = copy.deepcopy(env)
    smuggled["rows"][0]["equity"] = 123.0
    check(s1_rows.validate_rows(smuggled["rows"]), "no-S1.1: a smuggled equity key is rejected")


def t_preview_wording():
    """The two zero-position states must never share wording."""
    m = FakeMT5(positions=())
    env, missing, meta, facts = capture(m)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        s1_snapshot.print_preview(env, missing, meta, facts, envelope_path="x.json", sha256="a" * 64)
    out = buf.getvalue()
    check("OPEN POSITIONS OBSERVED: 0" in out, "wording: genuine empty count line")
    check("broker read HEALTHY - positions_get returned an empty tuple" in out,
          "wording: genuine empty is explicitly HEALTHY")
    check("COULD NOT BE DETERMINED" not in out, "wording: healthy empty never says undetermined")

    args = argparse.Namespace(
        user_id=UID, source_account=ACCT, lease_seconds=300, connector_version="s1-oneshot/0.1",
        policy_version="s1.v1", max_positions=200, envelope=None)
    old = s1_snapshot._mt5_connect
    s1_snapshot._mt5_connect = lambda: FakeMT5(positions=None, last_error=RES_FAIL)
    try:
        rc, out2, err2 = quiet(lambda: s1_snapshot.run_preview(args))
    finally:
        s1_snapshot._mt5_connect = old
    check(rc == 3, "wording: failed read exits non-zero")
    check("BROKER READ FAILED" in out2 and "No S1 write is possible." in out2,
          "wording: failure banner")
    check("OPEN POSITIONS OBSERVED" not in out2, "wording: failure never reports a count")
    check("--write" not in out2 and "No envelope was created" in err2,
          "wording: failure offers NO arm instruction and creates no envelope")


ALL = [
    t_strict_read, t_capture_guards, t_capture_mapping, t_contract_size, t_missing_optional_fields,
    t_row_validation, t_envelope_hash, t_arming_matrix, t_envelope_age, t_hash_binding,
    t_write_never_touches_mt5, t_one_cycle_only, t_failure_terminalization,
    t_sealed_fails_closed, t_reconcile_status_matrix, t_canonical_payload_wording,
    t_idempotent_replay, t_client_surface, t_side_effects_declared, t_preview_wording,
]


def main():
    for fn in ALL:
        try:
            fn()
        except Exception as e:                                   # a test itself blew up
            FAILS.append(f"{fn.__name__} raised {type(e).__name__}: {e}")
    print(f"s1_snapshot pure tests: {CHECKS[0]} checks, "
          f"{'PASS' if not FAILS else f'{len(FAILS)} FAIL'}")
    for f in FAILS:
        print("  FAIL:", f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
