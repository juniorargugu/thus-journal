# Glossary

Quick definitions for the acronyms, phase codes, and status tags used across the THUS
Project Bible. A stub — extend it as new terms appear. When a term's meaning is not yet
confirmed against source, it is marked **NEEDS VERIFICATION**.

---

## Trade grouping (G-series)

- **Grouping** — the non-destructive successor to the retired "Merge": associating
  multiple executions as one trade *idea* via metadata, without collapsing them into a
  synthetic row.
- **G0–G6** — the phased grouping roadmap:
  - **G0** — design only (locked 2026-05-20).
  - **G1** — schema + RLS (`trade_groups` table, `trades.group_id`); applied 2026-06-08.
  - **G2** — first persistence: create/ungroup RPCs + group-aware display/loader; applied
    + deployed default-off (see **v0.3 / v0.4**).
  - **G3** — open-position create + ungroup UI; removes dead legacy-merge handlers.
  - **G3.5** — closed-trade retroactive grouping UI (optional, later).
  - **G4** — group pre/post notes + child-note timeline.
  - **G5** — `[Insert GUGU summary]` button (reads `checkin_events`); the first Journal↔GUGU
    integration hook.
  - **G6** — legacy `isMerged` cleanup (gated on near-zero `isMerged` rows + approval).
- **v0.3 / v0.4 / v0.5** — G2 UI increments: **v0.3** = create-only UI (local);
  **v0.4** = group-aware loader/render, deployed default-off at v3.23.0; **v0.5** = ungroup
  UI (design approved, deferred).
- **`create_trade_group_v1` / `ungroup_trade_group_v1`** — the SECURITY DEFINER RPCs that
  write only `trades.group_id` (+`updated_at`), never `raw`.
- **write gate** — the `tj_trade_group_write_v01` localStorage flag that must be enabled
  before any real grouping write; **default-off**, human-approved to enable.
- **real group** — a persisted (non-rollback) trade group kept in the DB. Keeping one is
  user-gated; currently **none kept** (DB has 0 active groups, 1 archived from a rollback
  smoke).
- **P/L invariant** — all reducers walk raw `trades[]` and ignore `group_id`; group totals
  are computed at render time. Protects against the double-count bug class.

## MT5 import (0-series)

- **MT5** — MetaTrader 5, the broker platform whose executions are mirrored into THUS.
- **MT5 0A** — schema/RLS/RPC phase (staging/groups/cursors tables); applied + verified
  2026-06-25.
- **MT5 0B** — the read-only probe phase (terminal probe findings feeding 0A/0C design).
- **MT5 0C** — the local Python tooling phase (probe → dry-run builder → gated writer),
  incl. **0C-3a** (first armed open write) and **0C-3b** (first armed close-deal write).
- **MT5 0D** — the read-only **MT5 Inbox** UI phase (**0D-0** embed, **0D-1** clarity),
  behind default-off `tj_mt5_inbox`.
- **MT5→staging writer** — the local Python writer that inserts/patches rows in the MT5
  *staging* tables. Exists; has done armed staging writes under an explicit three-key gate.
- **staging→trades materializer** — the (unbuilt, **hard-gated**) path that would turn
  confirmed staged rows into Journal `trades`. Distinct from the staging writer; armed
  staging smokes are **not** precedent for it.
- **`needs_mapping`** — state for a staged instrument with no confirmed product mapping.
- **cross-account gate** — a hard STOP unless the MT5 terminal login is the expected
  account (`301102520`).
- **dry-run harness** — the offline fixture-driven rehearsal tool (no network / Supabase /
  MT5); merged as inert tooling.

## Persistence / Journal

- **P0 / P1 / P2** — the durable-persistence program phases: **P0** = close-save
  durability (the confirmed close-persistence bug + fix); **P1** = edit/update/note save-
  first durability; **P2** = full stack (single-row durable writes for every mutation,
  full-array writer retired). All **LIVE**.
- **single-row durable write** — saving one trade via `db.saveTrade` / `commitUpdateTrade`,
  awaited and confirmed (`.select(...)`), before the UI reports success. Replaces the
  optimistic + debounced full-array writer.
