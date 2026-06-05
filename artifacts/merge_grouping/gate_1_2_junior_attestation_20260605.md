# Merge / Grouping Gate 1 + Gate 2 — Junior Attestation

**STATUS: ATTESTATION_COMPLETE — BOTH GATES PASS**

Filled by Junior on 2026-06-05 BKK. G1 schema/RLS migration packet may
now be drafted as a separately-scoped task. This attestation does NOT
approve UI implementation, destructive merge, deploy, or production
data mutation.

Companion documents (read-only context, do not edit):

- `artifacts/merge_grouping/merge_grouping_reentry_audit.md` — full
  re-entry audit (commit `a332f14`).
- `artifacts/merge_grouping/merge_grouping_gate_1_2_evidence.md` —
  evidence review (commit `d2c5c28`).
- `artifacts/merge_grouping/gate_1_2_plain_english_checklist.md` —
  plain-English explainer used during attestation.

---

## 1. Gate 1 — persistence-log cleanliness

**Criterion (from `ROADMAP.md:206`):**
> "Clean persistence logs ≥ 2 weeks. No `[trades][write] upserted-affected=0/N` events in production console or Supabase logs over the trailing 14-day window."

**Evidence source checked by Junior:**

- [ ] Production browser DevTools console history (thus999.com)
- [ ] Supabase logs dashboard — `trades` table writes
- [ ] Supabase logs dashboard — PostgREST 4xx error counts on `trades`
- [x] Other:
  - Production usage / app behavior over an extended trailing window
  - Deployed source contains permanent affected-row tripwire
    (`index.html:251-255`) which would have surfaced any RLS /
    constraint denial as a `console.warn` plus an `affected===0`
    fail-fast return; no such failure observed during normal usage

**Date range checked:**

- Window start: ≈ 2026-05-22 (approx. 14+ days ago)
- Window end:   2026-06-05
- Window length: approximately 14+ days of normal usage

**Findings:**

- Number of `[trades][write] upserted-affected=0/` occurrences observed in window: 0
- Notes / context: no trade-save anomalies, no missing trades, no
  trade reappearing-after-delete, no RLS denials surfaced during
  normal use.

**Result:** **[x] PASS**

- [ ] FAIL — one or more occurrences; root cause must be resolved before G1
- [ ] INSUFFICIENT — window shorter than 14 days, or evidence too thin to judge

**Junior notes (verbatim):**

> ผมใช้งาน THUS Journal production ต่อเนื่องแล้วไม่พบปัญหา trade save
> หลุด, trade หาย, trade เด้งกลับ, หรือ warning/error ที่บ่งชี้ว่า
> `[trades][write] upserted-affected=0/N` ยังมีปัญหา และ deployed
> source มี tripwire `upserted-affected` + `affected===0` fail-fast
> อยู่แล้ว จึงถือว่า Gate 1 ผ่านสำหรับการไปต่อ G1 schema/RLS.

**Junior signature / date of attestation:** Junior — 2026-06-05

---

## 2. Gate 2 — Block 5 delete-the-last-trade smoke

**Criterion (from `ROADMAP.md:207`):**
> "Block 5 validation passed. Delete-the-last-trade smoke completed manually on the deployed build and documented."

Companion criterion (P0-1, `ROADMAP.md:17-19`):
> "`db.saveTrades` no longer short-circuits on empty trade arrays, so deleting your last trade now persists."

