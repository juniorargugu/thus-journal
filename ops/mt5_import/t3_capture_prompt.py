#!/usr/bin/env python3
"""
MT5 T3 capture-prompt renderer v0.1 — PURE.

Turns ONE persisted-style `mt5_capture_events` row into the Telegram prompt model. It builds a
model; it does not send one. There is no Telegram client, no HTTP, no DB, no MT5, no Journal and
no scheduler in this module, and there never will be: the send path, the callback handling and
the decision layer are separate concerns that must not be able to hide inside a renderer.

WHAT THIS RENDERS
-----------------
EVIDENCE, and only evidence. A capture event says "between these two observations, the snapshot
changed like this". It does NOT say what the broker did, and neither does this module.

    NEW_POSITION               พบ position ใหม่ใน MT5
    REAPPEARANCE               พบ position นี้กลับมาใน snapshot อีกครั้ง
    POSITION_INCREASE          volume เปลี่ยน 2 → 4 ระหว่างการตรวจสองครั้ง
    POSITION_DECREASE          volume เปลี่ยน 4 → 2 ระหว่างการตรวจสองครั้ง
    POSITION_DISAPPEARED       ไม่พบ position นี้ใน snapshot ล่าสุด
    POSITION_IDENTITY_CONFLICT หลักฐานขัดแย้งกัน — flagged, never smoothed over

A DECREASE is a smaller volume in a later snapshot. It is NOT a sale, NOT a partial close and
NOT a realised result. A DISAPPEARED is an absence from the latest snapshot; the position may
have closed, but this evidence cannot say so, cannot say at what price, and cannot say for how
much. Those claims need S2 deal evidence, which does not exist yet. `FORBIDDEN_INFERENCE_TOKENS`
makes that structural rather than a promise: every rendered string is checked against it, so a
future edit that reintroduces "ปิด position" or "ขายออก" fails here instead of in Telegram.

THE EVIDENCE IS REVALIDATED, NOT TRUSTED
----------------------------------------
A stored row is not self-certifying. Every detection is put back through the COMMITTED T2 core
validator (`t2_quiet_window.validate_detection`) before a word of it is rendered, so a row
claiming POSITION_INCREASE while carrying 2 -> 1 is refused instead of printed as "volume
เพิ่มขึ้น". Ordinal correspondence is re-proved too: detections[i] must BE detection_identities[i],
must agree with run_references[i], and must match event_types[i].

There is exactly ONE event-semantics specification in this codebase and it lives in T1/T2. This
module reuses it; it does not restate it, because two copies of a rule are two rules.

Membership history — whether the position really was absent, present, or seen before — stays
where it was proved: in `mt5_append_capture_event_v1`, against the immutable snapshots. T3 is
pure and offline and re-checks only the STRUCTURE of the evidence it is about to display.

PRESENCE SEGMENTS, AND SEQUENCES THAT CANNOT HAVE HAPPENED
----------------------------------------------------------
One capture event can carry several detections, and what to offer a human depends on the whole
sequence, not on its last element. A DISAPPEARED ends the current presence; a NEW_POSITION or
REAPPEARANCE starts a new one; INCREASE/DECREASE modify the presence under way. The prompt kind
is derived from the FINAL presence segment, so `NEW -> INCREASE` is still an ENTRY and keeps its
Journal-add path instead of degrading into a bare volume change.

The same model says which sequences are IMPOSSIBLE, and those are REFUSED rather than rendered.
A position cannot grow, shrink, conflict with itself or vanish again while it is absent, and it
cannot APPEAR while it is already being observed. `DISAPPEARED -> INCREASE` is not a volume
change with an awkward prefix and `INCREASE -> REAPPEARANCE` is not a return — neither is an
observation of one position at all, and drawing them carefully would still be drawing something
that never happened. Only REAPPEARANCE may follow an absence, because a position_id this
candidate has already seen cannot satisfy T1's definition of NEW. A candidate may START in any
state, because the capture window need not begin at the position's first observation.

VOLUME IS NEVER BRIDGED ACROSS AN ABSENCE
-----------------------------------------
`DISAPPEARED(2) -> REAPPEARANCE(4)` is not "2 → 4". The position was not observed continuously,
so no continuous span is rendered: any before -> after summary is derived from the FINAL
contiguous presence segment only, and is simply absent when that segment has nothing to compare.
If the identity differs across the gap, that difference gets its own evidence line rather than
being smoothed into a story about one position.

ACCOUNT FACTS AND DECISION STATE ARE NOT RENDERED
-------------------------------------------------
Equity, balance, currency and margin stay authoritative in `mt5_sync_run_account`; the same
forbidden vocabulary T2 enforces on the stored payload is enforced again on this model, at any
depth. Neither may a rendered model carry `journal_trade_id`, `decision`, `promoted`, `skipped`
or any other workflow state — those belong to the layer that records a human's answer.

RENDERING A BUTTON IS NOT A WRITE
---------------------------------
`actions` is a list of OFFERS. Every one carries `writes_journal: False`, because nothing here
writes anything. Persisting a decision, promoting to a Journal trade and recording a skip are
T4's job and need their own review.

WHAT THIS DELIBERATELY DOES NOT DO
----------------------------------
Product-family / group resolution. A volume change belongs to some existing trade, but working
out WHICH one needs a resolver this module does not have, so the "รวม Position เดิม" action is
named in `DEFERRED_ACTIONS` and never emitted. If an authoritative target is not supplied, it is
not guessed: a wrong target silently attached to real evidence is worse than no target at all.

TIME
----
A timestamptz reaches this module in whichever shape the driver chose — `...Z`, `...+00:00`,
`...+07:00`, or an aware `datetime`. Those are the SAME INSTANT, so instants are normalised to
aware UTC and compared as instants; comparing their text would reject a coherent row for a
formatting difference. Naive datetimes, malformed strings and Postgres sentinels ("infinity",
"now") are refused: a value whose instant is unknown is not evidence.

Rendering stays UTC and says UTC. Converting to Bangkok would be a product decision, and a
renderer inventing a timezone is a renderer inventing a fact.
"""
from __future__ import annotations

