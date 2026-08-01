# MT5 Auto Sync — S1 Append-Only Snapshot-Membership Design

**Type:** Planning / relational-contract design record (docs-only) · **Date:** 2026-08-01 · **Revision:** 3 (folds in Codex + Fable reviews of rev 2; relational contracts only)
**Status:** `DESIGN — RELATIONAL CONTRACTS ONLY. EXECUTABLE PACKET NOT WRITTEN.` (no migration/RPC SQL bodies; no runtime code, no applied SQL, no invoked RPC, no MT5 run, no Supabase write, no schedule, no commit)
**Authoring branch:** `work/mt5-phase-a-positions-review` · **Tracked HEAD:** `3a05d43` · **origin/main (re-checked):** `f37a0ef`
**Supersedes (foundation):** `artifacts/mt5_reconciliation/S1_snapshot_lifecycle_design.md` (rev 4) — **REJECTED**, banner added.
**Depends on:** Phase 0A (`mt5_import_staging` PK `id uuid`, `position_id bigint`; `mt5_import_cursors`/`mt5_import_groups`); the 0C-3a/0C-3b writer.
**Review status folded in:** append-only foundation **PASSES** (Codex + Fable); **no foundational redesign**; this revision closes the narrow contract gaps. **Provenance note:** rev-2 on-disk bytes = SHA-256 `780210F7…` (28,478 B / 437 lines) = Fable's reviewed copy; Codex's reported `C5B0EE76…` (54,732 B / 867 lines) did **not** match the on-disk file (stale copy).

> Planning only. This revision **contains no executable PL/pgSQL bodies and no full migration** — those are drafted only
> after these contracts pass review. Nothing here edits runtime code, applies SQL, invokes an RPC, runs the writer,
> writes Supabase, schedules the connector, creates a branch/worktree/migration file, or touches Journal/GUGU.

---

## 0. Verdict & scope

**Verdict:** `READY_FOR_EXECUTABLE_PACKET_DRAFT`.

