# T4B executable packet readme

Journal promotion: fulfilling a durable T4A `journal_add` decision into exactly one canonical
Journal trade. **Nothing here has been applied to production.** Packet revision **6**.

## Artifacts and their safety class

| File | Class | Purpose |
|---|---|---|
| `T4B_promotion_schema_packet.sql` | **PRODUCTION-SAFE APPLY** | promotion ledger + guards + RLS/ACLs + the `trades` incarnation marker + ledger identity |
| `T4B_promotion_rpc_packet.sql` | **PRODUCTION-SAFE APPLY** | `mt5_promote_capture_decision_v1(uuid)` + three private helpers |
| `T4B_promotion_security_verification_packet.sql` | **READ-ONLY PRODUCTION VERIFIER** | `begin transaction read only … rollback`; SEC1–SEC12; rerunnable; seeds nothing |
| `T4B_promotion_verification_packet.sql` | **OFFLINE-ONLY SYNTHETIC** | seeds fixtures, runs the 205-check outcome matrix, `rollback` |
| `T4B_offline_bootstrap.sql` | **OFFLINE-ONLY SYNTHETIC** | the `trades` / `products` Journal substrate no MT5 packet creates |
| `T4B_promotion_rollback_packet.sql` | PRODUCTION-SAFE (conditional) | refuses while any durable promotion exists; never deletes or updates a trade |
| `T4B_packet_identity.py` | TOOLING | generates and verifies the canonical packet digests |
| `T4B_packet_manifest_v1.json` | GENERATED | the digests, recorded outside the packets |
| `T4B_offline_probes.sh` | OFFLINE HARNESS | docker `postgres:17`; 143 probes |
| `T4B_1_promotion_contract_v1.md` | CONTRACT | the frozen contract; also the packets' `source_artifact_sha256` |

Both OFFLINE-ONLY artifacts require **two independent conditions**: an explicit session marker the
operator has to type, and the absence of durable rows in *any* pipeline or Journal table. They
cannot be mistaken for the production verifier: only
`T4B_promotion_security_verification_packet.sql` opens a read-only transaction, and it is the only
one that runs without a marker.

## Pre-apply byte check (do this before pasting anything into a SQL editor)

```bash
python artifacts/mt5_reconciliation/T4B_packet_identity.py --check
```

This hashes the packet bytes **on disk** and compares them to the identity each packet records and
to the manifest. Only after `T4B PACKET IDENTITY: OK` should the file be pasted into the editor —
SQL cannot inspect the bytes of the file an operator is about to paste, so this is the step that
binds what was reviewed to what gets run.

## Run

```bash
psql -v ON_ERROR_STOP=1 \
     -c "SET t4b.offline_fixture = 'I_UNDERSTAND_DISPOSABLE';" \
     -f artifacts/mt5_reconciliation/T4B_offline_bootstrap.sql      # disposable DB only

bash artifacts/mt5_reconciliation/T4B_offline_probes.sh             # 143 probes
docker rm -f t4b_probe_pg                                           # cleanup
```

Latest run: **143/143 probes pass**, with the embedded verification matrix reporting
**205/205 checks pass** and the security verifier reporting **ALL SECTIONS PASS**.

## Apply order (offline)

```
T4A_offline_bootstrap.sql            # ledger, mt5_sync_runs, mt5_sync_run_positions, sha helper
T2_capture_events_schema_packet.sql
T2_capture_events_rpc_packet.sql
T4A_decisions_schema_packet.sql
T4A_decisions_rpc_packet.sql
T4B_offline_bootstrap.sql            # public.trades + public.products substrate  [marker required]
T4B_promotion_schema_packet.sql
T4B_promotion_rpc_packet.sql
```

Production apply order would be the last two only — the rest is already installed. **Not authorized
by T4B-1.**

## Migration identities

| version | objects |
|---|---|
| `mt5_t4b_promotion_schema_v1` | `mt5_capture_promotions`, `trades.mt5_promotion_id`, `mt5_trades_promotion_uk`, 2 guard triggers + functions |
| `mt5_t4b_promotion_rpc_v1` | `mt5_promote_capture_decision_v1(uuid)`, `mt5_t4b_map_product_v1`, `mt5_t4b_validate_fulfillment_v1`, `mt5_t4b_freshness_window_v1` |

`checksum` is the **canonical packet digest** — sha256 over the packet's LF-normalised bytes with
its own digest slot normalised to 64 zeros, so it covers every byte except the slot that holds it.
`source_artifact_sha256` is the sha256 of `T4B_1_promotion_contract_v1.md`. Revision 1 recorded
`sha256('<version>|packet-revision-1')`, a restatement of the version string under which the SQL
could change freely, and carried an unrelated T3 fixture digest as its source artifact.

## What the probes prove, and what they deliberately do not

