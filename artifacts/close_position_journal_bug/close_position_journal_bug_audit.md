# P0 Audit — Close Position Disappears From Journal (v2)

**Date:** 2026-06-09
**Repo:** `C:\Users\Junior\Desktop\thus-journal\`
**File audited:** `index.html` (8574 lines, single-file SPA) — **read-only**
**Status:** `P0_CLOSE_POSITION_JOURNAL_AUDIT_CREATED`
**Triage verdict:** §16 resolved one case (stale client, no loss). **REOPENED 2026-06-09** — a *different* close did **not** survive a hard refresh (the position returned to Open Positions, absent from the closed Journal). The "stale-tab only" conclusion is therefore **incomplete**. **CONFIRMED 2026-06-09 → `P0_CLOSE_PERSISTENCE_BUG_CONFIRMED`** for trade `1781008993915` (Junior-confirmed row; server `open`/`raw open`, `updated_at===created_at`). See **§17**.
**Persistence architecture:** **FROZEN — remains frozen.** No evidence yet of a true persistence failure for a *normal* close.

---

## 1. Executive summary

A code-only audit of the close→save→load→render chain found **no defect that would silently delete a normally-closed trade**. Specifically:

- **Close preserves the trade id** and mutates the row in place (`updateTrade`, [index.html:8256](../../index.html#L8256)). A closed trade's id therefore stays in `localIds`, so it can **never** be selected by reconcile-delete ([index.html:259-264](../../index.html#L259-L264)).
- **`saveTrades` persists the full updated object** as `raw:t` ([index.html:242](../../index.html#L242)), and `loadAll` renders from that same `raw` ([index.html:213](../../index.html#L213)). A close written to `raw` survives a reload. The "raw goes stale on reload" theory raised during the fan-out was **investigated and REFUTED** (there is no nested `.raw` sub-field; see §10).
- **G1 is isolated.** No app code reads `trade_groups` or `trades.group_id`; `loadAll` selects only `raw`; `saveTrades` omits `group_id` (null-fills safely). Verdict **`G1_LIKELY_UNRELATED`** (§5).

That leaves three live, evidence-backed explanations, in order of likelihood:

1. **DATA_PRESENT_BUT_HIDDEN — leftover Journal filter.** The Journal list applies an in-session `dateFrom`/`dateTo`/`product` filter ([index.html:3545-3552](../../index.html#L3545-L3552)). A trade closed today is silently excluded if a date-range or product filter was left set. Resets on reload. **Most likely, fully benign.**
2. **DATA_PRESENT_BUT_HIDDEN — partial close left `status:"open"`.** The multi-contract close form keeps `status:"open"` while `remainingContracts > 0` ([index.html:1984](../../index.html#L1984)). The trade then lives in **Positions**, not the closed Journal. Looks "gone" but is not.
3. **LOCAL_HAS_DATA_SERVER_MISSING — silent cloud-save failure.** A close updates React + localStorage immediately, but the debounced (1.5 s) cloud upsert can fail silently (RLS `affected===0`, network, or **base64-image payload bloat**) with **no toast and no retry** ([index.html:7912-7918](../../index.html#L7912-L7918)). On the next reload, the wholesale server overwrite ([index.html:7827-7829](../../index.html#L7827-L7829)) reverts/erases the close. **This is the only candidate that could be a legitimate freeze exception** — and only if the triage in §11 proves server actually lacks the row.

**Recommended next step:** Junior runs the three read-only checks in §11 to classify the bug. Do not touch persistence until that classification lands.

---

## 2. User report (as received)

1. Today Junior closed 2 positions; closing *appeared* to work.
2. A position opened **today** was then closed, and after closing **disappeared** — it did not show on the Journal tab.
3. Junior had to open a new position because a real closed position had an incorrect entered price.
4. Cannot edit a closed position's detail after close → tracked separately as **P1** (out of scope).
5. Attached position image in Journal cannot be clicked to expand → **P3** (out of scope).
6. Wants modal accidental-close confirmation → **P2** (out of scope).
7. Wants MT5 product/spec/price sync → **P4** (out of scope).
8. Wants favicon → **P5** (out of scope).

This audit covers **only** item 2 (the P0 disappearance). P1–P5 are noted, not investigated.

---

## 3. Current blocked / frozen state

- THUS Journal **persistence architecture is FROZEN**. This audit did **not** modify it and recommends keeping it frozen pending §11 evidence.
- G1 schema/RLS migration was applied **today** (`trade_groups` table + nullable `trades.group_id`); run report committed `b2d4f9c`, verified V1–V9 PASS, count 133→133, `trades_with_group=0`.
- G2 baseline JSON work is **paused**; the stale 127-row baseline file (`artifacts/merge_grouping/g2_baseline_20260608.json`) is untracked and was **not** touched or committed.
- GroupCard / `[+ Group]` / merge-removal work is **paused**; none started here.

---

## 4. Immediate triage plan (read-only, 5 minutes)

Goal: classify the bug into exactly one of:
`DATA_PRESENT_BUT_HIDDEN` · `LOCAL_STORAGE_STALE` · `SERVER_HAS_DATA_LOCAL_MISSING` · `LOCAL_HAS_DATA_SERVER_MISSING` · `DATA_ACTUALLY_MISSING` · `BLOCKED_NEED_MORE_EVIDENCE`.

Decision flow once Junior runs §11:

| localStorage (`tj_trades`) | Supabase `public.trades` | Journal tab shows it? | Classification | Leading hypothesis |
|---|---|---|---|---|
| has it, `status:"closed"` | has it, `status:"closed"` | **no** | `DATA_PRESENT_BUT_HIDDEN` | leftover filter (H4/H14) |
| has it, `status:"open"` + `remainingContracts` | same | shows in **Positions** | `DATA_PRESENT_BUT_HIDDEN` | partial close (H12-adjacent) |
| has it, `status:"closed"` | **missing** or `status:"open"` | no | `LOCAL_HAS_DATA_SERVER_MISSING` | silent save failure (H9/H13) |
| missing/stale | has it | n/a | `SERVER_HAS_DATA_LOCAL_MISSING` / `LOCAL_STORAGE_STALE` | hydration / drift |
| missing | missing | no | `DATA_ACTUALLY_MISSING` | true loss (escalate) |

Only `LOCAL_HAS_DATA_SERVER_MISSING` and `DATA_ACTUALLY_MISSING` are persistence-failure candidates that could justify a freeze exception. The first two rows are UI/visibility bugs outside the freeze.

---

## 5. G1 migration interaction check

**Verdict: `G1_LIKELY_UNRELATED`** (causation distinguished from correlation; not assumed merely because V1–V9 passed).

| Question | Answer | Evidence |
|---|---|---|
| Any app code reads `public.trade_groups`? | **No** | only a design comment at [index.html:2769](../../index.html#L2769) |
| Any app code reads/writes `trades.group_id`? | **No** | `saveTrades` column list omits it ([index.html:235-243](../../index.html#L235-L243)); no reads anywhere |
| Does adding `group_id` change `loadAll`'s returned shape? | **No** | `loadAll` does `.select("raw")` ([index.html:188](../../index.html#L188), [:213](../../index.html#L213)) — only the `raw` JSON column; new columns are invisible to a fixed projection |
| Does omitting `group_id` in upsert break? | **No** | column is nullable, no default → upsert null-fills it ([index.html:235-243](../../index.html#L235-L243)) |
| Journal filter/sort/close reference `group_id`? | **No** | filters use `status`/prices/dates only |
| Could migration have altered existing trade fields? | **No evidence**; run report `b2d4f9c` says add-only, 133→133, `trades_with_group=0` | — |

The only `group_id`/`trade_groups` occurrence in app code is the comment at line 2769. `checkin_group_id` ([index.html:1010](../../index.html#L1010), [:1018](../../index.html#L1018)) is an **unrelated** check-in grouping domain, not `public.trades.group_id`. **Distinction:** the timing is suspicious (migration + bug same day) but the code shows zero coupling, so this is **correlation, not causation**, and not a pre-existing-bug exposure path either (the load/save column projections are fixed and unaffected by the new column).

---

## 6. 127 vs 133 correlation check

**Verdict: likely INDEPENDENT (stale-file artifact), not proven — resolve with the ID diff in §11C.**

Key structural fact that breaks the feared link: the app's known-id set (`lastSeenRef.current.tradeIds`, the `knownIds` passed to reconcile-delete) is **re-seeded from the server on every load** ([index.html:7886](../../index.html#L7886)) and updated only from confirmed saves ([index.html:7913](../../index.html#L7913)). Saves are gated behind `dbReady`, which only flips after a successful load ([index.html:7902](../../index.html#L7902)). Therefore **reconcile-delete is never driven by a stale 127-row localStorage/baseline set** — it always runs against the server's actual id set at load time.

- The 127 figure came from a **stale G2 baseline JSON on disk**, not necessarily the live app state. It does not feed the runtime.
- Whether local currently equals server is answerable: **§11C ID diff** lists `server-not-local` and `local-not-server`. If today's missing closed-trade id appears in `local-not-server`, that points to **save failure (H9/H13)**, not the old 127 gap. If it appears nowhere or in `server-not-local`, the 127 gap is a separate, older drift.
- Reload behaviour: a reload re-hydrates wholesale from server ([index.html:7827-7829](../../index.html#L7827-L7829)); if the row is server-side, reload restores it; if not, reload erases the local copy.

---

## 7. Code paths inspected (read-only)

| Path | Location | Role |
|---|---|---|
| `ls` localStorage wrapper | [index.html:177-180](../../index.html#L177-L180) | `get/set` = `localStorage.getItem/setItem` + JSON; **no key prefix** → key is literally `"tj_trades"` |
| `db.loadAll` | [index.html:185-227](../../index.html#L185-L227) | loads `trades` via `.select("raw")`; returns `t.data.map(r=>r.raw)`; critical-table failure → `ok:false` (no setTrades) |
| `db.saveTrades` | [index.html:228-273](../../index.html#L228-L273) | upsert by id + bounded reconcile-delete; `affected===0` tripwire |
| `db.savePortfolio` | [index.html:274-299](../../index.html#L274-L299) | (contrast) has optimistic-concurrency / 406 conflict handling that `saveTrades` lacks |
| `CloseTradeForm` (single close) | [index.html:1863-1930](../../index.html#L1863-L1930) | emits `exitPrice, exitDateTime, exitReason, feeling, tradeRating, winLossReason, postNote, postImages` |
| `MergedCloseForm` (partial / multi-contract) | [index.html:1932-2094](../../index.html#L1932-L2094) | `status:allDone?"closed":"open"` ([:1984](../../index.html#L1984)) |
| Close wiring in Positions | [index.html:3487](../../index.html#L3487) (partial), [index.html:3491](../../index.html#L3491) (full, forces `status:"closed"`) | parent `onClose` handlers |
| `addTrades` / `updateTrade` / `deleteTrade` | [index.html:8210](../../index.html#L8210) / [:8256](../../index.html#L8256) / [:8272](../../index.html#L8272) | state mutators |
| Hydration effect | [index.html:7811-7898](../../index.html#L7811-L7898) | wholesale `setTrades(data.trades)` + `ls.set("tj_trades",…)`; 3× retry; **no LS fallback** |
| `tj_trades` mirror effect | [index.html:7768](../../index.html#L7768) | `ls.set("tj_trades",trades)` on every change once `dbReady` |
| Trades save effect | [index.html:7900-7922](../../index.html#L7900-L7922) | 1.5 s debounce; `res.ok===false` → warn only, keep knownIds |
| `PageJournal` (closed list) | [index.html:3534-3855](../../index.html#L3534-L3855) | filter/sort/render of closed trades |

---

## 8. Close-position flow findings

1. **Id preserved; in-place update.** `updateTrade` does `setTrades(p=>p.map(x=>x.id===t.id?t:x))` ([index.html:8256-8261](../../index.html#L8256-L8261)). Full close forces `status:"closed"` ([index.html:3491](../../index.html#L3491)). DB upsert is `onConflict:"id"` ([index.html:250](../../index.html#L250)) — update, not delete+insert. **A normal close cannot create an orphan or change the id.**
   - *Edge note:* `updateTrade` is a `map`, **not an upsert**. If a close payload's `id` matched no existing trade, it would be a silent no-op (neither replaced nor appended). For a normal close this can't happen (the payload carries the real `closingTrade.id`), but it is a theoretical drop path (H5/H12-adjacent) worth keeping in mind for merged/sub-trade constructs.
2. **Partial close can keep `status:"open"`.** [index.html:1980-1984](../../index.html#L1980-L1984): `remaining=max(0,contracts-closedC)`, `allDone=remaining===0`, `status:allDone?"closed":"open"`. A multi-contract position closed partially stays **open** with `remainingContracts` set → appears in **Positions**, not the closed Journal. Strong match for "disappeared from Journal."
3. **No `status`/`raw.status` divergence.** `saveTrades` writes `status:t.status` and `raw:t` from the same in-memory object ([index.html:235-242](../../index.html#L235-L242)); both reflect the close.
4. **No `productId` divergence; `_next` is display-only.** `productId` is preserved through close; `resolveProduct` strips `_next` for lookup only ([index.html:83-87](../../index.html#L83-L87)).
5. **Images carried through.** `preImages` preserved via spread; `postImages` collected in the form and included in `raw` ([index.html:1922](../../index.html#L1922), [:242](../../index.html#L242)). Full-close in the merged form only writes `postImages` when `allDone` ([index.html:1989](../../index.html#L1989)).
6. **Secondary defect — `exit_date` column never populated.** The close form sets `exitDateTime` but never `exitDate`, so the **columnar** `exit_date` is always NULL ([index.html:241](../../index.html#L241) vs form [:1903](../../index.html#L1903)). **Harmless to the Journal** (it reads `raw.exitDateTime`, not the `exit_date` column), but it is a real schema inconsistency and would bite any future code that trusts `exit_date`. Severity: medium, **not** the cause of this bug.

---

## 9. Trades sync path findings

1. **Reconcile-delete is bounded and cannot delete a closed trade.** `removedIds = knownIds − localIds` ([index.html:259-260](../../index.html#L259-L260)); a closed trade's id is in `localIds`, so it is never deleted. Trades on server but unknown to this tab are preserved ([index.html:257-258](../../index.html#L257-L258)).
2. **`knownIds` is server-derived.** Seeded from the server set at load ([index.html:7886](../../index.html#L7886)); updated from confirmed saves ([index.html:7913](../../index.html#L7913), `res.ids = localIds` [:271](../../index.html#L271)). Saves gated by `dbReady` ([index.html:7902](../../index.html#L7902)). ⇒ The **stale-127 reconcile-delete catastrophe is structurally prevented.**
3. **Silent save failure (HIGH).** On upsert `affected===0` (RLS/constraint), `saveTrades` returns `ok:false` ([index.html:252-255](../../index.html#L252-L255)); the caller logs a warning, **keeps the trade locally, does not retry with backoff, and shows no toast** ([index.html:7912-7918](../../index.html#L7912-L7918)). The trade is then *stranded locally* and lost on the next reload's wholesale overwrite. **This is the primary persistence-adjacent risk.**
4. **No optimistic-concurrency / 406 handling (MEDIUM).** Unlike `savePortfolio` ([index.html:274-299](../../index.html#L274-L299)), `saveTrades` has no `expectedUpdatedAt`/conflict path. The `trades` table has **no `created_at`/`updated_at`** columns at all (confirmed: `loadAll` selects only `raw`).
5. **Empty-array mass-delete (HIGH, latent).** If `trades` ever became `[]` with a non-empty `knownIds`, reconcile-delete would delete every server row in `knownIds` ([index.html:249-264](../../index.html#L249-L264)). Guarded only by the null check ([index.html:234](../../index.html#L234)) and upstream React discipline (the "audit P0-1" comment, [index.html:230-233](../../index.html#L230-L233)). Not implicated in *this* close bug, but flagged.
6. **Base64 image bloat (MEDIUM) — plausible save-failure trigger.** Images are stored **inline as base64 data URIs** in `preImages`/`postImages` inside `raw` ([index.html:810-812](../../index.html#L810-L812), [:242](../../index.html#L242)). Several/large images make a big `raw` payload; a PostgREST/Supabase size or constraint rejection would manifest exactly as the silent failure in finding #3. This connects the user's image complaints to the disappearance and is worth checking if §11 shows `LOCAL_HAS_DATA_SERVER_MISSING` on an image-bearing trade.

---

## 10. Journal render / filter findings

1. **Single visibility gate:** `closed = trades.filter(t=>t.status==="closed")` ([index.html:3543](../../index.html#L3543)). No `_hiddenByMerge`, archived, deleted, or merged exclusion. Drafts are excluded only because their status is `"draft"`.
2. **Optional filters default empty:** `product / direction / setup / rating / dateFrom / dateTo` ([index.html:3537](../../index.html#L3537), applied [:3545-3552](../../index.html#L3545-L3552)). With a **leftover `dateTo` in the past or a `product` filter set**, a trade closed today is silently dropped from the list (but only this session — resets on reload). **Leading DATA_PRESENT_BUT_HIDDEN predicate.**
3. **Sort:** default `exitDateTime` desc ([index.html:3539-3540](../../index.html#L3539-L3540)). A missing/empty `exitDateTime` → `getTime()` 0/NaN → sorts to the **bottom**, not removed ([index.html:3564-3573](../../index.html#L3564-L3573)). With no pagination, it is still on the page (scroll to bottom).
4. **No pagination, no search, no month picker** in the Journal tab. (Calendar tab is separate.) A today-close can't fall outside a page window.
5. **Product-resolution failures degrade gracefully** — `calcPL/calcNetPL` return 0 on null product, render shows `—`; the row is **not** hidden and does **not** throw ([index.html:3557](../../index.html#L3557), [:594](../../index.html#L594), [:671](../../index.html#L671)).
6. **Images are not rendered in list rows** (only in `TradeDetailModal`, [index.html:2132-2156](../../index.html#L2132-L2156)) — a malformed image can't break a list row.
7. **`_hiddenByMerge` is written but never read** ([index.html:3613](../../index.html#L3613) write; [:3699-3703](../../index.html#L3699-L3703) comment). Consistent with the prior "Merge disabled" decision. It does **not** hide rows.

### 10a. REFUTED hypothesis — "raw goes stale on reload"

One fan-out tracer claimed a "CONFIRMED divergence": that closes write to columns but a stale nested `raw` field reverts the trade on reload. **This is incorrect and is refuted:**

- `loadAll` returns `t.data.map(r=>r.raw)` ([index.html:213](../../index.html#L213)) — the in-memory trade **is** the `raw` column's content. There is **no nested `t.raw`** sub-field on the in-memory object.
- `saveTrades` writes `raw:t` ([index.html:242](../../index.html#L242)) — the **entire current** object (including `status:"closed"` and `exitPrice`) becomes the new `raw`.
- Therefore reload renders the close correctly. (The §11A snippet still prints `rawStatus`/`rawProductId` per the audit spec; they will be `undefined`, which *confirms* there is no nested raw.)

This correction is why the **persistence-is-safe default stands** and this is not (yet) a freeze exception.

---

## 11. Read-only evidence checks for Junior to run manually

> **Run these yourself; do not let the audit run them.** All three are read-only. Snippets A/D paste into the browser DevTools console on the live Journal site; B/C paste into the Supabase SQL Editor. None write, delete, sync, or mutate anything.

### 11A. Browser console — read-only localStorage snapshot

```js
// THUS Journal — READ-ONLY localStorage triage. DevTools console on the Journal site.
// Reads only. No setItem / removeItem / clear. No network. No Supabase. No state mutation.
(() => {
  const raw = localStorage.getItem("tj_trades");
  if (raw == null) { console.log("tj_trades: NOT PRESENT"); return; }
  let trades; try { trades = JSON.parse(raw); } catch (e) { console.log("parse error", e); return; }
  if (!Array.isArray(trades)) { console.log("tj_trades not an array:", typeof trades); return; }
  const today = new Date().toLocaleDateString("en-CA"); // local YYYY-MM-DD (matches localNow)
  const tsOf = t => t.exitDateTime || t.exitDate || t.openDateTime || t.entryDate || "";
  const recent = [...trades].sort((a,b)=>String(tsOf(b)).localeCompare(String(tsOf(a))));
  const slim = t => ({
    id: t.id, status: t.status, rawStatus: (t.raw && t.raw.status),        // rawStatus expected undefined (no nested raw)
    productId: t.productId, rawProductId: (t.raw && t.raw.productId),
    contracts: t.contracts, remaining: t.remainingContracts,
    entry: t.entryPrice, exit: t.exitPrice,
    open: t.openDateTime, exitDT: t.exitDateTime, entryDate: t.entryDate, exitDate: t.exitDate,
    preImgs: (t.preImages||[]).length, postImgs: (t.postImages||[]).length,
    hiddenByMerge: t._hiddenByMerge || false, isMerged: t.isMerged || false,
    groupId: (t.group_id != null ? t.group_id : (t.groupId != null ? t.groupId : null))
  });
  console.log("LOCAL tj_trades total:", trades.length);
  console.log("  open  :", trades.filter(t=>t.status==="open").length);
  console.log("  closed:", trades.filter(t=>t.status==="closed").length);
  console.log("  draft :", trades.filter(t=>t.status==="draft").length);
  console.log("  other :", trades.filter(t=>!["open","closed","draft"].includes(t.status)).length);
  console.log("LAST 15 by best timestamp:");      console.table(recent.slice(0,15).map(slim));
  console.log("TODAY ("+today+"):");              console.table(trades.filter(t=>String(tsOf(t)).slice(0,10)===today).map(slim));
  console.log("CLOSED, most recent 10:");         console.table(
    trades.filter(t=>t.status==="closed")
          .sort((a,b)=>String(b.exitDateTime||"").localeCompare(String(a.exitDateTime||"")))
          .slice(0,10).map(slim));
  console.log("ALL LOCAL IDS (copy for §11C diff):", JSON.stringify(trades.map(t=>t.id)));
})();
```

### 11B. Supabase SQL Editor — SELECT-only schema discovery (run first)

```sql
-- READ-ONLY. Confirms columns + types of public.trades (incl. whether raw is json/jsonb, and group_id presence).
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'trades'
order by ordinal_position;
```

### 11C. Supabase SQL Editor — SELECT-only server snapshot + ID diff

Replace `<USER_ID>` with your auth uid (visible in Supabase Auth, or in the app's session).

```sql
-- READ-ONLY counts.
select count(*) as total from public.trades where user_id = '<USER_ID>';
select status, count(*) from public.trades where user_id = '<USER_ID>' group by status;
```

```sql
-- READ-ONLY recent 20, ordered by raw timestamps (trades table has no created_at/updated_at).
select
  id,
  status,
  raw->>'status'        as raw_status,
  product_id,
  raw->>'productId'     as raw_product_id,
  group_id,
  exit_price,
  raw->>'exitDateTime'  as raw_exit_dt,
  raw->>'openDateTime'  as raw_open_dt,
  remaining_contracts,
  jsonb_array_length(coalesce((raw::jsonb)->'postImages','[]'::jsonb)) as post_imgs
