# T4B-0 — Journal promotion contract audit

Status: **DESIGN FROZEN — READY TO IMPLEMENT** (capture-A promotion gated on a fresh S1 run)
Date: 2026-08-26
Mode: read-only audit. No implementation, no production writes, no migration.

T4B answers: *"How does an approved `journal_add` decision become Journal state exactly once,
with complete provenance and without inventing trading facts?"*

---

## 1. The decisive discovery

The T4A capture payload does **not** contain a price or a real open time. It proves identity,
side, volume and detection timing only.

The **S1 append-only snapshot** does contain them, and the capture event carries the exact
`basis_run_id` that joins to it:

```
mt5_capture_events.basis_run_id  →  mt5_sync_run_positions (PK: run_id, position_id)
```

For capture A, run `6e4ede3f-9c26-4e8c-8358-4787c25c114b`:

```
symbol_raw S50U26   side buy   volume 5.0
price_open      1067.3                      ← entry price
open_time_utc   2026-08-24T03:36:12+00:00   ← real position open time
contract_size   200.0
price_current   1071.6   profit 4300.0      ← point-in-time marks: MUST NOT be persisted
```

`mt5_sync_run_positions` is immutable (`mt5_run_positions_guard_v1` raises
`MT5_S1_IMMUTABLE_ROW` on UPDATE/DELETE), so the join target cannot drift. The later run
`dafcd193-…` reports identical `price_open` / `open_time_utc` — independent corroboration.

**Consequence:** T4B is a three-way join — decision (workflow truth) × capture (event identity)
× S1 snapshot (trading facts) — not a projection of the capture alone.

## 2. Two identities, both preserved

| | Identity | Value for A | Answers |
|---|---|---|---|
| A | **Workflow / execution** | `decision_id = 8434306f-84cc-42df-afb6-fa235f6d1145` | "Has this exact human request already been fulfilled?" |
| B | **Durable MT5 trading** | `(user_id, source_account, position_id)` = `(b77d0426-355d-4f31-b94a-1afbe8fd49fa, "301102520", 312261388)` | "Which real MT5 position does this Journal object represent?" |

`capture_event_id` is **provenance/event identity** — it is neither of these and must not be
used as the long-term trading key. The canonical trading tuple is the one S1 and T2 already
scope every row by (`mt5_srp_scope_position_run_idx`, `mt5_capture_events` scope columns).

## 3. Current Journal architecture (production truth)

* Single-file React SPA (`index.html`) writing Supabase **as the authenticated user**.
* `trades` = projected columns + **`raw` jsonb holding the whole trade object**.
  Projected: `id, user_id, product_id, direction, status, contracts, remaining_contracts,
  entry_price, exit_price, entry_date, exit_date, note, group_id` (+ legacy
  `created_at, current_price, invalidation, setup, tags, target, updated_at`).
* **Canonical writer: `db.saveTrade(uid, trade)`** — single-row `upsert([toTradeRow(uid,trade)],
  {onConflict:"id"}).select("id")` with an affected-row-count tripwire. The full-array writer
  was retired in P2-4C. There is **no server-side Journal trade writer** today.
* `products` is a **single JSON blob per user**, not a relational table.
* `status` ∈ `{open, closed}` only. **There is no draft / needs-reconciliation trade state.**
* 155 trades; **121 already carry `raw.mt5PositionId`** (from the Excel/MT5 file-import path,
  which dedups on it). 2 open trades, neither MT5-linked.

### Canonical trade object (155/155 carry these keys)

`id, status, isMerged, stopLoss, contracts, direction, preImages, productId, setupType,
subTrades, entryPrice, postImages, takeProfit, contractCode, openDateTime, mergedFromIds,
partialCloses`

Optional: `preNote, postNote, currentPrice, exitPrice, exitDateTime, feeling, exitReason,
tradeRating, winLossReason, fee, mt5PositionId, swap, commission, brokerProfit`

## 4. The other MT5 track (do not confuse them)

`mt5_import_staging` (Phase 0A/0C/0D) is a **separate** pipeline: broker deal/position rows
with `price, open_time, contract_size, product_id_candidate, state='needs_mapping'`,
lifecycle (`position_state, first_seen_open_at, missing_since_run_id`) and — notably —
`materialized_at` / `materialized_trade_id`. Three rows exist, all GOU26, all `needs_mapping`,
none for capture A's position.

