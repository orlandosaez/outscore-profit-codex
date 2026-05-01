create table if not exists profit_recognition_triggers (
  recognition_trigger_key text primary key,
  source_system text not null,
  source_record_id text not null,
  anchor_relationship_id text not null,
  macro_service_type text not null,
  service_period_month date,
  completion_date date not null,
  trigger_type text not null,
  recognition_action text not null default 'recognize_full_source_amount',
  notes text,
  raw jsonb,
  loaded_at timestamptz not null default now()
);

create unique index if not exists idx_profit_recognition_triggers_source_record
  on profit_recognition_triggers (source_system, source_record_id);

create index if not exists idx_profit_recognition_triggers_relationship_macro_period
  on profit_recognition_triggers (anchor_relationship_id, macro_service_type, service_period_month);

create index if not exists idx_profit_recognition_triggers_completion_date
  on profit_recognition_triggers (completion_date);

create index if not exists idx_profit_recognition_triggers_trigger_type
  on profit_recognition_triggers (trigger_type);

create or replace view profit_revenue_events_ready_for_recognition as
select
  event.revenue_event_key,
  event.anchor_line_item_id,
  event.anchor_invoice_id,
  event.anchor_relationship_id,
  event.macro_service_type,
  event.source_amount,
  event.recognition_status as current_recognition_status,
  event.recognition_rule,
  event.candidate_period_month,
  trigger.recognition_trigger_key,
  trigger.source_system,
  trigger.source_record_id,
  trigger.trigger_type,
  trigger.completion_date as recognition_date_to_apply,
  date_trunc('month', trigger.completion_date)::date as recognition_period_month_to_apply,
  case
    when trigger.recognition_action = 'recognize_zero' then 0
    else event.source_amount
  end::numeric as recognized_amount_to_apply,
  'recognized_by_completion_trigger'::text as next_recognition_status,
  concat(trigger.source_system, ':', trigger.source_record_id)::text as trigger_reference_to_apply
from profit_revenue_events event
join profit_recognition_triggers trigger
  on trigger.anchor_relationship_id = event.anchor_relationship_id
  and trigger.macro_service_type = event.macro_service_type
  and (
    trigger.service_period_month is null
    or event.candidate_period_month = trigger.service_period_month
  )
where event.recognition_period_month is null
  and event.recognized_amount = 0
  and (
    (event.recognition_rule = 'bookkeeping_complete_required' and trigger.trigger_type = 'bookkeeping_complete')
    or (event.recognition_rule = 'payroll_processed_required' and trigger.trigger_type = 'payroll_processed')
    or (event.recognition_rule = 'tax_filed_or_extended_required' and trigger.trigger_type in ('tax_filed', 'tax_extension_filed'))
    or (event.recognition_rule = 'advisory_delivery_review_required' and trigger.trigger_type = 'advisory_delivered')
    or (event.recognition_rule = 'manual_review_required' and trigger.trigger_type = 'manual_recognition_approved')
  );
