# THUS — PROJECT STATE

Single visible source of truth for Junior, GPT, Claude Code and Codex. **Cap: 150 lines.** One writer
per routing; every routing leaves §10 correct. Detail lives in `artifacts/`, not here.
**Updated:** 2026-09-26 · Claude Code · authority: GPT M1 local pre-release preparation order (M0b-B closed PASS)

| Question | Answer |
|---|---|
| What are we building? | A read-only MT5 exposure view in the Journal → an iPhone widget (§1, §7) |
| What can I use now? | Journal v3.23.0 served from `f37a0ef` since 2026-09-26 (mobile adoption UI + PWA manifest) (§2) |
| What is blocked? | The S2 **writer** track (§6). The read-only product track is not blocked by S2 gates |
| What comes next? | Junior's explicit M1 production-release authorization (§10). Push/deploy NOT authorized |

**Roles.** GPT — product/architecture planning owner · Claude Code — technical co-planner, challenger,
implementer, self-reviewer · Codex — independent verifier · Junior — product owner, UX, production
authorization.

## 1. Product goal
THUS is an AI-native trading OS; the Journal is its memory/data layer. **Near-term product:** Junior
sees their live MT5 exposure — by symbol, gross notional, floating P/L, freshness — first in the Journal
(M1), then with gearing % and P/L % (M2), then on an iPhone widget (M4). All of it read-only.

## 2. Current user-visible production
- **Served production application = `f37a0ef593b78791b0b1f00096106735b4c59ab3`** (= `origin/main`), v3.23.0,
  Netlify published deploy **`6ab79fafcfc6664f22148556`** (2026-09-26T10:34:31Z); index sha256 `97490a0b…`
  604,225 B; manifest/icons 200. Before M0b-B: served bytes = `f01eb33` (deploy `6a513ea9…`, commit `84c0a05`).
- **Release path (M0b CLOSED):** push to `main` → Netlify production auto-build + auto-publish, **credit-gated**
  (Free plan, 300 credits/month; July builds were skipped for credit exhaustion). Every push to `main`,
  including docs-only, costs a production build → **avoid standalone docs-only pushes to `main`.**
- Live read-only MT5 surfaces: Settings MT5 Inbox (0D-0/0D-1), default-off `tj_mt5_inbox`.

## 3. Current milestone — M1 MT5 Exposure
| Review | State |
|---|---|
| GPT product/architecture review | **COMPLETE** |
| Prior Codex independent review | **CHANGES_REQUIRED** (account discovery, non-finite arithmetic, P/L currency, mutation coverage) |
| GPT correction planning/review | **COMPLETE** |
| Claude Code correction batch | **COMPLETE** 2026-09-26 |
| Final Codex re-verification | **COMPLETED** — implementation verification **PASS** (3 bases 136/136 + static 22/22; repo static 25/25; mutants 24/24 killed, 0 survivors/invalid; production accounting ZERO) |
| GPT correction decision | **ACCEPTED** |
| State-only correction | **ACCEPTED BY GPT** |
| origin/main replay + local freeze | **COMPLETE** — `5b23f2ba93560a0700602ab06dfbd3c9c4eb183f` `feat: add read-only MT5 exposure card`, parent `f37a0ef`; 136/136, static 22/22 (25/25 repo), compile PASS |
| M0b-B production catch-up | **PASS** — production validation PASS; Junior authenticated smoke PASS; rollback NOT USED |
| Local release preparation | **COMPLETE** — one local commit `chore: prepare v3.24.0 release` on top of `5b23f2b` (APP_VERSION 3.23.0 → 3.24.0 + this file) |
**M1 is LOCAL ONLY — not pushed, not deployed. M1 release: NOT YET AUTHORIZED.**
- `index.html` only, **+253 / −0**, sha256 `9f051131…`; default-off `tj_mt5_exposure`; mounted in `App`
  above `PagePositions`; card-scoped error boundary.
