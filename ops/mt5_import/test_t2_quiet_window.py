#!/usr/bin/env python3
"""
MT5 T2 v0.1 — pure quiet-window tests. No MT5, no DB, no network, no clock.

Run with:  python -X utf8 ops/mt5_import/test_t2_quiet_window.py
"""
from __future__ import annotations

import copy
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:                                     # package mode
    from . import t1_detector as t1
    from . import t2_quiet_window as t2
except ImportError:                      # script mode
    import t1_detector as t1                                              # noqa: E402
    import t2_quiet_window as t2                                          # noqa: E402

CHECKS = [0]
FAILS = []

UID = "b77d0426-1111-4222-8333-444455556666"
ACCT = "301102520"
QW = 300.0                       # injected window for tests; NOT a production cadence


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


def det(*, at, pid=101, etype=t1.EVENT_POSITION_INCREASE, before="run-1", after="run-2",
        before_seq=1, after_seq=2, user=UID, acct=ACCT, **over):
    """Build a detection with EXACTLY the field set t1_detector.py emits for `etype`."""
    d = {"event_type": etype, "position_id": pid,
         "before_run_id": before, "after_run_id": after,
         "before_run_seq": before_seq, "after_run_seq": after_seq,
         "user_id": user, "source_account": acct}
    if etype == t1.EVENT_POSITION_IDENTITY_CONFLICT:
        d.update(before_symbol_raw="DELTAU26", after_symbol_raw="S50U26",
                 before_side="buy", after_side="buy",
                 before_volume=2.0, after_volume=4.0)
    else:
        d.update(symbol_raw="DELTAU26", side="buy")
        if etype in (t1.EVENT_POSITION_INCREASE, t1.EVENT_POSITION_DECREASE):
            d.update(before_volume=2.0,
                     after_volume=4.0 if etype == t1.EVENT_POSITION_INCREASE else 1.0)
        elif etype == t1.EVENT_POSITION_DISAPPEARED:
            d.update(before_volume=2.0)
        else:                                    # NEW_POSITION / REAPPEARANCE
            d.update(after_volume=4.0)
    d["detected_at"] = at
    d.update(over)
    return d


def boom(fn):
    try:
        fn()
        return None
    except t2.T2InputError as e:
        return str(e)


# ---------------------------------------------------------------------------------------------
# 1-4. windowing
# ---------------------------------------------------------------------------------------------
def t_single_detection_one_candidate():
    cands = t2.coalesce([det(at=1000.0)], quiet_window_seconds=QW)
    check(len(cands) == 1, "one detection -> one candidate")
    c = cands[0]
    check(c["first_detection_at"] == 1000.0 and c["last_detection_at"] == 1000.0,
          "single: first/last detection instants")
    check(c["quiet_deadline"] == 1300.0, "single: deadline = detected_at + window")
    check(t2.closed_candidates(cands, now=1299.0) == [],
          "single: still open before the deadline")
    check(len(t2.closed_candidates(cands, now=1301.0)) == 1,
          "single: the TIMER closes the candidate after expiry")


def t_inside_window_coalesces():
    cands = t2.coalesce([det(at=1000.0), det(at=1100.0, etype=t1.EVENT_POSITION_DECREASE,
                                             before="run-2", after="run-3", after_run_seq=3)],
                        quiet_window_seconds=QW)
    check(len(cands) == 1, "compatible detection inside the window coalesces")
    check(len(cands[0]["detection_identities"]) == 2, "coalesced: two identities retained")
    check(cands[0]["event_types"] == [t1.EVENT_POSITION_INCREASE,
                                      t1.EVENT_POSITION_DECREASE],
          "coalesced: contributing event types preserved in order")


def t_join_extends_deadline():
    cands = t2.coalesce([det(at=1000.0), det(at=1200.0, after="run-3", after_run_seq=3)],
                        quiet_window_seconds=QW)
    check(len(cands) == 1 and cands[0]["quiet_deadline"] == 1500.0,
          "join RESTARTS the deadline (1200 + 300), not the original 1300")
    check(cands[0]["last_detection_at"] == 1200.0, "join: last_detection_at advances")
    # a chain of joins keeps the window open well past the first deadline
    chain = [det(at=1000.0 + 200.0 * i, after=f"run-{i + 2}", after_run_seq=i + 2)
             for i in range(5)]
    cands = t2.coalesce(chain, quiet_window_seconds=QW)
    check(len(cands) == 1 and cands[0]["quiet_deadline"] == 1800.0 + 300.0,
          "join: a burst chain keeps one candidate open")


