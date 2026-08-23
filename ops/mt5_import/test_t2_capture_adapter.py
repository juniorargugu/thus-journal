#!/usr/bin/env python3
"""
MT5 T2 capture-event adapter — pure tests. No MT5, no DB, no network, no clock.

Run with:  python -X utf8 ops/mt5_import/test_t2_capture_adapter.py
"""
from __future__ import annotations

import copy
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:                                     # package mode
    from . import t1_detector as t1
    from . import t2_capture_adapter as ad
    from . import t2_quiet_window as t2
except ImportError:                      # script mode
    import t1_detector as t1                                              # noqa: E402
    import t2_capture_adapter as ad                                       # noqa: E402
    import t2_quiet_window as t2                                          # noqa: E402

CHECKS = [0]
FAILS = []

UID = "b77d0426-1111-4222-8333-444455556666"
ACCT = "301102520"
RUN_A = "3f1a0000-0000-4000-8000-00000000000a"
RUN_B = "3f1a0000-0000-4000-8000-00000000000b"
RUN_C = "3f1a0000-0000-4000-8000-00000000000c"
RUN_D = "3f1a0000-0000-4000-8000-00000000000d"
RUN_E = "3f1a0000-0000-4000-8000-00000000000e"
QW = 300.0
T0 = 1_787_000_000.0                     # epoch seconds, injected


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


def boom(fn):
    try:
        fn()
        return None
    except (ad.T2AdapterError, t2.T2InputError) as e:
        return str(e)


def det(*, at, pid=101, etype=t1.EVENT_POSITION_INCREASE, before=RUN_A, after=RUN_B,
        before_seq=1, after_seq=2, **over):
    d = {"event_type": etype, "position_id": pid,
         "before_run_id": before, "after_run_id": after,
         "before_run_seq": before_seq, "after_run_seq": after_seq,
         "user_id": UID, "source_account": ACCT}
    if etype == t1.EVENT_POSITION_IDENTITY_CONFLICT:
        d.update(before_symbol_raw="DELTAU26", after_symbol_raw="S50U26",
                 before_side="buy", after_side="buy", before_volume=2.0, after_volume=4.0)
    else:
        d.update(symbol_raw="DELTAU26", side="buy")
        if etype in (t1.EVENT_POSITION_INCREASE, t1.EVENT_POSITION_DECREASE):
            d.update(before_volume=2.0,
                     after_volume=4.0 if etype == t1.EVENT_POSITION_INCREASE else 1.0)
        elif etype == t1.EVENT_POSITION_DISAPPEARED:
            d.update(before_volume=2.0)
        else:
            d.update(after_volume=4.0)
    d["detected_at"] = at
    d.update(over)
    return d


def candidate(detections=None, *, window=QW):
    ds = detections if detections is not None else [det(at=T0)]
    cands = t2.coalesce(ds, quiet_window_seconds=window)
    assert len(cands) == 1, f"fixture produced {len(cands)} candidates"
    return cands[0]


def closed_now(c):
    return c["quiet_deadline"] + 1.0


# ---------------------------------------------------------------------------------------------
# determinism / identity
# ---------------------------------------------------------------------------------------------
def t_deterministic_payload():
    c = candidate()
    a = ad.build_capture_payload(c, now=closed_now(c))
    b = ad.build_capture_payload(candidate(), now=closed_now(c))
    check(a == b, "determinism: the same candidate yields an equal payload")
    check(ad.canonical_payload_json(a) == ad.canonical_payload_json(b),
          "determinism: canonical JSON is byte-identical")
    # and it survives a full T2 replay with shuffled input order
    ds = [det(at=T0), det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3,
                          etype=t1.EVENT_POSITION_DECREASE)]
    c1 = candidate(ds)
    c2 = candidate(list(reversed(ds)))
    check(ad.canonical_payload_json(ad.build_capture_payload(c1, now=closed_now(c1)))
          == ad.canonical_payload_json(ad.build_capture_payload(c2, now=closed_now(c2))),
          "determinism: T2 input order does not change the persistence payload")


def t_different_detection_set_differs():
    c1 = candidate([det(at=T0)])
    c2 = candidate([det(at=T0), det(at=T0 + 60, before=RUN_B, after=RUN_C,
                                    before_seq=2, after_seq=3)])
    p1 = ad.build_capture_payload(c1, now=closed_now(c1))
    p2 = ad.build_capture_payload(c2, now=closed_now(c2))
    check(p1["detection_identities"] != p2["detection_identities"],
          "identity: a different contributing detection set is different evidence")
    check(ad.canonical_payload_json(p1) != ad.canonical_payload_json(p2),
          "identity: ...and yields a different payload")


