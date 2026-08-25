-- ============================================================================
-- T4A T3 KIND/ACTION FIXTURE VERIFICATION — GENERATED FILE, DO NOT EDIT.
-- Regenerate with: python -X utf8 ops/mt5_import/gen_t4a_fixture_sql.py --write
-- Source fixture : ops/mt5_import/fixtures/t3_kind_fixtures_v1.json
-- Fixture version: t3-kind-fixtures/1
-- fixture_sha256 : 85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355
--   (canonical {version,cases} digest; the sha literal here is audit metadata —
--    structural equality is proven by regeneration + byte comparison in
--    test_t3_kind_fixture.py, never by comparing hash strings.)
--
-- RELEASE CORRECTNESS DOES NOT DEPEND ON THIS FILE. The same fragment is EMBEDDED
-- in T4A_decisions_rpc_packet.sql inside the packet transaction, BEFORE the ledger
-- insert, so parity failure rolls the whole RPC migration back. This standalone
-- copy exists for review and optional post-apply re-verification (it is read-only:
-- it calls the helpers and writes nothing).
-- ============================================================================

-- BEGIN GENERATED T4A T3 PARITY FIXTURE t3-kind-fixtures/1 sha256:85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355
-- Generated from ops/mt5_import/fixtures/t3_kind_fixtures_v1.json — DO NOT EDIT.
-- Regenerate + re-embed with: python -X utf8 ops/mt5_import/gen_t4a_fixture_sql.py --write
-- A valid case failing raises; an invalid case must raise SQLSTATE MT4E1.
do $t4a_fixture$
declare
  v_kind    text;
  v_actions text[];
begin
  -- entry_new
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_new: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_new: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_reappearance
  v_kind := public.mt5_t3_kind_v1(array['REAPPEARANCE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_reappearance: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_reappearance: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_new_increase
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_new_increase: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_new_increase: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_new_decrease
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_new_decrease: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_new_decrease: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_absence_then_reappearance
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'REAPPEARANCE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_absence_then_reappearance: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_absence_then_reappearance: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_change_absence_reappearance
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_DISAPPEARED', 'REAPPEARANCE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_change_absence_reappearance: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_change_absence_reappearance: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_full_life_reentry
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_INCREASE', 'POSITION_DISAPPEARED', 'REAPPEARANCE', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_full_life_reentry: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_full_life_reentry: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- entry_reappearance_changes
  v_kind := public.mt5_t3_kind_v1(array['REAPPEARANCE', 'POSITION_INCREASE', 'POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'ENTRY' then
    raise exception 'T4A FIXTURE entry_reappearance_changes: derived kind %, expected ENTRY', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['journal_add', 'already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE entry_reappearance_changes: allowed actions %, expected %',
      v_actions, array['journal_add', 'already_logged', 'no_record']::text[];
  end if;
  -- change_increase
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_increase: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_increase: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- change_decrease
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_decrease: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_decrease: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- change_mixed
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_DECREASE', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_mixed: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_mixed: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- change_double_decrease
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DECREASE', 'POSITION_DECREASE']::text[]);
  if v_kind is distinct from 'CHANGE' then
    raise exception 'T4A FIXTURE change_double_decrease: derived kind %, expected CHANGE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE change_double_decrease: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_terminal
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_terminal: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_terminal: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_after_new
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_after_new: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_after_new: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_after_increase
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_after_increase: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_after_increase: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_after_reentry
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'REAPPEARANCE', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_after_reentry: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_after_reentry: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- absence_full_entry_life
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_INCREASE', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'ABSENCE' then
    raise exception 'T4A FIXTURE absence_full_entry_life: derived kind %, expected ABSENCE', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['already_logged', 'no_record']::text[] then
    raise exception 'T4A FIXTURE absence_full_entry_life: allowed actions %, expected %',
      v_actions, array['already_logged', 'no_record']::text[];
  end if;
  -- conflict_alone
  v_kind := public.mt5_t3_kind_v1(array['POSITION_IDENTITY_CONFLICT']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_alone: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_alone: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_after_new
  v_kind := public.mt5_t3_kind_v1(array['NEW_POSITION', 'POSITION_IDENTITY_CONFLICT']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_after_new: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_after_new: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_then_disappeared
  v_kind := public.mt5_t3_kind_v1(array['POSITION_IDENTITY_CONFLICT', 'POSITION_DISAPPEARED']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_then_disappeared: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_then_disappeared: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_between_changes
  v_kind := public.mt5_t3_kind_v1(array['POSITION_INCREASE', 'POSITION_IDENTITY_CONFLICT', 'POSITION_INCREASE']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_between_changes: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_between_changes: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- conflict_after_reentry
  v_kind := public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'REAPPEARANCE', 'POSITION_IDENTITY_CONFLICT']::text[]);
  if v_kind is distinct from 'CONFLICT' then
    raise exception 'T4A FIXTURE conflict_after_reentry: derived kind %, expected CONFLICT', v_kind;
  end if;
  v_actions := public.mt5_t3_allowed_actions_v1(v_kind);
  if v_actions is distinct from array['no_record']::text[] then
    raise exception 'T4A FIXTURE conflict_after_reentry: allowed actions %, expected %',
      v_actions, array['no_record']::text[];
  end if;
  -- invalid_empty (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array[]::text[]);
    raise exception 'T4A FIXTURE invalid_empty: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_new_while_present (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NEW_POSITION', 'NEW_POSITION']::text[]);
    raise exception 'T4A FIXTURE invalid_new_while_present: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_reappearance_while_present (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NEW_POSITION', 'REAPPEARANCE']::text[]);
    raise exception 'T4A FIXTURE invalid_reappearance_while_present: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_new_after_reappearance (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['REAPPEARANCE', 'NEW_POSITION']::text[]);
    raise exception 'T4A FIXTURE invalid_new_after_reappearance: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_new_after_absence (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'NEW_POSITION']::text[]);
    raise exception 'T4A FIXTURE invalid_new_after_absence: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_increase_after_absence (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'POSITION_INCREASE']::text[]);
    raise exception 'T4A FIXTURE invalid_increase_after_absence: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_double_disappearance (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'POSITION_DISAPPEARED']::text[]);
    raise exception 'T4A FIXTURE invalid_double_disappearance: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_conflict_after_absence (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['POSITION_DISAPPEARED', 'POSITION_IDENTITY_CONFLICT']::text[]);
    raise exception 'T4A FIXTURE invalid_conflict_after_absence: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_unknown_type (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NOT_A_TYPE']::text[]);
    raise exception 'T4A FIXTURE invalid_unknown_type: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  -- invalid_unknown_after_new (must raise SQLSTATE MT4E1)
  begin
    perform public.mt5_t3_kind_v1(array['NEW_POSITION', 'NOT_A_TYPE']::text[]);
    raise exception 'T4A FIXTURE invalid_unknown_after_new: invalid sequence was accepted';
  exception when sqlstate 'MT4E1' then null;
  end;
  raise notice 'T4A fixture verification: % valid + % invalid cases PASS (sha 85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355)', 22, 10;
end $t4a_fixture$;
-- END GENERATED T4A T3 PARITY FIXTURE t3-kind-fixtures/1 sha256:85c076d09738d4f3189e54e2b33f6348ada205304291fd59b4801a8f2e629355
