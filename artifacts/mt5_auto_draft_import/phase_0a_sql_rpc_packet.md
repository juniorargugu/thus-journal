# MT5 Auto Draft Import — Phase 0A SQL/RPC Implementation Packet (r3, post-SQL-review polish)

> ## ⛔ `GATED — REVIEW ONLY — NOT APPLIED`
> - **Target baseline:** `09842d7` (prod). **Nothing in this file has been run.** No Supabase write, no migration, no apply.
> - **Review status:** Codex re-review = **PASS**; Supabase SQL review = **PASS / READY_FOR_CONFLICT_PRECHECK**. r3 folds in that review's optional (non-blocking) polish; the packet is **still NOT APPLIED**.
> - **Apply still requires ALL of:** explicit user GO **+** a clean conflict pre-check (§3) **+** execution inside **one transaction** (§3.5). (Codex + Supabase SQL review are now satisfied.)
> - This artifact translates the approved [`phase_0a_r3_design_plan.md`](phase_0a_r3_design_plan.md) into concrete, **fail-closed, create-only** SQL. No `ALTER`/`DROP` of any existing object.
> - Project: `wtfwynvvkiuottjnmozu`. There is **no separate staging Supabase** — the "staging vs prod create-only" decision is user-ratified, not default (§11.2, §12).

**Artifact date:** 2026-06-25 · **Revision:** r3 (folds in Supabase SQL-review optional polish; Codex PASS + SQL-review PASS) · **Type:** SQL/RPC packet (docs-only, gated)

### r3 change log (Supabase SQL-review optional polish — non-blocking, safety unchanged)
1. **Exact-name conflict pre-checks (§3):** added explicit `pg_class.relname` (index) and `pg_trigger.tgname` (trigger) existence checks for the packet's 10 index names + 3 trigger names, so a same-name object on *any* table is caught before `begin;`. Pre-check only; fail-closed `CREATE` unchanged.
2. **Explicit `service_role` grants (§6) + verification (§8):** the reader (0C) no longer relies on Supabase default privileges — `service_role` is explicitly granted SELECT/INSERT/UPDATE on staging+cursors and SELECT on groups (no DELETE; groups stay write-via-RPC). Browser roles unchanged (anon=none, authenticated=SELECT-only on staging/groups).
3. **Split routine-grant verification (§8):** separate assertions — the 3 RPCs have `authenticated` EXECUTE; the helper `mt5_set_updated_at()` has ZERO browser execute.
4. **`trim` on `p_trade_id` (§7.3):** `length(trim(p_trade_id))=0` rejects all-whitespace trade ids.

> r3 changes nothing about apply safety (no DDL/RLS/RPC-logic change beyond the trim guard and additive service_role grants); it is read-side/verification/ergonomics polish. Data-quality nits (`allow_mixed` aggregate pick, `weighted_avg_price` null-price handling) remain **deferred reader invariants**, intentionally not patched here.

### r2 change log (Codex items addressed)
1. **Fail-closed:** removed `create or replace` / `if not exists` / `drop … if exists`; plain `CREATE` only (fails if anything pre-exists).
2. **Transaction wrapper:** apply runs as one `begin; … commit;`; any error → `rollback;` → STOP; no partial apply (§3.5).
3. **DEFINER grant hardening:** each RPC `revoke execute … from public, anon, authenticated;` then `grant … to authenticated;` in-transaction (no transient PUBLIC window).
4. **Table grant hardening:** `revoke all … from public, anon, authenticated;` then SELECT-only back to `authenticated`; post-apply checks for absence of write grants/policies.
5. **`mt5_confirm_group` concurrency:** `FOR UPDATE` leg lock + guarded update with row-count assertion; group insert rolls back if the leg update count ≠ expected (no orphan group).
6. **Grouped-leg dismissal:** `mt5_set_leg_state` may only dismiss **ungrouped/unconfirmed** legs; grouped/materialized legs are not dismissible here (ungroup deferred).
7. **`mt5_mark_materialized` strengthened:** ownership of all legs, ≥1 owned leg, ALL legs `state='grouped'`, count coherence, locks; `p_product_id` retained as **audit** (`materialized_product_id`).
8. **Tripwire strengthened:** NULL `contract_size` → reject (route to `needs_mapping`); known-specific leg class requires a matching known product class; exact contract_size match (rationale in §7.3 note).
9. **`mt5_resolve_mapping` DEFERRED** — body removed; mapping authority stays in the materialize-time tripwire.
10. **Idempotency gaps** documented + reader invariant + STOP (§11.3, §12).
11. **Staging-vs-prod drift** reconciled (§11.2).
12. **Writer timezone invariant** added (§0 Writer invariants).

