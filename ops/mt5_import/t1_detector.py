#!/usr/bin/env python3
"""
MT5 T1 v0.1 — trusted position-change detector. PURE.

Implements the frozen contract in
artifacts/mt5_reconciliation/T1_T2_contract_freeze_addendum.md ("T1 source of truth" +
"Adjacency and gaps"). Detection only:

  - no Supabase / DB / RPC, no MT5, no staging, no Journal, no Telegram, no scheduler,
    no quiet window, no capture_event persistence;
  - no close-price or realised-P/L reconstruction — POSITION_DISAPPEARED means *observed
    membership disappearance*, never "closed";
  - no product-family logic.

Input model (plain data, injected by the caller — this module never fetches anything):

  runs         iterable of completed-run metadata dicts:
                 run_id, user_id, source_account, run_seq, snapshot_status, snapshot_health
               `snapshot_status` MUST be one of 'started' | 'complete' | 'failed' (the
               mt5_sync_runs domain) — an unknown, missing or malformed status raises
               T1InputError; it is NEVER silently skipped. 'started' and 'failed' are
               recognized non-authoritative attempts: ignored for completed-observation
               adjacency, no completed run_seq required, and they do not create a gap. An
               entirely missing attempt has no T1 semantics at all.
  memberships  dict run_id -> list of immutable mt5_sync_run_positions-style rows.
               Membership MUST be present (an empty list is a legal flat account) for every
               HEALTHY completed run; membership of suspicious runs is never consulted.
               Every consulted row is validated STRICTLY before any event is derived:
               `run_id` / `user_id` / `source_account` must exactly match the parent run
               (no cross-run, cross-user or cross-account projection), `position_id` must
               be a bigint-style integer (bool / str / None refused), `symbol_raw` a
               nonblank string, `side` exactly 'buy' or 'sell', and `volume` numeric,
               finite and > 0. Any violation fails the WHOLE detect() call — no partial
               events are ever emitted from malformed projection data. Nullable enrichment
               fields (price_open, price_current, profit, open_time_utc, source_time_msc,
               contract_size) are NOT required.

Adjacency (frozen executable rule): a normal delta is derived between two consecutive
completed observations for the same user/account when BOTH are healthy — *consecutive*
meaning no other completed run for that user/account has a run_seq between them. A completed
suspicious observation emits nothing and breaks continuity: the next healthy completed
observation becomes a fresh baseline and detection resumes from the one after it.

`mt5_import_staging.position_state` is deliberately not an input: it is a current
operational annotation, not replayable history.

Every event preserves at least: event_type, position_id, before_run_id, after_run_id.
`before_run_id` is the earlier run of the adjacent pair in ALL cases (for NEW_POSITION /
REAPPEARANCE it is the run where the position was absent).

Volume comparison is EXACT over a canonical decimal representation (Decimal(str(v))):
volumes are stored snapshot facts, not estimated calculations, so two stored values that
differ are a real difference regardless of magnitude — 1_000_000_000.0 -> 1_000_000_000.5
is a POSITION_INCREASE. No tolerance and no instrument-aware quantization in T1.
"""
from __future__ import annotations

import math
from decimal import Decimal

# ---------------------------------------------------------------------------------------------
# frozen vocabulary
# ---------------------------------------------------------------------------------------------
EVENT_NEW_POSITION = "NEW_POSITION"
EVENT_POSITION_INCREASE = "POSITION_INCREASE"
EVENT_POSITION_DECREASE = "POSITION_DECREASE"
EVENT_POSITION_DISAPPEARED = "POSITION_DISAPPEARED"
EVENT_REAPPEARANCE = "REAPPEARANCE"
EVENT_POSITION_IDENTITY_CONFLICT = "POSITION_IDENTITY_CONFLICT"

EVENT_TYPES = (
    EVENT_NEW_POSITION, EVENT_POSITION_INCREASE, EVENT_POSITION_DECREASE,
    EVENT_POSITION_DISAPPEARED, EVENT_REAPPEARANCE, EVENT_POSITION_IDENTITY_CONFLICT,
)

STATUS_COMPLETE = "complete"                  # mt5_sync_runs_snapshot_status_chk
STATUSES = ("started", STATUS_COMPLETE, "failed")
HEALTH_HEALTHY = "healthy"                    # mt5_sync_runs_health_chk
HEALTH_SUSPICIOUS = "suspicious"
_HEALTHS = (HEALTH_HEALTHY, HEALTH_SUSPICIOUS)
SIDES = ("buy", "sell")


class T1InputError(ValueError):
    """Malformed detector input. T1 fails closed on inputs that violate the S1 invariants it
    relies on (unique run_seq per account, unique position_id per run, membership present for
    every healthy completed run) rather than guessing its way past them."""


