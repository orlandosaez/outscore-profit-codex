# QBO Collection Loader Contract

Prepaid liability uses cash collected but not yet recognized. QBO is the source of truth for collection status; Anchor remains the source for invoice/agreement/service detail.

## Tables Written

- `profit_cash_collections`
  - One row per QBO payment.
  - Idempotency key: `collection_key = qbo_payment_<QBO Payment Id>`.
  - Unique source guard: `(source_system, source_payment_id)`.
  - Unmatched or ambiguous payments are still inserted with no Anchor invoice ID so they appear in `profit_unallocated_cash_collections`.

- `profit_collection_revenue_allocations`
  - One row per collection/revenue-event allocation.
  - Idempotency key: `(collection_key, revenue_event_key)`.
  - DB trigger enforces allocation caps so allocated cash cannot exceed collected cash or a revenue event's source amount.

## Matching Order

1. QBO payment linked invoice ID -> QBO invoice DocNumber -> Anchor `invoice_number`.
2. Explicit Anchor invoice ID found in memo/reference text.
3. Customer name + amount + date-window fallback.
4. If multiple fallback candidates match, mark ambiguous and leave unallocated for manual review.
5. If no fallback candidates match, mark unmatched and leave unallocated for manual review.

## Allocation Logic

For matched payments, the loader allocates cash across revenue events for the matched Anchor invoice by remaining source amount. Partial payments are prorated. Overpayments are capped at remaining revenue-event source amount. Rounding is pushed to the final allocation row and logged in `rounding_delta`.

## n8n Workflow

- File: `n8n/workflows/profit-24-qbo-collection-loader.json`
- Name: `Profit - 24 QBO Collection Loader`

Required n8n credential before first live run:

- `QuickBooks Online OAuth2` credential on the two QuickBooks nodes.

The workflow also uses the existing Supabase credential:

- `Supabase account 2`

## Review Views

- `profit_prepaid_liability_summary`
  - `tax_deferred_revenue_balance`: QBO Deferred Revenue JE number.
  - `trigger_backlog_balance`: delivered services waiting on FC completion triggers; not a QBO liability entry.
  - `total_prepaid_liability_balance`: reference total only; do not use as a JE amount.
  - `trigger_backlog_note`: fixed UI/help text for the trigger backlog bucket.
- `profit_prepaid_liability_balances`
  - Split by `service_category`: `tax_deferred_revenue`, `pending_recognition_trigger`, or `recognized`.
- `profit_prepaid_liability_ledger`
- `profit_unallocated_cash_collections`