def t_after_deadline_starts_new_candidate():
    cands = t2.coalesce([det(at=1000.0),
                         det(at=1300.1, after="run-9", after_run_seq=9)],
                        quiet_window_seconds=QW)
    check(len(cands) == 2, "a detection after the deadline starts a NEW candidate")
    check(cands[0]["quiet_deadline"] == 1300.0 and cands[1]["first_detection_at"] == 1300.1,
          "new candidate: the closed one keeps its own deadline")
    # exactly ON the deadline still joins (boundary is inclusive)
    cands = t2.coalesce([det(at=1000.0), det(at=1300.0, after="run-9", after_run_seq=9)],
                        quiet_window_seconds=QW)
    check(len(cands) == 1, "boundary: a detection exactly AT the deadline still joins")


# ---------------------------------------------------------------------------------------------
# 5-6. detection identity
# ---------------------------------------------------------------------------------------------
def t_identity_rule_and_dedup():
    d = det(at=1000.0)
    check(t2.detection_identity(d) ==
          (UID, ACCT, t1.EVENT_POSITION_INCREASE, 101, "run-1", "run-2"),
          "identity: the frozen six-field natural key")
    check(t2.detection_identity(dict(d, detected_at=9999.0)) == t2.detection_identity(d),
          "identity: derived from content only — replay time does not change it")

    cands = t2.coalesce([d, dict(d), dict(d, detected_at=1100.0)], quiet_window_seconds=QW)
    check(len(cands) == 1 and len(cands[0]["detection_identities"]) == 1,
          "dedup: the same identity replayed collapses to one detection")
    check(cands[0]["quiet_deadline"] == 1300.0,
          "dedup: a replay cannot push the deadline (minimum detected_at wins)")


def t_conflicting_payload_fails_closed():
    d = det(at=1000.0)
    conflict = dict(d, after_volume=99.0)
    msg = boom(lambda: t2.coalesce([d, conflict], quiet_window_seconds=QW))
    check(msg is not None and "conflicting payload" in msg,
          "conflict: same identity + different payload raises T2InputError")
    check(boom(lambda: t2.coalesce([d, dict(d, symbol_raw="S50U26")],
                                   quiet_window_seconds=QW)) is not None,
          "conflict: differing symbol under one identity raises")


# ---------------------------------------------------------------------------------------------
# 7-8. grouping isolation
# ---------------------------------------------------------------------------------------------
def t_never_coalesce_across_scope():
    cands = t2.coalesce([det(at=1000.0, pid=101), det(at=1010.0, pid=202)],
                        quiet_window_seconds=QW)
    check(len(cands) == 2, "different position_id never coalesces")
    cands = t2.coalesce([det(at=1000.0), det(at=1010.0, acct="999888777")],
                        quiet_window_seconds=QW)
    check(len(cands) == 2, "different source_account never coalesces")
    other_user = "c99f0000-1111-4222-8333-444455556666"
    cands = t2.coalesce([det(at=1000.0), det(at=1010.0, user=other_user)],
                        quiet_window_seconds=QW)
    check(len(cands) == 2, "different user_id never coalesces")
    # same position, different event types DO coalesce (grouping key excludes event_type)
    cands = t2.coalesce([det(at=1000.0),
                         det(at=1010.0, etype=t1.EVENT_POSITION_DISAPPEARED,
                             before="run-2", after="run-3", after_run_seq=3)],
                        quiet_window_seconds=QW)
    check(len(cands) == 1, "same position: different event types still coalesce")


