# Financial Cents Sync

Purpose: pull FC clients, projects, and completed tasks into Supabase so completion triggers can be reviewed before they recognize revenue.

The FC API docs confirm:

- Base URL: `https://app.financial-cents.com/api/v1`
- Auth: `Authorization: Bearer <personal_access_token>`
- Token location: FC web app, Settings -> API Settings
- Rate limit: 250 authenticated requests per minute
- Useful endpoints:
  - `GET /clients`
  - `GET /projects`
  - `GET /tasks`
  - `GET /time-activities`

## Migration

- `supabase/sql/006_profit_financial_cents_sync.sql`

## Workflow

- `Profit - 17 Financial Cents Sync`
- File: `n8n/workflows/profit-17-financial-cents-sync.json`

The workflow reads:

- `GET /clients`
- `GET /projects`
- `GET /tasks?status=completed`

The workflow upserts:

- `profit_fc_clients`
- `profit_fc_projects`
- `profit_fc_tasks`

## Credential

Create an n8n HTTP Header Auth credential:

- Name: `Financial Cents API - Production`
- Header name: `Authorization`
- Header value: `Bearer <FC_PERSONAL_ACCESS_TOKEN>`

After import, open the FC sync workflow and select this credential on each Financial Cents HTTP node.

## Review View

`profit_fc_completed_task_review` shows completed FC tasks with:

- client/project/task context
- Anchor relationship match, if available
- suggested trigger type
- suggested macro service type
- suggested service period month

This is only a review surface. It does not write recognition triggers.

## Next Step

After the first live FC sync:

1. Match FC clients to Anchor relationships in `profit_fc_client_anchor_matches`.
2. Review suggested task trigger types from `profit_fc_completed_task_review`.
3. Build the approved loader from review rows into `profit_recognition_triggers`.
4. Run `Profit - 16 Apply Recognition Triggers`.
