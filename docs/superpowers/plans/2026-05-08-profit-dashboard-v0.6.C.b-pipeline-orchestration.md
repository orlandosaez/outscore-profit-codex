# Profit Dashboard V0.6.C.b Pipeline Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the V0.6.C.b operational pipeline layer: Workflow 26 orchestration, Workflow 05/25 fixes, pipeline-run API endpoints, and React pipeline status/run-log surfaces.

**Architecture:** This is a workflow/API/frontend slice over the V0.6.C.a backend data layer. The API owns manual-run lock acquisition in `profit_pipeline_runs`, n8n Workflow 26 executes the ordered pipeline and writes step/run status, and React surfaces run state through a dashboard tile, audit strip, shared refresh dialog, and dedicated run-log route. No new SQL migrations are added; all database writes use C.a tables/functions and existing B/C contracts.

**Tech Stack:** n8n workflow JSON, Supabase REST/RPC through existing n8n credentials, FastAPI, Pydantic, existing Supabase REST client, React 19, Vite 6, React Router, lucide-react, custom CSS, Python `pytest` static/API tests, `npm run build`, existing VPS deploy/curl/browser-handoff pattern.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: V0.6.C pipeline orchestration spec, including 13-step pipeline, run-log UI, and migration ordering.
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.C.a-pipeline-backend.md`: C.a backend contract for run tables, expanded apply, reconcile, and diagnostic views.
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.b-audit-dashboard-frontend.md`: closest workflow/API/frontend plan template and shipped dashboard conventions.
- `docs/data-contracts/fulfillment-classifications.md`: Pipeline Run Log Schema, Apply Transitions V0.6.C.a, Match Reconciliation, Pipeline Diagnostic Views, Audit Dashboard API Conventions.
- `docs/tech-debt.md`: Workflow 05 limit/pagination entry, no-anchor-match auto-transition limitation, reconcile handoff, stuck-run deferral, and deprecated `auto_apply_enabled_in_b2a`.
- `supabase/sql/026_profit_pipeline_runs.sql`, `026a_profit_apply_classification_transitions_v2.sql`, `026b_profit_reconcile_fc_client_anchor_matches.sql`, `026c_profit_pipeline_diagnostic_views.sql`: C.a data-layer surface.
- `n8n/workflows/profit-05-anchor-agreements-sync.json`: Workflow 05 limit fix.
- `n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json`: Workflow 25 reconcile wiring.
- Existing workflow JSON patterns:
  - `n8n/workflows/profit-17-financial-cents-sync.json`: Supabase RPC call precedent.
  - `n8n/workflows/profit-07-anchor-invoices-sync.json`, `profit-11-classify-anchor-invoice-line-items.json`, `profit-15-load-revenue-event-candidates.json`, `profit-24-qbo-collection-loader.json`, `profit-16-apply-recognition-triggers.json`, `profit-19-load-fc-completion-triggers.json`, `profit-21-approve-matched-fc-tax-filed-triggers.json`, `profit-22-approve-matched-fc-bookkeeping-complete-triggers.json`: sub-workflows consumed by Workflow 26.
- Existing frontend/API files:
  - `profit_api/app.py`
  - `profit_api/audit.py`
  - `profit_api/supabase.py`
  - `app/frontend/src/App.jsx`
  - `app/frontend/src/components/PortalNav.jsx`
  - `app/frontend/src/routes/Dashboard.jsx`
  - `app/frontend/src/routes/AuditDashboard.jsx`
  - `app/frontend/src/routes/ManualRecognition.jsx`
  - `app/frontend/src/styles.css`

## Gate Decisions Locked Into This Plan

### G1: Workflow 26 Step Composition And Error Semantics

- Workflow 26 records 8 effective `profit_pipeline_run_steps` rows per run:
  1. `anchor_agreement_sync`: Workflow 05.
  2. `anchor_invoice_revenue_sync`: Workflow 07 -> Workflow 11 -> Workflow 15.
  3. `qbo_collection_loader`: Workflow 24.
  4. `fc_completion_sync`: Workflow 17 -> Workflow 21 -> Workflow 22 -> Workflow 19.
  5. `recognition_trigger_apply`: Workflow 16.
  6. `fc_anchor_match_refresh`: Workflow 25, whose output includes reconcile results.
  7. `fulfillment_audit_refresh`: diagnostics plus `profit_run_inactive_client_reemergence_scan(now())`.
  8. `classification_transition_apply`: `profit_apply_classification_transitions(now(), false)`.
- Sub-workflows inside grouped steps run strictly sequentially. There are no parallel branches.
- Step 2 order is hard: W07 invoices -> W11 line-item classifications -> W15 revenue events.
- Step 4 order is hard: W17 FC sync -> W21 tax approvals -> W22 bookkeeping approvals -> W19 completion-trigger load.
- Steps 1-6 are hard dependencies. Any failure sets run status to `failed` and halts.
- Steps 7-8 are soft. Failures are captured and the run can finish as `partial`.
- Reconcile inside step 6 is best-effort. Reconcile failure does not fail W25 or Workflow 26 step 6.
- API inserts the `profit_pipeline_runs` row with `status='running'`; Workflow 26 receives `pipeline_run_id` from the webhook payload.
- Workflow 26 inserts a step row at step start and updates it at step finish.
- Workflow 26 finalizes `profit_pipeline_runs.status` and `summary` at the end.
- Summary fields:
  - `total_steps_completed`
  - `total_steps_failed`
  - `total_rows_affected`
  - optional `error_summary`
  - optional `notable_findings`
- Grouped-step `rows_affected` equals the sum of all sub-operation `rows_affected`.
- `details.sub_workflows` carries per-sub-operation detail:

```json
[
  {
    "name": "profit-07-anchor-invoices-sync",
    "status": "success",
    "rows_affected": 10,
    "finished_at": "2026-05-08T12:00:00Z",
    "error": null
  }
]
```

- Pure DB function steps use returned row count for top-level `rows_affected`; `details` stores function result rows and diagnostic counts.
- Repo inspection found no existing chained-workflow precedent and no local `Execute Workflow` node usage. Workflow 26 Task 7 has a hard preflight to confirm `n8n-nodes-base.executeWorkflow` in the live n8n instance. If unavailable or operationally awkward, halt and switch Workflow 26 to webhook-trigger sub-workflows with the same step contract.

### G2: Manual Refresh API And Concurrency Lock

- Add three endpoints:
  - `POST /api/profit/admin/audit/pipeline-runs`
  - `GET /api/profit/admin/audit/pipeline-runs`
  - `GET /api/profit/admin/audit/pipeline-runs/{pipeline_run_id}`
- POST behavior:
  1. Insert `profit_pipeline_runs` with `run_source='manual'`, `status='running'`, `triggered_by`, `summary='{}'`.
  2. Call Workflow 26 webhook with `pipeline_run_id`.
  3. Return immediately after n8n accepts.
  4. If webhook call fails after row insert, delete the inserted run row before returning `500`.
- n8n webhook request:

```http
POST <PROFIT_PIPELINE_WEBHOOK_URL>
Content-Type: application/json
X-Profit-Pipeline-Secret: <PROFIT_PIPELINE_WEBHOOK_SECRET>
```

```json
{
  "pipeline_run_id": "00000000-0000-0000-0000-000000000000",
  "run_source": "manual",
  "triggered_by": "orlando",
  "requested_at": "2026-05-08T12:00:00Z",
  "requested_by": "profit_api"
}
```

- Workflow 26 webhook response mode must be immediate. Deploy checkpoint curls the webhook and expects a response in under 2 seconds with `{ "accepted": true, "pipeline_run_id": "..." }`.
- Extend `SupabaseRestError` as a discrete task. It preserves:
  - `status_code`
  - `postgres_code`
  - `constraint_name`
  - parsed `body`
  - message
- Pipeline service maps `postgres_code == '23505'` and `constraint_name == 'idx_profit_pipeline_runs_one_running'` to `409`.
- 409 race handling:
  1. Catch unique violation.
  2. Select current running row.
  3. If no running row exists, retry insert once.
  4. If retry succeeds, return `200`.
  5. If retry fails and no running row exists, return `500` with diagnostic detail.
  6. If running row exists, return `409`.
- 409 detail:

```json
{
  "current_run_id": "00000000-0000-0000-0000-000000000000",
  "started_at": "2026-05-08T12:00:00Z",
  "triggered_by": "orlando",
  "message": "Pipeline already running. Refresh again when complete."
}
```

- GET list response:

```json
{
  "rows": [],
  "limit": 20,
  "offset": 0
}
```

- GET list clamps `limit` to `1..200`, default `20`, and `offset >= 0`.
- GET single returns `{ "run": {...}, "steps": [] }` with `200` when the run exists but has no steps yet.
- `duration_seconds` is computed on read from `finished_at - started_at`; it is not stored.
- Frontend polling cadence is 4 seconds.
- Stuck-run detection is deferred to V0.6.C.c and documented as tech debt. C.b manual cleanup remains SQL-only operationally.

### G3: Run Log UI Placement And Pipeline Status Tile

- Add `/admin/pipeline` and `/admin/pipeline/:pipelineRunId` routes.
- Add a `Pipeline` nav item.
- Add a compact pipeline status tile to the main dashboard `/`.
- Add a compact pipeline status strip to `/admin/audit`.
- Add a full run-log page at `/admin/pipeline`.
- Add a shared `PipelineRefreshDialog.jsx` component used by:
  - main dashboard tile
  - audit dashboard strip
  - run-log page header
- `triggered_by` input is editable, defaults to `orlando`, and is not validated against a hardcoded operator list.
- Successful manual refresh navigates to `/admin/pipeline/{new_pipeline_run_id}` using React Router `useNavigate`.
- Polling only runs on `/admin/pipeline/:pipelineRunId` when that run's status is `running`.
- Polling effect clears interval on status transition and component unmount.
- No polling runs on the `/admin/pipeline` list route.
- Empty states:
  - Tile: `Pipeline: No runs yet` with refresh enabled.
  - Audit strip: `Pipeline: No runs yet` with refresh enabled.
  - Run log: `No pipeline runs to show. Trigger a manual refresh to start.` with refresh enabled.
- Long `error_summary`, `notable_findings`, and step `details.error` excerpts truncate around 200 characters with ellipsis in tables. Full text remains visible in detail/expanded view or hover.
- Step status badges reuse the run-level status visual vocabulary.
- New CSS classes use `pipeline-` prefix and reuse `.panel`, `.panel-title`, `.btn`, `.icon-button`, `.success-toast`, `.error-toast`, and `.table-wrap`.

### G4: Workflow 05 Limit Fix And Workflow 25 Reconcile Wiring

- Two-phase workflow deploy order is locked.
- Phase 1: W05 before W25.
  - Pre-deploy baseline: `profit_anchor_agreements` expected 38 active / 12 terminated / 2 stale / 52 total.
  - Change W05 URL from `https://api.sayanchor.com/agreements?limit=50` to `https://api.sayanchor.com/agreements?limit=100`.
  - Import and run W05 once.
  - Post-deploy expected: 40 active / 12 terminated / 0 stale / 52 total.
  - YV HB/PSL agreements become active.
  - Stop and report deltas.