It already anticipates materialization. T4B should **reuse that vocabulary**, but the
S1→T2→T4A chain is the reviewed, immutable, RPC-guarded one and is the correct source. Do not
promote from staging in T4B.

## 5. Field mapping table

| Journal field | Source | Transformation | Authority | Required | Safe now | S2 later |
|---|---|---|---|---|---|---|
| `id` | generated | epoch-ms string, app convention | client convention | yes | yes | — |
| `user_id` (row) | capture/decision scope | verbatim | **A. proven** | yes | yes | — |
| `mt5PositionId` | `capture.position_id` | `String()` | **A. proven** | for MT5 rows | yes | join key |
| `contractCode` | `capture.payload.detections[].symbol_raw` | verbatim (`S50U26`) | **A. proven** | yes | yes | — |
| `productId` | contractCode × products blob | exact match on `currentContract`/`nextContract` → `s50` / `s50_next` | **C. reference mapping** | yes | yes, deterministic today | — |
| `direction` | `side` (`buy`/`sell`) | `buy→Long`, `sell→Short` | **B. derivable** | yes | yes | — |
| `contracts` | S1 `volume` (5.0) | numeric | **A. proven** (S1) | yes | yes | partial closes |
| `entryPrice` | S1 `price_open` (1067.3) | numeric | **A. proven** (S1) | yes | **only via S1 join** | — |
| `openDateTime` | S1 `open_time_utc` | UTC → BKK → `YYYY-MM-DDTHH:mm` | **B. derivable** | yes | yes | — |
| `status` | — | `"open"` | **E. lifecycle-sensitive** | yes | **gated on freshness** | S2 closes |
| `remainingContracts` | = `contracts` | copy | derived | yes (projected) | yes | S2 reduces |
| `currentPrice` | S1 `price_current` | — | **D. unsafe** — point-in-time mark | no | **omit** | — |
| `exitPrice`,`exitDateTime` | — | — | **D. unavailable** | no | omit | **S2 owns** |
| `partialCloses` | — | `[]` | — | yes | yes | **S2 appends** |
| `fee, swap, commission, brokerProfit` | — | — | **D. unavailable** (deal-level) | no | omit | **S2 owns** |
| `stopLoss, takeProfit` | — | `null` | not observed | yes | yes (null) | — |
| `setupType`, `preNote`, `preImages` | human | `""` / `[]` | **D. not inferable** | yes | yes (empty) | — |
| `isMerged, mergedFromIds, subTrades` | — | `false` / `[]` / `[]` | — | yes | yes | grouping |
| `group_id` (column) | — | `NULL` | — | no | yes | grouping |
| contract size | S1 `contract_size` (200) vs product `contractSize` (200) | **cross-check, fail closed on mismatch** | **A+C** | validation | yes | — |

## 6. Recommended architecture — exactly-once

**Recommendation: dedicated fulfillment ledger + one SECURITY DEFINER RPC (options B + C).**

```
mt5_capture_promotions
  id            uuid pk
  decision_id   uuid NOT NULL UNIQUE   ← the exactly-once key
  capture_event_id uuid NOT NULL
  user_id       uuid NOT NULL
  source_account text NOT NULL
  position_id   bigint NOT NULL
  basis_run_id  uuid NOT NULL          ← the S1 run the facts came from
  trade_id      text NOT NULL          ← the Journal trades.id created
  product_id    text NOT NULL
  entry_price   numeric NOT NULL
  open_time_utc timestamptz NOT NULL
  created_at    timestamptz NOT NULL default now()
```

```
mt5_promote_capture_decision_v1(p_decision_id uuid, p_trade_id text, p_now timestamptz)
  → (o_ok, o_inserted, o_trade_id, o_existing_trade_id, o_error_code)
```

One transaction: validate the decision exists and `action='journal_add'` → resolve capture and
scope → resolve the S1 facts by `(basis_run_id, position_id)` → check freshness → insert the
`trades` row → insert the ledger row → return insert/replay truth. `UNIQUE(decision_id)` makes
concurrency the database's problem; the client never does check-then-insert.

