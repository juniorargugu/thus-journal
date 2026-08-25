#!/usr/bin/env python3
"""
Pure tests for ops/mt5_import/t2_capture_writer.py. No DB, no network, no clock.

Every scenario is driven through the REAL committed t1_detector / t2_quiet_window /
t2_capture_adapter, so a test passing means the approved pipeline accepted the harness's
projection — not that a weaker local shape was satisfied.

Run with:  python -X utf8 ops/mt5_import/test_t2_capture_writer.py
"""
from __future__ import annotations

import contextlib
import copy
import inspect
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from . import t1_detector as t1
    from . import t2_capture_adapter as t2a
    from . import t2_quiet_window as t2
    from . import t2_capture_writer as w
except ImportError:
    import t1_detector as t1                                                # noqa: E402
    import t2_capture_adapter as t2a                                        # noqa: E402
    import t2_quiet_window as t2                                            # noqa: E402
    import t2_capture_writer as w                                           # noqa: E402


CHECKS = [0]
FAILS = []

UID = "b77d0426-1111-4222-8333-444455556666"
OTHER_UID = "c88e1537-2222-4333-8444-555566667777"
ACCT = "301102520"
OTHER_ACCT = "0301102520"                     # a DIFFERENT account, not a normalised one

R1 = "3f1a0000-0000-4000-8000-000000000001"
R2 = "3f1a0000-0000-4000-8000-000000000002"
R3 = "3f1a0000-0000-4000-8000-000000000003"
R4 = "3f1a0000-0000-4000-8000-000000000004"
R5 = "3f1a0000-0000-4000-8000-000000000005"
# User B's own runs. run_seq is per user/account, so B legitimately reuses 1 and 2.
B1 = "3f1a0000-0000-4000-8000-0000000000b1"
B2 = "3f1a0000-0000-4000-8000-0000000000b2"

# captured_at is DELIBERATELY earlier than snapshot_completed_at, mirroring production
# (run_seq 1 was captured 12:30:00 and completed 12:35:05). A fixture that collapsed the two
# would let DETECTED_AT_SOURCE be changed with no test noticing.
CAP = {R1: "2026-08-22T12:30:00+00:00", R2: "2026-08-22T13:30:00+00:00",
       R3: "2026-08-22T13:36:00+00:00", R4: "2026-08-22T15:30:00+00:00",
       R5: "2026-08-22T15:36:00+00:00",
       B1: "2026-08-22T12:30:00+00:00", B2: "2026-08-22T13:30:00+00:00"}
# R2 -> R3 completions are 120s apart, INSIDE a 300s window.
# R3 -> R4 completions are ~118 minutes apart, far OUTSIDE it.
# R4 -> R5 completions are 120s apart, INSIDE it again.
DONE = {R1: "2026-08-22T12:35:00+00:00", R2: "2026-08-22T13:35:00+00:00",
        R3: "2026-08-22T13:37:00+00:00", R4: "2026-08-22T15:35:00+00:00",
        R5: "2026-08-22T15:37:00+00:00",
        B1: "2026-08-22T12:35:00+00:00", B2: "2026-08-22T13:35:00+00:00"}
SEQ = {R1: 1, R2: 2, R3: 3, R4: 4, R5: 5, B1: 1, B2: 2}
QW = 300.0
# well after every fixture deadline, so "closed" is the default unless a test says otherwise
NOW_CLOSED = w.to_epoch(w.parse_instant("2026-08-24T00:00:00Z"))


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


def boom(fn, expect=w.CaptureWriterError):
    """Return the message iff `fn` raised EXACTLY the expected type, else None.

    The type matters: a KeyError that happens to escape is not a refusal.
    """
    try:
        fn()
        return None
    except expect as e:
        return str(e)


# ---------------------------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------------------------
def run(rid, *, seq=None, status="complete", health="healthy", user=UID, acct=ACCT,
        completed=None):
    return {"id": rid, "user_id": user, "source_account": acct,
            "run_seq": SEQ[rid] if seq is None else seq,
            "snapshot_status": status, "snapshot_health": health,
            "captured_at": CAP[rid],
            "snapshot_completed_at": DONE[rid] if completed is None else completed}


def pos(rid, pid, *, symbol="DELTAU26", side="buy", volume=2.0, user=UID, acct=ACCT):
    return {"run_id": rid, "user_id": user, "source_account": acct, "position_id": pid,
            "symbol_raw": symbol, "side": side, "volume": volume, "captured_at": CAP[rid]}


def plan(runs, memberships, *, before=R1, after=R2, window=QW, now=NOW_CLOSED, acct=ACCT):
    return w.plan_capture(runs=runs, memberships=memberships, user_id=UID,
                          source_account=acct, before_run_id=before, after_run_id=after,
                          quiet_window_seconds=window, now=now)


def two_run(before_positions, after_positions):
    return [run(R1), run(R2)], {R1: before_positions, R2: after_positions}


def done_at(rid):
    return w.to_epoch(w.parse_instant(DONE[rid]))


def suspicious_gap_runs(*extra):
    """The frozen Codex repro: healthy R1, SUSPICIOUS R2, healthy R3, healthy R4 (+extras).

    R2 is a COMPLETED observation whose health is suspicious. It emits nothing and breaks
    continuity, so R3 is a fresh baseline and R1 -> R3 is NOT a delta.
    """
    return [run(R1), run(R2, health="suspicious"), run(R3), run(R4), *extra]


def suspicious_gap_membership(v1=2.0, v3=4.0, v4=6.0, **extra):
    """Membership for the HEALTHY runs only. R2 deliberately has NO key at all: an empty list
    would be flat-account evidence, which is not what a suspicious observation means."""
    mem = {R1: [pos(R1, 101, volume=v1)], R3: [pos(R3, 101, volume=v3)],
           R4: [pos(R4, 101, volume=v4)]}
    mem.update(extra)
    return mem


def pairs_of(detections):
    return [(d["before_run"].split()[-1], d["after_run"].split()[-1]) for d in detections]


# ---------------------------------------------------------------------------------------------
# anchor-pair validation
# ---------------------------------------------------------------------------------------------
def t_valid_pair_accepted():
    runs, _ = two_run([], [])
    before, after = w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                        before_run_id=R1, after_run_id=R2)
    check(before["id"] == R1 and after["id"] == R2, "valid anchor returns (before, after)")


def t_same_run_rejected():
    runs, _ = two_run([], [])
    msg = boom(lambda: w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                           before_run_id=R1, after_run_id=R1), w.RunPairError)
    check(msg is not None and "two observations" in msg, "same run for both sides refused")


def t_missing_run_rejected():
    runs, _ = two_run([], [])
    msg = boom(lambda: w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                           before_run_id=R1, after_run_id=R4), w.RunPairError)
    check(msg is not None and "not found" in msg, "unknown run id refused")


def t_wrong_scope_rejected():
    for label, bad in (("user", run(R2, user=OTHER_UID)),
                       ("account", run(R2, acct=OTHER_ACCT))):
        runs = [run(R1), bad]
        msg = boom(lambda rs=runs: w.validate_run_pair(
            rs, user_id=UID, source_account=ACCT, before_run_id=R1, after_run_id=R2),
            w.RunPairError)
        check(msg is not None and "out of the requested scope" in msg,
              f"cross-{label} anchor refused")


def t_incomplete_run_rejected():
    for status in ("started", "failed"):
        runs = [run(R1), run(R2, status=status)]
        msg = boom(lambda rs=runs: w.validate_run_pair(
            rs, user_id=UID, source_account=ACCT, before_run_id=R1, after_run_id=R2),
            w.RunPairError)
        check(msg is not None and "snapshot_status" in msg,
              f"non-complete ({status}) anchor run refused")


def t_unhealthy_run_rejected():
    runs = [run(R1), run(R2, health="suspicious")]
    msg = boom(lambda: w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                           before_run_id=R1, after_run_id=R2), w.RunPairError)
    check(msg is not None and "breaks continuity" in msg, "suspicious completed run refused")


def t_reversed_pair_rejected():
    runs = [run(R1), run(R2)]
    msg = boom(lambda: w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                           before_run_id=R2, after_run_id=R1), w.RunPairError)
    check(msg is not None and "reversed" in msg, "reversed anchor refused")


def t_non_adjacent_pair_rejected():
    runs = [run(R1), run(R2), run(R3)]
    msg = boom(lambda: w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                           before_run_id=R1, after_run_id=R3), w.RunPairError)
    check(msg is not None and "sit between" in msg, "non-adjacent anchor refused")
    runs2 = [run(R1), run(R2, health="suspicious"), run(R3)]
    msg2 = boom(lambda: w.validate_run_pair(runs2, user_id=UID, source_account=ACCT,
                                            before_run_id=R1, after_run_id=R3), w.RunPairError)
    check(msg2 is not None and "sit between" in msg2,
          "suspicious completed run between the anchor still breaks adjacency")


def t_duplicate_run_id_rejected():
    runs = [run(R1), run(R1), run(R2)]
    msg = boom(lambda: w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                           before_run_id=R1, after_run_id=R2), w.RunPairError)
    check(msg is not None and "twice" in msg, "duplicated run row refused")


def t_null_run_seq_on_non_complete_runs_is_tolerated():
    """mt5_sync_runs_complete_shape_chk only requires run_seq when snapshot_status='complete',
    so a started/failed run really does arrive with run_seq = NULL. Every comparison touching
    run_seq must be guarded by the status test, or the harness dies on a normal database."""
    started = run(R3, status="started")
    started["run_seq"] = None
    started["snapshot_completed_at"] = None
    runs = [run(R1), run(R2), started]
    _before, after = w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                         before_run_id=R1, after_run_id=R2)
    check(after["run_seq"] == 2, "a NULL run_seq elsewhere does not break anchor validation")
    obs = w.completed_observations_as_of(runs, now=NOW_CLOSED)
    check([r["id"] for r in obs] == [R1, R2],
          "the observation history skips non-completed rows without touching their NULLs")
    rep = plan(runs, {R1: [], R2: [pos(R2, 101)]})
    check(rep["detection_count"] == 1, "the full plan still runs with NULL rows present")


def t_non_complete_run_between_the_pair_is_not_adjacency():
    started = run(R2, status="started")
    started["run_seq"] = None
    runs = [run(R1), started, run(R3)]
    before, after = w.validate_run_pair(runs, user_id=UID, source_account=ACCT,
                                        before_run_id=R1, after_run_id=R3)
    check((before["id"], after["id"]) == (R1, R3),
          "a non-completed attempt between two completed runs does not break adjacency")


# ---------------------------------------------------------------------------------------------
# event semantics, end to end through the real pipeline
# ---------------------------------------------------------------------------------------------
def t_zero_detection():
    runs, mem = two_run([pos(R1, 101)], [pos(R2, 101)])
    rep = plan(runs, mem)
    check(rep["detections"] == [], "unchanged membership produces zero detections")
    check(rep["canonical_candidate_count"] == 0, "zero detections produce zero candidates")
    check(rep["anchored_candidate_count"] == 0, "and therefore zero anchored candidates")
    check(rep["rpc_requests"] == [], "zero candidates produce zero rpc requests")


def t_new_position():
    runs, mem = two_run([], [pos(R2, 101, volume=4.0)])
    rep = plan(runs, mem)
    check([d["event_type"] for d in rep["detections"]] == [t1.EVENT_NEW_POSITION],
          "absent -> present is NEW_POSITION")
    check(rep["detections"][0]["after_volume"] == 4.0, "NEW carries after_volume")
    check("before_volume" not in rep["detections"][0],
          "NEW has no before_volume — an absent position has no measured volume")


def t_reappearance_uses_full_history():
    runs = [run(R1), run(R2), run(R3)]
    mem = {R1: [pos(R1, 101)], R2: [], R3: [pos(R3, 101)]}
    rep = plan(runs, mem, before=R2, after=R3)
    types = [d["event_type"] for d in rep["detections"]]
    check(t1.EVENT_REAPPEARANCE in types,
          "a position seen in an earlier healthy run returns as REAPPEARANCE")
    rep_short = plan([run(R2), run(R3)], {R2: [], R3: [pos(R3, 101)]}, before=R2, after=R3)
    check([d["event_type"] for d in rep_short["detections"]] == [t1.EVENT_NEW_POSITION],
          "the same pair with truncated history would mint NEW — history load is load-bearing")


def t_increase_and_decrease():
    runs, mem = two_run([pos(R1, 101, volume=2.0)], [pos(R2, 101, volume=4.0)])
    check([d["event_type"] for d in plan(runs, mem)["detections"]]
          == [t1.EVENT_POSITION_INCREASE], "larger stored volume is POSITION_INCREASE")
    runs, mem = two_run([pos(R1, 101, volume=4.0)], [pos(R2, 101, volume=1.0)])
    rep = plan(runs, mem)
    check([d["event_type"] for d in rep["detections"]] == [t1.EVENT_POSITION_DECREASE],
          "smaller stored volume is POSITION_DECREASE")
    d = rep["detections"][0]
    check(d["before_volume"] == 4.0 and d["after_volume"] == 1.0,
          "DECREASE reports both truthful stored volumes")


def t_disappeared():
    runs, mem = two_run([pos(R1, 101, volume=2.0)], [])
    rep = plan(runs, mem)
    check([d["event_type"] for d in rep["detections"]] == [t1.EVENT_POSITION_DISAPPEARED],
          "present -> absent is POSITION_DISAPPEARED")
    check("after_volume" not in rep["detections"][0],
          "DISAPPEARED has no after_volume — absence is not a measured zero")


def t_identity_conflict():
    runs, mem = two_run([pos(R1, 101, symbol="DELTAU26")], [pos(R2, 101, symbol="S50U26")])
    rep = plan(runs, mem)
    check([d["event_type"] for d in rep["detections"]]
          == [t1.EVENT_POSITION_IDENTITY_CONFLICT],
          "same position_id with a different symbol is POSITION_IDENTITY_CONFLICT")
    d = rep["detections"][0]
    check(d["before_symbol_raw"] == "DELTAU26" and d["after_symbol_raw"] == "S50U26",
          "conflict reports both identities rather than choosing one")


def t_multiple_positions_one_pair():
    runs, mem = two_run([pos(R1, 101, volume=2.0), pos(R1, 202)],
                        [pos(R2, 101, volume=5.0)])
    rep = plan(runs, mem)
    check(sorted(d["event_type"] for d in rep["detections"])
          == [t1.EVENT_POSITION_DISAPPEARED, t1.EVENT_POSITION_INCREASE],
          "one pair can yield one detection per position")
    check(rep["canonical_candidate_count"] == 2,
          "coalesce keys by position, so two positions are two candidates")


# ---------------------------------------------------------------------------------------------
# CANONICAL COALESCING — the anchor selects, it does not bound
# ---------------------------------------------------------------------------------------------
def three_run_growing():
    """101 grows 2 -> 4 -> 6 across R1->R2->R3, whose COMPLETIONS are 120s apart."""
    runs = [run(R1), run(R2), run(R3)]
    mem = {R1: [pos(R1, 101, volume=2.0)],
           R2: [pos(R2, 101, volume=4.0)],
           R3: [pos(R3, 101, volume=6.0)]}
    return runs, mem


def t_two_detections_in_one_window_are_one_candidate():
    runs, mem = three_run_growing()
    rep = plan(runs, mem, before=R1, after=R2)
    check(rep["detection_count"] == 2, "two consecutive pairs yield two detections")
    check(rep["canonical_candidate_count"] == 1,
          "both detections land inside one quiet window -> ONE canonical candidate")
    cand = rep["canonical_candidates"][0]
    check(cand["detection_count"] == 2, "the canonical candidate carries BOTH detections")
    check(cand["basis_run_id"] == R3,
          "basis_run_id is the after_run_id of the FINAL detection, not of the anchor")


def t_anchor_on_the_first_pair_returns_the_whole_candidate():
    runs, mem = three_run_growing()
    rep = plan(runs, mem, before=R1, after=R2)
    check(rep["anchored_candidate_count"] == 1, "the anchor selects exactly one candidate")
    cand = rep["anchored_candidates"][0]
    check(cand["detection_count"] == 2,
          "anchoring on R1->R2 still returns the candidate containing R2->R3")
    check(cand["extends_beyond_anchor"] is True,
          "the report says plainly that the candidate extends beyond the anchor pair")
    check(rep["anchor_detection_count"] == 1,
          "exactly one detection belongs to the anchor pair itself")


