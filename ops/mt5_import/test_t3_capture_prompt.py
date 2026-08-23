#!/usr/bin/env python3
"""Pure tests for the T3 capture-prompt renderer.

Fixtures are built through the REAL pipeline — t1 event shapes -> t2.coalesce ->
t2_capture_adapter.build_capture_payload -> a persisted-style row — so a drift in any of those
contracts shows up here as a failure rather than as a stale local copy that still passes.
"""
from __future__ import annotations

import ast
import copy
import datetime as _dt
import json
import pathlib
import sys

try:                                     # package mode
    from . import t1_detector as t1
    from . import t2_capture_adapter as t2a
    from . import t2_quiet_window as t2
    from . import t3_capture_prompt as t3
except ImportError:                      # script mode
    import t1_detector as t1                                              # noqa: E402
    import t2_capture_adapter as t2a                                      # noqa: E402
    import t2_quiet_window as t2                                          # noqa: E402
    import t3_capture_prompt as t3                                        # noqa: E402

CHECKS = [0]
FAILS = []

UID = "b77d0426-1111-4222-8333-444455556666"
ACCT = "301102520"
RUN_A = "3f1a0000-0000-4000-8000-00000000000a"
RUN_B = "3f1a0000-0000-4000-8000-00000000000b"
RUN_C = "3f1a0000-0000-4000-8000-00000000000c"
RUN_D = "3f1a0000-0000-4000-8000-00000000000d"
RUN_E = "3f1a0000-0000-4000-8000-00000000000e"
RUN_F = "3f1a0000-0000-4000-8000-00000000000f"
EVENT_ID = "9c0e1d22-0000-4000-8000-0000000000e1"
QW = 300.0
T0 = 1_787_000_000.0


def check(cond, label):
    CHECKS[0] += 1
    if not cond:
        FAILS.append(label)


def boom(fn):
    try:
        fn()
        return None
    except (t3.T3PromptError, t2a.T2AdapterError, t2.T2InputError) as e:
        return str(e)


def det(*, at=T0, etype=t1.EVENT_POSITION_INCREASE, before=RUN_A, after=RUN_B,
        before_seq=1, after_seq=2, pid=101, **over):
    d = {"event_type": etype, "position_id": pid,
         "before_run_id": before, "after_run_id": after,
         "before_run_seq": before_seq, "after_run_seq": after_seq,
         "user_id": UID, "source_account": ACCT}
    if etype == t1.EVENT_POSITION_IDENTITY_CONFLICT:
        d.update(before_symbol_raw="DELTAU26", after_symbol_raw="S50U26",
                 before_side="buy", after_side="sell", before_volume=2.0, after_volume=2.0)
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


def event(detections=None, *, event_id=EVENT_ID):
    """A persisted-style mt5_capture_events row, built from a real adapter payload."""
    ds = detections if detections is not None else [det()]
    cands = t2.coalesce(ds, quiet_window_seconds=QW)
    assert len(cands) == 1, f"fixture produced {len(cands)} candidates"
    payload = t2a.build_capture_payload(cands[0], now=cands[0]["quiet_deadline"] + 1.0)
    return {
        "id": event_id,
        "created_at": "2026-08-23T09:07:01.500000+00:00",
        "event_key": "0" * 64,
        "payload_fingerprint": "1" * 64,
        "user_id": payload["user_id"],
        "source_account": payload["source_account"],
        "position_id": payload["position_id"],
        "basis_run_id": payload["basis_run_id"],
        "first_detection_at": payload["first_detection_at"],
        "last_detection_at": payload["last_detection_at"],
        "quiet_deadline": payload["quiet_deadline"],
        "quiet_window_seconds": payload["quiet_window_seconds"],
        "detector_version": payload["detector_version"],
        "aggregator_version": payload["aggregator_version"],
        "payload": payload,
    }


def text_of(model):
    return json.dumps(model, ensure_ascii=False, sort_keys=True)


