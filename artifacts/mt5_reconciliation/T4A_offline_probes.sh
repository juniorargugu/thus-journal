#!/usr/bin/env bash
# ================================================================================================
# T4A OFFLINE ADVERSARIAL PROBES — disposable docker PostgreSQL ONLY. NEVER production.
#
# Reproducible implementation of the T4A-0 adversarial probe matrix:
#   P1  ATOMICITY   corrupted embedded parity expectation -> the WHOLE rpc migration rolls
#                   back: no functions installed, no ledger row (grants cannot exist without
#                   the functions). The canonical packet is never touched — the corruption is
#                   spliced into a throwaway temp copy.
#   P2  STALENESS   a tampered embedded region in a temp copy of the rpc packet is refused by
#                   gen_t4a_fixture_sql.py --check (byte comparison, not sha literals).
#   P3–P10 DRIFT    each adversarial privilege/definition drift makes the standalone security
#                   verifier FAIL, and the verifier returns to PASS after the revert:
#                   P3 EXECUTE granted to PUBLIC          P4 table SELECT granted to authenticated
#                   P5 column-level SELECT grant          P6 helper EXECUTE exposed to service_role
#                   P7 extra RLS policy                   P8 search_path drift on a helper
#                   P9 SECURITY DEFINER bit cleared       P10 table owner drift
#   P11 CONCURRENCY (same action)      two decision-RPC transactions target the SAME capture
#   P12 CONCURRENCY (different action) event. Writers get unique application_name identities;
#                   the probe resolves BOTH exact backend PIDs from pg_stat_activity, proves
#                   each writer's query is the decision RPC against the intended capture id,
#                   and asserts — with bounded polling, fail-closed on timeout — that
#                   pg_blocking_pids(writer_B) CONTAINS writer_A while A's transaction is
#                   open. Only then does A commit, and the post-serialization outcome is
#                   asserted separately: idempotent same-action replay (P11) or
#                   ERR_DECISION_CONFLICT (P12), one decision row, first-writer provenance
#                   untouched. No global lock counts are used as evidence; wait_event_type is
#                   logged diagnostically only (row-lock waits may surface as transactionid
#                   locks — the internal lock type is deliberately NOT asserted).
#                   DELIBERATELY NOT CLAIMED: that the defensive ON CONFLICT branch executed —
#                   supported writers serialize BEFORE it, and its result shape is identical
#                   by design, so runtime coverage of that branch is not observable here. Its
#                   continued presence/boundedness is pinned statically by
#                   test_t3_kind_fixture.py.
#
# Requires: docker. Run from anywhere: bash artifacts/mt5_reconciliation/T4A_offline_probes.sh
# Creates its own container (t4a_probe_pg), leaves it running for inspection.
# Cleanup afterwards: docker rm -f t4a_probe_pg
# ================================================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"
ART="artifacts/mt5_reconciliation"
GEN="ops/mt5_import/gen_t4a_fixture_sql.py"
C=t4a_probe_pg
TMP="$(mktemp -d)"
PASS_N=0; FAIL_N=0

ok()  { PASS_N=$((PASS_N+1)); echo "PROBE PASS: $1"; }
bad() { FAIL_N=$((FAIL_N+1)); echo "PROBE FAIL: $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got [$1] want [$2])"; fi; }

psql_file() { docker exec -i "$C" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q; }
psql_val()  { docker exec "$C" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qAt -c "$2"; }

verifier_expect() { # $1=db $2=PASS|FAIL $3=label
  out=$(psql_file "$1" < "$ART/T4A_security_verification_packet.sql" 2>&1); rc=$?
  if [ "$2" = PASS ]; then
    if [ $rc -eq 0 ] && echo "$out" | grep -q "ALL SECTIONS PASS"; then ok "$3"; else
      bad "$3"; echo "$out" | tail -3; fi
  else
    if [ $rc -ne 0 ] && echo "$out" | grep -q "T4A SEC"; then
      ok "$3 — $(echo "$out" | grep -o 'T4A SEC[0-9]*:[^"]*' | head -1 | cut -c1-90)"
    else bad "$3 (verifier did not fail)"; fi
  fi
}

echo "== container =="
docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e POSTGRES_PASSWORD=t4a postgres:17 >/dev/null || { echo "docker run failed"; exit 1; }
sleep 6
docker exec "$C" psql -U postgres -q \
  -c "create role anon nologin; create role authenticated nologin; create role service_role nologin;" \
  -c "create schema extensions; create extension pgcrypto with schema extensions;" || exit 1

