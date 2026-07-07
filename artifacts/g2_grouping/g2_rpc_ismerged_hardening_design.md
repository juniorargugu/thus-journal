# G2 RPC-side `isMerged` Hardening — Design (audit-only)

**Date (local):** 2026-07-07
**Status:** **DESIGN ONLY — no SQL applied, no code changed.** A future gated DB/RPC migration.
**Scope:** add one defense-in-depth business error to `create_trade_group_v1` so it rejects legacy
merged rows (`raw->>'isMerged'` truthy). `ungroup_trade_group_v1` unchanged. UI already excludes merged
rows at the candidate layer (`b1f8e7d`, ROADMAP #184) — this closes the gap at the server.
**Source of truth for the current RPC:** [`../../migrations/20260705_g2_trade_group_rpcs.sql`](../../migrations/20260705_g2_trade_group_rpcs.sql).

> Defense-in-depth only. The write gate is off in production and the UI already filters `isMerged`
> candidates, so nothing merged can reach this RPC today. This guard makes the invariant hold at the
> data layer regardless of caller.

---

## 1. Repo state summary
- HEAD `69d7991`; `origin/main` `71283c3` (prod v3.22.0); 7 unpushed commits (2 code + 5 docs). Deploy ON HOLD.
- Tracked tree clean (only pre-existing untracked backups).

## 2. Findings from RPC inspection
`create_trade_group_v1(p_child_ids text[], p_label text)` — SECURITY DEFINER, `search_path=public,pg_temp`,
`auth.uid()`; returns json `{ok,…}`. Validation flow:
- **§0 input gates:** `invalid_child_ids` (null/empty array or element), `duplicate_child_ids`.
- **canonical sort → `too_few_children`** (< 2).
- **§1 lock** owned children `FOR UPDATE` in sorted id order.
- **§2 aggregate** over the locked owned rows — a single `SELECT count(*) FILTER (…) INTO …` computing
  found / open / grouped / missing_product / missing_direction / family-count / dir-count / family / direction.
- **§3 unconditional validations** (apply to BOTH re-click and create): `child_not_found`, `not_open`,
  `missing_product`, `missing_direction`, `family_mismatch`, `direction_mismatch`.
- **§4–5 idempotency:** sha256 membership key → if an ACTIVE group with that key exists, return
  `already_exists` (or `inconsistent_group_state`).
- **§6 create path only:** `already_grouped` (`v_grouped<>0`) → else insert group + `UPDATE trades SET group_id`
  (raw untouched — P/L invariant), owner-guard trigger validates each child.

Key facts:
- **`isMerged` is not a projected column** — it lives only in `raw` jsonb (`toTradeRow` writes `raw:t`; the app
  always sets a JS boolean `isMerged`, default `false`). So the check must read `raw->>'isMerged'`.
- §2 is the single natural place to add a merged count (rows are already locked there).
- Docs recording this deferred guard: [`merge_grouping_boundary_audit.md`](./merge_grouping_boundary_audit.md),
  pipeline Lane F, and the v0.4/write-gate closeouts.

## 3. Recommended SQL/RPC design (function-body change only)
Add one aggregate column + one DECLARE var + one §3 check. **No signature change, no new grants, no schema/table
change.** Exact edits to `create_trade_group_v1`:

1. **DECLARE:** add `v_merged int;`
2. **§2 aggregate** — add a FILTER column (and its INTO target). Crash-safe text comparison (see §4):
   ```sql
   count(*) FILTER (WHERE lower(btrim(coalesce(raw->>'isMerged',''))) = 'true')
   ```
   → into `v_merged`.
3. **§3 unconditional validations** — append after `direction_mismatch`:
   ```sql
   IF v_merged <> 0 THEN
     RETURN json_build_object('ok', false, 'error', 'merged_child_not_allowed');
   END IF;
   ```

**Placement (Q1, Q3): unconditional in §3, i.e. BEFORE the idempotency branch and BEFORE §6 `already_grouped`.**
Rationale: a merged row must never be validated into ANY group operation. This is safe because prod currently
has **0 active groups / 0 grouped trades** and every future group is created under this guard, so no active
group can contain a merged member for the re-click path to trip on. (Alternative: place the check on the
create path in §6 next to `already_grouped` to preserve idempotent re-click for hypothetical legacy groups —
rejected as weaker; noted for completeness.)

## 4. Proposed error code + later UI mapping
- **Error code (Q2): `merged_child_not_allowed`** — `{ok:false, error:'merged_child_not_allowed'}`.
- **Detection (Q4, Q5, Q6): crash-safe text compare**, treating only an explicit truthy as merged:
  `lower(btrim(coalesce(raw->>'isMerged',''))) = 'true'`.
  - `raw` null / key absent / value `false` / `null` → extracts to `''` or `'false'` → **allowed**.
  - JSON boolean `true` → `raw->>'isMerged'` yields text `'true'` → **rejected**.
  - Never throws (unlike `(raw->>'isMerged')::boolean`, which errors on non-boolean text like `"yes"`/`1`).
  - Alternative considered: jsonb compare `raw->'isMerged' = 'true'::jsonb` (matches only a JSON boolean true).
    Equivalent for this data (app writes a JS boolean); text-compare chosen for crash-safety on legacy garbage.
- **Later UI mapping (a separate, tiny future `index.html` change — NOT this task):** add to `_G2_CREATE_ERR`:
  `merged_child_not_allowed: "มี leg ที่เป็น merged position — จับกลุ่มไม่ได้"`.
  **No ordering dependency:** until mapped, `_g2MapCreateError` already falls back to the generic
  "สร้างกลุ่มไม่สำเร็จ" for unknown codes, so shipping the RPC before the mapping does not break the UI.

## 5. Test plan (negative + regression, all in SQL Editor `BEGIN … ROLLBACK`, simulated `auth.uid`, no persistent writes)
- **Negative — merged child:** one child `raw->>'isMerged'='true'` (other valid, same family/dir, open) → `merged_child_not_allowed`.
- **Negative — mixed:** 1 merged + 1 non-merged (same family/dir) → `merged_child_not_allowed` (single code; not per-child, matching existing first-failure model).
- **Allowed — isMerged false:** both children `isMerged=false` → proceeds → creates group (or normal validation).
- **Allowed — isMerged absent:** children with no `isMerged` key in `raw` → allowed.
- **Allowed — raw null:** child with `raw IS NULL` → allowed (no throw).
- **Boolean vs string:** JSON boolean `true` and (if present) string `"true"` → both rejected via text compare.
- **Regression — already_grouped:** non-merged children already in another active group → still `already_grouped` (unaffected; merged check passes with 0).
- **Regression — duplicate_child_ids:** duplicated input still returns `duplicate_child_ids` first (§0 precedes §2).
- **Regression — happy path:** 2 valid non-merged open same family/dir → group created.
- **Regression — idempotent re-click:** same non-merged membership as an active group → `already_exists`.
- **Regression — ungroup:** `ungroup_trade_group_v1` on a group → archives + clears children (Q9: unchanged, unaffected).

## 6. Rollback plan
- The change is a single `CREATE OR REPLACE FUNCTION create_trade_group_v1(text[],text)` — **function-body only**;
  identical signature, grants unchanged, no schema/table/data migration.
- **Apply inside a transaction** in the SQL Editor; run the §5 tests; `COMMIT` only if all pass, else `ROLLBACK`.
- **Rollback = re-apply the prior body**, which is preserved verbatim in git at
  `migrations/20260705_g2_trade_group_rpcs.sql` (lines 137–287). A `CREATE OR REPLACE` with the old body restores
  the exact previous behavior instantly, with zero data risk (no rows touched by the definition change).
- Package as a new migration file (e.g. `migrations/2026MMDD_g2_create_ismerged_guard.sql`) containing the full
  replaced function + a commented rollback block, mirroring the existing migration's structure.

## 7. Recommended sequencing: **AFTER_V04_DEPLOY**
- Pure DB/RPC change, independent of the v0.4 UI batch (index.html only) → it does **not** block deploy and must
  **not** expand the v0.4 batch.
- No production urgency: write gate is off + UI already excludes merged rows, so no merged create can occur until
  the write flag is enabled (itself gated, post-deploy).
- **Land it before the write gate is enabled for real use** (it is a pre-write-gate guard). Order:
  v0.4 deploy → default-off smoke → **apply this RPC hardening (gated SQL Editor, BEGIN/ROLLBACK tested)** →
  write-flag enable + keep a real group.

## 8. Explicit non-goals
No UI/index.html change in this task (the `_G2_CREATE_ERR` mapping is a separate future micro-edit); no
`ungroup_trade_group_v1` change; no signature/grant/schema/table change; no data backfill; no per-child error
enumeration; no change to existing error codes or the idempotency/already_grouped semantics; no SQL applied here.

## 9. Confirmations
This task created one docs file only (no other edits). No code changes. No SQL applied. No DB/RPC/Supabase
writes. No flags enabled. No push/deploy. Prod unchanged at `71283c3` / v3.22.0.

## 10. Next step routing
**SEND_TO_CHATGPT_REVIEW** — review this RPC hardening design before it becomes a migration. Confirm: (a)
crash-safe `lower(btrim(coalesce(raw->>'isMerged','')))='true'` detection (false/null/absent all allowed); (b)
unconditional §3 placement is safe given 0 active groups today; (c) one new `merged_child_not_allowed` code, no
other contract change; (d) function-body-only replace with git-preserved rollback; (e) sequence AFTER_V04_DEPLOY,
before write-gate enable. On approval, package as a gated migration + BEGIN/ROLLBACK test run (Junior's SQL Editor).
