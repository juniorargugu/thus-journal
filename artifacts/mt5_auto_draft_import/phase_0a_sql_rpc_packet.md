# MT5 Auto Draft Import — Phase 0A SQL/RPC Implementation Packet

> ## ⛔ `GATED — REVIEW ONLY — NOT APPLIED`
> - **Target baseline:** `09842d7` (prod). **Nothing in this file has been run.** No Supabase write, no migration, no apply.
> - **Apply requires ALL of:** explicit user GO **+** a fresh **Codex** pass **+** a **Supabase SQL review** **+** a clean conflict pre-check (§3).
> - This artifact translates the approved [`phase_0a_r3_design_plan.md`](phase_0a_r3_design_plan.md) (§4–6) into concrete, reviewable SQL. It is **docs-only**. It is **create-only** (no `ALTER`/`DROP` of any existing object).
> - Project: `wtfwynvvkiuottjnmozu`. There is **no separate staging Supabase** — the "staging vs prod create-only" decision is deferred to review (§12).

**Artifact date:** 2026-06-25 · **Type:** SQL/RPC packet (docs-only, gated)

---

## 1. Status
- Design lineage: 0A → 0B probe → 0A-r2 → Codex `PASS_WITH_CHANGES` → 0A-r3 → final ChatGPT pass → **this packet** (concrete SQL).
- Blocker note: the original parking blocker (P2 full-array `saveTrades` cleanup) is **cleared** (P2-4C shipped; prod `09842d7`). The remaining design blockers (product-mapping foundation, DELTA-SSF product decision) gate **materialization (Phase 1)**, **not** this schema gate.
- This packet is **not** applied, **not** a runnable migration in `migrations/`. It lives under `artifacts/` for review.

## 2. Scope / non-scope
**In scope (this packet authors, does NOT run):** DDL for 3 new tables (`mt5_import_staging`, `mt5_import_groups`, `mt5_import_cursors`), their indexes/partial-unique idempotency, `updated_at` triggers, RLS (browser SELECT-own only), minimal grants, and 4 `SECURITY DEFINER` RPC bodies.

**Out of scope (NOT in this slice):** applying any SQL; the Python reader/probe/writer (0C); the Inbox UI (0D); trade **materialization** into THUS `trades` (Phase 1); close/partial drafts (Phase 2); screenshots (Phase 3); the product-mapping foundation; the DELTA-SSF product decision; any `index.html`/runtime change; any Product/Symbol/DELTA/GUGU/Storage touch.

---

## 3. Conflict pre-check SQL (run FIRST, read-only; must return empty/zero before any apply)
```sql
-- (a) No existing mt5_import_* tables
select tablename from pg_tables
where schemaname='public' and tablename like 'mt5_import_%';                 -- expect: 0 rows

-- (b) No existing mt5_* functions/RPCs
select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname like 'mt5_%';                          -- expect: 0 rows

-- (c) No existing mt5_import_* policies
select policyname, tablename from pg_policies
where schemaname='public' and tablename like 'mt5_import_%';                  -- expect: 0 rows

-- (d) No existing mt5_import_* indexes / triggers
select indexname from pg_indexes where schemaname='public' and tablename like 'mt5_import_%';  -- expect: 0
select tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid
where c.relname like 'mt5_import_%' and not t.tgisinternal;                   -- expect: 0
```
**STOP if any of (a)–(d) returns rows** — investigate before applying (this packet assumes create-only on a clean namespace).

---

## 4. DDL — tables, indexes, triggers (create-only)

### 4.0 Shared `updated_at` trigger function
```sql
create or replace function public.mt5_set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
```

