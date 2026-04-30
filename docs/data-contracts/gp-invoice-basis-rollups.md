# GP Invoice-Basis Rollups

Purpose: provide the first directional Workstream B gross-profit surface from data already loaded into Supabase.

These views are **not** Workstream A recognition output. They use Anchor invoice issue/due dates and line classifications as a temporary revenue basis until the recognition engine writes `RevenueEvent` rows.

## Migration

- `supabase/sql/003_profit_gp_invoice_basis_views.sql`

## Views

### `profit_client_service_monthly_gp_invoice_basis`

One row per month, Anchor relationship, and macro service type.

Inputs:

- `profit_anchor_line_item_classifications`
- `profit_anchor_invoices`
- `profit_time_entries`
- `profit_client_service_owners`
- `profit_staff`
- `profit_anchor_agreements`

Key fields:

- `period_month`
- `anchor_relationship_id`
- `anchor_client_business_name`
- `macro_service_type`
- `primary_owner_staff_name`
- `invoice_revenue_amount`
- `matched_labor_cost`
- `gp_amount`
- `gp_pct`
- `matched_hours`
- `basis = invoice_basis_directional`

### `profit_company_monthly_gp_invoice_basis`

One row per month for company-level directional GP and admin load.

Key fields:

- `invoice_revenue_amount`
- `contractor_labor_cost`
- `gp_amount`
- `gp_pct`
- `total_hours`
- `admin_hours`
- `admin_load_pct`
- `matched_labor_cost`
- `admin_labor_cost`
- `unmatched_labor_cost`

## Caveats

- Revenue is invoice-basis, not recognition-basis.
- Unmatched time is included in company contractor labor but does not allocate to client/service GP.
- Owner attribution uses `profit_client_service_owners` at relationship + macro-service level.
- Final comp should wait for recognized revenue and resolved unmatched labor rules.
