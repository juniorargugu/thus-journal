# THUS Journal — Merge / Grouping Re-entry Audit v2

Generated 2026-06-03 BKK. Read-only audit. No code/runtime/data touched. No deploy, no push, no DB write.

> **Status: MERGE_GROUPING_AUDIT_COMPLETE.** A locked non-destructive
> grouping design **already exists** in `ROADMAP.md` lines 87-210 (commit
> `05105ce` — *docs: lock non-destructive trade grouping design*,
> 2026-05-20). This audit does NOT re-litigate that design. It validates
> the design against the current code, confirms gate readiness, surfaces
> two pieces of dead-but-in-tree merge code that need physical removal
> before G3, and recommends the next concrete step: **G1 (schema + RLS
> only)**, contingent on Junior approving the migration SQL in the
> Supabase SQL Editor.

---

## 1. Executive summary

| Question | Answer |
|---|---|
| Does a prior locked design exist? | ✅ YES — `ROADMAP.md:87-210` (commit `05105ce`, 2026-05-20). Design = `trade_groups` table + `trades.group_id` column. |
| Is the destructive Merge UI reachable today? | ❌ NO — both entry buttons commented out (PositionCard `index.html:2768-2773`, PageJournal `index.html:3699-3703`). |
| Is the destructive Merge logic removed from the tree? | ❌ NO — dead but reachable if a button were re-added: `handleMerge` (`index.html:3252-3284`), `mergeSelected` (`index.html:3588-3617` — still writes `_hiddenByMerge:true`). |
| Are there any `_hiddenByMerge` readers anywhere in the app? | ❌ NO — grep returns 1 writer + 1 comment, 0 readers. The double-count class of bug remains latent if Merge were re-enabled. |
| Does the legacy `isMerged:true` close path still work? | ✅ YES — `MergedCloseForm` (`index.html:1932`), badge rendering (`index.html:2173, 2218, 2700`). Per ROADMAP `legacy isMerged coexistence` section, this is intentional. |
| Are the pre-G1 gates satisfied? | ✅ 3 of 5 confirmable from code: `[DIAG] TEMPORARY` logs **gone** (0 matches); `affected===0` tripwire permanent (`index.html:254-255`); next-series resolver landed (`33c9320`). The 2 gates that need Junior judgment: ≥2 weeks clean `[trades][write] affected=0/N` events; Block 5 delete-the-last-trade smoke documented. |
| Does the current persistence model support adding `group_id` columnar safely? | ✅ YES — `db.saveTrades` already does `rows = trades.map(t => ({id, user_id, product_id, …, raw:t}))`. Adding `group_id:t.groupId||null` to that map is a one-line extension. The full trade is mirrored in `raw` so old clients won't lose any field. |
| Recommended next step | **G1 only.** Apply schema + RLS via Supabase SQL Editor (Junior). No app changes in the same PR. Then `git status` returns clean before any G2 UI work begins. |

---

## 2. Preflight state and prior design artifacts

### 2.1 Branch + working tree

- Branch: `main`
- HEAD: `208f534 docs: GUGU freeze + Notes bulk-import gate`
- Local ahead of `origin/main` by **2 commits** (`208f534`, `603988e`); 0 behind.
- Working tree NOT clean — untracked items:
  - `.gitignore`
  - `RESOURCE_AUDIT.md`
  - `archive/` (contains `index_20260330_broken.html`, `index_20260331_1400.html` — old broken HTML snapshots, not merge-related)
- None of the untracked items are this audit's concern. The new report at `artifacts/merge_grouping/merge_grouping_reentry_audit.md` is the only file this turn writes.

### 2.2 Recent relevant commits

```
208f534 docs: GUGU freeze + Notes bulk-import gate
603988e fix: clarify Journal margin alert metrics
b33d964 fix: resolve next-series product lookups in Journal metrics
05105ce docs: lock non-destructive trade grouping design       ← LOCKED DESIGN (G0)
8fa3450 chore: remove temporary DIAG console logs              ← Gate 3 satisfied
5d1f04f feat: add guided trade note templates
33c9320 fix: resolve next-series live prices in positions      ← resolveProduct hardening
362afb4 feat: add read-only check-in activity feed
406bf94 pivot: archive v1 surfaces and hide unused Journal UI
0e010ba fix: Supabase resource hotspots
7309756 feat: enable closed-trade deletion from Journal
2292c4f docs: roadmap + retain trade diagnostic logs during validation
b798c31 fix: P0 persistence + disable unsafe Journal merge     ← Merge disabled (P0-2)
f03ed03 fix: harden persistence to eliminate trade/deposit data loss
```

### 2.3 Prior design artifacts found

- `ROADMAP.md:23-83` — "Future: Trade Grouping / Thesis Grouping" (the *why* of the P0-2 disable + future direction principles)
- `ROADMAP.md:87-210` — **"Trade Grouping Design Locked — 2026-05-20"** (the canonical G0 design; data model, P/L invariant, label format, validation rules, group notes, ungroup semantics, legacy `isMerged` coexistence, phase order G0→G6, gates before G1)
- `ROADMAP.md:212-244` — `[DIAG] TEMPORARY` log policy (Gate 3 — confirmed satisfied by commit `8fa3450`)
- `docs/notes_taxonomy.md` — unrelated to grouping
- No standalone artifacts/ folder pre-existed; this is the first artifact under `artifacts/merge_grouping/`.

**This audit does NOT propose a different design.** It reconciles the locked design against current code.

---

