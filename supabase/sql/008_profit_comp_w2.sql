create table if not exists profit_comp_plan_config (
  config_key text primary key,
  config_value text not null,
  value_type text not null default 'numeric',
  notes text,
  updated_at timestamptz not null default now()
);

insert into profit_comp_plan_config (config_key, config_value, value_type, notes)
values
  ('floor_gp_pct', '0.35', 'numeric', 'Client/service GP percent below which no kicker is paid.'),
  ('kicker_rate', '0.20', 'numeric', 'Staff share of GP dollars above the floor.'),
  ('company_gate_gp_pct', '0.50', 'numeric', 'Hard company GP gate for any payout.'),
  ('baseline_company_gp_pct', '0.40', 'numeric', 'Planning baseline used for target ratchet display.'),
  ('quarterly_target_step_pct', '0.03', 'numeric', 'Quarterly target ratchet step.'),
  ('company_gp_target_cap_pct', '0.65', 'numeric', 'Maximum ratcheted company GP target.'),
  ('w2_cost_trigger_amount', '55000', 'numeric', 'Annualized contractor cost above this amount trips cost trigger.'),
  ('w2_weekly_hours_trigger', '25', 'numeric', 'Average weekly hours threshold for consistency trigger.'),
  ('w2_consistency_month_count', '6', 'numeric', 'High-hour months required in trailing 8 months.'),
  ('w2_hours_cv_limit', '0.30', 'numeric', 'Trailing 8-month coefficient of variation limit.')
on conflict (config_key) do nothing;

create or replace view profit_comp_plan_config_values as
select
  max(config_value::numeric) filter (where config_key = 'floor_gp_pct') as floor_gp_pct,
  max(config_value::numeric) filter (where config_key = 'kicker_rate') as kicker_rate,
  max(config_value::numeric) filter (where config_key = 'company_gate_gp_pct') as company_gate_gp_pct,
  max(config_value::numeric) filter (where config_key = 'baseline_company_gp_pct') as baseline_company_gp_pct,
  max(config_value::numeric) filter (where config_key = 'quarterly_target_step_pct') as quarterly_target_step_pct,
  max(config_value::numeric) filter (where config_key = 'company_gp_target_cap_pct') as company_gp_target_cap_pct,
  max(config_value::numeric) filter (where config_key = 'w2_cost_trigger_amount') as w2_cost_trigger_amount,
  max(config_value::numeric) filter (where config_key = 'w2_weekly_hours_trigger') as w2_weekly_hours_trigger,
  max(config_value::numeric) filter (where config_key = 'w2_consistency_month_count') as w2_consistency_month_count,
  max(config_value::numeric) filter (where config_key = 'w2_hours_cv_limit') as w2_hours_cv_limit
from profit_comp_plan_config;

create or replace view profit_company_quarterly_gp_gate as
with quarterly as (
  select
    date_trunc('quarter', period_month)::date as quarter_start,
    sum(recognized_revenue_amount)::numeric as recognized_revenue_amount,
    sum(contractor_labor_cost)::numeric as contractor_labor_cost
  from profit_company_monthly_gp_recognition_basis
  group by 1
),
indexed as (
  select
    quarterly.*,
    dense_rank() over (order by quarter_start) - 1 as quarter_index
  from quarterly
)
select
  indexed.quarter_start,
  indexed.recognized_revenue_amount,
  indexed.contractor_labor_cost,
  (indexed.recognized_revenue_amount - indexed.contractor_labor_cost)::numeric as gp_amount,
  ((indexed.recognized_revenue_amount - indexed.contractor_labor_cost) / nullif(indexed.recognized_revenue_amount, 0))::numeric as gp_pct,
  least(
    config.company_gp_target_cap_pct,
    config.baseline_company_gp_pct + (indexed.quarter_index * config.quarterly_target_step_pct)
  )::numeric as ratcheted_company_gp_target_pct,
  config.company_gate_gp_pct,
  (
    ((indexed.recognized_revenue_amount - indexed.contractor_labor_cost) / nullif(indexed.recognized_revenue_amount, 0))
    >= config.company_gate_gp_pct
  ) as gate_passed
from indexed
cross join profit_comp_plan_config_values config;

create or replace view profit_staff_monthly_kicker_candidates as
select
  gp.period_month,
  date_trunc('quarter', gp.period_month - interval '3 months')::date as prior_company_gate_quarter,
  gp.primary_owner_staff_name as staff_name,
  gp.anchor_relationship_id,
  gp.anchor_client_business_name,
  gp.macro_service_type,
  gp.recognized_revenue_amount,
  gp.matched_labor_cost,
  gp.gp_amount,
  gp.gp_pct,
  config.floor_gp_pct,
  config.kicker_rate,
  greatest(0, (gp.gp_pct - config.floor_gp_pct) * gp.recognized_revenue_amount)::numeric as gp_above_floor_amount,
  (greatest(0, (gp.gp_pct - config.floor_gp_pct) * gp.recognized_revenue_amount) * config.kicker_rate)::numeric as gross_kicker_amount
