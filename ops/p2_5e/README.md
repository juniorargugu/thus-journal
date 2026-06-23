# P2-5-E Phase A — `trade-images` Orphan Inventory (READ-ONLY)

Out-of-band **admin** tool. Run **locally on Junior's PC only**. It reports orphaned
objects in the private `trade-images` Storage bucket. It **never deletes, uploads,
or modifies anything** — deletion is a separate, gated **Phase C**.

## What it does
1. Reads every `trades` row's `raw` (service_role bypasses RLS) and builds the
   **exact-path reference set**.
2. Recursively **lists** objects in `trade-images` (read-only enumeration).
3. Classifies each object and prints a counts + capped-sample report.

## What it never does (Phase A has no deletion path)
- No object delete / upload / overwrite / move.
- No SQL, no schema/policy change, no Supabase writes of any kind.
- No image-content download; no logging of raw JSON or signed URLs (paths only, capped).
- Only network calls: `GET /rest/v1/trades` and `POST /storage/v1/object/list/trade-images` (read-only).

## The orphan predicate (the reviewed design lock)
An object is an **orphan-candidate** only if its **exact path string** is referenced by
**no** `trades` row anywhere. It is **not** decided by "the `{tradeId}` folder segment no
longer has a trade" — `handleDuplicate` copies image **path** refs into a *new* trade id
(and `externalizeTradeImages` skips existing paths), so one object can be referenced by a
trade whose id differs from the path's `tradeId` segment. Folder/id-existence would delete a
**live** image; exact-reference never does.

## Requirements
- Node ≥ 18 (Junior's PC has v24). Zero npm dependencies (uses global `fetch`).
- Env vars (same names already set on this PC; same project `wtfwynvvkiuottjnmozu`):
  - `SUPABASE_URL`
  - `SUPABASE_SERVICE_KEY` (service_role — **local/admin only; never ship to browser/Netlify/app runtime**)

## Run
```sh
# from the repo root
node ops/p2_5e/orphan_inventory.mjs

# write the report to a local JSON file as well (paths only — no secrets)
node ops/p2_5e/orphan_inventory.mjs --out artifacts/image_externalization/p2_5e_inventory_$(date +%Y%m%d).json

# retention is 7 days and is the policy floor for live cleanup; values < 7 are clamped to 7
node ops/p2_5e/orphan_inventory.mjs --retention-days 7
```

## Reading the report
- **referenced (LIVE)** — object's exact path is in some trade row. Never a candidate.
- **orphan-candidates → retention-passed (≥7d)** — unreferenced and old enough that a future
  Phase C cleanup *would* consider them. (Phase A still deletes nothing.)
- **orphan-candidates → within-retention (<7d)** — unreferenced but too new; Phase C would skip
  them (guards against racing a just-uploaded object whose row hasn't landed/synced yet).
- **malformed (report-only)** — object name doesn't match the strict 4-segment convention.
  **Never** an auto-delete candidate — investigate manually if it ever appears.

## After running
- Save/share the report. If orphan counts/bytes are immaterial, **stay deferred** (monitor only).
- Phase C (actual deletion) is a **separate** service_role script with `--dry-run` default,
  pre-delete re-verification, retention enforcement, small batches, and a fresh review **before**
  implementation. It is intentionally **not** in this directory yet.
