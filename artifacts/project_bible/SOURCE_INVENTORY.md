# Source Inventory

Where the facts in this Bible come from. Every source is listed with **what it
contains**, **which subsystem** it belongs to, a **confidence** level, and whether it
**should be used** in later chapters. This inventory also calls out, explicitly, the
areas where the repo has *no* good source and future search or user-memory capture is
required (see [§7 Gaps](#7-gaps--areas-with-no-good-in-repo-source)).

- **Repo:** `thus-journal`. `origin/main` = `b94f7fd` ("docs: record G2 isMerged RPC
  migration applied + verified"); the Project Bible sits on top as a local-only commit.
  Authored/synced 2026-07-10.
- **Confidence** = the inventory author's confidence that the summary reflects the file's
  actual content, *not* a claim that the file's own assertions are verified against live
  systems.
- **Closeouts are point-in-time.** Several dated closeouts predate later state changes;
  when a closeout and the latest pipeline state differ, **the latest state wins.** For
  example, the `20260708` isMerged RPC hardening reads "apply pending" in the older
  design/validation closeouts but is now **APPLIED + VERIFIED in prod (2026-07-10, commit
  `b94f7fd`)** — that applied state is settled and authoritative, not uncertain.

---

## 1. Strategic / cross-cutting root docs

| path | what it contains | subsystem | conf. | use later? |
|---|---|---|---|---|
| `ROADMAP.md` | Canonical "why we chose what we chose" record: grouping G0 design lock (G0–G6), P/L invariant, disabled-Merge rationale, `[DIAG] TEMPORARY` log policy, deferred items, 2026-05-12 pivot patch, Notes LLM-retrieval deferral + bulk-import gate, GUGU cognition freeze, Capture Bot Day 4 prep, navigation audit, PageSteps cleanup. | Grouping, Journal, Notes, GUGU, Portfolio | High | **Yes** — 07, 08, 12, 13, 16, 17 |
| `artifacts/pipeline/PIPELINE_STATE.md` | Authoritative current lane/gate glance: prod bundle `f01eb33`/v3.23.0, deploy verification complete, Lanes A–I with status/next/gate, detail notes. **Most current lane/gate doc.** ⚠️ The `HEAD 042aeed` figure *inside* this file is a point-in-time self-report and goes stale — do **not** cite it as the current repo HEAD. | Operations, all | High | **Yes** — 01, 14, 15 |
| `artifacts/pipeline/AUTOPILOT_RULES.md` | The gate model: MAY / MUST STOP / MUST NOT, operating loop, "when in doubt STOP." | Operations | High | **Yes** — 00, 06, 15 |
| `artifacts/pipeline/NEXT_SAFE_TASK.md` | Recommended next safe task + explicitly-blocked steps + the standing Lane-B (G2) gate checklist. | Operations, Grouping | High | **Yes** — 14, 15 |
| `docs/notes_taxonomy.md` | The Notes 4-type taxonomy (quote/rule/lesson/idea), tag conventions, source conventions, how to encode confidence/applies-to/invalidation without extra fields. | Notes/Knowledge | High | **Yes** — 11 |
| `RESOURCE_AUDIT.md` *(untracked)* | Supabase resource/cost audit: `portfolio_summary` write loop (P0, patched), `live_prices` double-fetch (patched), diagnostic SELECT (patched), subscriptions/RLS audit, deferred cost items. | Operations, Portfolio | High | **Yes** — 15 (note: **untracked**, do not stage) |
| `scripts/pipeline_snapshot.ps1` | Read-only PowerShell state snapshot used by autopilot to ground on real repo/prod state. | Operations | Med | Maybe — 15 |
| `README.md` | Repo stub ("# thus-journal", 14 bytes). | — | High | No |

> **Current HEAD / prod state — cite one place only:** use [`README.md`](./README.md) →
> "Repo state" (and `14_CURRENT_STATE.md` once written). SHAs embedded inside
> pipeline/closeout docs are point-in-time self-reports and drift; treat them as
> historical, not current.

---

## 2. Merge / Grouping (G1/G2 trade grouping)

Design intent: a **non-destructive** replacement for the retired row-collapsing "Merge."
A group is metadata (`group_id` FK + a `trade_groups` row) over canonical executions —
never a synthetic trade. All reducers ignore `group_id` (P/L invariant). Phases G0→G6.
Current: schema + RPCs + loader/render **LIVE default-off** at v3.23.0; RPC `isMerged`
guard applied + verified in prod (2026-07-10); write gate **not enabled**; DB clean (0
active / 1 archived). GUGU tie-in is the designed **G5 `[Insert GUGU summary]`** hook
(reads `checkin_events`), not yet built.

| path | what it contains | status | conf. | use later? |
|---|---|---|---|---|
| `artifacts/g2_grouping/g2_lean_rpc_packet_20260705.README.md` | Tombstone: the reviewed G2 SQL was applied 2026-07-05 and promoted to `migrations/20260705_...`; duplicate removed. | DONE | High | ref only |
| `artifacts/g2_grouping/g2_rpc_ismerged_hardening_design.md` | Design (ChatGPT PASS) for the `merged_child_not_allowed` reject; crash-safe text compare; precheck-expect-0; sequencing. | DESIGNED | High | 08, 12 |
| `artifacts/g2_grouping/g2_rpc_ismerged_hardening_validation.sql` | Runbook SQL: read-only precheck (A, **returned 0**) + BEGIN/ROLLBACK behavior tests (B, T1–T6) — **executed + PASSED** (jsonb true/false/null/missing-key handled, ungroup normal, final grouped count 0, merged child → `merged_child_not_allowed`; no data persisted). | VERIFIED | High | 15 |
| `artifacts/g2_grouping/g2_schema_apply_closeout.md` | Closeout of 2026-07-05 DB-only apply of G2 RPCs/schema; V1–V5 PASS; happy-path not exercised at apply. | DONE/LIVE | High | 15 |
| `artifacts/g2_grouping/g2_v03_ui_and_rpc_smoke_closeout.md` | v0.3 create-only UI: two default-off flags, rollback smoke PASS (2026-07-06). Local-only. | DONE (local) | High | 08 |
| `artifacts/g2_grouping/g2_v04_loader_render_closeout.md` | v0.4 group-aware loader/render: `loadAll` selects `raw,group_id`; separate `tradeGroupIds` map; ⛓ badge; Codex PASS. | DONE (reviewed) | High | 08 |
| `artifacts/g2_grouping/g2_v04_mt5_harness_deploy_closeout.md` | Deploy: v0.4 + MT5 dry-run harness shipped to prod `f01eb33`/v3.23.0; both smoke halves PASS (2026-07-08). | LIVE | High | 15 |
| `artifacts/g2_grouping/g2_v04_post_deploy_smoke_runbook.md` | Prepared read-only post-deploy smoke runbook (authored while deploy on hold; superseded by the executed smoke). | DONE | Med | 15 |
| `artifacts/g2_grouping/g2_v05_ungroup_design_closeout.md` | v0.5 ungroup UI design (ChatGPT PASS, approved-deferred): detail-modal affordance, typed UNGROUP, one RPC, no raw touch. No code. | DESIGNED/DEFERRED | High | 08, 12 |
| `artifacts/g2_grouping/g2_write_gate_browser_smoke_closeout.md` | First live write-gate smoke (2026-07-07): real create → one RPC, P/L invariant held byte-identical → ungrouped; net 0 active / 1 archived. | DONE | High | 15 |
| `artifacts/g2_grouping/merge_grouping_boundary_audit.md` | Audit: legacy Merge unreachable/dead; no cross-wiring with G2; isMerged-exclusion gap noted; CLEAR_FOR_BATCH_DEPLOY. | REVIEWED/DONE | High | 08 |
| `artifacts/merge_grouping/g1_schema_rls_migration_packet.md` | The G1 review packet: schema/RLS design, idempotency, 9 verification queries, rollback, risks (incl. FK cascade #10.4), run instructions. | REVIEWED/DONE | High | 12 |
| `artifacts/merge_grouping/g1_schema_rls_packet_static_review.md` | Static review of the G1 packet: READY_TO_COMMIT; index deviation accepted; no blockers. | REVIEWED/DONE | High | 12 |
| `artifacts/merge_grouping/g1_schema_rls_run_report.md` | Run report (2026-06-08): G1 applied in SQL Editor at `79140c6`; #10.4 resolved; V1–V9 PASS; app smoke PASS; 0 rows mutated. | DONE/LIVE | High | 15 |
| `artifacts/merge_grouping/g2_baseline_capture_plan.md` | Read-only plan to capture a P/L baseline (Gate 5) via a browser-console IIFE mirroring reducers; SHA-256 change detection. | DESIGNED | High | 15 |
| `artifacts/merge_grouping/gate_1_2_junior_attestation_20260605.md` | Junior's signed attestation: Gate 1 (14-day clean writes) + Gate 2 (Block 5) PASS; unlocks G1 design only; approves no UI/deploy/mutation. | DONE | High | 15 |
| `artifacts/merge_grouping/gate_1_2_plain_english_checklist.md` | Thai plain-English explainer of grouping, disabled-Merge rationale, Gate 1/2, G0–G6, GUGU at G5. | DONE | High | ref only |
| `artifacts/merge_grouping/merge_grouping_gate_1_2_evidence.md` | Evidence review (2026-06-05): gates NEEDS_JUNIOR_CONFIRMATION at the time (superseded by the attestation). | GATED (superseded) | High | ref only |
| `artifacts/merge_grouping/merge_grouping_reentry_audit.md` | Foundational re-entry audit (2026-06-03): confirms locked G0 design, inventories dead merge code, 4 data-model options (B locked), full v0.1 design, phase plan, risks. | RESEARCH/REVIEWED | High | 12, 08 |
| `migrations/20260607_g1_trade_groups_schema.sql` | Applied G1 migration: `trade_groups` table, dormant `trades.group_id` FK ON DELETE SET NULL, 3 indexes, RLS + 4 policies, grants, V1–V9 verification, commented rollback. | LIVE (2026-06-08) | High | 15 (schema of record) |
| `migrations/20260705_g2_trade_group_rpcs.sql` | Applied G2 migration (source of truth): `idempotency_key` + unique active index, ownership trigger, two SECURITY DEFINER RPCs (create/ungroup) writing only `group_id`+`updated_at`. | LIVE (2026-07-05) | High | 15 (schema of record) |
| `migrations/20260708_g2_create_group_reject_ismerged.sql` | Function-body-only replace of `create_trade_group_v1` adding `merged_child_not_allowed`. **APPLIED + VERIFIED in prod 2026-07-10** (precheck 0; new function installed; BEGIN/ROLLBACK validation passed; merged child → `{"ok":false,"error":"merged_child_not_allowed"}`; no test data persisted; recorded in `b94f7fd`). | LIVE (applied) | High | 15, 12 |
| `artifacts/pipeline/g2_candidate_check.sql` | Read-only diagnostics (autopilot must NOT run): eligible-candidate query, raw-vs-projected invariant check, baseline 0/0 sanity. | DONE (tooling) | High | 15 |
| `artifacts/merge_grouping/g2_baseline_20260702.json` *(6.4 KB)* | P/L baseline snapshot data (not deeply read). | data | Med | ref only |
| `artifacts/merge_grouping/g2_baseline_20260702_v3.json` *(8.2 KB)* | P/L baseline snapshot data, v3 (not deeply read). | data | Med | ref only |

> Untracked/uncommitted grouping artifacts present in the working tree (do **not** stage):
> `artifacts/merge_grouping/g2_baseline_20260608.json`, plus modified
> `artifacts/pipeline/NEXT_SAFE_TASK.md` and `PIPELINE_STATE.md` (pre-existing edits).

---

## 3. MT5 Import (execution/source layer)

Design intent: mirror MT5 executions into a gated staging area; nothing auto-materializes
into Journal trades. **Terminology (keep distinct):** the **MT5→staging writer** exists
(local Python; has done armed *staging* writes under gate); the **staging→trades
materializer** is **not started; hard-gated** — armed staging smokes are not precedent for
automatic materialization. Phases: 0A schema/RLS/RPCs (applied+verified 2026-06-25) → 0C
local Python MT5→staging writer (probe → dry-run builder → gated service_role writer) →
0C-3a/0C-3b armed staging smokes (first open + first close-deal writes, idempotent) →
0D-0/0D-1 read-only Inbox UI (default-off `tj_mt5_inbox`). Offline dry-run harness merged.
Cross-account gate (terminal `301102520`), `needs_mapping`, idempotency via
`position_id`/`deal_id`/`raw_sha`.

| path | what it contains | status | conf. | use later? |
|---|---|---|---|---|
| `artifacts/mt5_auto_draft_import/mt5_manual_sync_runbook.md` | Operator runbook to manually stage a new MT5 open into the Inbox (dry-run→armed `writer.py --scope open`); STOP conditions; three-key arm gate. | LIVE | High | 15 |
| `artifacts/mt5_auto_draft_import/phase_0a_apply_closeout.md` | 0A schema/RLS/RPC applied+verified in prod (2026-06-25): 3 tables, 10 indexes, 3 triggers, 3 RPCs; SELECT-only browser; DO NOT RE-RUN. | DONE | High | 09 |
| `artifacts/mt5_auto_draft_import/phase_0a_r3_design_plan.md` | Approved 0A-r3 design: 3-table architecture, 0B probe findings (hedging, idempotency, DELTAU26 csize 1000, Bangkok tz), RPC sketches. | DESIGNED | High | 09, 12 |
| `artifacts/mt5_auto_draft_import/phase_0a_sql_rpc_packet.md` | Concrete fail-closed, create-only SQL/RPC packet (DDL, RLS, grants, 3 RPC bodies, verify+rollback). Historical record of what was applied. | DONE | High | 09, 12 |
| `artifacts/mt5_auto_draft_import/phase_0c3_writer_design.md` | 0C-3a open-only writer design: SELECT→INSERT/PATCH, three-key gate, `--max-write-count`, PATCH allowlist, unknown hard-STOP. Codex PASS_WITH_CHANGES. | DESIGNED | High | 09 |
| `artifacts/mt5_auto_draft_import/phase_0c3a_armed_smoke_record.md` | First armed service_role write: GOU26 open `305830528` inserted; idempotent rerun→PATCH; tz + contract_size=300 confirmed. PASS. | DONE | High | 09, 15 |
| `artifacts/mt5_auto_draft_import/phase_0c3b_armed_smoke_record.md` | First armed close-deal write: GOU26 close `deal_id=2141744`; insert-once immutable (rerun=no-op); cross-account gate STOPPED wrong-terminal attempts. PASS. | DONE | High | 09, 15 |
| `artifacts/mt5_auto_draft_import/phase_0c_staging_writer_design.md` | Parent 0C design: local Python architecture, gated sub-slices, tz/idempotency/cursor/lifecycle plans, field allowlists, secret-hygiene `.gitignore` rules, table-allowlist boundaries. | DESIGNED | High | 09 |
| `artifacts/mt5_auto_draft_import/phase_0d0_deploy_closeout.md` | Read-only Settings MT5 Inbox pushed to prod (`8864e73`); default-OFF `tj_mt5_inbox`, SELECT-only, no write buttons. PASS. | LIVE | High | 15, 09 |
| `artifacts/mt5_auto_draft_import/phase_0d0_local_browser_smoke_record.md` | Local browser smoke of 0D-0 + postmortem of a `LS` vs `ls` Settings black-page bug (fixed `267e579`). PASS. | DONE | High | 09, 15 |
| `artifacts/mt5_auto_draft_import/phase_0d1_inbox_clarity_deploy_closeout.md` | 0D-1 Inbox clarity UI live (`7088473`): sectioning (open/closed/other), summary strip, per-row safety labels, read-only position↔deal hint. | LIVE | High | 09, 15 |
| `artifacts/mt5_import/README.md` | README for the offline fixture dry-run harness (`dry_run.py`): pure mappers + tz, class-aware mapping, `raw_sha`/`idempotency_key`; never touches Supabase/MT5/network. | DONE | High | 09, 15 |
| `artifacts/mt5_import/reports/mt5_dry_run_report.md` | Sample rendered dry-run report: 6 rows (4 mapped, 2 needs_mapping), DELTAU26 guard PASS, tz + contract-size samples. Fixture output. | DONE | High | ref only |
| `ops/mt5_import/README.md` | Developer README for `ops/mt5_import/` tooling: per-module purpose/commands (probe/build_rows/writer/staging_db), read-only guarantees, secret hygiene, three-key gate, PATCH allowlist, next gates 0C-3c/0C-3d. | LIVE | High | 15, 09 |
| `ops/mt5_import/*.py` | The tooling itself: `probe.py` (0C-1 read-only MT5 probe), `build_rows.py` (0C-2 pure transforms), `dry_run.py` (offline harness), `writer.py` (0C-3 gated service_role writer), `staging_db.py` (table-allowlisted PostgREST client), `tz.py` (Bangkok→UTC), `common.py`, `test_dry_run.py`. | mixed (LIVE tooling) | High | 09, 15 |
| `artifacts/mt5_import/fixtures/*.json`, `reports/mt5_dry_run_report.json` | Harness fixture inputs (probe + mapping) and machine-readable sample output. | data | High | ref only |

> **NEEDS VERIFICATION (MT5):** all apply/smoke/deploy records are self-reported docs.
> Prod Supabase object inventory, current `origin/main` vs `7088473`, and whether the
> second open `305832434` remains unwritten should be re-confirmed against live systems
> before citing as current fact.

---

## 4. Durable persistence, UI hardening, image externalization, product registry

| path | what it contains | status | conf. | use later? |
|---|---|---|---|---|
| `artifacts/close_position_journal_bug/close_position_journal_bug_audit.md` | P0 audit of "closed position disappears"; §17 CONFIRMS a real close-persistence bug on trade `1781008993915`; root cause = optimistic toast + debounced/unawaited/no-retry save. | REVIEWED | High | 12, 07 |
| `artifacts/close_position_journal_bug/close_save_durability_design.md` | Option-A fix (route `commitClose` through awaited full-array save). Superseded by the timeout addendum. | DESIGNED (superseded) | High | 12 |
| `artifacts/close_position_journal_bug/close_save_durability_design_timeout_addendum.md` | Revised fix after prod `57014` timeout on ~11 MB base64: single-row `db.saveTrade`, bounded RETURNING, post-hydration autosave suppression, save-first ordering. | DESIGNED | High | 12 |
| `artifacts/close_position_journal_bug/p1_durable_update_path_closeout.md` | P1 update writer shipped (`30d5a1d`, deployed, prod smoke PASS): `commitUpdateTrade` makes edit/price/note+meta saves save-first durable. Lists residual non-durable writers. | LIVE | High | 07, 12 |
| `artifacts/image_externalization/p2_5a_storage_policy_pack.md` | Storage policy pack APPLIED 2026-06-22: private `trade-images` bucket + 2 RLS policies, 5 MB cap, MIME allow-list, path shape; append-only (no UPDATE/DELETE); verify+rollback SQL. | DONE/LIVE | High | 15, 07 |
| `artifacts/image_externalization/p2_5c_disposable_smoke_result.md` | PASS smoke of upload-on-commit on a disposable trade: PNG externalized to a Storage path, rendered via signed-URL resolver. Local HEAD `0a6dd43`. | DONE | High | 13, 15 |
| `artifacts/image_externalization/p2_5d_backfill_design.md` | Design for one-time eager backfill of 18 closed rows / 37 images (~16.6 MB → ~0.15 MB, ~112×); save-first, batched, backup-first, STOP rules. READY_FOR_CODEX_REVIEW. | DESIGNED | High | 12 |
| `artifacts/image_externalization/p2_5e_inventory_result_20260623.md` | Result of read-only orphan inventory: 141 trades, 3 bucket objects (1 live + 2 within-retention orphans), 0 retention-passed orphans. Phase-C deletion DEFERRED. | DONE | High | 15 |
| `artifacts/image_externalization/p2_5e_phase_a_inventory.md` | Implementation record for the read-only orphan-inventory tool (`ops/p2_5e/orphan_inventory.mjs`); exact-path predicate; 7-day retention floor; no deletion path. | DONE | High | 15 |
| `artifacts/p2_5_image_externalization/p2_5d_backfill_closeout.md` | Closeout: backfill RAN browser-side (18 rows / 37 images, 0 remaining, allClean); driver removed. Local-only commit — **not pushed/deployed**. (Note divergent dir path.) | DONE (deploy deferred) | High | 13, 15 |
| `artifacts/p2_deploy_readiness/p2_full_stack_burn_in_result.md` | PASS burn-in of the 15-commit P2 stack (local `00f02e7`): durable single-row open/close, ids-only reconcile autosave, image externalization, no `57014`. | DONE | High | 13, 15 |
| `artifacts/p2_deploy_readiness/p2_full_stack_production_closeout.md` | P2 full stack DEPLOYED + VERIFIED (`ba532be`, `2c2c8d2..ba532be`): every mutation single-row durable, autosave ids-only reconcile, full-array writer retired, images externalized. | LIVE | High | 07, 13 |
| `artifacts/ui/closed_trade_correction_production_closeout.md` | Closed-Trade Correction V1 DEPLOYED (`09842d7`): correct exitPrice/exitDateTime on eligible manual standalone closed trades via durable update path; P/L stays derived. | LIVE | High | 07 |
| `artifacts/ui/closed_trade_correction_smoke_result_20260623.md` | PASS smoke (local `8647fec`) of the correction feature; non-eligible gating static-verified. | DONE | High | 13 |
| `artifacts/ui/lightbox_smoke_result_20260623.md` | PASS smoke (local `352854f`) of trade-image lightbox; render-layer only, no save/upload fired. | DONE | High | 13 |
| `artifacts/ui/ui_lightbox_unsaved_guard_smoke_result_20260623.md` | PASS smoke (local `904e739`) of lightbox + add/replace images on open position + `useUnsavedGuard` across forms/editMode/NoteField. | DONE | High | 13 |
| `artifacts/ui/ui_stack_production_closeout.md` | UI/docs/tool stack DEPLOYED (`eca0e00`, `ba532be..eca0e00`): lightbox, reusable `useUnsavedGuard`+`ConfirmDialog`, read-only P2-5-E inventory tool. | LIVE | High | 07, 13 |
| `artifacts/product_symbol_live_price/product_symbol_live_price_foundation_closeout.md` | Product/Symbol/Live-Price Foundation DEPLOYED (`2c2c8d2`, 2026-06-19): `ProductRegistry` facade, price-source badge, runtime kind inference, kind-aware expansion, first stock preset DELTA; no schema/P&L/durable change. | LIVE | High | 03 |
| `ops/p2_5e/README.md` | Runbook for the orphan-inventory admin tool: local-only, service_role (never shipped), exact-path orphan predicate, 7-day retention floor. Phase-C deletion intentionally absent. | DONE | High | 15 |
| `migrations/20260512_archive_trade_events_v1_lockdown.sql` | Archive-in-place lockdown of legacy GUGU v1 `public.trade_events` (3066 rows): preserve table, drop permissive policies, ENABLE RLS, REVOKE anon/authenticated, COMMENT. Manual-run, DO NOT RUN AUTOMATICALLY. | GATED / NEEDS VERIFICATION (applied?) | Med | 15, 12 |
| `ops/p2_5e/orphan_inventory.mjs`, `artifacts/image_externalization/p2_5e_inventory_20260623.json` | The read-only inventory script + its generated paths/counts report (noted, not deeply read). | tooling/data | High | ref only |

> **NEEDS VERIFICATION (persistence cluster):** (a) confirm the timeout-addendum design
> is the one that shipped as `db.saveTrade`; (b) confirm the `20260512` trade_events
> lockdown was actually applied in prod; (c) the backfill (and its paired design) live
> under a **divergent directory** (`artifacts/p2_5_image_externalization/` vs
> `artifacts/image_externalization/`) and the backfill commit is local-only.

---

## 5. Migrations (schema of record)

| path | purpose | applied? |
|---|---|---|
| `migrations/20260512_archive_trade_events_v1_lockdown.sql` | Lock down legacy GUGU v1 `trade_events`. | **NEEDS VERIFICATION** (manual-run; not confirmed here) |
| `migrations/20260607_g1_trade_groups_schema.sql` | G1: `trade_groups` + `trades.group_id` + RLS. | Applied 2026-06-08 (run report) |
| `migrations/20260705_g2_trade_group_rpcs.sql` | G2: idempotency key, ownership trigger, create/ungroup RPCs. | Applied 2026-07-05 (schema apply closeout) |
| `migrations/20260708_g2_create_group_reject_ismerged.sql` | Defense-in-depth `merged_child_not_allowed`. | **APPLIED + VERIFIED in prod 2026-07-10** (precheck 0; BEGIN/ROLLBACK PASS; recorded `b94f7fd`) |

---

## 6. Confidence & staleness notes

- **High confidence** items were read in full (or are canonical design docs). **Med**
  items were noted by filename/size or are process scripts. Data JSON files were not
  deeply parsed.
- **Every closeout is point-in-time and self-reported.** They assert PASS against the
  author's environment at that date; none is a live re-verification. For money-/data-
  bearing claims, re-confirm against live systems or the latest `PIPELINE_STATE.md`.
- **`RESOURCE_AUDIT.md` is untracked** (working-tree only) — usable as a source, but **do
  not stage it** as part of Bible work.

---

## 7. Gaps — areas with no good in-repo source

These subsystems/topics are named as important (see [`03_PRODUCT_MAP.md`](./03_PRODUCT_MAP.md))
but the `thus-journal` repo has **little or no forward design documentation** for them.
They require future search of the other repo (`thus-trading-bot`), the auto-memory index,
or direct capture from the user. **Do not fabricate these in later chapters — mark
NEEDS VERIFICATION and capture deliberately.**

| Gap area | Why it's a gap | Where to look |
|---|---|---|
| **GUGU roadmap / capabilities** | GUGU v2 is an **active build** in `thus-trading-bot` (reported Days 1–8 sprint: memory → agent+tools → Telegram → observation cycle → cost monitoring → VPS at Day 8, **NEEDS VERIFICATION**). Its architecture, phases, and live runtime live there + in user memory, not here. Only the freeze policy + G5 hook appear in `thus-journal`. | `thus-trading-bot` CLAUDE.md + memory index; user. |
| **GUGU cost / economics** | v2 needs a **hard cost ceiling + per-cycle token/cost logging** before any autonomous run; v1 reportedly leaked ~$5/day on a Haiku monitor daemon. A first-class safety rule (rank of "no silent unfreeze"). **NEEDS VERIFICATION.** | `thus-trading-bot` + user memory. |
| **Existing knowledge corpus** | The knowledge layer does **not** start from zero. Reported external corpus: mentor-PDF → NotebookLM → `bot_knowledge` pipeline; ~70 items across 17 categories; candlestick / Wyckoff curriculum artifacts; codified rules (range boundaries, no-falling-knife, S50 gap rule). **NEEDS VERIFICATION.** | `thus-trading-bot` + user memory. |
| **Mentor system** | No forward design in-repo; the old AI-mentor-note route was deprecated. | User memory; future design session. |
| **Notes / Knowledge engine** | Taxonomy exists; the *retrieval/activation* design is deferred until real content exists. | `docs/notes_taxonomy.md` + a future "Session B". |
| **Pattern / Lesson engine** | Not implemented or designed in-repo; only conceptual (GUGU v2 "connect dots"/"self-correct"). | User; GUGU v2 vision. |
| **Merge history (full)** | Rationale is in `ROADMAP.md` + audits, but the complete evolution (v1 merge → disable → grouping) is spread across many docs + memory. | ROADMAP + `artifacts/merge_grouping/*` + memory index. |
| **Durable persistence history (full)** | Spread across P0/P1/P2 closeouts + a long memory-index trail; needs consolidation into chapter 13. | `artifacts/close_position_journal_bug/*`, `p2_*`, memory index. |
| **Bot capabilities (Capture Bot)** | Command set + schema partly in ROADMAP; full capability set lives in the trading-bot repo. | `thus-trading-bot` repo; user. |
| **Portfolio roadmap** | One of the thinnest areas: only patched cost issues + hidden HWM/style cards. No forward roadmap. | User memory; RESOURCE_AUDIT; ROADMAP. |
| **Product registry roadmap** | Foundation shipped; forward plan (FX/CFD/crypto kinds, spot routing to `trades_capture`) not consolidated. | Foundation closeout + user. |
| **MT5 full roadmap** | Through-materialization plan (0C-3c/0C-3d, 0D-1 write actions, Phase 1) partly in docs; end-state not fully specified. | `artifacts/mt5_auto_draft_import/*` + user. |
| **AI automation roadmap** | The autopilot *engineering* rules exist; the GUGU *product* automation roadmap does not live here. | `AUTOPILOT_RULES.md` (eng) + GUGU v2 vision (product). |

See [`TODO_ROADMAP_CAPTURE.md`](./TODO_ROADMAP_CAPTURE.md) for how these map to the
remaining chapters.