import datetime as _dt
import json
import math
from decimal import Decimal, InvalidOperation

try:                                     # package mode: from ops.mt5_import import ...
    from . import t1_detector as t1
    from . import t2_capture_adapter as t2a
    from . import t2_quiet_window as t2
except ImportError:                      # script mode:  python ops/mt5_import/<module>.py
    import t1_detector as t1
    import t2_capture_adapter as t2a
    import t2_quiet_window as t2

PROMPT_DOMAIN = "mt5.t3.capture_prompt/1"
RENDERER_VERSION = "t3-capture-prompt/0.1"

_UTC = _dt.timezone.utc

# Exactly the columns of public.mt5_capture_events. An exact set, so a schema change is loud
# here instead of silently rendering a row this module has never seen.
CAPTURE_EVENT_KEYS = (
    "id", "created_at", "event_key", "user_id", "source_account", "position_id",
    "basis_run_id", "first_detection_at", "last_detection_at", "quiet_deadline",
    "quiet_window_seconds", "detector_version", "aggregator_version",
    "payload", "payload_fingerprint",
)

# Columns that restate a payload fact. A row whose column and payload disagree is not coherent
# evidence, and this module refuses it rather than picking a side.
MIRRORED_TEXT_FIELDS = (
    "user_id", "source_account", "position_id", "basis_run_id",
    "detector_version", "aggregator_version",
)
# ...and the same idea for instants, compared as INSTANTS. "2026-08-17T20:53:20Z" and
# "2026-08-18T03:53:20+07:00" are one moment written two ways; only a text comparison
# disagrees with them.
MIRRORED_INSTANT_FIELDS = ("first_detection_at", "last_detection_at", "quiet_deadline")

# Postgres accepts these as timestamptz literals. None of them names an instant.
TIMESTAMP_SENTINELS = ("infinity", "-infinity", "+infinity", "now", "today", "tomorrow",
                       "yesterday", "epoch", "allballs")

KIND_ENTRY = "ENTRY"
KIND_CHANGE = "CHANGE"
KIND_ABSENCE = "ABSENCE"
KIND_CONFLICT = "CONFLICT"

