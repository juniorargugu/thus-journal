# T4B-1 — Journal promotion contract (frozen)

Status: **IMPLEMENTED, UNCOMMITTED, NOT APPLIED ANYWHERE**
Revision: **6** — supersedes revisions 1–5 after five external reviews. Each superseded defect is
named inline rather than deleted, because every one of them is a trap worth remembering.
`T4B_0_contract_audit_v1.md` is the preserved audit and is **not** rewritten; this document records
the amendments T4B-1 froze on top of it.

---

## 1. The three-way join

A capture event does not contain the facts a Journal trade needs — **no price, no real open time**.
The capture carries `basis_run_id`; the immutable S1 row for `(basis_run_id, position_id)` carries
`price_open`, `open_time_utc` and `contract_size`.

```
mt5_capture_decisions.id                 the human's durable request
  → mt5_capture_decisions.capture_event_id
  → mt5_capture_events (user_id, source_account, position_id, basis_run_id)
  → mt5_sync_run_positions (basis_run_id, position_id)      ← the FACTS
  → mt5_sync_runs: newest run for the scope                 ← the PRESENCE proof
  → public.products catalog                                 ← the MAPPING
  → public.trades  +  public.mt5_capture_promotions         ← one transaction
```

Facts always come from the **basis** run (contemporaneous with the decision, immutable). Presence
always comes from the **fresh** run. The fresh run is never a source of facts.

## 2. Freshness: newest run, 2 hours, server-owned, wall clock

`mt5_t4b_freshness_window_v1()` returns `interval '7200 seconds'`. It is a function so it has one
definition the verifier can assert, and the promotion RPC takes **no interval argument at all** —
no caller can supply, widen or bypass it.

The rule selects the **newest run for the exact `(user_id, source_account)` scope regardless of its
state**, then requires that run to be `snapshot_status='complete'`, `snapshot_health='healthy'`, and
captured within the window. A newer failed / incomplete / suspicious run is **never skipped in
favour of an older healthy one**.

**Frozen boundary, one definition for SQL, doc and tests:**

| evidence age | outcome |
|---|---|
| `age < 0` (future-dated capture) | `ERR_STALE_EVIDENCE` |
| `0 ≤ age ≤ 7200s` | fresh — **exactly 7200 is allowed** |
| `age > 7200s` | `ERR_STALE_EVIDENCE` |

**The clock is `clock_timestamp()`, captured once, after every lock this call waits on.** Revision 1
used `now()`, which is transaction-start time: a call could enter the transaction while the evidence
was fresh, block behind another writer for longer than the window, and then promote against evidence
that had gone stale while it waited. One instant is captured and reused for both comparisons, so
they cannot disagree with each other.

## 3. Strict seven-field basis ↔ fresh equality

`position_id, symbol_raw, side, price_open, open_time_utc, contract_size, volume` must all be
`is distinct from`-equal. Exact canonical semantics: numeric equality by value, no tolerance, no
rounding, no epsilon.

**Volume is included and load-bearing.** A changed volume may be a scale-in, a partial close or a net
lifecycle change, and S2 is not available to tell them apart. T4B does not promote the reduced
volume, the increased volume, an average, or the latest. It returns `ERR_POSITION_FACT_DRIFT`.

## 4. Dual exactly-once identity — both DB-enforced

| Axis | Constraint | Answers |
|---|---|---|
| Workflow fulfilment | `UNIQUE(decision_id)` | "has this exact human request already been fulfilled?" |
| Durable MT5 trading | `UNIQUE(user_id, source_account, position_id)` | "does this real MT5 position already have a promoted trade?" |
| Object | `UNIQUE(trade_id)` | "is this Journal row claimed by more than one promotion?" |
| Incarnation | `UNIQUE(trades.mt5_promotion_id) WHERE NOT NULL` | "is this Journal row the object one promotion created?" |

`UNIQUE(decision_id)` alone is **not sufficient**: a later REAPPEARANCE capture for the same real
position produces a different `capture_event_id` and a different `decision_id`, and would happily
create a second Journal trade for one position.

## 5. Trade identity: a reserved namespace the browser cannot reach

```
trade_id := 'mt5p_' || replace(decision_id::text, '-', '')
         -- e.g. mt5p_8434306f84cc42dfafb6fa235f6d1145
```

Deterministic from the decision id, lowercase, canonical, `text`. No wall-clock component, no
random retry loop, no global id-mint lock: the same decision always targets the same address.
Enforced by `CHECK (trade_id ~ '^mt5p_[0-9a-f]{32}$')`, not merely by the minting code.

