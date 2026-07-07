# THUS Journal — Pipeline State

**Updated (local):** 2026-07-07
**Local HEAD:** `3a0b258` (fix: show contract size in trade picker)
**Remote:** local `main` ahead of `origin/main` by 9 (G2 stack + pipeline docs + MT5 preview + trade-picker csize), unpushed.
**Deploy posture:** HOLD — user chose to wait for a batch deploy. (Ahead stack is growing — a batch deploy or an explicit pause is worth considering.)

> This is a glance-able state file for autopilot. Autopilot **preserves adversarial
> review** — see [`AUTOPILOT_RULES.md`](./AUTOPILOT_RULES.md). It may inspect / summarize /
> run static checks / do low-risk local docs+UI work on already-reviewed scope, and MUST
> STOP for anything on the stop list (DB/SQL/RLS, Supabase/RPC writes, push/deploy, enabling
> write gates, MT5 writer, GUGU cognition, durable save/close/delete/merge/import, failed
> validation, architecture/product tradeoffs).

---

## Lanes

| Lane | Title | Status | Next action | Gate |
|---|---|---|---|---|
| **A** | Deploy batch | **HOLD** | Wait for explicit user go on batch deploy | push/deploy = user approval |
| **B** | G2 grouping | Schema/RPC applied; rollback happy-path smoke **PASS**; UI create-only default-off local | Post-deploy browser gated smoke, then (approved) enable write gate | deploy + explicit flag enable |
| **C** | Product/MT5 preview UX cleanup | **DONE** — MT5 Inbox preview (`85e5116`) + trade-open picker card csize (`3a0b258`); review-summary row optional/deferred | (optional) review-summary "Contract Size" row | scope review before code |
| **D** | MT5 auto draft import | Designed, not implementing | Design review before any code | review + architecture gate |
| **E** | GUGU bot | Capture-only / **cognition freeze** | Backlog: market-aware cadence, review_week, review_position, snooze, group-aware check-ins | cognition/autonomy = STOP |
| **F** | Merge/grouping boundary | Later audit | Keep destructive **merge** separate from non-destructive **grouping** | audit before code |
| **G** | RLS / security hardening | High-risk | Fresh **read-only** audit required first | RLS/schema = STOP |
| **H** | P2-5 image externalization | **CLOSED** (18/18 backfilled) | Backup retention decision later (holds sensitive base64) | delete backup = user approval |
| **I** | Mentor / GUGU notes | Backlog | — | — |

---

## Detail notes

- **A — Deploy batch.** The G2 stack + prior journal work sit unpushed. User: no deploy yet; batch later. Autopilot must not push/deploy.
- **B — G2 grouping.** Applied migration `20260705_g2_trade_group_rpcs.sql`; happy-path rollback smoke PASS (group `87585d32-…`, both children attached then cleared, ROLLBACK, baseline 0/0/0). UI v0.3 create-only behind `tj_trade_group_ui_v01` + `tj_trade_group_write_v01`, both default-off. See [`../g2_grouping/g2_v03_ui_and_rpc_smoke_closeout.md`](../g2_grouping/g2_v03_ui_and_rpc_smoke_closeout.md).
- **C — Product/MT5 preview UX cleanup.** **DONE** for the MT5 Inbox Mapping preview surface (`85e5116`, 2026-07-07): `_mt5PreviewLabel`/`_mt5ContractPair` now render family-level `Name — base · Current <cur> · Next <nxt> · csize <n>` with the `matches row (current|next)` suffix preserved; display-string helpers only, no product_id/registry/persistence change; esbuild EXIT 0, 16/16 unit. **DONE** for the trade-open product picker cards too (`3a0b258`, 2026-07-07): step-0 cards show a display-only ` · size <n>` fragment via `_csizeFrag(p)` (family-level; omitted when absent). `f.productId` still set from `s.id`; `buildTrade`/`toTradeRow`/`raw` unchanged; esbuild EXIT 0, 11/11 unit + 9/9 component smoke. **Deferred (optional, low priority):** the order review-summary "Contract Size" row was explicitly excluded — selection-time visibility is now solved, so this is polish, not a gap. The `productId`-driving picker was changed display-only (no selection/persistence change).
- **D — MT5 auto draft import.** Draft import touches durable/import paths → STOP for review.
- **E — GUGU bot.** Cognition/autonomous behavior is frozen; capture-only. Any cadence/cognition change = STOP.
- **F — Merge vs grouping.** Destructive merge (double-counts P/L historically, now disabled) must stay separate from non-destructive `group_id` grouping. Boundary audit later.
- **G — RLS/security.** Requires a fresh read-only audit; never edit RLS/policies under autopilot.
- **H — P2-5 image externalization.** Closed/backfilled. Sensitive raw backup lives outside git; delete only on explicit approval.
- **I — Mentor/GUGU notes.** Backlog only.
