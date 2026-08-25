#!/usr/bin/env python3
"""T4A-0 cross-language parity — the Python half of the fixture chain.

ONE fixture authority: ops/mt5_import/fixtures/t3_kind_fixtures_v1.json.

This suite proves, from that single file:
  1. the fixture's sha256 metadata equals the canonical {version,cases} digest (the digest
     domain EXCLUDES the sha field — no self-reference);
  2. every VALID case, built into a REAL persisted-style capture event with the committed T3
     test builders, renders through the committed validator/renderer to exactly the expected
     kind and the expected ORDERED action list — and that list equals the committed
     KIND_ACTIONS matrix, so the fixture cannot drift from frozen T3 either;
  3. every INVALID case is rejected at its committed contract point (presence-continuity for
     coherent-vocabulary sequences, the T1 event vocabulary for unknown tokens, and the
     no-contributing-detections rule for the empty sequence);
  4. BOTH generated-SQL copies are byte-identical to a fresh generation from this fixture
     (structural parity — never a hash-literal comparison): the standalone review artifact
     T4A_t3_kind_fixture_v1.generated.sql AND the release-critical fragment EMBEDDED in
     T4A_decisions_rpc_packet.sql, which must sit inside the packet transaction BEFORE the
     migration-ledger insert (atomicity: a parity failure rolls the whole RPC install back);
  5. STATIC STRUCTURAL checks on the decision RPC's defensive uniqueness-race branch: the
     bounded ON CONFLICT + single reselect remains present with no loop. This is a text-level
     presence proof, deliberately NOT a claim of runtime branch coverage — under the supported
     serialized write path (parent FOR UPDATE lock) the branch is not naturally reachable.

The SQL half runs at APPLY TIME, inside the rpc packet's own transaction; the standalone
generated file re-runs the same cases post-apply for review.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import gen_t4a_fixture_sql as gen                                   # noqa: E402
import t1_detector as t1                                            # noqa: E402
import t2_quiet_window as t2                                        # noqa: E402
import t3_capture_prompt as t3                                      # noqa: E402
import test_t3_capture_prompt as tt                                 # noqa: E402

CHECKS = [0]
FAILS: list[str] = []

RUNS = (tt.RUN_A, tt.RUN_B, tt.RUN_C, tt.RUN_D, tt.RUN_E, tt.RUN_F)


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


def boom(fn):
    try:
        fn()
        return None
    except (t3.T3PromptError, t2.T2InputError) as e:
        return str(e)


def build_sequence(event_types):
    """One REAL detection chain for an event-type sequence, via the committed builders.

    Runs/seqs/instants chain forward; volumes chain so every per-detection direction rule
    holds. Cross-detection volume continuity is not a T1/T3 contract and is kept sensible
    only for readability.
    """
    dets, volume = [], 2.0
    for index, etype in enumerate(event_types):
        base = dict(at=tt.T0 + 60.0 * index, etype=etype,
                    before=RUNS[index], after=RUNS[index + 1],
                    before_seq=index + 1, after_seq=index + 2)
        if etype in (t1.EVENT_NEW_POSITION, t1.EVENT_REAPPEARANCE):
            volume = 4.0
            dets.append(tt.det(**base, after_volume=volume))
        elif etype == t1.EVENT_POSITION_INCREASE:
            before, volume = volume, volume + 2.0
            dets.append(tt.det(**base, before_volume=before, after_volume=volume))
        elif etype == t1.EVENT_POSITION_DECREASE:
            before, volume = volume, volume / 2.0
            dets.append(tt.det(**base, before_volume=before, after_volume=volume))
        elif etype == t1.EVENT_POSITION_DISAPPEARED:
            dets.append(tt.det(**base, before_volume=volume))
        else:                                   # POSITION_IDENTITY_CONFLICT — its own shape
            dets.append(tt.det(**base))
    return dets


def load_fixture():
    physical = json.loads(gen.FIXTURE_PATH.read_text(encoding="utf-8"))
    logical = {"version": physical["version"], "cases": physical["cases"]}
    canonical = json.dumps(logical, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False)
    canonical.encode("ascii")
    sha = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return physical, logical, sha


def t_fixture_digest_domain():
    physical, logical, sha = load_fixture()
    check(physical["sha256"] == sha,
          "the sha256 metadata equals the canonical {version,cases} digest")
    with_sha = dict(logical)
    with_sha["sha256"] = physical["sha256"]
    other = hashlib.sha256(json.dumps(with_sha, sort_keys=True, separators=(",", ":"),
                                      ensure_ascii=False).encode("utf-8")).hexdigest()
    check(other != sha, "the digest domain EXCLUDES the sha field (no self-reference)")
    check(set(logical) == {"version", "cases"}, "the digest domain is exactly version+cases")


def t_fixture_coverage_is_complete():
    _, logical, _ = load_fixture()
    valid = [c for c in logical["cases"] if c["valid"]]
    invalid = [c for c in logical["cases"] if not c["valid"]]
    check(len(valid) == 22 and len(invalid) == 10, "32 cases: 22 valid + 10 invalid")
    check({c["kind"] for c in valid}
          == {t3.KIND_ENTRY, t3.KIND_CHANGE, t3.KIND_ABSENCE, t3.KIND_CONFLICT},
          "every frozen kind is covered by at least one valid case")
    names = [c["name"] for c in logical["cases"]]
    check(len(names) == len(set(names)), "case names are unique")
    for case in valid:
        check(case["actions"] == list(t3.KIND_ACTIONS[case["kind"]]),
              f"{case['name']}: fixture actions equal the committed KIND_ACTIONS matrix")


def t_valid_cases_render_to_expected_kind_and_actions():
    _, logical, _ = load_fixture()
    for case in (c for c in logical["cases"] if c["valid"]):
        model = t3.render_capture_prompt(tt.event(build_sequence(case["event_types"])))
        check(model["kind"] == case["kind"],
              f"{case['name']}: committed T3 derives {model['kind']}, "
              f"fixture expects {case['kind']}")
        check([a["id"] for a in model["actions"]] == case["actions"],
              f"{case['name']}: committed T3 offers exactly the fixture's ordered actions")


def t_invalid_cases_are_rejected_by_the_committed_contract():
    _, logical, _ = load_fixture()
    for case in (c for c in logical["cases"] if not c["valid"]):
        seq = case["event_types"]
        unknown = [e for e in seq if e not in t1.EVENT_TYPES]
        if not seq:
            ev = tt.event([tt.det(etype=t1.EVENT_NEW_POSITION, after_volume=4.0)])
            for field in ("detections", "event_types", "detection_identities",
                          "run_references"):
                ev["payload"][field] = []
            check(boom(lambda e=ev: t3.validate_capture_event(e)) is not None,
                  f"{case['name']}: an empty evidence set is refused")
        elif unknown:
            for token in unknown:
                bad = tt.det(etype=token, after_volume=4.0)
                bad["detected_at"] = tt.T0
                check(boom(lambda b=bad: t2.validate_detection(b)) is not None,
                      f"{case['name']}: unknown event type {token!r} is refused by the "
                      f"committed T1 contract")
        else:
            dets = [{"event_type": e} for e in seq]
            check(boom(lambda d=dets: t3._validate_presence_continuity(d)) is not None,
                  f"{case['name']}: the committed presence state machine refuses {seq}")


def t_generated_sql_is_structurally_the_fixture():
    _, logical, sha = load_fixture()
    fragment = gen.render_fragment(logical, sha)
    committed = gen.GENERATED_PATH.read_text(encoding="utf-8")
    check(committed == gen.render_standalone(logical, sha),
          "the standalone SQL artifact is byte-identical to a fresh generation from the "
          "repository fixture (structural parity, not a hash literal)")
    check(f"fixture_sha256 : {sha}" in committed,
          "the standalone artifact carries the fixture sha as audit metadata")
    check(gen.EVIDENCE_SQLSTATE == "MT4E1"
          and f"sqlstate '{gen.EVIDENCE_SQLSTATE}'" in committed,
          "invalid cases assert the ONE pinned evidence SQLSTATE")
    packet_text = gen.RPC_PACKET_PATH.read_text(encoding="utf-8")
    embedded, _ = gen.extract_embedded(packet_text)
    check(embedded == fragment,
          "the fragment EMBEDDED in the rpc packet is byte-identical to a fresh generation "
          "(release-critical copy: stale embed fails before release)")
    try:
        gen.check_embedded_position(packet_text)
        positioned = True
    except SystemExit:
        positioned = False
    check(positioned,
          "the embedded fragment sits INSIDE the rpc packet transaction BEFORE the ledger "
          "insert (parity is atomic with the install)")


def _decision_rpc_body(packet_text):
    start = packet_text.index("create function public.mt5_record_capture_decision_v1")
    end = packet_text.index("$fn$;", start)
    return packet_text[start:end]


def t_static_defensive_race_branch():
    """STATIC STRUCTURAL presence proof — NOT runtime branch coverage. The supported write
    path serializes concurrent callers on the parent capture row's FOR UPDATE lock, so the
    ON CONFLICT branch is defense-in-depth and not naturally reachable; these checks pin
    that the defense stays present and bounded (single reselect, no loop, race error last)."""
    body = _decision_rpc_body(gen.RPC_PACKET_PATH.read_text(encoding="utf-8"))
    check(body.count("on conflict (capture_event_id) do nothing") == 1,
          "the decision RPC keeps exactly one defensive ON CONFLICT insert")
    check(body.count("'ERR_DECISION_RACE'") == 1,
          "the bounded fail-closed race code remains the branch's last resort")
    check(" loop" not in body and "\nloop" not in body,
          "the race reselect is a single bounded pass — no loop in the decision RPC body")
    check(body.count("from public.mt5_capture_decisions d") == 2,
          "exactly two existing-decision reads: the pre-insert load and ONE race reselect")
    check("for update" in body,
          "the parent capture FOR UPDATE lock (what actually serializes supported writers) "
          "is present")


ALL = [
    t_fixture_digest_domain,
    t_fixture_coverage_is_complete,
    t_valid_cases_render_to_expected_kind_and_actions,
    t_invalid_cases_are_rejected_by_the_committed_contract,
    t_generated_sql_is_structurally_the_fixture,
    t_static_defensive_race_branch,
]


def main():
    for test in ALL:
        test()
    if FAILS:
        for f in FAILS:
            print(f"FAIL: {f}")
        print(f"t3 kind fixture parity: {CHECKS[0]} checks, {len(FAILS)} FAILED")
        return 1
    print(f"t3 kind fixture parity: {CHECKS[0]} checks, PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