---

## 0. Writer invariants (reader/Python contract — NOT enforced by this SQL)
The SQL stores UTC-intended `timestamptz` columns and does **no** timezone math. The reader/writer (later, 0C) owns conversion and must guarantee:
- **MT5 time is Asia/Bangkok wall-clock** (probe finding) → convert to **true UTC** (`wall − 7h`) **before insert** into `open_time`/`close_time`/`mt5_time`/`last_seen_open_at`/`first_seen_open_at`.
- **Preserve raw** without loss: `mt5_time_raw_epoch` (raw epoch seconds as MT5 returned, pre-correction), `mt5_time_msc` (raw epoch ms), and the full `raw jsonb`.
- **Idempotency keys:** an `open` row MUST carry `position_id`; a `close`/`partial` row MUST carry `deal_id`. The reader MUST NOT blind-insert rows missing their stable key (see §11.3) — the partial-unique indexes only protect rows that HAVE the key.
- `service_role` is **local/admin only** — never shipped to browser/client/Netlify.

## 1. Status
- Lineage: 0A → 0B probe → 0A-r2 → Codex `PASS_WITH_CHANGES` → 0A-r3 → ChatGPT pass → **packet** → Codex `PASS_WITH_CHANGES` → packet r2 → Codex re-review `PASS` → Supabase SQL review `PASS / READY_FOR_CONFLICT_PRECHECK` → **this packet r3** (optional polish folded in).
- Parking blocker (P2 full-array cleanup) is **cleared** (P2-4C, prod `09842d7`). Remaining design blockers (product-mapping foundation, DELTA-SSF decision) gate **materialization (Phase 1)**, not this schema gate.
- **Not applied. Not a runnable migration in `migrations/`.** Lives under `artifacts/` for review.

## 2. Scope / non-scope
**In scope (authors, does NOT run):** DDL for 3 new tables + indexes/partial-unique + `updated_at` triggers; RLS (browser SELECT-own only); minimal grants; 3 `SECURITY DEFINER` RPC bodies (`mt5_confirm_group`, `mt5_set_leg_state`, `mt5_mark_materialized`).
**Out of scope:** applying SQL; Python reader/probe/writer (0C); Inbox UI (0D); **materialization into THUS `trades`** (Phase 1); close/partial drafts (Phase 2); screenshots (Phase 3); product-mapping foundation; DELTA-SSF decision; any `index.html`/runtime/Product/Symbol/DELTA/GUGU/Storage change; `mt5_resolve_mapping` (deferred, §9).

---

## 3. Conflict pre-check SQL (run FIRST, read-only; must return ZERO before apply)
```sql
select tablename from pg_tables where schemaname='public' and tablename like 'mt5_import_%';            -- expect 0
select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'mt5_%';                                                  -- expect 0
select policyname, tablename from pg_policies where schemaname='public' and tablename like 'mt5_import_%'; -- expect 0
select indexname from pg_indexes where schemaname='public' and tablename like 'mt5_import_%';           -- expect 0
select tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid
  where c.relname like 'mt5_import_%' and not t.tgisinternal;                                           -- expect 0

-- exact-name guards (r3): index names are schema-global, so a same-name index on ANY existing table
-- (not just mt5_import_*) would collide. Trigger names are checked by exact name across the schema too.
select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='i'
    and c.relname in ('mt5_groups_user_acct','mt5_groups_user_state',
                      'mt5_staging_open_uniq','mt5_staging_deal_uniq','mt5_staging_balance_uniq',
                      'mt5_staging_user_acct','mt5_staging_user_state','mt5_staging_group',
                      'mt5_staging_open_live','mt5_staging_created');                                   -- expect 0
select t.tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and not t.tgisinternal
    and t.tgname in ('mt5_groups_updated_at','mt5_staging_updated_at','mt5_cursors_updated_at');        -- expect 0
```
**STOP if any returns rows.** The packet is fail-closed: with no `if not exists`/`or replace`, a plain `CREATE` against a pre-existing object **errors**, which (inside the transaction) forces a full rollback.

## 3.5 Apply procedure (REQUIRED — one transaction, fail-closed, no partial apply)
1. Run §3 pre-check; proceed only if all zero.
2. Execute §4 → §5 → §6 → §7 **as a single transaction**: literally `begin;` **before** §4.0 and `commit;` **after** §7's grants.
3. **If ANY statement errors:** the transaction aborts — run `rollback;` and **STOP**. Never leave a half-applied schema. Do not "fix forward" mid-apply.
4. All objects here are transaction-safe (no `CREATE INDEX CONCURRENTLY`, no `VACUUM`).
5. Only after a clean `commit;` run §8 verification.

