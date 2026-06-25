# MT5 Auto Draft Import — Phase 0C Staging Writer Design

**Type:** Planning / design record (docs-only) · **Date:** 2026-06-25
**Status:** `DESIGN — NOT IMPLEMENTED` · **Codex verdict:** `PASS_WITH_CHANGES` → this revision folds in the requested guardrails.
**Production app baseline:** `origin/main` = `09842d7` (unchanged) · **Repo HEAD at authoring:** `1752c6a`
**Depends on:** Phase 0A schema/RLS/RPC **APPLIED & VERIFIED** (2026-06-25) — see [`phase_0a_apply_closeout.md`](phase_0a_apply_closeout.md).

> This artifact is **planning only**. No code, no `probe.py`, no `.env`, no `.env.example`, no `.gitignore` change, no MT5 run, no Supabase write. It defines the gated slices and the guardrails each slice must encode **before** any implementation prompt.

---

## 1. Current Phase 0A DB state (the only surface 0C may ever touch)
Live in `public` (project `wtfwynvvkiuottjnmozu`): `mt5_import_staging`, `mt5_import_groups`, `mt5_import_cursors`; helper `mt5_set_updated_at`; RPCs `mt5_confirm_group` / `mt5_set_leg_state` / `mt5_mark_materialized` (SECURITY DEFINER, browser-side). `mt5_resolve_mapping` deferred/not created.
**Grants relevant to the writer:** `service_role` = SELECT/INSERT/UPDATE on `mt5_import_staging` + `mt5_import_cursors`, SELECT on `mt5_import_groups`. Browser = SELECT-own only; no browser/anon write path.
→ The reader writes **staging/cursors directly via service_role**; the RPCs are **browser-side lifecycle** and are **never called by the writer**.

## 2. Architecture (local Python on Junior's PC)
MT5 terminal binding is **Python-only** (`MetaTrader5` pip pkg, Windows); the existing `price_pusher` is already Python on this machine. Node cannot bind the terminal, so 0C is Python (diverges from the `ops/p2_5e` Node precedent, but follows its **read-only-first, local-only, service_role-never-shipped** discipline).

```
MetaTrader5 terminal (read)        Supabase (service_role, LOCAL only)
   positions_get() ─┐                 ┌─ upsert mt5_import_staging (open/close/partial/balance)
   history_deals_get()├─► transform ──┤  update open lifecycle (allow-listed fields only)
   account_info()   │   (UTC, keys,   └─ upsert mt5_import_cursors (resume marker)
   symbol_info()  ──┘    normalize)
                         └─ dry-run prints rows; never RPCs / groups / trades / Storage
```

## 3. Gated sub-slices (each strictly larger surface than the last)
- **0C-0 — Repo & Secrets Hygiene** *(NEW, Codex-requested; must precede any secrets-bearing slice)*.
- **0C-1 — read-only MT5 probe** — reads MT5, prints; **no Supabase client, no secrets, no file with secrets**.
- **0C-2 — dry-run row builder** — full transform → prints / ignored local JSON of the exact staging rows + cursor it *would* write; **no Supabase write**.
- **0C-3 — gated writer** — behind `MT5_WRITE=1`; idempotent upserts to staging/cursors **only**, with field-level update allowlists; default is dry-run.

---

## 4. 0C-0 — Repo & Secrets Hygiene gate (NEW)
**Purpose:** make the repo safe to *hold* MT5/service_role tooling **before** any `.env`, MT5-login workflow, service_role workflow, or generated account-data artifact can exist. This is a pure repo-hygiene slice.

**Scope (0C-0):**
- Track `.gitignore` (it is currently **untracked** and contains only `.netlify`).
- Add secret/local-artifact ignore patterns **before** any secret-bearing file exists.
- **No** probe code, **no** MT5 run, **no** Supabase, **no** service_role, **no** `.env`/`.env.example` creation in 0C-0.

