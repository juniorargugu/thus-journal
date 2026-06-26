# MT5 Auto Draft Import — Phase 0C-3 Writer Design (split → **0C-3a open-only** first)

**Type:** Planning / design record (docs-only) · **Date:** 2026-06-26
**Status:** `DESIGN — NOT IMPLEMENTED` · **Codex verdict on 0C-3:** `PASS_WITH_CHANGES / NEEDS_DESIGN_PATCH`
→ this revision **splits** the first writer into a much smaller **0C-3a open-only** slice.
**Production app baseline:** `origin/main` = `09842d7` (unchanged) · **Repo HEAD at authoring:** `5026a99`
**Depends on:** Phase 0A schema/RLS/RPC **APPLIED & VERIFIED** (see [`phase_0a_apply_closeout.md`](phase_0a_apply_closeout.md)); 0C-2 dry-run row builder (`ops/mt5_import/build_rows.py`).

> Planning only. **No code, no `writer.py`, no `staging_db.py`, no `.env`, no Supabase client, no SQL,
> no MT5 write.** This defines the first service_role writer slice and its guardrails for a Codex
> delta review **before** any implementation.

---

## 1. Why split — first service_role write must be tiny

The reviewed 0C-3 plan (open + deals + balance + cursor + lifecycle reconcile) is too large for a
*first* service_role write. The first slice is reduced to **opens only**, single table, no cursor, no
reconcile — the smallest thing that proves the write path is safe and idempotent. Everything else is a
later, separately-reviewed sub-slice.

| Sub-slice | Scope | Status |
|---|---|---|
| **0C-3a** | write eligible `kind='open'` rows → `mt5_import_staging` only | **this design** |
| 0C-3b | deals (`close`/`partial`) insert-once by `deal_id` | deferred |
| 0C-3c | balance rows + **cursor** (`mt5_import_cursors`) | deferred |
| 0C-3d | open-lifecycle reconcile (`position_state` closed/gone) | deferred |

## 2. 0C-2 input (the writer's source) & live Phase 0A facts
- `build_rows.py` emits in-memory `mt5_import_staging`-shaped dicts; each carries dry-run meta
  `writer_eligible` + `writer_skip_reason`. `kind='unknown'` → `writer_eligible=false`. All rows
  currently `state='needs_mapping'`, `product_id_candidate=null`. DELTAU26 → csize 1000 / class ssf /
  needs_mapping / no stock hint.
- **Live grants (applied 0A):** `service_role` = SELECT/INSERT/UPDATE on `mt5_import_staging` +
  `mt5_import_cursors`, SELECT on `mt5_import_groups`. Browser SELECT-own only. `service_role` bypasses RLS.
- **Idempotency indexes are PARTIAL unique** (see §5).

## 3. 0C-3a scope (open-only)

**In scope:** write **only** eligible `kind='open'` rows, **only** to `mt5_import_staging`, via
explicit SELECT-then-INSERT/PATCH (no upsert).

**Explicitly OUT for 0C-3a:**
- ❌ deals (`close`/`partial`), ❌ balance, ❌ `unknown` rows
- ❌ cursor / any `mt5_import_cursors` touch
- ❌ open-lifecycle reconcile (no `gone`/`closed` marking)
- ❌ `mt5_import_groups`, ❌ RPC calls, ❌ THUS trade creation
- ❌ Product/Symbol resolver (rows stay `needs_mapping`), ❌ Storage, ❌ GUGU, ❌ app deploy

## 4. Architecture (proposed; NOT created in this slice)
- **`ops/mt5_import/writer.py`** — entrypoint: read MT5 (read-only, reuse 0C-2 path) → `build_rows` →
  filter to eligible **opens only** → sanitize → build a **write-plan** → dry-run prints the plan /
  armed mode executes opens → done (no cursor, no reconcile).
- **`ops/mt5_import/staging_db.py`** — narrow, table-allowlisted PostgREST client. For 0C-3a it exposes
  ONLY: `select_open_by_key()`, `insert_open()`, `patch_open_allowlisted()`. `ALLOWED_TABLES =
  {"mt5_import_staging"}` for this slice (cursors added in 0C-3c). **No** generic `write(table,…)`,
  **no** RPC, **no** `groups`/`trades`/Storage path, **no** `DELETE`.
- Reuse `build_rows.py`, `common.py`, `tz.py` unchanged.

## 5. PostgREST partial-index mitigation — **NO upsert** (Codex item 2)

Phase 0A's idempotency indexes are **PARTIAL UNIQUE** with predicates, e.g.:
```
unique (user_id, source_account, position_id) where kind='open' and position_id is not null
```
**Do NOT rely on PostgREST `on_conflict` / `merge-duplicates` / `ignore-duplicates`** against these:
a plain `on_conflict=user_id,source_account,position_id` does not carry the `where kind='open' and
position_id is not null` predicate, so PostgREST cannot reliably target the partial index (it may
error "no unique constraint matching" or behave unexpectedly). **0C-3a avoids upsert entirely.**