### 4.1 `mt5_import_groups` (created first — `mt5_import_staging` FKs to it)
```sql
create table if not exists public.mt5_import_groups (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  source_account      text not null,
  normalized_symbol   text,
  instrument_class    text default 'unknown',   -- fail-open: no rejecting CHECK
  side                text,
  state               text not null default 'grouped',  -- grouped | materialized | dismissed (RPC-controlled; no rejecting CHECK)
  prenote             text,
  thesis              text,
  plan                text,
  suggested_start_time timestamptz,   -- server-computed in mt5_confirm_group
  suggested_end_time   timestamptz,
  leg_count            int,
  total_volume         numeric,
  weighted_avg_price   numeric,
  import_group_key     text,
  materialized_trade_id text,         -- loose ref to a THUS trade id (string); NOT an FK to trades (decoupled)
  materialized_at      timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists mt5_groups_user_acct on public.mt5_import_groups (user_id, source_account);
create index if not exists mt5_groups_user_state on public.mt5_import_groups (user_id, state);
create trigger mt5_groups_updated_at before update on public.mt5_import_groups
  for each row execute function public.mt5_set_updated_at();
```

### 4.2 `mt5_import_staging`
```sql
create table if not exists public.mt5_import_staging (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  source_account      text not null,
  kind                text not null default 'unknown',   -- open|close|partial|balance|unknown (fail-open; no rejecting CHECK)
  -- symbol / instrument (mapping safety: store EVERYTHING raw)
  symbol_raw          text,
  normalized_symbol   text,
  instrument_path     text,
  instrument_class    text default 'unknown',             -- fail-open
  contract_size       numeric,                            -- e.g. DELTAU26 SSF = 1000  (tripwire input)
  digits              int,
  product_id_candidate text,                              -- HINT ONLY; never authoritative (tripwire ignores it)
  -- leg facts
  side                text,                               -- buy|sell (raw)
  volume              numeric,
  price               numeric,
  -- times: store true UTC + retain raw (MT5 = Asia/Bangkok wall-clock per probe)
  open_time           timestamptz,                        -- true UTC
  close_time          timestamptz,                        -- true UTC
  mt5_time            timestamptz,                        -- true UTC of the deal/position
  mt5_time_msc        bigint,                             -- raw epoch ms (lossless)
  mt5_time_raw_epoch  bigint,                             -- raw epoch seconds AS MT5 RETURNED (pre +7 correction)
  server_tz           text,                               -- e.g. 'Asia/Bangkok' / offset
  -- broker ids
  position_id         bigint,
  deal_id             bigint,
  order_id            bigint,
  ticket              bigint,
  external_id         text,
  -- money
  commission          numeric,
  swap                numeric,
  fee                 numeric,
  broker_profit       numeric,
  -- open-row lifecycle
  position_state      text default 'open',                -- open|closed|gone (fail-open)
  first_seen_open_at  timestamptz,
  last_seen_open_at   timestamptz,
  -- leg state machine (RPC-controlled): new|group_suggested|grouped|needs_mapping|materialized|dismissed
  state               text not null default 'new',
  import_group_key    text,
  confirmed_group_id  uuid references public.mt5_import_groups(id) on delete set null,  -- ownership enforced in RPC, NOT trusted to FK/RLS
  materialized_trade_id text,                             -- loose ref to THUS trade id (string); NOT FK
  materialized_at     timestamptz,
  dismissed_at        timestamptz,
  error_message       text,
  screenshot_url      text,                               -- Phase 3; URL/path ONLY, never base64
  raw                 jsonb,                              -- full raw MT5 record
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Idempotency (partial unique): reader can re-run safely
create unique index if not exists mt5_staging_open_uniq
  on public.mt5_import_staging (user_id, source_account, position_id)
  where kind='open' and position_id is not null;
create unique index if not exists mt5_staging_deal_uniq
  on public.mt5_import_staging (user_id, source_account, deal_id)
  where deal_id is not null and kind in ('close','partial');
create unique index if not exists mt5_staging_balance_uniq
  on public.mt5_import_staging (user_id, source_account, deal_id)
  where kind='balance' and deal_id is not null;

-- Query indexes
create index if not exists mt5_staging_user_acct on public.mt5_import_staging (user_id, source_account);
create index if not exists mt5_staging_user_state on public.mt5_import_staging (user_id, state);
create index if not exists mt5_staging_group on public.mt5_import_staging (confirmed_group_id);
create index if not exists mt5_staging_open_live on public.mt5_import_staging (user_id, position_state) where kind='open';
create index if not exists mt5_staging_created on public.mt5_import_staging (created_at);

create trigger mt5_staging_updated_at before update on public.mt5_import_staging
  for each row execute function public.mt5_set_updated_at();
```

