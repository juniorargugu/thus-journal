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
        -> mt5_append_capture_event_v1   (PERSIST; fully-armed operator canary path,
                                          exactly ONE explicitly named candidate)

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

PERSIST WRITE CONTRACT (phase-enabled for the reviewed first-append canary)
  Dry run remains the DEFAULT and remains structurally read-only. The persist path exists
  behind FOUR keys plus a targeting rule, every one required, none persisted anywhere:

    --persist  +  --confirm PERSIST-CAPTURE-EVENTS  +  env MT5_T2_WRITE=1
    --position-id <int>          the WRITE-SAFETY SELECTOR

  EXACTLY ONE candidate per invocation. The selector never narrows the canonical
  reconstruction — detection, coalescing and the dry-run truth still cover every candidate —
  it narrows only WHAT MAY BE WRITTEN: the single closed, anchored, eligible candidate whose
  position_id it names. Zero matches refuse. More than one match refuses. "First" is never
  chosen silently, and a second eligible candidate is never persisted merely because it is
  ready.

  Persist additionally REFUSES any quiet window other than PRODUCTION_QUIET_WINDOW_SECONDS:
  the v0.1 production policy (900 s) is frozen and forward-only, and W is fingerprint-bearing,
  so a persist under a drifted W must be impossible without a reviewed code change. Dry-run
  analysis may still use any window.

  The write itself is CAPABILITY-GATED. A raw adapter request can NEVER be handed to the
  network: the only path is

      canonical report -> prepare_selected_persist()   (re-verifies phase + all three arming
                          keys + W == 900 + exact single-candidate selection)
                       -> ArmedSelectedAppend          (internal capability; validates its own
                          invariants and pins a digest of the one request it carries)
                       -> CaptureAppendClient.append(capability)   (refuses anything that is
                          not an intact capability)
                       -> mt5_append_capture_event_v1.

  No direct INSERT/UPDATE/DELETE exists anywhere in this file, and the RPC's exact return
  contract (o_ok, o_inserted, o_event_id, o_event_key, o_error_code) is validated as a full
  truth table — success requires a canonical o_event_id AND a canonical 64-hex o_event_key
  with no error code; failure requires o_inserted = 0 and a nonblank error code. Anything
  incoherent stops processing.

  OUTCOME STATE MACHINE (frozen):
    A. NOT SENT / REFUSED     — every failure BEFORE a send is attempted. Nothing was written.
    B. OUTCOME UNCERTAIN      — a send was attempted but no trustworthy result came back
                                (transport error, malformed result). NEVER auto-retried, and
                                NEVER reported as a refusal: the row may exist.
    C. SERVER-CONFIRMED       — a validated result row arrived. A validated INSERT makes the
                                operation permanently WRITE_OCCURRED: no later count, read-back
                                or rendering failure may reclassify it. A post-write
                                verification failure is APPEND_INSERTED_POSTVERIFY_FAILED —
                                "the RPC confirmed the insert, the id/key are known, DO NOT
                                blindly retry, reconcile read-only first" — and it blocks the
                                deliberate replay, because the replay is verification, not
                                recovery.

  --replay-verify sends the SAME capability a second time ONLY after a fully validated insert
  AND a successful identity-bound post-write verification, to prove idempotent replay
  (o_inserted = 0, SAME o_event_id / o_event_key, count unchanged). The persisted row is read
  back and bound to the selected request AND the RPC result (row id == o_event_id, event_key
  == o_event_key, user/account/position/basis/W == the request's) — a row that merely exists
  is not verification. `payload_fingerprint` is server-only: its canonical shape is validated
  and surfaced, never predicted.

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
import hashlib
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

#: Phase gate — OPEN for the reviewed first-append canary. Flipping this back to False
#: re-closes the whole persist path structurally (arming refuses, CaptureAppendClient refuses
#: construction). While open, persistence still requires every arming key AND the
#: single-candidate selector below; the default invocation remains read-only.
PERSIST_ENABLED_IN_THIS_PHASE = True

#: The FROZEN v0.1 production quiet-window policy. PERSIST refuses any other value: the
#: policy is forward-only and W is fingerprint-bearing, so changing it must cost a reviewed
#: code change, never a CLI flag. Dry runs may analyse with any window.
PRODUCTION_QUIET_WINDOW_SECONDS = 900.0

#: The EXACT return contract of mt5_append_capture_event_v1 (rpc packet:
#: `returns table(o_ok boolean, o_inserted integer, o_event_id uuid, o_event_key text,
#: o_error_code text)`). Field names are the server's, never invented here.
RPC_RESULT_FIELDS = ("o_ok", "o_inserted", "o_event_id", "o_event_key", "o_error_code")

#: Columns read back from the persisted row: the fields T3 requires (id / created_at /
#: event_key / payload_fingerprint) plus every identity field the read-back is bound against.
#: payload_fingerprint is server-derived and NOT in the RPC return, so surfacing it honestly
#: means reading the stored row, not computing it.
CAPTURE_EVENT_ROW_COLUMNS = ("id", "created_at", "event_key", "payload_fingerprint",
                             "user_id", "source_account", "position_id", "basis_run_id",
                             "quiet_window_seconds")

#: FAILURE-BRANCH CONTRACT of the applied RPC (T2_capture_events_rpc_packet.sql, packet
#: revision 5, applied migration mt5_t2_capture_events_rpc_v1). Maps every o_error_code the
#: applied SQL can emit to the (o_event_id, o_event_key) shape its return branch carries:
#: "null" = that branch returns NULL, "present" = that branch always returns a value. All 71
#: validation returns in the applied SQL are `select false, 0, null::uuid, null::text, code`;
#: the ERR_CAPTURE_CONFLICT branch answers with the EXISTING row's id and key; the
#: bounded-retry ERR_CAPTURE_RACE branch computed the key but has no row id to name. The
#: applied SQL has NO generic catch-all branch, so an error code outside this table is a
#: contract violation and the response is refused, never interpreted.
RPC_FAILURE_SHAPES = {
    **{code: ("null", "null") for code in (
        "ERR_BAD_INPUT", "ERR_CAPTURE_PAYLOAD_KEYS", "ERR_CAPTURE_DOMAIN",
        "ERR_CAPTURE_FORBIDDEN_FIELD", "ERR_CAPTURE_SCOPE", "ERR_CAPTURE_PAYLOAD_INVALID",
        "ERR_CAPTURE_TIME_ORDER", "ERR_CAPTURE_WINDOW_MISMATCH", "ERR_CAPTURE_PROVENANCE",
        "ERR_CAPTURE_IDENTITY", "ERR_CAPTURE_DETECTION", "ERR_CAPTURE_BASIS_MISMATCH",
        "ERR_BASIS_RUN_NOT_FOUND", "ERR_BASIS_RUN_SCOPE", "ERR_BASIS_RUN_NOT_COMPLETE",
        "ERR_BASIS_RUN_NOT_HEALTHY", "ERR_RUN_NOT_FOUND", "ERR_RUN_SCOPE",
        "ERR_RUN_NOT_COMPLETE", "ERR_RUN_NOT_HEALTHY", "ERR_RUN_SEQ_MISMATCH",
        "ERR_RUN_NOT_ADJACENT")},
    "ERR_CAPTURE_CONFLICT": ("present", "present"),
    "ERR_CAPTURE_RACE": ("null", "present"),
}

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
# Persist targeting + RPC-result contract — pure, exercised by test_t2_capture_writer.py.
# =============================================================================================
def validate_position_selector(value):
    """The write-safety selector must be a positive bigint-style integer. Fail closed on
    bool / str / float / None — a selector that had to be coerced is not an exact target."""
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise CaptureWriterError(
            f"--position-id {value!r} is not a positive integer position id — the persist "
            f"selector is exact or it is nothing")
    return value


def select_persist_request(report, *, position_id):
    """EXACTLY ONE closed, anchored, eligible candidate for `position_id` — or a refusal.

    Selection happens strictly AFTER canonical reconstruction: `report` already contains the
    complete truth (every canonical candidate, every anchored candidate, and one prepared RPC
    request per CLOSED anchored candidate). This function only decides what may be WRITTEN:

      0 matching requests  -> refuse (an open, unanchored, or absent candidate is never
                              promoted to persistable by naming it)
      2+ matching requests -> refuse (impossible through the real pipeline — T1 emits at most
                              one event per position per adjacent pair — but a corrupted or
                              hand-built report must not get to pick "first")
      exactly 1            -> returned VERBATIM, after cross-checks

    Other ready candidates are listed in the refusal by position_id only, and are NEVER
    persisted implicitly.
    """
    validate_position_selector(position_id)
    requests = report["rpc_requests"]
    matches = [r for r in requests if r["p_candidate"]["position_id"] == position_id]
    if not matches:
        others = sorted({r["p_candidate"]["position_id"] for r in requests})
        raise CaptureWriterError(
            f"no closed, anchored, eligible candidate exists for position {position_id} in "
            f"this reconstruction — nothing is persisted. Persistable position(s) here: "
            f"{others or 'none'}; each needs its own explicit invocation")
    if len(matches) > 1:
        raise CaptureWriterError(
            f"{len(matches)} prepared requests claim position {position_id} — exactly one "
            f"candidate may be persisted per invocation and this harness never chooses "
            f"'first', so the whole persist is refused")
    summaries = [c for c in report["anchored_candidates"] if c["position_id"] == position_id]
    if len(summaries) != 1:
        raise CaptureWriterError(
            f"candidate summary for position {position_id} is not unique "
            f"({len(summaries)} entries) — the report is not internally consistent, refusing")
    summary = summaries[0]
    if not (summary["closed"] is True and summary["eligible_for_this_invocation"] is True):
        raise CaptureWriterError(
            f"candidate for position {position_id} is not closed+eligible "
            f"(closed={summary['closed']!r}, "
            f"eligible={summary['eligible_for_this_invocation']!r}) — refusing")
    request = matches[0]
    scope = report["scope"]
    if request["p_user"] != scope["user_id"] or request["p_account"] != scope["source_account"]:
        raise CaptureWriterError(
            f"prepared request for position {position_id} does not carry the requested "
            f"scope — refusing a cross-scope write")
    return request


def canonical_event_key_or_raise(value, *, field):
    """Exactly 64 lowercase hex characters. No trimming, no case folding, no coercion — a
    malformed server key is a contract violation that stops processing, never a fixable
    spelling."""
    if not (isinstance(value, str) and len(value) == 64
            and all(c in "0123456789abcdef" for c in value)):
        raise CaptureWriterError(
            f"{field} {value!r} is not a canonical event key (exactly 64 lowercase hex)")
    return value


def parse_rpc_result(rows, *, call_label):
    """One RPC response -> the single validated result row, checked as a FULL truth table.

    PostgREST renders a `returns table(...)` function as a JSON array of row objects, so a
    valid answer is EXACTLY one row carrying EXACTLY the five contract columns:

      o_ok = true   ->  o_error_code NULL, o_inserted in {0, 1}, o_event_id REQUIRED
                        canonical uuid, o_event_key REQUIRED canonical 64-hex.
                        inserted=1 is a fresh insert; inserted=0 is an exact replay.
      o_ok = false  ->  o_inserted = 0 and a nonblank o_error_code that the applied RPC
                        actually emits, with o_event_id/o_event_key in EXACTLY the shape of
                        the SQL branch that named the error (RPC_FAILURE_SHAPES): both null
                        for every validation refusal, both present for ERR_CAPTURE_CONFLICT
                        (the EXISTING row's identity), null id + present key for
                        ERR_CAPTURE_RACE. Present values must still be canonical.

    Any other combination — an unknown error code included — is not the applied contract
    and is refused rather than interpreted.
    """
    if not isinstance(rows, list) or len(rows) != 1:
        raise CaptureWriterError(
            f"{call_label}: RPC answered {type(rows).__name__} with "
            f"{len(rows) if isinstance(rows, list) else 'n/a'} row(s); the contract is "
            f"exactly one result row")
    row = rows[0]
    if not isinstance(row, dict) or set(row) != set(RPC_RESULT_FIELDS):
        raise CaptureWriterError(
            f"{call_label}: result columns {sorted(row) if isinstance(row, dict) else row!r} "
            f"are not exactly {sorted(RPC_RESULT_FIELDS)}")
    if not isinstance(row["o_ok"], bool):
        raise CaptureWriterError(f"{call_label}: o_ok {row['o_ok']!r} is not a boolean")
    if (not isinstance(row["o_inserted"], int) or isinstance(row["o_inserted"], bool)
            or row["o_inserted"] not in (0, 1)):
        raise CaptureWriterError(
            f"{call_label}: o_inserted {row['o_inserted']!r} is not 0 or 1")
    for field in ("o_event_id", "o_event_key", "o_error_code"):
        value = row[field]
        if value is not None and not (isinstance(value, str) and value.strip()):
            raise CaptureWriterError(f"{call_label}: {field} {value!r} is neither null nor a "
                                     f"nonblank string")
    if row["o_event_id"] is not None and not t2a._canonical_uuid(row["o_event_id"]):
        raise CaptureWriterError(
            f"{call_label}: o_event_id {row['o_event_id']!r} is not a canonical uuid")
    if row["o_event_key"] is not None:
        canonical_event_key_or_raise(row["o_event_key"],
                                     field=f"{call_label}: o_event_key")

    if row["o_ok"]:
        # SUCCESS CONTRACT — both the fresh insert AND the exact replay return the row's
        # identity; a success without it is not the SQL contract.
        if row["o_error_code"] is not None:
            raise CaptureWriterError(
                f"{call_label}: o_ok with o_error_code {row['o_error_code']!r} — "
                f"contradictory")
        if row["o_event_id"] is None:
            raise CaptureWriterError(f"{call_label}: success without an o_event_id")
        if row["o_event_key"] is None:
            raise CaptureWriterError(f"{call_label}: success without an o_event_key")
    else:
        # FAILURE CONTRACT — bound branch-by-branch to the applied SQL. The RPC never
        # writes on failure, always names the error, and returns o_event_id/o_event_key in
        # exactly the shape of the branch that named it (RPC_FAILURE_SHAPES). An unknown
        # code or an impossible id/key shape means the response does not come from the
        # applied contract and cannot be trusted.
        if row["o_inserted"] != 0:
            raise CaptureWriterError(
                f"{call_label}: o_ok=false with o_inserted={row['o_inserted']} — the RPC "
                f"never claims a write on failure")
        if row["o_error_code"] is None:
            raise CaptureWriterError(
                f"{call_label}: o_ok=false without an o_error_code")
        shape = RPC_FAILURE_SHAPES.get(row["o_error_code"])
        if shape is None:
            raise CaptureWriterError(
                f"{call_label}: o_error_code {row['o_error_code']!r} is not an error the "
                f"applied RPC revision emits — an unknown contract is refused, not "
                f"interpreted")
        for field, required in (("o_event_id", shape[0]), ("o_event_key", shape[1])):
            if required == "null" and row[field] is not None:
                raise CaptureWriterError(
                    f"{call_label}: the applied {row['o_error_code']} branch never returns "
                    f"{field}, but the response carries {row[field]!r}")
            if required == "present" and row[field] is None:
                raise CaptureWriterError(
                    f"{call_label}: the applied {row['o_error_code']} branch always "
                    f"returns {field}, but the response has null")
    return row


def validate_persisted_row(row, *, request, rpc_result):
    """Bind the read-back row to the SELECTED request and the VALIDATED RPC result.

    Cardinality alone proves nothing — a row that merely exists could be anyone's. Every
    identity fact the client knew before the write (scope, position, basis run, window) and
    every fact the server confirmed (o_event_id, o_event_key) must match EXACTLY; only
    server-only values (created_at, payload_fingerprint) are shape-validated instead of
    compared. source_account is exact TEXT — never normalised to match.
    """
    if not isinstance(row, dict) or set(row) != set(CAPTURE_EVENT_ROW_COLUMNS):
        raise CaptureWriterError(
            f"persisted row columns {sorted(row) if isinstance(row, dict) else row!r} are "
            f"not exactly {sorted(CAPTURE_EVENT_ROW_COLUMNS)}")
    candidate = request["p_candidate"]
    expected = {
        "id": rpc_result["o_event_id"],
        "event_key": rpc_result["o_event_key"],
        "user_id": request["p_user"],
        "source_account": request["p_account"],
        "position_id": candidate["position_id"],
        "basis_run_id": candidate["basis_run_id"],
    }
    for field, want in expected.items():
        got = row[field]
        if got != want:
            raise CaptureWriterError(
                f"persisted row {field} {got!r} does not match the expected {want!r} — the "
                f"row that came back is not the row this invocation wrote")
    window = row["quiet_window_seconds"]
    try:
        window_value = float(window)
    except (TypeError, ValueError):
        raise CaptureWriterError(
            f"persisted row quiet_window_seconds {window!r} is not numeric") from None
    if (window_value != float(candidate["quiet_window_seconds"])
            or window_value != PRODUCTION_QUIET_WINDOW_SECONDS):
        raise CaptureWriterError(
            f"persisted row quiet_window_seconds {window!r} is not the frozen production "
            f"window {PRODUCTION_QUIET_WINDOW_SECONDS:g}")
    canonical_uuid_or_raise(row["id"], field="persisted row id")
    canonical_event_key_or_raise(row["event_key"], field="persisted row event_key")
    canonical_event_key_or_raise(row["payload_fingerprint"],
                                 field="persisted row payload_fingerprint")
    parse_instant(row["created_at"])                     # shape only: server-owned instant
    return row


#: Module-private mint token: ArmedSelectedAppend refuses construction without it, so the
#: ONLY way to obtain a write capability through the supported API is prepare_selected_persist.
_MINT_TOKEN = object()


class ArmedSelectedAppend:
    """INTERNAL write capability: exactly ONE selected request, minted only by
    prepare_selected_persist() after every arming and selection check passed.

    The capability validates its own invariants — it cannot hold zero or several requests, a
    request for a different position than it names, or a non-production window — and it pins
    a canonical digest of the request at mint time. The transport re-verifies that digest
    before every send, so the capability cannot be re-used with a different or mutated
    request: what was selected is byte-for-byte what is sent, on the first call and on the
    deliberate replay alike.
    """

    __slots__ = ("request", "position_id", "digest")

    def __init__(self, *, _token=None, request, position_id):
        if _token is not _MINT_TOKEN:
            raise CaptureWriterError(
                "ArmedSelectedAppend can only be minted by prepare_selected_persist() — a "
                "self-built capability is not a write authorization")
        if not (isinstance(request, dict)
                and set(request) == {"p_user", "p_account", "p_candidate"}):
            raise CaptureWriterError("capability request is not a build_rpc_request() "
                                     "argument set")
        candidate = request["p_candidate"]
        validate_position_selector(position_id)
        if candidate.get("position_id") != position_id:
            raise CaptureWriterError(
                f"capability position {position_id} does not match the request's "
                f"{candidate.get('position_id')!r}")
        identities = candidate.get("detection_identities")
        if not (isinstance(identities, list) and identities
                and all(identity[3] == position_id for identity in identities)):
            raise CaptureWriterError(
                f"capability for position {position_id} carries identities that are not all "
                f"its own — a foreign candidate can never hitchhike in a capability")
        if (float(candidate.get("quiet_window_seconds", -1.0))
                != PRODUCTION_QUIET_WINDOW_SECONDS):
            raise CaptureWriterError(
                f"capability window {candidate.get('quiet_window_seconds')!r} is not the "
                f"frozen production window {PRODUCTION_QUIET_WINDOW_SECONDS:g}")
        object.__setattr__(self, "request", request)
        object.__setattr__(self, "position_id", position_id)
        object.__setattr__(self, "digest", self._canonical_digest(request))

    def __setattr__(self, name, value):
        raise CaptureWriterError("ArmedSelectedAppend is immutable")

    @staticmethod
    def _canonical_digest(request):
        try:
            wire = json.dumps(request, sort_keys=True, separators=(",", ":"))
        except (TypeError, ValueError) as exc:
            raise CaptureWriterError(
                f"capability request is not JSON-serialisable: {exc}") from None
        return hashlib.sha256(wire.encode("utf-8")).hexdigest()

    def verify_intact(self):
        """The request now must be the request that was minted. Refuses mutation/swap."""
        if self._canonical_digest(self.request) != self.digest:
            raise CaptureWriterError(
                "capability request no longer matches its minted digest — a mutated or "
                "swapped request is refused, never sent")
        return self


def prepare_selected_persist(report, *, position_id, persist, confirm, write_env,
                             quiet_window_seconds):
    """The ONLY minting path for a write capability. Re-verifies EVERYTHING itself —
    phase gate, all three arming keys, the frozen production window, and the exact
    single-candidate selection — so a caller that skipped the CLI cannot skip the contract.
    """
    mode, reason = arming_status(persist=persist, confirm=confirm, write_env=write_env)
    if mode != "armed":
        raise CaptureWriterError(
            f"persist capability refused: "
            f"{reason if reason else 'not armed (--persist was not requested)'}")
    try:
        window = float(quiet_window_seconds)
    except (TypeError, ValueError):
        raise CaptureWriterError(
            f"persist capability refused: quiet window {quiet_window_seconds!r} is not "
            f"numeric") from None
    if window != PRODUCTION_QUIET_WINDOW_SECONDS:
        raise CaptureWriterError(
            f"persist capability refused: quiet window {quiet_window_seconds!r} is not the "
            f"frozen production value {PRODUCTION_QUIET_WINDOW_SECONDS:g} — the policy is "
            f"forward-only")
    request = select_persist_request(report, position_id=position_id)
    return ArmedSelectedAppend(_token=_MINT_TOKEN, request=request,
                               position_id=position_id)


#: Verdicts that mean the RPC validated a genuine INSERT. Permanent: no later failure of any
#: count / read-back / render may reclassify the operation as anything but a write.
_WRITE_OCCURRED_VERDICTS = (
    "APPEND_INSERTED_POSTVERIFY_FAILED",
    "INSERTED_NO_REPLAY_REQUESTED",
    "INSERTED_AND_REPLAY_IDEMPOTENT",
    "INSERTED_BUT_REPLAY_NOT_IDEMPOTENT",
    "INSERTED_REPLAY_OUTCOME_UNCERTAIN",
    "INSERTED_REPLAY_POSTVERIFY_FAILED",
)

#: The only verdicts that exit 0. Everything else is evidence plus a nonzero exit.
_CLEAN_VERDICTS = ("INSERTED_NO_REPLAY_REQUESTED", "INSERTED_AND_REPLAY_IDEMPOTENT")


def execute_selected_persist(client, reader, capability, *, replay_verify, count_before):
    """The whole write operation, as the frozen outcome state machine. NEVER raises after a
    send has been attempted: EVERY ordinary exception past that point — transport failure,
    JSON decoding, a contract violation, any other Exception — is captured INSIDE the
    outcome, because an exception escaping to a generic handler is how a completed write
    gets misreported as a refusal. Only process-termination signals (KeyboardInterrupt,
    SystemExit, GeneratorExit — BaseException, not Exception) still escape.

      call 1 attempted, no validated result -> UNCERTAIN (row may exist; no retry)
      validated o_ok=false                  -> SERVER_CONFIRMED, no write (FIRST_CALL_REFUSED)
      validated o_inserted=0 on call 1      -> SERVER_CONFIRMED, no new write (ALREADY_A_REPLAY)
      validated o_inserted=1                -> write_occurred=True, PERMANENTLY

    The two verification phases are tracked INDEPENDENTLY — they never share a flag:

      insert_post_verify_*   count == before+1 AND the identity-bound row read-back, directly
                             after the confirmed insert. Failure yields
                             APPEND_INSERTED_POSTVERIFY_FAILED: the write stands, the id/key
                             are preserved, and the deliberate replay is BLOCKED (it is
                             verification, not recovery).
      replay_post_verify_*   after a validated idempotent replay answer (o_inserted=0, SAME
                             id and key), the count must STILL be before+1. Failure yields
                             INSERTED_REPLAY_POSTVERIFY_FAILED while the insert and ITS
                             verification remain truthfully PASS.

    A failed or uncertain replay never un-claims the confirmed insert, and no path ever
    makes a third call.
    """
    if not isinstance(capability, ArmedSelectedAppend):
        raise CaptureWriterError(          # pre-send: still a legitimate REFUSED
            "execute_selected_persist requires the armed-selected capability")
    capability.verify_intact()             # pre-send: a tampered capability is REFUSED here,
    #                                        never misreported as an uncertain send
    out = {"write_state": None, "write_occurred": False, "verdict": None,
           "first": None, "replay": None, "uncertainty": None,
           "insert_post_verify_ok": None, "insert_post_verify_error": None,
           "replay_post_verify_ok": None, "replay_post_verify_error": None,
           "row": None, "count_before": count_before, "count_after": None,
           "replay_count_after": None, "calls_attempted": 0, "position_id":
           capability.position_id}

    # ---- CALL 1 ------------------------------------------------------------------------
    out["calls_attempted"] = 1
    try:
        first = parse_rpc_result(client.append(capability), call_label="append call 1")
    except CaptureWriterError as exc:
        out["write_state"] = "UNCERTAIN"
        out["verdict"] = "APPEND_OUTCOME_UNCERTAIN"
        out["uncertainty"] = str(exc)
        return out
    except Exception as exc:               # noqa: BLE001 — call 1: the POST was attempted,
        # so a JSON decode error, a ValueError, ANY ordinary exception makes the outcome
        # UNKNOWABLE — never REFUSED, never an escape. BaseException still terminates.
        out["write_state"] = "UNCERTAIN"
        out["verdict"] = "APPEND_OUTCOME_UNCERTAIN"
        out["uncertainty"] = f"{type(exc).__name__}: {exc}"
        return out
    out["first"] = first
    out["write_state"] = "SERVER_CONFIRMED"
    if not first["o_ok"]:
        out["verdict"] = f"FIRST_CALL_REFUSED:{first['o_error_code']}"
        return out
    if first["o_inserted"] != 1:
        out["verdict"] = "FIRST_CALL_WAS_ALREADY_A_REPLAY"
        return out
    out["write_occurred"] = True                      # PERMANENT from this line on

    # ---- POST-INSERT VERIFICATION (best-effort; failures stay INSIDE the outcome) -------
    error = None
    try:
        count_after = reader.capture_event_count(user_id=capability.request["p_user"])
        out["count_after"] = count_after
        if count_after != count_before + 1:
            error = (f"capture_event_count moved {count_before} -> {count_after}; a single "
                     f"fresh insert expects exactly +1")
        else:
            row = reader.capture_event_by_id(user_id=capability.request["p_user"],
                                             event_id=first["o_event_id"])
            validate_persisted_row(row, request=capability.request, rpc_result=first)
            out["row"] = row
    except Exception as exc:                          # noqa: BLE001 — MUST NOT escape
        error = f"{type(exc).__name__}: {exc}"
    if error is not None:
        out["insert_post_verify_ok"] = False
        out["insert_post_verify_error"] = error
        out["verdict"] = "APPEND_INSERTED_POSTVERIFY_FAILED"
        return out                                    # replay BLOCKED: verify, don't recover
    out["insert_post_verify_ok"] = True
    if not replay_verify:
        out["verdict"] = "INSERTED_NO_REPLAY_REQUESTED"
        return out

    # ---- CALL 2: deliberate identical replay --------------------------------------------
    out["calls_attempted"] = 2
    try:
        second = parse_rpc_result(client.append(capability), call_label="replay call 2")
    except CaptureWriterError as exc:
        out["verdict"] = "INSERTED_REPLAY_OUTCOME_UNCERTAIN"
        out["uncertainty"] = str(exc)
        return out
    except Exception as exc:               # noqa: BLE001 — call 2: same rule as call 1. The
        # replay outcome is UNKNOWABLE, the confirmed insert stands, and NO third call runs.
        out["verdict"] = "INSERTED_REPLAY_OUTCOME_UNCERTAIN"
        out["uncertainty"] = f"{type(exc).__name__}: {exc}"
        return out
    out["replay"] = second
    if not (second["o_ok"] and second["o_inserted"] == 0
            and second["o_event_id"] == first["o_event_id"]
            and second["o_event_key"] == first["o_event_key"]):
        out["verdict"] = "INSERTED_BUT_REPLAY_NOT_IDEMPOTENT"
        return out
    # ---- POST-REPLAY VERIFICATION (independent of the insert verification) --------------
    error = None
    try:
        replay_count = reader.capture_event_count(user_id=capability.request["p_user"])
        out["replay_count_after"] = replay_count
        if replay_count != count_before + 1:
            error = (f"count moved to {replay_count} after the replay; "
                     f"expected it to remain {count_before + 1}")
    except Exception as exc:                      # noqa: BLE001 — MUST NOT escape (replay)
        error = f"{type(exc).__name__}: {exc}"
    if error is not None:
        out["replay_post_verify_ok"] = False
        out["replay_post_verify_error"] = error
        out["verdict"] = "INSERTED_REPLAY_POSTVERIFY_FAILED"
        return out
    out["replay_post_verify_ok"] = True
    out["verdict"] = "INSERTED_AND_REPLAY_IDEMPOTENT"
    return out


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

    def capture_event_by_id(self, *, user_id, event_id):
        """The persisted capture row (GET). Cardinality only — IDENTITY is deliberately not
        proven here: validate_persisted_row() binds the row to the selected request and the
        RPC result, because a row that merely exists could be anyone's."""
        canonical_uuid_or_raise(event_id, field="event_id")
        q = (f"?select={','.join(CAPTURE_EVENT_ROW_COLUMNS)}"
             f"&user_id={self._eq(user_id)}&id={self._eq(event_id)}")
        rows, _ = self._get(CAPTURE_EVENTS, q)
        if len(rows) != 1:
            raise CaptureWriterError(
                f"{CAPTURE_EVENTS}: expected exactly one row for event {event_id}, "
                f"got {len(rows)}")
        return rows[0]

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

    Constructed only on the fully-armed persist path (arming_status() == 'armed' AND an
    explicit --position-id selection succeeded); construction itself still refuses whenever
    PERSIST_ENABLED_IN_THIS_PHASE is False, so re-closing the phase is one constant. Narrow
    on purpose:

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

    def append(self, capability):
        """One RPC call for ONE armed-selected capability. A raw adapter request — however
        well-formed — is NOT a write authorization and is refused: minting the capability is
        where arming, selection cardinality and the frozen window were proven, and the digest
        check makes the sent bytes the minted bytes."""
        if not isinstance(capability, ArmedSelectedAppend):
            raise CaptureWriterError(
                "CaptureAppendClient.append accepts ONLY the ArmedSelectedAppend capability "
                "minted by prepare_selected_persist() — a raw request dict is not a write "
                "authorization")
        capability.verify_intact()
        return self._post_rpc(RPC_APPEND_CAPTURE, capability.request)

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
    add("append RPC calls made                 0  (dry run — this invocation is structurally "
        "read-only; persisting needs --persist --confirm + MT5_T2_WRITE=1 + --position-id)")
    if report["closed_anchored_candidates"]:
        add("")
        add("CANDIDATES_READY_FOR_EXPLICIT_APPEND_GATE")
        add(f"  {report['closed_anchored_candidates']} COMPLETE canonical CLOSED candidate(s)")
        add("  would be persistable by a future gate. NOT persisted here.")
    return "\n".join(out)


def _render_persist(outcome):
    out = []
    add = out.append
    add("=" * 78)
    add("MT5 T2 CAPTURE — PERSIST (single named candidate)")
    add("=" * 78)
    add(f"  target position                {outcome['position_id']}")
    add(f"  append RPC calls attempted     {outcome['calls_attempted']}")
    add(f"  write_state                    {outcome['write_state']}")
    add(f"  WRITE OCCURRED                 {outcome['write_occurred']}")
    for label, result in (("CALL 1 (append)", outcome["first"]),
                          ("CALL 2 (identical replay)", outcome["replay"])):
        if result is None:
            add(f"  {label}: no validated result")
            continue
        add(f"  {label}:")
        for field in RPC_RESULT_FIELDS:
            add(f"      {field:<13} {result[field]!r}")
    add(f"  VERDICT                        {outcome['verdict']}")
    if outcome["uncertainty"]:
        add(f"  uncertainty                    {outcome['uncertainty']}")
        if outcome["write_occurred"]:
            add("  The INSERT above is confirmed; only the REPLAY outcome is unknown. "
                "DO NOT retry. Reconcile with a read-only dry run first.")
        else:
            add("  The row MAY exist. DO NOT retry. Reconcile with a read-only dry run "
                "first.")
    add("")
    if outcome["write_occurred"]:
        add("SERVER-CONFIRMED WRITE — this fact is permanent regardless of anything below.")
        add(f"  o_event_id   {outcome['first']['o_event_id']}")
        add(f"  o_event_key  {outcome['first']['o_event_key']}")
    # ---- PHASE REPORT: each verification phase independently; the OVERALL line follows
    #      the VERDICT alone. No single flag may ever make a partial success look like a
    #      full pass: a failed replay verification is an overall FAILURE even though the
    #      insert and its own verification remain truthfully PASS.
    verdict = outcome["verdict"]
    if outcome["write_occurred"]:
        add("INITIAL INSERT: CONFIRMED")
    elif outcome["write_state"] == "SERVER_CONFIRMED":
        add("INITIAL INSERT: NONE (the server confirmed that no new row was written)")
    else:
        add("INITIAL INSERT: OUTCOME UNCERTAIN")
    if outcome["insert_post_verify_ok"] is True:
        add("INITIAL VERIFICATION: PASS (count +1; row identity-bound to the selected "
            "request and the RPC result)")
    elif outcome["insert_post_verify_ok"] is False:
        add("INITIAL VERIFICATION: FAILED")
        add(f"  {outcome['insert_post_verify_error']}")
        add("  The RPC confirmed the insert and the id/key above are known good.")
        add("  DO NOT BLINDLY RETRY. The deliberate replay was NOT attempted.")
        add("  Reconcile READ-ONLY first; only then decide the next step.")
    else:
        add("INITIAL VERIFICATION: NOT ATTEMPTED")
    if verdict == "INSERTED_NO_REPLAY_REQUESTED":
        add("REPLAY: NOT REQUESTED")
    elif verdict == "APPEND_INSERTED_POSTVERIFY_FAILED":
        add("REPLAY: BLOCKED — initial verification failed (replay is verification, "
            "never recovery)")
    elif verdict == "INSERTED_REPLAY_OUTCOME_UNCERTAIN":
        add("REPLAY: OUTCOME UNCERTAIN — the replay POST was attempted but returned no "
            "validated result. NO third call was made.")
    elif outcome["replay"] is not None:
        add("REPLAY: SERVER RESPONSE RECEIVED")
    else:
        add("REPLAY: NOT ATTEMPTED")
    if outcome["replay_post_verify_ok"] is True:
        add("REPLAY VERIFICATION: PASS (same id/key, o_inserted=0, count unchanged)")
    elif outcome["replay_post_verify_ok"] is False:
        add("REPLAY VERIFICATION: FAILED")
        add(f"  {outcome['replay_post_verify_error']}")
    elif verdict == "INSERTED_BUT_REPLAY_NOT_IDEMPOTENT":
        add("REPLAY VERIFICATION: FAILED (the replay answered a DIFFERENT identity)")
    else:
        add("REPLAY VERIFICATION: NOT ATTEMPTED")
    if verdict in _CLEAN_VERDICTS:
        add("OVERALL: PASS")
    else:
        add("OVERALL: FAILURE — this is NOT a clean canary result.")
        if outcome["write_occurred"]:
            add("  The initial insert IS real and MUST be treated as persisted evidence.")
        add("  DO NOT BLINDLY RETRY.")
        add("  READ-ONLY RECONCILIATION REQUIRED before any further write decision.")
    if outcome["row"] is not None:
        add("")
        add("PERSISTED ROW (read back; identity-bound)")
        for field in CAPTURE_EVENT_ROW_COLUMNS:
            add(f"  {field:<21} {outcome['row'].get(field)!r}")
    add("")
    add(f"mt5_capture_events count (THIS user)  before={outcome['count_before']}  "
        f"after_insert={outcome['count_after']}  after_replay={outcome['replay_count_after']}")
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
                    help="Arm the append gate. Requires --confirm, env MT5_T2_WRITE=1 and "
                         "--position-id; persists EXACTLY ONE named candidate.")
    ap.add_argument("--confirm", default=None,
                    help=f"Exact literal {CONFIRM_PERSIST}, required with --persist.")
    ap.add_argument("--position-id", dest="position_id", type=int, default=None,
                    help="WRITE-SAFETY SELECTOR (persist only): the exact position_id of the "
                         "single candidate this invocation may persist. Never narrows the "
                         "dry-run/canonical truth.")
    ap.add_argument("--replay-verify", dest="replay_verify", action="store_true",
                    help="Persist only: after a fully VERIFIED first insert (validated "
                         "RPC result, count +1, identity-bound read-back), send the "
                         "IDENTICAL request once more to prove idempotent replay. Not a "
                         "retry, and never attempted when any of that failed.")
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

    # The selector belongs EXCLUSIVELY to persist mode: a dry run always reports every
    # canonical candidate (the selector must never narrow evidence), and persist never runs
    # without one (the selector must always narrow the mutation set to exactly one).
    if mode == "dry-run" and args.position_id is not None:
        print("REFUSED: --position-id is a write-safety selector for --persist; a dry run "
              "always reports every canonical candidate and needs no selector.",
              file=sys.stderr)
        return 2
    if mode == "dry-run" and args.replay_verify:
        print("REFUSED: --replay-verify only has meaning with --persist.", file=sys.stderr)
        return 2

    # Required for any reconstruction, but NOT declared required= in argparse: that would
    # make --self-test (which needs none of them) impossible to invoke.
    missing = [name for name, value in (
        ("--user-id", args.user_id), ("--source-account", args.source_account),
        ("--before-run-id", args.before_run_id), ("--after-run-id", args.after_run_id),
        ("--quiet-window-seconds", args.quiet_window_seconds)) if value is None]
    if missing:
        print(f"REFUSED: this invocation requires {', '.join(missing)}", file=sys.stderr)
        return 2

    if mode == "armed":
        if args.position_id is None:
            print("REFUSED: --persist requires --position-id: exactly one candidate may be "
                  "persisted per invocation, and it must be NAMED, never inferred.",
                  file=sys.stderr)
            return 2
        try:
            validate_position_selector(args.position_id)
        except CaptureWriterError as exc:
            print(f"REFUSED: {exc}", file=sys.stderr)
            return 2
        if float(args.quiet_window_seconds) != PRODUCTION_QUIET_WINDOW_SECONDS:
            print(f"REFUSED: persist requires the frozen production quiet window "
                  f"({PRODUCTION_QUIET_WINDOW_SECONDS:g}s); got "
                  f"{args.quiet_window_seconds!r}. The policy is forward-only — changing it "
                  f"is a reviewed code change, not a CLI value.", file=sys.stderr)
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

    if mode == "dry-run":
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

    # ---- PERSIST (armed): exactly one named candidate ---------------------------------
    # Selection is applied AFTER the full canonical reconstruction above — the report still
    # carries every candidate; only the mutation set narrows. prepare_selected_persist()
    # re-verifies arming + window + selection itself, so the CLI checks above are a fast
    # path, not the boundary. Every failure HERE is pre-send: nothing was written.
    try:
        capability = prepare_selected_persist(
            report, position_id=args.position_id, persist=args.persist,
            confirm=args.confirm, write_env=os.environ.get(WRITE_ENV),
            quiet_window_seconds=args.quiet_window_seconds)
        client = CaptureAppendClient(base_url, service_key)
    except CaptureWriterError as exc:
        print(f"REFUSED (nothing sent): {exc}", file=sys.stderr)
        return 2

    # From here on, NOTHING may be reported as REFUSED: a send will be attempted, and
    # execute_selected_persist() owns the outcome state machine. The belt below exists for a
    # bug in this harness itself — even then the truthful claim is UNCERTAIN, never refusal.
    try:
        outcome = execute_selected_persist(client, reader, capability,
                                           replay_verify=args.replay_verify,
                                           count_before=before_count)
    except Exception as exc:                          # noqa: BLE001
        print(f"APPEND OUTCOME UNCERTAIN — the harness failed mid-operation "
              f"({type(exc).__name__}: {exc}). The row MAY exist. NO retry was attempted "
              f"and none will be: reconcile read-only first.", file=sys.stderr)
        return 2

    if args.as_json:
        print(json.dumps({"persist": outcome,
                          "append_rpc_calls": outcome["calls_attempted"]},
                         indent=2, sort_keys=True, default=str))
    else:
        print(_render_persist(outcome))
    return 0 if outcome["verdict"] in _CLEAN_VERDICTS else 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except CaptureWriterError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        sys.exit(2)