**Why not the alternatives:**

* **A — idempotency directly on `trades`.** The browser upserts `trades` freely on
  `onConflict:"id"` and rewrites `raw` wholesale, so any marker living in `raw` can be silently
  clobbered by a normal edit. A partial unique index on `raw->>'mt5PositionId'` would break the
  121 existing imported rows and legitimate re-import/merge histories.
* **D — an existing durable primitive.** None qualifies. `db.saveTrade` is a browser upsert on a
  client-chosen id. `create_trade_group_v1` proves the *pattern* we are copying (nullable
  `idempotency_key` + partial unique index + `SECURITY DEFINER` + locked `search_path` +
  authenticated-only EXECUTE) but is group-scoped.

Keeping provenance in a **separate table** — not only inside `raw` — is what makes the lineage
survive ordinary user edits (§9).

## 7. Promotion target semantics

**Create a canonical OPEN Journal trade, or create nothing.** There is no third truthful option:
`trades.status` is `open|closed` only, and inventing a state would break every reducer,
P/L path and UI filter. `mt5_import_staging.state='needs_mapping'` is a *staging* concept with a
read-only Inbox — it is not a Journal trade state and must not be conflated.

That is precisely why the freshness gate below is load-bearing: an `open` row is a claim about
*now*.

## 8. Staleness / lifecycle policy — **option B**

> Promotion requires a **fresh S1 observation** confirming the position is still present.

Concretely, all must hold at promotion time:
1. an `mt5_sync_runs` row with `snapshot_status='complete'` and `snapshot_health='healthy'`;
2. `captured_at` within a bounded window (proposed: **≤ 2 hours**, operator-tunable);
3. that run contains `(user_id, source_account, position_id)` in `mt5_sync_run_positions`;
4. its `price_open` and `open_time_utc` equal the values in the capture's `basis_run_id` row —
   a drift here means the position identity was reused and promotion must fail closed.

Facts are taken from the **basis run** (immutable, contemporaneous with the decision); presence
is proven by the **fresh run**.

**Current state: the newest S1 run is `run_seq 4` captured 2026-08-24T16:06:10Z — about 42 hours
stale.** S1 runs are operator-triggered, not scheduled. So capture A is **not promotable today**
without a new S1 run.

## 9. S2 boundary

T4B must never infer close, partial close, realized P/L, close price or close time from
disappearance or snapshot deltas. It must not persist `price_current` or `profit`.

S2 attaches later **additively**, joining on `(user_id, source_account, position_id)` →
`raw.mt5PositionId`, and updates `status / exitPrice / exitDateTime / partialCloses /
remainingContracts` through the existing durable update path. The promotion row and its ledger
entry are never replaced, so lineage survives closure.

## 10. Grouping boundary

Promoted rows are created with `group_id = NULL`. Grouping stays a separate concern handled by
the existing `create_trade_group_v1`, which sets the projected `trades.group_id` and rejects
`isMerged` children. Because `group_id` is a projected column and is never merged into `raw`,
grouping cannot destroy MT5 identity, decision provenance or individual leg evidence.

## 11. Product / symbol mapping

Deterministic today for capture A:

```
S50U26 → products blob: s50.nextContract === "S50U26" → registry id s50_next
         contractSize 200  ==  S1 contract_size 200.0   ✔ cross-check passes
```

The registry expands each futures product into Active (`s50` / S50M26) and Next
(`s50_next` / S50U26). The mapping rule must be **exact match on the contract code**, and must
**fail closed** when: no product matches, more than one matches, or `contractSize` disagrees
with S1's `contract_size`. The DELTA/SSF precedent already in the UI (contract size 1000 vs 1)
is exactly the failure this guard prevents. Never map by base symbol text alone.

## 12. Idempotency / failure state machine

