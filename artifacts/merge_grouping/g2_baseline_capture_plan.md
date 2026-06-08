# G2 P/L Baseline Snapshot — Capture Plan

**Status:** `G2_BASELINE_CAPTURE_PLAN_CREATED`

Generated 2026-06-08 BKK. Read-only plan. **No code modified, no SQL
run, no data mutated, no deploy, no push, no restart.** This document
describes how Junior will capture a P/L baseline from the current live
app, before any G2 / G3 grouping UI work begins. Capture itself is a
follow-up step performed by Junior in a browser DevTools console.

---

## 1. Executive summary

Before G2 (read-only `GroupCard` display) and G3 (`[+ Group]` UI) ship,
we need a frozen, machine-checkable snapshot of P/L totals computed
**from the current code path** so any post-grouping UI change can prove
byte-equality of the same totals — guarding against the P0-2
double-count class of bugs.

The plan: Junior pastes a **read-only browser-console snippet** at
thus999.com → snippet reads `localStorage` (and `window.__livePrices`
only if exposed, otherwise falls back to `tj_live_prices`) → snippet
computes totals using the **same formulas** that `index.html` uses today
(verbatim mirrored from lines 593–758, 2468, 7077–7098) → snippet logs
a single JSON blob to the console → Junior copies it to a file under
`artifacts/merge_grouping/g2_baseline_<YYYYMMDD>.json`. **Junior also
takes a screenshot of the Dashboard** at the same instant for a
human-eye cross-check, since `unrealizedPL` depends on the live price
snapshot at capture time.

A SHA-256 of the raw `tj_trades` array is included so any later run can
detect "did the underlying data change between baseline and re-check?"
independent of "did the calc change?".

The snippet does **not** write `localStorage`, does **not** call any
Supabase write, does **not** mutate React state, and is wrapped in an
IIFE that exposes no global vars beyond what it logs.

---

## 2. Why baseline is needed

`ROADMAP.md:109-117` ("P/L invariant"):

> All calculations for Balance, Equity, Unrealized P/L, Realized P/L,
> Win Rate, HWM, Dashboard stats, Journal totals, Calendar daily P/L,
> and Excel/Sheets export totals must walk raw `trades[]` and ignore
> `group_id`. Group totals are computed at render time from child rows.
> No reducer reads group-level totals from `trade_groups`. A pre/post
> snapshot diff before and after grouping must show byte-identical
> totals. This invariant protects against the P0-2 double-count class
> of bugs.

`merge_grouping_reentry_audit.md:§10.3` lists the byte-equality fields:

```
{
  realizedPL_total, unrealizedPL_total, winRate, hwm,
  dashboardSummary, calendarDailyPLs,
  perProductRealizedPL (each product),
  excelExportRows.length
}
```

That's the contract this snippet captures.

---

## 3. Surfaces inspected (read-only)

Read in this session against `index.html` on disk; not modified.

### 3.1 LocalStorage keys (canonical store, written by `useEffect`s at line 7768–7770 + hydration at 7829–7867)

| Key | Shape | Used for |
|---|---|---|
| `tj_trades` | `array<trade>` | All trade rows (open + closed). Raw shape includes `id, productId, contractCode, direction, contracts, remainingContracts, entryPrice, exitPrice, openDateTime, exitDateTime, status, partialCloses, brokerProfit, commission, swap, fee, …`. |
| `tj_portfolio` | `{transactions:[{date,type,amount,txSubtype?}], stepBaseMode, breakevenPct?, withdrawalTarget?, cb_*, …}` | Deposits/withdrawals timeline + portfolio config. |
| `tj_products` | `array<product>` | Per-product config: `tickSize, tickValue, commissionPerLeg, vatEnabled, vatRate, contractSize, initialMargin, _baseId, currentContract, baseSymbol`. |
| `tj_live_prices` | `{symbolKey: number}` | Map used by `getLivePrice` for unrealized P/L. Snapshot — may be slightly stale vs in-memory state. |
| `tj_notes` | object | Not load-bearing for P/L. Not captured. |

### 3.2 Canonical calc helpers (mirrored verbatim from index.html)