# ---------------------------------------------------------------------------------------------
# every T1 event type renders TRUTHFUL wording
# ---------------------------------------------------------------------------------------------
def t_wording_per_event_type():
    expected = {
        t1.EVENT_NEW_POSITION: ("พบ position ใหม่ใน MT5", t3.KIND_ENTRY),
        t1.EVENT_REAPPEARANCE: ("พบ position นี้กลับมาใน snapshot อีกครั้ง", t3.KIND_ENTRY),
        t1.EVENT_POSITION_INCREASE: ("volume เปลี่ยน 2 → 4 ระหว่างการตรวจสองครั้ง",
                                     t3.KIND_CHANGE),
        t1.EVENT_POSITION_DECREASE: ("volume เปลี่ยน 2 → 1 ระหว่างการตรวจสองครั้ง",
                                     t3.KIND_CHANGE),
        t1.EVENT_POSITION_DISAPPEARED: ("ไม่พบ position นี้ใน snapshot ล่าสุด", t3.KIND_ABSENCE),
    }
    for etype, (phrase, kind) in expected.items():
        model = t3.render_capture_prompt(event([det(etype=etype)]))
        check(any(phrase in line for line in model["lines"]),
              f"wording: {etype} says {phrase!r}")
        check(model["kind"] == kind, f"wording: {etype} is {kind}")
        check(model["symbol"] == "DELTAU26" and model["position_id"] == 101,
              f"wording: {etype} carries its symbol and position")

    # every T1 event type is covered by a wording rule, so a new one cannot render blank
    covered = set(t3.EVENT_WORDING) | {t1.EVENT_POSITION_IDENTITY_CONFLICT}
    check(covered == set(t1.EVENT_TYPES),
          "wording: every T1 event type has a rule and nothing extra")
    check(set(t3.EVENT_KIND) == set(t1.EVENT_TYPES),
          "wording: every T1 event type maps to a kind")
    check(set(t3.EVENT_HEADLINE) == set(t1.EVENT_TYPES),
          "wording: every T1 event type has its own headline")
    # a REAPPEARANCE is ENTRY-kind, but its headline must not claim the position is new
    reappeared = t3.render_capture_prompt(event([det(etype=t1.EVENT_REAPPEARANCE)]))
    check(reappeared["headline"] == "position กลับมาใน snapshot"
          and "ใหม่" not in reappeared["headline"],
          "wording: a REAPPEARANCE headline does not call the position new")


# ---------------------------------------------------------------------------------------------
# a DECREASE is a smaller number, not a sale
# ---------------------------------------------------------------------------------------------
def t_decrease_infers_nothing():
    model = t3.render_capture_prompt(event([det(etype=t1.EVENT_POSITION_DECREASE)]))
    blob = text_of(model).lower()
    for token in ("ขายออก", "ซื้อเพิ่ม", "partial close", "ปิด position", "closed",
                  "realized", "กำไร", "ขาดทุน"):
        check(token not in blob, f"decrease: never says {token!r}")
    check(model["volume_before"] == 2.0 and model["volume_after"] == 1.0,
          "decrease: before and after volumes are the evidence, unchanged")
    check(model["volume_text"] == "2 → 1", "decrease: renders the change as 2 → 1")
    check([a["id"] for a in model["actions"]] == ["already_logged", "no_record"],
          "decrease: offers no Journal add — the target trade is unresolved")


def t_disappeared_never_says_closed():
    model = t3.render_capture_prompt(event([det(etype=t1.EVENT_POSITION_DISAPPEARED)]))
    blob = text_of(model).lower()
    for token in ("closed", "ปิด position", "ปิดออเดอร์", "ราคาปิด", "close price",
                  "realized", "realised", "pnl", "p/l"):
        check(token not in blob, f"disappeared: never says {token!r}")
    check(any("ไม่พบ position นี้ใน snapshot ล่าสุด" in line for line in model["lines"]),
          "disappeared: says only that the latest snapshot does not have it")
    check(any("S2" in line for line in model["lines"]),
          "disappeared: says the cause is unknown without deal evidence")
    check(model["kind"] == t3.KIND_ABSENCE, "disappeared: is an ABSENCE, not a close")


def t_identity_conflict_warns():
    model = t3.render_capture_prompt(event([det(etype=t1.EVENT_POSITION_IDENTITY_CONFLICT)]))
    check(model["kind"] == t3.KIND_CONFLICT, "conflict: is its own kind")
    check(any("หลักฐานขัดแย้งกัน" in line for line in model["lines"]),
          "conflict: is flagged in the evidence, not smoothed over")
    check("DELTAU26" in text_of(model) and "S50U26" in text_of(model),
          "conflict: shows BOTH identities the snapshots reported")
    check(model["symbol"] is None and model["side"] is None,
          "conflict: refuses to pick one symbol/side as if it were settled")
    check(model["volume_before"] is None and model["volume_after"] is None
          and model["volume_text"] is None,
          "conflict: shows no before -> after span — the two volumes are different instruments")
    check("volume 2" in model["lines"][0],
          "conflict: both reported volumes stay visible inside the conflict line")
    check([a["id"] for a in model["actions"]] == ["no_record"],
          "conflict: offers no answer button beyond dismissal")


