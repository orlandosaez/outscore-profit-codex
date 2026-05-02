create table if not exists profit_cash_collections (
  collection_key text primary key,
  source_system text not null,
  source_payment_id text not null,
  anchor_invoice_id text,
  anchor_relationship_id text,
  qbo_payment_id text,
  collected_at date not null,
  collected_amount numeric not null check (collected_amount >= 0),
  currency text not null default 'USD',
  collection_status text not null default 'collected',
  raw_payload jsonb not null default '{}'::jsonb,
  loaded_at timestamptz not null default now(),
  unique (source_system, source_payment_id)
);

create index if not exists idx_profit_cash_collections_invoice
  on profit_cash_collections (anchor_invoice_id);

create index if not exists idx_profit_cash_collections_relationship
  on profit_cash_collections (anchor_relationship_id);

create index if not exists idx_profit_cash_collections_collected_at
  on profit_cash_collections (collected_at);

create table if not exists profit_collection_revenue_allocations (
  allocation_key text primary key,
  collection_key text not null references profit_cash_collections (collection_key),
  revenue_event_key text not null references profit_revenue_events (revenue_event_key),
  allocated_amount numeric not null check (allocated_amount >= 0),
  rounding_delta numeric not null default 0,
  allocation_method text not null,
  loaded_at timestamptz not null default now(),
  unique (collection_key, revenue_event_key)
);

alter table profit_collection_revenue_allocations
  add column if not exists rounding_delta numeric not null default 0;

create index if not exists idx_profit_collection_allocations_collection
  on profit_collection_revenue_allocations (collection_key);

create index if not exists idx_profit_collection_allocations_event
  on profit_collection_revenue_allocations (revenue_event_key);

create or replace function profit_validate_collection_revenue_allocation()
returns trigger
language plpgsql
as $$
declare
  collection_limit numeric;
  collection_total numeric;
  event_limit numeric;
  event_total numeric;
begin
  select collected_amount
  into collection_limit
  from profit_cash_collections
  where collection_key = new.collection_key;

  select source_amount
  into event_limit
  from profit_revenue_events
  where revenue_event_key = new.revenue_event_key;

  select coalesce(sum(allocated_amount), 0)
  into collection_total
  from profit_collection_revenue_allocations
  where collection_key = new.collection_key
    and allocation_key <> new.allocation_key;

  if collection_total + new.allocated_amount > collection_limit + 0.005 then
    raise exception 'allocated amount exceeds collected cash';
  end if;

  select coalesce(sum(allocated_amount), 0)
  into event_total
  from profit_collection_revenue_allocations
  where revenue_event_key = new.revenue_event_key
    and allocation_key <> new.allocation_key;

  if event_total + new.allocated_amount > event_limit + 0.005 then
    raise exception 'allocated amount exceeds revenue event source amount';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_profit_validate_collection_revenue_allocation
  on profit_collection_revenue_allocations;

create trigger trg_profit_validate_collection_revenue_allocation
  before insert or update on profit_collection_revenue_allocations
  for each row
  execute function profit_validate_collection_revenue_allocation();

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
    collection.collection_key,
    allocation.allocation_key,
    allocation.revenue_event_key,
    collection.source_system,
    collection.source_payment_id,
    collection.anchor_invoice_id,
    coalesce(event.anchor_relationship_id, collection.anchor_relationship_id) as anchor_relationship_id,
    event.macro_service_type,
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
    collection.collection_key,
    allocation.allocation_key,
    allocation.revenue_event_key,
    collection.source_system,
    collection.source_payment_id,
    collection.anchor_invoice_id,
    coalesce(event.anchor_relationship_id, collection.anchor_relationship_id) as anchor_relationship_id,
    event.macro_service_type,
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
  collection_key,
  allocation_key,
  revenue_event_key,
  source_system,
  source_payment_id,
  anchor_invoice_id,
  anchor_relationship_id,
  macro_service_type,
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
  collection_key,
  allocation_key,
  revenue_event_key,
  source_system,
  source_payment_id,
  anchor_invoice_id,
  anchor_relationship_id,
  macro_service_type,
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
  sum(ledger.amount_delta)::numeric as balance,
  sum(ledger.collected_amount)::numeric as collected_amount,
  sum(ledger.recognized_drawdown_amount)::numeric as recognized_drawdown_amount,
  sum(ledger.rounding_delta)::numeric as rounding_delta,
  max(ledger.event_at) as last_updated,
  count(*)::integer as ledger_entry_count
from profit_prepaid_liability_ledger ledger
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = ledger.anchor_relationship_id
group by 1, 2, 3
having sum(ledger.amount_delta) <> 0;

create or replace view profit_prepaid_liability_summary as
with balance_summary as (
  select
    coalesce(sum(balance), 0)::numeric as current_total_prepaid_liability,
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
  balance_summary.current_total_prepaid_liability,
  balance_summary.client_balance_count,
  collection_summary.collection_count,
  balance_summary.last_updated
from balance_summary
cross join collection_summary;

create or replace view profit_unallocated_cash_collections as
with allocation_summary as (
  select
    allocation.collection_key,
    sum(allocation.allocated_amount)::numeric as allocated_amount
  from profit_collection_revenue_allocations allocation
  group by 1
)
select
  collection.collection_key,
  collection.source_system,
  collection.source_payment_id,
  collection.anchor_invoice_id,
  collection.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  collection.qbo_payment_id,
  collection.collected_at,
  collection.collected_amount,
  coalesce(allocation_summary.allocated_amount, 0)::numeric as allocated_amount,
  (collection.collected_amount - coalesce(allocation_summary.allocated_amount, 0))::numeric as unallocated_amount,
  case
    when coalesce(allocation_summary.allocated_amount, 0) = 0 then 'unmatched_payment'
    else 'partially_allocated'
  end::text as review_status,
  collection.raw_payload,
  collection.loaded_at
from profit_cash_collections collection
left join allocation_summary
  on allocation_summary.collection_key = collection.collection_key
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = collection.anchor_relationship_id
where collection.collected_amount - coalesce(allocation_summary.allocated_amount, 0) > 0.005;
