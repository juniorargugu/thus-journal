#!/usr/bin/env bash
# ================================================================================================
# T4B OFFLINE ADVERSARIAL PROBES — disposable docker PostgreSQL ONLY. NEVER production.
#
#   B0      BASELINE     the full packet chain applies clean; the offline verification matrix and
#                        the read-only security verifier both PASS.
#   B1      ATOMICITY    a promotion that fails AFTER the LEDGER insert leaves NEITHER the ledger
#                        row nor the trade (one transaction, no split-brain). The insert order is
#                        ledger-then-trade, so the fault is induced on the trade insert.
#   D1–D17  DRIFT        each adversarial privilege/definition drift makes the security verifier
#                        FAIL, and it returns to PASS after the revert:
#                        D1  EXECUTE granted to PUBLIC on the promotion RPC
#                        D2  table SELECT granted to authenticated
#                        D3  column-level SELECT grant
#                        D4  helper EXECUTE exposed to service_role
#                        D5  extra RLS policy
#                        D6  search_path cleared on a helper
#                        D7  SECURITY DEFINER bit cleared
#                        D8  the position-uniqueness constraint dropped
#                        D9  SAME-NAMED unique constraint over the WRONG columns
#                        D10 SAME-NAMED foreign key with a DIFFERENT column mapping
#                        D11 SAME-NAMED index with a DIFFERENT predicate
#                        D12 SAME-NAMED trigger replaced by a NO-OP function
#                        D13 MALICIOUS search_path that still "contains search_path="
#                        D14 volatility changed (stable -> volatile)
#                        D15 an ARBITRARY role granted a table privilege
#                        D16 an ARBITRARY role granted EXECUTE on the promotion RPC
#                        D17 the incarnation guard trigger dropped from public.trades
#                        D18 a function BODY replaced with metadata preserved
#                        D19 service_role LOSES a required table grant
#                        D20 service_role LOSES EXECUTE on the promotion RPC
#                        D21 the marker made client-writable again
#                        D22 an arbitrary but well-formed migration checksum
#                        D23 an arbitrary but well-formed source-artifact digest
#                        D24 a recorded function digest dropped from the ledger
#                        D25 a required digest key substituted, total count preserved
#                        D26 a same-named overload deployed alongside the real function
#   N1-N4  grantor chains and role identity: a grant option exercised before apply and after it,
#          a renamed grantee, and a grantee dropped and recreated under the same name
#   M1–M3   MIGRATION    packet identity binds real bytes:
#                        M1 executable SQL mutated, version/revision constant -> identity FAILS
#                        M2 the frozen contract mutated -> source-artifact digest FAILS
#                        M3 deployed-object drift with the ledger row untouched -> verifier FAILS
#   O1–O2   OFFLINE      the synthetic-substrate guard actually guards:
#                        O1 no disposable marker -> REFUSE
#                        O2 populated S1/T2/T4A state with NO Journal tables -> REFUSE
#   C1      CONCURRENCY  two transactions promote the SAME decision. The second is proven to be
#   C2      CONCURRENCY  BLOCKED BY the first (exact backend PIDs, pg_blocking_pids), and after
#                        serialization there is exactly ONE trade and ONE promotion: the loser
#                        returns the deterministic same-decision replay (C1) or
#                        ERR_POSITION_ALREADY_PROMOTED for a DIFFERENT decision naming the SAME
#                        durable MT5 position (C2). Only TWO advisory locks remain (decision and
#                        position) — the global trade-id mint lock is gone, because the reserved
#                        namespace makes minting deterministic.
#                        DELIBERATELY NOT CLAIMED: that the mt5_cp_decision_uk / mt5_cp_position_uk
#                        branches of the unique_violation handler execute. Under the supported
#                        serialization they are unreachable BY CONSTRUCTION — the loser always
#                        re-reads after the winner commits and takes the normal path — and that is
#                        a proof, not a coverage gap. The branches that ARE reachable
#                        (mt5_cp_trade_uk, and the unknown-constraint re-raise) are executed for
#                        real in sections I1–I5 of the verification matrix.
#   W1      WALL CLOCK   a caller that enters while the evidence is fresh, then BLOCKS on a real
#                        T4B lock past the window, is refused. Transaction-start time would have
#                        promoted; clock_timestamp() captured after the lock does not. The window
#                        is redefined to 3s in that disposable database only — the CLOCK is under
#                        test, not the boundary value, which E6/E6b pin at the real 7200s.
#   X1      FORGERY      an authenticated owner reads its own marker, deletes the promoted trade and
#                        re-inserts the same (id, user_id, marker) tuple — the guard cannot refuse
#                        that tuple, so the column privilege must, and does. Ordinary app writes
#                        keep working.
#   R1      ROLLBACK     the rollback packet REFUSES while a durable promotion exists, and never
#                        touches public.trades.
#   R2      REAPPLY      rollback removes the ledger rows, and both packets reapply cleanly.
#
# Requires: docker. Run from anywhere: bash artifacts/mt5_reconciliation/T4B_offline_probes.sh
# Creates its own container (t4b_probe_pg), leaves it running for inspection.
# Cleanup afterwards: docker rm -f t4b_probe_pg
# ================================================================================================
set -u
# Git Bash / MSYS rewrites arguments that look like absolute POSIX paths into Windows paths, which
# would turn an in-container "/tmp/x" into "C:/Users/.../Temp/x" before docker ever sees it. Harmless
# elsewhere; required here.
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"
ART="artifacts/mt5_reconciliation"
C=t4b_probe_pg
TMP="$(mktemp -d)"
PASS_N=0; FAIL_N=0
MARKER_SET="SET t4b.offline_fixture = 'I_UNDERSTAND_DISPOSABLE';"

ok()  { PASS_N=$((PASS_N+1)); echo "PROBE PASS: $1"; }
bad() { FAIL_N=$((FAIL_N+1)); echo "PROBE FAIL: $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got [$1] want [$2])"; fi; }

psql_file() { docker exec -i "$C" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q; }
psql_val()  { docker exec "$C" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qAt -c "$2"; }
psql_do()   { docker exec "$C" psql -U postgres -d "$1" -q -c "$2" >/dev/null 2>&1; }

# An OFFLINE-ONLY packet needs the disposable marker in its session. Prepending it to the stream
# sets it before the packet's own BEGIN, exactly as the documented invocation does.
psql_marked() { { echo "$MARKER_SET"; cat; } | psql_file "$1"; }

verifier_expect() { # $1=db $2=PASS|FAIL $3=label
  out=$(psql_file "$1" < "$ART/T4B_promotion_security_verification_packet.sql" 2>&1); rc=$?
  if [ "$2" = PASS ]; then
    if [ $rc -eq 0 ] && echo "$out" | grep -q "ALL SECTIONS PASS"; then ok "$3"; else
      bad "$3"; echo "$out" | grep -E '^ERROR|SEC[0-9]+' | head -3; fi
  else
    if [ $rc -ne 0 ] && echo "$out" | grep -q "SEC"; then
      ok "$3 — $(echo "$out" | grep -oE 'SEC[0-9]+[a-z]?:[^"]*' | head -1 | cut -c1-88)"
    else bad "$3 (verifier did not fail)"; fi
  fi
}

CHAIN_PRE="T4A_offline_bootstrap.sql T2_capture_events_schema_packet.sql \
T2_capture_events_rpc_packet.sql T4A_decisions_schema_packet.sql T4A_decisions_rpc_packet.sql"
CHAIN_T4B="T4B_offline_bootstrap.sql T4B_promotion_schema_packet.sql T4B_promotion_rpc_packet.sql"

apply_chain() { # $1=db
  for f in $CHAIN_PRE $CHAIN_T4B; do
    psql_marked "$1" < "$ART/$f" >/dev/null 2>"$TMP/apply.err" \
      || { echo "apply failed in $1: $f"; tail -4 "$TMP/apply.err"; exit 1; }
  done
}
new_db() { # $1=db
  psql_val postgres "create database $1" >/dev/null
  psql_do "$1" "create schema extensions; create extension pgcrypto with schema extensions;"
}