# Events that OPEN a presence segment, and the one that CLOSES it.
SEGMENT_OPENERS = (t1.EVENT_NEW_POSITION, t1.EVENT_REAPPEARANCE)
SEGMENT_CLOSER = t1.EVENT_POSITION_DISAPPEARED

EVENT_KIND = {
    t1.EVENT_NEW_POSITION: KIND_ENTRY,
    t1.EVENT_REAPPEARANCE: KIND_ENTRY,
    t1.EVENT_POSITION_INCREASE: KIND_CHANGE,
    t1.EVENT_POSITION_DECREASE: KIND_CHANGE,
    t1.EVENT_POSITION_DISAPPEARED: KIND_ABSENCE,
    t1.EVENT_POSITION_IDENTITY_CONFLICT: KIND_CONFLICT,
}

# The headline follows the DECIDING EVENT TYPE, not the coarse kind. A REAPPEARANCE and a
# NEW_POSITION are both ENTRY-kind, but a headline saying "พบ position ใหม่" above a line saying
# "กลับมาใน snapshot อีกครั้ง" contradicts its own evidence.
EVENT_HEADLINE = {
    t1.EVENT_NEW_POSITION: "พบ position ใหม่",
    t1.EVENT_REAPPEARANCE: "position กลับมาใน snapshot",
    t1.EVENT_POSITION_INCREASE: "volume เพิ่มขึ้น",
    t1.EVENT_POSITION_DECREASE: "volume ลดลง",
    t1.EVENT_POSITION_DISAPPEARED: "position หายจาก snapshot",
    t1.EVENT_POSITION_IDENTITY_CONFLICT: "หลักฐานขัดแย้ง",
}

# One line per contributing detection, in the order they were observed.
EVENT_WORDING = {
    t1.EVENT_NEW_POSITION: "พบ position ใหม่ใน MT5 (volume {after})",
    t1.EVENT_REAPPEARANCE: "พบ position นี้กลับมาใน snapshot อีกครั้ง (volume {after})",
    t1.EVENT_POSITION_INCREASE: "volume เปลี่ยน {before} → {after} ระหว่างการตรวจสองครั้ง",
    t1.EVENT_POSITION_DECREASE: "volume เปลี่ยน {before} → {after} ระหว่างการตรวจสองครั้ง",
    t1.EVENT_POSITION_DISAPPEARED: "ไม่พบ position นี้ใน snapshot ล่าสุด (ก่อนหน้านี้ volume {before})",
}

CONFLICT_WORDING = (
    "หลักฐานขัดแย้งกัน: position_id เดิม แต่การตรวจสองครั้งบอกไม่ตรงกัน "
    "({before_symbol} {before_side} volume {before_volume} → "
    "{after_symbol} {after_side} volume {after_volume})")

# Rendered when a position_id comes back with a different identity than it had before it
# vanished. Stated as two observations, never as one position that changed.
IDENTITY_ACROSS_ABSENCE_WORDING = (
    "identity ไม่ตรงกันข้ามช่วงที่หายไป — ก่อนหาย: {before_symbol} {before_side} "
    "· กลับมา: {after_symbol} {after_side}")

ABSENCE_BOUNDARY_NOTE = ("มีช่วงที่ไม่เห็น position นี้อยู่กลางชุดหลักฐาน "
                         "— ตัวเลขสรุปจึงนับเฉพาะช่วงที่เห็นล่าสุดเท่านั้น")

KIND_NOTE = {
    KIND_CHANGE: "หลักฐานนี้บอกได้แค่ว่า volume ใน snapshot ต่างกัน "
                 "— ยังไม่มีหลักฐาน deal จาก S2 จึงยังสรุปสาเหตุไม่ได้",
    KIND_ABSENCE: "หลักฐานนี้บอกได้แค่ว่า snapshot ล่าสุดไม่มี position นี้ "
                  "— ยังไม่มีหลักฐาน deal จาก S2 จึงยังสรุปสาเหตุไม่ได้",
    KIND_CONFLICT: "อย่าเพิ่งสรุปจากหลักฐานชุดนี้ — ต้องดู snapshot ทั้งสองครั้งก่อน",
}

