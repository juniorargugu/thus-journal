# MT5 S1.1 — executable packet readme

Contract source: **`S1_1_account_observation_design.md`** — FROZEN, Codex approved, 2026-08-22.

> ## ⚠ S1.1 ROLLBACK MUST RUN BEFORE S1 ROLLBACK
>
> `S1_rollback_packet.sql` ends with `drop table if exists public.mt5_sync_runs;` and uses **no
> `CASCADE`**. While `public.mt5_sync_run_account` holds its composite FK to that table, the S1
> rollback **fails** at that statement.
>
> Correct order, always:
>
> 1. `S1_1_rollback_packet.sql`
> 2. `S1_rollback_packet.sql`
>
> **`S1_rollback_packet.sql` is frozen** — not its logic, not its header, not a comment. Never edit
> it to work around the dependency. Its file SHA-256 staying unchanged is an acceptance test (F4).

---

## Frozen design hash

```
812D80AE8BBD9624446BBC3FCE9898E49C5E5F136F9DFEDC56DDBDB022DE9DF1
```

Every S1.1 packet records this as `source_artifact_sha256`. The ledger CHECK requires **upper-case**
hex; the packet identity `checksum` column requires **lower-case**.

The hash is over the **LF-normalised bytes** — exactly what this prints:

```bash
git show <rev>:artifacts/mt5_reconciliation/S1_1_account_observation_design.md | sha256sum
```

This repo has `core.autocrlf=true` and no `.gitattributes`, so a Windows working-copy checkout may
hold CRLF and hash differently. **The git blob is the authority**, not the file on disk. Verify with
the command above rather than `sha256sum` on the checked-out path.

## Packet identity tokens

| Packet | Ledger version | `checksum` |
|---|---|---|
| schema | `mt5_s1_1_account_observation_schema_v1` | `cf9427c58b916c6f2dd528dd5a23fdb14ed8624fc334e4b9aa0080980276f121` |
| rpc | `mt5_s1_1_account_observation_rpc_v1` | `370a41bfe7d8d72d9e3e99aa1d38d2f4bd68c06a95cd1d1a056afa28e365c93a`  |

Each is `sha256('<ledger version>|packet-revision-3')` — a deterministic revision token anyone can
reproduce from that literal string.

**Revision history.** Nothing before revision 3 was ever applied outside the disposable test
database.

- **rev 2** — the RPC gained the S1.1 connector-namespace gate (`ERR_CONNECTOR_NOT_S1_1`);
  apply-time provenance was extended to owner/table-ACL/row-security, policy roles + `WITH CHECK`
  and function ACLs; rollback began establishing authority over every object class it removes and
  treating the RPC ledger as an absolute drop gate.
- **rev 3** — apply-time provenance extended to the **column-level** ACL (`pg_attribute.attacl`).
  See *Column ACL authority* below. The **RPC packet has no behaviour change at rev 3**: it
  validates the schema packet's identity token, and that token advanced, so its bytes and its
  declared dependency advanced mechanically with it.

The **test preflight** is at **revision 3**. It writes no ledger row (it is read-only and ends in
`rollback;`), so it carries no ledger identity token — its only checksum is its file SHA-256. Its
generations: 1 pinned the superseded revision-1 S1.1 tokens; 2 re-pinned them to revision 3; 3 split
the exact-replay predicate (below). Revisions 1–2 carried no explicit marker in the file.

### Exact-replay predicate

The preflight has exactly two green outcomes, and nothing in between:

| | |
|---|---|
| **clean first install** | no S1.1 ledger rows, no S1.1 objects → PASS, no replay message |
| **exact current replay** | `v_schema_exact AND v_rpc_exact` → PASS with the idempotent-path notice |

Each predicate is a full **per-version tuple** — `version` = its own literal, `status='applied'`,
`checksum` = **its own** identity token by equality, `source_artifact_sha256` = the frozen design
hash, and `objects->>'packet_revision' = '3'`.

Never `version IN (…) AND checksum IN (…)` in one `EXISTS`. That form proves neither that each
version carries *its own* token nor that *both* rows exist, so a schema-exact/RPC-stale database
would have been told "exact replay" by the operator's first gate and only refused by a later packet.
`checksum IN (…)` would additionally let the RPC token satisfy the schema predicate.

Because `version` is the ledger's **primary key**, at most one row can satisfy each predicate, so
`EXISTS` means *exactly one* — and `v_schema_exact AND v_rpc_exact` is therefore a sufficient proof
that both rows are present. No `count(*)` is needed.

