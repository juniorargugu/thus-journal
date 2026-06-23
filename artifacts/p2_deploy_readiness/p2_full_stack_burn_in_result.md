# P2 Full-Stack Disposable Burn-In — Result

**Status:** `P2_FULL_STACK_BURN_IN — PASS`

**Date/time:** 2026-06-23 ~15:27–15:30 Asia/Bangkok (BKK) — disposable row `created_at` `2026-06-23 08:27:50+00`.
**Run by:** Junior, in a browser against the local app served from local HEAD.

---

## 1. Repo / code state at burn-in time

| Item | Value |
|---|---|
| Local HEAD | `00f02e7` — *"refactor: retire full-array trades writer"* (P2-4C) |
| Local main ahead of origin | 15 local-only commits (before this docs commit) |
| App code changed during burn-in? | **No** (`index.html` untouched) |
| Local app URL | `http://127.0.0.1:8000/index.html` (static-served, no build) |
| App ran from | local HEAD `00f02e7` (NOT production `https://thus999.com`) |

## 2. Production / origin state

| Item | Value |
|---|---|
| origin/main (production) | `2c2c8d2` — **unchanged, no drift** |
| Supabase project | Production `wtfwynvvkiuottjnmozu` (no staging environment) |
| Push / deploy during burn-in? | **No** |
| SQL run during burn-in? | **No** |

## 3. Burn-in scope

Integrated, single-session disposable browser burn-in validating the full **15-commit P2 stack** end-to-end before any deploy:

- durable **single-row** open / edit / close / delete
- **reconcile-only** autosave (no full-array writer)
- image **externalization** on save (base64 → private Storage path)
- **signed** image rendering (path → signed URL at render)
- absence of the **full-array writer fallback** (`fullarray_retired` guard)
- non-recurrence of the original **57014 / full-array upsert** failure

**Disposable trade only:**
- trade id: `1782203176443` (product `s50`, Long, open→close)
- label / note: `P2 FULL STACK BURN-IN — DELETE ME`

## 4. Evidence

| # | Check | Evidence | Verdict |
|---|---|---|---|
| 1 | Image stored as **Storage path**, not base64 / signed / public URL | `raw.preImages[0]` = `b77d0426-…/1782203176443/pre/1782203176444.png` | ✅ HARD |
| 2 | Path is **authUid-anchored** (RLS-correct) | first segment `b77d0426-…` matches `auth.uid()` | ✅ HARD |
| 3 | **Externalize on save** | `[img-externalize] {uploaded:1, failed:0, skipped:0/1}` | ✅ HARD |
| 4 | **Idempotent re-save** (no duplicate upload) | close save → existing preImage path `skipped:1`; new postImage `uploaded:1` | ✅ HARD |
| 5 | Durable **single-row close** | `[close-save] durable ok (single-row) {id:'1782203176443'}` (observed twice) | ✅ HARD |
| 6 | **Reconcile-only** autosave, no over-deletion | `[autosave][backstop] reconcile fire {rows:142, knownIds:142, removedIds:0, imgRows:21, imgItems:40}` | ✅ HARD |
| 7 | **Full-array writer retired** — fallback not hit | `fullarray_retired` — **absent** | ✅ HARD |
| 8 | **Original failure mode absent** | no `[trades][write] upsert-error`, no `57014`, no `500`, no red uncaught console errors | ✅ HARD |
| 9 | Disposable label correct | `raw.preNote` = `"P2 FULL STACK BURN-IN — DELETE ME"` | ✅ HARD |
| 10 | Open / close persisted after refresh; image rendered | user-confirmed | ✅ user-confirmed |
| 11 | Edit persisted; delete persisted after refresh | user-confirmed | ⚠️ see §6 caveat |

Notes:
- The `skipped:1` on the close save is a **positive** signal: the already-externalized preImage path was correctly **not re-uploaded** (idempotent), while the new postImage was uploaded (`uploaded:1`).
- The DB snapshot showing `status:"open"` with `created_at === updated_at` is the **open** write (one write → equal timestamps is correct); it is **not** the close-persistence bug. The two `[close-save] durable ok` lines confirm the close landed separately.

## 5. Safety confirmation

- ✅ **Disposable trade only** (`1782203176443`, labelled "DELETE ME").
- ✅ **No real / non-disposable trade was modified.**
- ✅ **No app runtime code changed** (`index.html` untouched).
- ✅ **No SQL run**; no Supabase schema / policy / data change.
- ✅ **Nothing pushed / deployed** (origin/main still `2c2c8d2`).
- ✅ Upload used the **authenticated** client only (no `service_role`); bucket `trade-images` is **private**; `upsert:false`.

## 6. Caveat (non-blocking)

- **Edit** persistence and **delete** persistence were **user-confirmed** ("all smoke tests passed") but were **not separately line-evidenced** in the pasted console logs (no explicit `delete persisted after refresh` / edit-write line was captured).
- Accepted as **non-blocking**: the integrated burn-in was completed in one session, the user confirmed all steps passed, and every P2-**novel / risky** behavior (image externalization → path, durable single-row write, reconcile-only autosave with `removedIds:0`, absence of `fullarray_retired` / `57014`) carries hard console + DB evidence.

## 7. Remaining non-blocking items

- **P2-5-E** — Storage orphan-sweep strategy (independent of deploy; orphans are cheap, no correctness impact). The disposable burn-in's uploaded objects may remain as orphans by design.
- **UI backlog** — add / replace images on an **already-open** position (parity with the detail-modal edit path).
- **UI backlog** — **clickable / lightbox** detail thumbnail (open a larger preview on click).

## 8. Deploy posture

- The 15-commit P2 stack is **READY_TO_RECORD_BURN_IN** → now **recorded** (this artifact).
- Deploy = push to `main` (Netlify auto-deploy → `https://thus999.com`); it is **gated** on ChatGPT review of a deploy prompt.
- The Storage prereq (P2-5-A: private `trade-images` bucket + SELECT/INSERT-own RLS) is **already applied** to the same production Supabase project, so the first real image-bearing save post-deploy will externalize correctly (de-risked by this burn-in + the P2-5-C smoke).

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Burn-in PASS has been recorded; the deploy prompt should be reviewed before push-to-deploy.
Next action: Prepare the final deploy prompt for the 15-commit (+ this docs commit) local stack.