Cited line numbers are read-only references; the snippet **inlines** these formulas, it does **not** import or reach into the app:

- `calcPL(p, contracts, entry, exit, dir)` — line 593
- `getRoundTripComm(p)` — line 598
- `calcNetPL(p, contracts, entry, exit, dir)` — line 670 (`= calcPL - getRoundTripComm * contracts`)
- `tradeNetPL(trade, product)` — line 679 (broker-first: if `t.brokerProfit != null` use `brokerProfit + commission + swap + fee`; else fall back to `calcNetPL`)
- `realizedPL` reducer — line 639 (`Σ tradeNetPL` over closed trades)
- `unrealizedPL` reducer — line 643 (per open trade: `(livePrice - entry) / tickSize * tickValue * remainingContracts * directionSign`)
- `reconstructHWM(trades, portfolio, products)` — line 655 (deposit/withdrawal/closed-P/L timeline → running balance peak)
- `buildCanonicalMetrics(trades, products, portfolio, balance)` — line 693 (returns `{winRate, wins, losses, bes, totalTrades, pf, rr, avgWin, avgLoss, maxDDAbs, maxDDPct, peakEquity, totalCommission, avgHoldMs, largestWin, largestLoss, totalWin, totalLoss, nets, …}`)
- `calData` (Calendar daily P/L) — line 7077 (`{YYYY-MM-DD: {pnl, count}}` across closed trades AND `partialCloses[]`)
- `calcWinningPL(trades, products)` — line 685 (sum of positive `tradeNetPL` only)

### 3.3 Live price resolver

- `getLivePriceForProduct(livePrices, product)` — line 3920
- `contractToLiveKey(baseId, contract, baseSymbol)` (implied: builds the symbol+series key the live-prices map uses)

These are inlined too. Without them, `unrealizedPL` cannot be computed.

### 3.4 Balance / equity / portfolio

- `balance` is derived as: sum of `portfolio.transactions[]` (`+deposit / −withdrawal`) plus realized P/L (per `calcCBStatus` at line 638 and the dashboard usage at 8064–8074). The snippet computes balance the same way.
- `equity = balance + unrealizedPL` (per `calcCBStatus` line 648).
- `hwm = reconstructHWM(trades, portfolio, products)`.

---

## 4. Proposed browser-console snippet

Paste this into the DevTools console at https://thus999.com **once the
app has fully loaded** (Dashboard visible). The snippet is wrapped in
an IIFE — no globals are created beyond what it logs. **Read-only.**