**0C-3a write strategy (explicit, multi-call):**
1. **SELECT** the existing open row by **exact key**: `kind='open'` AND `user_id` AND
   `source_account` AND `position_id`.
2. **Absent** → **INSERT** the full sanitized open row.
3. **Present** → **PATCH** only allowlisted fields (§7) filtered by that exact key.
4. **INSERT race → duplicate error** → **re-SELECT** the exact key; treat as a duplicate success (or
   PATCH allowlisted fields). Never blanket-upsert, never `merge-duplicates`.

Multi-call (select→insert/patch) is acceptable **only because 0C-3a is open-only and low-volume**
(§11). Deals/cursor/reconcile slices may need explicit duplicate handling or a reviewed SQL RPC for
atomicity — out of scope here.

## 6. Secrets / env plan
- **Write mode requires** local `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` (git-ignored `.env`/env);
  **hard-STOP if missing**. No MT5 secrets (attach to running terminal). `.env.example` stays
  value-free. **Never read in dry-run; never logged; service key never printed; sanitized tracebacks.**
- **`--user-id` (UUID) + `--source-account` stay required CLI args** (no env default → no silent
  cross-account write). Hard-STOP if `account_info().login != --source-account`.

## 7. Three-key write gate (Codex item 3) + max write count (item 4)

**Dry-run is the default** and must: construct **no** Supabase client, read **no** service_role env,
write **nothing** (only prints the write-plan).

**Arming a write requires ALL THREE:**
- `--write` (CLI flag), **and**
- `--confirm WRITE_STAGING` (exact literal), **and**
- `MT5_WRITE=1` (env).

Plus, before executing: `SUPABASE_URL`+`SUPABASE_SERVICE_KEY` present, source-account == terminal
login, eligible set contains **no** `writer_eligible=false`, and the planned write count ≤
**`--max-write-count N`** (default **3**). If planned writes exceed the limit → **refuse** unless
explicitly raised. **First smoke writes 1–3 open rows only.** A bare `python writer.py …` can never write.

## 8. Writer eligibility + unknown handling (Codex item 5)
0C-3a candidate set = rows with `kind='open'` **and** `writer_eligible is True` **and** `position_id`
present. **If any `kind='unknown'` (or `writer_eligible=false`) row is in the write-candidate set →
hard-STOP with a loud summary** for the first service_role smoke (do not silently exclude). 0C-3a must
never write `kind in ('unknown','close','partial','balance')` — those are later reviewed sub-slices.

## 9. Row sanitization / schema-key stripping
Project each eligible open row onto the exact `STAGING_COLUMNS` allowlist before any request → drops
`writer_eligible`, `writer_skip_reason`, and any non-schema key. A row missing a required non-null
column (`user_id`, `source_account`, `kind`, `position_id`) → STOP run (builder/schema drift). PostgREST
only ever receives real staging columns.

## 10. Existing-open PATCH: filters + state exclusions (Codex item 6)
- **PATCH filter (exact key):** `kind='open'` AND `user_id` AND `source_account` AND `position_id`.
- **Skip + loud report (no patch)** any existing row with `state='materialized'` or `state='dismissed'`
  (browser/RPC has taken it over — the writer must not touch it). Preferred for first smoke: **skip +
  report**; do not STOP the whole run for these (but count them prominently).

## 11. Field allowlist for existing open rows (Codex item 7)

**MAY PATCH (0C-3a):** `last_seen_open_at`, `price`, `volume`, `mt5_time`, `mt5_time_msc`,
`mt5_time_raw_epoch`. (`updated_at` is set by the DB trigger — not sent.)

**`raw` update: DEFERRED for 0C-3a** (reduces payload/noise; revisit in a later slice).

**NEVER PATCH:** `state`, `confirmed_group_id`, `dismissed_at`, `materialized_trade_id`,
`materialized_at`, `first_seen_open_at`, `symbol_raw`, `normalized_symbol`, `instrument_path`,
`instrument_class`, `contract_size`, `digits`, `side`, `open_time`, `product_id_candidate`, `kind`,
and any user/group/note field. (These are insert-only or browser/RPC-owned; instrument fields feed the
materialize tripwire and must not churn.) The PATCH payload is built solely from the MAY-PATCH constant set.

## 12. Cursor — DEFERRED (Codex item 8)
**No cursor writes in 0C-3a; no `mt5_import_cursors` touch.** Cursor advancement is deferred to the
deal-writing slice (0C-3c). When added, the cursor must advance **only after every write in the
cursor-covered range is inserted or confirmed duplicate**; unknown/skipped rows must **not** be
silently cursor-advanced past without a reviewed policy.