ACTION_LABELS = {
    "journal_add": "เพิ่มเข้า Journal",
    "already_logged": "ลงเองแล้ว",
    "no_record": "ไม่ต้องจด",
}

KIND_ACTIONS = {
    KIND_ENTRY: ("journal_add", "already_logged", "no_record"),
    # A volume change belongs to an existing trade, and picking WHICH one needs a resolver this
    # module does not have — so no "add" offer here, only acknowledgement.
    KIND_CHANGE: ("already_logged", "no_record"),
    KIND_ABSENCE: ("already_logged", "no_record"),
    # Conflicting evidence is not something to answer with a button.
    KIND_CONFLICT: ("no_record",),
}

# Named so the omission is deliberate and reviewable, never emitted until a layer exists that
# can resolve a product family. See the module docstring.
DEFERRED_ACTIONS = ("merge_with_existing",)

# Claims T1/T2 evidence CANNOT support. Checked against every rendered string, so this is a
# structural guarantee and not a wording convention someone can quietly drift away from.
FORBIDDEN_INFERENCE_TOKENS = (
    "ซื้อเพิ่ม", "ขายออก", "ปิด position", "ปิดออเดอร์", "ปิดสถานะ", "ราคาปิด",
    "partial close", "closed", "close price", "realized", "realised",
    "กำไร", "ขาดทุน", "p/l", "pnl",
)


class T3PromptError(ValueError):
    """This capture event cannot be rendered truthfully. Fails closed: a row this module does
    not fully understand is never shown to a human in a partly-guessed form."""


def _nonblank_str(value):
    return isinstance(value, str) and not isinstance(value, bool) and bool(value.strip())


def _finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _volume(value):
    """`2.0` -> "2", `4.5` -> "4.5". Exact decimal text, never float repr."""
    try:
        d = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise T3PromptError(f"volume {value!r} is not a renderable number") from exc
    d = d.normalize()
    if d == d.to_integral_value():
        d = d.quantize(Decimal(1))
    return format(d, "f")


def to_instant(value):
    """Normalise a timestamptz-ish value to an AWARE UTC datetime, or refuse it.

    Accepted: an ISO-8601 string ending in Z, an ISO-8601 string with an explicit UTC offset,
    or an aware `datetime`. Refused: a naive datetime (its instant is unknowable), a malformed
    string, a Postgres sentinel, and anything that is not one of those two types — a number is
    not a timestamp just because a timestamp can be turned into one.
    """
    if isinstance(value, _dt.datetime):
        if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
            raise T3PromptError(
                f"instant {value!r} is a NAIVE datetime — without an offset it names no instant")
        return value.astimezone(_UTC)
    if not _nonblank_str(value):
        raise T3PromptError(f"instant {value!r} is neither an ISO-8601 string nor a datetime")
    text = value.strip()
    if text.lower() in TIMESTAMP_SENTINELS:
        raise T3PromptError(f"instant {value!r} is a timestamp sentinel, not an observation")
    if text[-1:] in ("Z", "z"):
        text = text[:-1] + "+00:00"
    try:
        moment = _dt.datetime.fromisoformat(text)
    except ValueError as exc:
        raise T3PromptError(f"instant {value!r} is not an ISO-8601 timestamp") from exc
    if moment.tzinfo is None or moment.tzinfo.utcoffset(moment) is None:
        raise T3PromptError(
            f"instant {value!r} carries no UTC offset — its instant is ambiguous")
    return moment.astimezone(_UTC)


def _render_instant(moment):
    return moment.strftime("%Y-%m-%d %H:%M:%S") + " UTC"


def _same_number(left, right):
    """Numeric equality across int / float / Decimal / numeric-string column reads."""
    try:
        return Decimal(str(left)) == Decimal(str(right))
    except (InvalidOperation, ValueError):
        return False


