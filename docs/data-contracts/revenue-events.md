# Revenue Events

Purpose: create the Workstream A/Workstream B bridge without letting invoice-basis revenue masquerade as recognized revenue.

`profit_revenue_events` starts as a candidate ledger. Anchor invoice line classifications generate rows with `source_amount`, a recognition rule, and a pending status. The row does **not** affect recognition-basis GP until a completion trigger writes `recognized_amount`, `recognition_date`, and `recognition_period_month`.

## Migration

- `supabase/sql/004_profit_revenue_events.sql`

## Workflow

- `Profit - 15 Load Revenue Event Candidates`
- File: `n8n/workflows/profit-15-load-revenue-event-candidates.json`

The workflow reads:

- `profit_anchor_line_item_classifications`
- `profit_anchor_invoices`

The workflow upserts:

- `profit_revenue_events`

## Candidate Rules

- `bookkeeping` -> `bookkeeping_complete_required`, pending Financial Cents bookkeeping completion
- `payroll` -> `payroll_processed_required`, pending Financial Cents payroll processed trigger
- `tax` -> `tax_filed_or_extended_required`, pending filed/extension trigger
- `advisory` -> `advisory_delivery_review_required`, pending manual/advisory review trigger

Candidate rows intentionally set:

- `recognized_amount = 0`
- `recognition_date = null`
- `recognition_period_month = null`
- `trigger_source = null`

## Views

### `profit_client_service_monthly_gp_recognition_basis`

One row per recognition month, Anchor relationship, and macro service type, with matched client/service labor joined in.

### `profit_company_monthly_gp_recognition_basis`

One row per recognition month for company-level GP gate reporting. This includes all contractor labor, including admin and unmatched labor.

### `profit_revenue_event_status_summary`

Operational queue by period, macro service, status, and recognition rule.

## Caveats

- Until completion triggers are wired, recognition-basis revenue will remain zero.
- Invoice-basis views remain the directional Workstream B surface during this transition.
- Tax prepaid/drawdown logic still needs a dedicated trigger pass once filed and extension data is available.