Every partial state — schema exact + RPC stale/missing, RPC exact + schema stale/missing, swapped
tokens, or either plus a foreign object — falls through to the collision enumeration and refuses,
naming which side failed:

```
MT5_S1_1_PREFLIGHT: NOT an exact replay of the current S1.1 packet revision
  (schema_exact=t, rpc_exact=f) — S1.1 object/ledger collision (…) that this packet revision
  cannot claim. Stale or missing provenance, or an object of unknown origin; refusing to overwrite it
```

There is deliberately no optimistic partial-replay path: a partially-current installation is exactly
the state an operator most needs told about. **It is not a hash of the .sql file and proves nothing about the
deployed objects.** Destructive authority is the apply-time catalog fingerprints recorded in
`objects->'provenance'`, exactly as in frozen S1 revision 5.

---

## Execution order (disposable database only)

```
1. Phase-0A baseline
2. S1_test_preflight_packet.sql        frozen
3. S1_schema_packet.sql                frozen, unchanged
4. S1_rpc_packet.sql                   frozen, unchanged
5. S1_1_test_preflight_packet.sql   <- read-only; must PASS before any S1.1 packet
6. S1_1_schema_packet.sql
7. S1_1_rpc_packet.sql
8. S1_1_verification_packet.sql        read-only; safe to repeat
9. S1_1_rollback_packet.sql            MUST precede S1_rollback_packet.sql
```

**None of these may be run against production.** S1.1 has never been applied to production, and
applying it is a separate, separately authorised step.

---

## What each file does

### `S1_1_test_preflight_packet.sql` — read-only, no mutation, ends in `ROLLBACK`

Refuses to let S1.1 install onto anything but an intact frozen S1 revision 5:

- PostgreSQL 17.x (the validated band; the design was proven on 17.6)
- `extensions.digest`, and the `service_role` / `authenticated` / `anon` roles
- both S1 ledger rows present, `applied`, revision 5, with the expected identity tokens
- `mt5_sync_runs` / `mt5_sync_run_positions` present, with the columns and the
  `mt5_sync_runs_id_scope_uniq` key the S1.1 FK needs, and both S1 immutability triggers
- **rollback-arming proof**: both S1 table fingerprints still equal the S1 ledger provenance —
  proven *before* S1.1 adds any dependency, so a later F5/F6 result is attributable to S1.1 alone
- no unclaimed S1.1 name collision (an exact replay of this revision is allowed and logged)

### `S1_1_schema_packet.sql`

Creates `public.mt5_sync_run_account` (one immutable row per run), `mt5_run_account_guard_v1()`, the
two immutability triggers, RLS + the `service_role` SELECT policy, and the SELECT-only grant.
**It alters nothing S1 owns.**

Postflight proves: correct owner, RLS on, exactly two enabled triggers, **no** application
`INSERT/UPDATE/DELETE` grant, no column ACLs, and that the **frozen S1 table fingerprints are
unchanged** — i.e. S1 rollback is still armed after S1.1 apply.

### `S1_1_rpc_packet.sql`

Adds `mt5_account_fingerprint_v1(...)` (postgres-only) and
`mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb)` (`service_role` only).

Deliberately **absent**: any UPDATE / PATCH / correct / delete path for an account row; any exposure
or gearing RPC; any change to the frozen `mt5_get_current_snapshot_v1(text)`.

### `S1_1_verification_packet.sql` — read-only, ends in `ROLLBACK`

19 assertions: ledger rows, table shape, all 14 required constraints, **that
`mt5_sra_status_shape_chk` is still the total `CASE` / `IS NOT NULL` / `ELSE false` form**, triggers,
RLS, ACLs, RPC grant shape, no mutation RPC, the frozen browser RPC untouched, the **completed-S1.1
run invariant** (§13), the **historical exemption** (§14 — catches a backfill), one row per run,
scope/instant agreement, the 30 s window, fingerprint recomputation, and the rollback-arming
fingerprints.

Behavioural cases (the 44-case matrix) are **not** here: proving a CHECK rejects a row requires
attempting to insert it, which is a mutation. The disposable harness runs those.

### `S1_1_rollback_packet.sql`

Removes S1.1-owned objects only, after proving they match their apply-time fingerprints. Refuses if
anything was replaced or altered. Postflight proves S1.1 is gone **and** frozen S1 survived intact.

