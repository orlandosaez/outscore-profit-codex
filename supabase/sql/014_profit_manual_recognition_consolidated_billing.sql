create or replace view profit_manual_recognition_pending_events as
with sibling_counts as (
  select
    event.anchor_relationship_id,
    event.macro_service_type,
    event.candidate_period_month,
    count(*) as sibling_event_count
  from profit_revenue_events event
  where event.recognition_status like 'pending_%'
    and event.recognition_period_month is null
    and event.recognized_amount = 0
  group by 1, 2, 3
)
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
  coalesce(sum(allocation.allocated_amount), 0)::numeric as cash_allocated,
  siblings.sibling_event_count
from profit_revenue_events event
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = event.anchor_relationship_id
left join profit_anchor_invoices invoice
  on invoice.anchor_invoice_id = event.anchor_invoice_id
left join profit_collection_revenue_allocations allocation
  on allocation.revenue_event_key = event.revenue_event_key
left join sibling_counts siblings
  on siblings.anchor_relationship_id = event.anchor_relationship_id
  and siblings.macro_service_type = event.macro_service_type
  and siblings.candidate_period_month = event.candidate_period_month
where event.recognition_status like 'pending_%'
  and event.recognition_period_month is null
  and event.recognized_amount = 0
group by 1,2,3,4,5,6,7,8,9,10,11,siblings.sibling_event_count;
