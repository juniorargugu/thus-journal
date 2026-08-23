#!/usr/bin/env python3
"""
MT5 T1 v0.1 — pure detector tests. No MT5, no DB, no network, no clock.

Run with:  python -X utf8 ops/mt5_import/test_t1_detector.py
"""
from __future__ import annotations

import copy
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import t1_detector as t1                                                  # noqa: E402

CHECKS = [0]
FAILS = []

UID = "b77d0426-1111-4222-8333-444455556666"
ACCT = "301102520"


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


# ---------------------------------------------------------------------------------------------
# fixture helpers
# ---------------------------------------------------------------------------------------------
def run(seq, *, health="healthy", status="complete", user=UID, acct=ACCT, run_id=None):
    return {"run_id": run_id or f"run-{user[:4]}-{acct[-4:]}-{seq}",
            "user_id": user, "source_account": acct,
            "run_seq": seq if status == "complete" else None,
            "snapshot_status": status, "snapshot_health": health if status == "complete" else None}


def pos(pid, *, symbol="DELTAU26", side="buy", volume=2.0):
    return {"position_id": pid, "symbol_raw": symbol, "side": side, "volume": volume,
            "price_open": 310.0, "price_current": 262.59, "profit": -94820.0,
            "open_time_utc": "2026-07-14T02:45:00Z", "source_time_msc": 1784022300090,
            "contract_size": 1000.0}


def mem(*pairs):
    """[(run, rows), ...] -> memberships dict keyed by run_id. Each row is scope-stamped
    with its parent run's run_id / user_id / source_account (the real
    mt5_sync_run_positions columns) unless the test supplied those keys explicitly —
    adversarial tests override them to prove the scope guards fire."""
    return {r["run_id"]: [
        {"run_id": r["run_id"], "user_id": r["user_id"],
         "source_account": r["source_account"], **row} for row in rows]
        for r, rows in pairs}


# ---------------------------------------------------------------------------------------------
# 1. first healthy observation = baseline, zero events
# ---------------------------------------------------------------------------------------------
def t_first_observation_is_baseline():
    r1 = run(1)
    events = t1.detect([r1], mem((r1, [pos(101), pos(102)])))
    check(events == [], "baseline: first healthy observation emits zero events")

    empty = t1.detect([r1], mem((r1, [])))
    check(empty == [], "baseline: a flat first observation emits zero events")


# ---------------------------------------------------------------------------------------------
# 2-5. the four basic deltas between adjacent healthy runs
# ---------------------------------------------------------------------------------------------
def t_new_position():
    r1, r2 = run(1), run(2)
    ev = t1.detect([r1, r2], mem((r1, [pos(101)]), (r2, [pos(101), pos(202, volume=5.0)])))
    check(len(ev) == 1 and ev[0]["event_type"] == t1.EVENT_NEW_POSITION,
          "NEW_POSITION: absent before, present after, no earlier history")
    e = ev[0]
    check(e["position_id"] == 202 and e["before_run_id"] == r1["run_id"]
          and e["after_run_id"] == r2["run_id"],
          "NEW_POSITION: carries position_id + before/after run ids")
    check(e["after_volume"] == 5.0 and e["symbol_raw"] == "DELTAU26" and e["side"] == "buy",
          "NEW_POSITION: carries the after-run facts")


def t_increase():
    r1, r2 = run(1), run(2)
    ev = t1.detect([r1, r2], mem((r1, [pos(101, volume=2.0)]), (r2, [pos(101, volume=4.0)])))
    check(len(ev) == 1 and ev[0]["event_type"] == t1.EVENT_POSITION_INCREASE,
          "INCREASE: after volume > before volume")
    check(ev[0]["before_volume"] == 2.0 and ev[0]["after_volume"] == 4.0,
          "INCREASE: preserves both volumes")


def t_decrease():
    r1, r2 = run(1), run(2)
    ev = t1.detect([r1, r2], mem((r1, [pos(101, volume=4.0)]), (r2, [pos(101, volume=1.0)])))
    check(len(ev) == 1 and ev[0]["event_type"] == t1.EVENT_POSITION_DECREASE,
          "DECREASE: after volume < before volume")


def t_disappeared():
    r1, r2 = run(1), run(2)
    ev = t1.detect([r1, r2], mem((r1, [pos(101), pos(202)]), (r2, [pos(101)])))
    check(len(ev) == 1 and ev[0]["event_type"] == t1.EVENT_POSITION_DISAPPEARED,
          "DISAPPEARED: present before, absent after")
    e = ev[0]
    check(e["position_id"] == 202 and e["before_volume"] == 2.0,
          "DISAPPEARED: carries the before-run facts")
    # observed membership disappearance ONLY: no close semantics may leak into the event.
    check(all("close" not in k.lower() for k in e)
          and all("realized" not in k.lower() and "realised" not in k.lower() for k in e)
          and "profit" not in e,
          "DISAPPEARED: no close-price / realised-P/L / 'closed' fields")