Rolling back **discards all S1.1 account evidence permanently** — account facts are immutable
contemporaneous evidence and cannot be reconstructed, because a later observation is a different
run. Export first if it still matters.

---

## Design rules the packets enforce

| Rule | Where |
|---|---|
| One immutable row per run; never overwritten | PK + guard trigger (`UPDATE`/`DELETE` → `MT5_S1_1_IMMUTABLE_ROW`) |
| Insert only while the parent run is `started` | guard → `MT5_S1_1_RUN_NOT_STARTED` |
| Account instant must equal the run's | guard → `MT5_S1_1_CAPTURE_CONFLICT` |
| `account_read_at` within a fixed 30 s window | `mt5_sra_read_at_window_chk` + the RPC (`ERR_ACCOUNT_READ_AT_WINDOW`) |
| `equity_quality='usable'` ⟺ finite and `> 0` | `mt5_sra_equity_quality_shape_chk` (total `CASE`) |
| A `failed` row must carry `ACCOUNT_READ_FAILED` | `mt5_sra_status_shape_chk` — see below |
| No `NaN` / `±Infinity` reaches storage | `mt5_sra_*_finite_chk`, defence in depth |
| Scope/provenance never trusted from the caller | RPC derives them from the locked parent run |
| Same facts replay, changed facts refuse | `account_fingerprint` → `ERR_ACCOUNT_CONFLICT` |

### The three-valued-logic rule

A PostgreSQL `CHECK` passes when its expression is **TRUE *or NULL***; only explicit FALSE rejects.
An earlier directional form,

```sql
account_observation_status <> 'failed'
OR (... AND failure_reason = 'ACCOUNT_READ_FAILED')
```

evaluated to `NULL` for a `failed` row whose `failure_reason` was `NULL` — and therefore **accepted**
it. `mt5_sra_status_shape_chk` is a `CASE` over the `NOT NULL` discriminator with `ELSE false`, whose
`failed` branch tests `failure_reason IS NOT NULL` **before** comparing it. `FALSE AND anything` is
`FALSE`, so the row is now rejected. Verification assertion **V5** guards against this being
"simplified" back.

**Do not** rewrite any of these constraints into a directional `A <> x OR (...)` form where the
right-hand side compares a nullable column to a literal.

---

## `failure_reason` boundary

`failure_reason` has exactly one v1 value, `ACCOUNT_READ_FAILED`, and one meaning:

> the second broker `account_info()` observation itself failed.

It must **never** encode a transport error, a PostgREST error, an RPC contract failure, a fingerprint
conflict, a lease error, a run-state error, or a constraint violation. Those are **operational**
errors belonging to the connector state machine, and every error code the RPC returns is one of them.

## RPC error codes (all operational — never stored)

| Code | Meaning |
|---|---|
| `ERR_BAD_INPUT` | a scalar identity argument is null/blank |
| `ERR_CONNECTOR_NOT_S1_1` | the **locked parent run** was created outside the `s1.1-oneshot/…` namespace, so it is not an S1.1 run and must not carry account evidence. `connector_version` is sealed at `create_run`, so this cannot be fixed in place — capture a new observation with `--with-account-facts` |
| `ERR_ACCOUNT_PAYLOAD_KEYS` | payload is not an object, too large, or the key set is not exactly the eight facts |
| `ERR_ACCOUNT_PAYLOAD_INVALID` | right keys, wrong JSON types or values (includes quality/status incoherence) |
| `ERR_ACCOUNT_READ_AT_WINDOW` | `account_read_at` outside the fixed 30 s window |
| `ERR_RUN_NOT_FOUND` / `ERR_RUN_CONFLICT` | unknown run, or user/account do not match it |
| `ERR_RUN_SEALED` / `ERR_RUN_FAILED` / `ERR_NOT_STARTED` | parent run is not `started` |
| `ERR_LEASE_MISMATCH` / `ERR_LEASE_EXPIRED` | lease is not held |
| `ERR_CAPTURE_TIME_INVALID` / `ERR_CONNECTOR_VERSION_INVALID` | parent run is unusable as a scope source |
| `ERR_ACCOUNT_CONFLICT` | a row exists for this run with **different** facts — never an overwrite |

`p_facts` must carry exactly these eight keys, no more and no fewer:

```
account_read_at · account_observation_status · equity · balance
currency · equity_quality · balance_quality · failure_reason
```

Exact-key validation runs *before* extraction because `jsonb_to_record` silently ignores extra keys
and silently yields `NULL` for absent or misspelled ones — a typo would become a `NULL` equity
indistinguishable from a legitimate `absent`.

