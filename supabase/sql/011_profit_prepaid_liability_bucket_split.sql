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
        or event.recognition_status = 'recognized_by_completion_trigger'
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
