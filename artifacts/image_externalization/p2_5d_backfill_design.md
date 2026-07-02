# P2-5-D — Legacy Base64 Image Backfill: Design

**Status:** `P2_5D_BACKFILL_DESIGN — READY_FOR_CODEX_REVIEW`

Drafted 2026-07-02 BKK. **Design only.** No Storage writes, no trade mutations, no SQL/RPC, no
uploads, no app-code change, no deploy. This document specifies a one-time eager backfill and the
gates that must pass before any write. Implementation and any apply are separate, later, gated tasks.

---

## 1. Objective

P2-5-D is a **one-time eager backfill** that externalizes the legacy inline base64 trade images still
embedded in the `preImages` / `postImages` arrays of a bounded set of **closed** trades. It uploads each
base64 image to the private `trade-images` Storage bucket and replaces the `data:` ref in the trade's
`raw` with a stable Storage **path** string — exactly what P2-5-C already does on new saves, applied
retroactively to the legacy rows that will otherwise never self-heal (they are all closed and thus
rarely re-saved).

Goal outcome: shrink the `trades` `raw` payload from ~16.77 MB to ~0.15 MB (~112×), restoring
`localStorage.tj_trades` viability and making every `db.loadAll` hydration dramatically lighter — with
**zero** change to P/L, trade semantics, or the shipped save/render architecture.

## 2. Current state (P2-5-A/B/C already live)

- **P2-5-A (applied 2026-06-22):** private `trade-images` bucket; `storage.objects` RLS = SELECT-own +
  INSERT-own (no UPDATE/DELETE); 5 MB per-object cap; MIME allow-list `png/jpg/jpeg/webp/gif`; path shape
  `{uid}/{trade_id}/{pre|post}/{image_id}.{ext}` (first segment = `auth.uid()` = RLS anchor).
- **P2-5-B render resolver (shipped):** `preImages`/`postImages` stay plain string arrays; `data:` and
  `http(s)` render as-is; a strict Storage path is signed at render via the authenticated client
  (1 h TTL, in-memory cache). **Mixed base64/path/http arrays fully supported** — no field-shape change.
- **P2-5-C upload-on-commit (shipped):** `externalizeTradeImages(authUid, trade)` uploads `data:` refs →
  stores the path; runs inside the single-row durable saves (`commitClose`, `commitTradeWrite`); **new
  images only** (lazy). Authenticated client only — **no `service_role` in the browser**; `upsert:false`;
  **never drops** an image (keeps base64 on upload failure).
- **P2-5-E orphan sweep:** Phase-A inventory ran 2026-06-23 → `DEFER_PHASE_C / MONITOR_ONLY`.
- **Legacy set is bounded and non-growing:** new/edited image trades externalize automatically via
  P2-5-C, so only the pre-existing closed rows carry base64.

## 3. Dry-run evidence (2026-07-02, read-only)

| Metric | Value |
|---|---|
| Affected rows | 18 (all `closed`) |
| Base64 images | 37 (preImages 17 / postImages 20) |
| Base64 string payload | ~16.62 MB |
| Decoded/upload bytes | ~12.46 MB |
| Current whole `trades` raw payload | ~16.77 MB |
| Projected post-backfill payload | ~0.15 MB (**~112× reduction**) |
| MIME | 32 `image/png` + 5 `image/jpeg` → **37/37 in allow-list** |
| Size | **37/37 < 5 MB** (largest ~452 KB decoded) |
| Path simulation | 37 paths, **0 collisions** |
| Row complexity | straightforward 17 · caution 1 (MT5 provenance, not a blocker) · **blocked 0** |
| Partial-externalized rows | 0 (no mixed base64+path state) |
| `isMerged` / `subTrades` / `partialCloses` | none on the 18 rows |

**No blockers found.** Every image is eligible; every row is safely re-savable.

## 4. Execution vehicle decision

**Recommended: browser-authenticated driver reusing the shipped, module-level client functions.**

- Read affected rows read-only via the authenticated session (RLS-scoped `select=raw`), exactly as the
  v3 baseline snippet does.
- Per row, reuse the **already-shipped** code path:
  - `externalizeTradeImages(authUid, trade)` — module-level (`index.html:996`); returns the
    path-replaced trade (`{trade, uploaded, failed, skipped}`), keeping base64 on any upload failure.
  - Durable single-row save of the externalized trade via the **same save-first pattern** as
    `commitClose` / `commitTradeWrite` (`index.html:9338`, `9356`): `saveTradesSerialized(ext, {...})`
    when the driver runs inside the app; or the underlying module-level `db.saveTrade(authUid, ext)`
    (onConflict `id`, mock-guard + `affected===0` tripwire) when driven from a console dev routine.
