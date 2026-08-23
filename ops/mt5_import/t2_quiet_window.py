#!/usr/bin/env python3
"""
MT5 T2 v0.1 — quiet-window core. PURE.

Coalesces T1 detections into capture candidates. Implements the "Detection and quiet-window
provenance" section of artifacts/mt5_reconciliation/T1_T2_contract_freeze_addendum.md.

NOT in this module, by design — each is a separate reviewed step:

  no capture_event table, no SQL, no RPC, no Supabase, no account/equity lookup, no gearing,
  no Journal promotion, no Telegram, no scheduler/cadence, no automatic S1/S1.1 observation,
  no T3 UX, no K=2 presentation wording, no persistence of any kind.

Time is INJECTED. Every detection carries its own `detected_at`; there is no clock read, no
sleep and no timer thread here. The caller supplies `quiet_window_seconds` — this module
deliberately does not choose a production cadence.


DETECTION IDENTITY (frozen)
---------------------------
A T1 detection is identified by the deterministic natural key

    (user_id, source_account, event_type, position_id, before_run_id, after_run_id)

and nothing else. T1 is a pure function of sealed observations, so replaying it produces
byte-identical detections — the identity must therefore be derivable from the detection's own
content. No random/generated detection ids: a generated id would make the same logical
detection look like two different ones on replay, which is precisely the duplicate-promotion
failure the freeze forbids.

T2 deduplicates by this identity. If the same identity arrives twice carrying a CONFLICTING
payload, that is not a replay — one of the two is wrong — and T2 raises `T2InputError` rather
than silently choosing a winner. For an EXACT replay the surviving `detected_at` is the
MINIMUM across the duplicates, not the first encountered: a replay observes nothing new, so
the evidence instant is the earliest time the detection was seen, and the result must not
depend on which copy the caller happened to list first.


LOGICAL OBSERVATION KEY (secondary, not durable)
------------------------------------------------
The durable identity above deliberately includes `event_type`, so two contradictory
classifications of the SAME run pair would otherwise be two legal identities. T2 therefore
also checks a secondary key

    (user_id, source_account, position_id, before_run_id, after_run_id)

which answers "what happened to this position between these two observations". T1 emits at
most one event per position per adjacent pair, so two different `event_type`s under one
observation key (an INCREASE *and* a DECREASE for the same run pair) is impossible evidence
— one of them is wrong — and T2 raises. This is a validation key only: it is NOT the durable
detection identity and nothing is stored under it.


REAPPEARANCE HISTORY CONTRACT
-----------------------------
T1's NEW_POSITION vs REAPPEARANCE classification is authoritative **only for the trusted
healthy membership history that was supplied to T1**. If T1 was run over a truncated history,
a genuine reappearance can legitimately classify as NEW_POSITION.

T2 preserves `event_type` EXACTLY and never reinterprets it. T2 performs no history
reconstruction and holds no membership at all, so it is in no position to second-guess the
classification — re-deriving it here from partial data would produce a *less* trustworthy
answer wearing the same name.


EVIDENCE, NOT ACTIONS
---------------------
A candidate summarises coalesced machine evidence. It preserves the contributing event types
verbatim and must never translate them into actions: POSITION_DECREASE is not "closed X lots"
and POSITION_DISAPPEARED is not "trade closed". Between two observations a position's volume
may have moved several times, so a net decrease is evidence of a net change, not a record of
what the human did. No realised P/L, no close price, no Journal semantics.
"""
from __future__ import annotations

import math

# T1 is the producer of the detections consumed here. Importing it keeps the event vocabulary
# single-sourced: a new T1 event type cannot silently become an unknown string in T2.
try:                                     # package mode: from ops.mt5_import import ...
    from . import t1_detector as t1
except ImportError:                      # script mode:  python ops/mt5_import/<module>.py
    import t1_detector as t1

DETECTION_IDENTITY_FIELDS = (
    "user_id", "source_account", "event_type", "position_id",
    "before_run_id", "after_run_id",
)

# Secondary VALIDATION key only — never stored, never durable. See the module docstring.
OBSERVATION_KEY_FIELDS = (
    "user_id", "source_account", "position_id", "before_run_id", "after_run_id",
)

# Grouping key for coalescing. Per the freeze: no product-family grouping in T1/T2.
CANDIDATE_KEY_FIELDS = ("user_id", "source_account", "position_id")