def _revalidate_detections(payload):
    """Put every stored detection back through the COMMITTED T2 core validator.

    A persisted row is not self-certifying: it may have been written by an older producer,
    hand-edited, or read back from somewhere this module cannot see. The event-semantics rules
    (exact per-event-type shape, volume direction, scope identity, run-sequence validity) live
    in T1/T2 and are reused here rather than restated, so there is one specification and one
    place to change it.

    The stored form differs from the T2 input form in exactly one field: `detected_at` is the
    rendered instant instead of the injected float. It is normalised and substituted on a COPY.
    """
    detections = payload["detections"]
    identities = payload["detection_identities"]
    references = payload["run_references"]
    event_types = payload["event_types"]

    for index, stored in enumerate(detections):
        if not isinstance(stored, dict):
            raise T3PromptError(f"detection {index} is not an object")
        if "detected_at" not in stored:
            raise T3PromptError(f"detection {index} has no detected_at")
        replay = dict(stored)
        replay["detected_at"] = to_instant(stored["detected_at"]).timestamp()
        try:
            identity, _ = t2.validate_detection(replay)
        except t2.T2InputError as exc:
            raise T3PromptError(
                f"detection {index} does not satisfy the current T1 contract: {exc}") from exc

        # ordinal correspondence: arrays that merely line up in length are not evidence
        if list(identity) != list(identities[index]):
            raise T3PromptError(
                f"detection {index} is not detection_identities[{index}]: the detection says "
                f"{list(identity)} and the identity says {list(identities[index])}")
        if event_types[index] != stored["event_type"]:
            raise T3PromptError(f"detection {index} disagrees with event_types[{index}]")
        reference = references[index]
        if not isinstance(reference, dict) or set(reference) != set(t2a.RUN_REFERENCE_KEYS):
            raise T3PromptError(f"run_references[{index}] is not the canonical shape")
        for field in t2a.RUN_REFERENCE_KEYS:
            if reference[field] != stored[field]:
                raise T3PromptError(
                    f"detection {index} does not agree with run_references[{index}] on {field}")

        # the whole event is about ONE position in ONE scope
        for field in ("user_id", "source_account", "position_id"):
            if stored[field] != payload[field]:
                raise T3PromptError(f"detection {index} {field} is outside the event's scope")


PRESENCE_UNKNOWN = "UNKNOWN"
PRESENCE_PRESENT = "PRESENT"
PRESENCE_ABSENT = "ABSENT"


def _validate_presence_continuity(detections):
    """Refuse a sequence that could not have been observed. VALIDATION, not rendering.

    The presence model, stated once and completely. All detections in a candidate are about ONE
    position_id, so the sequence has to describe one position's life:

        UNKNOWN   any individually-valid first event is allowed. A quiet window does not have
                  to begin at the position's first observation, so a bare INCREASE, DECREASE or
                  DISAPPEARED is a perfectly good candidate. DISAPPEARED -> ABSENT, else PRESENT.

        PRESENT   INCREASE / DECREASE / IDENTITY_CONFLICT -> PRESENT; DISAPPEARED -> ABSENT.
                  NEW_POSITION and REAPPEARANCE are REFUSED: something already being observed
                  cannot appear. If the disappearance that would make it appear again happened
                  outside this candidate, then this candidate is incomplete — and an incomplete
                  candidate is a reason to fail closed, not a reason to invent the missing step.

        ABSENT    REAPPEARANCE -> PRESENT, and nothing else. In particular NOT NEW_POSITION:
                  once this candidate has already observed that position_id, T1's definition of
                  NEW cannot apply to it, so an absent -> present transition must be a
                  REAPPEARANCE. Nor INCREASE / DECREASE / IDENTITY_CONFLICT / DISAPPEARED — a
                  position that is not there cannot be observed doing anything.

    Returns the final state, so a caller can see what the sequence ended in.
    """
    state = PRESENCE_UNKNOWN
    for index, detection in enumerate(detections):
        etype = detection["event_type"]
        if state == PRESENCE_UNKNOWN:
            state = PRESENCE_ABSENT if etype == SEGMENT_CLOSER else PRESENCE_PRESENT
        elif state == PRESENCE_PRESENT:
            if etype in SEGMENT_OPENERS:
                raise T3PromptError(
                    f"detection {index} claims {etype} but the position was last observed "
                    f"PRESENT — something already being observed cannot appear, and if the "
                    f"disappearance in between is outside this candidate then the candidate is "
                    f"incomplete; T3 fails closed rather than inventing the missing step")
            state = PRESENCE_ABSENT if etype == SEGMENT_CLOSER else PRESENCE_PRESENT
        else:                                   # PRESENCE_ABSENT
            if etype != t1.EVENT_REAPPEARANCE:
                raise T3PromptError(
                    f"detection {index} claims {etype} but the position was last observed "
                    f"ABSENT — only {t1.EVENT_REAPPEARANCE} can follow an absence for a "
                    f"position_id this candidate has already seen, so this sequence is not a "
                    f"coherent observation of one position and is refused rather than rendered")
            state = PRESENCE_PRESENT
    return state