echo "== container =="
docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e POSTGRES_PASSWORD=t4b postgres:17 >/dev/null || { echo "docker run failed"; exit 1; }
sleep 7
docker exec "$C" psql -U postgres -q \
  -c "create role anon nologin; create role authenticated nologin; create role service_role nologin;" \
  -c "create schema extensions; create extension pgcrypto with schema extensions;" || exit 1

echo "== B0 baseline =="
apply_chain postgres
ok "B0a the full S1/T2/T4A/T4B packet chain applies clean"
out=$(psql_marked postgres < "$ART/T4B_promotion_verification_packet.sql" 2>&1)
if echo "$out" | grep -q "ALL .* CHECKS PASS"; then
  ok "B0b offline verification matrix: $(echo "$out" | grep -o 'ALL [0-9]* CHECKS PASS')"
else bad "B0b offline verification matrix"; echo "$out" | grep -E '^ERROR' -A 8 | head -14; fi
verifier_expect postgres PASS "B0c security verifier PASSES on a clean apply"
# The canonical expression for "the non-owner INSERT/UPDATE privilege shape of public.trades".
# Byte-for-byte the same shape the schema packet snapshots and the rollback packet restores.
Q_WRITE_ACL="select coalesce(jsonb_agg(j order by j->>'scope', j->>'grantee', j->>'priv', coalesce(j->>'column','')), '[]'::jsonb)::text from (select jsonb_build_object('scope','table','grantee', case when x.grantee=0 then 'public' else (select q.rolname from pg_roles q where q.oid=x.grantee) end,'priv',x.privilege_type,'grantable',x.is_grantable) as j from pg_class c, lateral aclexplode(c.relacl) x where c.oid='public.trades'::regclass and x.privilege_type in ('INSERT','UPDATE') and x.grantee <> c.relowner union select jsonb_build_object('scope','column','grantee', case when x.grantee=0 then 'public' else (select q.rolname from pg_roles q where q.oid=x.grantee) end,'priv',x.privilege_type,'grantable',x.is_grantable,'column',a.attname) as j from pg_attribute a, lateral aclexplode(a.attacl) x where a.attrelid='public.trades'::regclass and a.attnum>0 and not a.attisdropped and x.privilege_type in ('INSERT','UPDATE') and x.grantee <> (select c.relowner from pg_class c where c.oid='public.trades'::regclass)) s"

assert_eq "$(psql_val postgres 'select count(*) from public.trades')" "0" \
  "B0d the verification packet rolled back — no trade survived it"
if python -X utf8 "$ART/T4B_packet_identity.py" --check >"$TMP/id.out" 2>&1; then
  ok "B0e packet identity: $(grep -o 'OK .*' "$TMP/id.out" | head -1)"
else bad "B0e packet identity --check failed"; sed -n '1,6p' "$TMP/id.out"; fi

# ------------------------------------------------------------------------------------------------
# shared fixture for the stateful probes (a separate database, committed not rolled back)
# ------------------------------------------------------------------------------------------------
seed_db() { # $1=db
  psql_val "$1" "select 1" >/dev/null
  psql_file "$1" <<'SQL'
insert into public.products(user_id, data, updated_at) values (
  '11111111-1111-4111-8111-111111111111',
  jsonb_build_array(jsonb_build_object('id','s50','baseSymbol','S50','currentContract','S50M26',
    'nextContract','S50U26','contractSize',200,'tickSize',0.1,'tickValue',20)), now());
insert into public.mt5_sync_runs(id,user_id,source_account,captured_at,snapshot_status,
  reconcile_status,snapshot_health,run_seq,previous_positions_count,positions_count,
  position_ids_hash,manifest_hash,policy_version,policy_thresholds,connector_version,
  lease_token,lease_expires_at,heartbeat_at,snapshot_completed_at,reconciled_at)
select v.id,'11111111-1111-4111-8111-111111111111','301102520', now() - v.age,'complete',
  'complete','healthy',v.seq,0,1,repeat('a',64),repeat('b',64),'s1-policy/0.1',
  '{"k":3,"susp_min_base":4,"susp_drop_ratio":0.5,"freshness_seconds":900}'::jsonb,
  's1-connector/0.1',gen_random_uuid(),now()+interval '1 hour',now(),now()-v.age,now()-v.age
from (values ('aaaaaaaa-0000-4000-8000-000000000001'::uuid, interval '90 minutes', 3::bigint),
             ('aaaaaaaa-0000-4000-8000-000000000002'::uuid, interval '10 minutes', 4::bigint))
     v(id,age,seq);
insert into public.mt5_sync_run_positions(run_id,user_id,source_account,position_id,symbol_raw,
  side,volume,price_open,price_current,profit,open_time_utc,source_time_msc,contract_size,
  captured_at,row_fingerprint)
select r.id,'11111111-1111-4111-8111-111111111111','301102520',312261388,'S50U26','buy',5,1067.3,
  1071.6,4300,timestamptz '2026-08-24 03:36:12+00',1787567772245,200,r.captured_at,
  md5(r.id::text)||md5('pos')
from public.mt5_sync_runs r;
insert into public.mt5_capture_events(id,event_key,user_id,source_account,position_id,basis_run_id,
  first_detection_at,last_detection_at,quiet_deadline,quiet_window_seconds,detector_version,
  aggregator_version,payload,payload_fingerprint)
select v.id, md5(v.k)||md5(v.k||'k'),'11111111-1111-4111-8111-111111111111','301102520',312261388,
  'aaaaaaaa-0000-4000-8000-000000000001', now()-interval '3 hours', now()-interval '3 hours',
  now()-interval '2 hours',900,'t1-detector/0.1','t2-quiet-window/0.1',
  jsonb_build_object('domain','mt5.t2.capture/1'), md5(v.k)||md5(v.k||'f')
from (values ('cccccccc-0000-4000-8000-00000000000a'::uuid,'a'),
             ('cccccccc-0000-4000-8000-00000000000b'::uuid,'b')) v(id,k);
insert into public.mt5_capture_decisions(id,capture_event_id,action,source,telegram_chat_id,
  telegram_message_id) values
 ('dddddddd-0000-4000-8000-00000000000a','cccccccc-0000-4000-8000-00000000000a','journal_add','telegram',1,1),
 ('dddddddd-0000-4000-8000-00000000000b','cccccccc-0000-4000-8000-00000000000b','journal_add','telegram',1,2);
SQL
}

# ------------------------------------------------------------------------------------------------
# B1 atomicity: the insert order is LEDGER then TRADE, so the fault is induced on the trade insert.
# A check violation is NOT a unique violation, so it is not caught by the handler — it must abort
# the whole call and take the already-inserted ledger row down with it.
# ------------------------------------------------------------------------------------------------
echo "== B1 atomicity =="
new_db probe_atomic
apply_chain probe_atomic
seed_db probe_atomic
psql_do probe_atomic "alter table public.trades add constraint probe_boom check (id !~ '^mt5p_')"
out=$(psql_val probe_atomic "select o_ok::text from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-00000000000a')" 2>&1)
if echo "$out" | grep -q "probe_boom"; then
  ok "B1a a trade-side failure aborts the call (constraint surfaced, not swallowed)"
else bad "B1a expected the trades constraint to abort the call (got: $(echo "$out" | head -1))"; fi
assert_eq "$(psql_val probe_atomic 'select count(*) from public.mt5_capture_promotions')" "0" \
  "B1b NO orphan ledger row survived the failed promotion (it was inserted FIRST)"
assert_eq "$(psql_val probe_atomic 'select count(*) from public.trades')" "0" \
  "B1c NO Journal trade survived either"
psql_do probe_atomic "alter table public.trades drop constraint probe_boom"
assert_eq "$(psql_val probe_atomic "select o_inserted::text from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-00000000000a')")" "1" \
  "B1d with the induced fault removed, the same call promotes normally"
assert_eq "$(psql_val probe_atomic "select (mt5_promotion_id is not null)::text from public.trades limit 1")" "true" \
  "B1e the promoted trade carries its incarnation marker"

