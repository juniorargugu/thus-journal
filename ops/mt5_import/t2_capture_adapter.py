#!/usr/bin/env python3
"""
MT5 T2 capture-event adapter v0.1 — PURE.

Turns a CLOSED t2_quiet_window candidate into the exact `p_candidate` payload for
`public.mt5_append_capture_event_v1`. It builds a payload; it does not send one. There is no
Supabase client, no HTTP, no DB, no MT5, no Telegram and no scheduler in this module, and the
pure T2 core stays pure — DB concerns live here, not there.

WHAT A CAPTURE EVENT IS
-----------------------
Immutable MACHINE EVIDENCE: "between these observations, this position changed like this, and
the quiet timer closed at this instant". It is NOT a Journal trade, not a decision_event, not
a Telegram session, not a promotion record and not a mutable workflow state. Accordingly this
payload carries no `skipped` / `promoted` / `ignored` / `dismissed` / `confirmed` /
`decision` / `decision_state` / `journal_trade_id` / `materialized_trade_id` field — those
belong to the later human-decision layer, which references `mt5_capture_events.id` rather than
mutating the row.

ACCOUNT FACTS ARE NOT COPIED
----------------------------
`basis_run_id` is the reference to the S1/S1.1 machine context. Raw equity / balance / currency
stay authoritative in `mt5_sync_run_account` and are never duplicated here: a copy could drift
from, or outlive, the observation that justified it.

SERVER-OWNED FIELDS
-------------------
`id`, `created_at`, `event_key` and `payload_fingerprint` are derived by the RPC and are NOT
in this payload. A caller able to supply the key or the fingerprint could make a conflicting
replay look identical, which is exactly the check that must not be forgeable.

TIME
----
T2 instants are injected numbers; this adapter pins them to **epoch seconds (UTC)** and renders
them as ISO-8601 `Z` strings, matching the S1 envelope convention.

PARITY WITH THE RPC
-------------------
Everything the RPC will refuse, this adapter refuses first, on the values it is about to send:

  * exact candidate field set, and the exact per-event-type field set of every detection
    (re-derived from t1_detector via t2_quiet_window, never restated here);
  * the CANONICAL IDENTITY WIRE FORMAT — every UUID-valued identity/provenance field is the
    one canonical textual spelling (lowercase, hyphenated, 36 characters), and every
    position_id is an actual integer, never its string spelling. `str(UUID(s)) == s` is the
    whole rule. Aliases are REFUSED, not normalised: the identity tuple is compared and hashed
    as TEXT, so "3F1A…" and "3f1a…" would be two identities for one observation, and one
    logical capture could mint two deterministic event keys — the exact collision the key
    exists to prevent. Rewriting the caller's spelling instead would change what the stored
    evidence says it is about;
  * EXACT TYPES, checked before any value comparison. `source_account` is opaque broker/account
    identity TEXT: a real `str`, nonblank, preserved byte for byte. It is never parsed as a
    number and never normalised, so `301102520` (the integer) is refused rather than accepted
    as `"301102520"`, and `"0301102520"` stays a different account instead of collapsing into
    the same one. The database cannot tell those apart through `->>` either, which is why both
    layers settle the TYPE before they compare the value;
  * ordinal correspondence — detections[i] must BE detection_identities[i], and must agree
    with run_references[i] on both run ids and both sequence numbers. Swapped arrays are not
    evidence just because their lengths match;
  * candidate-SET sanity — the frozen identity may not repeat, and one observation key
    (the identity minus event_type) may carry only ONE classification. Duplicate evidence is
    refused, never silently de-duplicated: collapsing it here would let one candidate produce
    the deterministic event_key of a different, smaller set;
  * the complete quiet-window time invariant — every instant finite, detections chronological,
    `first_detection_at` IS the first detection's instant and `last_detection_at` IS the last
    one's, each joined detection within one window of its predecessor (so they really are one
    restarted window), and therefore no detection beyond the candidate's own deadline. Equal
    instants order by the EXISTING T2 canonical rule (after_run_seq, then the frozen identity
    tuple); no new semantic rule is invented here;
  * positive position_id and positive, strictly increasing run sequence numbers;
  * quiet_window_seconds inside the range the table's CHECK accepts, expressible in whole
    microseconds;
  * `quiet_deadline == last_detection_at + quiet_window_seconds` **as rendered**, in exact
    integer microseconds — the same arithmetic Postgres performs on the strings it receives.
    Rendering rounds to microseconds, so agreeing "in float" is not the same as agreeing in the
    values actually sent, and only the sent values matter.

A malformed candidate is REFUSED, never quietly normalised into a valid-looking one: a payload
that had to be corrected before it could be stored is not evidence of what was observed.

WHAT THIS MODULE DELIBERATELY DOES NOT CHECK
--------------------------------------------
Membership truth. Whether a position really was absent in the before run, present in the after
run, and never seen in any earlier healthy observation is a question only the database can
answer, and it is answered there — `mt5_append_capture_event_v1` re-derives every detection
from `mt5_sync_run_positions` and refuses anything the snapshots contradict. Faking that check
locally against data this module cannot see would be worse than not doing it: it would look
like a guarantee while proving nothing.
"""
from __future__ import annotations