```sql
begin;   -- ⬅ START of the single apply transaction (everything in §4–§7 runs here)
```

---

## 4. DDL — tables, indexes, triggers (fail-closed, create-only)

### 4.0 Shared `updated_at` trigger function
```sql
create function public.mt5_set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
revoke execute on function public.mt5_set_updated_at() from public, anon, authenticated;  -- trigger-invoked only
```

### 4.1 `mt5_import_groups` (created first — staging FKs to it)
```sql
create table public.mt5_import_groups (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  source_account      text not null,
  normalized_symbol   text,
  instrument_class    text default 'unknown',   -- fail-open: no rejecting CHECK
  side                text,
  state               text not null default 'grouped',  -- grouped | materialized | dismissed (RPC-controlled)
  prenote             text,
  thesis              text,
  plan                text,
  suggested_start_time  timestamptz,
  suggested_end_time    timestamptz,
  leg_count             int,
  total_volume          numeric,
  weighted_avg_price    numeric,
  import_group_key      text,
  materialized_trade_id text,        -- loose ref to a THUS trade id (string); NOT an FK to trades
  materialized_product_id text,      -- AUDIT: which product was chosen at materialize (from mt5_mark_materialized)
  materialized_at       timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index mt5_groups_user_acct  on public.mt5_import_groups (user_id, source_account);
create index mt5_groups_user_state on public.mt5_import_groups (user_id, state);
create trigger mt5_groups_updated_at before update on public.mt5_import_groups
  for each row execute function public.mt5_set_updated_at();
```

### 4.2 `mt5_import_staging`
```sql
create table public.mt5_import_staging (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  source_account      text not null,
  kind                text not null default 'unknown',   -- open|close|partial|balance|unknown (fail-open)
  symbol_raw          text,
  normalized_symbol   text,
  instrument_path     text,
  instrument_class    text default 'unknown',             -- fail-open
  contract_size       numeric,                            -- e.g. DELTAU26 SSF = 1000 (tripwire input)
  digits              int,
  product_id_candidate text,                              -- HINT ONLY; tripwire never trusts it
  side                text,                               -- buy|sell (raw)
  volume              numeric,
  price               numeric,
  open_time           timestamptz,                        -- true UTC (reader-converted)
  close_time          timestamptz,                        -- true UTC
  mt5_time            timestamptz,                        -- true UTC
  mt5_time_msc        bigint,                             -- raw epoch ms (lossless)
  mt5_time_raw_epoch  bigint,                             -- raw epoch seconds AS MT5 RETURNED (pre +7)
  server_tz           text,
  position_id         bigint,
  deal_id             bigint,
  order_id            bigint,
  ticket              bigint,
  external_id         text,
  commission          numeric,
  swap                numeric,
  fee                 numeric,
  broker_profit       numeric,
  position_state      text default 'open',                -- open|closed|gone (fail-open)
  first_seen_open_at  timestamptz,
  last_seen_open_at   timestamptz,
  state               text not null default 'new',        -- new|group_suggested|grouped|needs_mapping|materialized|dismissed
  import_group_key    text,
  confirmed_group_id  uuid references public.mt5_import_groups(id) on delete set null,  -- ownership enforced in RPC
  materialized_trade_id text,                             -- loose ref to THUS trade id; NOT FK
  materialized_at     timestamptz,
  dismissed_at        timestamptz,
  error_message       text,
  screenshot_url      text,                               -- Phase 3; URL/path ONLY, never base64
  raw                 jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Idempotency (partial unique). NOTE: protects only rows that HAVE the key (see §11.3 for null-key rows).
create unique index mt5_staging_open_uniq
  on public.mt5_import_staging (user_id, source_account, position_id)
  where kind='open' and position_id is not null;
create unique index mt5_staging_deal_uniq
  on public.mt5_import_staging (user_id, source_account, deal_id)
  where deal_id is not null and kind in ('close','partial');
create unique index mt5_staging_balance_uniq
  on public.mt5_import_staging (user_id, source_account, deal_id)
  where kind='balance' and deal_id is not null;

create index mt5_staging_user_acct  on public.mt5_import_staging (user_id, source_account);
create index mt5_staging_user_state on public.mt5_import_staging (user_id, state);
create index mt5_staging_group      on public.mt5_import_staging (confirmed_group_id);
create index mt5_staging_open_live  on public.mt5_import_staging (user_id, position_state) where kind='open';
create index mt5_staging_created    on public.mt5_import_staging (created_at);

create trigger mt5_staging_updated_at before update on public.mt5_import_staging
  for each row execute function public.mt5_set_updated_at();
```