# ------------------------------------------------------------------------------------------------
# D1–D17 security drift
# ------------------------------------------------------------------------------------------------
echo "== D1-D17 security drift =="
drift() { # $1=label $2=break-sql $3=revert-sql
  psql_do postgres "$2"
  verifier_expect postgres FAIL "$1"
  psql_do postgres "$3"
  verifier_expect postgres PASS "$1 reverted -> verifier PASSES again"
}

# A body-drift probe cannot be reverted by re-typing the function: SEC7i compares
# sha256(pg_get_functiondef()), so an equivalent-but-not-identical rewrite still counts as drift
# (correctly). Capture the deployed definition first and replay exactly that.
drift_body() { # $1=label $2=function-signature $3=break-sql
  docker exec "$C" psql -U postgres -d postgres -qAt \
    -c "select pg_get_functiondef('$2'::regprocedure)" > "$TMP/saved_fn.sql" 2>/dev/null
  echo ";" >> "$TMP/saved_fn.sql"
  psql_do postgres "$3"
  verifier_expect postgres FAIL "$1"
  psql_file postgres < "$TMP/saved_fn.sql" >/dev/null 2>&1
  verifier_expect postgres PASS "$1 reverted -> verifier PASSES again"
}

# Same shape for a scalar the probe overwrites: remember it, break it, restore the remembered value.
drift_value() { # $1=label $2=select-current $3=break-template(%s) $4=restore-template(%s)
  saved=$(psql_val postgres "$2")
  psql_do postgres "$3"
  verifier_expect postgres FAIL "$1"
  psql_do postgres "$(printf "$4" "$saved")"
  verifier_expect postgres PASS "$1 reverted -> verifier PASSES again"
}
drift "D1 EXECUTE granted to PUBLIC on the promotion RPC" \
  "grant execute on function public.mt5_promote_capture_decision_v1(uuid) to public" \
  "revoke execute on function public.mt5_promote_capture_decision_v1(uuid) from public"
drift "D2 table SELECT granted to authenticated" \
  "grant select on table public.mt5_capture_promotions to authenticated" \
  "revoke select on table public.mt5_capture_promotions from authenticated"
drift "D3 column-level SELECT grant" \
  "grant select (trade_id) on table public.mt5_capture_promotions to authenticated" \
  "revoke select (trade_id) on table public.mt5_capture_promotions from authenticated"
drift "D4 helper EXECUTE exposed to service_role" \
  "grant execute on function public.mt5_t4b_map_product_v1(uuid,text,numeric) to service_role" \
  "revoke execute on function public.mt5_t4b_map_product_v1(uuid,text,numeric) from service_role"
drift "D5 extra RLS policy" \
  "create policy probe_extra on public.mt5_capture_promotions for select to authenticated using (true)" \
  "drop policy probe_extra on public.mt5_capture_promotions"
drift "D6 search_path cleared on a helper" \
  "alter function public.mt5_t4b_map_product_v1(uuid,text,numeric) reset search_path" \
  "alter function public.mt5_t4b_map_product_v1(uuid,text,numeric) set search_path = public, pg_temp"
drift "D7 SECURITY DEFINER bit cleared" \
  "alter function public.mt5_t4b_freshness_window_v1() security invoker" \
  "alter function public.mt5_t4b_freshness_window_v1() security definer"
drift "D8 position-uniqueness constraint dropped" \
  "alter table public.mt5_capture_promotions drop constraint mt5_cp_position_uk" \
  "alter table public.mt5_capture_promotions add constraint mt5_cp_position_uk unique (user_id, source_account, position_id)"

# D9 — the attack a name-only check cannot see: the constraint still EXISTS, is still UNIQUE, is
# still called mt5_cp_position_uk, and no longer enforces one-trade-per-MT5-position.
drift "D9 SAME-NAMED unique constraint over the WRONG columns" \
  "alter table public.mt5_capture_promotions drop constraint mt5_cp_position_uk; \
   alter table public.mt5_capture_promotions add constraint mt5_cp_position_uk unique (user_id, source_account, position_id, decision_id)" \
  "alter table public.mt5_capture_promotions drop constraint mt5_cp_position_uk; \
   alter table public.mt5_capture_promotions add constraint mt5_cp_position_uk unique (user_id, source_account, position_id)"

# D10 — a same-named foreign key that no longer carries the scope columns, so a promotion could
# cite a run belonging to another account.
drift "D10 SAME-NAMED foreign key with a DIFFERENT column mapping" \
  "alter table public.mt5_capture_promotions drop constraint mt5_cp_basis_run_fk; \
   alter table public.mt5_capture_promotions add constraint mt5_cp_basis_run_fk foreign key (basis_run_id) references public.mt5_sync_runs(id)" \
  "alter table public.mt5_capture_promotions drop constraint mt5_cp_basis_run_fk; \
   alter table public.mt5_capture_promotions add constraint mt5_cp_basis_run_fk foreign key (basis_run_id, user_id, source_account) references public.mt5_sync_runs(id, user_id, source_account)"

# D11 — a same-named index whose predicate no longer restricts anything the contract promises.
drift "D11 SAME-NAMED index with a DIFFERENT predicate" \
  "drop index public.mt5_trades_promotion_uk; \
   create unique index mt5_trades_promotion_uk on public.trades (mt5_promotion_id) where mt5_promotion_id is not null and id is not null" \
  "drop index public.mt5_trades_promotion_uk; \
   create unique index mt5_trades_promotion_uk on public.trades (mt5_promotion_id) where mt5_promotion_id is not null"

# D12 — the classic: keep every name, gut the behaviour.
drift_body "D12 SAME-NAMED trigger replaced by a NO-OP function" \
  "public.mt5_capture_promotion_guard_v1()" \
  "create or replace function public.mt5_capture_promotion_guard_v1() returns trigger language plpgsql security definer set search_path = '' as \$\$ begin return new; end \$\$"

# D13 — a search_path that a `like 'search_path=%'` check accepts and that changes resolution.
drift "D13 MALICIOUS search_path that still contains 'search_path='" \
  "alter function public.mt5_t4b_validate_fulfillment_v1(uuid,text,uuid) set search_path = evil, public, pg_temp" \
  "alter function public.mt5_t4b_validate_fulfillment_v1(uuid,text,uuid) set search_path = public, pg_temp"

# D14 — volatility is part of the contract: a STABLE validator turned VOLATILE changes planning
# and caching assumptions.
drift "D14 volatility changed (stable -> volatile)" \
  "alter function public.mt5_t4b_validate_fulfillment_v1(uuid,text,uuid) volatile" \
  "alter function public.mt5_t4b_validate_fulfillment_v1(uuid,text,uuid) stable"

# D15/D16 — an ARBITRARY role nobody wrote a denylist rule for. Only an allowlist catches these.
psql_do postgres "create role probe_intruder nologin"
drift "D15 an ARBITRARY role granted a table privilege" \
  "grant select on table public.mt5_capture_promotions to probe_intruder" \
  "revoke select on table public.mt5_capture_promotions from probe_intruder"
drift "D16 an ARBITRARY role granted EXECUTE on the promotion RPC" \
  "grant execute on function public.mt5_promote_capture_decision_v1(uuid) to probe_intruder" \
  "revoke execute on function public.mt5_promote_capture_decision_v1(uuid) from probe_intruder"

# D17 — the incarnation guard removed: markers become forgeable and mutable.
drift "D17 the incarnation guard trigger dropped from public.trades" \
  "drop trigger mt5_trades_incarnation_guard_v1 on public.trades" \
  "create trigger mt5_trades_incarnation_guard_v1 before insert or update of mt5_promotion_id on public.trades for each row execute function public.mt5_trades_incarnation_guard_v1()"

# D18 — THE ATTACK METADATA CANNOT SEE: the validator keeps its signature, owner, SECURITY DEFINER
# flag, volatility and search_path, and simply stops validating. Only an exact body digest catches
# it.
drift_body "D18 a function BODY replaced while every metadata property is preserved" \
  "public.mt5_t4b_validate_fulfillment_v1(uuid,text,uuid)" \
  "create or replace function public.mt5_t4b_validate_fulfillment_v1(p_promotion uuid, p_trade text, p_user uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as \$v\$ select true \$v\$"