def _is_real(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def canonical_volume(v):
    """Canonical EXACT numeric form of a validated volume. Decimal(str(v)) is deterministic
    and preserves every stored digit, so comparison is exact at any magnitude — raw float
    `==` is never used, and no tolerance is applied: stored snapshot facts that differ are
    a real difference."""
    return Decimal(str(v))


# ---------------------------------------------------------------------------------------------
# input normalisation
# ---------------------------------------------------------------------------------------------
def _completed_runs(runs):
    """Validate and return ONLY completed runs, grouped by (user_id, source_account) and sorted
    by run_seq. Non-complete rows are ignored entirely (not observations, not gaps)."""
    groups = {}
    seen_run_ids = set()
    for r in runs:
        if not isinstance(r, dict):
            raise T1InputError(f"run metadata must be a dict, got {type(r).__name__}")
        status = r.get("snapshot_status")
        if status not in STATUSES:
            # FAIL CLOSED: an unknown or missing status is malformed input, never a skip.
            raise T1InputError(f"run {r.get('run_id')!r} has unknown snapshot_status "
                               f"{status!r} (domain: {STATUSES})")
        if status != STATUS_COMPLETE:
            continue          # started/failed: recognized non-authoritative attempts, ignored
        run_id = r.get("run_id")
        user_id = r.get("user_id")
        account = r.get("source_account")
        run_seq = r.get("run_seq")
        health = r.get("snapshot_health")
        if not (isinstance(run_id, str) and run_id.strip()):
            raise T1InputError("completed run without a run_id")
        if run_id in seen_run_ids:
            raise T1InputError(f"duplicate run_id {run_id!r}")
        seen_run_ids.add(run_id)
        if not (isinstance(user_id, str) and user_id.strip()):
            raise T1InputError(f"completed run {run_id!r} without a user_id")
        if not (isinstance(account, str) and account.strip()):
            raise T1InputError(f"completed run {run_id!r} without a source_account")
        if not (isinstance(run_seq, int) and not isinstance(run_seq, bool) and run_seq >= 1):
            raise T1InputError(f"completed run {run_id!r} without a valid run_seq (>= 1)")
        if health not in _HEALTHS:
            raise T1InputError(f"completed run {run_id!r} health {health!r} not in {_HEALTHS}")
        groups.setdefault((user_id, account), []).append(
            {"run_id": run_id, "user_id": user_id, "source_account": account,
             "run_seq": run_seq, "snapshot_health": health})
    for key, seq in groups.items():
        seq.sort(key=lambda r: r["run_seq"])
        for a, b in zip(seq, seq[1:]):
            if a["run_seq"] == b["run_seq"]:
                raise T1InputError(
                    f"duplicate completed run_seq {a['run_seq']} for user/account {key}")
    return groups


def _membership_map(run, memberships):
    """position_id -> STRICTLY validated row for one HEALTHY completed run. Presence of the
    membership entry is required (an empty list is legal flat-account evidence). Every row's
    scope must exactly match the parent run, every identity/fact field must be well-formed,
    and duplicate position_ids are refused — any violation raises for the whole call."""
    run_id = run["run_id"]
    if run_id not in memberships:
        raise T1InputError(
            f"membership missing for healthy completed run {run_id!r} "
            f"(a flat account is an EMPTY list, not an absent key)")
    rows = memberships[run_id]
    if not isinstance(rows, (list, tuple)):
        raise T1InputError(f"membership of run {run_id!r} must be a list")
    out = {}
    for row in rows:
        if not isinstance(row, dict):
            raise T1InputError(f"membership row of run {run_id!r} must be a dict")
        # SCOPE: a row may only ever be counted for the exact run/user/account it belongs to.
        for key in ("run_id", "user_id", "source_account"):
            if row.get(key) != run[key]:
                raise T1InputError(
                    f"membership scope violation in run {run_id!r}: row {key}="
                    f"{row.get(key)!r} does not match the parent run's {run[key]!r}")
        pid = row.get("position_id")
        if not isinstance(pid, int) or isinstance(pid, bool):
            raise T1InputError(f"run {run_id!r}: position_id {pid!r} is not a bigint-style "
                               f"integer (bool / str / None refused)")
        if pid in out:
            raise T1InputError(f"duplicate position_id {pid!r} in run {run_id!r}")
        sym = row.get("symbol_raw")
        if not (isinstance(sym, str) and sym.strip()):
            raise T1InputError(f"run {run_id!r} position {pid}: symbol_raw {sym!r} is not a "
                               f"nonblank string")
        side = row.get("side")
        if side not in SIDES:
            raise T1InputError(f"run {run_id!r} position {pid}: side {side!r} not in {SIDES}")
        vol = row.get("volume")
        if not (_is_real(vol) and vol > 0):
            raise T1InputError(f"run {run_id!r} position {pid}: volume {vol!r} is not a "
                               f"finite number > 0")
        out[pid] = row
    return out


# ---------------------------------------------------------------------------------------------
# detection
# ---------------------------------------------------------------------------------------------
def _base_event(event_type, pid, before, after):
    return {
        "event_type": event_type,
        "position_id": pid,
        "before_run_id": before["run_id"],
        "after_run_id": after["run_id"],
        "before_run_seq": before["run_seq"],
        "after_run_seq": after["run_seq"],
        "user_id": after["user_id"],
        "source_account": after["source_account"],
    }


def _diff_pair(before, after, before_map, after_map, seen_healthy_ids):
    """Events between two ADJACENT HEALTHY completed observations. `seen_healthy_ids` is the
    trusted healthy membership history strictly before `after` (suspicious runs never
    contribute to it)."""
    events = []
    for pid in after_map:
        if pid in before_map:
            b, a = before_map[pid], after_map[pid]
            # identity first; a conflicted identity fails closed and suppresses size deltas.
            if b.get("symbol_raw") != a.get("symbol_raw") or b.get("side") != a.get("side"):
                ev = _base_event(EVENT_POSITION_IDENTITY_CONFLICT, pid, before, after)
                ev.update(before_symbol_raw=b.get("symbol_raw"),
                          after_symbol_raw=a.get("symbol_raw"),
                          before_side=b.get("side"), after_side=a.get("side"),
                          before_volume=b.get("volume"), after_volume=a.get("volume"))
                events.append(ev)
                continue
            bv, av = b["volume"], a["volume"]           # strictly validated upstream
            cb, ca = canonical_volume(bv), canonical_volume(av)
            if ca == cb:
                continue
            etype = EVENT_POSITION_INCREASE if ca > cb else EVENT_POSITION_DECREASE
            ev = _base_event(etype, pid, before, after)
            ev.update(symbol_raw=a.get("symbol_raw"), side=a.get("side"),
                      before_volume=bv, after_volume=av)
            events.append(ev)
        else:
            row = after_map[pid]
            etype = EVENT_REAPPEARANCE if pid in seen_healthy_ids else EVENT_NEW_POSITION
            ev = _base_event(etype, pid, before, after)
            ev.update(symbol_raw=row.get("symbol_raw"), side=row.get("side"),
                      after_volume=row.get("volume"))
            events.append(ev)
    for pid in before_map:
        if pid not in after_map:
            row = before_map[pid]
            # observed membership disappearance ONLY — not "closed", no close price, no P/L.
            ev = _base_event(EVENT_POSITION_DISAPPEARED, pid, before, after)
            ev.update(symbol_raw=row.get("symbol_raw"), side=row.get("side"),
                      before_volume=row.get("volume"))
            events.append(ev)
    return events


def detect(runs, memberships):
    """Pure T1 detection over completed-run metadata + membership facts.

    Returns a deterministically ordered list of event dicts, sorted by
    (user_id, source_account, after_run_seq, position_id) — independent of input order.
    Inputs are never mutated.
    """
    groups = _completed_runs(runs)
    # STRICT FIRST: validate the membership of EVERY healthy completed run before deriving a
    # single event, so malformed projection data fails the whole call with no partial output.
    maps = {}
    for seq in groups.values():
        for run in seq:
            if run["snapshot_health"] == HEALTH_HEALTHY:
                maps[run["run_id"]] = _membership_map(run, memberships)

    all_events = []
    for (_user, _acct), seq in groups.items():
        seen_healthy_ids = set()
        prev = prev_map = None
        for run in seq:
            if run["snapshot_health"] != HEALTH_HEALTHY:
                # completed suspicious: emits nothing, breaks continuity, contributes no
                # trusted history. The NEXT healthy run is a fresh baseline.
                prev, prev_map = None, None
                continue
            cur_map = maps[run["run_id"]]
            if prev is not None:
                all_events.extend(_diff_pair(prev, run, prev_map, cur_map, seen_healthy_ids))
            # else: fresh baseline (first healthy observation, or first after a gap) — zero events.
            seen_healthy_ids.update(cur_map)
            prev, prev_map = run, cur_map
    # position_id is a validated integer: NUMERIC order (2 before 10), never lexicographic.
    all_events.sort(key=lambda e: (e["user_id"], e["source_account"],
                                   e["after_run_seq"], e["position_id"]))
    return all_events
