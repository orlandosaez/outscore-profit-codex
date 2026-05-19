-- Migration 049a: payroll compliance triggers must use trigger_type='payroll_processed'
--
-- Discovery 2026-05-18: my 049 trigger function used a new trigger_type
-- 'payroll_compliance_completed', but the canonical view
-- profit_revenue_events_ready_for_recognition hard-codes the match:
--   event.recognition_rule = 'payroll_processed_required'
--   AND trigger.trigger_type = 'payroll_processed'
--
-- Result: W16 didn't drain the 9 triggers I created. The source-of-truth
-- distinction (sheet vs FC vs other) lives in source_system, not
-- trigger_type. Fix: use trigger_type='payroll_processed' for all
-- payroll-compliance-sheet-driven triggers. Keep source_system tag
-- 'payroll_compliance_sheet' so audit trail remains clear.
--
-- A. Backfill existing 9 wrong-type triggers to the correct trigger_type
-- B. Update the trigger function to emit payroll_processed going forward

-- ===== A. Backfill existing rows =====
update profit_recognition_triggers
   set trigger_type = 'payroll_processed',
       notes = coalesce(notes, '') || E'\n[049a: trigger_type corrected from payroll_compliance_completed → payroll_processed for view compatibility]'
 where trigger_type = 'payroll_compliance_completed';

-- ===== B. Replace trigger function =====
create or replace function profit_payroll_compliance_fire_recognition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bounds   record;
  v_event    record;
  v_loaded   integer := 0;
  v_trigger_key text;
begin
  -- Resolve fc_client_id by exact name match if not already set.
  if NEW.fc_client_id is null and NEW.client_name_in_sheet is not null then
    select fc.fc_client_id
      into NEW.fc_client_id
      from profit_fc_clients fc
     where lower(trim(fc.name)) = lower(trim(NEW.client_name_in_sheet))
       and fc.is_archived = false
     limit 1;
  end if;

  if NEW.status <> 'done' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status = 'done' then
    return NEW;
  end if;
  if NEW.fc_client_id is null then
    NEW.notes := coalesce(NEW.notes || E'\n', '')
              || 'No fc_client_id resolved from name "' || NEW.client_name_in_sheet || '". Recognition not fired.';
    return NEW;
  end if;

  select cycle_start, cycle_end
    into v_bounds
    from profit_payroll_compliance_cycle_bounds(NEW.cycle_period);

  for v_event in
    select
      e.revenue_event_key,
      e.anchor_relationship_id,
      e.candidate_period_month,
      e.source_amount
    from profit_revenue_events e
    join profit_fc_client_anchor_matches m
      on m.anchor_relationship_id = e.anchor_relationship_id
    where m.fc_client_id = NEW.fc_client_id
      and e.macro_service_type = 'payroll'
      and e.recognition_status like 'pending_%'
      and e.candidate_period_month between v_bounds.cycle_start and v_bounds.cycle_end
  loop
    v_trigger_key := 'payroll_compliance_' || NEW.cycle_period || '_' || v_event.revenue_event_key;
    insert into profit_recognition_triggers (
      recognition_trigger_key,
      source_system,
      source_record_id,
      anchor_relationship_id,
      macro_service_type,
      service_period_month,
      completion_date,
      trigger_type,                    -- 049a: use canonical 'payroll_processed'
      recognition_action,
      notes,
      raw,
      loaded_at,
      approved_by,
      approved_at
    ) values (
      v_trigger_key,
      'payroll_compliance_sheet',      -- 049a: distinction lives here, not in trigger_type
      v_event.revenue_event_key,
      v_event.anchor_relationship_id,
      'payroll',
      v_event.candidate_period_month,
      v_bounds.cycle_end,
      'payroll_processed',             -- 049a: canonical trigger_type matched by W16 view
      'recognize_full_source_amount',
      'Recognized by ''Payroll Tax, W2, 1099 Admin'' sheet for cycle ' || NEW.cycle_period
        || ' (operator: Beth McGuire). Sheet row marked DONE on '
        || to_char(now(), 'YYYY-MM-DD'),
      jsonb_build_object(
        'cycle_period', NEW.cycle_period,
        'client_name_in_sheet', NEW.client_name_in_sheet,
        'sheet_id', NEW.source_sheet_id,
        'ein', NEW.ein,
        'cycle_label', NEW.cycle_label,
        'source_kind', 'payroll_compliance_sheet'
      ),
      now(),
      'sheet:Beth McGuire',
      now()
    )
    on conflict (source_system, source_record_id) do nothing;
    if FOUND then
      v_loaded := v_loaded + 1;
    end if;
  end loop;

  NEW.triggers_loaded := (v_loaded > 0);
  NEW.triggers_loaded_count := v_loaded;
  NEW.triggers_loaded_at := now();
  return NEW;
end;
$$;

do $$
declare v_count integer;
begin
  select count(*) into v_count
    from profit_recognition_triggers
   where source_system = 'payroll_compliance_sheet'
     and trigger_type = 'payroll_processed';
  raise notice '049a verify: % payroll_compliance_sheet triggers now correctly typed as payroll_processed', v_count;
end $$;