**Why the namespace had to move.** Revision 1 minted decimal epoch-ms ids — the browser's own
namespace. `db.saveTrade` upserts with `onConflict:"id"` and participates in no T4B lock, so a
same-millisecond browser write could overwrite a promoted row. The generator is
`let _seq = Date.now(); const uid = () => \`${++_seq}\`` — pure decimal digits — so a `mt5p_` prefix
is unreachable from it under any clock, at any millisecond.

**Compatibility, audited rather than assumed** (`thus-journal/index.html`, 661 KB, single-file SPA):

* `trades.id` is `text`. Proved twice: a non-numeric PostgREST filter returns rows instead of
  `22P02`, and the applied migration `20260705_g2_trade_group_rpcs.sql` carries the same hard
  precondition in its own preflight (it passes ids as `text[]` and compares `trades.id = ANY(...)`).
* The only regex ever applied to a trade id is the demo-trade guard `/^m\d+$/` at
  `detectUnsafeMockTrades`. `mt5p_…` cannot match it — `t` follows `m`, not a digit. A namespace
  like `m123…` would have been silently refused by the writer; this is tested, not reasoned about.
* No arithmetic, ordering, `parseInt`, `Number()`, routing or hash use of trade ids anywhere. Every
  comparison is `===` on strings or `String()`-wrapped on both sides.
* `create_trade_group_v1(p_child_ids text[])` already treats trade ids as text.
* React keys, `filter(t => t.id !== id)`, `mergedFromIds`, `subTrades`, `childIds` and the G2
  child-id hash are all string operations.

**Collision policy.** If the reserved id is already occupied by anything that is not this decision's
fulfilled incarnation: `ERR_TRADE_ID_COLLISION`. Never overwrite, never upsert into it, never treat
it as replay, never pick a nearby id. The schema packet's preflight additionally asserts that **no
existing Journal row occupies the `mt5p_` namespace** before any T4B object is created.

## 6. The incarnation marker

`public.trades.mt5_promotion_id uuid`, nullable, no default, carrying the promotion's own id.

It answers the one question id-plus-owner cannot: *is this row the object T4B created, or merely a
row that reuses the address?* Revision 1 validated `id + user_id` only, so deleting a promoted trade
and creating any same-owner row with the same id produced a clean replay against an unrelated
object.

**Ordinary Journal editing is untouched.** Nothing about the trade's content is constrained — no
hash, no frozen row, no locked fields. The marker survives edits by exactly the mechanism that
already carries `group_id`:

* `toTradeRow()` emits 13 columns and not this one; PostgREST upsert compiles to
  `INSERT … ON CONFLICT (id) DO UPDATE SET <payload columns>`, and a column absent from the SET
  list keeps its stored value.
* `db.loadAll` selects `(raw, group_id)` and rehydrates from `raw`, so the marker never enters the
  app's in-memory trade object and can never be echoed back.
* `DELETE` then a fresh `INSERT` takes the insert path, where the marker defaults to NULL — which is
  precisely the drift signal wanted.

**Two layers, and the second is the load-bearing one.**

The `BEFORE INSERT` guard requires a matching ledger row to already exist (`p.id =
NEW.mt5_promotion_id AND p.trade_id = NEW.id AND p.user_id = NEW.user_id`); the ledger has no
`INSERT` grant to any client role and is append-once. The `BEFORE UPDATE OF mt5_promotion_id` guard
makes the marker immutable in every direction. `DELETE` is deliberately unguarded: a promoted trade
stays deletable, and the ledger survives it.

**The guard alone was not enough, and revision 2 shipped believing it was.** The Journal's existing
table-level `INSERT` privilege extends to any column added later, including this one. An
authenticated owner could therefore read their own marker, delete the trade, and re-insert the same
`(id, user_id, mt5_promotion_id)` tuple — which the guard *correctly* accepts, because that tuple
genuinely matches its ledger row. The guard cannot tell a restoration from the original write.
Revision 2's own test suite proved the exploit and called it a feature.

So revision 3 removes the privilege: every grantee that held table-level `INSERT`/`UPDATE` on
`public.trades` keeps it, expressed as column-level grants over **every column except the marker**.
The column list is derived from the live catalog, not hardcoded. `SELECT` and `DELETE` are
untouched, the RLS policies are untouched, and this is the **only** place T4B narrows the Journal's
writer surface — by exactly one column. The marker becomes writable only by the table owner, which
means only by the `SECURITY DEFINER` RPC.