from profit_client_service_monthly_gp_recognition_basis gp
cross join profit_comp_plan_config_values config
where gp.primary_owner_staff_name is not null
  and gp.recognized_revenue_amount > 0;

create or replace view profit_staff_monthly_kicker_accruals as
select
  candidate.period_month,
  candidate.prior_company_gate_quarter,
  candidate.staff_name,
  coalesce(gate.gate_passed, false) as company_gate_passed,
  gate.gp_pct as prior_company_gp_pct,
  gate.company_gate_gp_pct,
  gate.ratcheted_company_gp_target_pct,
  sum(candidate.recognized_revenue_amount)::numeric as owned_recognized_revenue_amount,
  sum(candidate.gp_amount)::numeric as owned_gp_amount,
  sum(candidate.gp_above_floor_amount)::numeric as gp_above_floor_amount,
  sum(candidate.gross_kicker_amount)::numeric as gross_kicker_amount,
  case when coalesce(gate.gate_passed, false)
    then sum(candidate.gross_kicker_amount)::numeric
    else 0::numeric
  end as kicker_accrual_amount,
  count(*)::integer as client_service_count
from profit_staff_monthly_kicker_candidates candidate
left join profit_company_quarterly_gp_gate gate
  on gate.quarter_start = candidate.prior_company_gate_quarter
group by
  candidate.period_month,
  candidate.prior_company_gate_quarter,
  candidate.staff_name,
  gate.gate_passed,
  gate.gp_pct,
  gate.company_gate_gp_pct,
  gate.ratcheted_company_gp_target_pct;

create or replace view profit_staff_monthly_workload as
select
  date_trunc('month', entry.entry_date)::date as period_month,
  entry.staff_name,
  sum(entry.hours)::numeric as total_hours,
  sum(entry.labor_cost)::numeric as contractor_labor_cost,
  (sum(entry.hours) / 4.333)::numeric as avg_weekly_hours,
  count(*)::integer as time_entry_count
from profit_time_entries entry
group by 1, 2;

create or replace view profit_staff_monthly_w2_conversion_flags as
with rolling as (
  select
    current_month.period_month,
    current_month.staff_name,
    current_month.total_hours,
    current_month.contractor_labor_cost,
    current_month.avg_weekly_hours,
    sum(history.contractor_labor_cost)::numeric as trailing_8m_labor_cost,
    count(history.period_month)::integer as observed_month_count_8m,
    avg(history.total_hours)::numeric as avg_monthly_hours_8m,
    stddev_pop(history.total_hours)::numeric as stddev_monthly_hours_8m,
    count(*) filter (where history.avg_weekly_hours >= 25)::integer as high_hour_month_count_8m
  from profit_staff_monthly_workload current_month
  join profit_staff_monthly_workload history
    on history.staff_name = current_month.staff_name
    and history.period_month between (current_month.period_month - interval '7 months')::date and current_month.period_month
  group by
    current_month.period_month,
    current_month.staff_name,
    current_month.total_hours,
    current_month.contractor_labor_cost,
    current_month.avg_weekly_hours
),
scored as (
  select
    rolling.*,
    (rolling.trailing_8m_labor_cost / nullif(rolling.observed_month_count_8m, 0) * 12)::numeric as annualized_contractor_cost,
    (rolling.stddev_monthly_hours_8m / nullif(rolling.avg_monthly_hours_8m, 0))::numeric as hours_cv_8m
  from rolling
)
select
  scored.period_month,
  scored.staff_name,
  scored.total_hours,
  scored.contractor_labor_cost,
  scored.avg_weekly_hours,
  scored.trailing_8m_labor_cost,
  scored.observed_month_count_8m,
  scored.high_hour_month_count_8m,
  scored.annualized_contractor_cost,
  scored.hours_cv_8m,
  (scored.annualized_contractor_cost > config.w2_cost_trigger_amount) as cost_trigger,
  (
    scored.high_hour_month_count_8m >= 6
    and scored.avg_weekly_hours >= 25
    and coalesce(scored.hours_cv_8m, 0) < 0.30
  ) as consistency_trigger,
  case
    when (scored.annualized_contractor_cost > config.w2_cost_trigger_amount)
      and (
        scored.high_hour_month_count_8m >= 6
        and scored.avg_weekly_hours >= 25
        and coalesce(scored.hours_cv_8m, 0) < 0.30
      ) then 'convert'
    when (scored.annualized_contractor_cost > config.w2_cost_trigger_amount)
      or (
        scored.high_hour_month_count_8m >= 6
        and scored.avg_weekly_hours >= 25
        and coalesce(scored.hours_cv_8m, 0) < 0.30
      ) then 'watch'
    else 'no_flag'
  end as w2_flag_status
from scored
cross join profit_comp_plan_config_values config;
