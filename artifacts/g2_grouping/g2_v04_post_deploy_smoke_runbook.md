# G2 v0.4 — Post-Deploy Smoke Runbook

**Date (local):** 2026-07-07
**Status:** **PREPARED — not yet executed.** Deploy batch is **ON HOLD** by user decision.
**Applies to:** the G2 v0.4 loader/render deploy batch (local `ba9e780`+`9a07fdc` code + docs,
preflight **READY_FOR_DEPLOY_PROMPT**). Run this runbook **only after** a user-approved deploy has shipped.
**Prod at authoring time:** `71283c3` / v3.22.0. **Target after deploy:** the pushed HEAD, app version **v3.23.0**.

> This is a **read-only** smoke: load the app, observe, and inspect the network tab. It performs **no**
> writes, enables **no** write flag, and creates/keeps **no** group. The one optional step (UI-flag-only
> preview) is **separately approved** and reverts itself. If any check fails, treat the deploy as FAIL and
> escalate before enabling anything.

---

## 0. Scope / preconditions

- Requires: a completed, user-approved production deploy (push → Netlify publish) that **included the
  `APP_VERSION` bump `3.22.0`→`3.23.0`**.
- Signed-in production browser at `thus999.com`.
- Network tab open (to confirm zero grouping writes on load).
- DB baseline (unchanged from the write-gate smoke closeout): **0 active groups / 0 grouped trades**, 1
  archived group row by design → **no ⛓ Grouped badge should appear anywhere**.

---

## 1. Pre-deploy reminder (verify before the push that precedes this smoke)

- [ ] Deploy approval was explicitly given by the user (batch was ON HOLD until then).
- [ ] The deploy commit bumps `APP_VERSION` **`3.22.0` → `3.23.0`** (single-source constant near top of
      `index.html`) — this is step 1 of the deploy prompt.
- [ ] No untracked backup/archive files staged. Expected untracked (must stay untracked, never `git add`):
      `.claude/`, `RESOURCE_AUDIT.md`, `archive/`, `artifacts/close_position_journal_bug/backup_*.json`,
      `artifacts/merge_grouping/g2_baseline_20260608.json`.
- [ ] Pushed range contains only the expected commits — the 6 unpushed
      (`f45416e`, `a555414`, `ba9e780`, `9a07fdc`, `4e63783`, `e650fbb`) **plus** the single version-bump
      commit. Nothing else.
      - Verify locally before push: `git log --oneline origin/main..HEAD` shows exactly those 7.

---

## 2. Production verification

- [ ] **Netlify deploy succeeded** — latest deploy for the site is "Published" (not failed/building).
- [ ] **Served bundle byte-identical to HEAD** (when feasible). Compare sha256:
  ```
  # served:
  curl -s https://thus999.com/index.html | sha256sum
  # local HEAD blob:
  git show HEAD:index.html | sha256sum
  ```
  The two hashes must match (static single-file app; prior deploys were byte-identical). HTTP 200 expected.
- [ ] **Version shows v3.23.0** — hard-refresh (Ctrl/Cmd+Shift+R to bust cache); the footer version badge
      reads **v3.23.0**. A stale `v3.22.0` after hard refresh = FAIL (version mismatch).

---

## 3. Default-off smoke (core — must PASS)

With **no** grouping flags set (fresh/normal session):

- [ ] `localStorage.getItem("tj_trade_group_ui_v01")` → **null**.
- [ ] `localStorage.getItem("tj_trade_group_write_v01")` → **null**.
- [ ] `localStorage.getItem("tj_trade_group_mock")` → **null** (mock render also default-off).
- [ ] **Grouping UI absent** — no "Grouping preview" block on the Positions page.
- [ ] **No `create_trade_group_v1`** request on load (Network tab, filter `rpc`).
- [ ] **No direct `/rest/v1/trades` write** on load (only the read `select` on hydration is expected; no
      POST/PATCH/DELETE to trades).
- [ ] **No direct `/rest/v1/trade_groups` write** on load (no POST/PATCH/DELETE; the app does not read or
      write `trade_groups` in v0.4).

