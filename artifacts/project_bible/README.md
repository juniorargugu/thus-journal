# THUS Project Bible — v1

This directory is the long-term **operating manual and source of truth** for THUS.
It is written for AI agents (Claude Fable, Claude Code, Codex, GPT) and future human
contributors. It is **not** a README for the Journal app, and it is **not** marketing
copy. It is the durable record of *what THUS is, where it is going, what is real today,
and what must never be done silently.*

---

## The one thing to internalize first

**THUS is not "a journal app."** The Journal is the current focus of hardening work,
but it is a means, not the end. The North Star is **GUGU** — an AI-native trading
copilot / trading operating system. The Journal exists to become the trustworthy
memory/data layer that GUGU can reason over. See
[`02_VISION_AND_NORTH_STAR.md`](./02_VISION_AND_NORTH_STAR.md).

If you ever find yourself reducing THUS to "a trade-logging web app," stop and re-read
chapter 02. That framing loses the entire point.

---

## Two-repo topology & scope of authority

THUS spans **two repositories** plus a runtime host. Always know which one you are in:

- **`thus-journal`** (this repo) — the Journal / memory-data layer, the production SPA
  (`index.html`), the Supabase-facing artifacts (migrations, RLS, storage), and the home
  of this Project Bible.
- **`thus-trading-bot`** (sibling repo) — the **GUGU runtime**: the capture bot, the
  **active GUGU v2 build**, the bot's own memory/context, and that repo's own CLAUDE.md /
  handoff / current-state docs.
- **VPS** (`168.144.35.127`, NEEDS VERIFICATION) — the intended runtime environment for
  GUGU.

**This Bible is currently authoritative for:**
- THUS direction and North Star.
- `thus-journal` facts (Journal, persistence, grouping, MT5 staging, product registry).
- Cross-system gates *as documented here*.

**It is NOT yet fully authoritative for the current GUGU build state.** GUGU v2 is an
active build in `thus-trading-bot`; until a cross-repo capture pass reconciles that repo's
live state into this Bible (see [`TODO_ROADMAP_CAPTURE.md`](./TODO_ROADMAP_CAPTURE.md)),
GUGU details here are directional, not a live status report.

**Rule for agents working in `thus-trading-bot`:** read *that* repo's own CLAUDE.md /
handoff / current-state first, then reconcile back to this Bible. Do not assume this Bible
reflects the bot repo's latest sprint.

---

## Read order

New agents and contributors should read in this order:

1. [`00_AI_BOOTSTRAP.md`](./00_AI_BOOTSTRAP.md) — how to reason about, review, and
   propose work here; what the gates are; what must never be done silently.
2. [`01_EXECUTIVE_SUMMARY.md`](./01_EXECUTIVE_SUMMARY.md) — a 5-minute explanation of
   THUS: what it is, what's live, what's gated, the risks, the next tracks.
3. [`02_VISION_AND_NORTH_STAR.md`](./02_VISION_AND_NORTH_STAR.md) — the direction-
   preserving chapter. The most important one.
4. [`03_PRODUCT_MAP.md`](./03_PRODUCT_MAP.md) — every subsystem, its state, its gates,
   and its relationship to GUGU.
5. [`SOURCE_INVENTORY.md`](./SOURCE_INVENTORY.md) — where the facts in this Bible come
   from, with confidence levels and explicit gaps.
6. [`TODO_ROADMAP_CAPTURE.md`](./TODO_ROADMAP_CAPTURE.md) — the remaining chapters to
   write and what still needs to be captured or verified.
7. [`GLOSSARY.md`](./GLOSSARY.md) — quick definitions for the acronyms and status tags
   used throughout (G0–G6, MT5 0A–0D, Lanes, `raw`/`group_id`, GUGU v1/v2, etc.). Keep it
   open as a reference while reading the rest.

---

## Status vocabulary

Roadmap and subsystem items in this Bible are tagged with a fixed vocabulary so that
work never silently disappears just because it is not implemented:

| Tag | Meaning |
|---|---|
| **DONE** | Completed and closed out; may be local-only (not deployed). |
| **LIVE** | Shipped to production (app bundle) and verified. |
| **APPLIED** | A DB / RPC / schema / migration change has been executed against live Supabase / project state. Distinct from **LIVE** (an app bundle shipped) and **DONE** (a local artifact). Usually paired with **VERIFIED** once its validation has passed — e.g. *APPLIED + VERIFIED*. |
| **DESIGNED** | Design written and (usually) reviewed; no code/apply yet. |
| **REVIEWED** | Passed an adversarial/static review pass. |
| **DEFERRED** | Deliberately postponed with a documented trigger to revisit. |
| **GATED** | Blocked behind an explicit human approval / gate. |
| **RESEARCH** | Under investigation; conclusions not settled. |
| **VISION** | Long-horizon intent; not scheduled. |
| **NEEDS VERIFICATION** | Asserted somewhere but not confirmed against live state or current docs. |

When in doubt, prefer **NEEDS VERIFICATION** over asserting a fact.

**Qualifier patterns are blessed and meaningful** — read the parenthetical/suffix as part
of the tag: **DONE (local)** = closed out but unpushed; **DONE (reviewed)** = passed
review, not yet applied/shipped; **LIVE (default-off)** = shipped but behind an unset
flag; **APPLIED + VERIFIED** = executed against live state and validated. When a bare tag
would overstate reality, add the qualifier.

---

## Authoring conventions

- **English** for the Bible body. Preserve Thai user intent verbatim where the exact
  wording carries meaning (e.g. the North Star statement, "propose not prescribe").
- Use the section headers **"Current state,"** **"Design intent,"** **"Open questions,"**
  and **"Gates"** frequently. They keep facts, intentions, and unknowns separate.
- Avoid hype. Do not present uncertain things as confirmed.
- This is a living document. Update it as reality changes, and keep
  [`SOURCE_INVENTORY.md`](./SOURCE_INVENTORY.md) honest about confidence and gaps.

---

## Repo state

- **Repo:** `thus-journal` (`c:\Users\Junior\Desktop\thus-journal`)
- **`origin/main`:** `b94f7fd` — "docs: record G2 isMerged RPC migration applied + verified"
- **Local `main`:** ahead of origin by the Project Bible commits (local-only, not pushed)
- **Production bundle:** `f01eb33` / **v3.23.0** on thus999.com — unchanged (`index.html`
  byte-identical; docs/migration commits after `f01eb33` do not touch it)
- **G2 status:** RPC `isMerged` hardening **applied + verified** (2026-07-10); write gate
  **not enabled**; **no real group kept**
- **Bible created / last synced:** 2026-07-10, docs-only
