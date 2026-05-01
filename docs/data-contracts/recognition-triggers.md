# Recognition Triggers

Purpose: record service completion events that are allowed to turn pending revenue-event candidates into recognized revenue.

This keeps Financial Cents/API behavior separate from recognition math. Any upstream source can load a trigger, but only rows exposed through `profit_revenue_events_ready_for_recognition` are eligible to update `profit_revenue_events`.

## Migration

- `supabase/sql/005_profit_recognition_triggers.sql`

## Trigger Table

`profit_recognition_triggers` stores one completion event per source record.

Key fields:

- `source_system`
- `source_record_id`
- `anchor_relationship_id`
- `macro_service_type`
- `service_period_month`
- `completion_date`
- `trigger_type`
- `recognition_action`
- `raw`

## Trigger Types

- `bookkeeping_complete`
- `payroll_processed`
- `tax_filed`
- `tax_extension_filed`
- `advisory_delivered`
- `manual_recognition_approved`

## Ready View

`profit_revenue_events_ready_for_recognition` joins pending revenue candidates to matching triggers by:

- Anchor relationship
- Macro service type
- Service period month, when supplied
- Compatible recognition rule and trigger type

The view emits update-ready fields:

- `recognized_amount_to_apply`
- `recognition_date_to_apply`
- `recognition_period_month_to_apply`
- `next_recognition_status`
- `trigger_reference_to_apply`

## Apply Workflow

- `Profit - 16 Apply Recognition Triggers`
- File: `n8n/workflows/profit-16-apply-recognition-triggers.json`

The workflow reads `profit_revenue_events_ready_for_recognition` and upserts recognized values back into `profit_revenue_events`.

## Financial Cents Path

The FC sync should write only trigger rows. It should not update revenue events directly.

Initial mapping:

- Bookkeeping completion task -> `bookkeeping_complete`
- Payroll processed task -> `payroll_processed`
- Return filed task -> `tax_filed`
- Extension filed task -> `tax_extension_filed`

This is the next API milestone.
