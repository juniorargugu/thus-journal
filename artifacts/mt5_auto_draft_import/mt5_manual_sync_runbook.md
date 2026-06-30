# MT5 Manual Open-Position Sync — Runbook

**Scope:** open positions only. Local writer → `mt5_import_staging`. No deploy, no Journal write.

This runbook explains how to make a **new MT5 open position show up in the THUS Inbox**. It exists
because the Inbox is read-only over Supabase and cannot see MT5 by itself.

---

## What "Reload" does (THUS Inbox)

- The Inbox **Reload** button only runs a Supabase `SELECT` on `mt5_import_staging` (RLS = your rows).
- It does **not** talk to MT5. It cannot discover new MT5 positions on its own.
- A new MT5 position appears in the Inbox **only after** the local writer has staged it.

## What "Sync MT5 now" means

- Run the **local writer** on this PC (`ops/mt5_import/writer.py --scope open`) with the MT5 terminal up.
- The writer reads MT5 open positions and writes `kind='open'` rows into `mt5_import_staging`
  (SELECT → INSERT new / PATCH re-seen). Then you **Reload** the Inbox to see them.
- This is **manual / on demand** — there is **no** continuous importer and **no** scheduler.

## When to use it

- You opened (or changed) an MT5 position and it is not in the Inbox yet.
- Run the **dry-run** first, confirm the plan, then run the **armed** command (when authorized).
- Finally **Reload** the THUS Inbox.

---

## STOP conditions (check before anything)

- **MT5 terminal login must be `301102520`.** If it is anything else → **STOP**
  (`STOP_SOURCE_ACCOUNT_MISMATCH`). Do not dry-run, do not arm. Switch the terminal account first.
- MT5 terminal not running / not logged in → `mt5.initialize()` fails → STOP, start the terminal.
- Dry-run plan looks wrong (more writes than expected, unexpected symbol) → **STOP**, do not arm.

## Read-only account check (optional, recommended)

Confirms the terminal login (masked) and lists current open positions. No write, no Supabase:

```
python ops/mt5_import/writer.py --scope open --days 8 \
  --user-id b77d0426-355d-4f31-b94a-1afbe8fd49fa --source-account 301102520 --max-write-count 5
```

(The dry-run below already prints the terminal login and candidate count, so this is just the dry-run.)

## Step 1 — Dry-run (mandatory, never writes)

```
python ops/mt5_import/writer.py --scope open --days 8 \
  --user-id b77d0426-355d-4f31-b94a-1afbe8fd49fa --source-account 301102520 --max-write-count 5
```

- No `--write`, no Supabase client, no service-role read — **nothing is written**.
- Read the plan: `candidate open rows`, `planned write ops`, and the per-position line
  (`open position_id=… → SELECT then INSERT-or-PATCH`).
- A source-account mismatch shows as a **WARN** in dry-run (it would HARD-STOP when armed).
- Proceed only if the planned writes are exactly the open position(s) you expect.

## Step 2 — Armed sync (only when authorized, after a clean dry-run)

Three keys are required together — this is intentional; do **not** wrap them in a one-click helper:

```
MT5_WRITE=1 python ops/mt5_import/writer.py --scope open --days 8 \
  --user-id b77d0426-355d-4f31-b94a-1afbe8fd49fa --source-account 301102520 \
  --max-write-count 5 --write --confirm WRITE_STAGING
```

- Needs local `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` in the shell env (values never printed).
- `--source-account 301102520` must equal the terminal login or the writer HARD-STOPS.
- `--max-write-count 5` caps the write count; raise it deliberately only if you have more opens.
- Opens are **PATCH on re-seen** (price/volume/last_seen) — safe to re-run; it will not duplicate.

## Step 3 — Reload THUS Inbox

- Open **Settings → MT5 Inbox** (flag ON), press **↻ Reload**.
- The new open position should appear under **📂 Open MT5 positions** (`needs_mapping`).

---

## Expected result

- Exactly the new open position(s) are INSERTed (or PATCHed if already staged).
- No close/partial/balance/unknown rows written. No cursor, no groups, no THUS trades.
- After Reload, the position is visible in the Inbox, still inert (not a Journal trade).

## Warnings / boundaries

- `source_account` **must** be `301102520`. Mismatch = STOP.
- This runbook is **open positions only** — no close/partial deals, no balance, no unknown rows.
- No `mt5_import_cursors` write — this is **not** the continuous importer.
- No `mt5_import_groups` write, no THUS trade/product/portfolio/notes write.
- No **Journal draft** creation and no **materialization** happen here (Inbox stays read-only).
- No **browser** `service_role` and no browser MT5 sync button — the writer runs **locally** only.
- Limited Netlify credits: this workflow needs **no deploy** (writer + Supabase only).
