"""
Shared helpers for the MT5 import tooling (Phase 0C). MT5-independent, no Supabase, no secrets.

NOTE: probe.py (0C-1) predates this module and keeps equivalent inline copies; it is intentionally
left UNTOUCHED in this slice (its behaviour is frozen / already reviewed). probe.py can be migrated
to import from here in a later cleanup. build_rows.py (0C-2) and any future writer use this module.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

# --- MT5 enum name maps (mirror of probe.py; kept in sync deliberately) -----------------------
MARGIN_MODE_NAMES = {0: "RETAIL_NETTING", 1: "EXCHANGE", 2: "RETAIL_HEDGING"}
POSITION_TYPE_NAMES = {0: "BUY", 1: "SELL"}
DEAL_TYPE_NAMES = {
    0: "BUY", 1: "SELL", 2: "BALANCE", 3: "CREDIT", 4: "CHARGE",
    5: "CORRECTION", 6: "BONUS", 7: "COMMISSION", 8: "COMMISSION_DAILY",
    9: "COMMISSION_MONTHLY", 10: "COMMISSION_AGENT_DAILY", 11: "COMMISSION_AGENT_MONTHLY",
    12: "INTEREST", 13: "BUY_CANCELED", 14: "SELL_CANCELED", 15: "DIVIDEND",
    16: "DIVIDEND_FRANKED", 17: "TAX",
}
DEAL_ENTRY_NAMES = {0: "IN", 1: "OUT", 2: "INOUT", 3: "OUT_BY"}

SAFE_OUT_PREFIX = "ops/mt5_import/out/"
_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def stop(msg: str, code: int = 2):
    """Fail safe: clear message, non-zero exit, no writes, no fabrication."""
    eprint("STOP:", msg)
    sys.exit(code)


def as_dict(obj):
    """MT5 namedtuple-likes expose _asdict(); fall back to attribute scrape. None -> None."""
    if obj is None:
        return None
    if hasattr(obj, "_asdict"):
        try:
            return dict(obj._asdict())
        except Exception:
            pass
    return {k: getattr(obj, k) for k in dir(obj) if not k.startswith("_") and not callable(getattr(obj, k))}


def rough_instrument_class(path, symbol=None) -> str:
    """HINT ONLY. Derived from symbol_info.path; never authoritative, never coerces mapping."""
    p = (path or "").lower()
    if "single stock future" in p or "\\ssf" in p or "/ssf" in p:
        return "ssf"
    if "future" in p:
        return "futures"
    if "stock" in p or "\\set" in p or "/set" in p or "equity" in p or "share" in p:
        return "stock"
    if "forex" in p or "\\fx" in p or "/fx" in p or "currency" in p:
        return "forex"
    if "crypto" in p:
        return "crypto"
    if "index" in p or "indices" in p:
        return "index"
    if "metal" in p or "commodit" in p:
        return "commodity"
    return "unknown"


def is_uuid(s) -> bool:
    return isinstance(s, str) and bool(_UUID_RE.match(s.strip()))


def mask_login(login, show: bool = False) -> str:
    if login is None:
        return "(unknown)"
    s = str(login)
    if show or len(s) <= 4:
        return s
    return s[:2] + "*" * (len(s) - 4) + s[-2:]


# --- safe --out path guard (same policy as probe.py) ------------------------------------------
def _norm_path(p: str) -> str:
    return os.path.normpath(p).replace("\\", "/")


def _git_check_ignore_rc(path: str):
    """git check-ignore exit code: 0 = ignored, 1 = not ignored, None = git unavailable / error."""
    try:
        r = subprocess.run(["git", "check-ignore", "--quiet", path], capture_output=True)
        return r.returncode
    except Exception:
        return None


def is_ignored_output_path(path: str):
    """(allowed, reason). --out allowed ONLY if git-ignored OR under ops/mt5_import/out/. If git is
    unavailable, fall back to a STRICT prefix-only allowlist (never write to a trackable path)."""
    norm = _norm_path(path)
    under_prefix = norm == SAFE_OUT_PREFIX.rstrip("/") or norm.startswith(SAFE_OUT_PREFIX)
    rc = _git_check_ignore_rc(path)
    if rc == 0:
        return True, "git-ignored"
    if under_prefix:
        return True, "under ops/mt5_import/out/"
    if rc is None:
        return False, "git unavailable and path is not under ops/mt5_import/out/"
    return False, "path is not git-ignored"