## 3. Current merge / grouping code inventory

### 3.1 Disabled at UI, but logic still in-tree

| Surface | File:line | Status | Risk if re-enabled |
|---|---|---|---|
| Open-positions Merge button (PositionCard `🔗`) | `index.html:2768-2773` | **Commented + visible disabled button** with title `"Merge ปิดชั่วคราว — กำลังรอ feature ใหม่ที่ไม่ลบ note ของแต่ละไม้"` and `disabled` attribute. ROADMAP citation in comment. | High — wired to `onMergeStart` → `startMerge` (`index.html:3276-3282`) → `setMergeMode(true)` |
| `mergeMode` UI bar in PositionsBoard | `index.html:3391-3406` | Render-gated on `mergeMode` state. Currently unreachable. | If reached, `handleMerge` button creates a synthetic open trade via `onAddTrade(merged)`. Originals NOT marked `_hiddenByMerge`, so they'd remain visible → would **double-count open exposure** (margin + unrealized P/L). |
| `handleMerge` (open positions) | `index.html:3252-3274` | Dead but callable from the UI bar above. Writes new trade with `isMerged:true, mergedFromIds:[...], subTrades:[…]`. Does NOT delete or hide originals. | **DO NOT REUSE.** Conflicts with locked design (synthetic trade row in `trades[]`). |
| Closed-trades Merge entry button (PageJournal) | `index.html:3699-3703` | Removed (only the comment remains). `mergeActive` state still declared (`index.html:3588`) and used by table header (`index.html:3733-3735`) — render-gated, currently unreachable. | If reached, `mergeSelected` (`index.html:3588-3617`) writes the synthetic merged closed-trade AND sets `_hiddenByMerge:true` on children. **This is the classic double-count path (every reducer counts both children and the merged row).** |
| `mergeSelected` (closed trades) | `index.html:3588-3617` | Dead but callable. **Still writes `_hiddenByMerge:true` to children at line 3613.** | **DO NOT REUSE.** This is the exact code the ROADMAP P0-2 was written against. |
| `MergedCloseForm` (legacy close path) | `index.html:1932-1959` | **LIVE.** Triggered by `closingTrade?.isMerged && subTrades.length > 0` (`index.html:3286, 3486`). | Acceptable — per ROADMAP `Legacy isMerged coexistence`, existing `isMerged:true` rows must remain closeable. New grouping never creates `isMerged` rows. |
| `isMerged` badge + sub-trade list rendering | `index.html:2173, 2218-2240, 2700` | Live for legacy data. | Acceptable for read-back of legacy rows. |

### 3.2 Dead state declarations that should be removed in G3

Per `ROADMAP.md:193` (G3 goal: *"Removes dead `handleMerge`, `startMerge`, `mergeMode`, and `mergeIds` from PositionsBoard"*), these become unreachable code once `[+ Group]` ships:

```
mergeMode, setMergeMode      (index.html:3214)
mergeSym, setMergeSym        (index.html:3215)
mergeIds, setMergeIds        (index.html:3216)
handleMerge                  (index.html:3252-3274)
startMerge                   (index.html:3276-3283)
cancelMerge                  (index.html:3284)
mergeActive, setMergeActive  (index.html:3588)
selMerge, setSelMerge        (index.html:3589)
toggleSelMerge               (index.html:3590)
exitMergeMode                (index.html:3591)
mergeSelected                (index.html:3592-3617)
canMerge                     (index.html:3617-onward)
```

**v0.1 audit recommendation:** leave them in place **until G3**. Removing them before G2/G3 would touch the file in a way orthogonal to the gate sequence and risk an accidental UI regression. Cite the to-remove list explicitly in the G3 PR description so reviewers can verify the deletion is byte-exact.

### 3.3 `_hiddenByMerge` reader scan

```
$ grep -n "_hiddenByMerge" index.html
3613:    onUpdateTrade&&sel.forEach(t=>onUpdateTrade({...t,_hiddenByMerge:true}));
3700: comment: "_hiddenByMerge" was written to sub-trades but never read by any
```

**0 readers, 1 writer (dead), 1 comment.** The legacy bug class is latent. If any reducer is later written that *does* filter on `_hiddenByMerge`, double-count returns for any legacy data. Per ROADMAP §"Hard rules": *"Do not introduce hidden rows in any reducer."* — preserve this rule.

### 3.4 `trade_groups` / `group_id` references in app code

**0 matches.** No JS code currently reads or writes group metadata. The locked design is purely documentation today. This is correct for phase G0 (design only) and remains correct until G2.

### 3.5 Other relevant code

- `MOCK_TRADES` default row template `_D = {isMerged:false, mergedFromIds:[], subTrades:[], partialCloses:[], preImages:[], postImages:[]}` (`index.html:843`). Legacy merge fields are part of the default trade shape — they will continue to serialize as `false`/`[]` on new trades forever. This is fine; no removal needed.
- `archive/` (untracked) contains only two old broken HTML snapshots (`index_20260330_broken.html`, `index_20260331_1400.html`). No grouping-related dead code outside `index.html`.

---

## 4. Current trade persistence model

### 4.1 Trade object shape (in-app)

The trade default carries legacy merge fields plus standard fields. Example trade row (post-import or after save) has at minimum:

```
id, productId, contractCode, direction, contracts, remainingContracts,
entryPrice, exitPrice, openDateTime, exitDateTime, status, setupType, exitReason,
feeling, tradeRating, preNote, postNote, preImages, postImages,
isMerged, mergedFromIds, subTrades, partialCloses,
plus any per-trade extension fields.
```

