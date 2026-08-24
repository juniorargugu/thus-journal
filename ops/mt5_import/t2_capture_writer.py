#!/usr/bin/env python3
"""
MT5 T2 capture writer — OPERATOR-ONLY one-shot bridge from immutable S1 evidence to a
canonical capture-event candidate.

    completed observation history (healthy AND suspicious), as of `now`
        -> t1_detector.detect()          (existing, frozen) over the WHOLE completed stream
        -> t2_quiet_window.coalesce()    (existing, frozen) over the COMPLETE detection stream
        -> t2_quiet_window.closed_candidates()
        -> select the candidate(s) containing the operator's ANCHOR pair
        -> t2_capture_adapter.build_rpc_request()
        -> DRY-RUN report                (default; cannot persist)
        -> mt5_append_capture_event_v1   (PERSIST; separate explicit gate, blocked here)

THE ANCHOR PAIR IS A SELECTOR, NOT A BOUNDARY
  `--before-run-id` / `--after-run-id` say which observation the operator is asking about.
  They do NOT delimit the detection stream. Coalescing a pair-local detection list is not
  canonical T2: if A->B and B->C both change the same position inside one quiet window, T2
  produces ONE candidate carrying both detections, while a pair-local run would produce two
  different single-detection candidates depending on which pair the operator happened to name.
  Neither of those is what the server validates, so neither is append-ready.

  So: detection runs over the whole completed observation history, coalescing runs over the
  whole detection stream, and only THEN are candidates filtered to those containing a
  detection whose (before_run_id, after_run_id) is the anchor. An anchored candidate may legitimately carry
  detections from before or after the anchor pair. That is correct, and it is the point.

COMPLETED OBSERVATION HISTORY vs HEALTHY MEMBERSHIP HISTORY
  These are two different sets, and conflating them fabricates evidence.

  COMPLETED OBSERVATION HISTORY AS-OF = every run in the scope whose snapshot_status is
  'complete' and whose authoritative completion instant is <= the effective `now` — HEALTHY
  AND SUSPICIOUS alike. 'started' and 'failed' are recognized non-authoritative attempts: T1
  ignores them and they create no gap. Runs that completed AFTER `now` are excluded, because
  they were not observable at that instant. Later runs are NOT excluded merely for having a
  higher run_seq than the anchor — those are precisely the observations that can prove the
  anchor's candidate continued inside its quiet window.

  This WHOLE completed sequence is what T1 consumes, because a completed SUSPICIOUS
  observation is a continuity CONTROL: it emits nothing and BREAKS the chain, so the next
  healthy observation is a fresh baseline and no delta is derived across the gap. Filtering
  suspicious runs out before T1 silently bridges that gap and mints a delta the frozen
  contract forbids — a POSITION_INCREASE 2 -> 4 spanning an interval nobody trusted.

  HEALTHY MEMBERSHIP HISTORY = the healthy subset of that sequence. Membership is fetched and
  supplied for exactly those runs: they are the only observations T1 may compare.

  A suspicious run is NEVER given an empty position list. An empty list is legal evidence of a
  FLAT ACCOUNT — "we looked, and nothing was open" — so handing one to a suspicious run would
  promote a control observation into a trusted one and manufacture POSITION_DISAPPEARED for
  every position that was in fact still open. plan_capture() refuses such input outright.

  Anchor adjacency is checked against every COMPLETED run in the scope, as-of filter or not,
  because that is what mt5_append_capture_event_v1 does (ERR_RUN_NOT_ADJACENT), and because a
  suspicious run between two healthy ones must BREAK the pair rather than be stepped over. A
  pair this harness blessed but the server would refuse is worse than no answer.

WHY `detected_at` IS THE AFTER RUN'S COMPLETION INSTANT
  A detection cannot be observed before the run that reveals it is an authoritative completed
  healthy observation. `mt5_sync_runs_complete_shape_chk` makes `snapshot_completed_at` and
  `snapshot_health` NOT NULL exactly when `snapshot_status = 'complete'`, so
  `snapshot_completed_at` IS the instant the run became the trusted observation T1 consumes.
  `captured_at` is earlier — the broker read — and keying the window to it lets a quiet
  deadline expire before the evidence was authoritative at all.

  `reconciled_at` is deliberately NOT used: reconcile is a later, separate lifecycle stage
  that neither the frozen T1 contract nor mt5_append_capture_event_v1 consults (both gate on
  snapshot_status + snapshot_health alone), so trusting it here would refuse evidence the
  server accepts and bind fingerprint-bearing timestamps to a stage that cannot refuse them.

  This is NOT operator-selectable. `event_key` is derived from the detection identities alone
  and excludes every timestamp, while `payload_fingerprint` covers the whole payload including
  the instants. Two runs that disagreed about the instant would mint the SAME key with a
  DIFFERENT fingerprint, and the RPC would answer ERR_CAPTURE_CONFLICT instead of replaying
  idempotently. One fixed rule removes that by construction.

EVIDENCE-SET VALIDITY (checked before ANY filtering, in this order)
  1. SCOPE. EVERY loaded run must carry the requested user_id AND source_account. A foreign
     row is never filtered away: its presence means the caller assembled the wrong evidence
     set, and silently dropping it would let a stranger's run contaminate the canonical
     detection stream while the report still claimed the requested scope. Fail closed on the
     whole set. `user_id` follows the canonical-UUID rule already used for the anchor;
     `source_account` is opaque exact TEXT, never normalised and never coerced from a number.
  2. STATUS DOMAIN. EVERY loaded run's snapshot_status must be EXACTLY one of the frozen
     mt5_sync_runs values ('started' | 'complete' | 'failed'). An unknown string, an empty
     string, a missing key, None, an int, a bool, a list or a dict is malformed input, not a
     recognised attempt. This matters because 'not complete' is otherwise indistinguishable
     from 'complete', and a mystery status would vanish from the observation history — taking
     its continuity break with it and letting the runs either side be compared as adjacent.
     T1 fails closed on exactly this, but only for runs it is given; a run filtered out before
     T1 is a run T1 can never refuse.
     Case and whitespace variants (' complete ', 'Complete') are REFUSED, not normalised: the
     stored contract has one spelling, and quietly repairing input hides a broken writer.

  Both checks run inside the PURE planner, not only at the I/O boundary, because tests and
  callers can reach plan_capture() without ever constructing an EvidenceReader.

HARD BOUNDARIES
  - No second T1/T2 implementation. Every event-semantics, windowing, identity, canonical-wire
    and payload rule is delegated to the committed modules above. This file decides only WHICH
    runs to feed them, WHEN the clock says a candidate is closed, and HOW to report it.
  - No scheduler, no polling, no continuous writer, no MT5, no Telegram, no Journal.
  - Reads are structurally GET-only against an allowlist of exactly three tables.
    `EvidenceReader` has no POST/PATCH/DELETE method at all, so "the dry run cannot write" is
    a property of the class, not of a flag someone can flip.
  - Every collection read proves completeness from the server's OWN page coordinates. The
    complete Content-Range (start, end, total) is parsed, and every page must satisfy:
    start == the requested offset, end >= start, end within the requested bound, end < total,
    a body cardinality of exactly end - start + 1, and a total that never moves. The next
    offset is END + 1 taken from the HEADER — never merely len(rows) — so a server that
    replays page 0's coordinates for page 1 is caught instead of silently duplicating row 0
    and calling the set complete. A capped or repeated membership page would invent
    POSITION_DISAPPEARED events for the rows that fell off the end.
  - `mt5_import_staging.position_state` is never consulted: it is a mutable operational
    annotation, not replayable history.
  - The service_role key is held in memory only and never logged; errors carry the table/RPC
    name and HTTP status, never the URL and never the Authorization header.

TRUTH RULES (frozen, restated here only because this file is what an operator reads)
  POSITION_DISAPPEARED is an observed membership disappearance, NOT a closed trade.
  POSITION_DECREASE is a smaller stored volume, NOT a sale or partial close.
  POSITION_INCREASE is a larger stored volume, NOT an observed buy execution.
  There is no deal evidence, no close price and no realised P/L anywhere in this pipeline.
  Trade-outcome semantics need S2, which does not exist yet.

Run with:  python -X utf8 ops/mt5_import/t2_capture_writer.py --help
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:                                                                       # package import
    from . import t1_detector as t1
    from . import t2_capture_adapter as t2a
    from . import t2_quiet_window as t2
except ImportError:                                                        # direct script run
    import t1_detector as t1                                               # noqa: E402
    import t2_capture_adapter as t2a                                       # noqa: E402
    import t2_quiet_window as t2                                           # noqa: E402


# =============================================================================================
# Structural constants
# =============================================================================================
RUNS = "mt5_sync_runs"
POSITIONS = "mt5_sync_run_positions"
CAPTURE_EVENTS = "mt5_capture_events"

#: The ONLY tables this module may name in a URL. Read-only by construction.
ALLOWED_READ_TABLES = frozenset({RUNS, POSITIONS, CAPTURE_EVENTS})

#: The ONLY RPC the persist boundary may ever name.
RPC_APPEND_CAPTURE = "mt5_append_capture_event_v1"
ALLOWED_RPCS = frozenset({RPC_APPEND_CAPTURE})

#: Persist arming — mirrors s1_snapshot.py's multi-key model. All three are required.
WRITE_ENV = "MT5_T2_WRITE"
CONFIRM_PERSIST = "PERSIST-CAPTURE-EVENTS"

#: Phase gate. The append RPC has never been called in production and this phase does not
#: authorize the first call. A later explicit gate flips this constant; until then the persist
#: path refuses even when the operator supplies every arming key, so "append RPC calls = 0" is
#: structural rather than procedural.
PERSIST_ENABLED_IN_THIS_PHASE = False

#: The AUTHORITATIVE completion instant. See the module docstring: not captured_at, not
#: reconciled_at, not wall-clock, and not operator-selectable.
DETECTED_AT_SOURCE = "snapshot_completed_at"

DEFAULT_TIMEOUT = 30
#: Rows requested per page. Paging continues until the server's exact count is satisfied.
PAGE_SIZE = 1000
#: Hard stop so a wrong count can never spin forever.
MAX_PAGES = 200
#: Run ids per membership request, so the `in.(...)` filter cannot build an unbounded URL.
#: 60 canonical uuids is roughly 2.3 KB of query, comfortably inside every proxy limit.
RUN_IDS_PER_REQUEST = 60

STATUS_COMPLETE = t1.STATUS_COMPLETE
#: The FROZEN mt5_sync_runs_snapshot_status_chk domain, reused from T1 rather than restated
#: here — one vocabulary, one definition, so the two can never drift apart.
STATUSES = t1.STATUSES
HEALTH_HEALTHY = t1.HEALTH_HEALTHY

#: Distinguishes "key absent" from "key present and None"; both are refused, differently.
_MISSING = object()

RUN_COLUMNS = ("id", "user_id", "source_account", "run_seq", "snapshot_status",
               "snapshot_health", "captured_at", "snapshot_completed_at")
POSITION_COLUMNS = ("run_id", "user_id", "source_account", "position_id", "symbol_raw",
                    "side", "volume", "captured_at")

_EPOCH = _dt.datetime(1970, 1, 1, tzinfo=_dt.timezone.utc)


class CaptureWriterError(Exception):
    """Any refusal from this harness. Never carries a URL, a key or a header."""


class RunPairError(CaptureWriterError):
    """The requested anchor pair is not usable evidence under the frozen T1 rules."""


class IncompleteReadError(CaptureWriterError):
    """A collection read could not be PROVEN complete, so nothing may be derived from it."""


# =============================================================================================
# Pure helpers — no DB, no clock, no I/O. Exercised by test_t2_capture_writer.py.
# =============================================================================================
def arming_status(*, persist, confirm, write_env):
    """('dry-run'|'armed', None) or ('stop', reason).

    Reads ONLY the passed values, so a caller can decide whether to build a write client
    before touching the environment. Dry run is the default and needs no key at all.
    """
    if not persist:
        return "dry-run", None
    if not PERSIST_ENABLED_IN_THIS_PHASE:
        return "stop", ("persist is disabled in this phase: "
                        f"{__name__}.PERSIST_ENABLED_IN_THIS_PHASE is False. The first "
                        f"production call to {RPC_APPEND_CAPTURE} needs its own explicit gate.")
    if confirm != CONFIRM_PERSIST:
        return "stop", f"--persist requires --confirm {CONFIRM_PERSIST} (exact literal)."
    if write_env != "1":
        return "stop", f"--persist requires env {WRITE_ENV}=1."
    return "armed", None


def parse_instant(value):
    """A PostgREST/ISO-8601 timestamptz -> aware UTC datetime. Refuses anything else.

    Accepts the 'Z' spelling and an explicit offset; refuses a naive string, because an
    instant without an offset names no instant.
    """
    if not isinstance(value, str) or not value.strip():
        raise CaptureWriterError(f"instant {value!r} is not an ISO-8601 string")
    text = value.strip()
    if text[-1:] in ("Z", "z"):
        text = text[:-1] + "+00:00"
    try:
        moment = _dt.datetime.fromisoformat(text)
    except ValueError as exc:
        raise CaptureWriterError(f"instant {value!r} is not an ISO-8601 timestamp") from exc
    if moment.tzinfo is None or moment.tzinfo.utcoffset(moment) is None:
        raise CaptureWriterError(f"instant {value!r} carries no UTC offset")
    return moment.astimezone(_dt.timezone.utc)


def to_epoch(moment):
    """Aware datetime -> epoch seconds (float), the injected-instant form T2 consumes."""
    if moment.tzinfo is None or moment.tzinfo.utcoffset(moment) is None:
        raise CaptureWriterError("refusing to convert a naive datetime to an instant")
    return (moment - _EPOCH).total_seconds()


def _iso(epoch_seconds):
    return (_EPOCH + _dt.timedelta(seconds=epoch_seconds)).isoformat().replace("+00:00", "Z")


def canonical_uuid_or_raise(value, *, field):
    """Reuse the APPROVED canonical-UUID rule instead of restating it.

    An equivalent spelling ('3F1A...', '{3f1a...}') is refused rather than normalised: the
    payload is compared and hashed as text, so rewriting the operator's input here would
    change what the evidence identifies.
    """
    if not t2a._canonical_uuid(value):
        raise CaptureWriterError(
            f"{field} {value!r} is not a canonical UUID (32 lowercase hex in 8-4-4-4-12) — "
            f"refused rather than normalised")
    return value


def snapshot_status_of(run):
    """The run's snapshot_status, PROVEN to be in the frozen domain. Fail closed otherwise.

    The single funnel every status question goes through, so no caller can reach a filter
    while holding a value nobody validated. Exact match only: no case folding, no strip(),
    no truthiness, no numeric coercion.
    """
    status = run.get("snapshot_status", _MISSING) if isinstance(run, dict) else _MISSING
    if status is _MISSING:
        raise CaptureWriterError(
            f"run {run.get('id') if isinstance(run, dict) else run!r} has no snapshot_status "
            f"key — a run whose status is unknown cannot be classified as an observation or "
            f"an attempt, so the evidence set is refused")
    if not isinstance(status, str) or status not in STATUSES:
        raise CaptureWriterError(
            f"run {run.get('id')!r} has snapshot_status {status!r}, which is not exactly one "
            f"of the frozen domain {STATUSES} — refused rather than normalised or treated as "
            f"a non-authoritative attempt, because an unrecognised status filtered out of the "
            f"observation history would take its continuity break with it")
    return status


def validate_status_domain(runs):
    """Prove the WHOLE loaded set before a single status is compared. Returns `runs`."""
    for run in runs:
        snapshot_status_of(run)
    return runs


def is_completed(run):
    """A COMPLETED OBSERVATION — healthy or suspicious.

    Both are real observations and both belong in T1's input: a suspicious one emits nothing
    but BREAKS continuity. 'started' / 'failed' are non-authoritative attempts, not
    observations, and they create no gap.

    NOTE the asymmetry this guards: an unrecognised status must NEVER reach here and be
    answered `False`, because False here means "filtered out of the observation history",
    which is exactly how a malformed run would silently bridge the gap it should have made.
    """
    return snapshot_status_of(run) == STATUS_COMPLETE


def is_trusted(run):
    """A completed HEALTHY observation: the only kind whose membership T1 may compare, and the
    RPC's definition of a usable run. NEVER the bound of the observation history."""
    return is_completed(run) and run["snapshot_health"] == HEALTH_HEALTHY


