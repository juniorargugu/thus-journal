# MT5 Auto Draft Import — Phase 0A Apply Closeout

**Status:** `MT5_PHASE_0A_SCHEMA_RLS_RPC — APPLIED & VERIFIED`

**Apply date:** 2026-06-25 (Asia/Bangkok)
**Supabase project:** `wtfwynvvkiuottjnmozu`
**Applied packet version:** r3 · repo commit `c490d6a` (*"docs: polish MT5 phase 0A SQL RPC packet"*)
**Production app commit at apply time:** `09842d7` — **DB-only change, no app/Netlify deploy**
**Source packet (historical/audit):** [`phase_0a_sql_rpc_packet.md`](phase_0a_sql_rpc_packet.md)

> 🚫 **DO NOT RE-RUN the Phase 0A apply transaction.** All objects already exist. Re-running the create-only SQL raises `already exists` (e.g. `42723`) — that is the **fail-closed CREATE guard working as designed**. Do **not** "fix forward", do **not** retry, do **not** `rollback`. Any future change is a **new reviewed migration**, never a re-run of the old packet.

---

## 1. What happened

The reviewed Phase 0A SQL/RPC packet (r3) was applied by the user in the **Supabase SQL editor** on 2026-06-25, as a single transaction, after a clean §3 conflict pre-check. The agent did **not** run SQL. A subsequent `already exists` error during a duplicate re-run confirmed the fail-closed guard; nothing was damaged or partially applied. Read-only verification (object inventory + grants + `pg_get_functiondef`) returned **PASS** across the board.

## 2. What was applied

- **3 tables:**
  - `mt5_import_staging`
  - `mt5_import_groups`
  - `mt5_import_cursors`
- **10 named indexes** (+ primary keys):
  - `mt5_groups_user_acct`, `mt5_groups_user_state`
  - `mt5_staging_open_uniq`, `mt5_staging_deal_uniq`, `mt5_staging_balance_uniq`
  - `mt5_staging_user_acct`, `mt5_staging_user_state`, `mt5_staging_group`, `mt5_staging_open_live`, `mt5_staging_created`
- **3 `updated_at` triggers:** `mt5_groups_updated_at`, `mt5_staging_updated_at`, `mt5_cursors_updated_at`
- **Helper trigger function:** `mt5_set_updated_at()` (plain `plpgsql`, `search_path=''`; **not** SECURITY DEFINER)
- **3 SECURITY DEFINER RPCs:**
  - `mt5_confirm_group`
  - `mt5_set_leg_state`
  - `mt5_mark_materialized`
- **`mt5_resolve_mapping` was DEFERRED and intentionally NOT created** — mapping authority lives in the `mt5_mark_materialized` contract_size/class tripwire.

## 3. Verification matrix (all PASS)

| Check | Expected | Result |
|---|---|---|
| 3 tables exist + RLS enabled | `relrowsecurity=t` ×3 | ✅ PASS |
| SELECT-own policies only | 2 policies, `cmd=SELECT`, role `authenticated` | ✅ PASS |
| write policies | 0 | ✅ PASS |
| browser write grants (anon/authenticated INSERT/UPDATE/DELETE) | 0 | ✅ PASS |
| anon grants | 0 | ✅ PASS |
| `service_role` write — staging | 2 (INSERT+UPDATE) | ✅ PASS |
| `service_role` write — cursors | 2 (INSERT+UPDATE) | ✅ PASS |
| authenticated RPC EXECUTE | 3 | ✅ PASS |
| helper `mt5_set_updated_at` browser execute | 0 | ✅ PASS |
| RPC bodies match reviewed r3 | — | ✅ PASS |
| &nbsp;&nbsp;• SECURITY DEFINER (3 RPCs) | yes | ✅ |
| &nbsp;&nbsp;• `search_path = ''` | yes | ✅ |
| &nbsp;&nbsp;• `trim` on `p_trade_id` | `length(trim(p_trade_id))=0` | ✅ |
| &nbsp;&nbsp;• mapping tripwire (contract_size/class) | present | ✅ |
| create-only proof — THUS tables gained no `mt5_*` columns (`trades`/`products`/`portfolio_summary`/`trade_groups`) | 0 rows | ✅ PASS |

> RPC body comments are absent in the stored definitions (the applied block was assembled comment-stripped) — the executable logic is byte-identical to the reviewed r3 packet; no logic diff.

## 4. Safety confirmations

- ✅ User ran the SQL manually in the Supabase SQL editor; **the agent did not run SQL**.
- ✅ **No app/runtime deploy** — production app remained `09842d7` (DB-only change).
- ✅ **No THUS trade created**; **no MT5 import run**.
- ✅ **No Storage changes**; **no GUGU changes**.
- ✅ **No browser write path created** (no write policy, no anon/authenticated write grant).
- ✅ **No existing THUS table altered** (create-only proof: zero `mt5_*` columns on existing tables).
- ✅ **No real trade materialization** — Phase 0A is schema/RLS/RPC only.

## 5. Known note — the `already exists` error

A later `already exists` (e.g. `42723`) error from re-running the apply packet means the **fail-closed `CREATE` guard is working**. It is expected and benign.
- **Do not re-run.**
- **Do not rollback.**
- Treat Phase 0A as **complete** unless an **explicit future migration is reviewed** (its own pre-check + review gate).

## 6. Next gated tracks (all still GATED — not started)

1. **Phase 0C — staging writer**
   - Local Python reader on the user's machine.
   - `service_role` writes **only** `mt5_import_staging` / `mt5_import_cursors`.
   - **No writes** to `trades` / `products` / `portfolio` / `notes`.
   - Must convert **MT5 Asia/Bangkok wall-clock → true UTC** before insert (`wall − 7h`).
   - Must preserve raw `mt5_time_raw_epoch` / `mt5_time_msc` / `raw` payload (lossless).
   - Must **not blind-insert** rows missing their stable idempotency key (`open`→`position_id`, `close`/`partial`→`deal_id`); skip / quarantine / reader-side dedupe instead.
2. **Phase 0D — THUS Inbox UI**
   - Read/import inbox display first; **no auto-materialization**; **confirm-first**.
3. **Phase 1 — materialization**
   - Still blocked by the **product-mapping foundation** and the **DELTA-SSF decision**.
   - `DELTAU26` (contract_size 1000) must **never** map to the DELTA stock preset (contractSize 1) — the materialize tripwire enforces this.
4. **P2-5-E Phase C** — Storage orphan deletion: still **deferred / monitor-only**.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Phase 0A schema/RLS/RPC is applied and verified; repo docs now reflect the live DB state and warn against re-running the packet.
Next action: Plan Phase 0C staging writer under a separate gated design prompt.