### 4.3 `mt5_import_cursors`
```sql
create table public.mt5_import_cursors (
  user_id           uuid not null,
  source_account    text not null,
  last_seen_deal_id bigint,
  last_seen_time    timestamptz,   -- true UTC; bounds the deal-history query
  server_tz         text,
  updated_at        timestamptz not null default now(),
  primary key (user_id, source_account)
);
create trigger mt5_cursors_updated_at before update on public.mt5_import_cursors
  for each row execute function public.mt5_set_updated_at();
```

---

## 5. RLS — enable + browser SELECT-own ONLY (no `drop`, no write policies)
```sql
alter table public.mt5_import_staging enable row level security;
alter table public.mt5_import_groups  enable row level security;
alter table public.mt5_import_cursors enable row level security;

create policy "mt5_import_staging select own" on public.mt5_import_staging
  for select to authenticated using (user_id = (select auth.uid()));
create policy "mt5_import_groups select own" on public.mt5_import_groups
  for select to authenticated using (user_id = (select auth.uid()));
-- mt5_import_cursors: reader-internal → NO browser policy (and no grant in §6). service_role bypasses RLS.
```
No INSERT/UPDATE/DELETE policies for `authenticated`. RLS enabled with no write policy = browser cannot write. Lifecycle changes flow only through the DEFINER RPCs (§7); the reader writes via `service_role`.

## 6. Grants — hardened (revoke-all then SELECT-only)
```sql
revoke all on public.mt5_import_staging from public, anon, authenticated;
revoke all on public.mt5_import_groups  from public, anon, authenticated;
revoke all on public.mt5_import_cursors from public, anon, authenticated;
grant select on public.mt5_import_staging to authenticated;
grant select on public.mt5_import_groups  to authenticated;
-- mt5_import_cursors: NO authenticated/anon grant (reader-internal). service_role bypasses RLS.

-- service_role (server-side reader / Phase 0C) — EXPLICIT grants (r3): do NOT rely on Supabase default
-- privileges for the reader's writes. The reader writes ONLY staging + cursors; groups are written by the
-- DEFINER RPC (mt5_confirm_group), so groups stays read-only here. No DELETE anywhere (append/RPC lifecycle).
grant select, insert, update on public.mt5_import_staging to service_role;
grant select, insert, update on public.mt5_import_cursors to service_role;
grant select                 on public.mt5_import_groups  to service_role;
```
Result: `anon` = nothing; `authenticated` = SELECT-only (RLS-scoped) on staging/groups, **no** INSERT/UPDATE/DELETE, **no** cursor access. `service_role` = explicit SELECT/INSERT/UPDATE on staging+cursors and SELECT on groups (server-side reader only — never shipped to browser; **no DELETE**, **no group writes**). (Transaction-level revoke is sufficient — the whole apply is atomic, so no committed state ever exposes a browser write grant; `ALTER DEFAULT PRIVILEGES` is not used as it targets *future* objects, not these. The explicit `service_role` grants replace the prior implicit reliance on Supabase default privileges.)

---

## 7. RPC definitions (full bodies — `SECURITY DEFINER`, `search_path=''`, in-body ownership, per-RPC grant hardening)

> All RPCs: `security definer`, `set search_path = ''` (every object fully schema-qualified; `auth.uid()` qualified), ownership enforced **inside** via `auth.uid()`, reject unsafe transitions, **no writes to `trades`/`products`/`portfolio`/`notes`**, **no materialization into THUS trades**. Each `create` is immediately followed (same transaction) by `revoke execute … from public, anon, authenticated` then `grant execute … to authenticated` — closing any transient PUBLIC-execute default.