Rev 3 freezes: one-active-cycle (`ERR_RUN_ACTIVE`); **captured-at supersession** at completion (`ERR_SUPERSEDED`);
DB-derived `previous_positions_count` (healthy-complete only); **corrected consecutive-absence K** (actual membership,
presence resets the streak even if that run's reconcile failed) with the H1/H2/H3 proof; composite-scope lifecycle FK +
RPC-only lifecycle writes; **narrowed staging privileges** (no direct `service_role` lifecycle-column UPDATE);
**RPC-only browser read** (no direct table SELECT) with server-authoritative freshness on `captured_at`; append error
precedence (status before lease); server-allowlisted completion policy; exhaustive lifecycle CASE; NaN/side/nonblank
schema constraints; `row_fingerprint` kept as NOT-NULL audit metadata. No executable packet is drafted here.

---

# PART A — Preserved foundation & invariants

## A1. Three separated responsibilities (approved)

| Table | Role | Mutability |
|---|---|---|
| `mt5_sync_runs` | run envelope: identity, account, status dims, DB-time lease, counts, `run_seq`, **sealed policy**, capture identity, timestamps | status-machine via RPC only |
| **`mt5_sync_run_positions`** | **append-only immutable** per-run membership + snapshot facts; **current-open source of truth**; suspicious/failed diagnostics; seal input | INSERT-only (started run); **no UPDATE/DELETE by any application role or S1 RPC** |
| `mt5_import_staging` | candidates, product mapping, Journal matching, **workflow + lifecycle annotation only** | narrow writer/RPC ops; **never authoritative for current-open membership or values** |

## A2. Preserved / never-regress

Current-open truth independent from staging membership; partial/failed/unsealed runs non-authoritative; suspicious runs
diagnostic-only; account advisory lock shared by append + completion; no application UPDATE/DELETE of immutable rows.
**Never reintroduce** `staging.last_seen_run_id`, mutable pre-seal membership, or staging market fields as current truth.

## A3. Isolation invariant (release-blocking; Part L proof)

Current-open reads only the **latest completed** run's rows (gated by health+freshness). A `started` run's appends live
in a disjoint PK space (`run_id=new`) and can never mutate a prior run's rows; a crash/fail/suspicious new run leaves the
latest *completed* run byte-for-byte intact. ∎

---

# PART B — Frozen immutable schema (contract, not migration)

## B1. `mt5_sync_run_positions` — required S1 shape (no `staging_id`, no `position_payload`)

Enrichment linkage later uses `(user_id, source_account, position_id)` — no stored staging pointer.

| Column | Type | Null? | Notes |
|---|---|---|---|
| `run_id` | uuid | not null | PK part; composite-FK part |
| `user_id` | uuid | not null | scope; composite-FK part |
| `source_account` | text | not null | scope; composite-FK part; **non-blank CHECK** |
| `position_id` | bigint | not null | PK part; MT5 `POSITION_IDENTIFIER` |
| `symbol_raw` | text | **not null** | **non-blank CHECK** |
| `side` | text | **not null** | **domain exactly `buy`\|`sell` (CHECK) for S1** |
| `volume` | numeric | **not null** | **CHECK `volume > 0 AND volume <> 'NaN'`** |
| `price_open` | numeric | null | NULL when omitted (≠0); **CHECK NULL or `<> 'NaN'`** |
| `price_current` | numeric | null | NULL when unavailable (≠0); **CHECK NULL or `<> 'NaN'`** |
| `profit` | numeric | null | NULL when unavailable (≠0); **CHECK NULL or `<> 'NaN'`** |
| `open_time_utc` | timestamptz | null | true UTC when known |
| `source_time_msc` | bigint | null | raw epoch ms; **nullable — explicitly documented**; **returned by the read RPC** |
| `contract_size` | numeric | null | NULL when unknown (≠0); **CHECK NULL or `<> 'NaN'`** |
| `captured_at` | timestamptz | **not null** | = the run's immutable **capture identity** (Part D); not RPC fallback |
| `row_fingerprint` | text | **not null** | **audit/replay metadata only** (Part C) — **kept in S1, not droppable**; not the correctness authority |
| `created_at` | timestamptz | not null default now() | DB insert time |

**Keys / constraints (contract):**
```
PRIMARY KEY (run_id, position_id)
CHECK (volume > 0 AND volume <> 'NaN'::numeric)
CHECK (price_open    IS NULL OR price_open    <> 'NaN'::numeric)
CHECK (price_current IS NULL OR price_current <> 'NaN'::numeric)
CHECK (profit        IS NULL OR profit        <> 'NaN'::numeric)
CHECK (contract_size IS NULL OR contract_size <> 'NaN'::numeric)
CHECK (btrim(symbol_raw) <> '')
CHECK (side IN ('buy','sell'))
CHECK (btrim(source_account) <> '')
-- parent must expose:  mt5_sync_runs UNIQUE (id, user_id, source_account)
FOREIGN KEY (run_id, user_id, source_account)
  REFERENCES mt5_sync_runs (id, user_id, source_account) ON DELETE RESTRICT
```
> **NaN note:** PostgreSQL numeric `NaN` sorts **greater** than any number, so `volume > 0` alone would *pass* NaN — the
> explicit `<> 'NaN'` guards are required.

## B2. No silent defaults (frozen)

`volume` required (`>0`, not NaN); `symbol_raw`/`side` required; `captured_at` = the run's capture identity (Part D),
never `clock_timestamp()`/RPC fallback; `price_open`/`price_current`/`profit`/`contract_size` may be **NULL** (distinct
from 0) and, when present, must not be NaN; `source_time_msc` nullable by documentation. A row missing required evidence
is **rejected before append** (`ERR_MISSING_FACT`); the append RPC never substitutes guessed/default values.

## B3. `mt5_sync_runs` additions

Rev-4-shaped envelope **plus**: `UNIQUE (id, user_id, source_account)` (composite-FK target); a sealed **capture
identity** `captured_at` (set at create from the writer's single capture instant); sealed **policy** (`policy_version`
allowlisted, `policy_thresholds` incl. `k`, `susp_min_base`, `susp_drop_ratio`, `freshness_seconds`). **No
`last_seen_run_id`.**

## B4. `mt5_import_staging` deltas (annotation only)

- Add `lifecycle_updated_at timestamptz`.
- Add `missing_since_run_id uuid` — **lifecycle annotation/provenance only, never current membership truth**;
  **composite-scope FK** `(missing_since_run_id, user_id, source_account) → mt5_sync_runs (id, user_id, source_account)
  ON DELETE RESTRICT` (proves existence **and scope**; complete+healthy is enforced by the RPC, Part G).
- Extend `position_state` CHECK to the S1 vocabulary (legacy `open|closed|gone` tolerated `NOT VALID`).
- **No `last_seen_run_id`.** Preserve the unique open identity `(user_id, source_account, position_id) WHERE kind='open'`.

---

# PART C — Full immutable replay identity

Replay identity = **field-by-field over every stored immutable fact**: `position_id, symbol_raw, side, volume,
price_open, price_current, profit, open_time_utc, source_time_msc, contract_size, captured_at`.

- same `run_id`+`position_id` + **every field `IS NOT DISTINCT FROM`** stored → stable idempotent success.
- **any** field differs (incl. NULL↔value) → **`ERR_POSITION_CONFLICT`**, no insert.
- a changed MT5 read (any fact) is a new observation → **new run ID**, never an overwrite.

Correctness authority = field-by-field `IS NOT DISTINCT FROM`. `row_fingerprint` is **audit metadata only** (kept, NOT
droppable): canonical typed encoding — explicit NULL sentinel distinct from any value, normalized numeric form,
deterministic UTC/epoch encoding, **no `concat_ws`/`coalesce` ambiguity**. The digest never decides conflict.

---

# PART D — Create / append / seal atomicity & error precedence

**Capture identity:** the writer records one capture instant per run as `mt5_sync_runs.captured_at` at create; every
appended row inherits it (append stamps `captured_at := run.captured_at`, rejecting a run with no capture identity).

**Shared account advisory lock** for create/append/complete/reconcile:
`pg_advisory_xact_lock(hashtextextended(stored_user||':'||stored_account, 0))`.

**Existing-run ordering:** reject null identity → fetch by `run_id` → derive stored user/account → account lock →
re-fetch `FOR UPDATE` → caller identity `IS DISTINCT FROM` (`ERR_RUN_CONFLICT`) → **status check** → lease check
(`clock_timestamp()`) → act.

## D1. Create-run — one active cycle (frozen)

**One active cycle per `(user_id, source_account)`**, active = `snapshot_status='started'` **OR**
(`snapshot_status='complete'` AND `reconcile_status='pending'`). A live active cycle **blocks create-run** →
**`ERR_RUN_ACTIVE`**. Enforced by a partial unique index **and** re-checked in the RPC (no reliance on ordering several
concurrent `started` runs later). An **expired** cycle must first pass through the guarded expiry/failure protocol
(`mt5_expire_stale_run_v1` / `mt5_mark_*_failed_v1`) before a new run may start.

## D2. Append — insert-only, error precedence (frozen)

`mt5_append_run_positions_v1(run_id, user, account, lease_token, rows jsonb) → (o_ok, o_inserted, o_error_code)`:
- **status precedence BEFORE lease:** run `complete` → **`ERR_RUN_SEALED`**; run `failed` → **`ERR_RUN_FAILED`**; run
  `started` → then validate matching lease token + DB-time expiry (`ERR_LEASE_MISMATCH`/`ERR_LEASE_EXPIRED`). **A
  completed run must never return `ERR_LEASE_EXPIRED`** merely because its old lease time has passed.
- required-field validation (Part B2) → `ERR_MISSING_FACT`; id null/dup → `ERR_NULL_OR_DUP_ID`.
- exact replay → idempotent success; payload conflict → **`ERR_POSITION_CONFLICT`**.
- **no UPDATE fallback**; `user/account` stamped from the stored run.
- a concurrent append waiting behind completion re-reads state after the lock and returns **`ERR_RUN_SEALED`**.

**DB backstop triggers:** `BEFORE UPDATE OR DELETE → raise`; `BEFORE INSERT → reject unless target run is 'started'`.

---

# PART E — Completion contract (supersession + manifest + policy authority)

`mt5_complete_snapshot_v1` (under the account lock, `FOR UPDATE`):

## E1. Captured-at supersession (frozen)

While holding the lock, load the **latest completed observation** for the same `(user, account)` and compare immutable
`captured_at`. First-time completion is eligible **iff** there is **no** previous completed observation **or** the
current `captured_at` is **strictly newer** than the latest completed `captured_at`. If the capture is **older or equal**
→ **`ERR_SUPERSEDED`**: the run never becomes a completed observation and never receives an authoritative
`run_seq`/current status. (Prevents a delayed **stale** capture from becoming current just because its completion
*timestamp* is newer.) **Completion replay** of the *same already-completed run* is handled separately by the sealed
manifest replay contract (E3), not by supersession.

## E2. Full-payload seal

Recompute **from stored child rows**: exact sorted position-ID set + count; exact user/account/run scope (no cross-scope
row); **aggregate immutable-payload manifest** (deterministic digest over the full typed payload of every child row,
ordered by `position_id`, canonical Part-C encoding — covers values, not just IDs); no invalid/duplicate identity; valid
empty set supported. **`previous_positions_count`** is DB-derived **under the lock** from the latest prior run with
`snapshot_status='complete'` AND `snapshot_health='healthy'` — **never** suspicious observations, **never** client
input, **never** a create-time cached value without revalidation. Health re-derived fail-closed from that
`previous_positions_count` + `positions_count` + sealed thresholds. Sealed atomically: ID set/count evidence, aggregate
manifest fingerprint, `policy_version`+`policy_thresholds`, health inputs, `run_seq` (under lock), **DB completion time**.

## E3. Completion policy authority (frozen)

`policy_version` is **server-allowlisted**; `K` range **1..10**; suspicious thresholds (`base ≥ 1`, `ratio ∈ (0,1]`) and
`freshness_seconds` are **server-authorized/allowlisted**. The caller may **request a supported policy version** but
**cannot invent arbitrary threshold JSON**; completion records the exact applied policy and derives health + previous
count from DB evidence.

## E4. Replay

Recompute + compare ID set, count, **full immutable-payload manifest**, policy/version/thresholds, and health against the
sealed values. Exact match → stable stored success; any mismatch → **`ERR_REPLAY_CONFLICT`**.

---

# PART F — Read semantics, RPC-only browser surface & authoritative freshness

## F1. Latest-observation rule (corrected)

Select the **latest completed observation ordered primarily by `run_seq DESC`** (tiebreak `snapshot_completed_at DESC,
id DESC`), **then** inspect that run's health + freshness. **Never** pre-filter to the latest *healthy* run.

| Latest completed observation | Result |
|---|---|
| healthy + fresh | current positions = that run's immutable rows |
| healthy + empty | current state = **zero** open positions |
| **suspicious** | unknown/suspicious; **no trusted positions**; previous healthy run **only** as explicit stale context |
| **stale** (healthy but old) | stale; **no current claim** |
| newer run only `started`/`failed` | does **not** hide the latest completed observation |

## F2. Browser read surface is RPC-ONLY (frozen)

- `authenticated` receives **NO direct SELECT** on `mt5_sync_runs` and **NO direct SELECT** on
  `mt5_sync_run_positions`. Normal browser access is **only** `mt5_get_current_snapshot_v1(source_account text)`.
- The read RPC: identity from **`auth.uid()`** (no caller `user_id`); **database time**; latest completed observation
  first, then health+freshness; returns immutable positions **only** when healthy + fresh; **metadata-only** for
  suspicious / stale / healthy-empty; may return the previous healthy snapshot's metadata as explicit stale context;
  **includes `source_time_msc`** in the immutable position output; exposes **no** lease, hashes, raw errors, policy
  internals, or terminal details. (This blocks direct PostgREST queries from bypassing the suspicious/stale gate.)
- **Contract only — no executable body in this revision.**

Safe metadata fields: `run_id, source_account, snapshot_status, reconcile_status, snapshot_health,
snapshot_completed_at, positions_count, warning_code, freshness_state`. Immutable position fields returned (healthy+fresh):
`position_id, symbol_raw, side, volume, price_open, price_current, profit, open_time_utc, source_time_msc,
contract_size, captured_at`.

## F3. Authoritative freshness (frozen)

Freshness is decided **by the read RPC** as `clock_timestamp() - run.captured_at` against a **sealed server-authorized
`freshness_seconds`**. **`snapshot_completed_at` is seal/audit time only** — not the current-state age. **No
UI-authoritative freshness alternative exists.** (The executable packet may additionally enforce a maximum
append-to-seal duration, but current-state age is always `captured_at`-based.)

---

# PART G — Deterministic lifecycle baseline (annotation only)

Reconcile annotates only `mt5_import_staging.position_state` (+ `lifecycle_updated_at`, `missing_since_run_id`); it
**never** touches current-open membership. It runs only for a **healthy completed** run. Signature drops the caller K:
`mt5_reconcile_snapshot_v1(run_id, user, account, lease_token)` — **K is read from the run's sealed policy** (Part E3).

## G1. Composite-scope FK + privilege (frozen)

- `missing_since_run_id` uses the **composite-scope FK** (Part B4) → existence + scope. **Complete + healthy** of any
  baseline run is enforced **inside the reconcile RPC** (the FK cannot prove status/health).
- **Only the guarded reconcile SECURITY DEFINER RPC** may set or clear `position_state` / `lifecycle_updated_at` /
  `missing_since_run_id`. **No browser or ingestion writer** receives a direct UPDATE on these columns (Part J3).

## G2. Exhaustive lifecycle CASE — single original-state classification pass

Every original `position_state` has an explicit outcome (no implicit fall-through). Classification uses **one** pass on
the *original* state so a newly-created `unknown` conflict can **never** be promoted to `still_open` in the same reconcile.

**Observed in this healthy run's immutable set** (`EXISTS run_positions(this_run, position_id)`):

| Original state | New state | `missing_since_run_id` |
|---|---|---|
| `seen_open` / `open` / `unknown` / `missing_once` | `still_open` | cleared |
| `still_open` | `still_open` | cleared |
| `not_open_confirmed` / `partial` / `closed_confirmed` | `unknown` (conflict) | cleared |
| tolerated legacy terminal (`closed` / `gone`) | `unknown` (conflict) | cleared |

**Absent in this healthy run** (`NOT EXISTS`):

| Original state (open-ish) | Condition | New state | `missing_since_run_id` |
|---|---|---|---|
| `still_open` / `seen_open` / `open` | first eligible absence | `missing_once` | = **first-absent run of the current streak** |
| `missing_once` | active streak `< K` | `missing_once` (unchanged) | unchanged |
| `missing_once` | active streak `≥ K` | `not_open_confirmed` | unchanged (provenance kept) |
| `unknown` / `not_open_confirmed` / `partial` / `closed_confirmed` / legacy terminal | — | **explicit no-op** | unchanged |

**Suspicious run:** **zero** lifecycle changes of every kind (Part H).

---

# PART H — Corrected consecutive-absence K (frozen) + H1/H2/H3 proof

## H1. Contract

Absence credit comes **only** from eligible healthy completed runs in which the position is **actually absent**:
```sql
NOT EXISTS (
  SELECT 1 FROM mt5_sync_run_positions p
   WHERE p.run_id = eligible_run.id AND p.position_id = target_position_id
)
```
- **eligible run** = `snapshot_status='complete'` AND `snapshot_health='healthy'`, `run_seq ≤ current` (suspicious
  excluded — they neither count nor reset).
- `last_present_seq(pid)` = **max** eligible `run_seq` whose **actual membership** contains `pid` (NULL if never).
- **absence streak** = count of eligible runs with `run_seq > coalesce(last_present_seq, -1)` and `≤ current`. Because
  `last_present_seq` is the maximum present seq, **every** eligible run after it is absent → the streak is genuinely
  **consecutive**.
- `missing_since_run_id` = the **min** eligible `run_seq` in that window (first consecutive-absent run).
- `not_open_confirmed` when `streak ≥ K` (sealed K).
- **A later healthy run containing the position resets the baseline**, and this holds **even if that presence run's
  lifecycle reconciliation failed** — because the streak reads **actual `run_positions` membership**, not the lagging
  annotation. Later absence counting restarts at 1.
- Compute **set-wise** (one aggregate over candidate positions), not one full-history scan per row.

## H2. Why the naive baseline-count is wrong (counterexample)

Runs (all healthy, complete), position **X**: **H1** `run_seq=1` X **absent**; **H2** `run_seq=2` X **present** but its
**reconcile FAILED**; **H3** `run_seq=3` X **absent**. K=2.

- **Naive** (count healthy runs from `missing_since_run_id.run_seq` established at H1): at H3, count healthy runs in
  `[1,3]` = **3 ≥ K=2** → `not_open_confirmed`. **WRONG** — X was present at H2; the streak must have reset. The bug is
  that H2's failed reconcile never cleared `missing_since_run_id`, so a baseline-count wrongly spans the presence.
- **Corrected** (actual membership): `last_present_seq(X) = 2` (H2's *membership* contains X regardless of its
  reconcile status). streak at H3 = count eligible runs with `run_seq > 2` and `≤ 3` = `{H3}` = **1** → `missing_once`,
  `missing_since_run_id = H3`. **CORRECT.** ∎

The correction is exactly to **derive absence from immutable membership**, not from annotation provenance — the provenance
column stays for display but never drives K.

---

# PART I — Suspicious contract + workflow/staging mapping

## I1. Suspicious zero-mutation (frozen)

A suspicious completed run performs **zero** observed-row transitions, **zero** absent-row transitions, **zero**
`missing_since` changes, **zero** K advancement. It remains diagnostic evidence, **blocks reconciliation of an older
run** (a newer complete run → `ERR_SUPERSEDED` for the older), and preserves previous-healthy reconstruction. Only a
**later healthy** run changes lifecycle annotation.

## I2. Workflow/staging mapping (frozen)

Annotation targets only deterministic open staging rows: same `user_id`, `source_account`, stable `position_id`,
`kind='open'` (the unique open identity). `grouped`/`materialized`/`dismissed` rows **still** receive annotation;
workflow state **never** blocks it; **deal rows excluded**; missing staging row → **annotation no-op**; **multiple
matching open rows → invariant violation to surface**, not an arbitrary patch. No staging mutable fact is read as
snapshot truth.

---

# PART J — Index, privilege & RLS model

## J1. Indexes

- **Runs:** latest-completed `(user_id, source_account, run_seq DESC)` partial `WHERE snapshot_status='complete'`;
  healthy-history `(user_id, source_account, run_seq DESC)` partial `WHERE snapshot_status='complete' AND
  snapshot_health='healthy'`; one-active-cycle partial unique index (D1).
- **Run positions:** PK `(run_id, position_id)` for run lookup; history `(user_id, source_account, position_id,
  run_id)` for set-wise K/enrichment. **No redundant `run_id`-only index** unless plans justify.
- **Staging:** preserve unique open identity `(user_id, source_account, position_id) WHERE kind='open'`; add a lifecycle
  index for account/state/open-row reconciliation so **K is set-wise** (no per-row correlated full-history scan).

## J2. RLS / immutability (precise wording)

- **“No application role or S1 RPC may UPDATE or DELETE immutable run-position rows.”** Not a claim against the
  PostgreSQL **owner/superuser** (who owns the tables and can bypass triggers/grants). Enforced against every application
  role and S1 RPC.
- **`mt5_sync_run_positions`:** authenticated **no direct SELECT** (browser reads via the read RPC only); `service_role`
  = SELECT if required, **no direct INSERT/UPDATE/DELETE**; INSERT only via the guarded append RPC (owner `postgres`);
  no application DELETE. Guard trigger functions owned by `postgres`, EXECUTE revoked from
  `public`/`anon`/`authenticated`/**`service_role`**.
- **`mt5_sync_runs`:** RPC-only writes; **authenticated no direct SELECT** (read RPC only); `service_role` read-only SELECT.
- Read RPC + connector RPCs are the only interfaces; RLS stays enabled as defense even though no direct grant exists.

## J3. Staging privilege narrowing (frozen migration requirement)

Phase 0A grants `service_role` broad `INSERT/UPDATE` on staging. S1 migration must **revoke broad staging UPDATE from
`service_role`** and replace it with **exact column-level UPDATE** on the value/import columns ingestion legitimately
owns, **or** route ingestion through guarded RPCs if column grants are insufficient. **Direct `service_role` mutation of
`position_state`, `lifecycle_updated_at`, `missing_since_run_id` is excluded** — lifecycle writes occur **only** through
the reconcile SECURITY DEFINER RPC. Ingestion keeps its ability to update the reviewed non-lifecycle columns.

**Future staging privilege matrix (documented; applied in the S1 migration):**

| Column group | `service_role` | reconcile RPC (definer/postgres) | authenticated |
|---|---|---|---|
| identity/import facts (`symbol_raw`, `normalized_symbol`, `side`, `volume`, `price`, `*_time*`, `contract_size`, `digits`, `commission`, `swap`, `fee`, `broker_profit`, `raw`, …) | INSERT + column UPDATE | — | none |
| workflow (`state`, `import_group_key`, `confirmed_group_id`, `materialized_*`, `dismissed_at`) | via existing 0A workflow RPCs (unchanged) | — | none |
| **lifecycle (`position_state`, `lifecycle_updated_at`, `missing_since_run_id`)** | **NO direct UPDATE** | UPDATE | none |

---

# PART K — Rev-4 RPC treatment & migration/version boundary

## K1. `REUSE_CONCEPTS_REWRITE_BODIES`

Rev-4 bodies are **not** reused verbatim. Reusable **concepts**: responsibilities, DB-time lease, account advisory lock,
failure separation, status dimensions, `SECURITY DEFINER` principles. **Bodies rewritten + re-reviewed** for
stored-identity lock derivation, expired-lease non-revival, `IS DISTINCT FROM`, stable replay,
successor-before-terminal-failure ordering, `clock_timestamp()`, fully-qualified columns, exact output/error contracts.

**Anticipated RPC set (contracts drafted next):** `mt5_create_run_v1` (`ERR_RUN_ACTIVE`), `mt5_heartbeat_run_v1`,
`mt5_append_run_positions_v1`, `mt5_complete_snapshot_v1` (supersession + manifest), `mt5_reconcile_snapshot_v1` (no
caller K), `mt5_mark_snapshot_failed_v1`, `mt5_mark_reconcile_failed_v1`, `mt5_expire_stale_run_v1`, and the read-only
`mt5_get_current_snapshot_v1`.

## K2. Migration/version boundary (executable packet BLOCKED this task)

Freeze only: **separate schema and RPC migration ledger versions/states**; ledger **created before queried**; **success
recorded last**; **exact object-definition checks** (catalog comparison, not name/substring markers); **exact per-object
ownership**; **incompatible prior object rejection**; a **transactional schema packet** and a **separate transactional
RPC packet**; **ownership-safe, dependency-safe rollback**. **No rev-4 markers or SQL reuse.** No migration SQL is
written here.

---

# PART L — Updated invariant proofs & future fixtures (not executable yet)

Encode as **real SQL assertions / function calls** (not labeled executable until they exist):

1. **partial B preserves A** — B appends P1, crashes → current = A's full frozen set.
2. **failed B preserves A** — B appends a full set, `mark_snapshot_failed` → current = A; B rows remain diagnostics.
3. **suspicious B preserves A as stale context** — reconcile B mutates **zero** lifecycle rows; A reconstructable.
4. **successful C atomically replaces A** — C completes healthy → current flips A→C in one evaluation.
5. **full-payload replay conflict** — re-append with any differing field (incl. NULL↔value) → `ERR_POSITION_CONFLICT`.
6. **append after seal → `ERR_RUN_SEALED`** before any lease error; trigger rejects a raw insert.
7. **no UPDATE/DELETE** on run-positions → trigger `raise`.
8. **valid zero** — append []; complete seals; read = 0 open, healthy.
9. **delayed older capture cannot complete after a newer observation** — B `captured_at ≤` latest completed → `ERR_SUPERSEDED`.
10. **live active run blocks another create** → `ERR_RUN_ACTIVE`.
11. **H1 absent / H2 present with FAILED reconcile / H3 absent → new streak 1** (`missing_once`, not `not_open_confirmed`).
12. **direct authenticated table reads denied** (runs + run-positions); only the read RPC returns data.
13. **ingestion credential cannot update lifecycle columns** — `service_role` UPDATE of `position_state`/
    `lifecycle_updated_at`/`missing_since_run_id` denied; reconcile RPC succeeds.
14. **completed append returns `ERR_RUN_SEALED` before lease errors** (status precedence).
15. **freshness uses `captured_at`, not completion time** — a run with new `snapshot_completed_at` but old `captured_at`
    reads as **stale** via the read RPC.
16. **previous count ignores suspicious observations** — seal derives `previous_positions_count` from the latest
    healthy-complete run only.
17. **exhaustive lifecycle no-op states** — `unknown`/`not_open_confirmed`/`partial`/`closed_confirmed`/legacy-terminal
    absent rows are unchanged.
18. **conflict does not become still_open in same reconcile** — single original-state classification.
19. **suspicious run mutates zero lifecycle rows.**
20. **K read only from sealed policy** — reconcile ignores any caller K.
21. **read-RPC latest-observation semantics** — healthy+fresh / healthy-empty / suspicious / stale / newer-started.
22. **cross-account isolation** — mismatched scope → `ERR_RUN_CONFLICT` (RPC) / composite-FK violation (raw).
23. **migration preserves staging evidence** — `count(mt5_import_staging)` unchanged; existing rows untouched.

---

## Remaining decisions

- **DR-1 `source_time_msc` nullability** — kept nullable with explicit documentation; **returned by the read RPC**.
- **DR-2 `row_fingerprint`** — **RESOLVED: kept** as NOT-NULL audit/replay metadata (canonical typed digest); the
  "may be dropped" wording is removed. Field-by-field comparison remains the correctness authority.
- **DR-3 freshness location** — **RESOLVED: server/RPC-authoritative** on `captured_at` + sealed `freshness_seconds`;
  no UI-authoritative alternative.
- **DR-4 aggregate manifest algorithm** — canonical encoding + ordering (`position_id` asc, typed NULL sentinel) fixed
  in the packet draft.
- **DR-5 prev-healthy-as-stale-context** — render or warning-only under suspicious (default: warning-only + opt-in panel).
- **DR-6 K default/range** — default 2, range **1..10** (sealed); real-book sanity pass.
- **DR-7 ingestion column-grant vs RPC** — confirm whether column-level UPDATE grants cover all legitimate ingestion
  writes or whether a guarded ingestion RPC is required (Part J3).

## Actions requiring explicit user approval

Drafting the executable migration/RPC packet; applying the schema packet; applying the RPC packet; building/running the
Part L harness; implementing the S1 writer (capture → append → verify → seal → reconcile) + local run-state; the S4
browser change to consume `mt5_get_current_snapshot_v1`; the Phase-0A staging privilege narrowing (Part J3); creating
`work/mt5-s1-snapshot-lifecycle`, pushing/deploying, enabling `tj_mt5_inbox`; proceeding to S2.

## S2 compatibility (design note; do NOT implement)

Open snapshots stay immutable per-run facts; deals become append-only by `deal_id`; lifecycle joins through stable
`position_id` (a close deal annotates `partial`/`closed_confirmed` without editing sealed snapshot rows); report upload
stays fallback evidence; Journal mutation stays separate and human-confirmed.

## Final recommendation

`READY_FOR_EXECUTABLE_PACKET_DRAFT` — rev 3 freezes: one-active-cycle (`ERR_RUN_ACTIVE`), captured-at supersession
(`ERR_SUPERSEDED`), DB-derived healthy-only `previous_positions_count`, corrected consecutive-absence K (actual
membership; presence resets even after a failed reconcile) with the H1/H2/H3 proof, composite-scope lifecycle FK with
RPC-only lifecycle writes, narrowed staging privileges (no direct `service_role` lifecycle UPDATE), an RPC-only browser
read surface with server-authoritative `captured_at` freshness, append status-before-lease error precedence,
server-allowlisted completion policy, an exhaustive lifecycle CASE, NaN/side/nonblank schema constraints, and a kept
NOT-NULL `row_fingerprint` — with the executable migration/RPC packet deliberately **not** drafted until these contracts
pass review.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: rev 3 closes the narrow contract gaps from the Codex + Fable reviews (active-cycle/supersession, consecutive-K,
lifecycle FK/privilege, RPC-only read + authoritative freshness, error precedence, policy authority, exhaustive
lifecycle, schema constraints) and must pass one more adversarial review before any executable migration/RPC packet is
drafted.
Next action: On `READY_FOR_EXECUTABLE_PACKET_DRAFT`, draft the transactional schema packet + separate transactional RPC
packet + Part L harness against these frozen contracts, on a fresh `work/mt5-s1-snapshot-lifecycle` worktree off
`f37a0ef` — no scheduled mode, no deals, no Journal.