**Recommended `.gitignore` patterns** (to be applied in the 0C-0 *implementation* slice — NOT in this docs patch):
```gitignore
# secrets / env
.env
.env.*
!.env.example
*.env
ops/mt5_import/.env
ops/mt5_import/.env.*
!ops/mt5_import/.env.example
# key material
*.key
*.pem
*.p12
*.pfx
*_service_role*
*service_role*
# local/generated MT5 dumps that may contain account data
ops/mt5_import/out/
ops/mt5_import/*.json
artifacts/mt5_auto_draft_import/0c_local_*.json
artifacts/mt5_auto_draft_import/0c_dryrun_*.json
```
**Over-ignore caution:** keep committed review docs safe — the `ops/mt5_import/*.json` and `0c_*_*.json` ignores are intentional (those carry account data). Any dry-run artifact meant to be **committed for review must be redacted first**; raw/account-bearing dumps stay **ignored** (`ops/mt5_import/out/` or `0c_local_*`). The negation `!.env.example` keeps a committed, value-free template.

## 5. 0C-1 — read-only probe (tightened)
The safest first code (zero write surface, zero Supabase surface):
- **Must NOT import or initialize a Supabase client.**
- **Must NOT require** `SUPABASE_URL` or `SUPABASE_SERVICE_KEY`.
- **Must NOT write any file containing secrets** (prints to stdout; any `--out` is a redacted, ignored local file only).
- **Should attach to the already-running, logged-in MT5 terminal** (`mt5.initialize()` with no creds). If MT5 **credentials are required**, that moves the work into a **secrets-bearing slice** which **requires 0C-0 first** (and is no longer 0C-1).
- Reads: `account_info()` (login, currency, `margin_mode` — assert hedging =2), `positions_get()`, `history_deals_get(bounded)`, `symbol_info()`; prints field inventory for 0C-2 to consume.
- If `MetaTrader5` import fails / terminal not connected → **STOP** with a clear message; **no fallback, never fabricate**.

## 6. Bounded-history requirement (all probe/writer history reads)
- **Default to a small bounded window** (e.g. `--days 7`).
- Support explicit `--from` / `--to`.
- **Refuse unbounded "all history"** (no default full-account dump).
- **Log the actual window used** (from/to/day-count).
- Initial backfill is an explicit, bounded, opt-in window — never implicit.

## 7. Timezone conversion plan
MT5 timestamps = **Asia/Bangkok wall-clock** (+7 vs true UTC). The writer converts **wall − 7h → true UTC** for `open_time`/`close_time`/`mt5_time`/`first_seen_open_at`/`last_seen_open_at`, and **preserves raw losslessly**: `mt5_time_raw_epoch` (epoch s, pre-correction), `mt5_time_msc` (epoch ms), full `raw jsonb`. **STOP/flag** if the terminal's runtime server offset ≠ +7. SQL does no tz math (Phase 0A §0) — conversion is the writer's job, isolated + unit-tested.

## 8. Idempotency plan
- **Open** key `(user_id, source_account, position_id)` where `kind='open'` (index `mt5_staging_open_uniq`).
- **Close/partial** key `(user_id, source_account, deal_id)` (`mt5_staging_deal_uniq`); **balance** same key (`mt5_staging_balance_uniq`).
- **Never blind-insert a key-less row** (Phase 0A §11.3): open w/o `position_id`, close/partial/balance w/o `deal_id` → **skip + log + `error_message`**, never insert.
- Partial-vs-full close classification is **informational only** — `deal_id` keys both, so mis-class can't break idempotency.