## 13. Lifecycle reconcile — DEFERRED (Codex item 9)
**No reconcile in 0C-3a** — absent opens are NOT marked `gone`/`closed`. A later reconcile slice (0C-3d)
requires: successful `account_info` + `positions_get` + bounded `history_deals_get`, source-account
match, **no MT5 partial failure**, a **suspicious-drop guard** (don't mass-mark `gone` on a transient
empty read), and a grouped/materialized policy — updating `position_state` only, never `state`, never delete.

## 14. Error handling / partial-failure plan (Codex item 11)
- Multi-call PostgREST (select→insert/patch) is acceptable **only** for 0C-3a open-only.
- Any write error (non-2xx / network) → **STOP**, sanitized error (no key), exit non-zero. There is
  **no cursor to advance** in 0C-3a, so there is nothing to roll back beyond the partial set; written
  open rows are **idempotent / staging-only** and a re-run resolves them (re-SELECT → patch/duplicate).
- `writer_eligible=false` reaching the write path, or a row failing the schema projection → STOP (loud).
- service key/URL missing in write mode, or source-account mismatch → hard-STOP before any write.
- Later deals/cursor/reconcile may need explicit duplicate handling or a reviewed SQL RPC for atomicity.

## 15. Smoke / validation plan (narrowed — Codex item 10)
1. **Preflight read:** `count(*)` of `mt5_import_staging` (read-only) + the exact target open key(s).
2. **Dry-run:** print the exact write-plan (planned INSERT/PATCH per open, sanitized), **no client constructed**.
3. **Armed write** (`--write --confirm WRITE_STAGING` + `MT5_WRITE=1`, `--max-write-count 3`,
   `--source-account <real login>` matching terminal): write **1–3 open rows**.
4. **Idempotency:** immediate **re-run → 0 new rows** (re-SELECT finds them; patch-or-duplicate).
5. **Boundary asserts:** `mt5_import_cursors` unchanged (0 touched); `mt5_import_groups` unchanged;
   `trades`/`products`/`portfolio_summary`/`notes`/`trade_groups` unchanged; **no `deal`/`balance`/
   `unknown` rows inserted**; DELTAU26 rows (if written) remain `state='needs_mapping'`.
6. **Browser RLS** SELECT-own check later (Junior sees only his rows). **No app deploy** (prod stays `09842d7`).

## 16. Rollback / cleanup stance
**No delete by default**; the few smoke rows are real staging rows (fresh mirror, no downstream
consumer). If cleanup is ever needed → a **separate reviewed cleanup prompt** (user-run SQL, exact key
filter). No ad-hoc SQL deletes, no writer delete path.

## 17. Explicit non-scope (0C-3a)
Phase 0D Inbox UI; grouping; materialization; product resolver; screenshots; Storage; scheduled
automation / Windows Task Scheduler; Netlify/deploy; GUGU; THUS trade/product/portfolio/notes/
trade_groups creation; `mt5_import_groups` writes; lifecycle/materialization RPCs; deals/balance/cursor/
reconcile (later sub-slices).

## 18. Risks and mitigations
| Risk | Mitigation |
|---|---|
| **service_role leak** | local git-ignored `.env`; never logged; sanitized tracebacks; never browser/Netlify/repo |
| **PostgREST upsert misfires on partial index** | upsert banned; explicit SELECT→INSERT/PATCH by exact key |
| **Blanket update clobbers browser `state`** | field-level PATCH allowlist (§11); `state`/`confirmed_group_id`/`materialized_*` never sent |
| **Patching a materialized/dismissed open** | skip + loud report (§10) |
| **Accidental write from default command** | three-key gate (`--write` + `--confirm WRITE_STAGING` + `MT5_WRITE=1`); dry-run constructs no client |
| **Runaway write volume** | `--max-write-count` (default 3); refuse above limit |
| **Cross-account write** | `--source-account` required CLI + hard-STOP on terminal-login mismatch |
| **Unknown/deal/balance leak into write** | candidate set = opens only; hard-STOP if any unknown present |
| **Generic table write reaching groups/trades** | `staging_db.py` allowlist = `{mt5_import_staging}` only; no generic writer/RPC |
| **Stray non-schema key to PostgREST** | project each row onto `STAGING_COLUMNS` first |
| **DELTAU26 → stock DELTA** | no resolver; rows stay `needs_mapping`, candidate=None; tripwire is the materialize backstop |
| **Cursor advanced past skipped rows** | no cursor in 0C-3a (deferred) |

## 19. Recommendation
**READY_FOR_CODEX_DELTA_REVIEW** — 0C-3a is now the smallest safe first service_role write
(opens-only, single table, SELECT→INSERT/PATCH with no upsert against the partial indexes, three-key
gate + max-write-count, unknown hard-STOP, field-level PATCH allowlist, materialized/dismissed skip, no
cursor, no reconcile). As the **first service_role writer**, it still warrants a short delta review
before implementation.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Codex requested splitting 0C-3 into a smaller open-only writer and patching the design before any service_role implementation.
Next action: Route the patched 0C-3a design to Codex delta review, then decide whether to implement the open-only writer.