- **Reads:** ONE account-discovery SELECT (`source_account` only, exact count, no row limit,
  completeness proven) + AT MOST ONE `mt5_get_current_snapshot_v1` call. Never chooses between accounts.
- **Shows:** per-symbol Long/Short **gross** notional in each symbol's own **unconverted** currency,
  lots, position count, **floating P/L in the MT5 account's deposit currency (not identified by M1)**,
  snapshot freshness + time. Missing or non-finite data → "—", never 0 / ∞ / NaN.
- **Deliberately absent:** gearing %, P/L %, FX, equity, cross-symbol total notional.
- Release lineage: `f37a0ef` → `5b23f2b` → release-prep commit — a pure fast-forward of `main`. Release version **3.24.0**.

## 4. Frozen / verified foundations
| Foundation | State |
|---|---|
| MT5 read side `mt5_sync_runs` / `_run_positions` / `_run_account` | **APPLIED**; prod canary 2026-08-23 |
| `public.mt5_get_current_snapshot_v1(text)` | **APPLIED** (recorded); `authenticated` only; never yet called from a browser |
| `mt5_import_staging` (0A) — `source_account text not null`, RLS select-own | **APPLIED** |
| S2-1 lifecycle contract rev 15 | **FROZEN** `3026d8c` (+ `569381b`) |
| S2-2A Stage-A privilege pack | **FROZEN** `2c1cd46`; identities `706F8AAE…` / `53c09ce7…` / `8b8c03db…` |

## 5. Current candidates
| Candidate | Where | State |
|---|---|---|
| **M1 Exposure card** | `work/m1-mt5-exposure` (worktree `thus-journal-m1-replay`), 2 local commits on `f37a0ef` | release candidate v3.24.0 READY; unpushed; awaiting Junior release authorization |
| Stage-A credential-intake fence | `thus-journal-mt5-s2-aux-freeze`, 3,606 uncommitted lines, **no remote** | independent re-verification **NOT COMPLETE**; needs Codex with repo + evidence |
| 9 local UI commits (Phase-A review, reconciliation preview) | same branch as M1, unpushed | **not** bundled with M1 |
| 30 MT5 S1/S2 commits | `thus-journal-mt5-s1` / aux-freeze, unpushed | frozen/reviewed per track |

## 6. Open blockers / gates
**Read-only product track — no S2 gate applies** (decided 2026-09-25).
| Gate | State | Closes when |
|---|---|---|
| M0b deploy-path proof | **CLOSED — PASS** 2026-09-26 (deploy `6ab79faf…`) | — |
| M1 release | **NOT YET AUTHORIZED** — needs explicit Junior authorization + Junior re-confirms Netlify Usage not exceeded and credits sufficient immediately before release (else **NO-GO**) | rollback target: deploy **`6ab79fafcfc6664f22148556`** (= `f37a0ef`) |
| M3 capture cadence | NEEDS AUTHORIZATION | cadence + retention decision + kill switch |
| M4 device credential | UNDECIDED | phone-auth + revocation decision |
| "Gearing" label collision | OPEN — resolve before M2 | production *Gearing = entry notional ÷ balance* vs M2 *current notional ÷ equity, FX-converted* |

**S2 writer track — unchanged, never closed by rewording.**
| Gate | State |
|---|---|
| **STOP-1** | **OPEN** — no S2-owned Journal write before the ownership guard is applied **and verified** |
| **STOP-15 / B-2** | **OPEN, co-terminal** — FINAL A/B/C on the production catalog + accepted STOP-1/object-7 evidence + operator record |
| **DEFECT 1** | **Permanent** — `S2_STAGE_A_EXECUTOR_EXCEPTION_001`; never fixed by B2 grants |
| W1 Stage-A state check | authorized: runbook Step 1a only, read-only |
| aux-freeze backup | remote + freeze commit authorized **after** FIX2 independent PASS; push separately gated |

