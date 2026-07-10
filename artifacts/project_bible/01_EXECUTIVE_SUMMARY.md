# 01 — Executive Summary

*A 5-minute explanation of THUS. For the full direction, read
[`02_VISION_AND_NORTH_STAR.md`](./02_VISION_AND_NORTH_STAR.md).*

---

## What THUS is

THUS is a personal **trading operating system** being built by and for one active
trader (Junior). It has two visible layers today and one destination:

- **THUS Journal** — a single-file React SPA (`index.html`) persisted to Supabase and
  deployed on Netlify (thus999.com). It records trades, notes, portfolio state, and
  imported executions. This is where nearly all current engineering effort lives.
- **MT5 pipeline** — local tooling and a gated staging schema that mirrors MetaTrader 5
  executions into the system as a trustworthy source of fills, prices, and contract
  sizes.
- **GUGU** (the destination) — an AI-native trading copilot that will reason over all of
  the above. GUGU's cognition/runtime is currently **frozen**; only a capture bot runs.

## The problem it solves

A discretionary trader accumulates decisions, executions, emotional context, and lessons
across years. That history is normally scattered, lossy, and unaudited — impossible for
either the trader or an AI to learn from reliably. THUS's bet is that a **lossless,
durable, correctly-attributed record** of trading — executions, theses, notes, outcomes —
is the foundation for an AI copilot that can genuinely improve decision quality over a
multi-year horizon.

## Why the Journal exists

The Journal is the **memory/data layer.** Before an AI can be trusted to reason about
trades, the trade data has to be trustworthy: every close must actually persist, no P/L
may be double-counted, raw executions must stay canonical, and images/notes must not
corrupt or bloat the record. Most of the last several months of work has been exactly
this hardening — durable single-row writes, retiring a data-losing merge feature,
externalizing images out of the trade rows, and building a safe grouping model.

## Why GUGU is the destination

GUGU is the reason the data-integrity work matters. The intent (carried over from the
GUGU v2 design) is a memory-stream + reasoning copilot that learns a trader's framework
over years, connects dots, challenges the trader when warranted, and **proposes rather
than prescribes** — the human stays in control of every trade. The Journal, MT5,
portfolio, notes/knowledge, and a future mentor layer are all inputs GUGU will consume.
See chapter 02.

## What is currently live

- **Journal persistence, hardened.** Every trade mutation (open/add, close, edit,
  price/meta update) is **single-row durable** in production (P2 full stack, `ba532be`;
  updates via `commitUpdateTrade`, `30d5a1d`). The data-losing full-array writer is
  retired. **LIVE.**
- **Image externalization.** Trade screenshots moved from inline base64 to a private
  Supabase Storage bucket (`trade-images`); 18 legacy rows / 37 images backfilled
  (~112× row-size reduction). **LIVE** (backfill ran browser-side; see chapter for
  deploy-scope caveat).
- **Product/Symbol registry foundation.** `ProductRegistry` facade + first non-futures
  product (DELTA stock). **LIVE** (`2c2c8d2`).
- **Trade grouping (G1/G2), default-off.** Non-destructive replacement for the old
  Merge: schema + RLS applied, SECURITY DEFINER RPCs applied, group-aware loader/render
  shipped default-off at **v3.23.0** (`f01eb33`). RPC `isMerged` defense-in-depth guard
  (`20260708`) **APPLIED + VERIFIED in prod (2026-07-10, `b94f7fd`)** — precheck 0,
  BEGIN/ROLLBACK validation passed (merged child → `merged_child_not_allowed`). The
  **write gate is not enabled** and **no real group is kept** (DB holds 0 active groups).
  **LIVE (default-off).**
- **MT5 read-only Inbox.** A Settings-embedded, read-only view of staged MT5 rows behind
  default-off flag `tj_mt5_inbox` (`7088473`). Staging schema + local writer exist. The
  offline dry-run harness is merged. **LIVE (read-only, default-off).**
- **Capture Bot.** GUGU's capture-only check-in bot runs (check-ins via `checkin_events`).

Production bundle at authoring: **`f01eb33` / v3.23.0**, deploy verification complete
(no-auth default-off smoke PASS + authenticated visual smoke PASS, 2026-07-08).

## What is intentionally gated

- **G2 write gate** (`tj_trade_group_write_v01`) and keeping a real, persistent group.
- **MT5 real staging writer** materializing into Journal `trades`.
- **GUGU cognition/runtime** — frozen; no autonomous market cognition, capture-only.
- **v0.5 ungroup UI** — design approved, deferred until after the current deploy.
- **RLS/security hardening** — requires a fresh read-only audit first.
- **Any new deploy, flag enable, or migration apply** — human-approved, every time.

See [`00_AI_BOOTSTRAP.md`](./00_AI_BOOTSTRAP.md) §5 for the full gate list.

## The biggest current risks

1. **Silent data loss** — the historical bug class (optimistic UI reporting success
   before a write lands). Largely fixed for the core mutation paths; residual non-durable
   writers (delete/duplicate/import/merge-legacy) still warrant care.
2. **Silent double-counting** — the P0-2 class where a synthetic row is counted with its
   source rows. The grouping design defends against this *by construction* (metadata
   only, P/L invariant). Any regression that lets a reducer read group-level totals or a
   merge write a synthetic trade re-opens it.
3. **Single-file SPA scale** — `index.html` is ~596 KB and monolithic; large `raw`
   payloads have already caused PostgREST statement timeouts (`57014`), which drove the
   image-externalization and single-row-write work.
4. **GUGU echo chamber / premature unfreeze** — GUGU cognition is frozen partly because
   an early shadow cycle produced a signal from *remembered arithmetic*, not market
   cognition. Unfreezing without a real data corpus and adversarial guard is a known
   trap.
5. **Docs drift** — closeouts go stale; asserting an old "done" as current is a risk.
   The Bible and pipeline state must be kept honest.

## Immediate next strategic tracks

- **G2 write-gate / real-group path** — now unblocked of its migration prereq; remaining
  is explicit flag-enable approval + a reviewed enable/rollback plan + keeping one real
  group to exercise the v0.4 loader end-to-end. **GATED.**
- **MT5 real staging writer planning** — design/planning is safe; any DB write is
  user-gated. **GATED.**
- **G2 v0.5 ungroup UI** — approved-deferred; implement after the current deploy, with
  its own adversarial review. **DEFERRED.**
- **Notes/Knowledge activation** — deferred until Junior has ~20–30 real notes (typed or
  reviewed-bulk-imported); this is the seed of the mentor/knowledge layer for GUGU.
  **DEFERRED.**
- **Building out the Bible itself** — see [`TODO_ROADMAP_CAPTURE.md`](./TODO_ROADMAP_CAPTURE.md).
