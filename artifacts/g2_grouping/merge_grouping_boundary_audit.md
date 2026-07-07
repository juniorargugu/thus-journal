# Merge ↔ Grouping Boundary Audit

**Date (local):** 2026-07-07
**Type:** Read-only audit (code + git-tracked docs). No code/DB/deploy changes.
**HEAD at audit:** `91a2156` (local, ahead of `origin/main` by 10, unpushed).

## Audit scope

Confirm that, before the batch deploy of the local stack (which includes the G2 grouping
UI), the app does not confuse — or cross-wire — two distinct concepts:

- **Legacy Merge** — destructive/manual; collapses multiple trade rows into one `isMerged`
  row with `subTrades`/`mergedFromIds`. Two historical forms (see F1).
- **G2 grouping** — non-destructive; associates open rows via a projected `group_id`
  (+ `trade_groups`); reducers walk `raw` and ignore `group_id`, so P/L is unchanged.

## Code paths inspected

| Area | Location |
|---|---|
| Legacy row-collapsing Merge (removed) | comments at [index.html:4129-4133](../../index.html#L4129-L4133), [4212-4217](../../index.html#L4212-L4217) |
| Durable merge entry point (disabled) | [index.html:3015-3020](../../index.html#L3015-L3020) (`🔗` button, `disabled`, no onClick) |
| Durable merge state/handlers | `mergeMode`/`mergeSym`/`mergeIds` [3712-3714](../../index.html#L3712), `handleMerge` [3759](../../index.html#L3759), `startMerge` [3791](../../index.html#L3791), banner [3906-3919](../../index.html#L3906) |
| Durable merge writer | `commitMerge` [index.html:9695-9740](../../index.html#L9695-L9740) |
| Merged-trade display/close (existing rows) | `MergedCloseForm` [2201](../../index.html#L2201), badges [2515](../../index.html#L2515)/[2944](../../index.html#L2944)/[4289](../../index.html#L4289) |
| G2 grouping preview/proposal/create | `buildGroupingPreview` [3536](../../index.html#L3536), `GroupingPreview` (create-only, write-gated), flags `tj_trade_group_ui_v01` / `tj_trade_group_write_v01` |
| Persistence omission of group_id | `toTradeRow` [213-221](../../index.html#L213-L221), `db.loadAll` `select("raw")` [228](../../index.html#L228) |
| Design contract | `ROADMAP.md` "Future: Trade Grouping" + "Trade Grouping Design Locked — 2026-05-20" (esp. items #177, #182-184) |

## Findings (answers to the audit questions)

**F1 — Two historical "merge" concepts.** The old **row-collapsing** Merge (P2-4A) was
deleted as dead code (it double-counted realized P/L via `_hiddenByMerge`, written but never
read). A separate **durable** `commitMerge` (merged-first + source-delete + repair-on-load)
exists in code.

**F2 — Legacy destructive Merge is NOT reachable in the UI.** The only entry control is the
`🔗` button at [3018](../../index.html#L3018), which is `disabled` and has **no `onClick`**.
`onMergeStart` is passed to `PositionCard` ([3955](../../index.html#L3955)) but is never
invoked by any live control (the only other pass is a no-op at [3985](../../index.html#L3985)).
So `startMerge → mergeMode=true` never fires, the merge banner never renders, and
`handleMerge`/`commitMerge` are unreachable. *(Existing `isMerged` rows from before Merge was
disabled still display and can be closed via `MergedCloseForm` — display/close of prior data,
not creation of new merges.)*

**F3 — Disabled wording is clear enough.** The button is dimmed (`opacity-40 cursor-not-allowed`)
with tooltip *"Merge ปิดชั่วคราว — กำลังรอ feature ใหม่ที่ไม่ลบ note ของแต่ละไม้"* and an explicit
code comment: *"Do not re-enable… Future replacement should be non-destructive logical grouping
via group_id/trade_groups."* Minor: the label is a bare dimmed `🔗` (tooltip only on hover).

**F4 — No merge path writes `group_id` or `trade_groups`.** `commitMerge` persists rows through
`saveTradesSerialized → db.saveTrade → toTradeRow` (which **omits** `group_id`) and
`db.deleteTrades`; it never references `trade_groups`. Grep: zero `group_id` occurrences on any
merge line. (Moot in practice since Merge is unreachable, but confirmed.)

**F5 — G2 grouping never calls a merge/delete path.** The create action issues exactly one
`SUPA.rpc("create_trade_group_v1", …)`; it never calls `commitMerge`, `deleteTrades`, or any
`isMerged`/`subTrades` writer.

**F6 — Durable paths preserve `group_id` by omission.** `toTradeRow` omits `group_id`, so
save/close/update upserts (ON CONFLICT SET only named columns) leave an existing row's
`group_id` intact; duplicate/import create fresh rows (correctly no `group_id`); delete removes
the row (and its `group_id`). `db.loadAll` reads only `raw`, which never contains `group_id`.

**F7 — No misleading "merge group" / "group merge" labels.** Merge uses `⊕`/`🔗` and
"Merge"/"Merged"; grouping uses `🧩` and "Grouping"/"Create group"/"write-gated". No shared
string conflates them, and the grouping UI is **default-off** (both flags), so a normal user at
deploy sees only the disabled `🔗` and no grouping UI at all.

**F8 — Gap vs ROADMAP #184 (pre-write-gate, not pre-deploy).** ROADMAP requires
*"Validation rejects grouping of legacy merged rows."* The current `buildGroupingPreview`
([3536-3545](../../index.html#L3536-L3545)) filters only `status==="open"` + non-empty
direction; it does **not** exclude `isMerged` rows. The `create_trade_group_v1` RPC validates on
projected columns (status/product_id/direction/group_id) and does **not** read
`raw->>'isMerged'`. So once the write gate is enabled, a legacy merged open row could be included
in a group. This is **P/L-safe** (reducers ignore `group_id`) but violates the design contract
and could cause conceptual confusion. It is **not reachable at deploy** (grouping default-off +
write-gated), so it is a **stop-gate before enabling the write gate**, not a deploy blocker.

## Reachable / not-reachable status

| Concept | Status at deploy |
|---|---|
| Old row-collapsing Merge | Removed (dead code deleted) — not reachable |
| Durable `commitMerge` | Present but **not reachable** (sole entry `disabled`, no onClick) |
| Display/close of existing `isMerged` rows | Reachable (read/close of prior data only) |
| G2 grouping preview/proposal | Not visible (flag `tj_trade_group_ui_v01` default-off) |
| G2 grouping **write** (create RPC) | Not reachable (flag `tj_trade_group_write_v01` default-off + handler `!writeEnabled` guard) |

## Risk list

1. **R1 — Legacy merged row groupable once write gate is on** *(Low; pre-write-gate).* Violates
   ROADMAP #184. Data-safe (P/L unaffected) but a design-contract + clarity gap. **Mitigate before
   enabling the write gate:** exclude `isMerged` in `buildGroupingPreview` (client has `raw.isMerged`)
   and, defense-in-depth, add a `raw->>'isMerged'` reject in `create_trade_group_v1`.
2. **R2 — Disabled-merge discoverability** *(Very low.)* The `🔗` reason shows only on hover.
   Cosmetic; not a boundary risk.
3. **R3 — Deploy-time confusion** *(None.)* Grouping UI default-off; Merge disabled → nothing
   user-visible to confuse at deploy.

## Recommended wording / UX changes

- **Pre-deploy: none required.**
- **Optional, when grouping later ships to users (flags on):** a one-line distinction — "Group =
  non-destructive association (P/L unchanged)" vs the disabled "Merge (retired)" — and consider a
  short visible label on the disabled `🔗` instead of hover-only.

## Required stop gates before any implementation (grouping write-enable)

In addition to the existing Lane B write-gate gates (deploy shipped + explicit flag-enable
approval + post-deploy browser flag-matrix smoke + reducers re-confirmed to ignore `group_id` +
adversarial review):

- **G-merge-1:** `buildGroupingPreview` (and the create path) must **exclude `isMerged` rows**
  (ROADMAP #184). Add a `raw->>'isMerged'` reject in `create_trade_group_v1` for authority.
- **G-merge-2:** Do **not** re-enable the disabled `🔗` Merge as part of grouping work; grouping
  is the replacement, not a merge variant.

## Verdict

**CLEAR_FOR_BATCH_DEPLOY_AS_IS** — at deploy the legacy Merge is disabled/unreachable and G2
grouping is default-off + write-gated, so there is no reachable confusion or data risk. The one
substantive gap (F7/R1, `isMerged` exclusion per ROADMAP #184) is **data-safe** and is a
documented **stop-gate before enabling the write gate**, not a blocker for the batch deploy.
