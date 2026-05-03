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

- `Profit - 22 Approve Matched FC Bookkeeping Complete Triggers`
- File: `n8n/workflows/profit-22-approve-matched-fc-bookkeeping-complete-triggers.json`

This follows the same conservative approval pattern for `bookkeeping_complete`, but also requires a resolved service period before today. Run a read-only dry run grouped by client and period before executing it.

## Manual Recognition Overrides

V0.5 adds manual override support through `profit_recognition_triggers`, not through direct revenue edits. Manual rows use `trigger_type = manual_recognition_approved`, `source_system = manual_override`, and `source_record_id = <revenue_event_key>`.

Required manual fields:

- `manual_override_reason_code`: one of `backbill_pre_engagement`, `client_operational_change`, `entity_restructure`, `service_outside_fc_scope`, `fc_classifier_gap`, `voided_invoice_replacement`, `billing_amount_adjustment`, `other`.
- `manual_override_notes`: required non-empty explanation. When reason is `other`, the API requires at least 20 characters.
- `manual_override_reference`: optional external reference such as an email subject, ticket, or link.
- `approved_by`: currently `orlando`.
- `approved_at`: timestamp of approval.

The API inserts the manual trigger, reads `profit_revenue_events_ready_for_recognition`, and patches the selected event with the ready-view output. Manual overrides produce `recognition_status = recognized_by_manual_override`. The ready view requires `trigger.source_record_id = event.revenue_event_key` for manual overrides so one manual approval cannot recognize sibling events in the same client/service/month. The audit surface reads `profit_manual_recognition_override_audit`, latest approvals first.

### Manual Override Batch ID

`manual_override_batch_id` is nullable and is populated only when multiple sibling revenue events are approved through the V0.5.1 batch path. Each recognized event still receives its own `profit_recognition_triggers` row and its own reason/notes audit trail. Rows in the same batch share one UUID-like batch id so the approval can be reviewed as a group.

## V0.5.2 Service-Aware Tax Recognition

Tax completion triggers (`tax_filed`, `tax_extension_filed`) do not require month equality between `profit_recognition_triggers.service_period_month` and `profit_revenue_events.candidate_period_month`.

For tax triggers, `profit_revenue_events_ready_for_recognition` matches by:

1. `anchor_relationship_id`
2. `macro_service_type = tax`
3. tax form type parsed from FC trigger context (`1040`, `1065`, `1120`, `990`, `990-EZ`, `990-T`)
4. `profit_revenue_events.service_name` joined to `profit_service_recognition_rules.form_type_pattern`
5. invoice-note scope when `profit_anchor_invoices.invoice_note` contains `TY:YYYY`, `FY:YYYY-MM`, or `Amended`

If multiple same-form pending events remain possible and no invoice note disambiguates the target, the ready view does not expose an auto-recognition row. The candidates surface through `profit_tax_recognition_ambiguities` for V0.5.3 run-log review.

`profit_service_recognition_rules.source` and `last_synced_at` are forward-compatible sync metadata. V0.5.2 seeds this table from `docs/service-recognition-rules.md` with `source = manual_seed`; a future Anchor service sync should upsert the same table with `source = anchor_api_sync`.

## V0.5.2.1 Service Crosswalk

`profit_service_recognition_rules` includes three nullable crosswalk columns:

- `fc_tag`: exact Financial Cents tag string from the Anchor service catalog.
- `qbo_category_path`: full QBO product/service category hierarchy from the QBO export.
- `qbo_product_name`: exact QBO product/service name, stored separately from Anchor `service_name` for drift detection.

Shared umbrella tags are valid. `S BILL` maps to Billable Expenses, Remote Desktop Access, and Remote QBD Access, so `fc_tag` must not be unique.

`profit_anchor_services_without_tag` lists configured services without an FC tag and is intended for V0.5.3 pipeline run logs. Missing tags do not block recognition in V0.5.2.1 because recognition still uses `service_name`.
