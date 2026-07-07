# G2 v0.5 Ungroup UI — Design Closeout (Approved-Deferred)

**Date (local):** 2026-07-07
**Status:** **DESIGN REVIEWED + APPROVED-DEFERRED** — ChatGPT verdict **PASS**,
recommendation **IMPLEMENT_AFTER_CURRENT_DEPLOY**. No code written; nothing deployed.
**Depends on:** G2 v0.4 loader/render ([`g2_v04_loader_render_closeout.md`](./g2_v04_loader_render_closeout.md),
`ba9e780`+`9a07fdc`) — provides the `tradeGroupIds` (`childId → group_id uuid`) map the ungroup UI keys off.
**Prod:** unchanged at `71283c3` / v3.22.0; deploy batch on hold.

> This records the reviewed v0.5 ungroup design as a **deferred** work item. Implementation is
> explicitly **NOT** part of the current v0.4 deploy batch (ungroup is a new write path). It is
> sequenced after: v0.4 deploys → default-off smoke passes → write-flag enable + a real kept group
> exists to smoke against.

---

## Why deferred (not in the current batch)

- Ungroup is a **new write path**; folding it into the on-hold, already-preflighted v0.4 batch would
  expand that batch's reviewed risk surface (the task explicitly forbids batch expansion).
- Ungroup only has something to act on once a **real group is kept**, which is itself gated behind
  deploy + `tj_trade_group_write_v01` enable. Natural order: ship v0.4 (read/render) → enable write flag
  + keep a real group (gated) → build & smoke ungroup end-to-end.

---

## Reviewed design (record)

**Primary UI location** — the **trade detail modal** opened from a grouped `PositionCard`. One affordance
per opened trade; ungrouping acts on the whole group regardless of which child was opened → no N duplicate
buttons across N cards. (A dedicated "active groups" summary strip is a larger surface → out of scope.)

**Visibility gate** — the Ungroup affordance renders only when
`groupUiV01On && groupWriteV01On && !!tradeGroupIds[String(trade.id)]`. The grouped badge itself stays
display-only and flag-independent (v0.4). Handler first line `if(!writeEnabled)return;` (defense-in-depth,
mirrors create).

