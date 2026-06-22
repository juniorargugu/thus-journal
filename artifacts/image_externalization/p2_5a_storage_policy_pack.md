# P2-5-A — Image Externalization: Supabase Storage Policy Pack

**Status:** `P2_5A_STORAGE_POLICY_PACK — DRAFT / NOT APPLIED`

Drafted 2026-06-22 BKK. **SQL drafted only. No SQL was executed. No bucket was created.**
No Supabase write. No app code touched. No deploy. No push. No restart. No objects uploaded.

> ⚠️ **DO NOT RUN ANY SQL IN THIS FILE WITHOUT AN EXPLICIT WRITTEN "GO" FROM JUNIOR.**
> This pack only *prepares* the private `trade-images` Storage bucket + RLS. Creating the bucket and
> policies does **not** make the app write anything — app reads/writes arrive later in P2-5-B / P2-5-C.

This is the draft Junior reviews **before** opening the Supabase SQL Editor. Approve in writing
(a follow-up "run P2-5-A" task) or send back revisions.

---

## 1. Executive summary

| Item | Value |
|---|---|
| Supabase project | `wtfwynvvkiuottjnmozu` |
| Bucket proposed | `trade-images` |
| Bucket visibility | **private** (public rejected — see §3) |
| SQL applied? | **No.** Draft only. |
| App code changes? | **None.** |
| Supabase changes? | **None.** |
| Deploy / push / restart? | **None.** |
| New policies proposed | **2** — `storage.objects` SELECT + INSERT (authenticated, own-folder) |
| UPDATE / DELETE policies | **None in v1** (drafted but commented out, see §5) |
| Stored ref format | storage **path** string, `{user_id}/{trade_id}/{pre\|post}/{image_id}.{ext}` |
| Idempotent? | Yes — bucket `on conflict do nothing`; policies `drop policy if exists` then `create`. Safe to re-run. |
| Rollback included? | Yes — §7. |
| Verification queries included? | Yes — §6 (SELECT-only + manual two-user checks). |
| Enables app writes by itself? | **No.** Render resolver (P2-5-B) and upload-on-commit (P2-5-C) are separate, later, gated. |

This pack does **only** the minimum the approved P2-5 design calls for and stops. Nothing here is exploratory.

---

## 2. Context

- Trade screenshots currently live **inline as base64** in the `preImages` / `postImages` string arrays,
  stored inside the JSONB `raw` column of each `trades` row (`toTradeRow` → `raw:t`). They are
  **RLS-protected today** (only the owning user can read the trade row).
- **P2-4B** (`bf0f71d`) removed base64 from the full-array autosave path — that path is now ids-only
  delete reconcile, no upsert, no base64, no 57014 risk.
- **Remaining base64 risk:** the single-row durable saves (`commitOpen` / `commitClose` /
  `commitUpdateTrade` via `commitMeta`) still embed base64 in `raw` when an image-bearing trade is
  created/closed/edited. Bounded to one row (~≤1.5 MB), so no statement timeout, but it bloats the row.
- **P2-5** externalizes images to a private Supabase Storage bucket and stores **path refs** instead
  of base64. This pack (**P2-5-A**) prepares the bucket + RLS only.

---

## 3. Design decisions

- **Bucket name:** `trade-images`.
- **Bucket is private.** A public bucket is **rejected**: the current base64 images are RLS-protected
  inside the owner-scoped trade row, so a public bucket (security-by-unguessable-UUID ≠ access control)
  would be a **privacy downgrade** for the user's private trading screenshots.
- **Stored refs are storage path strings, NOT signed URLs.** Paths are stable; signed URLs expire.
  The app render resolver (P2-5-B) turns a path into a short-lived signed URL at display time.
- **Path convention:** `{user_id}/{trade_id}/{pre|post}/{image_id}.{ext}`
  - first segment = `auth.uid()::text` → the RLS anchor (`storage.foldername(name))[1]`).
  - `{trade_id}` is available at upload time (the trade `id` is assigned client-side before the durable commit; drafts already have ids).
  - `{image_id}` = a fresh `uid()` per image → **unique filenames**, no overwrite.
  - `{pre|post}` is a fixed literal segment chosen by the app, never user free-text.
- **Minimum v1 policies:** **SELECT + INSERT only.**
- **No UPDATE / DELETE / upsert in v1.** New images are immutable once uploaded; removing an image
  from a trade only drops the *ref* from the array (the object is left as a cheap orphan).