- Phase 2: W25 after W05.
  - Add Supabase RPC HTTP node after upsert:
    - URL: `/rest/v1/rpc/profit_reconcile_fc_client_anchor_matches`
    - body: `{ "p_dry_run": false }`
    - `continueOnFail=true`
  - Reconcile runs inside W25 so standalone W25 runs stay self-consistent.
  - W25 output includes:
    - `upsertedFcClientMatchCount`
    - `reconciledDemotedMatchCount`
    - `reconcileStatus`: `ok` or `error`
    - `reconcileError`
  - Reconcile failure does not fail W25 or Workflow 26 step 6.
  - Standalone W25 runs do not write `profit_pipeline_run_steps`.
  - Workflow 26 writes the step row using W25 output.
  - Post-W25 expected: YV HB/PSL re-added to `profit_fc_client_anchor_matches` as `auto_exact`, reconcile demotions 0, final persisted matches 30 auto_exact + 12 manual_override = 42.
- Rollback uses git history, not `/tmp` copies:

```bash
git checkout HEAD~1 -- n8n/workflows/profit-05-anchor-agreements-sync.json
git checkout HEAD~1 -- n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json
```

Then re-import the rolled-back workflow JSON in n8n.

### G5: `auto_apply_enabled` Field Migration

- Detail endpoint transition-rule rows emit both fields:
  - canonical `auto_apply_enabled`
  - deprecated `auto_apply_enabled_in_b2a`
- Canonical `auto_apply_enabled` is true only for enabled rules in the C.b active apply set:
  - `PENDING_ENGAGEMENT_DRAFT` / `PENDING_ENGAGEMENT_SENT` + `active_agreement_appears`
  - `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_mid_cycle`
  - `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_group_billed`
  - `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_group_parent`
  - `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_standalone_mid_cycle`
- Canonical false for:
  - disabled rules
  - `SETTLED_VIA_QUICKBOOKS_PAYMENT` + `anchor_backfill_*` rules
  - `INACTIVE_FORMER_CLIENT` + `any_active_signal_returns`
- Legacy `auto_apply_enabled_in_b2a` remains unchanged:
  - true only for `active_agreement_appears` from `PENDING_ENGAGEMENT_DRAFT` or `PENDING_ENGAGEMENT_SENT`.
- Frontend reads canonical first:

```js
const autoApplyEnabled = rule.auto_apply_enabled ?? rule.auto_apply_enabled_in_b2a;
```

- Badge text:
  - `Will auto-apply on next pipeline run`
  - `Eligible — manual apply only`
  - `Not eligible: <signal_reason>`
- Remove stale text `V0.6.C will automate` from frontend source.
- Deprecation tech-debt text:

> `auto_apply_enabled_in_b2a` in detail endpoint transition_rules array is deprecated as of V0.6.C.b. Removal target: after V0.6 ships AND 30 days of dual-emission with no observed legacy-only reads in API access logs. Frontend reads `auto_apply_enabled` with fallback to legacy; once frontend bundles are confirmed deployed everywhere (no cached old bundles in browsers), the legacy field can be removed in V0.7. Track in V0.7 backlog.

## Scope

In scope:

- Workflow 05 limit fix.
- Workflow 25 reconcile node and output extension.
- New Workflow 26 chained pipeline JSON.
- Pipeline API service and three endpoints.
- Supabase REST structured error extension.
- 409 lock conflict and retry-once race handling.
- Audit detail endpoint dual-emission of `auto_apply_enabled` and `auto_apply_enabled_in_b2a`.
- `/admin/pipeline` and `/admin/pipeline/:pipelineRunId`.
- Pipeline status tile on main dashboard.
- Pipeline status strip on audit dashboard.
- Shared `PipelineRefreshDialog`.
- Pipeline polling lifecycle.
- Empty states for pre-first-run pipeline surfaces.
- Frontend badge wording update.
- Static/API/workflow tests, `npm run build`, deploy, curl spot-checks, browser handoff.
- Data-contract and tech-debt updates.

Out of scope:

- New SQL migrations or views.
- Cron schedule.
- Run-stability monitoring or stale-run cleanup automation.
- V0.6.D SLA dashboard.
- Removing `auto_apply_enabled_in_b2a`.
- Anchor service API sync replacing static seeds.
- 21 service-alias backlog seeding.
- New npm packages.
- Auth/permissions changes beyond existing nginx basic auth and n8n shared-secret webhook.
- Adding `profit_pipeline_run_steps` writes to standalone W25.
- V0.6.C.c cron or alerting work.

## Deploy Checkpoints

Stop after every deploy checkpoint and wait for orchestrator approval.

1. **Workflow 05 Phase 1**
   - Pre-baseline `profit_anchor_agreements` distribution.
   - Deploy W05 limit=100.
   - Run W05.
   - Verify 40 active / 12 terminated / 0 stale / 52 total.
   - Stop and report W05 delta.

2. **Workflow 25 Phase 2**
   - Pre-baseline `profit_fc_client_anchor_matches` distribution.
   - Deploy W25 reconcile node.
   - Run W25.
   - Verify output schema and final matches 30 auto_exact + 12 manual_override = 42.
   - Stop and report W25 delta.

3. **Workflow 26 Deploy**
   - Verify Execute Workflow node availability or approved webhook fallback.
   - Import/deploy Workflow 26.
   - Curl webhook; response must be under 2 seconds and include `{accepted: true}`.
   - Execute one manual pipeline run through the webhook/API path.
   - Verify 8 step rows, sequential grouped-step detail, correct final status.
   - Stop and report run id, step rows, and summary.

