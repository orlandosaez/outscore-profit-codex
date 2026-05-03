create or replace function profit_extract_tax_form_type(input_text text)
returns text
language sql
immutable
as $$
  select case
    when coalesce(input_text, '') ~* '\m990[- ]?t\M' then '990-T'
    when coalesce(input_text, '') ~* '\m990[- ]?ez\M' then '990-EZ'
    when coalesce(input_text, '') ~* '\m1120s?\M' then '1120'
    when coalesce(input_text, '') ~* '\m1065\M' then '1065'
    when coalesce(input_text, '') ~* '\m1040\M' then '1040'
    when coalesce(input_text, '') ~* '\m990\M' then '990'
    else null
  end;
$$;

create or replace function profit_extract_anchor_invoice_note_scope(input_text text)
returns table (
  tax_year text,
  fiscal_year_end text,
  is_amended boolean
)
language sql
stable
as $$
  select
    substring(coalesce(input_text, '') from '(?i)TY:(\d{4})') as tax_year,
    substring(coalesce(input_text, '') from '(?i)FY:(\d{4}-\d{2})') as fiscal_year_end,
    coalesce(input_text, '') ~* 'Amended' as is_amended;
$$;

create or replace view profit_tax_recognition_ambiguities as
with tax_triggers as (
  select
    trigger.recognition_trigger_key,
    trigger.anchor_relationship_id,
    trigger.trigger_type,
    trigger.service_period_month,
    trigger.source_record_id,
    trigger.notes,
    trigger.raw,
    profit_extract_tax_form_type(
      concat_ws(
        ' ',
        trigger.notes,
        trigger.raw->>'task_title',
        trigger.raw->>'project_title',
        trigger.raw->>'client_name'
      )
    ) as trigger_form_type
  from profit_recognition_triggers trigger
  where trigger.trigger_type in ('tax_filed', 'tax_extension_filed')
),
tax_candidates as (
  select
    trigger.recognition_trigger_key,
    trigger.anchor_relationship_id,
    trigger.trigger_type,
    trigger.service_period_month,
    trigger.source_record_id,
    trigger.trigger_form_type,
    event.revenue_event_key,
    event.candidate_period_month,
    event.source_amount,
    event.service_name,
    rule.form_type_pattern,
    invoice.invoice_note,
    'ambiguous_tax_form_match'::text as ambiguity_reason,
    count(*) over (partition by trigger.recognition_trigger_key) as candidate_count
  from tax_triggers trigger
  join profit_revenue_events event
    on event.anchor_relationship_id = trigger.anchor_relationship_id
    and event.macro_service_type = 'tax'
  left join profit_service_recognition_rules rule
    on rule.service_name = event.service_name
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
  where trigger.trigger_form_type is not null
    and event.recognition_status like 'pending_%'
    and event.recognition_period_month is null
    and coalesce(event.recognized_amount, 0) = 0
    and coalesce(rule.form_type_pattern, profit_extract_tax_form_type(event.service_name)) = trigger.trigger_form_type
    and coalesce(invoice.invoice_note, '') !~* '(TY|FY):\d{4}(-\d{2})?'
)
select *
from tax_candidates
where candidate_count > 1;

drop view if exists profit_revenue_events_ready_for_recognition;