## 7. Product roadmap
| # | Milestone | User-visible outcome | Gate |
|---|---|---|---|
| **M1** | Exposure card (v3.24.0) | exposure + floating P/L + freshness in the Journal | Junior release authorization + credit check |
| M0a | Preserve aux-freeze | none (backup) | after FIX2 PASS |
| M0b | Reconcile lineages + **prove deploy** | production caught up to `f37a0ef` | **CLOSED — PASS** |
| M2 | Account + **FX evidence** + account currency | **gearing %** + **floating P/L %** + a named P/L currency | schema review + apply; label ruling |
| M3 | Capture cadence | numbers become current | write-cadence authorization |
| **M4** | **iPhone widget v0 (Scriptable)** | three numbers on the home screen | M2 + M3 + phone auth |
| W1–W4 | Stage-A → Phase 2 → Phase 3 (STOP-1) → Phase 4 FINAL | none (writer safety) | per-phase authorization |

**Decisions.** *2026-09-25:* gearing = gross notional ÷ current equity, in THB; margin/equity is a
separate metric, *margin usage* · FX authority = MT5 USD/THB at the same snapshot; missing → unavailable
· fence: Approach A once, then any new intake finding → Approach B · third finding in one boundary →
architecture review; two rounds per boundary. *2026-09-26 (M1 plan review):* no cross-symbol total ·
App-level mount · card-scoped boundary · discovery = one dedicated SELECT with exact count, completeness
proven, never choose among >1 accounts · floating P/L = MT5 account currency, not assumed THB, no new
currency read in M1 · eventual commit replays onto a fresh branch from exact `origin/main`. *Release policy:*
every production release that changes application code bumps `APP_VERSION`; docs-only changes do not.

## 8. Widget status
| Dependency | State |
|---|---|
| Durable read side · authenticated position RPC | **DONE** |
| Exposure arithmetic + freshness semantics + overflow safety | **IMPLEMENTED in M1** (Codex-verified; local release candidate, unpushed) |
| Equity · durable FX evidence · account currency · instrument currency | MISSING — M2 |
| Refresh cadence · retention policy | MISSING — M3 |
| iOS host | DECIDED — Scriptable v0 |
| Device credential + revocation | MISSING — before M4 |
| Gearing definition · FX authority | DECIDED 2026-09-25 |
| MT5 terminal on Junior's PC | standing runtime dependency |
**No widget dependency is behind an S2 gate.**

## 9. Deferred backlog — item · un-defer trigger
- Entry "Gearing" silent-zero (`fmtGearing` renders missing as `0.00X`) · its own fix, not in M1
- Account selection when >1 MT5 account · after M1; M1 refuses instead of choosing
- `Mt5ReportRecon` fires a staging read with its flag OFF (local unpushed only) · before that lineage ships
- App has no error boundary (M1 contains its own) · any other flag-on surface
- Accounts with snapshots but no staging rows are undiscoverable · M2 account-list read
- G2 write gate / v0.5 ungroup UI · explicit user approval
- S2-2 ingestion; staging→trades materializer · after W2–W4 / reviewed design

## 10. Next actor / next action
**Completed action:** M1 local release preparation (Claude Code) — one local commit on `5b23f2b`, not pushed.
**Current actor: GPT** · **Next decision:** explicit **Junior M1 production-release authorization**.
Release preconditions: `origin/main` still `f37a0ef` (fast-forward) · Junior re-confirms Netlify Usage not
exceeded + credits sufficient (else NO-GO) · rollback target deploy `6ab79fafcfc6664f22148556` (`f37a0ef`).
**Push: NOT AUTHORIZED · Deploy: NOT AUTHORIZED.** Production = `f37a0ef` / v3.23.0; M1 is NOT deployed.
Evidence env pinned exactly (`@supabase/supabase-js 2.39.0`, react 18.2.0, @babel/standalone 7.23.2).