def completion_instant(run):
    """The authoritative instant at which `run` became a COMPLETED observation.

    Healthy or suspicious alike: mt5_sync_runs_complete_shape_chk makes snapshot_completed_at
    NOT NULL for every completed run, so a suspicious observation is datable too — which it
    must be, since it takes part in the as-of history that decides continuity.
    """
    value = run.get(DETECTED_AT_SOURCE)
    if value is None:
        raise CaptureWriterError(
            f"run {run.get('id')!r} is completed but carries no {DETECTED_AT_SOURCE} — its "
            f"authoritative completion instant is unknown, so nothing may be dated from it")
    return to_epoch(parse_instant(value))


def completed_observations_as_of(runs, *, now):
    """EVERY completed observation — HEALTHY AND SUSPICIOUS — completed at or before `now`, in
    run_seq order. This is T1's input.

    Suspicious runs are included on purpose: they are the continuity controls that break the
    chain. Dropping them here would hand T1 two healthy runs as though they were consecutive
    and mint a delta across an interval nobody trusted.

    Bounded by the CLOCK, not by the anchor's run_seq: a later observation is exactly what can
    prove the anchor's candidate continued inside its quiet window.
    """
    kept = [r for r in runs if is_completed(r) and completion_instant(r) <= now]
    return sorted(kept, key=lambda r: r["run_seq"])


