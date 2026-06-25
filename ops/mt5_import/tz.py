"""
MT5 timezone helpers (Phase 0C).

THE INVARIANT (probe finding 0B): MT5 server time behaves as **Asia/Bangkok wall-clock** (UTC+7,
no DST). The terminal returns a Unix epoch whose value, when rendered at UTC offset 0, shows the
Bangkok wall-clock H:M:S. The writer must store **true UTC** (`wall - 7h`) and keep the raw values.

This module does the conversion the writer will use; the 0C-1 probe does NOT convert (it only reports
raw epochs). Pure stdlib, no MT5, no Supabase, no secrets.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

BKK_OFFSET_HOURS = 7  # Asia/Bangkok = UTC+7, fixed (no DST).
SERVER_TZ_LABEL = "Asia/Bangkok"


def raw_wallclock(epoch_s):
    """Render an MT5 epoch (seconds) as the *server wall-clock* it encodes (naive, no shift).
    For audit/printing only — this is the Bangkok local time the terminal shows."""
    if epoch_s in (None, ""):
        return None
    return datetime.fromtimestamp(int(epoch_s), tz=timezone.utc).replace(tzinfo=None)


def bkk_epoch_to_utc(epoch_s):
    """Convert an MT5 epoch (Bangkok wall-clock mislabeled as UTC) to the TRUE UTC instant
    (`wall - 7h`). Returns a tz-aware UTC datetime, or None."""
    if epoch_s in (None, ""):
        return None
    wall = datetime.fromtimestamp(int(epoch_s), tz=timezone.utc)  # wall-clock H:M:S, tagged UTC
    return wall - timedelta(hours=BKK_OFFSET_HOURS)               # subtract +7 to reach true UTC


def utc_iso(dt):
    """Format a tz-aware (or naive-UTC) datetime as RFC3339 'Z'. None -> None."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def selfcheck():
    """Fixed-input self-checks (no clock, no MT5). Returns list of failures (empty = OK)."""
    fails = []
    # An epoch whose UTC-rendered wall-clock is 2026-06-25 07:00:00 must convert to 00:00:00Z.
    wall = datetime(2026, 6, 25, 7, 0, 0, tzinfo=timezone.utc)
    epoch = int(wall.timestamp())
    got = bkk_epoch_to_utc(epoch)
    want = datetime(2026, 6, 25, 0, 0, 0, tzinfo=timezone.utc)
    if got != want:
        fails.append(f"bkk_epoch_to_utc: got {got!r}, want {want!r}")
    if utc_iso(got) != "2026-06-25T00:00:00Z":
        fails.append(f"utc_iso: got {utc_iso(got)!r}, want '2026-06-25T00:00:00Z'")
    if raw_wallclock(epoch) != datetime(2026, 6, 25, 7, 0, 0):
        fails.append(f"raw_wallclock: got {raw_wallclock(epoch)!r}, want naive 07:00:00")
    if bkk_epoch_to_utc(None) is not None or utc_iso(None) is not None:
        fails.append("None handling failed")
    return fails


if __name__ == "__main__":
    import sys
    f = selfcheck()
    print("tz selfcheck:", "PASS" if not f else "FAIL")
    for x in f:
        print("  -", x)
    sys.exit(1 if f else 0)