### 4.2 Columnar vs raw split (`db.saveTrades`, `index.html:228-273`)

`saveTrades` writes each trade as ONE row with:

```js
const rows = trades.map(t => ({
  id:                  t.id,
  user_id:             uid,
  product_id:          t.productId,
  direction:           t.direction,
  status:              t.status,
  contracts:           t.contracts,
  remaining_contracts: t.remainingContracts || t.contracts,
  entry_price:         t.entryPrice,
  exit_price:          t.exitPrice,
  entry_date:          t.entryDate,
  exit_date:           t.exitDate,
  note:                t.note || null,
  raw:                 t,                  // <-- full object mirrored as JSONB
}));
```

| Field source | Goes to | Notes |
|---|---|---|
| Columnar | `trades.{id, user_id, product_id, direction, status, contracts, remaining_contracts, entry_price, exit_price, entry_date, exit_date, note}` | These are the indexable / queryable fields. |
| Raw JSON | `trades.raw` (JSONB) | Mirrors the full in-app trade. All legacy merge fields (`isMerged`, `subTrades`, `mergedFromIds`, `partialCloses`, `preImages`, `postImages`, `_hiddenByMerge` if it ever appears) live here. |

**For grouping:** the ROADMAP-locked design adds `group_id uuid REFERENCES trade_groups(id) ON DELETE SET NULL` as a **new columnar field**. To wire it into `saveTrades` requires exactly one new line:

```js
group_id: t.groupId || null,
```

`raw:t` already carries any future fields automatically, so backward compatibility holds even if a client is one release behind.

### 4.3 Open vs closed vs delete behavior

- Open trades: same upsert path; differ only by `status:"open"` and `exit_price/exit_date` being null.
- Closed trades: same upsert path; `status:"closed"`, `exit_price/exit_date` set.
- Edits: same upsert path; full row re-written on every save.
- Deletes: handled by the **reconcile-delete** step (`index.html:257-263`):
  - `const removedIds = knownIds ? [...knownIds].filter(id => !localIds.has(id)) : []`
  - `if (removedIds.length > 0) SUPA.from("trades").delete().eq("user_id", uid).in("id", removedIds)`
  - **Critical:** only IDs that *this tab knew about* and is no longer sending. Rows added by another tab/device are preserved.

### 4.4 Optimistic concurrency, affected-row verification

- **Per-trade upsert tripwire** (`index.html:252-255`): `affected === 0` → POSSIBLE RLS / CONSTRAINT DENIAL warning + return `ok:false`. **Permanent** per ROADMAP §"Permanent (do not remove with the rest)".
- **Optimistic concurrency** lives on `portfolio` / `products` / `notes` / `user_data` via `.eq("updated_at", expectedUpdatedAt)` (e.g. `index.html:287-298, 311-322, 336-348, 369-381`). On conflict, the save returns `{ok:false, conflict:true}` and the client refuses to overwrite.
- **Trades table itself has no `updated_at`-based OC** — instead it relies on per-row idempotent upsert + the affected-rows tripwire. This is sufficient for grouping if the group join lives on a separate `trade_groups` table with its own OC.

### 4.5 `product_id` vs `raw.productId`

- `product_id` (columnar, snake_case) and `raw.productId` (JSON, camelCase) **must remain consistent.** Currently they always do because `saveTrades` derives both from `t.productId`.
- Grouping must preserve this invariant — if grouping ever rewrites a trade row, it must rewrite both fields together via the existing `saveTrades` path. ROADMAP §"Validation rules v0.1" implies grouping does **not** rewrite `product_id` (it only sets `group_id`), so this is automatic.

### 4.6 Next-series product handling

`resolveProduct(products, pid)` (`index.html:83-86`) is the canonical resolver:

```js
const resolveProduct = (products, pid) => {
  if (!pid) return null;
  if (pid.endsWith("_next")) {
    const base = pid.replace("_next","");
    return products.find(p => p.id === base);
  }
  return products.find(p => p.id === pid);
};
```

There are **30+ call sites** for `resolveProduct` across the file. Any group-summary calculation MUST use this resolver — never look up products by raw `productId` directly. The next-series live price fix (commit `33c9320`) and the metrics fix (`b33d964`) both landed in the last 14 days; both pin grouping's product-resolution requirements.

ROADMAP §"Validation rules v0.1" specifically allows current + next series in a single group (e.g. `S50M26 Long + S50U26 Long`). The product-family check uses `t.productId.replace(/_next$/,"")` — same suffix-strip pattern as `resolveProduct`.

### 4.7 LocalStorage ↔ Supabase divergence

- `db.loadAll` (`index.html:185-227`) hydrates 5 critical tables. If any **critical** read fails, `loadAll` returns `{ok:false, fatal:true}` and the app refuses to mark hydrated — this is the post-`f03ed03` divergence-preserving guarantee.
- `localStorage` is the in-tab working set; Supabase is the canonical store. Optimistic concurrency on `portfolio`/`products`/`notes`/`user_data` plus the per-row upsert tripwire on `trades` keeps divergence small.
- **For grouping:** `trade_groups` is a separate small table. Its read should be folded into the existing `loadAll` batch (so all hydration succeeds or fails together). Optimistic concurrency on `trade_groups.updated_at` follows the existing `portfolio/notes` pattern.

### 4.8 Trades primary-key shape (per memory)