# D19 — a REQUIRED grant removed. An allowlist that only rejects extras passes a strict subset.
drift "D19 service_role LOSES SELECT on the promotion ledger" \
  "revoke select on table public.mt5_capture_promotions from service_role" \
  "grant select on table public.mt5_capture_promotions to service_role"
drift "D20 service_role LOSES EXECUTE on the promotion RPC" \
  "revoke execute on function public.mt5_promote_capture_decision_v1(uuid) from service_role" \
  "grant execute on function public.mt5_promote_capture_decision_v1(uuid) to service_role"

# D21 — the marker made client-writable again. attacl alone would not necessarily see a grant made
# through a role the app inherits; has_column_privilege does.
drift "D21 the incarnation marker made writable by authenticated again" \
  "grant insert (mt5_promotion_id) on table public.trades to authenticated" \
  "revoke insert (mt5_promotion_id) on table public.trades from authenticated"

# D22 — the ledger checksum replaced with an arbitrary but well-formed hash. A shape-only check
# ("two distinct hashes, neither of them the old T3 one") would accept this.
drift_value "D22 an arbitrary migration checksum in the ledger" \
  "select checksum from public.mt5_schema_migrations where version = 'mt5_t4b_promotion_rpc_v1'" \
  "update public.mt5_schema_migrations set checksum = repeat('a',64) where version = 'mt5_t4b_promotion_rpc_v1'" \
  "update public.mt5_schema_migrations set checksum = '%s' where version = 'mt5_t4b_promotion_rpc_v1'"

# D23 — an arbitrary but well-formed source-artifact digest.
drift_value "D23 an arbitrary source-artifact digest in the ledger" \
  "select source_artifact_sha256 from public.mt5_schema_migrations where version = 'mt5_t4b_promotion_schema_v1'" \
  "update public.mt5_schema_migrations set source_artifact_sha256 = repeat('A',64) where version = 'mt5_t4b_promotion_schema_v1'" \
  "update public.mt5_schema_migrations set source_artifact_sha256 = '%s' where version = 'mt5_t4b_promotion_schema_v1'"

# D25 — the subtler shape of the same attack: a REQUIRED key is swapped for an unrelated deployed
# function whose OWN digest is recorded correctly. The total stays at six and every recorded digest
# matches its deployed body, so a count-and-compare verifier is perfectly happy while the T4B
# function that fell out of the set is no longer covered by anything.
drift_value "D25 a required digest key SUBSTITUTED for an unrelated function, count preserved" \
  "select objects->'function_digests'->>'public.mt5_t4b_map_product_v1(uuid, text, numeric)' from public.mt5_schema_migrations where version = 'mt5_t4b_promotion_rpc_v1'" \
  "update public.mt5_schema_migrations set objects = jsonb_set(objects,'{function_digests}', ((objects->'function_digests') - 'public.mt5_t4b_map_product_v1(uuid, text, numeric)') || jsonb_build_object('public.mt5_t4b_freshness_window_v1_decoy()', (select encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='mt5_t4b_freshness_window_v1'))) where version = 'mt5_t4b_promotion_rpc_v1'" \
  "update public.mt5_schema_migrations set objects = jsonb_set(objects,'{function_digests}', ((objects->'function_digests') - 'public.mt5_t4b_freshness_window_v1_decoy()') || jsonb_build_object('public.mt5_t4b_map_product_v1(uuid, text, numeric)','%s')) where version = 'mt5_t4b_promotion_rpc_v1'"

# D26 — the digest key kept, but pointed at a same-named function with a DIFFERENT signature. Bare
# proname resolution would find the wrong overload; to_regprocedure cannot.
drift "D26 a same-named overload deployed alongside the real function" \
  "create function public.mt5_t4b_freshness_window_v1(int) returns interval language sql immutable set search_path = '' as \$d\$ select interval '1 second' \$d\$; grant execute on function public.mt5_t4b_freshness_window_v1(int) to public" \
  "drop function public.mt5_t4b_freshness_window_v1(int)"

# D24 — a recorded function digest quietly dropped from the ledger, which would make SEC7i skip it.
drift_value "D24 a recorded function digest removed from the ledger" \
  "select objects->'function_digests'->>'public.mt5_t4b_map_product_v1(uuid, text, numeric)' from public.mt5_schema_migrations where version = 'mt5_t4b_promotion_rpc_v1'" \
  "update public.mt5_schema_migrations set objects = jsonb_set(objects,'{function_digests}', (objects->'function_digests') - 'public.mt5_t4b_map_product_v1(uuid, text, numeric)') where version = 'mt5_t4b_promotion_rpc_v1'" \
  "update public.mt5_schema_migrations set objects = jsonb_set(objects,'{function_digests}', (objects->'function_digests') || jsonb_build_object('public.mt5_t4b_map_product_v1(uuid, text, numeric)','%s')) where version = 'mt5_t4b_promotion_rpc_v1'"

# ------------------------------------------------------------------------------------------------
# M1–M3 migration identity binds real artifacts
# ------------------------------------------------------------------------------------------------
echo "== M1-M3 migration identity =="
IDDIR="$TMP/ident"
mkdir -p "$IDDIR"
# python here is a WINDOWS binary and MSYS_NO_PATHCONV=1 (needed for docker) stops MSYS from
# translating POSIX paths on its behalf, so hand it a native path explicitly.
IDDIR_W="$(cygpath -w "$IDDIR" 2>/dev/null || echo "$IDDIR")"
cp "$ART/T4B_packet_identity.py" "$ART/T4B_promotion_schema_packet.sql" \
   "$ART/T4B_promotion_rpc_packet.sql" "$ART/T4B_1_promotion_contract_v1.md" \
   "$ART/T4B_packet_manifest_v1.json" \
   "$ART/T4B_promotion_security_verification_packet.sql" "$IDDIR/"
if python -X utf8 "$IDDIR_W\T4B_packet_identity.py" --check >/dev/null 2>&1; then
  ok "M0 the copied artifact set verifies clean"
else bad "M0 the copied artifact set should verify clean"; fi

# M1 — change executable SQL, leave version and packet_revision alone.
python -X utf8 - "$IDDIR_W\T4B_promotion_rpc_packet.sql" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
# a real executable change: widen the freshness window
t = t.replace("interval '7200 seconds' $win$", "interval '99999 seconds' $win$", 1)
p.write_text(t, encoding="utf-8", newline="")
PY
if python -X utf8 "$IDDIR_W\T4B_packet_identity.py" --check >"$TMP/m1.out" 2>&1; then
  bad "M1 mutated executable SQL still passed identity verification"
else
  ok "M1 mutated executable SQL FAILS identity: $(grep -o 'canonical digest drift.*' "$TMP/m1.out" | head -1 | cut -c1-60)"
fi
cp "$ART/T4B_promotion_rpc_packet.sql" "$IDDIR/"

# M2 — change the frozen contract the packets claim to implement.
python -X utf8 - "$IDDIR_W\T4B_1_promotion_contract_v1.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text(encoding="utf-8") + "\nan unreviewed amendment\n", encoding="utf-8",
             newline="")
PY
if python -X utf8 "$IDDIR_W\T4B_packet_identity.py" --check >"$TMP/m2.out" 2>&1; then
  bad "M2 a mutated contract still passed identity verification"
else
  ok "M2 a mutated contract FAILS the source-artifact digest"
fi

# M3 — the ledger row says "applied" and is untouched, but a deployed object drifted.
LEDGER_BEFORE=$(psql_val postgres "select md5(string_agg(version||checksum||status,'|' order by version)) from public.mt5_schema_migrations where version like 'mt5_t4b%'")
psql_do postgres "alter table public.mt5_capture_promotions drop constraint mt5_cp_trade_uk"
verifier_expect postgres FAIL "M3a deployed-object drift is caught even with the ledger row intact"
assert_eq "$(psql_val postgres "select md5(string_agg(version||checksum||status,'|' order by version)) from public.mt5_schema_migrations where version like 'mt5_t4b%'")" \
  "$LEDGER_BEFORE" "M3b ...and the ledger row really was untouched during that drift"
