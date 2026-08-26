# T4B closeout — promotion of a captured MT5 position into the Journal

Status: **CLOSED**. Foundation and first production canary complete, 2026-08-26.
Docs-only artifact. No executable change accompanies it.

## A. Purpose

T4B converts a durable T4A `journal_add` decision into **exactly one** canonical Journal trade,
and records that materialisation in an immutable ledger. It decides nothing: the intent is
already durable when T4B runs. It refuses rather than guesses.

## B. Final architecture

```
mt5_capture_decisions   (action = journal_add)
   -> mt5_capture_events            owner scope, position_id, basis_run_id
      -> basis S1 run               immutable contemporaneous facts
      -> newest fresh S1 run        selected by captured_at desc, run_seq desc, id desc
         -> run must be complete + healthy, and inside the freshness window
         -> position must still be present         (absence is refusal, never a close)
         -> strict 7-field equality basis vs fresh (is distinct from, no tolerance)
         -> product mapping                        (exact contract code, fail closed)
            -> public.trades row                   canonical Journal shape
            -> mt5_capture_promotions row          immutable lineage ledger
```

Ownership is never taken from the caller: `user_id`, `source_account`, `position_id` and
`basis_run_id` all come from the immutable capture row the decision points at.

Freshness is **7200 s measured from the newest run's `captured_at`** (not `completed_at`),
against `clock_timestamp()` captured after every lock the call waits on. A future-dated run
yields a negative age and is refused. The window is a server-owned `IMMUTABLE` function; no
caller can widen it.

## C. Exactly-once

Five independent layers, all DB-enforced:

1. `mt5_cp_decision_uk` — UNIQUE `decision_id`. One decision can never fulfil twice.
2. `mt5_cp_position_uk` — UNIQUE `(user_id, source_account, position_id)`. A REAPPEARANCE
   capture produces a different decision id; this is what stops a second Journal trade for
   one real MT5 position.
3. Reserved trade-id namespace — `'mt5p_' || 32 hex of the decision id`, `CHECK`-enforced
   shape, disjoint from the browser's decimal `uid()` namespace. Deterministic: the same
   decision always targets the same id. An occupant is a collision, never an adoption.
4. Incarnation marker — `trades.mt5_promotion_id`, writable by no client role, guarded by a
   trigger, unique where non-null. A deleted-and-recreated row is not this incarnation.
5. Same-decision replay — existing fulfilment is resolved **before** any eligibility is
   re-evaluated, so a promotion made while evidence was fresh stays replayable afterwards.

## D. Production foundation

- Schema and RPC packets, **revision 6**, applied 2026-08-26.
- `mt5_schema_migrations` = **10**.
- Full production security verifier: **SEC1–SEC12 PASS**.
- `mt5_promote_capture_decision_v1(uuid)` — SECURITY DEFINER, owner `postgres`,
  `search_path = public, pg_temp`, EXECUTE granted to `service_role` only. The three helpers
  have no client-executable grant. The promotion ledger is SELECT-only for `service_role`.

## E. First real canary

| | |
|---|---|
| decision_id | `8434306f-84cc-42df-afb6-fa235f6d1145` |
| capture_event_id | `80c099f3-7a7b-45bb-86a9-f295d1d0dfd3` |
| MT5 position | `312261388` (account `301102520`) |
| promotion_id | `5c7b2b29-865b-49fa-a0e1-957e4396b1f0` |
| trade_id | `mt5p_8434306f84cc42dfafb6fa235f6d1145` |
| product | `s50_next` (contract `S50U26`, contract size 200) |
| direction / status | Long / open |
| contracts | 5 (remaining 5) |
| entry_price | 1067.3 |
| basis_run_id | `6e4ede3f-9c26-4e8c-8358-4787c25c114b` (run_seq 3) |
| fresh_run_id | `081d9066-aff4-45e1-b705-663db8870a79` (run_seq 5) |
| written at | `2026-08-26 14:10:42.115385+00` |