import datetime as _dt
import json
import math
from decimal import Decimal, InvalidOperation
from uuid import UUID as _UUID

try:                                     # package mode: from ops.mt5_import import ...
    from . import t1_detector as t1
    from . import t2_quiet_window as t2
except ImportError:                      # script mode:  python ops/mt5_import/<module>.py
    import t1_detector as t1
    import t2_quiet_window as t2

# Domain tag: mirrored by the SQL packet. Bumping either without the other is a conflict the
# RPC's own domain check will catch, not a silent divergence.
CAPTURE_DOMAIN = "mt5.t2.capture/1"
DETECTOR_VERSION = "t1-detector/0.1"
AGGREGATOR_VERSION = "t2-quiet-window/0.1"

# Exactly the keys t2.coalesce() puts on a candidate.
CANDIDATE_KEYS = frozenset({
    "user_id", "source_account", "position_id", "quiet_window_seconds",
    "first_detection_at", "last_detection_at", "quiet_deadline",
    "detection_identities", "event_types", "run_references", "detections", "basis_run_id",
})

PAYLOAD_KEYS = (
    "domain", "user_id", "source_account", "position_id", "basis_run_id",
    "first_detection_at", "last_detection_at", "quiet_deadline", "quiet_window_seconds",
    "detector_version", "aggregator_version",
    "detection_identities", "event_types", "run_references", "detections",
)

RUN_REFERENCE_KEYS = frozenset({
    "before_run_id", "after_run_id", "before_run_seq", "after_run_seq"})

# The table's mt5_ce_window_chk. Kept here so a candidate that the database would refuse never
# leaves this module in the first place.
SQL_MAX_WINDOW_SECONDS = 86400
MICROSECONDS = 1_000_000

# Refused ANYWHERE in the payload, at any depth — the same vocabulary as the two recursive CHECK
# constraints on mt5_capture_events and the RPC's own jsonpath guard.
FORBIDDEN_PAYLOAD_KEYS = (
    "skipped", "promoted", "ignored", "dismissed", "confirmed",
    "decision", "decision_state", "journal_trade_id", "materialized_trade_id",
    "equity", "balance", "account_equity", "account_balance", "currency",
    "equity_quality", "balance_quality", "margin", "profit_total",
)
_FORBIDDEN_KEY_SET = frozenset(FORBIDDEN_PAYLOAD_KEYS)

# A deliberately STRICTER adapter-side guard: these must not appear even as substrings of the
# rendered payload. The database refuses forbidden KEYS; this refuses anything that merely looks
# like account money anywhere in the text. Being stricter than the server is safe — the failure
# mode is a local refusal, never a surprise acceptance.
FORBIDDEN_PAYLOAD_TOKENS = ("equity", "balance", "currency", "margin", "profit_total")

_EPOCH = _dt.datetime(1970, 1, 1, tzinfo=_dt.timezone.utc)


class T2AdapterError(ValueError):
    """The candidate cannot be turned into capture evidence. Fails closed: a malformed or
    still-open candidate is never persisted in a degraded form."""