**Confirmation** — exact typed text **`UNGROUP`** (symmetric with create's `CREATE GROUP`, distinct).

**Write behavior** — exactly one `SUPA.rpc("ungroup_trade_group_v1",{p_group_id:groupId})`.
- No direct `/rest/v1/trades` writes. No direct `/rest/v1/trade_groups` writes.
- Dual error handling: transport (`txErr`) + business (`data.ok===false` → mapped message). Ungroup RPC
  error codes: `not_authenticated`, `group_not_found`.
- RPC contract ([`../../migrations/20260705_g2_trade_group_rpcs.sql`](../../migrations/20260705_g2_trade_group_rpcs.sql), fn `ungroup_trade_group_v1`):
  success `{ok:true, group_id, archived:true, already_archived:false, cleared:<int>, child_ids:[…]}`;
  idempotent `{ok:true, …, already_archived:true, cleared:0, child_ids:[]}`. Server sets children
  `group_id=NULL` (**raw untouched**) and **archives** the group row (never deletes).

**Success behavior** — clear `tradeGroupIds` entries for the returned `child_ids` (server-authoritative):
`setTradeGroupIds(prev => omit(child_ids))`. If `already_archived:true` returns empty `child_ids`, use a
**safe group_id-map fallback** (remove entries whose value === `groupId`). **No `loadAll` refresh required**
unless a later implementation review decides otherwise. Never attach `group_id`/`_groupId` to `raw` or
frontend trade objects — the map is the only place group membership lives. Toast + close modal on success.

**UX copy** — **Grouped ≠ Merged.** Wording "Ungroup" / "แยกกลุ่ม"; copy states it removes only the group
label and does **not** delete trades, change P/L, or mutate `raw`. Never "unmerge". Legacy Merge `🔗` stays
disabled/unreachable.

**No `trade_groups` label read** — ungroup needs only the `group_id` (already in `tradeGroupIds`); the
confirm can show a child-derived label (family+direction, like create's proposal) without reading
`trade_groups`.

---

## Likely code surfaces (when implemented later)

- **Module G2 helpers** (near `_G2_CREATE_CONFIRM`, ~L3600 of index.html): add `_G2_UNGROUP_CONFIRM="UNGROUP"`,
  `_g2UngroupConfirmOk`, `_G2_UNGROUP_ERR` (`not_authenticated`, `group_not_found`), `_g2MapUngroupError`.
- **Trade detail modal** (component around L2490–2565, rendered from `detailTrade`): gated Ungroup affordance
  + typed-confirm sub-UI + `onUngroup`; needs the trade's `group_id` + flags passed in.
- **`PagePositions`** (L3717): owns `gmap`+flags; host `onUngroup(groupId)` (single RPC); thread `group_id` +
  flags to the detail modal.
- **App** (state L8660; render L9903): pass a clear-callback
  (`onGroupUngrouped={(childIds)=>setTradeGroupIds(prev=>omit(childIds))}`) down, since `tradeGroupIds`
  state lives in App.
- **Unchanged:** `toTradeRow`, `raw`, reducers, P/L, portfolio, `buildGroupingPreview` semantics,
  `MergedCloseForm`/`commitMerge`, all durable save/close/delete/merge/import paths.

---

## Explicit non-goals (v0.5)

No group editing (rename/add/remove leg); no `trade_groups` label/history read; no collapse/nesting/grouped
section render; no Journal-row ungroup; no bulk/ungroup-all; no legacy Merge change; no reducer/P&L/portfolio
change; no durable save/close/delete/merge/import change; no RPC/schema change; **no RPC-side
`raw->>'isMerged'` guard in this task** (separate schema review); no undo-ungroup (re-create is the path).

---

## Test plan (for the future implementation)

- Confirm gate: `_g2UngroupConfirmOk("UNGROUP")` true; trimmed/other false.
- Error map: `not_authenticated`/`group_not_found`/transport → mapped Thai messages.
- Single-RPC discipline: `onUngroup` issues exactly one `SUPA.rpc` with `{p_group_id}`, zero direct table writes.
- State update: success `{child_ids:[a,b]}` → `tradeGroupIds` loses a,b; `isGrouped` flips false;
  `buildGroupingPreview` re-offers the pair.
- Raw non-contamination: `toTradeRow` output still has no `group_id`/`_groupId`; handler never assigns onto trade/raw.
- P/L invariant: portfolio/P&L snapshot identical pre/post ungroup.
- Idempotent: `already_archived:true` → success path, map cleared via group_id fallback, no error surfaced.
- Gate: button hidden unless UI+write+group_id; `onUngroup` no-ops when `writeEnabled` false.
- Static/syntax: esbuild EXIT 0; `git diff --check` clean.

---

## Risks / stop gates (carried to implementation)

- **R1 (critical):** handler clears the *separate map* only — never assign `group_id` onto trade/raw → static test.
- **R2:** Merge confusion → distinct wording/icon; `🔗` stays disabled.
- **R3 (known):** post-create-without-reload, `tradeGroupIds` lacks the real uuid (v0.4 deferred item) → ungroup
  relies on **reload-populated** `group_id`. Acceptable; or stretch-wire a post-create map update.
- **R4 (minor UX):** same-session create→ungroup: session `groupedKeys` still suppresses re-candidacy until
  reload (badge clears correctly). Note, don't fix in v0.5.
- **Stop gates before coding:** (a) v0.4 deployed; (b) write-flag enable approved + a real kept group to test
  against; (c) adversarial review of the ungroup code; (d) P/L snapshot proven identical.

---

## Sequencing

v0.4 deploy (user-gated, version bump `3.22.0`→`3.23.0`) → post-deploy default-off smoke → write-flag enable
+ keep one real group (gated) → **implement v0.5 ungroup UI + adversarial code review** → live ungroup smoke.
See [`../pipeline/NEXT_SAFE_TASK.md`](../pipeline/NEXT_SAFE_TASK.md).
