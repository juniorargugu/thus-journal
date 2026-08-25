-- ================================================================================================
-- T4A HUMAN DECISION LAYER — ROLLBACK PACKET
--
-- Reverses BOTH T4A packets (rpc + schema) completely. Refuses to run if decision rows exist:
-- recorded human decisions are durable workflow truth and are never dropped implicitly — deleting
-- them must be its own explicit, human-approved act (truncate as owner) BEFORE this packet.
--
-- psql -v ON_ERROR_STOP=1 -f T4A_decisions_rollback_packet.sql
-- ================================================================================================

begin;

do $t4a_rb_pre$
declare
  v_n bigint;
begin
  if to_regclass('public.mt5_capture_decisions') is not null then
    execute 'select count(*) from public.mt5_capture_decisions' into v_n;
    if v_n <> 0 then
      raise exception 'MT5_T4A_ROLLBACK: % recorded decision row(s) exist — refusing to drop '
        'durable workflow truth implicitly', v_n;
    end if;
  end if;
end $t4a_rb_pre$;

drop function if exists
  public.mt5_record_capture_decision_v1(uuid, uuid, text, text, bigint, bigint);
drop function if exists public.mt5_next_pending_capture_v1(uuid);
drop function if exists public.mt5_t3_allowed_actions_v1(text);
drop function if exists public.mt5_t3_kind_v1(text[]);
drop function if exists public.mt5_t3_event_types_v1(jsonb);

drop table if exists public.mt5_capture_decisions;   -- drops the trigger with it
drop function if exists public.mt5_capture_decision_guard_v1();

delete from public.mt5_schema_migrations
 where version in ('mt5_t4a_decisions_schema_v1', 'mt5_t4a_decisions_rpc_v1');

do $t4a_rb_post$
begin
  if to_regclass('public.mt5_capture_decisions') is not null
     or to_regprocedure('public.mt5_t3_kind_v1(text[])') is not null then
    raise exception 'MT5_T4A_ROLLBACK: objects survived the rollback';
  end if;
end $t4a_rb_post$;

commit;