# ---------------------------------------------------------------------------------------------
# 9-10. provenance
# ---------------------------------------------------------------------------------------------
def t_basis_run_and_provenance():
    ds = [det(at=1000.0, before="run-1", after="run-2", before_run_seq=1, after_run_seq=2),
          det(at=1100.0, before="run-2", after="run-3", before_run_seq=2, after_run_seq=3,
              etype=t1.EVENT_POSITION_DECREASE),
          det(at=1200.0, before="run-3", after="run-4", before_run_seq=3, after_run_seq=4,
              etype=t1.EVENT_POSITION_INCREASE)]
    c = t2.coalesce(ds, quiet_window_seconds=QW)[0]
    check(c["basis_run_id"] == "run-4",
          "basis_run_id = after_run_id of the FINAL detection in the candidate")
    check(len(c["detection_identities"]) == 3, "provenance: all contributing identities kept")
    befores = [r["before_run_id"] for r in c["run_references"]]
    afters = [r["after_run_id"] for r in c["run_references"]]
    check(befores == ["run-1", "run-2", "run-3"] and afters == ["run-2", "run-3", "run-4"],
          "provenance: every before/after run reference retained")
    check(c["first_detection_at"] == 1000.0 and c["last_detection_at"] == 1200.0
          and c["quiet_deadline"] == 1500.0,
          "provenance: first/last detection instants and quiet_deadline present")
    check(c["quiet_window_seconds"] == QW, "provenance: the window used is recorded")
    # the timer closes it, not the run: a later run reference does not close anything
    check(t2.closed_candidates([c], now=1400.0) == [],
          "the run does NOT close the candidate — only the timer does")


# ---------------------------------------------------------------------------------------------
# 11-12, 14. determinism and purity
# ---------------------------------------------------------------------------------------------
def t_input_order_normalised():
    ds = [det(at=1000.0, after="run-2", after_run_seq=2),
          det(at=1100.0, before="run-2", after="run-3", after_run_seq=3),
          det(at=2000.0, after="run-9", after_run_seq=9),
          det(at=1050.0, pid=202, after="run-2", after_run_seq=2)]
    baseline = t2.coalesce(ds, quiet_window_seconds=QW)
    rng = random.Random(11)
    for _ in range(8):
        shuffled = rng.sample(ds, k=len(ds))
        check(t2.coalesce(shuffled, quiet_window_seconds=QW) == baseline,
              "determinism: output independent of input order")
    check([(c["position_id"], c["first_detection_at"]) for c in baseline]
          == sorted((c["position_id"], c["first_detection_at"]) for c in baseline),
          "determinism: candidates ordered by (…, position_id, first_detection_at)")


def t_inputs_not_mutated():
    ds = [det(at=1000.0), det(at=1100.0, before="run-2", after="run-3", after_run_seq=3)]
    snap = copy.deepcopy(ds)
    cands = t2.coalesce(ds, quiet_window_seconds=QW)
    check(ds == snap, "purity: input detections not mutated")
    cands[0]["detections"][0]["symbol_raw"] = "MUTATED"
    check(ds == snap, "purity: candidate detections are copies, not aliases of the input")


# ---------------------------------------------------------------------------------------------
# 13. evidence-only, and the T1 classification is preserved verbatim
# ---------------------------------------------------------------------------------------------
def t_evidence_only():
    ds = [det(at=1000.0, etype=t1.EVENT_POSITION_DECREASE, after_volume=1.0),
          det(at=1100.0, etype=t1.EVENT_POSITION_DISAPPEARED, before="run-2", after="run-3",
              after_run_seq=3)]
    c = t2.coalesce(ds, quiet_window_seconds=QW)[0]
    check(c["event_types"] == [t1.EVENT_POSITION_DECREASE, t1.EVENT_POSITION_DISAPPEARED],
          "evidence: contributing T1 event types preserved verbatim")
    blob = repr(c).lower()
    for banned in ("closed", "close_price", "realized", "realised", "pnl", "p/l", "lots"):
        check(banned not in blob,
              f"evidence: candidate never renders {banned!r} — observation-level only")
    check(not any(k in c for k in ("close_price", "realized_pl", "realised_pl", "action")),
          "evidence: no action/close/P-L fields on the candidate")

    # T1's NEW vs REAPPEARANCE classification is passed through untouched
    for etype in (t1.EVENT_NEW_POSITION, t1.EVENT_REAPPEARANCE):
        c = t2.coalesce([det(at=1000.0, etype=etype)], quiet_window_seconds=QW)[0]
        check(c["event_types"] == [etype],
              f"history contract: T2 preserves {etype} exactly, no reinterpretation")


