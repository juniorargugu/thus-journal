# MT5 Auto Draft Import — Phase 0A-r3 Design Plan

**Artifact date:** 2026-06-22
**Type:** Planning record (docs-only)
**Production baseline:** `origin/main` = `2c2c8d2` (Product/Symbol/Live-Price + DELTA stock live)

---

## 1. Status

- ✅ **Design approved** — Phase 0A-r3 received the final ChatGPT design pass (after Codex `PASS_WITH_CHANGES` → r3 patch).
- ✋ **Schema / RPC apply: GATED (HOLD)** — no SQL applied, no migrations, no Supabase writes.
- ✋ **Implementation: GATED (HOLD)** — no reader, no staging writer, no Inbox UI, no materialization.
- ⏸️ **Not priority-active yet** — parked behind higher-priority pipeline items (see §9).

Lineage: `0A` → `0B` probe (read-only) → `0A-r2` → Codex review (`PASS_WITH_CHANGES`) → `0A-r3` → final ChatGPT pass → **this artifact**.

## 2. Approved architecture

- **`mt5_import_staging`** — raw MT5 leg/deal rows (open snapshots + close/partial deals).
- **`mt5_import_groups`** — user-confirmed trade ideas; **one pre-note / thesis / plan per scaled-in idea**.
- **`mt5_import_cursors`** — reader resume marker per `(user, account)`.
- **Python reader** (Junior's PC, `service_role`) writes **only** staging + cursors.
- **Browser** reads staging/groups (SELECT-only on staging).
- **User manually confirms** grouping and draft materialization.
- **No auto-open, no auto-close, no auto-merge, no auto-materialize.** MT5 is an input source only; THUS stays user-confirmed.

## 3. Critical Phase 0B findings (probe, read-only)

- Account is **RETAIL_HEDGING** (`margin_mode=2`) → scale-ins are **multiple simultaneous positions with distinct `position_id`** (observed: 3 GOU26-long legs, vols 1/2/3).
- **Open idempotency = `position_id`** (stable; `ticket==position_id` only coincidentally for current opens — not assumed).
- **Close/partial idempotency = `deal_id`** (150/150 unique over 90 days).
- **Every trade deal carries `position_id`** → close/partial matches back through it.
- 🔴 **`DELTAU26` = TFEX Single Stock Future, `contract_size 1000`**, normalizes to `DELTA` → **must NOT map to the THUS DELTA stock preset (`contractSize 1`)** — would be a **1000× P/L error**. Routes to `needs_mapping` until a DELTA-futures product exists.
- **MT5 time behaves like Asia/Bangkok wall-clock** (+7 vs true UTC) → store true UTC (`wall − 7h`), retain raw epoch + `time_msc`.

## 4. r3 design locks

- **RPC-only lifecycle transitions** (`SECURITY DEFINER`); no direct authenticated UPDATE on staging.
- **Browser SELECT-only on staging** (no INSERT/UPDATE/DELETE policy or grant).
- **`confirmed_group_id` FK `ON DELETE SET NULL`**; ownership enforced **inside RPCs**, never trusted to FK/RLS.
- **Fail-open `instrument_class`** — no rejecting CHECK; unknown broker paths classify as `'unknown'`, never block ingest.
- **Open-row lifecycle fields:** `position_state` (`open`/`closed`/`gone`), `first_seen_open_at`, `last_seen_open_at`; reader reconcile marks stale opens `gone` without deleting raw rows.
- **Materialize-time tripwire** — `contract_size` + `instrument_class` / product compatibility enforced **inside `mt5_mark_materialized`**; `product_id_candidate` is a hint only and cannot bypass it.
- **Server-side group aggregate recompute** — `leg_count`, `total_volume`, `weighted_avg_price`, `suggested_start_time`, `suggested_end_time` computed in `mt5_confirm_group`, recomputed on membership change.
- **`updated_at` BEFORE UPDATE trigger** on all three tables.
- **`screenshot_url` only, never base64** (deferred to Phase 3; Supabase Storage URL).

## 5. Proposed tables (summary)

- **`mt5_import_staging`** — surrogate `id`; `user_id`; `source_account`; `kind` (open/close/partial/balance/unknown); `symbol_raw` / `normalized_symbol` / `instrument_path` / `instrument_class` (no CHECK) / `contract_size` / `digits`; `product_id_candidate` (hint); `side` / `volume` / `price`; `open_time` / `close_time` / `mt5_time` (true UTC) / `mt5_time_msc` / `server_tz`; ids `position_id` / `deal_id` / `order_id` / `ticket` / `external_id`; `commission` / `swap` / `fee` / `broker_profit`; lifecycle `position_state` / `first_seen_open_at` / `last_seen_open_at`; `raw jsonb`; `state`; `import_group_key`; `confirmed_group_id` (FK ON DELETE SET NULL); `materialized_trade_id` / `materialized_at` / `dismissed_at`; `error_message`; `screenshot_url`; `created_at` / `updated_at`.
  - Idempotency: `unique (user_id, source_account, position_id) where kind='open'`; `unique (user_id, source_account, deal_id) where deal_id is not null and kind in ('close','partial')`; balance dedup partial unique.
- **`mt5_import_groups`** — `id` (preserved into trade `raw.mt5_group_id` for future G2 migration); `user_id`; `source_account`; `normalized_symbol` / `instrument_class` / `side`; `state` (grouped/materialized/dismissed); `prenote` / `thesis` / `plan`; server-computed `suggested_start_time` / `suggested_end_time` / `leg_count` / `total_volume` / `weighted_avg_price`; `import_group_key`; `materialized_trade_id` / `materialized_at`; `created_at` / `updated_at`.
- **`mt5_import_cursors`** — `user_id` + `source_account` (PK); `last_seen_deal_id`; `last_seen_time`; `server_tz`; `updated_at`. Both deal-id and time retained (time bounds the deal-history query; deal_id dedups the final second). Optimization only — idempotency indexes guarantee no duplicates if lost.

## 6. Proposed RPCs (design only — NOT applied)

- **`mt5_confirm_group(leg_ids, prenote, thesis, plan, allow_mixed)`** — verifies `auth.uid()` owns all legs, legs are `open` + `new|group_suggested` + ungrouped + same `source_account` (and same class/symbol/side unless `allow_mixed`); computes aggregates server-side; creates the group; stamps `confirmed_group_id` + `state='grouped'`.
- **`mt5_set_leg_state(leg_ids, new_state)`** — controlled transitions only (e.g. `→ dismissed`, `needs_mapping → new`, `new ↔ group_suggested`); no arbitrary jumps; no `→ materialized` here.
- **`mt5_mark_materialized(group_id, trade_id, product_id, product_contract_size, product_class)`** — called **after** the browser durably wrote the THUS draft/trade via the single-row path; enforces ownership + the `contract_size`/class **tripwire** before flipping `materialized`.
- **`mt5_resolve_mapping(leg_ids, product_id)`** (optional, later) — `needs_mapping → new` once a compatible product exists; re-runs the class/contract_size check.

**These are sketches only.** No RPC bodies are implemented or applied.

## 7. Important STOP conditions

- **No schema/RPC apply without explicit user approval.**
- **No browser direct staging writes** (bypassing RPCs).
- **No reader writes to `trades` / `products` / `portfolio` / `notes`.**
- **No `addTrades` / full-array autosave materialization** — drafts/closes use the durable single-row path only.
- **No `DELTAU26` → DELTA-stock mismatch** (tripwire must fire; csize 1000 ≠ csize 1).
- **No base64 screenshots** in any staging or trade row.
- **No GUGU capture-only boundary violation** — the MT5 reader is a separate input-only role.
- **No dependency on unimplemented G2 / `trade_groups`** — preserve `mt5_import_groups.id` for future migration instead.

## 8. Deferred / future work

- Re-run **Codex review** before schema apply if significant time has passed.
- **Apply only on a staging/branch Supabase first**, never prod-first; confirm create-only (no diff to existing tables/policies).
- **Phase 0C** — staging mirror writer (reader → staging), after schema reviewed + applied.
- **Phase 0D** — THUS read-only MT5 Inbox (no create-draft button).
- **Phase 1** — manual open-draft materialization via durable `commitOpen`, with grouped/merged draft support.
- **Phase 2** — close/partial drafts keyed by `deal_id`, matched to grouped legs.
- **Phase 3** — screenshots via Supabase Storage URL only.

## 9. Priority note

The MT5 track is valuable but **stays parked** until higher-priority pipeline items clear:

1. **P2 residual full-array `saveTrades` autosave cleanup** (recurring 500 / 57014 on the ~11 MB base64-image payload).
2. **Product mapping foundation** for TFEX futures / single-stock futures / stocks (class-aware resolver).
3. **DELTA single-stock-future product decision** (the `DELTAU26` csize-1000 instrument has no THUS product yet; the stock preset must not absorb it).

---

*Recommendation at time of writing: `READY_FOR_FINAL_REVIEW` cleared; schema/RPC apply remains gated pending an explicit user GO and a fresh pre-apply Codex pass.*