4. **API Deploy**
   - Deploy `profit_api`.
   - Curl:
     - `GET /pipeline-runs`
     - `GET /pipeline-runs/{id}`
   - Do not curl `POST /pipeline-runs` at this checkpoint. Workflow 26 does not exist until Task 9, so POST would correctly insert a running row, fail webhook delivery, clean up the row, and return 500. That path is tested locally and becomes operationally useful after Task 9.
   - Verify `duration_seconds` computed on read and empty steps return `200`.
   - Stop and report curl bodies.

5. **Frontend Deploy**
   - `npm run build` green.
   - Deploy frontend.
   - Browser handoff for:
     - main dashboard tile
     - audit strip
     - `/admin/pipeline`
     - `/admin/pipeline/:pipelineRunId`
     - shared refresh dialog
     - polling cleanup behavior
   - Stop for Orlando browser spot-check.

6. **Final Verification**
   - Targeted pytest.
   - Full pytest.
   - Final `npm run build`.
   - Scope-boundary `git diff --name-only`.
   - Final live curl summary.
   - Stop before commit.

## Files

Create:

- `profit_api/pipeline.py`: PipelineService, n8n webhook client wrapper, run-list/detail methods, manual-run trigger logic, 409 race handling.
- `tests/test_profit_api_pipeline.py`: API/service tests for pipeline endpoints, lock conflict, retry-once race, webhook cleanup, duration computation, empty steps.
- `app/frontend/src/components/PipelineRefreshDialog.jsx`: shared manual refresh dialog used by three hosts.
- `app/frontend/src/components/PipelineStatusSummary.jsx`: compact status rendering shared by tile/strip/header.
- `app/frontend/src/routes/PipelineRuns.jsx`: `/admin/pipeline` and `/admin/pipeline/:pipelineRunId` page.
- `n8n/workflows/profit-26-pipeline-orchestration.json`: Workflow 26.

Modify:

- `profit_api/supabase.py`: structured `SupabaseRestError`.
- `profit_api/app.py`: pipeline service injection, Pydantic payloads, three pipeline routes, structured 409/500 mapping.
- `profit_api/audit.py`: dual-emission `auto_apply_enabled` + `auto_apply_enabled_in_b2a`.
- `tests/test_profit_api_supabase.py`: structured PostgREST error parsing tests.
- `tests/test_profit_api_audit.py`: dual-emission tests.
- `tests/test_profit_admin_frontend.py`: route/static UI tests, badge wording tests, polling cleanup tests, shared dialog import tests.
- `tests/test_n8n_workflows.py`: W05, W25, W26 workflow JSON shape tests.
- `app/frontend/src/App.jsx`: pipeline routes.
- `app/frontend/src/components/PortalNav.jsx`: Pipeline nav link.
- `app/frontend/src/routes/Dashboard.jsx`: pipeline status tile.
- `app/frontend/src/routes/AuditDashboard.jsx`: pipeline status strip, badge wording, canonical auto-apply read.
- `app/frontend/src/styles.css`: append `pipeline-` styles only.
- `n8n/workflows/profit-05-anchor-agreements-sync.json`: limit=100.
- `n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json`: reconcile node and summary output.
- `docs/data-contracts/fulfillment-classifications.md`: pipeline API conventions, W25 standalone run-log note, auto-apply field deprecation.
- `docs/tech-debt.md`: SupabaseRestError adoption note, stuck-run detection, free-text `triggered_by`, deprecated legacy field.

Do not modify:

- `supabase/sql/**`
- `n8n/workflows/profit-07-*`, `profit-11-*`, `profit-15-*`, `profit-16-*`, `profit-17-*`, `profit-19-*`, `profit-21-*`, `profit-22-*`, `profit-24-*` except if Workflow 26 uses immutable references to their IDs/names.
- `docs/audits/**`
- package dependency files for new npm dependencies.
- V0.6.D files or `027_profit_sla_views.sql`.

## Tasks

### Task 1: Structured Supabase REST Errors - Red Tests

**Files:**
- Modify: `tests/test_profit_api_supabase.py`
- Modify: `tests/test_profit_api_pipeline.py` if it already exists from a previous attempt; otherwise create in Task 3.

- [ ] **Step 1: Add failing Supabase error tests**

Add tests that simulate a PostgREST unique-violation body:

```json
{
  "code": "23505",
  "details": "Key ((status))=(running) already exists.",
  "hint": null,
  "message": "duplicate key value violates unique constraint \"idx_profit_pipeline_runs_one_running\""
}
```

Assertions:

- `SupabaseRestError.status_code == 409`
- `postgres_code == "23505"`
- `constraint_name == "idx_profit_pipeline_runs_one_running"`
- `body["code"] == "23505"`
- `str(error)` does not expose service role key.

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_supabase.py -q
```

Expected: FAIL because `SupabaseRestError` does not yet expose structured fields.

### Task 2: Structured Supabase REST Errors - Implementation

**Files:**
- Modify: `profit_api/supabase.py`
- Modify: `tests/test_profit_api_supabase.py`

- [ ] **Step 1: Extend `SupabaseRestError`**

Implement:

```python
class SupabaseRestError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        postgres_code: str | None = None,
        constraint_name: str | None = None,
        body: dict[str, object] | None = None,
    ) -> None:
        self.status_code = status_code
        self.postgres_code = postgres_code
        self.constraint_name = constraint_name
        self.body = body or {}
        super().__init__(message)
```

Parse `HTTPError.fp` JSON bodies in `_write_json` and `read_view`, extracting constraint name from the Postgres `message` string when present.

- [ ] **Step 2: Run green test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_supabase.py -q
```

Expected: PASS.