> Note: on load the app **reads** `trades` with `select=raw,group_id` (v0.4 loader). That single GET is
> expected and is **not** a write. What must be absent are grouping *writes* and any `create_trade_group_v1`.

---

## 4. Normal UI smoke (must PASS)

- [ ] App mounts (no console errors that block render; the benign Babel ">500KB deopt" note is OK).
- [ ] **Positions** render normally — existing open trades still visible, cards render, prices/badges as before.
- [ ] **Journal** renders normally.
- [ ] **P/L and portfolio visually unchanged** vs. pre-deploy (reducers walk `raw`; v0.4 does not touch P/L).
- [ ] **No unexpected ⛓ Grouped badge** — DB has 0 grouped trades, so no green ⛓ badge should appear on any
      card. (The yellow `⊕M` merge badge, if any merged trades exist, is unrelated and may still show.)
- [ ] Existing open/closed trades, steps, dashboard all render as before.

---

## 5. Optional visual-only dev-flag check (SEPARATELY APPROVED ONLY)

> Do **not** run this unless separately approved. It sets the **UI flag only** and reverts it. The **write
> flag stays absent**, so no group can be created.

- [ ] Precondition: at least two open trades of the same product-family + direction exist (otherwise no
      candidate will show — that itself is a valid, expected result).
- [ ] Set **UI flag only**: `localStorage.setItem("tj_trade_group_ui_v01","1")` → hard-refresh.
- [ ] Confirm `tj_trade_group_write_v01` remains **null** (do NOT set it).
- [ ] Grouping **preview** UI may appear if candidates exist; each candidate shows **"preview only"** /
      **"read-only · no group is saved"** wording (write flag off).
- [ ] Open a proposal → confirm there is **no** active "Create group" button/action (create control is gated
      on the write flag) and the modal states preview-only / nothing saved.
- [ ] Confirm **no `create_trade_group_v1`** request is sent during the whole check (Network tab).
- [ ] **Cleanup:** `localStorage.removeItem("tj_trade_group_ui_v01")` → hard-refresh; grouping UI absent again.

---

## 6. Explicitly out of scope (do NOT do here)

- Enabling `tj_trade_group_write_v01`.
- Creating or keeping a real group.
- Running `create_trade_group_v1`.
- Running `ungroup_trade_group_v1`.
- SQL Editor rollback / any SQL.
- v0.5 ungroup UI implementation.
- RPC-side `raw->>'isMerged'` hardening.

---

## 7. Pass / fail criteria

**PASS** — all of §2 (production verification), §3 (default-off), and §4 (normal UI) pass. The optional §5
check, if run, must also show no create RPC and a blocked create action.

**FAIL** (stop and escalate; do not enable anything) if any of:
- Any grouping **write** occurs on load (`create_trade_group_v1`, or a POST/PATCH/DELETE to `/rest/v1/trades`
  or `/rest/v1/trade_groups`).
- Grouping UI appears **by default** (with no flags set).
- **Version mismatch** persists after a hard refresh (footer not `v3.23.0`).
- **P/L / Positions / Journal** behave unexpectedly, or an unexpected ⛓ Grouped badge appears while DB has 0
  grouped trades.
- Served bundle sha256 does **not** match `HEAD:index.html` (when the comparison was feasible).

On PASS: record a short closeout (e.g. `g2_v04_post_deploy_smoke_closeout.md`) and update
[`../pipeline/PIPELINE_STATE.md`](../pipeline/PIPELINE_STATE.md). Enabling the write flag / keeping a real
group / v0.5 ungroup remain **separately gated** next steps.

---

## Related

- Deploy preflight: batch verdict READY_FOR_DEPLOY_PROMPT (see [`../pipeline/PIPELINE_STATE.md`](../pipeline/PIPELINE_STATE.md) Lane B).
- Loader/render: [`g2_v04_loader_render_closeout.md`](./g2_v04_loader_render_closeout.md).
- Write-gate live smoke (rollback): [`g2_write_gate_browser_smoke_closeout.md`](./g2_write_gate_browser_smoke_closeout.md).
- v0.5 ungroup (deferred): [`g2_v05_ungroup_design_closeout.md`](./g2_v05_ungroup_design_closeout.md).
