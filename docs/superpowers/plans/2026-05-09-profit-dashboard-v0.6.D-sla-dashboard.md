# Profit Dashboard V0.6.D SLA Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the read-only `/profit/admin/sla` admin surface with per-client SLA status, per-staff workload, breach/at-risk triage, fixed 90-day SLA performance, and the `/profit/admin/sla/backfill` Anchor backfill queue for `SETTLED_VIA_QUICKBOOKS_PAYMENT`.

**Architecture:** V0.6.D adds a dedicated SLA API namespace backed by SQL views that compute stable SLA facts close to the source data. SQL owns canonical SLA target-day, age, workflow-status, and state classification; the FastAPI service owns read-only endpoint shape, filter validation, and pagination; React owns the admin route shell and read-only tables. The Anchor backfill queue is its own SLA sub-route, not an in-page panel on the main dashboard.

**Tech Stack:** Supabase SQL views, FastAPI service layer, existing Supabase REST client, React/Vite admin frontend, existing Python `pytest` static/API coverage, `npm run build`, existing direct `scp` frontend deploy convention.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: V0.6.D SLA dashboard scope, route, inputs, required views, locked SLA states, and Anchor backfill queue requirement.
- `/Users/orlandosaez/agents/outscore-profit-cc/coordination/ui-sprint-handoff.md`: V0.6.C.5 shared frontend components, load-bearing dashboard anchors, CSS sectioning, build/deploy convention, and deferred inclusion gates A-E.
- `docs/superpowers/plans/2026-05-09-profit-dashboard-v0.6.C.c-cron-and-stability.md`: current plan structure, task checkpoint format, migration numbering precedent, and operator-gated Task 1 precedent.
- `docs/data-contracts/fulfillment-classifications.md`: classification verdict semantics, transition rules, pipeline payload fields, and deferred `SETTLED_VIA_QUICKBOOKS_PAYMENT` Anchor backfill transition rules.
- `docs/tech-debt.md`: V0.6.D overlap for FC project workflow-status tags, `default_sla_day` quality gaps, staff context gaps, W16 duplicate recognition key defect, and deferred frontend/UI polish.
- Existing code contracts: `profit_api/app.py`, `profit_api/audit.py`, `profit_api/pipeline.py`, `app/frontend/src/App.jsx`, `app/frontend/src/components/PortalNav.jsx`, `app/frontend/src/components/EmptyState.jsx`, `app/frontend/src/components/PipelineStatusBanner.jsx`, `app/frontend/src/routes/Dashboard.jsx`, and `supabase/sql/020_profit_name_normalization_and_fc_tags.sql`.

## Gate Decisions Locked Into This Plan

### G1: API Endpoint Shape

Options:

- **A. Dedicated `/api/profit/admin/sla/*` family.**
- **B. Co-locate SLA reads under `/api/profit/admin/audit/*`.**

LOCKED: Dedicated `/api/profit/admin/sla/*` family.

Implementation:

- Add `/api/profit/admin/sla/summary`.
- Add `/api/profit/admin/sla/clients`.
- Add `/api/profit/admin/sla/workload`.
- Add `/api/profit/admin/sla/queue`.
- Add `/api/profit/admin/sla/performance`.
- Add `/api/profit/admin/sla/backfill`.

Reasoning:

- SLA is an operational management surface, not an audit classification mutation surface.
- A dedicated namespace keeps read-only SLA contracts separate from audit write endpoints.
- The namespace leaves room for future remediation workflows without overloading `/audit`.

### G2: Per-Client SLA Aggregation Source

Options:

- **A. SQL views analogous to `profit_audit_*` views.**
- **B. API-side computation from raw FC, Anchor, recognition, and classification tables.**

LOCKED: SQL `profit_sla_*` views (mirroring `profit_audit_*` pattern). Stable, queryable from API + ops + future services.

Implementation:

- Create SQL views named with the `profit_sla_*` prefix.
- Keep state, age, target-day, workflow-status, per-client aggregation, per-staff workload, queue, performance, and backfill queue facts queryable directly from SQL.
- API code may filter and paginate view rows, but must not reimplement SLA classification.

Reasoning:

- The dashboard needs repeated aggregations across FC tasks/projects, tags, service rules, Anchor agreements, classifications, and cash signals.
- SQL views keep business rules close to indexed data and make ops/debug queries possible without API code.
- API-side computation would duplicate business rules and make future services less stable.

### G3: SLA Computation Location And State Formula

Options:

- **A. SQL computes target day, age, and state.**
- **B. API computes state from raw SQL rows.**
- **C. Frontend computes state from payload fields.**

LOCKED: SQL owns canonical state computation. The set of states stays locked: `on_track`, `at_risk`, `breached`, `waiting_on_client`, `not_applicable`. No new states.

State precedence:

1. `not_applicable`: no `default_sla_day` and no `sla_day_override`, or service is pass-through/manual-only.
2. `waiting_on_client`: project workflow tag says `Waiting on Client`.
3. `breached`: `age_days > target_sla_day`.
4. `at_risk`: `age_days >= greatest(target_sla_day - 2, ceil(target_sla_day * 0.8))`.
5. `on_track`: all other applicable rows.

