create or replace view profit_client_service_monthly_gp_invoice_basis as
with revenue as (
  select
    date_trunc('month', coalesce(invoice.issue_date, invoice.due_date, current_date))::date as period_month,
    line.anchor_relationship_id,
    line.macro_service_type,
    sum(line.revenue_amount)::numeric as invoice_revenue_amount,
    count(*)::integer as revenue_line_count
  from profit_anchor_line_item_classifications line
  join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = line.anchor_invoice_id
  where line.include_in_revenue_allocation = true
  group by 1, 2, 3
),
labor as (
  select
    date_trunc('month', entry.entry_date)::date as period_month,
    entry.anchor_relationship_id,
    entry.macro_service_type,
    sum(entry.labor_cost)::numeric as matched_labor_cost,
    sum(entry.hours)::numeric as matched_hours,
    count(*)::integer as matched_time_entry_count
  from profit_time_entries entry
  where entry.match_status = 'matched'
  group by 1, 2, 3
),
combined as (
  select
    coalesce(revenue.period_month, labor.period_month) as period_month,
    coalesce(revenue.anchor_relationship_id, labor.anchor_relationship_id) as anchor_relationship_id,
    coalesce(revenue.macro_service_type, labor.macro_service_type) as macro_service_type,
    coalesce(revenue.invoice_revenue_amount, 0)::numeric as invoice_revenue_amount,
    coalesce(revenue.revenue_line_count, 0)::integer as revenue_line_count,
    coalesce(labor.matched_labor_cost, 0)::numeric as matched_labor_cost,
    coalesce(labor.matched_hours, 0)::numeric as matched_hours,
    coalesce(labor.matched_time_entry_count, 0)::integer as matched_time_entry_count
  from revenue
  full outer join labor
    on labor.period_month = revenue.period_month
    and labor.anchor_relationship_id = revenue.anchor_relationship_id
    and labor.macro_service_type = revenue.macro_service_type
)
select
  combined.period_month,
  combined.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  combined.macro_service_type,
  staff.name as primary_owner_staff_name,
  combined.invoice_revenue_amount,
  combined.matched_labor_cost,
  (combined.invoice_revenue_amount - combined.matched_labor_cost)::numeric as gp_amount,
  ((combined.invoice_revenue_amount - combined.matched_labor_cost) / nullif(combined.invoice_revenue_amount, 0))::numeric as gp_pct,
  combined.matched_hours,
  combined.matched_time_entry_count,
  combined.revenue_line_count,
  'invoice_basis_directional'::text as basis
from combined
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = combined.anchor_relationship_id
left join lateral (
  select owner.staff_id
  from profit_client_service_owners owner
  where owner.anchor_relationship_id = combined.anchor_relationship_id
    and owner.macro_service_type = combined.macro_service_type
    and owner.effective_from <= combined.period_month
    and (owner.effective_to is null or owner.effective_to >= combined.period_month)
  order by owner.effective_from desc
  limit 1
) owner_match on true
left join profit_staff staff
  on staff.id = owner_match.staff_id;

create or replace view profit_company_monthly_gp_invoice_basis as
with revenue as (
  select
    date_trunc('month', coalesce(invoice.issue_date, invoice.due_date, current_date))::date as period_month,
    sum(line.revenue_amount)::numeric as invoice_revenue_amount
  from profit_anchor_line_item_classifications line
  join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = line.anchor_invoice_id
  where line.include_in_revenue_allocation = true
  group by 1
),
labor as (
  select
    date_trunc('month', entry.entry_date)::date as period_month,
    sum(entry.labor_cost)::numeric as contractor_labor_cost,
    sum(entry.hours)::numeric as total_hours,
    sum(entry.hours) filter (where entry.match_status = 'admin')::numeric as admin_hours,
    sum(entry.labor_cost) filter (where entry.match_status = 'matched')::numeric as matched_labor_cost,
    sum(entry.labor_cost) filter (where entry.match_status = 'admin')::numeric as admin_labor_cost,
    sum(entry.labor_cost) filter (where entry.match_status = 'unmatched')::numeric as unmatched_labor_cost
  from profit_time_entries entry
  group by 1
),
combined as (
  select
    coalesce(revenue.period_month, labor.period_month) as period_month,
    coalesce(revenue.invoice_revenue_amount, 0)::numeric as invoice_revenue_amount,
    coalesce(labor.contractor_labor_cost, 0)::numeric as contractor_labor_cost,
    coalesce(labor.total_hours, 0)::numeric as total_hours,
    coalesce(labor.admin_hours, 0)::numeric as admin_hours,
    coalesce(labor.matched_labor_cost, 0)::numeric as matched_labor_cost,
    coalesce(labor.admin_labor_cost, 0)::numeric as admin_labor_cost,
    coalesce(labor.unmatched_labor_cost, 0)::numeric as unmatched_labor_cost
  from revenue
  full outer join labor
    on labor.period_month = revenue.period_month
)
select
  period_month,
  invoice_revenue_amount,
  contractor_labor_cost,
  (invoice_revenue_amount - contractor_labor_cost)::numeric as gp_amount,
  ((invoice_revenue_amount - contractor_labor_cost) / nullif(invoice_revenue_amount, 0))::numeric as gp_pct,
  total_hours,
  admin_hours,
  (admin_hours / nullif(total_hours, 0))::numeric as admin_load_pct,
  matched_labor_cost,
  admin_labor_cost,
  unmatched_labor_cost,
  'invoice_basis_directional'::text as basis
from combined;