| Condition | Outcome |
|---|---|
| first promotion | one Journal trade + one ledger row; `o_inserted=1` |
| same decision replayed | `o_inserted=0`, same `o_trade_id`, no second row |
| decision action ≠ `journal_add` | reject `ERR_NOT_JOURNAL_ADD`, nothing written |
| decision or capture out of scope | reject `ERR_SCOPE` |
| no S1 facts for `(basis_run_id, position_id)` | reject `ERR_NO_FACTS` |
| freshness gate fails | reject `ERR_STALE_EVIDENCE` (retryable after a new S1 run) |
| product mapping ambiguous / contract-size mismatch | reject `ERR_PRODUCT_MAPPING` |
| ledger says fulfilled but the trade row is gone/drifted | `ERR_FULFILLMENT_DRIFT` — incident, fail closed, never silently re-create |
| transport uncertain | no blind retry; reconcile by `decision_id` in the ledger |
| partial DB failure | impossible by construction — single transaction |
| concurrent double execution | `UNIQUE(decision_id)` ⇒ exactly one fulfillment |

## 13. Post-promotion editability

The user edits the promoted trade normally — it is an ordinary trade object. Do **not**
over-constrain.

Provenance that must not silently disappear lives in `mt5_capture_promotions`, keyed by
`decision_id` and holding `trade_id`, so a user edit to `raw` cannot erase the lineage. Inside
`raw`, `mt5PositionId` is written once and treated as immutable by convention (the app already
uses it only as a dedup key, never rewrites it). If the user edits symbol/volume/entry, the
Journal interpretation diverges from the imported evidence — that is legitimate, and the ledger
preserves what was originally imported so the divergence is inspectable rather than invisible.

## 14. Recommended trigger for v0.1

**Decision-only callback + a separate operator-run materializer.**

The Telegram callback continues to record the decision and nothing else. Promotion runs as an
explicit operator step (e.g. `python -m gugu.mt5_promote --decision-id <uuid>`), because:

* the freshness gate needs an S1 run that is itself operator-triggered;
* the first Journal write should be inspected before it lands;
* it keeps the callback path — already reviewed and canaried — unchanged.

A second in-Telegram confirmation step is a natural later evolution once the promotion path has
production history.

## 15. Capture-A canary prerequisites

Before A may be promoted:

1. a fresh healthy S1 run containing position 312261388 (currently ~42 h stale);
2. `mt5_capture_promotions` + `mt5_promote_capture_decision_v1` deployed and reviewed;
3. product mapping check passes (`s50_next`, contract size 200 — verified today);
4. **book-state decision by Junior.** MT5 shows three S50U26 positions
   (311607926 ×10 @ 1077.5, 312261388 ×5 @ 1067.3, 312265597 ×5 @ 1069.4) and the Journal has
   one open `s50_next` trade of 15 contracts @ 1069.9 dated 2026-07-03 with no `mt5PositionId`.
   Promoting A alone leaves a knowingly partial and possibly double-counted book. This is a
   business decision, not a technical one.

## 16. Security / write surface

* New RPC only. **No broad service-role direct table write** to `trades`.
* `SECURITY DEFINER`, `SET search_path = public, pg_temp`, `REVOKE ALL … FROM public, anon`.
* `GRANT EXECUTE … TO service_role` only (the bot is the caller; the browser has no reason to
  promote). This mirrors `mt5_record_capture_decision_v1`, which is service_role-only.
* Ownership: `user_id` is derived server-side from the decision→capture chain, never supplied.
* RLS on `mt5_capture_promotions`: no browser grant in v0.1 (read-only exposure can be added
  later, as `mt5_import_staging` did).
* Replay semantics identical to T4A: shape-identical result rows, `o_inserted` distinguishes.

## 17. Test ladder

1. offline contract/unit tests (mapping, direction, time conversion, field completeness, the
   full outcome matrix) — hermetic, fake transport;
2. local disposable-Postgres concurrency/idempotency probes for the RPC (double execution,
   fulfillment drift, stale evidence);
3. one exhaustive external review after implementation;
4. production read-only preflight;
5. one controlled promotion of capture A;
6. exact replay verification (same `trade_id`, no second row);
7. Journal read-back smoke — the trade appears with correct product, direction, size, entry and
   open time, and no invented P/L.

## 18. Open risk carried from T4A

Production bot commits `9fb310d` and `9123320` are **local only** (`origin/main` = `16798a4`),
and `thus-journal` has 30 unpushed commits across branches including the entire S1→T4A
foundation (`origin/main` = `f37a0ef`). The running production system is not remotely preserved.
Separate gate.