# ---------------------------------------------------------------------------------------------
# input validation
# ---------------------------------------------------------------------------------------------
def t_input_validation():
    d = det(at=1000.0)
    check(boom(lambda: t2.coalesce([d], quiet_window_seconds=0)) is not None,
          "validation: quiet_window_seconds must be > 0")
    check(boom(lambda: t2.coalesce([d], quiet_window_seconds=-5)) is not None,
          "validation: negative window refused")
    check(boom(lambda: t2.coalesce([d], quiet_window_seconds=float("inf"))) is not None,
          "validation: non-finite window refused")
    check(boom(lambda: t2.coalesce([dict(d, detected_at=None)],
                                   quiet_window_seconds=QW)) is not None,
          "validation: missing detected_at refused (injected time only)")
    check(boom(lambda: t2.coalesce([dict(d, detected_at="1000")],
                                   quiet_window_seconds=QW)) is not None,
          "validation: string detected_at refused")
    check(boom(lambda: t2.coalesce([dict(d, event_type="POSITION_CLOSED")],
                                   quiet_window_seconds=QW)) is not None,
          "validation: event_type outside the T1 vocabulary refused")
    check(boom(lambda: t2.coalesce([dict(d, position_id="101")],
                                   quiet_window_seconds=QW)) is not None,
          "validation: string position_id refused")
    check(boom(lambda: t2.coalesce([dict(d, position_id=True)],
                                   quiet_window_seconds=QW)) is not None,
          "validation: bool position_id refused")
    check(boom(lambda: t2.coalesce([dict(d, after_run_id="  ")],
                                   quiet_window_seconds=QW)) is not None,
          "validation: blank after_run_id refused")
    missing = {k: v for k, v in d.items() if k != "before_run_id"}
    check(boom(lambda: t2.coalesce([missing], quiet_window_seconds=QW)) is not None,
          "validation: missing identity field refused")
    check(boom(lambda: t2.closed_candidates([], now=None)) is not None,
          "validation: closed_candidates requires an injected numeric now")
    check(t2.coalesce([], quiet_window_seconds=QW) == [], "validation: empty input is legal")


# ---------------------------------------------------------------------------------------------
# end-to-end over REAL T1 output
# ---------------------------------------------------------------------------------------------
def t_consumes_real_t1_events():
    def run_meta(seq, run_id):
        return {"run_id": run_id, "user_id": UID, "source_account": ACCT, "run_seq": seq,
                "snapshot_status": "complete", "snapshot_health": "healthy"}

    def row(run_id, pid, volume):
        return {"run_id": run_id, "user_id": UID, "source_account": ACCT,
                "position_id": pid, "symbol_raw": "DELTAU26", "side": "buy",
                "volume": volume}

    r1, r2, r3 = run_meta(1, "ra"), run_meta(2, "rb"), run_meta(3, "rc")
    events = t1.detect([r1, r2, r3], {
        "ra": [row("ra", 101, 2.0)],
        "rb": [row("rb", 101, 4.0)],
        "rc": [row("rc", 101, 6.0), row("rc", 202, 1.0)]})
    check(len(events) == 3, "e2e: T1 produced the expected events")
    stamped = [dict(e, detected_at=1000.0 + 60.0 * i) for i, e in enumerate(events)]
    cands = t2.coalesce(stamped, quiet_window_seconds=QW)
    by_pid = {c["position_id"]: c for c in cands}
    check(set(by_pid) == {101, 202}, "e2e: one candidate per position")
    check(by_pid[101]["event_types"] == [t1.EVENT_POSITION_INCREASE,
                                         t1.EVENT_POSITION_INCREASE],
          "e2e: both increases on 101 coalesced")
    check(by_pid[101]["basis_run_id"] == "rc", "e2e: basis_run_id is the final after_run_id")
    check(by_pid[202]["event_types"] == [t1.EVENT_NEW_POSITION],
          "e2e: the new position is its own candidate")
    # identities computed from real T1 output are stable across a T1 replay
    replay = t1.detect([r3, r1, r2], {
        "ra": [row("ra", 101, 2.0)],
        "rb": [row("rb", 101, 4.0)],
        "rc": [row("rc", 202, 1.0), row("rc", 101, 6.0)]})
    check([t2.detection_identity(e) for e in replay]
          == [t2.detection_identity(e) for e in events],
          "e2e: identities are stable across a T1 replay with shuffled input")