def validate_capture_event(event):
    """Refuse anything this module cannot render truthfully. Returns (payload, instants).

    Row coherence is checked as well as evidence structure: a column that disagrees with the
    payload it summarises means one of the two is wrong, and a renderer must not choose which.
    """
    if not isinstance(event, dict):
        raise T3PromptError(f"capture event must be a dict, got {type(event).__name__}")
    keys = set(event)
    if keys != set(CAPTURE_EVENT_KEYS):
        raise T3PromptError(
            f"capture event field set does not match mt5_capture_events — missing "
            f"{sorted(set(CAPTURE_EVENT_KEYS) - keys)}, unexpected "
            f"{sorted(keys - set(CAPTURE_EVENT_KEYS))}")

    # The one canonical uuid rule, reused from the approved T2 adapter rather than restated:
    # two spellings of one id would be two capture events to a human reading the prompt.
    if not t2a._canonical_uuid(event["id"]):
        raise T3PromptError(f"capture event id {event['id']!r} is not a canonical UUID text")
    for field in ("event_key", "payload_fingerprint"):
        if not _nonblank_str(event[field]):
            raise T3PromptError(f"capture event {field} {event[field]!r} is not a nonblank string")
    to_instant(event["created_at"])          # server-owned, not rendered, but must be an instant

    payload = event["payload"]
    if not isinstance(payload, dict) or set(payload) != set(t2a.PAYLOAD_KEYS):
        raise T3PromptError("capture event payload is not the canonical T2 capture payload")
    if payload["domain"] != t2a.CAPTURE_DOMAIN:
        raise T3PromptError(
            f"payload domain {payload['domain']!r} is not {t2a.CAPTURE_DOMAIN!r}")

    for field in MIRRORED_TEXT_FIELDS:
        if event[field] != payload[field]:
            raise T3PromptError(
                f"capture event {field} {event[field]!r} disagrees with the payload it "
                f"summarises ({payload[field]!r}) — one of them is wrong and a renderer must "
                f"not choose which")
    instants = {}
    for field in MIRRORED_INSTANT_FIELDS:
        column, inner = to_instant(event[field]), to_instant(payload[field])
        if column != inner:
            raise T3PromptError(
                f"capture event {field} is a different INSTANT from the payload it summarises "
                f"({column.isoformat()} vs {inner.isoformat()})")
        instants[field] = inner
    if not _same_number(event["quiet_window_seconds"], payload["quiet_window_seconds"]):
        raise T3PromptError("capture event quiet_window_seconds disagrees with the payload")

    smuggled = t2a._forbidden_key_in(event)
    if smuggled is not None:
        raise T3PromptError(
            f"capture event carries the forbidden field {smuggled!r} — account facts stay in "
            f"mt5_sync_run_account and human-decision state belongs to the decision layer")

    detections = payload["detections"]
    if not isinstance(detections, list) or not detections:
        raise T3PromptError("capture event has no contributing detections")
    if not (len(detections) == len(payload["event_types"])
            == len(payload["detection_identities"]) == len(payload["run_references"])):
        raise T3PromptError("capture event provenance arrays do not line up")

    _revalidate_detections(payload)
    # Every detection is individually real and ordinally correct by here. What is still
    # unchecked is whether they can be true TOGETHER — and that must be settled before the
    # segment, the kind, the volume summary or a single line is derived from them.
    _validate_presence_continuity(detections)
    return payload, instants


