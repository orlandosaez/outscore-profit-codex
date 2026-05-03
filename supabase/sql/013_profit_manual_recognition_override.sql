alter table profit_recognition_triggers
  add column if not exists manual_override_reason_code text,
  add column if not exists manual_override_notes text,
  add column if not exists manual_override_reference text,
  add column if not exists approved_by text,
  add column if not exists approved_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profit_recognition_triggers_manual_reason_code_check'
  ) then
    alter table profit_recognition_triggers
      add constraint profit_recognition_triggers_manual_reason_code_check
      check (
        manual_override_reason_code is null
        or manual_override_reason_code in (
          'backbill_pre_engagement',
          'client_operational_change',
          'entity_restructure',
          'service_outside_fc_scope',
          'fc_classifier_gap',
          'voided_invoice_replacement',
          'billing_amount_adjustment',
          'other'
        )
      );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profit_recognition_triggers_manual_required_fields_check'
  ) then
    alter table profit_recognition_triggers
      add constraint profit_recognition_triggers_manual_required_fields_check
      check (
        trigger_type <> 'manual_recognition_approved'
        or (
          manual_override_reason_code is not null
          and manual_override_notes is not null
          and length(trim(manual_override_notes)) > 0
          and approved_by is not null
          and length(trim(approved_by)) > 0
          and approved_at is not null
        )
      );
  end if;
end $$;

create index if not exists idx_profit_recognition_triggers_manual_approved_at
  on profit_recognition_triggers (trigger_type, approved_at desc)
  where trigger_type = 'manual_recognition_approved';

drop view if exists profit_revenue_events_ready_for_recognition;

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
    or (event.recognition_rule = 'tax_filed_or_extended_required' and trigger.trigger_type in ('tax_filed', 'tax_extension_filed'))
    or (event.recognition_rule = 'advisory_delivery_review_required' and trigger.trigger_type = 'advisory_delivered')
    or (
      trigger.trigger_type = 'manual_recognition_approved'
      and event.recognition_status like 'pending_%'
    )
  );

create or replace view profit_manual_recognition_pending_events as
select
  event.revenue_event_key,
  event.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  event.anchor_invoice_id,
  invoice.invoice_number,
  event.macro_service_type,
  event.candidate_period_month,
  event.source_amount,
  event.recognized_amount,
  event.recognition_status,
  event.recognition_rule,
  coalesce(sum(allocation.allocated_amount), 0)::numeric as cash_allocated
from profit_revenue_events event
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = event.anchor_relationship_id
left join profit_anchor_invoices invoice
  on invoice.anchor_invoice_id = event.anchor_invoice_id
left join profit_collection_revenue_allocations allocation
  on allocation.revenue_event_key = event.revenue_event_key
where event.recognition_status like 'pending_%'
  and event.recognition_period_month is null
  and event.recognized_amount = 0
group by 1,2,3,4,5,6,7,8,9,10,11;

create or replace view profit_manual_recognition_override_audit as
select
  trigger.approved_at,
  trigger.approved_by,
  trigger.recognition_trigger_key,
  trigger.source_record_id as revenue_event_key,
  event.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  event.macro_service_type,
  event.candidate_period_month,
  event.source_amount,
  event.recognized_amount,
  event.recognition_status,
  trigger.manual_override_reason_code,
  trigger.manual_override_notes,
  trigger.manual_override_reference
from profit_recognition_triggers trigger
join profit_revenue_events event
  on event.revenue_event_key = trigger.source_record_id
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = event.anchor_relationship_id
where trigger.trigger_type = 'manual_recognition_approved';

drop view if exists profit_prepaid_liability_summary;
drop view if exists profit_prepaid_liability_balances;
drop view if exists profit_prepaid_liability_ledger;

