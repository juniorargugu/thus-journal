# MT5 S1.1 — Account Observation Design

**STATUS: FROZEN — CODEX APPROVED**

Approval verdict: S1.1 DESIGN APPROVED
Approval date: 2026-08-22
Revision: draft-3 (incorporates the REVISE_BEFORE_DESIGN_APPROVAL review of draft-2)
Depends on: S1 append-only snapshot membership, **packet revision 5, frozen**
Baseline commit: `dd0a18fa506d761ea3fb9b0d7a733ee66bec6e49`

---

## 0. Purpose and scope

S1.1 is an **additive** layer that lets every future broker observation preserve the
account facts that were true *at the same instant* as the position membership:

- `equity` — the exposure denominator
- `balance` — context only, never a denominator
- `currency` — needed to prove the denominator and the numerator are in the same unit

plus the minimum quality, timing and provenance needed to know whether those facts are
safe to use.

### In scope

Storage, immutability, capture ordering, envelope versioning, the write RPC contract, the
failure state machine, and the verification invariants.

### Explicitly NOT in scope

- exposure/gearing calculation (specified only as an eligibility predicate, §15)
- product-family notional mapping (§16)
- any browser-facing exposure RPC (§17)
- any change to S1 revision 5 — schema, RPCs, design document, or rollback packet
- schedulers, daemons, continuous writers, Telegram, T2/T3, Journal, G2

### The one-sentence rule

> A run's account facts are **historical contemporaneous evidence**, not current state.
> They are written once, never corrected, and a later observation is a different run.

---

## 1. Relationship to the frozen S1 packet

S1 revision 5 is frozen. S1.1 must not alter it, and must not *disarm* it.

Two mechanisms in the frozen packet make this a hard constraint rather than a preference:

**(a) Structural fingerprints are rollback's destructive authority.**
`S1_rollback_packet.sql` recomputes an apply-time fingerprint for `mt5_sync_runs` and
`mt5_sync_run_positions` covering **owner + full column list + all constraints + all
indexes**, and on any difference raises:

```
MT5_S1_ROLLBACK: table(s) % no longer match the apply-time S1 definition
                 (replaced or altered) — refusing to drop
```

Adding *any* column to `mt5_sync_runs` therefore permanently disarms S1 rollback.
**S1.1 adds no column to either S1 table.**

**(b) The final teardown has no `CASCADE`.**
`S1_rollback_packet.sql` ends with `drop table if exists public.mt5_sync_runs;`. While an
S1.1 table holds a foreign key to it, that statement fails. This is deterministic and
resolvable, and it dictates the rollback ordering in §19.

Two facts that make the sibling-table approach safe, verified against the frozen packet:

- the S1 provenance trigger assertion is scoped by
  `t.tgrelid='public.mt5_sync_run_positions'::regclass`, so S1.1's own triggers cannot
  break its "expected both immutability trigger fingerprints" count;
- the S1 postflight write-grant assertion is scoped by
  `table_name in ('mt5_sync_runs','mt5_sync_run_positions')`, so the S1.1 table is outside
  it — which is exactly why S1.1 must carry its **own** equivalent postflight (§19).

**No frozen S1 file is edited by S1.1 — including `S1_rollback_packet.sql`.** Its
byte-level SHA must remain unchanged, and that is itself an acceptance test (§20).

---

## 2. Storage model

**Decision: a separate, immutable, one-to-one sibling table
`public.mt5_sync_run_account`, keyed by `run_id`.**

Rejected alternative: columns on `mt5_sync_runs`. Rejected for four reasons, in order of
weight:

1. **Rollback safety** — see §1(a). Disqualifying on its own.
2. **Immutability** — `mt5_sync_runs` is deliberately *mutable*: `snapshot_status`,
   `reconcile_status`, `lease_*`, `heartbeat_at` and `updated_at` all transition, and five
   frozen RPCs `UPDATE` that row. Account columns there would inherit a mutable row with
   no per-column protection, contradicting the one-sentence rule.
3. **Provenance** — an account fact is a *broker observation*, the same class of evidence
   as a position row, not lifecycle control state. Position facts already live in their own
   immutable table bound by `captured_at`; account facts belong beside them.
4. **Extension** — `margin`, `margin_free`, `leverage`, `currency_digits` can later be
   added to an S1.x observation table without ever touching `mt5_sync_runs` again.

The honest cost: one extra object, one FK dependency, and a mandatory rollback ordering
(§19).

---

## 3. Envelope format: v1 and v2

S1.1 **must not** silently extend the existing envelope. A v1 envelope carries no account
block, and a writer that accepted it as S1.1-capable would seal an S1.1-versioned run with
no account row — precisely the anomaly §13 is designed to detect.

| Format | Meaning | Account block | Status |
|---|---|---|---|
| `mt5.s1.oneshot.envelope/1` | S1 membership only | absent | **unchanged forever**; existing files remain valid historical S1 envelopes |
| `mt5.s1.oneshot.envelope/2` | S1 membership **+** account observation | required | new; the only format an S1.1 write path accepts |

### Rules

- An S1.1 write path **must reject** a v1 envelope: `ENVELOPE_FORMAT_NOT_S1_1`, refuse
  before any credential read or DB call.
- An S1 (v1) write path **must reject** a v2 envelope: `ENVELOPE_FORMAT_NOT_S1`. Accepting
  it would silently discard approved account facts and produce exactly the anomaly in §13.
- v2 is `ENVELOPE_KEYS_V1 + ("account",)` — nothing else changes. Canonicalisation stays
  recursive key-sort over the exact key set, no whitespace, UTF-8, `allow_nan=False`, so
  **the canonical SHA-256 covers the account block automatically**. Any change to any
  account fact changes the approval hash.
- `allow_nan=False` is a **defensive backstop, not the normal classifier** for broker
  non-finite values. The normal path normalises a non-finite broker value to `null` plus
  quality `invalid` *before* canonicalisation, so canonicalisation succeeds and the preview
  completes. `allow_nan=False` exists so that if an implementation bug ever let a raw
  `NaN`/`Infinity` reach the canonical payload builder, that builder refuses and no
  envelope approval is possible. See §7.

### Exact v2 account block

Exactly eight keys, all required, none optional, `null` used for absence:

```json
"account": {
  "account_read_at":            "2026-08-22T12:29:58.412000Z",
  "account_observation_status": "observed",
  "equity":                     1234567.89,
  "balance":                    1300000.0,
  "currency":                   "THB",
  "equity_quality":             "usable",
  "balance_quality":            "usable",
  "failure_reason":             null
}
```

A failed observation is the same eight keys:

```json
"account": {
  "account_read_at":            "2026-08-22T12:29:58.412000Z",
  "account_observation_status": "failed",
  "equity":                     null,
  "balance":                    null,
  "currency":                   null,
  "equity_quality":             "absent",
  "balance_quality":            "absent",
  "failure_reason":             "ACCOUNT_READ_FAILED"
}
```

A successful read whose equity was non-finite is **observed**, not failed:

```json
"account": {
  "account_read_at":            "2026-08-22T12:29:58.412000Z",
  "account_observation_status": "observed",
  "equity":                     null,
  "balance":                    1300000.0,
  "currency":                   "THB",
  "equity_quality":             "invalid",
  "balance_quality":            "usable",
  "failure_reason":             null
}
```

Exact-key-set validation applies, for the same reason it applies to position rows: a
misspelled key silently becomes `NULL` under `jsonb_to_record` semantics.

---

## 4. Account capture ordering

One MT5 session. One membership read. Two account reads with **different jobs**.

