# SLA Dashboard Data Contract

## Overview

The SLA dashboard is the read-only operator surface for fulfillment timeliness, staff workload, breach triage, fixed-window staff performance, and Anchor backfill convergence. SQL owns the canonical SLA facts; the API exposes paginated rows with validation; the frontend renders those facts without recomputing SLA state.

Frontend routes:

- `/admin/sla`
- `/admin/sla/clients`
- `/admin/sla/workload`
- `/admin/sla/queue`
- `/admin/sla/performance`
- `/admin/sla/backfill`

## SQL Views

- `profit_sla_project_statuses`: normalizes FC project workflow-status tags into one current workflow status per project/client/service context.
- `profit_sla_service_items`: canonical service-item grain for SLA target days, age days, workflow status, assigned staff, and locked SLA state.
- `profit_sla_client_status`: per-client rollup of service-item SLA state, counts, worst state, and next action context.
- `profit_sla_staff_workload`: staff workload summary derived from assigned service items and their current SLA states.
- `profit_sla_breach_queue`: breach and at-risk triage queue for service items that need operator attention.
- `profit_sla_staff_service_performance_90d`: fixed 90-day staff/service performance view for completion timeliness and breach history.
- `profit_sla_anchor_backfill_queue`: read-only convergence queue for QuickBooks-settled classifications that have QBO payment evidence and are missing Anchor settlement linkage.

## API Endpoints

All SLA endpoints are `GET` routes and return paginated payloads. Unless noted otherwise, the response shape is:

```json
{ "rows": [], "limit": 50, "offset": 0, "total_count": 0 }
```

- `GET /api/profit/admin/sla/summary` returns dashboard summary rows as `{rows, limit, offset, total_count}`.
- `GET /api/profit/admin/sla/clients` returns client rollup rows as `{rows, limit, offset, total_count}`.
- `GET /api/profit/admin/sla/workload` returns staff workload rows as `{rows, limit, offset, total_count}`.
- `GET /api/profit/admin/sla/queue` returns breach/at-risk queue rows as `{rows, limit, offset, total_count}`.
- `GET /api/profit/admin/sla/performance` returns staff/service performance rows as `{rows, limit, offset, total_count, window_days: 90}`.
- `GET /api/profit/admin/sla/backfill` returns Anchor backfill queue rows as `{rows, limit, offset, total_count}`.

## Locked SLA States

The locked SLA states are:

- `on_track`
- `at_risk`
- `breached`
- `waiting_on_client`
- `not_applicable`

State precedence is:

```text
not_applicable > waiting_on_client > breached > at_risk > on_track
```

SQL is the canonical source for state classification. API and frontend code must not reclassify service items from raw age, target-day, or workflow-status fields.

## At-Risk Threshold Formula

The at-risk threshold is:

```text
age_days >= greatest(target_sla_day - 2, ceil(target_sla_day * 0.8))
```

SQL is the canonical source for this formula and owns any future change to the threshold.

## Workflow-Status Tag Mapping

V0.6.D backfills three FC project workflow-status tags into `profit_fc_project_tags` with `tag_type='workflow_status'`:

- `Waiting on Client`
- `In Preparation`
- `Ready to Submit`

`Waiting on Client` maps to canonical SLA state `waiting_on_client` when it applies. `In Preparation` and `Ready to Submit` remain workflow-status display/filter values unless SQL state logic promotes them through another locked state.

The `profit_fc_project_tags.tag_type` constraint extension allows future Workflow 17 updates to maintain workflow-status tags directly instead of treating them as `unknown` or dropping them.

## Staff Workload Assignment Fallback

Staff workload assignment uses the task assignee first, from `profit_fc_tasks.user_name`. When a service item has no task assignee, staff assignment falls back to FC client staff tags. This fallback keeps workload rows useful for client-owned service items even when task-level ownership is not populated.

## Fixed 90-Day Performance Scope

`profit_sla_staff_service_performance_90d` uses a fixed SQL window of `interval '90 days'`. The API advertises this as `window_days: 90`.

There is no parameterization in V0.6.D. Override the performance window only by changing the SQL view definition.

## Anchor Backfill Queue

`profit_sla_anchor_backfill_queue` is a read-only convergence queue for classifications with verdict `SETTLED_VIA_QUICKBOOKS_PAYMENT`. It surfaces QBO payment evidence, missing-Anchor settlement signal, and the auto-transition eligibility flag needed to identify classifications that can converge after Anchor payment backfill is available.

The `/admin/sla/backfill` route and `GET /api/profit/admin/sla/backfill` endpoint expose this queue for review only. V0.6.D does not add write controls, mutation endpoints, or operator actions for the backfill queue.