def t_anchor_on_the_second_pair_returns_the_same_candidate():
    runs, mem = three_run_growing()
    first = plan(runs, mem, before=R1, after=R2)["anchored_candidates"][0]
    second = plan(runs, mem, before=R2, after=R3)["anchored_candidates"][0]
    for field in ("detection_count", "event_sequence", "first_detection_at",
                  "last_detection_at", "quiet_deadline", "basis_run_id", "run_pairs"):
        check(first[field] == second[field],
              f"anchoring on either pair yields the SAME canonical candidate ({field})")


def t_pair_local_coalescing_would_have_been_wrong():
    """The regression this refactor exists for: a pair-local run would produce two
    single-detection candidates whose basis_run_id depends on which pair was named."""
    runs, mem = three_run_growing()
    rep = plan(runs, mem, before=R1, after=R2)
    check(rep["canonical_candidate_count"] == 1,
          "canonical coalescing produces ONE candidate, not one per pair")
    check(rep["anchored_candidates"][0]["run_pairs"] == [f"{R1} -> {R2}", f"{R2} -> {R3}"],
          "and it names both contributing run pairs in order")


def t_detection_outside_the_window_starts_a_new_candidate():
    runs = [run(R1), run(R2), run(R3), run(R4)]
    mem = {R1: [pos(R1, 101, volume=2.0)], R2: [pos(R2, 101, volume=4.0)],
           R3: [pos(R3, 101, volume=6.0)], R4: [pos(R4, 101, volume=8.0)]}
    rep = plan(runs, mem, before=R1, after=R2)
    check(rep["detection_count"] == 3, "three consecutive pairs yield three detections")
    check(rep["canonical_candidate_count"] == 2,
          "the R3->R4 detection is far outside the window, so it opens a SECOND candidate")
    check(rep["anchored_candidate_count"] == 1,
          "only the candidate containing the anchor pair is returned")
    check(rep["anchored_candidates"][0]["detection_count"] == 2,
          "the anchored candidate carries the two in-window detections only")


def t_anchor_with_no_detection_returns_nothing_even_if_others_exist():
    """R1->R2 unchanged, R2->R3 changed. Anchoring the quiet pair must return no candidate,
    not the neighbouring one."""
    runs = [run(R1), run(R2), run(R3)]
    mem = {R1: [pos(R1, 101, volume=2.0)], R2: [pos(R2, 101, volume=2.0)],
           R3: [pos(R3, 101, volume=6.0)]}
    rep = plan(runs, mem, before=R1, after=R2)
    check(rep["detection_count"] == 1, "the history still contains one detection")
    check(rep["canonical_candidate_count"] == 1, "which forms one canonical candidate")
    check(rep["anchored_candidate_count"] == 0,
          "but the anchor pair contributed nothing, so nothing is anchored")
    check(rep["rpc_requests"] == [], "and no request is built")


def t_later_trusted_run_with_no_detection_manufactures_nothing():
    runs = [run(R1), run(R2), run(R3)]
    mem = {R1: [], R2: [pos(R2, 101, volume=4.0)], R3: [pos(R3, 101, volume=4.0)]}
    rep = plan(runs, mem, before=R1, after=R2)
    check(rep["detection_count"] == 1,
          "a later trusted run with unchanged membership adds no event")
    check(rep["anchored_candidates"][0]["detection_count"] == 1,
          "the anchored candidate is not padded with a phantom detection")


def t_readiness_is_never_overclaimed():
    """A closed canonical candidate the operator did NOT anchor is not this run's to append."""
    runs = [run(R1), run(R2), run(R3)]
    mem = {R1: [pos(R1, 101, volume=2.0)], R2: [pos(R2, 101, volume=2.0)],
           R3: [pos(R3, 101, volume=6.0)]}
    rep = plan(runs, mem, before=R1, after=R2)
    other = rep["canonical_candidates"][0]
    check(other["closed"] is True, "the neighbouring candidate really is closed")
    check(other["eligible_for_this_invocation"] is False,
          "but it is NOT eligible for this invocation — the anchor did not select it")
    check(rep["closed_anchored_candidates"] == 0, "so nothing is counted as ready")
    check(rep["rpc_requests"] == [], "and no request is built for it")
    anchored_rep = plan(runs, mem, before=R2, after=R3)
    check(anchored_rep["anchored_candidates"][0]["eligible_for_this_invocation"] is True,
          "anchoring the pair that produced it does make it eligible")


# ---------------------------------------------------------------------------------------------
# AS-OF HISTORY
# ---------------------------------------------------------------------------------------------
def t_run_completed_after_now_is_excluded():
    runs, mem = three_run_growing()
    now = done_at(R3) - 1.0            # between R2's completion and R3's
    obs = w.completed_observations_as_of(runs, now=now)
    check([r["id"] for r in obs] == [R1, R2],
          "a run completed after `now` is not in the as-of observation history")
    rep = plan(runs, mem, before=R1, after=R2, now=now)
    check(rep["detection_count"] == 1, "and contributes no detection")
    check(rep["canonical_history"]["excluded_as_future_to_now"] == 1,
          "the report states how many completed observations were excluded as future-to-now")
    # A SUSPICIOUS run completed after `now` is an observation too, and is counted as one.
    rep2 = plan(runs + [run(R4, health="suspicious")], mem, before=R1, after=R2, now=now)
    check(rep2["canonical_history"]["excluded_as_future_to_now"] == 2,
          "a suspicious future run is excluded AND counted as a completed observation")


def t_later_run_included_when_within_now():
    runs, mem = three_run_growing()
    rep = plan(runs, mem, before=R1, after=R2, now=done_at(R3) + 1.0)
    check(rep["detection_count"] == 2,
          "a later trusted run completed at or before `now` IS part of the history")
    check(rep["anchored_candidates"][0]["detection_count"] == 2,
          "and can join the anchor's candidate")


def t_anchor_after_run_completed_after_now_is_refused():
    runs, mem = three_run_growing()
    msg = boom(lambda: plan(runs, mem, before=R2, after=R3, now=done_at(R3) - 1.0),
               w.RunPairError)
    check(msg is not None and "completed after the effective now" in msg,
          "an anchor that was not yet observable at `now` is refused, not silently emptied")


def t_history_is_not_bounded_by_the_anchor_run_seq():
    """The old, wrong bound. R3 has a HIGHER run_seq than the anchor's after-run and must
    still be included when it completed within `now`."""
    runs, mem = three_run_growing()
    rep = plan(runs, mem, before=R1, after=R2)
    seqs = sorted({int(d["after_run"].split()[1]) for d in rep["detections"]})
    check(seqs == [2, 3],
          "detections come from run_seq 2 AND 3 even though the anchor's after-run is 2")
    check(rep["canonical_history"]["last_run_seq"] == 3,
          "the canonical history extends past the anchor")


# ---------------------------------------------------------------------------------------------
# TIME — authoritative completion instant
# ---------------------------------------------------------------------------------------------
def t_detected_at_is_the_completion_instant_not_captured_at():
    runs, mem = two_run([], [pos(R2, 101)])
    rep = plan(runs, mem)
    check(rep["detections"][0]["detected_at"] == "2026-08-22T13:35:00Z",
          "detected_at is the after run's snapshot_completed_at")
    check(rep["detections"][0]["detected_at"] != "2026-08-22T13:30:00Z",
          "detected_at is NOT captured_at — the source constant is load-bearing")
    check(w.DETECTED_AT_SOURCE == "snapshot_completed_at",
          "the source is pinned to the authoritative completion column")
    cand = rep["anchored_candidates"][0]
    check(cand["first_detection_at"] == "2026-08-22T13:35:00Z",
          "first_detection_at is that instant")
    check(cand["quiet_deadline"] == "2026-08-22T13:40:00Z",
          "quiet_deadline is that instant + the window")


def t_candidate_cannot_close_before_the_after_run_completed():
    runs, mem = two_run([], [pos(R2, 101)])
    captured = w.to_epoch(w.parse_instant(CAP[R2]))
    # An instant past captured_at + window but before completion + window: under the old
    # captured_at rule the window would already have expired here. It must not be closed.
    rep = plan(runs, mem, now=captured + QW + 1.0)
    check(rep["closed_anchored_candidates"] == 0,
          "a candidate cannot be closed before its after-run was authoritative")
    check(plan(runs, mem, now=done_at(R2) + QW + 1.0)["closed_anchored_candidates"] == 1,
          "it closes once the window has run from the COMPLETION instant")


def t_each_detection_is_dated_by_its_own_after_run():
    runs, mem = three_run_growing()
    rep = plan(runs, mem, before=R1, after=R2)
    check([d["detected_at"] for d in rep["detections"]]
          == ["2026-08-22T13:35:00Z", "2026-08-22T13:37:00Z"],
          "each detection carries its OWN after-run completion instant, not one batch value")


def t_boundary_is_strictly_after_deadline():
    runs, mem = two_run([], [pos(R2, 101)])
    deadline = done_at(R2) + QW
    check(plan(runs, mem, now=deadline)["closed_anchored_candidates"] == 0,
          "now == quiet_deadline is NOT closed (strictly after)")
    check(plan(runs, mem, now=deadline + 0.001)["closed_anchored_candidates"] == 1,
          "now just past the deadline closes it")


def t_open_candidate_builds_no_request():
    runs, mem = two_run([], [pos(R2, 101)])
    rep = plan(runs, mem, now=done_at(R2) + 1.0)
    check(rep["anchored_candidates"][0]["closed"] is False, "open candidate reports not closed")
    check(rep["anchored_candidates"][0]["state"].startswith("OPEN"),
          "open candidate is reported as OPEN / NOT YET PERSISTABLE")
    check(rep["rpc_requests"] == [],
          "an OPEN candidate builds no rpc request — the adapter refuses it")


def t_completed_run_without_a_completion_instant_is_refused():
    """Applies to SUSPICIOUS completed runs too: they now sit in the observation history, so
    an undatable one would silently drop out of it and re-bridge the very gap it creates."""
    for health in ("healthy", "suspicious"):
        bad = run(R2, health=health)
        bad["snapshot_completed_at"] = None
        msg = boom(lambda b=bad: w.completed_observations_as_of([run(R1), b], now=NOW_CLOSED))
        check(msg is not None and "authoritative completion instant is unknown" in msg,
              f"a completed {health} run with no completion instant is refused, never "
              f"defaulted")


# ---------------------------------------------------------------------------------------------
# COUNT COMPLETENESS / PAGINATION
# ---------------------------------------------------------------------------------------------
def fake_reader(pages):
    """An EvidenceReader whose _get replays a scripted list of (rows, headers)."""
    reader = w.EvidenceReader.__new__(w.EvidenceReader)
    seen = []

    def fake_get(table, query, *, first=None, last=None):
        seen.append((table, first, last))
        if not pages:
            raise AssertionError("more pages requested than scripted")
        return pages.pop(0)

    reader._get = fake_get
    reader._seen = seen
    return reader


def t_missing_count_is_rejected():
    reader = fake_reader([([{"run_id": R1}], {})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "no exact Content-Range count" in msg,
          "a response with no Content-Range is refused, never accepted as complete")


def t_malformed_count_is_rejected():
    for bad in ("0-0/*", "0-0/abc", "*/", "items 0-0"):
        reader = fake_reader([([{"run_id": R1}], {"Content-Range": bad})])
        msg = boom(lambda r=reader: r._get_all(w.POSITIONS, "?order=id.asc"),
                   w.IncompleteReadError)
        check(msg is not None, f"malformed Content-Range {bad!r} refused")


def t_truncated_response_is_completed_by_paging():
    reader = fake_reader([
        ([{"run_id": R1, "position_id": 1}], {"Content-Range": "0-0/2"}),
        ([{"run_id": R1, "position_id": 2}], {"Content-Range": "1-1/2"}),
    ])
    rows = reader._get_all(w.POSITIONS, "?order=run_id.asc")
    check(len(rows) == 2, "a short first page is completed by fetching the next page")
    check([p[1] for p in reader._seen] == [0, 1],
          "the second request starts exactly where the first ended")


def t_incomplete_read_that_cannot_progress_is_rejected():
    reader = fake_reader([
        ([{"run_id": R1}], {"Content-Range": "0-0/7"}),
        ([], {"Content-Range": "1-1/7"}),
    ])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "the body was empty" in msg,
          "a page that claims coordinates but carries no rows fails closed")


def t_inconsistent_total_between_pages_is_rejected():
    reader = fake_reader([
        ([{"a": 1}], {"Content-Range": "0-0/3"}),
        ([{"a": 2}], {"Content-Range": "1-1/9"}),
    ])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "changed between pages" in msg,
          "a total that moves mid-read is refused as ambiguous")