Reasoning:

- SQL gives one state contract for all downstream views.
- The locked at-risk rule handles both short monthly bookkeeping SLAs and longer tax/quarterly SLAs.
- API and frontend consumers display the canonical state; they do not classify.

### G4: Workflow-Tag Wiring

Options:

- **A. Wire project-level `project.raw.tags` workflow statuses in V0.6.D.**
- **B. Defer workflow-status wiring to V0.7 and omit `waiting_on_client` except for future data.**

LOCKED: Include -- wire `project.raw.tags` workflow status (`Waiting on Client`, `In Preparation`, `Ready to Submit`) into SLA computation. Update Workflow 17 if needed for tag capture.

Implementation:

- Extend FC tag normalization so project workflow statuses are available to SQL as `workflow_status`.
- If Workflow 17 currently drops project-level workflow tags, update it during execution after the profiling gate proves the exact payload path.
- `Waiting on Client` is the only workflow status that directly changes SLA state; `In Preparation` and `Ready to Submit` remain display/filter context.

Reasoning:

- `waiting_on_client` is a locked SLA state.
- The V0.6 spec says `project.raw.tags` carries these statuses for D.
- A display-only placeholder would make the locked state misleading.

### G5: Anchor Backfill Queue Placement

Options:

- **A. Sub-route under `/admin/sla/backfill`.**
- **B. Separate top-level `/admin/anchor-backfill`.**
- **C. Nest under existing `/admin/audit`.**

LOCKED: Sub-route `/admin/sla/backfill`. Separate from main SLA panels. Don't render as in-page panel.

Implementation:

- Add frontend route `/admin/sla/backfill`, rendered at `/profit/admin/sla/backfill`.
- Add API endpoint `/api/profit/admin/sla/backfill`.
- Keep the main SLA dashboard linked to the backfill route, but do not render the backfill queue as one of the main SLA panels.

Reasoning:

- The queue is part of SLA/convergence management, but it is operationally distinct from the main SLA panels.
- A sub-route avoids navigation sprawl while keeping the queue deep-linkable.
- Keeping it separate prevents the main SLA dashboard from becoming a mixed-purpose remediation page.

### G6: Rolling SLA Performance Scope

Options:

- **A. Last 30 days, regular view.**
- **B. Last 90 days, regular view.**
- **C. Configurable lookback, materialized view.**
- **D. Configurable lookback, on-demand API query.**

LOCKED: 90-day fixed regular SQL view. No materialization, no parameterization.

Implementation:

- Create a regular SQL view for fixed 90-day performance.
- Do not add an API `lookback_days` parameter.
- Do not create a materialized view or refresh workflow.

Reasoning:

- 30 days is too thin for tax and quarterly services.
- A materialized view adds refresh burden before dashboard query cost is proven.
- Fixed 90-day SQL keeps the contract simple and fresh after pipeline syncs.

### G7: Manual Recognition UI Polish

Options:

- **A. Include the four deferred Manual Recognition UI polish items in V0.6.D.**
- **B. Defer to V0.6.5/V0.7.**

LOCKED: Deferred to V0.6.5 / V0.7. Out of scope.

Reasoning:

- V0.6.D is already backend-heavy and closes V0.6.
- Manual Recognition polish is unrelated to SLA state, workload, performance, or Anchor backfill queue delivery.
- The execution tasks must not modify Manual Recognition UI files unless a later turn explicitly changes scope.

### Inclusion A: Recognized Tile Drill-Down

Options:

- **Include:** Add `GET /api/profit/admin/recognition/recognized`, `/admin/recognition?view=recognized`, and make the Recognized tile linkable.
- **Defer:** Keep current recognized tile non-drillable.

LOCKED: Recognized tile drill-down: defer.

### Inclusion B: Review Checklist "Reviewed" Tracking

Options:

- **Include:** Add active-step IntersectionObserver and localStorage completion state to V0.6.C.5 `ReviewChecklist`.
- **Defer:** Leave checklist as stateless navigation.

LOCKED: "Reviewed" tracking on review checklist: defer.

### Inclusion C: Per-Tile Staleness Badges

Options:

- **Include:** Add `last_successful_run_at` to dashboard payload and stale badges on Stat tiles.
- **Defer:** Keep global `PipelineStatusBanner` as the failure/partial signal.

LOCKED: Per-tile staleness badges: defer.

### Inclusion D: Audit Page Service-Tag Density Redesign

Options:

- **Include:** Collapse service-tag badge soup on `/admin/audit` to `<n services>` with hover reveal.
- **Defer:** Leave audit tag density as-is.

LOCKED: Audit page service-tag density redesign: defer.

### Inclusion E: Frontend Test Infrastructure

Options:

- **Include:** Add Vitest + React Testing Library.
- **Defer:** Continue existing static frontend tests plus `npm run build`.

LOCKED: Frontend test infrastructure: defer.

## Resolved Decisions