def _detection_line(detection):
    etype = detection["event_type"]
    if etype == t1.EVENT_POSITION_IDENTITY_CONFLICT:
        return CONFLICT_WORDING.format(
            before_symbol=detection["before_symbol_raw"],
            before_side=detection["before_side"],
            before_volume=_volume(detection["before_volume"]),
            after_symbol=detection["after_symbol_raw"],
            after_side=detection["after_side"],
            after_volume=_volume(detection["after_volume"]))
    return EVENT_WORDING[etype].format(
        before=_volume(detection["before_volume"]) if "before_volume" in detection else "-",
        after=_volume(detection["after_volume"]) if "after_volume" in detection else "-")


def _final_presence_segment(detections):
    """The final contiguous presence segment, and the event that OPENED it.

    `opened_by` is None when the presence was already under way before this candidate began
    (the candidate starts mid-life, e.g. INCREASE -> INCREASE) or when nothing reopened a
    presence after the last disappearance.
    """
    start, opened_by = 0, None
    for index, detection in enumerate(detections):
        etype = detection["event_type"]
        if etype in SEGMENT_OPENERS:
            start, opened_by = index, etype
        elif etype == SEGMENT_CLOSER:
            start, opened_by = index + 1, None
    return detections[start:], opened_by


def _identity_across_absence(detections):
    """One line per absence boundary the identity did not survive unchanged.

    A position_id that comes back as a different symbol or side is not the same observation
    continued, and pretending otherwise would manufacture a position that was never seen.
    """
    lines = []
    for index, detection in enumerate(detections):
        if detection["event_type"] != SEGMENT_CLOSER:
            continue
        following = next((d for d in detections[index + 1:]
                          if d["event_type"] in SEGMENT_OPENERS), None)
        if following is None:
            continue
        if (detection["symbol_raw"], detection["side"]) == (following["symbol_raw"],
                                                            following["side"]):
            continue
        lines.append(IDENTITY_ACROSS_ABSENCE_WORDING.format(
            before_symbol=detection["symbol_raw"], before_side=detection["side"],
            after_symbol=following["symbol_raw"], after_side=following["side"]))
    return lines


def _symbol_and_side(detections):
    """The symbol/side ALL the evidence agrees on, or None when it does not agree.

    A conflict detection carries two of each by definition, and a position that returns under a
    different identity disagrees with itself; both report None here and say so in their own
    evidence line instead.
    """
    symbols, sides = set(), set()
    for detection in detections:
        if detection["event_type"] == t1.EVENT_POSITION_IDENTITY_CONFLICT:
            return None, None
        symbols.add(detection["symbol_raw"])
        sides.add(detection["side"])
    return (symbols.pop() if len(symbols) == 1 else None,
            sides.pop() if len(sides) == 1 else None)


def _volume_span(kind, detections, segment):
    """A before -> after summary, or (None, None) when no truthful one exists.

    Derived from the FINAL presence segment only. A disappearance breaks continuity, so a span
    that crossed one would describe a position nobody observed.
    """
    if kind == KIND_CONFLICT:
        # the two volumes belong to two different instruments; a span would assert a
        # continuity this evidence specifically denies
        return None, None
    if kind == KIND_ABSENCE:
        # the last thing actually observed before it vanished, and nothing after it
        return detections[-1].get("before_volume"), None
    if not segment:
        return None, None
    first, last = segment[0], segment[-1]
    after = last.get("after_volume")
    if len(segment) == 1:
        # a lone NEW/REAPPEARANCE observed one volume, it did not observe a change
        return first.get("before_volume"), after
    before = first.get("before_volume", first.get("after_volume"))
    return before, after


