# MT5 S1 Append-Only Executable Packet — README

**Status:** `EXECUTABLE DRAFT — NOT APPLIED TO PRODUCTION`. No production SQL was applied, no production RPC invoked,
no production Supabase write, no MT5 writer run, no schedule, no deploy. The packet **has** been executed once against a
disposable local Supabase database; that run **failed at the schema stage** and is recorded under
"Runtime execution record" below.
**Contract source (frozen):** `S1_append_only_snapshot_membership_design.md` — Revision 3 · SHA-256
`9902B301B3E170A7FD5AA348C9892395CEBEE129DF1B5F63FAB9F62D53CA266D` (33,189 B / 500 lines). Every SQL file records this
source hash in its migration-ledger row.
**Branch / base:** `work/mt5-s1-snapshot-lifecycle` off `origin/main = f37a0ef` (clean worktree
`C:\Users\Junior\Desktop\thus-journal-mt5-s1`).

## Files

| File | Purpose | Ledger version |
|---|---|---|
| `S1_append_only_snapshot_membership_design.md` | frozen rev-3 relational contract (copied verbatim) | — |
| `S1_test_preflight_packet.sql` | **TEST-ONLY** independent pre-migration evidence capture (fixture 25 input) | — |
| `S1_schema_packet.sql` | transactional schema + Phase-0A privilege narrowing | `mt5_s1_append_only_schema_v1` |
| `S1_rpc_packet.sql` | 8 connector RPCs + 1 browser RPC + 3 internal helpers | `mt5_s1_append_only_rpc_v1` |
| `S1_verification_packet.sql` | **28** numbered fixtures in **25** rollback-wrapped blocks (executable, **NOT RUN**) | — |
| `S1_rollback_packet.sql` | ledger-guarded, provenance-verified transactional revert | — |
| `S1_executable_packet_readme.md` | this file | — |

### Exact disposable-DB execution order

| # | File | Required? | Notes |
|---|---|---|---|
| 1 | `S1_test_preflight_packet.sql` | **required before the schema packet** *(disposable DB only)* | Seeds representative staging rows and records an INDEPENDENT pre-migration evidence observation into `public.mt5_s1_test_pre_evidence`. Fixture 25 **hard-fails** if this step was skipped, so it cannot be silently omitted. It refuses to run if S1 objects already exist. **Never run this against production.** |
| 2 | `S1_schema_packet.sql` | required | Preflight → DDL → privilege narrowing → postflight → ledger row last. |
| 3 | `S1_rpc_packet.sql` | required | Preflight refuses to run unless the schema ledger row exists with the exact recorded checksum + source hash. |
| 4 | `S1_verification_packet.sql` | required | One transaction ending in `ROLLBACK`; must reach the final PASS notice. |
| 5 | `S1_rollback_packet.sql` | optional | Only to exercise the revert path; see the rollback matrix below. |

**Production apply order** omits step 1 entirely (it is test-only) and is: schema packet → RPC packet → approval →
post-migration verification. A production apply happens only after a disposable-DB run has actually passed.

## Migration ledger & exact-definition strategy

`public.mt5_schema_migrations` (version PK, description, checksum, `source_artifact_sha256`, status, `objects` jsonb,
`applied_at`, `applied_by`). It is **created before it is queried**, records **separate** schema/RPC versions, and each
packet **records success only at the very end** (the ledger `insert ... 'applied'` is the last statement before
`commit`). Compatibility is proven by **catalog-definition checks (not name/substring markers)** — column
names+types+nullability, the exact Phase-0A open-position partial-unique predicate, object ownership, grant privilege
sets, function `prosecdef`/owner/`search_path`, and exact function signatures.

**Pre-existing ledger policy (fail-closed, three outcomes):**

1. **absent** → S1 creates the exact ledger definition and records `ledger_created_by_s1: true`.
2. **present and exactly compatible** → reused **without any mutation of its provenance**. Compatibility is validated in
   full *before* anything is written: exact column set (names/types/nullability + exact column count), the `objects` and
   `applied_by` default expressions, `PRIMARY KEY (version)`, all five CHECK constraints **by name and by
   `pg_get_constraintdef`**, the absence of any additional constraint, postgres ownership, and a privilege state already
   equal to S1's target (`service_role` SELECT only; nothing for anon/authenticated/PUBLIC).
3. **present and different in any of the above** → **STOP before mutation.** S1 never "repairs" a foreign ledger into
   its own shape and never re-owns or re-privileges an object it did not create.

Because outcome 2 proves the owner/ACL already match, the static `ALTER … OWNER` / `REVOKE` / `GRANT` statements that
follow the preflight are no-ops for a pre-existing ledger. Rollback reads `ledger_created_by_s1` and drops the ledger
table only when S1 created it and it is now empty.

- staging column names+types+nullability (`information_schema.columns`), the exact Phase-0A open-position partial-unique
  predicate (`pg_get_expr(indpred)`), absence of `last_seen_run_id`/lifecycle columns, absence of pre-existing S1 run
  tables, and — if the ledger pre-exists — its exact column shape.
- RPC preflight re-verifies the schema ledger row's exact checksum + source hash and that no S1 function name pre-exists.
- Postflights assert table ownership (`postgres`), zero application write grants on the run tables, zero `service_role`
  lifecycle-column UPDATE, function `prosecdef` + owner + `search_path=""`, all 9 exact function signatures present, and
  that staging row-count + a non-lifecycle-column checksum are unchanged across the migration.

## Schema summary

- **`mt5_sync_runs`** — uuid `id`; `(user_id, source_account)` scope; immutable `captured_at`; three dimensions
  `snapshot_status`/`reconcile_status`/`snapshot_health`; `run_seq`; `previous_positions_count`/`positions_count`;
  `position_ids_hash` + **`manifest_hash`** (full-payload aggregate); sealed `policy_version`/`policy_thresholds`;
  DB-time lease trio; audit timestamps; `warning_code`/`error_code`. Constraints: `UNIQUE (id,user_id,source_account)`
  (composite-FK target), one-active-cycle partial unique index, `run_seq` per-account unique, complete/failed/reconcile
  shape biconditionals, warning↔suspicious binding, active-state lease-non-null, hex-hash format. Indexes:
  latest-complete + healthy-history (both `run_seq DESC`, partial). RPC-only writes; `service_role` read-only SELECT;
  authenticated **no direct grant**.