- [ ] **Step 3: Run existing API smoke tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py tests/test_profit_api_dashboard.py tests/test_profit_api_manual_recognition.py -q
```

Expected: PASS; existing code keeps working with the richer error class.

### Task 3: Pipeline API Red Tests

**Files:**
- Create: `tests/test_profit_api_pipeline.py`
- Modify: `profit_api/app.py` later
- Create: `profit_api/pipeline.py` later

- [ ] **Step 1: Add service and route tests**

Cover:

- `GET /api/profit/admin/audit/pipeline-runs` returns `{rows, limit, offset}`.
- `GET /api/profit/admin/audit/pipeline-runs/{id}` returns `200` with `{run, steps: []}` when no steps exist.
- `duration_seconds` is computed on read and null for running rows.
- `POST /pipeline-runs` inserts running row, calls webhook, returns run immediately.
- Webhook failure deletes inserted row before returning 500.
- Unique violation returns 409 with current running row.
- Unique violation followed by no current row retries insert once and returns 200.
- Retry failure with no current row returns 500 diagnostic.

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_pipeline.py -q
```

Expected: FAIL because `profit_api.pipeline` and routes do not exist.

### Task 4: Pipeline API Implementation And Deploy Checkpoint

**Files:**
- Create: `profit_api/pipeline.py`
- Modify: `profit_api/app.py`
- Modify: `tests/test_profit_api_pipeline.py`

- [ ] **Step 1: Implement `PipelineService`**

Implement methods:

- `list_runs(limit, offset)`
- `run_detail(pipeline_run_id)`
- `trigger_manual_run(triggered_by)`

Use existing Supabase REST methods only. Add a small webhook client using `urllib.request.Request` so no new dependency is needed.

- [ ] **Step 2: Wire `create_app` injection and routes**

Add optional `pipeline_service` injection, Pydantic payload for `triggered_by`, and three routes under `/api/profit/admin/audit/pipeline-runs`.

Add this comment in the POST handler or service method that triggers n8n:

```python
# Webhook target must be deployed before this endpoint is operationally usable;
# pre-Task-9 calls return 500 after running-row cleanup.
```

- [ ] **Step 3: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_pipeline.py tests/test_profit_api_supabase.py -q
```

Expected: PASS.

- [ ] **Step 4: Deploy API**

Run:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service && systemctl status profit-admin-api.service --no-pager"
```

- [ ] **Step 5: Curl checkpoint**

Run curls for:

```bash
curl -s https://app.outscore.com/profit/api/profit/admin/audit/pipeline-runs
```

Expected initially:

```json
{"rows":[],"limit":20,"offset":0}
```

Also curl a fake UUID detail and expect `404`.

Do not issue `POST /api/profit/admin/audit/pipeline-runs` during Task 4 deploy verification. Workflow 26 is intentionally not deployed yet, so POST is a pre-operational path until Task 9.

Stop and report before workflow deploy tasks if API behavior diverges.

### Task 5: Workflow 05 Limit Fix - Red Tests

**Files:**
- Modify: `tests/test_n8n_workflows.py`
- Modify later: `n8n/workflows/profit-05-anchor-agreements-sync.json`

- [ ] **Step 1: Add failing W05 assertions**

Assert:

- Workflow 05 contains `https://api.sayanchor.com/agreements?limit=100`.
- Workflow 05 no longer contains `agreements?limit=50`.

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py -q
```

Expected: FAIL because W05 still uses limit 50.

### Task 6: Workflow 05 Limit Fix - Implementation And Phase 1 Deploy

**Files:**
- Modify: `n8n/workflows/profit-05-anchor-agreements-sync.json`
- Modify: `tests/test_n8n_workflows.py`

- [ ] **Step 1: Capture pre-deploy live baseline**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "select display_status, count(*) from profit_anchor_agreements group by display_status order by display_status;"'
```

Expected before W05 fix: 38 active / 12 terminated / 2 stale / 52 total. If live drift differs, report and re-baseline before editing.

- [ ] **Step 2: Change URL**

Change the W05 `Fetch API Visible Agreements` URL to `https://api.sayanchor.com/agreements?limit=100`.

- [ ] **Step 3: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py -q
```

Expected: PASS.

- [ ] **Step 4: Import and run W05**

Use the established n8n import/run method for workflow JSON. Do not modify any other W05 node.

- [ ] **Step 5: Post-deploy checkpoint**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "select display_status, count(*) from profit_anchor_agreements group by display_status order by display_status;" -c "select client_business_name, display_status from profit_anchor_agreements where client_business_name ilike any (array['\''%yv enterprises hb%'\'','\''%yv enterprises psl%'\'']) order by client_business_name;"'
```

Expected: 40 active / 12 terminated / 0 stale / 52 total; YV HB/PSL active.

STOP. Report W05 deltas: pre-deploy distribution (38 active / 12 terminated / 2 stale), post-deploy distribution (40 active / 12 terminated / 0 stale), and YV HB/PSL transition from stale to active. Wait for explicit orchestrator approval before starting Task 7. Do not begin W25 work until Phase 1 is approved; running W25 against stale W05 state produces an incoherent matches table.

### Task 7: Workflow 25 Reconcile Wiring - Red Tests

**Files:**
- Modify: `tests/test_n8n_workflows.py`
- Modify later: `n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json`

**Phase gate:** Do not start Task 7 until Task 6 Phase 1 W05 deploy has been approved by the orchestrator. W25 must not run against stale W05 agreement state.

- [ ] **Step 1: Add failing W25 assertions**

Assert:

- Workflow 25 contains RPC URL `/rest/v1/rpc/profit_reconcile_fc_client_anchor_matches`.
- RPC body contains `"p_dry_run": false`.
- Reconcile node has `continueOnFail` true.
- Summary output includes `reconciledDemotedMatchCount`, `reconcileStatus`, and `reconcileError`.
- Workflow 25 does not reference `profit_pipeline_run_steps`.

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py -q
```

Expected: FAIL because W25 has no reconcile node.

### Task 8: Workflow 25 Reconcile Wiring - Implementation And Phase 2 Deploy

**Files:**
- Modify: `n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json`
- Modify: `tests/test_n8n_workflows.py`

- [ ] **Step 1: Capture pre-deploy live baseline**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "select match_method, count(*) from profit_fc_client_anchor_matches group by match_method order by match_method;"'
```

Expected after W05 phase: likely 28 auto_exact + 12 manual_override until W25 reruns.

- [ ] **Step 2: Add reconcile node**

Insert `Reconcile Demoted FC Client Anchor Matches` after `Upsert FC Client Anchor Matches` and before summary. Use Supabase RPC POST, `Prefer: return=representation`, body `{ "p_dry_run": false }`, and `continueOnFail=true`.

- [ ] **Step 3: Extend summary code**

Summary JSON must include:

```json
{
  "status": "ok",
  "upsertedFcClientMatchCount": 30,
  "reconciledDemotedMatchCount": 0,
  "reconcileStatus": "ok",
  "reconcileError": null
}
```

If reconcile node errors, return `reconcileStatus: "error"` and `reconcileError` while preserving W25 success.

- [ ] **Step 4: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py -q
```

Expected: PASS.

- [ ] **Step 5: Import and run W25**

Use established n8n import/run method.

- [ ] **Step 6: Post-deploy checkpoint**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "select match_method, count(*) from profit_fc_client_anchor_matches group by match_method order by match_method;" -c "select client.name, match.match_method, match.anchor_client_business_name from profit_fc_client_anchor_matches match join profit_fc_clients client on client.fc_client_id = match.fc_client_id where client.name ilike any (array['\''%yv enterprises hb%'\'','\''%yv enterprises psl%'\'']) order by client.name;"'
```

Expected: 30 auto_exact + 12 manual_override = 42; YV HB/PSL present as auto_exact; reconcileStatus `ok`, reconciledDemotedMatchCount 0.

Stop and report before Workflow 26.

### Task 9: Workflow 26 Chained Pipeline

**Files:**
- Create: `n8n/workflows/profit-26-pipeline-orchestration.json`
- Modify: `tests/test_n8n_workflows.py`

- [ ] **Step 1: Verify Execute Workflow availability**

Before writing Workflow 26, verify live n8n supports `n8n-nodes-base.executeWorkflow`. Use the n8n UI, CLI, or a minimal import probe. Record which of these is true:

- Execute Workflow node is available and can invoke by workflow ID/name.
- Execute Workflow node is unavailable or cannot return usable output.

If unavailable, halt and ask for approval to implement the documented webhook-subworkflow fallback.

- [ ] **Step 2: Add red workflow tests**

Assert Workflow 26:

- Has a Webhook trigger with immediate response mode (`responseMode` equivalent to `onReceived`).
- Checks `X-Profit-Pipeline-Secret`.
- Contains exactly the 8 locked step names.
- Uses strict sequential edges for grouped steps.
- Has no parallel fan-out inside grouped steps.
- Writes `profit_pipeline_run_steps` at step start and finish.
- Finalizes `profit_pipeline_runs`.
- Aggregates `rows_affected`.
- Emits `details.sub_workflows`.
- Treats steps 1-6 as hard and steps 7-8 as soft.