```
T0    account_info()            -> login / server / margin_mode
        login == source_account ?          else HARD STOP (cross-account guard)
        margin_mode == 2 (RETAIL_HEDGING)? else HARD STOP
T1    read_positions_strict()   -> immutable membership
        None (incl. None + RES_S_OK) -> HARD STOP, never an empty snapshot
T1.5  account_info()            -> financial account sample
        stamp account_read_at IMMEDIATELY
        login must STILL equal source_account
T2    captured_at = now(UTC)    -> the observation seal instant
T3    symbol_info() per symbol, terminal_info()
```

Why two reads rather than one: T0 must precede T1 so the cross-account guard fires before
anything is observed, but a T0 equity would be measured *before* the membership it is
meant to be contemporaneous with. T1.5 places the financial sample as close to
`captured_at` as the API allows.

### Second-read semantics

**A. The second `account_info()` returns an object.**
Stamp `account_read_at` immediately. Re-check `login`.

- `login == source_account` → proceed; classify the values per §7 and §8.
- `login != source_account` → **`ACCOUNT_IDENTITY_DRIFT` → HARD STOP the entire
  snapshot.** Nothing is written; no run is created.

  The reason is *not* gearing. If the terminal's login changed between T0 and T1.5, the
  position set at T1 was read under an unknown identity, so the **membership itself** is
  untrustworthy. This is the one and only case where account handling blocks membership.

**B. The second `account_info()` returns `None` or raises.**
Stamp `account_read_at` at the attempt. Record a **failed account observation**
(`status='failed'`, all values `NULL`, `failure_reason='ACCOUNT_READ_FAILED'`).

**The membership snapshot still proceeds.** The T0 identity guard already passed and the
strict positions read already succeeded, so the membership remains valid S1 evidence.

This is a **value-observation failure, not observed identity drift.** A failed read tells
us nothing about identity — it is the absence of an observation, not the presence of a
contradictory one. Treating it as drift would destroy good membership evidence to punish a
flaky API call, and would create exactly the operational pressure toward a fallback value
that S1 exists to prevent.

### The rule, stated once

> Account handling may block membership **only** for reasons of *identity integrity*,
> never for reasons of *value quality or availability*.

---

## 5. Contemporaneity: `account_read_at`

The field is named **`account_read_at`**, not `account_observed_at`, because a *failed*
read also has a read-attempt timestamp and "observed" would be a lie on those rows.

### Required window

```
captured_at - INTERVAL '30 seconds'  <=  account_read_at  <=  captured_at
```

**FINAL DECISION:** 30 seconds is the initial fixed fail-closed bound, and it is **not
runtime-configurable in S1.1 v1**. Under normal operation the gap is sub-millisecond — two
consecutive local IPC calls — so 30 s is three orders of magnitude of headroom, not a
tolerance anyone should ever be near.

### Enforcement, in both layers

- **Connector**: validated at preview time, before the envelope is written. If the window
  is exceeded, **preview fails and must recapture.** It must never seal stale account
  facts, and must never adjust `captured_at` or the account timestamp to fit.
- **Database**: `mt5_sra_read_at_window_chk`, so a connector bug cannot bypass it.

The bound is a constant. It must **not** be widened by a flag, an environment variable, or
a retry path. Widening it is a design change requiring review.

---

## 6. Revised schema

Proposed only. **Not implemented, not executed, no SQL packet exists yet.**

```sql
create table public.mt5_sync_run_account (
  -- identity and scope: ALL server-derived from the locked parent run (see §9)
  run_id                     uuid        not null,
  user_id                    uuid        not null,
  source_account             text        not null,
  captured_at                timestamptz not null,   -- must equal the parent run's
  connector_version          text        not null,   -- copied from the parent run

  -- the observation
  account_read_at            timestamptz not null,
  account_observation_status text        not null,   -- 'observed' | 'failed'
  equity                     numeric,
  balance                    numeric,
  currency                   text,
  equity_quality             text        not null,   -- 'usable' | 'invalid' | 'absent'
  balance_quality            text        not null,   -- 'usable' | 'invalid' | 'absent'
  failure_reason             text,                   -- NULL iff observed; see §8

  account_fingerprint        text        not null,
  created_at                 timestamptz not null default now(),

  ---------------------------------------------------------------- identity / scope ----
  constraint mt5_sra_pk primary key (run_id),                 -- exactly one row per run
  constraint mt5_sra_run_scope_fk foreign key (run_id, user_id, source_account)
    references public.mt5_sync_runs(id, user_id, source_account) on delete restrict,
  constraint mt5_sra_account_nonblank_chk   check (btrim(source_account) <> ''),
  constraint mt5_sra_connector_nonblank_chk check (btrim(connector_version) <> ''),

  ------------------------------------------------------------------ contemporaneity ----
  constraint mt5_sra_read_at_window_chk check (
    account_read_at <= captured_at
    and account_read_at >= captured_at - interval '30 seconds'),

  ------------------------------------------------------------------ enumerations ------
  constraint mt5_sra_status_chk check (account_observation_status in ('observed','failed')),
  constraint mt5_sra_equity_quality_chk  check (equity_quality  in ('usable','invalid','absent')),
  constraint mt5_sra_balance_quality_chk check (balance_quality in ('usable','invalid','absent')),
  constraint mt5_sra_currency_nonblank_chk check (currency is null or btrim(currency) <> ''),

  ------------------------------------------- finite numerics: defence in depth (§7) ---
  -- The connector normalises non-finite broker values to NULL before this point. These
  -- CHECKs exist so a payload that FALSELY carries a non-finite numeric is still rejected.
  constraint mt5_sra_equity_finite_chk check (
    equity is null
    or equity not in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
  constraint mt5_sra_balance_finite_chk check (
    balance is null
    or balance not in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),

  ------------------------------------------------- quality <-> value, DB-enforced -----
  -- 'usable' is a promise the DATABASE keeps, so a connector bug cannot store a lie.
  -- The usable branch restates FINITE explicitly so the equivalence is self-contained.
  -- CASE over a NOT NULL column with an ELSE branch => total, never NULL. (See §14.)
  constraint mt5_sra_equity_quality_shape_chk check (
    case equity_quality
      when 'usable'  then equity is not null
                          and equity not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
                          and equity > 0
      when 'absent'  then equity is null
      when 'invalid' then equity is null or equity <= 0
      else false
    end),
  constraint mt5_sra_balance_quality_shape_chk check (
    case balance_quality
      when 'usable'  then balance is not null
                          and balance not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)
      when 'absent'  then balance is null
      when 'invalid' then balance is null
      else false
    end),

  ------------------------------------------------ status shape: TOTAL, NULL-proof -----
  -- HIGH-severity correction (draft-2 -> draft-3). The previous directional form
  --     account_observation_status <> 'failed' OR (... AND failure_reason = 'ACCOUNT_READ_FAILED')
  -- evaluated to NULL for a failed row with failure_reason IS NULL, and a CHECK that
  -- evaluates NULL PASSES. A failed row with no reason was therefore accepted. The CASE
  -- below tests IS NOT NULL explicitly, so that row now evaluates FALSE and is rejected.
  constraint mt5_sra_status_shape_chk check (
    case account_observation_status
      when 'observed' then
        failure_reason is null
      when 'failed' then
        failure_reason is not null
        and failure_reason = 'ACCOUNT_READ_FAILED'
        and equity is null and balance is null and currency is null
        and equity_quality = 'absent' and balance_quality = 'absent'
      else false
    end),

  -- Documents the permitted vocabulary. It does NOT and CANNOT replace the IS NOT NULL
  -- requirement above: `failure_reason is null or ...` passes for a NULL reason by design.
  constraint mt5_sra_failure_reason_allowlist_chk check (
    failure_reason is null or failure_reason = 'ACCOUNT_READ_FAILED'),

  ------------------------------------------------------------------- fingerprint ------
  constraint mt5_sra_fingerprint_chk check (account_fingerprint ~ '^[0-9a-f]{64}$')
);

alter table public.mt5_sync_run_account owner to postgres;

create index mt5_sra_scope_idx
  on public.mt5_sync_run_account(user_id, source_account, captured_at desc);
```