echo "== baseline apply (db postgres) =="
for f in T4A_offline_bootstrap.sql T2_capture_events_schema_packet.sql \
         T2_capture_events_rpc_packet.sql T4A_decisions_schema_packet.sql \
         T4A_decisions_rpc_packet.sql; do
  psql_file postgres < "$ART/$f" >/dev/null 2>"$TMP/apply.err" || { echo "baseline apply failed: $f"; cat "$TMP/apply.err"; exit 1; }
done
verifier_expect postgres PASS "baseline: security verifier PASSES on a clean apply"

echo "== P1 atomicity: corrupted parity -> whole rpc migration rolls back =="
psql_val postgres "create database probe_atomic" >/dev/null
docker exec "$C" psql -U postgres -d probe_atomic -q \
  -c "create schema extensions; create extension pgcrypto with schema extensions;"
for f in T4A_offline_bootstrap.sql T2_capture_events_schema_packet.sql \
         T2_capture_events_rpc_packet.sql T4A_decisions_schema_packet.sql; do
  psql_file probe_atomic < "$ART/$f" >/dev/null 2>&1 || { echo "P1 pre-apply failed: $f"; exit 1; }
done
python -X utf8 - "$ART/T4A_decisions_rpc_packet.sql" "$TMP/rpc_corrupt.sql" <<'PY'
import sys, pathlib
sys.path.insert(0, "ops/mt5_import")
import gen_t4a_fixture_sql as gen
logical, sha = gen.load_fixture()
case = next(c for c in logical["cases"] if c["valid"])
case["kind"] = "CHANGE" if case["kind"] != "CHANGE" else "ENTRY"   # wrong EXPECTATION
frag = gen.render_fragment(logical, sha)
packet = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
pathlib.Path(sys.argv[2]).write_text(gen.splice_embedded(packet, frag),
                                     encoding="utf-8", newline="\n")