# ---------------------------------------------------------------------------------------------
# provenance / identity retained
# ---------------------------------------------------------------------------------------------
def t_provenance_retained():
    ds = [det(), det(at=T0 + 60, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3,
               before_volume=4.0, after_volume=6.0)]
    e = event(ds)
    model = t3.render_capture_prompt(e)
    check(model["capture_event_id"] == EVENT_ID, "provenance: capture_event_id is carried")
    check(model["event_key"] == e["event_key"], "provenance: event_key is carried")
    check(model["provenance"]["basis_run_id"] == RUN_C,
          "provenance: basis_run_id is carried verbatim")
    check(model["provenance"]["event_types"] == e["payload"]["event_types"],
          "provenance: the contributing event types are carried")
    check(model["provenance"]["detector_version"] == t2a.DETECTOR_VERSION
          and model["provenance"]["aggregator_version"] == t2a.AGGREGATOR_VERSION,
          "provenance: the producing versions are carried")
    check(len(model["lines"]) == 3, "provenance: one line per detection plus the note")
    check(model["observed"]["detection_count"] == 2,
          "provenance: the observation count is the real one")
    check(model["volume_before"] == 2.0 and model["volume_after"] == 6.0,
          "provenance: the span is first.before -> last.after across the whole window")
    check(model["observed"]["first_detection_at"] == "2026-08-17 20:53:20 UTC"
          and model["observed"]["last_detection_at"] == "2026-08-17 20:54:20 UTC",
          "provenance: instants are rendered in UTC and labelled UTC")


def t_entry_offers_journal_add():
    model = t3.render_capture_prompt(event([det(etype=t1.EVENT_NEW_POSITION)]))
    check([a["id"] for a in model["actions"]]
          == ["journal_add", "already_logged", "no_record"],
          "entry: offers add / already logged / no record")
    check([a["label"] for a in model["actions"]]
          == ["เพิ่มเข้า Journal", "ลงเองแล้ว", "ไม่ต้องจด"],
          "entry: the labels are the agreed wording")
    check(all(a["writes_journal"] is False for a in model["actions"]),
          "entry: every action is an OFFER — a rendered button is not a write")
    blob = text_of(model)
    check("รวม Position เดิม" not in blob and "merge_with_existing" not in blob,
          "entry: the group-merge action is deferred, not guessed")


def t_no_target_is_guessed():
    for etype in t1.EVENT_TYPES:
        model = t3.render_capture_prompt(event([det(etype=etype)]))
        blob = text_of(model)
        for banned in t2a.FORBIDDEN_PAYLOAD_KEYS:
            check(f'"{banned}"' not in blob, f"target: {etype} carries no {banned!r} field")
        check(t2a._forbidden_key_in(model) is None,
              f"target: {etype} carries no decision state at any depth")


# ---------------------------------------------------------------------------------------------
# determinism, purity, fail-closed
# ---------------------------------------------------------------------------------------------
def t_deterministic():
    e = event([det(), det(at=T0 + 30, before=RUN_B, after=RUN_C, before_seq=2, after_seq=3,
                          before_volume=4.0, after_volume=6.0)])
    first = t3.canonical_prompt_json(t3.render_capture_prompt(copy.deepcopy(e)))
    second = t3.canonical_prompt_json(t3.render_capture_prompt(copy.deepcopy(e)))
    check(first == second, "determinism: the same event renders byte-identically")
    other = t3.render_capture_prompt(event([det(etype=t1.EVENT_NEW_POSITION)]))
    check(t3.canonical_prompt_json(other) != first,
          "determinism: different evidence renders differently")


def t_input_not_mutated():
    e = event([det()])
    before = copy.deepcopy(e)
    model = t3.render_capture_prompt(e)
    check(e == before, "purity: the capture event is not mutated")
    model["lines"].append("tampered")
    model["provenance"]["event_types"].append("tampered")
    check(e == before, "purity: the model shares no mutable structure with the input")


def t_malformed_fails_closed():
    good = event([det()])

    def raises(mutate):
        broken = copy.deepcopy(good)
        mutate(broken)
        return boom(lambda: t3.render_capture_prompt(broken))

    check(boom(lambda: t3.render_capture_prompt("nope")) is not None,
          "closed: a non-dict event is refused")
    check(raises(lambda b: b.pop("event_key")) is not None,
          "closed: a missing column is refused")
    check(raises(lambda b: b.update(extra=1)) is not None,
          "closed: an unexpected column is refused")
    check(raises(lambda b: b.update(id="3F1A0000-0000-4000-8000-00000000000A")) is not None,
          "closed: a non-canonical capture id is refused")
    check(raises(lambda b: b.update(id=None)) is not None, "closed: a null capture id is refused")
    check(raises(lambda b: b.update(event_key="  ")) is not None,
          "closed: a blank event_key is refused")
    check(raises(lambda b: b.update(position_id=999)) is not None,
          "closed: a column that disagrees with the payload is refused")
    check(raises(lambda b: b.update(source_account="OTHER")) is not None,
          "closed: an account that disagrees with the payload is refused")
    check(raises(lambda b: b["payload"].pop("detections")) is not None,
          "closed: a payload missing an array is refused")
    check(raises(lambda b: b["payload"].update(domain="mt5.t2.capture/2")) is not None,
          "closed: a foreign payload domain is refused")
    check(raises(lambda b: b["payload"].__setitem__("detections", [])) is not None,
          "closed: an event with no detections is refused")
    check(raises(lambda b: b["payload"]["detections"][0].update(event_type="SOMETHING")) is not None,
          "closed: an unknown event type is refused")
    check(raises(lambda b: b["payload"]["detections"][0].update(after_volume=float("inf")))
          is not None, "closed: a non-finite volume is refused")
    check(raises(lambda b: b["payload"]["event_types"].append("NEW_POSITION")) is not None,
          "closed: provenance arrays that do not line up are refused")
    check(raises(lambda b: b["payload"].update(first_detection_at="yesterday")) is not None,
          "closed: an instant that is not the T2 envelope form is refused")