### Immutability guard — mirrors the proven `mt5_run_positions_guard_v1()`

```sql
create function public.mt5_run_account_guard_v1() returns trigger
language plpgsql security definer set search_path = '' as $guard$
declare v_status text; v_capture timestamptz;
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'MT5_S1_1_IMMUTABLE_ROW' using errcode='P0001';
  end if;
  select r.snapshot_status, r.captured_at into v_status, v_capture
    from public.mt5_sync_runs r where r.id = new.run_id for share;
  if not found or v_status is distinct from 'started' then
    raise exception 'MT5_S1_1_RUN_NOT_STARTED' using errcode='P0001';
  end if;
  if new.captured_at is distinct from v_capture then
    raise exception 'MT5_S1_1_CAPTURE_CONFLICT' using errcode='P0001';
  end if;
  return new;
end $guard$;
alter function public.mt5_run_account_guard_v1() owner to postgres;
revoke all on function public.mt5_run_account_guard_v1()
  from public, anon, authenticated, service_role;

create trigger mt5_run_account_no_mutate_v1
  before update or delete on public.mt5_sync_run_account
  for each row execute function public.mt5_run_account_guard_v1();
create trigger mt5_run_account_started_only_v1
  before insert on public.mt5_sync_run_account
  for each row execute function public.mt5_run_account_guard_v1();
```

### RLS and grants — no application write grant, ever

```sql
alter table public.mt5_sync_run_account enable row level security;
create policy mt5_sra_service_read_v1 on public.mt5_sync_run_account
  for select to service_role using (true);
revoke all on table public.mt5_sync_run_account
  from public, anon, authenticated, service_role;
grant select on table public.mt5_sync_run_account to service_role;   -- SELECT only
```

`authenticated` receives **nothing** on this table — not `SELECT`, not `EXECUTE` on any
function that returns its rows. See §17.

### Immutability summary

| Rule | Enforcement |
|---|---|
| Never overwritten | `BEFORE UPDATE OR DELETE → MT5_S1_1_IMMUTABLE_ROW`, unconditional |
| Exactly one row per run | `primary key (run_id)` |
| Cannot attach to a sealed run | insert allowed only while parent `snapshot_status='started'` |
| Cannot claim a different instant | `captured_at` must equal parent's → `MT5_S1_1_CAPTURE_CONFLICT` |
| Cannot cross scope | composite FK `(run_id, user_id, source_account)` |
| No PATCH path exists | no `UPDATE` in any S1.1 RPC; no `mt5_patch_*` is designed, now or later |
| Exact replay only | `account_fingerprint`; any changed fact → `ERR_ACCOUNT_CONFLICT` |

---

## 7. Non-finite values: normalisation is the mechanism

**FINAL DECISION: a non-finite broker value (`NaN`, `+Infinity`, `-Infinity`) is a
VALUE-QUALITY problem. It does not block the position snapshot, and it does not make the
account read "failed".**

### Connector normalisation — the normal path

```
broker value
  -> explicit finite validation
  -> if non-finite:  stored value = NULL,  quality = 'invalid'
  -> build canonical v2 envelope           <- succeeds
  -> membership proceeds
```

For a non-finite equity or balance, provided `account_info()` itself returned successfully
and the identity re-check passed:

| Field | Result |
|---|---|
| `equity` / `balance` | `NULL` |
| `equity_quality` / `balance_quality` | `'invalid'` |
| `account_observation_status` | **`'observed'`** |
| `failure_reason` | **`NULL`** |
| Membership | **proceeds** |

`failure_reason` stays `NULL` because it is reserved for a *whole account-read* failure —
see §8.

### `allow_nan=False` — a defensive backstop, not the classifier

Canonical JSON serialisation with `allow_nan=False` is **not** how non-finite broker
values are normally detected or classified. Normalisation happens first, so the
canonicaliser never sees a non-finite number on the correct path.

Its role is narrow and defensive: **if an implementation bug ever lets a raw
`NaN`/`Infinity` bypass normalisation and reach the canonical payload builder, that builder
must refuse, and no envelope approval is possible.**

This is why §20 keeps **two separate tests**: a normalisation test (broker non-finite →
`null` + `invalid` → canonicalisation **succeeds**), and a defensive serialiser test
(deliberately unnormalised non-finite injected into the payload builder → **refused**).

There is no circumstance in which a non-finite *broker input* by itself makes preview fail.

### Database finite CHECKs remain — defence in depth

The `mt5_sra_equity_finite_chk` / `mt5_sra_balance_finite_chk` constraints stay, and must
not be weakened. The connector should never send a non-finite numeric, so these exist to
reject a payload that **falsely** carries one.

```
value IS NULL
OR value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
```

> **To validate in disposable work:** the exact PostgreSQL 17.6 behaviour of
> `numeric = 'NaN'::numeric` (PostgreSQL treats numeric `NaN` as equal to itself, unlike
> float, which is what makes `NOT IN` correct here). The `value IS NULL OR ...` prefix is
> deliberate belt-and-braces; do not remove it on the assumption that `CHECK` already
> passes on `NULL`.

### Required value semantics

**equity**

| Quality | Condition | Stored value |
|---|---|---|
| `usable` | finite **and** `> 0` | the observed value |
| `invalid` | zero, negative, **or** non-finite | the observed value when finite (`0`, negative); `NULL` when non-finite |
| `absent` | broker value missing / `None` | `NULL` |

**balance**

| Quality | Condition | Stored value |
|---|---|---|
| `usable` | finite and non-null | the observed value, **including a negative one** |
| `invalid` | non-finite | `NULL` |
| `absent` | missing / `None` | `NULL` |

A negative *finite* balance is legitimate broker evidence (a debit balance is real) and
stays `usable` — but balance is context only and never enters a denominator.

Zero and negative *finite* equity keep their observed value rather than being nulled: a
zeroed or blown account is real, valuable evidence, and discarding it would be the same
lossy-extraction mistake S1 was built to avoid. `invalid` guarantees it can never be a
denominator.

---

## 8. Quality and failure model

### `failure_reason` describes ONE thing only

> `failure_reason` describes **only the immutable broker account observation** — whether
> the second `account_info()` read itself succeeded.

It does **not** describe, and must never be used for:

- PostgREST transport failure
- RPC contract failure
- account fingerprint conflict (`ERR_ACCOUNT_CONFLICT`)
- lease failure
- run state failure
- database constraint error
- field-level value problems on a successful read

Those are **operational execution errors** belonging to the state machine in §11, not to
the immutable broker observation row.

Therefore:

```
account_observation_status = 'failed'
failure_reason             = 'ACCOUNT_READ_FAILED'
```

means exactly: *the second broker `account_info()` read itself failed.* Nothing else.

### `account_observation_status`

| Status | Meaning | `failure_reason` |
|---|---|---|
| `observed` | `account_info()` returned an object and identity re-check passed | **`NULL`, always** |
| `failed` | `account_info()` returned `None` or raised | **`NOT NULL` and `= 'ACCOUNT_READ_FAILED'`** |

**FINAL DECISION:** the allowlist is one value — `ACCOUNT_READ_FAILED`. No
transport-vs-terminal split inside the immutable broker observation row, because those
distinctions are operational, not observational.

**Raw exception text is never stored.** It is unbounded, non-deterministic, may embed
paths or identifiers, and would break fingerprint stability across replays.

A `failed` row is fully determined:

```
equity = NULL, balance = NULL, currency = NULL,
equity_quality = 'absent', balance_quality = 'absent',
failure_reason = 'ACCOUNT_READ_FAILED'      -- NOT NULL, enforced (see §6, §14)
```

An `observed` row has `failure_reason IS NULL` and says everything else through the value
and quality columns:

- equity → `usable` / `invalid` / `absent`
- balance → `usable` / `invalid` / `absent`
- `currency IS NULL` → the currency was unavailable

No additional reason code is needed.

### Failure matrix

Every row below is internally consistent with §7 and §11.

| # | Condition | Row written | status | equity | equity_q | balance_q | failure_reason | Membership |
|---|---|---|---|---|---|---|---|---|
| 1 | 2nd `account_info()` → `None`/raises | ✅ | `failed` | `NULL` | `absent` | `absent` | `ACCOUNT_READ_FAILED` | **proceeds** (if the failed row persists) |
| 2 | `balance` missing | ✅ | `observed` | unaffected | unaffected | `absent` | **`NULL`** | **proceeds** |
| 3 | `equity` missing | ✅ | `observed` | `NULL` | `absent` | unaffected | **`NULL`** | **proceeds** |
| 4 | `equity = NaN` | ✅ | `observed` | **`NULL`** | `invalid` | unaffected | **`NULL`** | **proceeds** |
| 5 | `equity = +Infinity` | ✅ | `observed` | **`NULL`** | `invalid` | unaffected | **`NULL`** | **proceeds** |
| 6 | `equity = -Infinity` | ✅ | `observed` | **`NULL`** | `invalid` | unaffected | **`NULL`** | **proceeds** |
| 7 | `equity = 0` | ✅ | `observed` | raw `0` | `invalid` | unaffected | **`NULL`** | **proceeds** |
| 8 | `equity` negative finite | ✅ | `observed` | raw negative | `invalid` | unaffected | **`NULL`** | **proceeds** |
| 9 | `balance` non-finite | ✅ | `observed` | unaffected | unaffected | `invalid` (`NULL` value) | **`NULL`** | **proceeds** |
| 10 | `currency` blank/`None` | ✅ | `observed` | unaffected | unaffected | unaffected | **`NULL`** | **proceeds**; exposure unavailable |
| 11 | **login drift T0 → T1.5** | ❌ none | — | — | — | — | — | **NO row, NO snapshot, HARD STOP** |
| 12 | account OK, `positions_get()` fails | ❌ none | — | — | — | — | — | **NO** (existing S1 behaviour; no run created) |
| 13 | **deterministic append contract failure** | operational | — | — | — | — | — | operational failure → attempt `APPEND_FAILED` terminalisation (§11 B) |
| 14 | **transport unknown on account append** | operational | — | — | — | — | — | operational unknown → **no terminalisation** (§11 C) |
| 15 | snapshot later `suspicious` | unchanged (immutable) | — | — | — | — | — | excluded by §15 |
| 16 | snapshot becomes stale | unchanged (immutable) | — | — | — | — | — | excluded by §15 |

Rows 1–10 are **broker value quality**: represented as valid account rows, never blocking
membership. Row 11 is identity integrity. Rows 13–14 are **operational**, and are
deliberately not expressible as `failure_reason` values. Rows 15–16 are consumption-time
judgements that never mutate the row.

---

## 9. `p_facts` contract and server-derived fields

The append RPC **must not trust** identity, scope, provenance or the fingerprint from the
caller. It derives them from the parent `mt5_sync_runs` row it has already locked:

| Field | Source |
|---|---|
| `user_id` | parent run |
| `source_account` | parent run |
| `captured_at` | parent run |
| `connector_version` | parent run |
| `account_fingerprint` | computed by the RPC from the stored column values |

A caller that could supply `captured_at` could seal an account sample against a different
instant than the membership; a caller that could supply `account_fingerprint` could make
a conflicting replay look identical. Neither is negotiable.

`p_facts` therefore carries **only observation facts** — exactly these eight keys, no
more, no fewer:

```
account_read_at
account_observation_status
equity
balance
currency
equity_quality
balance_quality
failure_reason
```

Exact-key validation runs **before** any `jsonb_to_record` / `jsonb_to_recordset`
extraction, for the reason S1 already learned the hard way: those functions **silently
ignore extra keys and silently yield `NULL` for absent or misspelled ones**, so a typo
would become a `NULL` equity that looks like a legitimate `absent`.

Rejection codes: `ERR_ACCOUNT_PAYLOAD_KEYS` (wrong key set),
`ERR_ACCOUNT_PAYLOAD_INVALID` (right keys, bad types/values). Both are **operational**
errors (§11 class B), never `failure_reason` values.

---

## 10. Account fingerprint

Domain-separated, deterministic, NULL-safe. It mirrors the style of the frozen
`mt5_position_fingerprint_v1` — a JSON array rendered to text and SHA-256'd, where JSON
`null` is an unambiguous, collision-free representation of a missing value — and adds an
explicit domain tag, which the S1 position fingerprint does not carry.

```sql
create function public.mt5_account_fingerprint_v1(
  p_user uuid, p_account text, p_captured_at timestamptz, p_connector_version text,
  p_account_read_at timestamptz, p_status text,
  p_equity numeric, p_balance numeric, p_currency text,
  p_equity_quality text, p_balance_quality text, p_failure_reason text
) returns text
language sql stable security definer set search_path='' as $fp$
  select public.mt5_sha256_text_v1(
    pg_catalog.jsonb_build_array(
      pg_catalog.to_jsonb('mt5.s1_1.account/1'::text),          -- domain separation
      pg_catalog.to_jsonb(p_user),
      pg_catalog.to_jsonb(p_account),
      pg_catalog.to_jsonb(extract(epoch from p_captured_at)::numeric),
      pg_catalog.to_jsonb(p_connector_version),
      pg_catalog.to_jsonb(extract(epoch from p_account_read_at)::numeric),
      pg_catalog.to_jsonb(p_status),
      pg_catalog.to_jsonb(p_equity),
      pg_catalog.to_jsonb(p_balance),
      pg_catalog.to_jsonb(p_currency),
      pg_catalog.to_jsonb(p_equity_quality),
      pg_catalog.to_jsonb(p_balance_quality),
      pg_catalog.to_jsonb(p_failure_reason)
    )::text
  )
$fp$;
```

Covers every immutable stored evidence field **except `created_at`** (a server clock
artefact, not evidence) and `run_id` (already the primary key; including it would make the
fingerprint useless for detecting a same-run fact change, which is its entire job).

**FINAL DECISION: no `trim_scale()`.** S1.1 stays consistent with the frozen S1 fingerprint
semantics. `to_jsonb(numeric)` preserves display scale, so `100.0` and `100.00` render
differently — harmless for exact replay of the *same* envelope (identical JSON in →
identical numeric scale → identical fingerprint), which is the only property the
fingerprint claims. Disposable tests must validate numeric scale and canonical-text
behaviour explicitly rather than assuming it (§20).

### Replay contract

| Case | Result |
|---|---|
| Same run, byte-identical facts | `o_ok = true, o_inserted = 0` — exact idempotent replay |
| Same run, **any** changed fact | **`ERR_ACCOUNT_CONFLICT`** — never an overwrite |
| Second row for the same run | primary-key violation — structurally impossible |

---

## 11. Append RPC and the failure state machine

```sql
create function public.mt5_append_run_account_v1(
  p_run_id uuid, p_user uuid, p_account text, p_lease_token uuid, p_facts jsonb
) returns table(o_ok boolean, o_inserted integer, o_error_code text)
language plpgsql security definer set search_path='';
grant execute on function
  public.mt5_append_run_account_v1(uuid,uuid,text,uuid,jsonb) to service_role;
```