def t_exact_volume_comparison():
    r1, r2 = run(1), run(2)
    ev = t1.detect([r1, r2], mem((r1, [pos(101, volume=2.0)]), (r2, [pos(101, volume=2.0)])))
    check(ev == [], "no event for an unchanged position")
    ev = t1.detect([r1, r2], mem((r1, [pos(101, volume=2)]), (r2, [pos(101, volume=2.0)])))
    check(ev == [], "exact: int 2 and float 2.0 are the same canonical volume")
    # comparison is EXACT over stored facts: differing stored digits ARE a difference
    ev = t1.detect([r1, r2], mem((r1, [pos(101, volume=0.3)]),
                                 (r2, [pos(101, volume=0.30000000000000004)])))
    check([e["event_type"] for e in ev] == [t1.EVENT_POSITION_INCREASE],
          "exact: stored-digit difference is a real difference, not noise")
    # the Codex case: magnitude must never swallow a real half-lot change
    ev = t1.detect([r1, r2], mem((r1, [pos(101, volume=1_000_000_000.0)]),
                                 (r2, [pos(101, volume=1_000_000_000.5)])))
    check([e["event_type"] for e in ev] == [t1.EVENT_POSITION_INCREASE],
          "exact: 1_000_000_000.0 -> 1_000_000_000.5 emits POSITION_INCREASE")
    check(t1.canonical_volume(2) == t1.canonical_volume(2.0),
          "canonical_volume: cross-type equality is exact, not float ==")
    check(t1.canonical_volume(1_000_000_000.5) > t1.canonical_volume(1_000_000_000.0),
          "canonical_volume: exact ordering survives large magnitude")


# ---------------------------------------------------------------------------------------------
# 6. disappearance then later healthy reappearance
# ---------------------------------------------------------------------------------------------
def t_reappearance():
    r1, r2, r3 = run(1), run(2), run(3)
    ev = t1.detect([r1, r2, r3],
                   mem((r1, [pos(101)]), (r2, []), (r3, [pos(101)])))
    kinds = [e["event_type"] for e in ev]
    check(kinds == [t1.EVENT_POSITION_DISAPPEARED, t1.EVENT_REAPPEARANCE],
          f"REAPPEARANCE: disappear then reappear, got {kinds}")
    check(ev[1]["before_run_id"] == r2["run_id"] and ev[1]["after_run_id"] == r3["run_id"],
          "REAPPEARANCE: before/after run ids are the pair where it reappeared")

    # membership seen ONLY in a suspicious run is not trusted history -> NEW, not REAPPEARANCE
    s1, s2, s3 = run(1, health="suspicious"), run(2), run(3)
    ev = t1.detect([s1, s2, s3], mem((s2, []), (s3, [pos(101)])))
    check([e["event_type"] for e in ev] == [t1.EVENT_NEW_POSITION],
          "suspicious membership never counts as trusted healthy history")


# ---------------------------------------------------------------------------------------------
# 7. identity conflict suppresses size delta
# ---------------------------------------------------------------------------------------------
def t_identity_conflict():
    r1, r2 = run(1), run(2)
    ev = t1.detect([r1, r2], mem((r1, [pos(101, symbol="DELTAU26", volume=2.0)]),
                                 (r2, [pos(101, symbol="S50U26", volume=9.0)])))
    check(len(ev) == 1 and ev[0]["event_type"] == t1.EVENT_POSITION_IDENTITY_CONFLICT,
          "CONFLICT: symbol_raw change is a conflict and suppresses INCREASE")
    check(ev[0]["before_symbol_raw"] == "DELTAU26" and ev[0]["after_symbol_raw"] == "S50U26",
          "CONFLICT: carries both symbols")

    ev = t1.detect([r1, r2], mem((r1, [pos(101, side="buy", volume=2.0)]),
                                 (r2, [pos(101, side="sell", volume=1.0)])))
    check(len(ev) == 1 and ev[0]["event_type"] == t1.EVENT_POSITION_IDENTITY_CONFLICT,
          "CONFLICT: side change is a conflict and suppresses DECREASE")