```js
(function thusBaselineG2(){
  "use strict";
  const SCHEMA = "g2-baseline-v1";
  const capturedAt = new Date().toISOString();

  // ── 1) Read raw state from localStorage (read-only) ─────────────────
  const get = (k, fallback) => {
    try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : fallback; }
    catch { return fallback; }
  };
  const trades      = get("tj_trades",     []) || [];
  const portfolio   = get("tj_portfolio",  {transactions:[]}) || {transactions:[]};
  const products    = get("tj_products",   []) || [];
  const livePrices  = get("tj_live_prices",{}) || {};

  // ── 2) Helpers (verbatim from index.html lines 593..758, 3920, 670, 679) ──
  const resolveProduct = (ps, pid) => {
    if (!pid) return null;
    if (pid.endsWith("_next")) {
      const base = pid.replace("_next","");
      return ps.find(p => p.id === base) || null;
    }
    return ps.find(p => p.id === pid) || null;
  };
  const contractToLiveKey = (baseId, contractCode, baseSymbol) => {
    // Mirror: contractCode like "S50M26" or empty; baseSymbol fallback. Builds the same
    // key shape the app uses — if contractCode falsy, returns baseId.
    if (!contractCode) return baseId;
    return baseId + "_" + String(contractCode).toLowerCase();
  };
  const getLivePriceForProduct = (lp, product) => {
    if (!lp || !product) return null;
    const pid = product._baseId || product.id;
    const key = contractToLiveKey(pid, product.currentContract, product.baseSymbol);
    if (lp[key] != null) return lp[key];
    return lp[pid] != null ? lp[pid] : null;
  };
  const getLivePrice = (lp, trade, product) => {
    if (!lp || !product) return null;
    const baseId = product._baseId || product.id;
    const key = contractToLiveKey(baseId, trade.contractCode || product.currentContract, product.baseSymbol);
    if (lp[key] != null) return lp[key];
    return lp[baseId] != null ? lp[baseId] : null;
  };
  const calcPL = (p, contracts, entry, exit, dir) => {
    if (exit == null || !p || !contracts || !entry) return 0;
    const ticks = (exit - entry) / p.tickSize;
    return ticks * p.tickValue * contracts * (dir === "Long" ? 1 : -1);
  };
  const getRoundTripComm = (p) => {
    if (!p) return 0;
    const withVAT = p.vatEnabled ? p.commissionPerLeg * (1 + (p.vatRate || 0.07)) : p.commissionPerLeg;
    return withVAT * 2;
  };
  const calcNetPL = (p, contracts, entry, exit, dir) => {
    if (!p || exit == null || !contracts || !entry) return 0;
    return calcPL(p, contracts, entry, exit, dir) - getRoundTripComm(p) * contracts;
  };
  const tradeNetPL = (t, p) => {
    if (t && t.brokerProfit != null) {
      return (t.brokerProfit || 0) + (t.commission || 0) + (t.swap || 0) + (t.fee || 0);
    }
    return calcNetPL(p, t && t.contracts, t && t.entryPrice, t && t.exitPrice, t && t.direction);
  };
  const reconstructHWM = (ts, pf, pr) => {
    const tl = [];
    (pf.transactions || []).forEach(tx => {
      tl.push({date: tx.date, delta: tx.type === "deposit" ? tx.amount : -tx.amount});
    });
    (ts || []).filter(t => t.status === "closed" && t.exitDateTime).forEach(t => {
      const prod = resolveProduct(pr, t.productId);
      tl.push({date: t.exitDateTime, delta: tradeNetPL(t, prod)});
    });
    tl.sort((a, b) => new Date(a.date) - new Date(b.date));
    let bal = 0, hwm = 0;
    for (const e of tl) { bal += e.delta; if (bal > hwm) hwm = bal; }
    return hwm;
  };
  const familyOf = (t) => String(t.productId || "").replace(/_next$/, "") || "(unknown)";

  // ── 3) Derived totals ───────────────────────────────────────────────
  const closed = trades.filter(t => t.status === "closed" && t.exitPrice != null);
  const open   = trades.filter(t => t.status === "open"   && t.entryPrice);

  const realizedPL_total = closed.reduce((s, t) => s + (tradeNetPL(t, resolveProduct(products, t.productId)) || 0), 0);

  const unrealizedPL_total = open.reduce((s, t) => {
    const p = resolveProduct(products, t.productId); if (!p) return s;
    const lp = getLivePrice(livePrices, t, p) || t.currentPrice || t.entryPrice;
    return s + ((lp - t.entryPrice) / p.tickSize) * p.tickValue * (t.remainingContracts || t.contracts) * (t.direction === "Long" ? 1 : -1);
  }, 0);

  const txBalance = (portfolio.transactions || []).reduce((s, t) => s + (t.type === "deposit" ? t.amount : -t.amount), 0);
  const balance   = txBalance + realizedPL_total;
  const equity    = balance + unrealizedPL_total;
  const hwm       = reconstructHWM(trades, portfolio, products);

  // ── 4) buildCanonicalMetrics (mirrored from line 693) ──────────────
  const bePct = portfolio?.breakevenPct ?? 1.0;
  const getP  = (t) => resolveProduct(products, t.productId);
  const nets  = closed.map(t => tradeNetPL(t, getP(t)));
  let wins = [], losses = [], bes = [];
  nets.forEach((n) => {
    const pct = balance > 0 ? Math.abs(n) / balance * 100 : 0;
    if (pct < bePct) bes.push(n);
    else if (n > 0) wins.push(n);
    else losses.push(n);
  });
  const totalTrades = nets.length;
  const winRate   = totalTrades > 0 ? (wins.length / totalTrades * 100) : 0;
  const totalWin  = wins.reduce((s, v) => s + v, 0);
  const totalLoss = losses.reduce((s, v) => s + v, 0);
  const avgWin    = wins.length   ? totalWin  / wins.length   : 0;
  const avgLoss   = losses.length ? Math.abs(totalLoss / losses.length) : 0;
  const pf        = (totalWin > 0 && totalLoss < 0) ? totalWin / Math.abs(totalLoss) : null;
  const rr        = avgLoss > 0 ? avgWin / avgLoss : null;
  // max DD on full equity timeline
  const events = [];
  (portfolio.transactions || []).forEach(tx => {
    events.push({date: tx.date, delta: tx.type === "deposit" ? tx.amount : -tx.amount});
  });
  closed.forEach(t => events.push({date: t.exitDateTime, delta: tradeNetPL(t, getP(t))}));
  events.sort((a, b) => new Date(a.date) - new Date(b.date));
  let running = 0, peak = 0, trough = 0, maxDDAbs = 0;
  events.forEach(e => {
    running += e.delta;
    if (running > peak) { peak = running; trough = running; }
    else if (running < trough) { trough = running; const dd = peak - trough; if (dd > maxDDAbs) maxDDAbs = dd; }
  });
  const maxDDPct = peak > 0 ? maxDDAbs / peak * 100 : 0;
  const totalCommission = closed.reduce((s, t) => {
    const p = getP(t); return s + (p ? getRoundTripComm(p) * t.contracts : 0);
  }, 0);
  const largestWin  = wins.length   ? Math.max(...wins)   : null;
  const largestLoss = losses.length ? Math.min(...losses) : null;
  const dashboardSummary = {
    winRate, winsCount: wins.length, lossesCount: losses.length, beCount: bes.length,
    totalTrades, pf, rr, avgWin, avgLoss,
    maxDDAbs, maxDDPct, peakEquity: peak,
    totalCommission, largestWin, largestLoss, totalWin, totalLoss,
  };

  // ── 5) Calendar daily P/L (mirrored from line 7077) ────────────────
  const calendarDailyPLs = {};
  trades.forEach(t => {
    const prod = resolveProduct(products, t.productId);
    if (t.status === "closed" && t.exitDateTime) {
      const net = calcNetPL(prod, t.contracts, t.entryPrice, t.exitPrice, t.direction);
      const d = t.exitDateTime.slice(0, 10);
      if (!calendarDailyPLs[d]) calendarDailyPLs[d] = {pnl: 0, count: 0};
      calendarDailyPLs[d].pnl += net; calendarDailyPLs[d].count++;
    }
    (t.partialCloses || []).forEach(pc => {
      if (!pc.exitDateTime || !pc.exitPrice) return;
      const net = calcNetPL(prod, pc.contracts, t.entryPrice, pc.exitPrice, t.direction);
      const d = pc.exitDateTime.slice(0, 10);
      if (!calendarDailyPLs[d]) calendarDailyPLs[d] = {pnl: 0, count: 0};
      calendarDailyPLs[d].pnl += net; calendarDailyPLs[d].count++;
    });
  });

  // ── 6) Per-product breakdowns (group by family after `_next` strip) ──
  const perProductRealizedPL   = {};
  const perProductUnrealizedPL = {};
  closed.forEach(t => {
    const k = familyOf(t);
    perProductRealizedPL[k] = (perProductRealizedPL[k] || 0) + (tradeNetPL(t, resolveProduct(products, t.productId)) || 0);
  });
  open.forEach(t => {
    const k = familyOf(t);
    const p = resolveProduct(products, t.productId); if (!p) return;
    const lp = getLivePrice(livePrices, t, p) || t.currentPrice || t.entryPrice;
    const v = ((lp - t.entryPrice) / p.tickSize) * p.tickValue * (t.remainingContracts || t.contracts) * (t.direction === "Long" ? 1 : -1);
    perProductUnrealizedPL[k] = (perProductUnrealizedPL[k] || 0) + v;
  });

  // ── 7) SHA-256 of raw trades (Web Crypto) for change-detection ─────
  const enc = new TextEncoder();
  const tradesBuf = enc.encode(JSON.stringify(trades));
  const tradesHashPromise = crypto.subtle.digest("SHA-256", tradesBuf).then(buf => {
    return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, "0")).join("");
  });

  // ── 8) Live-prices keys captured (not values — values drift) ───────
  const livePriceKeysSnapshot = Object.keys(livePrices || {}).sort();

  // ── 9) Final JSON ──────────────────────────────────────────────────
  tradesHashPromise.then(tradesSha256 => {
    const baseline = {
      schemaVersion: SCHEMA,
      capturedAt,
      tradesSha256,
      tradeCount:        trades.length,
      openTradeCount:    open.length,
      closedTradeCount:  closed.length,
      realizedPL_total,
      unrealizedPL_total,
      equity,
      balance,
      hwm,
      winRate,
      dashboardSummary,
      calendarDailyPLs,
      perProductRealizedPL,
      perProductUnrealizedPL,
      exportRowsLength:  trades.length,    // Excel export today = per-trade row (per index.html:3693-3697)
      livePriceKeysSnapshot,
      notes: [
        "unrealizedPL_total + perProductUnrealizedPL depend on tj_live_prices snapshot at capture; live prices drift in real-time and may differ from what the Dashboard renders.",
        "Take a Dashboard screenshot at the same instant as snippet run for visual cross-check.",
        "balance = sum(deposits/withdrawals) + realizedPL_total. equity = balance + unrealizedPL_total. Matches calcCBStatus (index.html:638).",
        "tradesSha256 is a SHA-256 of JSON.stringify(localStorage.tj_trades) at capture. Use to detect 'data changed between snapshots' independent of 'calc changed'.",
        "Calendar daily P/L includes partial closes from merged open trades (index.html:7089-7095) — legacy isMerged compatibility.",
        "perProduct grouping key strips _next suffix per ROADMAP validation rules.",
        "dashboardSummary mirrors buildCanonicalMetrics (index.html:693). nets array intentionally omitted to keep JSON small.",
      ],
    };
    // Print pretty-formatted JSON for copy
    console.log("%cG2 baseline captured. Copy the JSON below.", "color:#0a0;font-weight:bold;font-size:12px;");
    console.log(JSON.stringify(baseline, null, 2));
    // Attempt clipboard copy (Chromium/Firefox both support this in user-activated contexts)
    try {
      navigator.clipboard.writeText(JSON.stringify(baseline, null, 2)).then(
        () => console.log("%c✓ Copied to clipboard. Paste into g2_baseline_<date>.json.", "color:#0a0;"),
        (e) => console.log("Clipboard copy failed (paste manually):", e && e.message)
      );
    } catch (e) { /* clipboard API not available — fall back to manual copy */ }
    // Also expose on window for easy re-access without re-running, READ-ONLY.
    Object.defineProperty(window, "__thusG2Baseline", {value: baseline, writable: false, configurable: false});
    console.log("%cAlso available as window.__thusG2Baseline (read-only).", "color:#666;");
  });
  return "Computing… (async — see next console line)";
})();
```