## 9. Cursor plan
`mt5_import_cursors` PK `(user_id, source_account)`; stores `last_seen_deal_id` + `last_seen_time`.
- **Initial run:** bounded backfill window (§6) — never "all history".
- **Repeat run:** deals from `last_seen_time − overlap` to now; `last_seen_time` bounds the query, `deal_id` unique index dedups the boundary → no missing/duplicate deals.
- Cursor is an optimization (idempotency indexes guarantee correctness if it's lost). Opens are re-read in full each run (`positions_get` is a live snapshot).

## 10. Open-position lifecycle plan
Each run against the live `positions_get` set:
- new `position_id` → INSERT `kind='open'`, `position_state='open'`, `first_seen_open_at=now`, `last_seen_open_at=now`, initial `state` (§13).
- existing open `position_id` → UPDATE **allow-listed fields only** (§11).
- staging open rows whose `position_id` is absent from the live set → `position_state='closed'` if a matching close `deal_id` was seen, else `'gone'`. **Never delete raw rows.**

## 11. 0C-3 field-level update allowlists (encode as code, not convention)
For existing open rows, the writer must **not** send a broad row-replacement/upsert payload. It may UPDATE **only** reader-owned fields:
- ✅ `position_state`
- ✅ `last_seen_open_at`
- ✅ `price`
- ✅ `volume`
- ✅ selected raw/snapshot fields **only if explicitly reviewed**
- ✅ `updated_at`

It must **never** overwrite browser/RPC-owned fields:
- ❌ `state`
- ❌ `confirmed_group_id`
- ❌ `dismissed_at`
- ❌ `materialized_trade_id`
- ❌ `materialized_at`
- ❌ any user/group notes fields (`prenote`/`thesis`/`plan` live on groups; never written by the reader)

This is an **explicit allowlist in code** (e.g. a constant set of updatable columns), not a comment/convention. `state` is set **only on initial INSERT**; reconcile/update never touches it.

## 12. Symbol normalization / mapping-hint plan
Staging-only, hint-level (mapping authority stays in the materialize tripwire):
- store `symbol_raw`, `normalized_symbol`, `instrument_path`, `instrument_class`, `contract_size`, `digits` **verbatim from `symbol_info`**.
- `product_id_candidate` is a **hint only**, optional; **never coerce** a futures/SSF symbol onto the stock preset.
- `DELTAU26` (SSF, `contract_size=1000`) → futures/SSF class, csize 1000, `state='needs_mapping'` (no DELTA-SSF product yet); **never** a stock `product_id_candidate`. The Phase 0A tripwire is the backstop; the writer must not even hint wrong.
- Writer sets initial `state='needs_mapping'` for instruments with no resolvable product, else `'new'`.

## 13. Logging / redaction requirement
- **Never log:** `SUPABASE_SERVICE_KEY`; MT5 password/login tokens; `.env` values; full connection strings containing secrets.
- **Catch exceptions without dumping env** (no traceback that prints secrets; sanitize before logging).
- **Raw JSON dumps must be redacted/truncated** unless explicitly produced as a **local, git-ignored** artifact.
- **Log:** run summary (n opens / n deals / n inserted / n updated / n gone-or-closed / n skipped-STOP), cursor advance (old→new), bounded window used, per-row decisions at `--debug`.

## 14. Data-quality STOP conditions
- Block **run:** MT5 import/connect fail; `account_info().login != MT5_SOURCE_ACCOUNT` (cross-account guard); missing required env in a writer slice; server tz offset ≠ +7; `MT5_WRITE` unset → stays dry-run.
- Block **row** (skip + `error_message`, never insert): open w/o `position_id`; close/partial/balance w/o `deal_id`; unknown deal type → `kind='unknown'`, don't fabricate.
- `contract_size` null is allowed in staging (materialize tripwire rejects null-csize later) — but log it.

## 15. Supabase write boundaries
**ONLY** `mt5_import_staging` (INSERT + allow-listed UPDATE) and `mt5_import_cursors` (UPSERT). **NEVER** `mt5_import_groups` (browser RPC owns it; writer SELECT only), **never** `trades`/`products`/`portfolio`/`notes`/`trade_groups`, **never** Storage, **never** the RPCs, **never** materialization. Enforced by a hard table allowlist + no RPC client surface.

## 16. Env / secrets plan (for the writer slices, NOT 0C-1)
**Required (0C-2/0C-3):** `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` (already on this PC), `MT5_USER_ID` (Junior's THUS auth uid — must equal the Journal's `user_id` so browser RLS SELECT-own works), `MT5_SOURCE_ACCOUNT` (MT5 login as text). **Optional:** `MT5_LOGIN`/`MT5_PASSWORD`/`MT5_SERVER`/`MT5_TERMINAL_PATH` only if not attaching to a running terminal. **Handling:** local `.env` under `ops/mt5_import/` only; never committed; never logged; service_role local/admin only — never browser/Netlify/repo. **0C-0 must land the `.gitignore` patterns first.**

## 17. Proposed files/folders (future implementation — NOT created now)
```
ops/mt5_import/
  README.md            # local-only, service_role caveat, run instructions (like ops/p2_5e/README.md)
  probe.py             # 0C-1: read-only MT5 dump, NO supabase, NO secrets
  build_rows.py        # 0C-2: MT5 reads → staging-row dicts (pure transform, unit-testable)
  writer.py            # 0C-3: dry-run default; upsert behind MT5_WRITE=1, field allowlist
  tz.py                # BKK wall-clock → true UTC (+ raw epoch/msc preserved)
  .env / .env.example  # created only in/after 0C-0+secrets slice; .env git-ignored, example value-free
```

## 18. Validation / smoke plan (per slice)
- **0C-0:** `.gitignore` tracked; a scratch `ops/mt5_import/.env` would show as ignored (`git check-ignore`); `.env.example` (when it exists) is **not** ignored; no committed secret.
- **0C-1:** probe prints non-empty opens + deals; `margin_mode=2`; `DELTAU26` csize prints **1000**; **no** Supabase import; bounded window logged.
- **0C-2:** dry-run row count reconciles with probe; UTC spot-check (BKK − 7h); every row has its stable key; DELTAU26 row = futures/SSF, csize 1000, no stock hint, `state='needs_mapping'`. No write.
- **0C-3:** small bounded first run → browser SELECT-own shows Junior's rows only (RLS); **re-run → 0 new rows** (idempotency); closed position flips `closed`/`gone`; cursor advances; **assert zero rows in `mt5_import_groups`, zero change to `trades`**.

## 19. Risks and mitigations
| Risk | Mitigation |
|---|---|
| **service_role leak** (biggest) | **0C-0 first** (gitignore) + folder `.env` + never log + never ship; `.env.example` value-free |
| Wrong UTC (server-tz assumption) | runtime offset check; STOP on ≠ +7; lossless raw epoch kept |
| DELTAU26 → stock mis-map | verbatim csize/class from `symbol_info`; no stock hint; `needs_mapping`; tripwire backstop |
| Missing/duplicate deals | bounded overlap window + `deal_id` unique index + on-conflict-do-nothing |
| Cross-account contamination | assert `login == MT5_SOURCE_ACCOUNT` before any write |
| Stomping browser-owned state | explicit field allowlist (§11); `state` set only on INSERT |
| Write beyond boundary | code allowlist of 2 tables; no RPC/groups/trades client surface |
| Unbounded history dump | default `--days 7`; refuse "all"; log window (§6) |

## 20. Non-scope (preserved)
**0C-1 specifically excludes:** Supabase writes, service_role, staging row builder, the writer. **All 0C excludes:** THUS `trades`/`products`/`portfolio`/`notes`/`trade_groups`; `mt5_import_groups` writes; materialization RPC calls; Storage; GUGU; Product/Symbol/DELTA runtime; `index.html`/THUS app runtime; Phase 0D Inbox UI; Phase 1 materialization; product-mapping resolution; screenshots; deploy.

## 21. Recommendation
**READY_FOR_0C0_PLUS_0C1_IMPLEMENTATION_PROMPT** — bundle the `.gitignore` safety (0C-0) **plus** the 0C-1 read-only probe in the first code slice, with **absolutely no Supabase / service_role / writer**. Reason to bundle: 0C-0 is pure repo hygiene and 0C-1 has zero secret/write surface, so the combined slice cannot leak or write; landing the gitignore first in the same slice removes the risk that a later secrets file precedes its ignore rule. The writer slices (0C-2 dry-run, 0C-3 gated writer) remain separate, gated, and reviewed.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Codex requested a 0C-0 hygiene gate and tighter guardrails before any MT5/service_role path is coded; this design patch folds them in.
Next action: Review the patched design, then prepare a narrow implementation prompt for `.gitignore` safety (0C-0) + the 0C-1 read-only probe only — no Supabase, no service_role, no writer.