print(f"corrupted parity expectation for fixture case: {case['name']}")
PY
out=$(psql_file probe_atomic < "$TMP/rpc_corrupt.sql" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "T4A FIXTURE"; then
  ok "P1a corrupted-parity apply FAILS inside the packet transaction"
else bad "P1a corrupted-parity apply did not fail"; echo "$out" | tail -3; fi
state=$(psql_val probe_atomic "select
  (to_regprocedure('public.mt5_record_capture_decision_v1(uuid,uuid,text,text,bigint,bigint)') is null)
  and (to_regprocedure('public.mt5_next_pending_capture_v1(uuid)') is null)
  and (to_regprocedure('public.mt5_t3_kind_v1(text[])') is null)
  and (to_regprocedure('public.mt5_t3_event_types_v1(jsonb)') is null)
  and (to_regprocedure('public.mt5_t3_allowed_actions_v1(text)') is null)
  and not exists (select 1 from public.mt5_schema_migrations where version = 'mt5_t4a_decisions_rpc_v1')
  and exists (select 1 from public.mt5_schema_migrations where version = 'mt5_t4a_decisions_schema_v1')")
assert_eq "$state" "t" "P1b after rollback: NO rpc functions live (so no grants), NO rpc ledger row, schema ledger row intact"

echo "== P2 stale embedded fragment -> --check refuses =="
sed 's/, 22, 10;/, 23, 10;/' "$ART/T4A_decisions_rpc_packet.sql" > "$TMP/rpc_stale.sql"
if python -X utf8 "$GEN" --check --rpc-packet "$TMP/rpc_stale.sql" >"$TMP/p2.out" 2>&1; then
  bad "P2 --check accepted a tampered embedded region"
else
  grep -q "STALE: embedded parity region" "$TMP/p2.out" \
    && ok "P2 --check refuses a tampered embedded region (byte comparison)" \
    || { bad "P2 --check failed for the wrong reason"; cat "$TMP/p2.out"; }
fi

echo "== P3-P10 security drift probes (db postgres) =="
run_drift() { # $1=label $2=drift-sql $3=revert-sql
  psql_val postgres "$2" >/dev/null || { bad "$1 (drift sql failed)"; return; }
  verifier_expect postgres FAIL "$1"
  psql_val postgres "$3" >/dev/null || { bad "$1 (REVERT sql failed)"; return; }
}
run_drift "P3 EXECUTE to PUBLIC on the decision RPC" \
  "grant execute on function public.mt5_record_capture_decision_v1(uuid,uuid,text,text,bigint,bigint) to public" \
  "revoke execute on function public.mt5_record_capture_decision_v1(uuid,uuid,text,text,bigint,bigint) from public"
run_drift "P4 table SELECT to authenticated" \
  "grant select on table public.mt5_capture_decisions to authenticated" \
  "revoke select on table public.mt5_capture_decisions from authenticated"
run_drift "P5 column-level SELECT(action) to authenticated" \
  "grant select(action) on public.mt5_capture_decisions to authenticated" \
  "revoke select(action) on public.mt5_capture_decisions from authenticated"
run_drift "P6 helper EXECUTE exposed to service_role" \
  "grant execute on function public.mt5_t3_kind_v1(text[]) to service_role" \
  "revoke execute on function public.mt5_t3_kind_v1(text[]) from service_role"
run_drift "P7 extra RLS policy" \
  "create policy t4a_probe_extra on public.mt5_capture_decisions for select to authenticated using (true)" \
  "drop policy t4a_probe_extra on public.mt5_capture_decisions"
run_drift "P8 search_path drift on a SECURITY DEFINER helper" \
  "alter function public.mt5_t3_kind_v1(text[]) set search_path = public" \
  "alter function public.mt5_t3_kind_v1(text[]) set search_path = ''"
run_drift "P9 SECURITY DEFINER bit cleared on the pending RPC" \
  "alter function public.mt5_next_pending_capture_v1(uuid) security invoker" \
  "alter function public.mt5_next_pending_capture_v1(uuid) security definer"
run_drift "P10 table owner drift" \
  "alter table public.mt5_capture_decisions owner to service_role" \
  "alter table public.mt5_capture_decisions owner to postgres;
   revoke all on table public.mt5_capture_decisions from public, anon, authenticated, service_role;
   grant select on table public.mt5_capture_decisions to service_role"
verifier_expect postgres PASS "P3-P10 done: verifier PASSES again after every revert"

echo "== P11/P12 supported concurrency (two decision-RPC transactions, same capture) =="
psql_file postgres >/dev/null <<'SEEDSQL'
-- probe seed: same column shapes as the verification packet's pg_temp seed helpers
insert into public.mt5_sync_runs(
  id, user_id, source_account, captured_at, snapshot_status, reconcile_status,
  snapshot_health, run_seq, previous_positions_count, positions_count,
  position_ids_hash, manifest_hash, policy_version, policy_thresholds,
  connector_version, lease_token, lease_expires_at, heartbeat_at, snapshot_completed_at,
  reconciled_at)
values ('aaaaaaaa-0000-4000-8000-00000000009a', '99999999-9999-4999-8999-999999999999',
  '9009', timestamptz '2026-08-20 10:00:00+00', 'complete', 'complete', 'healthy', 1, 0, 1,
  repeat('a', 64), repeat('b', 64), 'seed-policy/1',
  jsonb_build_object('k', 3, 'susp_min_base', 5, 'susp_drop_ratio', 0.5,
                     'freshness_seconds', 900),
  'seed-connector/1', gen_random_uuid(),
  timestamptz '2026-08-20 11:00:00+00', timestamptz '2026-08-20 10:00:30+00',
  timestamptz '2026-08-20 10:00:45+00', timestamptz '2026-08-20 10:01:00+00');
insert into public.mt5_capture_events(
  id, created_at, event_key, user_id, source_account, position_id, basis_run_id,
  first_detection_at, last_detection_at, quiet_deadline, quiet_window_seconds,
  detector_version, aggregator_version, payload, payload_fingerprint)
select v.id, timestamptz '2026-08-25 12:00:00+00',
  encode(sha256(('key' || v.id::text)::bytea), 'hex'),
  '99999999-9999-4999-8999-999999999999', '9009', 555001,
  'aaaaaaaa-0000-4000-8000-00000000009a',
  timestamptz '2026-08-24 15:00:00+00', timestamptz '2026-08-24 15:00:00+00',
  timestamptz '2026-08-24 15:15:00+00', 900, 'seed-detector/1', 'seed-aggregator/1',
  jsonb_build_object('event_types', jsonb_build_array('NEW_POSITION'),
                     'detections', jsonb_build_array(jsonb_build_object('seed_ordinal', 1))),
  encode(sha256(('fp' || v.id::text)::bytea), 'hex')
from (values ('cccccc09-0000-4000-8000-0000000000c1'::uuid),
             ('cccccc09-0000-4000-8000-0000000000c2'::uuid)) v(id);
SEEDSQL

conc_run() { # $1=probe_tag (p11|p12) $2=capture_uuid $3=action_A $4=action_B
  # Prints: EVIDENCE:<tag> writer_a_pid=... writer_b_pid=... blocking_pids_contains_a=t ...
  # then A:<six-field tuple> and B:<six-field tuple>. Exit nonzero = evidence not obtained.
  docker exec -i "$C" bash -s "$1" "$2" "$3" "$4" <<'INNER'
TAG="$1"; CAP="$2"; ACT_A="$3"; ACT_B="$4"
U='99999999-9999-4999-8999-999999999999'
RUNID="$$_$(date +%s)"                 # unique per run: no stale-session ambiguity
APP_A="t4a_${TAG}_writer_a_${RUNID}"
APP_B="t4a_${TAG}_writer_b_${RUNID}"
FIFO=/tmp/t4a_a_in.$$
OUT_A=/tmp/t4a_a_out.$$; OUT_B=/tmp/t4a_b_out.$$

cleanup() {
  exec 3>&- 2>/dev/null || true
  # terminate ONLY the backends this probe created, by their exact unique names
  psql -U postgres -d postgres -qAt -c "
    select pg_terminate_backend(pid) from pg_stat_activity
     where application_name in ('$APP_A', '$APP_B')
       and pid <> pg_backend_pid();" >/dev/null 2>&1
  wait 2>/dev/null
  rm -f "$FIFO" "$OUT_A" "$OUT_B"
}
trap cleanup EXIT

mkfifo "$FIFO"
PGAPPNAME="$APP_A" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1 \
  < "$FIFO" > "$OUT_A" 2>&1 &
AJOB=$!
exec 3>"$FIFO"
echo "begin;" >&3
echo "select * from public.mt5_record_capture_decision_v1('$U'::uuid, '$CAP'::uuid, '$ACT_A', 'harness');" >&3

# --- writer A readiness: resolve A's exact backend PID AND prove it executed the target RPC
#     against the intended capture id and now holds the transaction open ------------------------
APID=""
for i in $(seq 1 50); do             # <= 10s
  APID=$(psql -U postgres -d postgres -qAt -c "
    select pid from pg_stat_activity
     where application_name = '$APP_A'
       and state = 'idle in transaction'
       and position('mt5_record_capture_decision_v1' in coalesce(query, '')) > 0
       and position('$CAP' in coalesce(query, '')) > 0")
  [ -n "$APID" ] && break
  sleep 0.2
done
if [ -z "$APID" ]; then
  echo "EVIDENCE:FAIL writer A never reached idle-in-transaction holding the target-capture RPC"
  exit 1
fi

# --- writer B: same capture event, then bounded poll until B's exact backend is observed
#     ACTIVE on the target RPC for the SAME capture AND blocked by A (pg_blocking_pids) -------
PGAPPNAME="$APP_B" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1 \
  -c "select * from public.mt5_record_capture_decision_v1('$U'::uuid, '$CAP'::uuid, '$ACT_B', 'harness');" \
  > "$OUT_B" 2>&1 &
BJOB=$!

BLOCKED=no
for i in $(seq 1 100); do            # <= 20s, fail-closed on timeout
  # every requirement is a WHERE predicate: a non-empty row IS the proof that writer B's
  # exact backend is ACTIVE on the decision RPC for THIS capture id AND that
  # pg_blocking_pids(B) contains writer A's pid, all observed in one snapshot
  row=$(psql -U postgres -d postgres -qAt -c "
    select a.pid || '|' || coalesce(a.wait_event_type, '-')
      from pg_stat_activity a
     where a.application_name = '$APP_B'
       and a.state = 'active'
       and position('mt5_record_capture_decision_v1' in coalesce(a.query, '')) > 0
       and position('$CAP' in coalesce(a.query, '')) > 0
       and pg_blocking_pids(a.pid) @> array[${APID}]::int[]")
  if [ -n "$row" ]; then
    BPID=${row%%|*}; b_wet=${row#*|}
    BLOCKED=yes
    echo "EVIDENCE:${TAG} writer_a_pid=$APID writer_b_pid=$BPID blocking_pids_contains_a=t b_active_on_target_rpc=t b_targets_same_capture=t b_wait_event_type=$b_wet capture=$CAP"
    break
  fi
  # if B's client already finished without the blocking relationship being observed, that is
  # NOT serialization evidence — fail closed (never reinterpret "B finished fast" as PASS)
  kill -0 "$BJOB" 2>/dev/null || break
  sleep 0.2
done
if [ "$BLOCKED" != yes ]; then
  echo "EVIDENCE:FAIL blocking of $APP_B by $APP_A (pid ${APID}) not observed within timeout"
  exit 1
fi

# --- serialization observed; only now release writer A and let B complete -------------------
echo "commit;" >&3
exec 3>&-
wait "$AJOB" "$BJOB" 2>/dev/null
echo "A:$(cat "$OUT_A")"
echo "B:$(cat "$OUT_B")"
INNER
}

CAP11='cccccc09-0000-4000-8000-0000000000c1'
out=$(conc_run p11 "$CAP11" no_record no_record); rc=$?
ev=$(printf '%s\n' "$out" | sed -n 's/^EVIDENCE:p11 //p' | head -1)
[ -n "$ev" ] && echo "  P11 evidence: $ev"
if [ $rc -ne 0 ]; then
  bad "P11 serialization evidence not obtained"; printf '%s\n' "$out" | tail -3
else
  case "$ev" in
    *"blocking_pids_contains_a=t"*"b_targets_same_capture=t"*"capture=$CAP11"*)
      ok "P11a writer B observed BLOCKED BY writer A via pg_blocking_pids while both targeted capture $CAP11" ;;
    *) bad "P11a blocking evidence line malformed ($ev)" ;;
  esac
  a=$(printf '%s\n' "$out" | sed -n 's/^A://p'); b=$(printf '%s\n' "$out" | sed -n 's/^B://p')
  aid=$(printf '%s' "$a" | cut -d'|' -f3)
  assert_eq "$a" "t|1|$aid||ENTRY|" "P11b writer A performed the fresh insert (o_ok=t, o_inserted=1, derived kind ENTRY)"
  assert_eq "$b" "t|0|$aid|no_record||" "P11c after A committed, writer B resolved to the idempotent same-action replay of A's decision id"
  n=$(psql_val postgres "select count(*) from public.mt5_capture_decisions where capture_event_id = '$CAP11'")
  assert_eq "$n" "1" "P11d exactly one decision row exists (no duplicate)"
  prov=$(psql_val postgres "select source || '|' || coalesce(telegram_chat_id::text,'') || '|' || coalesce(telegram_message_id::text,'') from public.mt5_capture_decisions where capture_event_id = '$CAP11'")
  assert_eq "$prov" "harness||" "P11e first-writer provenance untouched"
fi

CAP12='cccccc09-0000-4000-8000-0000000000c2'
out=$(conc_run p12 "$CAP12" no_record already_logged); rc=$?
ev=$(printf '%s\n' "$out" | sed -n 's/^EVIDENCE:p12 //p' | head -1)
[ -n "$ev" ] && echo "  P12 evidence: $ev"
if [ $rc -ne 0 ]; then
  bad "P12 serialization evidence not obtained"; printf '%s\n' "$out" | tail -3
else
  case "$ev" in
    *"blocking_pids_contains_a=t"*"b_targets_same_capture=t"*"capture=$CAP12"*)
      ok "P12a writer B observed BLOCKED BY writer A via pg_blocking_pids while both targeted capture $CAP12" ;;
    *) bad "P12a blocking evidence line malformed ($ev)" ;;
  esac
  a=$(printf '%s\n' "$out" | sed -n 's/^A://p'); b=$(printf '%s\n' "$out" | sed -n 's/^B://p')
  aid=$(printf '%s' "$a" | cut -d'|' -f3)
  assert_eq "$a" "t|1|$aid||ENTRY|" "P12b writer A performed the fresh insert (o_ok=t, o_inserted=1, derived kind ENTRY)"
  assert_eq "$b" "f|0|$aid|no_record||ERR_DECISION_CONFLICT" "P12c after A committed, writer B resolved to ERR_DECISION_CONFLICT naming A's decision id/action"
  n=$(psql_val postgres "select count(*) from public.mt5_capture_decisions where capture_event_id = '$CAP12'")
  assert_eq "$n" "1" "P12d exactly one decision row exists (conflict wrote nothing)"
  prov=$(psql_val postgres "select source || '|' || coalesce(telegram_chat_id::text,'') || '|' || coalesce(telegram_message_id::text,'') || '|' || action from public.mt5_capture_decisions where capture_event_id = '$CAP12'")
  assert_eq "$prov" "harness|||no_record" "P12e writer A's terminal action and provenance remain authoritative (no rewrite)"
fi

rm -rf "$TMP"
echo "================================================================"
echo "T4A OFFLINE PROBES: $PASS_N PASS, $FAIL_N FAIL"
echo "container $C left running for inspection (docker rm -f $C to clean up)"
[ "$FAIL_N" -eq 0 ]