### 7.1 `mt5_confirm_group` — confirm-first grouping (concurrency-safe)
```sql
create function public.mt5_confirm_group(
  p_leg_ids   uuid[],
  p_prenote   text default null,
  p_thesis    text default null,
  p_plan      text default null,
  p_allow_mixed boolean default false
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_group_id uuid;
  v_n int := coalesce(array_length(p_leg_ids,1),0);
  v_ok int; v_accts int; v_keys int; v_upd int;
  v_acct text; v_sym text; v_cls text; v_side text; v_key text;
  v_legcount int; v_totvol numeric; v_wavg numeric; v_start timestamptz; v_end timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if v_n = 0 then raise exception 'no legs provided'; end if;

  -- (concurrency) lock all OWNED candidate legs; a concurrent grouping of the same legs blocks here
  perform 1 from public.mt5_import_staging s
    where s.id = any(p_leg_ids) and s.user_id = v_uid for update;

  -- re-check eligibility UNDER the lock (a racing committed group would drop this count)
  select count(*) into v_ok from public.mt5_import_staging s
    where s.id = any(p_leg_ids) and s.user_id = v_uid
      and s.kind='open' and s.state in ('new','group_suggested') and s.confirmed_group_id is null;
  if v_ok <> v_n then raise exception 'legs not all owned/open/ungrouped (% eligible of %)', v_ok, v_n; end if;

  select count(distinct s.source_account) into v_accts from public.mt5_import_staging s
    where s.id = any(p_leg_ids) and s.user_id = v_uid;
  if v_accts <> 1 then raise exception 'legs span multiple accounts'; end if;

  if not p_allow_mixed then
    select count(distinct (s.normalized_symbol, s.instrument_class, s.side)) into v_keys
      from public.mt5_import_staging s where s.id = any(p_leg_ids) and s.user_id = v_uid;
    if v_keys <> 1 then raise exception 'mixed symbol/class/side — pass p_allow_mixed to override'; end if;
  end if;

  select max(s.source_account), max(s.normalized_symbol), max(s.instrument_class), max(s.side), max(s.import_group_key),
         count(*), sum(s.volume),
         case when sum(s.volume) > 0 then sum(s.price*s.volume)/sum(s.volume) else null end,
         min(coalesce(s.open_time,s.mt5_time)), max(coalesce(s.open_time,s.mt5_time))
    into v_acct,v_sym,v_cls,v_side,v_key,v_legcount,v_totvol,v_wavg,v_start,v_end
    from public.mt5_import_staging s where s.id = any(p_leg_ids) and s.user_id = v_uid;

  insert into public.mt5_import_groups
    (user_id, source_account, normalized_symbol, instrument_class, side, state,
     prenote, thesis, plan, suggested_start_time, suggested_end_time,
     leg_count, total_volume, weighted_avg_price, import_group_key)
  values
    (v_uid, v_acct, v_sym, v_cls, v_side, 'grouped',
     p_prenote, p_thesis, p_plan, v_start, v_end,
     v_legcount, v_totvol, v_wavg, v_key)
  returning id into v_group_id;

  -- atomic guarded update; affected count MUST equal expected, else abort (rolls back the inserted group → no orphan)
  update public.mt5_import_staging
    set confirmed_group_id = v_group_id, state='grouped', updated_at=now()
   where id = any(p_leg_ids) and user_id = v_uid
     and kind='open' and state in ('new','group_suggested') and confirmed_group_id is null;
  get diagnostics v_upd = row_count;
  if v_upd <> v_n then
    raise exception 'concurrent modification: updated % of % legs — aborting (group rolled back)', v_upd, v_n;
  end if;

  return v_group_id;
end; $$;
revoke execute on function public.mt5_confirm_group(uuid[],text,text,text,boolean) from public, anon, authenticated;
grant  execute on function public.mt5_confirm_group(uuid[],text,text,text,boolean) to authenticated;
```

### 7.2 `mt5_set_leg_state` — controlled transitions; dismiss ONLY ungrouped legs
```sql
create function public.mt5_set_leg_state(p_leg_ids uuid[], p_new_state text)
returns int language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_rows int := 0;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_new_state = 'materialized' then raise exception 'use mt5_mark_materialized for materialization'; end if;
  if p_new_state = 'grouped'      then raise exception 'use mt5_confirm_group for grouping'; end if;
  if p_new_state not in ('dismissed','new','group_suggested') then
    raise exception 'unsupported target state: %', p_new_state;
  end if;

  if p_new_state = 'dismissed' then
    -- v0: only UNGROUPED/UNCONFIRMED legs may be dismissed here. Grouped/materialized legs are NOT
    -- dismissible via this RPC (ungroup/edit-group is deferred — see §12).
    update public.mt5_import_staging set state='dismissed', dismissed_at=now(), updated_at=now()
     where id = any(p_leg_ids) and user_id=v_uid
       and confirmed_group_id is null and state in ('new','group_suggested','needs_mapping');
  elsif p_new_state = 'new' then
    update public.mt5_import_staging set state='new', updated_at=now()
     where id = any(p_leg_ids) and user_id=v_uid
       and confirmed_group_id is null and state in ('needs_mapping','group_suggested');
  elsif p_new_state = 'group_suggested' then
    update public.mt5_import_staging set state='group_suggested', updated_at=now()
     where id = any(p_leg_ids) and user_id=v_uid
       and confirmed_group_id is null and state='new';
  end if;

  get diagnostics v_rows = row_count;
  return v_rows;   -- caller compares to expected; 0 = nothing eligible (e.g. tried to dismiss a grouped leg)
end; $$;
revoke execute on function public.mt5_set_leg_state(uuid[],text) from public, anon, authenticated;
grant  execute on function public.mt5_set_leg_state(uuid[],text) to authenticated;
```

