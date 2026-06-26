"""
MT5 Phase 0C-3a — narrow, table-ALLOWLISTED Supabase/PostgREST client (staging opens only).

HARD BOUNDARIES (structural):
  - The ONLY table this module may touch is `mt5_import_staging` (ALLOWED_TABLES).
  - No generic `write(table, …)`. No RPC (`/rpc/…`) path. No DELETE. No upsert / on_conflict /
    merge-duplicates (Phase 0A uses PARTIAL unique indexes — see writer.py / the design doc).
  - It is constructed ONLY in armed-write mode by writer.py, AFTER the three-key gate + env checks.
    Dry-run never imports/instantiates this class and never reads the service_role key.
  - The service_role key is held in memory only, NEVER logged/printed (errors are sanitized).

Pure stdlib (urllib) — zero third-party Supabase client, matching ops/p2_5e.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

# --- structural allowlist -------------------------------------------------------------------
STAGING = "mt5_import_staging"
ALLOWED_TABLES = frozenset({STAGING})

# Exact Phase 0A `mt5_import_staging` columns (server-managed id/created_at/updated_at excluded
# from inserts via INSERT_SKIP). Used by writer.py to project rows before INSERT.
STAGING_COLUMNS = frozenset({
    "id", "user_id", "source_account", "kind", "symbol_raw", "normalized_symbol", "instrument_path",
    "instrument_class", "contract_size", "digits", "product_id_candidate", "side", "volume", "price",
    "open_time", "close_time", "mt5_time", "mt5_time_msc", "mt5_time_raw_epoch", "server_tz",
    "position_id", "deal_id", "order_id", "ticket", "external_id", "commission", "swap", "fee",
    "broker_profit", "position_state", "first_seen_open_at", "last_seen_open_at", "state",
    "import_group_key", "confirmed_group_id", "materialized_trade_id", "materialized_at",
    "dismissed_at", "error_message", "screenshot_url", "raw", "created_at", "updated_at",
})
INSERT_SKIP = frozenset({"id", "created_at", "updated_at"})  # DB-managed; never sent on insert


class StagingDBError(Exception):
    pass


class DuplicateInsert(StagingDBError):
    """409 unique violation — the open row already exists (idempotency index fired)."""


def _assert_table(table: str):
    if table not in ALLOWED_TABLES:
        raise StagingDBError(f"table not allowlisted: {table!r} (only {sorted(ALLOWED_TABLES)})")


def _parse_total(content_range: str) -> int:
    # PostgREST Content-Range like "0-0/42" or "*/0"; total is after the slash.
    if not content_range or "/" not in content_range:
        return 0
    tail = content_range.rsplit("/", 1)[-1].strip()
    return 0 if tail in ("*", "") else int(tail)


class StagingDB:
    def __init__(self, base_url: str, service_key: str):
        if not base_url or not service_key:
            raise StagingDBError("StagingDB requires base_url + service_key")
        self.base = base_url.rstrip("/")
        self._key = service_key  # in-memory only; never logged

    # -- low-level (sanitized errors; never leak the key) --------------------------------------
    def _headers(self, with_body=False, prefer=None, range_header=None):
        h = {"apikey": self._key, "Authorization": f"Bearer {self._key}", "Accept": "application/json"}
        if with_body:
            h["Content-Type"] = "application/json"
        if prefer:
            h["Prefer"] = prefer
        if range_header is not None:
            h["Range-Unit"] = "items"
            h["Range"] = range_header
        return h

    def _request(self, method, table, query="", body=None, prefer=None, range_header=None):
        _assert_table(table)
        url = f"{self.base}/rest/v1/{table}{query}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(
            url, data=data, method=method,
            headers=self._headers(with_body=data is not None, prefer=prefer, range_header=range_header),
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                txt = resp.read().decode("utf-8")
                payload = json.loads(txt) if txt.strip() else None
                return resp.status, dict(resp.headers), payload
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode("utf-8")[:300]
            except Exception:
                pass
            if e.code == 409:
                raise DuplicateInsert(f"HTTP 409 conflict on {method} {table}: {detail}") from None
            # NB: the URL/headers (which carry the key) are NOT included in the message.
            raise StagingDBError(f"HTTP {e.code} on {method} {table}: {detail}") from None
        except urllib.error.URLError as e:
            raise StagingDBError(f"network error on {method} {table}: {e.reason!r}") from None

    @staticmethod
    def _eq(value):
        return f"eq.{urllib.parse.quote(str(value), safe='')}"

    def _open_key_query(self, user_id, source_account, position_id, extra=""):
        return (f"?kind={self._eq('open')}&user_id={self._eq(user_id)}"
                f"&source_account={self._eq(source_account)}&position_id={self._eq(position_id)}{extra}")

    # -- narrow operations (the entire 0C-3a surface) ------------------------------------------
    def select_open_by_key(self, user_id, source_account, position_id):
        """Return the existing open row (dict) for the exact key, or None."""
        q = self._open_key_query(user_id, source_account, position_id, extra="&limit=1")
        _, _, rows = self._request("GET", STAGING, q)
        return rows[0] if rows else None

    def count_open_by_scope(self, user_id, source_account) -> int:
        q = (f"?kind={self._eq('open')}&user_id={self._eq(user_id)}"
             f"&source_account={self._eq(source_account)}&select=position_id")
        _, headers, _ = self._request("GET", STAGING, q, prefer="count=exact", range_header="0-0")
        return _parse_total(headers.get("Content-Range", ""))

    def count_open_by_key(self, user_id, source_account, position_id) -> int:
        q = self._open_key_query(user_id, source_account, position_id, extra="&select=position_id")
        _, headers, _ = self._request("GET", STAGING, q, prefer="count=exact", range_header="0-0")
        return _parse_total(headers.get("Content-Range", ""))

    def insert_open(self, sanitized_row: dict):
        """Plain INSERT (NO upsert/on_conflict). Raises DuplicateInsert on 409."""
        if sanitized_row.get("kind") != "open":
            raise StagingDBError("insert_open refuses a non-open row")
        _, _, rows = self._request("POST", STAGING, body=sanitized_row, prefer="return=representation")
        return rows[0] if rows else None

    def patch_open_allowlisted(self, user_id, source_account, position_id, patch: dict) -> int:
        """PATCH only the allow-listed fields, restricted to writer-owned states. Returns the number
        of rows actually patched (0 = state changed concurrently / not writer-owned)."""
        if not patch:
            return 0
        # filter: exact key + only states the reader may touch + not yet grouped
        q = self._open_key_query(
            user_id, source_account, position_id,
            extra=("&state=in.(needs_mapping,new,group_suggested)&confirmed_group_id=is.null"),
        )
        _, _, rows = self._request("PATCH", STAGING, q, body=patch, prefer="return=representation")
        return len(rows or [])