- **OQ1:** At-risk threshold is `age_days >= greatest(target_sla_day - 2, ceil(target_sla_day * 0.8))`. Use this formula in SQL state computation.
- **OQ2:** Staff workload assignment source is task assignee first, falling back to FC client staff tags only when no task assignee is present. Document this fallback rule in the per-staff workload SQL view.
- **OQ3:** Anchor backfill placement is sub-route `/admin/sla/backfill` per G5.
- **OQ4:** Inclusion gates A-E are all deferred.
- **OQ5:** Manual Recognition UI polish is deferred; no V0.6.D task touches it.

## Migration Numbering

LOCKED SUB-DECISION: C.c shipped `027_profit_finalize_stale_pipeline_runs.sql` and `027a_profit_cron_pipeline_run_health.sql`, so V0.6.D starts at `028`.

Use two migrations:

- `supabase/sql/028_profit_sla_core_views.sql`: workflow-status tag normalization support plus core SLA service-item, client, workload, and breach/at-risk queue views.
- `supabase/sql/028a_profit_sla_backfill_and_performance_views.sql`: fixed 90-day performance view and Anchor backfill queue view.

Reasoning:

- `028` owns the canonical SLA state contract and downstream core views.
- `028a` owns secondary operational read surfaces that depend on the core contract.
- Splitting keeps deployment rollback/debug boundaries clear while preserving the C.c alphanumeric numbering convention.

## Scope

In scope:

- Read-only `/profit/admin/sla` frontend route.
- Read-only `/profit/admin/sla/backfill` frontend sub-route.
- Dedicated `/api/profit/admin/sla/*` read endpoints.
- SQL-backed SLA service-item status, client status, staff workload, breach/at-risk queue, fixed 90-day performance, and Anchor backfill queue views.
- FC project workflow status tag normalization for `Waiting on Client`, `In Preparation`, and `Ready to Submit`.
- Locked states only: `on_track`, `at_risk`, `breached`, `waiting_on_client`, `not_applicable`.
- Empty states via existing `EmptyState`; summary tile style should reuse the existing `Stat` pattern from C.5 without modifying shared C.5 component internals.
- `PipelineStatusBanner` only if pipeline status is displayed on SLA surfaces using existing payload/API conventions.
- CSS appended at bottom of `app/frontend/src/styles.css` under `/* === V0.6.D: SLA dashboard === */`.
- Deploy verification with `cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build`.

Out of scope:

- Write controls, assignment changes, status changes, remediation workflows, or Anchor backfill mutations.
- New SLA states.
- W16 duplicate `revenue_event_key` fix.
- Main dashboard scroll-anchor edits.
- Reworking V0.6.C.5 shared components.
- Recognition recognized-drilldown.
- Review checklist "Reviewed" tracking.
- Per-tile staleness badges.
- Audit page service-tag density redesign.
- Frontend test infrastructure.
- Manual Recognition UI polish.

## Out of Scope (Deferred)

- A -- Recognized tile drill-down: defer.
- B -- "Reviewed" tracking on review checklist: defer.
- C -- Per-tile staleness badges: defer.
- D -- Audit page service-tag density redesign: defer.
- E -- Frontend test infrastructure: defer.

## File Structure

Create:

- `supabase/sql/028_profit_sla_core_views.sql`: normalizes project workflow-status tags and defines core `profit_sla_*` views for canonical SLA state, client rollups, staff workload, and breach/at-risk triage.
- `supabase/sql/028a_profit_sla_backfill_and_performance_views.sql`: defines fixed 90-day performance and Anchor backfill queue views that depend on the core SLA contract.
- `profit_api/sla.py`: read-only SLA service class using the existing Supabase `read_view` pattern; validates filters, pagination, and fixed endpoint payload shapes.
- `tests/test_sla_dashboard_sql.py`: static SQL contract tests for migration numbering, view names, locked states, threshold formula, workflow-status handling, staff fallback, and read-only shape.
- `tests/test_profit_api_sla.py`: FastAPI/service tests for dedicated endpoints, payload keys, filters, pagination, validation, and no audit-route coupling.
- `app/frontend/src/routes/SlaDashboard.jsx`: main read-only SLA dashboard route with summary, client status, workload, breach/at-risk queue, and fixed 90-day performance panels.
- `app/frontend/src/routes/SlaBackfill.jsx`: dedicated read-only Anchor backfill queue sub-route.
- `docs/data-contracts/sla-dashboard.md`: SLA SQL/API/frontend data contract, state precedence, workload assignment fallback, and backfill queue semantics.

Modify:

- `profit_api/app.py`: register `SlaDashboardService`, inject it through `create_app`, and add `/api/profit/admin/sla/*` routes.
- `app/frontend/src/App.jsx`: import SLA routes and add `/admin/sla` plus `/admin/sla/backfill`.
- `app/frontend/src/components/PortalNav.jsx`: add `SLA` navigation link to `/admin/sla`.
- `app/frontend/src/styles.css`: append V0.6.D SLA styles only under the section comment.
- `tests/test_profit_admin_frontend.py`: extend static contract tests for route registration, nav, endpoint strings, shared empty-state usage, backfill sub-route, and absence of write controls.
- `docs/data-contracts/fulfillment-classifications.md`: link `SETTLED_VIA_QUICKBOOKS_PAYMENT` to the new SLA backfill queue and document read-only status.
- `docs/tech-debt.md`: mark FC project workflow-status tag deferral resolved after implementation; leave unrelated default-SLA data-quality issues as follow-up notes.
- `n8n/workflows/profit-17-*.json`: modify only if Task 1 proves Workflow 17 must capture project workflow tags for the SQL views to work.
- `tests/test_n8n_workflows.py`: modify only if Workflow 17 changes are required.

Do not modify:

- `app/frontend/src/components/ReviewChecklist.jsx`.
- Existing dashboard section ids or scroll anchors.
- `app/frontend/src/components/EmptyState.jsx`, `PipelineStatusBanner.jsx`, or shared C.5 component internals.
- `app/deploy/deploy_profit_app.sh`.
- Existing audit classification write endpoints.
- Manual Recognition route/component files.

## Sub-Decisions Made

- Split SQL into `028` core views and `028a` performance/backfill views.
- Use new API module `profit_api/sla.py`, matching the existing `audit.py` and `pipeline.py` service-module pattern.
- Keep SLA tests in new backend files rather than bloating existing audit/pipeline tests; extend existing frontend static tests because that is the current frontend test convention.
- Main frontend route is `app/frontend/src/routes/SlaDashboard.jsx`; backfill sub-route is `app/frontend/src/routes/SlaBackfill.jsx`.
- Do not create SLA-specific reusable components unless Task 5 shows repeated UI code that would otherwise be copied across `SlaDashboard.jsx` and `SlaBackfill.jsx`.
- Staff workload grouping uses task assignee first; when task assignee is absent, the SQL view falls back to FC client staff tags.
- `In Preparation` and `Ready to Submit` are retained as workflow-status display/filter values, but only `Waiting on Client` changes canonical SLA state.
- The fixed performance view name includes `90d` so future non-90-day surfaces cannot accidentally reuse it.

## Sub-Decisions Surfaced As DECISION NEEDED

- None at plan-refinement time. During Task 1, stop and surface `DECISION NEEDED` if required source fields are absent, workflow tags cannot be captured without a broader Workflow 17 redesign, or Anchor/QBO evidence fields differ materially from the plan.

## Task Breakdown

Each implementation task below follows red test -> green implementation -> checkpoint verification -> commit. Do not combine commits across tasks unless Orlando explicitly changes the execution model.

### Task 1: Live Data Profiling Gate

**Purpose:** Confirm source fields before encoding SQL SLA state and before deciding whether Workflow 17 must change.

**Operator Action Required:** This task requires live Supabase/n8n profiling evidence from Orlando/operator context before migration work begins. Treat this like the C.c Task 1 gate: gather evidence, report it, and halt if any source signal is absent or materially different.

**Files:**

- No committed file changes.
- Read/query live Supabase tables and current Workflow 17 only.
- Do not write migrations, workflow JSON, API code, frontend code, docs, or commits in this task.

- [ ] **Step 1: Profile FC project workflow tags**

  Query live `profit_fc_projects` samples where `raw` contains tags. Confirm exact source path and strings for:

  - `Waiting on Client`
  - `In Preparation`
  - `Ready to Submit`

  Expected evidence: table/query output showing at least one raw payload path for each present workflow status, or a clear zero-row result if a status is absent in current data.

- [ ] **Step 2: Profile existing FC tag normalization**

  Query live `profit_fc_project_tags` and `profit_fc_client_tags` for `tag_type` values and tag names matching workflow/status/staff patterns.

  Expected evidence: confirm whether `workflow_status` already exists, whether a check constraint must be updated, and whether project-level tags are currently persisted.

- [ ] **Step 3: Profile staff assignment sources**

  Query representative open FC tasks for assignee fields and client staff tags for Beth, Laura, Julie, Wama, and other staff spellings.

  Expected evidence: confirm task assignee field name, whether it is populated on SLA-relevant tasks, and the exact fallback tag names used when task assignee is missing.

- [ ] **Step 4: Profile SLA target-day inputs**

  Query service rules where `default_sla_day is null`, rows with `sla_day_override`, and SLA-relevant FC service/task rows.

  Expected evidence: distinguish true `not_applicable` service categories from data-quality gaps that should remain visible as `not_applicable` plus tech-debt notes.

- [ ] **Step 5: Profile Anchor backfill evidence**

  Query active `SETTLED_VIA_QUICKBOOKS_PAYMENT` classifications and available QBO cash/payment evidence fields through current cash/classification views.

  Expected evidence: confirm columns for client/group, payment evidence, missing Anchor agreement/invoice state, aging, and eligibility signal.

- [ ] **Step 6: Decision checkpoint**

  If all source signals match the locked plan, report the exact field paths and proceed to Task 2.

  If any required source signal is absent or materially different, stop and report `DECISION NEEDED` with the specific missing/different table, column/path, and downstream task impacted.