---

## Cycle order

```
create_run → append_run_positions → append_run_account → complete_snapshot → reconcile_snapshot
```

`append_run_account` must precede completion because the guard requires the parent run to be
`started`. A useful consequence: the same `complete_snapshot` seals both membership and account
facts, with **no change to any frozen S1 RPC**.

`mt5_complete_snapshot_v1` stays entirely ignorant of account facts. That is deliberate — it is what
lets a bad or missing broker *value* leave the position snapshot untouched.

## Connector namespace and the two modes

The envelope format and the connector namespace are **one decision**, enforced in three places that
all quote the same prefix:

| Mode | CLI | envelope format | connector namespace |
|---|---|---|---|
| S1-only (membership) | *(no flag)* | `mt5.s1.oneshot.envelope/1` | `s1-oneshot/…` |
| S1.1 (membership + account) | `--with-account-facts` | `mt5.s1.oneshot.envelope/2` | `s1.1-oneshot/…` |

`--connector-version` has **no single default**. It defaults to `None` and is resolved *after* the
mode is known (`resolve_connector_version`). An explicitly supplied value is validated against the
selected mode and **never rewritten** — silently correcting it would hide which mode actually ran.

Why it matters: verification V13 keys the "a completed S1.1 run MUST carry exactly one account row"
invariant off `connector_version like 's1.1-oneshot/%'`, and V14 keys the never-backfill exemption
off its absence. A v2 capture stamped with the S1 namespace would be **invisible** to V13, so a lost
account row would never be reported. A v1 capture stamped with the S1.1 namespace would be reported
as an anomaly **forever**, and the only "fix" is the backfill the design forbids.

Enforced at three layers, independently:

1. `s1_rows.validate_envelope` — structural, on every entry point, before any credential or transport
2. `resolve_connector_version` — at capture time, before the terminal is opened
3. `mt5_append_run_account_v1` — server-side on the **locked** parent run, so a foreign client
   holding a service_role key cannot bypass the reviewed CLI (`ERR_CONNECTOR_NOT_S1_1`)

### Armed commands — per mode

The preview prints the armed command for you; these are what it prints. Use the one matching the
envelope you approved, because the other mode's write path refuses that envelope outright.

S1-only (v1 envelope) — **no** `--with-account-facts`:

```
set MT5_S1_WRITE=1
python ops/mt5_import/s1_snapshot.py --write --confirm WRITE_S1_SNAPSHOT \
  --envelope ops/mt5_import/out/s1_capture_<ts>.json \
  --envelope-sha256 <64-hex>
```

S1.1 (v2 envelope) — `--with-account-facts` is **required**:

```
set MT5_S1_WRITE=1
python ops/mt5_import/s1_snapshot.py --with-account-facts --write --confirm WRITE_S1_SNAPSHOT \
  --envelope ops/mt5_import/out/s1_capture_<ts>.json \
  --envelope-sha256 <64-hex>
```

Mixing them is refused before any database call: `--with-account-facts` on a v1 envelope gives
`ENVELOPE_FORMAT_NOT_S1_1`, and a plain `--write` on a v2 envelope gives `ENVELOPE_FORMAT_NOT_S1`
(accepting it would silently discard approved account facts and manufacture the V13 anomaly).

There is deliberately **no** documented command combining v2 with `s1-oneshot/…`, or v1 with
`s1.1-oneshot/…`. Neither is reachable: both are hard validation errors.

---

## Account-append failure classes (both the armed write and `--resume-account-append`)

One classifier, `classify_account_refusal`, serves both paths so they cannot drift.

| Outcome | Cleanup | Seal / reconcile | Exit |
|---|---|---|---|
| `o_ok=true` | — | resume STOPS; the armed write continues | 0 |
| transport exception (**unknown**) | **never** | never | 5 |
| `ERR_RUN_SEALED` | **never** | never | 10 |
| lease refusal (`ERR_LEASE_EXPIRED` / `ERR_LEASE_MISMATCH`) | attempted | never | 8 |
| every other returned refusal | attempted | never | 7 |

- An **unknown** outcome is never terminalised — the append may have committed, and destroying the
  exact-replay path is unrecoverable.
- A **sealed** run is never a terminalisation opportunity: account facts cannot be attached after
  the fact, and `mark_snapshot_failed` on a sealed run is both refused and wrong to ask for.