# ---------------------------------------------------------------------------------------------
# 8-10. suspicious completed run: gap, fresh baseline, resume
# ---------------------------------------------------------------------------------------------
def t_suspicious_gap_and_resume():
    r1, r2, r3, r4 = run(1), run(2, health="suspicious"), run(3), run(4)
    m = mem((r1, [pos(101, volume=2.0)]),
            (r3, [pos(101, volume=9.0), pos(202)]),        # differs from r1 across the gap
            (r4, [pos(101, volume=9.0), pos(202), pos(303)]))
    # note: NO membership entry for suspicious r2 -- it must never be consulted.
    ev = t1.detect([r1, r2, r3, r4], m)
    check(all(e["after_run_id"] != r3["run_id"] for e in ev),
          "gap: no event lands on the first healthy run after a suspicious run")
    check([e["event_type"] for e in ev] == [t1.EVENT_NEW_POSITION]
          and ev[0]["position_id"] == 303
          and ev[0]["before_run_id"] == r3["run_id"] and ev[0]["after_run_id"] == r4["run_id"],
          "resume: detection resumes between the two healthy runs AFTER the gap")

    # 8/9 in isolation: healthy -> suspicious -> healthy = zero events in total
    ev = t1.detect([r1, r2, r3], mem((r1, [pos(101, volume=2.0)]),
                                     (r3, [pos(101, volume=9.0), pos(202)])))
    check(ev == [], "gap: healthy/suspicious/healthy emits ZERO events (fresh baseline)")

    # all six classes suppressed across the gap: r1 has 101+404, r3 lacks 404 (disappear?),
    # has 505 (new?), and 101 changed volume (increase?) -- none may be emitted.
    ev = t1.detect([r1, r2, r3], mem((r1, [pos(101, volume=2.0), pos(404)]),
                                     (r3, [pos(101, volume=9.0), pos(505)])))
    check(ev == [], "gap: NEW/INCREASE/DECREASE/DISAPPEARED/REAPPEARANCE all suppressed")


# ---------------------------------------------------------------------------------------------
# 11. started / failed / unsealed attempts: not observations, no gap
# ---------------------------------------------------------------------------------------------
def t_attempts_are_not_observations():
    r1, r3 = run(1), run(3)
    started = run(2, status="started", run_id="run-started")
    failed = run(2, status="failed", run_id="run-failed")
    m = mem((r1, [pos(101, volume=2.0)]), (r3, [pos(101, volume=4.0)]))
    ev = t1.detect([r1, started, failed, r3], m)
    check([e["event_type"] for e in ev] == [t1.EVENT_POSITION_INCREASE],
          "attempts: started/failed rows between two healthy runs create NO gap")
    check(ev[0]["before_run_id"] == r1["run_id"] and ev[0]["after_run_id"] == r3["run_id"],
          "attempts: the healthy pair is still consecutive-completed")
    # no membership needed for attempts, and their (absent) membership adds no history
    ev2 = t1.detect([r1, started, r3], m)
    check(ev == ev2, "attempts: presence or absence of a failed attempt changes nothing")


# ---------------------------------------------------------------------------------------------
# 12. deterministic output ordering
# ---------------------------------------------------------------------------------------------
def t_deterministic_ordering():
    r1, r2, r3 = run(1), run(2), run(3)
    m = [(r1, [pos(101, volume=2.0), pos(202)]),
         (r2, [pos(101, volume=4.0), pos(303, volume=1.0)]),
         (r3, [pos(101, volume=4.0), pos(303, volume=1.0), pos(404)])]
    baseline = t1.detect([r1, r2, r3], mem(*m))
    check([(e["after_run_seq"], e["position_id"]) for e in baseline]
          == sorted((e["after_run_seq"], e["position_id"]) for e in baseline),
          "ordering: (after_run_seq, position_id) ascending")
    rng = random.Random(7)
    for _ in range(6):
        runs_shuffled = [r1, r2, r3][:]
        rng.shuffle(runs_shuffled)
        pairs = m[:]
        rng.shuffle(pairs)
        rows_shuffled = [(r, rng.sample(rows, k=len(rows))) for r, rows in pairs]
        check(t1.detect(runs_shuffled, mem(*rows_shuffled)) == baseline,
              "ordering: output independent of input order")