# ---------------------------------------------------------------------------------------------
# provenance preserved
# ---------------------------------------------------------------------------------------------
def t_provenance_preserved():
    ds = [det(at=T0),
          det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3,
              etype=t1.EVENT_POSITION_DISAPPEARED)]
    c = candidate(ds)
    p = ad.build_capture_payload(c, now=closed_now(c))
    check(p["basis_run_id"] == RUN_C, "provenance: basis_run_id is the final after_run_id")
    check([r["before_run_id"] for r in p["run_references"]] == [RUN_A, RUN_B]
          and [r["after_run_id"] for r in p["run_references"]] == [RUN_B, RUN_C],
          "provenance: every before/after run reference is preserved")
    check([r["before_run_seq"] for r in p["run_references"]] == [1, 2]
          and [r["after_run_seq"] for r in p["run_references"]] == [2, 3],
          "provenance: run seqs preserved")
    check(len(p["detection_identities"]) == 2 and len(p["detections"]) == 2,
          "provenance: all contributing identities and detections retained")
    check(p["event_types"] == [t1.EVENT_POSITION_INCREASE, t1.EVENT_POSITION_DISAPPEARED],
          "provenance: contributing event types preserved verbatim")
    check(all(len(i) == 6 for i in p["detection_identities"]),
          "provenance: identities are the frozen 6-field tuples")
    check(p["detector_version"] == ad.DETECTOR_VERSION
          and p["aggregator_version"] == ad.AGGREGATOR_VERSION
          and p["domain"] == ad.CAPTURE_DOMAIN,
          "provenance: producer versions and domain tag recorded")
    check(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z", p["quiet_deadline"]),
          "provenance: instants rendered as ISO-8601 Z")
    check(p["quiet_window_seconds"] == QW, "provenance: the window used is recorded")


def t_no_account_facts_and_no_decision_state():
    c = candidate()
    p = ad.build_capture_payload(c, now=closed_now(c))
    blob = json.dumps(p, sort_keys=True).lower()
    for token in ("equity", "balance", "currency", "margin"):
        check(token not in blob, f"evidence: no {token!r} anywhere in the capture payload")
    for token in ("skipped", "promoted", "ignored", "dismissed", "confirmed",
                  "journal_trade_id"):
        check(token not in blob, f"evidence: no human-decision field {token!r}")
    for token in ("closed", "realized", "realised", "pnl"):
        check(token not in blob, f"evidence: no action/P-L wording {token!r}")
    check("basis_run_id" in p,
          "evidence: machine context is a REFERENCE (basis_run_id), not a copy")
    # the guard actually fires if account facts ever sneak in
    poisoned = copy.deepcopy(c)
    poisoned["detections"][0]["equity"] = 1.0
    check(boom(lambda: ad.build_capture_payload(poisoned, now=closed_now(c))) is not None,
          "evidence: a smuggled equity field is refused")


# ---------------------------------------------------------------------------------------------
# closed-only, refusals, purity
# ---------------------------------------------------------------------------------------------
def t_open_candidate_refused():
    c = candidate()
    check(not ad.is_closed(c, now=c["quiet_deadline"]),
          "closed: exactly AT the deadline is not yet closed")
    check(ad.is_closed(c, now=c["quiet_deadline"] + 0.001), "closed: past the deadline is closed")
    msg = boom(lambda: ad.build_capture_payload(c, now=c["quiet_deadline"]))
    check(msg is not None and "still OPEN" in msg,
          "closed: a not-yet-closed candidate is refused")
    check(boom(lambda: ad.build_capture_payload(c, now=c["first_detection_at"])) is not None,
          "closed: a candidate mid-window is refused")
    check(boom(lambda: ad.is_closed(c, now=None)) is not None,
          "closed: is_closed requires an injected numeric now")


def t_malformed_candidate_refused():
    c = candidate()
    now = closed_now(c)

    def raises(mutate):
        broken = copy.deepcopy(c)
        mutate(broken)
        return boom(lambda: ad.build_capture_payload(broken, now=now))

    check(boom(lambda: ad.build_capture_payload({"user_id": UID}, now=now)) is not None,
          "malformed: wrong field set refused")
    check(raises(lambda b: b.pop("basis_run_id")) is not None,
          "malformed: missing basis_run_id refused")
    check(raises(lambda b: b.update(basis_run_id=RUN_A)) is not None,
          "malformed: basis_run_id that is not the final after_run_id refused")
    check(raises(lambda b: b.update(basis_run_id="   ")) is not None,
          "malformed: blank basis_run_id refused")
    check(raises(lambda b: b.update(position_id="101")) is not None,
          "malformed: string position_id refused")
    check(raises(lambda b: b.update(position_id=True)) is not None,
          "malformed: bool position_id refused")
    check(raises(lambda b: b.update(quiet_window_seconds=0)) is not None,
          "malformed: non-positive window refused")
    check(raises(lambda b: b.update(quiet_deadline=b["last_detection_at"])) is not None,
          "malformed: deadline not after last detection refused")
    check(raises(lambda b: b.update(detection_identities=[])) is not None,
          "malformed: no contributing identities refused")
    check(raises(lambda b: b["detection_identities"].append(b["detection_identities"][0]))
          is not None, "malformed: provenance arity mismatch refused")
    check(raises(lambda b: b["detection_identities"].__setitem__(
        0, (UID, ACCT, t1.EVENT_POSITION_INCREASE, 999, RUN_A, RUN_B))) is not None,
        "malformed: identity for another position refused")
    check(raises(lambda b: b["detection_identities"].__setitem__(
        0, ("someone-else", ACCT, t1.EVENT_POSITION_INCREASE, 101, RUN_A, RUN_B))) is not None,
        "malformed: identity out of scope refused")
    check(raises(lambda b: b["event_types"].__setitem__(0, t1.EVENT_POSITION_DECREASE))
          is not None, "malformed: event_types disagreeing with identities refused")
    check(raises(lambda b: b["run_references"][0].update(before_run_id=RUN_C)) is not None,
          "malformed: run references disagreeing with identities refused")
    check(raises(lambda b: b["run_references"][0].pop("before_run_seq")) is not None,
          "malformed: non-canonical run reference shape refused")
    check(raises(lambda b: b["detections"][0].update(after_volume=1.0)) is not None,
          "malformed: a detection whose direction contradicts its type refused")
    check(raises(lambda b: b["detections"][0].pop("symbol_raw")) is not None,
          "malformed: a detection missing a required T1 fact refused")


