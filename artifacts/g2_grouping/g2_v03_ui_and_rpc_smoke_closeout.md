# G2 v0.3 — UI create-only + RPC happy-path smoke closeout

**Date (local):** 2026-07-06
**Status:** v0.3 create-only implemented, adversarially reviewed, and smoke-verified.
**Deployment:** LOCAL ONLY — default-OFF flags, un-pushed, **not deployed**.

---

## Local commit stack (unpushed, ahead of origin/main)

| SHA | Summary |
|---|---|
| `527be87` | feat: add G2 grouping preview UI (v0.1, render-only) |
| `610e3c6` | feat: add G2 group proposal preview (v0.2, preview-only modal) |
| `f2a7d9f` | docs: record G2 grouping RPC schema apply |
| `9c77629` | feat: add gated G2 group create action (v0.3 create-only) |
| `27fc357` | fix: guard G2 create action by write flag |

---

## Schema / RPC status

- Applied in prod Supabase **2026-07-05**. Source-of-truth: [`migrations/20260705_g2_trade_group_rpcs.sql`](../../migrations/20260705_g2_trade_group_rpcs.sql).
- Objects: `trade_groups.idempotency_key`, unique **active** partial index, owner-guard trigger, `create_trade_group_v1(text[],text)`, `ungroup_trade_group_v1(uuid)`. Both `SECURITY DEFINER`, `search_path=public, pg_temp`, `authenticated`-only.
- Apply record: [`g2_schema_apply_closeout.md`](./g2_schema_apply_closeout.md).

---

## Negative / no-candidate smoke (2026-07-05)

`invalid_child_ids`, `too_few_children`, `duplicate_child_ids`, `child_not_found`, `group_not_found` all returned their expected coded rejections; post-rollback baseline stayed clean.

---

## Happy-path RPC rollback smoke (2026-07-06) — **PASS**

Run inside `BEGIN; … ROLLBACK;` in the Supabase SQL Editor with a simulated `auth.uid()`. Candidate confirmed read-only via PostgREST first.

- **user_id:** `b77d0426-355d-4f31-b94a-1afbe8fd49fa`
- **children:** `1782833054555` (5 contracts) + `1783351013452` (3 contracts, the new GOU26 row) — `gold_next` / `Long`
- **create_result:** `ok=true, created=true`, `group_id=87585d32-e49a-4b2c-8920-95513ddee606`; both children attached to that group inside the transaction
- **recreate_result:** `ok=true, created=false, already_exists=true` (idempotency verified)
- **ungroup_result:** `ok=true, archived=true, cleared=2`; both children `group_id=NULL` after
- **ROLLBACK** completed. Post-rollback baseline: `trade_groups_count=0`, `grouped_trades_count=0`, `gold_group_label_count=0`
- **No persistent grouped data left behind.**

P/L invariant holds: the RPCs write only `trades.group_id` (+`updated_at`); `raw` is untouched; reducers walk `raw` and ignore `group_id`.

---

## UI v0.3 behavior + flags

Two **independent, read-only, default-OFF** localStorage flags:

- `tj_trade_group_ui_v01` — shows the grouping preview + proposal modal.
- `tj_trade_group_write_v01` — **independent** write gate; only with **both** on does the modal expose a Create action.

| ui flag | write gate | behavior |
|---|---|---|
| off | — | no grouping UI |
| on | off | preview + proposal modal; **no Create button; no RPC possible** |
| on | on | Create action; typed confirm exactly `CREATE GROUP`; disabled until matched + while creating; Close/backdrop disabled while creating |

Write path (only in the both-on state): exactly one `SUPA.rpc("create_trade_group_v1", {p_child_ids: childIds.map(String), p_label: null})`. Dual error handling (transport `error` **and** `data.ok===false`) keeps the modal open with a mapped message (13 codes + fallback). Success → success toast + close + session-only candidate suppression. Handler also early-returns when `!writeEnabled` (defense-in-depth, `27fc357`).

Implementation validation: static greps (1 rpc, no direct table writes, `toTradeRow`/`db.loadAll` unchanged), esbuild EXIT 0, **36/36** pure unit + **27/27** component smoke.

---

## Explicit deferrals

- **No deploy yet** — user chose to wait for a batch deploy.
- **No persistent grouped data yet** — the write gate is off and the smoke was rollback-only.
- **Browser write-gate smoke deferred** until after deploy **and** explicit flag enable.
- **group_id-aware loader/render deferred** — `db.loadAll` still selects only `raw`; grouped state is not loaded or rendered.
- **Ungroup UI (v0.4) deferred.**

---

## Stop gates before enabling the write gate

1. Batch deploy shipped (thus999.com serves the reviewed bundle) — explicit user go.
2. Explicit user approval to enable `tj_trade_group_write_v01` (never auto-enabled).
3. Post-deploy browser smoke of the full flag matrix on the live bundle (no persistent write until the user chooses a real create).
4. Re-confirm reducers/P&L still ignore `group_id` on the deployed bundle.
5. Adversarial review of any follow-up (loader / ungroup / render) before implementation.