- [ ] **Step 7: Commit**

  No commit for Task 1. Expected normal result: operational evidence only.

### Task 2: SQL Core SLA Views

**Purpose:** Add canonical SLA state and core aggregations in SQL.

**Files:**

- Create: `supabase/sql/028_profit_sla_core_views.sql`
- Create: `tests/test_sla_dashboard_sql.py`
- Modify if Workflow 17 tag capture is required: `n8n/workflows/profit-17-*.json`
- Modify if Workflow 17 tag capture is required: `tests/test_n8n_workflows.py`

- [ ] **Step 1: Write red static SQL tests**

  Add tests in `tests/test_sla_dashboard_sql.py` proving:

  - `supabase/sql/028_profit_sla_core_views.sql` exists.
  - Core views include `profit_sla_project_statuses`, `profit_sla_service_items`, `profit_sla_client_status`, `profit_sla_staff_workload`, and `profit_sla_breach_queue`.
  - Locked states appear exactly as `on_track`, `at_risk`, `breached`, `waiting_on_client`, `not_applicable`.
  - The at-risk formula contains `greatest(target_sla_day - 2, ceil(target_sla_day * 0.8))`.
  - `sla_day_override` takes precedence over `default_sla_day`.
  - `Waiting on Client` workflow status takes precedence over breached/at-risk state.
  - Staff workload logic documents and encodes task assignee first, FC client staff tags fallback second.
  - The migration creates views only and does not define write functions.

- [ ] **Step 2: Run red tests**

  Run: `pytest tests/test_sla_dashboard_sql.py -q`

  Expected: FAIL because `tests/test_sla_dashboard_sql.py` is new and `028_profit_sla_core_views.sql` does not exist or does not contain required contracts.

- [ ] **Step 3: Implement core migration**

  Create `supabase/sql/028_profit_sla_core_views.sql` with:

  - workflow-status tag support from Task 1 source paths
  - `profit_sla_project_statuses`
  - `profit_sla_service_items`
  - `profit_sla_client_status`
  - `profit_sla_staff_workload`
  - `profit_sla_breach_queue`
  - SQL comments documenting state precedence and staff fallback

  If Task 1 proved Workflow 17 must change, update only the minimal workflow JSON path needed to persist project workflow-status tags, then add static workflow tests for that exact tag capture.

- [ ] **Step 4: Run green static tests**

  Run: `pytest tests/test_sla_dashboard_sql.py -q`

  Expected: PASS for core SQL contract tests.

- [ ] **Step 5: Live SQL checkpoint**

  Apply the migration in a dev/live-safe environment per current operator practice, then run:

  - `select sla_state, count(*) from profit_sla_service_items group by 1 order by 1;`
  - `select * from profit_sla_client_status limit 20;`
  - `select * from profit_sla_staff_workload limit 20;`
  - `select * from profit_sla_breach_queue limit 20;`

  Expected: views query successfully, states are limited to locked values, and staff assignment uses task assignee where present.

- [ ] **Step 6: Commit**

  Commit message: `feat: add core SLA dashboard views`

### Task 3: SQL Performance And Anchor Backfill Views

**Purpose:** Add fixed 90-day performance and dedicated Anchor backfill queue SQL views.

**Files:**

- Create: `supabase/sql/028a_profit_sla_backfill_and_performance_views.sql`
- Modify: `tests/test_sla_dashboard_sql.py`

- [ ] **Step 1: Write red static SQL tests**

  Extend `tests/test_sla_dashboard_sql.py` proving:

  - `supabase/sql/028a_profit_sla_backfill_and_performance_views.sql` exists.
  - The migration defines `profit_sla_staff_service_performance_90d`.
  - The performance view uses a fixed `interval '90 days'` or equivalent fixed 90-day predicate.
  - The migration does not expose a parameterized lookback function.
  - The migration defines `profit_sla_anchor_backfill_queue`.
  - The backfill view references `SETTLED_VIA_QUICKBOOKS_PAYMENT`.
  - The backfill view exposes client/group identity, QBO payment evidence, Anchor agreement/invoice state, aging, and auto-transition eligibility fields.
  - The migration creates views only and does not define write functions.

- [ ] **Step 2: Run red tests**

  Run: `pytest tests/test_sla_dashboard_sql.py -q`

  Expected: FAIL because `028a_profit_sla_backfill_and_performance_views.sql` does not exist or lacks required contracts.

- [ ] **Step 3: Implement secondary migration**

  Create `supabase/sql/028a_profit_sla_backfill_and_performance_views.sql` with:

  - `profit_sla_staff_service_performance_90d`
  - `profit_sla_anchor_backfill_queue`
  - SQL comments documenting fixed 90-day scope and read-only backfill semantics

- [ ] **Step 4: Run green static tests**

  Run: `pytest tests/test_sla_dashboard_sql.py -q`

  Expected: PASS for core and secondary SLA SQL contract tests.