def t_no_account_facts_leak():
    for etype in t1.EVENT_TYPES:
        blob = text_of(t3.render_capture_prompt(event([det(etype=etype)]))).lower()
        for token in t2a.FORBIDDEN_PAYLOAD_TOKENS:
            check(token not in blob, f"money: {etype} never renders {token!r}")

    # and a row that smuggles account money in never renders at all
    smuggled = event([det()])
    smuggled["payload"]["detections"][0]["equity"] = 123456.0
    check(boom(lambda: t3.render_capture_prompt(smuggled)) is not None,
          "money: a capture event carrying account money is refused outright")


def t_forbidden_inference_is_structural():
    """The wording rules are not a convention — the renderer checks itself."""
    original = dict(t3.EVENT_WORDING)
    try:
        t3.EVENT_WORDING[t1.EVENT_POSITION_DECREASE] = "ขายออก {before} → {after}"
        check(boom(lambda: t3.render_capture_prompt(
            event([det(etype=t1.EVENT_POSITION_DECREASE)]))) is not None,
            "structural: wording that infers a broker action is refused by the renderer itself")
    finally:
        t3.EVENT_WORDING.clear()
        t3.EVENT_WORDING.update(original)
    check(t3.render_capture_prompt(event([det(etype=t1.EVENT_POSITION_DECREASE)]))["kind"]
          == t3.KIND_CHANGE, "structural: the restored wording still renders")


