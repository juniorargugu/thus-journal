# T0 — Capture & Exposure Contract (Telegram-first)

**Date:** 2026-08-21 · **Branch:** `work/mt5-phase-a-positions-review` · **Type:** contract
addendum, **docs-only**. **Nothing implemented.** No SQL applied, no RPC invoked, no runtime or
GUGU change, no flag enabled, no push/deploy. **S1 frozen Revision 3 is NOT modified by this
document.**

Freezes only the decisions that must exist before T1/T2 implementation. It does not restate or
replace `04_COMPLETE_ROADMAP.md`; it supersedes the *web-Inbox-as-primary-capture* assumption in
`03_PRODUCT_MAP.md` §5 and `04_COMPLETE_ROADMAP.md` §3 (0D-2+), which are re-tagged SUPERSEDED.

Evidence base: read-only re-baseline audit, 2026-08-21, over `thus-journal` @ `3a05d43`,
`thus-journal-mt5-s1` @ `a56dfbd`, `thus-trading-bot` @ `b03758a`.

---

## 0. State of record (corrected)

| Fact | Status |
|---|---|
| Last **VERIFIED** production deploy | `f01eb33` / v3.23.0 (2026-07-08), served bundle 595,900 B |
| **Current** production identity | **UNKNOWN — pending operator verification.** Two later code commits (`ef856bc`, `f37a0ef`) carry no deploy record. |
| Prior "prod is byte-identical to `f01eb33`" statement | **Stale — no longer trustworthy as a current-state assertion.** It is not re-asserted here, and nothing in this document depends on it either way. |
| `origin/main` (at audit time) | `f37a0ef` |
| `APP_VERSION` | `"3.23.0"` on `f01eb33`, `ef856bc`, `f37a0ef` and the working branch — **cannot resolve bundle identity** |
| S1 | packet corrected (`a56dfbd`), **0 fixtures executed**, awaiting repeat executable review |

No claim in this document depends on knowing which bundle is live.

---

## A. Product boundary (FROZEN)

- **Telegram** = capture / confirm / small context. **THUS Desktop** = understanding / review /
  reconciliation. **Mobile web** = fallback.
- **GUGU cognition stays frozen and outside the capture path.** Capture must function with
  Anthropic entirely unavailable. This is already true and proven: `CAPTURE_ONLY_MODE` defaults
  True when unset, provider SDKs are behind a lazy import in the legacy branch only,
  `ANTHROPIC_API_KEY` is absent from the capture-mode required-env set, `manual_run_guard.py`
  fail-closed-guards every manual entrypoint, and **zero** capture modules import
  `cost_ceiling.py`. Any new capture code MUST preserve this property.

## B. G2 as the Position container (FROZEN)

- `trade_group` **is** the Position / Trading Idea container. No new container entity.
- A group exists **from the first confirmed position**, before any second leg.
- **One-member groups are valid.** Evidence: `trade_groups` has zero CHECK constraints and no
  member-count column; the `≥2` rule (`v_n < 2 → too_few_children`) exists *only inside*
  `create_trade_group_v1`, and one-member groups are already reachable at rest via
  `ON DELETE SET NULL`. It is a creation-time invariant, never a schema invariant. **Readers MUST
  NOT assume cardinality ≥ 2.**
- **`create_trade_group_v1` is NOT the Telegram write path.** It derives identity from
  `v_uid := auth.uid()` and is `GRANT EXECUTE … TO authenticated` only; under the bot's
  service_role key `auth.uid()` is NULL and the call returns `not_authenticated`. Its `≥2 open
  children` gate also makes it structurally unusable for a first entry.
- **`tj_trade_group_write_v01` remains browser-only** (one `useMemo`, `index.html:3752`). It gates
  nothing server-side and MUST NOT be repurposed as server authorization. Never auto-enable.
- Series rollover (`GOU26 → GOZ26`) may share one group: the family key strips `_next`, so both
  collapse to `gold`. **Open:** a quick-added legacy series product (`gold_gou26`) does not
  collapse — not resolved here.