- **No `service_role` in the browser.** Uploads/signs/saves use the authenticated anon client under RLS.

**Explicitly rejected / deferred:**
- ❌ `service_role` in the browser — never.
- ❌ Server/local `service_role` script — deferred; bypasses RLS, re-implements upload + `toTradeRow`
  (corruption risk), only worth it if the browser vehicle proves infeasible, and only under separate review.
- ❌ Full-array writer (`db.saveTrades`, retired in P2-4C) — never resurrected.
- ❌ Direct raw SQL `UPDATE` of `trades.raw` — never.
- ❌ Manual Storage upload without the durable per-row row update — never (would create a path with no
  referencing row, or a row with a dangling/absent path).

**Open sub-decision (see §13):** in-app dev-only gated routine (closure access to `saveTradesSerialized`
+ all guards) **vs** console-only dev routine (reuses module-level `externalizeTradeImages` +
`db.saveTrade`, no app-code change, runs against production today). Both reuse vetted code; the in-app
routine reuses the serialization/optimistic-token guards, the console routine avoids any code change.

## 5. Algorithm (pseudocode — design only, NOT runnable)

```
PRECONDITIONS (all must hold or STOP):
  - explicit user GO
  - valid authUid + non-expired session
  - fresh read-only dry-run: affected-row count and per-image eligibility re-confirmed
  - full-raw backup of the affected rows written locally (see §7) and verified readable

run_backfill(authUid):
  affected = read_only_fetch_rows_with_data_refs(authUid)          # RLS-scoped select=raw
  assert every image eligible (allow-list MIME, decoded < 5MB)     # else STOP
  for batch in chunks(affected, BATCH_SIZE=5):
    for trade in batch:
      if no data: refs remain in trade: skip (idempotent)
      ext, uploaded, failed, skipped = externalizeTradeImages(authUid, trade)
      if failed > 0: STOP (row keeps base64; report; do not save a partial-guessed state)
      if ext has any remaining data: ref: STOP (unexpected)
      res = durable_single_row_save(ext)          # saveTradesSerialized / db.saveTrade — SAVE-FIRST
      if not res.ok: STOP (base64 intact in DB; uploaded objects = orphans, monitored)
      reread = read_only_fetch_row(authUid, trade.id)
      assert reread.preImages/postImages are now storage-path refs (no data:)
      assert reread renders via P2-5-B resolver (paths sign OK)
      assert broker fields (brokerProfit/commission/swap/fee) unchanged   # see §9
      assert status still "closed", productId/direction unchanged
    report batch progress (counts only); PAUSE for continue/stop
  FINAL VERIFY:
    base64-bearing rows == 0
    total trades payload reduced toward ~0.15 MB
    P2-5-E orphan inventory acceptable
```

Batching + a continue/stop pause between batches bounds blast radius and lets the operator abort after
any anomaly.

## 6. Save-first / never-drop semantics

- An image's base64 is replaced by a path **only after a successful upload** (this is
  `externalizeTradeImages`'s existing behavior — on upload failure it keeps the base64).
- The row's `raw` is written **only** with the externalized object returned by
  `externalizeTradeImages`; the driver never hand-edits `raw`.
- **No image is removed from `raw` until its Storage path is saved and the re-read verifies the path.**
- If upload succeeds but the durable row save fails, the uploaded object becomes a harmless **orphan**
  (P2-5-E monitors; no deletion, immaterial). The row keeps its base64 in DB.
- The pre-run full-raw backup (§7) is **never deleted until the entire run is verified complete.**

## 7. Backup / export plan (mandatory, before any write)

- **Before the first write**, export the **full `raw`** of the 18 affected rows — **including base64** —
  to a **local** backup file. This is the recovery set if a Storage object is ever lost (after backfill,
  the Storage object becomes the sole copy of each image).
- The backup **contains image data → it MUST NOT be committed** and MUST NOT be logged/printed.
  Store it under a git-ignored/scratch location (e.g. the session scratchpad, or a
  `artifacts/image_externalization/_backups/` path added to `.gitignore`). Confirm it is untracked
  before proceeding.
