# Anchor Sync Contract

These n8n workflows pull Anchor into Supabase as the revenue-side source for Workstream A/B modeling.

## Imported Workflows

- `Profit - 04 Anchor Agreements Inspect` — verifies `GET /agreements` and `GET /agreements/{relationshipId}` shape.
- `Profit - 05 Anchor Agreements Sync` — syncs active agreements into `profit_anchor_agreements`.
- `Profit - 06 Anchor Invoices Inspect` — verifies `GET /invoices` and `GET /invoices/{invoiceId}` shape.
- `Profit - 07 Anchor Invoices Sync` — syncs invoice headers into `profit_anchor_invoices` and invoice lines into `profit_anchor_invoice_line_items`.

## Agreement Sync

`profit_anchor_agreements.raw` stores the full Anchor agreement detail plus a derived `profitSyncServiceSummary`.

`profitSyncServiceSummary` flattens top-level services and bundle child services:

- `service_id`
- `parent_service_id`
- `service_template_id`
- `name`
- `occurrence`
- `trigger`
- `is_billed_upfront`
- `pricing_type`
- `price`
- `status`
- `is_paused`
- `is_bundle_parent`
- `is_bundle_child`

## Invoice Line Sync

Invoice line items are flattened recursively from `lineItems`, `groupedLineItems`, and `subItems`.

Bundle child line items use these fallbacks:

- `service_id = lineItem.serviceId ?? lineItem.origin.serviceBundle.bundleItemId`
- `service_template_id = lineItem.serviceTemplateId ?? lineItem.origin.serviceBundle.serviceTemplateId`

This is important because Anchor bundle children often do not expose `serviceTemplateId` at the top level.

## Current Limits

- Sync currently pulls active agreements only.
- Invoice list calls use `limit=100` per relationship and do not paginate yet.
- QBO remains read-only; Anchor/QBO sync status is stored from Anchor invoice payloads, but no QBO writes happen here.