### 7.3 `mt5_mark_materialized` — lifecycle flip AFTER browser durably wrote the THUS draft (strict + tripwire)
```sql
create function public.mt5_mark_materialized(
  p_group_id uuid,
  p_trade_id text,
  p_product_id text,
  p_product_contract_size numeric,
  p_product_class text
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_grp int; v_total int; v_grouped int; v_foreign int; v_nullcs int; v_bad int;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_trade_id is null or length(trim(p_trade_id))=0 then
    raise exception 'missing trade_id — materialize the THUS draft via the durable single-row path FIRST';
  end if;
  if p_product_contract_size is null then raise exception 'missing product_contract_size'; end if;

  -- lock + verify the group is owned and still 'grouped'
  perform 1 from public.mt5_import_groups g where g.id=p_group_id and g.user_id=v_uid for update;
  select count(*) into v_grp from public.mt5_import_groups g
    where g.id=p_group_id and g.user_id=v_uid and g.state='grouped';
  if v_grp <> 1 then raise exception 'group not owned, or not in grouped state'; end if;

  -- lock the group's legs (serialize concurrent materialize calls)
  perform 1 from public.mt5_import_staging s where s.confirmed_group_id=p_group_id and s.user_id=v_uid for update;

  -- ownership: no leg of this group may belong to another user (FK does not enforce ownership)
  select count(*) into v_foreign from public.mt5_import_staging s
    where s.confirmed_group_id=p_group_id and s.user_id<>v_uid;
  if v_foreign > 0 then raise exception 'group contains % leg(s) not owned by caller', v_foreign; end if;

  -- require >=1 owned leg and ALL owned legs currently 'grouped' (reject dismissed/non-grouped members)
  select count(*) into v_total   from public.mt5_import_staging s where s.confirmed_group_id=p_group_id and s.user_id=v_uid;
  select count(*) into v_grouped from public.mt5_import_staging s where s.confirmed_group_id=p_group_id and s.user_id=v_uid and s.state='grouped';
  if v_total < 1 then raise exception 'group has no owned legs'; end if;
  if v_grouped <> v_total then raise exception 'group has % non-grouped leg(s) — refusing to materialize', v_total - v_grouped; end if;

  -- TRIPWIRE (mapping safety):
  --  (a) NULL contract_size is NOT materializable → route to needs_mapping.
  --  (b) contract_size must EXACTLY match the chosen product (exact, not tolerance — see note).
  --  (c) a known-specific leg class REQUIRES a matching known product class (cannot be skipped via null/unknown).
  --  product_id_candidate is NOT consulted here.
  select count(*) into v_nullcs from public.mt5_import_staging s
    where s.confirmed_group_id=p_group_id and s.user_id=v_uid and s.contract_size is null;
  if v_nullcs > 0 then
    raise exception '% leg(s) have NULL contract_size — route to needs_mapping; cannot materialize', v_nullcs;
  end if;
  select count(*) into v_bad from public.mt5_import_staging s
    where s.confirmed_group_id=p_group_id and s.user_id=v_uid
      and (
        s.contract_size <> p_product_contract_size
        or (s.instrument_class is not null and s.instrument_class <> 'unknown'
            and (p_product_class is null or p_product_class = 'unknown' or p_product_class <> s.instrument_class))
      );
  if v_bad > 0 then
    raise exception 'mapping tripwire: % incompatible leg(s) (contract_size/class) — refusing (e.g. DELTAU26 csize 1000 vs DELTA-stock csize 1)', v_bad;
  end if;

  -- flip lifecycle ONLY (no write to trades/products/portfolio/notes). Browser already wrote the THUS draft.
  update public.mt5_import_groups
    set state='materialized', materialized_trade_id=p_trade_id, materialized_product_id=p_product_id,
        materialized_at=now(), updated_at=now()
   where id=p_group_id and user_id=v_uid;
  update public.mt5_import_staging
    set state='materialized', materialized_trade_id=p_trade_id, materialized_at=now(), updated_at=now()
   where confirmed_group_id=p_group_id and user_id=v_uid;
end; $$;
revoke execute on function public.mt5_mark_materialized(uuid,text,text,numeric,text) from public, anon, authenticated;
grant  execute on function public.mt5_mark_materialized(uuid,text,text,numeric,text) to authenticated;
```
> **contract_size = exact match (rationale):** MT5 `trade_contract_size` is a fixed per-symbol constant (e.g. SSF `DELTAU26` = 1000, index futures, etc.), not a fractional/variable quantity, so exact equality is the correct, safest guard and trivially catches the 1000×/1× class confusion. If a broker is ever observed reporting a variant size for the same instrument, revisit with an explicit tolerance — **do not** loosen pre-emptively.