## C. Capture events (FROZEN — new additive domain)

A new additive capture-event domain. **Not** an extension of `mt5_import_staging` (S1 freezes
staging as annotation-only; the Phase 0A packet forbids re-running itself) and **not**
`mt5_import_groups` (no pending state).

Required states: `pending` · `confirmed`/`promoted` · `skipped` · `unconfirmed` ·
`conflict`/`failed`.

- **`skipped`** = explicit user action (`ไม่ต้องจด`).
- **`unconfirmed`** = no answer, produced by an **explicit ageing rule**, never by absence.
- These are **distinct states**. Nothing in either repo can distinguish them today:
  `checkin_events` collapses both into `replied_at IS NULL` — its own scheduler docstring treats
  long-pending rows as *"skipped/abandoned"* — and the browser Inbox's Dismiss is
  `localStorage`-only (`// Local-only triage (0D-2): … No backend write, no RPC`), so an explicit
  skip is today per-device and invisible to the DB.
- **Neither state becomes Journal narrative automatically.** Both remain visible through
  audit/reconciliation surfaces only.
- **`capture_event_id` is the promotion idempotency key.**
- Linkage to MT5 by `(user_id, source_account, position_id)` — the scope S1 froze — not by a
  staging row UUID, so a link survives re-staging.

## D. Promotion transaction boundary (FROZEN)

A future **dedicated server-side SECURITY DEFINER promotion RPC**. Conceptually one durable
transaction:

1. lock + reload the capture event
2. prove promote-once / idempotent replay (same `capture_event_id` → same result, never a second
   group, trade, or event)
3. resolve canonical MT5 execution linkage (§E2)
4. link existing canonical Journal evidence where it exists; create only where it does not
5. create or reuse the G2 group
6. assign canonical rows to the group **without placing `group_id` into `raw`** — `toTradeRow`
   does `raw:t`, and the loader deliberately keeps `group_id` out of the trade object; a writer
   that stuffs it in silently breaks the P/L invariant
7. create the human decision event
8. mark the capture event promoted
9. commit
10. **only then** may Telegram acknowledge "saved"

**Authorization boundary (FROZEN).**

- The promotion RPC is restricted to the **trusted service execution path**. It is not reachable by
  the browser role and is not a general-purpose write surface.
- **`capture_event_id` is the persisted authority anchor.** The RPC locks and reloads that row, and
  derives `user_id` and `source_account` **from** it — or validates them strictly against it.
- **A caller-supplied `p_user_id` must never independently authorize which user's Journal may be
  mutated.** If such a parameter exists at all, it is only an **equality assertion / defense check**
  against the persisted row; a mismatch is an error, never a redirection of the write.

Explicitly rejected architectures: reusing the browser G2 RPC; and a **multi-call direct-table-write
sequence from the bot**. The Journal's existing multi-step writes compensate manually rather than
transact (`commitMerge` performs an explicit rollback delete on failure) — that pattern must not be
extended across a process boundary.

## E. Decision events

### E1. Semantic model (FROZEN)

Human-confirmed narrative only. `ENTRY` · `SCALE_IN` · later `REDUCE` · later `EXIT`; plus
`occurred_at`, preset ids, optional text, attachment ownership, execution references.

**Never owns:** P/L · running size · average entry/exit · notional · gearing. Those are derived at
read time from canonical trades and immutable S1 snapshot facts.

**Legacy `trade_events` is permanently excluded** — no `user_id`, no `trade_id`, RLS enabled with
zero policies, `REVOKE ALL` from `authenticated`, ~3,066 rows of GUGU v1 bot history, and an
explicit written directive in both the lockdown migration and `index.html`: *"Do NOT restore by
adding columns to this table — design a fresh Journal-scoped audit table."*

### E2. Physical storage — **DECIDED: new sibling Journal decision-events table**

Not an extension of `checkin_events`. Reasoning, from repo evidence only:

1. **Wrong ownership boundary.** Decision events are a **Journal-owned domain** — they describe
   Journal positions, reference `trade_groups`, and inherit the RLS model that already mirrors
   `trades`/`trade_groups`. They therefore belong inside the Journal's schema and migration
   ownership boundary. `checkin_events` is defined and migrated in
   `thus-trading-bot/migrations/0001…0005`, a different owner with a different release cadence.
   *(This is an ownership and stewardship argument, not a technical one: cross-schema references
   are perfectly creatable from another migration set — the point is that they should not be.)*
2. **No group linkage exists there.** `checkin_events` has `trade_id text` (no FK) and **no
   `group_id`**. Contract B makes the group the container, so this is a structural miss, not a
   missing column.
3. **Incompatible lifecycle.** `checkin_events` is a prompt/response record whose core semantic is
   *may be unanswered* (`prompted_at` / `replied_at`). A decision event under E1 exists **only
   after promotion** and is never unanswered. Housing a never-unanswered entity in a
   may-be-unanswered table re-creates precisely the skipped-vs-unconfirmed conflation Contract C
   forbids. The Journal's own reader already encodes that semantic by filtering
   `.not("replied_at","is",null)`.
4. **Domain collision is the exact failure that killed `trade_events`.** It became unusable partly
   by holding two subsystems' histories in one table. Merging behavioral check-ins (emotion / urge
   / mistake tags) with trade-structural narrative repeats that mistake.

**Consequence worth recording: the `checkin_events.surface` CHECK migration identified in the
re-baseline audit is NOT required.** `checkin_events` keeps `surface IN ('daily','during_trade')`
unchanged, and the capture bot's existing behavior is untouched.

## F. Presets (FROZEN)

Reuse the existing **code-versioned** preset machinery with namespaces — `entry.*`, `scale.*`,
`close_trigger.*`, `close_adherence.*`. **No second preset framework.**

- The catalog stays one code-versioned Python catalog with its existing **IMMUTABILITY CONTRACT**
  (never rename an existing preset id).
- The `"<namespace>.<short>"` id convention already yields non-colliding namespaces without
  flattening (`entry.fomo` coexists cleanly with the existing tag `fomo`).
- The single-character callback op (`0`–`4`, `s`, `S`) fits 4- and 5-item sets unchanged.
- Reuse means the **catalog and picker machinery**, not the column location: the new decision-events
  table carries its own `preset_ids text[]`. Preset ids are plain strings; `checkin_events` keeps
  its own column. No migration to the bot's preset storage.

## G. Scale UX (FROZEN)

Rapid fills inside the quiet window → **one episode**, silently aggregated. Outside the window:

```
[ ตามแผนเดิม ✓ ]   [ มีเหตุผลเพิ่ม ]   [ ไม่ใช่ Scale-in ]
```

`มีเหตุผลเพิ่ม` opens one preset layer, then done. **Do not restore a separate
"ไม้เข้าเดิม vs Scale-in ใหม่" interrogation** — it is permanently removed, not deferred.

## H. Screenshot ownership (FROZEN)

Attachment belongs primarily to the **decision event**; the position gallery is a derived view.
The Telegram photo handler is **greenfield** — no `filters.PHOTO`, `send_photo`, or `get_file`
exists anywhere in the bot today; a photo currently matches no handler and is dropped.

The existing **private `trade-images` bucket** should be reused if safe. Known constraints, recorded
now so a later design does not rediscover them: the path must satisfy a strict 4-segment regex whose
**first segment equals the viewing user's `auth.uid()`** or the signed URL fails; today the ref must
also be written where the app indexes it, or the object is invisible and counts as an orphan; the
bucket MIME allow-list and 5 MB limit bind service_role too; **no reproducible migration exists** for
the bucket or its policies; and delete is unimplemented by design. **No implementation designed
here.**

## I. Equity & exposure

### I1. Do not duplicate S1 facts