def t_inputs_not_mutated():
    c = candidate([det(at=T0), det(at=T0 + 60, before=RUN_B, after=RUN_C,
                                   before_seq=2, after_seq=3)])
    snap = copy.deepcopy(c)
    p = ad.build_capture_payload(c, now=closed_now(c))
    check(c == snap, "purity: the candidate is not mutated")
    p["detections"][0]["symbol_raw"] = "MUTATED"
    p["detection_identities"][0][0] = "MUTATED"
    p["run_references"][0]["before_run_id"] = "MUTATED"
    check(c == snap, "purity: the payload shares no mutable structure with the candidate")


def t_rpc_request_shape():
    c = candidate()
    req = ad.build_rpc_request(c, now=closed_now(c))
    check(set(req) == {"p_user", "p_account", "p_candidate"},
          "rpc: exactly the three RPC arguments")
    check(req["p_user"] == UID and req["p_account"] == ACCT,
          "rpc: explicit trusted-writer scope")
    for server_owned in ("id", "created_at", "event_key", "payload_fingerprint"):
        check(server_owned not in req["p_candidate"],
              f"rpc: the caller does not supply server-owned {server_owned!r}")
    check(set(req["p_candidate"]) == set(ad.PAYLOAD_KEYS),
          "rpc: payload carries exactly the canonical key set")
    # the RPC packet's expected key list must match this payload exactly
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    sql = open(os.path.join(root, "artifacts", "mt5_reconciliation",
                            "T2_capture_events_rpc_packet.sql"), encoding="utf-8").read()
    block = sql.split("v_expect_keys  constant text[] := array[", 1)[1].split("];", 1)[0]
    sql_keys = sorted(re.findall(r"'([a-z_]+)'", block))
    check(sql_keys == sorted(ad.PAYLOAD_KEYS),
          f"rpc: the SQL expected-key list matches the adapter payload exactly "
          f"(sql={sql_keys})")
    check(ad.CAPTURE_DOMAIN in sql, "rpc: the SQL packet pins the same domain tag")


def t_end_to_end_from_real_t1():
    """Real T1 -> real T2 -> adapter, with nothing hand-built."""
    def run_meta(seq, run_id):
        return {"run_id": run_id, "user_id": UID, "source_account": ACCT, "run_seq": seq,
                "snapshot_status": "complete", "snapshot_health": "healthy"}

    def row(run_id, pid, volume):
        return {"run_id": run_id, "user_id": UID, "source_account": ACCT, "position_id": pid,
                "symbol_raw": "DELTAU26", "side": "buy", "volume": volume}

    r1, r2, r3 = run_meta(1, RUN_A), run_meta(2, RUN_B), run_meta(3, RUN_C)
    events = t1.detect([r1, r2, r3], {
        RUN_A: [row(RUN_A, 101, 2.0)],
        RUN_B: [row(RUN_B, 101, 4.0)],
        RUN_C: [row(RUN_C, 101, 6.0)]})
    stamped = [dict(e, detected_at=T0 + 60 * i) for i, e in enumerate(events)]
    cands = t2.coalesce(stamped, quiet_window_seconds=QW)
    check(len(cands) == 1, "e2e: one candidate")
    c = cands[0]
    p = ad.build_capture_payload(c, now=closed_now(c))
    check(p["basis_run_id"] == RUN_C, "e2e: basis_run_id is the final after_run_id")
    check(p["event_types"] == [t1.EVENT_POSITION_INCREASE, t1.EVENT_POSITION_INCREASE],
          "e2e: both increases carried as evidence")
    check(len(p["detections"]) == 2 and all("detected_at" in d for d in p["detections"]),
          "e2e: detections carry rendered instants")
    check(ad.build_capture_payload(c, now=closed_now(c)) == p, "e2e: repeatable")