- [ ] **Step 5: Live SQL checkpoint**

  Apply the migration in a dev/live-safe environment after Task 2, then run:

  - `select * from profit_sla_staff_service_performance_90d limit 20;`
  - `select * from profit_sla_anchor_backfill_queue limit 20;`

  Expected: both views query successfully; performance is fixed to 90 days; backfill rows are read-only eligibility signals.

- [ ] **Step 6: Commit**

  Commit message: `feat: add SLA performance and Anchor backfill views`

### Task 4: SLA API Service And Routes

**Purpose:** Expose dedicated read endpoints without mixing SLA into audit.

**Files:**

- Create: `profit_api/sla.py`
- Create: `tests/test_profit_api_sla.py`
- Modify: `profit_api/app.py`

- [ ] **Step 1: Write red API tests**

  Add `tests/test_profit_api_sla.py` with a fake store and FastAPI client proving:

  - `GET /api/profit/admin/sla/summary` reads SLA summary/client aggregate views and returns summary counts.
  - `GET /api/profit/admin/sla/clients` reads `profit_sla_client_status`.
  - `GET /api/profit/admin/sla/workload` reads `profit_sla_staff_workload`.
  - `GET /api/profit/admin/sla/queue` reads `profit_sla_breach_queue`.
  - `GET /api/profit/admin/sla/performance` reads `profit_sla_staff_service_performance_90d`.
  - `GET /api/profit/admin/sla/backfill` reads `profit_sla_anchor_backfill_queue`.
  - invalid state filters return 422.
  - invalid staff/service filters return 422 when not present in filter options.
  - `limit` clamps to 1-200 and `offset` clamps to `>= 0`.
  - no SLA endpoint calls audit write methods.

- [ ] **Step 2: Run red API tests**

  Run: `pytest tests/test_profit_api_sla.py -q`

  Expected: FAIL because `profit_api.sla` and `/api/profit/admin/sla/*` routes do not exist.

- [ ] **Step 3: Implement service module**

  Create `profit_api/sla.py` with:

  - `SlaDashboardStore` protocol exposing `read_view`
  - `SlaDashboardService`
  - methods `summary`, `clients`, `workload`, `queue`, `performance`, and `backfill`
  - validation for locked state filters only
  - pagination clamping
  - fixed performance endpoint with no `lookback_days` argument

- [ ] **Step 4: Register API routes**

  Modify `profit_api/app.py` to:

  - import `SlaDashboardService`
  - add optional `sla_service` injection to `create_app`
  - instantiate the service with the existing `SupabaseRestClient`
  - add six `GET /api/profit/admin/sla/*` routes
  - map validation errors to HTTP 422

- [ ] **Step 5: Run green API tests**

  Run: `pytest tests/test_profit_api_sla.py -q`

  Expected: PASS.

- [ ] **Step 6: Regression checkpoint**

  Run: `pytest tests/test_profit_api_sla.py tests/test_profit_api_audit.py tests/test_profit_api_dashboard.py tests/test_profit_api_pipeline.py -q`

  Expected: PASS; audit and pipeline endpoint behavior remains unchanged.

- [ ] **Step 7: Commit**

  Commit message: `feat: expose SLA dashboard API`

### Task 5: Frontend Route Shell And Navigation

**Purpose:** Make `/profit/admin/sla` and `/profit/admin/sla/backfill` reachable and read-only.

**Files:**

- Create: `app/frontend/src/routes/SlaDashboard.jsx`
- Create: `app/frontend/src/routes/SlaBackfill.jsx`
- Modify: `app/frontend/src/App.jsx`
- Modify: `app/frontend/src/components/PortalNav.jsx`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write red frontend static tests**

  Extend `tests/test_profit_admin_frontend.py` proving:

  - `App.jsx` imports `SlaDashboard` and `SlaBackfill`.
  - `App.jsx` registers `/admin/sla` and `/admin/sla/backfill`.
  - `PortalNav.jsx` includes `SLA` linked to `/admin/sla`.
  - `SlaDashboard.jsx` exists and contains `/profit/admin/sla/summary`, `/clients`, `/workload`, `/queue`, and `/performance`.
  - `SlaBackfill.jsx` exists and contains `/profit/admin/sla/backfill`.
  - Both SLA route files import/use `EmptyState`.
  - SLA route files do not contain `fetch(` calls with `POST`, `PATCH`, or `DELETE`.
  - The main SLA dashboard links to `/admin/sla/backfill` but does not render the backfill queue table in-page.

- [ ] **Step 2: Run red frontend tests**

  Run: `pytest tests/test_profit_admin_frontend.py -q`

  Expected: FAIL because SLA route files and route/nav registrations do not exist.

- [ ] **Step 3: Implement route shell**

  Create:

  - `app/frontend/src/routes/SlaDashboard.jsx` with summary loading, read-only tab/segmented controls for clients/workload/queue/performance, empty/error/loading states, and a link to `/admin/sla/backfill`.
  - `app/frontend/src/routes/SlaBackfill.jsx` with read-only loading/error/empty states and the backfill endpoint fetch.

  Modify:

  - `app/frontend/src/App.jsx` to register both routes.
  - `app/frontend/src/components/PortalNav.jsx` to add `SLA`.

