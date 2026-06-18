# Closeout — P1 Durable Update Path (THUS Journal)

**Date:** 2026-06-18
**Status:** `P1_DURABLE_UPDATE_PATH_COMPLETE`
**Repo:** `C:\Users\Junior\Desktop\thus-journal\` · `index.html`
**Lineage:** continues the durable-save work in [`close_save_durability_design.md`](close_save_durability_design.md) (P0 close) and the open/draft-execute durable path (commit `3947a6d`). This is the **update**-writer phase: close → open → update.

---

## 1. Outcome

| | |
|---|---|
| Deployed commit | `30d5a1d` — *"fix: make trade updates save durable before success"* |
| Parent (prior prod) | `3947a6d` (open-save durable) |
| Netlify deploy | `6a33faf0b6c18f000824c757` — state **ready** — branch `main` |
| Production URL | https://thus999.com |
| `main` / `origin/main` | `30d5a1d` (fast-forward, no merge commit) |
| Manual production smoke (Junior) | **PASS / all good** |
| Static verification | HTTP 200; `v3.20.0` + favicon retained; durable-update markers present in served bundle |

The earlier production `POST /rest/v1/trades` **500 / PostgREST 57014 statement timeout (~11.7 s)** was the *old* full-array `db.saveTrades` detail-note save on `3947a6d` — i.e. evidence of the bug this patch fixes, not a patch failure. Post-deploy smoke on the patched bundle confirmed durable note saves.

## 2. Scope completed (now save-first durable)

1. Edit existing order
2. Update current price
3. `TradeDetailModal` notes / images / meta — **Positions**
4. `TradeDetailModal` notes / images / meta — **Journal**

## 3. Implementation summary

- **`commitUpdateTrade`** — clears the pending debounced autosave, `await`s a durable single-row write via `saveTradesSerialized({source:"update", affectedTradeId})`, applies local state only on `res.ok`.
- **`source:"update"`** added to the single-row branch of `saveTradesSerialized`; the `lastSeenRef` known-set union stays gated to `source==="open"` only.
- **Pure `replaceTradeLocal`** on success — a `setTrades` map-replace with **no** `updateTrade` side effects (no CB-disarm, no `tradeEvents("closed")` insert).
- **`metaSavingRef` / `metaSaving` guard** in `TradeDetailModal` — blocks a second whole-row save built from stale props (prevents lost edits); blocked attempt shows "กำลังบันทึก...".
- **`NoteField.save` is async** — awaits `onSave`, keeps the editor open on explicit failure, legacy sync callers unaffected.
- **Single, edit-specific failure toast** — parent no longer double-toasts; `OpenTradeForm` is the single, mode-aware source.
- **PageJournal included** (shared detail modal threaded through `onCommitUpdate` + `showToast`).
- Close / open-add / draft-execute durable paths **unchanged**.

## 4. Remaining residual non-durable writers (follow-ups, out of scope here)

- **delete trade** — state-first delete + debounced full-array reconcile
- **duplicate-to-draft** — state-first add
- **Excel / MT5 import** — bulk state-first add (keep as a separate small-batch design)
- **position merge / `handleMerge` / G2 / GroupCard / `trade_groups`** — frozen scope; do not touch
- **journal `mergeSelected`** — disabled (no activator; `_hiddenByMerge` never read)
- **settings danger-zone deletes** — separate intentional admin destructive path

## 5. Recommended next planning item

Pick one for the next `/design` cycle:
- **Product / Symbol / Live Price Foundation**, or
- **Residual-writer audit** for `delete` / `duplicate-to-draft` / `import` (apply the same `commitUpdateTrade`-style save-first pattern; delete needs a Supabase-delete-first variant).