- **`mt5_sync_run_positions`** — immutable facts `run_id,user_id,source_account,position_id,symbol_raw,side,volume,
  price_open,price_current,profit,open_time_utc,source_time_msc,contract_size,captured_at,row_fingerprint,created_at`;
  `PRIMARY KEY (run_id,position_id)`; **composite scope FK** `(run_id,user_id,source_account)→mt5_sync_runs
  (id,user_id,source_account) ON DELETE RESTRICT`; non-blank symbol/account, `side ∈ {buy,sell}`, `volume>0 AND <>NaN`,
  nullable numerics NULL-distinct-from-zero and `<>NaN`, `row_fingerprint` sha256-hex NOT NULL. **Immutability triggers:**
  `BEFORE UPDATE OR DELETE → raise`; `BEFORE INSERT → reject unless target run is 'started' AND row.captured_at =
  run.captured_at`. No UPDATE/DELETE grant to any role; INSERT only via the append RPC.
- **`mt5_import_staging`** — adds only `lifecycle_updated_at`, `missing_since_run_id` (composite-scope FK,
  `ON DELETE RESTRICT`); tolerant `position_state` S1 CHECK (`NOT VALID`); lifecycle + missing-since indexes. **No
  `last_seen_run_id`.**

## RPC inventory & exact signatures

| # | Function → returns |
|---|---|
| 1 | `mt5_create_run_v1(uuid,uuid,text,uuid,integer,timestamptz,text,integer,text,text)` → `(o_ok,o_run_id,o_lease_expires_at,o_error_code)` |
| 2 | `mt5_heartbeat_run_v1(uuid,uuid,text,uuid,integer)` → `(o_ok,o_lease_expires_at,o_error_code)` |
| 3 | `mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)` → `(o_ok,o_inserted,o_error_code)` |
| 4 | `mt5_complete_snapshot_v1(uuid,uuid,text,uuid,integer,bigint[])` → `(o_ok,o_run_seq,o_snapshot_health,o_error_code)` |
| 5 | `mt5_reconcile_snapshot_v1(uuid,uuid,text,uuid)` → `(o_ok,o_still_open,o_missing_once,o_not_open_confirmed,o_conflicts,o_error_code)` |
| 6 | `mt5_mark_snapshot_failed_v1(uuid,uuid,text,uuid,text)` → `(o_ok,o_error_code)` |
| 7 | `mt5_mark_reconcile_failed_v1(uuid,uuid,text,uuid,text)` → `(o_ok,o_error_code)` |
| 8 | `mt5_expire_stale_run_v1(uuid,uuid,text)` → `(o_ok,o_error_code)` |
| 9 | `mt5_get_current_snapshot_v1(text)` → `jsonb` (browser read) |
| — | helpers `mt5_s1_policy_v1(text)`, `mt5_sha256_text_v1(text)`, `mt5_position_fingerprint_v1(...)` — postgres-only, no grant |

All `SECURITY DEFINER`, `set search_path=''`, owner `postgres`, no dynamic SQL, allowlist `{mt5_sync_runs,
mt5_sync_run_positions, mt5_import_staging}` (no Journal/product/Portfolio writes). Connector RPCs 1–8 EXECUTE →
`service_role` only; the read RPC 9 EXECUTE → `authenticated` only. Shared existing-run protocol: reject null → fetch by
`run_id` → advisory-lock on **stored** identity → re-fetch `FOR UPDATE` → `IS DISTINCT FROM` identity → terminal-state
precedence → DB-time lease → act. Identical lock key `hashtextextended(user||':'||account,0)` everywhere; every column
table-aliased; `o_`-prefixed result columns.

## Read-RPC response contract

`mt5_get_current_snapshot_v1(source_account)` returns a single JSONB envelope: `{ok, error_code, freshness_state,
snapshot:{run_id, source_account, snapshot_status, reconcile_status, snapshot_health, snapshot_completed_at,
positions_count, warning_code, freshness_state}, positions:[{position_id, symbol_raw, side, volume, price_open,
price_current, profit, open_time_utc, source_time_msc, contract_size, captured_at}]}`. Identity from `auth.uid()` (no
caller `user_id`); latest completed observation by `run_seq DESC` then health+freshness (`clock_timestamp() -
captured_at` vs sealed `freshness_seconds`); **positions only when healthy+fresh**; `freshness_state` ∈ `fresh /
suspicious / stale / no_snapshot`; **no** lease/hashes/raw errors/policy internals/terminal internals exposed. Never
falls back to staging `kind='open'`.

## Phase-0A staging privilege matrix (before → after) — derived from the real writer

Ground truth: `ops/mt5_import/writer.py` `PATCH_ALLOWLIST = ("last_seen_open_at","price","volume","mt5_time",
"mt5_time_msc","mt5_time_raw_epoch")` — the exact 6 columns the writer ever PATCHes (UPDATEs). The mapper
`ops/mt5_import/build_rows.py` supplies `"position_state":"open"` on the initial **INSERT** of a new open row, but the
writer **never UPDATEs `position_state`** (it is not in `PATCH_ALLOWLIST`). Therefore S1 keeps `service_role` **INSERT**
on `position_state` (initial value only) and **denies UPDATE** on it and the two new lifecycle columns — this is exact,
derived from the real writer, and cannot break ingestion.

| Grant on `mt5_import_staging` to `service_role` | Before (Phase 0A) | After (S1) |
|---|---|---|
| INSERT | all columns (broad) | column-scoped: the 40 non-`id/created_at/updated_at` columns (incl. initial `position_state`) |
| UPDATE | **all columns (broad)** | **only** `last_seen_open_at, price, volume, mt5_time, mt5_time_msc, mt5_time_raw_epoch` |
| UPDATE `position_state` / `lifecycle_updated_at` / `missing_since_run_id` | allowed (broad) | **DENIED** — lifecycle writes only via `mt5_reconcile_snapshot_v1` (definer) |
| DELETE | none | none |
| Browser (`authenticated`) lifecycle writes | none | none |

The rollback packet restores the broad Phase-0A `INSERT, UPDATE` grant. The existing 0A workflow RPCs
(`mt5_confirm_group`, etc.) are `SECURITY DEFINER` and run as `postgres`, so the UPDATE narrowing does not affect them.

## Key implementation notes (mapped to rev-3)

