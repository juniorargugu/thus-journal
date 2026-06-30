# MT5 Phase 0D-0 — Local Browser Smoke Record

**Status:** `PHASE_0D0_LOCAL_BROWSER_SMOKE_PASS`

**Recorded:** 2026-06-30 (docs-only; recorded from the user-reported local browser smoke result).

This is a **docs-only** closeout. No SQL, no MT5, no `writer.py`, no Supabase mutation, no deploy.

---

## 1. Final good state

| Fact | Value |
|---|---|
| current HEAD | `267e579` — *fix: restore Settings after MT5 inbox panel* |
| production / origin/main app commit | `09842d7` (unchanged) |
| local main ahead origin/main | by 15 |
| push | none |
| deploy | none |

0D-0 landed as **two `index.html`-only commits**:

| Commit | Subject | Δ |
|---|---|---|
| `5913ace` | feat: add MT5 read-only inbox panel | +183 / −2 |
| `267e579` | fix: restore Settings after MT5 inbox panel | +2 / −2 |

No other runtime file changed. No new DB tables / migrations / policies / grants.

---

## 2. Settings black-page issue — fixed (not reverted)

- **Symptom:** after `5913ace`, opening THUS → Settings showed a black/broken page; other pages worked.
- **Root cause:** `ReferenceError: LS is not defined`. The app's localStorage wrapper is `ls`
  (lowercase). `Mt5InboxPanel` referenced `LS.get(...)` in a `useState` initializer and `LS.set(...)`
  in the toggle. On the first render of the panel (when Settings mounts) the initializer threw, and
  with no React error boundary the whole tree unmounted → black page. Other pages never render the
  panel, so they stayed usable. It was a **runtime** error (the script transpiled fine), which is why
  only Settings broke.
- **Fix (`267e579`):** narrow 2-character rename `LS` → `ls` on the two panel lines. The read-only MT5
  Inbox implementation was **preserved** (no rollback). All other referenced globals
  (`db`, `SUPA`, `clsBtn`, `fmtTime`, React hooks) were verified defined.
- **Prevention note:** a pre-commit grep for undefined globals (e.g. `LS.` vs `ls.`) would have caught
  this before the black-page smoke.

---

## 3. Final browser smoke results (user-run) — PASS

UI / behavior:

- Settings opens normally — **no black page**.
- MT5 Inbox local flag (`tj_mt5_inbox`) is **OFF by default**.
- Flag **OFF:** **no** `/rest/v1/mt5_import_staging` query fires.
- Flag **ON:** exactly **one** `GET /rest/v1/mt5_import_staging?...`.
  - no POST
  - no PATCH
  - no DELETE
  - no RPC
- GOU26 row renders:
  - `needs_mapping`
  - `open`
  - `position_id=305830528`
  - `position_state=open`
  - `contract_size=300`
  - `instrument_class=futures`
  - `product_id_candidate=—`
  - `source_account` masked
  - no SSF warning (correct — GOU26 is futures, csize 300)
- No confirm / dismiss / group / create-draft / create-trade / materialize / resolve / delete action
  buttons present.
- Read-only / "not Journal trades" caption visible.

---

## 4. Read-only boundary confirmations (net 0D-0 diff `09842d7..267e579`)

- no `.insert(`
- no `.update(`
- no `.delete(`
- no `.upsert(`
- no `.rpc(`
- no `service_role`
- no `SUPABASE_SERVICE_KEY`
- no `mt5_import_cursors`
- no `mt5_import_groups`
- no `select("*")` on staging (explicit column list)
- no SQL / MT5 / writer run
- no Supabase mutation
- no `.env` created or staged
- no generated JSON / output / pycache / pyc staged

DB-level backstop (Phase 0A, applied & verified): `authenticated` has SELECT-only on
`mt5_import_staging` (RLS `user_id = auth.uid()`), **no** write grant/policy — so browser writes to
staging are server-impossible regardless of client code.

---

## 5. Interpretation

- The Settings-embedded MT5 Inbox is **production-safe and read-only**, behind a default-OFF local flag,
  with no DB change.
- It surfaces the real 0C-3a staged GOU26 open row in THUS UI without creating trades, drafts, groups,
  mappings, or any DB write.
- This does **not** materialize anything into THUS trades and does **not** run any import.

---

## 6. Still gated / not done

- promote MT5 Inbox to a dedicated nav tab (deferred until actions exist)
- 0C-3b close/partial deal writer
- 0C-3c balance + cursor
- 0C-3d lifecycle reconcile
- 0D-1 confirm/dismiss/group actions (write path via RPCs)
- Phase 1 materialization into THUS trades
- product resolver / mapping, DELTAU26 mapping
- screenshots / Storage
- scheduling / automation
- deploy decision (still local; prod app remains `09842d7`)

---

## 7. Result

**`PHASE_0D0_LOCAL_BROWSER_SMOKE_PASS`** — recorded docs-only. Final good HEAD `267e579`. Ready for
Codex implementation review of the 0D-0 read-only Inbox before any deploy decision.
