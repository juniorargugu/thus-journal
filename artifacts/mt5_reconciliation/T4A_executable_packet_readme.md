# T4A Executable Packets — Human Decision Foundation (v1, packet-boundary revision)

Implements the approved T4 HUMAN DECISION CONTRACT Revision 3. **Production apply is NOT
authorized by T4A-0** — these packets are verified offline only, in a disposable PostgreSQL.

## Files (15 in T4A-0 scope — count derived from `git status --untracked-files=all`, each listed once)

| file | role |
|---|---|
| `T4A_executable_packet_readme.md` | this file |
| `T4A_decisions_schema_packet.sql` | `mt5_capture_decisions` + immutability guard + RLS/grants (packet revision 1) |
| `T4A_decisions_rpc_packet.sql` | T3 policy helpers + decision RPC + pending read RPC + grants + **embedded parity fragment** (packet revision 2) |
| `T4A_t3_kind_fixture_v1.generated.sql` | GENERATED standalone copy of the parity fragment — review / optional post-apply re-run only, **not** the release step |
| `T4A_security_verification_packet.sql` | standalone RE-RUNNABLE read-only security-surface verifier (raw ACLs, RLS, owners, search_path) |
| `T4A_decisions_verification_packet.sql` | offline behavior test matrix S3–S13 (guarded: refuses without the offline GUC) |
| `T4A_decisions_rollback_packet.sql` | full reversal; refuses if decision rows exist |
| `T4A_offline_bootstrap.sql` | disposable-DB substrate, verbatim from the committed S1 packets |
| `T4A_offline_probes.sh` | reproducible adversarial probes P1–P12 (atomicity, staleness, drift, concurrency) |
| `T4A_canary_acceptance_v1.md` | frozen T4A-2 production canary assertions |
| `../../ops/mt5_import/fixtures/t3_kind_fixtures_v1.json` | THE parity fixture (single authority) |
| `../../ops/mt5_import/fixtures/t4a_copy_contract_v1.json` | frozen bot acknowledgement semantics (executable — see its test) |
| `../../ops/mt5_import/gen_t4a_fixture_sql.py` | fixture → SQL fragment generator; `--check` verifies both copies, `--write` re-embeds |
| `../../ops/mt5_import/test_t3_kind_fixture.py` | Python parity suite (92 checks, incl. embedded-region byte parity + static race-branch pins) |
| `../../ops/mt5_import/test_t4a_copy_contract.py` | copy-contract validation vs committed `T3.ACTION_LABELS` (52 checks incl. 5 negative controls) |

## Atomic parity (the release contract)

The RPC packet transaction order is frozen:

```
begin -> preflight -> helpers -> decision RPC -> pending RPC -> grants/revokes
      -> EMBEDDED GENERATED PARITY FIXTURE (all 32 cases)
      -> postflight assertions -> migration-ledger insert -> commit
```

A parity failure aborts the whole packet: **no functions installed, no grants applied, no
ledger row**. There is no window where the RPC surface is live-and-recorded but unproven, and
no "run this separate generated file afterward" release step. Proven live by probe P1
(corrupted expectation → apply fails → zero rpc objects, zero rpc ledger row, schema ledger
row intact).

Structural parity chain: repository fixture (canonical `{version,cases}` digest, sha
`85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355`) → `gen_t4a_fixture_sql.py`
renders ONE fragment → byte-compared against BOTH the embedded region and the standalone
artifact (`--check`, and again inside `test_t3_kind_fixture.py`), plus a positional check that
the embedded region sits inside the transaction before the ledger insert. Hash literals are
audit metadata only. A stale embed is refused before release (probe P2).

## Frozen decisions carried by these packets

- **Evidence SQLSTATE `MT4E1`** — the only state the decision RPC translates
  (`ERR_DECISION_EVIDENCE_INVALID`). No `when others` anywhere; other faults escape as system
  failures.
- **Action matrix** — ENTRY {journal_add, already_logged, no_record}; CHANGE/ABSENCE
  {already_logged, no_record}; CONFLICT {no_record}; identical in Python and SQL, proven by the
  shared fixture at apply time.
- **RPC order** — args → lock+scope → existing decision (replay/conflict, NO policy
  recomputation) → derive kind → matrix → insert → ONE bounded race reselect.
- **Six-field result** — `o_ok, o_inserted, o_decision_id, o_existing_action, o_derived_kind,
  o_error_code`; `o_derived_kind` non-NULL only on fresh derivation (first insert /
  action-not-allowed); race outcomes shape-identical to their non-race equivalents.