# ---------------------------------------------------------------------------------------------
# Codex adversarial round: contradictory classification, order-independent replay, strict T1
# contract validation
# ---------------------------------------------------------------------------------------------
def t_contradictory_classification():
    """Same observation key (same run pair, same position) cannot carry two classifications."""
    inc = det(at=1000.0, etype=t1.EVENT_POSITION_INCREASE)
    dec = det(at=1010.0, etype=t1.EVENT_POSITION_DECREASE)
    check(t2.observation_key(inc) == t2.observation_key(dec),
          "obs key: INCREASE and DECREASE for one run pair share the observation key")
    check(t2.detection_identity(inc) != t2.detection_identity(dec),
          "obs key: ...while their durable detection identities differ (event_type is in it)")
    msg = boom(lambda: t2.coalesce([inc, dec], quiet_window_seconds=QW))
    check(msg is not None and "contradictory classification" in msg,
          "obs key: INCREASE + DECREASE on one observation key raises")
    check(boom(lambda: t2.coalesce([dec, inc], quiet_window_seconds=QW)) is not None,
          "obs key: raises regardless of input order")
    check(boom(lambda: t2.coalesce(
        [det(at=1000.0, etype=t1.EVENT_NEW_POSITION),
         det(at=1000.0, etype=t1.EVENT_REAPPEARANCE)], quiet_window_seconds=QW)) is not None,
          "obs key: NEW_POSITION + REAPPEARANCE on one observation key raises")
    # a DIFFERENT run pair for the same position is legitimate, not a contradiction
    ok = t2.coalesce([inc, det(at=1010.0, etype=t1.EVENT_POSITION_DECREASE,
                               before="run-2", after="run-3", before_seq=2, after_seq=3)],
                     quiet_window_seconds=QW)
    check(len(ok) == 1 and ok[0]["event_types"] == [t1.EVENT_POSITION_INCREASE,
                                                    t1.EVENT_POSITION_DECREASE],
          "obs key: different run pairs may legitimately classify differently")
    # the durable identity itself is unchanged by this round
    check(t2.DETECTION_IDENTITY_FIELDS ==
          ("user_id", "source_account", "event_type", "position_id",
           "before_run_id", "after_run_id"),
          "obs key: the frozen durable detection identity is unchanged")


def t_replay_timestamp_is_minimum():
    late, early = det(at=200.0), det(at=100.0)
    forward = t2.coalesce([late, early], quiet_window_seconds=QW)
    reverse = t2.coalesce([early, late], quiet_window_seconds=QW)
    check(len(forward) == 1 and forward[0]["first_detection_at"] == 100.0,
          "replay: detected_at is the MINIMUM across duplicates, not first-encountered")
    check(forward == reverse,
          "replay: reversing duplicate input order yields an identical candidate")
    for field in ("first_detection_at", "last_detection_at", "quiet_deadline",
                  "basis_run_id", "detection_identities"):
        check(forward[0][field] == reverse[0][field],
              f"replay: {field} identical in both orders")
    check(forward[0]["detections"][0]["detected_at"] == 100.0,
          "replay: the stored detection's detected_at is normalised to the minimum")
    check(forward[0]["quiet_deadline"] == 400.0,
          "replay: the deadline is built from the minimum instant")
    # three copies, arbitrary order -> still the minimum
    rng = random.Random(3)
    copies = [det(at=t) for t in (300.0, 100.0, 200.0)]
    for _ in range(5):
        shuffled = rng.sample(copies, k=3)
        check(t2.coalesce(shuffled, quiet_window_seconds=QW) == forward,
              "replay: N duplicates in any order collapse to the minimum instant")


