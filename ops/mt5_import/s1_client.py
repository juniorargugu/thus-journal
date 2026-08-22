"""
MT5 S1 — narrow, RPC-ALLOWLISTED Supabase/PostgREST client (connector surface only).

HARD BOUNDARIES (structural, mirroring ops/mt5_import/staging_db.py)
  - The ONLY endpoints this module may reach are the six RPCs in ALLOWED_RPCS. There is no
    generic public `rpc(name, ...)`; `_post_rpc` is private and asserts the allowlist.
  - No table URL (`/rest/v1/<table>`), no arbitrary endpoint, no GET, no DELETE, no PATCH.
  - The browser read RPC `mt5_get_current_snapshot_v1` is deliberately ABSENT: it derives identity
    from `auth.uid()` and is granted to `authenticated`, not `service_role` -- a service-role call
    could only ever return ERR_UNAUTHENTICATED, so exposing it here would be misleading.
  - `mt5_heartbeat_run_v1` is absent: a one-shot cycle finishes far inside the lease.
  - `mt5_mark_reconcile_failed_v1` is absent BY DESIGN: per the reviewed failure contract it is a
    deliberate operator recovery action, never an automatic first-smoke error path. Leaving it out
    of the allowlist makes "the orchestrator cannot auto-fail a reconcile" a structural fact.
  - The service_role key is held in memory only, NEVER logged/printed. Errors carry the RPC name,
    HTTP status and a trimmed server detail -- never the URL, never the Authorization header.

Signatures are taken VERBATIM from the installed revision-5 packet
(artifacts/mt5_reconciliation/S1_rpc_packet.sql, postflight allowlist at lines 905-913):
    mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamp with time zone,text,integer,text,text)
    mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)      <- p_rows is ONE jsonb (a JSON array)
    mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[])
    mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid)
    mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text)
    mt5_expire_stale_run_v1(uuid,uuid,text)

Pure stdlib (urllib) -- zero third-party Supabase client, matching staging_db.py / ops/p2_5e.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

# --- structural allowlist ---------------------------------------------------------------------
RPC_CREATE_RUN = "mt5_create_run_v1"
RPC_APPEND_ROWS = "mt5_append_run_positions_v1"
RPC_COMPLETE = "mt5_complete_snapshot_v1"
RPC_RECONCILE = "mt5_reconcile_snapshot_v1"
RPC_MARK_SNAPSHOT_FAILED = "mt5_mark_snapshot_failed_v1"
RPC_EXPIRE_STALE_RUN = "mt5_expire_stale_run_v1"

ALLOWED_RPCS = frozenset({
    RPC_CREATE_RUN, RPC_APPEND_ROWS, RPC_COMPLETE, RPC_RECONCILE,
    RPC_MARK_SNAPSHOT_FAILED, RPC_EXPIRE_STALE_RUN,
})

# Reason codes mt5_mark_snapshot_failed_v1 accepts (packet: p_reason_code not in (...) -> ERR_BAD_INPUT).
SNAPSHOT_FAILED_REASONS = frozenset({
    "CAPTURE_FAILED", "VALIDATION_FAILED", "APPEND_FAILED", "SEAL_FAILED",
    "UNSUPPORTED_MARGIN_MODE", "OPERATOR_CANCELLED",
})

DEFAULT_TIMEOUT = 30
MAX_RETRIES = 2                 # bounded: at most 2 retries => at most 3 attempts per stage
_RETRYABLE_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504})


class S1ClientError(Exception):
    """Non-retryable transport/protocol failure (4xx, malformed response, allowlist violation)."""


class S1TransportError(S1ClientError):
    """Retryable network-level failure. Retrying is safe ONLY with identical parameters."""


class S1Client:
    """One instance per invocation. Tracks logical stage calls so a caller (and the tests) can
    prove a single process issued at most one create-run stage."""

    def __init__(self, base_url: str, service_key: str, *, max_retries: int = MAX_RETRIES,
                 sleeper=time.sleep, timeout: int = DEFAULT_TIMEOUT, log=None):
        if not base_url or not service_key:
            raise S1ClientError("S1Client requires base_url + service_key")
        self.base = base_url.rstrip("/")
        self._key = service_key                 # in-memory only; never logged
        self.max_retries = max(0, int(max_retries))
        self._sleep = sleeper
        self.timeout = timeout
        self._log = log or (lambda msg: None)
        self.stage_calls = {}                   # rpc name -> logical stage invocations
        self.http_attempts = 0                  # total HTTP POSTs incl. retries

    # -- low-level (sanitized; never leaks the key) --------------------------------------------
    def _headers(self):
        return {
            "apikey": self._key,
            "Authorization": f"Bearer {self._key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def _post_rpc(self, name: str, params: dict):
        """ONE HTTP attempt against ONE allow-listed RPC. Raises S1TransportError (retryable) or
        S1ClientError (terminal). Returns the decoded JSON body."""
        if name not in ALLOWED_RPCS:
            raise S1ClientError(f"RPC not allowlisted: {name!r} (only {sorted(ALLOWED_RPCS)})")
        url = f"{self.base}/rest/v1/rpc/{urllib.parse.quote(name, safe='')}"
        data = json.dumps(params, allow_nan=False).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST", headers=self._headers())
        self.http_attempts += 1
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                txt = resp.read().decode("utf-8")
                return json.loads(txt) if txt.strip() else None
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode("utf-8")[:300]
            except Exception:
                pass
            # NB: url/headers (which carry the key) are NOT included in the message.
            msg = f"HTTP {e.code} on rpc {name}: {detail}"
            if e.code in _RETRYABLE_STATUS:
                raise S1TransportError(msg) from None
            raise S1ClientError(msg) from None
        except urllib.error.URLError as e:
            raise S1TransportError(f"network error on rpc {name}: {e.reason!r}") from None
        except TimeoutError as e:
            raise S1TransportError(f"timeout on rpc {name}: {e!r}") from None
        except json.JSONDecodeError as e:
            raise S1ClientError(f"malformed JSON response from rpc {name}: {e.msg}") from None

    def _call(self, name: str, params: dict, *, run_id=None):
        """One LOGICAL stage: bounded retry with IDENTICAL parameters, then unwrap the single
        result row. Retries are transport-only -- a contract answer (o_ok=false) is never retried,
        and parameters are never regenerated between attempts."""
        self.stage_calls[name] = self.stage_calls.get(name, 0) + 1
        last = None
        for attempt in range(self.max_retries + 1):
            try:
                body = self._post_rpc(name, params)
                break
            except S1TransportError as e:
                last = e
                if attempt >= self.max_retries:
                    self._log(f"  stage={name} run_id={run_id} transport FAILED after "
                              f"{attempt + 1} attempt(s): {e}")
                    raise
                self._log(f"  stage={name} run_id={run_id} transport error "
                          f"(attempt {attempt + 1}/{self.max_retries + 1}), retrying identically: {e}")
                self._sleep(0.5 * (attempt + 1))
        else:                                                   # pragma: no cover - defensive
            raise last or S1TransportError(f"rpc {name} exhausted retries")

        # Every allow-listed RPC is `RETURNS TABLE(...)` -> PostgREST yields a 1-element array.
        if not isinstance(body, list) or len(body) != 1 or not isinstance(body[0], dict):
            raise S1ClientError(f"rpc {name} returned an unexpected shape "
                                f"(expected exactly 1 result row, got {type(body).__name__} "
                                f"len={len(body) if isinstance(body, list) else 'n/a'})")
        return body[0]

    # -- the entire connector surface ----------------------------------------------------------
    def create_run(self, *, run_id, user_id, source_account, lease_token, lease_seconds,
                   captured_at, connector_version, terminal_build, terminal_server, policy_version):
        """-> {o_ok, o_run_id, o_lease_expires_at, o_error_code}"""
        return self._call(RPC_CREATE_RUN, {
            "p_run_id": run_id,
            "p_user": user_id,
            "p_account": source_account,
            "p_lease_token": lease_token,
            "p_lease_seconds": lease_seconds,
            "p_captured_at": captured_at,
            "p_connector_version": connector_version,
            "p_terminal_build": terminal_build,
            "p_terminal_server": terminal_server,
            "p_policy_version": policy_version,
        }, run_id=run_id)

    def append_run_positions(self, *, run_id, user_id, source_account, lease_token, rows):
        """-> {o_ok, o_inserted, o_error_code}. `rows` is a JSON array sent as ONE jsonb param."""
        return self._call(RPC_APPEND_ROWS, {
            "p_run_id": run_id,
            "p_user": user_id,
            "p_account": source_account,
            "p_lease_token": lease_token,
            "p_rows": rows,
        }, run_id=run_id)

    def complete_snapshot(self, *, run_id, user_id, source_account, lease_token,
                          expected_count, expected_ids):
        """-> {o_ok, o_run_seq, o_snapshot_health, o_error_code}"""
        return self._call(RPC_COMPLETE, {
            "p_run_id": run_id,
            "p_user": user_id,
            "p_account": source_account,
            "p_lease_token": lease_token,
            "p_expected_count": expected_count,
            "p_expected_ids": expected_ids,
        }, run_id=run_id)

    def reconcile_snapshot(self, *, run_id, user_id, source_account, lease_token):
        """-> {o_ok, o_still_open, o_missing_once, o_not_open_confirmed, o_conflicts, o_error_code}"""
        return self._call(RPC_RECONCILE, {
            "p_run_id": run_id,
            "p_user": user_id,
            "p_account": source_account,
            "p_lease_token": lease_token,
        }, run_id=run_id)

    def mark_snapshot_failed(self, *, run_id, user_id, source_account, lease_token, reason_code):
        """-> {o_ok, o_error_code}. Cleanup for a run THIS invocation created (never another
        invocation's active cycle)."""
        if reason_code not in SNAPSHOT_FAILED_REASONS:
            raise S1ClientError(f"reason_code {reason_code!r} is not server-allowlisted "
                                f"(expected one of {sorted(SNAPSHOT_FAILED_REASONS)})")
        return self._call(RPC_MARK_SNAPSHOT_FAILED, {
            "p_run_id": run_id,
            "p_user": user_id,
            "p_account": source_account,
            "p_lease_token": lease_token,
            "p_reason_code": reason_code,
        }, run_id=run_id)

    def expire_stale_run(self, *, run_id, user_id, source_account):
        """-> {o_ok, o_error_code}. Deliberate operator recovery; takes NO lease token by design
        (the lease is exactly what has expired)."""
        return self._call(RPC_EXPIRE_STALE_RUN, {
            "p_run_id": run_id,
            "p_user": user_id,
            "p_account": source_account,
        }, run_id=run_id)
