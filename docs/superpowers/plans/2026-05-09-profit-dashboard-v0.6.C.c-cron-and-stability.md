# Profit Dashboard V0.6.C.c Cron And Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish V0.6.C pipeline orchestration by adding conservative scheduled execution, stale-run finalization, and minimal run-stability monitoring around the shipped Workflow 26/manual-refresh layer.

**Architecture:** C.c stays on the C.b contract: one durable `profit_pipeline_runs` row is created before Workflow 26 starts, Workflow 26 receives `pipeline_run_id`, writes step rows, and owns normal finalization. Scheduled runs reuse the existing manual-refresh API/webhook path so lock semantics, run logs, operator UI, webhook auth, and cleanup behavior remain consistent. Stale-run handling is database-owned cleanup invoked before automated cron work and exposed as an on-demand RPC.

**Tech Stack:** Supabase SQL/RPC, FastAPI, existing Supabase REST client, n8n Workflow 26 webhook, n8n scheduled wrapper workflow, existing pipeline run-log UI/API, Python `pytest` static/API tests, n8n workflow JSON tests, existing deploy/curl/browser-handoff pattern.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: V0.6.C pipeline orchestration spec and cron cadence: full recognition pipeline nightly at 2:00 AM America/New_York; optional mid-day pipeline disabled by default until V0.6.C has run stability data; no 4-hour cron.
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.C.b-pipeline-orchestration.md`: shipped C.b operational layer: Workflow 26 contract, run finalization, lock semantics, manual refresh API, run-log routes, and explicit C.c deferral for cron/stale-run automation.
- `docs/tech-debt.md`: C.c-load-bearing entries for stuck pipeline detection, webhook 404 after n8n restart, W16 duplicate `revenue_event_key` defect out of scope, and deprecated `auto_apply_enabled_in_b2a` removal out of scope until V0.7.
- `docs/data-contracts/fulfillment-classifications.md`: Pipeline Run Log Schema and Workflow 26 Run Log Semantics; `run_source` already allows `cron`; statuses remain `running`, `success`, `failed`, and `partial`.
- `docs/operator-guides/pipeline-glossary.md`: operator-facing run meanings and common errors; cron failures/partials must map to existing statuses and glossary language.

## Gate Decisions Locked Into This Plan

### G1: Cron Trigger Source

Options:

- **A. n8n built-in Schedule Trigger on Workflow 26 directly.** Workflow 26 would create or receive scheduled execution context in-band, likely requiring schedule-specific insert/lock logic inside n8n.
- **B. External cron/systemd timer calls `POST /api/profit/admin/audit/pipeline-runs` with `run_source='cron'`.** The API creates the `profit_pipeline_runs` row, enforces the existing running lock, calls the Workflow 26 webhook, and returns immediately.
- **C. New n8n scheduled wrapper workflow calls the same API endpoint.** n8n owns time-zone scheduling, but the API still owns row creation and lock semantics.

LOCKED: n8n scheduled wrapper workflow calls existing `POST /api/profit/admin/audit/pipeline-runs` with `run_source='cron'`. Conditional on n8n schedule restart reliability -- verified via Task 1 below. Fallback (if Task 1 finds n8n unreliable): systemd timer, but halt and re-escalate before switching paths.

Reasoning:

- Reusing the API path preserves C.b semantics: one lock, one insert path, one webhook auth mechanism, one run-log shape, and one cleanup path if webhook delivery fails.
- Directly scheduling Workflow 26 creates a second run-start path and risks duplicating insert/lock/finalization behavior inside workflow JSON.
- A wrapper n8n schedule is more operator-visible than OS cron because runs and failures appear in n8n execution history. It also avoids storing Supabase credentials in cron; it only needs the same API auth/curl shape an external timer would use.
- A systemd timer is more restart-resilient than in-process n8n scheduling and has clear host-level logs, but secret handling and observability move outside the current operator workflow.

Implementation gate:

- Task 1 must verify the live n8n schedule survives restart before any C.c implementation assumes the n8n wrapper path.
- If Task 1 cannot confirm reliability in roughly 10 minutes, stop and escalate. Do not silently implement systemd.

### G2: Stuck-Run Detection Mechanism

Options:

- **A. SQL function `profit_finalize_stale_pipeline_runs(p_threshold interval)` plus scheduled invocation.**
- **B. n8n workflow checks for stale `running` rows and patches them directly.**
- **C. API endpoint finalizes stale rows from application code.**

LOCKED: SQL function `profit_finalize_stale_pipeline_runs(p_threshold interval)`. Default `30 minutes`. Action: set `status='failed'`, `finished_at=now()`, `summary.error_summary='Stuck running detection - no progress for >30min'`. Preserve all existing summary keys. No new run statuses. Function returns finalized row count/identifiers. Called pre-cron AND available as on-demand RPC.

Reasoning:

- The invariant belongs beside the lock: stale `status='running'` rows block `idx_profit_pipeline_runs_one_running`, so the database should atomically identify and finalize stale rows.
- A SQL function can update `finished_at`, `status='failed'`, and `summary.error_summary` in one operation with predictable race behavior.
- n8n/API code can call the function, but should not reimplement stale-row criteria in multiple places.
- The default threshold from tech debt and the operator guide is 30 minutes.

Locked behavior:

- Threshold: `30 minutes`.
- Candidate rows: `profit_pipeline_runs.status = 'running'` and `started_at < now() - p_threshold`.
- Action: mark `status='failed'`, set `finished_at=now()`, preserve existing `summary` keys, and set `summary.error_summary = 'Stuck running detection - no progress for >30min'`.
- Existing statuses only: no new `stuck` status.
- The function returns finalized row identifiers and a count for logs, tests, and on-demand RPC callers.

Edge cases:

- Legitimately long-running step: keep the threshold configurable via function argument, but schedule default remains 30 minutes. If W26 later proves normal duration can exceed 30 minutes, update the caller threshold instead of changing status semantics.
- Recovery semantics: after stale finalization, the next cron/manual run may start normally because the partial unique index is unblocked.
- Race with normal finalization: SQL should only update rows still `running`; if Workflow 26 finalizes first, stale cleanup returns no row.

### G3: Mid-Day Cron Decision

Options:

- **A. Build a disabled-by-default mid-day schedule/toggle in C.c.**
- **B. Defer mid-day scheduling until V0.7 or after observed V0.6.C run-stability data.**

LOCKED: Deferred. Document explicitly as out-of-scope in plan.

Reasoning:

- The V0.6 spec explicitly says optional mid-day pipeline is disabled by default until V0.6.C has run stability data.
- C.c should establish nightly automation and stale-run cleanup first. Adding a dormant toggle now expands configuration and test surface without delivering an active workflow.
- Manual refresh already covers urgent operational cases while automated side effects are still being observed.

Plan note:

- Mid-day cron is out of scope for C.c. Revisit after several successful nightly runs and no repeated stale-run cleanups.

### G4: Run-Stability Monitoring

Options:

- **A. Log-only: scheduled runner logs latest run result and stale cleanup count.**
- **B. SQL view/function summarizes recent failures/partials and consecutive bad runs for operator review.**
- **C. Active alerting to Slack/email after N consecutive failed/partial runs.**

LOCKED: SQL view OR function summarizing recent cron runs. Surface latest cron run health: `run_source='cron'` + `status in ('success','failed','partial')`. Threshold: flag when latest 2 cron runs are `failed` or `partial`, include latest `error_summary`. NO external alerting (Slack/email). NO new statuses.

Reasoning:

- V0.6.D owns push alerts and SLA/dashboard polish next; C.c should not introduce Slack/email routing, credentials, or notification policy.
- A SQL object keeps monitoring queryable from ops, tests, and future UI/alerting without creating external dependencies.
- Log-only is too weak for final orchestration hardening because it does not give Orlando a durable stability signal.

Chosen implementation trade-off:

- Use a SQL view named `profit_cron_pipeline_run_health` for C.c. The threshold is fixed at 2 consecutive bad terminal cron runs, so a view is simpler than an RPC function and easier to inspect with Supabase SQL editor/curl.
- Defer a parameterized function until a future requirement needs custom lookback windows, custom thresholds, or multiple consumers with different alert policies.

Locked behavior:

- Monitor terminal scheduled runs only: `run_source='cron'` and `status in ('success', 'failed', 'partial')`.
- Threshold: surface when the latest 2 cron runs are `failed` or `partial`, and include the latest `error_summary`.
- No new run statuses. Cron failures and partials retain existing glossary meanings.

### G5: Webhook-404-After-Restart Handling

Options:

- **A. Include retry-with-backoff in C.c in the API webhook client before cleanup/error return.**
- **B. Add a dedicated webhook health probe before inserting the running row.**
- **C. Defer entirely and keep operator retry guidance only.**

LOCKED: API-side retry-with-backoff in `POST /api/profit/admin/audit/pipeline-runs` webhook-call path. 2 attempts max, ~3-5s backoff. Surface decision in plan: where exactly the retry sits (before or after the run row insert) and rollback semantics if all retries fail.

Reasoning:

- The tech-debt note says retry resolves n8n restart-time webhook registration lag, and this is directly load-bearing for scheduled unattended runs.
- API-side retry benefits both manual and cron starts because both use the same webhook call path.
- A pre-insert health probe can race with actual webhook registration and adds another endpoint/contract to maintain.

Locked behavior:

- Retry sits after the `profit_pipeline_runs` row insert and before the endpoint returns, inside the existing webhook-call path. The inserted row is required so the webhook payload has the durable `pipeline_run_id` Workflow 26 expects.
- Use 2 attempts max: initial webhook attempt plus 1 retry after roughly 3-5 seconds.
- Retry HTTP 404, connection refused, timeout, and 5xx. Non-transient 4xx remains a hard failure.
- If all attempts fail, preserve C.b cleanup semantics: delete the just-created running row and return/report failure. No failed row is retained for webhook-start failures because Workflow 26 never received the run.

## Resolved Decisions

- **Q1:** Verify n8n schedule survives restart. Trigger test schedule on Workflow 26, restart n8n process, confirm schedule re-fires at expected time. Time-box to roughly 10 minutes. If reliability is not confirmed, halt and re-escalate; do not silently fall back.
- **Q2:** Cron reuses the same endpoint as manual refresh: `POST /api/profit/admin/audit/pipeline-runs` plus `run_source='cron'`. No new internal endpoint.
- **Q3:** SQL health view ships in C.c. Push alerts are deferred to V0.6.D.

## Scope

In scope:

- Nightly full recognition pipeline start at 2:00 AM America/New_York.
- Scheduled run creation with `run_source='cron'` and `triggered_by='cron'`.
- Reuse of Workflow 26 and existing run-log statuses.
- Stale running-row finalization with 30-minute default threshold.
- Webhook delivery retry/backoff for restart-time 404 and similar transient failures.
- Minimal durable run-stability query for recent cron failures/partials.
- Tests and docs for the above.

Out of scope:

- Fixing W16 duplicate `revenue_event_key` behavior.
- Removing `auto_apply_enabled_in_b2a`.
- V0.6.D SLA dashboard work and push alerts.
- Mid-day cron enablement, schedule artifact, or UI toggle.
- New statuses, new user-facing run-log pages, or broader pipeline UI redesign.
- Reworking C.b Workflow 26 step composition beyond schedule/start hardening.
- Switching to systemd timer without a fresh Orlando decision after Task 1.

## File Structure

Create:

- `supabase/sql/027_profit_finalize_stale_pipeline_runs.sql`: defines `profit_finalize_stale_pipeline_runs(p_threshold interval default interval '30 minutes')`, updates stale `running` rows atomically, preserves existing `summary` keys, and returns finalized identifiers/count.
- `supabase/sql/027a_profit_cron_pipeline_run_health.sql`: defines `profit_cron_pipeline_run_health` view for latest terminal cron health, consecutive bad-run count, threshold flag, and latest `error_summary`.
- `n8n/workflows/profit-29-schedule-wrapper.json`: n8n wrapper workflow with Schedule Trigger at 2:00 AM America/New_York, stale cleanup RPC call, and shared manual-refresh API call with `run_source='cron'`. Number `29` follows the existing workflow sequence, where `profit-28-qbo-product-sync.json` already exists.

Modify:

- `profit_api/pipeline.py`: accept cron source through the existing run-start service path, set `triggered_by='cron'` for cron starts, and add 2-attempt webhook retry/backoff after row insert and before cleanup/error return.
- `profit_api/app.py`: preserve existing `POST /api/profit/admin/audit/pipeline-runs` route while allowing `run_source='cron'` in the request body; no new cron endpoint.
- `tests/test_profit_api_pipeline.py`: add red/green tests for cron-source request behavior and webhook retry/cleanup semantics.
- `tests/test_n8n_workflows.py`: add static workflow tests for `profit-29-schedule-wrapper.json`, Schedule Trigger timezone/cadence, stale cleanup before API start, and cron payload shape.
- `docs/data-contracts/fulfillment-classifications.md`: document cron start semantics, stale-run finalization behavior, monitoring view, and webhook retry behavior.
- `docs/operator-guides/pipeline-glossary.md`: replace SQL-cleanup escalation language with C.c stale-run automation guidance and add the cron health view interpretation.
- `docs/tech-debt.md`: mark stuck-run detection and webhook 404 handling resolved by C.c after implementation; leave W16 and `auto_apply_enabled_in_b2a` entries out of C.c.

Do not modify:

- `n8n/workflows/profit-16-apply-recognition-triggers.json`.
- `n8n/workflows/profit-26-pipeline-orchestration.json`, except during Task 1 live operational verification if n8n needs a temporary schedule-test clone or test fixture. Do not commit such a temporary artifact.
- `app/frontend/**` unless Orlando explicitly requests a cron-health UI surface in a later version.
- Existing C.b route/component structure except as needed for shared API payload typing.
- V0.6.D SLA files or future `auto_apply_enabled_in_b2a` removal work.

## Sub-Decisions Made

- Use `profit-29-schedule-wrapper.json` because the repository already has `profit-28-qbo-product-sync.json`; do not reuse `profit-27` for workflow JSON.
- Split SQL into `027_` stale cleanup and `027a_` cron health so each migration has one operational responsibility and can be tested independently.
- Implement G4 as a SQL view, not a function, because C.c has a fixed threshold and no parameterization requirement.
- Keep cron API tests in existing `tests/test_profit_api_pipeline.py` because the current C.b tests already cover the shared route and fake webhook/store infrastructure.
- Use 2 attempts as "initial attempt + 1 retry" with a single 3-5 second delay, matching G5's max-attempt limit and keeping manual refresh latency bounded.

## Sub-Decisions Surfaced As DECISION NEEDED

- None at plan-refinement time. During Task 5, if the n8n wrapper requires a new shared credential or a new secret storage path that C.b did not already use, stop and escalate before routing around it.

## Task Breakdown

Each implementation task below follows red test -> green implementation -> checkpoint verification -> commit. Do not combine commits across tasks unless Orlando explicitly changes the execution model.

### Task 1: Verify n8n Schedule Restart-Survival

**Purpose:** Resolve Q1 operationally before committing to the n8n wrapper path.

**Files:**

- Read: `n8n/workflows/profit-26-pipeline-orchestration.json`
- Optional test-only fixture: uncommitted n8n UI clone or temporary disabled schedule workflow based on Workflow 26
- Do not modify repo files unless a temporary local fixture is unavoidable; delete temporary fixtures before moving to Task 2.

- [ ] **Step 1: Create a short-interval schedule test**

  In the live n8n instance, create or clone a test schedule that safely exercises Workflow 26's trigger path without running the full nightly pipeline unexpectedly. Prefer a disabled/test wrapper that calls a harmless endpoint or a known test-safe target if the live instance has one.

- [ ] **Step 2: Confirm the first scheduled fire**

  Observe the scheduled execution at the expected minute and capture:

  - workflow id/name
  - scheduled time
  - actual execution time
  - execution status
  - whether timezone handling matches America/New_York expectations

- [ ] **Step 3: Restart n8n**

  Restart the n8n process using the live environment's normal process manager. Do not change persistence, credentials, or production workflow configuration during this test.

- [ ] **Step 4: Confirm schedule re-fires after restart**

  Wait for the next expected scheduled fire within the roughly 10-minute time box. Confirm the workflow execution appears after restart without manual reactivation.

- [ ] **Step 5: Decision checkpoint**

  If schedule restart-survival is confirmed, proceed to Task 2 on the n8n wrapper path.

  If not confirmed, halt and report the finding to Orlando. Do not implement the systemd fallback without a new explicit decision.

- [ ] **Step 6: Commit**

  No commit for Task 1 unless a committed test fixture was explicitly needed and approved. Expected normal result: operational evidence only.

### Task 2: SQL Function `profit_finalize_stale_pipeline_runs`

**Purpose:** Add database-owned stale-run cleanup with a 30-minute default threshold.

**Files:**

- Create: `supabase/sql/027_profit_finalize_stale_pipeline_runs.sql`
- Test: SQL verification through Supabase SQL editor/psql transaction or existing migration test harness if present
- Docs later: `docs/operator-guides/pipeline-glossary.md`, `docs/data-contracts/fulfillment-classifications.md`, `docs/tech-debt.md`

- [ ] **Step 1: Write the failing SQL test**

  Create a transaction-scoped verification script that inserts:

  - one `running` row older than 30 minutes with an existing `summary` key
  - one recent `running` row
  - one already terminal row

  Call `profit_finalize_stale_pipeline_runs(interval '30 minutes')` before the migration exists and verify it fails because the function is undefined.

- [ ] **Step 2: Run the red test**

  Run the SQL verification against dev.

  Expected: failure with `function profit_finalize_stale_pipeline_runs(interval) does not exist` or equivalent undefined-function error.

- [ ] **Step 3: Add the migration**

  Implement `supabase/sql/027_profit_finalize_stale_pipeline_runs.sql` with:

  - default argument `p_threshold interval default interval '30 minutes'`
  - candidate filter `status = 'running'` and `started_at < now() - p_threshold`
  - update to `status='failed'`, `finished_at=now()`
  - JSON summary merge preserving existing keys and setting exact `error_summary`
  - return shape containing finalized run identifiers and count

- [ ] **Step 4: Run the green SQL test**

  Apply the migration to dev, then rerun the transaction-scoped verification.

  Expected: only the stale row is finalized; existing `summary` keys remain; exact `summary.error_summary` is present; recent and terminal rows are unchanged.

- [ ] **Step 5: Manual integration checkpoint**

  Insert a synthetic stuck row in dev, call the RPC on demand, confirm the partial unique running lock is unblocked, then remove the synthetic data if the test transaction did not roll back automatically.

- [ ] **Step 6: Commit**

  Commit message: `feat: finalize stale pipeline runs`

### Task 3: SQL View For Cron-Stability Monitoring

**Purpose:** Expose durable cron health without external alerting.

**Files:**

- Create: `supabase/sql/027a_profit_cron_pipeline_run_health.sql`
- Test: SQL verification through Supabase SQL editor/psql transaction or existing migration test harness if present
- Docs later: `docs/operator-guides/pipeline-glossary.md`, `docs/data-contracts/fulfillment-classifications.md`

- [ ] **Step 1: Write the failing SQL test**

  Create a transaction-scoped verification script that inserts terminal cron rows covering:

  - latest two rows both `failed`/`partial`
  - latest row `success`
  - manual rows that must be ignored
  - `running` cron rows that must be ignored

  Query `profit_cron_pipeline_run_health` before the migration exists and verify it fails because the relation is undefined.

- [ ] **Step 2: Run the red test**

  Run the SQL verification against dev.

  Expected: failure with `relation profit_cron_pipeline_run_health does not exist` or equivalent undefined-relation error.

- [ ] **Step 3: Add the migration**

  Implement `supabase/sql/027a_profit_cron_pipeline_run_health.sql` as a view that returns the latest terminal cron health, including:

  - latest cron run id
  - latest cron run status
  - latest cron `started_at` and `finished_at`
  - latest `summary.error_summary`
  - count of consecutive latest bad terminal cron runs
  - boolean flag when the latest 2 terminal cron runs are `failed` or `partial`

- [ ] **Step 4: Run the green SQL test**

  Apply the migration to dev, then rerun the transaction-scoped verification.

  Expected: the view ignores manual/running rows, flags two latest bad terminal cron runs, includes latest error summary, and resets the flag when the latest terminal cron run is `success`.

- [ ] **Step 5: Integration checkpoint**

  Query the view against current dev data and confirm the result shape is stable even when there are fewer than two terminal cron runs.

- [ ] **Step 6: Commit**

  Commit message: `feat: expose pipeline cron stability health`

### Task 4: API-Side Webhook Retry-With-Backoff

**Purpose:** Harden the shared manual/cron run-start path against n8n restart-time webhook registration lag.

**Files:**

- Modify: `tests/test_profit_api_pipeline.py`
- Modify: `profit_api/pipeline.py`
- Modify if route schema requires it: `profit_api/app.py`

- [ ] **Step 1: Write the failing retry tests**

  Add focused tests in `tests/test_profit_api_pipeline.py` proving:

  - webhook 404 on the first attempt and success on the second keeps the inserted run row and returns accepted
  - timeout/connection/5xx behavior is retryable
  - repeated retryable failure deletes the inserted running row
  - non-transient 4xx does not retry and still cleans up the inserted running row

- [ ] **Step 2: Run the red API tests**

  Run: `pytest tests/test_profit_api_pipeline.py -k "webhook or pipeline_run" -v`

  Expected: new retry-count assertions fail because the current service performs one webhook attempt.

- [ ] **Step 3: Implement minimal retry behavior**

  Update `profit_api/pipeline.py` so the existing webhook-call path:

  - inserts the run row first
  - calls the webhook
  - retries once after roughly 3-5 seconds for HTTP 404, timeout, connection refused, and 5xx
  - deletes the inserted running row if all attempts fail
  - preserves current manual refresh behavior and error response shape as much as possible

- [ ] **Step 4: Run the green API tests**

  Run: `pytest tests/test_profit_api_pipeline.py -k "webhook or pipeline_run" -v`

  Expected: retry and cleanup tests pass.

- [ ] **Step 5: Regression checkpoint**

  Run: `pytest tests/test_profit_api_pipeline.py -v`

  Expected: existing manual run-log tests still pass.

- [ ] **Step 6: Commit**

  Commit message: `fix: retry transient pipeline webhook startup failures`

### Task 5: n8n Scheduled Wrapper Workflow JSON

**Purpose:** Add the nightly schedule artifact that calls the existing manual-refresh API endpoint with cron source.

**Files:**

- Create: `n8n/workflows/profit-29-schedule-wrapper.json`
- Modify: `tests/test_n8n_workflows.py`

- [ ] **Step 1: Write the failing workflow fixture test**

  Add tests in `tests/test_n8n_workflows.py` asserting `profit-29-schedule-wrapper.json` exists and contains:

  - a Schedule Trigger set to 2:00 AM America/New_York
  - an HTTP request to `POST /api/profit/admin/audit/pipeline-runs`
  - request JSON including `run_source='cron'` and `triggered_by='cron'` if the endpoint accepts both fields
  - no direct call to Workflow 26's n8n webhook
  - no new run status strings

- [ ] **Step 2: Run the red workflow test**

  Run: `pytest tests/test_n8n_workflows.py -k "schedule_wrapper or pipeline" -v`

  Expected: failure because the wrapper workflow JSON does not exist.

- [ ] **Step 3: Create the wrapper JSON**

  Build `n8n/workflows/profit-29-schedule-wrapper.json` following existing n8n export conventions in `n8n/workflows/*.json`. Include:

  - Schedule Trigger at 2:00 AM America/New_York
  - API auth matching the existing admin/manual-refresh request pattern
  - `POST /api/profit/admin/audit/pipeline-runs`
  - JSON payload with `run_source='cron'`
  - execution/log nodes only as needed for observability

- [ ] **Step 4: Run the green workflow test**

  Run: `pytest tests/test_n8n_workflows.py -k "schedule_wrapper or pipeline" -v`

  Expected: wrapper workflow static tests pass.

- [ ] **Step 5: Checkpoint**

  Import or validate the JSON in n8n without enabling the production nightly schedule until Task 7. Confirm the workflow has no missing credentials. If a new shared credential is required, halt and escalate before continuing.

- [ ] **Step 6: Commit**

  Commit message: `feat: schedule nightly recognition pipeline`

### Task 6: Wire Pre-Cron Stale-Run Cleanup Invocation

**Purpose:** Ensure the scheduled wrapper clears stale running rows before starting a new cron run.

**Files:**

- Modify: `n8n/workflows/profit-29-schedule-wrapper.json`
- Modify: `tests/test_n8n_workflows.py`
- Optional modify: `profit_api/pipeline.py` only if the shared API start path needs a thin RPC helper for wrapper compatibility

- [ ] **Step 1: Write the failing workflow order test**

  Extend `tests/test_n8n_workflows.py` so the wrapper must:

  - call `profit_finalize_stale_pipeline_runs` before `POST /api/profit/admin/audit/pipeline-runs`
  - pass the default threshold or omit the threshold to use the SQL default
  - continue to the cron start call after cleanup succeeds
  - expose cleanup result in execution data/logs

- [ ] **Step 2: Run the red workflow test**

  Run: `pytest tests/test_n8n_workflows.py -k "schedule_wrapper or stale" -v`

  Expected: failure until the cleanup RPC node and ordering are present.

- [ ] **Step 3: Update the wrapper workflow**

  Add the pre-cron cleanup invocation before the manual-refresh API call. The wrapper should call the Supabase RPC for `profit_finalize_stale_pipeline_runs` using the configured service/admin credential already used by existing operational workflows, then call the API endpoint with `run_source='cron'`.

- [ ] **Step 4: Run the green workflow tests**

  Run: `pytest tests/test_n8n_workflows.py -k "schedule_wrapper or stale" -v`

  Expected: stale cleanup ordering and cron payload tests pass.

- [ ] **Step 5: Integration checkpoint**

  In dev, run the wrapper manually with the schedule disabled. Confirm the cleanup RPC executes before the cron-start API call and that the API receives `run_source='cron'`.

- [ ] **Step 6: Commit**

  Commit message: `feat: run stale pipeline cleanup before cron`

### Task 7: Deploy And Live Verification

**Purpose:** Prove C.c works end-to-end and update operator-facing docs only after behavior is verified.

**Files:**

- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/operator-guides/pipeline-glossary.md`
- Modify: `docs/tech-debt.md`
- Read: `supabase/sql/027_profit_finalize_stale_pipeline_runs.sql`
- Read: `supabase/sql/027a_profit_cron_pipeline_run_health.sql`
- Read: `n8n/workflows/profit-29-schedule-wrapper.json`

- [ ] **Step 1: Write the failing docs/static scan**

  Add or run a static scan proving docs do not yet mention:

  - cron source via the shared manual-refresh endpoint
  - stale-run automation with the exact error summary
  - cron health view and two-bad-run threshold
  - webhook retry behavior
  - mid-day cron deferral

  Expected: scan fails before docs are updated.

- [ ] **Step 2: Deploy database migrations to dev**

  Apply:

  - `supabase/sql/027_profit_finalize_stale_pipeline_runs.sql`
  - `supabase/sql/027a_profit_cron_pipeline_run_health.sql`

  Confirm both SQL objects exist in dev.

- [ ] **Step 3: Deploy/import wrapper workflow**

  Import `n8n/workflows/profit-29-schedule-wrapper.json` into n8n, keep the schedule disabled until manual verification is complete, and verify required credentials are present.

- [ ] **Step 4: Live stale-cleanup verification**

  Create a synthetic stuck `profit_pipeline_runs` row in dev, call `profit_finalize_stale_pipeline_runs()`, and confirm:

  - row status becomes `failed`
  - `finished_at` is set
  - existing summary keys remain
  - `summary.error_summary` equals `Stuck running detection - no progress for >30min`
  - a new run can start after cleanup

- [ ] **Step 5: Live retry-path verification**

  Exercise the API retry path with a controlled fake/mocked webhook client in tests and, if safe, with a live n8n restart window. Confirm repeated webhook failure deletes the inserted running row.

- [ ] **Step 6: Live cron wrapper verification**

  Manually execute the wrapper once in dev with schedule disabled. Confirm:

  - stale cleanup runs first
  - `POST /api/profit/admin/audit/pipeline-runs` is called
  - created row has `run_source='cron'` and `triggered_by='cron'`
  - Workflow 26 receives `pipeline_run_id`

- [ ] **Step 7: Health view verification**

  Query `profit_cron_pipeline_run_health` with synthetic terminal cron rows and confirm:

  - latest two `failed`/`partial` rows set the flag
  - latest `success` clears the flag
  - latest `error_summary` is included

- [ ] **Step 8: Enable nightly schedule**

  Enable the wrapper schedule for 2:00 AM America/New_York only after Tasks 1-7 checks pass.

- [ ] **Step 9: Update docs**

  Update operator/data-contract/tech-debt docs to reflect implemented behavior, including mid-day cron as out-of-scope and push alerts deferred to V0.6.D.

- [ ] **Step 10: Final verification commands**

  Run:

  - `pytest tests/test_profit_api_pipeline.py -v`
  - `pytest tests/test_n8n_workflows.py -v`
  - any existing SQL migration verification command used by this repo, if present

  Expected: all targeted tests pass.

- [ ] **Step 11: Commit**

  Commit message: `docs: document pipeline cron stability operations`

## Self-Review

Spec coverage:

- Nightly 2:00 AM America/New_York cadence is covered by G1 and Tasks 1, 5, 6, and 7.
- Optional mid-day cron is explicitly deferred by G3, Scope, and Task 7 docs.
- `run_source='cron'` through the existing API endpoint is covered by Resolved Decisions, Tasks 4, 5, 6, and 7.
- Existing status vocabulary is preserved in G2, G4, G5, and all task constraints.
- Stuck-run detection at 30 minutes is covered by G2 and Tasks 2, 6, and 7.
- Webhook 404 after restart is covered by G5 and Task 4.
- SQL health view shipping in C.c is covered by G4 and Task 3.
- Push alerts are deferred to V0.6.D in G4, Resolved Decisions, Scope, and Task 7 docs.

Placeholder scan:

- No implementation placeholders are left for locked architecture.
- The only `DECISION NEEDED` path is a real architectural fork: new credential/secret requirements for the wrapper workflow.
- The systemd fallback is named only as an escalation path after failed Task 1 reliability verification.

Type consistency:

- Run statuses remain `running`, `success`, `failed`, and `partial`.
- Step statuses remain unchanged.
- Cron runs use `run_source='cron'` and `triggered_by='cron'`.
- Stuck detection writes `summary.error_summary` without introducing a new status or field.
- Webhook retry preserves C.b cleanup semantics by deleting the inserted row if Workflow 26 is never triggered.

No scope creep:

- No frontend UI is planned for C.c.
- No external Slack/email alerting is planned for C.c.
- No mid-day schedule artifact is planned for C.c.
- No W16 duplicate-key repair or `auto_apply_enabled_in_b2a` cleanup is included.