def healthy_membership_run_ids(observations):
    """The healthy subset of a completed observation history, in order.

    Membership is loaded for exactly these runs: T1 requires it for every healthy completed
    run and never consults it for a suspicious one.
    """
    return [r["id"] for r in observations if is_trusted(r)]


def validate_scope(runs, *, user_id, source_account):
    """EVERY loaded run must belong to the requested scope. Returns `runs`.

    A foreign row is NOT filtered away. T1 groups by (user_id, source_account) and happily
    derives events for every group it is handed, so a stranger's run that survived into the
    planner would produce detections and canonical candidates that the report then presents
    under the requested scope's heading. Worse, at the I/O boundary the membership query is
    scoped, so a foreign healthy run would arrive with an EMPTY position list and read as a
    trusted flat account — fabricating POSITION_DISAPPEARED for positions that were never
    ours to observe.

    So a foreign row means the evidence set is wrong for this invocation, and the whole set
    is refused. Comparison is EXACT: `user_id` must be canonical (never case-normalised) and
    `source_account` is opaque TEXT (never coerced from a number, never zero-stripped).
    """
    canonical_uuid_or_raise(user_id, field="user_id")
    if not isinstance(source_account, str) or not source_account.strip():
        raise CaptureWriterError("source_account must be nonblank opaque text")
    for run in runs:
        run_id = run.get("id") if isinstance(run, dict) else None
        if not isinstance(run, dict):
            raise CaptureWriterError(f"run metadata must be a dict, got {type(run).__name__}")
        # The foreign VALUE is deliberately not echoed: this is a scope error, and the report
        # has no business reproducing another user's identifiers.
        if run.get("user_id") != user_id:
            raise CaptureWriterError(
                f"run {run_id!r} carries a different user_id than the requested scope — the "
                f"loaded evidence set is not this user's, so it is refused whole rather than "
                f"filtered")
        if run.get("source_account") != source_account:
            raise CaptureWriterError(
                f"run {run_id!r} carries a different source_account than the requested scope "
                f"({source_account!r}) — accounts are opaque exact text and are never "
                f"normalised to match, so the evidence set is refused whole")
    return runs


