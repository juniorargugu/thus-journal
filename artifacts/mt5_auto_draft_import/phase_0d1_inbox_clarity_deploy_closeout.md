# MT5 Phase 0D-1 — Inbox Clarity Deploy Closeout

**Status:** `DEPLOY_COMPLETE_0D1_INBOX_CLARITY`

**Recorded:** 2026-06-30 (docs-only; no runtime change, no SQL/MT5/writer/Supabase mutation).

The read-only MT5 Inbox clarity UI (commit `7088473`) was pushed, auto-deployed by Netlify, and
verified live in production. This artifact records the evidence.

---

## 1. Repo / deploy facts

| Fact | Value |
|---|---|
| origin/main | `7088473` — *feat: clarify MT5 inbox staging rows* |
| local HEAD | `7088473` (in sync) |
| pushed range | `1424904..7088473` (index.html only) |
| Netlify deploy id | `6a43bc08f059210008915fe0` |
| Netlify state | `ready` (published) |
| commit_ref / branch | `7088473` / `main` |
| published_at | 2026-06-30T12:52:31Z |
| production URL | https://thus999.com |
| served `index.html` | byte-identical to committed `7088473` |
| production bundle sha256 | `71594431707139399b8ad59036b7a0c320a80db7c531ae1d6eba9ffd906117c5` |
| production bundle size | 565,847 bytes |
| commits made during this deploy task | none |

---

## 2. Implemented scope (read-only invariants preserved)

- MT5 Inbox remains **default-OFF** behind localStorage flag `tj_mt5_inbox`.
- Query runs only when the flag is ON **and** `authUid` exists (effect gate `if(on&&authUid){load()}`).
- `db.loadMt5Staging` remains **SELECT-only** (explicit column list; no `select("*")`).
- `raw` excluded from the select and never rendered.
- `source_account` masked by default.
- No action buttons; no write-capable UI.
- No RPC; no `service_role` in the browser; no schema/data mutation.

---

## 3. User-visible improvements (0D-1)

**Sectioning** — rows grouped into:
- 📂 Open MT5 positions (`kind=open`)
- ✅ Closed MT5 deals (`kind` = close/partial)
- • Other staging rows (balance/unknown/etc, shown only if present)

**Summary strip** — total, open, close/partial, (other), needs_mapping, no-product counts, masked
accounts represented, and the loaded timestamp.

**Safety labels** (per row):
- Staging only
- Not a Journal trade
- Needs mapping (+ "No Journal draft/trade has been created from this row.")
- No product mapped
- Check contract size before mapping
- Derivative/SSF-style symbol — do not map by name alone

**Open rows emphasize:** position_id, position_state, side, volume, price, open_time,
first_seen_open_at, last_seen_open_at, state, product_id_candidate, contract_size / instrument_class —
with copy: *"This is an MT5 open-position staging row. It has not created or changed a Journal
position."*

**Close/partial rows emphasize:** deal_id, position_id, order_id, side, volume, price, close_time /
mt5_time, broker_profit, commission, swap, fee, state, product_id_candidate, contract_size /
instrument_class — with copy: *"This is an MT5 historical deal staging row. It is not linked to a
Journal trade yet."*

**Read-only position↔deal hint** — closed rows show "Matches open staging position <id>" or
"No matching open staging row currently loaded" (computed from loaded open rows; **no** group_id,
**no** write, **no** RPC, **no** Journal linkage).

**Clearer empty/error states** — flag OFF explains how to enable; ON + no auth explains sign-in (and
sends no query); 0 rows → "No MT5 staging rows found for this user"; load error → safe generic message
(no raw/secret) + retry.

**Sorting** — open by last_seen_open_at/open_time desc; close/partial by close_time/mt5_time desc;
other by mt5_time desc.

---

## 4. Production verification

- App served the new `7088473` bundle (byte-identical to the committed blob; sha256 `71594431…`).
- Live-bundle invariants confirmed: default-OFF flag init present, effect gate present,
  `loadMt5Staging` SELECT-only, the three section headers present, the safety labels present.
- **No** `mt5_import_staging` write/RPC in the served Inbox path; **no** `raw` rendered in the Inbox
  (the only `r.raw` in index.html is the pre-existing THUS trades loader, outside the Inbox block).
- Expected interactive behavior (user-run DevTools smoke; served bytes == the locally smoke-passed
  build): flag OFF → no `mt5_import_staging` request; flag ON → GET-only; no POST/PATCH/DELETE/RPC;
  open row `305830528` under **Open MT5 positions**; close deal `2141744` under **Closed MT5 deals**;
  no raw visible; Reload works; no console error; Settings/Positions/Journal navigation intact.

---

## 5. Boundary confirmations

- no SQL
- no MT5
- no `writer.py`
- no Supabase mutation
- no `service_role`
- no staging write
- no cursor / group write
- no THUS table write
- no Storage
- no GUGU
- no raw exposure
- no secrets printed

---

## 6. Still not done / gated

- no confirm button
- no create-Journal-draft
- no product mapping write
- no materialization
- no cursor advancement
- no balance row importer
- no lifecycle reconcile
- no continuous importer
- no automation / scheduler

---

## 7. Recommendation

- **0D-1 is complete and deployed** (read-only MT5 Inbox clarity live in production).
- Recommended to **pause the MT5 backend pipeline before 0C-3c** and let the current Inbox be used
  manually for a while.
- Next decision (in order of suggested priority):
  1. Pause and use the current Inbox manually to build intuition on the staged rows.
  2. Design the **product mapping / review workflow** (the step that turns inert staging rows into
     reviewable Journal drafts — the first real user value beyond visibility).
  3. Only later design **0C-3c** (balance rows + `mt5_import_cursors` advancement → continuous importer).

---

## 8. Result

**`DEPLOY_COMPLETE_0D1_INBOX_CLARITY`** — recorded docs-only. Production web app is now `7088473`
(prior `8864e73` via the intervening docs commit `1424904`). The MT5 Inbox is a clear, read-only,
default-OFF diagnostic; no write surface exists anywhere in the pipeline's UI.