- A **lease refusal is deterministic**, not unknown, so it takes the cleanup *attempt*. That attempt
  is usually refused for the same reason; it is reported as a **secondary** cleanup failure and
  never converted into an auto-expire.
- In every case the **original refusal is printed last** and stays primary. A cleanup failure can
  never mask why the cycle stopped.

---

## Rollback destructive authority

> **NO DROP WITHOUT EXACT APPLY-TIME PROVENANCE.**

`S1_1_rollback_packet.sql` establishes authority over **every** class it can remove, in one
transaction, before any destructive statement. A refusal therefore leaves every S1.1 object and both
ledger rows exactly as they were.

| Class | Proven against apply-time provenance |
|---|---|
| schema ledger | version · `status='applied'` · checksum · `source_artifact_sha256` · `packet_revision` |
| table | owner · full column shape · constraints · indexes |
| owner / grants / RLS | table owner · normalised ACL · `relrowsecurity` · `relforcerowsecurity` |
| **column-level ACL** | every live user column's `pg_attribute.attacl`, normalised (see below) |
| triggers | `pg_get_triggerdef` + `tgenabled`, **both directions** (no unrecorded trigger may exist) |
| policy | `USING` · `WITH CHECK` · command · permissive · **roles**, both directions |
| guard function | definition · owner · `SECURITY DEFINER` · `proconfig` · ACL |
| RPC functions | **absolute gate** — see below |

### Column ACL authority — why table ACL is not enough

```sql
GRANT SELECT (equity) ON public.mt5_sync_run_account TO authenticated;
```

That statement writes `pg_attribute.attacl` and leaves **`pg_class.relacl` completely unchanged**.
Table-level grant checks, `information_schema.table_privileges`, and the `security` fingerprint
(owner · `relrowsecurity` · `relforcerowsecurity` · `relacl`) all reproduce byte-identically —
while `authenticated` now genuinely reads broker equity. Rollback would have established authority
and dropped a table whose security contract had changed after apply, destroying the evidence of the
change along with the data.

So the column ACL is its **own** provenance class, recorded at apply and re-derived at rollback with
one algorithm:

- one entry per live user column (`attnum > 0 AND NOT attisdropped`), ordered by `attnum`;
- `attnum:attname:NULL` when `attacl IS NULL`, else `attnum:attname:ACL[…]`;
- ACL entries come from `aclexplode()`, not raw `aclitem[]` text, so catalog display order is
  irrelevant; each is `grantee/grantor/privilege/grantable`, sorted;
- role OIDs resolved to **names**; grantee `0` is `PUBLIC`.

`NULL` and `ACL[]` are deliberately different strings. Revoking a grant back to an empty-but-not-null
ACL is not the pristine state, and rollback authority is *exact apply-time provenance*, not
approximate effective access.

The ledger stores both the readable normalised text (15 short entries — it lets rollback name which
column drifted) and its SHA-256 (which makes the comparison total). Apply records the value, then
proves it covers every live column, that no column ACL exists, and that it reproduces. Verification
re-proves it (**V23**, **V24**). Rollback compares it **before any destructive statement** and, on a
mismatch, refuses atomically — it does **not** revoke the foreign grant and does not repair-then-roll-back.

**The RPC ledger is an absolute drop gate.** `mt5_append_run_account_v1` and
`mt5_account_fingerprint_v1` are dropped **only** if an exact valid S1.1 RPC ledger row exists *and*
positively authorises those exact current functions (matched by OID, both directions). If the ledger
row is missing while either function exists, rollback **refuses** — ownership is never inferred from
a name or a signature. If the ledger row is missing and neither function exists, that is a partial
install and there is nothing to authorise.

Repeat rollback stays fail-closed. There is no permissive "ledger missing, just `DROP IF EXISTS`"
path, and adding one would make every same-name foreign object destroyable.

---

## Completed-run invariant

For `connector_version like 's1.1-oneshot/%'`, a completed run must have exactly one account row —
including when the broker read failed (`status='failed'`). A completed S1.1 run with no row is
`S1_1_ACCOUNT_ROW_MISSING_ANOMALY` (verification V13).

This is an **application/verification** invariant, not a database one: enforcing it with a trigger on
`mt5_sync_runs` would alter that table's structural fingerprint and disarm S1 rollback.

A pre-S1.1 run with no account row — e.g. production `run_seq=1`, `connector s1-oneshot/0.1` — is
**expected historical truth**. Never backfill it; V14 fails if anything does.