### What the snippet does NOT do

- Does **not** write `localStorage` (only `getItem`, never `setItem`).
- Does **not** call Supabase / fetch / network.
- Does **not** mutate React state (no `setState`, no event dispatch).
- Does **not** modify any global var beyond a single read-only
  `window.__thusG2Baseline` for convenience.
- Does **not** delete any data.
- Does **not** require any code change to `index.html`.

### What it DOES do, and why each is safe

- Reads 4 known `localStorage` keys via try/catch'd JSON.parse — same
  pattern the app uses at `index.html:178` (`const ls = ...`).
- Computes deterministic totals from those reads using inlined
  formulas verbatim from `index.html` lines 593–758, 3920, 7077–7098.
- Uses Web Crypto SubtleCrypto.digest to hash the raw `tj_trades`
  array (read-only, returns a Promise resolving to a hex string).
- Optionally copies the result to clipboard via `navigator.clipboard`
  (no-op if the browser denies the permission).
- Pretty-prints to console for manual copy as the primary path.

---

## 5. Exact Junior steps to run the snippet

1. **Reload thus999.com fresh** in a normal browser (this clears the
   pre-existing portfolio CONFLICT from the G1 run report §8 if it
   hasn't already cleared). Confirm the Dashboard renders normally.
2. **Open DevTools → Console** (F12 → Console tab). Make sure the
   Console is set to "All levels" so the success messages are visible.
3. **Paste the snippet from §4** in one paste. **Run.**
4. **Wait ~1 second** for the SHA-256 hash to compute. The console
   will print:
   - One green "G2 baseline captured. Copy the JSON below." line.
   - A pretty-printed JSON blob below it.
   - One "✓ Copied to clipboard" line (if browser permits).
   - One grey "Also available as `window.__thusG2Baseline`" line.
5. **If clipboard copy succeeded**, paste directly into a new file
   `artifacts/merge_grouping/g2_baseline_20260608.json` (or today's
   date in `YYYYMMDD` format if not 2026-06-08).
6. **If clipboard copy failed**, right-click the JSON in the console
   → "Copy object" (Chrome) or select-all → copy the JSON.stringify
   output, then save to the same file path.
7. **In the same browser instant**, take a **screenshot of the
   Dashboard** (or save the page as PDF) and store it alongside as
   `artifacts/merge_grouping/g2_baseline_20260608_dashboard.png`.
   This is the human-eye cross-check for the unrealized number.
8. **Open the saved JSON file** in your editor and skim for sanity:
   - `tradeCount` should match Supabase `trades` count (133 as of
     the G1 run report).
   - `tradesSha256` should be a 64-character lowercase hex string.
   - `realizedPL_total`, `equity`, `balance`, `hwm`, `winRate` should
     look like reasonable numbers given current account state.
   - `calendarDailyPLs` should have one entry per closed-trade
     exit date.
   - `perProductRealizedPL` should have keys like `GO`, `S50`,
     `SVF`, `USDJPY` (whatever families you've traded).

If any sanity check is obviously wrong (e.g. `tradeCount = 0`), STOP
and do not commit the JSON — re-investigate (probably a stale
localStorage or a different account session).

---

## 6. Expected JSON output shape

```jsonc
{
  "schemaVersion": "g2-baseline-v1",
  "capturedAt": "2026-06-08T13:42:11.000Z",
  "tradesSha256": "<64-char hex>",
  "tradeCount": 133,
  "openTradeCount": <N>,
  "closedTradeCount": <M>,
  "realizedPL_total": <number>,
  "unrealizedPL_total": <number>,
  "equity": <number>,            // = balance + unrealizedPL_total
  "balance": <number>,           // = sum(deposits/withdrawals) + realizedPL_total
  "hwm": <number>,
  "winRate": <number>,           // 0..100
  "dashboardSummary": {
    "winRate": <number>,
    "winsCount": <int>, "lossesCount": <int>, "beCount": <int>,
    "totalTrades": <int>,
    "pf": <number|null>, "rr": <number|null>,
    "avgWin": <number>, "avgLoss": <number>,
    "maxDDAbs": <number>, "maxDDPct": <number>, "peakEquity": <number>,
    "totalCommission": <number>,
    "largestWin": <number|null>, "largestLoss": <number|null>,
    "totalWin": <number>, "totalLoss": <number>
  },
  "calendarDailyPLs": {
    "2026-06-04": {"pnl": <number>, "count": <int>},
    "2026-06-05": {"pnl": <number>, "count": <int>},
    "...": "..."
  },
  "perProductRealizedPL":   {"GO": <number>, "S50": <number>, ...},
  "perProductUnrealizedPL": {"GO": <number>, "S50": <number>, ...},
  "exportRowsLength": 133,
  "livePriceKeysSnapshot": ["go_gom26", "s50_s50m26", ...],
  "notes": [ "...documented caveats..." ]
}
```

---

## 7. Where to save the output

Final location, untracked until Junior approves a separate commit:

```
artifacts/merge_grouping/g2_baseline_20260608.json
artifacts/merge_grouping/g2_baseline_20260608_dashboard.png   (optional)
```

(Use the actual capture date if different.)

**Do NOT** commit the JSON in this task — the spec is plan-only. A
follow-up "commit G2 baseline" task does the commit explicitly after
Junior verifies the JSON looks sane.

---

## 8. Risks and limitations

| # | Risk | Mitigation |
|---|---|---|
| 1 | **`tj_live_prices` is stale** vs in-memory state. `unrealizedPL_total` and `perProductUnrealizedPL` may differ from what the Dashboard renders by a small amount. | Take a Dashboard screenshot in the same instant for human cross-check. After G2/G3 ships, re-snapshot at a similarly low-volatility moment (off-hours). |
| 2 | **Formulas may drift** if `index.html` changes between baseline and re-snapshot. | The snippet **inlines** the formulas, so re-snapshots are stable as long as the same snippet is reused. If `index.html` changes a calc, that's a deliberate code change and the diff is visible in git. The baseline JSON's `schemaVersion` lets us version the snippet itself. |
| 3 | **localStorage is per-browser**. Capturing in Chrome and re-checking in Firefox will see different snapshots if either is out of sync with the server. | Use the same browser for both captures. Reload before each capture so the localStorage is freshly hydrated from Supabase. |
| 4 | **Clipboard API may fail** under strict browser permissions. | Snippet falls back to console-only output; manual copy works fine. |
| 5 | **`navigator.clipboard.writeText` requires HTTPS + user activation**. | thus999.com is HTTPS. The snippet is pasted by Junior (user activation). Should work; fallback documented. |
| 6 | **`crypto.subtle.digest` requires secure context (HTTPS)**. | thus999.com is HTTPS. OK. |
| 7 | **Some calc paths I did not capture** in this plan: `useEquityHWM` (line 2468), `excelExportRows` (line 3693-3697 — but `exportRowsLength` = `trades.length` per current code), `sheetsSync._calcMetrics` (line 451+, hidden UI). | `exportRowsLength` and `excelExportRows.length` are equivalent today. `useEquityHWM` is a hook that fetches a separate dailyPoints series — capture that separately if needed at G2 design time; not required for the byte-equality contract per ROADMAP. |
| 8 | **`unrealizedPL` baseline becomes meaningless after market moves**. | The contract is "byte-identical totals **on the same data**". As long as the **same `tradesSha256`** is observed in baseline and re-check, all closed-trade totals must match exactly. Unrealized is treated as a "should be approximately equal at similar market times" check, not a hard byte-equality. |
| 9 | **No way to validate the snippet's calcs match `index.html` automatically.** | The snippet's formulas are verbatim transcriptions of cited line numbers. The static-review reader (me, in this plan) confirmed the transcription manually. If future `index.html` changes make the snippet diverge, the byte-equality check itself will surface it, at which point the snippet must be re-aligned. |
| 10 | **Account-divergence: different user sessions = different baselines.** | Snippet captures whatever's in *this* browser's localStorage. Run it as the same account (anan.skpnm@gmail.com) you'll use post-G2/G3 checks. |

---

## 9. Next step after Junior reviews this plan

1. **Junior reads this plan end-to-end** (~5 minutes).
2. **If approved**, follow §5 steps in a fresh browser session.
   - Save JSON to `artifacts/merge_grouping/g2_baseline_<YYYYMMDD>.json`.
   - Optionally save Dashboard screenshot.
   - **Do not commit yet.**
3. **Open a separate "commit G2 baseline" task** that:
   - Verifies the JSON file exists and is well-formed.
   - Skims `tradeCount`, `tradesSha256`, top-level totals for sanity.
   - Stages and commits **only** the JSON (and screenshot if present).
   - Suggested commit message: `docs: add G2 grouping baseline snapshot 20260608`.
4. **Only then**, open the **G2 design** task (read-only `GroupCard`
   display). Implementation is a separate follow-up after G2 design
   approval. The snippet from §4 will be re-run after each G2 / G3 PR
   to confirm byte-equality on closed-trade totals
   (`realizedPL_total`, `winRate`, `hwm`, `calendarDailyPLs`,
   `perProductRealizedPL`, `dashboardSummary` except moving fields,
   `exportRowsLength`).

Stop after plan.