Signature deliberately parallel to `mt5_append_run_positions_v1(uuid,uuid,text,uuid,jsonb)`:
same lease check, same scope check, same active-run requirement, same
`security definer set search_path=''`, `service_role` only.

### Precedent: what the reviewed S1 adapter actually does

S1.1 follows the **existing** S1 one-shot behaviour rather than inventing a new stance.
The committed adapter (`s1_snapshot.py`) already distinguishes the two cases:

```python
STAGE_FAILED_REASON = {STAGE_APPEND: "APPEND_FAILED", STAGE_COMPLETE: "SEAL_FAILED"}
```

- **Deterministic `o_ok = false`** from a stage → `_fail(stage, code)`, then
  `client.mark_snapshot_failed(..., reason_code=reason)` is **attempted**, its outcome is
  printed separately, and on cleanup failure the message is explicitly
  `cleanup FAILED: ... (the ORIGINAL failure above is still {code})`, followed by
  `ORIGINAL FAILURE: stage=... code=...`.
- **Transport exception (outcome unknown)** → `_fail(stage, "TRANSPORT_FAILED", ...)` and
  `RUN_STATE_UNKNOWN`, with the comment *"Do NOT auto-terminalise: the call may have
  landed"* and **no cleanup attempted**.

Draft-2 of this document claimed S1 deliberately leaves deterministic append/complete
failures in `started`. **That was factually wrong** and is corrected here.

### Class A — BROKER VALUE QUALITY

Examples: second `account_info()` read failed · equity absent · equity `<= 0` · equity
non-finite · balance invalid or absent · currency absent.

Behaviour:

- represent a deterministic account observation row (per §7, §8)
- **do not block** the position snapshot
- continue the cycle normally if persistence succeeds

No change from draft-2.

### Class B — DETERMINISTIC ACCOUNT-APPEND CONTRACT / INTEGRITY FAILURE

Examples: `ERR_ACCOUNT_CONFLICT` · malformed payload contract rejection
(`ERR_ACCOUNT_PAYLOAD_KEYS` / `ERR_ACCOUNT_PAYLOAD_INVALID`) · scope conflict ·
`captured_at` conflict · deterministic lease/state refusal once the invocation knows
`create_run` succeeded · any other deterministic `o_ok = false` from
`append_run_account`.

Behaviour:

1. **STOP before `complete_snapshot`.**
2. **Preserve the ORIGINAL account-append error as the primary error.**
3. **Attempt** `mt5_mark_snapshot_failed_v1(reason = 'APPEND_FAILED')` using the exact
   current run identity and lease, where the frozen S1 contract allows it.
4. **Report the cleanup outcome separately.**
5. **A cleanup failure must NEVER hide or replace the original account-append error.**
6. **Do not call `reconcile_snapshot`.**
7. **Do not run another cycle automatically.**

Expected terminal state when cleanup succeeds: `snapshot_status = 'failed'`.

`APPEND_FAILED` is reused deliberately: it is already the S1 reason code for the append
stage, and an S1.1 account append is an append. No new reason vocabulary is introduced.

> **No S1.1 account persistence failure may be misreported as bad equity.** Class B is an
> operational failure of the write path; class A is an observation about the broker. They
> have different codes, different outcomes, and different recoveries.

### Class C — TRANSPORT UNKNOWN DURING ACCOUNT APPEND

After bounded identical retry is exhausted (same payload, `MAX_RETRIES = 2`, exactly as
S1):

```
ACCOUNT_APPEND_RESULT_UNKNOWN
```

Behaviour:

- **do NOT** call `complete_snapshot`
- **do NOT** call `mt5_mark_snapshot_failed_v1`
- **do NOT** expire automatically
- **do NOT** call `reconcile_snapshot`
- **STOP**

Reason: the account append **may have committed** despite the lost response. Terminalising
the run here could destroy a recoverable exact-replay path, and sealing it could
permanently create the §13 anomaly.

### Class C recovery — operator-gated identical resume

Safe **only** because `append_run_account` uses full-fact fingerprint replay: same facts →
`inserted = 0` / success; different facts → `ERR_ACCOUNT_CONFLICT`.

Resume conditions, all required:

- same `run_id`
- same canonical v2 envelope
- same approved SHA-256
- run still `snapshot_status = 'started'`
- lease still live
- **no MT5 re-read, no recapture**
- explicit operator action
- a bounded single request — **no loop**

| Outcome | Meaning | Action |
|---|---|---|
| `o_ok, o_inserted = 0` | the row exists and is fact-identical | safe to continue the cycle |
| `o_ok, o_inserted = 1` | the row did not exist; now written from the approved envelope | safe to continue |
| `ERR_ACCOUNT_CONFLICT` | a row exists with **different** facts | class B — fail closed, attempt `APPEND_FAILED` |
| lease expired | authority lost | **do NOT resume append**; use separately reviewed stale-run recovery, and eventually a NEW observation after terminalisation |

**This is not the rejected `ERR_RUN_SEALED` resume.** That one was unsafe because
`ERR_RUN_SEALED` proves only *run identity and create metadata* — run_id, user, account,
`captured_at`, connector, policy — and never the per-position facts, so a resume could
continue against a run whose contents differed from the approved envelope. Here the run is
**not sealed**, and `append_run_account` compares the **full account fingerprint**, which
covers every stored evidence field. A mismatch is detected and refused rather than assumed
away. The resume is fact-complete, not identity-only — and still never automatic.

---

## 12. Cycle order

```
create_run
  → append_run_positions
  → append_run_account          <-- S1.1, while the parent run is still 'started'
  → complete_snapshot
  → reconcile_snapshot
  → exit
```

The account append must precede completion because the guard requires
`snapshot_status='started'`. A convenient consequence: the same `complete_snapshot` seals
both membership and account facts, with no change to any frozen RPC.

**No frozen S1 RPC is altered.** `mt5_complete_snapshot_v1` stays entirely ignorant of
account facts, which is what makes §11 class A possible.

---

## 13. Completed S1.1 run invariant

Because the frozen `mt5_complete_snapshot_v1` cannot require an account row, this is an
**application and verification invariant, not a frozen-S1 database invariant**:

> For any run whose `connector_version` is in the S1.1 one-shot namespace
> (`s1.1-oneshot/*`), a completed run **must** have exactly one
> `mt5_sync_run_account` row — including when the broker account read failed, in which
> case the row has `status='failed'`.

A completed S1.1-namespace run with no account row is:

```
S1_1_ACCOUNT_ROW_MISSING_ANOMALY
```

**Do not** add a trigger to `mt5_sync_runs` to enforce it — that would alter the frozen
table's structural fingerprint and disarm S1 rollback (§1a). **Do not** alter the frozen
completion RPC.

The S1.1 verification packet must assert it:

```sql
-- expected: zero rows
select r.id, r.connector_version, r.run_seq, r.snapshot_completed_at
  from public.mt5_sync_runs r
  left join public.mt5_sync_run_account a on a.run_id = r.id
 where r.snapshot_status = 'complete'
   and r.connector_version like 's1.1-oneshot/%'
   and a.run_id is null;
```

---

## 14. PostgreSQL three-valued-logic review

A `CHECK` constraint **passes when its expression evaluates TRUE *or* NULL**. Only an
explicit FALSE rejects a row. Every constraint touching a nullable column is reviewed
below against the question: *could this expression evaluate NULL and therefore pass
unexpectedly?*

### The defect this review found (HIGH, fixed in draft-3)

Draft-2 used:

```sql
constraint mt5_sra_failed_shape_chk check (
  account_observation_status <> 'failed'
  or (equity is null and ... and failure_reason = 'ACCOUNT_READ_FAILED'))
```