- **`57014`** — the PostgREST/Postgres statement-timeout error that large `raw` payloads
  (inline base64 images) triggered; the driver behind image externalization + single-row
  writes.
- **image externalization** — moving trade screenshots from inline base64 in `raw` to a
  private Supabase Storage bucket (`trade-images`), resolved to signed URLs at render.

## Data / schema terms

- **`raw`** — the canonical JSONB blob on a `trades` row; the single source of truth for
  all P/L. Metadata layers must never mutate it.
- **`group_id`** — the FK column on `trades` pointing to a `trade_groups` row; grouping
  membership. Never stored inside `raw`.
- **`tradeGroupIds`** — the separate in-app `id → group_id` map produced by `db.loadAll`;
  keeps `group_id` off the `raw`/trade objects so the P/L invariant holds.
- **`isMerged`** — a legacy flag on old row-collapsing "Merge" rows. New grouping rejects
  `isMerged` children; the `20260708` RPC guard enforces this server-side
  (`merged_child_not_allowed`).
- **`APP_VERSION`** — the single-source app version constant in `index.html` (currently
  **v3.23.0**), surfaced as the UI version badge.

## Operations / process

- **Lane A–I** — the tracks in `artifacts/pipeline/PIPELINE_STATE.md`: A deploy batch,
  B G2 grouping, C product/MT5 preview UX, D MT5 auto draft import, E GUGU bot, F merge/
  grouping boundary, G RLS/security, H image externalization, I mentor/GUGU notes.
- **autopilot** — the convenience layer for *safe, reviewed* forward motion under strict
  gates (MAY / MUST STOP / MUST NOT); see `artifacts/pipeline/AUTOPILOT_RULES.md`.
- **review chain** — GPT (plan) → Claude Code (implement + report) → Codex (review) → GPT
  (adversarial review) → human deploy + smoke. "Codex PASS" / "ChatGPT PASS" are its gates.
- **default-off flag** — a capability shipped dark behind an unset `tj_*` localStorage
  flag; enabling it is a separate, human-approved step.

## GUGU

- **GUGU** — the AI-native trading copilot that is the North Star; long-term primary
  consumer of THUS data.
- **GUGU v1** — the first bot architecture (stacked hardcoded gates / prefilters / zone
  rules); abandoned for a maintenance-death-spiral lesson.
- **GUGU v2** — the current, **active** build in the sibling `thus-trading-bot` repo:
  memory-stream + reasoning, tools, capture bot.
- **capture-only** — the allowed production behavior: the check-in bot records
  `checkin_events` etc.; no autonomous cognition.
- **cognition freeze** — the policy that forbids autonomous GUGU cognition against
  live/production data on any repo without explicit approval. Does **not** forbid reviewed
  v2 development in `thus-trading-bot`.
- **Days 1–8 / "Day 4"** — the reported GUGU v2 sprint (Days 1–4 complete: memory, cold
  start, agent+tools, Telegram bot; Days 5–8 in progress: observation cycle, adversarial
  testing, cost monitoring; VPS at Day 8). **NEEDS VERIFICATION** until cross-repo capture.
- **hard cost ceiling / per-cycle token-cost logging** — the required economic guardrails
  before v2 runs autonomously (v1 reportedly leaked ~$5/day; **NEEDS VERIFICATION**).

## Status tags

See [`README.md`](./README.md) → "Status vocabulary" for the authoritative table.

- **DONE** — completed/closed out; may be local-only.
- **LIVE** — app bundle shipped to production and verified.
- **APPLIED** — a DB/RPC/schema/migration change executed against live Supabase/project
  state (distinct from LIVE and DONE); usually paired with **VERIFIED**.
- **DESIGNED / REVIEWED** — design written / passed a review pass; not yet applied.
- **DEFERRED** — postponed with a documented trigger to revisit.
- **GATED** — blocked behind explicit human approval.
- **RESEARCH / VISION** — under investigation / long-horizon intent.
- **NEEDS VERIFICATION** — asserted somewhere but not confirmed against live state or
  current docs.
- **Qualifier patterns** — e.g. *DONE (local)*, *DONE (reviewed)*, *LIVE (default-off)*,
  *APPLIED + VERIFIED* — read the suffix as part of the tag.
