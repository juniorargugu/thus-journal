# Autopilot Rules — THUS Journal / GUGU

**Core principle: Autopilot must preserve adversarial review.**

Autopilot is a convenience layer for *safe, reviewed* forward motion. It never
substitutes its own judgment for a review gate, and it never silently makes a call
that a human reviewer (Junior / Codex) was supposed to make.

---

## MAY (no approval needed)

- **Inspect** — read code, schema (read-only), git state, prior artifacts.
- **Summarize** — status, diffs, candidate lists, what changed and why.
- **Run static checks** — grep/marker checks, esbuild syntax check, pure unit tests, `git diff --check`, the read-only [`pipeline_snapshot.ps1`](../../scripts/pipeline_snapshot.ps1).
- **Read-only DB reads** via PostgREST (SELECT-style) — e.g. candidate confirmation. **No** writes, **no** RPC writes, **no** transactions.
- **Low-risk local docs/UI changes** — ONLY when the scope is already reviewed, default-off, and does not touch a stop-list surface. Local commit only.
- **Propose the next safe task** and **stop, routing back with a clear question.**

## MUST STOP (explicit review + approval required)

Stop and route back before any of:

- **DB / schema / RLS / SQL** — DDL, policy changes, migrations apply, `ALTER`, index/trigger/function changes.
- **Supabase writes / RPC writes** — any mutation (`insert`/`update`/`delete`/`upsert`) or any RPC that writes. (Rollback-only smoke is a **user/SQL-Editor** step, not autopilot.)
- **push / deploy** — `git push`, Netlify deploy, shipping a bundle.
- **enabling write gates** — e.g. `tj_trade_group_write_v01` (or any `tj_*` write/feature flag) must never be auto-enabled.
- **MT5 writer** — staging→journal materialization or any MT5 write path.
- **GUGU cognition / autonomous behavior** — capture-only is frozen; cadence/cognition/autonomy changes.
- **durable save / close / delete / merge / import paths** — the trade persistence surfaces.
- **failed validation** — any static check, syntax build, or test failing.
- **architecture / product tradeoffs** — anything that collapses a design debate or picks between approaches.

## MUST NOT (ever, under autopilot)

- Collapse design debate or make architecture decisions silently.
- Apply SQL/RLS/schema changes.
- Push or deploy.
- Enable production/write flags.
- Run live writer/RPC-write smoke.
- Change bot cognition / autonomous behavior.
- Touch durable save/close/delete/merge/import paths.

...without explicit review and approval.

---

## Operating loop

1. Read [`PIPELINE_STATE.md`](./PIPELINE_STATE.md) and [`NEXT_SAFE_TASK.md`](./NEXT_SAFE_TASK.md).
2. Run [`pipeline_snapshot.ps1`](../../scripts/pipeline_snapshot.ps1) (read-only) to ground on real state.
3. If the next step is on the **MAY** list and scope is reviewed → do it, commit locally, report.
4. If the next step is on the **STOP** list → stop, summarize, and ask a clear question. Do not proceed.
5. Never batch a stop-list action behind a safe one.

**When in doubt, STOP and ask.** A missed safe task costs a round-trip; a silent
stop-list action costs trust and possibly data.