For the row `status='failed', failure_reason=NULL`:

```
'failed' <> 'failed'                    -> FALSE
equity is null AND ... AND (NULL = 'ACCOUNT_READ_FAILED')
  = TRUE AND ... AND NULL               -> NULL
FALSE OR NULL                           -> NULL          -> CHECK PASSES
```

A failed row with **no reason** was therefore accepted. The companion constraints did not
catch it either: `mt5_sra_observed_shape_chk` short-circuits on
`'failed' <> 'observed' -> TRUE`, and the allowlist passes on
`failure_reason is null -> TRUE`.

**Fix:** `mt5_sra_status_shape_chk` is now a `CASE` over the `NOT NULL` column
`account_observation_status`, with an `ELSE false`, whose `failed` branch tests
`failure_reason IS NOT NULL` **before** comparing it. Re-evaluating the same row:

```
CASE 'failed' -> failed branch
  failure_reason is not null            -> FALSE
  FALSE AND (NULL = 'ACCOUNT_READ_FAILED') AND ...
                                        -> FALSE     (FALSE AND NULL = FALSE)
CASE result                             -> FALSE     -> CHECK REJECTS
```

The `IS NOT NULL` test can never itself be NULL, and `FALSE AND anything` is FALSE, so the
whole expression is now total. The allowlist constraint is retained for documentation but
is explicitly noted as **unable** to substitute for the non-null requirement.

### Full constraint review

| Constraint | Nullable columns | Can evaluate NULL? | Verdict |
|---|---|---|---|
| `mt5_sra_status_shape_chk` | `failure_reason`, `equity`, `balance`, `currency` | **No** — `CASE` over a `NOT NULL` column with `ELSE false`; every branch is built from `IS NULL` / `IS NOT NULL` tests and comparisons of `NOT NULL` columns | **total** |
| `mt5_sra_failure_reason_allowlist_chk` | `failure_reason` | **Yes, by design** — passes on NULL. Documented as non-substituting | intentional |
| `mt5_sra_equity_quality_shape_chk` | `equity` | **No** — `CASE` over `NOT NULL` `equity_quality` with `ELSE false`; the `usable` branch leads with `equity is not null`, so the later `>` and `not in` can never be reached with NULL | **total** |
| `mt5_sra_balance_quality_shape_chk` | `balance` | **No** — same structure | **total** |
| `mt5_sra_equity_finite_chk` | `equity` | **Yes, by design** — `equity is null OR ...`; NULL equity is legitimate | intentional |
| `mt5_sra_balance_finite_chk` | `balance` | same | intentional |
| `mt5_sra_currency_nonblank_chk` | `currency` | **Yes, by design** — NULL currency is legitimate | intentional |
| `mt5_sra_read_at_window_chk` | none (`NOT NULL` both sides) | No | total |
| `mt5_sra_status_chk`, `*_quality_chk` | none | No | total |
| `mt5_sra_account_nonblank_chk`, `*_connector_nonblank_chk` | none | No | total |
| `mt5_sra_fingerprint_chk` | none | No | total |

**Rule adopted for S1.1:** any constraint that must *require* a value on a nullable column
uses a `CASE ... ELSE false` over a `NOT NULL` discriminator and leads with an explicit
`IS NOT NULL` test. Directional `A <> x OR (...)` forms are not used where the right-hand
side compares a nullable column to a literal.

### Draft-3 contradiction sweep

The whole artifact was searched for draft-2 remnants. **None remain.** Specifically, there
is no longer any claim that:

- non-finite broker equity always fails preview — **removed**; §3 and §7 now state
  normalisation succeeds and preview completes
- `allow_nan=False` is the normal non-finite classifier — **removed**; §3 and §7 label it a
  defensive backstop
- deterministic account append failure intentionally remains `started` — **removed**;
  §11 class B now attempts `APPEND_FAILED` terminalisation
- S1 precedent leaves deterministic append errors unterminated — **removed and explicitly
  corrected** in §11 with the actual `STAGE_FAILED_REASON` behaviour
- the S1 rollback packet header should be edited — **removed**; §19 lists three S1.1-owned
  locations only
- `trim_scale` remains open — **decided** in §10: no `trim_scale`
- class-B recovery remains open — **decided** in §11
- the 30-second bound remains open — **decided** in §5
- the `failure_reason` value set remains open — **decided** in §8

The former "Open questions for review" section is deleted; §22 now records final decisions.

---

## 15. Exposure boundary

**S1.1 does not implement exposure calculation.** This section specifies only the
eligibility predicate a future, separately reviewed consumer must satisfy.

```
run R is a valid exposure basis  ⟺
    R.snapshot_status = 'complete'
AND R.snapshot_health = 'healthy'
AND freshness_state(R) = 'fresh'
        -- clock_timestamp() - R.captured_at <= R.policy_thresholds->>'freshness_seconds'
AND ∃ account row A with A.run_id = R.id
AND A.account_observation_status = 'observed'
AND A.equity_quality = 'usable'          -- ⇒ finite and > 0, DB-enforced
AND A.currency is not null and btrim(A.currency) <> ''
AND notional_currency(p) = A.currency    -- for each position p being included
```

### Storage quality vs exposure eligibility — they are different questions

Missing currency does **not** invalidate the stored scalar equity. This row is legitimate
broker evidence:

```
equity = 100000    equity_quality = 'usable'    currency = NULL
```

The equity was genuinely observed and is genuinely a positive finite number. What is
missing is the ability to prove the denominator and the numerator share a unit. So the row
is **stored as usable** and **excluded from exposure** — the constraint lives at
consumption, where the notional's currency is also known.

This also guards the no-FX-conversion boundary: an account may be denominated in one
currency while holding an instrument quoted in another. A currency mismatch yields
`unavailable`, never a silently mixed-unit ratio.

**Never fall back to balance.** Structurally enforced by keeping `balance` out of the
denominator path entirely — the future exposure RPC should not even select it.

### `reconcile_status` is NOT a gate

Exposure eligibility must **not** require `reconcile_status = 'complete'`.

A healthy, fresh, `snapshot_status='complete'` run already contains authoritative
immutable broker membership. `reconcile_status` governs the **mutable Phase-0A staging
lifecycle** — a different subsystem answering a different question. A `complete + pending`
run may therefore be exposure-eligible if every other predicate passes.

This also matches the frozen `mt5_get_current_snapshot_v1`, which selects on
`snapshot_status='complete'` alone. `reconcile_status` may be exposed as diagnostic
metadata, never as a denominator gate.

### Per-position vs portfolio gearing

```
position_gearing(p)     = abs(validated_notional(p)) / A.equity
portfolio_gross_gearing = Σ abs(validated_notional(p)) / A.equity     -- all p, or nothing
```

**Per-position gearing MAY be returned** for an individually validated position when the
account equity basis is eligible, that position has a validated notional, and its notional
currency matches the account currency — **even if another open position is unresolved**.

**Portfolio gross gearing MUST be unavailable if ANY open position lacks a validated
notional or currency basis:**

```
portfolio_gross_gearing = unavailable
unavailable_reason      = 'NOTIONAL_BASIS_INCOMPLETE'
blocking_position_ids   = [ ... ]
```

Never partial-sum the portfolio gross. A partial sum silently **understates** leverage,
and an understated gearing number is more dangerous than no number — it is confidently
wrong in the direction that invites more risk.

---

## 16. Notional source boundary — documented, not solved

**S1.1 does not own product-family notional mapping.** Recorded direction only:

| Family | Direction |
|---|---|
| Gold | dual-source validation eventually |
| S50 / Silver / USDJPY | single-source validation |
| SSF (e.g. `DELTAU26`) | strict futures / contract-size handling |
| Spot / CFD / user-added products | **excluded** until explicitly validated |