```sql
commit;   -- ⬅ END of the single apply transaction. If anything above errored, run `rollback;` and STOP.
```

### 7.4 `mt5_resolve_mapping` — **DEFERRED (not in this packet)**
Removed from Phase 0A to avoid a misleading partial RPC. Mapping authority stays in the **materialize-time tripwire** (§7.3). Re-routing `needs_mapping → new` (and any candidate-hint write) will be designed in a later slice that **re-runs** the compatibility check at write time. Until then, the reader sets `state='needs_mapping'` for unmapped futures and a human resolves mapping out-of-band.

---

## 8. Post-apply verification (run AFTER a clean `commit;`; SELECT-only)
```sql
-- tables (3) + RLS enabled
select tablename from pg_tables where schemaname='public' and tablename like 'mt5_import_%' order by 1;     -- expect 3
select relname, relrowsecurity from pg_class
  where relname in ('mt5_import_staging','mt5_import_groups','mt5_import_cursors');                          -- rowsecurity=t

-- policies = exactly SELECT-own (NO write policy)
select tablename, policyname, cmd, roles from pg_policies
  where schemaname='public' and tablename like 'mt5_import_%' order by 1,2;                                  -- only cmd=SELECT, {authenticated}
select count(*) as write_policies from pg_policies
  where schemaname='public' and tablename like 'mt5_import_%' and cmd <> 'SELECT';                           -- expect 0

-- table grants: NO write grants to anon/authenticated; NO anon grants at all
select table_name, grantee, privilege_type from information_schema.role_table_grants
  where table_schema='public' and table_name like 'mt5_import_%' order by 1,2,3;
select count(*) as browser_write_grants from information_schema.role_table_grants
  where table_schema='public' and table_name like 'mt5_import_%'
    and grantee in ('anon','authenticated') and privilege_type in ('INSERT','UPDATE','DELETE');             -- expect 0
select count(*) as anon_grants from information_schema.role_table_grants
  where table_schema='public' and table_name like 'mt5_import_%' and grantee='anon';                        -- expect 0

-- service_role write capability (r3): explicit grant must have landed (reader/0C depends on it)
select count(*) as svc_staging_write from information_schema.role_table_grants
  where table_schema='public' and table_name='mt5_import_staging'
    and grantee='service_role' and privilege_type in ('INSERT','UPDATE');                                   -- expect 2
select count(*) as svc_cursors_write from information_schema.role_table_grants
  where table_schema='public' and table_name='mt5_import_cursors'
    and grantee='service_role' and privilege_type in ('INSERT','UPDATE');                                   -- expect 2

-- RPCs present + SECURITY DEFINER
select proname, prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and proname like 'mt5_%' order by 1;                                              -- 3 RPCs (secdef=t) + mt5_set_updated_at
-- (a) the 3 RPCs: EXECUTE granted to authenticated (and only authenticated — no anon/PUBLIC)
select routine_name, grantee, privilege_type from information_schema.role_routine_grants
  where routine_schema='public'
    and routine_name in ('mt5_confirm_group','mt5_set_leg_state','mt5_mark_materialized')
  order by 1,2;                                                                                              -- each → grantee=authenticated
select count(*) as rpc_authenticated_exec from information_schema.role_routine_grants
  where routine_schema='public'
    and routine_name in ('mt5_confirm_group','mt5_set_leg_state','mt5_mark_materialized')
    and grantee='authenticated' and privilege_type='EXECUTE';                                               -- expect 3
-- (b) helper trigger fn mt5_set_updated_at(): ZERO browser execute (no anon/authenticated/PUBLIC)
select count(*) as helper_browser_exec from information_schema.role_routine_grants
  where routine_schema='public' and routine_name='mt5_set_updated_at'
    and grantee in ('anon','authenticated','PUBLIC');                                                       -- expect 0

-- no existing THUS table gained mt5 columns (create-only proof)
select table_name from information_schema.columns
  where table_schema='public' and column_name like 'mt5\_%'
    and table_name in ('trades','products','portfolio_summary','trade_groups');                              -- expect 0
```

## 9. Two-account RLS spot-check plan (later; checklist — no real run in this slice)
- [ ] `service_role` seeds a staging row owned by A → A (authenticated) `select` sees it; B sees **none** of A's rows.
- [ ] B calls `mt5_confirm_group(A_leg_ids,…)` → in-RPC ownership filter yields 0 eligible → **exception**, no change.
- [ ] A calls `mt5_set_leg_state(A_ungrouped_leg,'dismissed')` → succeeds; A calls it on a **grouped** leg → 0 rows (not dismissible).
- [ ] `mt5_mark_materialized` on a group whose leg `contract_size=1000` with `p_product_contract_size=1` → **tripwire exception**; with a NULL-csize leg → **null-csize exception**.
- [ ] Neither A nor B can `insert/update/delete` staging/groups directly (no policy/grant) → permission denied; neither can `select` cursors.