def t_no_write_or_network_imports():
    """A renderer that can reach Telegram, Supabase or the filesystem is not a renderer."""
    source = pathlib.Path(t3.__file__).with_suffix(".py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:                       # relative: siblings in this package
                imported.update(a.name for a in node.names)
            elif node.module:
                imported.add(node.module.split(".")[0])
    allowed = {"__future__", "datetime", "json", "math", "decimal",
               "t1_detector", "t2_capture_adapter", "t2_quiet_window"}
    check(imported <= allowed,
          f"boundary: imports only pure stdlib and sibling contracts (extra: "
          f"{sorted(imported - allowed)})")
    for banned in ("requests", "httpx", "urllib", "socket", "http", "supabase", "telegram",
                   "psycopg", "psycopg2", "sqlite3", "subprocess", "os", "pathlib"):
        check(banned not in imported, f"boundary: does not import {banned}")
    check("open(" not in source and "def send" not in source and "def post" not in source,
          "boundary: no file handle, no send, no post")


# ---------------------------------------------------------------------------------------------
# timestamps are INSTANTS, not text
# ---------------------------------------------------------------------------------------------
def t_instant_normalisation():
    """A driver may hand back Z, an explicit offset, or an aware datetime. Same moment."""
    good = event([det()])
    utc_text = good["first_detection_at"]                    # ...Z, as T2 renders it
    moment = t3.to_instant(utc_text)

    def rendered(mutate):
        row = copy.deepcopy(good)
        mutate(row)
        return t3.render_capture_prompt(row)

    baseline = t3.render_capture_prompt(copy.deepcopy(good))["observed"]["first_detection_at"]

    offset_text = moment.isoformat()                          # 2026-...+00:00
    check(offset_text.endswith("+00:00") and offset_text != utc_text,
          "instant: the fixture really does compare two different spellings")
    check(rendered(lambda r: r.update(first_detection_at=offset_text))
          ["observed"]["first_detection_at"] == baseline,
          "instant: Z and +00:00 are the same instant")

    bangkok = moment.astimezone(_dt.timezone(_dt.timedelta(hours=7))).isoformat()
    check(bangkok.endswith("+07:00"), "instant: the fixture really is a +07:00 spelling")
    check(rendered(lambda r: r.update(first_detection_at=bangkok))
          ["observed"]["first_detection_at"] == baseline,
          "instant: a +07:00 spelling of the same moment is accepted, rendered in UTC")

    check(rendered(lambda r: r.update(first_detection_at=moment))
          ["observed"]["first_detection_at"] == baseline,
          "instant: an aware datetime column equals the payload string")
    check(rendered(lambda r: r.update(created_at=moment))["kind"] == t3.KIND_CHANGE,
          "instant: an aware datetime created_at is accepted")

    def raises(mutate):
        row = copy.deepcopy(good)
        mutate(row)
        return boom(lambda: t3.render_capture_prompt(row))

    later = (moment + _dt.timedelta(seconds=1)).isoformat()
    check(raises(lambda r: r.update(first_detection_at=later)) is not None,
          "instant: a genuinely different instant is refused")
    check(raises(lambda r: r.update(first_detection_at=moment.replace(tzinfo=None))) is not None,
          "instant: a NAIVE datetime is refused — it names no instant")
    check(raises(lambda r: r.update(created_at=moment.replace(tzinfo=None))) is not None,
          "instant: a naive created_at is refused too")
    for bad in ("infinity", "-infinity", "now", "2026-08-17 20:53:20", "yesterday", "", "   "):
        check(raises(lambda r, bad=bad: r.update(first_detection_at=bad)) is not None,
              f"instant: {bad!r} is refused")
    for bad in (1787000000.0, 1787000000, True, None, ["2026-08-17T20:53:20Z"]):
        check(raises(lambda r, bad=bad: r.update(first_detection_at=bad)) is not None,
              f"instant: {bad!r} is not a timestamp")
    check(raises(lambda r: r["payload"].update(quiet_deadline="not-a-time")) is not None,
          "instant: a malformed payload instant is refused")


# ---------------------------------------------------------------------------------------------
# the whole sequence decides — presence segments and the absence boundary
# ---------------------------------------------------------------------------------------------
def seq(*detections):
    return event(list(detections))


def t_mixed_sequences():
    # 1. NEW -> INCREASE stays an ENTRY: the Journal path is not lost because volume moved
    model = t3.render_capture_prompt(seq(
        det(etype=t1.EVENT_NEW_POSITION, after_volume=4.0),
        det(at=T0 + 60, etype=t1.EVENT_POSITION_INCREASE, before=RUN_B, after=RUN_C,
            before_seq=2, after_seq=3, before_volume=4.0, after_volume=6.0)))
    check(model["kind"] == t3.KIND_ENTRY, "seq1: NEW -> INCREASE is an ENTRY")
    check("journal_add" in [a["id"] for a in model["actions"]],
          "seq1: the Journal-add path survives a volume change after entry")
    check(model["headline"] == "พบ position ใหม่", "seq1: the headline speaks for the entry")
    check(model["volume_text"] == "4 → 6", "seq1: the span covers the presence segment")
    check(model["lines"][0].startswith("พบ position ใหม่ใน MT5")
          and "4 → 6" in model["lines"][1], "seq1: both detections keep their own line")

    # 2. NEW -> DECREASE while still present is still an ENTRY
    model = t3.render_capture_prompt(seq(
        det(etype=t1.EVENT_NEW_POSITION, after_volume=4.0),
        det(at=T0 + 60, etype=t1.EVENT_POSITION_DECREASE, before=RUN_B, after=RUN_C,
            before_seq=2, after_seq=3, before_volume=4.0, after_volume=1.0)))
    check(model["kind"] == t3.KIND_ENTRY, "seq2: NEW -> DECREASE is still an ENTRY")
    check("journal_add" in [a["id"] for a in model["actions"]],
          "seq2: the Journal-add path survives a decrease after entry")
    check(model["volume_text"] == "4 → 1", "seq2: the span covers the presence segment")

    # 3. NEW -> DISAPPEARED ends the presence
    model = t3.render_capture_prompt(seq(
        det(etype=t1.EVENT_NEW_POSITION, after_volume=4.0),
        det(at=T0 + 60, etype=t1.EVENT_POSITION_DISAPPEARED, before=RUN_B, after=RUN_C,
            before_seq=2, after_seq=3, before_volume=4.0)))
    check(model["kind"] == t3.KIND_ABSENCE, "seq3: NEW -> DISAPPEARED is an ABSENCE")
    check("journal_add" not in [a["id"] for a in model["actions"]],
          "seq3: nothing is offered for adding a position that is no longer there")
    check(model["volume_before"] == 4.0 and model["volume_after"] is None
          and model["volume_text"] is None,
          "seq3: the last observed volume, and nothing after it")
    check("closed" not in text_of(model).lower() and "ปิด position" not in text_of(model),
          "seq3: an absence is still not a close")

    # 4. DISAPPEARED -> REAPPEARANCE: an entry again, with NO span across the gap
    model = t3.render_capture_prompt(seq(
        det(etype=t1.EVENT_POSITION_DISAPPEARED, before_volume=2.0),
        det(at=T0 + 60, etype=t1.EVENT_REAPPEARANCE, before=RUN_B, after=RUN_C,
            before_seq=2, after_seq=3, after_volume=4.0)))
    check(model["kind"] == t3.KIND_ENTRY, "seq4: DISAPPEARED -> REAPPEARANCE is an ENTRY")
    check(model["headline"] == "position กลับมาใน snapshot",
          "seq4: the headline says it came back, not that it is new")
    check(model["volume_before"] is None and model["volume_text"] is None,
          "seq4: no 2 → 4 across the gap — the position was not observed continuously")
    check(model["volume_after"] == 4.0, "seq4: the volume it came back with is still evidence")
    check("2 → 4" not in text_of(model), "seq4: the bridged span appears nowhere")
    check(model["observed"]["crosses_absence"] is True,
          "seq4: the absence boundary is stated, not hidden")
    check(any(t3.ABSENCE_BOUNDARY_NOTE == line for line in model["lines"]),
          "seq4: the human is told why there is no span")

    # 5. DISAPPEARED -> REAPPEARANCE -> INCREASE: the span covers only the final segment
    model = t3.render_capture_prompt(seq(
        det(etype=t1.EVENT_POSITION_DISAPPEARED, before_volume=2.0),
        det(at=T0 + 60, etype=t1.EVENT_REAPPEARANCE, before=RUN_B, after=RUN_C,
            before_seq=2, after_seq=3, after_volume=4.0),
        det(at=T0 + 120, etype=t1.EVENT_POSITION_INCREASE, before=RUN_C, after=RUN_D,
            before_seq=3, after_seq=4, before_volume=4.0, after_volume=6.0)))
    check(model["kind"] == t3.KIND_ENTRY, "seq5: the final segment still opens with a return")
    check(model["volume_text"] == "4 → 6",
          "seq5: the span covers the final presence segment only")
    check("2 → 6" not in text_of(model) and model["volume_before"] == 4.0,
          "seq5: the pre-disappearance volume never enters the span")
    check(len(model["lines"]) >= 3, "seq5: every detection keeps its own line")

    # 6. it comes back as something else
    model = t3.render_capture_prompt(seq(
        det(etype=t1.EVENT_POSITION_DISAPPEARED, before_volume=2.0),
        det(at=T0 + 60, etype=t1.EVENT_REAPPEARANCE, before=RUN_B, after=RUN_C,
            before_seq=2, after_seq=3, after_volume=4.0, symbol_raw="S50U26", side="sell")))
    blob = text_of(model)
    check(model["symbol"] is None and model["side"] is None,
          "seq6: incompatible identities are not resolved into one")
    check(any("ก่อนหาย" in line and "กลับมา" in line for line in model["lines"]),
          "seq6: the identity difference gets its own evidence line")
    check("DELTAU26" in blob and "S50U26" in blob and "buy" in blob and "sell" in blob,
          "seq6: both observed identities stay visible")
    check(model["volume_text"] is None, "seq6: still no fake continuous span")

    # 7. a row that claims INCREASE while carrying 2 -> 1
    broken = seq(det(etype=t1.EVENT_POSITION_INCREASE, before_volume=2.0, after_volume=4.0))
    broken["payload"]["detections"][0]["after_volume"] = 1.0
    reason = boom(lambda: t3.render_capture_prompt(broken))
    check(reason is not None, "seq7: an INCREASE carrying 2 -> 1 is refused")
    rendered = boom(lambda: t3.render_capture_prompt(broken)) or ""
    check("เพิ่มขึ้น" not in rendered and "2 → 1" not in rendered,
          "seq7: the refusal does not print the impossible claim as if it were true")

    # 8. arrays that merely line up in length
    # two DIFFERENT event types, so swapping event_types is a real swap and not a no-op
    two = seq(det(etype=t1.EVENT_NEW_POSITION, after_volume=4.0),
              det(at=T0 + 60, etype=t1.EVENT_POSITION_INCREASE, before=RUN_B, after=RUN_C,
                  before_seq=2, after_seq=3, before_volume=4.0, after_volume=6.0))

    def swapped(key):
        row = copy.deepcopy(two)
        row["payload"][key][0], row["payload"][key][1] = (row["payload"][key][1],
                                                          row["payload"][key][0])
        return boom(lambda: t3.render_capture_prompt(row))

    check(swapped("detection_identities") is not None,
          "seq8: swapped detection_identities are refused")
    check(swapped("run_references") is not None, "seq8: swapped run_references are refused")
    check(swapped("event_types") is not None, "seq8: swapped event_types are refused")

    # 10. an absence with nothing reopening after it. A position cannot grow while it is
    # absent, so this is not one position observed carefully — it is not one position at all,
    # and rendering it truthfully would still be rendering something that never happened.
    reason = boom(lambda: t3.render_capture_prompt(seq(
        det(etype=t1.EVENT_POSITION_DISAPPEARED, before_volume=2.0),
        det(at=T0 + 60, etype=t1.EVENT_POSITION_INCREASE, before=RUN_B, after=RUN_C,
            before_seq=2, after_seq=3, before_volume=4.0, after_volume=6.0))))
    check(reason is not None, "seq10: DISAPPEARED -> INCREASE is REFUSED, not classified")
    check("ABSENT" in (reason or ""), "seq10: the refusal names the broken continuity")

    # 9. a realistic driver serialisation of the same row
    realistic = copy.deepcopy(two)
    for field in ("first_detection_at", "last_detection_at", "quiet_deadline"):
        realistic[field] = t3.to_instant(realistic[field]).isoformat()
    realistic["created_at"] = t3.to_instant(realistic["created_at"])
    check(t3.canonical_prompt_json(t3.render_capture_prompt(realistic))
          == t3.canonical_prompt_json(t3.render_capture_prompt(copy.deepcopy(two))),
          "seq9: a driver-serialised row renders identically to the T2-rendered one")


def t_presence_continuity():
    """The complete transition table, exercised in both directions.

    All detections in a candidate are about ONE position_id, so the sequence has to describe one
    position's life. A candidate may START anywhere — the quiet window need not begin at the
    position's first observation — but once it has begun, something already being observed
    cannot appear, and something absent can only come back as a REAPPEARANCE.
    """
    RUNS = [RUN_A, RUN_B, RUN_C, RUN_D, RUN_E, RUN_F]

    def step(etype, index):
        """One detection at chain position `index`, with that event type's own T1 fields."""
        return det(at=T0 + 60 * index, etype=etype,
                   before=RUNS[index], after=RUNS[index + 1],
                   before_seq=index + 1, after_seq=index + 2)

    def render(*types):
        return lambda: t3.render_capture_prompt(
            seq(*[step(etype, index) for index, etype in enumerate(types)]))

    NEW = t1.EVENT_NEW_POSITION
    BACK = t1.EVENT_REAPPEARANCE
    UP = t1.EVENT_POSITION_INCREASE
    DOWN = t1.EVENT_POSITION_DECREASE
    GONE = t1.EVENT_POSITION_DISAPPEARED
    CLASH = t1.EVENT_POSITION_IDENTITY_CONFLICT
    SHORT = {NEW: "NEW", BACK: "REAPPEARANCE", UP: "INCREASE", DOWN: "DECREASE",
             GONE: "DISAPPEARED", CLASH: "IDENTITY_CONFLICT"}

    def name(types):
        return " -> ".join(SHORT[t] for t in types)

    # ---- UNKNOWN accepts any individually-valid first event -----------------------------------
    for etype in (NEW, BACK, UP, DOWN, CLASH, GONE):
        model = t3.render_capture_prompt(seq(step(etype, 0)))
        check(model["kind"] in (t3.KIND_ENTRY, t3.KIND_CHANGE, t3.KIND_ABSENCE,
                                t3.KIND_CONFLICT),
              f"continuity: a candidate STARTING with {SHORT[etype]} is accepted")

    # ---- from PRESENT: nothing may appear again ----------------------------------------------
    for types in ((NEW, NEW), (NEW, BACK), (UP, BACK), (DOWN, NEW), (CLASH, BACK)):
        reason = boom(render(*types))
        check(reason is not None, f"continuity: {name(types)} is refused (already PRESENT)")
        check("PRESENT" in (reason or ""),
              f"continuity: the {name(types)} refusal names the PRESENT state")

    # ---- from ABSENT: only a REAPPEARANCE may follow ------------------------------------------
    for second in (NEW, UP, DOWN, CLASH, GONE):
        reason = boom(render(GONE, second))
        check(reason is not None,
              f"continuity: {name((GONE, second))} is refused (still ABSENT)")
        check("ABSENT" in (reason or ""),
              f"continuity: the {name((GONE, second))} refusal names the ABSENT state")

    # ---- the sequences that ARE one position's life ------------------------------------------
    for types in ((NEW, UP), (NEW, DOWN), (UP, DOWN), (UP, GONE), (GONE, BACK),
                  (GONE, BACK, UP), (NEW, UP, GONE, BACK, DOWN)):
        model = t3.render_capture_prompt(seq(
            *[step(etype, index) for index, etype in enumerate(types)]))
        check(model["kind"] in (t3.KIND_ENTRY, t3.KIND_CHANGE, t3.KIND_ABSENCE),
              f"continuity: {name(types)} is accepted")
    # and the classification of the two that matter most
    check(t3.render_capture_prompt(seq(step(GONE, 0), step(BACK, 1), step(UP, 2)))["kind"]
          == t3.KIND_ENTRY, "continuity: DISAPPEARED -> REAPPEARANCE -> INCREASE is an ENTRY")
    check(t3.render_capture_prompt(seq(step(NEW, 0), step(UP, 1), step(GONE, 2), step(BACK, 3),
                                       step(DOWN, 4)))["kind"] == t3.KIND_ENTRY,
          "continuity: a full appear/grow/vanish/return/shrink life is an ENTRY at the end")

    # ---- the state machine itself, called directly --------------------------------------------
    def states(*types):
        return [{"event_type": t} for t in types]

    check(t3._validate_presence_continuity([]) == t3.PRESENCE_UNKNOWN,
          "continuity: an empty sequence is UNKNOWN, not asserted either way")
    check(t3._validate_presence_continuity(states(NEW)) == t3.PRESENCE_PRESENT,
          "continuity: NEW leaves the position PRESENT")
    check(t3._validate_presence_continuity(states(GONE)) == t3.PRESENCE_ABSENT,
          "continuity: DISAPPEARED leaves the position ABSENT")
    check(t3._validate_presence_continuity(states(UP)) == t3.PRESENCE_PRESENT,
          "continuity: a candidate that starts mid-life ends PRESENT")
    check(t3._validate_presence_continuity(
        states(GONE, BACK, UP, GONE, BACK)) == t3.PRESENCE_PRESENT,
        "continuity: repeated vanish/return cycles are fine while each return is explicit")
    check(boom(lambda: t3._validate_presence_continuity(
        states(NEW, GONE, DOWN))) is not None,
        "continuity: an absence later in the sequence still blocks what follows it")
    check(boom(lambda: t3._validate_presence_continuity(
        states(UP, NEW))) is not None,
        "continuity: a present position cannot be discovered as new")


def t_evidence_is_revalidated():
    """The committed T2 core owns event semantics; T3 reuses it rather than restating it."""
    good = seq(det())

    def raises(mutate):
        row = copy.deepcopy(good)
        mutate(row)
        return boom(lambda: t3.render_capture_prompt(row))

    check(raises(lambda r: r["payload"]["detections"][0].pop("symbol_raw")) is not None,
          "revalidate: a detection missing a T1 field is refused")
    check(raises(lambda r: r["payload"]["detections"][0].update(extra=1)) is not None,
          "revalidate: a detection carrying an extra field is refused")
    check(raises(lambda r: r["payload"]["detections"][0].update(side="long")) is not None,
          "revalidate: a side outside the T1 vocabulary is refused")
    check(raises(lambda r: r["payload"]["detections"][0].update(before_volume=0.0)) is not None,
          "revalidate: a non-positive volume is refused")
    check(raises(lambda r: r["payload"]["detections"][0].update(before_run_seq=5)) is not None,
          "revalidate: before_run_seq >= after_run_seq is refused")
    check(raises(lambda r: r["payload"]["detections"][0].update(after_run_id=RUN_A)) is not None,
          "revalidate: a delta naming one run twice is refused")
    check(raises(lambda r: r["payload"]["run_references"][0].update(after_run_seq=9)) is not None,
          "revalidate: a run_reference disagreeing with its detection is refused")
    check(raises(lambda r: r["payload"]["detections"][0].update(position_id=999)) is not None,
          "revalidate: a detection about another position is refused")
    # and the one specification lives upstream, not here
    check(t3.EVENT_WORDING.keys() <= set(t2.T1_EVENT_FIELDS),
          "revalidate: the wording table cannot outgrow the T1 contract")


GROUPS = [
    t_wording_per_event_type, t_decrease_infers_nothing, t_disappeared_never_says_closed,
    t_identity_conflict_warns, t_provenance_retained, t_entry_offers_journal_add,
    t_no_target_is_guessed, t_deterministic, t_input_not_mutated, t_malformed_fails_closed,
    t_no_account_facts_leak, t_forbidden_inference_is_structural,
    t_no_write_or_network_imports,
    t_instant_normalisation, t_mixed_sequences, t_presence_continuity,
    t_evidence_is_revalidated,
]


def main():
    for group in GROUPS:
        group()
    for failure in FAILS:
        print(f"FAIL: {failure}")
    print(f"t3 capture prompt pure tests: {CHECKS[0]} checks, "
          f"{'PASS' if not FAILS else f'{len(FAILS)} FAILURE(S)'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