create or replace view profit_prepaid_liability_ledger as
with event_allocations as (
  select
    allocation.revenue_event_key,
    sum(allocation.allocated_amount)::numeric as total_allocated_amount
  from profit_collection_revenue_allocations allocation
  group by 1
),
cash_entries as (
  select
    collection.collected_at as event_at,
    date_trunc('month', collection.collected_at)::date as period_month,
    'cash_collected'::text as ledger_entry_type,
    case
      when event.recognition_status = 'pending_tax_completion' then 'tax_deferred_revenue'::text
      when event.recognition_status in (
        'pending_bookkeeping_completion',
        'pending_payroll_processed',
        'pending_advisory_review'
      ) then 'pending_recognition_trigger'::text
      when event.recognition_date is not null
        or event.recognized_amount > 0
        or event.recognition_status in (
          'recognized_by_completion_trigger',
          'recognized_by_manual_override'
        )
        then 'recognized'::text
      else 'pending_recognition_trigger'::text
    end as service_category,
    collection.collection_key,
    allocation.allocation_key,
    allocation.revenue_event_key,
    collection.source_system,
    collection.source_payment_id,
    collection.anchor_invoice_id,
    coalesce(event.anchor_relationship_id, collection.anchor_relationship_id) as anchor_relationship_id,
    event.macro_service_type,
    event.recognition_status,
    allocation.allocated_amount::numeric as amount_delta,
    allocation.allocated_amount::numeric as collected_amount,
    0::numeric as recognized_drawdown_amount,
    allocation.rounding_delta::numeric as rounding_delta,
    allocation.allocation_method
  from profit_collection_revenue_allocations allocation
  join profit_cash_collections collection
    on collection.collection_key = allocation.collection_key
  join profit_revenue_events event
    on event.revenue_event_key = allocation.revenue_event_key
),
recognition_entries as (
  select
    event.recognition_date as event_at,
    event.recognition_period_month as period_month,
    'revenue_recognized'::text as ledger_entry_type,
    'recognized'::text as service_category,
    collection.collection_key,
    allocation.allocation_key,
    allocation.revenue_event_key,
    collection.source_system,
    collection.source_payment_id,
    collection.anchor_invoice_id,
    coalesce(event.anchor_relationship_id, collection.anchor_relationship_id) as anchor_relationship_id,
    event.macro_service_type,
    event.recognition_status,
    -least(
      allocation.allocated_amount,
      event.recognized_amount
      * (allocation.allocated_amount / nullif(event_allocations.total_allocated_amount, 0))
    )::numeric as amount_delta,
    0::numeric as collected_amount,
    least(
      allocation.allocated_amount,
      event.recognized_amount
      * (allocation.allocated_amount / nullif(event_allocations.total_allocated_amount, 0))
    )::numeric as recognized_drawdown_amount,
    0::numeric as rounding_delta,
    allocation.allocation_method
  from profit_collection_revenue_allocations allocation
  join profit_cash_collections collection
    on collection.collection_key = allocation.collection_key
  join profit_revenue_events event
    on event.revenue_event_key = allocation.revenue_event_key
  join event_allocations
    on event_allocations.revenue_event_key = allocation.revenue_event_key
  where event.recognition_date is not null
    and event.recognized_amount > 0
)
select
  event_at,
  period_month,
  ledger_entry_type,
  service_category,
  collection_key,
  allocation_key,
  revenue_event_key,
  source_system,
  source_payment_id,
  anchor_invoice_id,
  anchor_relationship_id,
  macro_service_type,
  recognition_status,
  amount_delta,
  collected_amount,
  recognized_drawdown_amount,
  rounding_delta,
  allocation_method
from cash_entries
union all
select
  event_at,
  period_month,
  ledger_entry_type,
  service_category,
  collection_key,
  allocation_key,
  revenue_event_key,
  source_system,
  source_payment_id,
  anchor_invoice_id,
  anchor_relationship_id,
  macro_service_type,
  recognition_status,
  amount_delta,
  collected_amount,
  recognized_drawdown_amount,
  rounding_delta,
  allocation_method
from recognition_entries;

create or replace view profit_prepaid_liability_balances as
select
  ledger.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  ledger.macro_service_type,
  ledger.service_category,
  sum(ledger.amount_delta)::numeric as balance,
  sum(ledger.collected_amount)::numeric as collected_amount,
  sum(ledger.recognized_drawdown_amount)::numeric as recognized_drawdown_amount,
  sum(ledger.rounding_delta)::numeric as rounding_delta,
  max(ledger.event_at) as last_updated,
  count(*)::integer as ledger_entry_count
from profit_prepaid_liability_ledger ledger
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = ledger.anchor_relationship_id
group by 1, 2, 3, 4
having sum(ledger.amount_delta) <> 0;

create or replace view profit_prepaid_liability_summary as
with balance_summary as (
  select
    coalesce(sum(balance) filter (
      where service_category = 'tax_deferred_revenue'
    ), 0)::numeric as tax_deferred_revenue_balance,
    coalesce(sum(balance) filter (
      where service_category = 'pending_recognition_trigger'
    ), 0)::numeric as trigger_backlog_balance,
    coalesce(sum(balance) filter (
      where service_category in ('tax_deferred_revenue', 'pending_recognition_trigger')
    ), 0)::numeric as total_prepaid_liability_balance,
    count(*)::integer as client_balance_count,
    max(last_updated) as last_updated
  from profit_prepaid_liability_balances
),
collection_summary as (
  select
    count(*)::integer as collection_count
  from profit_cash_collections
)
select
  balance_summary.tax_deferred_revenue_balance,
  balance_summary.trigger_backlog_balance,
  balance_summary.total_prepaid_liability_balance,
  'Delivered services with no recognition trigger loaded — not a QBO liability entry. Clears when FC completion triggers are approved.'::text as trigger_backlog_note,
  balance_summary.client_balance_count,
  collection_summary.collection_count,
  balance_summary.last_updated
from balance_summary
cross join collection_summary;
