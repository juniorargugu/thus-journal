# P2-5-E — Phase A: Storage Orphan Inventory (READ-ONLY) — Implementation Record

**Status:** `P2_5E_PHASE_A — IMPLEMENTED (read-only); NOT YET RUN`

**Date:** 2026-06-23 (Asia/Bangkok)
**Review lineage:** P2-5-E strategy audit → ChatGPT `PASS_WITH_CHANGES` → `READY_FOR_PHASE_A_IMPLEMENTATION` → this build.

---

## 1. What was built

A zero-dependency Node ESM **admin** script + runbook that produces a **read-only** orphan
inventory for the private `trade-images` Storage bucket. No deletion path exists in it.

| File | Purpose |
|---|---|
| `ops/p2_5e/orphan_inventory.mjs` | Read-only inventory/dry-run script (GET trades + read-only Storage list → classify → report) |
| `ops/p2_5e/README.md` | Runbook: env, usage, report interpretation, Phase C boundary |

## 2. Design choices (recorded)

- **Runtime:** zero-dependency Node ESM (`.mjs`) using global `fetch` (Junior's PC has Node v24); no `package.json`/npm install — matches the repo's zero-build posture.
- **Auth/env:** reads `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` (service_role) from env — the names already set on Junior's PC; same project `wtfwynvvkiuottjnmozu`. **Local/admin only — never shipped to browser/Netlify/app runtime.**
- **Execution:** authored here; **Junior runs it locally**. Not run from CI/agent (no service_role in this environment; and the established pattern is user-run for anything touching production).

## 3. Reviewed design locks honored

- **Exact-path-reference predicate** (the key lock): orphan = "no trade row references the exact path," **never** "the `{tradeId}` folder segment no longer has a trade." Rationale: `handleDuplicate` (index.html 3492–3494) copies image **path** refs into a new trade id and `externalizeTradeImages` (969) **skips** existing paths → one object can be referenced by a trade whose id ≠ the path's `tradeId` segment. Folder/id existence would delete a **live** image.
- **Full-`raw` defensive scan** — scans the stringified `raw` JSON (not just `preImages`/`postImages`) for strict-path matches. (A literal `.` before the ext and the `_`/`-` charset never occur inside standard base64, so scanning raw incl. base64 yields no false refs.)
- **URL-embedded path extraction** — also harvests paths inside any `…/trade-images/<path>` URL, `decodeURIComponent`-decoded with query/fragment stripped, before exact matching (defensive; rows shouldn't hold URLs).
- **Exact, case-sensitive** object-name comparison; extension match is case-insensitive for **classification** only.
- **Retention window = 7 days**, enforced as a **floor** (values < 7 clamped + warned). Unknown object age → treated as within-retention (conservative).
- **Malformed object names → report-only forever** (never an auto-delete candidate).
- **Browser stays append-only** — no DELETE policy proposed; no app-runtime deletion. Unchanged.
- **No image-content download; no logging of raw JSON or signed URLs**; sample paths only, capped (20/category).

## 4. Read-only verification (at build time)

- `node --check ops/p2_5e/orphan_inventory.mjs` → **PARSE OK**.
- Mutation-call token scan (`.remove(` / `.upload(` / `.move(` / `.copy(` / `.insert(` / `.rpc(` / `.createSignedUrl(`) → **0 each**.
- Only HTTP method literal present: a single `POST` — the **read-only** Storage `list` endpoint. Trades read is a default `GET`.
- Endpoints touched: `/rest/v1/trades` (GET) and `/storage/v1/object/list/trade-images` (read-only enumeration) only.

## 5. Classification emitted by the report

| Bucket | Meaning | Phase C action (future) |
|---|---|---|
| referenced (LIVE) | exact path found in some trade row | never delete |
| orphan-candidate · retention-passed (≥7d) | unreferenced, old enough | eligible (gated, re-verified) |
| orphan-candidate · within-retention (<7d) | unreferenced, too new | skip (race guard) |
| malformed (report-only) | name off-convention | never auto-delete |

## 6. Status & next steps

- **Phase A is read-only and complete as code.** It has **not** been run (no production read executed from here).
- **Next (Junior):** run it locally per `ops/p2_5e/README.md`; review counts/bytes.
  - If orphans are immaterial → **stay deferred** (monitor only).
  - If material → design **Phase C** as a *separate* service_role deletion script (`--dry-run` default, pre-delete re-verify, retention enforced, small batches, full path log) and get a **fresh review before** implementing it. Phase C is intentionally not in `ops/p2_5e/` yet.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_FYI
Reason: P2-5-E Phase A read-only inventory tool is implemented (not yet run); no deletion path, no policy change, browser stays append-only.
Next action: Junior runs the inventory locally and reviews the report; decide defer-vs-Phase-C based on real orphan volume.
