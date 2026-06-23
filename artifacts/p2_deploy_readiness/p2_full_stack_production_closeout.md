# THUS Journal — P2 Full-Stack Production Closeout

**Status:** `P2_FULL_STACK — DEPLOYED & VERIFIED IN PRODUCTION`

**Date:** 2026-06-23 (Asia/Bangkok)
**Production URL:** https://thus999.com

---

## 1. What happened

The P2 full-stack persistence-durability + image-externalization track is **live in production**. The validated local-only stack was pushed to `origin/main`, Netlify auto-deployed, and production was verified to be serving exactly the committed HEAD.

| Item | Value |
|---|---|
| Production `origin/main` | `ba532be` — *"docs: record P2 full-stack burn-in pass"* |
| Previous production baseline | `2c2c8d2` — *"feat: add DELTA stock product preset"* |
| Deploy mechanism | Push to `main` → Netlify auto-deploy → https://thus999.com |
| Netlify deploy | **Published** (`Server: Netlify`, `X-Nf-Request-Id: 01KVSVPG2Z1ATT6WHH70Y4Y8N9`) |

## 2. Commit range deployed

`2c2c8d2..ba532be` — 16 commits:

```
6509a0c docs: add product foundation deploy closeout
9a782bb docs: add MT5 auto draft import design plan
3e84db1 fix: make position merge durable
c0ae3f0 refactor: decouple merge local removal
4e205f6 fix: make standalone trade deletion durable
fec6d2d fix: make trade duplication durable
259381e fix: make trade import durable
d58242f refactor: remove dead merge autosave path
bf0f71d fix: narrow trades autosave to reconcile only
8e968a2 docs: add trade image storage policy pack
92ba315 feat: add trade image render resolver
3fe4ec6 docs: record trade image storage apply
0a6dd43 feat: externalize trade images on save
9e8e32b docs: record P2-5-C image smoke pass
00f02e7 refactor: retire full-array trades writer
ba532be docs: record P2 full-stack burn-in pass
```

## 3. What shipped

- **Durable single-row writes** for every trade mutation: open / draft / draft-execute / close / edit / delete / duplicate / import / merge — all via `db.saveTrade` (single-row, `.select("id")`-verified) or `db.deleteTrades` (batch delete by id).
- **Autosave narrowed to ids-only reconcile** — `source:"autosave_reconcile"` → `db.reconcileDeletedTrades` (shrink-only, bounded by known ids, never resurrects). No more full-array trade payload on autosave.
- **Full-array `db.saveTrades` writer retired** (P2-4C) — method removed; an impossible-path attempt fails loud via the `fullarray_retired` guard. This eliminates the recurring `57014` statement-timeout / 500 on the ~11 MB base64-image autosave payload.
- **Image externalization** on save — base64 trade images uploaded to the **private** Supabase Storage bucket `trade-images`, path `{authUid}/{tradeId}/{pre|post}/{imageId}.{ext}`, authenticated client only (no `service_role`), `upsert:false`, RLS SELECT/INSERT-own.
- **Rows store Storage path strings** — `raw.preImages[]` / `raw.postImages[]` hold the path, **never** base64 / signed URL / public URL. Failed uploads keep the original ref (never lose an image); already-externalized paths are skipped (idempotent, no duplicate uploads).
- **Signed-URL render resolver** live — `ResolvedImage` signs a Storage path → short-lived signed URL at render time (1h TTL, in-memory cache); remains format-agnostic (still renders legacy base64 / http refs).

## 4. Verification

| Stage | Result |
|---|---|
| Preflight (branch / HEAD / exact 16-commit range / no drift / clean tree / known untracked only) | ✅ PASS |
| Push `2c2c8d2..ba532be main -> main` | ✅ succeeded; `origin/main` = `ba532be` |
| Netlify deploy | ✅ published; `Cache-Control: must-revalidate` on `index.html` (no stale CDN) |
| Production content match | ✅ production HTML **byte-identical** to committed HEAD `index.html` (542,498 bytes, LF) |
| New-stack markers live in production | ✅ `externalizeTradeImages`, `fullarray_retired`, `autosave_reconcile`, `ResolvedImage`, `trade-images` |
| User-side view-only runtime smoke (positions render, image resolver, console clean) | ✅ user reported all good |

Pre-deploy gates already recorded: P2-5-A Storage policy applied (`p2_5a_storage_policy_pack.md`), P2-5-C image smoke PASS (`p2_5c_disposable_smoke_result.md`), P2 full-stack burn-in PASS (`p2_full_stack_burn_in_result.md`).

## 5. Safety confirmation (deploy)

- ✅ **No real trade modified** during deploy (git + read-only verification only).
- ✅ **No SQL run** during deploy; no Supabase schema / policy / data change.
- ✅ **No file upload** during deploy.
- ✅ **Known untracked files remained untracked** (`.claude/`, `.gitignore`, `RESOURCE_AUDIT.md`, `archive/`, 2 close-bug backups, merge baseline) — none staged, none pushed.
- ✅ App runtime code unchanged by the closeout (this artifact is docs-only).

## 6. Remaining non-blocking backlog

- **P2-5-E** — Storage orphan-sweep strategy (deletes / removed images / save-failures leave orphan objects by design; v1 has no eager Storage deletion). Independent of deploy.
- **UI backlog** — add / replace images on an already-**open** position (parity with the detail-modal edit path).
- **UI backlog** — clickable / lightbox detail thumbnail (open a larger preview on click).

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_FYI
Reason: P2 production closeout is recorded.
Next action: Choose next backlog item: P2-5-E orphan sweep, add images to already-open position, or clickable/lightbox detail thumbnail.