# ---------------------------------------------------------------------------------------------
# ordinal correspondence: parallel arrays that merely line up are not evidence
# ---------------------------------------------------------------------------------------------
def t_ordinal_correspondence_enforced():
    ds = [det(at=T0), det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3)]
    c = candidate(ds)
    now = closed_now(c)
    check(len(ad.build_capture_payload(c, now=now)["detections"]) == 2,
          "correspondence: the correctly aligned candidate is accepted")

    def raises(mutate):
        broken = copy.deepcopy(c)
        mutate(broken)
        return boom(lambda: ad.build_capture_payload(broken, now=now))

    check(raises(lambda b: b["detections"].reverse()) is not None,
          "correspondence: swapped detections refused")
    check(raises(lambda b: b["detection_identities"].reverse()) is not None,
          "correspondence: swapped identities refused")
    check(raises(lambda b: b["run_references"].reverse()) is not None,
          "correspondence: swapped run references refused")
    check(raises(lambda b: b["run_references"][0].update(after_run_seq=9)) is not None,
          "correspondence: a run_reference seq disagreeing with its detection refused")
    check(raises(lambda b: b["run_references"][0].update(before_run_seq=0)) is not None,
          "correspondence: run_reference before_run_seq 0 refused")
    check(raises(lambda b: b["run_references"][1].update(before_run_seq=3, after_run_seq=2))
          is not None, "correspondence: a run_reference running backwards refused")
    check(raises(lambda b: b["run_references"][0].update(after_run_id=RUN_A)) is not None,
          "correspondence: a run_reference naming one run twice refused")


# ---------------------------------------------------------------------------------------------
# parity with what the capture table / RPC will actually accept
# ---------------------------------------------------------------------------------------------
def t_sql_range_parity():
    c = candidate()
    now = closed_now(c)

    def raises(mutate):
        broken = copy.deepcopy(c)
        mutate(broken)
        return boom(lambda: ad.build_capture_payload(broken, now=now))

    check(raises(lambda b: b.update(position_id=0)) is not None,
          "parity: position_id 0 refused (mt5_ce_position_chk requires > 0)")
    check(raises(lambda b: b.update(position_id=-1)) is not None,
          "parity: a negative position_id refused")
    # coherently about position 0 everywhere: nothing else disagrees, so only the
    # mt5_ce_position_chk parity guard can refuse this one
    zeroed = copy.deepcopy(c)
    zeroed["position_id"] = 0
    zeroed["detection_identities"][0] = (UID, ACCT, t1.EVENT_POSITION_INCREASE, 0, RUN_A, RUN_B)
    zeroed["detections"][0]["position_id"] = 0
    check(boom(lambda: ad.build_capture_payload(zeroed, now=now)) is not None,
          "parity: a candidate coherently about position_id 0 is still refused")
    check(raises(lambda b: b.update(quiet_deadline=b["last_detection_at"] + 1.0)) is not None,
          "parity: a deadline that is not last_detection_at + window refused")

    ceiling = candidate(window=float(ad.SQL_MAX_WINDOW_SECONDS))
    check(boom(lambda: ad.build_capture_payload(ceiling, now=closed_now(ceiling))) is not None,
          "parity: a window AT the SQL ceiling is refused")
    over = candidate(window=float(ad.SQL_MAX_WINDOW_SECONDS) + 1.0)
    check(boom(lambda: ad.build_capture_payload(over, now=closed_now(over))) is not None,
          "parity: a window above the SQL ceiling is refused")
    inside = candidate(window=float(ad.SQL_MAX_WINDOW_SECONDS) - 1.0)
    check(ad.build_capture_payload(inside, now=closed_now(inside))["quiet_window_seconds"]
          == float(ad.SQL_MAX_WINDOW_SECONDS) - 1.0,
          "parity: a window just inside the ceiling is accepted")
    sub_us = candidate(window=0.0000001)
    check(boom(lambda: ad.build_capture_payload(sub_us, now=closed_now(sub_us))) is not None,
          "parity: a sub-microsecond window is refused, not rounded into one")


def t_microsecond_rendering_parity():
    """The database does its arithmetic on the RENDERED strings, so that is what must agree."""
    c = candidate()
    p = ad.build_capture_payload(c, now=closed_now(c))
    last_us = ad._iso_microseconds(p["last_detection_at"])
    dead_us = ad._iso_microseconds(p["quiet_deadline"])
    first_us = ad._iso_microseconds(p["first_detection_at"])
    check(dead_us - last_us == ad._window_microseconds(QW),
          "parity: rendered deadline == rendered last_detection_at + window, exactly")
    check(first_us <= last_us < dead_us,
          "parity: the rendered instants satisfy the table's ordering CHECK")
    check(ad._window_microseconds(300.0) == 300_000_000,
          "parity: a whole-second window converts exactly")
    check(ad._window_microseconds(0.5) == 500_000,
          "parity: a fractional window converts exactly")
    check(ad._window_microseconds(0.0000001) is None,
          "parity: a sub-microsecond window has no exact microsecond form")


