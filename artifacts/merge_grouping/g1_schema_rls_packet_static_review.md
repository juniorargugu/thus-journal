# G1 Schema + RLS Migration Packet — Static Review

**Status:** `G1_SCHEMA_RLS_STATIC_REVIEW_COMPLETE`

**Verdict:** `READY_TO_COMMIT_PACKET`

Generated 2026-06-07 BKK. **Review-only.** No SQL was executed.
No Supabase write. No app code touched. No deploy. No push. No restart.
No commit performed.

Junior's run-time gate (Junior reviews + runs SQL in Supabase SQL Editor)
remains intact and is not impacted by this review.

---

## 1. Executive summary

The G1 packet (migration SQL + companion review document) is internally
consistent, scope-compliant, idempotent, and faithful to the locked
design in `ROADMAP.md:87-210`. Verification queries are SELECT-only and
comprehensive. Rollback SQL is present, correctly ordered, and clearly
guarded with a destructive-data warning. No security or RLS regression
risk identified. No mutation beyond schema/RLS scope.

The single deviation from the locked design (a composite leading
`user_id` on the `trades.group_id` partial index) is documented in the
packet as an enhancement and is strictly more useful than the
single-column form for the per-user query pattern used throughout the
schema. It is not a blocker.

The one explicit open question in the packet (open question #10.4 —
existing `trades.user_id` FK delete behaviour) is correctly surfaced
with a SELECT-only verification query Junior runs **before** applying
the migration. This is the right disposition: any answer leaves the
packet runnable.

No blockers. The packet is ready for Junior to commit (separately,
when asked) and then schedule a "Run G1" task.

---

## 2. Files reviewed

| File | Status checked |
|---|---|
| `migrations/20260607_g1_trade_groups_schema.sql` | Read end-to-end (422 lines). |
| `artifacts/merge_grouping/g1_schema_rls_migration_packet.md` | Read end-to-end. Cross-referenced every claim against the SQL. |
| `artifacts/merge_grouping/merge_grouping_reentry_audit.md` | Re-read §4, §6, §7, §14 for scope compliance. |
| `artifacts/merge_grouping/merge_grouping_gate_1_2_evidence.md` | Re-read to confirm gates referenced in the SQL header are the actual passed gates. |
| `artifacts/merge_grouping/gate_1_2_junior_attestation_20260605.md` | Confirmed: Gate 1 PASS, Gate 2 PASS, "G1 schema / RLS may proceed: YES". |
| `ROADMAP.md:87-210` | Re-read to compare each migration block against the locked design. |
| `migrations/20260512_archive_trade_events_v1_lockdown.sql` | Re-read to confirm style adherence (file naming, header tone, `REVOKE ALL FROM anon`, comment-block rollback). |

No production database was queried during this review.

---

## 3. Verdict

**`READY_TO_COMMIT_PACKET`**

Reasoning: the packet does only what the locked design calls for,
documents every deviation, includes a re-runnable migration with
SELECT-only verification, and a correctly ordered rollback. The
single open question is surfaced as a pre-run Junior check, not as
an unknown that the SQL silently relies on. No security/RLS/grant
ambiguity was identified. No SQL mutation beyond schema/RLS.

This verdict authorises a **separate, explicitly-asked** commit of
the two untracked packet files:

- `migrations/20260607_g1_trade_groups_schema.sql`
- `artifacts/merge_grouping/g1_schema_rls_migration_packet.md`

