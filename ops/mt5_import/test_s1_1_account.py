#!/usr/bin/env python3
"""
MT5 S1.1 — pure checks for the account observation layer.

PURE: no MetaTrader5, no database, no network, no wall clock. Every timestamp and every RPC
outcome is injected. Run with:  python -X utf8 ops/mt5_import/test_s1_1_account.py

Covers the connector half of the frozen design's acceptance matrix:
    B1-B6  non-finite NORMALISATION vs the DEFENSIVE SERIALISER backstop (two distinct things)
    D1-D8  the class A / B / C account-append state machine
    E1-E3  envelope v1/v2 bidirectional format gate and canonical-SHA sensitivity
The database half (A1-A6, B7-B10, C1-C11, F1-F6) needs a real PostgreSQL and lives in the
disposable harness -- proving a CHECK rejects a row requires attempting to insert it.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common                                                            # noqa: E402
import s1_client                                                        # noqa: E402
import s1_rows                                                          # noqa: E402
import s1_snapshot                                                      # noqa: E402
import test_s1_snapshot as base                                         # noqa: E402

CHECKS = [0]
FAILS = []
UID = base.UID
ACCT = base.ACCT


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


# ==============================================================================================
# fakes
# ==============================================================================================
class FakeAccount2:
    """Second-read account sample. `login` defaults to the expected account."""

    def __init__(self, *, login=None, equity=100000.0, balance=120000.0, currency="THB",
                 server="PiSecurities-Live", margin_mode=2):
        self.login = int(ACCT) if login is None else login
        self.equity = equity
        self.balance = balance
        self.currency = currency
        self.server = server
        self.margin_mode = margin_mode

    def _asdict(self):
        return dict(self.__dict__)


class TwoReadMT5(base.FakeMT5):
    """account_info() returns the identity sample first, then the financial sample."""

    def __init__(self, *, second, **kw):
        super().__init__(**kw)
        self._second = second
        self._account_reads = 0

    def account_info(self):
        self.calls.append("account_info")
        self._account_reads += 1
        if self._account_reads == 1:
            return self._account
        if self._second == "raise":
            raise RuntimeError("terminal went away")
        return self._second


_RPC_NAME = {
    "create": s1_client.RPC_CREATE_RUN, "append": s1_client.RPC_APPEND_ROWS,
    "account": s1_client.RPC_APPEND_ACCOUNT, "complete": s1_client.RPC_COMPLETE,
    "reconcile": s1_client.RPC_RECONCILE, "mark_failed": s1_client.RPC_MARK_SNAPSHOT_FAILED,
}


class FakeClient:
    """Scripted S1 client. `script` maps stage name -> 'ok' | dict | Exception instance."""

    def __init__(self, script):
        self.script = dict(script)
        self.calls = []
        self.stage_calls = {}
        self.http_attempts = 0

    def _r(self, stage, ok_extra=None):
        self.calls.append(stage)
        rpc = _RPC_NAME[stage]
        self.stage_calls[rpc] = self.stage_calls.get(rpc, 0) + 1
        self.http_attempts += 1
        out = self.script.get(stage, "ok")
        if isinstance(out, Exception):
            raise out
        if out == "ok":
            res = {"o_ok": True, "o_error_code": None}
            res.update(ok_extra or {})
            return res
        return out

    def create_run(self, **kw):
        return self._r("create", {"o_lease_expires_at": "2026-08-22T13:00:00Z"})

    def append_run_positions(self, **kw):
        return self._r("append", {"o_inserted": len(kw.get("rows") or [])})

    def append_run_account(self, **kw):
        self.last_facts = kw.get("facts")
        return self._r("account", {"o_inserted": 1})

    def complete_snapshot(self, **kw):
        return self._r("complete", {"o_run_seq": 1, "o_snapshot_health": "healthy"})

    def reconcile_snapshot(self, **kw):
        return self._r("reconcile", {"o_still_open": 0, "o_missing_once": 0,
                                     "o_not_open_confirmed": 0, "o_conflicts": 0})

    def mark_snapshot_failed(self, **kw):
        self.last_reason = kw.get("reason_code")
        return self._r("mark_failed")


GOOD_ACCOUNT = {
    "account_read_at": "2026-08-22T09:14:00Z",
    "account_observation_status": "observed",
    "equity": 100000.0, "balance": 120000.0, "currency": "THB",
    "equity_quality": "usable", "balance_quality": "usable", "failure_reason": None,
}


def v2_envelope(account=None, captured_at="2026-08-22T09:14:00Z"):
    env = base.good_envelope()
    env = dict(env)
    env["envelope_format"] = s1_rows.ENVELOPE_FORMAT_V2
    # v2 and the S1.1 connector namespace are ONE decision (see s1_rows.connector_namespace_error).
    env["connector_version"] = s1_snapshot.CONNECTOR_VERSION_S11_DEFAULT
    env["captured_at"] = captured_at
    env["account"] = dict(account or GOOD_ACCOUNT)
    return env


def write_args(env, *, s11=True, tmp=None):
    path = os.path.join(tmp, "env.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(env, fh)
    return Namespace(
        envelope=path, envelope_sha256=s1_rows.envelope_sha256(env),
        max_envelope_age_seconds=10 ** 9, user_id=None, source_account=None,
        with_account_facts=s11, write=True, confirm=s1_snapshot.CONFIRM_WRITE)


def run_write(env, script, *, s11=True, now=None):
    with tempfile.TemporaryDirectory() as tmp:
        args = write_args(env, s11=s11, tmp=tmp)
        cli = FakeClient(script)
        os.environ.setdefault("SUPABASE_URL", "http://disposable.invalid")
        os.environ.setdefault("SUPABASE_SERVICE_KEY", "k")
        buf, ebuf = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(ebuf):
            try:
                rc = s1_snapshot.run_write(args, now=now or base.NOW,
                                           client_factory=lambda: cli)
            except SystemExit as e:
                rc = e.code
        return rc, buf.getvalue() + ebuf.getvalue(), cli


# ==============================================================================================
# B1-B6  normalisation vs the defensive serialiser
# ==============================================================================================
def t_normalisation():
    inf, ninf, nan = float("inf"), float("-inf"), float("nan")

    for label, raw in (("NaN", nan), ("+Infinity", inf), ("-Infinity", ninf)):
        val, q = s1_rows.normalise_equity(raw)
        check(val is None and q == "invalid", f"B: equity {label} -> NULL + invalid")
        val, q = s1_rows.normalise_balance(raw)
        check(val is None and q == "invalid", f"B: balance {label} -> NULL + invalid")

    check(s1_rows.normalise_equity(100.0) == (100.0, "usable"), "equity positive finite -> usable")
    check(s1_rows.normalise_equity(0) == (0.0, "invalid"), "equity zero -> value kept, invalid")
    check(s1_rows.normalise_equity(-5.5) == (-5.5, "invalid"), "equity negative -> value kept, invalid")
    check(s1_rows.normalise_equity(None) == (None, "absent"), "equity missing -> absent")
    check(s1_rows.normalise_balance(-42.0) == (-42.0, "usable"),
          "balance negative FINITE stays usable (a debit balance is real evidence)")
    check(s1_rows.normalise_balance(None) == (None, "absent"), "balance missing -> absent")
    check(s1_rows.normalise_currency("  THB ") == "THB", "currency trimmed")
    check(s1_rows.normalise_currency("   ") is None, "blank currency -> None, never ''")
    check(s1_rows.normalise_currency(None) is None, "missing currency -> None")

    # B1-B4: a non-finite broker value still yields a VALID, canonicalisable v2 envelope
    acct = {"equity": nan, "balance": inf, "currency": "THB"}
    block = s1_rows.build_account_block(acct, account_read_at="2026-08-22T09:14:00Z")
    check(block["account_observation_status"] == "observed",
          "B1-B4: non-finite is a VALUE problem -- status stays observed")
    check(block["failure_reason"] is None,
          "B1-B4: non-finite does NOT set failure_reason (reserved for whole-read failure)")
    check(block["equity"] is None and block["equity_quality"] == "invalid", "B1-B4: equity normalised")
    check(block["balance"] is None and block["balance_quality"] == "invalid", "B1-B4: balance normalised")
    env = v2_envelope(block)
    check(s1_rows.validate_envelope(env) == [], "B1-B4: normalised envelope is structurally valid")
    check(len(s1_rows.envelope_sha256(env)) == 64,
          "B1-B4: canonicalisation SUCCEEDS after normalisation (preview does NOT fail)")


def t_serializer_backstop():
    """B5-B6: the ONLY way a non-finite reaches the serialiser is an implementation bug. It must
    then refuse -- allow_nan=False is a backstop, never the normal classifier."""
    for label, raw in (("NaN", float("nan")), ("Infinity", float("inf"))):
        env = v2_envelope()
        env["account"]["equity"] = raw                    # deliberately UNNORMALISED
        try:
            s1_rows.canonical_envelope_bytes(env)
            check(False, f"B5-B6: serialiser must REFUSE unnormalised {label}")
        except ValueError:
            check(True, f"B5-B6: serialiser REFUSES unnormalised {label} (allow_nan=False)")


# ==============================================================================================
# capture ordering, identity drift, failed second read
# ==============================================================================================
def t_capture_two_reads():
    m = TwoReadMT5(second=FakeAccount2(), positions=(base.pos(), base.pos(ticket=308292939)))
    env, _missing, _meta, facts = base.capture(m, with_account_facts=True)
    check(m.calls.count("account_info") == 2, "capture: exactly two account_info reads")
    idx_pos = m.calls.index("positions_get")
    check(m.calls.index("account_info") < idx_pos, "capture: identity read is BEFORE positions_get")
    check(len(m.calls) - 1 - m.calls[::-1].index("account_info") > idx_pos,
          "capture: financial read is AFTER positions_get (T1.5)")
    check(env["envelope_format"] == s1_rows.ENVELOPE_FORMAT_V2, "capture: emits envelope v2")
    check(env["account"]["account_observation_status"] == "observed", "capture: observed block")
    check(env["account"]["equity_quality"] == "usable", "capture: usable equity")
    check(facts.get("account_block") is not None, "capture: block surfaced for the preview printer")
    check(s1_rows.validate_envelope(env) == [], "capture: v2 envelope validates")


def t_capture_v1_unchanged():
    m = TwoReadMT5(second=FakeAccount2(), positions=(base.pos(), base.pos(ticket=308292939)))
    env, _m2, _meta, facts = base.capture(m)                       # no with_account_facts
    check(env["envelope_format"] == s1_rows.ENVELOPE_FORMAT_V1, "v1 default: format unchanged")
    check("account" not in env, "v1 default: no account key")
    check(m.calls.count("account_info") == 1, "v1 default: only ONE account_info read")
    check(facts.get("account_block") is None, "v1 default: no account block")


def t_identity_drift_hard_stops():
    m = TwoReadMT5(second=FakeAccount2(login=999999999), positions=(base.pos(), base.pos(ticket=308292939)))
    try:
        base.capture(m, with_account_facts=True)
        check(False, "drift: must raise BrokerReadFailure")
    except s1_snapshot.BrokerReadFailure as e:
        msg = str(e)
        check("ACCOUNT_IDENTITY_DRIFT" in msg, "drift: names ACCOUNT_IDENTITY_DRIFT")
        check("HARD STOP" in msg, "drift: hard stop, nothing written")
        check("30" not in msg.split("HARD STOP")[0][-4:], "drift: not confused with the window")


def t_failed_second_read_is_not_drift():
    for second in (base.NO_ACCOUNT, "raise"):
        m = TwoReadMT5(second=None if second is base.NO_ACCOUNT else second,
                       positions=(base.pos(), base.pos(ticket=308292939)))
        env, _mi, _me, _f = base.capture(m, with_account_facts=True)
        b = env["account"]
        check(b["account_observation_status"] == "failed", "failed read: status failed")
        check(b["failure_reason"] == "ACCOUNT_READ_FAILED", "failed read: the one v1 reason code")
        check(b["equity"] is None and b["balance"] is None and b["currency"] is None,
              "failed read: no financial value")
        check(b["equity_quality"] == "absent" and b["balance_quality"] == "absent",
              "failed read: both qualities absent")
        check(len(env["rows"]) == 2, "failed read: MEMBERSHIP STILL CAPTURED (not a hard stop)")
        check(s1_rows.validate_envelope(env) == [], "failed read: envelope still valid")


# ==============================================================================================
# account block validation -- the three-valued-logic shape, mirrored client-side
# ==============================================================================================
def t_account_block_validation():
    ok = dict(GOOD_ACCOUNT)
    check(s1_rows.validate_account_block(ok, "2026-08-22T09:14:00Z") == [], "block: good passes")

    bad = dict(GOOD_ACCOUNT); bad["account_observation_status"] = "failed"
    bad.update(equity=None, balance=None, currency=None,
               equity_quality="absent", balance_quality="absent", failure_reason=None)
    errs = s1_rows.validate_account_block(bad)
    check(any("failure_reason" in e for e in errs),
          "A1 (client mirror): failed + NULL reason is REJECTED")

    bad2 = dict(bad); bad2["failure_reason"] = "ACCOUNT_READ_FAILED"
    check(s1_rows.validate_account_block(bad2) == [], "A2 (client mirror): failed + reason accepted")

    bad3 = dict(GOOD_ACCOUNT); bad3["failure_reason"] = "ACCOUNT_READ_FAILED"
    check(s1_rows.validate_account_block(bad3) != [], "A3: observed + reason REJECTED")

    bad4 = dict(GOOD_ACCOUNT); bad4["equity"] = 0.0
    check(s1_rows.validate_account_block(bad4) != [], "usable + zero equity REJECTED")
    bad5 = dict(GOOD_ACCOUNT); bad5["equity_quality"] = "absent"
    check(s1_rows.validate_account_block(bad5) != [], "absent + non-null equity REJECTED")
    bad6 = dict(GOOD_ACCOUNT); bad6.pop("currency")
    check(s1_rows.validate_account_block(bad6) != [], "missing key REJECTED")
    bad7 = dict(GOOD_ACCOUNT); bad7["extra"] = 1
    check(s1_rows.validate_account_block(bad7) != [], "extra key REJECTED")

    # contemporaneity: fixed 30 s, both directions
    late = dict(GOOD_ACCOUNT); late["account_read_at"] = "2026-08-22T09:14:01Z"
    check(any("AFTER" in e for e in s1_rows.validate_account_block(late, "2026-08-22T09:14:00Z")),
          "C2 (client mirror): account_read_at AFTER captured_at REJECTED")
    old = dict(GOOD_ACCOUNT); old["account_read_at"] = "2026-08-22T09:13:00Z"
    check(any("recapture" in e for e in s1_rows.validate_account_block(old, "2026-08-22T09:14:00Z")),
          "C1 (client mirror): 60s gap REJECTED, advice is RECAPTURE not widen")
    edge = dict(GOOD_ACCOUNT); edge["account_read_at"] = "2026-08-22T09:13:30Z"
    check(s1_rows.validate_account_block(edge, "2026-08-22T09:14:00Z") == [],
          "exactly 30s is inside the fixed bound")
    check(s1_rows.ACCOUNT_WINDOW_SECONDS == 30, "the bound is the frozen constant 30")


# ==============================================================================================
# E1-E3  envelope format gate + canonical SHA sensitivity
# ==============================================================================================
def t_format_gate():
    v1 = base.good_envelope()
    rc, out, cli = run_write(v1, {}, s11=True)
    check(rc == 2 and "ENVELOPE_FORMAT_NOT_S1_1" in out,
          "E1: v1 envelope REFUSED by the S1.1 write path")
    check(cli.calls == [], "E1: refused before ANY database call")

    v2 = v2_envelope()
    rc, out, cli = run_write(v2, {}, s11=False)
    check(rc == 2 and "ENVELOPE_FORMAT_NOT_S1" in out,
          "E2: v2 envelope REFUSED by the S1-only write path")
    check(cli.calls == [], "E2: refused before ANY database call")
    check("silently discard" in out, "E2: says why -- approved account facts would be lost")


def t_sha_covers_account_block():
    base_env = v2_envelope()
    h0 = s1_rows.envelope_sha256(base_env)
    for key, val in (("equity", 999.0), ("balance", 1.0), ("currency", "USD"),
                     ("equity_quality", "invalid"), ("balance_quality", "invalid"),
                     ("account_observation_status", "failed"),
                     ("account_read_at", "2026-08-22T09:13:59Z"),
                     ("failure_reason", "ACCOUNT_READ_FAILED")):
        env = v2_envelope()
        env["account"][key] = val
        check(s1_rows.envelope_sha256(env) != h0, f"E3: SHA changes when account.{key} changes")

    # reformatting must NOT change it (canonical write payload, not raw bytes)
    reordered = {k: base_env[k] for k in reversed(list(base_env.keys()))}
    reordered["account"] = {k: base_env["account"][k]
                            for k in reversed(list(base_env["account"].keys()))}
    check(s1_rows.envelope_sha256(reordered) == h0,
          "E3: key reordering does NOT change the canonical SHA")
    check(s1_rows.ENVELOPE_KEYS_V2 == s1_rows.ENVELOPE_KEYS + ("account",),
          "v2 is exactly v1 + account")


# ==============================================================================================
# D1-D8  the account-append state machine
# ==============================================================================================
def t_d6_failed_read_completes():
    """D6: a failed broker account read still completes and reconciles the position snapshot."""
    failed = s1_rows.build_account_block(None, account_read_at="2026-08-22T09:14:00Z")
    env = v2_envelope(failed)
    rc, out, cli = run_write(env, {})
    check(rc == 0, "D6: exit 0 with a failed account observation")
    check(cli.calls == ["create", "append", "account", "complete", "reconcile"],
          f"D6: full cycle in order, got {cli.calls}")
    check("status=failed" in out, "D6: reports the degraded account status")


def t_d1_conflict_terminalises():
    """D1: deterministic ERR_ACCOUNT_CONFLICT -> no complete; APPEND_FAILED cleanup attempted;
    the ORIGINAL error stays primary."""
    env = v2_envelope()
    rc, out, cli = run_write(env, {"account": {"o_ok": False,
                                               "o_error_code": "ERR_ACCOUNT_CONFLICT"}})
    check(rc == 7, "D1: exit 7")
    check("complete" not in cli.calls, "D1: complete_snapshot NEVER called")
    check("reconcile" not in cli.calls, "D1: reconcile NEVER called")
    check("mark_failed" in cli.calls, "D1: mark_snapshot_failed ATTEMPTED")
    check(getattr(cli, "last_reason", None) == "APPEND_FAILED", "D1: reason is APPEND_FAILED")
    check("ORIGINAL FAILURE" in out and "ERR_ACCOUNT_CONFLICT" in out,
          "D1: original error reported as primary")
    check("not a broker value problem" in out, "D1: distinguished from bad equity")
    check("NOT overwritten" in out, "D1: says the existing row was not overwritten")


def t_d2_payload_rejection_terminalises():
    env = v2_envelope()
    rc, out, cli = run_write(env, {"account": {"o_ok": False,
                                               "o_error_code": "ERR_ACCOUNT_PAYLOAD_INVALID"}})
    check(rc == 7, "D2: exit 7")
    check("complete" not in cli.calls, "D2: no complete")
    check("mark_failed" in cli.calls and cli.last_reason == "APPEND_FAILED",
          "D2: same APPEND_FAILED terminalisation")


def t_d3_cleanup_failure_keeps_original_primary():
    env = v2_envelope()
    rc, out, cli = run_write(env, {"account": {"o_ok": False, "o_error_code": "ERR_ACCOUNT_CONFLICT"},
                                   "mark_failed": {"o_ok": False, "o_error_code": "ERR_LEASE_EXPIRED"}})
    check(rc == 7, "D3: exit 7")
    check("cleanup FAILED" in out, "D3: cleanup failure reported SEPARATELY")
    check("the ORIGINAL failure above is still ERR_ACCOUNT_CONFLICT" in out,
          "D3: cleanup failure never replaces the original error")
    check("complete" not in cli.calls and "reconcile" not in cli.calls,
          "D3: still no complete / reconcile")


def t_d5_transport_unknown_stops_closed():
    env = v2_envelope()
    rc, out, cli = run_write(env, {"account": s1_client.S1ClientError("connection reset")})
    check(rc == 5, "D5: exit 5")
    check("ACCOUNT_APPEND_RESULT_UNKNOWN" in out, "D5: emits ACCOUNT_APPEND_RESULT_UNKNOWN")
    check("complete" not in cli.calls, "D5: NO complete_snapshot")
    check("mark_failed" not in cli.calls, "D5: NO automatic terminalisation")
    check("reconcile" not in cli.calls, "D5: NO reconcile")
    check("--resume-account-append" in out, "D5: points at the operator-gated resume")
    check("may or may not have landed" in out, "D5: states the outcome is genuinely unknown")


def t_d8_write_path_never_touches_mt5():
    """D8: the armed write must not import or call MetaTrader5, even in S1.1 mode."""
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "s1_snapshot.py"),
               encoding="utf-8").read()
    body = src.split("def run_write", 1)[1].split("\ndef ", 1)[0]
    for tok in ("MetaTrader5", "_mt5_connect", "positions_get", "account_info", "symbol_info",
                "terminal_info", "capture_observation"):
        check(tok not in body, f"D8: run_write body has no {tok!r}")
    rbody = src.split("def run_resume_account_append", 1)[1].split("\ndef ", 1)[0]
    for tok in ("MetaTrader5", "_mt5_connect", "positions_get", "account_info", "symbol_info"):
        check(tok not in rbody, f"D8: resume body has no {tok!r}")


def t_resume_contract():
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "s1_snapshot.py"),
               encoding="utf-8").read()
    rbody = src.split("def run_resume_account_append", 1)[1].split("\ndef ", 1)[0]
    for tok in ("create_run", "complete_snapshot", "reconcile_snapshot", "expire_stale_run"):
        check(f"client.{tok}(" not in rbody, f"resume: never calls {tok}")
    check("append_run_account" in rbody, "resume: calls exactly the account append")
    check("fact-complete, not identity-only" in rbody,
          "resume: documents why it differs from the rejected sealed resume")

    # MEDIUM 4: there must be exactly ONE classification path. The resume body must NOT carry its
    # own per-code ladder -- it delegates every RETURNED refusal to the shared handler, so the two
    # paths cannot drift apart again.
    check("handle_account_refusal(" in rbody,
          "resume: delegates every returned refusal to the SHARED classifier")
    for tok in ("ERR_ACCOUNT_CONFLICT", "ERR_LEASE_EXPIRED", "ERR_RUN_SEALED"):
        check(f'code == "{tok}"' not in rbody and f'code in ("{tok}"' not in rbody,
              f"resume: no private branch for {tok} (it belongs to the shared classifier)")
    # ...and a transport exception is still handled locally, because an UNKNOWN outcome must never
    # reach a classifier that terminalises.
    check("ACCOUNT_APPEND_RESULT_UNKNOWN" in rbody,
          "resume: class C (transport unknown) is still handled locally, never terminalised")

    hbody = src.split("def handle_account_refusal", 1)[1].split("\ndef ", 1)[0]
    check("ACCOUNT_APPEND_LEASE_EXPIRED_REVIEW_REQUIRED" in src,
          "shared handler: names the lease-refusal review status")
    check("SEALED_RUN_REVIEW_REQUIRED" in hbody, "shared handler: sealed run still fails closed")
    check("do NOT backfill" in hbody, "shared handler: forbids backfilling a sealed-run anomaly")
    # Precedence is structural: the ORIGINAL failure line is emitted AFTER the cleanup attempt.
    check(hbody.index("_attempt_append_failed_cleanup") < hbody.rindex("ORIGINAL FAILURE"),
          "shared handler: ORIGINAL failure is reported LAST, so cleanup can never mask it")


def t_connector_namespace_and_reason():
    check(s1_snapshot.CONNECTOR_VERSION_S11_DEFAULT.startswith("s1.1-oneshot/"),
          "S1.1 connector namespace matches the invariant's LIKE pattern")
    check(s1_snapshot.STAGE_FAILED_REASON[s1_snapshot.STAGE_ACCOUNT] == "APPEND_FAILED",
          "account stage reuses APPEND_FAILED, no new terminal vocabulary")
    check(s1_rows.ACCOUNT_READ_FAILED == "ACCOUNT_READ_FAILED", "the one v1 failure_reason")
    check(set(s1_rows.ACCOUNT_KEYS) == {
        "account_read_at", "account_observation_status", "equity", "balance", "currency",
        "equity_quality", "balance_quality", "failure_reason"}, "exact 8-key p_facts set")
    check("mt5_append_run_account_v1" in s1_client.ALLOWED_RPCS, "client allowlists the S1.1 RPC")
    check("mt5_get_current_snapshot_v1" not in s1_client.ALLOWED_RPCS,
          "browser read RPC still unreachable")


def run_resume(env, script):
    with tempfile.TemporaryDirectory() as tmp:
        args = write_args(env, s11=True, tmp=tmp)
        args.resume_account_append = True
        cli = FakeClient(script)
        buf, ebuf = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(ebuf):
            try:
                rc = s1_snapshot.run_resume_account_append(args, client_factory=lambda: cli)
            except SystemExit as e:
                rc = e.code
        return rc, buf.getvalue() + ebuf.getvalue(), cli


def t_d4_resume_behaviour():
    """D4: transport lost the ACK but the row DID commit -> the operator-gated resume replays the
    same envelope, the full-fingerprint comparison proves it, and the cycle may continue."""
    env = v2_envelope()

    rc, out, cli = run_resume(env, {"account": {"o_ok": True, "o_inserted": 0,
                                                "o_error_code": None}})
    check(rc == 0, "D4: resume exit 0 when the row already existed")
    check(cli.calls == ["account"], f"D4: EXACTLY ONE RPC, got {cli.calls}")
    check("FACT-IDENTICAL" in out, "D4: reports a full-fingerprint match")
    check("SAFE TO CONTINUE" in out, "D4: tells the operator the cycle may continue")
    check("STOP here until a human decides" in out, "D4: still stops; never continues by itself")

    rc, out, cli = run_resume(env, {"account": {"o_ok": True, "o_inserted": 1,
                                                "o_error_code": None}})
    check(rc == 0 and "did NOT exist" in out, "D4b: resume writes the row if it never landed")
    check(cli.calls == ["account"], "D4b: still exactly one RPC")

    # a changed fact must be refused, never overwritten -> class B
    rc, out, cli = run_resume(env, {"account": {"o_ok": False,
                                                "o_error_code": "ERR_ACCOUNT_CONFLICT"}})
    check(rc == 7, "D4c: conflicting resume exits 7")
    check("NOT overwritten" in out, "D4c: says the existing row was not overwritten")
    check("mark_failed" in cli.calls and cli.last_reason == "APPEND_FAILED",
          "D4c: falls through to class-B APPEND_FAILED terminalisation")

    # expired lease -> a DETERMINISTIC refusal (the server decided; the outcome is known), so it
    # takes the class-B cleanup ATTEMPT. The frozen S1 failure RPC will usually refuse it for the
    # same reason -- reported as a SECONDARY cleanup failure that never replaces the original.
    rc, out, cli = run_resume(env, {"account": {"o_ok": False,
                                               "o_error_code": "ERR_LEASE_EXPIRED"},
                                    "mark_failed": {"o_ok": False,
                                                    "o_error_code": "ERR_LEASE_EXPIRED"}})
    check(rc == 8, "D4d: expired lease exits 8 (authority lost, distinct from an integrity refusal)")
    check("ACCOUNT_APPEND_LEASE_EXPIRED_REVIEW_REQUIRED" in out, "D4d: names the review status")
    check("mark_failed" in cli.calls, "D4d: cleanup IS attempted (deterministic, not unknown)")
    check(cli.last_reason == "APPEND_FAILED", "D4d: cleanup uses the APPEND_FAILED reason")
    check("cleanup FAILED" in out, "D4d: the refused cleanup is reported SEPARATELY")
    check(out.rindex("ORIGINAL FAILURE") > out.index("cleanup FAILED"),
          "D4d: the ORIGINAL refusal stays PRIMARY, printed after the cleanup outcome")
    check("do NOT auto-expire" in out or "NOT auto-expire" in out,
          "D4d: never converts a lease refusal into an auto-expire")

    # sealed run -> fail closed, no further RPC
    rc, out, cli = run_resume(env, {"account": {"o_ok": False, "o_error_code": "ERR_RUN_SEALED"}})
    check(rc == 10, "D4e: sealed run exits 10")
    check("SEALED_RUN_REVIEW_REQUIRED" in out, "D4e: fails closed exactly as S1 does")
    check(cli.calls == ["account"], "D4e: no further RPC after the seal refusal")
    check("do NOT backfill" in out, "D4e: forbids backfilling the anomaly")

    # still-unknown transport -> STOP, nothing terminalised
    rc, out, cli = run_resume(env, {"account": s1_client.S1ClientError("reset again")})
    check(rc == 5, "D4f: still-unknown exits 5")
    check("ACCOUNT_APPEND_RESULT_UNKNOWN" in out, "D4f: still unknown")
    check("mark_failed" not in cli.calls, "D4f: NO terminalisation while the outcome is unknown")

    # a v1 envelope can never be resumed as S1.1
    rc, out, cli = run_resume(base.good_envelope(), {})
    check(rc == 2 and "ENVELOPE_FORMAT_NOT_S1_1" in out, "D4g: resume refuses a v1 envelope")
    check(cli.calls == [], "D4g: refused before any RPC")


# =============================================================================================
# HIGH 1 -- mode-resolved connector namespace, through the REAL parser and the REAL preview path.
# =============================================================================================
def run_cli_preview(argv_extra, *, second=None):
    """Drive parse_args() -> run_preview() for real. Only the MT5 terminal is faked.

    Returns (rc, output, envelope_or_None). The envelope is read back from disk, so what is
    asserted is what the real path actually SEALED -- never a constant.
    """
    # run_preview REFUSES a git-trackable envelope path, so this must use the real ignored
    # out/ directory rather than a system temp dir. That guard is part of the contract under test.
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    rel = common.SAFE_OUT_PREFIX + "cli_test_env.json"
    cwd = os.getcwd()
    os.chdir(repo)
    try:
        os.makedirs(common.SAFE_OUT_PREFIX, exist_ok=True)
        if os.path.exists(rel):
            os.remove(rel)
        argv = ["--user-id", UID, "--source-account", ACCT, "--envelope", rel] + list(argv_extra)
        args = s1_snapshot.parse_args(argv)
        mt5 = TwoReadMT5(second=second if second is not None else FakeAccount2(),
                         positions=(base.pos(), base.pos(ticket=308292939)))
        old = s1_snapshot._mt5_connect
        s1_snapshot._mt5_connect = lambda: mt5
        buf, ebuf = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(ebuf):
                try:
                    rc = s1_snapshot.run_preview(args)
                except SystemExit as e:
                    rc = e.code
        finally:
            s1_snapshot._mt5_connect = old
        env = None
        if os.path.exists(rel):
            with open(rel, encoding="utf-8") as fh:
                env = json.load(fh)
            os.remove(rel)                      # leave no artefact behind
        return rc, buf.getvalue() + ebuf.getvalue(), env
    finally:
        os.chdir(cwd)


def t_cli_mode_resolution():
    """A/B/C/D/E of review section 5, against the real CLI -- not against constants."""
    # (A) default CLI: S1-only namespace, envelope v1.
    rc, out, env = run_cli_preview([])
    check(rc == 0, f"CLI-A: default preview succeeds (rc={rc})")
    check(env is not None and env["connector_version"] == "s1-oneshot/0.1",
          f"CLI-A: resolved connector is s1-oneshot/0.1, got "
          f"{env and env.get('connector_version')!r}")
    check(env["envelope_format"] == s1_rows.ENVELOPE_FORMAT_V1, "CLI-A: envelope v1")
    check("account" not in env, "CLI-A: no account block on a v1 capture")

    # (B) --with-account-facts: S1.1 namespace, envelope v2. THE defect Codex found.
    rc, out, env = run_cli_preview(["--with-account-facts"])
    check(rc == 0, f"CLI-B: S1.1 preview succeeds (rc={rc})")
    check(env is not None and env["connector_version"] == "s1.1-oneshot/0.1",
          f"CLI-B: resolved connector is s1.1-oneshot/0.1, got "
          f"{env and env.get('connector_version')!r}")
    check(env["envelope_format"] == s1_rows.ENVELOPE_FORMAT_V2, "CLI-B: envelope v2")
    check("account" in env, "CLI-B: the account block is present")

    # (E) and that resolved value is the one V13/V14 key off. Asserted from the SEALED envelope.
    check(s1_rows.is_s11_connector(env["connector_version"]),
          "CLI-E: the sealed v2 connector is in the S1.1 namespace V13 inspects")
    check(env["connector_version"].startswith("s1.1-oneshot/"),
          "CLI-E: matches the SQL predicate `connector_version like 's1.1-oneshot/%'` literally")

    # (C) S1.1 mode + an explicit S1 connector -> refuse, before the terminal is even opened.
    rc, out, env = run_cli_preview(["--with-account-facts",
                                    "--connector-version", "s1-oneshot/0.1"])
    check(rc == 2, f"CLI-C: refused (rc={rc})")
    check("CONNECTOR_VERSION_NOT_S1_1" in out, "CLI-C: stable code CONNECTOR_VERSION_NOT_S1_1")
    check(env is None, "CLI-C: NO envelope was written")

    # (D) the inverse. An S1.1 connector on an S1-only capture would be a permanent V13 anomaly.
    rc, out, env = run_cli_preview(["--connector-version", "s1.1-oneshot/0.1"])
    check(rc == 2, f"CLI-D: refused (rc={rc})")
    check("CONNECTOR_VERSION_NOT_S1" in out and "CONNECTOR_VERSION_NOT_S1_1" not in out,
          "CLI-D: stable code CONNECTOR_VERSION_NOT_S1")
    check(env is None, "CLI-D: NO envelope was written")

    # An unrelated namespace belongs to no reviewed mode, in either direction.
    for extra, code in ((["--with-account-facts"], "CONNECTOR_VERSION_NOT_S1_1"),
                        ([], "CONNECTOR_VERSION_NOT_S1")):
        rc, out, env = run_cli_preview(extra + ["--connector-version", "vendor-x/9"])
        check(rc == 2 and code in out and env is None,
              f"CLI: an unrelated namespace is refused with {code}")

    # Explicitly supplied and CORRECT -> honoured verbatim, never rewritten to the default.
    rc, out, env = run_cli_preview(["--with-account-facts",
                                    "--connector-version", "s1.1-oneshot/0.9-canary"])
    check(rc == 0 and env["connector_version"] == "s1.1-oneshot/0.9-canary",
          "CLI: a valid explicit connector version is honoured verbatim")


def t_cli_refuses_before_any_side_effect():
    """The namespace refusal must cost nothing: no terminal, no credential, no transport."""
    args = s1_snapshot.parse_args(["--user-id", UID, "--source-account", ACCT,
                                   "--with-account-facts",
                                   "--connector-version", "s1-oneshot/0.1"])

    def boom():
        raise AssertionError("run_preview opened the MT5 terminal despite a namespace refusal")

    old = s1_snapshot._mt5_connect
    s1_snapshot._mt5_connect = boom
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            try:
                rc = s1_snapshot.run_preview(args)
            except SystemExit as e:
                rc = e.code
    finally:
        s1_snapshot._mt5_connect = old
    check(rc == 2, "CLI: refuses with exit 2")
    check("CONNECTOR_VERSION_NOT_S1_1" in buf.getvalue(), "CLI: names the stable code")

    # ...and structurally: resolution precedes the connect call in run_preview's source.
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "s1_snapshot.py"),
               encoding="utf-8").read()
    body = src.split("def run_preview", 1)[1].split("\ndef ", 1)[0]
    check(body.index("resolve_connector_version") < body.index("_mt5_connect"),
          "CLI: the mode is resolved BEFORE the terminal/transport is constructed")


def t_resolver_unit():
    check(s1_snapshot.resolve_connector_version(None, with_account_facts=False)
          == "s1-oneshot/0.1", "resolver: S1-only default")
    check(s1_snapshot.resolve_connector_version(None, with_account_facts=True)
          == "s1.1-oneshot/0.1", "resolver: S1.1 default")
    check(s1_snapshot.resolve_connector_version("  ", with_account_facts=True)
          == "s1.1-oneshot/0.1", "resolver: a blank value falls back to the mode default")
    check(s1_snapshot.resolve_connector_version(" s1.1-oneshot/0.2 ", with_account_facts=True)
          == "s1.1-oneshot/0.2", "resolver: an explicit value is trimmed, not rewritten")
    check(s1_snapshot.CONNECTOR_VERSION_S1_DEFAULT != s1_snapshot.CONNECTOR_VERSION_S11_DEFAULT,
          "resolver: the two mode defaults are genuinely different values")
    # argparse must NOT carry a default that could apply to the wrong mode.
    ns = s1_snapshot.parse_args(["--user-id", UID, "--source-account", ACCT])
    check(ns.connector_version is None,
          "argparse: --connector-version defaults to None so the MODE chooses")


def t_namespace_contract():
    """s1_rows is the ONE definition, and it is bound to the envelope format."""
    check(s1_rows.CONNECTOR_NAMESPACE_S11 == "s1.1-oneshot/", "namespace: S1.1 prefix literal")
    check(s1_rows.CONNECTOR_NAMESPACE_S1 == "s1-oneshot/", "namespace: S1 prefix literal")
    # Disjoint: 's1.1-' must never satisfy the 's1-' test, or every classification is ambiguous.
    check(not s1_rows.is_s1_connector("s1.1-oneshot/0.1"),
          "namespace: an S1.1 value is NOT an S1 value")
    check(not s1_rows.is_s11_connector("s1-oneshot/0.1"),
          "namespace: an S1 value is NOT an S1.1 value")
    for bad in (None, 42, "", "oneshot/1", "S1.1-ONESHOT/0.1"):
        check(not s1_rows.is_s1_connector(bad) and not s1_rows.is_s11_connector(bad),
              f"namespace: {bad!r} belongs to no reviewed mode (matching is exact, not fuzzy)")

    # structural binding: a mismatched pair cannot survive validate_envelope
    env = v2_envelope()
    env["connector_version"] = "s1-oneshot/0.1"
    errs = s1_rows.validate_envelope(env)
    check(any("CONNECTOR_VERSION_NOT_S1_1" in e for e in errs),
          "binding: a v2 envelope with an S1 connector is structurally INVALID")
    v1 = base.good_envelope()
    v1["connector_version"] = "s1.1-oneshot/0.1"
    errs = s1_rows.validate_envelope(v1)
    check(any("CONNECTOR_VERSION_NOT_S1" in e for e in errs),
          "binding: a v1 envelope with an S1.1 connector is structurally INVALID")
    check(s1_rows.validate_envelope(v2_envelope()) == [], "binding: a correct v2 pair validates")
    check(s1_rows.validate_envelope(base.good_envelope()) == [],
          "binding: a correct v1 pair validates")

    # the write and resume paths both refuse it before any DB call
    bad = v2_envelope()
    bad["connector_version"] = "s1-oneshot/0.1"
    rc, out, cli = run_write(bad, {}, s11=True)
    check(rc != 0 and cli.calls == [],
          "binding: the armed write refuses a mismatched envelope before any RPC")
    rc, out, cli = run_resume(bad, {})
    check(rc == 2 and cli.calls == [],
          "binding: the resume refuses a mismatched envelope before any RPC")


# =============================================================================================
# MEDIUM 3 -- the generated armed command must run under the mode that produced the envelope.
# =============================================================================================
def join_shell_command(out):
    """Reassemble the multi-line `python ... \\` block the preview prints, and return its argv
    (everything after the script path)."""
    lines = out.splitlines()
    start = next(i for i, l in enumerate(lines) if "s1_snapshot.py" in l and "--write" in l)
    parts = []
    i = start
    while True:
        raw = lines[i].strip()
        cont = raw.endswith("\\")
        parts.append(raw[:-1].strip() if cont else raw)
        if not cont:
            break
        i += 1
    joined = " ".join(parts)
    return joined.split("s1_snapshot.py", 1)[1].split()


def t_generated_armed_command():
    rc, out, env = run_cli_preview([])
    check(rc == 0, "cmd: v1 preview ok")
    line = [l for l in out.splitlines() if "s1_snapshot.py" in l and "--write" in l]
    check(len(line) == 1, f"cmd: exactly one generated v1 command, got {len(line)}")
    check("--with-account-facts" not in line[0],
          "cmd: the v1 command does NOT carry --with-account-facts (the S1.1 path rejects v1)")
    check("--write" in line[0] and s1_snapshot.CONFIRM_WRITE in line[0],
          "cmd: the v1 command still carries --write --confirm")

    rc, out, env = run_cli_preview(["--with-account-facts"])
    check(rc == 0, "cmd: v2 preview ok")
    line = [l for l in out.splitlines() if "s1_snapshot.py" in l and "--write" in l]
    check(len(line) == 1, f"cmd: exactly one generated v2 command, got {len(line)}")
    check("--with-account-facts" in line[0],
          "cmd: the v2 command CARRIES --with-account-facts (MEDIUM 3)")
    check(line[0].index("--with-account-facts") < line[0].index("--write"),
          "cmd: the mode flag precedes --write, as the reviewed example shows")

    # and the preview REPORTS the resolved namespace, so an operator can see the mode.
    check("s1.1-oneshot/0.1" in out and "S1.1 (--with-account-facts)" in out,
          "cmd: the v2 preview reports the resolved connector and its mode")

    # END-TO-END: reassemble the WHOLE displayed command across its shell continuations and parse
    # THAT. A command whose first line is right but whose continuations are not is still unusable.
    argv = s1_snapshot.parse_args(join_shell_command(out))
    parsed = argv
    check(parsed.with_account_facts is True and parsed.write is True,
          "cmd: the generated v2 command parses back into an armed S1.1 write")
    check(parsed.envelope_sha256 == s1_rows.envelope_sha256(env),
          "cmd: the generated command's hash binds THIS envelope")


# =============================================================================================
# MEDIUM 4 -- one classifier, both paths, every deterministic code.
# =============================================================================================
DETERMINISTIC_CODES = (
    "ERR_ACCOUNT_PAYLOAD_KEYS", "ERR_ACCOUNT_PAYLOAD_INVALID", "ERR_ACCOUNT_READ_AT_WINDOW",
    "ERR_RUN_CONFLICT", "ERR_RUN_NOT_FOUND", "ERR_RUN_FAILED", "ERR_NOT_STARTED",
    "ERR_LEASE_MISMATCH", "ERR_LEASE_EXPIRED", "ERR_ACCOUNT_CONFLICT", "ERR_BAD_INPUT",
    "ERR_CAPTURE_TIME_INVALID", "ERR_CONNECTOR_VERSION_INVALID", "ERR_CONNECTOR_NOT_S1_1",
    "ERR_SOMETHING_NOBODY_HAS_SEEN_YET",
)


def t_shared_classifier_covers_every_deterministic_code():
    env = v2_envelope()
    for code in DETERMINISTIC_CODES:
        check(s1_snapshot.classify_account_refusal(code)
              == s1_snapshot.ACCOUNT_REFUSAL_DETERMINISTIC,
              f"classifier: {code} is deterministic")

        # RESUME: every one of them now terminalises. Previously only ERR_ACCOUNT_CONFLICT did.
        rc, out, cli = run_resume(env, {"account": {"o_ok": False, "o_error_code": code}})
        check("mark_failed" in cli.calls,
              f"resume/{code}: class-B cleanup ATTEMPTED (was skipped before MEDIUM 4)")
        check(cli.last_reason == "APPEND_FAILED", f"resume/{code}: reason is APPEND_FAILED")
        check(out.rindex("ORIGINAL FAILURE") > out.index("cleanup"),
              f"resume/{code}: the ORIGINAL refusal stays primary")
        check(f"code={code}" in out, f"resume/{code}: the original code is named")
        check("complete" not in [c for c in cli.calls] and "reconcile" not in cli.calls,
              f"resume/{code}: no complete, no reconcile")
        resume_rc = rc

        # ARMED WRITE: byte-for-byte the same handler, so the two paths cannot drift.
        rc, out, cli = run_write(env, {"account": {"o_ok": False, "o_error_code": code}})
        check("mark_failed" in cli.calls, f"write/{code}: class-B cleanup ATTEMPTED")
        check("complete" not in cli.calls and "reconcile" not in cli.calls,
              f"write/{code}: run NOT sealed and NOT reconciled")
        check(rc == resume_rc, f"write/{code}: same exit code as the resume path ({rc})")

    # SEALED is the ONE exception, in BOTH paths (section 27).
    check(s1_snapshot.classify_account_refusal("ERR_RUN_SEALED")
          == s1_snapshot.ACCOUNT_REFUSAL_SEALED, "classifier: ERR_RUN_SEALED is its own class")
    for runner, label in ((run_resume, "resume"), (run_write, "write")):
        rc, out, cli = runner(env, {"account": {"o_ok": False, "o_error_code": "ERR_RUN_SEALED"}})
        check(rc == 10, f"{label}/sealed: exit 10")
        check("mark_failed" not in cli.calls,
              f"{label}/sealed: NO terminalisation -- a sealed run is never a cleanup opportunity")
        check("SEALED_RUN_REVIEW_REQUIRED" in out and "do NOT backfill" in out,
              f"{label}/sealed: review-required, no backfill")

    # A lease refusal keeps its own exit code, because the operator's next action differs.
    rc, _o, _c = run_resume(env, {"account": {"o_ok": False, "o_error_code": "ERR_LEASE_EXPIRED"}})
    check(rc == s1_snapshot.ACCOUNT_EXIT_LEASE == 8, "classifier: a lease refusal exits 8")
    rc, _o, _c = run_resume(env, {"account": {"o_ok": False,
                                              "o_error_code": "ERR_ACCOUNT_CONFLICT"}})
    check(rc == s1_snapshot.ACCOUNT_EXIT_REFUSED == 7, "classifier: an integrity refusal exits 7")


def t_transport_unknown_never_classified():
    """Class C must never reach the classifier: an UNKNOWN outcome cannot be terminalised."""
    env = v2_envelope()
    for runner, label in ((run_resume, "resume"), (run_write, "write")):
        rc, out, cli = runner(env, {"account": s1_client.S1ClientError("connection reset")})
        check("mark_failed" not in cli.calls,
              f"{label}/transport: NO terminalisation while the outcome is unknown")
        check("complete" not in cli.calls, f"{label}/transport: NO seal")
        check("ACCOUNT_APPEND_RESULT_UNKNOWN" in out, f"{label}/transport: names the unknown state")
        check(rc == 5, f"{label}/transport: exit 5")


ALL = [
    t_normalisation, t_serializer_backstop, t_capture_two_reads, t_capture_v1_unchanged,
    t_identity_drift_hard_stops, t_failed_second_read_is_not_drift, t_account_block_validation,
    t_format_gate, t_sha_covers_account_block, t_d6_failed_read_completes,
    t_d1_conflict_terminalises, t_d2_payload_rejection_terminalises,
    t_d3_cleanup_failure_keeps_original_primary, t_d5_transport_unknown_stops_closed,
    t_d8_write_path_never_touches_mt5, t_resume_contract, t_d4_resume_behaviour,
    t_cli_mode_resolution, t_cli_refuses_before_any_side_effect, t_resolver_unit,
    t_namespace_contract, t_generated_armed_command,
    t_shared_classifier_covers_every_deterministic_code,
    t_transport_unknown_never_classified, t_connector_namespace_and_reason,
]


def main():
    for fn in ALL:
        try:
            fn()
        except Exception as e:
            FAILS.append(f"{fn.__name__} raised {type(e).__name__}: {e}")
    print(f"s1.1 account pure tests: {CHECKS[0]} checks, "
          f"{'PASS' if not FAILS else f'{len(FAILS)} FAIL'}")
    for f in FAILS:
        print("  FAIL:", f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
