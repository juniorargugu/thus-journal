# P2-5D Image Backfill Closeout

**Date (local):** 2026-07-02
**Status:** CLOSED — eager base64→Storage backfill complete; temporary driver removed from `index.html`.

> Directory note: the paired design doc and all prior P2-5 artifacts live under
> `artifacts/image_externalization/` (e.g. `p2_5d_backfill_design.md`,
> `p2_5a_storage_policy_pack.md`). This closeout was created at the path named in the
> closeout task (`artifacts/p2_5_image_externalization/`). The two directories can be
> consolidated in a later docs-only pass if desired.

---

## Repo HEAD

| | Commit |
|---|---|
| Before closeout | `a6b4644` — `fix: allow P2-5D post-partial dry-run gating` |
| After closeout | this commit — `chore: close out P2-5D image backfill` |

Local-only stack; **not pushed, not deployed.**

---

## Scope (from metrics-only manifest, source commit `00be917`)

| Metric | Value |
|---|---|
| Closed rows backfilled | 18 |
| Base64 images total | 37 |
| preImages | 17 |
| postImages | 20 |
| PNG (`image/png`) | 32 |
| JPEG (`image/jpeg`) | 5 |
| MIME blockers | 0 |
| Size blockers | 0 |
| Largest single image | 617,314 bytes (< 5 MB) |
| Status distribution | 18 × `closed` |

All images passed the bucket MIME allow-list (png/jpeg/jpg/webp/gif) and the 5 MB decoded cap.

---

## Backup (sensitive — outside git)

- **Raw backup (SENSITIVE, contains full base64 image data):**
  `C:\Users\Junior\Desktop\thus_p2_5d_backfill_backup_20260702\affected_rows_raw_backup_20260702.json`
  - 17,472,409 bytes; `backupSha256 = 151ff27fa5d3211dcaf575daebc09398c5803aef8a2d84186352859e2422e267`
  - **Never committed / staged / printed.** Lives outside the repo by design.
- **Metrics-only manifest (safe — no raw bodies, no base64, no secrets):**
  `C:\Users\Junior\Desktop\thus_p2_5d_backfill_backup_20260702\p2_5d_backup_manifest_20260702.json`
  - Per-row stale-guard fields only (id, status, updated_at, rawSha256, image/byte counts, MIME summary).

The raw backup was captured before any write (Step A) and used as the authoritative
pre-image stale guard during apply. It was **not** modified by this closeout.

---

## Browser execution summary (operator-reported console logs)

The backfill ran entirely browser-side via the gated dev driver (now removed). Observed:

- **Initial dryRun (clean):** 18 remaining / 0 externalized / 0 mismatch / allClean true.
- **First apply, limit 1:** processed 1 row, uploadedPaths 1 → post-dryRun 17 remaining / 1 externalized / 0 mismatch.
- **Batch, limit 5:** processed 5 rows, uploadedPaths 9 → post-dryRun 12 remaining / 6 externalized / 0 mismatch.
- **Continuation batches:** completed the remaining rows over subsequent limit-≤5 batches.
- **Logged batch:** processed 5, uploadedPaths 11 → post-dryRun 2 remaining / 16 externalized / 0 mismatch.
- **Final observed dryRun (authoritative):** 0 remaining / 18 externalized / 0 mismatch / allClean **true** / readyForApply **false**.
- **Final apply attempt (`applyFinal2`):** safe no-op — `{ ok:true, done:true, reason:"nothing_remaining", processed:0, remainingDataRows:0 }`.
- Network: no reported errors during the runs.

Per-row guards enforced on every processed row: manifest stale guard (updated_at / rawSha256 / image count / byte count / status closed) → `externalizeTradeImages` upload (base64 kept on failure) → storage-path signability check → pre-save delta (image-only) → re-read-before-save stale guard → durable `db.saveTrade` single-row upsert → post-save re-read + raw delta verification.

---

## Caveat

- Some intermediate operator-side batch details were **not fully captured** in the transcript.
  The per-batch totals above are transcribed from observed logs only; **no exact per-batch
  figures were invented** beyond what was logged.
- The **final dryRun (0 remaining / 18 externalized / 0 mismatch / allClean true)** is the
  authoritative closeout signal, corroborated by the final no-op apply (`nothing_remaining`).

---

## Code closeout

- **Removed:** the temporary P2-5D browser backfill driver/harness from `index.html`
  (the dev-gated IIFE: `window.__tjP25DBackfill`, the `tj_p2_5d_backfill_dev` flag gate,
  `status()/dryRun()/applyBatch()` entry points, and all P2-5D-only stale/delta/manifest
  helpers). No temporary driver strings remain in `index.html`.
- **Preserved (production P2-5 A/B/C):**
  - Renderer support for mixed image refs — legacy `data:`, http(s), and Supabase Storage
    paths (`isDataImageRef`, `isHttpImageRef`, `isTradeImageStoragePath`, `signTradeImagePath`,
    `useResolvedImageSrc`, `ResolvedImage`).
  - Upload-on-commit / new-image externalization (`externalizeTradeImages`), still wired into
    the durable save/commit paths.
  - Durable single-row save (`db.saveTrade`) paths.

Local validation: driver strings absent, production helpers intact, in-browser Babel block
compiles (esbuild syntax check EXIT 0), pure LF, `git diff --check` clean.

---

## Residual follow-ups

- **Deploy is deferred.** This is a local-only commit within a held stack.
- When the next batched deploy happens, smoke:
  - normal image rendering across legacy `data:`, http(s), and Storage-path refs;
  - new-image **upload-on-commit** on a fresh trade save (base64 → Storage path).
- The **raw backup** may be retained temporarily until post-deploy confidence, then
  archived or deleted **only by explicit user approval** (it holds sensitive base64).