`trades_pkey` is **compound (id, user_id)**; a separate `UNIQUE(id)` constraint exists (added 2026-05-08) so `onConflict:"id"` works (per memory `reference_thus_journal_trades_pk`). This is load-bearing for the proposed `trades.group_id uuid REFERENCES trade_groups(id)` FK: the FK only needs to reference `trade_groups(id)`, which is its own simple `uuid PRIMARY KEY` in the locked design. No compound-FK gymnastics needed.

---

## 5. UI surfaces affected

| Surface | Source | Current behavior | If v0.1 grouping touches it | v0.1 verdict |
|---|---|---|---|---|
| Open positions table (`PositionsBoard`) | `index.html:3214+` | Renders per-trade `PositionCard`. Merge UI dead but in-tree. | G3 adds `[+ Group]` button and a `GroupCard` parent for `group_id !== null` trades. Children render under expand/collapse. | ✅ Primary target for v0.1 |
| Closed trades table (`PageJournal`) | `index.html:3588+` | Per-trade rows; legacy `isMerged` badge for old merged rows. | G3.5 (optional later). v0.1 SHOULD NOT touch. | ❌ Skip in v0.1 |
| Trade detail modal | (component used for child trades) | Per-trade view + edit. | Open child rows from group view via the same modal. No changes needed in v0.1. | ✅ No-op (reused) |
| Edit trade modal | Same | Per-trade edit. | Child rows remain individually editable. | ✅ No-op (reused) |
| Close trade flow | `closingTrade` + `MergedCloseForm` | Per-trade close; legacy merged uses `MergedCloseForm`. | Per-leg close stays the same in v0.1. Group close = NOT supported in v0.1. | ✅ No-op |
| Delete trade flow | `deleteTrade` (`index.html:8272+`) | Per-trade delete. | Per-leg delete stays the same. Group delete = NOT supported in v0.1; ungroup first. | ✅ No-op |
| P/L summaries (Dashboard, Calendar, Journal totals) | many | Reduce over `trades[]`. | **Must remain unchanged.** P/L invariant requires they ignore `group_id`. | ❌ Untouched |
| Dashboard metrics | `PageDashboard` | Computes win rate, HWM, equity from `trades[]`. | **Untouched.** | ❌ Untouched |
| Product-level aggregation | Per-product P/L summaries | Reduces by `productId` family. | **Untouched.** | ❌ Untouched |
| Notification Center / profit reminders | (lives in App) | Triggered on trade events. | **Untouched in v0.1.** | ❌ Untouched |
| Margin alert / margin usage | `calcPositionValue` consumers (`index.html:1475, 3228`) | Sum of `calcPositionValue` across open trades. | **Untouched.** Group does not change open-position margin total. | ❌ Untouched |
| Excel export | `index.html:3693-3697` | `XLSX.writeFile` over `filtered` trades. | Stays per-trade row in v0.1. Group label is display-only; future column-add deferred. | ❌ Untouched |
| Sheets sync | `sheetsSync` object (`index.html:451+`, UI hidden 2026-05-12) | Auto-fire on save disabled. | Stays disabled. **Untouched.** | ❌ Untouched |
| LocalStorage hydration | `ls.*` calls + `db.loadAll` | All trade fields carried in `raw`. | Add `tj_trade_groups` (or fold into existing `tj_trades` envelope — see §6). | ⚠️ Touches loader |
| Supabase sync | `db.saveTrades / loadAll` | Existing trades flow unchanged. | Add `db.saveTradeGroups / loadAll → trade_groups`. | ⚠️ Touches loader |
| Mobile layout | `md:` / `md:hidden` classes throughout | Responsive. | `GroupCard` must inherit responsive classes. | ⚠️ Verify in G2 |

**v0.1 scope (smallest possible):** Open positions only — `PositionsBoard` plus a small `GroupCard`. Skip everything in the "Untouched" rows above.

---

## 6. Non-destructive grouping data model — options

The locked design (`ROADMAP.md:93-117`) already chose **Option B (`trade_groups` + `trades.group_id`)**. This section reconciles that choice against the alternatives so the audit is complete.

### Option A — `trades.group_id` column only (no `trade_groups` table)

| Criterion | Assessment |
|---|---|
| Pros | Minimum schema. One FK-less UUID column on `trades`. |
| Cons | No place to store group label / pre-note / post-note. Forces label to be derived (auto-suggested) every render. No archived_at, no group-level audit. |
| Migration risk | Tiny (single ADD COLUMN). |
| RLS | Inherits `trades` policy. |
| Rollback | `ALTER TABLE trades DROP COLUMN group_id`. |
| Multi-product / next-series | Same as Option B. |
| Auditability | Same as Option B. |
| Cross-device | Works (group_id rides with trade row). |
| **Verdict vs locked design** | Insufficient — locked design uses group pre/post notes (`ROADMAP.md:160-169`). |

### Option B — `trade_groups` table + `trades.group_id` (LOCKED)

| Criterion | Assessment |
|---|---|
| Pros | Group label + notes have a stable home. Ungroup is `archived_at = now()` instead of destructive delete. Group-level audit trail. |
| Cons | Two-table schema; two writers (`saveTrades`, `saveTradeGroups`). Slightly larger surface. |
| Migration risk | One new table + one column. Mirrors existing `notes`/`portfolio` table patterns. |
| RLS | `trade_groups.user_id = auth.uid()` mirror of trades policy. |
| Rollback | `DROP TABLE trade_groups; ALTER TABLE trades DROP COLUMN group_id;` |
| Multi-product / next-series | Validated by ROADMAP rules (same family after `_next` strip). |
| Auditability | Group row carries history (created_at, updated_at, archived_at). |
| Cross-device | Works if `trade_groups` is folded into `loadAll`. |
| **Verdict vs locked design** | ✅ Locked direction. |