`SELECT` on the marker is deliberately *not* revoked. Once the column cannot be written by a
client, knowing its value buys an attacker nothing; probe X1b demonstrates the client reading its
own marker and still being unable to use it. Secrecy is not the control — privilege is.

Both halves are asserted as **effective** privileges via `has_column_privilege`, not by reading
`attacl`: only the effective check resolves role membership, inherited grants and `PUBLIC`.
Superusers and PostgreSQL's predefined administrative roles (the reserved `pg_` prefix —
`pg_write_all_data` can write every table by design) are out of scope; the threat model is the
Journal's own client roles.

## 7. Replay precedence (ordering is the contract)

```
call shape → lock(decision) → resolve decision + capture scope
  → EXISTING PROMOTION BY decision_id?  → replay / fulfilment-drift   ← before any eligibility
  → action must be journal_add
  → lock(user, account, position) → position already promoted?        ← cross-decision guard
  → CAPTURE THE ELIGIBILITY CLOCK (clock_timestamp)                   ← after all blocking locks
  → basis facts → freshness → presence → seven-field equality → product mapping
  → reserved trade id free? → insert promotion, then trade (one transaction)
```

A decision promoted while the evidence was fresh stays replayable **tomorrow** — after the window
closes, after the position disappears, after the catalog changes.

Replay requires: the trade **exists**, is owned by the **same user**, and carries the **same
incarnation marker**. Anything else is `ERR_FULFILLMENT_DRIFT`. There is exactly one implementation
of that rule, `mt5_t4b_validate_fulfillment_v1`, and both the ordinary replay path and the
uniqueness-race path call it — a shallow "a row exists, call it replay" on either path would
reintroduce the defect the marker fixes.

## 8. Uniqueness handling is constraint-aware

The sole exception handler catches `unique_violation`, reads `CONSTRAINT_NAME` via
`GET STACKED DIAGNOSTICS`, and dispatches on it. There is no `when others` anywhere.

| constraint | outcome |
|---|---|
| `mt5_cp_decision_uk` | re-resolve, then **full incarnation replay validation** |
| `mt5_cp_position_uk` | `ERR_POSITION_ALREADY_PROMOTED` with existing lineage |
| `mt5_cp_trade_uk` | `ERR_TRADE_ID_COLLISION` |
| `mt5_trades_promotion_uk` | **re-raise** — a marker collision is an internal defect, not an outcome |
| any constraint on `public.trades` (matched by relation, not name) | `ERR_TRADE_ID_COLLISION` |
| anything else | **re-raise** |

Revision 1 caught every `unique_violation` and guessed by re-querying, so an unrelated uniqueness
defect could be reported as `ERR_PROMOTION_RACE` — a recognised-looking outcome. That code is gone.

## 9. No lifecycle inference

T4B never derives close, partial close, realized P/L, close price, close time, commission, swap or
fees. **Disappearance is not a close** — it is `ERR_POSITION_ABSENT`, a refusal to assert "open"
today. The S1 marks `price_current` and `profit` are never persisted; verification asserts their
literal values appear nowhere in the created row.

## 10. Journal target semantics

One canonical trade with `status = 'open'`, or nothing. `trades.status` is `open|closed` only;
inventing a third state would break every reducer, P/L path and filter. `needs_mapping` is a
*staging* concept from the unrelated Phase-0A track and is never a Journal trade status.

The created row reproduces the browser contract exactly:

* projected columns as `toTradeRow` writes them, with `entry_date` / `exit_date` / `note` **NULL**
  (they are NULL in 155/155 production rows because no trade object carries those keys);
* `raw` with exactly the 19 keys `buildTrade()` emits for a new open trade, **plus**
  `mt5PositionId`;
* `currentPrice` mirrors `entryPrice`, which is what `buildTrade` does for a fresh trade. It is the
  app's own default, not the S1 mark;
* `openDateTime` is a Bangkok wall-time `datetime-local` string at minute precision;
* `group_id` NULL.

## 11. Product mapping

Exact contract-code match against the user's catalog, reproducing the registry's Active (`id`) /
Next (`id || '_next'`) expansion. **Never a base-symbol prefix.** Fails closed on: no match, more
than one match, missing or non-numeric `contractSize`, or a `contractSize` that disagrees with the
S1 `contract_size`. That last guard is what stops an SSF/stock catalog collision (size 1000 vs 1)
from silently creating a position a thousand times the real one.