# ---------------------------------------------------------------------------------------------
# forbidden fields, recursively
# ---------------------------------------------------------------------------------------------
def t_nested_forbidden_fields_refused():
    c = candidate()
    now = closed_now(c)
    for key in ad.FORBIDDEN_PAYLOAD_KEYS:
        broken = copy.deepcopy(c)
        broken["detections"][0][key] = "x"
        check(boom(lambda b=broken: ad.build_capture_payload(b, now=now)) is not None,
              f"forbidden: a detection carrying {key!r} is refused")
    deep = copy.deepcopy(c)
    deep["detections"][0]["extra"] = {"inner": [{"journal_trade_id": "t"}]}
    check(boom(lambda: ad.build_capture_payload(deep, now=now)) is not None,
          "forbidden: a forbidden key nested two levels down is refused")
    # the recursive walk itself, independent of the surrounding key-set checks
    check(ad._forbidden_key_in({"a": [{"b": {"equity": 1}}]}) == "equity",
          "forbidden: the recursive walk finds a deeply nested forbidden key")
    check(ad._forbidden_key_in([[{"decision_state": "x"}]]) == "decision_state",
          "forbidden: the recursive walk descends through arrays")
    check(ad._forbidden_key_in({"symbol_raw": "DELTAU26", "side": "buy"}) is None,
          "forbidden: a clean structure passes the recursive walk")
    check(ad._forbidden_key_in({"symbol_raw": "equity"}) is None,
          "forbidden: the walk matches KEYS, not values")


def t_sql_forbidden_vocabulary_parity():
    """The adapter, the RPC and the two table CHECKs must ban exactly the same vocabulary."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    art = os.path.join(root, "artifacts", "mt5_reconciliation")
    rpc = open(os.path.join(art, "T2_capture_events_rpc_packet.sql"), encoding="utf-8").read()
    schema = open(os.path.join(art, "T2_capture_events_schema_packet.sql"),
                  encoding="utf-8").read()
    match = re.search(r"v_forbidden\s+constant text := '([^']+)'", rpc)
    check(match is not None, "sql: the RPC declares a forbidden-field jsonpath")
    block = match.group(1) if match else ""
    check("$.**" in block, "sql: the RPC forbidden check is RECURSIVE")
    rpc_keys = sorted(set(re.findall(r'exists\(@\."([a-z_]+)"\)', block)))
    check(rpc_keys == sorted(ad.FORBIDDEN_PAYLOAD_KEYS),
          f"sql: the RPC forbidden vocabulary matches the adapter exactly (sql={rpc_keys})")
    schema_keys = sorted(set(re.findall(r'exists\(@\."([a-z_]+)"\)', schema)))
    check(schema_keys == sorted(ad.FORBIDDEN_PAYLOAD_KEYS),
          f"sql: the table CHECK vocabulary matches the adapter exactly (sql={schema_keys})")
    check(schema.count("$.**") >= 2,
          "sql: both forbidden-field CHECK constraints are RECURSIVE")


def t_sql_detection_field_sets_parity():
    """The RPC's per-event-type detection key sets must be the ones T2 derives from T1."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    rpc = open(os.path.join(root, "artifacts", "mt5_reconciliation",
                            "T2_capture_events_rpc_packet.sql"), encoding="utf-8").read()
    base = sorted(re.findall(
        r"'([a-z_]+)'",
        rpc.split("v_det_base     constant text[] := array[", 1)[1].split("];", 1)[0]))
    check(base == sorted(t2._BASE_FIELDS | {t2.DETECTED_AT}),
          f"sql: the RPC base detection field set matches T2 exactly (sql={base})")
    for etype in t1.EVENT_TYPES:
        extra = sorted(t2.T1_EVENT_FIELDS[etype] - t2._BASE_FIELDS)
        chunk = rpc.split("when '%s'" % etype, 1)
        if etype == t1.EVENT_POSITION_IDENTITY_CONFLICT:
            chunk = rpc.split("else v_det_base ||", 1)
        check(len(chunk) == 2, f"sql: the RPC names {etype}")
        if len(chunk) == 2:
            tail = chunk[1].split("]", 1)[0]
            found = sorted(set(re.findall(r"'([a-z_]+)'", tail)))
            check(found == extra,
                  f"sql: {etype} extra fields match T2 exactly (sql={found}, t2={extra})")


# ---------------------------------------------------------------------------------------------
# candidate-SET uniqueness: duplicate evidence is refused, never silently merged
# ---------------------------------------------------------------------------------------------
def t_set_uniqueness_enforced():
    ds = [det(at=T0), det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3)]
    c = candidate(ds)
    now = closed_now(c)

    def raises(mutate):
        broken = copy.deepcopy(c)
        mutate(broken)
        return boom(lambda: ad.build_capture_payload(broken, now=now))

    def duplicate(b):
        b["detection_identities"].append(b["detection_identities"][0])
        b["event_types"].append(b["event_types"][0])
        b["run_references"].append(copy.deepcopy(b["run_references"][0]))
        b["detections"].append(copy.deepcopy(b["detections"][0]))
    check(raises(duplicate) is not None,
          "set: a repeated detection identity is REFUSED, not de-duplicated")

    def contradictory(b):
        ident = list(b["detection_identities"][1])
        ident[2] = t1.EVENT_POSITION_DECREASE
        b["detection_identities"].append(tuple(ident))
        b["event_types"].append(t1.EVENT_POSITION_DECREASE)
        b["run_references"].append(copy.deepcopy(b["run_references"][1]))
        clone = copy.deepcopy(b["detections"][1])
        clone.update(event_type=t1.EVENT_POSITION_DECREASE, before_volume=4.0, after_volume=1.0)
        b["detections"].append(clone)
    check(raises(contradictory) is not None,
          "set: INCREASE and DECREASE for one observation key refused")

    def new_and_reappearance(b):
        base = det(at=T0, etype=t1.EVENT_NEW_POSITION)
        again = det(at=T0, etype=t1.EVENT_REAPPEARANCE)
        b["detections"] = [base, again]
        b["detection_identities"] = [t2.detection_identity(base), t2.detection_identity(again)]
        b["event_types"] = [base["event_type"], again["event_type"]]
        b["run_references"] = [{"before_run_id": d["before_run_id"],
                                "after_run_id": d["after_run_id"],
                                "before_run_seq": d["before_run_seq"],
                                "after_run_seq": d["after_run_seq"]} for d in (base, again)]
        b["last_detection_at"] = T0
        b["quiet_deadline"] = T0 + QW
        b["basis_run_id"] = base["after_run_id"]
    check(raises(new_and_reappearance) is not None,
          "set: NEW and REAPPEARANCE for one observation key refused")