# ---------------------------------------------------------------------------------------------
# The ACTUAL current t1_detector.py output contract, re-derived from what _base_event() and
# _diff_pair() emit — not from prose. `detected_at` is added by the caller of T2.
# Exact key sets: a detection carrying a field T1 does not emit for that event type is
# malformed, exactly as S1 treats its ten-column payload.
# ---------------------------------------------------------------------------------------------
_BASE_FIELDS = frozenset({
    "event_type", "position_id", "before_run_id", "after_run_id",
    "before_run_seq", "after_run_seq", "user_id", "source_account",
})
T1_EVENT_FIELDS = {
    t1.EVENT_NEW_POSITION: _BASE_FIELDS | {"symbol_raw", "side", "after_volume"},
    t1.EVENT_REAPPEARANCE: _BASE_FIELDS | {"symbol_raw", "side", "after_volume"},
    t1.EVENT_POSITION_INCREASE: _BASE_FIELDS | {"symbol_raw", "side",
                                                "before_volume", "after_volume"},
    t1.EVENT_POSITION_DECREASE: _BASE_FIELDS | {"symbol_raw", "side",
                                                "before_volume", "after_volume"},
    t1.EVENT_POSITION_DISAPPEARED: _BASE_FIELDS | {"symbol_raw", "side", "before_volume"},
    t1.EVENT_POSITION_IDENTITY_CONFLICT: _BASE_FIELDS | {
        "before_symbol_raw", "after_symbol_raw", "before_side", "after_side",
        "before_volume", "after_volume"},
}
assert set(T1_EVENT_FIELDS) == set(t1.EVENT_TYPES), \
    "T1_EVENT_FIELDS must cover exactly the T1 event vocabulary"

DETECTED_AT = "detected_at"


class T2InputError(ValueError):
    """Malformed or self-contradictory T2 input. T2 fails closed rather than choosing a
    winner between two conflicting versions of the same detection."""


def _is_finite_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def detection_identity(detection):
    """The frozen deterministic identity tuple of a T1 detection."""
    if not isinstance(detection, dict):
        raise T2InputError(f"detection must be a dict, got {type(detection).__name__}")
    missing = [f for f in DETECTION_IDENTITY_FIELDS if f not in detection]
    if missing:
        raise T2InputError(f"detection missing identity field(s): {missing}")
    event_type = detection["event_type"]
    if event_type not in t1.EVENT_TYPES:
        raise T2InputError(f"unknown event_type {event_type!r} (T1 vocabulary: "
                           f"{t1.EVENT_TYPES})")
    pid = detection["position_id"]
    if not isinstance(pid, int) or isinstance(pid, bool):
        raise T2InputError(f"position_id {pid!r} is not a bigint-style integer")
    for field in ("user_id", "source_account", "before_run_id", "after_run_id"):
        value = detection[field]
        if not (isinstance(value, str) and value.strip()):
            raise T2InputError(f"detection {field} {value!r} is not a nonblank string")
    return tuple(detection[f] for f in DETECTION_IDENTITY_FIELDS)


def observation_key(detection):
    """Secondary validation key: what happened to this position between these two runs."""
    return tuple(detection[f] for f in OBSERVATION_KEY_FIELDS)


def _payload(detection):
    """Everything the detection means, i.e. every field except the injected instant. Full-dict
    comparison (not an allowlist) so an unexpected extra field can never slip past the
    conflict check and make the result depend on input order."""
    return {k: v for k, v in detection.items() if k != DETECTED_AT}


def _nonblank(value):
    return isinstance(value, str) and bool(value.strip())


