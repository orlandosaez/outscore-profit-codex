# Anchor Line Item Classification

Purpose: classify synced Anchor invoice line items into macro service buckets for performance GP and service-owner attribution.

## Inputs

- `profit_anchor_invoice_line_items` from n8n workflow `Profit - 07 Anchor Invoices Sync`
- `QBO ProductsServicesList_SBC_Accounting_and_Tax,_LLC_4_26_2026.csv`

## Rules

- QBO category `Accounting` -> `bookkeeping`
- QBO category `Tax Work` -> `tax`
- QBO category `Payroll` -> `payroll`
- QBO category `Advisory` -> `advisory`
- Known pass-through or non-service rows are excluded from revenue allocation:
  - `Billable Expense`
  - `QuickBooks Payments Fees`
  - `Other Service Income`
  - `Uncategorized Income`
  - product names containing `expense` or `fee`
  - QBO category `Other`
- Bundle parent invoice rows are excluded when child line items exist, because the children carry the service split and the parent would double-count revenue.
- If Anchor sends `Category:Name` and the product name is not present in the QBO export, the known category prefix is used as a fallback.

## Outputs

Generated locally:

- `build/anchor_line_item_classifications_review.csv`
- `build/anchor_line_item_classifications_load.sql`

The SQL creates and upserts:

- `profit_anchor_line_item_classifications`

Columns:

- `anchor_line_item_id`
- `anchor_invoice_id`
- `anchor_relationship_id`
- `parent_line_item_id`
- `qbo_product_name`
- `source_name`
- `amount`
- `revenue_amount`
- `macro_service_type`
- `include_in_revenue_allocation`
- `classification_reason`
- `classified_at`

## Current Live Run

As of the first live export:

- Line items classified: 393
- Unclassified line items: 0
- Included revenue amount: 102,979.68
- Service rows by macro:
  - advisory: 7
  - bookkeeping: 84
  - payroll: 66
  - tax: 149
- Excluded rows:
  - bundle parent: 67
  - other/pass-through: 20

## Next Use

Revenue events should join `profit_anchor_line_item_classifications` to `profit_client_service_owners` on:

- `anchor_relationship_id`
- `macro_service_type`
- event/recognition date between `effective_from` and `effective_to`

This keeps the client/service owner model without adding service-template-level complexity yet.