### Option C — Grouping in `trades.raw` JSON only

| Criterion | Assessment |
|---|---|
| Pros | Zero schema change. Group metadata rides inside `raw`. |
| Cons | Group label / notes scattered across multiple `raw` blobs. Group-level invariants impossible to enforce without a denormalization round-trip. Querying open groups requires JSON filtering. Ungroup is N writes instead of 1 + 1. |
| Migration risk | None. |
| RLS | Inherits `trades`. |
| Rollback | Delete keys from `raw`. |
| Multi-product / next-series | Possible but messy. |
| Auditability | Group rows can't exist independently of trades — can't archive a group whose last child was deleted. |
| Cross-device | Works but slower. |
| **Verdict vs locked design** | ❌ Reject — violates ROADMAP §"Hard rules": *"Do not write a flag to existing trade rows to indicate group membership unless it's a real `group_id` foreign key with a referenced `trade_groups` row."* |

### Option D — UI-only heuristic grouping (no persisted grouping)

| Criterion | Assessment |
|---|---|
| Pros | Zero schema change. |
| Cons | Lost on reload, lost on tab switch, lost cross-device. User cannot label a group. No way to remember "this is one campaign". |
| **Verdict vs locked design** | ❌ Reject — fails the product premise (user wants to view/manage legs as one logical position persistently). |

### Recommendation

**Stick with Option B (the locked design).** No reconsideration warranted; all 4 options were already weighed before commit `05105ce`.

---

## 7. Recommended v0.1 design

This section restates the locked design and pins it to the audited code.

### 7.1 Schema (illustrative pseudocode — NOT a migration file)

```
trade_groups
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid()
  user_id      uuid NOT NULL REFERENCES auth.users(id)
  label        text NOT NULL                             -- auto-suggested, user-editable
  group_pre_note   text
  group_post_note  text
  created_at   timestamptz NOT NULL DEFAULT now()
  updated_at   timestamptz NOT NULL DEFAULT now()
  archived_at  timestamptz                                -- null = active

  RLS:  user_id = auth.uid()
  INDEX: trade_groups(user_id)
  INDEX: trade_groups(user_id) WHERE archived_at IS NULL

trades
  + group_id  uuid REFERENCES trade_groups(id) ON DELETE SET NULL  -- new column
  INDEX: trades(group_id) WHERE group_id IS NOT NULL
```

(SQL not authored in this audit per spec. G1 task will produce the exact migration file for Junior to review.)

### 7.2 Source of truth

- `trades` rows remain canonical execution records.
- `trade_groups` is metadata + group-level notes — never a trade.
- **No synthetic group row in `trades[]`. Ever.** (ROADMAP `Hard rules`.)

### 7.3 P/L invariant (load-bearing)

All P/L reducers walk raw `trades[]` and ignore `group_id`. Group totals are computed at render time from child rows. Pre/post grouping snapshot must show byte-identical totals.

Reducers that must remain unchanged (from ROADMAP + code inventory):

```
realizedPL, calcCBStatus, calcWinningPL, reconstructStepHistory,
reconstructHWM, useEquityHWM, buildSummaryPayload, buildCanonicalMetrics,
Calendar.calData, sheetsSync._calcMetrics
plus every inline `.reduce(...calcNetPL)` block in PageDashboard, PagePositions,
PageJournal, and the bottom-of-table aggregation strip (`index.html:3710-3712`).
```

The audit pass for G2 must grep for `.reduce(` patterns that touch trades, and confirm each ignores `group_id`. A snapshot diff (Step 5.5 of the locked plan) is the runtime safeguard.

### 7.4 Group label (auto-suggest)

Format: `{FAMILY} {Direction} — {series_set}{ ×n if useful}`

Family display map: `GO → GOLD`, `SVF → SILVER`, `S50 → S50`, `USDJPY → USDJPY`.

Display-only. No reducer reads it.

### 7.5 Validation rules v0.1 (verbatim from ROADMAP)

- Same product family required: `t.productId.replace(/_next$/,"")`.
- Same direction required.
- Current + next series allowed (e.g. `S50M26 Long + S50U26 Long`).
- Mixed product family rejected.
- Mixed direction rejected; hedge groups deferred to advanced mode.
- Minimum 2 children.
- Drafts (`status === "draft"`) rejected.
- Already-grouped trades rejected; user must ungroup first.
- Legacy `isMerged:true` rows rejected.
- No hard cap on group size; soft warning at >10.

### 7.6 Group status (derived)

- `open` if any child has `status === "open"`.
- `closed` if all children have `status === "closed"`.
- Status is NOT stored on `trade_groups`.

### 7.7 Group notes (fresh write layer, no two-way sync)

- `group_pre_note`, `group_post_note` live on `trade_groups`.
- Reuse existing `<TemplateButtons kind="pre"|"post">` and `appendTemplate`.
- Child `preNote`, `postNote`, `preImages`, `postImages` stay on child trade rows. Unchanged.
- Group view shows child notes as a read-only live timeline.
- No snapshot, no auto-copy, no two-way sync.
- Editing a child note from group view opens the existing `TradeDetailModal`.

### 7.8 Ungroup