- **No eager cleanup in v1.** Orphan sweep is a later, separate, gated phase (P2-5-E).
- **Mixed array support (app side, later):** `data:` (legacy) and `http(s)://` pass through render
  untouched; anything else is treated as a storage path → signed at render. No field-type migration.

---

## 4. Safety constraints

- **No `service_role` key in the browser.** All uploads/signs use the existing authenticated anon
  client under RLS. The `service_role` key is never shipped to the client.
- **Authenticated only.** Both policies are `to authenticated`; `anon` gets nothing.
- **Ownership = first path segment must equal `auth.uid()::text`** (`(storage.foldername(name))[1]`).
  A user can neither read nor write outside their own `{user_id}/…` folder.
- **Sanitize app-side (enforced in P2-5-C, restated here as the upload contract):**
  - `trade_id` and `image_id` are app-generated ids — emit only `[A-Za-z0-9_-]`; never pass raw
    user text into the path.
  - extension restricted to a known image allow-list (`png`, `jpg`, `jpeg`, `webp`, `gif`).
  - the only path separators are the **fixed** segments above; no user-controlled `/`.
- **MIME allow-list** at the bucket: only image types (`image/png`, `image/jpeg`, `image/webp`,
  `image/gif`).
- **Max file size guidance:** bucket `file_size_limit` = **5 MB** per object (charts are small; this
  is a generous ceiling that still blocks accidental huge uploads).
- **Unique filenames only / no overwrite / no upsert** — `{image_id}` guarantees uniqueness; there is
  no UPDATE policy, so an upsert/overwrite attempt is denied by RLS.

---

## 5. Proposed SQL (DRAFT — DO NOT RUN WITHOUT GO)

> Run in the Supabase SQL Editor for project `wtfwynvvkiuottjnmozu` **only after written approval**.
> Every block is idempotent and safe to re-run. This creates the bucket + 2 policies and nothing else.

```sql
-- ============================================================================
-- P2-5-A  trade-images  PRIVATE Storage bucket + RLS (SELECT + INSERT only)
-- DRAFT / NOT APPLIED. Do not run without an explicit written GO from Junior.
-- Project: wtfwynvvkiuottjnmozu
-- ============================================================================

-- 1) Bucket: private, image MIME allow-list, 5 MB cap. Idempotent (no-op if it exists).
--    public=false  → objects are NOT publicly readable; access is governed by the policies below
--                    and short-lived signed URLs minted by the owning user (P2-5-B).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'trade-images',
  'trade-images',
  false,
  5242880,  -- 5 MB
  array['image/png','image/jpeg','image/webp','image/gif']
)
on conflict (id) do nothing;

-- 2) SELECT policy — a user may read ONLY objects whose first path segment is their own uid.
--    Path shape: {user_id}/{trade_id}/{pre|post}/{image_id}.{ext}
--    (storage.foldername(name))[1] = the {user_id} segment.
drop policy if exists "trade-images select own" on storage.objects;
create policy "trade-images select own"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'trade-images'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

-- 3) INSERT policy — a user may upload ONLY into their own {user_id}/… folder.
--    with check enforces ownership at write time; no UPDATE policy ⇒ no overwrite/upsert.
drop policy if exists "trade-images insert own" on storage.objects;
create policy "trade-images insert own"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'trade-images'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

-- ----------------------------------------------------------------------------
-- 4) NOT v1 — UPDATE / DELETE policies are intentionally OMITTED.
--    v1 is append-only: removing an image from a trade drops the ref from the
--    array and leaves the object as a cheap orphan (orphan sweep = later P2-5-E).
--    If/when eager cleanup is approved, add scoped own-folder policies like:
--
-- drop policy if exists "trade-images delete own" on storage.objects;
-- create policy "trade-images delete own"
-- on storage.objects
-- for delete
-- to authenticated
-- using (
--   bucket_id = 'trade-images'
--   and (storage.foldername(name))[1] = (select auth.uid()::text)
-- );
--
-- (An UPDATE policy is deliberately NOT planned — immutable objects + unique
--  filenames mean overwrite is never needed.)
-- ============================================================================
```

---

## 6. Validation queries / checklist (run AFTER an approved apply)

**SELECT-only verification (safe, read-only):**