# ---------------------------------------------------------------------------------------------
# 13. user/account isolation
# ---------------------------------------------------------------------------------------------
def t_isolation():
    a1, a2 = run(1), run(2)
    b1 = run(1, acct="999888777", run_id="rb1")
    b2 = run(2, acct="999888777", run_id="rb2")
    m = mem((a1, [pos(101, volume=2.0)]), (a2, [pos(101, volume=4.0)]),
            (b1, []), (b2, [pos(101, volume=9.0)]))
    ev = t1.detect([a1, b1, a2, b2], m)
    by_acct = {e["source_account"]: e["event_type"] for e in ev}
    check(by_acct == {ACCT: t1.EVENT_POSITION_INCREASE, "999888777": t1.EVENT_NEW_POSITION},
          f"isolation: same position_id classifies independently per account, got {by_acct}")
    # same account string under a different user is a different stream too
    u2 = "c99f0000-1111-4222-8333-444455556666"
    c1, c2 = run(1, user=u2, run_id="rc1"), run(2, user=u2, run_id="rc2")
    ev = t1.detect([a1, a2, c1, c2],
                   mem((a1, [pos(101, volume=2.0)]), (a2, [pos(101, volume=4.0)]),
                       (c1, []), (c2, [pos(101)])))
    kinds = sorted(e["event_type"] for e in ev)
    check(kinds == sorted([t1.EVENT_POSITION_INCREASE, t1.EVENT_NEW_POSITION]),
          "isolation: user_id separates streams even on the same account string")


# ---------------------------------------------------------------------------------------------
# 14. inputs are not mutated
# ---------------------------------------------------------------------------------------------
def t_inputs_not_mutated():
    r1, r2 = run(1), run(2, health="suspicious")
    r3 = run(3)
    runs = [r1, r2, r3, run(4, status="started", run_id="ra")]
    memberships = mem((r1, [pos(101, volume=2.0), pos(202)]),
                      (r3, [pos(101, volume=4.0)]))
    runs_snap = copy.deepcopy(runs)
    mem_snap = copy.deepcopy(memberships)
    t1.detect(runs, memberships)
    check(runs == runs_snap, "purity: run metadata not mutated")
    check(memberships == mem_snap, "purity: membership rows not mutated")


# ---------------------------------------------------------------------------------------------
# input validation / event shape
# ---------------------------------------------------------------------------------------------
def t_input_validation():
    r1, r2 = run(1), run(2)

    def boom(runs, m):
        try:
            t1.detect(runs, m)
            return None
        except t1.T1InputError as e:
            return str(e)

    dup = run(1, run_id="other-run-same-seq")
    check(boom([r1, dup], mem((r1, []), (dup, []))) is not None,
          "validation: duplicate completed run_seq refused")
    check(boom([r1], {}) is not None,
          "validation: missing membership for a healthy completed run refused")
    check(boom([r1], mem((r1, [pos(101), pos(101)]))) is not None,
          "validation: duplicate position_id in one membership refused")
    check(boom([r1], mem((r1, [{"symbol_raw": "X"}]))) is not None,
          "validation: membership row without position_id refused")
    bad_health = dict(run(1), snapshot_health="odd")
    check(boom([bad_health], mem((bad_health, []))) is not None,
          "validation: completed run with unknown health refused")
    # suspicious membership NOT required (never consulted)
    s2 = run(2, health="suspicious")
    check(t1.detect([r1, s2], mem((r1, []))) == [],
          "validation: suspicious run needs no membership entry")
    # a strictly malformed row anywhere fails the WHOLE call -- no partial events. Run 1's
    # membership is perfectly valid and would otherwise diff cleanly against run 2.
    bad = mem((r1, [pos(101, volume=2.0)]), (r2, [pos(101, volume=4.0)]))
    bad[r2["run_id"]].append({**bad[r2["run_id"]][0], "position_id": 999, "side": "long"})
    check(boom([r1, r2], bad) is not None,
          "validation: one malformed row anywhere -> whole detect() call raises")


def t_event_minimum_fields():
    r1, r2, r3 = run(1), run(2), run(3)
    ev = t1.detect([r1, r2, r3],
                   mem((r1, [pos(101, volume=2.0), pos(202)]),
                       (r2, [pos(101, volume=4.0), pos(303, symbol="S50U26")]),
                       (r3, [pos(101, volume=4.0, side="sell"), pos(303, symbol="GOZ26")])))
    check(len(ev) > 0, "shape: fixture produces events")
    for e in ev:
        check(all(k in e for k in
                  ("event_type", "position_id", "before_run_id", "after_run_id")),
              f"shape: {e['event_type']} carries the four required fields")
        check(e["event_type"] in t1.EVENT_TYPES, "shape: event_type from the frozen vocabulary")