def t_over_long_read_is_rejected():
    """The PAGE coordinates are what refuse this, not a downstream tally of accumulated rows:
    '0-2/2' promises a row index 2 that cannot exist inside an exact total of 2."""
    reader = fake_reader([([{"a": 1}, {"a": 2}, {"a": 3}], {"Content-Range": "0-2/2"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "over-long read" in msg,
          "more rows than the server promised is refused, not truncated locally")
    check(msg is not None and "not below the exact total" in msg,
          "and it is the end-vs-total page invariant that refuses it")
    # A LATER page may also overrun: page 0 is fine, page 1 claims a row past the total.
    reader = fake_reader([
        ([{"a": 1}], {"Content-Range": "0-0/2"}),
        ([{"a": 2}, {"a": 3}], {"Content-Range": "1-2/2"}),
    ])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "not below the exact total" in msg,
          "an over-running SECOND page is refused at the page, before it is accumulated")


def t_end_below_start_is_rejected():
    """A later page really can carry a start that matches the request and an end beneath it
    ('1-0/3'); the total order of START-END must be proven, not assumed."""
    reader = fake_reader([
        ([{"a": 1}], {"Content-Range": "0-0/3"}),
        ([{"a": 2}], {"Content-Range": "1-0/3"}),
    ])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "is below its start" in msg,
          "a Content-Range whose end precedes its start is refused")


def t_exact_zero_and_exact_n_are_accepted():
    reader = fake_reader([([], {"Content-Range": "*/0"})])
    check(reader._get_all(w.POSITIONS, "?order=id.asc") == [],
          "an exact zero-row read is accepted (a legal flat account)")
    reader = fake_reader([([{"a": 1}, {"a": 2}], {"Content-Range": "0-1/2"})])
    check(len(reader._get_all(w.POSITIONS, "?order=id.asc")) == 2,
          "an exact N-row read is accepted")


def t_unordered_paginated_read_is_refused():
    reader = fake_reader([([{"a": 1}], {"Content-Range": "0-0/1"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?select=x"))
    check(msg is not None and "deterministic order=" in msg,
          "an unordered multi-page read is refused: pages could overlap or skip")


def t_every_collection_read_is_ordered():
    reader = w.EvidenceReader.__new__(w.EvidenceReader)
    seen = []

    def fake_get_all(table, query):
        seen.append((table, query))
        return []

    reader._get_all = fake_get_all
    reader.runs_in_scope(user_id=UID, source_account=ACCT)
    reader.memberships_for(user_id=UID, source_account=ACCT, run_ids=[R1])
    for table, query in seen:
        check("order=" in query, f"{table} collection read carries an order= clause")
    check(len(seen) == 2, "both collection reads were exercised")


# ---------------------------------------------------------------------------------------------
# SCOPE — capture count is user-scoped
# ---------------------------------------------------------------------------------------------
def t_capture_count_is_user_scoped():
    reader = w.EvidenceReader.__new__(w.EvidenceReader)
    captured = {}

    def fake_get(table, query, *, first=None, last=None):
        captured.update(table=table, query=query, first=first, last=last)
        return [], {"Content-Range": "*/0"}

    reader._get = fake_get
    check(reader.capture_event_count(user_id=UID) == 0, "an exact zero count is returned")
    check(captured["table"] == w.CAPTURE_EVENTS, "the count reads the capture table")
    check(f"user_id=eq.{UID}" in captured["query"],
          "the count is filtered to the requested user_id")
    check(OTHER_UID not in captured["query"], "no other user's rows are in scope")
    check((captured["first"], captured["last"]) == (0, 0),
          "rows 0-0: the count transfers at most one id row, never a bulk read")


def t_capture_count_ignores_other_users():
    """Whole-table counting was the bug. Prove the filter is what decides the answer.

    The fixture answers the way PostgREST actually does: '*/0' with no body for an empty set,
    and '0-0/N' with exactly ONE id row when rows exist.
    """
    rows_by_user = {UID: 0, OTHER_UID: 5}
    reader = w.EvidenceReader.__new__(w.EvidenceReader)

    def fake_get(table, query, *, first=None, last=None):
        who = UID if f"user_id=eq.{UID}" in query else OTHER_UID
        n = rows_by_user[who]
        if n == 0:
            return [], {"Content-Range": "*/0"}
        return [{"id": "row-0"}], {"Content-Range": f"0-0/{n}"}

    reader._get = fake_get
    check(reader.capture_event_count(user_id=UID) == 0,
          "user A's count is 0 even though user B has 5 rows")
    check(reader.capture_event_count(user_id=OTHER_UID) == 5,
          "and a request that asks for user B still sees B's own count")


def t_membership_refuses_an_out_of_scope_row():
    reader = w.EvidenceReader.__new__(w.EvidenceReader)
    reader._get_all = lambda table, query: [{"run_id": R4, "position_id": 1}]
    msg = boom(lambda: reader.memberships_for(user_id=UID, source_account=ACCT,
                                              run_ids=[R1, R2]))
    check(msg is not None and "not requested" in msg,
          "a membership row for an unrequested run is refused, never silently absorbed")


def t_membership_requests_are_chunked():
    reader = w.EvidenceReader.__new__(w.EvidenceReader)
    queries = []

    def fake_get_all(table, query):
        queries.append(query)
        return []

    reader._get_all = fake_get_all
    ids = [f"3f1a0000-0000-4000-8000-{i:012d}" for i in range(w.RUN_IDS_PER_REQUEST * 2 + 3)]
    out = reader.memberships_for(user_id=UID, source_account=ACCT, run_ids=ids)
    check(len(queries) == 3, "run ids are split into chunks, not one unbounded URL")
    check(all(len(q) < 4000 for q in queries),
          "every chunked query stays well inside any proxy URL limit")
    check(set(out) == set(ids) and all(v == [] for v in out.values()),
          "every requested run still appears in the result, defaulting to empty")


# ---------------------------------------------------------------------------------------------
# SUSPICIOUS RUNS BREAK CONTINUITY  (completed observation history vs healthy membership)
# ---------------------------------------------------------------------------------------------
def t_completed_observation_history_includes_suspicious():
    """T1's input is every COMPLETED observation. Membership is only the healthy subset."""
    runs = suspicious_gap_runs()
    obs = w.completed_observations_as_of(runs, now=NOW_CLOSED)
    check([r["id"] for r in obs] == [R1, R2, R3, R4],
          "the completed observation history carries the suspicious run too")
    check(w.healthy_membership_run_ids(obs) == [R1, R3, R4],
          "membership is loaded for exactly the HEALTHY subset")
    check(R2 not in w.healthy_membership_run_ids(obs),
          "the suspicious run is never given a position list")
    check(w.is_completed(run(R2, health="suspicious")) is True,
          "a suspicious run IS a completed observation")
    check(w.is_trusted(run(R2, health="suspicious")) is False,
          "...but it is NOT a trusted one")


def t_suspicious_run_breaks_continuity():
    """THE CODEX REPRO. R1 vol 2, SUSPICIOUS R2, R3 vol 4, R4 vol 6; anchor R3 -> R4.

    Only R3 -> R4 may be emitted. R1 -> R3 would be a delta across an untrusted gap.
    """
    report = plan(suspicious_gap_runs(), suspicious_gap_membership(), before=R3, after=R4)
    dets = report["detections"]
    check(report["detection_count"] == 1,
          "exactly ONE detection is derived across a suspicious gap, never two")
    check(pairs_of(dets) == [(R3, R4)],
          "the only detection is R3 -> R4; the gap is not bridged")
    check((R1, R3) not in pairs_of(dets),
          "R1 -> R3 is NOT emitted: R2 broke the chain and R3 is a fresh baseline")
    check(dets[0]["event_type"] == "POSITION_INCREASE" and dets[0]["position_id"] == 101,
          "R3 -> R4 is the POSITION_INCREASE")
    check((dets[0]["before_volume"], dets[0]["after_volume"]) == (4.0, 6.0),
          "and it is the 4 -> 6 change, not the fabricated 2 -> 4")
    hist = report["canonical_history"]
    check((hist["completed_observation_count"], hist["healthy_membership_count"],
           hist["suspicious_observation_count"]) == (4, 3, 1),
          "the report separates completed observations from healthy membership")
    check(hist["suspicious_run_seqs"] == [2], "and names which run_seq broke continuity")


def t_suspicious_gap_candidate_carries_only_the_real_detection():
    report = plan(suspicious_gap_runs(), suspicious_gap_membership(), before=R3, after=R4)
    check(report["canonical_candidate_count"] == 1, "one canonical candidate")
    cand = report["anchored_candidates"][0]
    check(cand["detection_count"] == 1, "the anchored candidate carries ONE detection")
    check(cand["run_pairs"] == [f"{R3} -> {R4}"],
          "and it is R3 -> R4; no fabricated R1 -> R3 evidence is inside it")
    check(cand["basis_run_id"] == R4, "basis is the final detection's after-run")


def t_unchanged_across_a_suspicious_gap_emits_nothing():
    """healthy R1 vol 2 / suspicious R2 / healthy R3 vol 2 => zero event.

    Continuity is NOT inferred just because position 101 reappears after the gap.
    """
    report = plan(suspicious_gap_runs(), suspicious_gap_membership(v1=2.0, v3=2.0, v4=2.0),
                  before=R3, after=R4)
    check(report["detection_count"] == 0,
          "an unchanged position across a suspicious gap produces no event at all")
    check(report["canonical_candidate_count"] == 0, "and therefore no candidate")


def t_new_position_after_a_suspicious_gap_is_not_a_delta():
    """R1 holds 101; R2 suspicious; R3 holds 101 AND 102. R1 -> R3 would call 102 NEW and
    would also diff 101 — both are fabricated. R3 is a baseline, so nothing is emitted."""
    mem = suspicious_gap_membership(v1=2.0, v3=9.0, v4=9.0)
    mem[R3] = [pos(R3, 101, volume=9.0), pos(R3, 102, volume=1.0)]
    mem[R4] = [pos(R4, 101, volume=9.0), pos(R4, 102, volume=1.0)]
    report = plan(suspicious_gap_runs(), mem, before=R3, after=R4)
    check(report["detection_count"] == 0,
          "a fresh baseline after a suspicious gap emits nothing, however different it looks")


def t_disappearance_is_not_fabricated_across_a_suspicious_gap():
    """The nightmare case: if the suspicious run were treated as an EMPTY membership, R1 -> R2
    would emit POSITION_DISAPPEARED for a position that was open the whole time."""
    report = plan(suspicious_gap_runs(), suspicious_gap_membership(), before=R3, after=R4)
    kinds = {d["event_type"] for d in report["detections"]}
    check("POSITION_DISAPPEARED" not in kinds,
          "no DISAPPEARED is manufactured from the suspicious observation")


def t_membership_for_a_suspicious_run_is_refused():
    """An empty list means 'we looked and the account was flat'. A suspicious run never
    licenses that claim, so supplying one is refused rather than quietly ignored."""
    for supplied in ([], [pos(R2, 101, volume=3.0)]):
        mem = suspicious_gap_membership()
        mem[R2] = supplied
        msg = boom(lambda m=mem: plan(suspicious_gap_runs(), m, before=R3, after=R4))
        check(msg is not None and "suspicious observation" in msg,
              f"membership {supplied!r} for a suspicious run is refused")


def t_anchor_spanning_a_suspicious_run_is_refused():
    """R1 -> R3 are the adjacent HEALTHY runs, but R2 sits between them as a completed
    observation. The pair is not a delta and must not be blessed."""
    msg = boom(lambda: plan(suspicious_gap_runs(), suspicious_gap_membership(),
                            before=R1, after=R3), w.RunPairError)
    check(msg is not None and "suspicious" in msg.lower(),
          "an anchor spanning a suspicious run is refused, naming the break")
    check(msg is not None and "2 (suspicious)" in msg,
          "and the refusal names the run_seq and health that broke it")


def t_started_run_in_the_gap_is_not_an_observation():
    """'started' / 'failed' are non-authoritative attempts: no gap, and not in the history."""
    runs = [run(R1), run(R2, status="started", health=None, completed=None), run(R3), run(R4)]
    obs = w.completed_observations_as_of(runs, now=NOW_CLOSED)
    check([r["id"] for r in obs] == [R1, R3, R4],
          "a started attempt is not a completed observation")
    report = plan(runs, {R1: [pos(R1, 101, volume=2.0)], R3: [pos(R3, 101, volume=4.0)],
                         R4: [pos(R4, 101, volume=6.0)]}, before=R3, after=R4)
    check(report["detection_count"] == 2,
          "R1 -> R3 IS a delta when the run between them never completed — no gap was created")
    check(report["canonical_history"]["suspicious_observation_count"] == 0,
          "and no suspicious observation is reported")


def t_canonical_repro_extends_into_the_quiet_window():
    """The order's second half: add healthy R5 vol 8 inside R4's quiet window.

    The anchored candidate must grow to R3 -> R4 AND R4 -> R5, and STILL never contain
    R1 -> R3.
    """
    runs = suspicious_gap_runs(run(R5))
    mem = suspicious_gap_membership()
    mem[R5] = [pos(R5, 101, volume=8.0)]
    report = plan(runs, mem, before=R3, after=R4)
    check(pairs_of(report["detections"]) == [(R3, R4), (R4, R5)],
          "exactly two detections: R3 -> R4 and R4 -> R5")
    check((R1, R3) not in pairs_of(report["detections"]),
          "the suspicious gap is STILL not bridged once later runs arrive")
    check(report["anchored_candidate_count"] == 1, "one anchored candidate")
    cand = report["anchored_candidates"][0]
    check(cand["run_pairs"] == [f"{R3} -> {R4}", f"{R4} -> {R5}"],
          "the anchored candidate carries both real pairs")
    check(cand["event_sequence"] == ["POSITION_INCREASE", "POSITION_INCREASE"],
          "4 -> 6 -> 8, both increases")
    check(cand["extends_beyond_anchor"] is True,
          "and it is reported as extending beyond the anchor pair")
    check(cand["basis_run_id"] == R5, "basis advances to the latest detection's after-run")


def t_suspicious_gap_survives_the_real_adapter():
    """The corrected projection must still satisfy the APPROVED adapter, not just our shapes."""
    runs = suspicious_gap_runs(run(R5))
    mem = suspicious_gap_membership()
    mem[R5] = [pos(R5, 101, volume=8.0)]
    report = plan(runs, mem, before=R3, after=R4)
    check(len(report["rpc_requests"]) == 1, "the closed candidate builds one RPC request")
    cand = report["rpc_requests"][0]["p_candidate"]
    check(len(cand["detections"]) == 2, "the payload carries both detections")
    check(cand["basis_run_id"] == R5, "and the adapter's basis matches")
    refs = {(r["before_run_id"], r["after_run_id"]) for r in cand["run_references"]}
    check((R1, R3) not in refs, "no fabricated pair reaches the wire payload")


# ---------------------------------------------------------------------------------------------
# CONTENT-RANGE: page coordinates must be proven, not just the total
# ---------------------------------------------------------------------------------------------
def t_content_range_is_parsed_completely():
    parse = w.EvidenceReader.parse_content_range
    check(parse({"Content-Range": "0-9/100"}, table=w.POSITIONS) == (0, 9, 100),
          "a page range parses to (start, end, total)")
    check(parse({"Content-Range": "*/0"}, table=w.POSITIONS) == (None, None, 0),
          "the zero-result form parses to a null range with an exact total")
    check(parse({"Content-Range": "*/7"}, table=w.POSITIONS) == (None, None, 7),
          "a '*' range is parsed, not guessed at")
    for bad in ("0-/5", "-0/5", "0/5", "a-b/5", "0-0/", "0-0/*"):
        msg = boom(lambda b=bad: parse({"Content-Range": b}, table=w.POSITIONS),
                   w.IncompleteReadError)
        check(msg is not None, f"malformed Content-Range {bad!r} is refused by the parser")


def t_repeated_page_coordinates_are_rejected():
    """THE CODEX REPRO. Page 2 is requested at offset 1 but the server replays '0-0/2'.

    The old reader accepted both bodies and returned row 0 twice as a complete two-row set.
    """
    reader = fake_reader([
        ([{"a": "row-0"}], {"Content-Range": "0-0/2"}),
        ([{"a": "row-0"}], {"Content-Range": "0-0/2"}),
    ])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "REPEATED" in msg,
          "a page that replays the previous coordinates is refused, not assembled")
    check([p[1] for p in reader._seen] == [0, 1],
          "and the second page really was requested at offset 1")


def t_returned_start_ahead_of_the_requested_offset_is_rejected():
    reader = fake_reader([
        ([{"a": 1}], {"Content-Range": "0-0/3"}),
        ([{"a": 3}], {"Content-Range": "2-2/3"}),      # row 1 silently skipped
    ])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "starting at 1" in msg,
          "a page that starts past the requested offset would skip rows: refused")


def t_returned_end_past_the_requested_bound_is_rejected():
    reader = fake_reader([([{"a": 1}], {"Content-Range": f"0-{w.PAGE_SIZE + 5}/9999"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "past the requested bound" in msg,
          "an end beyond the requested page bound is refused")


def t_coordinate_span_larger_than_the_body_is_rejected():
    reader = fake_reader([([{"a": 1}], {"Content-Range": "0-1/5"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "coordinates and cardinality disagree" in msg,
          "coordinates promising 2 rows with 1 in the body is refused")


def t_body_larger_than_the_coordinate_span_is_rejected():
    reader = fake_reader([([{"a": 1}, {"a": 2}], {"Content-Range": "0-0/5"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "coordinates and cardinality disagree" in msg,
          "a body larger than the coordinate span is refused")


def t_zero_total_with_a_non_empty_body_is_rejected():
    reader = fake_reader([([{"a": 1}], {"Content-Range": "*/0"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "carried 1 row" in msg,
          "an exact total of 0 with rows in the body is contradictory and refused")


def t_zero_total_with_a_coordinate_range_is_rejected():
    reader = fake_reader([([], {"Content-Range": "0-0/0"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "claims rows 0-0" in msg,
          "an exact total of 0 that still claims a row range is refused")


def t_star_range_with_a_non_zero_total_is_rejected():
    reader = fake_reader([([], {"Content-Range": "*/5"})])
    msg = boom(lambda: reader._get_all(w.POSITIONS, "?order=id.asc"), w.IncompleteReadError)
    check(msg is not None and "returned no range while promising 5" in msg,
          "'*/5' with an empty body cannot prove a 5-row read: refused")


def t_next_offset_comes_from_the_returned_end():
    """Variable page sizes: the next request must start at END + 1, from the header."""
    reader = fake_reader([
        ([{"a": 0}, {"a": 1}, {"a": 2}], {"Content-Range": "0-2/5"}),
        ([{"a": 3}, {"a": 4}], {"Content-Range": "3-4/5"}),
    ])
    rows = reader._get_all(w.POSITIONS, "?order=id.asc")
    check(len(rows) == 5, "a five-row set assembled from two unequal pages")
    check([p[1] for p in reader._seen] == [0, 3],
          "the second page was requested at END+1 = 3, taken from the header")


def t_capture_count_transfers_at_most_one_row():
    def counting_reader(rows, header):
        reader = w.EvidenceReader.__new__(w.EvidenceReader)
        reader._get = lambda table, query, *, first=None, last=None: (rows, header)
        return reader

    check(counting_reader([], {"Content-Range": "*/0"}).capture_event_count(user_id=UID) == 0,
          "an empty account counts 0 from '*/0' with no body")
    check(counting_reader([{"id": "x"}], {"Content-Range": "0-0/5"})
          .capture_event_count(user_id=UID) == 5,
          "a non-empty account counts 5 while transferring exactly one id row")
    msg = boom(lambda: counting_reader([], {"Content-Range": "0-0/5"})
               .capture_event_count(user_id=UID), w.IncompleteReadError)
    check(msg is not None, "a claimed row 0 with an empty body is refused")
    msg = boom(lambda: counting_reader([{"id": "x"}, {"id": "y"}], {"Content-Range": "0-0/5"})
               .capture_event_count(user_id=UID), w.IncompleteReadError)
    check(msg is not None, "more than one row from a rows 0-0 read is refused")
    msg = boom(lambda: counting_reader([], {"Content-Range": "*/5"})
               .capture_event_count(user_id=UID), w.IncompleteReadError)
    check(msg is not None, "'*/5' for a rows 0-0 count read is refused")
    # A well-formed page that is simply NOT the one asked for: one row, coherent
    # coordinates, wrong offset. Only the (start, end) == (0, 0) check catches this.
    msg = boom(lambda: counting_reader([{"id": "x"}], {"Content-Range": "1-1/5"})
               .capture_event_count(user_id=UID), w.IncompleteReadError)
    check(msg is not None and "did not answer the page that was asked for" in msg,
          "a coherent page at the WRONG offset is refused, not counted")


# ---------------------------------------------------------------------------------------------
# SNAPSHOT_STATUS DOMAIN — validated before anything is filtered
# ---------------------------------------------------------------------------------------------
def t_status_domain_is_the_frozen_vocabulary():
    check(w.STATUSES == t1.STATUSES,
          "the harness reuses T1's frozen status domain rather than restating it")
    check(tuple(w.STATUSES) == ("started", "complete", "failed"),
          "and that domain is exactly started/complete/failed")


def t_every_frozen_status_is_accepted():
    for status in ("started", "complete", "failed"):
        r = run(R1, status=status, health="healthy")
        check(w.snapshot_status_of(r) == status, f"status {status!r} is accepted verbatim")
    check(w.is_completed(run(R1, status="complete")) is True, "'complete' IS an observation")
    for status in ("started", "failed"):
        check(w.is_completed(run(R1, status=status)) is False,
              f"{status!r} is a recognised NON-authoritative attempt, not an observation")


def t_status_outside_the_domain_is_refused():
    """Unknown, empty, missing, None, int, bool, list, dict, and case/whitespace variants.

    Every one must raise the harness's OWN error type — not a KeyError, TypeError or
    AttributeError leaking out of a comparison.
    """
    for bad in ("mystery", "", None, 123, True, [], {}, "Complete", " complete ", "COMPLETE",
                "complete ", 0, 1.0, ("complete",)):
        r = run(R1)
        r["snapshot_status"] = bad
        msg = boom(lambda x=r: w.snapshot_status_of(x))
        check(msg is not None, f"snapshot_status {bad!r} is refused with the harness's error")
        check(msg is not None and "frozen domain" in msg,
              f"...and the refusal names the frozen domain for {bad!r}")
    missing = run(R1)
    del missing["snapshot_status"]
    msg = boom(lambda: w.snapshot_status_of(missing))
    check(msg is not None and "no snapshot_status key" in msg,
          "a MISSING key is refused distinctly from a None value")
    none_msg = boom(lambda: w.snapshot_status_of({**run(R1), "snapshot_status": None}))
    check(none_msg is not None and "frozen domain" in none_msg,
          "and None is refused as an out-of-domain value, not as a missing key")


def t_unknown_status_is_never_filtered_out_of_the_history():
    """`is_completed` answering False for a mystery status IS the bug: False means 'not an
    observation', which is how a malformed run would silently take its gap away with it."""
    bad = run(R2)
    bad["snapshot_status"] = "mystery"
    msg = boom(lambda: w.is_completed(bad))
    check(msg is not None, "is_completed refuses a mystery status instead of answering False")
    msg = boom(lambda: w.completed_observations_as_of([run(R1), bad, run(R3)], now=NOW_CLOSED))
    check(msg is not None and "frozen domain" in msg,
          "the as-of history refuses the set rather than dropping the mystery run")


def t_unknown_status_repro_refuses_the_whole_plan():
    """THE CODEX REPRO. R1 complete healthy / R2 status='mystery' / R3 complete healthy.

    Without the guard, R2 vanishes and R1 -> R3 is compared as adjacent.
    """
    mem = {R1: [pos(R1, 101, volume=2.0)], R2: [], R3: [pos(R3, 101, volume=4.0)]}
    good = [run(R1), run(R2), run(R3)]
    mystery = run(R2)
    mystery["snapshot_status"] = "mystery"
    runs = [run(R1), mystery, run(R3)]

    msg = boom(lambda: plan(runs, mem, before=R1, after=R2))
    check(msg is not None and "frozen domain" in msg,
          "the planner REFUSES the whole set when any run's status is outside the domain")
    check(msg is not None and "mystery" in msg, "and the refusal names the offending value")
    for anchor in ((R1, R2), (R2, R3)):
        m = boom(lambda a=anchor: plan(runs, mem, before=a[0], after=a[1]))
        check(m is not None, f"anchor {anchor} is refused too — no anchor rescues the set")
    # BOTH layers of the guard, proven by this SAME reproduction: the whole-set validator
    # the planner runs first, and the per-run funnel every filter goes through. Removing
    # either one alone must make this reproduction fail.
    check(boom(lambda: w.completed_observations_as_of(runs, now=NOW_CLOSED)) is not None,
          "the as-of filter refuses the mystery run rather than dropping it")
    check(boom(lambda: w.is_completed(mystery)) is not None,
          "and is_completed refuses it rather than answering False")
    # Discriminating: the SAME shape with a legal status plans normally, so the refusal is
    # caused by the status domain and by nothing else in the fixture.
    rep = plan(good, mem, before=R1, after=R2)
    check(rep["detection_count"] >= 0, "the same shape with legal statuses does plan")
    check("rpc_requests" in rep, "...and produces a report, which the mystery set never did")


def t_status_is_validated_before_scope_filtering_and_adjacency():
    """A run that is BOTH out-of-domain and non-adjacent must still be caught — the point is
    that no filter ever runs on an unvalidated status."""
    mystery = run(R2)
    mystery["snapshot_status"] = "mystery"
    msg = boom(lambda: plan([run(R1), mystery, run(R3)],
                            {R1: [], R3: []}, before=R1, after=R3))
    check(msg is not None and "frozen domain" in msg,
          "the status domain is proven before adjacency gets a chance to 'pass'")


def t_whole_set_status_domain_is_proven_before_the_anchor():
    """The domain is validated BEFORE anchor validation, not as a side effect of it.

    Here the anchor is independently broken (both sides name the same run). Without the
    up-front whole-set validation, validate_run_pair() refuses the PAIR and the mystery run is
    never looked at; with it, the malformed evidence wins, which is the correct precedence.
    """
    mystery = run(R3)
    mystery["snapshot_status"] = "mystery"
    runs = [run(R1), run(R2), mystery]
    msg = boom(lambda: plan(runs, {R1: [], R2: []}, before=R1, after=R1))
    check(msg is not None and "frozen domain" in msg,
          "a malformed status outranks a broken anchor: the evidence set is judged first")
    check(msg is not None and "same run" not in msg,
          "and the anchor-shape refusal never gets to speak for a malformed set")
    # Same fixture, legal status: NOW the anchor problem is the one reported.
    ok = boom(lambda: plan([run(R1), run(R2), run(R3)], {R1: [], R2: [], R3: []},
                           before=R1, after=R1), w.RunPairError)
    check(ok is not None and "same run" in ok,
          "with every status legal, the anchor-shape refusal is what surfaces")


def t_validate_run_pair_reads_status_through_the_funnel():
    """One function must not treat a mystery status as malformed input for its between-scan
    and merely 'not complete' for its anchor rows."""
    mystery = run(R2)
    mystery["snapshot_status"] = "mystery"
    msg = boom(lambda: w.validate_run_pair([run(R1), mystery], user_id=UID,
                                           source_account=ACCT,
                                           before_run_id=R1, after_run_id=R2))
    check(msg is not None and "frozen domain" in msg,
          "a malformed ANCHOR status is a DOMAIN refusal, not a 'not complete' refusal")
    msg2 = boom(lambda: w.validate_run_pair([run(R1), run(R2, status="started")],
                                            user_id=UID, source_account=ACCT,
                                            before_run_id=R1, after_run_id=R2),
                w.RunPairError)
    check(msg2 is not None and "not 'complete'" in msg2,
          "while a LEGAL 'started' anchor is still refused as a pair problem, as before")


# ---------------------------------------------------------------------------------------------
# SCOPE — every loaded run, not just the anchor pair
# ---------------------------------------------------------------------------------------------
def t_scope_accepts_a_uniform_set():
    runs = [run(R1), run(R2), run(R3)]
    check(w.validate_scope(runs, user_id=UID, source_account=ACCT) is runs,
          "a set entirely inside the requested scope is accepted unchanged")


def t_foreign_user_run_refuses_the_set():
    runs = [run(R1), run(R2), run(R3, user=OTHER_UID)]
    msg = boom(lambda: w.validate_scope(runs, user_id=UID, source_account=ACCT))
    check(msg is not None and "user_id" in msg, "a foreign user_id refuses the whole set")
    check(msg is not None and OTHER_UID not in msg,
          "and the refusal does NOT echo the other user's identifier")


def t_foreign_account_run_refuses_the_set():
    runs = [run(R1), run(R2), run(R3, acct=OTHER_ACCT)]
    msg = boom(lambda: w.validate_scope(runs, user_id=UID, source_account=ACCT))
    check(msg is not None and "source_account" in msg,
          "a foreign source_account refuses the whole set")
    check(msg is not None and "normalised" in msg,
          "and says accounts are never normalised to match")


def t_account_is_opaque_text_never_coerced():
    """'0301102520' and 301102520 are DIFFERENT accounts from '301102520'."""
    for foreign in (OTHER_ACCT, 301102520, " 301102520", "301102520 "):
        runs = [run(R1), run(R2, acct=foreign)]
        msg = boom(lambda r=runs: w.validate_scope(r, user_id=UID, source_account=ACCT))
        check(msg is not None, f"account {foreign!r} is not coerced into the requested scope")


def t_user_id_case_variant_is_not_normalised():
    runs = [run(R1), run(R2, user=UID.upper())]
    msg = boom(lambda: w.validate_scope(runs, user_id=UID, source_account=ACCT))
    check(msg is not None and "user_id" in msg,
          "an upper-case spelling of the same uuid is a different value, never normalised")
    msg = boom(lambda: w.validate_scope([run(R1)], user_id=UID.upper(), source_account=ACCT))
    check(msg is not None and "canonical" in msg,
          "and a non-canonical REQUESTED user_id is refused by the existing uuid policy")


def t_foreign_run_is_refused_wherever_it_sits():
    """Before, between and after the anchor — each must reject, never silently disappear.

    The 'between' case also proves ORDERING: the same layout with a same-scope run raises the
    ADJACENCY error, so a scope error there means scope was checked first.
    """
    anchor_runs = [run(R1, seq=10), run(R2, seq=20)]
    mem = {R1: [], R2: []}
    for label, foreign in (("before", run(R3, seq=5, user=OTHER_UID)),
                           ("between", run(R3, seq=15, user=OTHER_UID)),
                           ("after", run(R3, seq=25, user=OTHER_UID))):
        msg = boom(lambda f=foreign: plan(anchor_runs + [f], mem, before=R1, after=R2))
        check(msg is not None and "user_id" in msg,
              f"a foreign run sitting {label} the anchor refuses the plan")
    same_scope_between = run(R3, seq=15)
    msg = boom(lambda: plan(anchor_runs + [same_scope_between], {R1: [], R2: [], R3: []},
                            before=R1, after=R2), w.RunPairError)
    check(msg is not None and "sit between" in msg,
          "the identical layout in-scope fails on ADJACENCY — so scope is proven first")


def t_cross_user_repro_refuses_the_whole_plan():
    """THE CODEX REPRO. User A's anchor is unchanged; user B's pair changes volume.

    Without the guard the report claims user A's scope while carrying user B's detection.
    """
    a_runs = [run(R1), run(R2)]
    a_mem = {R1: [pos(R1, 101, volume=2.0)], R2: [pos(R2, 101, volume=2.0)]}
    b_runs = [run(B1, user=OTHER_UID), run(B2, user=OTHER_UID)]
    b_mem = {B1: [pos(B1, 909, volume=1.0, user=OTHER_UID)],
             B2: [pos(B2, 909, volume=7.0, user=OTHER_UID)]}

    clean = plan(a_runs, a_mem, before=R1, after=R2)
    check(clean["detection_count"] == 0, "user A alone: an unchanged anchor detects nothing")

    msg = boom(lambda: plan(a_runs + b_runs, {**a_mem, **b_mem}, before=R1, after=R2))
    check(msg is not None and "user_id" in msg,
          "adding user B's changing pair REFUSES the whole plan")
    check(msg is not None and "909" not in msg,
          "and no user-B position reaches the output")
    check(msg is not None and OTHER_UID not in msg,
          "and no user-B identifier reaches the output")


def t_foreign_scope_cannot_reach_membership_loading():
    """main() derives membership run_ids from the observation history, so a foreign run that
    survived scope validation would also be handed to the membership query."""
    runs = [run(R1), run(R2), run(B2, user=OTHER_UID)]
    msg = boom(lambda: w.validate_scope(runs, user_id=UID, source_account=ACCT))
    check(msg is not None, "the foreign run is refused before any membership id list is built")
    obs = w.completed_observations_as_of([run(R1), run(R2)], now=NOW_CLOSED)
    check(w.healthy_membership_run_ids(obs) == [R1, R2],
          "and the in-scope history still yields exactly its own run ids")


def t_reader_refuses_a_returned_row_outside_scope():
    """Defence in depth: the query filters on user/account, but the response is checked too."""
    reader = w.EvidenceReader.__new__(w.EvidenceReader)
    reader._get_all = lambda table, query: [
        {"id": R1, "user_id": UID, "source_account": ACCT},
        {"id": R2, "user_id": OTHER_UID, "source_account": ACCT},
    ]
    msg = boom(lambda: reader.runs_in_scope(user_id=UID, source_account=ACCT))
    check(msg is not None and "outside the requested scope" in msg,
          "a returned run outside the requested scope is refused at the reader")
    reader._get_all = lambda table, query: [
        {"id": R1, "user_id": UID, "source_account": OTHER_ACCT}]
    msg = boom(lambda: reader.runs_in_scope(user_id=UID, source_account=ACCT))
    check(msg is not None and "outside the requested scope" in msg,
          "a returned run on another account is refused at the reader too")
    reader._get_all = lambda table, query: [
        {"id": R1, "user_id": UID, "source_account": ACCT}]
    check(len(reader.runs_in_scope(user_id=UID, source_account=ACCT)) == 1,
          "an in-scope response is returned unchanged")


def t_membership_reader_refuses_a_foreign_scope_row():
    reader = w.EvidenceReader.__new__(w.EvidenceReader)
    reader._get_all = lambda table, query: [
        {"run_id": R1, "user_id": OTHER_UID, "source_account": ACCT, "position_id": 1}]
    msg = boom(lambda: reader.memberships_for(user_id=UID, source_account=ACCT,
                                              run_ids=[R1, R2]))
    check(msg is not None and "outside the requested scope" in msg,
          "a membership row for the right run but the wrong user is refused by the READER")
    reader._get_all = lambda table, query: [
        {"run_id": R1, "user_id": UID, "source_account": OTHER_ACCT, "position_id": 1}]
    msg = boom(lambda: reader.memberships_for(user_id=UID, source_account=ACCT,
                                              run_ids=[R1, R2]))
    check(msg is not None and "outside the requested scope" in msg,
          "and one for the wrong account is refused with the reader's own error type")


def t_scope_and_status_hold_together_with_the_suspicious_gap():
    """All three closed fixes at once: in-scope, legal statuses, suspicious run still breaks
    continuity."""
    report = plan(suspicious_gap_runs(), suspicious_gap_membership(), before=R3, after=R4)
    check(report["detection_count"] == 1, "still exactly one detection across the gap")
    check(pairs_of(report["detections"]) == [(R3, R4)], "still only R3 -> R4")
    check(report["canonical_history"]["suspicious_observation_count"] == 1,
          "the suspicious run is still an observation with a legal 'complete' status")
    check(w.snapshot_status_of(run(R2, health="suspicious")) == "complete",
          "suspicious is a HEALTH, never a status — the two stay separate")


# ---------------------------------------------------------------------------------------------
# adapter output stays the approved one
# ---------------------------------------------------------------------------------------------
def t_rpc_request_is_the_approved_shape():
    runs, mem = two_run([], [pos(R2, 101, volume=4.0)])
    req = plan(runs, mem)["rpc_requests"][0]
    check(set(req) == {"p_user", "p_account", "p_candidate"},
          "request is exactly the approved argument set")
    payload = req["p_candidate"]
    check(tuple(sorted(payload)) == tuple(sorted(t2a.PAYLOAD_KEYS)),
          "payload key set is exactly t2_capture_adapter.PAYLOAD_KEYS")
    check(payload["domain"] == t2a.CAPTURE_DOMAIN, "payload carries the approved domain tag")
    check(payload["detector_version"] == t2a.DETECTOR_VERSION
          and payload["aggregator_version"] == t2a.AGGREGATOR_VERSION,
          "payload carries the approved producer versions")
    check(req["p_user"] == UID and req["p_account"] == ACCT,
          "scope arguments come from the payload, not from the CLI separately")
    for absent in ("id", "created_at", "event_key", "payload_fingerprint"):
        check(absent not in payload, f"{absent} is server-derived and absent from the request")


def t_multi_detection_request_carries_both_detections():
    runs, mem = three_run_growing()
    payload = plan(runs, mem, before=R1, after=R2)["rpc_requests"][0]["p_candidate"]
    check(len(payload["detections"]) == 2,
          "the approved adapter accepted a TWO-detection canonical candidate")
    check(len(payload["detection_identities"]) == 2
          and len(payload["event_types"]) == 2
          and len(payload["run_references"]) == 2,
          "all provenance arrays line up at length 2")
    check(payload["basis_run_id"] == R3,
          "basis_run_id is the final detection's after_run_id")


def t_no_account_facts_or_decision_state():
    runs, mem = two_run([pos(R1, 101, volume=2.0)], [pos(R2, 101, volume=4.0)])
    payload = plan(runs, mem)["rpc_requests"][0]["p_candidate"]
    check(t2a._forbidden_key_in(payload) is None,
          "no decision-state or account-money key at any depth")
    blob = json.dumps(payload).lower()
    for token in t2a.FORBIDDEN_PAYLOAD_TOKENS:
        check(token not in blob, f"forbidden token {token!r} absent from the payload")


def t_inputs_are_not_mutated():
    runs, mem = three_run_growing()
    runs_before, mem_before = copy.deepcopy(runs), copy.deepcopy(mem)
    plan(runs, mem, before=R1, after=R2)
    check(runs == runs_before and mem == mem_before,
          "plan_capture does not mutate the loaded evidence")


def t_duplicate_dry_run_is_identical():
    runs, mem = three_run_growing()
    first = plan(runs, mem, before=R1, after=R2)
    second = plan(runs, mem, before=R1, after=R2)
    check(first == second, "running the dry run twice yields an identical report")
    check(t2a.canonical_payload_json(first["rpc_requests"][0]["p_candidate"])
          == t2a.canonical_payload_json(second["rpc_requests"][0]["p_candidate"]),
          "the payload is byte-identical across runs — a replay would collide, not duplicate")


# ---------------------------------------------------------------------------------------------
# safety boundary
# ---------------------------------------------------------------------------------------------
def t_dry_run_is_the_default():
    check(w.arming_status(persist=False, confirm=None, write_env=None) == ("dry-run", None),
          "no flag at all means dry run")
    check(w.arming_status(persist=False, confirm=w.CONFIRM_PERSIST,
                          write_env="1")[0] == "dry-run",
          "arming keys without --persist still means dry run")


def t_phase_gate_is_open_and_still_restorable():
    """The phase is now deliberately OPEN for the reviewed canary — and closing it again must
    still shut the whole path structurally, so the constant stays a real kill switch."""
    check(w.PERSIST_ENABLED_IN_THIS_PHASE is True, "the phase gate is open for the canary")
    check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST, write_env="1")
          == ("armed", None),
          "fully armed now reaches 'armed' instead of the phase refusal")
    original = w.PERSIST_ENABLED_IN_THIS_PHASE
    w.PERSIST_ENABLED_IN_THIS_PHASE = False
    try:
        mode, reason = w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST, write_env="1")
        check(mode == "stop", "re-closing the phase refuses even a fully-armed persist")
        check(reason is not None and "PERSIST_ENABLED_IN_THIS_PHASE" in reason,
              "and the refusal names the phase gate")
        msg = boom(lambda: w.CaptureAppendClient("https://example.invalid", "k"))
        check(msg is not None and "disabled in this phase" in msg,
              "and the append client refuses construction again")
    finally:
        w.PERSIST_ENABLED_IN_THIS_PHASE = original
    check(w.PERSIST_ENABLED_IN_THIS_PHASE is True, "the phase gate is restored to open")


def t_persist_arming_requires_every_key():
    """Every arming key is still load-bearing with the phase open — no bypass appeared."""
    check(w.arming_status(persist=True, confirm=None, write_env="1")[0] == "stop",
          "persist without --confirm refused")
    check(w.arming_status(persist=True, confirm="nope", write_env="1")[0] == "stop",
          "persist with the wrong --confirm literal refused")
    check(w.arming_status(persist=True, confirm=" PERSIST-CAPTURE-EVENTS", write_env="1")[0]
          == "stop", "a whitespace-mutated confirm literal is refused, not trimmed")
    check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST, write_env=None)[0]
          == "stop", f"persist without {w.WRITE_ENV}=1 refused")
    check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST, write_env="0")[0]
          == "stop", f"persist with {w.WRITE_ENV}=0 refused")
    check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST, write_env="true")[0]
          == "stop", f"persist with {w.WRITE_ENV}=true refused — '1' exactly")
    check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST, write_env="1")[0]
          == "armed", "all three keys together arm it — so the checks above are load-bearing")


def t_reader_has_no_write_surface():
    names = [n for n in dir(w.EvidenceReader) if not n.startswith("__")]
    for banned in ("insert", "update", "delete", "patch", "post", "rpc", "append", "upsert"):
        check(not any(banned in n.lower() for n in names),
              f"EvidenceReader exposes no {banned}-like method (has: {names})")
    src = inspect.getsource(w.EvidenceReader)
    for verb in ('"POST"', '"PATCH"', '"DELETE"', '"PUT"'):
        check(verb not in src, f"EvidenceReader never names the {verb} verb")
    check('method="GET"' in src, "EvidenceReader issues GET, and only GET")


def t_read_allowlist_is_enforced():
    for table in ("mt5_import_staging", "trades", "mt5_schema_migrations"):
        msg = boom(lambda t=table: w.EvidenceReader._assert_table(t))
        check(msg is not None and "read allowlist" in msg,
              f"table {table!r} is refused by the read allowlist")
    for table in (w.RUNS, w.POSITIONS, w.CAPTURE_EVENTS):
        check(boom(lambda t=table: w.EvidenceReader._assert_table(t)) is None,
              f"table {table!r} is allowed")
    check(w.ALLOWED_RPCS == frozenset({w.RPC_APPEND_CAPTURE}),
          "exactly one RPC is ever nameable")


def t_staging_is_never_consulted():
    src = inspect.getsource(w.EvidenceReader) + inspect.getsource(w.plan_capture)
    check("position_state" not in src,
          "the mutable staging annotation is never read as history")
    check("mt5_import_staging" not in src, "staging is never named in the read path")


def t_canonical_uuid_is_reused_not_restated():
    check(boom(lambda: w.canonical_uuid_or_raise(R1, field="--x")) is None,
          "a canonical uuid passes")
    for bad in (R1.upper(), "{" + R1 + "}", R1.replace("-", ""), "nope", None, 12):
        msg = boom(lambda b=bad: w.canonical_uuid_or_raise(b, field="--x"))
        check(msg is not None and "refused rather than normalised" in msg,
              f"non-canonical uuid {bad!r} refused, never rewritten")


def t_instants_must_carry_an_offset():
    check(w.parse_instant("2026-08-22T12:30:00Z").isoformat() == "2026-08-22T12:30:00+00:00",
          "the Z spelling parses to UTC")
    for bad in ("2026-08-22T12:30:00", "not a date", "", None, 17):
        msg = boom(lambda b=bad: w.parse_instant(b))
        check(msg is not None, f"instant {bad!r} refused")


# ---------------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------------------
# PERSIST TARGETING — exactly one named candidate may ever reach the RPC
# ---------------------------------------------------------------------------------------------
def two_position_plan(window=QW):
    """Two NEW_POSITION candidates from one anchor pair — both closed, both anchored,
    both eligible. The canary's real shape (312261388 / 312265597), in fixture form."""
    runs = [run(R1), run(R2)]
    mem = {R1: [], R2: [pos(R2, 101, volume=5.0), pos(R2, 202, volume=5.0)]}
    return plan(runs, mem, window=window)


def production_plan():
    """The same two-candidate shape, coalesced at the FROZEN production window — the only
    window a write capability can exist for."""
    return two_position_plan(window=w.PRODUCTION_QUIET_WINDOW_SECONDS)


def armed_capability(position_id=101, rep=None):
    """A genuinely minted capability, through the one supported path."""
    if rep is None:
        rep = production_plan()
    cap = w.prepare_selected_persist(
        rep, position_id=position_id, persist=True, confirm=w.CONFIRM_PERSIST,
        write_env="1", quiet_window_seconds=w.PRODUCTION_QUIET_WINDOW_SECONDS)
    return cap, rep


def t_production_window_constant_is_the_frozen_policy():
    check(w.PRODUCTION_QUIET_WINDOW_SECONDS == 900.0,
          "the frozen v0.1 production quiet window is 900 seconds")


def t_selector_requires_a_positive_integer():
    for bad in (True, False, 0, -5, "312261388", 3.5, None, [312261388]):
        msg = boom(lambda b=bad: w.validate_position_selector(b))
        check(msg is not None, f"selector {bad!r} is refused, never coerced")
    check(w.validate_position_selector(312261388) == 312261388,
          "an exact positive integer passes through unchanged")


def t_two_eligible_candidates_and_selection_targets_exactly_one():
    rep = two_position_plan()
    check(rep["canonical_candidate_count"] == 2 and rep["closed_anchored_candidates"] == 2,
          "fixture really has TWO closed anchored eligible candidates")
    r101 = w.select_persist_request(rep, position_id=101)
    check(r101["p_candidate"]["position_id"] == 101,
          "selecting 101 yields exactly the 101 request")
    check(r101 is next(r for r in rep["rpc_requests"]
                       if r["p_candidate"]["position_id"] == 101),
          "the returned request IS the prepared adapter request, verbatim")
    r202 = w.select_persist_request(rep, position_id=202)
    check(r202["p_candidate"]["position_id"] == 202,
          "selecting 202 yields exactly the 202 request")
    check(r101 is not r202, "the two selections are different requests")
    check((r101["p_user"], r101["p_account"]) == (UID, ACCT),
          "the selected request carries the requested scope")


def t_selection_never_persists_the_unselected_candidate():
    """THE CANARY PROPERTY: with both real candidates eligible, naming one can never let the
    other's evidence reach the wire — the selected request carries NO trace of it anywhere."""
    rep = two_position_plan()
    selected = w.select_persist_request(rep, position_id=101)

    def position_ids_in(node):
        """Every position_id-valued field anywhere in the structure, recursively."""
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "position_id":
                    yield value
                yield from position_ids_in(value)
        elif isinstance(node, (list, tuple)):
            for item in node:
                yield from position_ids_in(item)

    found = set(position_ids_in(selected))
    check(found == {101},
          f"every position_id field anywhere in the selected request is the named one "
          f"(found {sorted(found)})")
    ids = selected["p_candidate"]["detection_identities"]
    check(len(ids) == 1 and ids[0][3] == 101,
          "the identity set is exactly the named candidate's single identity")
    check(all(202 not in identity for identity in ids),
          "the unselected candidate's identity appears nowhere in the wire identity set")


def t_selection_refuses_zero_matches():
    rep = two_position_plan()
    msg = boom(lambda: w.select_persist_request(rep, position_id=999))
    check(msg is not None and "no closed, anchored, eligible candidate" in msg,
          "a nonexistent target refuses the persist outright")
    check(msg is not None and "101" in msg and "202" in msg,
          "...naming the persistable positions without persisting them")
    check(msg is not None and "own explicit invocation" in msg,
          "...and saying each needs its own explicit invocation")


def t_selection_refuses_duplicate_matches():
    rep = two_position_plan()
    forged = copy.deepcopy(rep)
    forged["rpc_requests"].append(copy.deepcopy(
        next(r for r in forged["rpc_requests"] if r["p_candidate"]["position_id"] == 101)))
    msg = boom(lambda: w.select_persist_request(forged, position_id=101))
    check(msg is not None and "never chooses 'first'" in msg,
          "duplicate matching requests refuse the whole persist — 'first' is never chosen")


def t_selection_cannot_promote_an_open_candidate():
    """Before the deadline the candidates are OPEN: no rpc_request exists for them, so naming
    one refuses — while the canonical truth still SHOWS both (the selector never hides)."""
    runs = [run(R1), run(R2)]
    mem = {R1: [], R2: [pos(R2, 101, volume=5.0), pos(R2, 202, volume=5.0)]}
    rep = plan(runs, mem, now=done_at(R2) + 1.0)          # inside the window
    check(rep["canonical_candidate_count"] == 2 and rep["anchored_candidate_count"] == 2,
          "both OPEN candidates remain fully visible in the canonical truth")
    check(rep["rpc_requests"] == [], "but no request exists for an open candidate")
    msg = boom(lambda: w.select_persist_request(rep, position_id=101))
    check(msg is not None and "no closed, anchored, eligible candidate" in msg,
          "naming an open candidate cannot make it persistable")


def t_selection_cannot_reach_an_unanchored_candidate():
    """A closed canonical candidate the operator did not anchor stays out of reach even when
    named — eligible_for_this_invocation stays the write boundary."""
    runs = [run(R1), run(R2), run(R3)]
    mem = {R1: [pos(R1, 101, volume=2.0)], R2: [pos(R2, 101, volume=2.0)],
           R3: [pos(R3, 101, volume=6.0)]}
    rep = plan(runs, mem, before=R1, after=R2)            # anchor produced nothing
    check(rep["canonical_candidate_count"] == 1, "the neighbouring candidate is visible")
    check(rep["canonical_candidates"][0]["closed"] is True, "and it is CLOSED")
    msg = boom(lambda: w.select_persist_request(rep, position_id=101))
    check(msg is not None and "no closed, anchored, eligible candidate" in msg,
          "but naming it under a different anchor cannot persist it")


def t_selection_refuses_inconsistent_eligibility():
    rep = two_position_plan()
    forged = copy.deepcopy(rep)
    for c in forged["anchored_candidates"]:
        if c["position_id"] == 101:
            c["eligible_for_this_invocation"] = False
    msg = boom(lambda: w.select_persist_request(forged, position_id=101))
    check(msg is not None and "not closed+eligible" in msg,
          "a summary that disagrees with the request list refuses the persist")


def t_selection_refuses_cross_scope_request():
    rep = two_position_plan()
    forged = copy.deepcopy(rep)
    for r in forged["rpc_requests"]:
        if r["p_candidate"]["position_id"] == 101:
            r["p_user"] = OTHER_UID
    msg = boom(lambda: w.select_persist_request(forged, position_id=101))
    check(msg is not None and "requested scope" in msg,
          "a request that lost the requested scope is refused")


def t_selection_does_not_mutate_or_narrow_the_report():
    rep = two_position_plan()
    frozen = copy.deepcopy(rep)
    w.select_persist_request(rep, position_id=101)
    check(rep == frozen, "selection mutates nothing — the canonical truth is untouched")
    check(rep["canonical_candidate_count"] == 2 and rep["anchored_candidate_count"] == 2,
          "both candidates are still reported after a selection")


# ---------------------------------------------------------------------------------------------
# WRITE CAPABILITY BOUNDARY — a raw request can never reach the network
# ---------------------------------------------------------------------------------------------
EV_ID = "3f1a0000-0000-4000-8000-00000000e001"
EV_ID2 = "3f1a0000-0000-4000-8000-00000000e002"
EV_KEY = "0f" * 32                                   # canonical: 64 lowercase hex
EV_KEY2 = "e1" * 32
FP_OK = "ab" * 32


def rpc_row(*, ok=True, inserted=1, event_id=EV_ID, key=EV_KEY, error=None):
    return {"o_ok": ok, "o_inserted": inserted, "o_event_id": event_id,
            "o_event_key": key, "o_error_code": error}


class FakeAppendClient:
    """Duck-typed transport: records the capability of every send, replays scripted rows."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def append(self, capability):
        self.requests.append(capability)
        nxt = self.responses.pop(0)
        if isinstance(nxt, Exception):
            raise nxt
        return nxt


class FakeVerifyReader:
    """Post-write verification double: scripted counts and one scripted row (or exception)."""

    def __init__(self, *, counts, row):
        self.counts = list(counts)
        self.row = row
        self.count_calls = 0
        self.row_calls = 0

    def capture_event_count(self, *, user_id):
        self.count_calls += 1
        nxt = self.counts.pop(0)
        if isinstance(nxt, Exception):
            raise nxt
        return nxt

    def capture_event_by_id(self, *, user_id, event_id):
        self.row_calls += 1
        if isinstance(self.row, Exception):
            raise self.row
        return self.row


def bound_row(cap, *, event_id=EV_ID, key=EV_KEY, **overrides):
    """A read-back row correctly bound to the capability's request + the RPC result."""
    candidate = cap.request["p_candidate"]
    row = {"id": event_id, "created_at": "2026-08-24T16:07:00Z", "event_key": key,
           "payload_fingerprint": FP_OK, "user_id": cap.request["p_user"],
           "source_account": cap.request["p_account"],
           "position_id": candidate["position_id"],
           "basis_run_id": candidate["basis_run_id"],
           "quiet_window_seconds": w.PRODUCTION_QUIET_WINDOW_SECONDS}
    row.update(overrides)
    return row


def run_persist(cap, responses, *, counts, row, replay=True, count_before=0):
    client = FakeAppendClient(responses)
    reader = FakeVerifyReader(counts=counts, row=row)
    out = w.execute_selected_persist(client, reader, cap, replay_verify=replay,
                                     count_before=count_before)
    return out, client, reader


def t_append_client_refuses_raw_requests():
    """THE CODEX BYPASS REPRO: both REAL prepared requests from the two-candidate report,
    handed straight to the transport — each must be refused before any network."""
    rep = production_plan()
    request_a = next(r for r in rep["rpc_requests"] if r["p_candidate"]["position_id"] == 101)
    request_b = next(r for r in rep["rpc_requests"] if r["p_candidate"]["position_id"] == 202)
    client = w.CaptureAppendClient("https://example.invalid", "k")
    for label, raw in (("A/101", request_a), ("B/202", request_b), ("dict", {"p_user": UID})):
        msg = boom(lambda r=raw: client.append(r))
        check(msg is not None and "not a write authorization" in msg,
              f"raw request {label} cannot reach the transport")


def t_capability_mint_requires_the_internal_token():
    rep = production_plan()
    request = rep["rpc_requests"][0]
    msg = boom(lambda: w.ArmedSelectedAppend(
        request=request, position_id=request["p_candidate"]["position_id"]))
    check(msg is not None and "prepare_selected_persist" in msg,
          "a self-built capability is refused without the internal mint token")
    msg = boom(lambda: w.ArmedSelectedAppend(
        _token=object(), request=request,
        position_id=request["p_candidate"]["position_id"]))
    check(msg is not None, "a forged token object does not mint either")


def t_capability_requires_full_arming_and_the_frozen_window():
    rep = production_plan()
    for label, kwargs in (
            ("persist not requested", dict(persist=False, confirm=w.CONFIRM_PERSIST,
                                           write_env="1", quiet_window_seconds=900.0)),
            ("wrong confirm literal", dict(persist=True, confirm="nope",
                                           write_env="1", quiet_window_seconds=900.0)),
            ("missing env", dict(persist=True, confirm=w.CONFIRM_PERSIST,
                                 write_env=None, quiet_window_seconds=900.0)),
            ("env not exactly 1", dict(persist=True, confirm=w.CONFIRM_PERSIST,
                                       write_env="true", quiet_window_seconds=900.0)),
            ("non-production window", dict(persist=True, confirm=w.CONFIRM_PERSIST,
                                           write_env="1", quiet_window_seconds=300.0)),
            ("non-numeric window", dict(persist=True, confirm=w.CONFIRM_PERSIST,
                                        write_env="1", quiet_window_seconds="soon"))):
        msg = boom(lambda kw=kwargs: w.prepare_selected_persist(rep, position_id=101, **kw))
        check(msg is not None and "persist capability refused" in msg,
              f"prepare refuses to mint when {label} — arming is re-proven inside the "
              f"boundary, not only by the CLI")
    cap, _ = armed_capability()
    check(isinstance(cap, w.ArmedSelectedAppend), "fully armed + selected mints exactly one")


def t_capability_binds_exactly_one_named_request():
    cap, rep = armed_capability(101)
    check(cap.position_id == 101, "the capability names its position")
    check(cap.request is next(r for r in rep["rpc_requests"]
                              if r["p_candidate"]["position_id"] == 101),
          "the capability holds the prepared adapter request VERBATIM")

    def position_ids_in(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "position_id":
                    yield value
                yield from position_ids_in(value)
        elif isinstance(node, (list, tuple)):
            for item in node:
                yield from position_ids_in(item)

    check(set(position_ids_in(cap.request)) == {101},
          "every position_id anywhere in the capability's request is the named one — "
          "candidate 202 cannot hitchhike")
    ids = cap.request["p_candidate"]["detection_identities"]
    check(len(ids) == 1 and ids[0][3] == 101, "exactly one identity, and it is 101's")
    check(not isinstance(cap.request, list), "a capability cannot hold a LIST of requests")


def t_capability_rejects_forged_shapes():
    rep = production_plan()
    request = copy.deepcopy(next(r for r in rep["rpc_requests"]
                                 if r["p_candidate"]["position_id"] == 101))
    mismatched = copy.deepcopy(request)
    msg = boom(lambda: w.ArmedSelectedAppend(_token=w._MINT_TOKEN, request=mismatched,
                                             position_id=202))
    check(msg is not None and "does not match" in msg,
          "a capability naming 202 refuses a request built for 101")
    foreign = copy.deepcopy(request)
    foreign["p_candidate"]["detection_identities"][0] = list(
        foreign["p_candidate"]["detection_identities"][0])
    foreign["p_candidate"]["detection_identities"][0][3] = 202
    msg = boom(lambda: w.ArmedSelectedAppend(_token=w._MINT_TOKEN, request=foreign,
                                             position_id=101))
    check(msg is not None and "hitchhike" in msg,
          "an identity for another position can never ride inside a capability")
    drifted = copy.deepcopy(request)
    drifted["p_candidate"]["quiet_window_seconds"] = 300.0
    msg = boom(lambda: w.ArmedSelectedAppend(_token=w._MINT_TOKEN, request=drifted,
                                             position_id=101))
    check(msg is not None and "frozen production window" in msg,
          "a capability cannot exist for a non-production window")


def t_capability_cannot_be_reused_with_a_different_request():
    cap, _ = armed_capability(101)
    check(cap.verify_intact() is cap, "an untouched capability verifies intact")
    cap.request["p_candidate"]["position_id"] = 202          # simulated post-mint tampering
    client = w.CaptureAppendClient("https://example.invalid", "k")
    msg = boom(lambda: client.append(cap))
    check(msg is not None and "minted digest" in msg,
          "a mutated/swapped request is refused by the digest check BEFORE any network")
    msg = boom(lambda: setattr(cap, "request", {"p_user": UID}))
    check(msg is not None and "immutable" in msg,
          "the capability's own attributes cannot be reassigned")


def t_no_public_path_sends_two_candidates_in_one_invocation():
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(
        cap, [[rpc_row()], [rpc_row(inserted=0)]], counts=[1, 1], row=bound_row(cap))
    check(out["verdict"] == "INSERTED_AND_REPLAY_IDEMPOTENT", "full clean run")
    check(all(c is cap for c in client.requests),
          "every wire send carried the SAME single capability")
    positions = {c.position_id for c in client.requests}
    check(positions == {101},
          "one invocation can only ever touch the one named position — persisting 202 "
          "requires its own prepare/mint/execute with its own selector")


# ---------------------------------------------------------------------------------------------
# RPC RESULT TRUTH TABLE — full semantic coherence, not just types
# ---------------------------------------------------------------------------------------------
def t_event_key_validator_is_exact():
    check(w.canonical_event_key_or_raise(EV_KEY, field="t") == EV_KEY,
          "a canonical 64-hex key passes through unchanged")
    for bad, label in ((EV_KEY.upper(), "uppercase"), (EV_KEY[:63], "63 chars"),
                       ((EV_KEY + "0"), "65 chars"), (("g" * 64), "non-hex"),
                       ((" " + EV_KEY[1:]), "leading space"), (None, "None"),
                       (123, "int")):
        msg = boom(lambda b=bad: w.canonical_event_key_or_raise(b, field="t"))
        check(msg is not None, f"event key {label} is refused — no trim, no case folding")


def t_rpc_result_truth_table():
    ok1 = w.parse_rpc_result([rpc_row()], call_label="t")
    check(ok1["o_inserted"] == 1, "success tuple (true,1,id,key,null) accepted: fresh insert")
    ok0 = w.parse_rpc_result([rpc_row(inserted=0)], call_label="t")
    check(ok0["o_inserted"] == 0, "success tuple (true,0,id,key,null) accepted: exact replay")
    fail_plain = w.parse_rpc_result(
        [rpc_row(ok=False, inserted=0, event_id=None, key=None, error="ERR_BAD_INPUT")],
        call_label="t")
    check(fail_plain["o_error_code"] == "ERR_BAD_INPUT",
          "failure tuple with null id/key accepted (pre-insert refusals)")
    conflict = w.parse_rpc_result(
        [rpc_row(ok=False, inserted=0, error="ERR_CAPTURE_CONFLICT")], call_label="t")
    check(conflict["o_event_id"] == EV_ID,
          "conflict failure keeps the EXISTING row's canonical id/key (the SQL returns them)")
    for bad, label in (
            ([rpc_row(ok=False, inserted=1, error="ERR_X")], "ok=false inserted=1"),
            ([rpc_row(ok=False, inserted=0, error=None)], "ok=false error null"),
            ([rpc_row(ok=False, inserted=0, error="")], "ok=false error empty"),
            ([rpc_row(inserted=1, event_id=None)], "ok=true insert without id"),
            ([rpc_row(inserted=1, key=None)], "ok=true insert without key"),
            ([rpc_row(inserted=0, event_id=None)], "ok=true replay without id"),
            ([rpc_row(inserted=0, key=None)], "ok=true replay without key"),
            ([rpc_row(error="ERR_X")], "ok=true with error code"),
            ([rpc_row(key=EV_KEY.upper())], "uppercase key"),
            ([rpc_row(key=EV_KEY[:63])], "63-char key"),
            ([rpc_row(key=EV_KEY + "0")], "65-char key"),
            ([rpc_row(key="g" * 64)], "non-hex key"),
            ([rpc_row(event_id="not-a-uuid")], "malformed uuid"),
            ([rpc_row(ok=False, inserted=0, error="ERR_X", key="G" * 64)],
             "failure with malformed non-null key"),
            ([rpc_row(ok=False, inserted=0, error="ERR_X",
                      event_id="3F1A0000-0000-4000-8000-00000000E001")],
             "failure with malformed non-null id"),
            ([rpc_row(inserted=2)], "inserted=2"),
            ([rpc_row(inserted=-1, ok=False, error="ERR_X")], "inserted=-1"),
            ([rpc_row(inserted=True)], "boolean inserted"),
            ([rpc_row(ok="yes")], "non-bool ok"),
            ([{**rpc_row(), "extra": 1}], "extra column"),
            ([rpc_row(), rpc_row()], "two rows"),
            ([], "zero rows")):
        msg = boom(lambda b=bad: w.parse_rpc_result(b, call_label="t"))
        check(msg is not None, f"incoherent RPC tuple ({label}) is refused")


# ---------------------------------------------------------------------------------------------
# IDENTITY-BOUND READ-BACK — cardinality alone proves nothing
# ---------------------------------------------------------------------------------------------
def t_validate_persisted_row_binds_identity():
    cap, _ = armed_capability(101)
    rpc = rpc_row()
    good = bound_row(cap)
    check(w.validate_persisted_row(good, request=cap.request, rpc_result=rpc) is good,
          "a row bound to the request AND the RPC result is accepted")
    for label, corrupted in (
            ("row id != o_event_id", bound_row(cap, event_id=EV_ID2)),
            ("event_key != o_event_key", bound_row(cap, key=EV_KEY2)),
            ("foreign user", bound_row(cap, user_id=OTHER_UID)),
            ("foreign account", bound_row(cap, source_account=OTHER_ACCT)),
            ("account normalised", bound_row(cap, source_account=" " + ACCT)),
            ("wrong position", bound_row(cap, position_id=202)),
            ("wrong basis run", bound_row(cap, basis_run_id=R4)),
            ("wrong window", bound_row(cap, quiet_window_seconds=300.0)),
            ("non-numeric window", bound_row(cap, quiet_window_seconds="soon")),
            ("malformed fingerprint", bound_row(cap, payload_fingerprint="XY" * 32)),
            ("malformed row uuid", bound_row(cap, event_id=EV_ID.upper())),
            ("bad created_at", bound_row(cap, created_at="yesterday"))):
        msg = boom(lambda c=corrupted: w.validate_persisted_row(
            c, request=cap.request, rpc_result=rpc))
        check(msg is not None, f"row with {label} is refused — the Codex wrong-row case")
    missing = bound_row(cap)
    del missing["basis_run_id"]
    msg = boom(lambda: w.validate_persisted_row(missing, request=cap.request, rpc_result=rpc))
    check(msg is not None and "not exactly" in msg, "a missing required column is refused")
    extra = bound_row(cap)
    extra["decision_state"] = "promoted"
    msg = boom(lambda: w.validate_persisted_row(extra, request=cap.request, rpc_result=rpc))
    check(msg is not None and "not exactly" in msg, "an unexpected extra column is refused")


# ---------------------------------------------------------------------------------------------
# OUTCOME STATE MACHINE — pre-write vs uncertain vs server-confirmed, and no retry ever
# ---------------------------------------------------------------------------------------------
def t_persist_full_clean_run_with_replay():
    cap, _ = armed_capability(101)
    out, client, reader = run_persist(
        cap, [[rpc_row()], [rpc_row(inserted=0)]], counts=[1, 1], row=bound_row(cap))
    check(out["verdict"] == "INSERTED_AND_REPLAY_IDEMPOTENT", "clean canary shape verifies")
    check(out["write_state"] == "SERVER_CONFIRMED" and out["write_occurred"] is True,
          "the write is server-confirmed")
    check(out["insert_post_verify_ok"] is True and out["row"] == bound_row(cap),
          "post-insert verification bound the row")
    check(out["replay_post_verify_ok"] is True and out["replay_post_verify_error"] is None,
          "and the replay verification passed as its OWN independent state")
    check((out["count_before"], out["count_after"], out["replay_count_after"]) == (0, 1, 1),
          "count went 0 -> 1 and STAYED 1 after the replay")
    check(out["calls_attempted"] == 2 and len(client.requests) == 2,
          "exactly two RPC calls")
    check(reader.count_calls == 2 and reader.row_calls == 1,
          "verification read the count twice and the row once")


def t_persist_without_replay_stops_after_verification():
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(cap, [[rpc_row()]], counts=[1], row=bound_row(cap),
                                 replay=False)
    check(out["verdict"] == "INSERTED_NO_REPLAY_REQUESTED" and out["calls_attempted"] == 1,
          "one call when replay is not requested")
    check(out["insert_post_verify_ok"] is True, "verification still ran")
    check(out["replay_post_verify_ok"] is None,
          "replay verification is NOT claimed when no replay was requested")


def t_persist_count_failure_keeps_the_confirmed_write():
    """THE CODEX COUNT REPRO: RPC insert succeeds, then capture_event_count raises."""
    cap, _ = armed_capability(101)
    out, client, reader = run_persist(
        cap, [[rpc_row()]], counts=[w.CaptureWriterError("HTTP 500 on GET mt5_capture_events")],
        row=bound_row(cap))
    check(out["verdict"] == "APPEND_INSERTED_POSTVERIFY_FAILED",
          "a post-write count failure is its own explicit state")
    check("REFUSED" not in out["verdict"], "and it is NEVER reported as a refusal")
    check(out["write_occurred"] is True and out["write_state"] == "SERVER_CONFIRMED",
          "the confirmed write remains a permanent fact")
    check(out["first"]["o_inserted"] == 1 and out["first"]["o_event_id"] == EV_ID
          and out["first"]["o_event_key"] == EV_KEY,
          "o_inserted/o_event_id/o_event_key are all preserved for reconciliation")
    check(out["insert_post_verify_ok"] is False
          and "HTTP 500" in out["insert_post_verify_error"],
          "the verification failure is captured inside the outcome")
    check(len(client.requests) == 1 and out["calls_attempted"] == 1,
          "exactly ONE POST occurred — the replay was BLOCKED, and nothing was retried")


def t_persist_readback_failure_keeps_the_confirmed_write():
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(
        cap, [[rpc_row()]], counts=[1],
        row=w.CaptureWriterError("mt5_capture_events: expected exactly one row"))
    check(out["verdict"] == "APPEND_INSERTED_POSTVERIFY_FAILED",
          "a read-back failure is the same explicit post-verify state")
    check(out["write_occurred"] is True and out["first"]["o_event_id"] == EV_ID,
          "the write and its id/key survive")
    check(len(client.requests) == 1, "and the replay was blocked")


def t_persist_wrong_row_is_a_postverify_failure():
    """THE CODEX WRONG-ROW REPRO: a row with entirely different identity comes back."""
    cap, _ = armed_capability(101)
    alien = bound_row(cap, event_id=EV_ID2, key=EV_KEY2, user_id=OTHER_UID,
                      source_account=OTHER_ACCT, position_id=999)
    out, client, _ = run_persist(cap, [[rpc_row()]], counts=[1], row=alien)
    check(out["verdict"] == "APPEND_INSERTED_POSTVERIFY_FAILED",
          "an identity-mismatched row FAILS verification instead of being accepted")
    check(out["write_occurred"] is True, "while the confirmed write stands")
    check("does not match" in out["insert_post_verify_error"],
          "and the mismatch is named in the captured error")
    check(len(client.requests) == 1, "replay blocked after failed verification")


def t_persist_transport_uncertainty_is_not_refused():
    cap, _ = armed_capability(101)
    out, client, reader = run_persist(
        cap, [w.CaptureWriterError("network error on RPC mt5_append_capture_event_v1")],
        counts=[0], row=bound_row(cap))
    check(out["verdict"] == "APPEND_OUTCOME_UNCERTAIN",
          "a call-1 transport failure is UNCERTAIN")
    check(out["write_state"] == "UNCERTAIN" and out["write_occurred"] is False,
          "no write is claimed and no refusal is claimed")
    check("network error" in out["uncertainty"], "the transport evidence is preserved")
    check(len(client.requests) == 1, "sent exactly once — no retry")
    check(reader.count_calls == 0, "no post-write verification on an uncertain outcome")


def t_persist_malformed_result_is_uncertain_not_refused():
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(cap, [[rpc_row(key="G" * 64)]], counts=[0],
                                 row=bound_row(cap))
    check(out["verdict"] == "APPEND_OUTCOME_UNCERTAIN",
          "a malformed server result stops processing as UNCERTAIN — the send happened")
    check(out["write_occurred"] is False and out["uncertainty"] is not None,
          "nothing is claimed either way; the contract violation is preserved")


def t_persist_server_refusal_is_confirmed_no_write():
    cap, _ = armed_capability(101)
    out, client, reader = run_persist(
        cap, [[rpc_row(ok=False, inserted=0, error="ERR_CAPTURE_CONFLICT")]],
        counts=[0], row=bound_row(cap))
    check(out["verdict"] == "FIRST_CALL_REFUSED:ERR_CAPTURE_CONFLICT",
          "a validated server refusal carries the server's own code")
    check(out["write_state"] == "SERVER_CONFIRMED" and out["write_occurred"] is False,
          "it is a CONFIRMED outcome — distinct from both refusal-before-send and uncertain")
    check(len(client.requests) == 1 and reader.count_calls == 0,
          "one call, no verification, no replay")


def t_persist_already_replay_makes_no_second_call():
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(cap, [[rpc_row(inserted=0)]], counts=[0],
                                 row=bound_row(cap))
    check(out["verdict"] == "FIRST_CALL_WAS_ALREADY_A_REPLAY",
          "a pre-existing key on call 1 is surfaced")
    check(out["write_occurred"] is False and len(client.requests) == 1,
          "no new write is claimed and no second call is made")


def t_replay_transport_uncertainty_keeps_the_write():
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(
        cap, [[rpc_row()], w.CaptureWriterError("network error on replay")],
        counts=[1], row=bound_row(cap))
    check(out["verdict"] == "INSERTED_REPLAY_OUTCOME_UNCERTAIN",
          "an uncertain replay is its own state")
    check(out["write_occurred"] is True and out["first"]["o_event_id"] == EV_ID,
          "the confirmed call-1 write is never un-claimed by a later uncertainty")
    check(len(client.requests) == 2, "the replay was attempted exactly once")


def t_replay_mismatch_is_flagged_but_write_stands():
    cap, _ = armed_capability(101)
    out, _, _ = run_persist(
        cap, [[rpc_row()], [rpc_row(inserted=0, event_id=EV_ID2, key=EV_KEY2)]],
        counts=[1], row=bound_row(cap))
    check(out["verdict"] == "INSERTED_BUT_REPLAY_NOT_IDEMPOTENT",
          "a replay answering a different identity is flagged, never papered over")
    check(out["write_occurred"] is True, "while the call-1 write remains a fact")


def t_replay_count_growth_is_a_postverify_failure():
    """THE CODEX 0 -> 1 -> 2 REPRO: the insert verifies clean, then the replay count check
    finds an impossible extra row. The failure must own the verdict AND the render — the
    truthful insert-verification PASS may never be presented as overall verification OK."""
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(cap, [[rpc_row()], [rpc_row(inserted=0)]], counts=[1, 2],
                                 row=bound_row(cap))
    check(out["verdict"] == "INSERTED_REPLAY_POSTVERIFY_FAILED",
          "a count that MOVED after the replay fails the final verification")
    check(out["write_occurred"] is True and out["first"]["o_inserted"] == 1,
          "the initial insert remains known successful")
    check(out["insert_post_verify_ok"] is True
          and out["insert_post_verify_error"] is None,
          "the initial verification remains a truthful, SEPARATE pass")
    check(out["replay_post_verify_ok"] is False
          and "expected it to remain 1" in out["replay_post_verify_error"],
          "the replay verification is FAIL and says exactly what moved")
    check((out["count_before"], out["count_after"], out["replay_count_after"]) == (0, 1, 2),
          "the exact 0 -> 1 -> 2 evidence sequence is preserved")
    check(len(client.requests) == 2 and out["calls_attempted"] == 2,
          "no additional RPC after the failed replay verification")
    text = w._render_persist(out)
    check("INITIAL INSERT: CONFIRMED" in text and "INITIAL VERIFICATION: PASS" in text,
          "the render reports the insert and ITS verification truthfully")
    check("REPLAY: SERVER RESPONSE RECEIVED" in text
          and "REPLAY VERIFICATION: FAILED" in text,
          "and surfaces the replay verification failure")
    check("DO NOT BLINDLY RETRY" in text and "READ-ONLY RECONCILIATION REQUIRED" in text,
          "and demands read-only reconciliation")
    check("OVERALL: PASS" not in text and "POST-WRITE VERIFICATION: OK" not in text,
          "and NEVER renders an overall verification OK")


def t_first_send_ordinary_exceptions_become_uncertain():
    """Once the call-1 POST has been attempted, EVERY ordinary exception — JSON decoding,
    ValueError, CaptureWriterError, anything else — returns through the state machine as
    APPEND_OUTCOME_UNCERTAIN. Nothing escapes, nothing retries, nothing is REFUSED."""
    for exc in (json.JSONDecodeError("malformed body", "x", 0), ValueError("boom"),
                w.CaptureWriterError("transport reset"), RuntimeError("mid-flight")):
        cap, _ = armed_capability(101)
        out, client, reader = run_persist(cap, [exc], counts=[0], row=None)
        check(out["verdict"] == "APPEND_OUTCOME_UNCERTAIN"
              and out["write_state"] == "UNCERTAIN",
              f"{type(exc).__name__} after the send attempt is UNCERTAIN, never an escape")
        check("REFUSED" not in out["verdict"], "and never REFUSED")
        check(out["write_occurred"] is False and out["uncertainty"],
              "nothing is claimed either way; the failure evidence is preserved")
        check(len(client.requests) == 1, "the POST was attempted exactly once — no retry")
        check(reader.count_calls == 0, "no verification and no replay on uncertainty")
        check(out["position_id"] == 101, "the candidate identity is preserved")


def t_replay_send_ordinary_exceptions_keep_the_write():
    """Same boundary on the deliberate replay: an ordinary exception after the call-2 POST
    becomes INSERTED_REPLAY_OUTCOME_UNCERTAIN — the confirmed insert and its verification
    stand, idempotency is NOT claimed, and no third call is made."""
    for exc in (json.JSONDecodeError("malformed body", "x", 0), ValueError("boom"),
                w.CaptureWriterError("transport reset"), RuntimeError("mid-flight")):
        cap, _ = armed_capability(101)
        out, client, _ = run_persist(cap, [[rpc_row()], exc], counts=[1],
                                     row=bound_row(cap))
        check(out["verdict"] == "INSERTED_REPLAY_OUTCOME_UNCERTAIN",
              f"{type(exc).__name__} on the replay send is its own uncertainty state")
        check(out["write_occurred"] is True and out["insert_post_verify_ok"] is True,
              "the insert AND its verification remain known facts")
        check(out["replay_post_verify_ok"] is None,
              "replay verification is NOT claimed in any direction")
        check(len(client.requests) == 2, "exactly two POSTs — no third call")
        text = w._render_persist(out)
        check("REPLAY: OUTCOME UNCERTAIN" in text
              and "REPLAY VERIFICATION: PASS" not in text
              and "OVERALL: PASS" not in text,
              "the render says the replay is uncertain and claims no idempotency pass")


def t_failure_shapes_follow_the_applied_sql():
    """Hand-authored from T2_capture_events_rpc_packet.sql (packet revision 5), NOT from the
    implementation mapping: all 71 validation returns are (false, 0, null, null, code) over
    these 22 codes; ERR_CAPTURE_CONFLICT returns the EXISTING row's id+key; ERR_CAPTURE_RACE
    returns the computed key with NO row id."""
    validation_codes = (
        "ERR_BAD_INPUT", "ERR_CAPTURE_PAYLOAD_KEYS", "ERR_CAPTURE_DOMAIN",
        "ERR_CAPTURE_FORBIDDEN_FIELD", "ERR_CAPTURE_SCOPE", "ERR_CAPTURE_PAYLOAD_INVALID",
        "ERR_CAPTURE_TIME_ORDER", "ERR_CAPTURE_WINDOW_MISMATCH", "ERR_CAPTURE_PROVENANCE",
        "ERR_CAPTURE_IDENTITY", "ERR_CAPTURE_DETECTION", "ERR_CAPTURE_BASIS_MISMATCH",
        "ERR_BASIS_RUN_NOT_FOUND", "ERR_BASIS_RUN_SCOPE", "ERR_BASIS_RUN_NOT_COMPLETE",
        "ERR_BASIS_RUN_NOT_HEALTHY", "ERR_RUN_NOT_FOUND", "ERR_RUN_SCOPE",
        "ERR_RUN_NOT_COMPLETE", "ERR_RUN_NOT_HEALTHY", "ERR_RUN_SEQ_MISMATCH",
        "ERR_RUN_NOT_ADJACENT")
    for code in validation_codes:
        got = w.parse_rpc_result([rpc_row(ok=False, inserted=0, event_id=None, key=None,
                                          error=code)], call_label="t")
        check(got["o_error_code"] == code, f"{code} with null id/key is the SQL's shape")
    conflict = w.parse_rpc_result([rpc_row(ok=False, inserted=0, error="ERR_CAPTURE_CONFLICT")],
                                  call_label="t")
    check(conflict["o_event_id"] == EV_ID and conflict["o_event_key"] == EV_KEY,
          "CONFLICT keeps the EXISTING row's id AND key — the SQL always returns both")
    race = w.parse_rpc_result([rpc_row(ok=False, inserted=0, event_id=None, key=EV_KEY,
                                       error="ERR_CAPTURE_RACE")], call_label="t")
    check(race["o_event_id"] is None and race["o_event_key"] == EV_KEY,
          "RACE returns the computed key but NO row id — the SQL's exact shape")
    check(set(w.RPC_FAILURE_SHAPES)
          == set(validation_codes) | {"ERR_CAPTURE_CONFLICT", "ERR_CAPTURE_RACE"},
          "the implementation table covers exactly the applied SQL's codes — none invented, "
          "none missing")
    for bad, label in (
            (rpc_row(ok=False, inserted=0, event_id=EV_ID, key=None,
                     error="ERR_CAPTURE_DETECTION"),
             "generic error with an event_id but no event_key"),
            (rpc_row(ok=False, inserted=0, event_id=None, key=EV_KEY,
                     error="ERR_BAD_INPUT"),
             "validation error carrying a key"),
            (rpc_row(ok=False, inserted=0, event_id=EV_ID, key=EV_KEY,
                     error="ERR_RUN_NOT_FOUND"),
             "success-shape id+key attached to a validation failure branch"),
            (rpc_row(ok=False, inserted=0, event_id=EV_ID, key=EV_KEY,
                     error="ERR_CAPTURE_RACE"),
             "RACE with an event_id (the SQL race branch has no row id)"),
            (rpc_row(ok=False, inserted=0, event_id=None, key=None,
                     error="ERR_CAPTURE_RACE"),
             "RACE without the computed key"),
            (rpc_row(ok=False, inserted=0, event_id=None, key=EV_KEY,
                     error="ERR_CAPTURE_CONFLICT"),
             "CONFLICT without the existing row id"),
            (rpc_row(ok=False, inserted=0, event_id=EV_ID, key=None,
                     error="ERR_CAPTURE_CONFLICT"),
             "CONFLICT without the existing key"),
            (rpc_row(ok=False, inserted=0, event_id=None, key=None,
                     error="ERR_CAPTURE_CONFLICT"),
             "CONFLICT with neither id nor key"),
            (rpc_row(ok=False, inserted=1, error="ERR_CAPTURE_CONFLICT"),
             "a KNOWN failure branch claiming a write (o_inserted=1)")):
        msg = boom(lambda b=bad: w.parse_rpc_result([b], call_label="t"))
        check(msg is not None, f"SQL-impossible failure shape ({label}) is refused")


def t_unknown_error_code_is_refused():
    """The applied SQL has no generic catch-all branch: an o_error_code it never emits is a
    contract violation and the whole response is refused, whatever id/key shape it wears."""
    for bad, label in (
            (rpc_row(ok=False, inserted=0, event_id=None, key=None,
                     error="ERR_SOMETHING_NEW"),
             "unknown code with null id/key"),
            (rpc_row(ok=False, inserted=0, event_id=EV_ID, key=EV_KEY, error="ERR_X"),
             "unknown code wearing the success shape"),
            (rpc_row(ok=False, inserted=0, event_id=None, key=None,
                     error="err_capture_conflict"),
             "known code in the wrong case — no normalisation")):
        msg = boom(lambda b=bad: w.parse_rpc_result([b], call_label="t"))
        check(msg is not None and "not an error the applied RPC revision emits" in msg,
              f"unknown o_error_code ({label}) is refused, not interpreted")


def t_render_reports_each_phase_independently():
    cap, _ = armed_capability(101)
    out, _, _ = run_persist(cap, [[rpc_row()], [rpc_row(inserted=0)]], counts=[1, 1],
                            row=bound_row(cap))
    text = w._render_persist(out)
    check("INITIAL INSERT: CONFIRMED" in text and "INITIAL VERIFICATION: PASS" in text
          and "REPLAY VERIFICATION: PASS" in text and "OVERALL: PASS" in text,
          "a fully verified canary renders as PASS in every phase")
    check("FAILED" not in text and "RECONCILIATION" not in text,
          "and carries no failure wording")
    out, _, _ = run_persist(cap, [[rpc_row()]], counts=[1], row=bound_row(cap),
                            replay=False)
    text = w._render_persist(out)
    check("REPLAY: NOT REQUESTED" in text
          and "REPLAY VERIFICATION: NOT ATTEMPTED" in text and "OVERALL: PASS" in text,
          "an unrequested replay is stated explicitly")
    check("REPLAY VERIFICATION: PASS" not in text,
          "and idempotency verification is NOT claimed without a replay")
    out, _, _ = run_persist(
        cap, [[rpc_row()]],
        counts=[w.CaptureWriterError("HTTP 500 on GET mt5_capture_events")],
        row=bound_row(cap))
    text = w._render_persist(out)
    check("INITIAL INSERT: CONFIRMED" in text and "INITIAL VERIFICATION: FAILED" in text,
          "a failed insert verification is named while the insert stays confirmed")
    check("REPLAY: BLOCKED" in text and "OVERALL: FAILURE" in text
          and "OVERALL: PASS" not in text,
          "the blocked replay and the overall failure are explicit")


def t_render_overall_follows_the_verdict_alone():
    """Every non-clean verdict renders OVERALL: FAILURE. No flag combination may dress a
    partial success up as a pass, and the retired overall-OK line stays retired."""
    cap, _ = armed_capability(101)
    scenarios = (
        ("APPEND_OUTCOME_UNCERTAIN",
         [w.CaptureWriterError("network down")], [0]),
        ("FIRST_CALL_REFUSED:ERR_CAPTURE_CONFLICT",
         [[rpc_row(ok=False, inserted=0, error="ERR_CAPTURE_CONFLICT")]], [0]),
        ("FIRST_CALL_WAS_ALREADY_A_REPLAY",
         [[rpc_row(inserted=0)]], [0]),
        ("APPEND_INSERTED_POSTVERIFY_FAILED",
         [[rpc_row()]], [7]),
        ("INSERTED_BUT_REPLAY_NOT_IDEMPOTENT",
         [[rpc_row()], [rpc_row(inserted=0, event_id=EV_ID2, key=EV_KEY2)]], [1]),
        ("INSERTED_REPLAY_OUTCOME_UNCERTAIN",
         [[rpc_row()], RuntimeError("mid-flight")], [1]),
        ("INSERTED_REPLAY_POSTVERIFY_FAILED",
         [[rpc_row()], [rpc_row(inserted=0)]], [1, 2]),
    )
    for want, responses, counts in scenarios:
        out, _, _ = run_persist(cap, responses, counts=counts, row=bound_row(cap))
        check(out["verdict"] == want, f"scenario reaches {want}")
        text = w._render_persist(out)
        check("OVERALL: FAILURE" in text and "OVERALL: PASS" not in text,
              f"{want} renders OVERALL: FAILURE, never PASS")
        check("POST-WRITE VERIFICATION: OK" not in text,
              f"{want} never renders the retired overall-OK line")


def t_replay_requires_prior_full_verification():
    """§8: call 2 only after call-1 success AND post-write verification success."""
    cap, _ = armed_capability(101)
    out, client, _ = run_persist(
        cap, [[rpc_row()], [rpc_row(inserted=0)]],
        counts=[7], row=bound_row(cap))          # count wrong -> verification fails
    check(out["verdict"] == "APPEND_INSERTED_POSTVERIFY_FAILED",
          "failed verification wins")
    check(len(client.requests) == 1,
          "and the deliberate replay is NOT attempted — it is verification, not recovery")


def t_execute_refuses_a_non_capability():
    client = FakeAppendClient([[rpc_row()]])
    reader = FakeVerifyReader(counts=[1], row=None)
    rep = production_plan()
    msg = boom(lambda: w.execute_selected_persist(
        client, reader, rep["rpc_requests"][0], replay_verify=False, count_before=0))
    check(msg is not None and "capability" in msg,
          "execute itself refuses a raw request — a pre-send refusal, nothing sent")
    check(client.requests == [], "and indeed nothing was sent")


# ---------------------------------------------------------------------------------------------
# MAIN-LEVEL WRITE SAFETY — refusals fire before credentials, so no network is reachable
# ---------------------------------------------------------------------------------------------
BASE_ARGS = ["--user-id", UID, "--source-account", ACCT,
             "--before-run-id", R1, "--after-run-id", R2]


def main_stderr(argv, *, env=None):
    """Run main() with a scrubbed environment and captured stderr. SUPABASE_* is removed so
    any path that survives to credential resolution refuses THERE — proving the safety
    refusals fire earlier, with no network reachable at all."""
    saved = {k: os.environ.pop(k, None)
             for k in ("SUPABASE_URL", "SUPABASE_SERVICE_KEY", w.WRITE_ENV)}
    for k, v in (env or {}).items():
        os.environ[k] = v
    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            code = w.main(argv)
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v
    return code, buf.getvalue()


def t_main_dry_run_refuses_the_selector():
    code, err = main_stderr(BASE_ARGS + ["--quiet-window-seconds", "900",
                                         "--position-id", "312261388"])
    check(code == 2 and "write-safety selector" in err,
          "--position-id without --persist is refused as a misused write-safety selector")
    code, err = main_stderr(BASE_ARGS + ["--quiet-window-seconds", "900", "--replay-verify"])
    check(code == 2 and "--replay-verify" in err,
          "--replay-verify without --persist is refused")


def t_main_persist_requires_the_selector():
    code, err = main_stderr(
        BASE_ARGS + ["--quiet-window-seconds", "900",
                     "--persist", "--confirm", w.CONFIRM_PERSIST],
        env={w.WRITE_ENV: "1"})
    check(code == 2 and "--position-id" in err and "never inferred" in err,
          "fully-armed persist without --position-id refuses before any network")
    check("SUPABASE" not in err, "...and never got as far as credential resolution")


def t_main_persist_refuses_a_non_production_window():
    code, err = main_stderr(
        BASE_ARGS + ["--quiet-window-seconds", "300",
                     "--persist", "--confirm", w.CONFIRM_PERSIST,
                     "--position-id", "312261388"],
        env={w.WRITE_ENV: "1"})
    check(code == 2 and "frozen production quiet window" in err,
          "persist with W != 900 is refused: the policy is forward-only")
    check("900" in err, "...and the refusal names the frozen value")
    code, err = main_stderr(
        BASE_ARGS + ["--quiet-window-seconds", "900",
                     "--persist", "--confirm", w.CONFIRM_PERSIST,
                     "--position-id", "312261388"],
        env={w.WRITE_ENV: "1"})
    check(code == 2 and "SUPABASE_URL" in err,
          "with W=900 the same invocation proceeds to credential resolution — so the window "
          "check above was the refusing guard, and no network is possible in this test env")


def t_main_persist_refuses_malformed_selector_values():
    code, err = main_stderr(
        BASE_ARGS + ["--quiet-window-seconds", "900",
                     "--persist", "--confirm", w.CONFIRM_PERSIST, "--position-id", "-5"],
        env={w.WRITE_ENV: "1"})
    check(code == 2 and "positive integer" in err, "a negative selector is refused")
    try:
        w.main(BASE_ARGS + ["--quiet-window-seconds", "900", "--position-id", "abc"])
        check(False, "argparse should have refused a non-integer selector")
    except SystemExit as e:
        check(e.code == 2, "a non-integer selector is refused by the parser with exit 2")


def t_append_client_is_rpc_allowlisted():
    client = w.CaptureAppendClient("https://example.invalid", "k")
    msg = boom(lambda: client._post_rpc("mt5_create_run_v1", {}))
    check(msg is not None and "not in the allowlist" in msg,
          "the client refuses every RPC name except the append RPC — before any network")
    msg = boom(lambda: client.append({"wrong": 1}))
    check(msg is not None and "not a write authorization" in msg,
          "the client refuses anything that is not the minted capability")
    check(w.ALLOWED_RPCS == frozenset({w.RPC_APPEND_CAPTURE}),
          "the allowlist holds exactly the append RPC")


ALL = [
    t_valid_pair_accepted, t_same_run_rejected, t_missing_run_rejected,
    t_wrong_scope_rejected, t_incomplete_run_rejected, t_unhealthy_run_rejected,
    t_reversed_pair_rejected, t_non_adjacent_pair_rejected, t_duplicate_run_id_rejected,
    t_null_run_seq_on_non_complete_runs_is_tolerated,
    t_non_complete_run_between_the_pair_is_not_adjacency,
    t_zero_detection, t_new_position, t_reappearance_uses_full_history,
    t_increase_and_decrease, t_disappeared, t_identity_conflict,
    t_multiple_positions_one_pair,
    t_two_detections_in_one_window_are_one_candidate,
    t_anchor_on_the_first_pair_returns_the_whole_candidate,
    t_anchor_on_the_second_pair_returns_the_same_candidate,
    t_pair_local_coalescing_would_have_been_wrong,
    t_detection_outside_the_window_starts_a_new_candidate,
    t_anchor_with_no_detection_returns_nothing_even_if_others_exist,
    t_later_trusted_run_with_no_detection_manufactures_nothing,
    t_readiness_is_never_overclaimed,
    t_run_completed_after_now_is_excluded, t_later_run_included_when_within_now,
    t_anchor_after_run_completed_after_now_is_refused,
    t_history_is_not_bounded_by_the_anchor_run_seq,
    t_detected_at_is_the_completion_instant_not_captured_at,
    t_candidate_cannot_close_before_the_after_run_completed,
    t_each_detection_is_dated_by_its_own_after_run,
    t_boundary_is_strictly_after_deadline, t_open_candidate_builds_no_request,
    t_completed_run_without_a_completion_instant_is_refused,
    t_missing_count_is_rejected, t_malformed_count_is_rejected,
    t_truncated_response_is_completed_by_paging,
    t_incomplete_read_that_cannot_progress_is_rejected,
    t_inconsistent_total_between_pages_is_rejected, t_over_long_read_is_rejected,
    t_exact_zero_and_exact_n_are_accepted, t_unordered_paginated_read_is_refused,
    t_every_collection_read_is_ordered,
    t_capture_count_is_user_scoped, t_capture_count_ignores_other_users,
    t_membership_refuses_an_out_of_scope_row, t_membership_requests_are_chunked,
    t_rpc_request_is_the_approved_shape, t_multi_detection_request_carries_both_detections,
    t_no_account_facts_or_decision_state, t_inputs_are_not_mutated,
    t_duplicate_dry_run_is_identical,
    t_dry_run_is_the_default, t_phase_gate_is_open_and_still_restorable,
    t_persist_arming_requires_every_key, t_reader_has_no_write_surface,
    t_read_allowlist_is_enforced, t_staging_is_never_consulted,
    t_canonical_uuid_is_reused_not_restated, t_instants_must_carry_an_offset,
    # suspicious runs break continuity
    t_completed_observation_history_includes_suspicious,
    t_suspicious_run_breaks_continuity,
    t_suspicious_gap_candidate_carries_only_the_real_detection,
    t_unchanged_across_a_suspicious_gap_emits_nothing,
    t_new_position_after_a_suspicious_gap_is_not_a_delta,
    t_disappearance_is_not_fabricated_across_a_suspicious_gap,
    t_membership_for_a_suspicious_run_is_refused,
    t_anchor_spanning_a_suspicious_run_is_refused,
    t_started_run_in_the_gap_is_not_an_observation,
    t_canonical_repro_extends_into_the_quiet_window,
    t_suspicious_gap_survives_the_real_adapter,
    # Content-Range page coordinates
    t_content_range_is_parsed_completely,
    t_repeated_page_coordinates_are_rejected,
    t_returned_start_ahead_of_the_requested_offset_is_rejected,
    t_returned_end_past_the_requested_bound_is_rejected,
    t_coordinate_span_larger_than_the_body_is_rejected,
    t_body_larger_than_the_coordinate_span_is_rejected,
    t_zero_total_with_a_non_empty_body_is_rejected,
    t_end_below_start_is_rejected,
    t_zero_total_with_a_coordinate_range_is_rejected,
    t_star_range_with_a_non_zero_total_is_rejected,
    t_next_offset_comes_from_the_returned_end,
    t_capture_count_transfers_at_most_one_row,
    # snapshot_status domain
    t_status_domain_is_the_frozen_vocabulary,
    t_every_frozen_status_is_accepted,
    t_status_outside_the_domain_is_refused,
    t_unknown_status_is_never_filtered_out_of_the_history,
    t_unknown_status_repro_refuses_the_whole_plan,
    t_status_is_validated_before_scope_filtering_and_adjacency,
    t_validate_run_pair_reads_status_through_the_funnel,
    t_whole_set_status_domain_is_proven_before_the_anchor,
    # all-runs scope
    t_scope_accepts_a_uniform_set,
    t_foreign_user_run_refuses_the_set,
    t_foreign_account_run_refuses_the_set,
    t_account_is_opaque_text_never_coerced,
    t_user_id_case_variant_is_not_normalised,
    t_foreign_run_is_refused_wherever_it_sits,
    t_cross_user_repro_refuses_the_whole_plan,
    t_foreign_scope_cannot_reach_membership_loading,
    t_reader_refuses_a_returned_row_outside_scope,
    t_membership_reader_refuses_a_foreign_scope_row,
    t_scope_and_status_hold_together_with_the_suspicious_gap,
    # persist targeting + RPC execution (first-append canary phase)
    t_production_window_constant_is_the_frozen_policy,
    t_selector_requires_a_positive_integer,
    t_two_eligible_candidates_and_selection_targets_exactly_one,
    t_selection_never_persists_the_unselected_candidate,
    t_selection_refuses_zero_matches,
    t_selection_refuses_duplicate_matches,
    t_selection_cannot_promote_an_open_candidate,
    t_selection_cannot_reach_an_unanchored_candidate,
    t_selection_refuses_inconsistent_eligibility,
    t_selection_refuses_cross_scope_request,
    t_selection_does_not_mutate_or_narrow_the_report,
    t_append_client_refuses_raw_requests,
    t_capability_mint_requires_the_internal_token,
    t_capability_requires_full_arming_and_the_frozen_window,
    t_capability_binds_exactly_one_named_request,
    t_capability_rejects_forged_shapes,
    t_capability_cannot_be_reused_with_a_different_request,
    t_no_public_path_sends_two_candidates_in_one_invocation,
    t_event_key_validator_is_exact,
    t_rpc_result_truth_table,
    t_validate_persisted_row_binds_identity,
    t_persist_full_clean_run_with_replay,
    t_persist_without_replay_stops_after_verification,
    t_persist_count_failure_keeps_the_confirmed_write,
    t_persist_readback_failure_keeps_the_confirmed_write,
    t_persist_wrong_row_is_a_postverify_failure,
    t_persist_transport_uncertainty_is_not_refused,
    t_persist_malformed_result_is_uncertain_not_refused,
    t_persist_server_refusal_is_confirmed_no_write,
    t_persist_already_replay_makes_no_second_call,
    t_replay_transport_uncertainty_keeps_the_write,
    t_replay_mismatch_is_flagged_but_write_stands,
    t_replay_count_growth_is_a_postverify_failure,
    t_first_send_ordinary_exceptions_become_uncertain,
    t_replay_send_ordinary_exceptions_keep_the_write,
    t_failure_shapes_follow_the_applied_sql,
    t_unknown_error_code_is_refused,
    t_render_reports_each_phase_independently,
    t_render_overall_follows_the_verdict_alone,
    t_replay_requires_prior_full_verification,
    t_execute_refuses_a_non_capability,
    t_main_dry_run_refuses_the_selector,
    t_main_persist_requires_the_selector,
    t_main_persist_refuses_a_non_production_window,
    t_main_persist_refuses_malformed_selector_values,
    t_append_client_is_rpc_allowlisted,
]

# A test function that is never registered is a test that never runs — and a suite that
# quietly shrinks is worse than no suite. ALL is explicit, so prove it is also complete.
_DEFINED = {name for name, obj in sorted(globals().items())
            if name.startswith("t_") and callable(obj)}
_REGISTERED = {fn.__name__ for fn in ALL}


def t_every_test_is_registered():
    missing = sorted(_DEFINED - _REGISTERED)
    check(not missing, f"every t_* function is registered in ALL (unregistered: {missing})")
    check(len(ALL) == len(_REGISTERED), "ALL contains no duplicate entries")


ALL.append(t_every_test_is_registered)
_DEFINED.add("t_every_test_is_registered")
_REGISTERED.add("t_every_test_is_registered")


def main():
    for fn in ALL:
        try:
            fn()
        except Exception as e:                                              # noqa: BLE001
            FAILS.append(f"{fn.__name__} raised {type(e).__name__}: {e}")
    print(f"t2 capture writer pure tests: {CHECKS[0]} checks, "
          f"{'PASS' if not FAILS else f'{len(FAILS)} FAIL'}")
    for f in FAILS:
        print("  FAIL:", f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
