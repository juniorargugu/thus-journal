# T4A closeout — MT5 capture decisions

Status: **CLOSED — PASS_WITH_CAVEAT**
Date: 2026-08-26
Scope: `mt5_capture_decisions` + the Telegram decision surface. No Journal writes.

---

## 1. What T4A answers

> "What durable human workflow decision was made about this immutable MT5 capture?"

It does **not** answer how a decision becomes Journal state. That is T4B, which does not
exist at closeout.

## 2. Phase results

| Phase | Result |
|---|---|
| T4A-0 DB foundation (schema + RPC + security verifier, production apply) | PASS |
| T4A-1 bot integration (reviewed, committed `9fb310d`) | PASS |
| T4A-2A sealed production rollout (writes structurally disabled) | PASS |
| T4A-2B1 reviewed write unlock (committed `9123320`) | PASS |
| T4A-2B2 production canary — probe 1: `journal_add` first insert | PASS |
| T4A-2B2 production canary — probe 2: same-action idempotent replay | PASS |
| T4A-2B2 production canary — probe 3: different-action conflict | **NOT EXECUTED** |

**This is not a 3/3 production pass.** Probe 3 was never executed.

## 3. The caveat (verbatim)

> Production first-insert and same-action idempotent replay were proven. Different-action
> conflict was not production-exercised because the live correlation session expired. The
> conflict behavior remains covered by the approved hermetic T4A tests and is not required
> to consume another real capture solely for QA.

Cause: the capture-A correlation session opened 11:10:15 with a 600 s TTL and expired at
11:20:15 before a third tap reached the callback handler. Observed: zero third callback,
zero third decision RPC, zero DB mutation, no uncertain outcome.

Not retryable on capture A: `mt5_next_pending_capture_v1` returns only captures with no
decision, so A can never be re-prompted. A different-action conflict requires a live
session for an already-decided capture — a window that exists only inside the TTL after
its first decision.

## 4. Production canary evidence

```
capture A   80c099f3-7a7b-45bb-86a9-f295d1d0dfd3   position 312261388   kind ENTRY
decision    8434306f-84cc-42df-afb6-fa235f6d1145   action journal_add   source telegram
            telegram_chat_id 6044856720   telegram_message_id 895
            created_at 2026-08-26T04:13:54.604716+00:00
row digest  b6e2365e72577edd391106dfcf491484682b3a8d9fd2448898d55a40fdcd03d9
```

* insert: `(o_ok=true, o_inserted=1, o_decision_id=uuid, o_existing_action=null, o_derived_kind=ENTRY, o_error_code=null)`
* replay: `(o_ok=true, o_inserted=0, o_decision_id=same, o_existing_action=journal_add, o_derived_kind=null, o_error_code=null)`
* decisions 0 → 1 → 1; pending 2 → 1; FIFO head A → B
* row digest identical across pre-replay / post-replay / closeout snapshots
* 2 human callbacks, 2 decision RPC calls, 0 automatic retries, 0 `already_logged` taps

## 5. Final durable state at closeout

```
mt5_capture_events    = 2   (both byte-identical to the pre-rollout baseline)
mt5_capture_decisions = 1

capture A  80c099f3-…  position 312261388  decision journal_add
capture B  7cdbdb0c-…  position 312265597  decision NONE (pending, untouched)

pending_count = 1        FIFO head = capture B / 312265597
Journal: trades 155 (newest 2026-07-06), trade_groups 1 (newest 2026-07-07) — unchanged by T4A
```

## 6. Runtime at closeout

```
production worktree  C:\Users\Junior\Desktop\thus-trading-bot
branch               work/mt5-t3-telegram-transport
HEAD                 912332091a0a9f61c409e793e06172d3bad36c9a
tree                 clean
runtime gate         T4A_DECISION_WRITES_ENABLED_IN_THIS_PHASE = True
bot PIDs             3620 / 36168 (started 2026-08-26 11:07:39), price_pusher 32152 untouched
```

## 7. Carried-forward items

1. **Remote preservation risk.** `9fb310d` and `9123320` — the code production is running —
   exist only locally. `origin/main` is at `16798a4`. Losing this machine loses the running
   production bot source. Needs its own gate.
2. **Opportunistic conflict evidence.** If a future genuine capture gives a natural reason to
   exercise a different-action conflict inside one live TTL, collect it then. Not a blocker
   for T4B.
3. **Capture B stays pending.** It is not QA material; it is awaiting its real workflow decision.