def render_capture_prompt(event):
    """Validate one persisted-style capture event and return its Telegram prompt model.

    Pure: the input is never mutated and the result shares no mutable structure with it.
    """
    payload, instants = validate_capture_event(event)
    detections = payload["detections"]
    segment, opened_by = _final_presence_segment(detections)

    # The whole sequence decides, not its last element.
    if any(d["event_type"] == t1.EVENT_POSITION_IDENTITY_CONFLICT for d in detections):
        kind, deciding = KIND_CONFLICT, t1.EVENT_POSITION_IDENTITY_CONFLICT
    elif detections[-1]["event_type"] == SEGMENT_CLOSER:
        kind, deciding = KIND_ABSENCE, SEGMENT_CLOSER
    elif opened_by in SEGMENT_OPENERS:
        # NEW -> INCREASE is still an entry: the Journal-add path is not lost because the
        # volume moved after the position appeared
        kind, deciding = KIND_ENTRY, opened_by
    else:
        kind, deciding = KIND_CHANGE, detections[-1]["event_type"]

    symbol, side = _symbol_and_side(detections)
    position_id = payload["position_id"]
    title = (f"MT5 {symbol} #{position_id}" if symbol else f"MT5 #{position_id}")

    has_absence = any(d["event_type"] == SEGMENT_CLOSER for d in detections)
    lines = [_detection_line(d) for d in detections]
    lines += _identity_across_absence(detections)
    if has_absence and kind != KIND_ABSENCE:
        lines.append(ABSENCE_BOUNDARY_NOTE)
    note = KIND_NOTE.get(kind)
    if note:
        lines.append(note)

    volume_before, volume_after = _volume_span(kind, detections, segment)

    model = {
        "domain": PROMPT_DOMAIN,
        "renderer_version": RENDERER_VERSION,
        "capture_event_id": event["id"],
        "event_key": event["event_key"],
        "kind": kind,
        "title": title,
        "headline": EVENT_HEADLINE[deciding],
        "symbol": symbol,
        "side": side,
        "position_id": position_id,
        "source_account": payload["source_account"],
        "lines": lines,
        "volume_before": volume_before,
        "volume_after": volume_after,
        "volume_text": (f"{_volume(volume_before)} → {_volume(volume_after)}"
                        if volume_before is not None and volume_after is not None else None),
        "observed": {
            "first_detection_at": _render_instant(instants["first_detection_at"]),
            "last_detection_at": _render_instant(instants["last_detection_at"]),
            "detection_count": len(detections),
            "quiet_window_seconds": payload["quiet_window_seconds"],
            "crosses_absence": has_absence,
        },
        # provenance a human can act on without leaving Telegram, and nothing derived from it
        "provenance": {
            "basis_run_id": payload["basis_run_id"],
            "event_types": list(payload["event_types"]),
            "detector_version": payload["detector_version"],
            "aggregator_version": payload["aggregator_version"],
        },
        # OFFERS. Nothing here writes; recording an answer is the decision layer's job.
        "actions": [{"id": action, "label": ACTION_LABELS[action], "writes_journal": False}
                    for action in KIND_ACTIONS[kind]],
    }

    _assert_renderable(model)
    return model


def _assert_renderable(model):
    """Last gate before a human sees this: no unsupported claim, no account money, no decision
    state, and no action that quietly promises a write."""
    blob = json.dumps(model, ensure_ascii=False, sort_keys=True).lower()
    for token in FORBIDDEN_INFERENCE_TOKENS:
        if token.lower() in blob:
            raise T3PromptError(
                f"rendered prompt contains {token!r} — T1/T2 evidence cannot support that "
                f"claim; deal-level facts come from S2, which does not exist yet")
    for token in t2a.FORBIDDEN_PAYLOAD_TOKENS:
        if token in blob:
            raise T3PromptError(
                f"rendered prompt contains {token!r} — account facts stay authoritative in "
                f"mt5_sync_run_account and are never copied into a message")
    smuggled = t2a._forbidden_key_in(model)
    if smuggled is not None:
        raise T3PromptError(
            f"rendered prompt contains the decision-state field {smuggled!r} — a prompt is an "
            f"offer, not a decision")
    for action in model["actions"]:
        if action["id"] in DEFERRED_ACTIONS:
            raise T3PromptError(
                f"action {action['id']!r} needs product-family resolution, which this layer "
                f"does not have — an unresolved target is not a target")
        if action["writes_journal"]:
            raise T3PromptError("a prompt action may not claim to write")


def canonical_prompt_json(model):
    """Deterministic text form, for local determinism checks."""
    return json.dumps(model, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
