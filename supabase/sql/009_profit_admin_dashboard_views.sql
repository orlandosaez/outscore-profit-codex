create or replace view profit_admin_company_dashboard_summary as
with latest_month as (
  select *
  from profit_company_monthly_gp_recognition_basis
  order by period_month desc
  limit 1
),
latest_quarter as (
  select *
  from profit_company_quarterly_gp_gate
  order by quarter_start desc
  limit 1
),
revenue_status as (
  select
    sum(source_amount) filter (where recognition_status like 'pending_%')::numeric as pending_revenue_amount,
    sum(recognized_amount)::numeric as recognized_revenue_amount,
    count(*) filter (where recognition_status like 'pending_%')::integer as pending_revenue_event_count,
    count(*) filter (where recognized_amount > 0)::integer as recognized_revenue_event_count
  from profit_revenue_events
),
fc_queue as (
  select
    count(*) filter (where trigger_load_status = 'ready_to_load')::integer as fc_ready_trigger_count,
    count(*) filter (where trigger_load_status = 'pending_approval')::integer as fc_pending_approval_count
  from profit_fc_completion_trigger_candidates
)
select
  latest_month.period_month as latest_period_month,
  latest_month.recognized_revenue_amount as latest_month_recognized_revenue_amount,
  latest_month.contractor_labor_cost as latest_month_contractor_labor_cost,
  latest_month.gp_amount as latest_month_gp_amount,
  latest_month.gp_pct as latest_month_gp_pct,
  latest_month.admin_load_pct,
  latest_quarter.quarter_start as latest_quarter_start,
  latest_quarter.recognized_revenue_amount as latest_quarter_recognized_revenue_amount,
  latest_quarter.contractor_labor_cost as latest_quarter_contractor_labor_cost,
  latest_quarter.gp_amount as latest_quarter_gp_amount,
  latest_quarter.gp_pct as latest_quarter_gp_pct,
  latest_quarter.company_gate_gp_pct,
  latest_quarter.ratcheted_company_gp_target_pct,
  latest_quarter.gate_passed,
  revenue_status.pending_revenue_amount,
  revenue_status.recognized_revenue_amount,
  revenue_status.pending_revenue_event_count,
  revenue_status.recognized_revenue_event_count,
  fc_queue.fc_ready_trigger_count,
  fc_queue.fc_pending_approval_count
from latest_month
cross join latest_quarter
cross join revenue_status
cross join fc_queue;

create or replace view profit_admin_client_gp_dashboard as
select
  gp.period_month,
  gp.anchor_relationship_id,
  gp.anchor_client_business_name,
  gp.macro_service_type,
  gp.primary_owner_staff_name,
  gp.recognized_revenue_amount,
  gp.matched_labor_cost,
  gp.gp_amount,
  gp.gp_pct,
  gp.matched_hours,
  gp.matched_time_entry_count,
  gp.revenue_event_count,
  row_number() over (
    partition by gp.period_month
    order by gp.gp_amount asc, gp.anchor_client_business_name asc, gp.macro_service_type asc
  ) as low_gp_rank
from profit_client_service_monthly_gp_recognition_basis gp;

create or replace view profit_admin_staff_gp_dashboard as
select
  gp.period_month,
  gp.primary_owner_staff_name as staff_name,
  sum(gp.recognized_revenue_amount)::numeric as owned_recognized_revenue_amount,
  sum(gp.matched_labor_cost)::numeric as owned_matched_labor_cost,
  sum(gp.gp_amount)::numeric as owned_gp_amount,
  (sum(gp.gp_amount) / nullif(sum(gp.recognized_revenue_amount), 0))::numeric as owned_gp_pct,
  sum(gp.matched_hours)::numeric as owned_matched_hours,
  count(*)::integer as client_service_count
from profit_client_service_monthly_gp_recognition_basis gp
where gp.primary_owner_staff_name is not null
group by 1, 2;

create or replace view profit_admin_comp_kicker_ledger as
select
  accrual.period_month,
  accrual.prior_company_gate_quarter,
  accrual.staff_name,
  accrual.company_gate_passed,
  accrual.prior_company_gp_pct,
  accrual.company_gate_gp_pct,
  accrual.ratcheted_company_gp_target_pct,
  accrual.owned_recognized_revenue_amount,
  accrual.owned_gp_amount,
  accrual.gp_above_floor_amount,
  accrual.gross_kicker_amount,
  accrual.kicker_accrual_amount,
  accrual.client_service_count
from profit_staff_monthly_kicker_accruals accrual;

create or replace view profit_admin_w2_candidates as
select
  flags.period_month,
  flags.staff_name,
  flags.w2_flag_status,
  flags.cost_trigger,
  flags.consistency_trigger,
  flags.annualized_contractor_cost,
  flags.avg_weekly_hours,
  flags.high_hour_month_count_8m,
  flags.observed_month_count_8m,
  flags.hours_cv_8m,
  flags.total_hours,
  flags.contractor_labor_cost
from profit_staff_monthly_w2_conversion_flags flags
where flags.w2_flag_status <> 'no_flag';

create or replace view profit_admin_fc_trigger_queue as
select
  candidate.approval_status,
  candidate.trigger_load_status,
  candidate.suggested_trigger_type,
  candidate.suggested_macro_service_type,
  candidate.anchor_client_business_name,
  candidate.client_name,
  candidate.project_title,
  candidate.task_title,
  candidate.completed_at,
  candidate.fc_task_id,
  candidate.fc_project_id,
  candidate.fc_client_id,
  candidate.anchor_relationship_id,
  candidate.macro_service_type,
  candidate.trigger_type,
  candidate.service_period_month,
  candidate.completion_date
from profit_fc_completion_trigger_candidates candidate;