- **Append/seal atomicity** — append is insert-only under the shared lock; **terminal-state precedence before lease**
  (`complete→ERR_RUN_SEALED`, `failed→ERR_RUN_FAILED`, then lease); field-by-field replay via `IS DISTINCT FROM`
  (any diff, incl. NULL↔value → `ERR_POSITION_CONFLICT`); `captured_at` stamped from the run (and re-checked by the
  INSERT trigger); bounded payload (≤10k rows / ≤8 MB). Completion recomputes the ID set/count/`manifest_hash` from the
  **stored children** (client count/hash never trusted), checks scope + child-fingerprint integrity, allocates `run_seq`
  under the lock, and re-verifies all sealed evidence on replay (`ERR_REPLAY_CONFLICT`).
- **Captured-at supersession** — completion compares the run's immutable `captured_at` with the latest completed
  observation under the lock; older-or-equal → `ERR_SUPERSEDED` (never gets `run_seq`/current status).
- **Consecutive-absence K** — a set-wise CTE computes `last_present_seq` from **actual `mt5_sync_run_positions`
  membership** across eligible healthy completed runs, and `streak = count(eligible absent with run_seq >
  last_present_seq)`. A later membership presence resets the streak **even if that run's reconcile failed** (H1/H2/H3,
  fixture 15). K comes only from the run's sealed policy. Single original-state CASE (no conflict-then-promote).
- **Lifecycle** — reconcile mutates only staging `position_state`/`lifecycle_updated_at`/`missing_since_run_id`; suspicious
  runs mutate zero rows; grouped/materialized/dismissed open rows remain eligible; a duplicate open identity →
  `ERR_STAGING_INVARIANT`; a baseline pointing at a non-healthy-complete run → `ERR_BASELINE_INVALID`.

## Verification fixtures (executable, NOT RUN)

**28 numbered fixtures in 25 executable blocks** in `S1_verification_packet.sql`, one transaction ending in `ROLLBACK`,
unique account per fixture. (Blocks `$f12$`, `$f15$` and `$f21$` each assert two or three numbered fixtures; `$f18$` is a
notice pointing at the assertion made inside fixture 3.) Fixture 25 additionally requires
`S1_test_preflight_packet.sql` to have run first.
1 partial-B-preserves-A · 2 failed-B-preserves-A · 3 suspicious-B (stale context + zero lifecycle mutation) · 4 healthy-C
atomic replace · 5 delayed-older-capture `ERR_SUPERSEDED` · 6 `ERR_RUN_ACTIVE` · 7 exact append replay · 8
`ERR_POSITION_CONFLICT` (value + NULL↔value) · 9 append-after-seal `ERR_RUN_SEALED` before lease · 10 immutable
UPDATE/DELETE denied · 11 valid zero · 12/13 completion replay success + conflict · 14 cross-account append denied ·
15/16 H1/H2/H3 consecutive absence + one credit · 17 conflict-not-promoted · 18 suspicious zero-mutation (via 3) · 19
previous-count-ignores-suspicious · 20 freshness-uses-captured_at · 21/22 healthy-empty + stale/suspicious no trusted
positions (via 11/3/20) · 23 direct authenticated table reads denied · 24 ingestion cannot write lifecycle columns
(value columns still writable) · 25 staging additions minimal / `last_seen_run_id` never exists / **ledger provenance ==
independent pre-migration observation** / lifecycle-only mutation leaves evidence invariant · 26 expiry only on
DB-time-expired lease (started→failed **and** complete+pending→reconcile-failed) · **27 append payload containment: SQL
NULL, wrong JSON type, array-of-non-objects and malformed row casts all → exact `ERR_BAD_PAYLOAD`, identity faults still
→ `ERR_BAD_INPUT`, valid empty array still succeeds** · **28 NULL and non-allowlisted reason codes on both failure RPCs →
exact `ERR_BAD_INPUT`, run left untouched**.

**Assertion style:** every expected-error fixture asserts **both** `o_ok IS DISTINCT FROM false` **and**
`o_error_code IS DISTINCT FROM '<exact code>'`. Plain `<>` is not used for error assertions anywhere, because a NULL
`o_error_code` (i.e. an erroneous success) satisfies neither branch of `<>` and would pass silently. Success assertions
are likewise `r.o_ok IS DISTINCT FROM true` rather than `NOT r.o_ok`, which had the same NULL-passes flaw. Every fixture
that reads a row asserts existence (`IF NOT FOUND`) before comparing.

**STATIC REVIEW vs EXECUTED DB VERIFICATION — these are different things.** Everything claimed in this README is the
result of **static review only**. **0 fixtures have been executed.** All 28 are drafted and marked
executable-but-NOT-RUN; they require a disposable Postgres with the test preflight + schema + RPC packets applied, and
are approval-gated. **No statement in this repository may be read as evidence that these fixtures pass.**

## Rollback summary

Two governing rules, both enforced before any destructive statement runs:

> **ROLLBACK MAY REMOVE OR RESTORE ONLY STATE IT CAN PROVE S1 OWNS.**
> **ROLLBACK MUST RESTORE PRE-S1 PRIVILEGES EXACTLY.**

### Packet identity vs deployed-object proof (honest limitation)

The database cannot read the `.sql` files, so **nothing in these packets verifies packet file bytes**, and no
self-referential "file SHA" is fabricated to imply otherwise.

| Kind | What it is | What it proves |
|---|---|---|
| `checksum` | a **deterministic packet revision token**: `sha256('<ledger version>\|packet-revision-5')` | *which packet revision* wrote the row, and that the schema/RPC/rollback packets belong to the same revision — **nothing** about file bytes or deployed objects |
| `source_artifact_sha256` | SHA-256 of the **frozen design document's** bytes (a static committed `.md`) | which contract revision the packet was written against; verifiable outside the DB, but still a statement about the design doc, not about deployed objects |
| `objects->'provenance'` fingerprints | **apply-time catalog fingerprints**, computed from the objects that actually exist after creation | that a surviving object is byte-for-byte the definition S1 created |

**Destructive authority is the fingerprints, not the checksums.** The checksum guard only establishes *which* migration
this rollback belongs to; every DROP is gated on a recomputed fingerprint match. Under the current manual SQL-Editor
execution model an exact full-file SHA could not be made trustworthy without an external runner, so it is deliberately
not claimed. **This limitation is raised explicitly for reviewer acceptance.**

**Why the `checksum` column is not a file hash (round 4; tokens re-derived in round 5).** The ledger's `checksum` CHECK requires 64 lowercase hex, so
the value keeps that shape — but it is now an explicitly derived revision token, not a pretend file digest:

| Ledger version | Token preimage | Value |
|---|---|---|
| `mt5_s1_append_only_schema_v1` | `mt5_s1_append_only_schema_v1\|packet-revision-5` | `7cd1e978…a948139b` |
| `mt5_s1_append_only_rpc_v1` | `mt5_s1_append_only_rpc_v1\|packet-revision-5` | `65a21a63…5953c835` |

Anyone can reproduce these from the literal preimage strings. The packets also record `objects->'packet_revision' = 5`,
and the rollback requires it. Earlier revisions carried an unchanged constant across three correction rounds, so a
revision-3-era ledger row was indistinguishable from this one; that ambiguity is now closed. Nothing has been applied to
any database, so no historical ledger row exists to migrate.

### Apply-time provenance recorded (rollback authority)

| Object class | Fingerprint inputs |
|---|---|
| tables (`mt5_sync_runs`, `mt5_sync_run_positions`) | owner + columns (name, type, notnull, default, identity, generated) + all constraints (name + `pg_get_constraintdef`) + all indexes (`pg_get_indexdef`). **ACLs excluded on purpose**, so privilege restoration cannot destabilise structural identity. |
| functions (12 RPC/helpers + the trigger guard) | `pg_get_functiondef` (**includes the body**) + owner + `prosecdef` + `proconfig` |
| triggers (both immutability triggers) | `pg_get_triggerdef` + `tgenabled` |
| policies (both service-read policies) | name + command + permissive + roles + `USING` + `WITH CHECK` |
| staging annotations (2 indexes, 2 constraints) | `pg_get_indexdef` / `pg_get_constraintdef` — these are dropped **by name** from a pre-existing table, so a same-named foreign object must not be destroyed |
| staging **columns** (`lifecycle_updated_at`, `missing_since_run_id`) | table identity + column name + `format_type` + notnull + default expression + `attidentity` + `attgenerated` — these are also dropped **by name** from a pre-existing table (round-4 addition) |
| staging column grants | the column ACLs S1 installed, read back from `pg_attribute` — **not** a hardcoded column list. Stored at `objects->'provenance'->'staging_col_grants'`; rollback reads that exact nesting |
| migration ledger itself | structural fingerprint (owner + columns + constraints + indexes, ACL-free) of `mt5_schema_migrations`, so rollback can verify the table it draws authority from is still the one S1 recorded (round-4 addition) |

A same-signature replacement that matches owner, kind, `SECURITY DEFINER` and `search_path` but has a **different body**
now produces a different fingerprint and **STOPs** the rollback. That was the gap in round 2.

Order: writer-disable prerequisite (comment) → **current-ledger revalidation** → ledger row identity + ledger structural
cross-check (`record`/scalar variables only, so a missing ledger raises the intended stable error rather than a
`%ROWTYPE` compile failure) → **provenance verification** (all object classes) → RPC-function drops **gated on a
successful RPC ledger record** → relation-guarded trigger/policy drops → **S1 column-ACL revokes** → exact pre-S1
table-ACL restore → staging FK/CHECK/index drops → **fingerprint-gated staging column drops** →
`mt5_sync_run_positions` + guard function → `mt5_sync_runs` → delete only the two S1 ledger rows (drop the ledger table
only if S1 created it and it is now empty) → exact postflight.

**Current-ledger revalidation (round-4 authority-chain fix).** Rollback previously trusted whatever relation happened to
be named `public.mt5_schema_migrations` and read destructive authority straight out of it. Rows copied into a
replacement table are not evidence, so before **any** provenance row is consumed the current ledger is revalidated
against the same canonical contract the schema packet enforces at apply time:

- **structure** — exact 8-column set with exact types and nullability, both `DEFAULT` expressions, `PRIMARY KEY (version)`,
  all five CHECK constraints **by name and definition**, and no extra constraints;
- **identity** — owner is `postgres`, plus the apply-time **structural fingerprint** of the ledger recorded in
  `provenance->'ledger_struct'`, which catches an exactly-shaped impersonating replacement;
- **ACL** — exact normalized equality to `service_role:SELECT:false` (rejecting missing SELECT, extra privileges,
  `WITH GRANT OPTION`, PUBLIC access and unrelated-role grants in one comparison) and no column-level ACLs.

Ledger absent → the documented stable fail-closed path. Ledger exact → provenance may be consumed. Ledger
replaced/altered/re-privileged → **STOP before any destructive action**.

**Packet identity metadata comparison.** Rollback compares every identity field the packets record: `status`, ledger
`version`, the packet revision token (`checksum`), `source_artifact_sha256` against the frozen rev-3 design hash, and
`objects->'packet_revision' = 5` — for the schema row and, when present, the RPC row. As stated above, none of this
proves the `.sql` files' bytes; it establishes packet identity only.

**Staging column provenance (round-4).** `lifecycle_updated_at` and `missing_since_run_id` are S1 additions to a
**pre-existing** table and were previously dropped by name alone. Each now carries an apply-time definition fingerprint;
before each `DROP COLUMN` the current definition is re-compared, so a user or replacement column that merely reuses the
name is never destroyed. Absent column → supported partial install → skip with a notice. Definition differs → **STOP**.
Column exists but has no recorded provenance → **STOP**.

**RPC ledger gating.** *No successful RPC ledger record = no authority to drop any RPC-packet function.* With the RPC
row absent, the drop block is a complete no-op and logs a notice; a same-named survivor is treated as **foreign** and is
never inspected, inferred about, or removed. When the row is present, the signatures come from the ledger's recorded
provenance (never a hardcoded list), each is re-rendered from the catalog via `regprocedure` before execution, and each
must match its apply-time body fingerprint.

**Column-ACL revocation (round-3 correctness fix, round-4 wiring fix).** `REVOKE INSERT/UPDATE ON TABLE …` does **not**
remove independently granted **column** privileges. S1 installs column-scoped INSERT (40 columns) and UPDATE (6 columns)
grants on `mt5_import_staging`, so a normal full install previously left S1 column ACLs behind and the rollback
postflight would fail — aborting the rollback transaction. Rollback revokes each recorded column privilege individually,
driven by the `staging_col_grants` provenance captured from `pg_attribute` at apply time, so exactly the S1-granted
columns are cleared and no unrelated column ACL is touched. The revoke is asserted complete *before* the columns are
dropped, and again in the postflight.