# ---------------------------------------------------------------------------------------------
# the canonical identity wire format
# ---------------------------------------------------------------------------------------------
def t_canonical_identity_wire():
    """An equivalent spelling is not the same identity.

    The identity tuple is compared and hashed as TEXT, so "3F1A..." and "3f1a..." would be two
    identities for one observation and would mint two different deterministic event keys. The
    adapter refuses the alias; it never rewrites it into the canonical form, because rewriting
    would change what the stored evidence claims to identify.
    """
    ds = [det(at=T0), det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3)]
    c = candidate(ds)
    now = closed_now(c)

    def raises(mutate):
        broken = copy.deepcopy(c)
        mutate(broken)
        return boom(lambda: ad.build_capture_payload(broken, now=now))

    # ---- C: the canonical candidate is unchanged and still accepted --------------------------
    payload = ad.build_capture_payload(copy.deepcopy(c), now=now)
    check(payload["basis_run_id"] == RUN_C, "canonical: the happy path is unaffected")
    check([i[4] for i in payload["detection_identities"]] == [RUN_A, RUN_B],
          "canonical: run ids are passed through verbatim, never rewritten")
    check(payload["position_id"] == 101 and isinstance(payload["position_id"], int),
          "canonical: position_id stays an integer on the wire")
    # deterministic across replay: the same candidate renders the same bytes, so the server's
    # event_key over these identities is the same on every attempt
    again = ad.build_capture_payload(copy.deepcopy(c), now=now)
    check(ad.canonical_payload_json(payload) == ad.canonical_payload_json(again),
          "canonical: replay of the same candidate renders byte-identical evidence")

    # ---- A: UUID case aliases ----------------------------------------------------------------
    def upper_identity(b):
        ident = list(b["detection_identities"][0])
        ident[4] = ident[4].upper()
        b["detection_identities"][0] = tuple(ident)
        b["detections"][0]["before_run_id"] = ident[4]
        b["run_references"][0]["before_run_id"] = ident[4]
    check(raises(upper_identity) is not None,
          "canonical: an UPPERCASE run uuid in a detection identity is refused")

    def upper_everywhere(b):
        for i, ident in enumerate(b["detection_identities"]):
            ident = [x.upper() if isinstance(x, str) and "-" in x else x for x in ident]
            b["detection_identities"][i] = tuple(ident)
            b["detections"][i]["before_run_id"] = ident[4]
            b["detections"][i]["after_run_id"] = ident[5]
            b["run_references"][i]["before_run_id"] = ident[4]
            b["run_references"][i]["after_run_id"] = ident[5]
        b["basis_run_id"] = b["basis_run_id"].upper()
    check(raises(upper_everywhere) is not None,
          "canonical: a consistently UPPERCASE candidate is still refused")

    # the coexistence Codex named: the SAME logical run pair spelled two ways would be two
    # identities, so the alias must not be able to join a candidate alongside the canonical one
    def alias_coexists(b):
        ident = list(b["detection_identities"][0])
        alias = [ident[0], ident[1], ident[2], ident[3], ident[4].upper(), ident[5].upper()]
        b["detection_identities"].append(tuple(alias))
        b["event_types"].append(ident[2])
        b["run_references"].append({"before_run_id": alias[4], "after_run_id": alias[5],
                                    "before_run_seq": 1, "after_run_seq": 2})
        clone = copy.deepcopy(b["detections"][0])
        clone.update(before_run_id=alias[4], after_run_id=alias[5])
        b["detections"].append(clone)
    check(raises(alias_coexists) is not None,
          "canonical: an uppercase alias may NOT coexist with its canonical identity")

    for label, spelling in (("braced", "{%s}" % RUN_A),
                            ("urn-prefixed", "urn:uuid:" + RUN_A),
                            ("unhyphenated", RUN_A.replace("-", "")),
                            ("not a uuid at all", "run-a")):
        def bad_basis(b, spelling=spelling):
            b["basis_run_id"] = spelling
        check(raises(bad_basis) is not None,
              f"canonical: a {label} basis_run_id is refused")

    def upper_ref(b):
        b["run_references"][0]["before_run_id"] = RUN_A.upper()
    check(raises(upper_ref) is not None,
          "canonical: an UPPERCASE run uuid in a run_reference is refused")

    # CONSISTENTLY uppercase, so nothing disagrees with anything: the identities, the
    # detections and the candidate all say the same thing, and only the canonical rule is left
    # to notice that what they all say is a second spelling of one user.
    def upper_user(b):
        b["user_id"] = UID.upper()
        for i, ident in enumerate(b["detection_identities"]):
            ident = list(ident)
            ident[0] = UID.upper()
            b["detection_identities"][i] = tuple(ident)
            b["detections"][i]["user_id"] = UID.upper()
    check(raises(upper_user) is not None,
          "canonical: a consistently UPPERCASE user_id is refused")

    # ---- B: position_id type aliases ---------------------------------------------------------
    def string_position(b):
        b["position_id"] = "101"
    check(raises(string_position) is not None,
          "canonical: position_id as the string \"101\" is refused")

    def string_position_in_identity(b):
        ident = list(b["detection_identities"][0])
        ident[3] = "101"
        b["detection_identities"][0] = tuple(ident)
    check(raises(string_position_in_identity) is not None,
          "canonical: a STRING position_id inside an identity is refused")

    # True == 1 and 101.0 == 101 in Python, so an equality check alone would let these through
    def bool_position_in_identity(b):
        ident = list(b["detection_identities"][0])
        ident[3] = True
        b["detection_identities"][0] = tuple(ident)
        b["position_id"] = True
    check(raises(bool_position_in_identity) is not None,
          "canonical: a BOOLEAN position_id is refused")

    def float_position_in_identity(b):
        ident = list(b["detection_identities"][0])
        ident[3] = 101.0
        b["detection_identities"][0] = tuple(ident)
    check(raises(float_position_in_identity) is not None,
          "canonical: a FRACTIONAL-typed position_id inside an identity is refused")

    def zero_position(b):
        b["position_id"] = 0
    check(raises(zero_position) is not None, "canonical: position_id 0 is refused")

    def null_position(b):
        b["position_id"] = None
    check(raises(null_position) is not None, "canonical: a null position_id is refused")