psql_do postgres "alter table public.mt5_capture_promotions add constraint mt5_cp_trade_uk unique (trade_id)"
verifier_expect postgres PASS "M3c reverted -> verifier PASSES again"

# ------------------------------------------------------------------------------------------------
# O1–O2 the offline substrate guard
# ------------------------------------------------------------------------------------------------
echo "== O1-O2 offline substrate guard =="
new_db probe_nomarker
for f in $CHAIN_PRE; do psql_marked probe_nomarker < "$ART/$f" >/dev/null 2>&1; done
out=$(psql_file probe_nomarker < "$ART/T4B_offline_bootstrap.sql" 2>&1)
if echo "$out" | grep -q "T4B_OFFLINE_BOOTSTRAP: refusing to run"; then
  ok "O1a the bootstrap REFUSES without the disposable marker"
else bad "O1a the bootstrap ran without a marker"; fi
assert_eq "$(psql_val probe_nomarker "select (to_regclass('public.trades') is null)::text")" "true" \
  "O1b no synthetic Journal substrate was created"

# O2 — the exact hole revision 1 had: real-looking pipeline data, no Journal tables at all.
new_db probe_populated
for f in $CHAIN_PRE; do psql_marked probe_populated < "$ART/$f" >/dev/null 2>&1; done
psql_file probe_populated <<'SQL' >/dev/null 2>&1
insert into public.mt5_sync_runs(id,user_id,source_account,captured_at,snapshot_status,
  reconcile_status,snapshot_health,run_seq,previous_positions_count,positions_count,
  position_ids_hash,manifest_hash,policy_version,policy_thresholds,connector_version,
  lease_token,lease_expires_at,heartbeat_at,snapshot_completed_at,reconciled_at)
values ('aaaaaaaa-0000-4000-8000-0000000000ff','11111111-1111-4111-8111-111111111111','301102520',
  now(),'complete','complete','healthy',9,0,1,repeat('a',64),repeat('b',64),'s1-policy/0.1',
  '{"k":3,"susp_min_base":4,"susp_drop_ratio":0.5,"freshness_seconds":900}'::jsonb,
  's1-connector/0.1',gen_random_uuid(),now()+interval '1 hour',now(),now(),now());
SQL
assert_eq "$(psql_val probe_populated 'select count(*) from public.mt5_sync_runs')" "1" \
  "O2a a database holding REAL S1 evidence and no Journal tables"
out=$({ echo "$MARKER_SET"; cat "$ART/T4B_offline_bootstrap.sql"; } | psql_file probe_populated 2>&1)
if echo "$out" | grep -q "already holds durable rows"; then
  ok "O2b the bootstrap REFUSES even WITH the marker, because durable rows exist"
else bad "O2b the bootstrap grafted a synthetic Journal onto a populated database"; fi
assert_eq "$(psql_val probe_populated "select (to_regclass('public.trades') is null)::text")" "true" \
  "O2c no synthetic Journal substrate was created"