### 4.3 `mt5_import_cursors`
```sql
create table if not exists public.mt5_import_cursors (
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

## 5. RLS — enable + browser SELECT-own ONLY (no browser writes)
```sql
alter table public.mt5_import_staging enable row level security;
alter table public.mt5_import_groups  enable row level security;
alter table public.mt5_import_cursors enable row level security;

-- Browser may read only its own rows. (select auth.uid()) is the per-row owner check.
drop policy if exists "mt5_import_staging select own" on public.mt5_import_staging;
create policy "mt5_import_staging select own" on public.mt5_import_staging
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "mt5_import_groups select own" on public.mt5_import_groups;
create policy "mt5_import_groups select own" on public.mt5_import_groups
  for select to authenticated using (user_id = (select auth.uid()));

-- cursors: reader-internal. SELECT-own is OPTIONAL (browser doesn't need it). Included for symmetry; drop if undesired.
drop policy if exists "mt5_import_cursors select own" on public.mt5_import_cursors;
create policy "mt5_import_cursors select own" on public.mt5_import_cursors
  for select to authenticated using (user_id = (select auth.uid()));
```
- **No INSERT/UPDATE/DELETE policies for `authenticated`** → the browser cannot write these tables directly. User-initiated lifecycle changes go **only** through the SECURITY DEFINER RPCs (§7). The Python reader writes via `service_role` (bypasses RLS).

## 6. Grants — minimal
```sql
-- Lock down, then grant only browser SELECT. service_role bypasses RLS and needs no explicit grant here.
revoke all on public.mt5_import_staging from anon;
revoke all on public.mt5_import_groups  from anon;
revoke all on public.mt5_import_cursors from anon;
grant select on public.mt5_import_staging to authenticated;
grant select on public.mt5_import_groups  to authenticated;
-- cursors: NO authenticated grant by default (reader-only). Grant select only if the optional policy above is kept AND a UI needs it.
```
- `anon` gets nothing. `authenticated` gets SELECT (RLS-scoped to own rows) on staging/groups. No write grants. `service_role` (reader, local/admin only) is never shipped to browser/client/Netlify.

---

## 7. RPC definitions (proposed full bodies — `SECURITY DEFINER`, ownership inside, `search_path=''`)

> All RPCs: `security definer`, `set search_path = ''` (every object fully schema-qualified; `auth.uid()` qualified), `auth.uid()` ownership enforced **inside** the body (never trusted to FK/RLS), reject unsafe transitions, **no writes to `trades`/`products`/`portfolio`/`notes`**, **no materialization into THUS trades**.

### 7.1 `mt5_confirm_group` — confirm-first grouping of open legs into one idea
```sql
create or replace function public.mt5_confirm_group(
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
  v_ok int; v_accts int; v_keys int;
  v_acct text; v_sym text; v_cls text; v_side text; v_key text;
  v_legcount int; v_totvol numeric; v_wavg numeric; v_start timestamptz; v_end timestamptz;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if v_n = 0 then raise exception 'no legs provided'; end if;

  -- every leg must be owned, kind=open, groupable (new|group_suggested), and ungrouped
  select count(*) into v_ok from public.mt5_import_staging s
   where s.id = any(p_leg_ids) and s.user_id = v_uid
     and s.kind = 'open' and s.state in ('new','group_suggested') and s.confirmed_group_id is null;
  if v_ok <> v_n then
    raise exception 'legs not all owned/open/ungroupable (% eligible of %)', v_ok, v_n;
  end if;

  -- single source_account
  select count(distinct s.source_account) into v_accts from public.mt5_import_staging s
   where s.id = any(p_leg_ids) and s.user_id = v_uid;
  if v_accts <> 1 then raise exception 'legs span multiple accounts'; end if;

  -- single (symbol,class,side) unless explicitly allowed
  if not p_allow_mixed then
    select count(distinct (s.normalized_symbol, s.instrument_class, s.side)) into v_keys
      from public.mt5_import_staging s where s.id = any(p_leg_ids) and s.user_id = v_uid;
    if v_keys <> 1 then raise exception 'mixed symbol/class/side — pass p_allow_mixed to override'; end if;
  end if;

  -- representative fields + server-side aggregates
  select max(s.source_account), max(s.normalized_symbol), max(s.instrument_class), max(s.side), max(s.import_group_key),
         count(*), sum(s.volume),
         case when sum(s.volume) > 0 then sum(s.price * s.volume)/sum(s.volume) else null end,
         min(coalesce(s.open_time, s.mt5_time)), max(coalesce(s.open_time, s.mt5_time))
    into v_acct, v_sym, v_cls, v_side, v_key, v_legcount, v_totvol, v_wavg, v_start, v_end
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

  update public.mt5_import_staging
     set confirmed_group_id = v_group_id, state = 'grouped', updated_at = now()
   where id = any(p_leg_ids) and user_id = v_uid;

  return v_group_id;
end; $$;
```

### 7.2 `mt5_set_leg_state` — controlled leg transitions (NO →materialized, NO →grouped here)
```sql
create or replace function public.mt5_set_leg_state(p_leg_ids uuid[], p_new_state text)
returns int language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_rows int := 0;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_new_state = 'materialized' then raise exception 'use mt5_mark_materialized for materialization'; end if;
  if p_new_state = 'grouped'      then raise exception 'use mt5_confirm_group for grouping'; end if;
  if p_new_state not in ('dismissed','new','group_suggested') then
    raise exception 'unsupported target state: %', p_new_state;
  end if;

  if p_new_state = 'dismissed' then                 -- from any non-materialized state
    update public.mt5_import_staging set state='dismissed', dismissed_at=now(), updated_at=now()
     where id = any(p_leg_ids) and user_id=v_uid and state <> 'materialized';
  elsif p_new_state = 'new' then                    -- needs_mapping → new, or group_suggested → new
    update public.mt5_import_staging set state='new', updated_at=now()
     where id = any(p_leg_ids) and user_id=v_uid and state in ('needs_mapping','group_suggested');
  elsif p_new_state = 'group_suggested' then        -- new → group_suggested
    update public.mt5_import_staging set state='group_suggested', updated_at=now()
     where id = any(p_leg_ids) and user_id=v_uid and state='new';
  end if;

  get diagnostics v_rows = row_count;
  return v_rows;
end; $$;
```

### 7.3 `mt5_mark_materialized` — flip lifecycle AFTER the browser durably wrote the THUS draft (tripwire enforced)
```sql
create or replace function public.mt5_mark_materialized(
  p_group_id uuid,
  p_trade_id text,
  p_product_id text,
  p_product_contract_size numeric,
  p_product_class text
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_grp int; v_bad int;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_trade_id is null or length(p_trade_id) = 0 then
    raise exception 'missing trade_id — materialize the THUS draft via the durable single-row path FIRST';
  end if;
  if p_product_contract_size is null then raise exception 'missing product_contract_size'; end if;

  -- group must be owned and still in 'grouped'
  select count(*) into v_grp from public.mt5_import_groups g
   where g.id = p_group_id and g.user_id = v_uid and g.state = 'grouped';
  if v_grp <> 1 then raise exception 'group not owned, or not in grouped state'; end if;

  -- TRIPWIRE: every leg's contract_size MUST equal the chosen product's contract_size (exact).
  -- If both classes are known+specific they must match too. product_id_candidate is NOT trusted here.
  -- This is what stops DELTAU26 (csize 1000) from materializing against DELTA stock (csize 1) = 1000x P/L error.
  select count(*) into v_bad from public.mt5_import_staging s
   where s.confirmed_group_id = p_group_id and s.user_id = v_uid
     and (
       (s.contract_size is not null and s.contract_size <> p_product_contract_size)
       or (p_product_class is not null and p_product_class <> 'unknown'
           and s.instrument_class is not null and s.instrument_class <> 'unknown'
           and s.instrument_class <> p_product_class)
     );
  if v_bad > 0 then
    raise exception 'mapping tripwire: % incompatible leg(s) (contract_size/class) — refusing to materialize', v_bad;
  end if;

  update public.mt5_import_groups
     set state='materialized', materialized_trade_id=p_trade_id, materialized_at=now(), updated_at=now()
   where id = p_group_id and user_id = v_uid;

  update public.mt5_import_staging
     set state='materialized', materialized_trade_id=p_trade_id, materialized_at=now(), updated_at=now()
   where confirmed_group_id = p_group_id and user_id = v_uid;
  -- NOTE: does NOT write to trades. The browser wrote the THUS draft first (Phase 1, durable commitOpen) and passed p_trade_id.
end; $$;
```

### 7.4 `mt5_resolve_mapping` (optional) — needs_mapping → new with a candidate hint
```sql
create or replace function public.mt5_resolve_mapping(p_leg_ids uuid[], p_product_id text)
returns int language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_rows int := 0;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  update public.mt5_import_staging
     set product_id_candidate = p_product_id, state = 'new', updated_at = now()
   where id = any(p_leg_ids) and user_id = v_uid and state = 'needs_mapping';
  get diagnostics v_rows = row_count;
  return v_rows;   -- product_id_candidate stays a HINT; the real check is the materialize-time tripwire (7.3)
end; $$;
```

### 7.5 RPC grants
```sql
revoke all on function public.mt5_confirm_group(uuid[],text,text,text,boolean) from public, anon;
revoke all on function public.mt5_set_leg_state(uuid[],text)                   from public, anon;
revoke all on function public.mt5_mark_materialized(uuid,text,text,numeric,text) from public, anon;
revoke all on function public.mt5_resolve_mapping(uuid[],text)                 from public, anon;
grant execute on function public.mt5_confirm_group(uuid[],text,text,text,boolean) to authenticated;
grant execute on function public.mt5_set_leg_state(uuid[],text)                   to authenticated;
grant execute on function public.mt5_mark_materialized(uuid,text,text,numeric,text) to authenticated;
grant execute on function public.mt5_resolve_mapping(uuid[],text)                 to authenticated;
```

---

## 8. Post-apply verification queries (run AFTER an approved apply; SELECT-only)
```sql
-- tables exist
select tablename from pg_tables where schemaname='public' and tablename like 'mt5_import_%' order by 1;  -- expect 3

-- RLS enabled on all three
select relname, relrowsecurity from pg_class
where relname in ('mt5_import_staging','mt5_import_groups','mt5_import_cursors');                          -- expect rowsecurity=t

-- policies = exactly the SELECT-own set (no write policies)
select tablename, policyname, cmd, roles from pg_policies
where schemaname='public' and tablename like 'mt5_import_%' order by 1,2;                                  -- expect only SELECT/authenticated

-- RPCs present
select proname, prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and proname like 'mt5_%' order by 1;                                              -- expect 4 RPCs + mt5_set_updated_at, prosecdef=t for RPCs

-- grants: no anon; authenticated has SELECT only (no INSERT/UPDATE/DELETE) on staging/groups
select table_name, grantee, privilege_type from information_schema.role_table_grants
where table_schema='public' and table_name like 'mt5_import_%' order by 1,2,3;

-- routine grants: execute = authenticated only
select routine_name, grantee, privilege_type from information_schema.role_routine_grants
where routine_schema='public' and routine_name like 'mt5_%' order by 1,2;

-- no existing THUS tables changed (implied by create-only + clean §3 pre-check; spot-check none of these gained mt5 columns)
select table_name from information_schema.columns
where table_schema='public' and column_name like 'mt5\_%' and table_name in ('trades','products','portfolio_summary','trade_groups');  -- expect 0
```

## 9. Two-account RLS spot-check plan (later; checklist — no real run in this slice)
Using two test auth users A and B and `service_role` to seed (browser can't write):
- [ ] `service_role` inserts a staging row owned by A → A (authenticated) `select` sees it; B (authenticated) `select` sees **none** of A's rows.
- [ ] B calls `mt5_confirm_group(A_leg_ids,…)` → ownership check fails inside the RPC (`auth.uid()` ≠ owner) → 0 legs eligible → **exception**, no rows changed.
- [ ] A calls `mt5_set_leg_state(A_leg_ids,'dismissed')` → succeeds for A's own legs only.
- [ ] `mt5_mark_materialized` with a leg whose `contract_size=1000` against `p_product_contract_size=1` → **tripwire exception** (the DELTAU26-vs-DELTA-stock guard).
- [ ] Neither A nor B can `insert/update/delete` staging/groups directly (no policy/grant) → permission denied.

## 10. Rollback plan (newly-created `mt5_import_*` / `mt5_*` objects ONLY — no existing table touched)
```sql
-- functions
drop function if exists public.mt5_resolve_mapping(uuid[],text);
drop function if exists public.mt5_mark_materialized(uuid,text,text,numeric,text);
drop function if exists public.mt5_set_leg_state(uuid[],text);
drop function if exists public.mt5_confirm_group(uuid[],text,text,text,boolean);
-- tables (indexes/policies/triggers drop with them); staging first (FK → groups)
drop table if exists public.mt5_import_staging;
drop table if exists public.mt5_import_cursors;
drop table if exists public.mt5_import_groups;
-- shared trigger fn last (after its triggers are gone with the tables)
drop function if exists public.mt5_set_updated_at();
```
No `trades`/`products`/`portfolio`/`notes`/`trade_groups` object is created, altered, or dropped.

## 11. STOP conditions (must all hold before any apply)
- No apply without **explicit user GO** + **fresh Codex pass** + **Supabase SQL review**.
- Conflict pre-check (§3) returns **clean**; **create-only** (no `ALTER`/`DROP` of existing objects).
- **No browser write grants/policies** on `mt5_import_*`.
- **No `service_role`** in client/browser/Netlify.
- **No writes to `trades`/`products`/`portfolio`/`notes`**; **no materialization** into THUS trades in Phase 0A.
- **No Product/Symbol/DELTA runtime edits**.
- **No `DELTAU26` → DELTA-stock silent mapping** (tripwire in `mt5_mark_materialized` must fire).
- **No base64 screenshots** (URL/path only, Phase 3).
- **No GUGU boundary violation** (the reader is a separate input-only role).
- **No hard dependency on `trade_groups`/G2** (preserve `mt5_import_groups.id` for future migration).

## 12. Open questions / deferred decisions
- **Product-mapping foundation** (class-aware resolver for futures/SSF/stocks) — needed for **Phase 1 materialization**, not for this schema. Deferred.
- **DELTA-SSF product preset decision** — `DELTAU26` (csize 1000) has no THUS product; until one exists it stays `needs_mapping`. Deferred.
- **Staging-vs-prod apply** — no separate staging Supabase exists; decide whether to apply create-only to prod (P2-5-A precedent: clean conflict pre-check + create-only) or stand up a branch DB. Review decision.
- **MT5 probe refresh** — optional; the 0B findings are recorded. If wanted, promote the scratch probe to a tracked read-only `ops/` script.
- **0C staging writer** (Python reader → staging via service_role) and **0D Inbox UI** (read-only) — after schema is reviewed + applied.
- **Soft CHECKs vs fail-open** — `kind`/`state`/`position_state`/`instrument_class` are stored without rejecting CHECKs (fail-open). Decide later whether to add *soft* documented CHECKs once the value sets stabilize.
- **Contract_size tripwire: exact vs tolerance** — packet uses **exact** equality (safest). Confirm no broker reports fractional/variant csize that needs tolerance.
- **Cursors browser SELECT** — included optionally; drop the policy+grant if no UI reads cursors.

---

## Next step routing

Next step routing: SEND_TO_CHATGPT_REVIEW
Reason: Phase 0A packet is authored but NOT applied; it needs a fresh Codex pass and a Supabase SQL review before any database execution.
Next action: Review this packet, then prepare (1) a Codex review prompt and (2) a Supabase SQL review prompt. Apply stays hard-gated behind explicit user GO + clean conflict pre-check.