```sql
UPDATE trades       SET group_id   = NULL WHERE group_id = $1;
UPDATE trade_groups SET archived_at = now() WHERE id      = $1;
```

Child rows return to flat display. Group row + notes recoverable from `trade_groups.archived_at IS NOT NULL`. **No child trade deleted, modified, or hidden by ungrouping.**

### 7.9 Legacy `isMerged` coexistence

Existing `isMerged:true` rows remain readable + closeable via `MergedCloseForm`. New grouping system **never** creates `isMerged` rows, never sets `subTrades` / `mergedFromIds` / `_hiddenByMerge`. Validation rejects grouping of legacy merged rows. No migration in v0.1. G6 legacy cleanup gated on Junior decision after G1-G5 stabilize.

### 7.10 `group_id` placement: columnar AND raw?

- **Columnar** (`trades.group_id`): yes. Indexable, joinable, FK-protected.
- **Raw JSON** (`raw.groupId`): yes — `db.saveTrades` already mirrors the full trade into `raw`, so as soon as the in-app trade object carries `t.groupId`, `raw.groupId` is automatic. No extra code.

### 7.11 Open-trades only in v0.1

`v0.1` UI shows `[+ Group]` only on open positions. Closed-trade retroactive grouping = G3.5 (optional later).

---

## 8. Migration / readiness gates

Pre-G1 gates (from `ROADMAP.md:203-210`). Cross-checked against current state:

| # | Gate | Current state | Source of truth |
|---|---|---|---|
| 0 | Read-only audit complete | ✅ DONE — this document | this file |
| 1 | Clean persistence logs ≥ 2 weeks (no `[trades][write] upserted-affected=0/N`) | ⚠️ NEEDS JUNIOR CONFIRMATION — check production console + Supabase logs over the trailing 14 days. Code-level tripwire is in place (`index.html:252-255`). | Junior |
| 2 | Block 5 validation passed (delete-the-last-trade smoke) on deployed build, documented | ⚠️ NEEDS JUNIOR CONFIRMATION — code is in place (empty-array MUST fall through, `index.html:230-247`); deployed verification still required. | Junior |
| 3 | `[DIAG] TEMPORARY` runtime logs removed | ✅ DONE — `grep "[DIAG] TEMPORARY"` returns 0 matches (commit `8fa3450`). Permanent `affected===0` tripwire retained (`index.html:252-255`). | code |
| 4 | Migration SQL reviewed + approved manually by Junior in Supabase SQL Editor before execution | ⏳ PENDING — SQL not yet authored. G1 task will draft it. Junior must approve before SQL Editor run. | Junior |
| 5 | P/L snapshot baseline ready | ⏳ PENDING — needs a per-trade-list snapshot taken before any G2 code change, then re-taken after, with byte-equality check. Defer to G2 task. | Junior + G2 task |

Phase plan (from ROADMAP `Phase order`):

```
G0 — Design only.                                      ✅ Delivered 2026-05-20
G1 — Schema + RLS only (SQL via Supabase SQL Editor).  ⏳ Next, contingent on gates 1+2
G2 — Read-only display. GroupCard renders for
     group_id !== null rows. Create/ungroup manual.    ⏳ Then
G3 — Open-position create + ungroup UI. Replace dead
     mergeMode with [+ Group]. Remove dead handleMerge,
     startMerge, mergeMode, mergeIds.                  ⏳ Then
G3.5 — Closed-trade retroactive grouping (optional).    ⏳ Maybe
G4 — Group pre/post notes + child note timeline.       ⏳ Then
G5 — [Insert GUGU summary] reads checkin_events.       ⏳ Gated on Capture Bot Day 4 (long since shipped — re-confirm)
G6 — Legacy isMerged cleanup. Junior approval.         ⏳ Last
```

**Each phase must pass the P/L-invariant snapshot test before the next begins. Do not bundle G1 with any UI phase in the same PR.**

---

## 9. Proposed UX flow (v0.1)

This UX is recommended below the locked design's `Phase G3` scope.

1. **Select multiple open legs.** User taps a new `[+ Group]` button (it replaces the disabled `🔗` placeholder at `index.html:2768`). Enters group-mode (same idea as the old `mergeMode` but with **no destructive handler attached**).
2. **Validation runs live.** Rejected combinations show inline reason (mixed product family / mixed direction / draft / already-grouped / `isMerged:true` / <2 children).
3. **"Group selected" confirmation modal** shows:
   - List of selected legs (id, product+series, direction, qty, entry)
   - Derived: product family, direction, total qty, weighted average entry, current derived unrealized P/L
   - Warning: **"Original rows remain unchanged. Ungroup any time."**
   - Auto-suggested label (editable): `S50 Long — M26+U26 ×3`
4. **Confirm → write.** Single transaction-ish flow:
   - INSERT into `trade_groups`
   - UPDATE matching trades' `group_id` (via the same `saveTrades` upsert path)
5. **UI displays grouped row** as `GroupCard` containing expand/collapse for children. Children remain individually editable / closable via their existing modals.
6. **Ungroup** button on the group row → `archived_at` flip + clear children's `group_id`. UI returns to flat per-leg display.

### Explicit v0.1 decisions