(and, on Junior's instruction, also this review document).
The verdict does **not** authorise running the SQL — that remains
Junior's manual SQL Editor session, gated on §11 of the packet.

---

## 4. Idempotency review

Re-runnable safely from a clean shell with no errors and no duplicate
objects. Each DDL block is guarded:

| Block | Guard | Verdict |
|---|---|---|
| §0 `CREATE EXTENSION IF NOT EXISTS pgcrypto` | Built-in `IF NOT EXISTS`. | ✅ |
| §1 `CREATE TABLE IF NOT EXISTS public.trade_groups` | Built-in `IF NOT EXISTS`. | ✅ (caveat — see below) |
| §2 `ALTER TABLE public.trades ADD COLUMN IF NOT EXISTS group_id` | Postgres 9.6+ supports this. Supabase = PG 14/15. | ✅ |
| §3 FK `trades_group_id_fkey` | Wrapped in `DO $$ ... IF NOT EXISTS (SELECT … pg_constraint …) ...` block. | ✅ |
| §4 indexes | `CREATE INDEX IF NOT EXISTS` per index. | ✅ |
| §5 `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` | Native no-op on re-run. | ✅ |
| §6 four policies | `DROP POLICY IF EXISTS` immediately before each `CREATE POLICY`. | ✅ |
| §7 GRANT/REVOKE | Re-granting the same set is a no-op. | ✅ |
| §8 `COMMENT ON` | Overwrites prior comment idempotently. | ✅ |

**Caveat at §1:** `CREATE TABLE IF NOT EXISTS` is silent when the
table already exists with divergent columns. The packet documents
this in §10.1 and verification query V1 (column-list dump) covers it.
Accepted disposition — the operator (Junior) sees actual columns and
compares to expected before declaring done.

**Caveat at §2:** if a pre-existing `trades.group_id` column of a
different type were already present, `ADD COLUMN IF NOT EXISTS` would
silently no-op. V2 verification covers this. Accepted disposition.

No idempotency blocker.

---

## 5. RLS review

`ALTER TABLE public.trade_groups ENABLE ROW LEVEL SECURITY` (line 189).

Four policies follow the `TO authenticated` pattern with `user_id =
auth.uid()` gates:

| Policy | Verb | `USING` | `WITH CHECK` | Verdict |
|---|---|---|---|---|
| `trade_groups_select_own_rows` | SELECT | `user_id = auth.uid()` | n/a | ✅ |
| `trade_groups_insert_own_rows` | INSERT | n/a | `user_id = auth.uid()` | ✅ |
| `trade_groups_update_own_rows` | UPDATE | `user_id = auth.uid()` | `user_id = auth.uid()` | ✅ — both clauses correctly prevent flipping `user_id` to another user mid-update. |
| `trade_groups_delete_own_rows` | DELETE | `user_id = auth.uid()` | n/a | ✅ |

Naming pattern (`<table>_<verb>_own_rows`) is consistent and greppable.

Each policy is preceded by `DROP POLICY IF EXISTS …` so the block is
fully re-run safe.

**`TO authenticated`** is correctly used. Anonymous users (anon role)
get no rows even if the GRANT block were tampered with later, because
`auth.uid()` is NULL for anon and `NULL = NULL` evaluates to NULL
(unknown), failing the gate. The explicit role binding is strictly
safer than the bare `CREATE POLICY ... USING (...)` form, even if the
existing `trades` policies use the bare form.

No RLS gap. No security regression introduced.

---

## 6. GRANT review

Lines 250–252:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON public.trade_groups TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.trade_groups TO service_role;
REVOKE ALL                            ON public.trade_groups FROM anon;
```

- **`authenticated`:** the four PostgREST-exposed verbs, gated by the
  policies in §6. No TRUNCATE, no REFERENCES, no TRIGGER, no USAGE —
  none of which authenticated needs. ✅
- **`service_role`:** the same four verbs. Belt-and-braces given that
  service_role bypasses RLS by default; documents intent and
  future-proofs against any Supabase default change. ✅
- **`anon`:** explicit `REVOKE ALL`. Mirrors the v1
  `trade_events_lockdown` style and makes the lockdown visible to
  anyone reading the file. ✅

**Sequence grants:** not required — `id` is `uuid DEFAULT
gen_random_uuid()`, no underlying sequence. ✅

**`CREATE EXTENSION IF NOT EXISTS pgcrypto`** at line 81: Supabase
projects ship with pgcrypto enabled by default and grant the editor
role sufficient privilege to issue this in the SQL Editor. The `IF NOT
EXISTS` keeps it harmless even if the extension already lives in the
`extensions` schema (which is in the default search_path). ✅

No GRANT gap. No privilege over-grant.

---

## 7. FK / delete behaviour review

Two FKs are introduced by the migration:

### 7.1 `trade_groups.user_id REFERENCES auth.users(id) ON DELETE CASCADE`

(Line 106.)

- Deleting a user cascade-deletes all of their `trade_groups`. ✅
- Matches the **assumed** existing behaviour on
  `trades.user_id REFERENCES auth.users(id) ON DELETE CASCADE`.
- The packet flags the assumption explicitly as **open question
  #10.4** with a one-liner read-only query Junior runs in step 3 of
  §11 to verify. ✅ — This is the correct disposition: the migration
  is runnable either way; Junior simply confirms the cascade
  behaviour matches before proceeding so the two tables behave
  consistently under user-delete.

**Reviewer's note:** even if the existing `trades.user_id` FK uses a
different rule (e.g. `RESTRICT`), the new `trade_groups.user_id
CASCADE` is not dangerous on its own. The worst case is that
deleting a user fails on `trades` and never gets to fire the
`trade_groups` cascade. No data loss in either direction. So the open
question is one of consistency, not safety. ✅

### 7.2 `trades.group_id REFERENCES trade_groups(id) ON DELETE SET NULL`

(Lines 146–150 inside the §3 DO block.)

- Dropping a group row sets each child's `group_id` to NULL. ✅
- Does **not** delete the child trade. ✅
- Matches the locked non-destructive ungroup semantics exactly. ✅
- The reverse direction is not present — the FK does not cascade from
  child to parent. Deleting a trade does not affect any group row.
  This is the desired behaviour: legacy `trades` row removal must not
  trigger group metadata loss. ✅

**No group row is inserted by the migration.** No DML at all.
**No existing trade row is mutated.** No `UPDATE`, no `INSERT`, no
data-rewriting `ALTER`. ✅

FK behaviour is correct and matches the locked design.

---

## 8. Verification SQL review

Nine inline verification blocks (V1–V9), all commented as documentation
inside the SQL file, all SELECT-only.

| # | What it checks | SELECT-only? | Mutation risk |
|---|---|---|---|
| V1 | `trade_groups` columns / types / defaults / nullability | Yes (`information_schema.columns`) | None |
| V2 | `trades.group_id` exists + is nullable | Yes (`information_schema.columns`) | None |
| V3 | FK definition (uses `pg_get_constraintdef`) | Yes | None |
| V4 | Three indexes present, partial WHERE clauses | Yes (`pg_indexes`) | None |
| V5 | RLS enabled on `trade_groups` (`relrowsecurity`) | Yes (`pg_class`) | None |
| V6 | Four policies + their `using/with check` clauses | Yes (`pg_policy`) | None |
| V7 | Privilege bits for anon/authenticated/service_role | Yes (`has_table_privilege`) | None |
| V8 | Zero rows in `trade_groups`; zero `trades.group_id IS NOT NULL` | Yes (`COUNT(*)`) | None |
| V9 | `COUNT(*) FROM public.trades` pre vs post migration unchanged | Yes (`COUNT(*)`) | None |

V8 + V9 together form the load-bearing "did the migration touch trade
data?" check. V9 explicitly requires the operator to capture a
baseline number BEFORE the migration. The packet §11 step 4 documents
how to do this.

No mutations. No risk. Verification block is comprehensive against the
schema deltas the migration claims to introduce.

---

## 9. Rollback SQL review

The rollback block (lines 384–421) is fully commented out and clearly
labelled. Order is correct:

1. `DROP CONSTRAINT IF EXISTS trades_group_id_fkey` (FK)
2. `DROP INDEX IF EXISTS` (×3)
3. `DROP POLICY IF EXISTS` (×4)
4. `DROP TABLE IF EXISTS public.trade_groups` (**no CASCADE**)
5. `ALTER TABLE public.trades DROP COLUMN IF EXISTS group_id`

The whole block is wrapped in `BEGIN; ... COMMIT;` so an operator can
dry-run with `BEGIN; ... ROLLBACK;` first.

Findings:

- ✅ FK dropped first so the table drop in step 4 has no dependency.
- ✅ Indexes dropped explicitly (the two on `trade_groups` would be
  dropped automatically by step 4, but the third — `trades_group_id_idx`
  on `public.trades` — must be dropped explicitly because it lives on
  a separate table; this is correctly handled here).
- ✅ Policies dropped before the table — harmless even though
  `DROP TABLE` would drop them automatically. Explicit for clarity.
- ✅ `DROP TABLE` uses **no `CASCADE`** — correctly fails loud if an
  unexpected dependent object exists.
- ✅ Column drop is the last step, after the FK is already gone.
- ✅ The destructive-data warning above the block ("If groups have
  already been created in production, this rollback will delete those
  group metadata rows … export them first or skip the rollback.") is
  clear and accurate.

No accidental cross-object drops. No risk of unrelated object removal.
Pre-condition guidance is correct.

---

## 10. Design-scope compliance

Compared against `merge_grouping_reentry_audit.md` and
`gate_1_2_junior_attestation_20260605.md`:

| Requirement from locked design / audit | Implementation | Verdict |
|---|---|---|
| New table `trade_groups (id, user_id, label NOT NULL, group_pre_note, group_post_note, created_at, updated_at, archived_at)` | Lines 104–113 match column-for-column. | ✅ |
| `trades.group_id uuid REFERENCES trade_groups(id) ON DELETE SET NULL` | Line 122–123 (column) + §3 DO block (FK). | ✅ |
| RLS `user_id = auth.uid()` mirror of trades | Lines 189–233. Four policies, all gated correctly. | ✅ |
| Index `trade_groups(user_id)` | Lines 172–173. | ✅ |
| Index `trade_groups(user_id) WHERE archived_at IS NULL` | Lines 175–177. | ✅ |
| Index `trades(group_id) WHERE group_id IS NOT NULL` | Lines 179–181 — implemented as composite `(user_id, group_id) WHERE group_id IS NOT NULL`. | ⚠️ Minor deviation (see §12 below). |
| **No backfill.** | Confirmed — zero DML. | ✅ |
| **No trade row mutation.** | Confirmed — zero `UPDATE`/`INSERT` on `trades`. | ✅ |
| **No raw.groupId update.** | Confirmed — no DML on `trades`, no JSON touched. | ✅ |
| **No app reducer change.** | Confirmed — no `index.html` edits. | ✅ |
| **No localStorage change.** | Confirmed — pure SQL packet. | ✅ |
| **No Notification Center / margin / profit reminder change.** | Confirmed — pure SQL packet. | ✅ |
| **No UI implementation.** | Confirmed — G2 is a separate later task per packet §13. | ✅ |
| **No GUGU / Capture Bot touch.** | Confirmed — no files touched outside `migrations/` and `artifacts/merge_grouping/`. | ✅ |
| Junior reviews + runs SQL in Supabase SQL Editor (Gate 4) | Packet §11 documents the exact step-by-step. | ✅ |
| Pre-G1 Gate 1 + Gate 2 PASS | SQL header lines 12–17 explicitly cite the attestation file (`gate_1_2_junior_attestation_20260605.md`, commit `c796db3`) and the PASS result for each gate. | ✅ |

### Packet/report consistency cross-checks

- ✅ Packet `g1_schema_rls_migration_packet.md` claim: "Migration applied? **No.** Draft only." — confirmed by `git status --short` showing the SQL file as untracked.
- ✅ Packet claim: "App code changes? **None.**" — confirmed by `git status` showing no modified files in `index.html` or elsewhere.
- ✅ Packet claim: "Supabase changes? **None.**" — no Bash command in this session connected to Supabase; the SQL is a draft only.
- ✅ Packet claim: "Includes exact Junior review/run instructions" — §11 has the 12-step run procedure, including pre-run baseline capture and post-run verification.
- ✅ Packet claim: "Includes open question #10.4" — confirmed at line ~258 of the packet, with the one-liner verification query.
- ✅ Packet claim: "Next step is review, then separate Run G1 task" — confirmed in §13 of the packet.
- ✅ Packet does NOT imply UI grouping is approved — §12 explicitly lists G2/G3/G3.5/G4/G5/G6 as non-goals.
- ✅ Packet does NOT imply destructive merge is allowed — §12 explicitly lists "Deletion of dead `handleMerge`/`mergeSelected`/`_hiddenByMerge` code" as a non-goal, deferred to the G3 PR.

All packet claims map cleanly to either SQL content or the audit/attestation it cites.

---

## 11. Blockers

**None.**

No security, RLS, grant, FK, idempotency, scope, or rollback issue
rises to a blocker level. The single deviation from the locked design
(§12 item #1 below) is documented in the packet and is strictly more
useful than the locked variant.

---

## 12. Non-blocking suggestions

These do **not** block commit of the packet or running of the SQL.
Recorded so Junior is aware before signing off, and so any future
review of `trade_groups` design starts from a complete picture.

1. **Composite `(user_id, group_id)` index on `trades`** vs locked
   design's single-column `(group_id)`. The migration uses a composite
   leading-`user_id` partial index because all per-user queries go
   through `WHERE user_id = uid AND group_id = X`. The locked design
   reads `trades(group_id) WHERE group_id IS NOT NULL` (single
   column). The composite form is **strictly more useful** (covers
   the per-user query pattern; does not require a separate scan to
   filter by user) and is documented in packet §5.3. If Junior
   prefers strict adherence to the locked text, the index can be
   replaced with the single-column form pre-run without invalidating
   any other part of the migration. No data risk either way.

2. **`TO authenticated` role binding on policies.** The migration
   restricts every `trade_groups` policy to the `authenticated` role
   explicitly. Whether the existing `trades` policies use the same
   restriction is **not verified** in this packet (no Supabase query
   was performed). The chosen behaviour is strictly safer than the
   bare `CREATE POLICY ... USING(...)` form. If existing `trades`
   policies bind to `PUBLIC`, the two tables will have slightly
   different policy headers, but functionally equivalent gates.
   Aligning the two is a cosmetic concern at best.

3. **Open question #10.4 — `trades.user_id` FK cascade behaviour.**
   The packet correctly surfaces this and provides a one-liner
   verification SQL in §11 step 3. Junior should run that one-liner
   in the SQL Editor first and decide whether to amend the new
   `trade_groups.user_id` CASCADE to match (if `trades.user_id` is
   not `CASCADE`) before applying the full migration. The migration
   is **runnable** in either case; this is a consistency check, not
   a safety check.

4. **`label NOT NULL`** is per the locked design but worth flagging
   for G3 UI: if any G3 code path constructs a `trade_groups` insert
   before label generation completes (e.g. async label compute), the
   INSERT will fail. Recommend G3 design ensures `label` is computed
   client-side before the INSERT. Documented in packet §10.6.

5. **Optional hardening for very large `trades` tables**
   (`NOT VALID` + `VALIDATE CONSTRAINT` two-step FK creation) is
   documented in packet §10.7 as not needed at current volumes.
   Re-evaluate if the table grows past several million rows. Not a
   concern today.

6. **Re-run safety vs schema drift detection.** If a pre-existing
   `public.trade_groups` table is found with divergent columns, the
   migration is silent because `CREATE TABLE IF NOT EXISTS` no-ops.
   V1 verification catches this (column-list dump), but the operator
   has to **read** V1's output and compare. Adding an explicit
   ASSERT-style block was considered out of scope for v0.1 and
   appropriately deferred. Note this in Junior's run checklist so
   step 9 (run V1) is not skipped.

7. **`CREATE EXTENSION` privilege.** The `CREATE EXTENSION IF NOT
   EXISTS pgcrypto` line is harmless on every Supabase project since
   pgcrypto ships pre-installed. If a future Supabase migration
   environment denies the SQL Editor role the `CREATE EXTENSION`
   privilege, the line could fail loud rather than silently — at
   which point removing the line is the correct fix because pgcrypto
   is already present. Not a current concern.

8. **Run order inside the SQL Editor.** §11 step 7 suggests pasting
   "everything above the VERIFICATION QUERIES divider". Worth
   emphasising: the entire migration must be pasted in **one
   request**, not split across two pastes, so the `DO` block on line
   135 and the `CREATE POLICY` blocks remain in the same session.
   The SQL Editor does support multi-statement input; the `DO` block
   syntax (`$$ … $$`) requires the editor not to split on `;`. The
   Supabase SQL Editor handles this correctly out of the box. Worth
   a sentence in §11 to be explicit.

None of these warrant revision-before-commit. They are nice-to-haves
for Junior's run-time checklist.

---

## 13. Recommended next step

Junior reads this review report end-to-end (~3 minutes), then:

1. **If Junior agrees with the verdict**, ask for an explicit "commit
   the G1 packet" task. That task commits the two untracked files
   (`migrations/20260607_g1_trade_groups_schema.sql` and
   `artifacts/merge_grouping/g1_schema_rls_migration_packet.md`), and
   optionally this review document, as one commit titled e.g.
   `docs: add G1 trade groups schema/RLS packet`.

2. **After commit**, open a separate "Run G1 — Apply Trade Groups
   Schema" task. That task is the manual SQL Editor session described
   in packet §11 (verify open question #10.4 → take baseline COUNT →
   paste + run migration → run V1–V9 verification → smoke the app →
   record G1 done).

3. **After G1 applies**, draft the Gate 5 P/L snapshot baseline as a
   separate task (packet §13 step 2). Only after Gate 5 baseline
   exists does G2 design begin.

This review document explicitly does **not** authorise running the
SQL, committing the packet, or starting G2 design.

Stop after report.