# ---------------------------------------------------------------------------------------------
# source_account is opaque TEXT
# ---------------------------------------------------------------------------------------------
def t_source_account_is_opaque_text():
    """An account identifier is a string, not a number that renders like one.

    `301102520` and `"301102520"` are indistinguishable once rendered — which is exactly how the
    numeric alias reached the server's key derivation. The type is settled before the value is
    compared, and the value is preserved byte for byte: "0301102520" stays a different account
    instead of collapsing into the same integer.
    """
    ds = [det(at=T0), det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3)]
    c = candidate(ds)
    now = closed_now(c)

    def raises(mutate):
        broken = copy.deepcopy(c)
        mutate(broken)
        return boom(lambda: ad.build_capture_payload(broken, now=now))

    # ---- A: the top-level account -----------------------------------------------------------
    payload = ad.build_capture_payload(copy.deepcopy(c), now=now)
    check(payload["source_account"] == ACCT and isinstance(payload["source_account"], str),
          "account: the canonical string is accepted and passed through verbatim")

    for label, alias in (("an integer", 301102520),
                         ("a float", 301102520.0),
                         ("a bool", True),
                         ("None", None),
                         ("blank", "   ")):
        def bad_account(b, alias=alias):
            b["source_account"] = alias
        check(raises(bad_account) is not None,
              f"account: a top-level source_account that is {label} is refused")

    # a DIFFERENT string that a numeric reading would flatten onto the same account
    def leading_zero(b):
        b["source_account"] = "0" + ACCT
    check(raises(leading_zero) is not None,
          "account: \"0301102520\" is a different account, not the same one re-spelled")

    # ---- B: the account inside a detection ---------------------------------------------------
    def numeric_in_detection(b):
        b["detections"][0]["source_account"] = 301102520
    check(raises(numeric_in_detection) is not None,
          "account: a NUMERIC source_account inside a detection is refused")

    # ---- C: the account inside an identity ---------------------------------------------------
    def numeric_in_identity(b):
        ident = list(b["detection_identities"][0])
        ident[1] = 301102520
        b["detection_identities"][0] = tuple(ident)
    check(raises(numeric_in_identity) is not None,
          "account: a NUMERIC source_account inside an identity is refused")

    # ---- D: CONSISTENTLY numeric, so no scope check can make this vacuous --------------------
    # Everything agrees with everything; only the type rule can see that what they all agree on
    # is a number pretending to be an account identifier.
    def numeric_everywhere(b):
        b["source_account"] = 301102520
        for i, ident in enumerate(b["detection_identities"]):
            ident = list(ident)
            ident[1] = 301102520
            b["detection_identities"][i] = tuple(ident)
            b["detections"][i]["source_account"] = 301102520
    check(raises(numeric_everywhere) is not None,
          "account: a consistently NUMERIC source_account is still refused")

    # ---- E: user_id of the wrong JSON/Python type --------------------------------------------
    for label, alias in (("an integer", 12345), ("a bool", True), ("None", None),
                         ("a list", [UID])):
        def bad_user(b, alias=alias):
            b["user_id"] = alias
            for i, ident in enumerate(b["detection_identities"]):
                ident = list(ident)
                ident[0] = alias
                b["detection_identities"][i] = tuple(ident)
                b["detections"][i]["user_id"] = alias
        check(raises(bad_user) is not None,
              f"account: a user_id that is {label} is refused before any UUID comparison")

    # ---- F: the canonical happy path still replays identically -------------------------------
    again = ad.build_capture_payload(copy.deepcopy(c), now=now)
    check(ad.canonical_payload_json(payload) == ad.canonical_payload_json(again),
          "account: the canonical candidate is unchanged and replays byte-identically")