| Question | v0.1 answer | Rationale |
|---|---|---|
| Group open trades only? | YES | ROADMAP `Phase G3` is open only; G3.5 closed retro is optional |
| Group closed trades? | NO | Defer to G3.5 |
| Group close? | NO | Per-leg close stays the only way |
| Group delete? | NO | Must ungroup first; group row never appears in `trades[]` so there is no "trade" to delete |
| Group edit? | LABEL ONLY | Pre/post notes land in G4 |
| Children hidden or expandable under group? | EXPANDABLE; default collapsed | Consistent with PositionCard density |
| Mixed products allowed? | NO | ROADMAP validation: same family required |
| Mixed direction allowed? | NO | ROADMAP validation; hedge groups deferred |
| Mixed series (M26 + U26)? | YES if same family after `_next` strip | ROADMAP validation explicitly allows |
| Mixed portfolio/account? | N/A — Journal is single-account today | No multi-account schema yet |

---

## 10. Derived calculations and invariants

### 10.1 Formulas (all derived at render time from children — never stored)

For a group `g` with children `C`:

```
total qty           = Σ_c contracts(c)
weighted avg entry  = Σ_c (entry(c) * contracts(c)) / total_qty
                       (only meaningful when all children share direction — which v0.1 enforces)
unrealized P/L      = Σ_c calcNetPL(resolveProduct(products, c.productId),
                                    c.contracts,
                                    c.entryPrice,
                                    livePrice(c),
                                    c.direction)
                       for c with status === "open"
realized P/L        = Σ_c calcNetPL(resolveProduct(products, c.productId),
                                    c.contracts,
                                    c.entryPrice,
                                    c.exitPrice,
                                    c.direction)
                       for c with status === "closed" and exitPrice !== null
status              = "open"   if any c has status === "open"
                       "closed" if all c have status === "closed"
margin estimate     = Σ_c calcPositionValue(p, c.contracts, c.entryPrice)
                       only if shown; otherwise omit
```

### 10.2 Reuse existing helpers

**Required** — do not reimplement:

- `resolveProduct(products, t.productId)` (`index.html:83-86`)
- `calcNetPL(p, contracts, entry, exit, direction)` (many call sites; canonical implementation high in `index.html`)
- `calcPositionValue(p, contracts, entryPrice)` (used at `index.html:1475, 3228, 3238`)
- `getRoundTripComm(p)` (used at `index.html:3711`)
- `calcPL(p, ...)` (`index.html:3710`)
- `getLivePrice(livePrices, t, p)` (used in `PositionCard` at `index.html:3437-3438`)
- `contractToLiveKey(baseId, contractCode, baseSymbol)` (used at `index.html:3438`)
- `fmtTHB(value, digits)` for display

### 10.3 Invariant: pre/post grouping byte-equality

Before any G2 PR opens, capture a baseline JSON of:

```
{
  realizedPL_total, unrealizedPL_total, winRate, hwm,
  dashboardSummary, calendarDailyPLs,
  perProductRealizedPL (each product),
  excelExportRows.length
}
```

After grouping a representative set of trades in dev, re-capture. Diff must be byte-identical except where the snapshot deliberately includes a group-aware section. This is the runtime guard against the P0-2 double-count class.

---

## 11. Test plan (for future implementation)

### 11.1 Data safety

| Test | What it asserts |
|---|---|
| `trades.length` before grouping === `trades.length` after grouping | No trade row deleted by grouping |
| Each child `trade.id` preserved | No ID rewrite |
| `raw.productId === product_id` columnar | No fork |
| Ungroup preserves all child rows, only group_id cleared | Ungroup is non-destructive |
| `raw` only adds `groupId`; all other keys unchanged | Raw integrity |
| `realizedPL` byte-identical pre/post grouping a closed set | P/L invariant |
| `unrealizedPL` byte-identical pre/post grouping an open set | P/L invariant |
| `resolveProduct(products, "S50M26_next")` resolves correctly inside group | Next-series resolution holds |
| localStorage `tj_trades` count === Supabase trades row count post-group + reload | Hydration parity |

### 11.2 UI

- Group row summary matches sum of children (qty, weighted entry, unrealized P/L)
- Expand shows all children
- Editing a child via the existing modal updates the group summary on next render
- Closing a child (per-leg close, the only v0.1 close path) updates group `status` derivation
- Deleting a child via existing flow updates group; if last child deleted, group `status` is "empty" — UI must handle (display archived state or empty card)
- Ungroup returns to flat per-leg layout; group label preserved in `trade_groups.archived_at` for recovery
- Selected rows clear after group/ungroup

### 11.3 Regression

- Open positions still load identically
- Closed trades still load identically
- Dashboard win-rate, HWM, equity numbers byte-identical
- Notification Center unaffected
- Margin alert unaffected
- Sheets sync unaffected (still hidden)
- Excel export unaffected
- Mobile layout: `GroupCard` inherits `md:` responsive classes
- Old destructive merge code remains unreachable (grep confirms no new caller of `handleMerge`, `mergeSelected`, or `_hiddenByMerge` writer)
- `MergedCloseForm` still triggers for legacy `isMerged:true` rows

### 11.4 Safety / regression tests

| Test | Source |
|---|---|
| `grep -n "_hiddenByMerge" index.html` returns ≤ current count | Static |
| `grep -n "isMerged:true" index.html` written only in legacy fixture (`MOCK_TRADES` if any) — not in any new code path | Static |
| No new `onAddTrade(merged)`-style call signature that creates a synthetic merge row | Static |
| `db.saveTrades` row mapping has exactly one new field (`group_id`); other columnar fields unchanged | Diff review |
| `affected===0` tripwire still fires on simulated RLS denial | Manual smoke or pgmock |

---

## 12. Risks and mitigations

