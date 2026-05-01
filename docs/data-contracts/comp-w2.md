# Compensation and W2 Flags

Purpose: calculate directional staff kicker accruals and W2 conversion flags from recognition-basis GP and contractor workload.

## Migration

- `supabase/sql/008_profit_comp_w2.sql`

Run after:

- `supabase/sql/004_profit_revenue_events.sql`
- `supabase/sql/005_profit_recognition_triggers.sql`
- `supabase/sql/007_profit_fc_trigger_loader.sql`

## Config

`profit_comp_plan_config` stores configurable plan variables:

- `floor_gp_pct` = `0.35`
- `kicker_rate` = `0.20`
- `company_gate_gp_pct` = `0.50`
- `baseline_company_gp_pct` = `0.40`
- `quarterly_target_step_pct` = `0.03`
- `company_gp_target_cap_pct` = `0.65`
- `w2_cost_trigger_amount` = `55000`

## Views

- `profit_company_quarterly_gp_gate` aggregates recognition-basis company GP by quarter and computes hard gate status.
- `profit_staff_monthly_kicker_candidates` computes per-client/service GP above floor for primary-owner staff.
- `profit_staff_monthly_kicker_accruals` applies the prior-quarter company gate and returns monthly staff kicker accruals.
- `profit_staff_monthly_workload` summarizes monthly contractor hours/cost by staff.
- `profit_staff_monthly_w2_conversion_flags` flags `convert`, `watch`, or `no_flag` using annualized cost and workload consistency.

## Inspect Workflow

- `Profit - 22 Comp W2 Inspect`
- File: `n8n/workflows/profit-22-comp-w2-inspect.json`

This workflow summarizes the quarterly gate, staff kicker accruals, and W2 flags for admin review.