# ---------------------------------------------------------------------------------------------
# the complete quiet-window time invariant
# ---------------------------------------------------------------------------------------------
def t_quiet_window_invariant():
    """Four detections, so a MIDDLE one can run backwards while first_detection_at and
    last_detection_at both stay correct — the only way to isolate the chronology guard."""
    ds = [det(at=T0),
          det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3),
          det(at=T0 + 120, before=RUN_C, after=RUN_D, before_seq=3, after_seq=4),
          det(at=T0 + 180, before=RUN_D, after=RUN_E, before_seq=4, after_seq=5)]
    c = candidate(ds)
    check(len(ad.build_capture_payload(c, now=closed_now(c))["detections"]) == 4,
          "time: a real coalesced candidate satisfies the whole invariant")

    def raises(mutate):
        broken = copy.deepcopy(c)
        mutate(broken)
        # `now` must come from the MUTATED candidate, or a mutation that moves the deadline is
        # refused as "still OPEN" and the guard under test never runs.
        deadline = broken.get("quiet_deadline")
        at = (deadline + 1.0
              if isinstance(deadline, (int, float)) and math.isfinite(deadline)
              else closed_now(c))
        return boom(lambda: ad.build_capture_payload(broken, now=at))

    def swap(b, i, j):
        for field in ("detections", "detection_identities", "event_types", "run_references"):
            b[field][i], b[field][j] = b[field][j], b[field][i]
        b["basis_run_id"] = b["run_references"][-1]["after_run_id"]

    check(raises(lambda b: swap(b, 1, 2)) is not None,
          "time: a detection that runs backwards refused")
    check(raises(lambda b: b.update(first_detection_at=b["first_detection_at"] - 30.0))
          is not None, "time: first_detection_at that is not the first detection refused")
    check(raises(lambda b: b.update(last_detection_at=b["last_detection_at"] + 30.0,
                                    quiet_deadline=b["quiet_deadline"] + 30.0))
          is not None, "time: last_detection_at that is not the final detection refused")

    def gap(b):
        b["detections"][3]["detected_at"] = b["detections"][2]["detected_at"] + 4 * QW
        b["last_detection_at"] = b["detections"][3]["detected_at"]
        b["quiet_deadline"] = b["last_detection_at"] + QW
    check(raises(gap) is not None,
          "time: an internal gap larger than the quiet window refused (two candidates, not one)")

    check(raises(lambda b: b.update(last_detection_at=float("inf"))) is not None,
          "time: a non-finite candidate instant refused")
    check(raises(lambda b: b["detections"][0].update(detected_at=float("nan"))) is not None,
          "time: a non-finite nested detected_at refused")

    def tie(b):
        # two MIDDLE detections share an instant; first and last are untouched
        b["detections"][2]["detected_at"] = b["detections"][1]["detected_at"]
    check(raises(tie) is None,
          "time: equal instants IN the T2 canonical order are accepted")

    def tie_out_of_order(b):
        tie(b)
        swap(b, 1, 2)
    check(raises(tie_out_of_order) is not None,
          "time: equal instants out of the T2 canonical order refused")


ALL = [
    t_deterministic_payload, t_different_detection_set_differs, t_provenance_preserved,
    t_no_account_facts_and_no_decision_state, t_open_candidate_refused,
    t_malformed_candidate_refused, t_inputs_not_mutated, t_rpc_request_shape,
    t_end_to_end_from_real_t1,
    t_ordinal_correspondence_enforced, t_sql_range_parity, t_microsecond_rendering_parity,
    t_nested_forbidden_fields_refused, t_sql_forbidden_vocabulary_parity,
    t_sql_detection_field_sets_parity,
    t_set_uniqueness_enforced, t_quiet_window_invariant, t_canonical_identity_wire,
    t_source_account_is_opaque_text,
]


def main():
    for fn in ALL:
        try:
            fn()
        except Exception as e:                                   # noqa: BLE001
            FAILS.append(f"{fn.__name__} raised {type(e).__name__}: {e}")
    print(f"t2 capture adapter pure tests: {CHECKS[0]} checks, "
          f"{'PASS' if not FAILS else f'{len(FAILS)} FAIL'}")
    for f in FAILS:
        print("  FAIL:", f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