def validate_run_pair(runs, *, user_id, source_account, before_run_id, after_run_id):
    """Validate the operator's ANCHOR pair against the frozen T1 rules. Fail closed.

    `runs` — every mt5_sync_runs row in the requested scope, NOT as-of filtered: adjacency is
    checked exactly as mt5_append_capture_event_v1 checks it, against every completed run.
    Returns (before_run, after_run).

    Every status this function reads — the anchor rows' and the between-scan's alike — goes
    through snapshot_status_of(), so a malformed status can never be answered "well, it isn't
    'complete'" and quietly become a non-adjacent neighbour instead of a refusal. This
    function still validates only the PAIR's scope; the whole-set invariants belong to
    plan_capture(), which runs them first.
    """
    by_id = {}
    for run in runs:
        if run["id"] in by_id:
            raise RunPairError(f"run id {run['id']} appears twice in the loaded evidence")
        by_id[run["id"]] = run

    if before_run_id == after_run_id:
        raise RunPairError("--before-run-id and --after-run-id are the same run; "
                           "a delta needs two observations")
    missing = [rid for rid in (before_run_id, after_run_id) if rid not in by_id]
    if missing:
        raise RunPairError(f"run(s) not found in this scope: {missing}")

    before, after = by_id[before_run_id], by_id[after_run_id]
    for label, run in (("before", before), ("after", after)):
        if run["user_id"] != user_id or run["source_account"] != source_account:
            raise RunPairError(
                f"{label} run {run['id']} is out of the requested scope "
                f"(user/account mismatch) — a cross-scope pair is never a delta")
        if snapshot_status_of(run) != STATUS_COMPLETE:
            raise RunPairError(
                f"{label} run {run['id']} has snapshot_status "
                f"{run['snapshot_status']!r}, not {STATUS_COMPLETE!r}")
        if run["snapshot_health"] != HEALTH_HEALTHY:
            raise RunPairError(
                f"{label} run {run['id']} has snapshot_health "
                f"{run['snapshot_health']!r}; a completed suspicious observation emits nothing "
                f"and breaks continuity")
        if not isinstance(run["run_seq"], int) or isinstance(run["run_seq"], bool) \
                or run["run_seq"] < 1:
            raise RunPairError(f"{label} run {run['id']} has run_seq {run['run_seq']!r}")

    if before["run_seq"] >= after["run_seq"]:
        raise RunPairError(
            f"before run_seq {before['run_seq']} is not below after run_seq "
            f"{after['run_seq']} — the pair is reversed or identical")

    # Executable T1 adjacency: ANY completed run between them (healthy or suspicious) means
    # this pair is not a legal delta. Mirrors the RPC's ERR_RUN_NOT_ADJACENT check.
    between = sorted(
        (r["run_seq"], r["snapshot_health"]) for r in runs
        if is_completed(r) and before["run_seq"] < r["run_seq"] < after["run_seq"])
    if between:
        shown = ", ".join(f"{seq} ({health})" for seq, health in between)
        raise RunPairError(
            f"completed run(s) {shown} sit between run_seq {before['run_seq']} and "
            f"{after['run_seq']} — consecutive completed observations only. A SUSPICIOUS run "
            f"between two healthy ones is not stepped over: it breaks continuity, so the pair "
            f"spanning it is not a delta")
    return before, after


def inject_detected_at(detections, *, runs_by_id):
    """Date every detection by ITS OWN after-run's authoritative completion instant.

    Not one instant for the whole batch: each detection becomes observable when the run that
    revealed it became authoritative, so a stream spanning several pairs carries several
    instants — which is exactly what lets T2 decide whether they share a quiet window.
    """
    dated = []
    for detection in detections:
        after_id = detection["after_run_id"]
        run = runs_by_id.get(after_id)
        if run is None:
            raise CaptureWriterError(
                f"detection names after_run_id {after_id!r}, which is not in the loaded "
                f"history — refusing to date evidence from a run this harness never read")
        dated.append({**detection, t2.DETECTED_AT: completion_instant(run)})
    return dated


def anchored_candidates(candidates, *, before_run_id, after_run_id):
    """Canonical candidates carrying at least one detection from the operator's anchor pair.

    Selection only. The candidate is whatever T2 built from the complete stream; it is never
    trimmed to the anchor, because a trimmed candidate is not the one the server validates.
    """
    out = []
    for candidate in candidates:
        if any(d["before_run_id"] == before_run_id and d["after_run_id"] == after_run_id
               for d in candidate["detections"]):
            out.append(candidate)
    return out


def summarise_detection(detection):
    """Compact, truthful one-line facts for the dry-run report.

    Only fields the detection actually carries are shown: a DISAPPEARED has no after_volume
    and a NEW has no before_volume, and inventing 'None' for the missing side would read as a
    measured zero.
    """
    row = {
        "event_type": detection["event_type"],
        "position_id": detection["position_id"],
        "before_run": f"seq {detection['before_run_seq']} {detection['before_run_id']}",
        "after_run": f"seq {detection['after_run_seq']} {detection['after_run_id']}",
    }
    if t2.DETECTED_AT in detection:
        row["detected_at"] = _iso(detection[t2.DETECTED_AT])
    for field in ("symbol_raw", "side", "before_symbol_raw", "after_symbol_raw",
                  "before_side", "after_side", "before_volume", "after_volume"):
        if field in detection:
            row[field] = detection[field]
    return row


def summarise_candidate(candidate, *, now, anchor=None):
    """Compact candidate facts, including whether the TIMER has closed it."""
    closed = t2a.is_closed(candidate, now=now)
    pairs = [(d["before_run_id"], d["after_run_id"]) for d in candidate["detections"]]
    return {
        "position_id": candidate["position_id"],
        "identity": {"user_id": candidate["user_id"],
                     "source_account": candidate["source_account"],
                     "position_id": candidate["position_id"]},
        "event_sequence": list(candidate["event_types"]),
        "detection_count": len(candidate["detections"]),
        "run_pairs": [f"{b} -> {a}" for b, a in pairs],
        "contains_anchor": (anchor in pairs) if anchor else None,
        "extends_beyond_anchor": (len(pairs) > 1) if anchor else None,
        "first_detection_at": _iso(candidate["first_detection_at"]),
        "last_detection_at": _iso(candidate["last_detection_at"]),
        "quiet_deadline": _iso(candidate["quiet_deadline"]),
        "quiet_window_seconds": candidate["quiet_window_seconds"],
        "basis_run_id": candidate["basis_run_id"],
        "closed": closed,
        # closed == the TIMER expired. Eligibility for THIS invocation additionally requires
        # that the candidate is the one the operator anchored; a closed canonical candidate
        # the operator did not ask about is not this run's to hand to the append gate.
        "persistable": closed,
        "eligible_for_this_invocation": bool(closed and anchor and anchor in pairs),
        "state": "CLOSED" if closed else "OPEN / NOT YET PERSISTABLE",
    }


