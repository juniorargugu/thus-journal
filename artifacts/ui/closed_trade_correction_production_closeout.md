# THUS Journal — Closed-Trade Correction V1 Production Closeout

**Status:** `CLOSED_TRADE_CORRECTION_V1 — DEPLOYED & VERIFIED IN PRODUCTION`

**Date:** 2026-06-25 (Asia/Bangkok)
**Production URL:** https://thus999.com

---

## 1. What happened

Closed-Trade Correction V1 is **live in production**. The validated 3-commit local-only range was pushed
to `origin/main`, Netlify auto-deployed, and production was verified to be serving exactly the committed HEAD.

| Item | Value |
|---|---|
| Production `origin/main` | `09842d7` — *"docs: record closed trade correction smoke pass"* |
| Previous production baseline | `eca0e00` — UI lightbox + unsaved-guard stack |
| Deploy mechanism | Push to `main` → Netlify auto-deploy → https://thus999.com |
| Netlify deploy | **Published** (`Server: Netlify`, `X-Nf-Request-Id: 01KVZ5A5K1XQZNEHNNWCWT8J02`) |

## 2. Commit range deployed

`eca0e00..09842d7` — 3 commits:

```
8feb486 docs: record UI stack production closeout
8647fec feat: allow closed trade correction
09842d7 docs: record closed trade correction smoke pass
```

## 3. What shipped

### Runtime feature — Closed-Trade Correction V1
- Correction UI inside `TradeDetailModal` **edit mode**, shown only for **eligible manual standalone fully-closed** trades.
- Editable correction fields: **`exitPrice`** + **`exitDateTime`**.
- Explicit warning: `การแก้ไขนี้จะอัปเดต P/L และประวัติ Journal ย้อนหลัง`.
- Invalid-price validation: `ราคาปิดต้องเป็นตัวเลขมากกว่า 0` (`Number()` coercion rejects empty/0/negative/NaN; empty datetime keeps the existing value).
- Reuses the existing durable update path: `saveEdits` → `commitMeta` → `commitUpdateTrade` → single-row `db.saveTrade`. **No new persistence route.**
- P/L stays **derived at render** (`tradeNetPL` → `calcNetPL`); a corrected `exitPrice` auto-recomputes P/L / balance / steps / HWM / win-rate / DD / withdrawal. **No P/L-function change; nothing persisted to migrate.**
- Hardenings (from adversarial review): `key={trade.id}` on both `TradeDetailModal` render sites (re-seed on trade switch); `exitPrice!=null` in the gate; `Number()` over `parseFloat`. Correction dirtiness folded into the existing `useUnsavedGuard`.

### Eligibility gate
`trade.status==="closed" && trade.exitPrice!=null && !trade.isMerged && !(trade.partialCloses&&trade.partialCloses.length) && trade.brokerProfit==null`

### Docs-only (in this range)
- UI stack production closeout artifact.
- Closed-trade correction smoke result.

## 4. Verification

| Stage | Result |
|---|---|
| Preflight (branch / HEAD / exact 3-commit range / no drift / clean tree / known untracked only) | ✅ PASS |
| Push `eca0e00..09842d7 main -> main` | ✅ succeeded; `origin/main` = `09842d7` |
| Netlify deploy | ✅ published; `Cache-Control: must-revalidate` on `index.html` |
| Production content match | ✅ production HTML **byte-identical** to committed HEAD `index.html` (549,509 bytes, LF) |
| New correction markers live | ✅ `แก้ไขข้อมูลปิด Position`, `การแก้ไขนี้จะอัปเดต P/L และประวัติ Journal ย้อนหลัง`, `ราคาปิดต้องเป็นตัวเลขมากกว่า 0`, `isCorrectable`, `correctionDirty` |
| Prior UI-stack markers retained | ✅ `onPreview`, `onDirtyChange`, `useUnsavedGuard`, `มีข้อมูลที่ยังไม่ได้บันทึก` |
| User-side production runtime smoke | ✅ user reported all passed |

## 5. Safety confirmation

- ✅ **No real trade modified** during deploy or runtime smoke.
- ✅ **No SQL run**; no Supabase schema / policy / data change.
- ✅ **No Storage upload / delete**.
- ✅ **No persistence/db/storage/autosave/P&L-function code changed** (TradeDetailModal UI/edit-path + two `key` props only; verified per the implementation diff + critic review — ineligible-trade mutation confirmed impossible).
- ✅ **Known untracked files remained untracked** (`.claude/`, `.gitignore`, `RESOURCE_AUDIT.md`, `archive/`, 2 close-bug backups, merge baseline) — none staged, none pushed.
- ✅ App runtime code unchanged by this closeout (docs-only).

## 6. Remaining backlog

- **Partial-close correction** — deferred (per-leg `pl` complexity).
- **Merged-trade correction** — deferred (avg-exit + stored per-leg `pl`).
- **MT5 / `brokerProfit` correction** — deferred (P/L is stored broker P/L, independent of `exitPrice`).
- **Audit trail / correction history (v2)** — optional; v1 silently overwrites with explicit "correction" wording, no edit log.
- **MT5 Auto Draft Import** — separate parked track (Phase 0A-r3 design approved, schema/RPC apply gated).

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Closed-Trade Correction V1 production closeout is recorded.
Next action: Decide next backlog item: audit trail/correction history v2, partial/merged/MT5 correction discovery, or return to MT5 Auto Draft Import planning.