Round 3 read that provenance from the **wrong JSON path** — `objects->'staging_col_grants'` instead of
`objects->'provenance'->'staging_col_grants'` — which silently yielded an empty object, so the round-3 fix did not
actually execute and a full install would still have failed its own postflight. Round 4 reads the correct nesting from
the already-loaded provenance object, and distinguishes the two cases the empty result had conflated:

| Provenance state | Meaning | Behavior |
|---|---|---|
| key **missing** or not a JSON object | provenance malformed/incomplete — "S1 granted nothing" was never recorded | **STOP** |
| key present, **empty** object | a recorded fact: zero S1-created column grants | proceed; nothing to revoke |
| key present, populated | the exact columns/privileges S1 installed | revoke each recorded privilege individually |

**Privilege restoration.** The schema packet captures the exact pre-S1 `service_role` table privileges (plus the raw
`relacl` for audit) and **refuses to migrate at all** if service_role holds `WITH GRANT OPTION` or the table already
carries explicit column-level ACLs — states a plain GRANT list could not faithfully reproduce. Rollback clears all seven
table privileges and re-grants **only** the captured ones. **An empty captured set restores to empty; there is no
fallback grant of any kind.** The postflight asserts the resulting privilege set equals the captured pre-S1 set exactly
and that no column-level ACL survived.

### Supported rollback matrix (static review)

Each row states what the **executable code now proves**, not intent.

| # | State | Behavior | Enforced by |
|---|---|---|---|
| 1 | full expected S1 install | rollback succeeds and restores **exact** pre-S1 ACLs, including the S1 column grants | `$col_acl$` per-column revokes reading `objects->'provenance'->'staging_col_grants'` + `$restore$` + postflight equality |
| 2 | schema packet only / RPC absent | **no foreign function is touched** — the drop block returns immediately on a notice | `mt5.s1_has_rpc` gate in `$drop_rpcs$` |
| 3 | a recorded function is absent | skipped (`to_regprocedure … is not null`); present ones fingerprint-checked then dropped | `$provenance$` + `$drop_rpcs$` |
| 4 | parent relation absent | relation-scoped trigger/policy statements are skipped, not executed | `to_regclass` guards in `$rel_scoped$` |
| 5 | S1 function replaced — same signature/owner/definer/search_path, **different body** | **STOP** | `pg_get_functiondef` fingerprint mismatch |
| 6 | trigger definition altered (timing/events/level/WHEN/enabled) | **STOP** | `pg_get_triggerdef` + `tgenabled` fingerprint |
| 7 | policy definition altered (cmd/roles/permissive/USING/WITH CHECK) | **STOP** | policy fingerprint |
| 8 | table materially altered or replaced | **STOP** | structural fingerprint (columns/constraints/indexes/owner) |
| 9 | pre-existing ledger, exactly compatible | reused; foreign provenance unchanged; only the two S1 rows deleted | exact-ACL + structural preflight |
| 10 | pre-existing ledger, incompatible in any respect | **STOP in the schema packet preflight**, before any mutation | exact normalized ACL equality + defaults/PK/CHECKs/owner |
| 11 | pre-S1 `service_role` grants empty or narrow | restores **exactly** empty/narrow — no fallback | `$restore$` conditional grants + postflight equality |
| 12 | S1 staging column absent (partial install) | skipped with a notice; the other column still evaluated | `$drop_cols$` null-definition branch |
| 13 | a same-named staging column exists with a **different definition** | **STOP** — a replacement column is never dropped | `$drop_cols$` definition fingerprint mismatch |
| 14 | `staging_col_grants` / `staging_columns_def` provenance missing or malformed | **STOP** before any destructive statement | `$guard$` key-presence + `jsonb_typeof` checks |
| 15 | `staging_col_grants` recorded but empty | accepted: zero S1 column grants to revoke | `$col_acl$` iterates an empty key set |
| 16 | ledger replaced/altered/re-privileged, or not the relation S1 recorded | **STOP** before any provenance row is consumed | `$ledger_valid$` canonical contract + `provenance->'ledger_struct'` cross-check |
| 17 | ledger row belongs to a different packet revision | **STOP** | `checksum` token + `source_artifact_sha256` + `packet_revision` comparison |

Additionally: grant options or pre-existing column ACLs on `mt5_import_staging` **STOP in the schema packet preflight**,
so those states are never migrated and therefore never mis-restored.

Original staging rows and `raw` evidence untouched; reconciliation failure is explicitly **not** a rollback reason.
`public.mt5_s1_test_pre_evidence` is test-only, is not an S1 migration object, and is deliberately left alone.

## Corrections applied (review round 1)

All blocking + gap findings from the first executable review were fixed in-place:
- **Parse blocker** — `pg_catalog.extract(...)` (3 sites) → bare `extract(epoch from ...)`; the fingerprint helper is now
  `stable` (it depends on `date_part`, which is stable), not `immutable`.
- **NULL reason code** — `mt5_mark_snapshot_failed_v1` / `mt5_mark_reconcile_failed_v1` now explicitly reject
  `p_reason_code is null` → `ERR_BAD_INPUT` (no raw CHECK failure).
- **Stale post-lock clock** — `mt5_create_run_v1` re-captures `clock_timestamp()` **after** each advisory-lock acquisition
  and row re-fetch, before any lease/expiry decision.
- **Payload sanitization** — the append parsing block now catches `when others` → `ERR_BAD_PAYLOAD` (all parse/shape/cast
  failures mapped to the stable contract).
- **Vacuous fixtures** — fixtures 3 and 4 now seed the open staging rows and assert the rows exist + hold the expected
  lifecycle state before comparing; fixture 13 expects exactly `ERR_REPLAY_CONFLICT`; fixture 25 independently recomputes
  the non-lifecycle evidence checksum and proves a lifecycle-only change leaves it invariant + asserts the ledger captured
  pre-migration evidence; fixture 26 now also tests `complete+pending → reconcile failed`.
- **Partial-install-safe rollback** — dropped the unconditional function `REVOKE`s (DROP removes ACLs); added owner guards
  for the run-position table and guard function.
- **Grant provenance** — the schema packet captures the pre-S1 `service_role` staging privileges into the ledger; rollback
  restores exactly those. *(Round 2 removed the `INSERT,SELECT,UPDATE` fallback this round had introduced.)*
