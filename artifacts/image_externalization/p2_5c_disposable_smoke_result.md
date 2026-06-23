# P2-5-C — Disposable Image Externalization Smoke Result

**Status:** `P2_5C_DISPOSABLE_SMOKE — PASS`

**Date/time:** 2026-06-23 14:32 Asia/Bangkok (BKK)
**Run by:** Junior, in a browser against the local app (`http://localhost:8000/`, static-served, no build).

---

## 1. Repo / code state at smoke time

| Item | Value |
|---|---|
| Local HEAD | `0a6dd43` — *"feat: externalize trade images on save"* (P2-5-C) |
| origin/main (production) | `2c2c8d2` — unchanged |
| Local main ahead of origin | 13 local-only commits (before this docs commit) |
| App code changed during smoke? | **No** |
| Deploy / push? | **No** |
| Storage prereq | Private bucket `trade-images` + SELECT-own / INSERT-own RLS (P2-5-A, applied 2026-06-22) |
| Render prereq | P2-5-B resolver (`92ba315`) — signs storage paths at render |

## 2. Smoke steps summary (Path A — open + preImage)

1. Created a **disposable** open/draft trade (not a real position).
2. Attached **one** small Pre-trade image (PNG, <5 MB).
3. Saved → `commitTradeWrite` → `externalizeTradeImages(authUid, trade)` → `db.saveTrade`.
4. Verified console, DB row, Storage object, and UI render.

- **Disposable trade id:** `1782199834317`
- **Disposable preNote:** `P2-5-C DISPOSABLE IMAGE SMOKE — DELETE ME`

## 3. Evidence

**Console (counts-only, no base64 logged):**
```
[img-externalize] {uploaded: 1, failed: 0, skipped: 0}
```

**DB — `raw.preImages[0]`:**
```
b77d0426-355d-4f31-b94a-1afbe8fd49fa/1782199834317/pre/1782199834318.png
```
- ✅ Stored value is a **Storage path string**.
- ✅ **Not** `data:image/…;base64,…`.
- ✅ **Not** a signed URL (`…?token=…`).
- ✅ **Not** a public URL (`…/storage/v1/object/public/…`).
- ✅ Path matches the design format `{authUid}/{tradeId}/{pre|post}/{imageId}.{ext}` — first segment = `auth.uid()` (RLS anchor), side `pre`, `imageId` `1782199834318` (`uid()`, one past the trade id), ext `png`.

**Storage object (`trade-images`):**
| Field | Value |
|---|---|
| File | `1782199834318.png` |
| Path | `b77d0426-355d-4f31-b94a-1afbe8fd49fa/1782199834317/pre/1782199834318.png` |
| MIME | `image/png` |
| Size | 363.87 KB |
| Added | 2026-06-23 14:32:57 Asia/Bangkok |

**UI:**
- ✅ Image rendered via the P2-5-B resolver (path → signed URL). No crash, no broken UI.

## 4. Result

- Upload **succeeded** (1/1).
- DB row stored the **path** (not base64 / not a URL).
- Storage object **exists** under the owner's `{authUid}/…` folder (RLS-scoped).
- End-to-end externalize → store-path → sign-on-render **verified**.

## 5. Safety confirmation

- ✅ **Disposable trade only** (`1782199834317`, labelled "DELETE ME").
- ✅ **No real / non-disposable trade was modified.**
- ✅ **No code changed** during the smoke (`index.html` untouched).
- ✅ **Nothing pushed / deployed** (origin/main still `2c2c8d2`).
- ✅ Upload used the **authenticated** client only (no `service_role`); bucket is **private**; `upsert:false`.

## 6. Known orphan note (by design)

v1 has **no eager Storage deletion**. If the disposable trade is deleted via the app (durable delete removes the row + ref), the uploaded object
`b77d0426-…/1782199834317/pre/1782199834318.png` **may remain as an orphan** in `trade-images`. This is **expected** and will be reclaimed by the future **P2-5-E orphan sweep**. Do not manually delete Storage objects unless explicitly approved.

## 7. Non-blocking UI backlog (recorded, not part of P2-5)

1. **Edit/add images on an already-open position** — let an existing open position add/replace Pre/Post images after it's opened (currently most natural via the detail modal; confirm parity for open positions).
2. **Clickable detail thumbnail** — the position-detail image thumbnail should open a larger preview/lightbox on click.

## 8. Remaining persistence-cleanup track

- **P2-4C** — final `db.saveTrades` (full-array) retirement, after an observation window confirms the reconcile-only autosave + durable single-row writers are sufficient.
- **P2-5-E** — orphan-sweep strategy for Storage objects left by deletes / removed images / save-failure.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: P2-5-C smoke passed and was recorded; next persistence cleanup step needs review.
Next action: Review whether to proceed to P2-4C final db.saveTrades retirement design or P2-5-E orphan strategy.
