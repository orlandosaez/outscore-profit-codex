# Admin Dashboard Views

Purpose: provide stable Supabase REST surfaces for the admin dashboard without coupling the React app to raw staging tables.

## Migration

- `supabase/sql/009_profit_admin_dashboard_views.sql`

Run after:

- `supabase/sql/004_profit_revenue_events.sql`
- `supabase/sql/007_profit_fc_trigger_loader.sql`
- `supabase/sql/008_profit_comp_w2.sql`

## Views

- `profit_admin_company_dashboard_summary` — latest monthly company GP, latest quarterly gate, revenue status, and FC trigger queue counts.
- `profit_admin_client_gp_dashboard` — recognition-basis client/service GP table with low-GP rank.
- `profit_admin_staff_gp_dashboard` — recognition-basis staff owner rollup.
- `profit_admin_comp_kicker_ledger` — staff kicker accrual ledger.
- `profit_admin_w2_candidates` — W2 `watch`/`convert` candidates only.
- `profit_admin_fc_trigger_queue` — FC task trigger approval queue.

## Inspect Workflow

- `Profit - 23 Admin Dashboard Inspect`
- File: `n8n/workflows/profit-23-admin-dashboard-inspect.json`

The workflow reads all admin dashboard views and returns a compact live smoke-test payload for the app/API layer.