# ------------------------------------------------------------------------------------------------
# C1 / C2 concurrency — exact backend PIDs, asserted blocking
# ------------------------------------------------------------------------------------------------
concurrency() { # $1=db $2=decision_A $3=decision_B $4=label-prefix $5=expected_B_error(- for replay)
  db="$1"; da="$2"; db2="$3"; pfx="$4"; expect="$5"
  rm -f "$TMP/$pfx.a" "$TMP/$pfx.b"
  docker exec -e PGAPPNAME="t4b_${pfx}_A" -d "$C" bash -lc \
    "psql -U postgres -d $db -qAt -c \"begin; select o_ok::text||'|'||o_inserted::text||'|'||coalesce(o_error_code,'-') from public.mt5_promote_capture_decision_v1('$da'); select pg_sleep(7); commit;\" > /tmp/$pfx.a 2>&1"
  sleep 2
  docker exec -e PGAPPNAME="t4b_${pfx}_B" -d "$C" bash -lc \
    "psql -U postgres -d $db -qAt -c \"begin; select o_ok::text||'|'||o_inserted::text||'|'||coalesce(o_error_code,'-') from public.mt5_promote_capture_decision_v1('$db2'); commit;\" > /tmp/$pfx.b 2>&1"
  # bounded, fail-closed proof that B is blocked BY A (exact pids, single snapshot)
  blocked=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    blocked=$(psql_val "$db" "
      select 'yes' from pg_stat_activity b
       where b.application_name = 't4b_${pfx}_B'
         and b.query like '%mt5_promote_capture_decision_v1%'
         and exists (select 1 from pg_stat_activity a
                      where a.application_name = 't4b_${pfx}_A'
                        and a.pid = any(pg_blocking_pids(b.pid)))
       limit 1")
    [ "$blocked" = "yes" ] && break
    sleep 1
  done
  assert_eq "$blocked" "yes" "$pfx-1 writer B is blocked BY writer A (exact pid via pg_blocking_pids)"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if docker exec "$C" test -s "/tmp/$pfx.a" && docker exec "$C" test -s "/tmp/$pfx.b"; then
      break
    fi
    sleep 1
  done
  ra=$(docker exec "$C" cat "/tmp/$pfx.a" 2>/dev/null | head -1)
  rb=$(docker exec "$C" cat "/tmp/$pfx.b" 2>/dev/null | head -1)
  assert_eq "$ra" "true|1|-" "$pfx-2 writer A performed the single insert"
  if [ "$expect" = "-" ]; then
    assert_eq "$rb" "true|0|-" "$pfx-3 writer B resolves as the deterministic same-decision replay"
  else
    assert_eq "$rb" "false|0|$expect" "$pfx-3 writer B resolves as $expect"
  fi
  assert_eq "$(psql_val "$db" "select count(*) from public.trades where raw->>'mt5PositionId'='312261388'")" "1" \
    "$pfx-4 exactly ONE Journal trade exists for the position"
  assert_eq "$(psql_val "$db" 'select count(*) from public.mt5_capture_promotions')" "1" \
    "$pfx-5 exactly ONE promotion row exists"
  assert_eq "$(psql_val "$db" "select count(*) from public.trades t join public.mt5_capture_promotions p on p.id = t.mt5_promotion_id")" "1" \
    "$pfx-6 the single trade carries the single promotion's incarnation marker"
}

echo "== C1 concurrency: same decision =="
new_db probe_c1
apply_chain probe_c1; seed_db probe_c1
concurrency probe_c1 "dddddddd-0000-4000-8000-00000000000a" "dddddddd-0000-4000-8000-00000000000a" C1 "-"

echo "== C2 concurrency: different decisions, SAME durable MT5 position =="
new_db probe_c2
apply_chain probe_c2; seed_db probe_c2
concurrency probe_c2 "dddddddd-0000-4000-8000-00000000000a" "dddddddd-0000-4000-8000-00000000000b" C2 \
  "ERR_POSITION_ALREADY_PROMOTED"

# The reserved namespace made minting deterministic, so the global id-mint lock is gone. Exactly
# two advisory locks remain, and both are scoped.
assert_eq "$(psql_val postgres "select (length(p.prosrc) - length(replace(p.prosrc,'pg_advisory_xact_lock','')))/length('pg_advisory_xact_lock') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='mt5_promote_capture_decision_v1'")" "2" \
  "C3 exactly TWO advisory locks remain (decision, position) — the global mint lock is gone"

# ------------------------------------------------------------------------------------------------
# X1 THE INCARNATION FORGERY, ATTEMPTED AS A REAL CLIENT SESSION.
#
# This is Codex's reproduction, executed rather than reasoned about: an authenticated owner reads
# their own marker, deletes the promoted trade, and re-inserts the SAME (id, user_id,
# mt5_promotion_id) tuple. The guard trigger CANNOT stop that — the tuple genuinely matches its
# ledger row — so the only thing standing between the attacker and a forged clean replay is the
# column-level privilege.
# ------------------------------------------------------------------------------------------------
echo "== X1 incarnation forgery as a client =="
new_db probe_forge
apply_chain probe_forge; seed_db probe_forge
psql_do probe_forge "grant usage on schema public to authenticated"
assert_eq "$(psql_val probe_forge "select o_inserted::text from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-00000000000a')")" "1" \
  "X1a a trade is promoted normally"
TRADE=$(psql_val probe_forge "select trade_id from public.mt5_capture_promotions")
MARKER=$(psql_val probe_forge "select mt5_promotion_id from public.trades where id = '$TRADE'")

# the client CAN read the marker — secrecy is not the control, privilege is
assert_eq "$(psql_val probe_forge "set role authenticated; select (mt5_promotion_id = '$MARKER')::text from public.trades where id = '$TRADE'")" "true" \
  "X1b the client can READ its own marker (secrecy is deliberately not the control)"

# ...and CAN delete its own trade, which stays allowed
psql_do probe_forge "set role authenticated; delete from public.trades where id = '$TRADE'"
assert_eq "$(psql_val probe_forge "select count(*) from public.trades where id = '$TRADE'")" "0" \
  "X1c the client deleted its own promoted trade (deletion stays permitted)"

# ...but CANNOT re-insert the marker. This is the whole fix.
out=$(docker exec "$C" psql -U postgres -d probe_forge -qAt -c \
  "set role authenticated; insert into public.trades(id,user_id,raw,mt5_promotion_id) values ('$TRADE','11111111-1111-4111-8111-111111111111','{}'::jsonb,'$MARKER');" 2>&1)
if echo "$out" | grep -qi "permission denied"; then
  ok "X1d the client CANNOT re-insert the marker — permission denied on mt5_promotion_id"
else
  bad "X1d the forgery succeeded or failed for the wrong reason: $(echo "$out" | head -1)"
fi

# the client can still recreate an ORDINARY row at that id — it just cannot carry authority
psql_do probe_forge "set role authenticated; insert into public.trades(id,user_id,raw) values ('$TRADE','11111111-1111-4111-8111-111111111111','{}'::jsonb)"
assert_eq "$(psql_val probe_forge "select (mt5_promotion_id is null)::text from public.trades where id = '$TRADE'")" "true" \
  "X1e the client-recreated row carries NO marker"
assert_eq "$(psql_val probe_forge "select coalesce(o_error_code,'-') from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-00000000000a')")" \
  "ERR_FULFILLMENT_DRIFT" \
  "X1f replay reports DRIFT against the forged row, not a clean replay"
assert_eq "$(psql_val probe_forge 'select count(*) from public.mt5_capture_promotions')" "1" \
  "X1g no second promotion was created"
# and the app's ordinary writes are untouched by the narrowing
psql_do probe_forge "set role authenticated; insert into public.trades(id,user_id,product_id,direction,status,contracts,remaining_contracts,entry_price,exit_price,entry_date,exit_date,note,raw) values ('1755000000001','11111111-1111-4111-8111-111111111111','s50_next','Long','open',5,5,1067.3,null,null,null,null,'{}'::jsonb)"
assert_eq "$(psql_val probe_forge "select count(*) from public.trades where id = '1755000000001'")" "1" \
  "X1h an ordinary 13-column app INSERT still works"
psql_do probe_forge "set role authenticated; update public.trades set entry_price = 1099.9, raw = '{\"x\":1}'::jsonb where id = '1755000000001'"
assert_eq "$(psql_val probe_forge "select entry_price::text from public.trades where id = '1755000000001'")" "1099.9" \
  "X1i an ordinary app UPDATE still works"

# ------------------------------------------------------------------------------------------------
# W1 THE BLOCK-ACROSS-BOUNDARY TEST — the exact defect the wall-clock fix exists for.
#
# A request enters the transaction while the evidence is comfortably fresh, blocks on a real T4B
# lock for longer than the freshness window, and only then reaches the eligibility check. With
# now() (transaction-start time) it would promote against evidence that expired while it waited;
# with clock_timestamp() captured after the lock it must refuse.
#
# The window is server-owned and frozen at 7200s, so the test cannot wait it out in real time.
# In this DISPOSABLE database only, the window function is redefined to 3 seconds — the boundary
# VALUE is not what is under test here, the CLOCK is. E6/E6b pin the real 7200s boundary.
# ------------------------------------------------------------------------------------------------
echo "== W1 freshness across a blocking wait =="
new_db probe_wall
apply_chain probe_wall; seed_db probe_wall
psql_do probe_wall "create or replace function public.mt5_t4b_freshness_window_v1() returns interval language sql immutable security definer set search_path = public, pg_temp as \$w\$ select interval '3 seconds' \$w\$"
assert_eq "$(psql_val probe_wall "select public.mt5_t4b_freshness_window_v1()::text")" "00:00:03" \
  "W1a fixture: the window is 3 seconds in this disposable database"
# evidence captured RIGHT NOW: age ~0, unambiguously fresh at the moment the caller starts
psql_do probe_wall "update public.mt5_sync_runs set captured_at = clock_timestamp() where run_seq = 4"

LOCKKEY="hashtextextended('mt5_t4b_pos:11111111-1111-4111-8111-111111111111|301102520|312261388', 0)"
rm -f "$TMP/w1.b"
# Session A takes the POSITION advisory lock the RPC will need, and holds it past the window.
docker exec -e PGAPPNAME="t4b_W1_A" -d "$C" bash -lc \
  "psql -U postgres -d probe_wall -qAt -c \"begin; select pg_advisory_xact_lock($LOCKKEY); select pg_sleep(8); commit;\" > /tmp/w1.a 2>&1"
sleep 2
# Session B starts NOW — while the evidence is still fresh — and blocks.
docker exec -e PGAPPNAME="t4b_W1_B" -d "$C" bash -lc \
  "psql -U postgres -d probe_wall -qAt -c \"begin; select o_ok::text||'|'||o_inserted::text||'|'||coalesce(o_error_code,'-') from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-00000000000a'); commit;\" > /tmp/w1.b 2>&1"
blocked=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  blocked=$(psql_val probe_wall "
    select 'yes' from pg_stat_activity b
     where b.application_name = 't4b_W1_B'
       and b.query like '%mt5_promote_capture_decision_v1%'
       and exists (select 1 from pg_stat_activity a
                    where a.application_name = 't4b_W1_A'
                      and a.pid = any(pg_blocking_pids(b.pid)))
     limit 1")
  [ "$blocked" = "yes" ] && break
  sleep 1
done
assert_eq "$blocked" "yes" "W1b writer B is blocked BY writer A on a real T4B lock (exact pid)"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  docker exec "$C" test -s /tmp/w1.b && break
  sleep 1
done
rb=$(docker exec "$C" cat /tmp/w1.b 2>/dev/null | head -1)
assert_eq "$rb" "false|0|ERR_STALE_EVIDENCE" \
  "W1c the evidence expired DURING the wait -> ERR_STALE_EVIDENCE (transaction-start time would have promoted)"
assert_eq "$(psql_val probe_wall 'select count(*) from public.trades')" "0" \
  "W1d no Journal trade was created"
assert_eq "$(psql_val probe_wall 'select count(*) from public.mt5_capture_promotions')" "0" \
  "W1e no promotion was recorded"
# control: same call, same window, no blocking wait -> fresh, promotes
psql_do probe_wall "update public.mt5_sync_runs set captured_at = clock_timestamp() where run_seq = 4"
assert_eq "$(psql_val probe_wall "select o_inserted::text from public.mt5_promote_capture_decision_v1('dddddddd-0000-4000-8000-00000000000a')")" "1" \
  "W1f control: without the wait the identical call promotes, so W1c failed on the CLOCK"

# ------------------------------------------------------------------------------------------------
# N1-N3 GRANTOR CHAINS AND ROLE IDENTITY.
#
# An ACL entry is (grantor, grantee, privilege, grantable). T4B revokes and re-grants as the owner,
# so it can only be lossless over an owner-granted surface; and a snapshot keyed by role NAME gets
# both role-lifecycle events wrong — a rename looks like a disappearance, a drop-and-recreate looks
# like the original role coming back.
# ------------------------------------------------------------------------------------------------
echo "== N1-N3 grantor chains and role identity =="

# N1 — a grant option that has actually been EXERCISED. PostgreSQL refuses to revoke a grant with
# dependent privileges, and the delegated entry carries a grantor this packet cannot act as.
new_db probe_chain
for f in $CHAIN_PRE T4B_offline_bootstrap.sql; do
  psql_marked probe_chain < "$ART/$f" >/dev/null 2>&1
done
psql_do probe_chain "create role t4b_child nologin"
psql_do probe_chain "set role t4b_app_writer; grant insert on table public.trades to t4b_child; reset role"
assert_eq "$(psql_val probe_chain "select count(*) from pg_class c, lateral aclexplode(c.relacl) x where c.oid='public.trades'::regclass and x.privilege_type in ('INSERT','UPDATE') and x.grantee <> c.relowner and x.grantor <> c.relowner")" "1" \
  "N1a fixture: the grant-option holder delegated INSERT, creating a non-owner grantor"
out=$(psql_marked probe_chain < "$ART/T4B_promotion_schema_packet.sql" 2>&1)
if echo "$out" | grep -q "MT5_T4B_NARROW_PREFLIGHT: REFUSING"; then
  ok "N1b apply REFUSES rather than half-migrating a delegation chain"
else bad "N1b apply did not refuse"; echo "$out" | grep -E '^ERROR' | head -2; fi
assert_eq "$(psql_val probe_chain "select count(*) from information_schema.columns where table_schema='public' and table_name='trades' and column_name='mt5_promotion_id'")" "0" \
  "N1c the refused apply left public.trades untouched"
assert_eq "$(psql_val probe_chain "select has_table_privilege('t4b_child','public.trades','INSERT')::text")" "true" \
  "N1d ...and left the delegated grant itself intact"
psql_do probe_chain "set role t4b_app_writer; revoke insert on table public.trades from t4b_child; reset role"
if psql_marked probe_chain < "$ART/T4B_promotion_schema_packet.sql" >/dev/null 2>&1; then
  ok "N1e ...and applies cleanly once the delegation is withdrawn"
else bad "N1e apply still failed after withdrawing the delegation"; fi

# N2 — the grantee is RENAMED between apply and rollback. Same principal, new label: the oid is
# what the snapshot recorded, so it must come back under whatever it is called now.
new_db probe_rename
for f in $CHAIN_PRE T4B_offline_bootstrap.sql; do
  psql_marked probe_rename < "$ART/$f" >/dev/null 2>&1
done
psql_do probe_rename "create role t4b_ren nologin"
psql_do probe_rename "grant update on table public.trades to t4b_ren"
REN_OID=$(psql_val probe_rename "select oid from pg_roles where rolname='t4b_ren'")
for f in T4B_promotion_schema_packet.sql T4B_promotion_rpc_packet.sql; do
  psql_marked probe_rename < "$ART/$f" >/dev/null 2>&1
done
assert_eq "$(psql_val probe_rename "select objects->'trades_prior_write_acl' @> jsonb_build_array(jsonb_build_object('grantee_oid', $REN_OID)) from public.mt5_schema_migrations where version='mt5_t4b_promotion_schema_v1'")" "t" \
  "N2a the snapshot recorded the grantee by OID, not only by name"
psql_do probe_rename "alter role t4b_ren rename to t4b_ren_v2"
if psql_marked probe_rename < "$ART/T4B_promotion_rollback_packet.sql" >/dev/null 2>&1; then
  ok "N2b rollback succeeds after the grantee was RENAMED"
else bad "N2b rollback failed after a rename"; fi
assert_eq "$(psql_val probe_rename "select has_table_privilege('t4b_ren_v2','public.trades','UPDATE')::text")" "true" \
  "N2c the renamed role got its table-level privilege back, under its new name"
assert_eq "$(psql_val probe_rename "select count(*) from pg_class c, lateral aclexplode(c.relacl) x where c.oid='public.trades'::regclass and x.grantee=$REN_OID and x.privilege_type='UPDATE'")" "1" \
  "N2d ...resolved to the SAME role oid the snapshot recorded"

# N3 — the grantee is dropped and a NEW role is created under the same name. Name-based matching
# would hand the replacement the privileges of the role it replaced.
new_db probe_recreate
for f in $CHAIN_PRE T4B_offline_bootstrap.sql; do
  psql_marked probe_recreate < "$ART/$f" >/dev/null 2>&1
done
psql_do probe_recreate "create role t4b_tmp nologin"
psql_do probe_recreate "grant update on table public.trades to t4b_tmp"
OLD_OID=$(psql_val probe_recreate "select oid from pg_roles where rolname='t4b_tmp'")
for f in T4B_promotion_schema_packet.sql T4B_promotion_rpc_packet.sql; do
  psql_marked probe_recreate < "$ART/$f" >/dev/null 2>&1
done
psql_do probe_recreate "drop owned by t4b_tmp"
psql_do probe_recreate "drop role t4b_tmp"
psql_do probe_recreate "create role t4b_tmp nologin"
NEW_OID=$(psql_val probe_recreate "select oid from pg_roles where rolname='t4b_tmp'")
if [ -n "$NEW_OID" ] && [ "$OLD_OID" != "$NEW_OID" ]; then
  ok "N3a fixture: the recreated role reuses the NAME with a different oid"
else bad "N3a the role oid did not change ($OLD_OID -> $NEW_OID)"; fi
out=$(psql_marked probe_recreate < "$ART/T4B_promotion_rollback_packet.sql" 2>&1)
if echo "$out" | grep -q "cannot be restored"; then
  ok "N3b rollback names the vanished grantee as non-restorable"
else bad "N3b no notice for the vanished grantee"; echo "$out" | grep -E '^ERROR' | head -2; fi
assert_eq "$(psql_val probe_recreate "select has_table_privilege('t4b_tmp','public.trades','UPDATE')::text")" "false" \
  "N3c the NAME-reusing replacement was NOT granted the original role's privileges"
assert_eq "$(psql_val probe_recreate "select (has_table_privilege('authenticated','public.trades','INSERT') and has_table_privilege('authenticated','public.trades','UPDATE'))::text")" "true" \
  "N3d ...while every still-identifiable grantee was restored"
psql_do probe_recreate "drop owned by t4b_tmp"
psql_do probe_recreate "drop role t4b_tmp"

# N4 — the ROLLBACK's grantor refusal, which N1 does not reach: N1 delegates BEFORE the apply, so
# it only ever exercises the apply's preflight. Here the apply runs clean, and the grant option it
# hands forward (now a COLUMN-level one, because that is what the narrowing produces) is exercised
# afterwards. The rollback must refuse, and refuse transactionally.
new_db probe_rbchain
apply_chain probe_rbchain
psql_do probe_rbchain "create role t4b_rbchild nologin"
psql_do probe_rbchain "set role t4b_app_writer; grant insert (raw) on table public.trades to t4b_rbchild; reset role"
assert_eq "$(psql_val probe_rbchain "select count(*) from pg_attribute a, lateral aclexplode(a.attacl) x where a.attrelid='public.trades'::regclass and a.attnum>0 and x.privilege_type in ('INSERT','UPDATE') and x.grantee<>(select relowner from pg_class where oid='public.trades'::regclass) and x.grantor<>(select relowner from pg_class where oid='public.trades'::regclass)")" "1" \
  "N4a fixture: the COLUMN grant option the narrowing produced was exercised after apply"
out=$(psql_marked probe_rbchain < "$ART/T4B_promotion_rollback_packet.sql" 2>&1)
if echo "$out" | grep -q "MT5_T4B_ROLLBACK: REFUSING"; then
  ok "N4b rollback REFUSES once a grant option has been exercised since apply"
else bad "N4b rollback did not refuse"; echo "$out" | grep -E '^ERROR' | head -2; fi
assert_eq "$(psql_val probe_rbchain "select (to_regclass('public.mt5_capture_promotions') is not null)::text")" "true" \
  "N4c the refused rollback left the promotion ledger in place"
assert_eq "$(psql_val probe_rbchain "select count(*) from information_schema.columns where table_schema='public' and table_name='trades' and column_name='mt5_promotion_id'")" "1" \
  "N4d ...and the incarnation column"
assert_eq "$(psql_val probe_rbchain "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('mt5_promote_capture_decision_v1','mt5_t4b_map_product_v1','mt5_t4b_validate_fulfillment_v1','mt5_t4b_freshness_window_v1','mt5_capture_promotion_guard_v1','mt5_trades_incarnation_guard_v1')")" "6" \
  "N4e ...and all six T4B functions"
assert_eq "$(psql_val probe_rbchain "select count(*) from public.mt5_schema_migrations where version like 'mt5_t4b%' and status='applied'")" "2" \
  "N4f ...and both ledger rows"
assert_eq "$(psql_val probe_rbchain "select has_column_privilege('t4b_rbchild','public.trades','raw','INSERT')::text")" "true" \
  "N4g ...and the delegated grant itself"
# ...and the read-only PRODUCTION verifier sees the same thing the rollback refused on, which is
# the point of SEC8m: an operator can detect this before an apply window rather than during one.
verifier_expect probe_rbchain FAIL "N4h the production verifier flags the delegated grant (SEC8m)"
psql_do probe_rbchain "set role t4b_app_writer; revoke insert (raw) on table public.trades from t4b_rbchild; reset role"
verifier_expect probe_rbchain PASS "N4h2 ...and passes again once the delegation is withdrawn"
if psql_marked probe_rbchain < "$ART/T4B_promotion_rollback_packet.sql" >/dev/null 2>&1; then
  ok "N4i ...and rolls back cleanly once the delegation is withdrawn"
else bad "N4i rollback still failed after withdrawing the delegation"; fi

# ------------------------------------------------------------------------------------------------
# R1 rollback refusal
# ------------------------------------------------------------------------------------------------
echo "== R1 rollback =="
before=$(psql_val probe_c1 'select count(*) from public.trades')
out=$(psql_file probe_c1 < "$ART/T4B_promotion_rollback_packet.sql" 2>&1)
if echo "$out" | grep -q "MT5_T4B_ROLLBACK: REFUSING"; then
  ok "R1a rollback REFUSES while a durable promotion exists"
else bad "R1a rollback did not refuse"; fi
assert_eq "$(psql_val probe_c1 'select count(*) from public.trades')" "$before" \
  "R1b the refused rollback left public.trades untouched"
Q_LEDGER="select (to_regclass('public.mt5_capture_promotions') is not null)::text"
assert_eq "$(psql_val probe_c1 "$Q_LEDGER")" "true" \
  "R1c the ledger survived the refused rollback"
Q_COL="select (exists (select 1 from information_schema.columns where table_schema='public' and table_name='trades' and column_name='mt5_promotion_id'))::text"
assert_eq "$(psql_val probe_c1 "$Q_COL")" "true" \
  "R1d the incarnation column survived the refused rollback"
# and it DOES run on a clean install
if psql_file postgres < "$ART/T4B_promotion_rollback_packet.sql" >"$TMP/rb.out" 2>&1; then
  ok "R1e rollback succeeds when no promotion exists"
else bad "R1e rollback failed on a clean install"; grep -E '^ERROR' "$TMP/rb.out" | head -2; fi
Q_TRADES="select (to_regclass('public.trades') is not null)::text"
assert_eq "$(psql_val postgres "$Q_TRADES")" "true" \
  "R1f the rollback never touched public.trades"
assert_eq "$(psql_val postgres "$Q_COL")" "false" \
  "R1g the rollback removed the incarnation column"
assert_eq "$(psql_val postgres "select (to_regclass('public.mt5_trades_promotion_uk') is null)::text")" "true" \
  "R1h the rollback removed the incarnation index"

# ------------------------------------------------------------------------------------------------
# R2 ROLLBACK -> REAPPLY. Revision 2 flagged the ledger rows 'rolled_back' and left them in place,
# so the documented reapply died on the version primary key and took the apply transaction with it.
# ------------------------------------------------------------------------------------------------
echo "== R2 rollback then reapply =="
assert_eq "$(psql_val postgres "select count(*) from public.mt5_schema_migrations where version like 'mt5_t4b%'")" "0" \
  "R2a the rollback REMOVED both ledger rows (matching S1/S1.1/T2/T4A)"
# R2b — the shape, not "can the app still insert?". The column grants T4B leaves behind keep
# ordinary writes working even when the table-level privilege was never restored, so a
# has_column_privilege probe on `raw` passes against a rollback that restored nothing at all.
#
# The baseline comes from a REFERENCE database carrying the same substrate and bootstrap and
# NEITHER T4B packet. Reading it from `postgres` would be too late: the narrowing has run there.
new_db probe_aclref >/dev/null 2>&1
for f in $CHAIN_PRE T4B_offline_bootstrap.sql; do
  psql_marked probe_aclref < "$ART/$f" >/dev/null 2>&1
done
ACL_BEFORE=$(psql_val probe_aclref "$Q_WRITE_ACL")
assert_eq "$(echo "$ACL_BEFORE" | grep -c 't4b_app_writer')" "1" \
  "R2b0 the reference baseline is non-trivial (table grants + a grant-option holder)"
assert_eq "$(psql_val postgres "$Q_WRITE_ACL")" "$ACL_BEFORE" \
  "R2b the rollback restored the EXACT pre-T4B INSERT/UPDATE ACL (grantees, scope, grant options)"
assert_eq "$(psql_val postgres "select (has_table_privilege('authenticated','public.trades','INSERT') and has_table_privilege('authenticated','public.trades','UPDATE'))::text")" "true" \
  "R2b1 authenticated holds TABLE-level INSERT and UPDATE again, not just column grants"
assert_eq "$(psql_val postgres "select count(*) from pg_class c, lateral aclexplode(c.relacl) x where c.oid='public.trades'::regclass and x.grantee=(select oid from pg_roles where rolname='t4b_app_writer') and x.privilege_type='INSERT' and x.is_grantable")" "1" \
  "R2b2 the WITH GRANT OPTION holder got its grant option back, not a plain grant"
assert_eq "$(psql_val postgres "select count(*) from pg_attribute a, lateral aclexplode(a.attacl) x where a.attrelid='public.trades'::regclass and a.attnum>0 and not a.attisdropped and x.privilege_type in ('INSERT','UPDATE') and x.grantee<>(select relowner from pg_class where oid='public.trades'::regclass) and not (x.grantee=(select oid from pg_roles where rolname='t4b_app_writer') and x.privilege_type='UPDATE' and a.attname='raw')")" "0" \
  "R2b3 T4B's own column grants are gone; only the column grant that PREDATED T4B survives"
assert_eq "$(psql_val postgres "select count(*) from information_schema.columns where table_schema='public' and table_name='trades' and column_name='mt5_promotion_id'")" "0" \
  "R2b4 no grant mentions the dropped marker column"
# The consequence that a column-grant residue hides: a column added AFTER the rollback must be
# writable by the app, because the app holds the privilege at TABLE level again.
psql_do postgres "alter table public.trades add column t4b_future_col text"
assert_eq "$(psql_val postgres "select has_column_privilege('authenticated','public.trades','t4b_future_col','INSERT')::text")" "true" \
  "R2b5 a column added AFTER the rollback is writable — the table-level privilege really is back"
psql_do postgres "alter table public.trades drop column t4b_future_col"

if { echo "$MARKER_SET"; cat "$ART/T4B_promotion_schema_packet.sql"; } | psql_file postgres >"$TMP/re1.out" 2>&1 \
   && psql_file postgres < "$ART/T4B_promotion_rpc_packet.sql" >"$TMP/re2.out" 2>&1; then
  ok "R2c both packets REAPPLY cleanly after a rollback"
else
  bad "R2c reapply failed"; grep -E '^ERROR' "$TMP/re1.out" "$TMP/re2.out" | head -3
fi
verifier_expect postgres PASS "R2d the reapplied install passes the security verifier"
assert_eq "$(psql_val postgres "select count(*) from public.mt5_schema_migrations where version like 'mt5_t4b%' and status='applied'")" "2" \
  "R2e both ledger rows are applied again"

echo
echo "================ T4B PROBES: $PASS_N pass, $FAIL_N fail ================"
[ "$FAIL_N" -eq 0 ] || exit 1