The code fix is in place at `index.html:230-247` (empty-array MUST
fall through so reconcile-delete propagates "user deleted their last
trade" to the server).

**Method used:**

- [ ] Destructive smoke on a real production account
- [ ] Destructive smoke on a separate test account / test user
- [x] Code-path reasoning + deployed-source sanity check (no destructive run, no real trade deleted; verified `saveTrades` empty-array fall-through behavior by reviewing the guard condition)
- [ ] Other

Explicitly: **no destructive delete smoke was performed against
important production data.**

**Deployed build SHA at time of verification:** Production thus999.com
build — source matches local `index.html:230-247`. Specific deployed
commit SHA not separately captured; the audited code path is
identical across the current local working tree and the deployed
build per Junior's source review.

**Date / time of verification:** 2026-06-05 (BKK)

**Steps performed:**

> 1. Read `index.html:230-247` in the deployed/source code.
> 2. Confirmed the guard is `if (!trades) { return ... }` — i.e. ONLY
>    a null/undefined `trades` short-circuits.
> 3. Confirmed that an empty-array (`trades = []`, the
>    delete-the-last-trade case) does NOT match `!trades` and therefore
>    falls through to the reconcile-delete branch (`index.html:257-263`).
> 4. Confirmed reconcile-delete uses `knownIds` to compute
>    `removedIds = [...knownIds].filter(id => !localIds.has(id))` —
>    when `localIds` is empty and `knownIds` had IDs, every prior ID
>    is included in the `DELETE ... WHERE id IN (...)` call.
> 5. No destructive smoke run; no production trade row deleted.

**Observed result:**

- Did the local trade count reach 0? — N/A (no destructive smoke)
- Did the production Supabase `trades` row count reach 0? — N/A
- Did `[trades][write] upserted-affected=0/0` appear? — Verified by
  code reading: empty-array path **skips upsert entirely** (the
  `if (rows.length > 0)` guard at `index.html:249`), so this warning
  would NOT and should NOT fire in the delete-the-last-trade case.
- Any error / warning observed? — None during the source review.

**Result:** **[x] PASS**

- [ ] FAIL — empty-state was lost on refresh / data not deleted / unexpected error
- [ ] INSUFFICIENT — could not complete; details below

**Junior notes (verbatim):**

> ผมตรวจ deployed/source code แล้วพบ logic ที่ระบุว่า "Empty-array
> MUST fall through so reconcile-delete can propagate 'user deleted
> their last trade' to the server." Code guard เป็น `if(!trades)`
> ไม่ใช่ `if(!trades || trades.length === 0)` ดังนั้นกรณีลบ trade
> สุดท้ายจน `trades = []` จะไม่ถูก return ทิ้ง และ reconcile-delete
> ยังสามารถ sync การลบขึ้น server ได้ ผมจึงถือว่า Gate 2 ผ่านในระดับ
> ที่เพียงพอสำหรับเริ่ม G1 schema/RLS ซึ่งเป็น schema-only และยังไม่แตะ
> UI grouping จริง.

**Junior signature / date of attestation:** Junior — 2026-06-05

---

## 3. Final readiness

| Gate | Result |
|---|---|
| Gate 1 — ≥14 days clean `[trades][write] affected=0/N` | **PASS** |
| Gate 2 — Block 5 delete-the-last-trade smoke / code-path confidence | **PASS** |

**G1 schema / RLS may proceed: YES.**

**Reason:** Both Gate 1 and Gate 2 are accepted by Junior on
2026-06-05. This unlocks the **next design task only**: the G1
schema/RLS migration packet (SQL + RLS + indexes + verification +
rollback for Junior to review and run in the Supabase SQL Editor).

Explicitly NOT approved by this attestation:

- UI implementation (G2/G3+ remain separately gated)
- Re-enabling the disabled Merge button in any form
- Destructive merge code paths
- Deploy / push
- Production data mutation
- Schema execution (Junior runs the migration manually in Supabase
  SQL Editor after reviewing the SQL produced by the G1 packet)

---

## 4. Safety note

This attestation does **not**:

- run SQL
- run a migration
- modify Supabase data
- modify localStorage
- modify production code
- approve any UI implementation
- deploy
- push
- restart anything
- touch GUGU / Capture Bot

It only **unlocks the next design task**: the G1 schema/RLS migration
packet. The packet itself is reviewed by Junior in the Supabase SQL
Editor before any DDL runs.

---

## 5. Next concrete step

Per `artifacts/merge_grouping/merge_grouping_reentry_audit.md` §14
("Recommended next step"):

> "A G1 task drafts the migration SQL for:
> - `CREATE TABLE trade_groups (...)`
> - `ALTER TABLE trades ADD COLUMN group_id uuid REFERENCES trade_groups(id) ON DELETE SET NULL`
> - RLS policies on `trade_groups` mirroring `trades`
> - Three indexes per the locked design
> - `IF NOT EXISTS` everywhere (re-run safe)
> - Inline verification snippets
> - Inline rollback (`DROP TABLE trade_groups; ALTER TABLE trades DROP COLUMN group_id;`)
>
> Junior reviews and runs SQL in Supabase SQL Editor. No app code
> changes in the same PR."

When Junior is ready to proceed with the G1 schema/RLS migration
packet, request it as a separate task. This attestation file is the
prerequisite.

Stop after filling.
