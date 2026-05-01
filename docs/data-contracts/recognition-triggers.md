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

The FC sync writes raw FC clients, projects, and tasks. A separate approval layer turns reviewed FC tasks into trigger rows. It does not update revenue events directly.

Required migration:

- `supabase/sql/007_profit_fc_trigger_loader.sql`

Approval table:

- `profit_fc_task_trigger_approvals`

Candidate/review views:

- `profit_fc_client_anchor_match_candidates` proposes exact normalized FC-to-Anchor client matches.
- `profit_fc_completion_trigger_candidates` shows each completed FC task, suggested trigger type, resolved client/service, approval status, and load status.
- `profit_fc_completion_triggers_ready_to_load` exposes only approved rows with a resolved Anchor relationship, macro service type, completion date, and non-manual trigger type.

Initial mapping:

- Bookkeeping completion task -> `bookkeeping_complete`
- Payroll processed task -> `payroll_processed`
- Return filed task -> `tax_filed`
- Extension filed task -> `tax_extension_filed`

## FC Trigger Load Workflow

- `Profit - 19 Load FC Completion Triggers`
- File: `n8n/workflows/profit-19-load-fc-completion-triggers.json`

The workflow reads `profit_fc_completion_triggers_ready_to_load` and upserts into `profit_recognition_triggers`. Run `Profit - 16 Apply Recognition Triggers` after reviewing the load summary.

## FC Review Helpers

- `Profit - 20 FC Completion Trigger Inspect`
- File: `n8n/workflows/profit-20-fc-completion-trigger-inspect.json`

This workflow summarizes FC client match status, completion trigger candidate status, and ready-to-load trigger counts.

- `Profit - 21 Approve Matched FC Tax Filed Triggers`
- File: `n8n/workflows/profit-21-approve-matched-fc-tax-filed-triggers.json`

This is a conservative starter approval workflow. It approves only pending FC tasks where the suggested trigger is `tax_filed`, the trigger type is `tax_filed`, and the task already has a resolved Anchor relationship and macro service type.
