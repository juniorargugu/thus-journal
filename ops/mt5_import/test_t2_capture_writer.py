#!/usr/bin/env python3
"""
Pure tests for ops/mt5_import/t2_capture_writer.py. No DB, no network, no clock.

Every scenario is driven through the REAL committed t1_detector / t2_quiet_window /
t2_capture_adapter, so a test passing means the approved pipeline accepted the harness's
projection — not that a weaker local shape was satisfied.

Run with:  python -X utf8 ops/mt5_import/test_t2_capture_writer.py
"""
from __future__ import annotations

import copy
import inspect
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


def t_persist_cannot_execute_in_this_phase():
    check(w.PERSIST_ENABLED_IN_THIS_PHASE is False, "the phase gate is closed")
    mode, reason = w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST, write_env="1")
    check(mode == "stop", "even fully armed, persist is refused in this phase")
    check("PERSIST_ENABLED_IN_THIS_PHASE" in reason,
          "the refusal names the phase gate, not a missing key")
    msg = boom(lambda: w.CaptureAppendClient("https://example.invalid", "k"))
    check(msg is not None and "disabled in this phase" in msg,
          "the append client cannot even be constructed")


def t_persist_arming_requires_every_key():
    """Proved against the gate OPEN, so these checks are not passing for the wrong reason."""
    original = w.PERSIST_ENABLED_IN_THIS_PHASE
    w.PERSIST_ENABLED_IN_THIS_PHASE = True
    try:
        check(w.arming_status(persist=True, confirm=None, write_env="1")[0] == "stop",
              "persist without --confirm refused")
        check(w.arming_status(persist=True, confirm="nope", write_env="1")[0] == "stop",
              "persist with the wrong --confirm literal refused")
        check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST,
                              write_env=None)[0] == "stop",
              f"persist without {w.WRITE_ENV}=1 refused")
        check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST,
                              write_env="0")[0] == "stop",
              f"persist with {w.WRITE_ENV}=0 refused")
        check(w.arming_status(persist=True, confirm=w.CONFIRM_PERSIST,
                              write_env="1")[0] == "armed",
              "all three keys together arm it — so the checks above are load-bearing")
    finally:
        w.PERSIST_ENABLED_IN_THIS_PHASE = original
    check(w.PERSIST_ENABLED_IN_THIS_PHASE is False, "the phase gate is restored")


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
    t_dry_run_is_the_default, t_persist_cannot_execute_in_this_phase,
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