def _iso_z(epoch_seconds):
    """Epoch seconds (UTC) -> ISO-8601 Z, microsecond precision, matching the S1 envelope."""
    moment = _dt.datetime.fromtimestamp(float(epoch_seconds), tz=_dt.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def _iso_microseconds(rendered):
    """Whole microseconds since the epoch for a string produced by `_iso_z`.

    timedelta arithmetic is exact integers, so this is the value Postgres will hold after
    casting the same string to timestamptz — no float re-entry.
    """
    moment = _dt.datetime.strptime(rendered, "%Y-%m-%dT%H:%M:%S.%fZ").replace(
        tzinfo=_dt.timezone.utc)
    delta = moment - _EPOCH
    return (delta.days * 86400 + delta.seconds) * MICROSECONDS + delta.microseconds


def _window_microseconds(seconds):
    """The window as whole microseconds, or None when it is not expressible as such."""
    try:
        exact = Decimal(str(seconds)) * MICROSECONDS
    except (InvalidOperation, ValueError):
        return None
    if exact != exact.to_integral_value():
        return None
    return int(exact)


def _finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _positive_int(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 1


def _nonblank_str(value):
    """A real, nonblank `str`. `bool` is excluded explicitly even though it is not a `str`,
    because the point of this predicate is that nothing is coerced on the way in."""
    return (isinstance(value, str) and not isinstance(value, bool) and bool(value.strip()))


def _canonical_uuid(value):
    """True only for the ONE canonical textual spelling of a UUID.

    `uuid.UUID` accepts braces, a `urn:uuid:` prefix, missing hyphens and uppercase hex, and
    Postgres's `uuid` type accepts the same aliases; both then RENDER exactly one spelling.
    Parsing here is used only to VALIDATE — `str(UUID(s)) == s` — never to rewrite `s`, because
    silently normalising a caller's identity would change what the evidence claims to identify.
    """
    if not isinstance(value, str):
        return False
    try:
        parsed = _UUID(value)
    except (ValueError, AttributeError, TypeError):
        return False
    return str(parsed) == value


def _forbidden_key_in(value):
    """The first forbidden key found at any depth, or None. Mirrors the RPC's `$.**` jsonpath."""
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in _FORBIDDEN_KEY_SET:
                return key
            found = _forbidden_key_in(nested)
            if found is not None:
                return found
    elif isinstance(value, (list, tuple)):
        for item in value:
            found = _forbidden_key_in(item)
            if found is not None:
                return found
    return None


def is_closed(candidate, *, now):
    """True when the quiet TIMER has expired at the injected instant `now`."""
    if not _finite(now):
        raise T2AdapterError(f"now {now!r} is not a finite number (injected time only)")
    return now > candidate["quiet_deadline"]


def build_capture_payload(candidate, *, now):
    """Validate a CLOSED candidate and return its canonical RPC payload. Pure; the input is
    never mutated and the result shares no mutable structure with it."""
    if not isinstance(candidate, dict):
        raise T2AdapterError(f"candidate must be a dict, got {type(candidate).__name__}")
    keys = set(candidate)
    if keys != CANDIDATE_KEYS:
        raise T2AdapterError(
            f"candidate field set does not match t2.coalesce() output — missing "
            f"{sorted(CANDIDATE_KEYS - keys)}, unexpected {sorted(keys - CANDIDATE_KEYS)}")

    # ---- scope, in the CANONICAL WIRE FORMAT ----------------------------------------------
    # Validated before anything derives an identity or a key from these values. An equivalent
    # spelling is not the same wire value: it would hash differently and mint a second event
    # key for one observation.
    if not _nonblank_str(candidate["source_account"]):
        raise T2AdapterError(
            f"candidate source_account {candidate['source_account']!r} is not a nonblank string "
            f"— an account identifier is opaque TEXT, never a number that happens to render "
            f"the same way, and it is refused rather than converted")
    for field in ("user_id", "basis_run_id"):
        value = candidate[field]
        if not _nonblank_str(value):
            raise T2AdapterError(f"candidate {field} {value!r} is not a nonblank string")
        if not _canonical_uuid(value):
            raise T2AdapterError(
                f"candidate {field} {value!r} is not a UUID in the canonical textual form "
                f"(lowercase, hyphenated, 36 characters) — an equivalent spelling is refused, "
                f"not normalised, because it would be a second identity for one observation")
    position_id = candidate["position_id"]
    if not isinstance(position_id, int) or isinstance(position_id, bool):
        raise T2AdapterError(f"position_id {position_id!r} is not a bigint-style integer")
    if position_id <= 0:
        raise T2AdapterError(f"position_id {position_id!r} must be > 0 (mt5_ce_position_chk)")

    # ---- window / timing ------------------------------------------------------------------
    for field in ("first_detection_at", "last_detection_at", "quiet_deadline",
                  "quiet_window_seconds"):
        if not _finite(candidate[field]):
            raise T2AdapterError(f"candidate {field} {candidate[field]!r} is not finite")
    window = candidate["quiet_window_seconds"]
    if not 0 < window < SQL_MAX_WINDOW_SECONDS:
        raise T2AdapterError(
            f"quiet_window_seconds {window!r} is outside the range the capture table accepts "
            f"(0 < w < {SQL_MAX_WINDOW_SECONDS})")
    window_us = _window_microseconds(window)
    if window_us is None or window_us < 1:
        raise T2AdapterError(
            f"quiet_window_seconds {window!r} is not a whole number of microseconds — the "
            f"stored deadline could not be derived from it exactly")
    if candidate["first_detection_at"] > candidate["last_detection_at"]:
        raise T2AdapterError("first_detection_at is after last_detection_at")
    if candidate["quiet_deadline"] != candidate["last_detection_at"] + window:
        raise T2AdapterError(
            f"quiet_deadline {candidate['quiet_deadline']!r} is not last_detection_at "
            f"{candidate['last_detection_at']!r} + quiet_window_seconds {window!r}")

    # ---- CLOSED ONLY ----------------------------------------------------------------------
    if not is_closed(candidate, now=now):
        raise T2AdapterError(
            f"candidate is still OPEN at {now!r} (quiet_deadline "
            f"{candidate['quiet_deadline']!r}) — only a timer-closed candidate is evidence")

    # ---- provenance -----------------------------------------------------------------------
    identities = candidate["detection_identities"]
    event_types = candidate["event_types"]
    run_refs = candidate["run_references"]
    detections = candidate["detections"]
    if not identities:
        raise T2AdapterError("candidate has no contributing detection identities")
    if not (len(identities) == len(event_types) == len(run_refs) == len(detections)):
        raise T2AdapterError(
            f"provenance arity mismatch: {len(identities)} identities, {len(event_types)} "
            f"event types, {len(run_refs)} run references, {len(detections)} detections")

    canonical_identities = []
    for identity in identities:
        if not (isinstance(identity, (tuple, list))
                and len(identity) == len(t2.DETECTION_IDENTITY_FIELDS)):
            raise T2AdapterError(f"detection identity {identity!r} is not the frozen "
                                 f"{len(t2.DETECTION_IDENTITY_FIELDS)}-field tuple")
        user, account, event_type, pid, before, after = identity
        # types before values: 301102520 != "301102520" in Python, but a caller that sent the
        # number everywhere would be internally consistent and only the type rule would notice
        if not (_nonblank_str(user) and _nonblank_str(account) and _nonblank_str(event_type)):
            raise T2AdapterError(
                f"detection identity {identity!r} carries a user_id, source_account or "
                f"event_type that is not a nonblank string")
        if user != candidate["user_id"] or account != candidate["source_account"]:
            raise T2AdapterError(f"detection identity {identity!r} is out of candidate scope")
        # an actual integer, not True and not 101.0 — both of which compare EQUAL to 101 in
        # Python but are different wire values, hence a different identity text
        if not _positive_int(pid):
            raise T2AdapterError(
                f"detection identity {identity!r} position_id {pid!r} is not a positive "
                f"bigint-style integer")
        if pid != position_id:
            raise T2AdapterError(f"detection identity {identity!r} is for another position")
        if event_type not in t1.EVENT_TYPES:
            raise T2AdapterError(f"unknown event_type {event_type!r} in identity")
        if not (_canonical_uuid(before) and _canonical_uuid(after)):
            raise T2AdapterError(
                f"detection identity {identity!r} carries a run id that is not a canonical "
                f"UUID text — two spellings of one run would be two identities, and two "
                f"event keys, for one observation")
        if before == after:
            raise T2AdapterError(
                f"detection identity {identity!r} names one run twice — a delta needs two")
        canonical_identities.append([user, account, event_type, pid, before, after])

    # The candidate SET itself, before anything downstream derives a key from it.
    seen_identities = set()
    seen_observations = {}
    for identity in canonical_identities:
        frozen = tuple(identity)
        if frozen in seen_identities:
            raise T2AdapterError(
                f"detection identity {frozen} appears more than once in one candidate — "
                f"duplicate evidence is not stronger evidence, and de-duplicating it here "
                f"would produce the event key of a different, smaller set")
        seen_identities.add(frozen)
        # the identity minus event_type: what happened to this position between these two runs
        observation = (identity[0], identity[1], identity[3], identity[4], identity[5])
        previous = seen_observations.get(observation)
        if previous is not None:
            raise T2AdapterError(
                f"observation key {observation} carries two classifications, {previous} and "
                f"{identity[2]} — T1 emits at most one event per position per adjacent run "
                f"pair, so one of these is wrong")
        seen_observations[observation] = identity[2]

    if list(event_types) != [i[2] for i in canonical_identities]:
        raise T2AdapterError("event_types do not agree with the detection identities")

    canonical_refs = []
    for ref in run_refs:
        if not isinstance(ref, dict) or set(ref) != RUN_REFERENCE_KEYS:
            raise T2AdapterError(f"run reference {ref!r} is not the canonical shape")
        for field in ("before_run_id", "after_run_id"):
            if not _canonical_uuid(ref[field]):
                raise T2AdapterError(
                    f"run reference {ref!r} {field} is not a canonical UUID text")
        if ref["before_run_id"] == ref["after_run_id"]:
            raise T2AdapterError(f"run reference {ref!r} names one run twice")
        for field in ("before_run_seq", "after_run_seq"):
            if not _positive_int(ref[field]):
                raise T2AdapterError(
                    f"run reference {ref!r} {field} {ref[field]!r} is not a positive integer")
        if not ref["before_run_seq"] < ref["after_run_seq"]:
            raise T2AdapterError(
                f"run reference {ref!r} does not run forwards: before_run_seq "
                f"{ref['before_run_seq']} must be < after_run_seq {ref['after_run_seq']}")
        canonical_refs.append({k: ref[k] for k in
                               ("before_run_id", "after_run_id",
                                "before_run_seq", "after_run_seq")})
    if [(r["before_run_id"], r["after_run_id"]) for r in canonical_refs] != \
            [(i[4], i[5]) for i in canonical_identities]:
        raise T2AdapterError("run references do not agree with the detection identities")

    # basis_run_id is the after_run_id of the FINAL contributing detection — the freeze's rule.
    if candidate["basis_run_id"] != canonical_refs[-1]["after_run_id"]:
        raise T2AdapterError(
            f"basis_run_id {candidate['basis_run_id']!r} is not the after_run_id of the final "
            f"detection ({canonical_refs[-1]['after_run_id']!r})")

    first_rendered = _iso_z(candidate["first_detection_at"])
    last_rendered = _iso_z(candidate["last_detection_at"])
    deadline_rendered = _iso_z(candidate["quiet_deadline"])
    # The database will do this arithmetic on the RENDERED strings, not on the floats, so these
    # are the values that actually have to agree. Rendering rounds to microseconds; refuse
    # rather than ship a payload whose own deadline would not reproduce.
    first_us = _iso_microseconds(first_rendered)
    last_us = _iso_microseconds(last_rendered)
    deadline_us = _iso_microseconds(deadline_rendered)
    if not first_us <= last_us:
        raise T2AdapterError(
            f"rendered first_detection_at {first_rendered} is after last_detection_at "
            f"{last_rendered}")
    if deadline_us != last_us + window_us:
        raise T2AdapterError(
            f"rendered quiet_deadline {deadline_rendered} is not last_detection_at "
            f"{last_rendered} + {window!r}s at microsecond precision — refusing to send a "
            f"payload the capture RPC would reject")

    # ---- detections: revalidate against the live T1 contract, prove ORDINAL correspondence,
    #      hold the quiet-window time invariant, then render time ----------------------------
    canonical_detections = []
    previous_us = None
    previous_tie = None
    for index, detection in enumerate(detections):
        t2.validate_detection(detection)          # raises T2InputError on any drift
        identity = list(t2.detection_identity(detection))
        if identity != canonical_identities[index]:
            raise T2AdapterError(
                f"detection {index} is not detection_identities[{index}]: the detection says "
                f"{identity} and the identity says {canonical_identities[index]} — arrays that "
                f"merely line up in length are not evidence")
        ref = canonical_refs[index]
        if (detection["before_run_id"] != ref["before_run_id"]
                or detection["after_run_id"] != ref["after_run_id"]
                or detection["before_run_seq"] != ref["before_run_seq"]
                or detection["after_run_seq"] != ref["after_run_seq"]):
            raise T2AdapterError(
                f"detection {index} does not agree with run_references[{index}] {ref}")

        rendered = {k: v for k, v in detection.items() if k != "detected_at"}
        rendered["detected_at"] = _iso_z(detection["detected_at"])
        detected_us = _iso_microseconds(rendered["detected_at"])
        # T2's canonical order for equal instants: after_run_seq, then the frozen identity.
        # Within one candidate user/account/position are constant, so the identity reduces to
        # (event_type, before_run_id, after_run_id).
        tie = (detection["after_run_seq"], identity[2], identity[4], identity[5])
        if previous_us is None:
            if detected_us != first_us:
                raise T2AdapterError(
                    f"first_detection_at {first_rendered} is not the first detection's instant "
                    f"{rendered['detected_at']} — it is not a free-standing claim")
        else:
            if detected_us < previous_us:
                raise T2AdapterError(
                    f"detection {index} at {rendered['detected_at']} runs backwards")
            if detected_us > previous_us + window_us:
                raise T2AdapterError(
                    f"detection {index} at {rendered['detected_at']} is more than "
                    f"{window!r}s after its predecessor — these detections are not one "
                    f"restarted quiet window")
            if detected_us == previous_us and tie <= previous_tie:
                raise T2AdapterError(
                    f"detection {index} shares an instant with its predecessor but does not "
                    f"follow it in the T2 canonical order (after_run_seq, then identity)")
        if detected_us >= deadline_us:
            raise T2AdapterError(
                f"detection {index} at {rendered['detected_at']} is at or after the "
                f"candidate's own quiet deadline {deadline_rendered}")
        previous_us, previous_tie = detected_us, tie
        canonical_detections.append(rendered)

    if previous_us != last_us:
        raise T2AdapterError(
            f"last_detection_at {last_rendered} is not the final detection's instant "
            f"{canonical_detections[-1]['detected_at']}")

    payload = {
        "domain": CAPTURE_DOMAIN,
        "user_id": candidate["user_id"],
        "source_account": candidate["source_account"],
        "position_id": position_id,
        "basis_run_id": candidate["basis_run_id"],
        "first_detection_at": first_rendered,
        "last_detection_at": last_rendered,
        "quiet_deadline": deadline_rendered,
        "quiet_window_seconds": float(window),
        "detector_version": DETECTOR_VERSION,
        "aggregator_version": AGGREGATOR_VERSION,
        "detection_identities": canonical_identities,
        "event_types": list(event_types),
        "run_references": canonical_refs,
        "detections": canonical_detections,
    }
    if set(payload) != set(PAYLOAD_KEYS):
        raise T2AdapterError("internal: payload key set drifted from PAYLOAD_KEYS")

    # Structural guarantee, not a promise: no human-decision state and no account money may ride
    # along in the evidence, at ANY depth — a nested object must not smuggle what the top level
    # forbids. Same vocabulary as the table's recursive CHECK constraints.
    smuggled = _forbidden_key_in(payload)
    if smuggled is not None:
        raise T2AdapterError(
            f"capture payload contains the forbidden field {smuggled!r} — human-decision state "
            f"belongs to a later layer that references the capture id, and account facts stay "
            f"authoritative in mt5_sync_run_account, referenced via basis_run_id")
    blob = json.dumps(payload, sort_keys=True).lower()
    for token in FORBIDDEN_PAYLOAD_TOKENS:
        if token in blob:
            raise T2AdapterError(
                f"capture payload contains {token!r} — account facts stay authoritative in "
                f"mt5_sync_run_account and are referenced via basis_run_id, never copied")
    return payload


def canonical_payload_json(payload):
    """Deterministic text form, for local determinism checks and for handing to the RPC."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def build_rpc_request(candidate, *, now):
    """The complete argument set for `public.mt5_append_capture_event_v1`.

    `id`, `created_at`, `event_key` and `payload_fingerprint` are deliberately ABSENT: the
    server derives them.
    """
    payload = build_capture_payload(candidate, now=now)
    return {"p_user": payload["user_id"],
            "p_account": payload["source_account"],
            "p_candidate": payload}