**The catalog itself must be exactly one row for the user.** Zero rows or several rows are both
`ERR_PRODUCT_MAPPING`, enforced at runtime by an explicit count and independent of schema.
Revision 1 used a non-`STRICT` `SELECT INTO`, which would have let PostgreSQL pick an arbitrary
catalog row if duplicates ever existed. The schema preflight additionally asserts the PK/UNIQUE on
`products(user_id)` that the app already depends on (`db.loadAll` reads it with `.maybeSingle()`,
which errors on a second row); the runtime count stays mandatory either way.

For capture A the mapping is deterministic today: `S50U26` → `s50_next`, size 200, matching S1's 200.

## 12. S2 attaches through the ledger, not through `raw`

**Authoritative future S2 linkage:**

```
(user_id, source_account, position_id) → mt5_capture_promotions → trade_id
```

The immutable promotion ledger is the durable mapping. `raw.mt5PositionId` is **initial
compatibility, display and import metadata** — useful while present, but *not* the attachment
authority: the browser rewrites `raw` wholesale through the 19-key `buildTrade` shape on every
ordinary edit, which drops the extra key. Revision 1 named `raw.mt5PositionId` as the S2 join and
was wrong about durability.

## 13. Grouping boundary

Promoted rows are created with `group_id = NULL`. T4B never calls `create_trade_group_v1` and never
auto-groups by symbol, account or family. Because `group_id` is a projected column never merged into
`raw`, later grouping cannot destroy MT5 identity, decision provenance or leg evidence.

## 14. No blanket product-overlap block

There is deliberately **no** rule of the form "any existing open trade on the same product blocks
promotion". A user may legitimately hold several independent positions in one product. The capture-A
overlap below is a specific unresolved book condition, not a general invariant, and is handled by the
canary preflight rather than by the RPC.

## 15. Result contract (frozen)

`o_ok · o_inserted · o_promotion_id · o_trade_id · o_existing_decision_id · o_error_code`

`ERR_BAD_INPUT · ERR_DECISION_NOT_FOUND · ERR_EVIDENCE_NOT_FOUND · ERR_NOT_JOURNAL_ADD ·
ERR_POSITION_ALREADY_PROMOTED · ERR_BASIS_NOT_FOUND · ERR_BASIS_INCOMPLETE · ERR_STALE_EVIDENCE ·
ERR_POSITION_ABSENT · ERR_POSITION_FACT_DRIFT · ERR_PRODUCT_MAPPING · ERR_FULFILLMENT_DRIFT ·
ERR_TRADE_ID_COLLISION`

Thirteen codes, each with exactly one meaning; none overloaded. `ERR_TRADE_ID_EXHAUSTED` and
`ERR_PROMOTION_RACE` were removed in revision 2 — the first became unreachable when minting became
deterministic, the second was the "translate an unknown defect into a known-looking outcome" hazard.

`ERR_BASIS_INCOMPLETE` was added during implementation and is not in the T4B-0 audit: S1 permits
`price_open` / `open_time_utc` / `contract_size` to be NULL, and a null entry price is a distinct
condition from a missing basis row.

## 16. Security surface

* One RPC: `mt5_promote_capture_decision_v1(uuid)` — `SECURITY DEFINER`, owner `postgres`, exactly
  one overload, `search_path = public, pg_temp` asserted by **exact equality** (a path that merely
  *contains* `search_path=` would admit `public, pg_temp, evil`), `EXECUTE` granted to
  **service_role only**.
* Three helpers — freshness window, fulfilment validator, product mapper — executable by **nobody**
  but the definer.
* Ledger: RLS enabled, one policy (service_role SELECT), no table or column grant to any client role.
* No broad service-role direct table writer was introduced.
* T4B narrows the Journal's `authenticated` writer surface on `public.trades` by **exactly one
  column** — the incarnation marker — and nothing else. Because a table-level `REVOKE` also drops
  that grantee's matching column privileges, the replay surface is computed per
  (grantee, privilege, column) as `table.is_grantable OR bool_or(column grant's is_grantable)`
  *before* anything is revoked: an option carried only by a column entry would otherwise be
  flattened away, which would narrow more than the marker. `SELECT`, `DELETE` and the RLS policies are
  untouched, every other column stays writable by exactly the roles that could write it before, and
  the rollback restores the table-level grants from a snapshot the apply recorded. (Revision 2 said
  T4B "does not narrow" this surface. That was true of revision 2 and is not true now; §6 explains
  why the guard trigger alone could not make the marker unforgeable.)
