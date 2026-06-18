# THUS Journal — Close-Save Durability Design: Timeout Addendum

**Status:** DESIGN ONLY — no code, no file writes. Phase 1 of 5. Supersedes the writer strategy of the original Option A design (`close_save_durability_design.md`). **Amended 2026-06-15** to resolve design-review MAJOR-1/2/3 + MINOR (review verdict `P0_TIMEOUT_DESIGN_HAS_BLOCKERS`). Awaiting `[DESIGN GATE]` approval before any Phase 2 code.
**Date:** 2026-06-15 (amended)
**Scope:** THUS Journal `C:/Users/Junior/Desktop/thus-journal/index.html` (single-file SPA). Persistence architecture is FROZEN except a narrow `/design`-approved exception for close-save durability (per close-position audit, 2026-06-09).
**Revised direction:** **C + A + D** (single-row durable close writer + bounded `db.saveTrades` RETURNING reduction + post-hydration autosave suppression).

---

## 0. TL;DR

The original Option A made the close durable by routing `commitClose` through the **canonical full-array writer** `db.saveTrades`. New production evidence proves that writer **times out (PostgREST 500, code `57014`, "canceling statement due to statement timeout")** on this user's real data: 134 rows / 11 MB total raw, driven by 13 trades carrying uncompressed base64 image data URLs (heaviest row 1488 kB). A close routed through an array writer that can itself time out is **not durable** — which is the most plausible mechanism for the original close-loss on trade `1781008993915` (an OPEN s50_next, 526 kB raw, the affected P0 row).

This addendum revises the writer to a **single-row upsert** (`db.saveTrade`) that touches ONLY the affected row, plus two supporting changes: stop `db.saveTrades` from RETURNING ~11 MB (`.select()` → `.select("id")`), and suppress the spurious post-hydration full-array write-back. Image compression — the true root cause of the 11 MB raw — is explicitly **backlog, not P0**.

**Adversarial blockers now resolved in this spec and MUST NOT be lost in Phase 2:** (B1) PostgREST returns the `bigint` `id` as a **JSON string** while `trade.id` from the `raw` JSONB is a **JS number** — the id-match tripwire MUST compare `String(...)` on both sides or every successful close falsely reports failure; (B2) the close path passes a **single trade object** to `saveTradesSerialized`, so the dispatch to `db.saveTrade` MUST be the FIRST statement (before the array-shaped `affected_trade_missing` guard and before `db.saveTrades`, whose `trades.map(...)` would `TypeError` on an object); (B3, MAJOR-1) the close is **save-first** — `db.saveTrade` is awaited and `updateTrade` (local state mutation, CB-disarm, success toast, modal close) runs **only on `res.ok`**, so no React state ever shows the trade closed and no circuit-breaker disarm ever fires before the server write succeeds. B1, B2, B3, plus the `!isClose` guard on `lastSeenRef.current.tradeIds`, are pinned in the §16 Phase-2 wiring checklist as named, load-bearing items.

---

## 1. Why original Option A is no longer sufficient

Option A's load-bearing assumption was: *"Reuse the single canonical writer `db.saveTrades` so there is no second writer and no raw/columnar divergence; just serialize and await it."* This is encoded directly in the current code:

- `commitClose` (8350-8366) → `saveTradesSerialized(snapshot, {source:"close", ...})` (8357)
- `saveTradesSerialized` (7846-7881) → `db.saveTrades(authUid, nextTrades, lastSeenRef.current.tradeIds)` (7861)
- `db.saveTrades` (245-297) does a **FULL-ARRAY** `upsert(rows,{onConflict:"id"}).select()` (274) over **all 134 rows**, then `.select()` makes PostgREST RETURN every affected row (≈11 MB).

The assumption was correct about *correctness* (no divergence) but wrong about *durability under production data volume*. Reusing the canonical writer means **the close inherits the canonical writer's timeout failure mode**. Awaiting and serializing a call that returns a 500 does not make it durable — it just surfaces the failure as a kept-open modal. The close cannot succeed while the array write it rides on cannot succeed. Option A is therefore **structurally unable to deliver a durable close** on this dataset.

## 2. Why the full-array writer timeout makes a durable close unreliable

Production evidence (localhost smoke against production user `b77d0426-355d-4f31-b94a-1afbe8fd49fa`):

- A `source:"autosave"` write fired after hydration and returned **PostgREST 500, code `57014`**, "canceling statement due to statement timeout". This was NOT a close — Junior did not close — which is decisive: it isolates the failure to **the canonical full-array `db.saveTrades` writer itself**, independent of the close path.
- Raw-size profile: `rows=134`, `total_raw≈11 MB`, `max_row_raw=1488 kB`, `avg_row_raw=84 kB`, `rows_with_images=13/134`. Images are uncompressed base64 data URLs (`readAsDataURL`, no resize) stored in `raw.preImages`/`raw.postImages`.

Mechanism: every close routed through `db.saveTrades` sends **all 134 rows** in one upsert and asks Postgres to RETURN them (`.select()`, 274). The request body **plus** the RETURNING payload **plus** the per-statement timeout budget make the statement abort (`57014`) under variable server load. Note (per critic): `.select()`→`.select("id")` shrinks only the RETURNING side; the **request body is still ~11 MB**, and the timeout is a server-side statement timeout on the upsert itself — so A helps but does NOT eliminate the autosave `57014`. Because the close write *is* that array write, a close is **only as reliable as a multi-megabyte round trip** — intermittently unreliable, worsening as the journal and image count grow. A "durable close" mechanism that fails whenever the array write fails is not durable.

## 3. Why `57014` likely explains the original close-loss on `1781008993915`

The confirmed P0 (close-position audit, 2026-06-09) was: trade `1781008993915` shows server `open`/raw-open with `updated_at === created_at` — the close never landed server-side despite an optimistic success toast. The audit attributed cause to "optimistic toast + debounced/unawaited/no-retry save" (anchors 3491 + 7900-7922 in the pre-Option-A code).

The new `57014` evidence supplies the concrete server-side failure mechanism that the audit could only describe behaviorally:

- The affected row is itself 526 kB raw (`1/0` images), and it lives in a 134-row / 11 MB array. Any pre-Option-A save attempt for that close went through the same full-array writer that we have now **directly observed timing out** on this exact dataset.
- A `57014` timeout returns an error, not a row mutation. With the old debounced/unawaited/no-retry save, the timeout was swallowed and the optimistic toast fired anyway → server stays `open`, `updated_at === created_at`, close lost. This matches the audit's signature exactly.
- This is more specific than "race / stale client": the writer can fail **even with correct client state and a single attempt**, purely because the array round-trip exceeds the statement-timeout budget. `57014` is therefore the most plausible root mechanism for the close-loss, and the reason the fix must change the **writer**, not just the call ordering.

## 4. Why a single-row close writer is the narrowest durable fix

The close mutates exactly one row. The narrowest writer that durably persists a close therefore upserts exactly one row:

- **Payload shrinks from ~11 MB (134 rows) to one row** (≤ ~1.5 MB worst case, ~526 kB for the actual P0 trade) → far inside the statement-timeout budget → `57014` does not trigger for the close path.
- **No reconcile-delete** in the close path → no destructive window, no dependency on `knownIds` correctness for the close.
- **RLS affected-row verification preserved** at row granularity (`.select("id")`, verify exactly one id and it equals `trade.id` — string-coerced, §5) → no silent RLS/constraint denial, no false success.
- **No schema, no RPC, no backend, no hydration redesign** → stays inside the frozen-architecture exception.
- **Mock/demo guard preserved** by running `detectUnsafeMockTrades([trade])` (array-wrapped, 189) in the single-row writer.

This is narrower than reusing the array writer (C touches 1 row vs 134), narrower than chunking (E still writes the whole journal), and does not require the moratorium-violating surface of an RPC (F). It fixes the close path while leaving the residual full-array autosave problem honestly documented for backlog (image compression, §13).

## 5. Exact writer strategy

Two writers share **one** row mapper so raw/columnar shape can never diverge. The mapper is spelled out field-for-field here (per critic, to prevent factoring drift — especially the falsy-zero fallbacks `remaining_contracts: t.remainingContracts || t.contracts` and `note: t.note || null`, which MUST be copied verbatim from lines 259-267).

1. **`toTradeRow(uid, t)`** — factored out of the current inline row map in `db.saveTrades` (259-267). Single source of truth for the row shape `{id,user_id,product_id,direction,status,contracts,remaining_contracts,entry_price,exit_price,entry_date,exit_date,note,raw}`.
2. **`db.saveTrade(uid, trade)`** — durable single-row close writer:
   - Run `detectUnsafeMockTrades([trade])` (array-wrapped, or it returns `{unsafe:false}` for a bare object at line 189); if unsafe → `{ok:false, guard:"mock_demo_trades", ...}` (no Supabase call).
   - `const row = toTradeRow(uid, trade)`
   - `await SUPA.from("trades").upsert([row], {onConflict:"id"}).select("id")` — **array-wrapped `[row]`** so `data` is reliably an array of one across supabase-js versions.
   - On error → `{ok:false, error}`.
   - **Verify exactly one returned id and `String(ids[0]) === String(trade.id)`** (string coercion is mandatory — PostgREST serializes the `bigint` id as a JSON string; `trade.id` is a JS number) → else `{ok:false, error}` (RLS / constraint / wrong-row tripwire).
   - On success → `{ok:true, id:trade.id}`.
   - **No full array. No reconcile-delete. No `knownIds`.**
3. **`db.saveTrades` keeps** the full-array upsert for autosave (the canonical writer), but stops RETURNING the whole payload (§6).

DESIGN pseudocode (NOT committed code — illustrative shape only; final code in Phase 2):

```js
// DESIGN PSEUDOCODE — NOT FOR COMMIT.

// (2) Shared row mapper — byte-identical extraction of db.saveTrades 259-267.
//     The two `|| ` fallbacks below are load-bearing — copy verbatim, do NOT "fix" them.
const toTradeRow = (uid, t) => ({
  id: t.id, user_id: uid,
  product_id: t.productId, direction: t.direction,
  status: t.status, contracts: t.contracts,
  remaining_contracts: t.remainingContracts || t.contracts,   // falsy-zero fallback — verbatim
  entry_price: t.entryPrice, exit_price: t.exitPrice,
  entry_date: t.entryDate, exit_date: t.exitDate,
  note: t.note || null, raw: t,                               // raw:t carries camelCase keys (exitPrice, status, …)
});

// (1) Single-row durable close writer (lives in the `db` object alongside saveTrades).
async saveTrade(uid, trade) {
  try {
    if (!trade || trade.id == null) return { ok:false, error:new Error("no trade") };
    // Mock/demo guard — same gate as the canonical writer (252-258), single-row form.
    // MUST be array-wrapped: detectUnsafeMockTrades(bareObject) returns {unsafe:false} (line 189).
    const mockCheck = detectUnsafeMockTrades([trade]);
    if (mockCheck.unsafe) {
      console.warn("[trades][guard] refusing to save mock/demo trade", mockCheck);
      return { ok:false, error:new Error("Refusing to save mock/demo trade"),
               guard:"mock_demo_trades", ids:mockCheck.ids };
    }
    const row = toTradeRow(uid, trade);
    // Array-wrapped single-row upsert; RETURNING id only — verifies RLS/constraint pass
    // without an 11 MB payload. [row] guarantees `data` is an array across supabase-js versions.
    const { data, error } = await SUPA.from("trades")
      .upsert([row], { onConflict:"id" }).select("id");
    if (error) { console.warn("[trades][write1] upsert-error", error); return { ok:false, error }; }
    const ids = (data || []).map(r => r.id);
    // String() BOTH sides: PostgREST returns bigint id as "1781008993915" (string);
    // trade.id from raw JSONB is the number 1781008993915. Strict !== would ALWAYS fire.
    if (ids.length !== 1 || String(ids[0]) !== String(trade.id)) {
      console.warn("[trades][write1] affected!=1 or id mismatch",
                   { got:ids, gotType:typeof ids[0], want:trade.id });
      return { ok:false, error:new Error("single-row upsert did not affect exactly the target row") };
    }
    return { ok:true, id:trade.id };
  } catch (e) { console.warn("[db] saveTrade error", e); return { ok:false, error:e }; }
}
```

## 6. How `db.saveTrades` changes (canonical full-array autosave writer)

Three surgical edits, behavior-preserving except the RETURNING payload:

1. **Shared mapper:** replace inline `rows=trades.map(t=>({...}))` (259-267) with `const rows = trades.map(t => toTradeRow(uid, t));` → no raw/columnar divergence between autosave and close. Phase 3 must diff `toTradeRow` against 259-267 field-for-field (esp. the two falsy-zero fallbacks).
2. **`.select()` → `.select("id")`** at 274, AND update the now-misleading inline comment (269-270): from *"`.select()` forces PostgREST to return the affected rows"* to *"`.select("id")` returns one minimal `{id}` per affected row for RLS/constraint verification without the ~11 MB payload"*. This prevents a future reader re-adding `.select()` to "restore" full rows.
3. **Preserve everything else:** the `affected===0 → {ok:false}` tripwire (277-279) — still works because PostgREST still returns one `{id}` per affected row, so `upsertedRows.length` is unchanged in meaning; the empty-array fall-through for reconcile (251, 273); the bounded reconcile-delete by `knownIds` (281-288); the return `{ok:true, ids:localIds}` (295) where `localIds = new Set(rows.map(r=>r.id))` is computed from `rows` **at line 283, before the upsert** — NOT from `.select()` — so changing what `.select()` returns does NOT change the return contract or the autosave caller's `lastSeenRef.current.tradeIds = res.ids` (confirmed at 295: `res.ids` is the local set, JS numbers, never the RETURNING data).