create or replace view profit_revenue_events_ready_for_recognition as
with non_tax_ready as (
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
    case
      when trigger.trigger_type = 'manual_recognition_approved'
        then 'recognized_by_manual_override'
      else 'recognized_by_completion_trigger'
    end::text as next_recognition_status,
    concat(trigger.source_system, ':', trigger.source_record_id)::text as trigger_reference_to_apply
  from profit_revenue_events event
  join profit_recognition_triggers trigger
    on trigger.anchor_relationship_id = event.anchor_relationship_id
    and trigger.macro_service_type = event.macro_service_type
    and trigger.trigger_type not in ('tax_filed', 'tax_extension_filed')
    and (
      trigger.trigger_type <> 'manual_recognition_approved'
      or trigger.source_record_id = event.revenue_event_key
    )
    and (
      trigger.service_period_month is null
      or event.candidate_period_month = trigger.service_period_month
    )
  where event.recognition_period_month is null
    and event.recognized_amount = 0
    and (
      (event.recognition_rule = 'bookkeeping_complete_required' and trigger.trigger_type = 'bookkeeping_complete')
      or (event.recognition_rule = 'payroll_processed_required' and trigger.trigger_type = 'payroll_processed')
      or (event.recognition_rule = 'advisory_delivery_review_required' and trigger.trigger_type = 'advisory_delivered')
      or (
        trigger.trigger_type = 'manual_recognition_approved'
        and event.recognition_status like 'pending_%'
      )
    )
),
tax_trigger_context as (
  select
    trigger.recognition_trigger_key,
    trigger.source_system,
    trigger.source_record_id,
    trigger.anchor_relationship_id,
    trigger.service_period_month,
    trigger.completion_date,
    trigger.trigger_type,
    trigger.recognition_action,
    trigger.notes,
    trigger.raw,
    profit_extract_tax_form_type(
      concat_ws(
        ' ',
        trigger.notes,
        trigger.raw->>'task_title',
        trigger.raw->>'project_title',
        trigger.raw->>'client_name'
      )
    ) as trigger_form_type
  from profit_recognition_triggers trigger
  where trigger.trigger_type in ('tax_filed', 'tax_extension_filed')
),
tax_candidates as (
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
    concat(trigger.source_system, ':', trigger.source_record_id)::text as trigger_reference_to_apply,
    event.service_name,
    rule.form_type_pattern,
    invoice.invoice_note,
    note_scope.tax_year,
    note_scope.fiscal_year_end,
    note_scope.is_amended,
    row_number() over (
      partition by trigger.recognition_trigger_key
      order by
        event.candidate_period_month asc nulls last,
        event.loaded_at asc,
        event.revenue_event_key asc
    ) as candidate_rank,
    count(*) over (partition by trigger.recognition_trigger_key) as candidate_count
  from tax_trigger_context trigger
  join profit_revenue_events event
    on event.anchor_relationship_id = trigger.anchor_relationship_id
    and event.macro_service_type = 'tax'
  left join profit_service_recognition_rules rule
    on rule.service_name = event.service_name
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
  left join lateral profit_extract_anchor_invoice_note_scope(invoice.invoice_note) note_scope
    on true
  where trigger.trigger_form_type is not null
    and event.recognition_rule = 'tax_filed_or_extended_required'
    and event.recognition_status like 'pending_%'
    and event.recognition_period_month is null
    and coalesce(event.recognized_amount, 0) = 0
    and coalesce(rule.form_type_pattern, profit_extract_tax_form_type(event.service_name)) = trigger.trigger_form_type
    -- TY: / FY: / Amended invoice notes intentionally participate in the candidate set.
    -- V0.5.3 run logs will surface ambiguous note cases for review; safe rows still require candidate_count = 1.
    and (
      note_scope.tax_year is null
      or extract(year from event.candidate_period_month)::text = note_scope.tax_year
    )
    and (
      note_scope.fiscal_year_end is null
      or to_char(event.candidate_period_month, 'YYYY-MM') = note_scope.fiscal_year_end
    )
)
select
  revenue_event_key,
  anchor_line_item_id,
  anchor_invoice_id,
  anchor_relationship_id,
  macro_service_type,
  source_amount,
  current_recognition_status,
  recognition_rule,
  candidate_period_month,
  recognition_trigger_key,
  source_system,
  source_record_id,
  trigger_type,
  recognition_date_to_apply,
  recognition_period_month_to_apply,
  recognized_amount_to_apply,
  next_recognition_status,
  trigger_reference_to_apply
from non_tax_ready
union all
select
  revenue_event_key,
  anchor_line_item_id,
  anchor_invoice_id,
  anchor_relationship_id,
  macro_service_type,
  source_amount,
  current_recognition_status,
  recognition_rule,
  candidate_period_month,
  recognition_trigger_key,
  source_system,
  source_record_id,
  trigger_type,
  recognition_date_to_apply,
  recognition_period_month_to_apply,
  recognized_amount_to_apply,
  next_recognition_status,
  trigger_reference_to_apply
from tax_candidates
where candidate_count = 1
  and candidate_rank = 1;