`mt5_sync_run_positions` already stores, immutably and append-only, per position per snapshot:
`volume`, `price_current`, `contract_size`, `symbol_raw`, `side`, plus run provenance and
`captured_at`. **Narrative events MUST NOT copy these.** Position and gross notional are *derived*
from the immutable snapshot, not stored.

Using S1 facts also resolves both defects the audit found in the browser implementation, without
reusing that code: S1 `volume` is MT5's **current open volume** (so the `contracts` vs
`remainingContracts` overstatement cannot occur), and `price_current` is a **mark** price (so the
entry-notional substitution cannot occur). **The existing `calcPositionValue` / `calcGearingX`
implementation is NOT to be reused as-is.**

### I2. S1.1 denominator contract (additive, later)

S1.1 captures the only genuinely irrecoverable facts. **Capture and use are separate concerns and
must not be conflated:**

- **CAPTURE — with every S1 broker snapshot/run observation.** Broker-observed account facts are
  read at the **same observation time as that run's position facts** and are **sealed with the
  run**, sharing its immutable `captured_at`. Capture is unconditional: it does **not** wait for a
  run to become healthy, complete, or current. A run that later fails or is judged suspicious still
  keeps the account facts it observed — that evidence is exactly what makes a degraded run
  diagnosable, and it can never be re-read later.
- **USE — only from trusted snapshots.** Gearing and exposure are displayed **only** from snapshots
  that satisfy the existing healthy/current/fresh read contract. Captured-but-untrusted account
  facts are audit evidence, never a rendered denominator.

| Field | Note |
|---|---|
| `account_balance` | supporting context |
| `account_equity` | the user-facing gearing denominator |
| `account_currency` | if useful |
| denominator **basis / quality / provenance** | e.g. source, completeness, degradation reason |
| `captured_at`, `source_account` | already present on the run; account facts share them |

- **User-facing gearing denominator = contemporaneous `account_equity`.** `account_balance` is
  supporting context and is **never** a competing headline denominator.
- **If trustworthy equity is unavailable or degraded → omit gearing.** Never silently fall back to
  balance. Never re-base against today's value (the current `%Port` column divides by *today's*
  balance and silently re-bases historical trades — that behavior must not be inherited).
- Rationale for the run row rather than the event row: the *ระหว่างถือ* peak metrics require equity
  at **every snapshot**, not only at decision moments.
- **S1 is not modified now.** S1.1 is a separate additive packet that occurs only **after** S1
  completes its current review → disposable-DB execution → apply gate. **S1.1 must land before live
  T2 capture begins** — every day capture runs without equity snapshots is exposure history that
  can never be reconstructed.

### I3. Allowlisted notional rule (FROZEN)

Exposure support is **allowlisted per instrument family**. There is no universal rule: the
`contractSize == tickValue / tickSize` invariant validates a **P/L multiplier**, and that does not
by itself prove economic-notional semantics for a future instrument.

| Family | Method | Validation basis |
|---|---|---|
| Gold `GO*` | `volume × contract_size × price` | **Dual-source**: catalog `contractSize` 300 == MT5 `trade_contract_size` 300 (dry-run report) |
| S50 | same | Single-source: catalog + multiplier invariant |
| Silver `SVF*` | same | Single-source: catalog + multiplier invariant |
| USDJPY futures | same | Single-source: catalog + multiplier invariant |
| SSF (e.g. `DELTAU26`) | — | **EXCLUDED** — no THUS product exists; MT5 reports `contract_size` 1000 against a stock preset of 1 (a 1000× error the existing tripwire correctly refuses). Junior currently holds open, unmatched DELTAU26 positions. |
| Spot / CFD (`XAUUSD`) | — | **EXCLUDED** — not a tradeable product in this system |
| Any user-added / unvalidated product | — | **EXCLUDED until explicitly allowlisted** |

Rules:

- A position is **valued** only if its family is allowlisted **and** the S1-captured MT5
  `contract_size` agrees with the allowlisted multiplier. Disagreement → **unresolved**, never a
  guess. This makes the DELTAU26-class error structurally impossible and does not rely on the
  user-editable catalog alone.
- **If ANY open position in the account is unresolved, whole-portfolio gross exposure is
  `unavailable`** — never a partial sum over the resolvable positions. A partial sum is understated,
  not merely incomplete, and reads as confident.
- **No FX service or workstream** for the currently validated set: all four families settle in THB
  and the conversion is already carried inside `tickValue`/`contractSize`. Do not build an FX
  service; do not add an `fx_rate` field. **Future products may require a new notional method**,
  including an FX-bearing one — that is a new allowlist entry, reviewed on its own.

### I4. Metric definitions (FROZEN)

- **Position exposure** = validated current position notional ÷ contemporaneous `account_equity`.
- **Portfolio gross exposure** = Σ |validated open position notional| ÷ contemporaneous
  `account_equity`. **Longs and shorts are NOT netted.**
- This is a **capacity/exposure** metric, **not** a complete risk metric, not margin utilization,
  not broker leverage, not directional beta. It must never be labelled as risk.
- **Peaks are snapshot-sampled, not tick-continuous.** A true intraday peak may exceed the reported
  one; label accordingly on desktop and do not chase tick-level truth.

## J. Closed Position Report (FROZEN)

Only **journaled / promoted** groups receive a normal Closed Position Report. **Skipped** →
no report. **Unconfirmed** → no report; remains audit/reconciliation state.

Preferred future Telegram surface:

```
🏁 GOU26 Long — ปิดแล้ว

+฿75,160 (+1.42% ของพอร์ต)
ถือ 3 วัน 6 ชม.

เริ่ม 3 → สูงสุด 6 สัญญา · Scale-in 2 ครั้ง
เข้าเฉลี่ย 4,231 → ออกเฉลี่ย 4,489

Exposure
ไม้นี้: เข้า 0.7× → สูงสุด 2.1× ของพอร์ต
ทั้งพอร์ต: ก่อนเข้า 0.9× → สูงสุด 3.4× ระหว่างถือ

[ บันทึกเหตุผลปิด ] [ ส่งรูป Exit ] [ จบเลย ✓ ]
```

- **Exposure lines are omitted when evidence is incomplete** (§I3). The report still ships with
  P/L, impact, and duration — a missing snapshot never blocks the payoff moment.
- **Portfolio impact** = net realized P/L ÷ `account_equity_at_entry`. Rendered `+1.42% ของพอร์ต`.
  **Do not call it "trade return"** — leverage makes that term ambiguous.
- The machine report must never depend on the human review being completed.

## K. Close review taxonomy (FROZEN)

Two independent axes — mechanical trigger, then self-assessment.

```
ปิดเพราะอะไร?
[ ถึงเป้า ]  [ Stop / Invalidation ]  [ Thesis เปลี่ยน ]  [ เลือกปิดเอง ]  [ อื่นๆ ]

เทียบกับแผน?
[ ตามแผน ]  [ ออกเร็วไป ]  [ ออกช้าไป ]  [ แหกแผน ]  [ ไม่แน่ใจ ]
```

Optional progressive layer only: mistake · next-time fix · Price Action · free text · screenshot.
No mandatory long-form review. Namespaces `close_trigger.*` and `close_adherence.*` per §F.

## L. Sequencing (FROZEN)

```
S1 current gate (review → disposable-DB execution → apply → post-verify)
  → S1.1 equity/balance capture on every run
    → T1 detection → T2 quiet window + capture_event → T3 prompts
      → T4 promotion → T5 screenshots
        → real-use observation
          → S2 deal reconstruction
            → Closed Report → post-trade review
              → desktop Completed Story → analytics
```

**Gate wording is deliberately split — design/prototype and live operation have different
preconditions:**

