# Design — P0 Close-Save Durability Fix (THUS Journal)

**Date:** 2026-06-10
**Status:** `P0_CLOSE_SAVE_DURABILITY_DESIGN_CREATED` — **design only, no code written.**
**Repo:** `C:\Users\Junior\Desktop\thus-journal\` · target `index.html` (read-only inspected)
**Protocol:** Adversarial `/design` — Phase 1 spec → 3 critic rounds → hardened. **Final design-level blockers: 0.**
**Recommended option:** **A** (awaited `commitClose` reusing the canonical `db.saveTrades` via a serialized promise).
**Implementation readiness:** **READY** (0 open design blockers). Implementation is a **separate, gated task** — not done here.
**Persistence freeze:** remains frozen except this **narrow close-save path**.

---

## 1. Executive summary

Closing a position is **optimistic and unconfirmed**: the success toast fires synchronously while the real write is a 1.5 s‑debounced, **unawaited, no‑retry, failure‑silent** effect. A hard refresh (or tab close, or a silent RLS/network failure) before the write lands loses the close; `loadAll` re‑hydrates the still‑open `raw` and the position returns to Open. Confirmed on trade `1781008993915` (server `open`/`raw open`, `updated_at===created_at`).

The fix makes the close **await a durable save** before reporting success, **reusing the existing single writer** (`db.saveTrades`) — no second write path, no schema change, no backend. Success/modal‑dismiss move **after** the server confirms the affected row; on failure the modal stays open with the entered data and a retry. All other persistence is untouched.

---

## 2. Confirmed bug evidence

Affected row (read-only SELECT, prior turn):

| field | value |
|---|---|
| id | `1781008993915` (s50_next, `isMerged`) |
| status / `raw->>'status'` | `open` / `open` |
| exit_price / raw_exit_dt | `null` / `null` |
| created_at | `2026-06-09 12:45:44.073863+00` |
| updated_at | `2026-06-09 12:45:44.073863+00` (**=== created_at**) |

The row was written once (the open) and never updated → **the close write never reached the server.** Not a render bug (only `db.saveTrades` writes `trades`, and it writes columnar `status` + `raw` together, so a server‑closed‑but‑hidden row is impossible). G1 cleared (`group_id` null, trades RLS unchanged). Full evidence: [close_position_journal_bug_audit.md §17](close_position_journal_bug_audit.md).

---

## 3. Current close flow findings (read-only)

- **Optimistic handoff.** `CloseTradeForm` onClose at [index.html:3491](../../index.html#L3491): `onUpdateTrade({...closingTrade,...d,status:"closed"}); setClosingTrade(null); showToast("ปิด order เรียบร้อย")` — all synchronous. `MergedCloseForm` onClose at [3487](../../index.html#L3487); its own success toast at [1993](../../index.html#L1993).
- **State mutator.** `updateTrade` ([8256-8270](../../index.html#L8256-L8270)): `setTrades(p=>p.map(x=>x.id===t.id?t:x))`, id‑preserving; chained CB‑disarm `setPortfolio` ([8263-8267](../../index.html#L8263-L8267)); `tradeEvents.insert` ([8258](../../index.html#L8258), currently a stub [443-445](../../index.html#L443-L445)).
- **Save.** App `useEffect` on `[trades,authUid]` ([7900-7922](../../index.html#L7900-L7922)): 1.5 s debounce (`dbTimers.current.trades`), serialized via boolean `savingRef.current.trades` ([7799](../../index.html#L7799)); calls `db.saveTrades(authUid,trades,lastSeenRef.current.tradeIds)`; on `res.ok` updates `lastSeenRef`; on failure **`console.warn` only — no toast, no retry**.
- **Writer.** `db.saveTrades` ([228-273](../../index.html#L228-L273)): full‑array `upsert(rows,{onConflict:"id"}).select()`; **already returns `{ok:false}` on `affected===0`** (250-255) and catches errors → `{ok:false,error}` (272); bounded reconcile‑delete (259-264).
- **Load.** `loadAll` reads `select("raw")` and renders from `raw` ([213](../../index.html#L213)); hydration overwrites wholesale ([7827-7829](../../index.html#L7827-L7829)).
- **Modal** ([951-962](../../index.html#L951-L962)): backdrop‑click + ✕ → `onClose`; **no Esc handler**.
- **PagePositions** ([3207](../../index.html#L3207), render [8415](../../index.html#L8415)) owns the close flow but has **no** `authUid`/`db`/save fn in props. React 18.2.0 prod UMD; **0** `startTransition`/`useTransition` (so `flushSync` is safe).

---

## 4. Durability invariant

On a close (full **or** partial):

1. **No success before durability.** The success toast and modal dismissal occur **only after** the server confirms the write of the affected trade.
2. **Affected row verified.** "Durably saved" = `db.saveTrades` returned `ok:true` (its `.select()` confirmed `affected>0` for the upserted rows). The reconcile‑delete tripwire and columnar+`raw` write are reused as‑is.
3. **Failure is visible and recoverable.** On `!ok`: modal stays open, explicit error, entered exit price/notes/images preserved, retry available.
4. **No accidental dismissal while saving.** Backdrop/✕/cancel are inert during the in‑flight save.
5. **Narrow.** No broad persistence refactor; one canonical writer; same row contract.

---

## 5. Options compared

| | **A — Awaited `commitClose` reusing `db.saveTrades`** ✅ | B — Flush the pending debounce | C — Targeted single‑trade upsert |
|---|---|---|---|
| Mechanism | New App async `commitClose` applies close via `updateTrade`, then `await`s the canonical full‑array `db.saveTrades` (de‑debounced, serialized) | Expose a "flush now" that cancels the debounce and awaits the same effect's save | New code path that upserts only the one closed row immediately |
| Files touched | App (`commitClose`, refs, serializer), `PagePositions` wrappers + 1 prop, `CloseTradeForm`, `MergedCloseForm`, `Modal` | similar to A but must still pass the explicit next array | App + forms + a new write fn |
| 2nd write path? | **No** — reuses single writer | No | **Yes** — breaks the single‑writer invariant |
| Raw/columnar contract | Preserved (same `saveTrades` mapping) | Preserved | **At risk** — must duplicate the exact mapping or `raw`/columnar diverge |
| Reconcile semantics | Preserved | Preserved | Skipped (must re‑prove safety) |
| Stale‑closure risk | Solved via snapshot capture | Same problem as A (needs explicit array) → converges to A | Lower (one row) but contract risk |
| Payload | Full array (same as today's debounce) | Full array | Minimal (one row) |
| Effort / risk | Moderate / **low** | Moderate / low‑med | Low / **med‑high** (invariant) |
| P/L · dashboard · calendar · export | Unaffected (same data, same writer) | Unaffected | Risk if `raw` diverges |
| Failure behavior | Surfaced + retry | Surfaced + retry | Surfaced + retry |
| Test/smoke | §9 | §9 | §9 + divergence checks |

**B** collapses into **A** once you account for the React stale‑closure problem (you must pass the explicit committed array, which is A's snapshot capture). **C** is the smallest payload but introduces a **second writer** — the exact thing that makes the raw/columnar divergence impossible today; rejected to preserve the frozen contract.

---

## 6. Recommended option — A (consolidated final design)

> Reuses the **single** canonical writer `db.saveTrades`; awaited; serialized; failure‑surfaced. No schema/backend/second‑writer.

**App‑level:**
- Add refs: `closeCommitSnapshotRef=useRef(null)`, `tradesSavePromiseRef=useRef(null)`.
- In `updateTrade`'s `setTrades(p=>{…})` updater, add **as the line immediately before `return next`** (inside the updater, **not** the outer body): `closeCommitSnapshotRef.current=next;`. (Idempotent; production build does not double‑invoke updaters.)
- **Serializer (never rejects):**
  ```
  saveTradesSerialized(arr){
    try{
      const prev=(tradesSavePromiseRef.current||Promise.resolve()).catch(()=>{});
      const p=prev.then(async()=>{
        try{
          const res=await db.saveTrades(authUid,arr,lastSeenRef.current.tradeIds);
          if(res&&res.ok) lastSeenRef.current.tradeIds=res.ids;
          return res;
        }catch(e){ return {ok:false,error:e}; }
      });
      tradesSavePromiseRef.current=p;
      return p;
    }catch(e){ return Promise.resolve({ok:false,error:e}); }
  }
  ```
- **commitClose (never rejects):**
  ```
  const commitClose=useCallback(async t=>{
    try{
      ReactDOM.flushSync(()=>updateTrade(t));     // commits close+CB-disarm+tradeEvents; sets closeCommitSnapshotRef.current
      return await saveTradesSerialized(closeCommitSnapshotRef.current);
    }catch(e){ return {ok:false,error:e}; }
  },[updateTrade]);
  ```
- **Debounced autosave:** keep the outer `setTimeout(tryFire,1500)`/`clearTimeout` skeleton; replace only the inner save call so `tryFire` calls `saveTradesSerialized(trades)` (drop the boolean busy‑poll). Other resources (portfolio/products/notes) keep their existing `savingRef` booleans — **only trades** moves to the promise chain.
- Wire the new prop at **all three sites**: define `commitClose` in App (~[8256](../../index.html#L8256)); add `onCommitClose={commitClose}` to `<PagePositions>` ([8415](../../index.html#L8415)); destructure `onCommitClose` in `PagePositions` ([3207](../../index.html#L3207)).

**PagePositions wrappers (async, gate on `res.ok`):**
```
// CloseTradeForm:
onClose={async d=>{ const res=await onCommitClose({...closingTrade,...d,status:"closed"});
  if(res.ok){ setClosingTrade(null); showToast("ปิด order เรียบร้อย","success"); } return res; }}