* That narrowing is **only** lossless over an owner-granted write surface. If any `INSERT`/`UPDATE`
  privilege on `public.trades` was granted by someone other than the owner — what an *exercised*
  grant option looks like in the catalog — the apply and the rollback both refuse. PostgreSQL
  tracks each ACL entry against its grantor and refuses to revoke a grant with dependent
  privileges, so a delegation chain can neither be revoked nor rebuilt by a packet running as the
  owner. Narrowing the contract and failing closed beats half-migrating a chain.
* The snapshot identifies each grantee by **role OID**, with the name recorded alongside for human
  readers only. A rename keeps the OID, so the principal is restored under whatever it is called
  now; a drop-and-recreate produces a new OID, so the name-reusing replacement is deliberately
  *not* handed the privileges of the role it replaced, and the loss is reported as a `NOTICE`.
* The verifier checks **definitions, not names**: `pg_get_constraintdef`, `conkey`/`confkey` resolved
  to column names, `pg_get_indexdef`, trigger timing/events/enabled-state/function, `proargtypes`,
  output column names and types, exact `proconfig`, and ACL **allowlists** built from
  `aclexplode` rather than a denylist of known-bad role names.
* **Exact deployed bodies.** Metadata says nothing about behaviour: a validator replaced by
  `select true`, or a product mapper returning an arbitrary product, keeps its signature, owner,
  security flag, volatility, `search_path` and ACLs. The apply packets record
  `sha256(pg_get_functiondef())` for all six T4B functions in the migration ledger, and the
  read-only verifier re-derives and compares them exactly. Revision 2 pinned metadata only.
  (A PostgreSQL major-version upgrade can re-render `pg_get_functiondef`; re-verify and re-record
  after one.)
* **...and the digest set is an INVENTORY, not a count.** Revision 3 required six recorded digests
  and compared whichever keys it found. Swapping a required key for an unrelated deployed function
  and recording *its* correct digest keeps the total at six and every remaining comparison green,
  while the T4B body that fell out of the set is verified by nothing at all. Each version now
  asserts its own exact key set, and the digest loop walks the **expected** list rather than the
  recorded one, so a renamed or removed key reports a missing digest as well as a bad inventory.
  Keys are full identity signatures (`public.name(argtypes)`) resolved through `to_regprocedure`,
  so a same-named overload cannot stand in for the real function either — and no ledger-supplied
  text is ever passed to `to_regprocedure`, where a malformed key would raise instead of report.
* **Required grants are asserted, not merely bounded.** An allowlist rejects extras but says nothing
  about grants that went *missing*: revoking `service_role`'s `SELECT` on the ledger, or its
  `EXECUTE` on the RPC, leaves a strict subset of the allowlist. Every required effective privilege
  is now asserted directly with `has_table_privilege` / `has_function_privilege`, which is also why
  this is not simple set equality — the owner's implicit privilege set differs between PostgreSQL
  majors and is not part of the contract.

## 17. Migration provenance

`checksum` is the **canonical packet digest**: sha256 over the packet's LF-normalised bytes with its
own digest slot normalised to 64 zeros. `source_artifact_sha256` is the sha256 of **this document**.
Both are produced and verified by `T4B_packet_identity.py` and recorded a third time in
`T4B_packet_manifest_v1.json`; none is hand-maintained.

Revision 1 recorded `sha256('<version>|packet-revision-1')` — a restatement of the version string,
under which every byte of SQL could change with the identity constant — and carried an unrelated T3
fixture digest as the source artifact. Changing one byte of executable SQL now fails `--check`.

Revision 2 generated the identities correctly but **read them back only by shape**: the verifier
accepted any two distinct checksums that were not the old T3 value, so arbitrary ledger identities
passed. The verifier now carries the **exact expected** schema checksum, RPC checksum and contract
digest — stamped into it by the same generator, so they cannot be hand-maintained or drift — and
compares each version against its own expected value.

## 18. Rollback and reapply

Rollback **removes** both ledger rows, matching what S1, S1.1, T2 and T4A all do. Revision 2 flagged
them `rolled_back` and left them in place, which quietly made both versions unreapplyable: the apply
packets `INSERT` into a version-primary-key ledger, so the documented rollback-then-reapply sequence
died on a duplicate key and took the whole apply transaction with it. Rollback also restores each
grantee's table-level `INSERT`/`UPDATE` on `public.trades`, so the writer surface returns exactly to
its pre-T4B shape rather than staying pinned to a column list T4B happened to compute.