Phase 3 must grep `upsertedRows` in `index.html` and confirm no code path reads any field beyond `.length` (none currently — the diagnostic SELECT was removed, 289-292).

DESIGN pseudocode (delta only — NOT FOR COMMIT):

```js
// DESIGN PSEUDOCODE — db.saveTrades, changed lines only.
const rows = trades.map(t => toTradeRow(uid, t));          // (1) shared mapper
// ...
const { data: upsertedRows, error: upErr } =
  await SUPA.from("trades").upsert(rows, { onConflict:"id" }).select("id");  // (2) "id" not full row
// affected-count tripwire UNCHANGED — upsertedRows is still one {id} per affected row:
const affected = upsertedRows ? upsertedRows.length : 0;
if (affected === 0) return { ok:false, error:new Error("upsert returned 0 rows ...") };
// ...
const localIds = new Set(rows.map(r => r.id));   // ids from rows (283), NOT from select — return contract intact
return { ok:true, ids:localIds };
```

## 7. How to suppress the post-hydration autosave (D)

**Problem:** hydration's `setTrades(data.trades)` (7910) changes the `trades` state, which triggers the autosave effect (7985-7991, deps `[trades, authUid]`), scheduling a redundant 1.5 s full-array write-back of **just-loaded, unchanged** data (7989). That redundant array write is exactly the one observed to `57014` in the smoke. We want hydration to NOT autosave, but the **first real user edit** must still autosave.

**Strategy — `prevDbReady` edge-detect ref (batching-robust), preferred over a "set-flag-before-setTrades" ref.**

The naive approach (set `skipNextTradesAutosaveRef = true` right before `setTrades`, consume in the effect) is mechanically correct *only* under React 18 `createRoot` automatic batching — confirmed at `index.html:8666` — because `setTrades(data.trades)` (7910) and `setDbReady(true)` (7970) fire in the **same** `.then()` callback and batch into one render, so the autosave effect runs once with `dbReady=true` and consumes the flag. **But** the autosave effect's `if(!dbReady) return` guard (7987) runs before the flag check; if batching ever broke (legacy `ReactDOM.render`, a future `flushSync` inserted between 7910–7970, or a refactor splitting the hydrate effect), `setTrades` could fire with `dbReady=false`, the effect would return early **without consuming the flag**, and the flag would then be consumed by the **first real user edit** — silently dropping that edit's autosave (a data-loss path).

To make D independent of batching (per critic MAJOR), use a **rising-edge detector** instead of a pre-set flag:

- Add `const prevDbReadyRef = useRef(false);` near the other refs (7831-7845).
- Add `dbReady` to the autosave effect's dep array → deps become `[trades, authUid, dbReady]`.
- At the top of the effect, after the `authUid`/`dbReady` guards: detect the `false → true` transition of `dbReady`. On the transition render (which is also the render where `trades` first holds the hydrated array), **skip scheduling** and record `prevDbReadyRef.current = true`. Every later render (genuine user edits) finds `prevDbReadyRef.current === true` and schedules normally.

This consumes the suppression on the **hydration-completion edge**, not on "the next `trades` change", so it cannot eat a real edit regardless of batching. It also covers the `loadAttempt` retry paths (7899-7901, 7975-7976) for free: retries keep `dbReady=false` until a successful load flips it once, and the edge fires exactly on that single flip. It uses **no localStorage as source of truth** and does **not** redesign hydration.

```js
// DESIGN PSEUDOCODE — autosave effect (7985), batching-robust D. NOT FOR COMMIT.
useEffect(() => {
  if (!authUid) return;
  if (!dbReady) { console.warn("[persist] skipped trades save — hydration not ready"); return; }
  // (D) Suppress exactly the post-hydration echo: fire once on the dbReady false->true edge.
  // Edge-detect is robust to React batching — does NOT depend on a pre-set flag being
  // consumed in the same render as setTrades. The FIRST real user edit (a later render
  // where dbReady is already true) schedules normally.
  if (!prevDbReadyRef.current) {
    prevDbReadyRef.current = true;
    return;                       // do NOT schedule a write-back of unchanged loaded data
  }
  clearTimeout(dbTimers.current.trades);
  dbTimers.current.trades = setTimeout(() => { saveTradesSerialized(trades, {source:"autosave"}); }, 1500);
  return () => clearTimeout(dbTimers.current.trades);
}, [trades, authUid, dbReady]);   // dbReady added to deps for the edge detector
```

**Why this is still correct on the happy path:** under automatic batching the effect runs once after hydration with `dbReady=true` and `prevDbReadyRef=false` → suppressed + flips to `true`. The next `trades` change (real edit) → `prevDbReadyRef=true` → schedules. ✔ Under broken batching: `dbReady=false` renders return at the guard (never reaching the edge code); the first `dbReady=true` render is the edge → suppressed; later edits schedule. ✔ No real edit is ever dropped.

**Interaction with `commitClose`'s own `clearTimeout` (8353):** `commitClose` already clears any pending debounced autosave before the close save. The edge detector and the `clearTimeout` are independent and compatible: the edge detector prevents *scheduling* the post-hydration echo; the `clearTimeout` cancels an *already-scheduled* autosave. Neither suppresses a legitimate user-edit autosave fired after the close.

## 8. How the mock/demo guard remains in BOTH writers

Both writers refuse demo/mock ids (`/^m\d+$/`) **before any Supabase call**, return the same structured shape, and **never throw**:

- **Autosave path (canonical full-array):** `db.saveTrades` keeps the existing `detectUnsafeMockTrades(trades)` guard (252-258) **unchanged** → logs `[trades][guard] refusing to save mock/demo trades` → returns `{ok:false, guard:"mock_demo_trades", ids:[...]}` → **skips Supabase entirely**.
- **Close path (single-row):** `db.saveTrade` runs `detectUnsafeMockTrades([trade])` (**array-wrapped** — a bare object returns `{unsafe:false}` at line 189) → on hit logs `[trades][guard] refusing to save mock/demo trades` → returns the **same** `{ok:false, guard:"mock_demo_trades", ids:[...]}` contract → **skips Supabase entirely**. Never throws (wrapped in the writer's try/catch).
- **`affectedTradeId`-present guard preserved AND adapted for the object shape:** the live guard at 7857 is array-shaped (`Array.isArray(nextTrades) && !nextTrades.some(...)`). Because the close path now passes the trade **object**, that guard silently no-ops on an object (`Array.isArray(object) === false`). The dispatch (§11/§16) therefore replaces it with an object-shaped check on the close branch: `if (info.affectedTradeId != null && (!nextTrades || nextTrades.id !== info.affectedTradeId)) return {ok:false, guard:"affected_trade_missing"}`. The array form is retained for any non-close (autosave / future array) caller. `closeFailMessage` (195-198) already maps both `mock_demo_trades` and `affected_trade_missing` to specific toasts.

## 9. Failure behavior + UX (no false success preserved)

The no-false-success contract is already wired and is **preserved unchanged**:

- `db.saveTrade` returns `{ok:false, error, guard?}` on timeout/RLS/constraint/mismatch/mock.
- `commitClose` propagates `{ok}` / `{ok:false, error, guard}` (revised shape, §11).
- Close wrappers (3526, 3530) gate `setClosingTrade(null)` **and** the success toast on `res.ok` ONLY → on failure the modal stays mounted with entered data.
- `CloseTradeForm` / `MergedCloseForm`: `setSaving(true)` → `await onClose(...)` → on `!res.ok`, `setSaving(false)` + `showToast(closeFailMessage(res),"error")`. The modal is NOT dismissed (parent only dismisses on `ok`) → entered data preserved, retry possible.
- `Modal busy={saving}` (972) blocks backdrop-close and ✕ during the in-flight write → no accidental dismissal mid-save.
- **Save-first (MAJOR-1):** because `updateTrade` runs only on `res.ok` (§11), on failure the trade is **never shown closed in Open Positions** and the **circuit breaker is never disarmed** — the local UI and CB state stay consistent with the unchanged server. Retry re-runs the same save-first `commitClose` with the current form values; entered close data is never silently reset.
- **Close success is decoupled from the post-close autosave (MAJOR-2):** the success toast + modal close are driven solely by the single-row `db.saveTrade` `res.ok`. A subsequent post-close full-array autosave failing (57014) **cannot un-close** the durably-saved row and must NOT be surfaced as a close failure (see §13 / smoke step 8b).

Net: a `57014` (or any failure) on close now returns `{ok:false}` → retry toast, modal stays open, state stays open, CB stays armed, no optimistic-success — exactly the behavior the P0 was missing. Guard-aware toasts (`mock_demo_trades`, `affected_trade_missing`) are preserved via `closeFailMessage`.

## 10. Revised localhost smoke plan (with the fixed hydration gate)

The prior smoke was **invalid** for two reasons: (a) it ran against mock/demo state where target `1781008993915` was absent (now blocked by the `affected_trade_missing` guard); (b) the gate **raced the localStorage mirror** and read `tj_trades` count `0` because the mirror effect (7783) is gated on `dbReady` and runs *after* hydration's `setTrades`. The fix: **gate on a concrete DOM-observable hydration signal**, not on the LS mirror and not on the un-observable React `dbReady` state.

**Pre-conditions / gates (ALL must pass before the close step):**

1. **authUid gate:** confirm `session.user.id === b77d0426-355d-4f31-b94a-1afbe8fd49fa` (production user). Abort otherwise.
2. **Hydration-complete gate (FIXED — permanent DOM observable, not the LS mirror, not "poll dbReady"):** `dbReady` is internal React state with no DOM/global handle, and the loading spinner renders while `!dbReady`. Gate on **rendered DOM**, NOT the localStorage mirror (the prior gate raced the `dbReady`-gated mirror at 7783 and read `0`). Preferred: add a **permanent, harmless render attribute** `[data-trade-id]` to the trade-row element (render-only, no logic change — fine to keep in production) and **DOM-count poll** until `document.querySelectorAll('[data-trade-id]').length === 134`, with a hard upper bound (e.g. 30 s) after which the smoke **FAILS** (never proceeds). **Avoid a smoke-only `window.__tjDbReady` global / divergent build** unless separately justified — a permanent attribute keeps the smoke build identical to production. The gate MUST NOT proceed on a timeout — count below 134 ⇒ fail, do not close.
3. **Local-trade-count gate:** after the DOM gate, assert in-app trade count `=== 134` (matches the production raw-size profile). Count `0` now means "gate fired too early" → fail the smoke.
4. **Target-id gate:** assert trade `1781008993915` is present in hydrated state, `status==="open"`, `productId` s50_next, entry `1013.3`, 5 contracts.
5. **Mock-id gate:** assert NO id matches `/^m\d+$/` in hydrated state (proves real prod data, not demo). Abort if any mock id present.
6. **Pre-state SELECT (read-only):** query Supabase directly for `1781008993915` → record columnar `status, exit_price, exit_date, updated_at, created_at` **AND** `raw->>'status'`, `raw->>'exitPrice'`, `raw->>'exitDateTime'`. Expect open / `updated_at === created_at` / `raw->>'status'='open'` / `raw->>'exitPrice'` null / `raw->>'exitDateTime'` null.

**Gate summary (ALL must pass before any close):** authUid === `b77d0426-355d-4f31-b94a-1afbe8fd49fa`; rendered/app trade count === 134; target `1781008993915` present; target status open; target product s50_next; mock-id count === 0.

**Gate-failure UX:** if ANY gate fails, the smoke **STOPS before the close** and reports a clear message — *"Local app is not synced with production; do not close. Refresh / re-login and rerun the gate."* A manual close smoke MUST NOT be allowed while the gate is false (this is exactly what blocked the previous invalid mock-state smoke).

**Action:**

7. **Close** through the real close UI → `commitClose` → `db.saveTrade`. **All smoke SQL in this design is SELECT-only — no reversal/cleanup/write SQL is pre-blessed (MAJOR-3).** `1781008993915` is Junior's actual open position; closing it is a permanent, intended production write (a real close is the point of the smoke). Allowed strategies:
   - **A —** close the real target `1781008993915` after the read-only backups (§ backups) and ALL gates pass. **If this real close smoke passes, do NOT auto-reverse it** — a durable close is the correct end state; leave it closed.
   - **B —** use a **disposable test trade**, created through the **normal app flow** (open a tiny throwaway position in the UI), only if **separately approved** beforehand. Do NOT fabricate a trade via SQL.
   - **C —** any SQL **write/reversal/recovery** (e.g. re-opening a row) requires **separate, explicit approval outside this design** — it is not part of the smoke plan.
   - **On smoke failure: STOP and report. Do NOT attempt SQL recovery** unless separately approved. A failed close already leaves the server unchanged (save-first; modal stays open), so no recovery is normally needed.
8. **Assert close UX:** success toast fired AND modal dismissed ⇒ `res.ok` was true. (If `57014` recurs on the single-row write, expect failure toast + modal open — a valid, safe outcome to record.)
8b. **Baseline the residual autosave (per critic):** ~1.5 s after the close UX, the post-close debounced full-array autosave fires (its body is unchanged). In DevTools Network, record whether that autosave returned 200 or 500/`57014`. This distinguishes "close durable, autosave also ok" from "close durable, autosave still failing" so the smoke does not false-pass into believing `57014` is gone (it is not — §13).

**Verification:**

9. **Hard refresh** the app (full reload, re-hydrate from server).
10. **Post-state SELECT:** query Supabase directly for `1781008993915` → assert columnar `status='closed'` (or expected partial), `exit_price`/`exit_date` set, `updated_at > created_at`, **AND** `raw->>'status'='closed'`, `raw->>'exitPrice' IS NOT NULL` (matches entered exit price). Verifying `raw->>` is mandatory because `loadAll` reconstructs trades from `raw` (230), so a columnar-only check could pass while the app still renders the trade as open. Assert the close **survived the refresh** (the original P0 was exactly a non-surviving close).
11. **First-edit-after-hydration check (R3):** after hydration completes (gate 2), make one trivial real edit and confirm its autosave fires (Network shows the autosave request) — proves the D edge-detector did not eat the first real edit.

**Cost discipline:** single-row, single-close smoke — no Claude calls, no eval suite. Safe under the eval-cost-discipline rule.

## 11. Design simplification decision (flushSync / snapshot / serialization)

**Save-first ordering (MAJOR-1 — load-bearing) + snapshot/`flushSync` machinery DROPPED:** With `db.saveTrade(uid, updatedTrade)` saving the **explicit `updatedTrade` object** (not a React-state-captured array), the durable write no longer needs — and MUST NOT depend on — a prior state mutation. The close is therefore **save-first**: `commitClose` awaits the durable single-row save and calls `updateTrade(updatedTrade)` (local state mutation + CB-disarm side effects) **only on `res.ok`**. Because the object is captured before any `setTrades`, `closeCommitSnapshotRef` + `ReactDOM.flushSync` + the `captureSnapshotRef` capture (8334, 8352-8356) are **removed from the close path** — gone, not merely optional. This eliminates the synchronous-render coupling and the `"close snapshot capture failed"` failure class (8356).

**Invariants (MAJOR-1):**
- **No React state may show the trade as closed before the server write succeeds.** `updateTrade` runs strictly after `res.ok`.
- **No circuit-breaker disarm may occur before durable save succeeds.** The CB-disarm `setPortfolio` lives *inside* `updateTrade`'s `setTrades` updater (8336-8340); deferring `updateTrade` to the `ok` branch defers CB-disarm too — a close that 57014-fails never disarms the breaker.
- **flushSync removed. `closeCommitSnapshotRef` removed. `captureSnapshotRef`/`updateTrade` options no longer needed for close durability.** The revised path saves the explicit `updatedTrade` object first; no state-snapshot capture exists.
- `updateTrade`'s single-arg callers stay byte-for-byte unaffected: the capture is gated on `options && options.captureSnapshotRef` (8334), and the close caller stops passing it. The now-unused gated line (8334) **should be removed** when the close path stops passing `captureSnapshotRef` (it becomes provably dead); leaving it is acceptable only if a clean removal is awkward — do not attempt a fragile partial rewrite of `updateTrade` internals.
- **Stale-array race is structurally impossible:** the durable write takes the **explicit `updatedTrade` object**, never the React `trades` array. On `res.ok`, `updateTrade` then mutates state; the subsequent debounced autosave (which *does* read the array) chains **behind** the close write via the single promise chain, so it writes the already-closed trade, never re-opens it.

**Failure UX detail (MAJOR-1):** on `!res.ok` — `updateTrade` is NOT called, local state stays `open`, CB stays armed, the modal stays open (parent dismisses only on `ok`), and the entered exit price / notes / images remain in the form (the form's local state is untouched). The submit button re-enables (`setSaving(false)`) so the user can **retry**: a retry re-runs the same save-first `commitClose` with the **current form values** (no silent reset of entered close data). When the failure carries a known `guard`/error category, `closeFailMessage` (195-198) shows the specific toast; otherwise the generic retry toast.

**`res.ids.has()` post-check in `commitClose` (REMOVE):** the live `commitClose` (8359) verifies `res.ids.has(updatedTrade.id)` — correct for the Option-A array return `{ok:true, ids:Set}`. Under the single-row writer, `res` is `{ok:true, id:trade.id}` (no `ids` Set), so the check silently passes (harmless but misleading dead code). It MUST be **removed**; the id-match verification now lives inside `db.saveTrade` (§5). This is a named Phase-2 checklist item.

**Serialization on `tradesSavePromiseRef` (KEEP):** even though the close is now a single-row write, it must still be **ordered against the still-full-array autosave** to (a) avoid interleaving with a concurrent `db.saveTrades` array write that includes the same row, and (b) avoid `lastSeenRef.tradeIds` races. Recommendation: **route the close through `saveTradesSerialized`** (keep the promise chain), with the dispatch (below) selecting `db.saveTrade` for `source==="close"` and `db.saveTrades` for `source:"autosave"`. This preserves the single ordering chain and never-rejects semantics (7878-7880).

**`lastSeenRef` handling for the close (load-bearing `!isClose` guard):** the closed id is **already in** `lastSeenRef.current.tradeIds` — closing mutates a row, it does not add/remove an id. The live `saveTradesSerialized` assigns `lastSeenRef.current.tradeIds = res.ids` **unconditionally** (7862-7863). Since `db.saveTrade` returns no `ids` field, an unconditional assignment after a close would set `tradeIds = undefined`, and the next autosave would call `db.saveTrades(authUid, trades, undefined)` → `knownIds` falsy → `removedIds = []` (284) → **reconcile-delete silently and permanently disabled for the rest of the session** (deletes stop propagating to the server until a refresh). Therefore the assignment MUST be guarded `if (!isClose)`. On a successful close, `tradeIds` is left **as-is** (unchanged set), and **no reconcile runs**. This guard is a named Phase-2 checklist item (§16, item f).

**Dispatch ordering (load-bearing):** the `isClose` branch MUST be the FIRST decision in the serialized inner function — **before** the array-shaped `affected_trade_missing` guard and **before** any `db.saveTrades` call — because passing the trade **object** into `db.saveTrades` would hit `trades.map(...)` and **TypeError** (every close fails). For the close branch, the guard is the object-shaped form (§8).

DESIGN pseudocode (revised `commitClose` + dispatch — NOT FOR COMMIT):

```js
// DESIGN PSEUDOCODE — revised commitClose. SAVE-FIRST (MAJOR-1):
// durable write FIRST; mutate local state + CB-disarm ONLY on res.ok.
// flushSync / closeCommitSnapshotRef / captureSnapshotRef all removed from this path.
const commitClose = useCallback(async (updatedTrade) => {
  try {
    clearTimeout(dbTimers.current.trades);        // cancel any pending array autosave (defensive)
    // Durable write uses the EXPLICIT object; dispatch (below) routes source:"close" -> db.saveTrade.
    // NO updateTrade yet — local state still shows the trade OPEN until the server confirms.
    const res = await saveTradesSerialized(updatedTrade, {
      source: "close", affectedTradeId: updatedTrade.id,
    });
    if (res && res.ok) {
      updateTrade(updatedTrade);                  // ONLY now: mutate state + CB-disarm (8336-8340)
      return { ok:true };
    }
    // Failure: state untouched (trade stays open, CB armed); parent keeps modal open + retry.
    return { ok:false, error:(res&&res.error), guard:res&&res.guard };
  } catch (e) { console.warn("[close-save] commitClose error", e); return { ok:false, error:e }; }
}, [updateTrade, saveTradesSerialized]);
// The live res.ids.has(updatedTrade.id) post-check (8359) is REMOVED — db.saveTrade does the
// single-row id-match internally (§5). Note: on res.ok, updateTrade's setTrades change triggers
// the debounced full-array autosave ~1.5s later (residual — see MAJOR-2 / §13), which cannot
// un-close the already-durably-saved row.

// DESIGN PSEUDOCODE — saveTradesSerialized inner function, dispatch FIRST.
// `payload` may be an ARRAY (autosave) or a single trade OBJECT (close) — polymorphic by source.
const isClose = info.source === "close";

if (isClose) {
  // Object-shaped affected-trade guard (the array-shaped 7857 guard no-ops on an object).
  if (info.affectedTradeId != null && (!payload || payload.id !== info.affectedTradeId)) {
    console.warn("[close-save][guard] affected trade missing/mismatch", { affectedTradeId:info.affectedTradeId });
    return { ok:false, error:new Error("Affected trade missing from close payload"), guard:"affected_trade_missing" };
  }
} else {
  // Array-shaped guard preserved for autosave / any future array caller.
  if (info.affectedTradeId != null && Array.isArray(payload) && !payload.some(t => t && t.id === info.affectedTradeId)) {
    return { ok:false, error:new Error("Affected trade missing from save snapshot"), guard:"affected_trade_missing" };
  }
}

const res = isClose
  ? await db.saveTrade(authUid, payload)                                  // single row, no knownIds, no reconcile
  : await db.saveTrades(authUid, payload, lastSeenRef.current.tradeIds);  // full array, reconcile-bounded

if (res && res.ok && !isClose) {
  lastSeenRef.current.tradeIds = res.ids;   // CLOSE: tradeIds UNCHANGED, no reconcile (load-bearing !isClose)
}
return res || { ok:false, error:new Error("save returned no result") };
```

> Phase-2 naming note (per critic minor): rename the serialized inner parameter from `nextTrades` to a shape-neutral name (e.g. `payload`) so the array-vs-object polymorphism is visible in review. `source:"close"` implies a single-trade-object payload by convention; a future bulk-close caller passing an array with `source:"close"` would route to `db.saveTrade` and fail the id-match — out of scope, documented as a constraint.

## 12. Candidate comparison (A–G)

| Opt | Description | Narrowness | Data safety | Fixes P0? | Freeze risk | Smoke-safe? | Recommendation |
|---|---|---|---|---|---|---|---|
| **A** | `db.saveTrades` `.select()`→`.select("id")` only (shrink RETURNING) | Very narrow | Keeps affected-count tripwire | **No** (request body still full-array → can still `57014`) | Low | Yes | Necessary but **insufficient alone** |
| **B** | Full-array writer, but save only the changed row inside it | Narrow-ish | OK | Mostly | Low-med | Yes | ≈C, **less explicit / more coupling**; not chosen |
| **C** | **Single-row `db.saveTrade` for close** (1 row, no reconcile, `[row]`+`.select("id")`, verify 1 id, `String()`-coerced) | **Narrowest durable** | Strong (row-level RLS verify) | **Yes** (close path) | Low (within exception) | Yes | **RECOMMENDED** |
| **D** | Suppress post-hydration full-array autosave echo (`prevDbReady` edge-detect) | Narrow | Neutral (removes a spurious write) | Removes the observed `57014` trigger | Low | Yes | **Complementary / necessary** |
| **E** | Chunk the full-array save into batches | Broad | Partial-write risk (mid-batch fail) | Partial | **High** | Risky | Rejected (too broad) |
| **F** | RPC / server-side write | Broad | Strong | Yes | **Outside freeze** (schema/backend) | N/A | Rejected (moratorium) |
| **G** | Image compression / resize on capture | Medium | Strong long-term | Root cause, but not the close-durability bug | Med | Needs broad smoke | **Needed follow-up, NOT P0** |

**Chosen set: C (durable close) + A (bounded RETURNING) + D (suppress hydration echo).** G is backlog.

## 13. Residual limitation (honest)

This P0 patch makes the **close durable regardless of journal size** (single-row write) and removes the spurious post-hydration array write (D). It does **NOT** fix the general case: a **real user-edit autosave is still a full-array ~11 MB request** (`db.saveTrades` body is unchanged; only RETURNING shrank via A). That autosave can still `57014` under load — the timeout is a server-side statement timeout on the upsert of the request body, which A does not address (A only trims the RETURNING side, with a mild positive side effect: a `57014` retry now has a smaller round-trip). The user's data is not lost when this happens (state stays in React + the LS mirror, and the next autosave retries), but the autosave write itself remains unreliable until the real root cause is addressed. **Full mitigation = image compression / resize on capture (Option G, backlog)**: uncompressed base64 data URLs (13/134 rows, up to 1488 kB each) are why the array exceeds the timeout budget. G is the only change that fixes the autosave path; it is deliberately out of scope for this P0. The Phase 5 commit message must explicitly note that a post-close autosave `57014` is a **known residual**, not a regression, so monitoring does not misattribute it.

**Post-close full-array autosave — explicit decision (MAJOR-2):** after a successful single-row close, `updateTrade`'s state change (on `res.ok`) triggers the debounced full-array autosave ~1.5 s later. While `raw` stays ~11 MB that autosave can still `57014`. This is **accepted as a documented residual**, valid ONLY because close success is fully decoupled from it:
- The close is durably persisted by `db.saveTrade` **before** `updateTrade` runs; the success toast + modal close are driven solely by the single-row `res.ok`.
- **A post-close autosave failure cannot un-close the durably-saved row** (the single-row upsert already committed `status='closed'` + `exit_price` + `raw`).
- It must be logged/treated as a **full-array-autosave residual risk, NOT a close-save failure**.
- **Smoke pass criterion (MAJOR-2):** the close smoke MUST NOT be marked failed on a post-close autosave `57014` **if** (1) `db.saveTrade` returned `ok`, (2) the post-state SELECT confirms the row `closed` (columnar + `raw->>`), and (3) hard refresh shows the row remains `closed`. The post-close autosave result (200 vs 57014) is *recorded* (smoke step 8b) as residual telemetry only.

**No risky one-shot suppression now (MAJOR-2 default):** a "skip the next autosave after close" flag is **rejected for this P0** because it could drop a concurrent dirty edit (the user may have edited another trade whose debounced autosave is still pending; `commitClose`'s leading `clearTimeout` already cancels that pending write, and a further blanket skip would lose those edits). No safe, narrow suppression exists without dirty-row tracking, which is out of the freeze. The real fix for the residual autosave timeout is later image compression / storage redesign or a broader autosave redesign — **out of P0**.

## 14. Risks + rollback

**Risks:**
- **R1 — single-row close also `57014`:** the affected row can be up to ~1.5 MB raw; a single-row upsert is far inside budget but not provably immune under extreme server load. *Mitigation:* failure returns `{ok:false}` → modal stays open, no false success (§9). Smoke records this outcome.
- **R2 — mapper divergence regression:** factoring `toTradeRow` could subtly change the row shape — especially "fixing" `remaining_contracts: t.remainingContracts || t.contracts` (0 is a valid `remainingContracts` for a fully closed leg) or `note: t.note || null`. *Mitigation:* `toTradeRow` is a byte-identical extraction (§5 spells the fields verbatim); Phase 3 diff review confirms field-for-field equality; smoke verifies the closed row's columnar **and** `raw->>` fields post-refresh.
- **R3 — D edge-detector eats a real edit:** addressed by the `prevDbReady` rising-edge design (§7), which is batching-independent (consumes on the `dbReady` false→true edge, not on "next trades change"). *Residual:* none expected; Phase 4 smoke step 11 explicitly verifies the first post-hydration edit autosaves.
- **R4 — `saveTradesSerialized` now polymorphic** (object vs array): a wrong dispatch could send an object to `db.saveTrades` → `trades.map` TypeError → every close fails. *Mitigation:* dispatch is the FIRST statement, branch by `source==="close"`, object-shaped guard on the close branch, `db.saveTrade` id-match tripwire; shape-neutral parameter name; Phase 3 review (grep dispatch ordering).
- **R5 — dropping flushSync** changes close timing (UI update now async **and** gated on durable success). *Mitigation:* durability no longer depends on render timing (writer takes the explicit object, §11). Under **save-first (MAJOR-1)** the CB-disarm `setPortfolio` inside the `setTrades` updater (8336-8340) now fires **only after `res.ok`** — a strict correctness improvement (a failed close no longer disarms the breaker). Modal-busy prevents double-submit. Document the timing change so future reviewers don't re-introduce `flushSync` or move `updateTrade` ahead of the await.
- **R6 — session refresh between user action and `commitClose`:** `saveTradesSerialized`/`commitClose` are `useCallback`s closing over `authUid`; if the session refreshes (new auth object, same user) a stale closure could write with the old `authUid`. RLS (`user_id = auth.uid()`) would deny the write → 0 affected rows → id-match tripwire → `{ok:false}` → modal stays open. No data written to the wrong user; user retries after re-auth. *Assumption gap for Phase 2:* confirm supabase-js uses the **live session token** (not the `authUid` argument) for the actual request auth — if so, R6 cannot mis-write; either way the failure mode is safe (kept-open modal), never a silent wrong-user write.
- **R7 — cancelled autosave window on retry:** `commitClose`'s leading `clearTimeout` cancels the pending debounced autosave; between a failed close and the user's retry, that autosave window is suppressed. *Mitigation:* `Modal busy=true` (972) blocks backdrop and ✕ during the in-flight write, so the closed React state cannot be abandoned mid-save; the retry re-runs `commitClose` (idempotent — same trade) → single-row write retried. Safe.

**Rollback:** all changes are local to `index.html`. Revert is a single-commit `git revert`. The change set is additive (`toTradeRow`, `db.saveTrade`, `prevDbReadyRef` + edge guard) plus a small set of edited lines (`.select("id")` + comment, mapper call, dispatch branch + `!isClose` guard, revised `commitClose` with `res.ids.has` removed). If post-deploy regressions appear, revert restores Option A behavior exactly. No schema/RPC/DB migration to undo. No data migration and **no smoke-reversal SQL** (a passing real close is left closed, §10 step 7; a failing close leaves the server unchanged via save-first). The frozen-architecture exception remains scoped to the close path.

## 15. Implementation phase plan

- **Phase 1 — Design addendum (THIS DOCUMENT):** approve direction C+A+D, the simplification decisions (**save-first close** / drop flushSync/snapshot + `res.ids.has`; keep serialization; `tradeIds` unchanged + no reconcile for close), the bigint/string and dispatch-ordering blocker fixes, the `prevDbReady` edge-detector, the post-close-autosave residual decision (MAJOR-2), the SELECT-only smoke (MAJOR-3), and the permanent-DOM hydration gate (MINOR). **No code.** **[DESIGN GATE]**
- **Phase 2 — Code:** implement per the §16 wiring checklist, scoped to `index.html`.
- **Phase 3 — Diff review:** verify mapper equality incl. both `||` fallbacks (R2), dispatch placed first + object-shaped guard (R4), `.select("id")` comment updated and no other reader of `upsertedRows` fields, `String()`-coerced id-match in `db.saveTrade`, `[row]` array-wrap, `!isClose` guard on `lastSeenRef.tradeIds`, `res.ids.has` removed from `commitClose`, `detectUnsafeMockTrades([trade])` array form, `prevDbReady` edge guard with `dbReady` in deps, no localStorage-as-truth, no hydration redesign.
- **Phase 4 — Localhost gated smoke (§10):** all gates (authUid, DOM-count hydration gate, count=134, target-id present/open, no mock ids, pre-SELECT incl. `raw->>`) → close → assert toast+modal → record post-close autosave 200/`57014` as residual telemetry (NOT a fail criterion, MAJOR-2) → hard refresh → post-SELECT confirms columnar + `raw->>` closed survives refresh → first-edit-after-hydration autosave check (R3). **SELECT-only SQL; no reversal SQL.** Close the real target after backups + gates (leave it closed if it passes), or a separately-approved disposable trade created through the app UI. On failure: STOP and report (server already unchanged via save-first).
- **Phase 5 — Commit if pass:** branch off `main` (do not commit on `main`), commit with the standard `Co-Authored-By` trailer, only if Phase 4 fully passes. Commit message notes the residual post-close autosave `57014` is known (§13). File a backlog ticket for Option G (image compression).

## 16. Phase-2 wiring checklist (load-bearing — each item is a named requirement)

a. Add `toTradeRow(uid, t)`, field-for-field per §5, copying the two `||` fallbacks verbatim.
b. `db.saveTrade(uid, trade)`: mock guard `detectUnsafeMockTrades([trade])` (**array-wrapped**); `upsert([row], {onConflict:"id"}).select("id")` (**array-wrapped row**); id-match `ids.length===1 && String(ids[0])===String(trade.id)` (**String both sides**); returns `{ok:true,id}` / `{ok:false,error,guard?}`; no reconcile, no knownIds.
c. `db.saveTrades`: use `toTradeRow`; change `.select()`→`.select("id")`; **update the 269-270 comment**; preserve `affected===0` tripwire and `{ok:true, ids:localIds}` (localIds from `rows`, line 283).
d. `saveTradesSerialized`: rename inner param to a shape-neutral name; put the `isClose` dispatch FIRST; object-shaped `affected_trade_missing` guard on the close branch, array-shaped guard retained for autosave.
e. Dispatch: `isClose ? db.saveTrade(authUid, payload) : db.saveTrades(authUid, payload, lastSeenRef.current.tradeIds)`.
f. **`lastSeenRef.current.tradeIds = res.ids` MUST be guarded `if (res && res.ok && !isClose)`** — never assign `undefined` on the close path (else reconcile-delete dies silently for the session).
g. **`commitClose` is SAVE-FIRST (MAJOR-1):** drop `flushSync` + `closeCommitSnapshotRef` + `captureSnapshotRef` from the close path; keep leading `clearTimeout(dbTimers.current.trades)`; `const res = await saveTradesSerialized(updatedTrade, {source:"close", affectedTradeId:updatedTrade.id})` **FIRST**; call `updateTrade(updatedTrade)` (state mutation + CB-disarm) **ONLY inside `if (res.ok)`**; on `!ok` do NOT mutate state. No React state shows closed and no CB-disarm fires before `res.ok`.
h. **Remove the `res.ids.has(updatedTrade.id)` post-check** in `commitClose` (8359); id-match now lives in `db.saveTrade`.
i. D suppression: add `prevDbReadyRef = useRef(false)`; add `dbReady` to the autosave effect deps; edge-detect false→true to skip exactly the post-hydration echo (§7).
j. **Remove** `updateTrade`'s now-unused `captureSnapshotRef`-gated line (8334) once the close path stops passing it (it becomes provably dead); leave it only if a clean removal is awkward — do not attempt a fragile partial removal of `updateTrade` internals.
l. **Smoke is SELECT-only (MAJOR-3):** no reversal/cleanup/write SQL in the smoke plan; a passing real close stays closed; on failure STOP + report (no SQL recovery without separate approval).
m. **Hydration gate (MINOR):** add the **permanent, production-safe `[data-trade-id]`** render attribute to trade rows; gate on the rendered DOM count (`querySelectorAll('[data-trade-id]').length === 134`), **never the LS mirror** and never `dbReady`-poll. Do **not** add a smoke-only `window.__tjDbReady` global / divergent build unless separately justified.

---

## Adversarial review trail

Four critic lenses reviewed the draft. Counts and resolutions:

- **React correctness lens** — 2 blockers, 5 majors. *Resolved:* (B) `lastSeenRef` clobber → §11 + checklist item (f) `!isClose` guard, named not prose; (B) bigint/string id mismatch → §5 `String()` both sides + checklist (b); (M) dead `affected_trade_missing` on object → §8/§11 object-shaped guard; (M) dead `res.ids.has` → §11 + checklist (h) explicit removal; (M) skip-flag batching dependency → §7 `prevDbReady` rising-edge detector (batching-independent); (M) stale `authUid` → §14 R6.
- **Supabase / data-safety lens** — 2 blockers, 4 majors. *Resolved:* both blockers identical to above (String-coerce id, `!isClose` guard) → §5/§11/checklist; (M) guard placement ordering → §11 dispatch-first; (M) `upsert([row])` array-wrap → §5/checklist (b); (M) flushSync removal stale-array race → §11 (writer takes explicit object, autosave chains behind) + §14 R5; (M) post-close array autosave race → resolved by promise serialization + §10 step 8b baseline.
- **Persistence-freeze-scope lens** — 3 blockers, 4 majors. *Resolved:* (B) polymorphic arg `trades.map` TypeError → §11 dispatch-first + object guard + checklist (d/e); (B) single-object upsert return shape → §5 `[row]` array-wrap; (B) skip-flag retry-path gap → §7 edge-detector covers all `loadAttempt` retries; (M) `toTradeRow` field drift → §5 verbatim fields + R2; (M) `res.ids.has` removal → checklist (h); (M) stale `.select()` comment → §6 + checklist (c); (M) cancelled-autosave-on-retry → §14 R7. Freeze boundary confirmed clean (no schema/RPC/loadAll/hydration redesign).
- **Smoke-validity / operability lens** — 4 blockers, 5 majors. *Resolved:* (B) hydration gate concreteness → §10 gate 2 DOM-count poll with hard-fail-on-timeout + `[data-trade-id]`/`window.__tjDbReady`; (B) dispatch ordering → §11; (B) `lastSeenRef` clobber → checklist (f); (B) post-SELECT misses `raw->>` → §10 step 10 adds `raw->>'status'`/`raw->>'exitPrice'`; (M) post-close autosave false-pass → §10 step 8b; (M) upsert array-wrap, (M) String-coerce → §5; (M) batching reliability → §7; (M) smoke data-rollback → §10 step 7 reversal SQL + disposable-trade option.

Every blocker and major maps to integrated design text, pseudocode, or a named §16 checklist item; none remain as prose-only acknowledgements. The direction (C+A+D) was unanimously assessed as architecturally sound and freeze-compliant.

### Amendment trail (2026-06-15) — design-review MAJORs resolved

Second review (`P0_TIMEOUT_DESIGN_HAS_BLOCKERS`) raised 3 MAJORs + 1 MINOR; all folded into this addendum:

- **MAJOR-1 (save-first close):** the prior draft mutated local state (`updateTrade`) *before* the durable save resolved → on failure the trade vanished from Open Positions and the circuit breaker disarmed against an unpersisted close. **Resolved:** §0 B3, §9, §11 (paragraph + `commitClose` pseudocode reordered: `await save` → `updateTrade` only on `res.ok`), §14 R5, §16 (g). No React state shows closed and no CB-disarm fires before `res.ok`.
- **MAJOR-2 (post-close autosave):** **Resolved as documented residual** — §9 + §13: close success is fully decoupled from the post-close full-array autosave; a post-close 57014 cannot un-close the durable row and MUST NOT fail the smoke (criteria: `db.saveTrade` ok + post-SELECT closed + refresh-survives). Risky one-shot suppression explicitly rejected (could drop concurrent dirty edits).
- **MAJOR-3 (no reversal SQL):** **Resolved** — §10 step 7, §14, §15, §16 (l): all smoke SQL is SELECT-only; a passing real close is left closed; failures STOP + report; any write/reversal needs separate explicit approval.
- **MINOR (hydration gate):** **Resolved** — §10 gate 2 + gate-failure UX: permanent `[data-trade-id]` DOM-count gate (not the LS mirror), smoke-only `window.__tjDbReady` avoided; clear "do not close" message on gate failure.

Approved items kept intact: single-row `db.saveTrade`, shared `toTradeRow`, `.select("id")` + `String(id)` compare, no reconcile in the single-row writer, `db.saveTrades` `.select("id")` mitigation, mock/demo guard in BOTH paths, post-hydration autosave suppression, image compression as backlog (not P0), no RPC/schema/backend, no loadAll/hydration redesign, no localStorage-as-source-of-truth.

**Final unresolved design blockers: 0.** (3 MAJORs + 1 MINOR from review v2 resolved.)