## 10. Rollback (new `mt5_import_*` / `mt5_*` objects ONLY; no existing table touched)
```sql
drop function if exists public.mt5_mark_materialized(uuid,text,text,numeric,text);
drop function if exists public.mt5_set_leg_state(uuid[],text);
drop function if exists public.mt5_confirm_group(uuid[],text,text,text,boolean);
drop table if exists public.mt5_import_staging;   -- indexes/policies/triggers drop with it (FK → groups)
drop table if exists public.mt5_import_cursors;
drop table if exists public.mt5_import_groups;
drop function if exists public.mt5_set_updated_at();
```
> `if exists` is acceptable in the **rollback** path (idempotent teardown of partial state); the **apply** path is strictly fail-closed (plain `CREATE`). No `trades`/`products`/`portfolio`/`notes`/`trade_groups` object is created/altered/dropped.

## 11. STOP conditions
### 11.1 Apply gating
- No apply without **explicit user GO** + **fresh Codex pass** + **Supabase SQL review** + **clean §3 pre-check**. *(As of r3: Codex re-review = PASS and Supabase SQL review = PASS / READY_FOR_CONFLICT_PRECHECK are satisfied; the remaining gates are the explicit user GO and a clean §3 pre-check at apply time.)*
- Apply runs as **one transaction**; any error → `rollback;` → **STOP**. **No partial apply.**
- **Create-only**, fail-closed: plain `CREATE` (no `or replace`/`if not exists`); no `ALTER`/`DROP` of existing objects.
- **No browser write grants/policies** on `mt5_import_*`; **no `service_role`** in client/browser/Netlify.
- **No writes to `trades`/`products`/`portfolio`/`notes`**; **no materialization** into THUS trades in Phase 0A.
- **No Product/Symbol/DELTA runtime edits**; **no GUGU boundary violation**; **no base64 screenshots**; **no hard dependency on `trade_groups`/G2** (preserve `mt5_import_groups.id`).

### 11.2 Staging-vs-prod apply (reconciled — was a drift vs r3)
- r3 originally preferred **staging/branch Supabase first**. The project has **no separate staging Supabase**.
- Therefore: a **create-only apply to prod** is a **user-ratified decision, NOT the default** (precedent: P2-5-A applied new create-only objects to prod after a clean conflict pre-check).
- With no staging, require **extra caution**: clean §3 pre-check, single-transaction apply, §10 rollback ready before starting, and §8 verification immediately after.

### 11.3 Idempotency STOP / reader invariant
- The partial-unique indexes protect only rows **with** their key. **`balance` rows with NULL `deal_id`, `open` rows with NULL `position_id`, and `close`/`partial` rows with NULL `deal_id` are NOT dedup-protected and CAN duplicate.**
- **Reader invariant (STOP):** the reader MUST NOT blind-insert a position/deal row missing its stable key (`open`→`position_id`, `close`/`partial`→`deal_id`). Such rows are either skipped, quarantined (`state='needs_mapping'`/`error_message`), or deduped reader-side (e.g. content hash) — never repeatedly inserted. This is **accepted fail-open** at the DB layer with the dedupe responsibility on the reader.

## 12. Open questions / deferred decisions
- **Product-mapping foundation** + **DELTA-SSF preset** — gate **Phase 1 materialization**, not this schema. Deferred.
- **`mt5_resolve_mapping`** — deferred (§7.4); design a check-on-write version later.
- **Ungroup / edit-group** — no RPC in v0; grouped legs are immutable except via materialize. Deferred.
- **Soft CHECK vs fail-open** on `kind`/`state`/`position_state`/`instrument_class` — kept fail-open; revisit soft documented CHECKs once value sets stabilize.
- **0C staging writer** (service_role) + **0D Inbox UI** (read-only) — after schema reviewed + applied.
- **MT5 probe refresh** — optional; promote scratch probe to a tracked read-only `ops/` script if wanted.
- **Cursors browser SELECT** — intentionally **none** in r2 (reader-internal); add a SELECT-own policy + grant later only if a UI needs cursor state.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Phase 0A packet r3 folds in the Supabase SQL-review optional polish (Codex re-review = PASS; Supabase SQL review = PASS / READY_FOR_CONFLICT_PRECHECK). It is still NOT applied.
Next action: Prepare a user-run §3 conflict pre-check prompt. Apply remains separate and hard-gated behind an explicit user GO after the pre-check returns clean, executed as a single transaction.
