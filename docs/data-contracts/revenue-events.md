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

## Service Names

`service_name` is raw Anchor operational text from the line item or service description. It may include prorations, client/entity suffixes, parenthetical notes, or other annotations, so it is not enforced as a foreign key to the canonical service taxonomy.

`canonical_service_name` is the nullable FK-safe taxonomy key. Migration `022_profit_canonical_service_aliases.sql` resolves it from `service_name` using exact service-name match, `profit_anchor_service_aliases`, then conservative prefix match. Rows that still cannot be resolved surface in `profit_unresolved_service_names` for manual alias review.

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

### `profit_unresolved_service_names`

Unresolved raw service descriptions grouped by service text and macro service type. This is the V0.6.A intake list for canonical alias review; it should not be auto-fixed without reviewing the operational meaning of each raw line item.

## Caveats

- Until completion triggers are wired, recognition-basis revenue will remain zero.
- Invoice-basis views remain the directional Workstream B surface during this transition.
- Tax prepaid/drawdown logic still needs a dedicated trigger pass once filed and extension data is available.