def t_strict_t1_contract_validation():
    d = det(at=1000.0)

    def raises(**over):
        return boom(lambda: t2.coalesce([dict(d, **over)], quiet_window_seconds=QW))

    def raises_on(detection):
        return boom(lambda: t2.coalesce([detection], quiet_window_seconds=QW))

    # ---- run references -----------------------------------------------------------------
    check(raises(before_run_id="run-2", after_run_id="run-2") is not None,
          "strict: before_run_id == after_run_id raises")
    check(raises(before_run_seq=None) is not None, "strict: missing before_run_seq raises")
    check(raises(after_run_seq="2") is not None, "strict: string after_run_seq raises")
    check(raises(before_run_seq=0) is not None, "strict: zero run_seq raises")
    check(raises(before_run_seq=-1) is not None, "strict: negative run_seq raises")
    check(raises(before_run_seq=True) is not None, "strict: bool run_seq raises")
    check(raises(before_run_seq=2, after_run_seq=2) is not None,
          "strict: before_run_seq == after_run_seq raises")
    check(raises(before_run_seq=3, after_run_seq=2) is not None,
          "strict: before_run_seq > after_run_seq raises")

    # ---- exact field set per event type --------------------------------------------------
    check(raises_on({k: v for k, v in d.items() if k != "symbol_raw"}) is not None,
          "strict: INCREASE missing symbol_raw raises")
    check(raises(unexpected_field=1) is not None,
          "strict: a field T1 does not emit raises")
    disappeared = det(at=1000.0, etype=t1.EVENT_POSITION_DISAPPEARED)
    check(raises_on(dict(disappeared, after_volume=1.0)) is not None,
          "strict: DISAPPEARED carrying after_volume raises (T1 emits before-facts only)")
    new_pos = det(at=1000.0, etype=t1.EVENT_NEW_POSITION)
    check(raises_on(dict(new_pos, before_volume=1.0)) is not None,
          "strict: NEW_POSITION carrying before_volume raises (after-facts only)")
    check(raises_on(dict(new_pos)) is None, "strict: a well-formed NEW_POSITION is accepted")
    check(raises_on(dict(disappeared)) is None,
          "strict: a well-formed DISAPPEARED is accepted")

    # ---- position facts ------------------------------------------------------------------
    check(raises(symbol_raw="  ") is not None, "strict: blank symbol_raw raises")
    check(raises(side="long") is not None, "strict: invalid side raises")
    check(raises(after_volume=0) is not None, "strict: zero volume raises")
    check(raises(after_volume=-4.0) is not None, "strict: negative volume raises")
    check(raises(after_volume=float("nan")) is not None, "strict: NaN volume raises")
    check(raises(after_volume=float("inf")) is not None, "strict: inf volume raises")
    check(raises(after_volume="4.0") is not None, "strict: string volume raises")

    # ---- direction must agree with the volumes T1 compared -------------------------------
    check(raises(before_volume=4.0, after_volume=2.0) is not None,
          "strict: INCREASE whose after_volume < before_volume raises")
    check(raises(before_volume=2.0, after_volume=2.0) is not None,
          "strict: INCREASE with equal volumes raises")
    dec = det(at=1000.0, etype=t1.EVENT_POSITION_DECREASE)
    check(raises_on(dict(dec, before_volume=1.0, after_volume=4.0)) is not None,
          "strict: DECREASE whose after_volume > before_volume raises")
    check(raises_on(dict(dec, before_volume=2.0, after_volume=2.0)) is not None,
          "strict: DECREASE with equal volumes raises")

    # ---- identity conflict must actually conflict ----------------------------------------
    conflict = det(at=1000.0, etype=t1.EVENT_POSITION_IDENTITY_CONFLICT)
    check(raises_on(dict(conflict)) is None,
          "strict: a genuine symbol conflict is accepted")
    check(raises_on(dict(conflict, before_symbol_raw="DELTAU26",
                         after_symbol_raw="DELTAU26")) is not None,
          "strict: IDENTITY_CONFLICT with unchanged symbol AND side raises")
    check(raises_on(dict(conflict, before_symbol_raw="DELTAU26",
                         after_symbol_raw="DELTAU26", after_side="sell")) is None,
          "strict: a side-only conflict is a genuine conflict")
    check(raises_on(dict(conflict, before_side="long")) is not None,
          "strict: IDENTITY_CONFLICT with an invalid side raises")
    check(raises_on(dict(conflict, after_symbol_raw="  ")) is not None,
          "strict: IDENTITY_CONFLICT with a blank symbol raises")

    # ---- injected time / window / deadline ----------------------------------------------
    check(raises(detected_at=float("nan")) is not None, "strict: NaN detected_at raises")
    check(raises(detected_at=float("inf")) is not None, "strict: inf detected_at raises")
    check(boom(lambda: t2.coalesce([d], quiet_window_seconds=float("nan"))) is not None,
          "strict: NaN quiet_window_seconds raises")
    huge = 1.7e308
    check(boom(lambda: t2.coalesce([dict(d, detected_at=huge)],
                                   quiet_window_seconds=huge)) is not None,
          "strict: a deadline that overflows to inf raises before anything is stored")