**Proven:** clean apply; the security verifier detects all twenty-six injected drifts — including a
same-named unique constraint over the *wrong columns*, a same-named FK with a *different column
mapping*, a same-named index with a *different predicate*, a same-named trigger backed by a *no-op
function*, a malicious `search_path` that still "contains `search_path=`", a changed volatility, and
an *arbitrary* role nobody wrote a denylist rule for, a function BODY swapped with every metadata
property preserved, a *required* grant silently revoked, and an arbitrary but well-formed ledger
hash, a required digest key SUBSTITUTED for an unrelated function so the total still reads six,
and a same-named overload deployed beside the real function — and returns to PASS on revert; an authenticated owner who reads their own incarnation marker,
deletes the promoted trade and re-inserts the same tuple is stopped by the column privilege while
ordinary app writes keep working; rollback removes the ledger rows, restores the EXACT pre-T4B
write ACL of `public.trades` (grantees, scope and grant options, compared against a reference
database that never saw T4B), and both packets reapply cleanly;
mutating one
byte of executable SQL while holding version and revision constant fails `--check`; a deployed
object drifting while the ledger row stays byte-identical fails the verifier; the offline bootstrap
refuses without a marker and refuses *even with one* on a database holding real S1 evidence; a
failure after the ledger insert leaves **neither** row; two transactions promoting the same decision
serialize with writer B **proven blocked by** writer A via `pg_blocking_pids` on exact backend PIDs,
ending with one trade and one promotion, and the same for two *different* decisions naming the same
durable MT5 position; **a caller that enters while the evidence is fresh and then blocks on a real
T4B lock past the window is refused** — the one test that separates `clock_timestamp()` from
transaction-start time, with a control proving the same call promotes without the wait; the rollback
refuses while a promotion exists and never touches a trade.

**Not claimed:** that the `mt5_cp_decision_uk` and `mt5_cp_position_uk` branches of the
`unique_violation` handler ever execute. Under the supported serialization they are unreachable **by
construction** — the loser always blocks on the advisory lock, and re-reads only after the winner
commits, so it takes the normal path every time. That is a proof about the locking, not a coverage
gap, and the branches are retained as fail-closed backstops so a future caller that bypasses the
locks, or a manual ledger write, cannot leak a raw SQLSTATE in place of the frozen contract. The
branches that *are* reachable — `mt5_cp_trade_uk`, and the unknown-constraint re-raise — are
executed for real in matrix sections I1–I5.

**Also not claimed:** anything about production. No production database was contacted at any point
in T4B-1.

## Notes for the reviewer

* Trade ids are `mt5p_<32 lowercase uuid hex>`, derived from the decision id. The browser's
  generator emits decimal digits only, so the namespaces are disjoint by construction — there is no
  millisecond at which they can meet.
* `trades.id` is **text**, established twice: a non-numeric PostgREST filter returns rows rather
  than `22P02`, and the applied migration `20260705_g2_trade_group_rpcs.sql` carries the same hard
  precondition in its own preflight.
* `trades.mt5_promotion_id` survives ordinary browser saves for the same reason `trades.group_id`
  already does: `toTradeRow` never emits it, and a column absent from an upsert's SET list keeps its
  stored value. `db.loadAll` rehydrates from `raw`, so it never enters the app's trade object.
* The marker is unforgeable because it is **not in any client role's writable column set** — the
  guard trigger alone could not do it, since a re-inserted `(id, user_id, marker)` tuple genuinely
  matches its ledger row. T4B narrows the Journal's writer surface by exactly this one column;
  `SELECT`, `DELETE` and the RLS policies are untouched, and the rollback restores the table-level
  grants from a snapshot the apply recorded — it cannot rediscover them, because the apply revoked
  exactly the catalog entries a rediscovery would read.
* The narrowing merges the table and column surfaces per (grantee, privilege, column) **before**
  revoking anything, because a table-level `REVOKE` also drops that grantee's matching column
  privileges. Re-granting from the table entry's grant option alone would flatten away an option
  carried only by a column entry — narrowing more than the marker.
* That narrowing is scoped to an **owner-granted** write surface. An exercised grant option shows up
  in the catalog as a non-owner grantor; PostgreSQL will not let such a grant be revoked, and no
  packet running as the owner can rebuild the chain. Apply and rollback both refuse, naming the
  entries. The snapshot identifies grantees by **role OID**, so a rename restores correctly and a
  drop-and-recreate under the same name is reported as non-restorable rather than handing the
  replacement somebody else's privileges.
* `entry_date` / `exit_date` / `note` are written **NULL** because they are NULL in 155/155
  production rows: `toTradeRow` maps them from `t.entryDate` / `t.exitDate` / `t.note`, keys no
  trade object has ever carried.
* The promotion ledger has **no foreign key to `trades`**, on purpose. See the schema packet header.
* The ledger — not `raw.mt5PositionId` — is the authoritative S2 attachment map. An ordinary edit
  rewrites `raw` through the 19-key `buildTrade` shape and drops the extra key; matrix checks
  B9–B12 demonstrate exactly that and show the ledger still resolving the trade.