def plan_capture(*, runs, memberships, user_id, source_account, before_run_id, after_run_id,
                 quiet_window_seconds, now):
    """The whole pure pipeline. `now` is injected; nothing here reads a clock.

    Building an RPC request is NOT persisting it — the request is the argument set the future
    gate would send, and it exists only for a CLOSED canonical candidate that the approved
    adapter accepted.
    """
    # EVIDENCE-SET VALIDITY FIRST — before as-of filtering, status filtering, adjacency,
    # anchor validation, detector-history construction or membership projection. Scope first
    # (is this set even ours?), then the status domain (is every row well-formed?).
    validate_scope(runs, user_id=user_id, source_account=source_account)
    validate_status_domain(runs)

    # The anchor is validated against the FULL run set (adjacency parity with the RPC)...
    before, after = validate_run_pair(
        runs, user_id=user_id, source_account=source_account,
        before_run_id=before_run_id, after_run_id=after_run_id)

    # ...but the detection stream is the COMPLETED OBSERVATION history as of `now`: healthy
    # AND suspicious, because the suspicious ones are exactly what break continuity.
    observations = completed_observations_as_of(runs, now=now)
    observation_ids = {r["id"] for r in observations}
    for label, run in (("before", before), ("after", after)):
        if run["id"] not in observation_ids:
            raise RunPairError(
                f"anchor {label} run {run['id']} completed after the effective now "
                f"({_iso(now)}) — it was not an observable completed run at that instant")

    healthy_ids = healthy_membership_run_ids(observations)
    # A suspicious observation must NOT arrive carrying a position list. An empty list is
    # legal FLAT-ACCOUNT evidence, so accepting one here would promote a continuity control
    # into a trusted observation and fabricate POSITION_DISAPPEARED for every open position.
    suspicious_with_membership = sorted(
        r["id"] for r in observations if not is_trusted(r) and r["id"] in memberships)
    if suspicious_with_membership:
        raise CaptureWriterError(
            f"membership was supplied for suspicious observation(s) "
            f"{suspicious_with_membership} — a suspicious run is a continuity control, not a "
            f"snapshot, and an empty list would falsely read as a trusted flat account")

    runs_by_id = {r["id"]: r for r in observations}
    # snapshot_health is passed through UNCHANGED: T1 needs to see the suspicious run to
    # break the chain on it.
    detector_runs = [{"run_id": r["id"], "user_id": r["user_id"],
                      "source_account": r["source_account"], "run_seq": r["run_seq"],
                      "snapshot_status": r["snapshot_status"],
                      "snapshot_health": r["snapshot_health"]} for r in observations]

    all_events = t1.detect(detector_runs, memberships)
    dated = inject_detected_at(all_events, runs_by_id=runs_by_id)

    # The COMPLETE stream is coalesced. Anything narrower is not canonical T2.
    candidates = t2.coalesce(dated, quiet_window_seconds=quiet_window_seconds)
    anchor = (before_run_id, after_run_id)
    anchored = anchored_candidates(
        candidates, before_run_id=before_run_id, after_run_id=after_run_id)
    closed = t2.closed_candidates(anchored, now=now)

    requests = [t2a.build_rpc_request(c, now=now) for c in closed]

    anchor_detections = [d for d in dated
                         if (d["before_run_id"], d["after_run_id"]) == anchor]
    return {
        "scope": {"user_id": user_id, "source_account": source_account},
        "anchor": {
            "before": {"run_id": before["id"], "run_seq": before["run_seq"],
                       "snapshot_status": before["snapshot_status"],
                       "snapshot_health": before["snapshot_health"],
                       "captured_at": before["captured_at"],
                       DETECTED_AT_SOURCE: before[DETECTED_AT_SOURCE]},
            "after": {"run_id": after["id"], "run_seq": after["run_seq"],
                      "snapshot_status": after["snapshot_status"],
                      "snapshot_health": after["snapshot_health"],
                      "captured_at": after["captured_at"],
                      DETECTED_AT_SOURCE: after[DETECTED_AT_SOURCE]},
        },
        "canonical_history": {
            "completed_observation_count": len(observations),
            "healthy_membership_count": len(healthy_ids),
            "suspicious_observation_count": len(observations) - len(healthy_ids),
            "suspicious_run_seqs": [r["run_seq"] for r in observations
                                    if not is_trusted(r)],
            "first_run_seq": observations[0]["run_seq"] if observations else None,
            "last_run_seq": observations[-1]["run_seq"] if observations else None,
            "as_of": _iso(now),
            "runs_in_scope_total": len(runs),
            "excluded_as_future_to_now": sum(
                1 for r in runs if is_completed(r) and completion_instant(r) > now),
        },
        "detected_at_rule": f"after run {DETECTED_AT_SOURCE} (authoritative completion)",
        "quiet_window_seconds": quiet_window_seconds,
        "detections": [summarise_detection(d) for d in dated],
        "detection_count": len(dated),
        "anchor_detection_count": len(anchor_detections),
        "canonical_candidates": [summarise_candidate(c, now=now, anchor=anchor)
                                 for c in candidates],
        "canonical_candidate_count": len(candidates),
        "anchored_candidates": [summarise_candidate(c, now=now, anchor=anchor)
                                for c in anchored],
        "anchored_candidate_count": len(anchored),
        "closed_anchored_candidates": len(closed),
        "rpc_requests": requests,
    }