// MergedCloseForm:
onClose={async updated=>{ const res=await onCommitClose(updated);
  if(res.ok){ setClosingTrade(null);
    showToast(updated.status==="closed" ? "ปิด order เรียบร้อย"
      : "ปิด "+(updated.contracts-updated.remainingContracts)+" สัญญา · เหลือ "+updated.remainingContracts, "success"); }
  return res; }}
```

**Forms:**
- `CloseTradeForm`: local `saving` state; `handleSubmit` async (validate sync → `setSaving(true)` → `const res=await onClose(...)` → `if(!res.ok) setSaving(false)`); submit button `disabled={saving}` + spinner; `Modal busy={saving}`.
- `MergedCloseForm`: **declare `const[saving,setSaving]=useState(false)` and `handleConfirmClose` BEFORE the `if(openSubs.length===0&&trade.isMerged)` early‑return at [1946](../../index.html#L1946)** (Rules of Hooks). `handleConfirmClose(updated){ setSaving(true); const res=await onClose(updated); if(!res.ok) setSaving(false); return res; }` used by **both** the main submit (replacing [1992-1993](../../index.html#L1992-L1993), **delete the 1993 toast**) **and** the all‑done sub‑branch button ([1953](../../index.html#L1953) → `handleConfirmClose({...trade,status:"closed"})`). Main Modal ([1996](../../index.html#L1996)) and sub Modal ([1947](../../index.html#L1947)) `busy={saving}`; submit/confirm/cancel buttons `disabled={saving}`.
- **`Modal`** ([951](../../index.html#L951)): add `busy=false` param; backdrop `onClick` guarded by `!busy`; ✕ no‑op + disabled when `busy`. (No Esc handler exists; none added.)
- Validation toasts (e.g. [1875](../../index.html#L1875)) stay synchronous/unchanged (fire before `setSaving`).

**Why it fixes `1781008993915`:** open → close → `commitClose` awaits `db.saveTrades`; toast/dismiss only on `ok:true` (affected‑rows confirmed) → server `raw.status="closed"` → hard refresh hydrates closed → appears in Journal. If the write fails, the user **sees it** and retries instead of believing it closed.

---

## 7. UX behavior

- **On submit:** validate (unchanged) → `saving=true` → submit shows spinner "กำลังบันทึก…" + disabled; backdrop/✕/cancel inert (`busy`).
- **On durable success (`res.ok`):** success toast (full or "ปิด N · เหลือ M" for partial) → modal closes → position leaves Open Positions → closed row appears in Journal.
- **On failure (`!res.ok`):** modal stays open; explicit error; entered exit price / notes / images preserved; retry enabled.
- **Accidental backdrop/Esc:** backdrop+✕ gated by `busy`; Esc not handled today (out of scope; the separate **P2 accidental‑close confirmation** is the right home for a dirty‑form guard).

---

## 8. Implementation boundaries

- **In scope:** the close path only — `commitClose`, `saveTradesSerialized`, `closeCommitSnapshotRef`/`tradesSavePromiseRef`, one line in `updateTrade`'s updater, the `tryFire` inner‑save swap, the `onCommitClose` prop (3 sites), the two form submit paths, and `Modal busy`.
- **Out of scope / frozen:** storage architecture, schema, `loadAll`, `savePortfolio`/other resources, no backend/RPC, no GUGU/Capture Bot, no G2 baseline/GroupCard.
- **Implementation wiring checklist (miss any one = silent crash):** (a) define `commitClose` in App; (b) `onCommitClose={commitClose}` at 8415; (c) destructure `onCommitClose` at 3207; (d) `closeCommitSnapshotRef.current=next` inside the updater; (e) delete `MergedCloseForm` toast at 1993; (f) `MergedCloseForm` `saving`/`handleConfirmClose` declared before the 1946 early‑return; (g) `disabled={saving}` on every submit/confirm/cancel button; (h) `busy={saving}` on Modals 1880/1996/1947; (i) `tryFire` → `saveTradesSerialized(trades)`.

---

## 9. Test / smoke plan

**Static / local (no destructive actions):**
- Grep proof: success toast strings appear only inside `if(res.ok)` branches; `MergedCloseForm` 1993 toast removed; `await onCommitClose` present in both wrappers; `disabled={saving}`/`busy={saving}` present; no second `.from("trades").upsert` introduced.
- Confirm `db.saveTrades` body unchanged (single writer preserved).

**Manual smoke (use an existing test position; do not ask Junior to churn real trades):**
1. Close a position → submit button locks + spinner.
2. Success toast appears **only after** the save resolves.
3. Hard refresh immediately after success → row stays **closed** and shows in Journal.
4. Supabase SELECT by id: `status='closed'`, `raw->>'status'='closed'`, `exit_price` not null, exit timestamp present, `updated_at` > `created_at`.
5. Images persist if attached (`post_imgs`).
6. P/L / dashboard / calendar / export reflect the close.
7. Partial (merged) close: status stays open with correct `remainingContracts`; "ปิด N · เหลือ M" toast; durably saved.
8. No GroupCard/G2 side effects.

**Failure‑mode smoke (only if safe/easy):**
- Simulate offline (DevTools) → close → modal **stays open**, error shown, fields preserved, retry works; on reconnect the retry persists.

---

## 10. Risks and rollback

| Risk | Mitigation |
|---|---|
| `flushSync` perf/jank | 0 concurrent features in app; click‑scoped; fallback = post‑commit‑effect (documented) |
| Slow full‑array write (base64 images) | spinner + the await *is* the durability guarantee; failure surfaces instead of silent loss |
| Debounced re‑save after `commitClose` | serialized + idempotent (chained behind the close save); ordering preserved |
| Wiring omission | explicit 8‑point checklist (§8) |
| **Pre‑existing, NOT fixed here (documented):** full‑array write flushes other same‑tab in‑progress edits; `knownIds=localIds` drops server‑only ids / stale‑tab overwrite; `db.saveTrades` returns `ok:true` even if reconcile‑delete `delErr` (multi‑tab delete races only) | out of scope; tracked as follow‑ups |
| **Rollback** | single‑commit change; revert restores the optimistic path. No schema/data migration → rollback is code‑only. |

---

## 11. Adversarial review trail (for the record)

Phase 2 critic: 3 BLOCKERs. Phase 4 round 1: 4 (ratchet regression — accepted, finer‑grained). Round 2: 4 prior resolved, 3 new (never‑reject wrap, delete‑1993‑toast, 3‑site wiring) → all folded. Round 3 (first pass) **misfired on scope** (flagged "not in file" — invalid for a design‑only task); re‑run with corrected framing → **1 BLOCKER** (Rules‑of‑Hooks placement) + 3 MAJORs, all resolved as explicit spec text. **Final unresolved design blockers: 0.** Full trail in the design cache.

---

## 12. Explicit non-actions

- ❌ No code changed (design only). ❌ No SQL writes / no Supabase modification. ❌ No localStorage modification. ❌ No deploy / push / restart. ❌ No GUGU / Capture Bot. ❌ No G2 baseline / GroupCard. ❌ Nothing committed.
- ✅ Persistence architecture **remains frozen** except this narrow close‑save durability path. Implementation is a **separate, gated** task.
