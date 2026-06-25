# Closed-Trade Correction V1 — Browser Smoke Result

**Status:** `CLOSED_TRADE_CORRECTION_V1_SMOKE — PASS`

**Date:** 2026-06-24/25 (Asia/Bangkok)
**Run by:** Junior, in a browser against the local app (`http://127.0.0.1:8000/index.html`, local HEAD).

---

## 1. Code state at smoke time

| Item | Value |
|---|---|
| Local HEAD | `8647fec` — *"feat: allow closed trade correction"* |
| origin/main (production) | `eca0e00` — unchanged |
| Local main ahead of origin | 2 commits (`8feb486` closeout docs + `8647fec` feature), before this docs commit |
| App code changed during smoke? | **No** |
| Push / deploy? | **No** |

## 2. Feature summary

Closed-Trade Correction V1 lets the user correct **`exitPrice`** and **`exitDateTime`** on eligible
**manual, standalone, fully-closed** trades, via the existing durable update path
(`TradeDetailModal` editMode → `saveEdits` → `commitMeta` → `commitUpdateTrade` → `db.saveTrade`).
P/L is derived from `exitPrice` at render (`tradeNetPL` → `calcNetPL`), so a correction recomputes
P/L / balance / steps / HWM / win-rate / DD / withdrawal everywhere — nothing persisted to migrate.

**Eligibility gate:**
`trade.status==="closed" && trade.exitPrice!=null && !trade.isMerged && !(trade.partialCloses&&trade.partialCloses.length) && trade.brokerProfit==null`

**Deferred:** partial-close correction · merged-trade correction · MT5/`brokerProfit` correction ·
audit trail / correction history · auto-appended correction note.

## 3. Smoke results

| Smoke | Result | Notes |
|---|---|---|
| **A — eligible correction UI** | ✅ PASS | On a disposable manual standalone closed trade: "🔧 แก้ไขข้อมูลปิด Position" section + warning copy + Exit Price + Exit Date & Time fields visible in editMode. |
| **B — correct exit price** | ✅ PASS | Changed exitPrice → saved → displayed exitPrice updated, P/L updated; refresh persisted the corrected exitPrice + P/L. |
| **C — unsaved guard** | ✅ PASS | Editing exitPrice/exitDateTime then backdrop/X triggers the unsaved dialog; `อยู่ต่อ` keeps the edited value; `ปิดโดยไม่บันทึก` closes without saving. |
| **D — invalid exit price** | ✅ PASS | Empty / 0 / negative / invalid blocked with "ราคาปิดต้องเป็นตัวเลขมากกว่า 0"; no update saved. |
| **E — non-eligible gating** | ⚠️ STATIC-VERIFIED / NOT MANUALLY RUN | No safe/easy merged / partial / MT5 closed-trade sample was available; **not** worth creating complex data just to smoke. The eligibility gate is statically validated in code (and adversarially reviewed) and explicitly excludes merged, partial-close, and `brokerProfit`/MT5 trades — the correction section never renders for them. |
| **F — regression** | ✅ PASS | Existing editable fields still save; NoteField guard still works; lightbox still works; console clean. |

## 4. Console / safety

- ✅ No `fullarray_retired`, no `[trades][write] upsert-error`, no `57014`/500, no red uncaught errors.
- ✅ No save logs from merely guarding/closing.
- ✅ No persistence / db / storage / autosave / externalize / P/L-function code changed (render/gate/guard wiring only; verified per the implementation diff + critic review).
- ✅ No real trade modified (disposable trade only for B/C).
- ✅ Nothing pushed / deployed (origin/main still `eca0e00`).

## 5. Net

Closed-Trade Correction V1 passed all hands-on smokes (A–D, F); non-eligible gating (E) is accepted as
static-verified given the code-level gate + adversarial review. No data-loss or regression in the smoked
surfaces. Production unchanged; the feature is ready for a **gated deploy review**.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Closed-trade correction smoke passed and was recorded; the final deploy prompt should be reviewed before push-to-deploy.
Next action: Prepare a gated deploy prompt for the closed-trade correction stack (2 commits ahead of `eca0e00`).