```sql
-- a) Bucket exists and is PRIVATE (public must be false).
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'trade-images';
-- expect: public = false, file_size_limit = 5242880, image-only mime list.

-- b) Exactly the two intended policies exist on storage.objects for this bucket.
select policyname, cmd, roles
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
  and policyname like 'trade-images %'
order by policyname;
-- expect: "trade-images insert own" (INSERT), "trade-images select own" (SELECT).
-- expect NO update/delete policy for trade-images in v1.

-- c) No public bucket slipped in.
select count(*) as public_trade_images
from storage.buckets where id = 'trade-images' and public = true;
-- expect: 0
```

**Manual two-user ownership checks (do with two test accounts; do NOT use real production data):**

- [ ] Bucket exists and `public = false`.
- [ ] SELECT policy `trade-images select own` exists.
- [ ] INSERT policy `trade-images insert own` exists.
- [ ] No UPDATE / DELETE policy on `trade-images` (unless a later phase intentionally added one).
- [ ] User A can upload to `A_uid/.../img.png` (own first segment) → **allowed**.
- [ ] User A cannot upload to `B_uid/.../img.png` → **denied** by `with check`.
- [ ] User A can read/sign `A_uid/...` objects → **allowed**.
- [ ] User A cannot read/sign `B_uid/...` objects → **denied** (empty / 403).
- [ ] Path format examples are valid:
  - `5b1f.../8830/pre/9c2a....png`
  - `5b1f.../mrg_171.../post/0f3e....webp`

---

## 7. Rollback notes

Rollback is **safe before any objects are uploaded**. After the app starts writing path refs into
trades (`P2-5-C`), the bucket holds real images referenced by rows — **do NOT delete the bucket then**.

```sql
-- Drop the policies (safe any time; only removes access rules).
drop policy if exists "trade-images select own" on storage.objects;
drop policy if exists "trade-images insert own" on storage.objects;

-- Remove the bucket ONLY if it is empty AND no app refs exist yet.
-- (Will error if objects remain — that is the intended guard.)
delete from storage.buckets where id = 'trade-images';
```

- ⚠️ **Do not delete the bucket once P2-5-C has shipped** — trade rows would hold dangling path refs.
- Dropping the policies without deleting the bucket simply removes access; objects (if any) remain
  but become unreadable until policies are re-created.

---

## 8. App implementation gates (future phases — NOT enabled by this pack)

- **P2-5-A (this pack):** create private bucket + SELECT/INSERT RLS. **Does not enable app writes.**
- **P2-5-B (app, render resolver):** add `resolveImageSrc(ref)` — `data:` / `http(s)://` pass through;
  otherwise treat as a storage path → mint a short-lived signed URL at render. Additive, no data change.
- **P2-5-C (app, upload-on-commit):** `externalizeImages(trade)` uploads `data:` entries → stores the
  path ref → runs inside the single-row durable saves; **new images only**, save-first semantics
  (on upload failure keep base64 + report; never lose an image).
- **P2-5-D (optional):** lazy migration of legacy base64 on next edit.
- **P2-5-E:** orphan-sweep cleanup (separate, gated).
- **P2-4C (separate):** final `db.saveTrades` / full-array retirement — **not bundled with P2-5.**

> P2-5-A alone changes no app behavior and writes no data. Applying it is inert until P2-5-B/C ship.

---

## 9. STOP / GO checklist

**STOP — do not apply if any is true:**

- [ ] Junior has **not** given an explicit written GO to apply Supabase changes.
- [ ] The bucket would be **public**.
- [ ] A `service_role` key would be needed in the browser.
- [ ] The policy cannot enforce **first folder = `auth.uid()::text`**.
- [ ] The SQL would grant broad / cross-user access (anything beyond own-folder SELECT+INSERT).
- [ ] Applying would **conflict with existing storage policies** (check `pg_policies` for prior
      `trade-images` or overlapping `storage.objects` policies first).

**GO — proceed to apply only when ALL are true:**

- [ ] Written GO received.
- [ ] Bucket `public = false`, image MIME allow-list, 5 MB cap.
- [ ] Exactly SELECT + INSERT policies, both own-folder scoped.
- [ ] No `service_role` in client.
- [ ] Verified no conflicting pre-existing `trade-images` policies.
- [ ] Applied to a non-destructive create-only step (no existing bucket/policy overwrite).

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Storage policy pack requires review before any Supabase apply.
Next action: Review the SQL/policy pack; if approved, decide whether to apply P2-5-A or first implement P2-5-B render resolver.
