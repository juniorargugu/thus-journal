# G2 Grouping RPC/Schema Apply Closeout

**Date (local):** 2026-07-05
**Status:** APPLIED — G2 first-persistence RPCs + schema live in the prod Supabase project.
**Applied by:** Junior, manually, in the Supabase SQL Editor (block by block).
**Source of truth:** [`migrations/20260705_g2_trade_group_rpcs.sql`](../../migrations/20260705_g2_trade_group_rpcs.sql)

> This apply was **DB-only**. No `index.html` / UI persistence was written. No push, no
> deploy. The client still has only the render-only G2 preview + preview-only proposal
> (commits `527be87`, `610e3c6`), both behind default-off flags; nothing in the app calls
> the new RPCs yet.

---

## What was applied

From the reviewed lean packet, applied in order:

1. `ALTER TABLE public.trade_groups ADD COLUMN IF NOT EXISTS idempotency_key text`
2. `CREATE UNIQUE INDEX trade_groups_user_idem_active_uidx` — partial, `WHERE archived_at IS NULL AND idempotency_key IS NOT NULL`
3. Ownership-guard trigger: `trades_group_id_owner_guard()` + `trades_group_id_owner_guard_trg` (`BEFORE INSERT OR UPDATE OF group_id`)
4. `create_trade_group_v1(text[], text)` — SECURITY DEFINER, `search_path=public, pg_temp`
5. `ungroup_trade_group_v1(uuid)` — SECURITY DEFINER, `search_path=public, pg_temp`
6. Grants: `REVOKE ALL … FROM public, anon` + `GRANT EXECUTE … TO authenticated` on both RPCs

The **commented ROLLBACK** block and the **OPTIONAL, DESTRUCTIVE** data-clear at the foot of
the packet were **NOT run** (they are documentation only).

The migration file committed to the repo is byte-identical to what was applied for every
executable statement — only the top comment banner was updated from "review artifact / draft"
to "applied" status (comments do not execute; verified by SHA-256 of the body from the first
`PREFLIGHT` line onward).

---

## Preflight results (read-only, run first)

| Preflight | Query | Result | Verdict |
|---|---|---|---|
| PREFLIGHT (core sha256 path) | `SELECT encode(sha256(convert_to('g2-preflight','UTF8')),'hex')` | 64-char hex returned | PASS — no `pgcrypto` fallback needed |
| PREFLIGHT 2 (id type) | `information_schema.columns … trades.id` | `data_type = text` | PASS — `text[]` / `= ANY(v_ids)` design valid |

Both stop-gates passed, so the packet proceeded to §1–§5.

---

## Verification results (V1–V5, read-only)

| Check | Expectation | Result |
|---|---|---|
| V1 idempotency_key column | exists on `trade_groups` | PASS |
| V2 unique active partial index | `trade_groups_user_idem_active_uidx`, UNIQUE, partial `WHERE archived_at IS NULL AND idempotency_key IS NOT NULL` | PASS |
| V3 owner-guard trigger | `trades_group_id_owner_guard_trg` present, `BEFORE INSERT OR UPDATE OF group_id` | PASS |
| V4 create_trade_group_v1 | exists, SECURITY DEFINER, `search_path=public, pg_temp`, auth EXECUTE = true, anon EXECUTE = false | PASS |
| V4 ungroup_trade_group_v1 | exists, SECURITY DEFINER, `search_path=public, pg_temp`, auth EXECUTE = true, anon EXECUTE = false | PASS |
| V5 baseline groups | `count(trade_groups) = 0` | PASS |
| V5 baseline grouped trades | `count(trades WHERE group_id IS NOT NULL) = 0` | PASS |

---

## Negative / no-candidate RPC smoke (authenticated, read-model unchanged)

Error-path calls returned the expected coded rejections; none mutated state:

- `invalid_child_ids`
- `too_few_children`
- `duplicate_child_ids`
- `child_not_found`
- `group_not_found`

Post-rollback baseline remained clean (`trade_groups = 0`, grouped `trades = 0`).

---

## No-candidate caveat (happy path NOT exercised)

The **happy-path create/ungroup smoke was NOT run**: at apply time there were **no eligible
open, same-family, same-direction legs** to form a real ≥2-leg group. So the following remain
**unproven in prod**:

- successful `create_trade_group_v1` (row inserted + children attached, `raw` untouched)
- idempotent re-click (`already_exists=true`, no duplicate group)
- `ungroup_trade_group_v1` archive + child clear
- the P/L invariant end-to-end (reducers ignore `group_id`) **on live grouped rows**

These are logically covered by design + the negative smoke, but not empirically confirmed.

---

## Stop gates preserved

- Apply was gated on **both** preflights passing (they did).
- Destructive rollback / data-clear **not run**.
- No unrelated SQL run.
- RPCs are `authenticated`-only; `anon`/`public` execute revoked (V4 confirmed).
- P/L invariant structurally preserved: RPCs write only `trades.group_id` (+`updated_at`),
  never `trades.raw`; `toTradeRow` still omits `group_id`; `db.loadAll` reads only `raw`.

---

## Next recommended step

1. **Controlled happy-path smoke** — once ≥2 eligible open same-family/same-direction legs
   exist (or a disposable test account is seeded): call `create_trade_group_v1`, verify the
   group row + child attach + `raw` unchanged + P/L totals byte-identical, then re-click for
   idempotency, then `ungroup_trade_group_v1` and confirm archive + clear.
2. **Gated UI wiring (later, adversarial-reviewed)** — wire the existing preview/proposal to a
   single authenticated RPC call behind a confirmation string and a default-off flag; exactly
   one RPC call per confirm; no direct `group_id` PATCH from the client.

Until step 1 passes on real rows, treat G2 persistence as **applied but not yet
production-exercised**.