# =============================================================================================
# Read-only evidence reader. GET is the only verb this class can issue.
# =============================================================================================
class EvidenceReader:
    """Narrow PostgREST reader over the immutable S1/S1.1 evidence.

    There is deliberately no insert/update/delete/rpc method: a dry run cannot write because
    the object it holds has no way to. Mirrors staging_db.py's allowlist shape.

    COMPLETENESS IS PROVEN, NEVER ASSUMED, and it is proven from the server's OWN page
    coordinates rather than from the row count alone. Every collection read demands a complete
    Content-Range and validates start / end / total against what it actually requested and
    actually received. Missing count metadata, a malformed total or range, a page whose start
    is not the requested offset (a REPEATED page), an end below its start, an end past the
    requested bound, an end not below the total, a body whose size disagrees with the
    coordinate span, a total that changes between pages, or a zero total with a non-empty body
    are all errors — because a capped or replayed membership page would make real positions
    look absent and manufacture POSITION_DISAPPEARED events.
    """

    def __init__(self, base_url, service_key):
        if not base_url or not service_key:
            raise CaptureWriterError("EvidenceReader requires base_url + service_key")
        self.base = base_url.rstrip("/")
        self._key = service_key                       # in-memory only; never logged

    @staticmethod
    def _assert_table(table):
        if table not in ALLOWED_READ_TABLES:
            raise CaptureWriterError(f"table {table!r} is not in the read allowlist")

    @staticmethod
    def _eq(value):
        return f"eq.{urllib.parse.quote(str(value), safe='')}"

    def _get(self, table, query, *, first=None, last=None):
        """One GET. When `first`/`last` are given, an exact count is requested with them."""
        self._assert_table(table)
        url = f"{self.base}/rest/v1/{table}{query}"
        headers = {"apikey": self._key, "Authorization": f"Bearer {self._key}",
                   "Accept": "application/json"}
        if first is not None:
            headers["Prefer"] = "count=exact"
            headers["Range-Unit"] = "items"
            headers["Range"] = f"{first}-{last}"
        req = urllib.request.Request(url, method="GET", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
                text = resp.read().decode("utf-8")
                rows = json.loads(text) if text.strip() else []
                return rows, dict(resp.headers)
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode("utf-8")[:300]
            except Exception:
                pass
            # NB: url/headers carry the key and are deliberately absent from the message.
            raise CaptureWriterError(f"HTTP {e.code} on GET {table}: {detail}") from None
        except urllib.error.URLError as e:
            raise CaptureWriterError(f"network error on GET {table}: {e.reason!r}") from None

    @staticmethod
    def parse_content_range(headers, *, table):
        """('0-7/8' | '*/0') -> (start, end, total). start/end are None for the '*' form.

        PostgREST answers 'START-END/TOTAL' for a page that carried rows and '*/TOTAL' when it
        returned none — the frozen convention staging_db.py already documents ("0-0/42" or
        "*/0"). Nothing here is optional: a '*' total, a missing header, or a non-integer
        coordinate is refused, because fail-open is exactly how a capped page becomes
        fabricated evidence.
        """
        raw = headers.get("Content-Range")
        if not isinstance(raw, str) or "/" not in raw:
            raise IncompleteReadError(
                f"{table}: no exact Content-Range count in the response — completeness cannot "
                f"be proven, so nothing may be derived from this read (got {raw!r})")
        head, _, tail = raw.rpartition("/")
        head, tail = head.strip(), tail.strip()
        if not tail.isdigit():
            raise IncompleteReadError(
                f"{table}: Content-Range total {tail!r} is not an exact integer (got {raw!r})")
        total = int(tail)
        if head == "*":
            return None, None, total
        lo, sep, hi = head.partition("-")
        lo, hi = lo.strip(), hi.strip()
        if not sep or not lo.isdigit() or not hi.isdigit():
            raise IncompleteReadError(
                f"{table}: Content-Range range {head!r} is neither 'START-END' nor '*' "
                f"(got {raw!r})")
        return int(lo), int(hi), total

    @staticmethod
    def validate_page(headers, *, table, row_count, first, last):
        """Prove ONE page against the coordinates the server itself returned.

        Returns (next_offset, total); next_offset is None once the read is provably finished.
        The next offset is END + 1 from the HEADER — never len(accumulated rows) — so a server
        that replays page 0's coordinates for page 1 is caught here instead of silently
        duplicating row 0 and calling a two-row set complete.
        """
        start, end, total = EvidenceReader.parse_content_range(headers, table=table)
        if total == 0:
            # A legal zero result is '*/0' with no body. Anything else contradicts itself.
            if start is not None:
                raise IncompleteReadError(
                    f"{table}: exact count is 0 but the response claims rows {start}-{end} — "
                    f"contradictory metadata is refused, never reconciled")
            if row_count:
                raise IncompleteReadError(
                    f"{table}: exact count is 0 but the body carried {row_count} row(s) — "
                    f"contradictory metadata is refused, never reconciled")
            return None, 0
        if start is None:
            raise IncompleteReadError(
                f"{table}: server answered '*/{total}' for the page starting at {first} — it "
                f"returned no range while promising {total} row(s), so this read cannot be "
                f"proven complete")
        if row_count == 0:
            raise IncompleteReadError(
                f"{table}: server claimed rows {start}-{end} but the body was empty")
        if start != first:
            raise IncompleteReadError(
                f"{table}: requested the page starting at {first} but the server answered "
                f"rows {start}-{end} — a shifted or REPEATED page would duplicate or skip "
                f"rows, so the read is refused rather than assembled")
        if end < start:
            raise IncompleteReadError(
                f"{table}: Content-Range end {end} is below its start {start}")
        if end > last:
            raise IncompleteReadError(
                f"{table}: server returned rows {start}-{end}, past the requested bound "
                f"{first}-{last}")
        span = end - start + 1
        if row_count != span:
            raise IncompleteReadError(
                f"{table}: Content-Range {start}-{end} promises {span} row(s) but the body "
                f"carried {row_count} — coordinates and cardinality disagree")
        if end >= total:
            raise IncompleteReadError(
                f"{table}: Content-Range end {end} is not below the exact total {total} — "
                f"refusing an over-long read")
        return end + 1, total

    @staticmethod
    def count_only_total(headers, *, table, row_count):
        """Exact total from a deliberate rows 0-0 read.

        That range asks for the count header plus AT MOST ONE row: an empty set answers '*/0'
        with no body, and a non-empty one answers '0-0/N' with exactly one row. Any other
        combination contradicts itself and is refused.
        """
        start, end, total = EvidenceReader.parse_content_range(headers, table=table)
        if total == 0:
            if start is not None or row_count:
                raise IncompleteReadError(
                    f"{table}: exact count is 0 but the response returned rows "
                    f"({start}-{end}, {row_count} row(s)) — contradictory metadata")
            return 0
        if (start, end) != (0, 0):
            shown = "*" if start is None else f"{start}-{end}"
            raise IncompleteReadError(
                f"{table}: a rows 0-0 count read over {total} row(s) was answered with "
                f"{shown}/{total} — the server did not answer the page that was asked for")
        if row_count != 1:
            raise IncompleteReadError(
                f"{table}: a rows 0-0 count read over {total} row(s) returned {row_count} "
                f"row(s); exactly one was expected")
        return total

    def _get_all(self, table, query):
        """Every row for `query`, proven complete by the server's own page coordinates.

        The query MUST carry a deterministic `order=`; without a total order two pages can
        overlap or skip rows and the assembled set would be silently wrong.

        Paging is driven by the returned END + 1, so page coordinates are strictly increasing
        and disjoint by construction: validate_page() refuses any page whose start is not the
        offset that was asked for, and the offset only ever advances past the end the server
        just reported. Overlap and repetition are therefore rejected at the page, not
        reconciled afterwards.

        There is deliberately NO separate "accumulated rows > total" check here. Because every
        page proves start == the requested offset and a body of exactly end - start + 1 rows,
        len(rows) telescopes to end + 1, and validate_page() already refuses end >= total — so
        an over-long accumulation is impossible rather than merely unobserved. A second check
        would be unreachable code masquerading as a safety net.
        """
        if "order=" not in query:
            raise CaptureWriterError(
                f"{table}: a paginated read needs a deterministic order= clause; refusing an "
                f"unordered multi-page read")
        rows, total, offset = [], None, 0
        for _ in range(MAX_PAGES):
            last = offset + PAGE_SIZE - 1
            page, headers = self._get(table, query, first=offset, last=last)
            next_offset, page_total = self.validate_page(
                headers, table=table, row_count=len(page), first=offset, last=last)
            if total is None:
                total = page_total
            elif page_total != total:
                raise IncompleteReadError(
                    f"{table}: exact count changed between pages ({total} -> {page_total}) — "
                    f"the underlying set moved mid-read and the result would be ambiguous")
            if next_offset is None:                    # proven empty: '*/0' with no body
                return []
            rows.extend(page)
            offset = next_offset                       # END + 1, from the header
            if len(rows) == total:                     # accumulated cardinality == exact total
                return rows
        raise IncompleteReadError(
            f"{table}: still incomplete after {MAX_PAGES} pages — refusing to continue")

    def runs_in_scope(self, *, user_id, source_account):
        """Runs for exactly this scope, verified AFTER the response as well as asked for in
        the query. Defence in depth: the pure planner repeats this check, because a caller can
        reach plan_capture() without an EvidenceReader — but a row that never should have been
        returned is better refused here, where the request that produced it is still in hand.
        """
        q = (f"?select={','.join(RUN_COLUMNS)}"
             f"&user_id={self._eq(user_id)}&source_account={self._eq(source_account)}"
             f"&order=run_seq.asc.nullslast,id.asc")
        rows = self._get_all(RUNS, q)
        for row in rows:
            if row.get("user_id") != user_id or row.get("source_account") != source_account:
                raise CaptureWriterError(
                    f"{RUNS}: returned run {row.get('id')!r} outside the requested scope even "
                    f"though the query filtered on it — refusing the read rather than "
                    f"reasoning over evidence the server should not have sent")
        return rows

    def memberships_for(self, *, user_id, source_account, run_ids):
        """{run_id: [rows]} for exactly these runs. Absent runs map to an empty list.

        Chunked so the `in.(...)` filter can never build an unbounded URL.
        """
        ordered = list(run_ids)
        out = {rid: [] for rid in ordered}
        for start in range(0, len(ordered), RUN_IDS_PER_REQUEST):
            chunk = ordered[start:start + RUN_IDS_PER_REQUEST]
            joined = ",".join(urllib.parse.quote(str(r), safe="") for r in chunk)
            q = (f"?select={','.join(POSITION_COLUMNS)}"
                 f"&user_id={self._eq(user_id)}&source_account={self._eq(source_account)}"
                 f"&run_id=in.({joined})&order=run_id.asc,position_id.asc")
            for row in self._get_all(POSITIONS, q):
                if row["run_id"] not in out:
                    raise CaptureWriterError(
                        f"{POSITIONS}: returned a row for run {row['run_id']!r}, which was "
                        f"not requested — refusing an out-of-scope projection")
                # T1 re-checks membership scope against the parent run and would refuse this
                # too, but with ITS error type. Catch it here so the refusal is deliberate and
                # names the reader, not the detector.
                if row.get("user_id") != user_id or row.get("source_account") != source_account:
                    raise CaptureWriterError(
                        f"{POSITIONS}: returned a row for run {row['run_id']!r} outside the "
                        f"requested scope — refusing an out-of-scope projection")
                out[row["run_id"]].append(row)
        return out

    def capture_event_count(self, *, user_id):
        """Exact count for THIS user only.

        Rows 0-0 asks the server for exact count metadata plus AT MOST ONE id row: an empty
        account answers '*/0' with no body, a non-empty one answers '0-0/N' with a single id.
        That one id is the entire transfer — no bulk read, and `user_id` scopes the count so
        another user's rows are never counted or seen.
        """
        q = f"?select=id&user_id={self._eq(user_id)}"
        rows, headers = self._get(CAPTURE_EVENTS, q, first=0, last=0)
        return self.count_only_total(headers, table=CAPTURE_EVENTS, row_count=len(rows))


# =============================================================================================
# Persist boundary — narrow, allowlisted, and closed in this phase.
# =============================================================================================
class CaptureAppendClient:
    """The ONE place that may ever call mt5_append_capture_event_v1.

    Not constructed at all unless arming_status() returns 'armed', which
    PERSIST_ENABLED_IN_THIS_PHASE currently makes impossible. Kept narrow so the later gate
    reviews a handful of lines rather than a new subsystem:

      - exactly one RPC name, asserted against ALLOWED_RPCS;
      - one call per CLOSED CANONICAL candidate, arguments exactly as build_rpc_request()
        produced them;
      - the RPC owns idempotency and conflict resolution — this client never retries a
        conflict, never falls back to a direct INSERT, and never edits a stored row;
      - the server's canonical id / event_key are returned to the caller, never re-derived.
    """

    def __init__(self, base_url, service_key):
        if not PERSIST_ENABLED_IN_THIS_PHASE:
            raise CaptureWriterError(
                "CaptureAppendClient is disabled in this phase — the first production call to "
                f"{RPC_APPEND_CAPTURE} requires its own explicit gate")
        if not base_url or not service_key:
            raise CaptureWriterError("CaptureAppendClient requires base_url + service_key")
        self.base = base_url.rstrip("/")
        self._key = service_key

    def append(self, request):
        """One approved RPC call for one closed canonical candidate. Returns the server row."""
        if set(request) != {"p_user", "p_account", "p_candidate"}:
            raise CaptureWriterError("request is not a build_rpc_request() argument set")
        return self._post_rpc(RPC_APPEND_CAPTURE, request)

    def _post_rpc(self, name, payload):
        if name not in ALLOWED_RPCS:
            raise CaptureWriterError(f"rpc {name!r} is not in the allowlist")
        if not PERSIST_ENABLED_IN_THIS_PHASE:                       # belt and braces
            raise CaptureWriterError(f"refusing to call {name}: persist is disabled")
        url = f"{self.base}/rest/v1/rpc/{name}"
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url, data=body, method="POST",
            headers={"apikey": self._key, "Authorization": f"Bearer {self._key}",
                     "Content-Type": "application/json", "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
                text = resp.read().decode("utf-8")
                return json.loads(text) if text.strip() else None
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode("utf-8")[:300]
            except Exception:
                pass
            raise CaptureWriterError(f"HTTP {e.code} on RPC {name}: {detail}") from None
        except urllib.error.URLError as e:
            raise CaptureWriterError(f"network error on RPC {name}: {e.reason!r}") from None


# =============================================================================================
# CLI
# =============================================================================================
def _render(report, *, capture_count_before, capture_count_after):
    out = []
    add = out.append
    add("=" * 78)
    add("MT5 T2 CAPTURE — DRY RUN (read-only; nothing was written)")
    add("=" * 78)
    scope, anchor, hist = report["scope"], report["anchor"], report["canonical_history"]
    add(f"  scope            user {scope['user_id']} / account {scope['source_account']}")
    add("")
    add("ANCHOR (a selector, not a boundary)")
    for label in ("before", "after"):
        run = anchor[label]
        add(f"  {label:<7} run     seq {run['run_seq']}  {run['run_id']}")
        add(f"                   {run['snapshot_status']}/{run['snapshot_health']}  "
            f"captured {run['captured_at']}")
        add(f"                   completed {run[DETECTED_AT_SOURCE]}")
    add("")
    add("COMPLETED OBSERVATION HISTORY (the detection stream is derived from ALL of this)")
    add(f"  as_of            {hist['as_of']}")
    add(f"  observations     {hist['completed_observation_count']}  "
        f"(run_seq {hist['first_run_seq']} .. {hist['last_run_seq']})")
    add(f"    healthy        {hist['healthy_membership_count']}  "
        f"(membership loaded for exactly these)")
    susp = (f"(no membership; each BREAKS continuity at run_seq "
            f"{hist['suspicious_run_seqs']})" if hist["suspicious_run_seqs"]
            else "(none: no continuity break in this history)")
    add(f"    suspicious     {hist['suspicious_observation_count']}  {susp}")
    add(f"  runs in scope    {hist['runs_in_scope_total']}  "
        f"(excluded as future-to-now: {hist['excluded_as_future_to_now']})")
    add(f"  detected_at rule {report['detected_at_rule']}")
    add(f"  quiet window     {report['quiet_window_seconds']}s")

    add("")
    add(f"T1 DETECTIONS OVER THE COMPLETED OBSERVATION HISTORY: "
        f"{report['detection_count']}  "
        f"(belonging to the anchor pair: {report['anchor_detection_count']})")
    if not report["detections"]:
        add("  (none — the immutable evidence shows no change across this history)")
    for d in report["detections"]:
        add(f"  - {d['event_type']}  position {d['position_id']}  at {d.get('detected_at')}")
        add(f"      before {d['before_run']}")
        add(f"      after  {d['after_run']}")
        facts = {k: v for k, v in d.items()
                 if k not in ("event_type", "position_id", "before_run", "after_run",
                              "detected_at")}
        add(f"      facts  {facts}")

    add("")
    add(f"CANONICAL T2 CANDIDATES: {report['canonical_candidate_count']}")
    add(f"ANCHORED CANDIDATES:     {report['anchored_candidate_count']}  "
        f"(closed: {report['closed_anchored_candidates']})")
    for c in report["anchored_candidates"]:
        add(f"  - position {c['position_id']}  {c['state']}")
        add(f"      events         {c['event_sequence']}  "
            f"({c['detection_count']} detection(s))")
        add(f"      run pairs      {c['run_pairs']}")
        add(f"      extends beyond the anchor pair: {c['extends_beyond_anchor']}")
        add(f"      first/last     {c['first_detection_at']} .. {c['last_detection_at']}")
        add(f"      quiet_deadline {c['quiet_deadline']}")
        add(f"      basis_run_id   {c['basis_run_id']}")
        add(f"      persistable    {c['persistable']}  "
            f"(eligible for THIS invocation: {c['eligible_for_this_invocation']})")

    add("")
    add("EVENT KEY / FINGERPRINT / id / created_at")
    add("  Server-derived. build_rpc_request() deliberately omits them, so this dry run cannot")
    add("  show them and does not invent them.")
    add("")
    add("T3 PROMPT RENDERING")
    add("  render_capture_prompt() consumes a PERSISTED mt5_capture_events row and requires")
    add("  id, created_at, event_key and payload_fingerprint. All four are server-derived, so")
    add("  T3 rendering is POST-PERSISTENCE ONLY and is not attempted here. No UUID is faked.")
    add("")
    add(f"mt5_capture_events count (THIS user)  before={capture_count_before}  "
        f"after={capture_count_after}")
    add(f"append RPC calls made                 0  (persist disabled: "
        f"PERSIST_ENABLED_IN_THIS_PHASE={PERSIST_ENABLED_IN_THIS_PHASE})")
    if report["closed_anchored_candidates"]:
        add("")
        add("CANDIDATES_READY_FOR_EXPLICIT_APPEND_GATE")
        add(f"  {report['closed_anchored_candidates']} COMPLETE canonical CLOSED candidate(s)")
        add("  would be persistable by a future gate. NOT persisted here.")
    return "\n".join(out)


def build_parser():
    ap = argparse.ArgumentParser(
        prog="t2_capture_writer.py",
        description="One-shot canonical T1/T2 capture dry run, selected by an explicit "
                    "anchor pair. Read-only by default; persistence needs its own gate.")
    ap.add_argument("--user-id", dest="user_id", default=None,
                    help="THUS auth uid (UUID).")
    ap.add_argument("--source-account", dest="source_account", default=None,
                    help="Broker account identity — opaque TEXT, never parsed as a number.")
    ap.add_argument("--before-run-id", dest="before_run_id", default=None,
                    help="Earlier completed healthy run of the ANCHOR pair (UUID).")
    ap.add_argument("--after-run-id", dest="after_run_id", default=None,
                    help="Later completed healthy run of the ANCHOR pair (UUID).")
    ap.add_argument("--quiet-window-seconds", dest="quiet_window_seconds", type=float,
                    default=None,
                    help="Quiet-window cadence. No default: production cadence is not chosen "
                         "by this harness.")
    ap.add_argument("--now", dest="now", default=None,
                    help="Operator clock as an ISO-8601 instant WITH an offset "
                         "(e.g. 2026-08-24T12:00:00Z); it is converted to UTC. "
                         "Defaults to the current UTC instant, resolved once here.")
    ap.add_argument("--json", dest="as_json", action="store_true",
                    help="Emit the machine-readable report instead of the text one.")
    ap.add_argument("--persist", action="store_true",
                    help="Arm the append gate (disabled in this phase).")
    ap.add_argument("--confirm", default=None,
                    help=f"Exact literal {CONFIRM_PERSIST}, required with --persist.")
    ap.add_argument("--self-test", action="store_true",
                    help="Run the pure test suite (no DB, no network).")
    return ap


def main(argv):
    args = build_parser().parse_args(argv)

    if args.self_test:
        import test_t2_capture_writer as suite                              # noqa: E402
        return suite.main()

    mode, reason = arming_status(persist=args.persist, confirm=args.confirm,
                                 write_env=os.environ.get(WRITE_ENV))
    if mode == "stop":
        print(f"REFUSED: {reason}", file=sys.stderr)
        return 2
    if mode != "dry-run":
        # Unreachable while PERSIST_ENABLED_IN_THIS_PHASE is False. Kept so the later gate has
        # one obvious place to implement, rather than a half-written path running today.
        print("REFUSED: the persist path has no authorized implementation in this phase.",
              file=sys.stderr)
        return 2

    # Required for a dry run, but NOT declared required= in argparse: that would make
    # --self-test (which needs none of them) impossible to invoke. Same refusal, reachable.
    missing = [name for name, value in (
        ("--user-id", args.user_id), ("--source-account", args.source_account),
        ("--before-run-id", args.before_run_id), ("--after-run-id", args.after_run_id),
        ("--quiet-window-seconds", args.quiet_window_seconds)) if value is None]
    if missing:
        print(f"REFUSED: a dry run requires {', '.join(missing)}", file=sys.stderr)
        return 2

    for field, value in (("--user-id", args.user_id),
                         ("--before-run-id", args.before_run_id),
                         ("--after-run-id", args.after_run_id)):
        canonical_uuid_or_raise(value, field=field)
    if not isinstance(args.source_account, str) or not args.source_account.strip():
        raise CaptureWriterError("--source-account must be nonblank opaque text")

    now = to_epoch(parse_instant(args.now) if args.now
                   else _dt.datetime.now(_dt.timezone.utc))

    base_url = os.environ.get("SUPABASE_URL")
    service_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not base_url or not service_key:
        print("REFUSED: SUPABASE_URL and SUPABASE_SERVICE_KEY must be set.", file=sys.stderr)
        return 2

    reader = EvidenceReader(base_url, service_key)
    before_count = reader.capture_event_count(user_id=args.user_id)

    runs = reader.runs_in_scope(user_id=args.user_id, source_account=args.source_account)
    # T1 is fed the WHOLE completed observation history (suspicious runs included, because
    # they break continuity), but membership is fetched for EXACTLY the healthy subset it may
    # compare — no load-then-discard, and never a position list for a control observation.
    # Scope and status domain are proven BEFORE the observation history is derived, so the
    # membership run-id list can never be built from evidence that was never ours. The reader
    # already verified the response; this is the layer that does not depend on it.
    validate_scope(runs, user_id=args.user_id, source_account=args.source_account)
    validate_status_domain(runs)
    observations = completed_observations_as_of(runs, now=now)
    memberships = reader.memberships_for(
        user_id=args.user_id, source_account=args.source_account,
        run_ids=healthy_membership_run_ids(observations))

    report = plan_capture(
        runs=runs, memberships=memberships, user_id=args.user_id,
        source_account=args.source_account, before_run_id=args.before_run_id,
        after_run_id=args.after_run_id, quiet_window_seconds=args.quiet_window_seconds,
        now=now)

    after_count = reader.capture_event_count(user_id=args.user_id)

    if args.as_json:
        print(json.dumps({"report": report,
                          "capture_event_count_before": before_count,
                          "capture_event_count_after": after_count,
                          "append_rpc_calls": 0},
                         indent=2, sort_keys=True, default=str))
    else:
        print(_render(report, capture_count_before=before_count,
                      capture_count_after=after_count))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except CaptureWriterError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        sys.exit(2)