- **Restore strategy outline:** to recover a row, take its pre-run `raw` from the backup and re-insert
  the original base64 into `preImages`/`postImages`, then durable-save that row (reverting it to the
  pre-backfill state). Because Storage objects are immutable and never deleted in v1, restore is only
  needed for the (unlikely) lost-object case.

## 8. Idempotency and retry

- **Skip refs already storage paths** (only `data:` refs are externalized) → re-running is safe.
- **Fresh `image_id` per upload** (`uid()`); `upsert:false` → no overwrite; unique filenames.
- A re-run processes **only remaining `data:` refs**; fully-externalized rows are no-ops.
- **STOP on any unexpected mixed/failure state** (e.g. a row that still has base64 after a reported
  success, or an upload failure) rather than guessing.
- Batch retry: after a STOP, fix the cause, re-run the fresh dry-run, and resume — the completed rows
  are skipped by the idempotency rule.

## 9. MT5 caution row

- Exactly **1** affected row (id `1778262155240`) carries MT5/broker fields.
- `externalizeTradeImages` rebuilds **only** `preImages`/`postImages`; it shallow-clones the trade and
  touches no other field. `brokerProfit` / `commission` / `swap` / `fee` are **not** modified.
- **Design validation must assert** (per-row re-read, §5/§10) that this row's broker fields are
  **byte-equivalent** before/after, so its P/L is provably unchanged. It is **not** a blocker.

## 10. Validation plan

**Before apply:** fresh read-only dry-run immediately before the run · Codex review (§12) · explicit
user authorization · backup written + verified (§7).

**During apply:** no `raw`/base64/note logs (counts only) · no secrets · **no `service_role` in
browser** · **no full-array save** · per-row re-read verification (paths present, renders via P2-5-B,
broker fields unchanged, status/productId/direction unchanged).

**After apply:**
- base64-bearing rows == 0.
- All externalized images render from Storage paths (P2-5-B signs successfully).
- All affected rows still `closed`; P/L unchanged; broker fields unchanged.
- `trades` payload reduced toward the projected ~0.15 MB.
- P2-5-E orphan inventory re-run → orphan volume acceptable.
- App hard reload renders 153 trades normally.
- Unrelated behavior (MT5 Inbox, hash routing, G2 mock, Dashboard/Positions/Journal) unaffected.

## 11. STOP conditions

STOP immediately (do not write / abort mid-run) on any of:
- any image with unsupported MIME or ≥ 5 MB decoded;
- missing/expired auth session or missing `authUid`;
- any Storage upload failure;
- any durable single-row save failure;
- re-read mismatch (row still has `data:` refs, or path refs missing);
- any broker field changed;
- any P/L change on an affected row;
- `raw` row missing a required field (`id`, `productId`, `status`, image arrays malformed);
- any attempt to use a full-array save or a non-durable write path;
- any `service_role` exposure in the browser;
- any row becoming unreadable/unrenderable after save;
- operator cancels between batches.

## 12. Codex review requirements

Before implementation/apply, Codex must review and approve:
- the driver loop (ordering, batching, save-first, STOP-on-error);
- the backup/restore plan (§7);
- idempotency + retry + STOP rules (§8, §11);
- confirmation of no `service_role`-in-browser, no full-array writer, no raw SQL, no base64 dropped.
No write run proceeds without Codex approval **and** explicit user authorization.

## 13. Open questions

- Batch size **5** vs smaller (e.g. 3 or 1) — smaller = finer abort granularity, slower.
- Keep the base64 backup **permanently local** vs delete after full post-apply verification.
- **In-app dev-only gated routine** (reuses `saveTradesSerialized` + all guards, needs a small gated
  index.html addition) **vs console-only dev routine** (reuses module-level `externalizeTradeImages` +
  `db.saveTrade`, no app-code change, runs against production today). Recommendation leans console-only
  for zero code change, pending Codex's view on guard reuse.
- Whether to produce a post-backfill closeout artifact (recommended: yes, metrics-only).

## 14. Recommendation

**READY_FOR_CODEX_REVIEW.** The dry-run found no blockers (37/37 eligible, 0 blocked, 0 collisions, 0
partial state, 1 non-blocking MT5 caution), the vehicle reuses shipped/vetted code with no
`service_role` in the browser, and the gates/STOP rules bound the risk. Proceed to Codex review of this
design; if approved, a fresh pre-apply dry-run + explicit user GO precede any write.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: ChatGPT should review the P2-5-D design and decide whether to send it to Codex review, defer, or request more design.
Next action: Do not write Storage or mutate trades until Codex review and explicit user authorization.