Called through the production `service_role` PostgREST surface — deliberately not as the
owning role — so the canary exercised the same permission boundary a future materialiser will.

## F. Canary result

| | |
|---|---|
| first call | `o_ok=true, o_inserted=1`, no error |
| same-decision replay | `o_ok=true, o_inserted=0`, no error, same promotion id, same trade id |
| `mt5_capture_promotions` | 0 → **1** |
| `trades` | 155 → **156** |
| `trade_groups` | 1 → 1 (untouched) |
| duplicates created | **0** |
| pre-existing rows changed | **0 of 155** (per-row digest comparison) |
| replay mutation | none — trade row, promotion row and the full 156-row digest byte-identical before and after; `created_at = updated_at` still holds |

No S1 point-in-time truth leaked into the Journal row: `currentPrice` mirrors `entryPrice`
(the app's own default for a fresh trade), and the mark 1075.0, the floating profit 7700.0 and
every S1-only field are absent from the row entirely.

## G. Time precision — read this before trusting `raw.openDateTime`

`raw.openDateTime` carries **minute precision only**. For this trade it is
`"2026-08-24T10:36"`, meaning *2026-08-24 10:36 Asia/Bangkok ≈ 2026-08-24 03:36 UTC*.

It does **not** encode the original `:12` seconds, and it must not be described as a lossless
round-trip of the MT5 open time.

This is current canonical Journal UI serialisation, not a T4B decision and not a lineage
authority. The app's own `localNow()` is `new Date(...).toISOString().slice(0,16)` — sixteen
characters, no seconds — and the value binds straight to `<input type="datetime-local">`.
T4B deliberately follows that representation via
`to_char(open_time_utc at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI')` so a promoted row
is structurally indistinguishable from a hand-entered one. Writing a richer value here would
make T4B rows unlike every other row in the table.

The authoritative exact open time is preserved in immutable S1 evidence:
`mt5_sync_run_positions.open_time_utc = 2026-08-24 03:36:12+00`, present in **both** the basis
run `6e4ede3f-9c26-4e8c-8358-4787c25c114b` and the fresh run
`081d9066-aff4-45e1-b705-663db8870a79`. The promotion ledger stores `basis_run_id` and
`fresh_run_id`, so the exact instant is always recoverable by join. Nothing was lost; it simply
does not live in `raw`.

Runtime behaviour is unchanged by this closeout. `raw.openDateTime` was not patched.

## H. S2 boundary

Future lifecycle work (S2) must attach through the **promotion ledger's durable identity** —
`(user_id, source_account, position_id) -> trade_id` — which no user action can rewrite.

`raw.mt5PositionId` is compatibility and display metadata only: an ordinary Journal edit
rewrites `raw` wholesale through the buildTrade shape and drops it. It is not the attachment
authority.

T4B added **no** close inference, no partial-close handling, no realized P/L and no grouping.
Absence of a position from a snapshot is explicitly *not* treated as a close.

## I. Remaining book state

Not T4B correctness failures — open workflow and book-reconciliation items:

- **Capture B / position `312265597`** (S50U26, 5 lots, opened 2026-08-24 04:51:15+00) —
  still pending: no decision, no promotion.
- **Position `311607926`** (S50U26, 10 lots, opened 2026-08-14 06:45:00+00) — still has no
  Journal representation, no capture and no decision.
- **Journal trade `1783047455562`** — the manual 15-contract `s50_next` row from 2026-07-03,
  proven distinct from all three MT5 positions (see
  [`T4B_3A_s50_book_reconciliation_v1.md`](T4B_3A_s50_book_reconciliation_v1.md),
  verdict `A_BOOK_OVERLAP_CLEARED`). Untouched by the canary, and deliberately not grouped
  with the promoted trade.

No generic rule was encoded from that audit. Same product does not block promotion; same
volume does not mean duplicate. The durable MT5 identity constraints in section C are the
only duplicate guarantee.

## J. Final verdict

```
T4B_PRODUCTION_PROVEN
```
