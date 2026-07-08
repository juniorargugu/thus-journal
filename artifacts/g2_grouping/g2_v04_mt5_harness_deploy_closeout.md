# G2 v0.4 + MT5 Dry-Run Harness — Deploy Closeout

**Date (local):** 2026-07-08
**Result:** **DEPLOYED + VERIFIED** in production. Prod `thus999.com` = **`f01eb33` / v3.23.0**, byte-identical served bundle. No-auth default-off smoke PASS + authenticated visual smoke PASS (2026-07-08).
**Deployed by:** assistant (user pre-approved Netlify deploys at agent discretion).

> Ships the G2 v0.4 group-aware loader/render (default-off) and merges the offline MT5 dry-run harness
> as inert tooling. No G2 flag enabled, no real group kept, no MT5 staging writer started, no DB/SQL/RPC
> writes. All further write paths remain separately gated.

---

## Pushed range: `71283c3` → `f01eb33` (13 commits)

| Commit | Type | What |
|---|---|---|
| `f45416e`, `a555414` | docs | batch-deploy + write-gate smoke closeouts |
| `ba9e780` | **code** | G2 v0.4 loader/render (select `raw,group_id`, separate `tradeGroupIds` map, candidate suppression, ⛓ badge) |
| `9a07fdc` | **code** | G2 v0.4 stale-map reset on hydration/auth/failure |
| `4e63783`, `e650fbb`, `69d7991`, `1de867d`, `2fbcb44` | docs | v0.4 closeout, v0.5 ungroup design, smoke runbook, RPC isMerged design + review |
| `85be5b2` | **code** | MT5 dry-run harness (offline) |
| `8fb9a33` | **code** | MT5 harness CLI exit-code fix |
| **`3f4a67d`** | merge | `--no-ff` merge of `mt5-dryrun-harness-v01` |
| **`f01eb33`** | **code** | version bump `APP_VERSION` `3.22.0` → `3.23.0` |

The only production-app (`index.html`) change vs prior prod is the reviewed G2 v0.4 loader/render/reset
hunks + the one-line `APP_VERSION` bump. Everything else is new docs / offline harness / fixtures.

## Netlify + production verification

- `git push origin main` → `71283c3..f01eb33`, exit 0. Netlify auto-published.
- Served `https://thus999.com/index.html`: **HTTP 200**, **595,900 bytes**, sha256 **`4f8564da…`** —
  **byte-identical** to `HEAD:index.html` (LF blob; CR-count 0). `APP_VERSION="3.23.0"` present in the bundle.
- Footer version badge shows **v3.23.0** (renders when signed in; hard-refresh to bust cache — user-side confirm).

## No-auth default-off G2 smoke — **PASS** (headless, read-only)

- App shell mounts (React).
- `tj_trade_group_ui_v01` = null, `tj_trade_group_write_v01` = null, `tj_trade_group_mock` = null.
- Grouping UI absent; no ⛓ Grouped badge.
- **0** `create_trade_group_v1` calls on load.
- **0** `/rest/v1/trades` writes and **0** `/rest/v1/trade_groups` writes on load.
- (No trades GET either — no auth session, so no hydration; expected.)

Static re-confirmation in the served/HEAD bundle: `select("raw,group_id")`; no `group_id`/`_groupId` assigned
onto `raw`/trade objects; `toTradeRow` unchanged; `buildGroupingPreview` excludes grouped rows via `groupIdMap`
and keeps the `isMerged` exclusion; success repopulates `setTradeGroupIds(data.tradeGroupIds||{})`; no
reducer/P&L/portfolio/durable hunks.

## MT5 dry-run harness (merged as offline tooling)

- `ops/mt5_import/dry_run.py` + `test_dry_run.py`; fixtures/reports under `artifacts/mt5_import/`.
- Reuses `build_rows.py` pure mappers + `tz.py` (Bangkok→UTC); adds class-aware mapping (exact-symbol only),
  `raw_sha`, idempotency keys (open→position_id, deal→deal_id).
- `python ops/mt5_import/test_dry_run.py` → **PASS** (incl. no-Supabase/MT5/network import scan + exit-code
  contract); CLI output **deterministic** (regeneration content-identical to the committed sample report).
- **Never** imports `staging_db`/`writer`/`MetaTrader5`/`supabase`; no DB/SQL/RPC/network. Not the writer.

## Authenticated visual smoke — **PASS** (user browser, 2026-07-08)

Signed-in verification (runbook §4–5) confirmed by the user: Positions/Journal render normally, P/L + portfolio
visually unchanged, footer shows **v3.23.0** after hard-refresh, and **no ⛓ Grouped badge** (DB has 0 grouped
trades). Combined with the no-auth default-off smoke above, **v3.23.0 deploy verification is COMPLETE.**

## Gated remaining work (each needs explicit approval)

- Enable `tj_trade_group_write_v01` / keep a real group persistently (Lane B).
- Apply the RPC `isMerged` hardening migration (Lane F) — run the read-only precheck (expect 0) first;
  sequenced before write-gate enable; SQL apply user-run.
- Implement G2 v0.5 ungroup UI (Lane B) — approved-deferred, its own review.
- MT5 real staging writer (Lane D) — reviewed schema/RLS + explicit DB-write approval.

## Rollback

Additive + default-off, so risk is low. If needed: `git revert f01eb33 3f4a67d` (version bump + harness merge)
then push, or redeploy the prior prod commit `71283c3` / v3.22.0.

---

_Branch `mt5-dryrun-harness-v01` (`8fb9a33`) is merged; it may be deleted at leisure._