Restoring `public.trades`' write privileges takes a **snapshot**, not a rediscovery. Revision 3
read `pg_class.relacl` at rollback time to find out whom to re-grant — but the apply had revoked
precisely those entries, so the loop found no non-owner `INSERT`/`UPDATE` grantee and restored
nothing. The column grants T4B left behind kept ordinary writes working, which is exactly why a
"can the app still insert?" probe passed; the table-level privilege and its grant options stayed
gone, and every column added after T4B would have been unwritable.

The schema packet therefore captures the pre-T4B non-owner `INSERT`/`UPDATE` shape — table-level
and column-level, grantee, grantor, privilege and grant option — *before* the narrowing touches it,
and records it in its ledger row as `objects->'trades_prior_write_acl'`. The rollback clears the
current write surface at both levels — a table-level `REVOKE` does take that grantee's matching
column privileges with it, but it reaches only grantees and privileges that *have* a table entry,
and T4B's own narrowing leaves column-only grantees behind by construction — replays the snapshot,
and then asserts restoration two ways: the recomputed shape must
equal the recorded one exactly, and every table-scope grantee must pass `has_table_privilege`. If
the ledger row exists but carries no snapshot, the rollback refuses rather than guessing.

**Identity is the role OID.** A PostgreSQL role can be renamed (same principal, new name) or dropped
and recreated under the same name (new principal, same name), and a name-keyed snapshot gets both
wrong in the dangerous direction — the rename reads as a disappearance, and the recreation reads as
the original coming back, so the replacement inherits privileges that were never granted to it. The
snapshot records `grantee_oid` and keeps the name only for human readers; the rollback resolves each
entry by OID, grants a renamed role under its current name, and treats a name reused by a different
OID as **non-restorable**, reporting it as a `NOTICE` that names the role rather than silently
glossing it or fatally raising. Probe NEG-N3 confirms the pre-fix behaviour: the name-keyed rollback
did hand the replacement role the original's `UPDATE` privilege.

**Grantors are a scope limit, not a thing to replay.** An ACL entry belongs to the role that granted
it, a `REVOKE` only removes entries the current user granted, and PostgreSQL refuses to revoke a
grant whose option has been exercised because dependent privileges hang off it. T4B revokes and
re-grants as the owner, so it is lossless only over an owner-granted surface. Rather than pretend to
rebuild a delegation chain — which would require the packet to become each grantor in turn — the
apply **and** the rollback refuse when any non-owner `INSERT`/`UPDATE` grantor exists on
`public.trades`, naming the offending entries and what to do about them. Both also refuse unless the executor **is** the table owner or a
superuser. PostgreSQL pins a grant's grantor to the owner deterministically only in those two
cases; for any other executor — a role that merely inherits the owner included — the containing
grantor it selects is documented as unspecified, and a grantor the packet did not choose is one
the rollback cannot revoke. Membership (`pg_has_role(..., 'USAGE')`) was too weak a test. The apply
postflight and the read-only production verifier (SEC8m) both assert owner attribution on the live
catalog afterwards, rather than inferring it from who ran the packet. Probe NEG-N1 confirms what the preflight is standing in
front of: without it the apply dies on `ERROR: dependent privileges exist`.

Rollback still refuses on three independent conditions: any durable promotion exists, any live trade
carries an incarnation marker, or anything occupies the reserved namespace. It contains no statement
that deletes or updates a Journal trade.

## 19. Rollout gates (none of which T4B-1 opens)

1. External review of this diff.
2. Commit.
3. Production preflight (read-only), including `python T4B_packet_identity.py --check` against the
   exact bytes about to be pasted.
4. Apply schema + RPC packets, then the read-only security verifier.
5. **Capture-A canary preconditions**, all still open:
   * a fresh healthy S1 run containing position 312261388 — the newest run is currently ~42 h old,
     and S1 runs are operator-triggered;
   * the book-overlap decision. MT5 shows three S50U26 positions (311607926 ×10, 312261388 ×5,
     312265597 ×5) while the Journal holds one open `s50_next` trade of 15 contracts @ 1069.9 dated
     2026-07-03 with no `mt5PositionId`. Whether that row already represents some of these positions
     is unknown. T4B must not auto-match, merge, mark already-logged, or alter it. **This is an
     operator/business reconciliation, not a technical gate.**
6. One controlled promotion, then replay verification, then a Journal read-back smoke.

Capture B (`7cdbdb0c-…` / 312265597) stays pending and untouched throughout.