- **Extra-column ledger guard** — the pre-existing-ledger preflight now also rejects an unexpected ledger column set.
- **Postflight clarity** — parenthesized the `proconfig @>` search_path test.
- **README consistency** — corrected the `position_state` statement (INSERT-only initial value; never UPDATEd) and
  softened the "exact catalog checks" / "IF EXISTS throughout" wording to match what the SQL actually does.

## Corrections applied (review round 2)

Codex verdict `REVISE_BEFORE_DB_TEST`. Frozen rev-3 confirmed valid unchanged; no relational architecture was altered.

- **NULL-vulnerable expected-error assertions (blocker)** — audited the **entire** packet, not only the cited fixtures.
  All 8 `<> 'ERR_…'` assertions (fixtures 5, 6, 8×2, 9, 13, 14, 26) now assert **both**
  `o_ok IS DISTINCT FROM false` **and** `o_error_code IS DISTINCT FROM '<exact>'`. An erroneous success with a NULL
  error code now fails. **0 plain `<>` error assertions remain**; 19 NULL-safe pairs total.
- **Vacuity re-audit** — fixtures 4, 15, 16 and 17 read rows with `SELECT … INTO` and compared without proving
  existence; each now has an explicit `IF NOT FOUND … RAISE` and NULL-safe comparison.
- **Fixture 3 suspicious zero-mutation (blocker)** — now captures **all three** lifecycle fields
  (`position_state`, `lifecycle_updated_at`, `missing_since_run_id`) for the **full 20-row seed** before and after,
  compares NULL-safely both as a whole document and element-by-element, asserts the post-set is still 20 rows, and
  **positively asserts the reconcile RPC succeeded** (`o_ok`/`o_error_code`) plus `reconcile_status='complete'` and
  `snapshot_health='suspicious'` — success is no longer inferred from the absence of an exception.
- **Append payload containment (blocker)** — the container-shape guard was one OR chain, so
  `jsonb_array_length(p_rows)` could be evaluated on a non-array (PostgreSQL does not guarantee OR short-circuit
  order) and leak a raw error. It is now a **staged sequence**: identity args → `p_rows IS NULL` → `jsonb_typeof` →
  `octet_length` → `jsonb_array_length` (**only after** array type is proven) → every element must be a JSON object.
  All payload-shape rejections return the single stable `ERR_BAD_PAYLOAD`; identity faults keep `ERR_BAD_INPUT`; the
  recordset/cast work stays inside the `WHEN OTHERS` boundary. **Frozen empty-array semantics are unchanged.**
- **New fixture 27** — SQL NULL, JSON object/number/string/null, array-of-scalars, array-with-null, nested array, and
  three malformed row casts (bigint, numeric, timestamptz) all → exact `ERR_BAD_PAYLOAD`; blank account still →
  `ERR_BAD_INPUT`; valid `[]` still succeeds with 0 inserted; no rejected payload inserted a row.
- **New fixture 28** — NULL and non-allowlisted reason codes on **both** failure RPCs → exact `ERR_BAD_INPUT`, with the
  run proven untouched.
- **Rollback object provenance (blocker)** — added a provenance-verification block that runs **before any DROP** and
  checks every S1 object class: tables (`relkind`+owner), all 13 functions (owner, `prokind`, `prosecdef`,
  `proconfig` search_path), the guard's `trigger` return type, and that the S1 triggers still point at the S1 guard
  function; plus a cross-check against the ledger-recorded function inventory. Any replaced/foreign object **aborts the
  whole rollback**. The RPC packet now records its exact `functions` signature list in the ledger so this provenance is
  ledger-based rather than name-based.
- **Relation-safe trigger/policy drops (blocker)** — `DROP TRIGGER/POLICY … ON t` still errors when `t` is absent, so
  both are now inside `to_regclass` guards, making "RPC packet applied, tables absent" a valid skippable state.
- **Exact privilege provenance (blocker)** — the schema packet now **refuses to migrate** when `service_role` holds
  `WITH GRANT OPTION` or the staging table already carries explicit column-level ACLs (states a GRANT list cannot
  reproduce), records the raw `relacl` for audit, and rollback **restores only the captured privileges with no fallback
  whatsoever** — an empty capture restores empty, and missing provenance aborts rather than guessing. Rollback also
  revokes all seven table privileges (not four) and its postflight asserts the final set equals the captured set exactly
  and that no S1 column ACL survived.
- **Pre-existing ledger compatibility (blocker)** — the preflight now validates defaults, `PRIMARY KEY`, all five CHECK
  constraints by name *and* definition, the absence of extra constraints, ownership, and privileges **before** any
  mutation, and STOPs on any difference. S1 no longer re-owns or re-privileges a ledger it did not create.
- **Fixture 25 pre-migration evidence** — added the minimal test-only `S1_test_preflight_packet.sql`, which seeds
  representative staging rows and records an **independent** pre-migration observation *before* the schema packet runs.
  Fixture 25 now compares the ledger provenance against that recorded reference (and hard-fails if the step was
  skipped), instead of recomputing both sides from the same post-migration state.
- **Privilege boundary unchanged (K)** — the post-S1 matrix is untouched: `service_role` still cannot UPDATE
  `position_state`/`lifecycle_updated_at`/`missing_since_run_id` (fixture 24), while Phase-0A insert/mapping still
  works. Rollback provenance was **not** "solved" by restoring broad UPDATE during normal S1 operation.

## Runtime execution record — disposable DB attempt #1

First execution of the packet against a real PostgreSQL. Target: a local `supabase start` stack (PostgreSQL **17.6**,
`supabase/postgres:17.6.1.143`) in a disposable project outside every git worktree, reached only through the container's
local socket. **No production database was involved.** Packet under test: `92e102b`.

| Stage | Result |
|---|---|
| Phase-0A baseline (repo-controlled, `phase_0a_sql_rpc_packet.md` §4.0–§7.3) | **PASS** |
| `S1_test_preflight_packet.sql` | **PASS** — 3 staging rows + evidence row, checksum `2c4a7275b242…` |
| `S1_schema_packet.sql` | **FAIL — SQLSTATE 42725** |
| `S1_rpc_packet.sql` | **NOT RUN** |
| `S1_verification_packet.sql` (28 fixtures) | **NOT RUN** — 0 of 28 executed |
| two-session concurrency test | **NOT RUN** |
| `S1_rollback_packet.sql` | **NOT RUN** |

**Root cause.** All schema DDL succeeded; the transaction aborted inside the apply-time provenance block (`$prov$`) with:

```
ERROR:  42725: operator is not unique: text || "char"
HINT:  Could not choose a best candidate operator.
```

Four `pg_catalog` columns are of the internal type `"char"` — `pg_attribute.attidentity`, `pg_attribute.attgenerated`,
`pg_trigger.tgenabled`, `pg_policy.polcmd` — and were concatenated directly into fingerprint preimages. Both
`text || anynonarray` and `anynonarray || text` match, so PostgreSQL cannot resolve the operator. This is a
**deterministic type-resolution defect, not environment-specific**: it would fail identically on any supported version,
including production. Consequence: **every provenance fingerprint added in rounds 3 and 4 was never executable.** Static
review cannot detect operator ambiguity, which is precisely what this gate exists to catch.

**Nothing committed.** The schema packet is one transaction, so the abort rolled everything back — verified afterwards:
ledger, both run tables and the guard function all absent, and the staging evidence checksum still matched the
independently recorded value. Only stage 1's committed artifacts remained.

**No runtime conclusion may be drawn beyond the failing schema stage.** The RPC packet, the 28 fixtures, the concurrency
invariant and the entire rollback matrix remain **unproven at runtime**; they are still static review only.

**Environment note (not a defect, no change made).** On PostgreSQL 17 `aclexplode` reports a `MAINTAIN` privilege for
`service_role` on staging, while `information_schema.role_table_grants` — which the packet uses for **both** privilege
capture and postflight comparison — does not list it. S1 therefore never revokes, restores, or compares `MAINTAIN`, and
the behavior is self-consistent. The string `MAINTAIN` appears nowhere in any packet.

## Corrections applied (review round 5)

Runtime verdict `FAIL_DISPOSABLE_DB` from disposable attempt #1 (above). A pure executable-SQL type fix — **no
architectural change, no fingerprint-format change, no ACL-model change, no fixture change.**

- **`pg_catalog` `"char"` concatenation ambiguity (runtime blocker)** — all **11** affected sites made type-explicit with
  `::text`: 5 in `S1_schema_packet.sql` (table, trigger, policy, `staging_columns_def`, `ledger_struct` fingerprints) and
  6 in `S1_rollback_packet.sql` (`ledger_struct` recompute, table, trigger, policy, `staging_columns_def`, and the
  per-column recompute before `DROP COLUMN`). `S1_rpc_packet.sql` and `S1_verification_packet.sql` had no affected site.
- **Full internal-`"char"` audit, not just the four failing names** — every catalog column of type `"char"` in the
  packets was inspected. `pg_class.relkind` and `pg_constraint.contype` also appear, but **only in equality comparisons**
  against unknown-type literals, which resolve unambiguously and were correctly left alone. `polpermissive`,
  `prosecdef` and `indisunique` are boolean, already cast or used as predicates. No other `"char"` field participates in
  any concatenation.
- **No `COALESCE` added** — all four fields are `NOT NULL` in the catalog, so `::text` alone is deterministic (a
  non-identity/non-generated column yields the empty string, matching the intended representation). The surrounding
  `string_agg` results keep their existing `coalesce(…,'')` normalization.
- **Apply/rollback preimage symmetry re-proven** after the casts — see the table below.
- **Packet revision bumped 4 → 5** across schema, RPC and rollback, since the executable content changed.

### Fingerprint preimage symmetry (round-5 audit)

Each family's preimage was extracted from inside `convert_to(…)`, normalized (comments and whitespace removed) and
compared between the write side and the rollback read side. All identical:

| Fingerprint family | Apply side | Rollback side | Preimage identical |
|---|---|---|---|
| run-table structural | schema `$prov$` `tables` | `$provenance$` tables check | **YES** |
| ledger structural | schema `$prov$` `ledger_struct` | `$guard$` recompute | **YES** (same recipe as run-table) |
| function / guard | schema `$prov$` + RPC `$prov$` | `$provenance$` guard + RPC checks | **YES** |
| trigger | schema `$prov$` `triggers` | `$provenance$` trigger check | **YES** |
| policy | schema `$prov$` `policies` | `$provenance$` policy check | **YES** |
| staging column definitions | schema `$prov$` `staging_columns_def` | `$provenance$` **and** `$drop_cols$` | **YES** (both rollback sites identical) |

## Corrections applied (review round 4)

Codex verdict `REVISE_BEFORE_DB_TEST`, with all core RPCs, append/seal atomicity, `captured_at` supersession,
consecutive-absence K, lifecycle transitions, the browser read RPC and the 28-fixture harness marked **PASS**. The
remaining blockers were confined to rollback provenance wiring. Frozen rev-3 unchanged; no RPC behavior altered; fixture
count unchanged at **28**.

- **`staging_col_grants` read from the wrong JSON path (correctness blocker)** — schema writes it inside
  `objects->'provenance'`; rollback read `objects->'staging_col_grants'` and always got `{}`, so round 3's column-ACL
  fix never executed and a normal full install would still have failed its own postflight. Rollback now reads the
  correct nesting from the already-loaded provenance object — provenance is **not** duplicated to a second location to
  paper over the defect — and separates *missing/malformed* (STOP) from *present but empty* (valid: nothing to revoke).
- **S1-added staging columns had no definition provenance** — `lifecycle_updated_at` and `missing_since_run_id` were
  dropped by name from a **pre-existing** table. Both now carry apply-time definition fingerprints (table identity, name,
  `format_type`, nullability, default, identity state, generated state), re-verified immediately before each
  `DROP COLUMN`. Absent → skip; different definition → **STOP**; present without provenance → **STOP**.
- **Rollback trusted the current ledger unconditionally** — it now revalidates the live `mt5_schema_migrations` against
  the full canonical contract (structure, defaults, PK, all five CHECKs by name and definition, no extra constraints,
  `postgres` owner, exact normalized ACL, no column ACLs) **and** against the ledger's own apply-time structural
  fingerprint, before any provenance row is consumed. A replaced or re-privileged ledger STOPs the rollback.
- **Packet identity metadata now fully compared** — `status`, ledger version, revision token, `source_artifact_sha256`
  and `objects->'packet_revision'` are all checked, for the schema row and the RPC row alike.
- **Stale packet identity constants replaced** — the `checksum` constants had been unchanged across three correction
  rounds, making a revision-3-era ledger row indistinguishable from this one. They are now explicit deterministic
  revision tokens, `sha256('<version>|packet-revision-5')`, documented as **not** file hashes. Nothing has been applied
  to any database, so there is no historical ledger row to migrate.