# ---------------------------------------------------------------------------------------------
# Codex adversarial round: fail-closed status domain, strict membership, exact volume, order
# ---------------------------------------------------------------------------------------------
def t_status_domain_fail_closed():
    r1 = run(1)

    def boom(runs, m):
        try:
            t1.detect(runs, m)
            return None
        except t1.T1InputError as e:
            return str(e)

    unknown = dict(run(2), snapshot_status="completed")          # unknown spelling
    check(boom([r1, unknown], mem((r1, []))) is not None,
          "status: unknown snapshot_status raises, never a silent skip")
    missing = {k: v for k, v in run(2).items() if k != "snapshot_status"}
    check(boom([r1, missing], mem((r1, []))) is not None, "status: missing status raises")
    check(boom([r1, dict(run(2), snapshot_status=None)], mem((r1, []))) is not None,
          "status: None status raises")
    check(boom([r1, dict(run(2), snapshot_status=1)], mem((r1, []))) is not None,
          "status: non-string status raises")
    # started/failed stay recognized non-authoritative attempts: ignored, no gap, no run_seq
    ok = t1.detect([r1, run(2, status="started", run_id="ra"),
                    run(3, status="failed", run_id="rb")], mem((r1, [pos(101)])))
    check(ok == [], "status: started/failed still recognized, ignored, and gap-free")


def t_membership_strict_validation():
    r1 = run(1)

    def stamped(**over):
        row = {"run_id": r1["run_id"], "user_id": r1["user_id"],
               "source_account": r1["source_account"], **pos(101)}
        row.update(over)
        return row

    def boom(rows):
        try:
            t1.detect([r1], {r1["run_id"]: rows})
            return None
        except t1.T1InputError as e:
            return str(e)

    check(t1.detect([r1], {r1["run_id"]: [stamped()]}) == [],
          "strict: a fully valid scope-stamped row is accepted")
    check(boom([stamped(run_id="someone-elses-run")]) is not None,
          "strict: cross-run membership scope refused")
    check(boom([stamped(run_id=None)]) is not None, "strict: missing row run_id refused")
    check(boom([stamped(user_id="c99f0000-9999-4999-8999-999999999999")]) is not None,
          "strict: cross-user membership scope refused")
    check(boom([stamped(source_account="999888777")]) is not None,
          "strict: cross-account membership scope refused")
    check(boom([stamped(position_id="306676142")]) is not None,
          "strict: string position_id refused")
    check(boom([stamped(position_id=True)]) is not None, "strict: bool position_id refused")
    check(boom([stamped(position_id=None)]) is not None, "strict: null position_id refused")
    check(boom([stamped(symbol_raw="   ")]) is not None, "strict: blank symbol_raw refused")
    check(boom([stamped(symbol_raw=None)]) is not None, "strict: missing symbol_raw refused")
    check(boom([stamped(side="long")]) is not None, "strict: invalid side refused")
    check(boom([stamped(side=None)]) is not None, "strict: missing side refused")
    check(boom([stamped(volume=None)]) is not None, "strict: missing volume refused")
    check(boom([stamped(volume=float("inf"))]) is not None,
          "strict: non-finite volume refused")
    check(boom([stamped(volume=float("nan"))]) is not None, "strict: NaN volume refused")
    check(boom([stamped(volume=0)]) is not None, "strict: zero volume refused")
    check(boom([stamped(volume=-2.0)]) is not None, "strict: negative volume refused")
    check(boom([stamped(volume=True)]) is not None, "strict: bool volume refused")
    check(boom([stamped(volume="2.0")]) is not None, "strict: string volume refused")


def t_numeric_position_order():
    r1, r2 = run(1), run(2)
    ev = t1.detect([r1, r2], mem((r1, []), (r2, [pos(10), pos(2)])))
    check([e["position_id"] for e in ev] == [2, 10],
          "ordering: numeric position order (2 before 10), never lexicographic '10' < '2'")


ALL = [
    t_first_observation_is_baseline, t_new_position, t_increase, t_decrease, t_disappeared,
    t_exact_volume_comparison, t_reappearance, t_identity_conflict,
    t_suspicious_gap_and_resume, t_attempts_are_not_observations, t_deterministic_ordering,
    t_isolation, t_inputs_not_mutated, t_input_validation, t_event_minimum_fields,
    t_status_domain_fail_closed, t_membership_strict_validation, t_numeric_position_order,
]


def main():
    for fn in ALL:
        try:
            fn()
        except Exception as e:                                   # noqa: BLE001
            FAILS.append(f"{fn.__name__} raised {type(e).__name__}: {e}")
    print(f"t1 detector pure tests: {CHECKS[0]} checks, "
          f"{'PASS' if not FAILS else f'{len(FAILS)} FAIL'}")
    for f in FAILS:
        print("  FAIL:", f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
