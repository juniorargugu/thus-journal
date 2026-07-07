# G2 v0.4 Group-Aware Loader/Render Closeout

**Date (local):** 2026-07-07
**Status:** **IMPLEMENTED LOCALLY + Codex PASS → OK_FOR_FUTURE_BATCH** (unpushed, not deployed).
**Implementation commits:** `ba9e780` (loader/render) + `9a07fdc` (stale-map reset fix).
**Base/prod:** production unchanged at `71283c3` / v3.22.0. Local `main` ahead by 4 unpushed
commits (2 code + 2 docs).

> This closes the G2 v0.4 loader/render workstream at the **local + reviewed** stage. It is the
> prerequisite for a **kept** real group to be visible in the app, but nothing is shipped or enabled:
> no push, no deploy, no flag enable, no persistent group. The write path itself (create/ungroup)
> was proven earlier in [`g2_write_gate_browser_smoke_closeout.md`](./g2_write_gate_browser_smoke_closeout.md).

---

## What was implemented (`ba9e780`)

1. **`db.loadAll`** now selects `raw,group_id` (was `raw` only).
2. **`trades[]` stays `raw`-only** — still `t.data.map(r=>r.raw)`; the reducer input is unchanged.
3. **`tradeGroupIds`** is a **SEPARATE** `id→group_id` map (non-null `group_id` + present `raw.id` only),
   returned alongside `trades` and held in its own App state.
4. **`group_id` is never attached to `raw` or any frontend trade object.** `toTradeRow` (which does
   `raw:t`) is unchanged, so no save/edit/close path can re-contaminate `raw` with `group_id`.
5. **`buildGroupingPreview(openTrades, products, groupIdMap={})`** suppresses grouped rows
   (`!groupIdMap[String(t.id)]`) **before bucketing**, alongside the existing `open` + `!isMerged`
   filters. Fixes the cross-reload re-offer of an already-persisted group.
6. **Empty `groupIdMap` preserves prior behavior** exactly (default `{}`).
7. **`PositionCard`** shows a distinct **green `⛓ Grouped`** badge (visually separate from the yellow
   `⊕M` merge badge), driven by `isGrouped={!!gmap[String(t.id)]}` on open cards only.
8. **No collapse / nesting / hiding / reorder** — grouped child rows remain individually visible.
9. **No P/L / reducer / portfolio / durable-persistence changes** — reducers keep walking `raw`.

## Stale-map reset (`9a07fdc`)

Codex's one required change on `ba9e780`: reset `tradeGroupIds` so a stale map cannot survive an
auth-identity transition or a critical hydration failure after an already-ready session. Added
`setTradeGroupIds({})`:
- at the **top of the hydration `useEffect`**, before `if(!authUid)return;` (covers mount, authUid
  change/absence, retry — before any load);
- in the **critical-failure branch** (`!data.ok`) before `return`;
- in the **`.catch`** path.

Successful hydration still repopulates via `setTradeGroupIds(data.tradeGroupIds||{})`. Render-only:
no `trades[]` / localStorage / persistence side effect, no DB read/write, no render loop
(setter does not affect the effect deps `[authUid, loadAttempt]`).

---

## Codex review chain

| Commit | Verdict | Notes |
|---|---|---|
| `ba9e780` | **PASS_WITH_CHANGES** (FIX_BEFORE_BATCH) | Only required change: stale `tradeGroupIds` reset on auth transition / critical failure. |
| `9a07fdc` | **PASS** → **OK_FOR_FUTURE_BATCH** | Reset fix reviewed: coverage correct, success path intact, no render loop, no persistence side effect, no raw/toTradeRow change. |

**Known non-blocker (pre-existing, out of scope):** the whole hydration effect does not cancel an
in-flight `db.loadAll` nor guard its `.then` with a current-identity check, so a superseded load for a
prior `authUid` could repopulate state (all hydrated state — trades/portfolio/products/tradeGroupIds —
identically) after a same-mount auth switch. This existed before G2 and is not introduced or worsened by
this patch; logout unmounts App, so the realistic logout→login path (remount) is unaffected. Flagged for
a possible future whole-effect generation-guard hardening (its own task), not required for this batch.

---

## Validation performed (implementation tasks)

- esbuild syntax check on the Babel block: **EXIT 0** (both commits).
- Static grep: no `group_id`/`_groupId` assignment onto `raw`/trade objects; `toTradeRow` unchanged.
- Candidate-exclusion + loader-map harness (scratchpad): **10/10 PASS** (empty map preserves behavior;
  both children grouped → 0 candidates; one-of-pair grouped → 0; mixed → only ungrouped pair; isMerged
  still excluded; loader map keeps only non-null gid + present `raw.id`, String keys; loader never
  mutates `raw`).
- Diff audits: `index.html` only; no reducer/P&L/persistence hunks; `git diff --check` clean; LF.

---

## Deferred items (not in v0.4)

- **Journal row badge** — badging the Journal table row would thread `tradeGroupIds` through a second
  page (`PageJournal`); skipped as broader than the minimal change. `PositionCard` badge (required) done.
- **Immediate post-create badge** — after `create_trade_group_v1` success the map is not updated
  in-session (RPC return shape not verified to expose the group id cleanly); the session `groupedKeys`
  suppresses re-offer and the badge appears on next reload. No new DB read/RPC added.
- **`trade_groups` label read** — v0.4 uses `group_id`-only badges (a non-null `group_id` always
  references an active group); reading group labels is a later nicety.
- **Ungroup UI** — separate task (a write path), its own review.
- **Real persistent-group test** — first true exercise of the new loader; gated behind a user-approved
  deploy + `tj_trade_group_write_v01` enable.
- **Grouped-child edit/close durability check** — future smoke to confirm that editing/closing a grouped
  child preserves `trades.group_id` via the omitted-column upsert behavior (`toTradeRow` omits
  `group_id`, so `ON CONFLICT` never overwrites it). Expected safe by construction; worth a live smoke
  once a real group is kept.

---

## Next recommended step

**Future deploy-batch preflight (local stack, non-write validation only)** — verify the unpushed stack
is deploy-clean without pushing; the push/deploy and any flag enable remain user-gated. See
[`../pipeline/NEXT_SAFE_TASK.md`](../pipeline/NEXT_SAFE_TASK.md).