def _positive_seq(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


def _positive_volume(value):
    return _is_finite_number(value) and value > 0


def validate_detection(detection):
    """Validate one T1 detection against the ACTUAL current t1_detector.py output contract.

    Raises T2InputError on any violation — the whole coalesce() call fails, because a
    malformed detection means the projection feeding T2 is wrong and no candidate built from
    it can be trusted. Returns the validated injected instant as a float.
    """
    identity = detection_identity(detection)                # shape + vocabulary + id types
    event_type = detection["event_type"]
    where = f"{event_type} position {detection['position_id']}"

    keys = set(detection) - {DETECTED_AT}
    expected = T1_EVENT_FIELDS[event_type]
    if keys != expected:
        raise T2InputError(
            f"{where}: field set does not match the T1 contract for {event_type} — "
            f"missing {sorted(expected - keys)}, unexpected {sorted(keys - expected)}")

    # ---- common facts ------------------------------------------------------------------
    if detection["before_run_id"] == detection["after_run_id"]:
        raise T2InputError(f"{where}: before_run_id == after_run_id "
                           f"{detection['before_run_id']!r} — a delta needs two observations")
    for field in ("before_run_seq", "after_run_seq"):
        if not _positive_seq(detection[field]):
            raise T2InputError(f"{where}: {field} {detection[field]!r} is not a positive int")
    if not detection["before_run_seq"] < detection["after_run_seq"]:
        raise T2InputError(
            f"{where}: before_run_seq {detection['before_run_seq']} must be < after_run_seq "
            f"{detection['after_run_seq']}")

    # ---- event-specific facts, exactly as t1_detector.py emits them ---------------------
    if event_type == t1.EVENT_POSITION_IDENTITY_CONFLICT:
        for field in ("before_symbol_raw", "after_symbol_raw"):
            if not _nonblank(detection[field]):
                raise T2InputError(f"{where}: {field} {detection[field]!r} is not nonblank")
        for field in ("before_side", "after_side"):
            if detection[field] not in t1.SIDES:
                raise T2InputError(f"{where}: {field} {detection[field]!r} not in {t1.SIDES}")
        for field in ("before_volume", "after_volume"):
            if not _positive_volume(detection[field]):
                raise T2InputError(f"{where}: {field} {detection[field]!r} is not finite > 0")
        if (detection["before_symbol_raw"] == detection["after_symbol_raw"]
                and detection["before_side"] == detection["after_side"]):
            raise T2InputError(
                f"{where}: claims an identity conflict but symbol_raw and side are unchanged")
    else:
        if not _nonblank(detection["symbol_raw"]):
            raise T2InputError(f"{where}: symbol_raw {detection['symbol_raw']!r} is not "
                               f"nonblank")
        if detection["side"] not in t1.SIDES:
            raise T2InputError(f"{where}: side {detection['side']!r} not in {t1.SIDES}")
        for field in ("before_volume", "after_volume"):
            if field in detection and not _positive_volume(detection[field]):
                raise T2InputError(f"{where}: {field} {detection[field]!r} is not finite > 0")
        if event_type in (t1.EVENT_POSITION_INCREASE, t1.EVENT_POSITION_DECREASE):
            # direction must agree with the volumes T1 itself compared (exact, no tolerance)
            before = t1.canonical_volume(detection["before_volume"])
            after = t1.canonical_volume(detection["after_volume"])
            grew = after > before
            if event_type == t1.EVENT_POSITION_INCREASE and not grew:
                raise T2InputError(
                    f"{where}: INCREASE but after_volume {detection['after_volume']!r} is not "
                    f"greater than before_volume {detection['before_volume']!r}")
            if event_type == t1.EVENT_POSITION_DECREASE and after >= before:
                raise T2InputError(
                    f"{where}: DECREASE but after_volume {detection['after_volume']!r} is not "
                    f"less than before_volume {detection['before_volume']!r}")

    value = detection.get(DETECTED_AT)
    if not _is_finite_number(value):
        raise T2InputError(
            f"{where}: detected_at {value!r} is not a finite number "
            f"(T2 uses INJECTED time only — there is no clock read here)")
    return identity, float(value)


def _dedupe(detections, *, quiet_window_seconds):
    """Validate, refuse contradictions, and collapse exact replays.

    `detected_at` of a deduplicated group is the MINIMUM across its duplicates, so reversing
    the input order cannot change any resulting instant or deadline.
    """
    by_identity = {}
    event_type_by_observation = {}
    for detection in detections:
        identity, detected_at = validate_detection(detection)

        # deadline must be representable BEFORE anything is stored under it
        deadline = detected_at + quiet_window_seconds
        if not math.isfinite(deadline):
            raise T2InputError(
                f"detected_at {detected_at!r} + quiet_window_seconds "
                f"{quiet_window_seconds!r} is not a finite deadline")

        # contradictory classification of the SAME run pair is impossible evidence
        obs = observation_key(detection)
        seen_type = event_type_by_observation.setdefault(obs, detection["event_type"])
        if seen_type != detection["event_type"]:
            raise T2InputError(
                f"contradictory classification for observation key {obs}: both "
                f"{seen_type} and {detection['event_type']} — T1 emits at most one event per "
                f"position per adjacent run pair, so one of these is wrong")

        if identity in by_identity:
            kept = by_identity[identity]
            if _payload(detection) != _payload(kept["detection"]):
                raise T2InputError(
                    f"conflicting payload for detection identity {identity}: a replayed "
                    f"detection must be identical — refusing to choose a winner")
            if detected_at < kept["detected_at"]:
                kept["detected_at"] = detected_at       # MIN wins: order-independent
            continue
        by_identity[identity] = {"identity": identity, "detection": detection,
                                 "detected_at": detected_at}
    return list(by_identity.values())


def _candidate_key(detection):
    return tuple(detection[f] for f in CANDIDATE_KEY_FIELDS)


def coalesce(detections, *, quiet_window_seconds):
    """Coalesce T1 detections into quiet-window capture candidates. Pure.

    `detections` — iterable of T1 event dicts, each additionally carrying `detected_at`
    (injected numeric instant). Input order does not matter: detections are normalised to a
    deterministic order first, so the same set always yields the same candidates.

    `quiet_window_seconds` — positive finite number, supplied by the caller. No default is
    offered: production cadence is not chosen here.

    Windowing, per (user_id, source_account, position_id):

      - the first detection opens a pending candidate with
        quiet_deadline = detected_at + quiet_window_seconds;
      - a detection at t <= quiet_deadline JOINS the candidate and RESTARTS the deadline
        (t + quiet_window_seconds), so a burst keeps the window open;
      - once the deadline passes with no further detection, the TIMER closes the candidate;
      - a detection at t > quiet_deadline opens a NEW candidate.

    The timer closes the candidate. A snapshot never closes it: `basis_run_id` is simply the
    `after_run_id` of the last detection that joined before the timer expired.

    Returns a list of candidate dicts, ordered by
    (user_id, source_account, position_id, first_detection_at). Inputs are not mutated.
    """
    if not (_is_finite_number(quiet_window_seconds) and quiet_window_seconds > 0):
        raise T2InputError(f"quiet_window_seconds {quiet_window_seconds!r} must be a finite "
                           f"number > 0")
    quiet_window_seconds = float(quiet_window_seconds)

    entries = _dedupe(detections, quiet_window_seconds=quiet_window_seconds)
    # Deterministic normalisation: input order must never change the result. after_run_seq is
    # a tiebreak for same-instant detections; identity is the final total order.
    entries.sort(key=lambda e: (e["detection"]["user_id"], e["detection"]["source_account"],
                                e["detection"]["position_id"], e["detected_at"],
                                e["detection"]["after_run_seq"], e["identity"]))

    candidates = []
    open_by_key = {}
    for entry in entries:
        detection, detected_at = entry["detection"], entry["detected_at"]
        key = _candidate_key(detection)
        current = open_by_key.get(key)
        if current is None or detected_at > current["quiet_deadline"]:
            current = {
                "user_id": detection["user_id"],
                "source_account": detection["source_account"],
                "position_id": detection["position_id"],
                "quiet_window_seconds": float(quiet_window_seconds),
                "first_detection_at": detected_at,
                "last_detection_at": detected_at,
                "quiet_deadline": detected_at + float(quiet_window_seconds),
                "detection_identities": [],
                "event_types": [],
                "run_references": [],
                "detections": [],
                "basis_run_id": None,
            }
            candidates.append(current)
            open_by_key[key] = current
        else:
            # inside the window: joining RESTARTS the quiet deadline
            current["last_detection_at"] = detected_at
            current["quiet_deadline"] = detected_at + float(quiet_window_seconds)

        current["detection_identities"].append(entry["identity"])
        current["event_types"].append(detection["event_type"])       # preserved EXACTLY
        current["run_references"].append({
            "before_run_id": detection["before_run_id"],
            "after_run_id": detection["after_run_id"],
            "before_run_seq": detection.get("before_run_seq"),
            "after_run_seq": detection.get("after_run_seq"),
        })
        # copy, never an alias of the input; detected_at normalised to the deduplicated
        # MINIMUM so the stored evidence cannot depend on which replay the caller listed first
        current["detections"].append({**detection, DETECTED_AT: detected_at})
        # basis_run_id = after_run_id of the FINAL detection included in the candidate.
        current["basis_run_id"] = detection["after_run_id"]

    candidates.sort(key=lambda c: (c["user_id"], c["source_account"], c["position_id"],
                                   c["first_detection_at"]))
    return candidates


def closed_candidates(candidates, *, now):
    """The subset whose quiet timer has expired at the injected instant `now`.

    Separated from `coalesce` so that windowing stays a pure function of the detections while
    "is it closed yet" stays a pure function of the caller's clock. Nothing here reads time.
    """
    if not _is_finite_number(now):
        raise T2InputError(f"now {now!r} is not a finite number (injected time only)")
    return [c for c in candidates if now > c["quiet_deadline"]]