| Risk | Severity | Mitigation | v0.1 status |
|---|---|---|---|
| Re-introducing double-count via a reducer that reads `_hiddenByMerge` | High | Hard ROADMAP rule (`§Hard rules`); static grep test in CI/review; **0 readers exist today** | ✅ Mitigated by design + tested by grep |
| Synthetic group row leaking into `trades[]` | High | Hard rule; type system implies group rows live in `trade_groups`, not `trades` | ✅ Mitigated by design |
| `raw.productId` vs `product_id` divergence after grouping | Medium | Grouping does not rewrite either field; only adds `group_id` | ✅ Avoided |
| Next-series price resolution breaks for grouped legs | Medium | All renderers use `resolveProduct` — group totals call existing per-row helpers | ✅ Avoided |
| P/L calculation drift (group summary computed differently than per-row) | High | Sum existing `calcNetPL`/`calcPL` outputs; never reimplement | ✅ Mitigated |
| Notification Center fires duplicate alerts because group looks like new trade | Medium | Group write inserts a `trade_groups` row, NOT a `trades` row. Notification Center listens on `trades` events — no extra event fires. | ✅ Mitigated |
| Margin alert miscounts grouped legs | Medium | Margin still sums per-trade `calcPositionValue` — group adds zero new rows | ✅ Mitigated |
| Closed-trade history corruption | High | v0.1 does not touch closed trades. G3.5 if/when, separately gated | ✅ Avoided in v0.1 |
| Multi-device sync conflict on `trade_groups` | Medium | OC pattern via `updated_at` (mirror `portfolio`/`notes`/`products` pattern) | ✅ Required at G1 schema design |
| User confusion between group row and real trade row | Medium | Visual `GroupCard` distinct from `PositionCard`; label `⊕ Group`-style badge; ungroup always one tap | ⚠️ Verify in G2 |
| Dead Merge code accidentally re-enabled by uncommenting a button | High | Two existing comment blocks (`index.html:2768-2773`, `index.html:3699-3703`) plus ROADMAP hard rules. G3 deletes the dead code outright. | ⚠️ Until G3 |
| Group operation lost mid-flight (browser crash) | Low | `trade_groups` insert + `trades` group_id update are separate writes. Mid-flight crash leaves orphan group with no children → cosmetic only, ungroup-safe. | ⚠️ Document; not blocking |
| Schema added without RLS | Critical | G1 SQL must include RLS in the same migration. Junior reviews before SQL Editor run. | ⚠️ Hard gate at G1 |
| Migration not idempotent / not rerun-safe | Medium | G1 migration uses `IF NOT EXISTS` for table + column + indexes | ⚠️ Required at G1 |

---

## 13. Explicit non-goals (v0.1)

- ❌ No destructive merge anywhere
- ❌ No closed-trade grouping (defer to G3.5)
- ❌ No group close
- ❌ No group delete (ungroup first; archived group is the recovery path)
- ❌ No row replacement / averaging-only collapse
- ❌ No Notification Center / profit reminder changes
- ❌ No margin formula changes
- ❌ Sheets / Excel export structurally unchanged (legacy per-trade rows; future column-add deferred)
- ❌ No GUGU / Capture Bot work in this PR sequence
- ❌ No `_hiddenByMerge` revival, in any form
- ❌ No deploy in audit phase
- ❌ No schema migration in audit phase
- ❌ No SQL writes in audit phase
- ❌ No localStorage / Supabase data mutation in audit phase
- ❌ No re-enabling the disabled Merge button in any form
- ❌ No new `isMerged:true` row creation in any new flow
- ❌ No multi-account / portfolio grouping (single-account today)

---

## 14. Recommended next step

**G1 — schema + RLS only.** Separately-scoped task. Concretely:

1. **Junior confirms Gate 1** (clean `[trades][write] affected=0/N` logs for the trailing 14 days) and **Gate 2** (Block 5 delete-the-last-trade smoke documented on the deployed build). If either is unmet, fix first; do not start G1.
2. A G1 task **drafts the migration SQL** for:
   - `CREATE TABLE trade_groups (...)`
   - `ALTER TABLE trades ADD COLUMN group_id uuid REFERENCES trade_groups(id) ON DELETE SET NULL`
   - RLS policies on `trade_groups` mirroring `trades`
   - Three indexes per the locked design
   - `IF NOT EXISTS` everywhere (re-run safe)
   - Inline verification snippets
   - Inline rollback (`DROP TABLE trade_groups; ALTER TABLE trades DROP COLUMN group_id;`)
3. **Junior reviews and runs SQL in Supabase SQL Editor.** No app code changes in the same PR.
4. After G1 applies and the app continues to function (no read/write of `group_id` yet — it's a dormant column), a separate G2 task adds read-only `GroupCard` display.
5. G3 adds `[+ Group]` UX AND deletes the dead `mergeMode`/`mergeActive` code blocks listed in §3.2 in the same PR.

**Blockers before implementation:**

- Gate 1 (14-day clean `affected=0/N` log) — needs Junior log review
- Gate 2 (deployed Block 5 smoke documentation) — needs Junior smoke + writeup
- Gate 4 (Junior reviews migration SQL) — produced by G1 task
- Gate 5 (P/L snapshot baseline) — produced before G2

Once Gates 1+2 are confirmed, the G1 task is small (~80 lines of SQL + RLS + verification) and isolated (zero app code change). The locked design (`ROADMAP.md:87-210`) is the source of truth for everything that follows.

Stop after report.