| Gate | Preconditions |
|---|---|
| **Before T1 design / local prototype** | T0 contract recorded (this document); stale planning docs corrected as appropriate. **S1 need not be applied.** Fixture- and prototype-level work may proceed while S1 is still completing its apply gate. |
| **Before T1 live operation** | **S1 applied and post-verified.** No live detector may treat the old staging lifecycle as current truth — `position_state` is hardcoded `"open"` and nothing transitions it, so a detector built on it today would read a permanently stale world. |
| **Before live T2 capture** | **S1.1 landed.** Every day capture runs without account snapshots is exposure history that can never be reconstructed. |

---

## Execution-link identity — recommendation (NOT frozen)

**`trades.mt5PositionId UNIQUE` is explicitly rejected.** The repository contains evidence of both
exact 1:1 position matches (`"id"` match kind) **and** aggregate Journal trades matching *multiple*
MT5 position ids (`_reconFindSubsets` → `EXACT_AGGREGATE_MATCH`). A unique column on `trades` cannot
represent the aggregate case, and `mt5PositionId` today is not a column at all — it survives only
inside the `raw` jsonb, unindexed and non-unique.

**Recommended shape: a link table, not a column.** One row per (account, MT5 position) → canonical
trade, carrying capture provenance:

- unique on `(user_id, source_account, mt5_position_id)` → **promote-once at position granularity**
- many link rows may share one `trade_id` → **aggregate cases representable**
- promotion consults the link table first → **link existing evidence instead of duplicating**
- group association follows the canonical trade → **compatible with G2 and one-member groups**
- `trade_id` is a **durable logical reference to the canonical Journal trade**
- existing `raw.mt5PositionId` values are backfillable into link rows **without touching `trades`**

**`trade_id` FK vs non-FK is explicitly NOT frozen here.** The `trades` DDL is **not
source-controlled** — no migration in this repo creates the table, and its identity/constraints
(`trades_pkey` compound `(id,user_id)` plus a separate `UNIQUE(id)`) are attested only by secondary
artifacts and by `onConflict:"id"` working in production. The existing
`materialized_trade_id text — NOT an FK` precedent is **not** sufficient grounds to freeze the same
choice. **T4 must inspect the live `trades` identity and constraints in a schema preflight before
choosing FK or non-FK**, exactly as the G2 packet preflighted `trades.id` being `text` before apply.

**Intentionally left open** (must be closed in the T4 design, not here): the `trade_id` FK decision
above; whether the same table also keys `deal_id` for S2 partial/close linkage; whether a
`link_kind` vocabulary is needed in v0.1; backfill policy for existing imported trades; and whether
`raw.mt5PositionId` is retained as a read-only denormalized convenience.

---

## Explicitly deferred

Thesis versioning · G2 ungroup UI · MT5 web-Inbox write actions (0D-2+, **SUPERSEDED**) · 0C-3d
lifecycle reconcile (**SUPERSEDED by S1**) · S2 and everything downstream · net directional exposure
· exposure curve visualization · gearing-band and crowding analytics · Telegram Mini App · any AI
involvement in capture · FX service.

## MUST-DECIDE before T1 design (per the §L gate split)

1. **Operator verification of the live production bundle** (§0) — `APP_VERSION` cannot resolve it.
2. **Record the Telegram-first decision in-repo** — this document is that record; the stale
   web-as-primary tags in `03_PRODUCT_MAP.md` §5 and `04_COMPLETE_ROADMAP.md` §3 still need
   re-tagging.
3. **Correct three load-bearing Project Bible entries**: the **stale** prod byte-identity statement
   (§0 — no longer trustworthy as a current-state assertion), the MT5
   materializer tagged both `DESIGNED` and "not started", and the dangling `14_CURRENT_STATE.md`
   reference that `00_AI_BOOTSTRAP.md` sends every agent to.

Not blockers for **T1 design**: the execution-link shape and its `trade_id` FK preflight (both T4),
the R0.5A branch merging (freeze in place), **S1 apply** (blocks T1 *live operation*, not design),
and **S1.1** (precedes live **T2**).