- [ ] **Step 4: Run green frontend static tests**

  Run: `pytest tests/test_profit_admin_frontend.py -q`

  Expected: PASS for static route/nav/read-only contracts.

- [ ] **Step 5: Build checkpoint**

  Run: `cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build`

  Expected: PASS with Vite production build.

- [ ] **Step 6: Commit**

  Commit message: `feat: add SLA dashboard routes`

### Task 6: SLA Panels, Backfill UI, And Styles

**Purpose:** Fill the routes with complete read-only SLA and backfill surfaces.

**Files:**

- Modify: `app/frontend/src/routes/SlaDashboard.jsx`
- Modify: `app/frontend/src/routes/SlaBackfill.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write red frontend panel tests**

  Extend `tests/test_profit_admin_frontend.py` proving:

  - `SlaDashboard.jsx` contains panel anchors `sla-client-status`, `sla-staff-workload`, `sla-breach-queue`, and `sla-performance`.
  - `SlaBackfill.jsx` contains anchor `sla-anchor-backfill`.
  - `SlaDashboard.jsx` renders fields for target SLA day, state, age days, staff, service, workflow status, client/group, and last activity.
  - `SlaDashboard.jsx` renders workload counts for open, breached, at-risk, waiting-on-client, and total/in-flight work.
  - `SlaDashboard.jsx` renders fixed `90-day` performance copy and does not include a lookback selector.
  - `SlaBackfill.jsx` renders client/group, QBO payment evidence, missing Anchor agreement/invoice state, age days, and auto-transition eligibility.
  - `styles.css` contains `/* === V0.6.D: SLA dashboard === */` and `.sla-` selectors.
  - SLA route sources do not include nested-card page-section patterns such as `card card`.

- [ ] **Step 2: Run red frontend panel tests**

  Run: `pytest tests/test_profit_admin_frontend.py -q`

  Expected: FAIL until the detailed panel fields/styles are present.

- [ ] **Step 3: Implement main SLA panels**

  Update `SlaDashboard.jsx` to render:

  - summary tiles for total applicable work, breached, at-risk, waiting on client, and not applicable
  - per-client SLA table
  - per-staff workload table grouped by assignee/fallback staff
  - breach/at-risk queue sorted by state severity and age
  - fixed 90-day staff/service performance table
  - refresh affordance consistent with existing frontend patterns
  - empty, loading, and API error states for every panel

- [ ] **Step 4: Implement backfill sub-route UI**

  Update `SlaBackfill.jsx` to render:

  - page title and back link to `/admin/sla`
  - read-only Anchor backfill queue table
  - QBO payment evidence columns from Task 1/Task 3
  - missing Anchor agreement/invoice state
  - aging and auto-transition eligibility
  - empty, loading, and API error states

- [ ] **Step 5: Add scoped CSS**

  Append SLA styles to `app/frontend/src/styles.css` under:

  `/* === V0.6.D: SLA dashboard === */`

  Expected styling constraints:

  - no nested cards inside cards
  - stable table/control dimensions
  - readable mobile overflow behavior
  - restrained operational dashboard layout
  - class names prefixed with `sla-` where practical

- [ ] **Step 6: Run green frontend tests and build**

  Run:

  - `pytest tests/test_profit_admin_frontend.py -q`
  - `cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build`

  Expected: PASS.

- [ ] **Step 7: Commit**

  Commit message: `feat: render SLA dashboard panels`

### Task 7: Data Contracts And Tech-Debt Updates

**Purpose:** Make the SLA behavior discoverable for future slices.

**Files:**

- Create: `docs/data-contracts/sla-dashboard.md`
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md`
- Modify: `tests/test_data_references_docs.py`

- [ ] **Step 1: Write red docs/static tests**

  Extend `tests/test_data_references_docs.py` proving docs mention:

  - `docs/data-contracts/sla-dashboard.md`
  - locked SLA states
  - at-risk threshold formula
  - SQL-owned canonical state
  - task assignee first with FC staff tag fallback
  - fixed 90-day performance view
  - `/api/profit/admin/sla/backfill`
  - `SETTLED_VIA_QUICKBOOKS_PAYMENT` as read-only backfill eligibility
  - deferred A-E items remain deferred

- [ ] **Step 2: Run red docs tests**

  Run: `pytest tests/test_data_references_docs.py -q`

  Expected: FAIL because the new SLA data contract doc does not exist and existing docs do not mention V0.6.D SLA contracts.

- [ ] **Step 3: Create SLA data contract**

  Create `docs/data-contracts/sla-dashboard.md` documenting:

  - SQL views and one-line responsibilities
  - endpoint payload shapes
  - state precedence and locked states
  - at-risk formula
  - workflow-status tag mapping
  - staff workload assignment fallback
  - fixed 90-day performance scope
  - Anchor backfill queue fields and read-only semantics