- **Decision table** — UNIQUE(capture_event_id), NO user_id column (scope derives from the
  parent capture row), append-once trigger, executable source/provenance CHECK
  (`telegram`: chat+message NOT NULL, message > 0, chat sign unconstrained; `harness`: both
  NULL), `created_at` is THE decision instant.
- **Pending read** — one statement/one snapshot; exact 15-column capture object (T3 consumes it
  unchanged) + `pending_count` beside it; FIFO `(created_at asc, id asc)`; the RPC never skips
  an unrenderable head (head-of-line blocking is the bot's fail-closed incident).

## Uniqueness-race branch: DEFENSE-IN-DEPTH, UNREACHABLE UNDER THE SUPPORTED WRITE PATH

The decision RPC locks the parent capture row `FOR UPDATE` before reading existing decisions,
so **supported concurrent RPC writers serialize on that lock** and the second writer resolves
through the ordinary existing-decision branch. No production-supported call path is expected
to reach the `ON CONFLICT (capture_event_id) DO NOTHING` + bounded-reselect branch; it remains
so the RPC fails safely (replay / conflict / fail-closed `ERR_DECISION_RACE`) if those
assumptions ever change or a future internal path hits the uniqueness constraint differently.

What IS proven, honestly:

- **Supported concurrency, observed externally (probes P11/P12):** each writer runs under a
  unique per-run `application_name`; the probe resolves BOTH exact backend PIDs from
  `pg_stat_activity`, requires each writer's query to be the decision RPC against the SAME
  intended capture id, and asserts — with bounded polling, fail-closed on timeout — that
  `pg_blocking_pids(writer_B)` contains `writer_A` while A's transaction is open. P11:
  observed writer B blocked by writer A via `pg_blocking_pids()` while both targeted the same
  capture event; after A committed, B resolved as an idempotent same-action replay of A's
  decision id. P12: the same observed blocking relationship; after A committed, B resolved as
  `ERR_DECISION_CONFLICT` for the different terminal action, with A's decision id/action
  surfaced and A's provenance authoritative. Exactly one decision row each; first-writer
  provenance byte-checked untouched. No global lock counts are evidence; `wait_event_type` is
  logged diagnostically only (`Lock` observed — row-lock waits may surface as transactionid
  locks, so the internal lock mechanism is deliberately not asserted).
- **Static structural pins (test_t3_kind_fixture.py):** exactly one defensive ON CONFLICT
  insert, exactly one bounded race reselect (no loop), `ERR_DECISION_RACE` as the last resort,
  and the FOR UPDATE lock present.

Deliberately NOT claimed: runtime execution of the ON CONFLICT branch. Race-resolved outcomes
are shape-identical to their non-race equivalents by frozen design, so branch execution is not
observable from results, and no owner-level bypass is fabricated to force it.

## Security-surface verification (re-runnable, read-only)

`T4A_security_verification_packet.sql` runs inside a READ ONLY transaction ending in ROLLBACK
— zero mutations, safe immediately after apply or any time later. It reads the RAW ACLs
(`aclexplode(relacl)`, `pg_attribute.attacl`, `aclexplode(proacl)`) — where a PUBLIC grant is
grantee oid 0 and cannot hide — because `information_schema.role_table_grants` does not fully
represent PUBLIC-derived access (it still also checks
`information_schema.table_privileges` for the named app roles). Sections:

- SEC1 objects exist; table owned by `postgres` (exact role, the project apply convention)
- SEC2 RLS enabled, NOT forced (pinned reviewed state); exactly one policy
  `mt5_cd_service_read_v1` (permissive, SELECT, to service_role, USING true, no WITH CHECK)
- SEC3 table ACL grantees exactly {postgres, service_role}; service_role exactly {SELECT},
  not grantable; no PUBLIC/anon/authenticated (raw relacl + table_privileges)
- SEC4 exactly the 7 frozen columns; NO column-level ACL (`attacl` NULL everywhere)
- SEC5 exactly one trigger `mt5_capture_decision_no_mutate_v1` (BEFORE UPDATE/DELETE, ROW,
  enabled, guard function)
- SEC6 all six functions: exact identity, sole overload of their name, owner postgres,
  SECURITY DEFINER, pinned volatility (helpers immutable, decision RPC volatile, pending RPC
  stable, guard volatile), `proconfig` exactly `{search_path=""}` (the live catalog
  representation of `set search_path = ''`, pinned from inspection — not guessed)
- SEC7 function ACLs: proacl MATERIALIZED on all six (NULL would re-grant PUBLIC EXECUTE);
  RPCs exactly {postgres, service_role}/EXECUTE; helpers+guard exactly {postgres};
  `has_function_privilege` proves anon/authenticated FALSE on all six (direct or
  PUBLIC-derived), service_role TRUE on exactly the two RPCs
- SEC8 ledger rows for both versions with the exact packet identity tokens (schema rev-1
  `66cbfaad…`, rpc rev-2 `3f4fbed1…`) and the UPPERCASE fixture digest

Drift detection proven live by probes P3–P10 (each drift → verifier FAIL in the right
section → revert → PASS).

## Index decision (with evidence)

No new index. Offline EXPLAIN at 2,000 captures / 1,000 decisions for one user (postgres:17):
hash anti-join over seq scans, **Execution Time ≈ 1.0 ms** (planning 0.2 ms). The anti-join
probe is served by `mt5_cd_capture_uk`. The candidate `mt5_capture_events(user_id, created_at,
id)` is recorded for re-evaluation with fresh EXPLAIN evidence before any volume jump.

## Offline verification procedure (docker, postgres:17 — matches Supabase's current major line)

```bash
docker run -d --name t4a_pg -e POSTGRES_PASSWORD=t4a postgres:17
docker exec t4a_pg psql -U postgres -c \
  "create role anon nologin; create role authenticated nologin; create role service_role nologin;"
docker exec t4a_pg psql -U postgres -c \
  "create schema extensions; create extension pgcrypto with schema extensions;"
# then, each with: docker exec -i t4a_pg psql -U postgres -v ON_ERROR_STOP=1 -q < FILE
#   1) T4A_offline_bootstrap.sql
#   2) T2_capture_events_schema_packet.sql
#   3) T2_capture_events_rpc_packet.sql
#   4) T4A_decisions_schema_packet.sql
#   5) T4A_decisions_rpc_packet.sql            # embedded parity runs INSIDE, pre-commit
#   6) T4A_security_verification_packet.sql    # re-runnable, read-only
#   7) -c "set t4a.offline_verify_ok = '1';" -f T4A_decisions_verification_packet.sql
#   8) T4A_security_verification_packet.sql    # again — proves re-runnability on a used DB
#   9) (optional) T4A_t3_kind_fixture_v1.generated.sql   # standalone review re-run
# and the reproducible adversarial matrix (own container t4a_probe_pg):
#   bash T4A_offline_probes.sh
```

Verified results in this round (2026-08-25, PostgreSQL 17.11):

- clean chain: steps 1–9 ALL PASS — the embedded parity notice (`22 valid + 10 invalid cases
  PASS`) fires during the rpc-packet apply itself; security verifier PASSES immediately after
  apply AND after the mutating behavior packet (re-runnable, no mutations);
- behavior packet: **S3–S13 ALL PASS** (argument/source, scope, matrix rejects,
  evidence-invalid translation, 8-decision first-insert matrix, replay + immutable
  provenance, conflict, immutability guard, pending FIFO + advancement, id tiebreak,
  capture table untouched);
- probes: **P1–P12, 23/23 PASS** (atomic rollback; stale-embed refusal; eight drift probes
  each failing the right verifier section and reverting clean; supported-concurrency
  same-action and different-action, each with writer PIDs resolved from unique
  application_names and the blocking relationship asserted via `pg_blocking_pids(B) ∋ A`
  before the outcome assertions);
- Python/artifacts: t1 84, t2 quiet-window 128, adapter 176, t3 351, writer 623 (all
  untouched by T4A-0), fixture parity **92**, copy contract **52** (incl. 5 negative
  controls) — ALL PASS, env-scrubbed; both JSON artifacts parse; `--check` OK;
- rollback: refuses on a database holding decision rows ("durable workflow truth"); clean
  roundtrip on a scratch database (objects gone, both ledger rows removed — ledger version
  detection unchanged by the atomicity move, which only strengthens it: the rpc ledger row
  now exists ONLY after parity passed).

## Rollback

`T4A_decisions_rollback_packet.sql` reverses both packets. It REFUSES while decision rows
exist — deleting recorded decisions is a separate explicit human act (owner truncate) first.

## Parity maintenance rule (frozen)

Any change to T3 kind/action logic REQUIRES: fixture version bump → `gen_t4a_fixture_sql.py
--write` (regenerates the standalone artifact AND re-embeds the rpc-packet region) → rpc
packet revision bump + new identity token → `test_t3_kind_fixture.py` green → security
verifier SEC8 re-pin. Staleness in either copy is refused by `--check`, the Python suite, and
probe P2 — never waved through on a matching hash literal.