- [ ] **Step 3: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py -q
```

Expected: FAIL because Workflow 26 does not exist.

- [ ] **Step 4: Create Workflow 26 JSON**

Use Execute Workflow nodes if available. Otherwise use webhook HTTP Request nodes for each sub-workflow, preserving the same output payload shape.

Webhook trigger response must be immediate:

```json
{
  "accepted": true,
  "pipeline_run_id": "={{ $json.body.pipeline_run_id }}"
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py -q
```

Expected: PASS.

- [ ] **Step 6: Import Workflow 26 and curl immediate webhook response**

Curl the Workflow 26 webhook with a synthetic `pipeline_run_id` that already exists in `profit_pipeline_runs` or with an approved test row. Time the response.

Expected: under 2 seconds and body includes `accepted: true`.

- [ ] **Step 7a: Pre-mutation state verification**

Before the first real pipeline run, verify no live pipeline-run data exists:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "select count(*) as pipeline_runs from profit_pipeline_runs;" -c "select count(*) as pipeline_run_steps from profit_pipeline_run_steps;"'
```

Expected:

```text
pipeline_runs = 0
pipeline_run_steps = 0
```

Also verify Workflow 26 imported successfully in n8n and the webhook responds with `{ "accepted": true, "pipeline_run_id": "..." }` in under 2 seconds.

STOP. Report empty table counts, import status, webhook URL timing, and response body. Wait for orchestrator approval before the first live pipeline run.

- [ ] **Step 7b: First manual pipeline run**

Run one manual pipeline execution after API support is live or through an approved webhook payload. Verify:

- 8 step rows.
- Grouped sub-workflow arrays are sequential and complete.
- W25 step carries reconcile output.
- Run status terminal is `success` unless soft steps fail, in which case `partial`.

Expected duration: 30 seconds to several minutes depending on sub-workflow latency.

On completion, verify:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "select pipeline_run_id, run_source, status, triggered_by, started_at, finished_at, summary from profit_pipeline_runs order by started_at desc limit 1;" -c "select step_order, step_name, status, rows_affected, details from profit_pipeline_run_steps order by step_order;"'
```

Expected:

- `profit_pipeline_runs` has exactly 1 row with terminal status.
- `profit_pipeline_run_steps` has exactly 8 rows with sequential `step_order`.
- Every step has `rows_affected` populated.
- Grouped steps' `details.sub_workflows` arrays carry per-sub data.
- Final run `summary` includes `total_steps_completed`, `total_steps_failed`, and `total_rows_affected`.

STOP. Report `pipeline_run_id`, terminal status, all 8 step results, and summary. Wait for orchestrator approval before Task 10.

If any hard step fails or any soft step produces `partial`, report the failure mode and do not proceed to Task 10. Investigation may require schema sniff, sub-workflow debugging, or rollback via git checkout of workflow JSON.

### Task 10: Detail Endpoint `auto_apply_enabled` Dual Emission

**Files:**
- Modify: `profit_api/audit.py`
- Modify: `tests/test_profit_api_audit.py`
- Modify: `app/frontend/src/routes/AuditDashboard.jsx`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Add API red tests**

Tests:

- Every `transition_rules` row contains both `auto_apply_enabled` and `auto_apply_enabled_in_b2a`.
- PENDING + `active_agreement_appears`: both true.
- LEGACY + `first_matching_anchor_invoice_mid_cycle`: canonical true, legacy false.
- INVOICE + `cash_collected_standalone_mid_cycle`: canonical true, legacy false.
- INACTIVE + `any_active_signal_returns`: canonical false, legacy false.

- [ ] **Step 2: Add frontend red tests**

Assertions:

```python
assert "auto_apply_enabled ?? rule.auto_apply_enabled_in_b2a" in audit_dashboard_jsx_source
assert "Eligible — manual apply only" in audit_dashboard_jsx_source
assert "V0.6.C will automate" not in audit_dashboard_jsx_source
assert "Will auto-apply on next pipeline run" in audit_dashboard_jsx_source
```

The `not in` assertion for `V0.6.C will automate` is load-bearing and must fail if stale B.2.b wording remains anywhere in `AuditDashboard.jsx`.

- [ ] **Step 3: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py tests/test_profit_admin_frontend.py -q
```

Expected: FAIL.

- [ ] **Step 4: Implement API and frontend**

Add helper `_auto_apply_enabled(rule)` in `AuditDashboardService`. Update `transitionBadge(rule)` to read canonical with fallback and replace stale copy.

- [ ] **Step 5: Run green tests and build**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py tests/test_profit_admin_frontend.py -q
cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: PASS and successful build.

### Task 11: Pipeline Frontend Surfaces

**Files:**
- Create: `app/frontend/src/components/PipelineRefreshDialog.jsx`
- Create: `app/frontend/src/components/PipelineStatusSummary.jsx`
- Create: `app/frontend/src/routes/PipelineRuns.jsx`
- Modify: `app/frontend/src/App.jsx`
- Modify: `app/frontend/src/components/PortalNav.jsx`
- Modify: `app/frontend/src/routes/Dashboard.jsx`
- Modify: `app/frontend/src/routes/AuditDashboard.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Add red static tests**

Assert:

- `/admin/pipeline` and `/admin/pipeline/:pipelineRunId` routes exist.
- Pipeline nav link exists.
- `PipelineRefreshDialog.jsx` exists and is imported by Dashboard, AuditDashboard, and PipelineRuns.
- Dialog includes editable `triggered_by` input defaulting to `orlando`.
- POST target is `/pipeline-runs`.
- Success uses `useNavigate`.
- Polling uses `setInterval(..., 4000)` only on detail route/running status.
- `clearInterval` cleanup exists.
- No global polling on list route.
- The polling test is behavioral string coverage, not just presence:

```python
assert "setInterval" in pipeline_runs_jsx_source
assert "if (pipelineRunId &&" in pipeline_runs_jsx_source
assert "clearInterval" in pipeline_runs_jsx_source
```

- Empty-state strings exist.
- `pipeline-` CSS prefix is used for new classes.

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL.

- [ ] **Step 3: Implement frontend**

Implement:

- Shared refresh dialog.
- Shared status summary.
- Run-log route with list/detail modes.
- Main dashboard tile.
- Audit dashboard strip.
- Polling lifecycle.
- Empty states.
- Excerpt truncation helper.
- Pipeline CSS appended at bottom of `styles.css`.

- [ ] **Step 4: Run green tests and build**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: PASS and successful build.

- [ ] **Step 5: Deploy frontend and API together**

Run:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
scp -P 2222 -r app/frontend/dist root@104.225.220.36:/opt/agents/outscore_profit/frontend/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service && systemctl status profit-admin-api.service --no-pager"
```

- [ ] **Step 6: Browser handoff**

Hand off:

- `https://app.outscore.com/profit/`
- `https://app.outscore.com/profit/admin/audit`
- `https://app.outscore.com/profit/admin/pipeline`
- `https://app.outscore.com/profit/admin/pipeline/<known-run-id>`

Expected:

- No runs yet states if no run exists.
- Refresh dialog opens from all three entry points.
- List route does not poll.
- Detail route polls only while running.
- Status badges and step details render consistently.

Stop for browser approval.

### Task 12: Documentation Updates

**Files:**
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md`
- Modify: `tests/test_data_references_docs.py`

- [ ] **Step 1: Add red doc tests**

Assert docs mention:

- Pipeline API endpoints.
- Workflow 26 8-step run contract.
- W25 standalone runs do not write run-log tables.
- `triggered_by` convention.
- `auto_apply_enabled` canonical field and `auto_apply_enabled_in_b2a` deprecation.
- Stuck-run detection deferred to C.c.
- SupabaseRestError structured fields.

- [ ] **Step 2: Run red doc tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: FAIL.

- [ ] **Step 3: Update docs**

Add data-contract subsections:

- Pipeline Orchestration API.
- Workflow 26 Run Log Semantics.
- Workflow 25 Standalone Run Behavior.
- Auto Apply Enabled Field Migration.

Add tech-debt entries:

- SupabaseRestError structured fields partially adopted.
- Stuck pipeline run detection deferred to V0.6.C.c.
- Manual refresh free-text `triggered_by`.
- Deprecated `auto_apply_enabled_in_b2a` removal target.

- [ ] **Step 4: Run green doc tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: PASS.

Stop and report documentation changes.

### Task 13: Full Verification, Final Deploy Summary, Commit

**Files:**
- All C.b files only.

- [ ] **Step 1: Targeted pytest**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest \
  tests/test_profit_api_supabase.py \
  tests/test_profit_api_pipeline.py \
  tests/test_profit_api_audit.py \
  tests/test_profit_admin_frontend.py \
  tests/test_n8n_workflows.py \
  tests/test_data_references_docs.py \
  -q
```

Expected: PASS.

- [ ] **Step 2: Full pytest**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest -q
```

Expected: PASS.

- [ ] **Step 3: Final frontend build**

Run:

```bash
cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: successful build.

- [ ] **Step 4: Final live one-liner**

Report:

- latest pipeline run summary
- `GET /pipeline-runs` row count
- `GET /pipeline-runs/{latest}` step count
- W05 agreement distribution
- W25 match distribution
- audit detail sample includes both auto-apply fields
- frontend routes reachable

- [ ] **Step 5: Scope boundary**

Run:

```bash
git diff --name-only
```

Expected files are limited to:

- `profit_api/supabase.py`
- `profit_api/app.py`
- `profit_api/audit.py`
- `profit_api/pipeline.py`
- `tests/test_profit_api_supabase.py`
- `tests/test_profit_api_pipeline.py`
- `tests/test_profit_api_audit.py`
- `tests/test_profit_admin_frontend.py`
- `tests/test_n8n_workflows.py`
- `tests/test_data_references_docs.py`
- `app/frontend/src/App.jsx`
- `app/frontend/src/components/PortalNav.jsx`
- `app/frontend/src/components/PipelineRefreshDialog.jsx`
- `app/frontend/src/components/PipelineStatusSummary.jsx`
- `app/frontend/src/routes/Dashboard.jsx`
- `app/frontend/src/routes/AuditDashboard.jsx`
- `app/frontend/src/routes/PipelineRuns.jsx`
- `app/frontend/src/styles.css`
- `n8n/workflows/profit-05-anchor-agreements-sync.json`
- `n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json`
- `n8n/workflows/profit-26-pipeline-orchestration.json`
- `docs/data-contracts/fulfillment-classifications.md`
- `docs/tech-debt.md`
- this plan file

No `supabase/sql/**`, package dependency, V0.6.D, or unrelated workflow files should appear.

- [ ] **Step 6: Stop before commit**

Report tests, build, live summary, and scope boundary. Wait for orchestrator approval before commit.

- [ ] **Step 7: Commit and push after approval**

Commit message:

```text
feat(profit): add v0.6.c.b pipeline orchestration

- add pipeline run API endpoints with structured Supabase error handling and 409 lock mapping
- add Workflow 05 limit fix, Workflow 25 reconcile wiring, and Workflow 26 orchestration
- add pipeline run-log route, dashboard tile, audit strip, and shared manual refresh dialog
- emit canonical auto_apply_enabled while preserving deprecated auto_apply_enabled_in_b2a
- document stuck-run cleanup, triggered_by convention, and legacy field deprecation
- keep SQL migrations, cron, V0.6.D, and new npm packages out of scope
```

Push after commit.

## Self-Review Checklist

- [ ] Zero new SQL migrations or views.
- [ ] Zero new npm dependencies or devDependencies.
- [ ] W05 deploy precedes W25 deploy.
- [ ] W25 reconcile uses Supabase RPC, `continueOnFail=true`, and does not write run-log tables standalone.
- [ ] Workflow 26 has exactly 8 effective steps.
- [ ] Workflow 26 grouped sub-workflows are strictly sequential.
- [ ] Workflow 26 webhook response mode is immediate and verified by curl timing.
- [ ] Steps 1-6 hard-fail; steps 7-8 soft-fail to partial.
- [ ] API owns running-row insert and maps `idx_profit_pipeline_runs_one_running` to 409.
- [ ] 409 race retry-once behavior is tested.
- [ ] Stuck-run cleanup is documented as V0.6.C.c tech debt.
- [ ] `triggered_by` is editable, defaults to `orlando`, and is not hardcoded to an operator list.
- [ ] Polling only runs on `/admin/pipeline/:pipelineRunId` while status is `running`.
- [ ] Polling cleans up on unmount and status transition.
- [ ] `PipelineRefreshDialog` is shared by dashboard, audit dashboard, and pipeline route.
- [ ] All three pipeline surfaces handle "No runs yet" without negative tone.
- [ ] `auto_apply_enabled` and `auto_apply_enabled_in_b2a` are both emitted on every transition-rule row.
- [ ] Frontend reads canonical `auto_apply_enabled` with legacy fallback.
- [ ] The stale text `V0.6.C will automate` is absent from frontend source.
- [ ] `profit_classifications` append-only invariant is unchanged.
- [ ] 14 verdict canon is read from API and not hardcoded.
- [ ] No frontend/API behavior assumes cron exists.
- [ ] Scope boundary excludes `supabase/sql/**`, V0.6.D, alias seeding, and unrelated workflow JSON.

Plan ready for orchestrator review.
