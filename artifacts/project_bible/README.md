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

---

## Status vocabulary

Roadmap and subsystem items in this Bible are tagged with a fixed vocabulary so that
work never silently disappears just because it is not implemented:

| Tag | Meaning |
|---|---|
| **DONE** | Completed and closed out; may be local-only (not deployed). |
| **LIVE** | Shipped to production and verified. |
| **DESIGNED** | Design written and (usually) reviewed; no code/apply yet. |
| **REVIEWED** | Passed an adversarial/static review pass. |
| **DEFERRED** | Deliberately postponed with a documented trigger to revisit. |
| **GATED** | Blocked behind an explicit human approval / gate. |
| **RESEARCH** | Under investigation; conclusions not settled. |
| **VISION** | Long-horizon intent; not scheduled. |
| **NEEDS VERIFICATION** | Asserted somewhere but not confirmed against live state or current docs. |

When in doubt, prefer **NEEDS VERIFICATION** over asserting a fact.

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

## Repo state at authoring

- **Repo:** `thus-journal` (`c:\Users\Junior\Desktop\thus-journal`)
- **HEAD == origin/main:** `042aeed` (in sync at authoring time)
- **Production bundle:** `f01eb33` / **v3.23.0** on thus999.com (`index.html` byte-identical
  through `042aeed`; docs/migration commits after `f01eb33` do not touch `index.html`)
- **Bible created:** 2026-07-10, docs-only
