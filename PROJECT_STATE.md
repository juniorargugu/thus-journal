# THUS — PROJECT STATE

Single visible source of truth for Junior, GPT, Claude Code and Codex. **Cap: 150 lines.** One writer
per routing; every routing leaves §10 correct. Detail lives in `artifacts/`, not here.
**Updated:** 2026-09-26 · Claude Code · authority: GPT replay + local-freeze work order (state-only correction accepted)

| Question | Answer |
|---|---|
| What are we building? | A read-only MT5 exposure view in the Journal → an iPhone widget (§1, §7) |
| What can I use now? | Journal v3.23.0. Nothing new since 2026-07-08 (§2) |
| What is blocked? | The S2 **writer** track (§6). The read-only product track is not blocked by S2 gates |
| What comes next? | GPT issues the separate M0b deploy-path-proof work order (§10). Push/deploy NOT authorized |

**Roles.** GPT — product/architecture planning owner · Claude Code — technical co-planner, challenger,
implementer, self-reviewer · Codex — independent verifier · Junior — product owner, UX, production
authorization.

## 1. Product goal
THUS is an AI-native trading OS; the Journal is its memory/data layer. **Near-term product:** Junior
sees their live MT5 exposure — by symbol, gross notional, floating P/L, freshness — first in the Journal
(M1), then with gearing % and P/L % (M2), then on an iPhone widget (M4). All of it read-only.

## 2. Current user-visible production
- **thus999.com = `f01eb33` / v3.23.0** — **measured** 2026-09-25 (sha256 `4f8564da…`, 595,900 B).
- **Last user-visible change: 2026-07-08 (80 days).** Top item of every planning routing until it moves.
- ⚠ `origin/main` = `f37a0ef`: two pushed `index.html` commits (2026-07-24) are **not serving** →
  **the deploy path is unproven.**
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
| origin/main replay + local freeze | **COMPLETE** — one LOCAL commit `feat: add read-only MT5 exposure card` on `work/m1-mt5-exposure`, parent `f37a0ef` (= `origin/main`); re-verified on that tree: 136/136, static 22/22 (25/25 repo), compile PASS, patch bodies identical to the reviewed candidate |
M1 is **NOT release-approved**. **Push: NOT AUTHORIZED. Deploy: NOT AUTHORIZED.** The branch is not deployed.
- `index.html` only, **+253 / −0**, sha256 `9f051131…`; default-off `tj_mt5_exposure`; mounted in `App`
  above `PagePositions`; card-scoped error boundary.
- **Reads:** ONE account-discovery SELECT (`source_account` only, exact count, no row limit,
  completeness proven) + AT MOST ONE `mt5_get_current_snapshot_v1` call. Never chooses between accounts.
- **Shows:** per-symbol Long/Short **gross** notional in each symbol's own **unconverted** currency,
  lots, position count, **floating P/L in the MT5 account's deposit currency (not identified by M1)**,
  snapshot freshness + time. Missing or non-finite data → "—", never 0 / ∞ / NaN.
- **Deliberately absent:** gearing %, P/L %, FX, equity, cross-symbol total notional.
- Shipping lineage: `work/m1-mt5-exposure` from `f37a0ef`. The reviewed candidate on `cae865c` stays as uncommitted review evidence.

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
| **M1 Exposure card** | `work/m1-mt5-exposure` (worktree `thus-journal-m1-replay`), 1 local commit on `f37a0ef` | local freeze COMPLETE; unpushed; M0b next |
| Stage-A credential-intake fence | `thus-journal-mt5-s2-aux-freeze`, 3,606 uncommitted lines, **no remote** | independent re-verification **NOT COMPLETE**; needs Codex with repo + evidence |
| 9 local UI commits (Phase-A review, reconciliation preview) | same branch as M1, unpushed | **not** bundled with M1 |
| 30 MT5 S1/S2 commits | `thus-journal-mt5-s1` / aux-freeze, unpushed | frozen/reviewed per track |

## 6. Open blockers / gates
**Read-only product track — no S2 gate applies** (decided 2026-09-25).
| Gate | State | Closes when |
|---|---|---|
| **M0b deploy-path proof** | **REQUIRED before any production M1 release** — does NOT block local M1 implementation/review | one observed deploy changes the production sha256 |
| M1 release | local freeze DONE → M0b (separate GPT order) → Junior authorization → push/deploy | M0b not yet authorized; push/deploy NOT AUTHORIZED |
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
| **M1** | Exposure card | exposure + floating P/L + freshness in the Journal | GPT → Codex → Junior; M0b before release |
| M0a | Preserve aux-freeze | none (backup) | after FIX2 PASS |
| M0b | Reconcile lineages + **prove deploy** | makes everything shippable | required before M1 release |
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
currency read in M1 · eventual commit replays onto a fresh branch from exact `origin/main`.

## 8. Widget status
| Dependency | State |
|---|---|
| Durable read side · authenticated position RPC | **DONE** |
| Exposure arithmetic + freshness semantics + overflow safety | **IMPLEMENTED in M1** (Codex-verified; local commit, unpushed) |
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
**Completed action:** origin/main replay + local freeze (Claude Code) — one local commit, not pushed.
**Current actor: GPT** · **Next action:** GPT issues the separate **M0b deploy-path-proof** routing
decision/work order. **No M0b execution is pre-authorized by this commit.**
M0b is **REQUIRED before production M1 release** and does **NOT** block local freeze/review work.
**Push: NOT AUTHORIZED · Deploy: NOT AUTHORIZED.** Production remains `f01eb33` until re-measured.
Evidence env pinned exactly (`@supabase/supabase-js 2.39.0`, react 18.2.0, @babel/standalone 7.23.2).