Evidence already on hand from the first production snapshot: `DELTAU26` reported
`contract_size = 1000` and `S50U26` reported `contract_size = 200`, both genuine broker
metadata with no substitution. S1's rule stands unchanged — **`contract_size` is never
defaulted to 1**; it stays `NULL` when `symbol_info` is unavailable.

Notional basis belongs in a later S2-class artefact (a versioned "notional basis
registry" keyed by `symbol_raw` and instrument class, with its own eligibility rules).
S1.1 stores only the `contract_size` S1 already captures, plus the account denominator.

---

## 17. Security and browser/API exposure

Posture preserved verbatim from S1:

- service_role writes **only** through `SECURITY DEFINER` RPCs
- `authenticated` receives `EXECUTE` on read functions only, and **no** table privileges
- no generic `rpc()`; the connector's allowlist is structural
- no direct browser table write
- no `localStorage` flag is ever authorization — a UI flag gates *rendering*, never access

### Decisions

**`mt5_get_current_snapshot_v1(text)` stays frozen and unchanged.** Raw `equity`,
`balance` and `currency` are **not** added to it.

**The account row is not exposed to `authenticated` at all** in S1.1 — no table grant, no
function returning its rows.

Three reasons: changing that RPC would edit a frozen artefact; the UI's actual need is a
*ratio*, not the account's cash position, so shipping raw equity widens the blast radius
of any future session/XSS issue to "attacker learns account size" for zero functional
gain; and a raw equity in the browser invites client-side arithmetic, which is exactly
where unvalidated notionals and silent partial sums reappear.

**A future exposure read must be a NEW, separately reviewed RPC**, conceptually:

```
mt5_get_current_exposure_v1(p_source_account text) -> jsonb    -- grant to authenticated
  { ok, error_code, freshness_state,
    basis_run_id, eligibility: 'available'|'unavailable', unavailable_reason,
    positions: [ { position_id, symbol_raw, gearing } ],
    portfolio_gross_gearing,      -- null whenever eligibility='unavailable'
    blocking_position_ids }
```

Derived fields only. **No exposure RPC is implemented in S1.1.**

---

## 18. Privacy and reporting

Equity and balance are private financial figures. They are needed to *operate*, not to
*review*.

**Local preview terminal (Junior only):** full `equity`, `balance`, `currency` displayed.
Junior must be able to see exactly what he is approving.

**External / reviewer reports:** **mask or omit `equity` and `balance` by default.**
Report instead:

- `account_observation_status` (`observed` / `failed`)
- `equity_quality`, `balance_quality`
- `currency`, if relevant to the review
- whether equity is exposure-eligible
- canonical envelope SHA-256
- structural validation result

A design or code review needs the *quality classification*, never the account size. The
canonical SHA still binds approval to the exact values without disclosing them.

---

## 19. Migration artifacts and rollback ordering

Additive only. No frozen S1 artefact is edited. Planned files (**none created yet**):

| Artifact | Contents |
|---|---|
| `S1_1_account_observation_design.md` | **this document**; frozen once approved, its file SHA-256 recorded as `source_artifact_sha256` |
| `S1_1_test_preflight_packet.sql` | asserts S1 revision 5 applied **and** `mt5_sync_runs`' current fingerprint still equals the S1 ledger's — refuses to install onto a drifted S1 |
| `S1_1_schema_packet.sql` | table + guard + 2 triggers + RLS + grants + postflight + ledger `mt5_s1_1_account_observation_schema_v1` |
| `S1_1_rpc_packet.sql` | `mt5_append_run_account_v1` + `mt5_account_fingerprint_v1` + ledger `mt5_s1_1_account_observation_rpc_v1` |
| `S1_1_verification_packet.sql` | read-only assertions, including the §13 anomaly query |
| `S1_1_rollback_packet.sql` | self-sufficient teardown of S1.1 objects only |

### Rollback ordering — mandatory operational invariant

> **S1.1 rollback MUST run before S1 rollback.**

`S1_rollback_packet.sql` ends with `drop table if exists public.mt5_sync_runs;` and uses
**no `CASCADE`** — the packet relies on explicit drop ordering throughout (its own
comment: `-- composite FK to mt5_sync_runs drops with it`). While `mt5_sync_run_account`
exists with its FK, that statement fails.

**The warning is documented in exactly three S1.1-owned locations:**

1. the `S1_1_rollback_packet.sql` header
2. the S1.1 README / runbook / operational documentation
3. this design artifact

**`S1_rollback_packet.sql` is FROZEN and must NOT be edited** — not its logic, not its
header, not a comment. Its byte-level SHA-256 must remain unchanged, and that is an
acceptance test (§20). The ordering is an operational invariant enforced by S1.1's
documentation and by the disposable acceptance test, never by modifying S1.

S1.1 rollback never touches `mt5_sync_runs`, so running it first fully restores S1
rollback to a working state.

### S1.1 apply must prove it did not disarm S1

A **required postflight** in `S1_1_schema_packet.sql` recomputes the structural
fingerprints of `mt5_sync_runs` and `mt5_sync_run_positions` and asserts they still equal
the values recorded in the S1 ledger's `objects->'provenance'->'tables'`.

Cheap, and it converts "we believe S1 rollback still works" into a fact checked at apply
time.

S1.1 must also carry its **own** postflight asserting no `INSERT`/`UPDATE`/`DELETE` grant
exists on `mt5_sync_run_account` for `anon`/`authenticated`/`service_role` — the S1
postflight is scoped by table name and does not cover the new table.

---

## 20. Disposable acceptance matrix

Disposable PostgreSQL 17.6 stack, S1 packets applied **unchanged**, S1.1 on top. Never
pointed at production.

### A. Status / `failure_reason` shape — includes the HIGH regression test

| # | Case | Expected |
|---|---|---|
| A1 | **`status='failed'`, equity/balance/currency `NULL`, both qualities `absent`, `failure_reason = NULL`** | **DB REJECT** — blocking regression test for the draft-2 three-valued-logic hole |
| A2 | `status='failed'` with `failure_reason='ACCOUNT_READ_FAILED'` and all other failed-row requirements met | **ACCEPT** |
| A3 | `status='observed'` with `failure_reason` non-null | **REJECT** |
| A4 | `status='failed'` with any `*_quality = 'usable'` | **REJECT** |
| A5 | `status='failed'` carrying a raw financial value | **REJECT** |
| A6 | `failure_reason` outside the allowlist | **REJECT** |

### B. Non-finite: normalisation vs defensive serialiser — two separate tests

| # | Case | Expected |
|---|---|---|
| B1 | broker `equity = NaN` → normalised to `null` + `invalid` | **ACCEPT**; canonical v2 envelope builds; membership may proceed |
| B2 | broker `equity = +Infinity` → normalised | **ACCEPT**, as B1 |
| B3 | broker `equity = -Infinity` → normalised | **ACCEPT**, as B1 |
| B4 | broker `balance` non-finite → normalised | **ACCEPT**, as B1 |
| B5 | **deliberately unnormalised `NaN`** injected into the canonical payload builder | **serialiser REFUSES** (`allow_nan=False`); no envelope approval possible |
| B6 | **deliberately unnormalised `Infinity`** injected into the canonical payload builder | **serialiser REFUSES** |
| B7 | direct DB payload falsely carrying a non-finite numeric | **DB REJECT** (finite CHECKs, defence in depth) |
| B8 | `equity_quality='usable'` with `equity` non-finite | **DB REJECT** |
| B9 | `equity_quality='usable'` with `equity = 0` or negative | **DB REJECT** |
| B10 | numeric scale / canonical text behaviour (`100.0` vs `100.00`) | **explicitly characterised**, not assumed (no `trim_scale`, §10) |

### C. Immutability, scope, replay

| # | Case | Expected |
|---|---|---|
| C1 | `account_read_at` older than 30 s before `captured_at` | REJECT |
| C2 | `account_read_at` after `captured_at` | REJECT |
| C3 | `captured_at` ≠ parent run's | `MT5_S1_1_CAPTURE_CONFLICT` |
| C4 | `UPDATE` any row | `MT5_S1_1_IMMUTABLE_ROW` |
| C5 | `DELETE` any row | `MT5_S1_1_IMMUTABLE_ROW` |
| C6 | insert after `complete_snapshot` | `MT5_S1_1_RUN_NOT_STARTED` |
| C7 | second row for the same `run_id` | PK violation |
| C8 | cross-scope `user_id` / `source_account` | FK violation |
| C9 | wrong or expired lease | refused |
| C10 | exact replay of identical facts | `o_ok`, `o_inserted = 0` |
| C11 | replay with **any** changed fact | `ERR_ACCOUNT_CONFLICT` |

### D. Class A/B/C state machine

| # | Case | Expected |
|---|---|---|
| D1 | deterministic `ERR_ACCOUNT_CONFLICT` | **no `complete_snapshot` call**; `mark_snapshot_failed(APPEND_FAILED)` **attempted**; original `ERR_ACCOUNT_CONFLICT` remains the primary reported error; run becomes `failed` when cleanup succeeds |
| D2 | deterministic malformed / payload-contract rejection | same terminalisation attempt as D1 |
| D3 | `mark_snapshot_failed` itself fails | original account-append error still reported as primary; cleanup error reported **separately**; no `complete`, no `reconcile` |
| D4 | transport lost ACK where the account row **actually committed** | **no terminalisation**; operator-gated identical resume; append replay proves the same fingerprint (`inserted=0`); cycle may then continue |
| D5 | transport unknown with no proof | **no `complete`**, **no automatic terminalisation**, STOP with `ACCOUNT_APPEND_RESULT_UNKNOWN` |
| D6 | failed account read (`status='failed'`) persisted | full position snapshot still completes and reconciles |
| D7 | login drift at T1.5 | hard stop; **no** run created, **no** row written |
| D8 | write path during `--write` | **zero** MetaTrader5 calls |

### E. Envelope versioning

| # | Case | Expected |
|---|---|---|
| E1 | v1 envelope passed to S1.1 write mode | `ENVELOPE_FORMAT_NOT_S1_1`, refused before any DB call |
| E2 | v2 envelope passed to S1 (v1) write mode | `ENVELOPE_FORMAT_NOT_S1` |
| E3 | any account-fact mutation in a v2 envelope | canonical SHA changes |

### F. Verification and rollback

| # | Case | Expected |
|---|---|---|
| F1 | completed `s1.1-oneshot/*` run with no account row | **anomaly** flagged by the verification packet |
| F2 | `run_seq = 1`, `s1-oneshot/0.1`, no account row | **expected**, not an anomaly |
| F3 | S1 table fingerprints after S1.1 apply | unchanged vs the S1 ledger |
| F4 | **`S1_rollback_packet.sql` file SHA-256** | **unchanged** — the frozen file was never edited |
| F5 | **S1 rollback alone while the S1.1 FK exists** | **fails safely** (blocking acceptance test) |
| F6 | S1.1 rollback → then S1 rollback | **both succeed** |

**A1, F5 and F6 are the blocking acceptance tests.** A1 proves the three-valued-logic hole
is closed. F5/F6 make the documented rollback ordering a verified fact rather than an
assumption, and would immediately catch a future change that added `CASCADE` or reordered
the teardown.

---

## 21. First S1.1 canary

Same discipline as the S1 first snapshot. Disposable-DB green before any of this.

| Phase | Action |
|---|---|
| **A — preview** | One MT5 session. Strict positions read. Second `account_info()` sample at T1.5 with identity re-check. Non-finite values normalised to `null` + `invalid`. `account_read_at` window validated. Canonical **v2** envelope written (git-ignored). **Zero DB calls**, no transport constructed. |
| **B — show** | Account facts + full position table + field completeness + warnings + envelope path + canonical SHA-256. **Full values locally only**; masked in any external report (§18). |
| **C — approve** | Human approval bound to the canonical v2 SHA — which now covers the account block, so approving the snapshot approves the exact denominator. Max envelope age 900 s; expiry means a new preview and a new approval, never a widened bound. |
| **D — write** | **Zero MT5 calls.** Replay the approved v2 canonical payload: `create_run → append_run_positions → append_run_account → complete_snapshot → reconcile_snapshot → exit`. Armed by `MT5_S1_WRITE` plus an explicit confirm token. |
| **E — verify** | Read-only: the rs01–rs09 equivalents, plus **rs10** (account row: status, qualities, `captured_at` equals the run's, `account_read_at` inside the window, fingerprint) and **rs11** (S1 table fingerprints still match the S1 ledger — rollback still armed). |
| **F** | **STOP.** No scheduler, no automatic second cycle, no writer, no browser consumption. |

### Behaviour inside phase D

- **Account VALUE invalid or unavailable (class A)** → a valid degraded account row is
  written and the position snapshot **proceeds** to completion and reconcile.
- **Account PERSISTENCE integrity fails (class B)** → **fail closed before
  `complete_snapshot`**; attempt `mark_snapshot_failed(APPEND_FAILED)`; report the
  original error as primary and the cleanup outcome separately; no `reconcile`; STOP.
- **Transport outcome unknown (class C)** → `ACCOUNT_APPEND_RESULT_UNKNOWN`; do **not**
  complete, do **not** terminalise, do **not** expire; STOP.

Carry-overs from the S1 canary that still apply: preview is the CLI **default** (there is
no `--preview` flag), and `ERR_RUN_SEALED` continues to fail closed — an account-facts
replay against a sealed run proves even less than a position replay does, since the row
would be recomputed from an already-sealed run.

---

## 22. Final design decisions

These were open questions in draft-2. They are now **decided**, not open.

| # | Question | **Final decision** |
|---|---|---|
| 1 | `trim_scale()` on fingerprint numerics | **No `trim_scale()`.** Stay consistent with frozen S1 fingerprint semantics. Disposable tests must characterise numeric scale / canonical text behaviour explicitly (§10, §20 B10). |
| 2 | Class-B recovery instrument | **Deterministic append failure → attempt `mt5_mark_snapshot_failed_v1(reason='APPEND_FAILED')`.** Transport unknown → **no terminalisation.** Mirrors the existing reviewed S1 adapter behaviour (§11). |
| 3 | `failure_reason` vocabulary | **One value: `ACCOUNT_READ_FAILED`.** No transport-vs-terminal split inside the immutable broker observation row; operational errors are not `failure_reason` values (§8, §12 boundary). |
| 4 | Contemporaneity window | **30 seconds, fixed fail-closed bound, NOT runtime-configurable in S1.1 v1** (§5). |

---

## 23. Non-goals, restated

S1.1 does **not**: compute exposure or gearing · own notional mapping · expose anything new
to the browser · alter any frozen S1 artefact (including `S1_rollback_packet.sql`, whose
file SHA must not change) · add a trigger to `mt5_sync_runs` · start a scheduler, daemon or
continuous writer · touch Telegram, T2, T3, Journal, G2 or GUGU · backfill any historical
run · permit any `UPDATE` of an account row, ever.

---

*End of draft-3. Status: FROZEN — CODEX APPROVED (2026-08-22). This document is frozen; its
SHA-256 is the `source_artifact_sha256` recorded by every S1.1 packet ledger row.*