def t_dual_mode_import():
    """Both usages must work. The package half runs in a SUBPROCESS whose sys.path does NOT
    contain ops/mt5_import, so this module's own sys.path insert cannot mask it: if T2 fell
    back to a bare sibling import, `from ops.mt5_import import ...` would fail there."""
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    here = os.path.dirname(os.path.abspath(__file__))
    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}

    probe = (
        "import sys, os;"
        "here = os.path.join(os.getcwd(), 'ops', 'mt5_import');"
        "assert not any(os.path.abspath(p) == here for p in sys.path if p), "
        "'ops/mt5_import must NOT be on sys.path for this probe';"
        "from ops.mt5_import import t2_quiet_window as t2;"
        "from ops.mt5_import import t1_detector as t1;"
        "assert t2.t1 is t1, 'T2 must bind the PACKAGE t1_detector in package mode';"
        "assert t2.DETECTION_IDENTITY_FIELDS[2] == 'event_type';"
        "assert set(t2.T1_EVENT_FIELDS) == set(t1.EVENT_TYPES);"
        "assert t2.coalesce([], quiet_window_seconds=300.0) == [];"
        "print('PACKAGE_IMPORT_OK')"
    )
    r = subprocess.run([sys.executable, "-X", "utf8", "-c", probe],
                       cwd=repo, env=env, capture_output=True, text=True)
    check(r.returncode == 0 and "PACKAGE_IMPORT_OK" in r.stdout,
          f"import: `from ops.mt5_import import t2_quiet_window` works "
          f"(rc={r.returncode} {r.stderr.strip()[-200:]})")

    # script/direct mode: run the module directly with ops/mt5_import on the path, as the
    # operator does. This is the mode this very suite runs under.
    r = subprocess.run(
        [sys.executable, "-X", "utf8", "-c",
         "import t2_quiet_window as t2, t1_detector as t1;"
         "assert t2.t1 is t1;"
         "assert t2.coalesce([], quiet_window_seconds=300.0) == [];"
         "print('SCRIPT_IMPORT_OK')"],
        cwd=here, env=env, capture_output=True, text=True)
    check(r.returncode == 0 and "SCRIPT_IMPORT_OK" in r.stdout,
          f"import: direct/local execution still works "
          f"(rc={r.returncode} {r.stderr.strip()[-200:]})")

    # and the source really carries the dual-mode form, not a bare sibling import
    src = open(os.path.join(here, "t2_quiet_window.py"), encoding="utf-8").read()
    check("from . import t1_detector as t1" in src and "except ImportError:" in src
          and "import t1_detector as t1" in src,
          "import: t2_quiet_window.py uses the repository dual-mode convention")


ALL = [
    t_dual_mode_import,
    t_single_detection_one_candidate, t_inside_window_coalesces, t_join_extends_deadline,
    t_after_deadline_starts_new_candidate, t_identity_rule_and_dedup,
    t_conflicting_payload_fails_closed, t_never_coalesce_across_scope,
    t_basis_run_and_provenance, t_input_order_normalised, t_inputs_not_mutated,
    t_evidence_only, t_input_validation, t_consumes_real_t1_events,
    t_contradictory_classification, t_replay_timestamp_is_minimum,
    t_strict_t1_contract_validation,
]


def main():
    for fn in ALL:
        try:
            fn()
        except Exception as e:                                   # noqa: BLE001
            FAILS.append(f"{fn.__name__} raised {type(e).__name__}: {e}")
    print(f"t2 quiet-window pure tests: {CHECKS[0]} checks, "
          f"{'PASS' if not FAILS else f'{len(FAILS)} FAIL'}")
    for f in FAILS:
        print("  FAIL:", f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
