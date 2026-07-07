# THUS Journal — Pipeline State

**Updated (local):** 2026-07-07
**Local HEAD:** `71283c3` (fix: bump deployed app version to 3.22.0)
**Remote:** `origin/main` == HEAD == `71283c3` — **in sync, deployed**.
**Deploy posture:** **DEPLOYED** — batch `f5290f7..b1f8e7d` + version hotfix `b1f8e7d..71283c3` live on thus999.com (byte-identical HEAD). App version **v3.22.0** (single-source `APP_VERSION` in index.html). G2 flags remain default-off; write gate NOT enabled.

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
| **A** | Deploy batch | **DONE** — deployed `71283c3` to prod (v3.22.0), byte-identical | — (next deploy is a fresh user-gated batch) | push/deploy = user approval |
| **B** | G2 grouping | Schema/RPC applied; rollback smoke **PASS**; UI create-only + isMerged exclusion **deployed** default-off | Draft post-deploy write-gate browser-smoke PLAN (not execution) | deploy + explicit flag enable |
| **C** | Product/MT5 preview UX cleanup | **DONE** — MT5 Inbox preview (`85e5116`) + trade-open picker card csize (`3a0b258`); review-summary row optional/deferred | (optional) review-summary "Contract Size" row | scope review before code |
| **D** | MT5 auto draft import | Designed, not implementing | Design review before any code | review + architecture gate |
| **E** | GUGU bot | Capture-only / **cognition freeze** | Backlog: market-aware cadence, review_week, review_position, snooze, group-aware check-ins | cognition/autonomy = STOP |
| **F** | Merge/grouping boundary | **AUDITED** (`8c01f95`) — CLEAR_FOR_BATCH_DEPLOY_AS_IS; isMerged exclusion shipped (`b1f8e7d`) | RPC-side `raw->>'isMerged'` guard (pre-write-gate, separate schema review) | audit before code |
| **G** | RLS / security hardening | High-risk | Fresh **read-only** audit required first | RLS/schema = STOP |
| **H** | P2-5 image externalization | **CLOSED** (18/18 backfilled) | Backup retention decision later (holds sensitive base64) | delete backup = user approval |
| **I** | Mentor / GUGU notes | Backlog | — | — |

---

## Detail notes

- **A — Deploy batch. DONE (2026-07-07).** Pushed `f5290f7..b1f8e7d` (12 commits) + version hotfix `b1f8e7d..71283c3`; Netlify auto-published. Prod thus999.com serves index.html byte-identical to `71283c3` (HTTP 200); boot smoke PASS (app mounts, grouping UI absent by default, flags null, 0 create RPC on load). Version badge now **v3.22.0** via single-source `APP_VERSION`. Signed-in footer visual confirm is user-side (hard-refresh to bust cache). A *future* deploy is again a fresh user-gated batch.
- **B — G2 grouping.** Applied migration `20260705_g2_trade_group_rpcs.sql`; happy-path rollback smoke PASS (group `87585d32-…`, both children attached then cleared, ROLLBACK, baseline 0/0/0). UI v0.3 create-only + `isMerged` candidate exclusion (`b1f8e7d`, ROADMAP #184) now **deployed**, behind `tj_trade_group_ui_v01` + `tj_trade_group_write_v01`, both default-off. Write gate NOT enabled. See [`../g2_grouping/g2_v03_ui_and_rpc_smoke_closeout.md`](../g2_grouping/g2_v03_ui_and_rpc_smoke_closeout.md) + [`../g2_grouping/merge_grouping_boundary_audit.md`](../g2_grouping/merge_grouping_boundary_audit.md).
- **C — Product/MT5 preview UX cleanup.** **DONE** for the MT5 Inbox Mapping preview surface (`85e5116`, 2026-07-07): `_mt5PreviewLabel`/`_mt5ContractPair` now render family-level `Name — base · Current <cur> · Next <nxt> · csize <n>` with the `matches row (current|next)` suffix preserved; display-string helpers only, no product_id/registry/persistence change; esbuild EXIT 0, 16/16 unit. **DONE** for the trade-open product picker cards too (`3a0b258`, 2026-07-07): step-0 cards show a display-only ` · size <n>` fragment via `_csizeFrag(p)` (family-level; omitted when absent). `f.productId` still set from `s.id`; `buildTrade`/`toTradeRow`/`raw` unchanged; esbuild EXIT 0, 11/11 unit + 9/9 component smoke. **Deferred (optional, low priority):** the order review-summary "Contract Size" row was explicitly excluded — selection-time visibility is now solved, so this is polish, not a gap. The `productId`-driving picker was changed display-only (no selection/persistence change).
- **D — MT5 auto draft import.** Draft import touches durable/import paths → STOP for review.
- **E — GUGU bot.** Cognition/autonomous behavior is frozen; capture-only. Any cadence/cognition change = STOP.
- **F — Merge vs grouping. AUDITED (`8c01f95`, verdict CLEAR_FOR_BATCH_DEPLOY_AS_IS).** Legacy Merge disabled/unreachable (sole `🔗` entry `disabled`, no onClick); no merge path writes `group_id`; durable paths preserve `group_id` by omission; no confusing labels. The one data-safe gap (grouping candidates could include `isMerged` rows) is FIXED at the UI/candidate layer (`b1f8e7d`). Remaining: the defense-in-depth RPC-side `raw->>'isMerged'` reject (separate schema change, pre-write-gate).
- **G — RLS/security.** Requires a fresh read-only audit; never edit RLS/policies under autopilot.
- **H — P2-5 image externalization.** Closed/backfilled. Sensitive raw backup lives outside git; delete only on explicit approval.
- **I — Mentor/GUGU notes.** Backlog only.
