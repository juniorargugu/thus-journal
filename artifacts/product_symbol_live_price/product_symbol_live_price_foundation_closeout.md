# Closeout — Product / Symbol / Live-Price Foundation (THUS Journal)

**Closeout date:** 2026-06-22
**Deploy date:** 2026-06-19 (~10:15 UTC)
**Status:** `PRODUCT_SYMBOL_LIVE_PRICE_FOUNDATION_DEPLOYED`
**Production URL:** https://thus999.com

---

## 1. Deploy facts

| | |
|---|---|
| `origin/main` commit | `2c2c8d2` — *"feat: add DELTA stock product preset"* |
| Prior production baseline | `30d5a1d` — *"fix: make trade updates save durable before success"* |
| Netlify deploy id | `6a3516d6c3e2a50008a2e024` — state **ready / current** |
| Push | fast-forward `30d5a1d..2c2c8d2`, plain `git push origin main` (no force) |
| Served bundle | **byte-identical** to `2c2c8d2:index.html` (LF-normalized match) |
| Version served | `v3.20.0` (unchanged by this stack) |

## 2. Scope deployed (8 commits)

| Commit | Change |
|---|---|
| `2ff3093` | docs: add P1 durable update closeout (docs artifact) |
| `711bef4` | ProductRegistry facade (Phase 1) |
| `c404be1` | price source badge (Phase 2A) |
| `d150b42` | registry price-status wiring (Phase 2B) |
| `3dadfa2` | runtime product kind inference (Phase 3B) |
| `9367b74` | kind-aware product expansion (Phase 3D) |
| `eaaab82` | kind-aware product labels (Phase 3E) |
| `2c2c8d2` | DELTA stock preset + idempotent Settings button + kind-aware Settings chips (Phase 3G) |

## 3. Important guarantees (verified across the stack)

- **No** Supabase schema migration.
- **No** `live_prices.id` format / `contractToLiveKey` change.
- **No** durable save path change (`commitClose/Open/ExecuteDraft/UpdateTrade`, `saveTradesSerialized`, `db.saveTrade(s)`, `replaceTradeLocal`).
- **No** P/L / margin / gearing / commission math semantic change (`calcPL/calcNetPL/tradeNetPL/calcPositionValue/calcGearingX/calcMargin`).
- **No** products load/merge behavior change; **no** merge-on-load; **no** `DEFAULT_PRODUCTS` change.
- **No** G2 / merge / `trade_groups` / import / delete / duplicate / GUGU change.
- DELTA delivery reuses the existing `onProductsChange` product save path (no new persistence route).

## 4. DELTA behavior (first real non-futures product)

- Classifies as **stock** via explicit `assetKind:"stock"` (precedence: `assetKind` wins over `manualPriceOnly`).
- Quantity label **`หุ้น`**; exposure label **`Exposure`**.
- Expands to **one** product — **no `_next`** synthetic series.
- Settings product list shows a compact **stock chip (`หุ้น`)** — **no** futures Active/Next chips, **no** "Active: undefined".
- **Manual-price-first** (`manualPriceOnly:true`) — price badge shows Manual/Entry fallback; **no live feed required**.
- **Commission 0 / gross P&L** for v1; P/L = `(exit − entry) × shares` (`contractSize:1`, `tickSize:tickValue:0.01`; invariant holds → `warnInvariants` silent).
- Shape: `{id:"delta", name:"DELTA", baseSymbol:"DELTA", assetKind:"stock", currency:"THB", digits:2, contractSize:1, tickSize:0.01, tickValue:0.01, manualPriceOnly:true, initialMargin:0, commissionPerLeg:0, vatEnabled:false}` — no `currentContract/nextContract/series/category/kind`.

## 5. Smoke results

- Deploy served **byte-identical** `2c2c8d2:index.html`; new-code markers present in production (`DELTA_STOCK_PRESET`, `productQuantityLabel`, `PriceSourceBadge`, `เพิ่มหุ้น DELTA`).
- Production **visual smoke passed per user**.
- DELTA UI smoke passed per user where applicable (Settings chip / trade-form single entry / labels), pending any items the user ran.

## 6. Console telemetry note

Post-deploy console telemetry observed `[close-save] durable ok (single-row)` followed by `500` / `[trades][write] upsert-error` / `[close-save] saveTrades not ok`. **This is expected residual pre-existing behavior, not a regression.** The single-row durable writer (`db.saveTrade`, introduced by P0 commit `69531ef`) persisted the trade; the *separate* debounced full-array autosave (`db.saveTrades`) can still hit 57014/500 due to the large full trades payload with base64 images (documented at `index.html:287-288`). The `[persist] skipped … hydration not ready` lines are the expected `!dbReady` startup guards. These paths **predate** the Product/Symbol/Live-Price deploy and were **not modified** by the stack (verified). Not a deploy blocker; no rollback needed; no data loss (post-refresh persistence confirms the durable write landed).

## 7. Remaining deferred items

- No DELTA **trade** smoke yet (open a manual DELTA trade) unless the user separately approves.
- Stock **notional buying-power warning** — deferred.
- Stock **commission model** (%-of-notional) — deferred (v1 = 0 / gross).
- **Generic kind-aware product editor** — deferred (the existing "+ เพิ่ม Product" form remains futures-shaped).
- **FX / crypto / non-THB** — deferred.
- **Market-hours / stale-price** logic (Phase 2B+ price status) — deferred.
- **GUGU market-aware cadence** — deferred.
- **Residual full-array trades autosave cleanup** — P2 (see below).

## 8. Suggested P2 backlog

**Residual full-array trades autosave cleanup.** Root cause of the recurring `500` / `57014` / `[trades][write] upsert-error`:
- Route the debounced `[trades]` autosave through per-row / diff-only single-row `db.saveTrade`, **or**
- Strip / externalize base64 images from the autosave payload so the request stays inside the statement-timeout budget.
- Goal: eliminate the recurring full-array `db.saveTrades` timeout. No urgency — durable single-row saves already protect data. Continues the P0/P1 "residual non-durable writers" list (delete / duplicate / import already noted).

## 9. Next recommended step

User-run **view-only browser smoke** confirmation at https://thus999.com (Settings → DELTA renders as a `หุ้น` stock chip, or the `เพิ่มหุ้น DELTA` button shows if the accidental click did not persist) **without** opening a DELTA trade. A controlled **manual DELTA trade smoke** (open → verify Manual badge + P/L = price-move × shares → close → delete) remains a separate, explicitly-approved follow-up.

---

*Lineage:* continues the durable-save work (P0/P1, ≤ `30d5a1d`). This is the Product / Symbol / Live-Price Foundation phase: facade → price source → kind inference → kind-aware expansion/labels → first real stock (DELTA).
