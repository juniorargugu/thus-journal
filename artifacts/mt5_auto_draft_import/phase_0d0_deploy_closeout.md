# MT5 Phase 0D-0 — Deploy Closeout

**Status:** `MT5_0D0_DEPLOY_PASS`

**Deployed:** 2026-06-30 (docs-only record; no SQL / MT5 / writer / Supabase mutation involved).

The Settings-embedded, read-only MT5 Inbox UI (commits `5913ace` + `267e579`) plus the preceding
reviewed MT5 0A/0C/0D documentation+code stack were pushed to `origin/main` and auto-deployed by
Netlify.

---

## 1. Deploy facts

| Fact | Value |
|---|---|
| pushed commit range | `09842d7..8864e73` (main → main) |
| final origin/main SHA | `8864e73` — *docs: record MT5 0D0 browser smoke* |
| prior production SHA | `09842d7` |
| Netlify deploy id | `6a437eaeee81f000082be4d8` |
| Netlify state | `ready` (published) |
| Netlify commit_ref / branch | `8864e73` / `main` |
| published_at | 2026-06-30T08:30:45Z (~7s build) |
| production URL | https://thus999.com |
| Netlify project / id | `thus-journal` / `d1a144c5-ecba-4414-9830-4d1b28678d0d` |
| served `index.html` vs committed blob | **byte-identical** (sha256 `31484918…`, 559,614 bytes) |

The push published the full reviewed MT5 stack (16 commits: 0A SQL/RPC packet + closeout, 0C probe/
row-builder/writer, 0C-3a smoke record, 0D-0 inbox feat+fix+smoke record). Only `index.html` affects
the served web app; the `ops/mt5_import/*.py` writer + `artifacts/*.md` are repo-only (not part of the
browser bundle).

---

## 2. Production smoke

**Deploy + live-bundle (verified directly):**

- Production app bundle is live and **byte-identical** to the reviewed commit `8864e73`.
- Live served bundle confirms the 0D-0 read-only invariants:
  - default-OFF flag init present: `ls.get(MT5_INBOX_FLAG,false)` (the `LS`→`ls` fix is live)
  - effect gate present: `if(on&&authUid){load()}` → flag OFF fires no query
  - `db.loadMt5Staging` present and SELECT-only (explicit column list, no `select("*")`)
  - account mask helper `_mt5MaskAccount` present (source_account masked by default)
  - read-only caption "Read-only mirror of MT5…" present; "ยังไม่จับคู่สินค้า" present
  - **no** `.insert/.update/.delete/.upsert/.rpc` on staging in the served bundle
  - **no** write-action buttons in the inbox block (Confirm / Dismiss / Group / Materialize /
    Resolve product / Create draft / Create trade — all absent from lines 6296–6423)

**Interactive DevTools smoke (user-run — I cannot drive a browser):** the served bytes are identical to
the build that already PASSED the local browser smoke (record: phase_0d0_local_browser_smoke_record.md),
so behavior is expected identical. Recommended final confirmation on https://thus999.com:

1. App loads; Positions / Journal / Settings load; **Settings does NOT black-page**.
2. `localStorage.removeItem("tj_mt5_inbox")` + reload → Settings → MT5 Inbox **OFF** by default →
   **no** `/rest/v1/mt5_import_staging` request fires.
3. Toggle **ON** → exactly **one** `GET /rest/v1/mt5_import_staging?...`; **no** POST / PATCH / DELETE / RPC.
4. GOU26 row renders: `needs_mapping` / "ยังไม่จับคู่สินค้า" / `open` / `position_id=305830528` /
   `position_state=open` / `contract_size=300` / `instrument_class=futures` / `product_id_candidate=—` /
   source_account masked / **no** SSF warning.
5. Panel shows read-only / "not Journal trades" caption; **no** action buttons.

---

## 3. Boundary confirmations (deploy task)

- no SQL run
- no MT5 / writer run
- no Supabase write by the deployment task (push + Netlify build + read-only fetches only)
- no `mt5_import_cursors` rows touched
- no `mt5_import_groups` rows touched
- no THUS trades / products / portfolio / notes / trade_groups changed
- no Storage touched
- no GUGU touched
- no DB schema / policy / grant change
- no secrets printed (service_role key never echoed; URLs/keys redacted in logs)
- no `.env` created or staged; no generated JSON / output / pycache / pyc staged; no unrelated untracked
  files staged

DB-level backstop (Phase 0A, applied & verified): browser `authenticated` role has SELECT-only on
`mt5_import_staging` (RLS `user_id = auth.uid()`), no write grant/policy → staging writes from the
browser are server-impossible regardless of UI.

---

## 4. Remaining gated work

- 0C-3b close / partial deal writer
- 0C-3c balance + cursor
- 0C-3d lifecycle reconcile
- 0D-1 actions (confirm / dismiss / group — write path via RPCs)
- promote MT5 Inbox to a dedicated nav tab (once actions exist)
- product resolver / mapping, DELTAU26 mapping
- Phase 1 materialization into THUS trades
- screenshots / Storage
- scheduling / automation

---

## 5. Result

**`MT5_0D0_DEPLOY_PASS`** — origin/main `8864e73` published by Netlify deploy
`6a437eaeee81f000082be4d8` (ready), production byte-identical to the reviewed commit, live bundle
verified read-only and default-OFF. Production is now ahead of the prior `09842d7` by the full MT5
0A→0D-0 stack. Interactive DevTools confirmation on thus999.com is the only user-run tick remaining.