from public.trades
where user_id = '<USER_ID>'
order by coalesce(raw->>'exitDateTime', raw->>'openDateTime', raw->>'entryDate') desc
limit 20;
```

```sql
-- READ-ONLY id list for the local↔server diff.
select id from public.trades where user_id = '<USER_ID>' order by id;
```

Then diff in the console (pure computation, no I/O):

```js
// Paste the two id arrays, then run. Read-only; no storage, no network.
const LOCAL  = [ /* paste "ALL LOCAL IDS" from §11A */ ];
const SERVER = [ /* paste the id column from the §11C id query */ ];
const ls = new Set(LOCAL), ss = new Set(SERVER);
console.log("local:", ls.size, "server:", ss.size);
console.log("in SERVER not LOCAL:", SERVER.filter(id => !ls.has(id)));
console.log("in LOCAL not SERVER:", LOCAL.filter(id => !ss.has(id)));  // today's missing closed id here ⇒ save failure
```

**Also do this zero-tooling check first:** on the Journal tab, click **Reset** on the filter bar (clears `dateFrom/dateTo/product/...`), then check the **Positions** tab for the "missing" trade (it may be a partial close still `open`). These two clicks resolve the two benign hypotheses immediately.

---

## 12. Banned-word / read-only review of the snippets

| Snippet | `setItem` / `removeItem` / `clear` | `fetch` / `XMLHttpRequest` / network | Supabase write / `SUPA` / `_supabaseClient` | React state mutation | SQL write (`insert/update/delete/alter/drop/truncate/upsert/create`) | Verdict |
|---|---|---|---|---|---|---|
| 11A localStorage | none (only `getItem`) | none | none | none | n/a | ✅ read-only |
| 11B schema discovery | n/a | n/a | n/a | n/a | none (`select` on `information_schema`) | ✅ read-only |
| 11C server snapshot + ids | n/a | n/a | n/a | n/a | none (`select` only) | ✅ read-only |
| 11C console diff | none | none | none | none | n/a | ✅ read-only (pure compute) |

Notes: 11A uses only `localStorage.getItem`, `JSON.parse`, `console.*`, and array methods. 11B/11C are `select`-only; running them in the SQL Editor (service role) **bypasses RLS**, which is *desirable here* — it reveals the true server state independent of any RLS denial that might be causing a silent save failure. No snippet references `tj_trades` writes, `window._supabaseClient`, or any sync function.

---

## 13. Hypothesis table

| # | Root cause | Evidence needed | Risk | Likely fix area | P/L / dashboard / calendar / export impact | G1 / 127 / independent |
|---|---|---|---|---|---|---|
| 0 | Capture Bot write conflict with Journal save | timing logs; Bot writes `checkin_events` not `trades` | Very low | none | none | Independent |
| 1 | **G1 migration causation** (new column/table breaks render/save) | §5 — none found | Very low | n/a | none | G1 — **ruled out** |
| 2 | G1 exposed pre-existing sync drift | §6 ID diff | Low | n/a | none | G1/127 — unlikely (knownIds server-seeded) |
| 3 | 127-vs-133 stale localStorage drift | §11C ID diff | Low | n/a | possibly counts | 127 — likely stale-file artifact |
| 4 | **Leftover Journal `dateTo`/`product` filter hides today's close** | Reset filters; §11A shows trade closed | **Low (benign)** | filter-state UX (out of freeze) | none (filters are view-only) | Independent |
| 5 | Close writes `raw.status` but not column (or vice-versa) | §10a — refuted; both from same object | Very low | none | none | Independent |
| 6 | Close writes malformed date → row sorts/filters out | §11A `exitDateTime` value; sorts to bottom not out | Low | close form validation | none | Independent |
| 7 | Product resolution failure hides the row | §10 #5 — renders `—`, never hidden | Very low | none | none | Independent |
| 8 | Stale localStorage after close | §11A vs live UI; `tj_trades` mirrors on change ([:7768](../../index.html#L7768)) | Low | none | none | Independent |
| 9 | **Silent cloud-save failure (RLS `affected===0` / network / image bloat) → reverted on reload** | §11C: local has closed, server missing/open | **Medium–High** | save error surfacing + retry (persistence — needs freeze exception) | the trade's P/L missing everywhere after reload | Independent (image-linked) |
| 10 | Old destructive merge / hidden flag hides row | `_hiddenByMerge` written-not-read ([:3699-3703](../../index.html#L3699-L3703)) | Very low | none | none | Independent |
| 11 | Attachment/image data shape breaks render | §10 #6 — images not in list rows | Very low | modal image handling (P3) | none | Independent |
| 12 | **Partial close left `status:"open"`** (shows in Positions, not Journal) | §11A: trade `open` + `remainingContracts`; check Positions | **Low–Medium** | partial-close UX clarity (out of freeze) | counted as open, not realized | Independent |
| 13 | Actual persistence failure / data loss (both sides gone) | §11A + §11C both missing | Medium (if confirmed) | persistence (freeze exception) | total loss of the trade | Independent |
| 14 | Closed trade hidden by in-session date/search/pagination | Reset filters; no pagination exists | Low (benign) | filter UX | none | Independent |

---

## 14. Recommended next step

1. **Junior runs §11** in this order: (a) on the Journal tab, click **Reset** filters and check **Positions** (resolves H4/H12 in seconds); (b) run **§11A** localStorage snapshot; (c) run **§11B** then **§11C** in Supabase; (d) run the **§11C ID diff**.
2. **Report back** the three numbers (local total / server total / Journal-visible) and, for the specific missing trade: its `status` and presence in local vs server.
3. **Classify** per the §4 table. Then:
   - `DATA_PRESENT_BUT_HIDDEN` (H4/H12/H14) → **UI/filter or partial-close UX fix, outside the persistence freeze.** Safe to schedule normally.
   - `LOCAL_HAS_DATA_SERVER_MISSING` or `DATA_ACTUALLY_MISSING` (H9/H13) → **legitimate freeze-exception candidate.** Before any code change: capture the failing trade's `raw` size / image count to test the base64-bloat trigger (§9 #6), and check the browser console for the `[trades][write] upserted-affected=0 … POSSIBLE RLS / CONSTRAINT DENIAL` warning ([index.html:254](../../index.html#L254)) from when the close was attempted.
4. **Do not** modify persistence, filters, or the close flow until the classification is in. This audit produced no code changes by design.

Independently of the P0 (note, do **not** fix now): the **`exit_date` column is never populated on close** (§8 #6) and `saveTrades` lacks the toast/retry/optimistic-concurrency that `savePortfolio` has (§9 #3-4). Track as follow-ups.

---

## 15. Explicit non-actions

- ❌ No code changed. `index.html` was **read only**.
- ❌ No SQL run (the §11 queries are for Junior to run manually).
- ❌ No Supabase modification.
- ❌ No localStorage modification.
- ❌ No deploy / push / restart / commit.
- ❌ No GUGU / Capture Bot interaction.
- ❌ No GroupCard / `[+ Group]` work started.
- ❌ No baseline JSON touched (`g2_baseline_20260608.json` remains untracked and unchanged).
- ❌ No migrations run.
- ✅ **Persistence architecture remains FROZEN** pending root-cause evidence from §11. The code-level default — "persistence is safe" — is **upheld** for normal closes; the only unproven exception is a silent save failure (§9 #3, §13 H9), which §11C will confirm or clear.

---

## 16. Triage result (2026-06-09, evidence-confirmed)

Junior ran §11. Outcome: **`SERVER_HAS_DATA_LOCAL_MISSING` (stale client). No data loss. Persistence sound. Freeze upheld — no exception.**

**Evidence:**
- **Server `public.trades` = 134** (status: closed 132, open 2). Schema confirmed: `raw` is `jsonb`, and the table **does** have `created_at`/`updated_at` (the §6/§9 "no timestamp columns" note was wrong — those columns exist; the app simply doesn't `select` them in `loadAll`).
- **Today's two closes are on the server, `status:"closed"`, `raw_status:"closed"`, with `post_imgs`:** `1780384871871` (s50_next, exit 1015.54, `2026-06-09T14:08`) and `1780888169970` (s50_next, exit 1013.3, `2026-06-09T14:09`).
- **Browser localStorage `tj_trades` = 127**, newest closed = `2026-05-15`. This is the same stale snapshot behind the earlier 127-vs-133/134 gap (§6 correlation **confirmed**).
- **ID diff:** `in SERVER not LOCAL` = 7 (`1779435642966`, `1779937358663`, `1780384871871`, `1780545697796`, `1780888169970`, `1780888169973`, `1781008993915`); **`in LOCAL not SERVER` = 0** ⇒ the client holds no unsaved data; a reload cannot lose anything.

**Root cause:** the Journal tab last hydrated when the server had 127 trades and never re-fetched. Trades load from the server **only once**, in the mount-time `loadAll` effect ([index.html:7811](../../index.html#L7811)); React `trades` init is `[]` ([index.html:7562](../../index.html#L7562)) and there is **no realtime / refresh-on-focus / multi-tab sync** for trades. Today's trades were created+saved in a fresher session (the G1 run report `b2d4f9c` even captured the successful writes: `[trades][write] upserted-affected=133/133 … 1780888169970, 1780888169973`, no RLS denial), so this older tab shows stale data.

**G1 cleared at the RLS layer too:** the G1 migration's `DROP/CREATE POLICY` + `GRANT`/`REVOKE` were **only on `trade_groups`**; `public.trades` got only `ADD COLUMN group_id` + FK + indexes — its RLS policies were untouched, and the captured writes confirm the authenticated client can still write/read trades. **`G1_LIKELY_UNRELATED` upgraded to confirmed.**

**Hypothesis outcomes:** H9/H13 (silent save-failure / data loss) **refuted by evidence** — server has every trade and today's writes succeeded. H3/H8 (stale localStorage) **confirmed**. H4/H12/H14 not the cause.

**Fix (outside the persistence freeze):** reload thus999.com (`Ctrl+Shift+R`) restores the full set immediately — safe because `local-not-server = 0`. **Recommended follow-up (not a freeze change):** add a lightweight refresh for trades — re-run `loadAll` on tab `visibilitychange`/focus, or a Supabase realtime subscription — so a long-open tab can't silently show stale data. Track as a normal enhancement, not a P0.

---

---

## 17. Reopened After Hard Refresh — P0 Reclassification (2026-06-09)

**The §16 "stale client" finding explained one case but is INCOMPLETE.** New evidence: Junior closed a position, the UI confirmed the close, and **after a hard refresh the position returned to Open Positions** and is **absent from the closed Journal**. A hard refresh re-hydrates wholesale from the server ([index.html:7814-7829](../../index.html#L7814-L7829)), so a post-refresh "Open" means the **server's `raw` currently says open** — i.e., this close did not end up persisted as closed (unlike the June‑09 closes in §16, which did).

### 17.1 Code-path findings (read-only)

- **Single trades write path.** The only writes to `public.trades` are `saveTrades`'s `upsert` ([index.html:250](../../index.html#L250)) and its bounded reconcile-delete ([:262](../../index.html#L262)); plus two bulk "wipe-all" `delete().eq("user_id",uid)` in Settings/reset ([index.html:6138](../../index.html#L6138), [:6170](../../index.html#L6170)). `tradeEvents.insert` ([:8186](../../index.html#L8186), [:8258](../../index.html#L8258)) writes a **separate events table**, not `trades`. ⇒ **No path sets columnar `status` independent of `raw`** — a columnar/raw *divergence* is not producible by app writes; if it ever existed it would be a manual-SQL/migration artifact. The bulk-deletes would remove the row entirely, not reopen it, so they are not implicated.
- **Optimistic, unconfirmed close handoff (the durability gap).** [index.html:3491](../../index.html#L3491): `onClose={d=>{onUpdateTrade({...closingTrade,...d,status:"closed"}); setClosingTrade(null); showToast("ปิด order เรียบร้อย","success");}}`. `onUpdateTrade` (`updateTrade`, [:8256](../../index.html#L8256)) only calls `setTrades` — it does **not** await or even trigger a save directly. The success toast and modal-close are **synchronous and unconditional**. The actual write is a **separate 1.5 s-debounced `useEffect`** ([index.html:7900-7922](../../index.html#L7900-L7922)) → `saveTrades`. That save is **not awaited, surfaces no toast on failure, and has no retry/backoff** ([:7912-7918](../../index.html#L7912-L7918)).
- **Reload reverts an unsaved close.** `loadAll` reads `raw` only and `setTrades(data.trades)` overwrites wholesale ([:213](../../index.html#L213), [:7827-7829](../../index.html#L7827-L7829)). If the debounced save did not complete (refresh/tab-close within the ~1.5 s window + network round-trip, or a silent `affected===0`/RLS/network failure, or `savingRef` still busy from a prior in-flight save [:7905-7910](../../index.html#L7905-L7910)), the server `raw` is still open and the position reappears in Open on refresh.
- **Multi-writer hazard (the §16 stale tab as a "zombie writer").** `saveTrades` upserts the tab's **entire** trades array by id ([:235-250](../../index.html#L235-L250)). If the §16 stale tab (or a phone/second device) is still open and its trades state changes, it re-upserts its **stale copy** of this position as `open`, overwriting a close made elsewhere — last-write-wins, no `updated_at`/OC guard on trades (unlike `savePortfolio`). This can resurrect a genuinely-saved close back to open.
- **G1 still cleared.** `saveTrades` omits `group_id` (null-fills); no new evidence implicates the migration. G1's RLS changes were `trade_groups`-only (§16). `G1_LIKELY_UNRELATED` stands.

### 17.2 Leading hypotheses for the reopened trade

1. **Close-save durability race (most likely).** Optimistic toast + debounced/unawaited/no-retry save → close lost when the tab is refreshed (or save fails silently) before the write completes. Server `raw->>'status'`=`open`, `updated_at` ≈ the *open* time (no close write landed).
2. **Overwrite by a second/stale tab or device.** A close that did save was reverted by another open tab's full-array upsert. Server `raw->>'status'`=`open`, but `updated_at` would be **after** the close time (a later write landed).
3. **Silent save failure (RLS `affected===0` / network / payload).** Same end state as #1; distinguishable only via the browser console warning `[trades][write] upserted-affected=0 … POSSIBLE RLS / CONSTRAINT DENIAL` ([:254](../../index.html#L254)) captured at close time.

`raw->>'status'` decides open-vs-render-bug; `updated_at` vs the close time discriminates #1 from #2.

### 17.3 Status — CONFIRMED

**`P0_CLOSE_PERSISTENCE_BUG_CONFIRMED`** (2026-06-09, Junior-confirmed affected row).

**Affected row (server, read-only SELECT):**

| field | value |
|---|---|
| id | `1781008993915` |
| status (columnar) | `open` |
| raw->>'status' | `open` |
| product_id / raw productId | `s50_next` / `s50_next` |
| group_id | `null` |
| entry_price | `1013.3` |
| exit_price / raw_exit_dt | `null` / `null` |
| raw_open_dt | `2026-06-08T09:53` (user-entered; backdated) |
| contracts / remaining | `5` / `5` |
| created_at | `2026-06-09 12:45:44.073863+00` |
| updated_at | `2026-06-09 12:45:44.073863+00` (**=== created_at**) |
| post_imgs | `0` |

**Server verdict:** the row is **open / raw-open**, has **no exit price, no exit timestamp, no post-images**, and **`updated_at === created_at`** — the row was written exactly once (the open) and **never updated**. ⇒ **No close write ever reached the server.** The close did not persist.

**Journal absence explained:** there is no server-closed row for the Journal to display. **This is NOT a Journal closed-trades render bug** for this row. (Consistent with §17.1: the only trades writer sets `raw` and columnar `status` together, so a server-closed-but-hidden row is not producible by the app.)

**Stale-tab overwrite ruled out for this row:** `1781008993915` was created today (`created_at 2026-06-09 12:45 UTC`) and is one of §16's *server-not-local* ids — the §16 stale 127-row tab never knew this id, so it could not have re-upserted it back to open. The **open save landed but the close save did not, in the same active tab.** This isolates the cause to the close→save handoff, not multi-tab last-write-wins (hazard #4 in §17.1 remains real in general but is not the cause here).

**Likely root cause:** optimistic close UI ([index.html:3491](../../index.html#L3491)) shows the success toast synchronously, while the real write is a **debounced (1.5 s), unawaited, no-retry, failure-silent** effect ([index.html:7900-7922](../../index.html#L7900-L7922)). The close was lost before a successful upsert landed — either the debounce never fired before the hard refresh, or the upsert failed silently (`affected===0`/network) with no surfaced error. `updated_at===created_at` is consistent with both (no successful write after open). On refresh, `loadAll` re-hydrated the still-open `raw` ([:213](../../index.html#L213), [:7827-7829](../../index.html#L7827-L7829)) → the position returned to Open.

**G1:** **remains cleared** — `group_id` is `null`, trades RLS unchanged, only writer omits `group_id` harmlessly. No reconsideration warranted.

**Persistence freeze:** **remains frozen.** This confirmed bug **authorizes a narrow design proposal** scoped to *close-save durability only* — **not** a storage-architecture refactor. No code is changed by this audit.

### 17.4 Next recommended action — design only (no code)

Create a **design-only, narrowly-scoped** proposal (`/design`) for **close-save durability**, explicitly excluding any broad persistence refactor. Directions to evaluate (each weighed for risk against the frozen architecture):

1. **Await a durable save before the success toast** — make the close path confirm the upsert landed (and `affected>0`) before showing "ปิด order เรียบร้อย".
2. **Lock the modal while the save is pending** — disable backdrop-close / duplicate submit until the write resolves.
3. **Verify after save** — check affected-rows (already returned by `.select()` at [:250](../../index.html#L250)) and/or re-read the affected trade or server count to confirm persistence.
4. **On failure, keep the modal open + show a clear error** (replace the silent `console.warn` at [:7914](../../index.html#L7914)) with optional retry.
5. **Guard against stale-tab full-array overwrite** *only if* later evidence implicates it (not this row) — e.g., per-row `updated_at`/OC for trades, mirroring `savePortfolio`.
6. **Add close-save lifecycle dev logging** (submit → debounce → upsert → affected-rows → done/fail).
7. **Keep everything else frozen** — touch only this close→save path if the design gate approves.

---

*Report generated read-only. Six parallel tracer agents (Explore type, no write access) + direct source verification by the lead. The one "confirmed divergence" claim from the fan-out was independently refuted (§10a); §16 triage confirmed by Junior's live read-only evidence; §17 reopened the case after a new hard-refresh observation and reclassified toward a close-save durability failure pending the affected row.*