- [ ] **Step 4: Update existing docs**

  Modify:

  - `docs/data-contracts/fulfillment-classifications.md` to link the backfill queue to `SETTLED_VIA_QUICKBOOKS_PAYMENT`.
  - `docs/tech-debt.md` to mark only FC workflow-status tag deferral resolved after implementation.

  Leave W16, stale service defaults, recognized drill-down, review checklist state, per-tile staleness, audit density, frontend test infrastructure, and Manual Recognition UI polish as follow-up/deferred notes.

- [ ] **Step 5: Run green docs tests**

  Run: `pytest tests/test_data_references_docs.py -q`

  Expected: PASS.

- [ ] **Step 6: Commit**

  Commit message: `docs: document SLA dashboard contracts`

### Task 8: Integrated Verification And Deploy Prep

**Purpose:** Verify the complete V0.6.D slice against existing backend/frontend conventions and prepare operator handoff.

**Files:**

- No new implementation files beyond prior tasks.
- Release notes or PR body only if requested during execution.

- [ ] **Step 1: Run focused verification**

  Run:

  - `pytest tests/test_sla_dashboard_sql.py tests/test_profit_api_sla.py tests/test_profit_admin_frontend.py tests/test_data_references_docs.py -q`

  Expected: PASS.

- [ ] **Step 2: Run related backend regression suite**

  Run:

  - `pytest tests/test_fulfillment_classification_sql.py tests/test_fulfillment_audit_queries.py tests/test_profit_api_audit.py tests/test_profit_api_dashboard.py tests/test_profit_api_pipeline.py tests/test_n8n_workflows.py -q`

  Expected: PASS.

- [ ] **Step 3: Run frontend production build**

  Run:

  - `cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build`

  Expected: PASS.

- [ ] **Step 4: Live SQL/API smoke checkpoint**

  After migrations are applied in the operator-approved environment, verify:

  - `select count(*) from profit_sla_service_items;`
  - `select count(*) from profit_sla_client_status;`
  - `select count(*) from profit_sla_staff_workload;`
  - `select count(*) from profit_sla_breach_queue;`
  - `select count(*) from profit_sla_staff_service_performance_90d;`
  - `select count(*) from profit_sla_anchor_backfill_queue;`
  - `curl` or equivalent GET for `/api/profit/admin/sla/summary`
  - `curl` or equivalent GET for `/api/profit/admin/sla/backfill`

  Expected: all SQL views and API endpoints return 200/valid rows or empty arrays without write side effects.

- [ ] **Step 5: Frontend smoke checkpoint**

  If a local dev server is needed for visual verification, run it after implementation and inspect:

  - `/profit/admin/sla`
  - `/profit/admin/sla/backfill`
  - `/profit/admin/audit`
  - `/profit/admin/recognition`
  - `/profit/admin/pipeline`

  Expected: SLA routes render, backfill is a separate sub-route, existing admin routes still render, and no C.5 dashboard anchors changed.

- [ ] **Step 6: Deploy prep**

  Prepare deploy notes:

  - apply `028_profit_sla_core_views.sql`
  - apply `028a_profit_sla_backfill_and_performance_views.sql`
  - deploy frontend by direct `scp -P 2222 -r app/frontend/dist/* root@104.225.220.36:/opt/agents/outscore_profit/frontend/dist/`
  - do not use `app/deploy/deploy_profit_app.sh`

- [ ] **Step 7: Commit**

  Commit message: `chore: verify SLA dashboard slice`

  Commit only if implementation execution made verification/deploy-prep doc changes. If Task 8 only runs commands and reports evidence, no commit is required.

## Self-Review

- Spec coverage: The plan covers dedicated SLA API routes, SQL `profit_sla_*` views, SQL-owned state computation, the locked five states, workflow-status wiring, per-client status, staff workload, breach/at-risk triage, fixed 90-day performance, and dedicated Anchor backfill sub-route.
- Locked decision coverage: G1-G7 and inclusion gates A-E are all converted to `LOCKED:` decisions, and the five open questions are moved into `Resolved Decisions`.
- Migration consistency: V0.6.D starts after C.c `027` and `027a`; the selected files are `028_profit_sla_core_views.sql` and `028a_profit_sla_backfill_and_performance_views.sql`.
- File-path consistency: SQL uses `supabase/sql/028*.sql`; API uses new `profit_api/sla.py`; frontend uses `app/frontend/src/routes/SlaDashboard.jsx` and `app/frontend/src/routes/SlaBackfill.jsx`; tests extend current repo conventions.
- Scope restraint: The plan does not modify V0.6.C.5 shared component internals, existing dashboard scroll anchors, Manual Recognition UI, audit density UI, recognized drill-down, review tracking, per-tile staleness, or frontend test infrastructure.
- Placeholder scan: No task uses unresolved placeholder language for implementation requirements. The only stop condition is explicit `DECISION NEEDED` from Task 1 source-signal mismatch.
- Type consistency: The plan uses the same endpoint names, view names, route paths, state strings, and file names across gates, file structure, tasks, docs, and verification.
