# MT5 S1 Append-Only Executable Packet — README

**Status:** `EXECUTABLE DRAFT — UNAPPLIED / NOT RUN`. Review artifacts only. No SQL was applied, no RPC invoked, no
Supabase write, no MT5 writer run, no schedule, no deploy.
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
`o_error_code` (i.e. an erroneous success) satisfies neither branch of `<>` and would pass silently. Every fixture that
reads a row asserts existence (`IF NOT FOUND`) before comparing.

**STATIC REVIEW vs EXECUTED DB VERIFICATION — these are different things.** Everything claimed in this README is the
result of **static review only**. **0 fixtures have been executed.** All 28 are drafted and marked
executable-but-NOT-RUN; they require a disposable Postgres with the test preflight + schema + RPC packets applied, and
are approval-gated. **No statement in this repository may be read as evidence that these fixtures pass.**

## Rollback summary

Two governing rules, both enforced before any destructive statement runs:

> **ROLLBACK MAY REMOVE ONLY AN OBJECT IT CAN PROVE IS STILL THE OBJECT S1 OWNS.**
> **ROLLBACK NEVER INVENTS A PRIVILEGE THAT DID NOT EXIST BEFORE S1.**

Order: operational writer-disable prerequisite (comment) → ledger + exact-checksum guard, which also **refuses to
proceed at all if `staging_pre_service_grants` provenance is absent** → **provenance verification block** (see below) →
drop the 9 RPCs + 3 helpers via `DROP FUNCTION IF EXISTS` (which also removes their ACLs, so no separate REVOKE is needed
and rollback is safe for a partial RPC install) → **relation-guarded** trigger/policy drops → restore the **exact**
pre-S1 `service_role` staging privileges → drop the S1 staging FK/CHECK/indexes/columns → drop
`mt5_sync_run_positions` + guard function → drop `mt5_sync_runs` → delete only the two S1 ledger rows (drop the ledger
table only if S1 created it and it is now empty) → postflight.

**Provenance verification.** Tables must be `relkind='r'` and postgres-owned. Every S1 function — 12 RPC-packet
functions plus the trigger guard — must, *if it still exists*, match the full S1 fingerprint: postgres-owned,
`prokind='f'`, `SECURITY DEFINER`, and `proconfig` pinning `search_path=""`; the guard must additionally still return
`trigger`; the S1 triggers must still point at the S1 guard function. When the RPC packet ran, the ledger's recorded
`functions` signature inventory is cross-checked as well. **Any same-named object that fails these checks aborts the
entire rollback and destroys nothing** — a replacement is never dropped, and object name alone is never accepted as
provenance.

**Privilege restoration.** The schema packet captures the exact pre-S1 `service_role` table privileges (plus the raw
`relacl` for audit) and **refuses to migrate at all** if service_role holds `WITH GRANT OPTION` or the table already
carries explicit column-level ACLs — states a plain GRANT list could not faithfully reproduce. Rollback revokes all
seven table privileges and re-grants **only** the captured ones. **An empty captured set restores to empty; there is no
fallback grant of any kind.** The postflight asserts the resulting privilege set equals the captured pre-S1 set exactly
and that no S1 column-level ACL survived.

### Supported rollback matrix (static review)

| # | State | Behavior |
|---|---|---|
| 1 | full expected S1 install | restores exactly |
| 2 | schema packet only / RPC packet incomplete | function drops are no-ops; ledger rpc row absent → skipped; restores exactly |
| 3 | some S1 functions absent | absent ones skipped; present ones provenance-checked then dropped |
| 4 | parent table absent | trigger/policy drops skipped via `to_regclass` guard (no relation-scoped error) |
| 5 | same-name function replaced after S1 | **STOP** — fingerprint mismatch aborts; nothing dropped |
| 6 | same-name trigger/policy collision | **STOP** — trigger no longer pointing at the S1 guard aborts |
| 7 | pre-existing ledger, exactly compatible | reused; only the two S1 rows deleted; ledger table kept |
| 8 | pre-existing ledger, incompatible | **STOP in the schema packet preflight**, before any mutation |
| 9 | pre-S1 service_role had no relevant grant | restores to **no grant** (never a fallback) |
| 10 | pre-S1 service_role had narrower grants | restores exactly that narrower set |
| 11 | grant options / pre-existing column ACLs | **STOP in the schema packet preflight** — never migrated, so never mis-restored |

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
- **Contract self-checksums** (`d72f7c…`, `97f4e99…`) are declared provenance constants recorded in the ledger; they are
  not recomputed from file bytes at apply time (they cannot self-contain their own hash). The **source-artifact** hash
  `9902B301…` is the authoritative gate.
- **Function-provenance limit (honest bound)** — rollback proves owner + `prokind` + `SECURITY DEFINER` +
  `search_path=""` at an exact S1 signature, cross-checked against the ledger's recorded signature list. A hostile
  replacement that matched **all** of those at the same signature would still be indistinguishable from S1's own
  function without storing and comparing a body fingerprint (`prosrc` hash) at apply time. That was judged out of scope
  for a safety-correction round because it changes the ledger contract; flagged for reviewer acceptance.
- **`information_schema.role_table_grants` grantee matching** — privilege capture/restore matches `grantee='service_role'`
  literally and does not attempt to resolve privileges inherited through role membership. S1 only ever grants/revokes
  directly to `service_role`, so the captured set is exactly the set S1 can alter; inherited privileges are neither
  recorded nor touched.
- **No execution performed** — correctness of the **28 fixtures** is unproven until run against a disposable database.
  The rollback partial-install matrix is likewise **static review only**, not an executed result.