- **Schema-qualified catalog lookups** — the staging-index provenance lookups (both write and read side) are qualified
  with `relnamespace='public'::regnamespace`, and policy lookups are restricted to the two S1 relations via
  `to_regclass` (NULL for an absent relation, which simply matches nothing). A same-named object in another schema can
  no longer satisfy or false-block a check.
- **Not changed** — the 28-fixture harness (no textual dependency on the identity constants), all RPC bodies, the frozen
  design, and the packet-file-SHA limitation, which remains flagged for acceptance.

## Corrections applied (review round 3)

Codex verdict `REVISE_BEFORE_DB_TEST`, with all core RPC behavior, atomicity, supersession, K, lifecycle and the browser
read boundary marked **PASS** and the harness judged adequate to execute. The **only** blocking area was
migration/rollback provenance safety. Frozen rev-3 unchanged; no RPC behavior altered.

- **Column-ACL rollback bug (immediate correctness blocker)** — table-level `REVOKE` leaves column privileges in place,
  so a **normal full install** would have left S1 column ACLs behind and failed its own postflight, rolling back the
  rollback. Rollback now revokes each S1-granted column privilege individually, driven by apply-time
  `staging_col_grants` provenance, and asserts completion twice.
- **RPC ledger gating** — with no successful RPC ledger record, rollback has **no authority** over any RPC-packet
  signature: the drop block short-circuits and a same-named survivor is left untouched. Signatures now come from ledger
  provenance, not a hardcoded list, and are re-rendered from the catalog before execution.
- **Real function-definition provenance** — apply-time fingerprints over `pg_get_functiondef` (body-sensitive) + owner +
  `prosecdef` + `proconfig`, recorded by the RPC packet for all 12 functions and by the schema packet for the trigger
  guard. Same signature + same properties + **different body** now STOPs.
- **Table provenance beyond owner/relkind** — structural fingerprint over owner, columns (type/notnull/default/
  identity/generated), all constraints, and all indexes. ACLs excluded so privilege restoration cannot destabilise it.
- **Trigger provenance** — `pg_get_triggerdef` (target, function, timing, events, level, WHEN) plus `tgenabled`.
- **Policy provenance** — name, command, permissive, roles, `USING`, `WITH CHECK`.
- **Pre-existing ledger exact ACL equality** — replaced the forbidden-subset search with a normalized
  `grantee:PRIVILEGE:is_grantable` set comparison (owner entries excluded) that must equal exactly
  `service_role:SELECT:false`, plus a no-column-ACL check. Missing SELECT, extra privileges, grant options, PUBLIC
  access and unrelated-role grants are all rejected in one comparison.
- **Missing-ledger type resolution** — the rollback guard no longer declares `public.mt5_schema_migrations%ROWTYPE`
  before proving the relation exists; it uses `record`/scalars so a missing ledger produces the intended stable guard.
- **Source identity honesty** — no fake self-hash was introduced. The README now separates *packet identity metadata*
  from *deployed-object proof* and states that destructive authority rests on the apply-time fingerprints.
- **Harness (non-blocking)** — did **not** expand fixture scope. Only normalized the 11 remaining `IF NOT r.o_ok`
  success assertions to `r.o_ok IS DISTINCT FROM true`, which closes the same NULL-passes-silently flaw on the success
  side. Fixture count unchanged at 28.

## Remaining risks / open decisions (for review)

- **`extensions.digest` dependency** — fingerprints/manifest use sha256 via `extensions.digest`; preflight requires it.
  Confirm pgcrypto lives in `extensions` on the target project (Supabase default). If not, swap to `pgcrypto` schema or
  a `digest` wrapper.
- **`reconcile_status` default `'pending'`** — the schema models `reconcile_status` as NOT NULL default `'pending'` from
  create (vs rev-4's NULL-until-complete). Internally consistent with all CHECKs and the one-active-cycle predicate;
  flagged for reviewer acceptance.
- **`mark_snapshot_failed` reason vocabulary** — implemented as `CAPTURE_FAILED/VALIDATION_FAILED/APPEND_FAILED/
  SEAL_FAILED/UNSUPPORTED_MARGIN_MODE/OPERATOR_CANCELLED` (allowlisted). rev-3 named `positions_none/identifier_invalid/
  membership_verification_failed/…`; semantically equivalent, reviewer may want the exact rev-3 strings.
- **`missing_since_run_id` for a first-miss `still_open` row** — recorded as the current run (`p_run_id`), i.e. "missing
  since first recorded", not `first_absent_run_id`. In steady operation these coincide; they diverge only after a skipped
  reconcile. K is unaffected (streak uses actual membership). Open decision: adopt `first_absent_run_id` for strict
  rev-3 §H1 provenance, or keep the "first recorded" semantics.
- **Advisory-lock hash collisions** — two accounts sharing a 64-bit key serialize needlessly (not incorrect).
- **Packet identity tokens** (`7cd1e978…`, `65a21a63…`) are deterministic revision tokens — `sha256('<version>|packet-revision-5')`
  — not file-byte hashes, and they are labelled as such in the packets and in the table above. The **source-artifact**
  hash `9902B301…` is a real hash of the frozen design document and is compared by both the RPC preflight and rollback.
- ~~Function-provenance limit~~ — **RESOLVED in round 3.** Apply-time `pg_get_functiondef`-based fingerprints are now
  recorded and compared, so a same-signature different-body replacement is detected and STOPs the rollback.
- **Packet-file identity cannot be proven from inside the database** — see "Packet identity vs deployed-object proof"
  above. `checksum`/`source_artifact_sha256` are declared packet metadata, not file-byte verification; the destructive
  authority is the apply-time object fingerprints. Making a true file SHA trustworthy would require an external runner
  rather than the manual SQL-Editor model. **Explicitly flagged for reviewer acceptance.**
- **`information_schema.role_table_grants` grantee matching** — privilege capture/restore matches `grantee='service_role'`
  literally and does not attempt to resolve privileges inherited through role membership. S1 only ever grants/revokes
  directly to `service_role`, so the captured set is exactly the set S1 can alter; inherited privileges are neither
  recorded nor touched.
- **No execution performed** — correctness of the **28 fixtures** is unproven until run against a disposable database.
  The rollback partial-install matrix is likewise **static review only**, not an executed result.
