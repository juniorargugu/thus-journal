# UI Lightbox + Unsaved-Changes Guard — Browser Smoke Result

**Status:** `UI_LIGHTBOX_UNSAVED_GUARD_SMOKE — PASS`

**Date:** 2026-06-23/24 (Asia/Bangkok)
**Run by:** Junior, in a browser against the local app (`http://127.0.0.1:8000/index.html`, local HEAD).

---

## 1. Code state at smoke time

| Item | Value |
|---|---|
| Local HEAD | `904e739` — *"fix: guard unsaved detail note edits"* |
| origin/main (production) | `ba532be` — unchanged |
| Local main ahead of origin | 8 commits (before this docs commit) |
| App code changed during smoke? | **No** |
| Push / deploy? | **No** |

Commits exercised (local UI stack):
`352854f` lightbox · `cf23f44` unsaved guard V1 · `f925259` detail editMode guard V1.1 · `904e739` detail note guard.

## 2. Smoke results

### 2.1 Trade image lightbox (`352854f`)
| Check | Result |
|---|---|
| Thumbnail click opens lightbox | ✅ PASS |
| Image renders large | ✅ PASS |
| Close button (✕) works | ✅ PASS |
| Backdrop close works | ✅ PASS |
| Esc close works | ✅ PASS |
| Detail modal stays open after closing lightbox | ✅ PASS |
| Preview does NOT trigger save/upload logs | ✅ PASS |
| Console clean | ✅ PASS |

### 2.2 Add/replace images on already-open position (verified already shipped)
- Card click opens detail modal; pre/post uploaders + `+` tile visible.
- Image add produced `[img-externalize] {uploaded:1, failed:0, skipped:1}`.
- Durable single-row save log observed; autosave reconcile log observed.
- After refresh, image persisted.
- **No new implementation needed** (capability already present; reuses `commitUpdateTrade` + externalization).

### 2.3 Unsaved guard V1 — Open/Close/Merged forms (`cf23f44`)
| Check | Result |
|---|---|
| OpenTradeForm dirty guard | ✅ PASS |
| OpenTradeForm clean close | ✅ PASS |
| Image dirty guard / no lag | ✅ PASS |
| Detail / lightbox regression | ✅ PASS |
| CloseTradeForm | ⚠️ not fully practical to smoke — real closed-trade exit-price correction is not currently editable; tracked as a **separate backlog item** (closed-trade correction). The guard wiring is present + statically + adversarially reviewed. |

### 2.4 Unsaved guard V1.1 — TradeDetailModal editMode (`f925259`)
| Check | Result |
|---|---|
| feeling / setup / rating guard | ✅ PASS |
| clean edit close | ✅ PASS |
| save path works | ✅ PASS |
| lightbox regression | ✅ PASS |

### 2.5 NoteField guard patch (`904e739`)
| Check | Result |
|---|---|
| note dirty guard | ✅ PASS |
| note clean close | ✅ PASS |
| note save persists | ✅ PASS |
| lightbox regression | ✅ PASS |

## 3. Safety

- ✅ No real trade modified (except disposable data if any save was tested).
- ✅ No persistence / db / storage / autosave / externalize code changed during these UI patches (verified per-commit: render/guard wiring only).
- ✅ No SQL; no Supabase schema/policy/data change.
- ✅ Nothing pushed / deployed (origin/main still `ba532be`).
- ✅ Console showed **no** `fullarray_retired`, `[trades][write] upsert-error`, `57014`/500, red uncaught errors, or save logs from merely previewing / closing / confirming.

## 4. Known remaining backlog

- **Closed-trade correction** — allow editing/correcting exit price / close details after a trade is closed (separate future feature; not in this UI stack).
- **P2-5-E Phase C** — Storage orphan deletion remains **deferred / monitor-only** (inventory showed immaterial within-retention orphans).
- **Optional future UI** — broader unsaved-guard coverage for `UpdatePriceModal` / non-trade modals, if desired.

## 5. Net

The local UI stack (lightbox + unsaved-changes guard across OpenTradeForm / CloseTradeForm / MergedCloseForm / TradeDetailModal editFields + notes) passed browser smoke. No data-loss gap remains in the smoked surfaces. Production unchanged; the 8-commit local stack is ready for a **gated deploy review**.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: UI smoke passed and was recorded; the final deploy prompt should be reviewed before push-to-deploy.
Next action: Prepare a gated deploy prompt for the local UI/docs/tool stack (8 commits ahead of `ba532be`).
