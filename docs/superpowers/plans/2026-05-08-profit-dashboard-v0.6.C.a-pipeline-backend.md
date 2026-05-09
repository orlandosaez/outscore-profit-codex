# Profit Dashboard V0.6.C.a Pipeline Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the V0.6.C.a backend pipeline foundation: pipeline run tables, expanded classification auto-transitions, FC-to-Anchor match reconciliation, and pipeline diagnostic views.

**Architecture:** This slice is SQL/data-layer only. It extends the V0.6.B classification and audit-query foundation without adding frontend, API, n8n workflow, or cron behavior. The pipeline backend remains append-friendly for `profit_classifications`, keeps transition execution in one dry-run/live function, and exposes diagnostic views that V0.6.C.b can consume from Workflow 26 and dashboard hooks.

**Tech Stack:** Supabase Postgres migrations/functions/views, static and SQL-shape `pytest`, live Supabase deploy through the established VPS `psql` pattern, existing V0.6.B audit views/functions, existing FC/Anchor/QBO recognition tables.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: V0.6.C pipeline orchestration spec, including 13-step pipeline, run-log table shape, and diagnostic surfacing.
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.a-audit-query-refactor.md`: structural template and B.2.a backend data-layer contracts.
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.b-audit-dashboard-frontend.md`: frontend/API consumer expectations that C.a must not break.
- `docs/data-contracts/fulfillment-classifications.md`: append-only classification invariant, current apply-transition scope, helper-view contracts, audit-dashboard API conventions.
- `docs/tech-debt.md`: Workflow 25 demotion gap, Workflow 05 agreement-sync limit gap, PENDING_SENT pending-review realism note, Anchor state visibility limitations.
- `supabase/sql/023_profit_fulfillment_classifications.sql`: 14-verdict canon, `profit_classifications`, and seeded transition rules.
- `supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql`: status-aware match-candidate truth table.
- `supabase/sql/025_profit_fulfillment_audit_views.sql`: layered audit views and existing diagnostic surfaces.
- `supabase/sql/025b_profit_audit_helpers.sql`: FC inactive, QBO leaf, and open-invoice helpers.
- `supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql`: inactive-client re-emergence scan v2.
- `supabase/sql/025d_profit_apply_classification_transitions.sql`: B.2.a narrow apply function to replace in migration 026a using the same function name/signature.

## Gate Decisions Locked Into This Plan

### G1: Pipeline Run Tables Shape

Create two run-log tables in `026_profit_pipeline_runs.sql`.

`profit_pipeline_runs` columns:

- `pipeline_run_id uuid primary key default gen_random_uuid()`
- `run_source text not null check (run_source in ('cron', 'manual'))`
- `started_at timestamptz not null default now()`
- `finished_at timestamptz`
- `status text not null check (status in ('running', 'success', 'failed', 'partial'))`
- `triggered_by text`
- `summary jsonb not null default '{}'::jsonb`

`profit_pipeline_run_steps` columns:

- `pipeline_run_id uuid not null references profit_pipeline_runs(pipeline_run_id) on delete cascade`
- `step_name text not null`
- `step_order integer not null check (step_order > 0)`
- `started_at timestamptz not null default now()`
- `finished_at timestamptz`
- `status text not null check (status in ('running', 'success', 'failed', 'skipped'))`
- `rows_affected integer check (rows_affected is null or rows_affected >= 0)`
- `details jsonb not null default '{}'::jsonb`
- primary key `(pipeline_run_id, step_name)`
- unique `(pipeline_run_id, step_order)`

Constraints and indexes:

- Timestamp consistency checks:
  - running rows have `finished_at is null`
  - terminal rows have `finished_at is not null`
- Unique partial index enforcing one active run:
  - `create unique index ... on profit_pipeline_runs ((status)) where status = 'running'`
- Indexes:
  - `idx_profit_pipeline_runs_started_at_desc`
  - `idx_profit_pipeline_runs_status_started_at_desc`
  - `idx_profit_pipeline_run_steps_run_order`

No trigger, status-transition trigger, advisory lock, or retention policy is added in C.a.

`triggered_by` convention:

- Manual runs: operator identifier matching `profit_classifications.classified_by` convention, such as `orlando` or `beth`.
- Cron runs: `cron`.
- Synthetic checkpoint rows: `test`.

`summary` and `details` remain free-form JSONB. Migration comments and the data contract document expected fields:

- `profit_pipeline_runs.summary`: `total_steps_completed`, `total_steps_failed`, `total_rows_affected`, optional `error_summary`, optional `notable_findings`.
- `profit_pipeline_run_steps.details`: step-specific payload, optional `error`, optional `notes`.

Synthetic deploy rows must be explicitly cleaned up. C.a leaves both tables empty after the migration checkpoint.

### G2: Auto-Transition Apply Scope Expansion

Replace the B.2.a `profit_apply_classification_transitions(p_run_at timestamptz, p_dry_run boolean)` implementation with `CREATE OR REPLACE FUNCTION` in migration `026a_profit_apply_classification_transitions_v2.sql`. Keep the same function name, signature, and return shape so B.2.b callers keep working. Migration `027_profit_sla_views.sql` remains reserved for V0.6.D per the V0.6 spec; C.a uses the same suffix convention as V0.6.B (`025a` through `025d`).

Existing B.2.a rule remains active:

- `PENDING_ENGAGEMENT_DRAFT` / `PENDING_ENGAGEMENT_SENT`
- `active_agreement_appears`
- `MIXED`

New C.a executable rules:

- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_group_billed` -> `CONSOLIDATED_VIA_GROUP_BILLED`
- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_mid_cycle` -> `BILLING_OUTSIDE_AUDIT_WINDOW`
- `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_group_parent` -> `CONSOLIDATED_VIA_GROUP_BILLED`
- `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_standalone_mid_cycle` -> `BILLING_OUTSIDE_AUDIT_WINDOW`

Still deferred:

- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + `anchor_backfill_*`: V0.6.D Anchor backfill queue work.
- `INACTIVE_FORMER_CLIENT` + `any_active_signal_returns`: handled by `025c` re-emergence scan v2, not the apply function.

Live active target rows at gate time:

- `LEGACY_ENGAGEMENT_PRE_ANCHOR`: 2 rows, Sutherland Markus H 1040 and Nazario Eric 1040.
- `INVOICE_OUTSTANDING_PAYMENT_PENDING`: 1 row, Sullivan Christopher 1040.
- All three currently have no persisted `profit_fc_client_anchor_matches.anchor_relationship_id`; expanded dry-run is expected to return 0 rows on live data.

Hard limitation to document in the function comment, data contract, and tech debt:

> Auto-transition correctness requires `profit_fc_client_anchor_matches.anchor_relationship_id` to be populated. Classifications for clients without anchor matches will be skipped silently. Use the audit dashboard's any-active-signal filter and Workflow 05/25 sync coverage to surface these cases for manual review.

Group-priority rule:

- Group-billed branch evaluates first.
- Standalone branch evaluates second.
- If both group and standalone signals exist for one classification, transition to `CONSOLIDATED_VIA_GROUP_BILLED`.

Group-sibling semantics:

- Any qualifying sibling invoice/cash signal can trigger the group-billed branch.
- The function fires at most once per source classification, regardless of how many sibling rows qualify.

Cash timing:

- Use `profit_cash_collections.collected_at`.
- Never use `profit_collection_revenue_allocations.loaded_at` as business-event timing.

Frontend compatibility:

- Do not rename B.2.b's `auto_apply_enabled_in_b2a` payload field in C.a.
- C.b may add a new canonical `auto_apply_enabled` field and deprecate the old name.

### G3: Workflow 25 Demotion Fix Design

Create `profit_reconcile_fc_client_anchor_matches(p_dry_run boolean default true)` in `026b_profit_reconcile_fc_client_anchor_matches.sql`.

Function behavior:

- Dry-run/live modes.
- Hard-delete stale persisted rows in live mode.
- Only considers `profit_fc_client_anchor_matches.match_method = 'auto_exact'`.
- Protects `manual_override` and other non-auto rows.
- Demote-eligible if:
  - candidate view now says the client is not `auto_exact`, or
  - candidate view says `auto_exact` but points at a different `anchor_relationship_id`.
- Idempotent: second live invocation returns 0 rows.

Return shape:

- `fc_client_id bigint`
- `fc_client_name text`
- `anchor_relationship_id text`
- `anchor_client_business_name text`
- `persisted_match_status text`
- `persisted_match_method text`
- `candidate_match_status text`
- `candidate_anchor_relationship_id text`
- `candidate_anchor_client_business_name text`
- `candidate_selected_anchor_status text`
- `action text`

Immediate deploy expectation:

- Dry-run returns exactly YV Enterprises HB LLC and YV Enterprises PSL LLC.
- Live deletes exactly 2 rows.
- Second live returns 0.

Operational ordering for C.b:

1. Workflow 05 agreement sync.
2. Workflow 25 upsert.
3. `profit_reconcile_fc_client_anchor_matches(false)`.
4. Audit refresh.
5. Re-emergence scan.
6. Transition apply.

### G4: Workflow 05 Sync Coverage Gap

No Workflow 05 rerun or n8n JSON change happens in C.a.

Gate findings:

- Workflow 05 currently fetches `https://api.sayanchor.com/agreements?limit=50`.
- Anchor `/agreements?limit=100` returns 52 rows: 40 active, 12 terminated.
- Anchor `/agreements?limit=200` returns `INVALID_PAGE_SIZE`.
- `offset=50` does not page; it returns the first 50 again.
- The 2 rows missed by limit 50 are YV Enterprises HB LLC and YV Enterprises PSL LLC active reissues.
- The older "12 active reissued agreements" note for PENDING_SENT rows is not reproducible against `/agreements?limit=100` on 2026-05-08.

C.a constraints:

- C.a expanded apply dry-run still expects 0 rows on live data.
- C.a reconcile deletes YV HB/PSL stale persisted matches; this is safe because Workflow 05 has not yet loaded their current active agreements into the database.
- C.b will raise Workflow 05 to `limit=100` as a short-term fix.

C.b deploy checkpoint expectation to document as tech debt:

- `profit_anchor_agreements`: 40 active, 12 terminated, 0 stale, 52 total after Workflow 05 limit=100 rerun.

### G5: Service-Type-Aware Matching

Use a composite service-type key:

```sql
rule.macro_service_type || '|' || rule.recognition_pattern || '|' || rule.service_period_rule
```

Canonical path for invoice signals:

```sql
profit_anchor_invoices invoice
join profit_revenue_events event
  on event.anchor_invoice_id = invoice.anchor_invoice_id
join profit_service_recognition_rules rule
  on rule.service_name = event.canonical_service_name
```

Canonical path for cash signals:

- Join `profit_collection_revenue_allocations` to `profit_cash_collections` using the live schema-confirmed allocation-to-cash key.
- Join `profit_revenue_events event` on `event.revenue_event_key = allocation.revenue_event_key`.
- Join `profit_service_recognition_rules rule` on `rule.service_name = event.canonical_service_name`.

Task 3 Step 0 must confirm the real allocation-to-cash join column before migration 026a is written. Gate notes contain two possible paths, `allocation.collection_key = collection.collection_key` and `allocation.cash_collection_id = collection.cash_collection_id`; the implementer must use the live schema result, not either assumption by memory. If neither path exists, halt and report before writing 026a.

Skip conditions:

- More than one distinct composite service-type key in the signal set.
- Any signal event has unresolved `canonical_service_name`.
- Any matching service rule has `recognition_pattern = 'manual_review'`.
- Any matching service rule has `service_period_rule = 'manual'`.

`profit_anchor_line_item_classifications.macro_service_type` may be included in evidence, but it does not satisfy `requires_service_type_match`.

### G6: Diagnostic Views For Ambiguous-State Surfacing

Create three `profit_pipeline_*` views in `026c_profit_pipeline_diagnostic_views.sql`.

1. `profit_pipeline_classification_transition_blockers`
   - Grain: one row per `(classification_id, signal_name, blocker_reason)`.
   - For hard-precondition `no_anchor_match`, emit one row per applicable transition rule, not one collapsed row per classification.
   - Expected live count after deploy: 6 rows, all `no_anchor_match`.
   - Expected breakdown:
     - Sutherland + Nazario each block two `LEGACY_ENGAGEMENT_PRE_ANCHOR` rules -> 4 rows.
     - Sullivan blocks two `INVOICE_OUTSTANDING_PAYMENT_PENDING` rules -> 2 rows.
     - 0 rows for `multi_service_ambiguity`, `unresolved_canonical_service`, and `manual_review_service_rule`.

2. `profit_pipeline_due_reclassifications`
   - Thin pipeline-facing wrapper over `profit_fulfillment_audit_candidates`.
   - Predicate: active classification with `re_evaluate_at <= current_date`.
   - Expected live count after deploy: 2 rows, Schmidli Enterprises LLC and West Coast Conference WMS Inc.

3. `profit_pipeline_stuck_recognition_triggers`
   - Pending revenue events older than 30 days that are not ready for recognition.
   - Hardcode the 30-day threshold in the view.
   - Inline comment required:

```sql
-- Stuck threshold: pending revenue events older than 30 days are surfaced for triage.
-- Threshold is operational policy; if changed, update this view rather than parameterizing.
```

   - Deploy checkpoint groups by `(recognition_status, recognition_rule)` and reports the live baseline count.

Reuse three existing diagnostic surfaces instead of duplicating them:

- `profit_tax_recognition_ambiguities`: expected 2.
- `profit_fulfillment_audit_qbo_category_gaps`: expected 5.
- `profit_unresolved_service_names`: expected 5.

The final C.a deploy summary must report counts from all six diagnostic surfaces.

## Scope

In scope:

- Migration `026_profit_pipeline_runs.sql`.
- Migration `026a_profit_apply_classification_transitions_v2.sql`.
- Migration `026b_profit_reconcile_fc_client_anchor_matches.sql`.
- Migration `026c_profit_pipeline_diagnostic_views.sql`.
- SQL-shape and fixture-style tests for pipeline run tables, expanded transitions, reconcile, and diagnostics.
- Documentation updates to `docs/data-contracts/fulfillment-classifications.md`.
- Tech-debt updates in `docs/tech-debt.md`.

Out of scope:

- Frontend files under `app/frontend/**`.
- API files under `profit_api/**`.
- n8n Workflow JSON changes.
- Workflow 26 chained pipeline.
- Manual refresh API endpoints.
- Pipeline status tile or `/profit/admin/pipeline` route.
- Cron schedule.
- Alias seeding from `docs/audits/2026-05-07-unresolved-service-names.csv`.
- Anchor service API sync replacing static seeds.
- V0.6.D SLA dashboard and Anchor backfill queue.
- Changes to the 14-verdict canon.
- Direct non-append updates to `profit_classifications`, except superseding source rows as part of the apply function's existing append-friendly pattern.

## Migration And Deploy Checkpoints

Stop after each deploy checkpoint and wait for orchestrator approval.

1. **026 pipeline run tables**
   - Apply `026_profit_pipeline_runs.sql`.
   - Verify both tables, checks, indexes, and unique partial running-run constraint.
   - Insert synthetic rows with `triggered_by='test'`, verify concurrency semantics, insert 13 steps, then delete synthetic rows.
   - Verify both run tables are empty after cleanup.

2. **026a expanded apply transitions**
   - Apply `026a_profit_apply_classification_transitions_v2.sql`.
   - Dry-run live:
     - expected 0 rows.
   - Verify function exists with same name/signature and return columns.
   - Verify existing B.2.a active-agreement rule still returns no rows after Schmidli was already applied.

3. **026b reconcile matches**
   - Apply `026b_profit_reconcile_fc_client_anchor_matches.sql`.
   - Checkpoint A: dry-run returns exactly YV HB and YV PSL.
   - Checkpoint B: live apply deletes exactly 2 persisted `auto_exact` rows.
   - Checkpoint C: second live apply returns 0 rows.
   - Verify manual override rows remain untouched.

4. **026c diagnostic views**
   - Apply `026c_profit_pipeline_diagnostic_views.sql`.
   - Verify all three new views exist.
   - Report all six diagnostic surface counts:
     - `profit_tax_recognition_ambiguities` -> expected 2.
     - `profit_fulfillment_audit_qbo_category_gaps` -> expected 5.
     - `profit_unresolved_service_names` -> expected 5.
     - `profit_pipeline_classification_transition_blockers` -> expected 6 rows, all `no_anchor_match`.
     - `profit_pipeline_due_reclassifications` -> expected 2 rows.
     - `profit_pipeline_stuck_recognition_triggers` -> report grouped baseline by `(recognition_status, recognition_rule)`.

5. **Final C.a verification**
   - Targeted pytest.
   - Full pytest.
   - `git diff --name-only` scope boundary check.
   - Final live one-liner with migration/function/view existence and diagnostic counts.
   - Stop before commit and push.

## Files

Create:

- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.C.a-pipeline-backend.md`
- `supabase/sql/026_profit_pipeline_runs.sql`
- `supabase/sql/026a_profit_apply_classification_transitions_v2.sql`
- `supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql`
- `supabase/sql/026c_profit_pipeline_diagnostic_views.sql`
- `tests/test_pipeline_backend_sql.py`

Modify:

- `docs/data-contracts/fulfillment-classifications.md`
- `docs/tech-debt.md`
- `tests/test_fulfillment_classification_sql.py` if the existing apply-transition assertions are easier to extend in place.
- `tests/test_fulfillment_audit_queries.py` if the existing diagnostic-view assertions are easier to extend in place.
- `tests/test_data_references_docs.py` only if new documentation anchors need static validation.

Do not modify:

- `app/frontend/**`
- `profit_api/**`
- `n8n/workflows/**`
- `scripts/**`
- `supabase/sql/027_profit_sla_views.sql` or any other V0.6.D migration
- `supabase/sql/030_*` or later
- `package.json`, `package-lock.json`
- `docs/audits/**`
- Existing V0.6.B migrations except by reading them for reference.

## Tasks

### Task 1: Pipeline Run Tables Red Tests

**Files:**

- Create: `tests/test_pipeline_backend_sql.py`
- Read: `supabase/sql/026_profit_pipeline_runs.sql` after it exists

- [ ] **Step 1: Add failing static tests for migration 026**

Add tests that expect:

```python
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_sql(path: str) -> str:
    return (ROOT / path).read_text()


def test_migration_026_defines_pipeline_run_tables():
    sql = read_sql("supabase/sql/026_profit_pipeline_runs.sql").lower()

    assert "create table if not exists profit_pipeline_runs" in sql
    assert "pipeline_run_id uuid primary key default gen_random_uuid()" in sql
    assert "run_source text not null" in sql
    assert "check (run_source in ('cron', 'manual'))" in sql
    assert "status text not null" in sql
    assert "check (status in ('running', 'success', 'failed', 'partial'))" in sql
    assert "triggered_by text" in sql
    assert "summary jsonb not null default '{}'::jsonb" in sql

    assert "create table if not exists profit_pipeline_run_steps" in sql
    assert "step_order integer not null" in sql
    assert "primary key (pipeline_run_id, step_name)" in sql
    assert "unique (pipeline_run_id, step_order)" in sql
    assert "details jsonb not null default '{}'::jsonb" in sql


def test_migration_026_locks_run_concurrency_and_indexes():
    sql = read_sql("supabase/sql/026_profit_pipeline_runs.sql").lower()

    assert "where status = 'running'" in sql
    assert "unique index" in sql
    assert "idx_profit_pipeline_runs_started_at_desc" in sql
    assert "idx_profit_pipeline_runs_status_started_at_desc" in sql
    assert "idx_profit_pipeline_run_steps_run_order" in sql


def test_migration_026_documents_triggered_by_and_jsonb_conventions():
    sql = read_sql("supabase/sql/026_profit_pipeline_runs.sql").lower()

    assert "manual runs: operator identifier" in sql
    assert "cron runs: cron" in sql
    assert "synthetic checkpoint rows: test" in sql
    assert "total_steps_completed" in sql
    assert "total_steps_failed" in sql
    assert "total_rows_affected" in sql
    assert "notable_findings" in sql
```

- [ ] **Step 2: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py -q
```

Expected: FAIL because `supabase/sql/026_profit_pipeline_runs.sql` does not exist.

- [ ] **Step 3: Stop and report red test**

Report the failing test names and confirm no migration has been written yet.

### Task 2: Pipeline Run Tables Migration And Deploy

**Files:**

- Create: `supabase/sql/026_profit_pipeline_runs.sql`
- Test: `tests/test_pipeline_backend_sql.py`

- [ ] **Step 1: Implement migration 026**

Create `supabase/sql/026_profit_pipeline_runs.sql` with:

- `create extension if not exists pgcrypto;`
- Both table definitions.
- Timestamp consistency `check` constraints.
- Partial unique running-run index.
- Three regular indexes.
- `comment on table` and `comment on column` statements documenting `triggered_by`, `summary`, and `details` conventions.

- [ ] **Step 2: Run focused tests green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py -q
```

Expected: PASS.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/026_profit_pipeline_runs.sql root@104.225.220.36:/tmp/026_profit_pipeline_runs.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/026_profit_pipeline_runs.sql'
```

- [ ] **Step 4: Run deploy checkpoint queries**

Run the checkpoint as explicit statements. Use a transaction where practical; still include the final delete-by-`triggered_by='test'` cleanup.

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('profit_pipeline_runs', 'profit_pipeline_run_steps')
order by table_name;

select indexname
from pg_indexes
where schemaname = 'public'
  and tablename in ('profit_pipeline_runs', 'profit_pipeline_run_steps')
order by indexname;

insert into profit_pipeline_runs (run_source, status, triggered_by, summary)
values ('manual', 'running', 'test', '{"checkpoint": "g1_concurrency_test"}'::jsonb)
returning pipeline_run_id;

-- Expected: unique violation on the second running insert.
insert into profit_pipeline_runs (run_source, status, triggered_by, summary)
values ('manual', 'running', 'test', '{"checkpoint": "g1_concurrency_test_second_running"}'::jsonb);

update profit_pipeline_runs
set status = 'success', finished_at = now()
where triggered_by = 'test'
  and status = 'running';

-- Expected: allowed because no running run remains.
insert into profit_pipeline_runs (run_source, status, triggered_by, summary)
values ('manual', 'running', 'test', '{"checkpoint": "g1_concurrency_test_after_success"}'::jsonb)
returning pipeline_run_id;

update profit_pipeline_runs
set status = 'success', finished_at = now()
where triggered_by = 'test'
  and status = 'running';

-- Expected: multiple non-running rows are allowed.
insert into profit_pipeline_runs (run_source, status, triggered_by, finished_at, summary)
values
  ('manual', 'success', 'test', now(), '{"checkpoint": "success_a"}'::jsonb),
  ('manual', 'success', 'test', now(), '{"checkpoint": "success_b"}'::jsonb);

-- Insert 13 synthetic steps under one synthetic run to verify PK and step_order constraints.
with selected_run as (
  select pipeline_run_id
  from profit_pipeline_runs
  where triggered_by = 'test'
  order by started_at
  limit 1
)
insert into profit_pipeline_run_steps (
  pipeline_run_id,
  step_name,
  step_order,
  status,
  finished_at,
  rows_affected,
  details
)
select
  selected_run.pipeline_run_id,
  'step_' || gs::text,
  gs,
  'success',
  now(),
  0,
  jsonb_build_object('checkpoint', 'g1_step_order_test', 'step_order', gs)
from selected_run
cross join generate_series(1, 13) as gs;

delete from profit_pipeline_runs
where triggered_by = 'test';

select count(*) as synthetic_runs_remaining
from profit_pipeline_runs
where triggered_by = 'test';

select count(*) as synthetic_steps_remaining
from profit_pipeline_run_steps step
join profit_pipeline_runs run
  on run.pipeline_run_id = step.pipeline_run_id
where run.triggered_by = 'test';
```

Expected:

- Both tables exist.
- Partial unique index exists.
- Second running insert fails with unique violation.
- Two success rows insert successfully.
- 13 step rows insert successfully.
- Cleanup leaves 0 synthetic runs and 0 synthetic steps.

- [ ] **Step 5: Stop for orchestrator approval**

Report table/index presence, partial-index result, success-row result, step insert result, and cleanup counts.

### Task 3: Expanded Apply Function Red Tests

**Files:**

- Modify: `tests/test_pipeline_backend_sql.py`
- Modify: `tests/test_fulfillment_classification_sql.py` only if existing apply-function assertions should stay together
- Read: `supabase/sql/026a_profit_apply_classification_transitions_v2.sql` after it exists

- [ ] **Step 0: Verify cash-allocation schema before writing 026a**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "\d+ profit_collection_revenue_allocations" -c "\d+ profit_cash_collections"'
```

Confirm and write into the Task 4 implementation notes before creating `026a`:

- the `profit_collection_revenue_allocations` join column to `profit_cash_collections`;
- `profit_cash_collections.collected_at` exists;
- the `profit_cash_collections` primary key.

Expected: one of the gate-note candidates is valid: either `allocation.collection_key = collection.collection_key` or `allocation.cash_collection_id = collection.cash_collection_id`. If the live schema differs from both, halt and report before writing migration 026a.

- [ ] **Step 1: Add failing SQL-shape tests for migration 026a**

Tests must assert:

```python
def test_migration_026a_expands_apply_transition_rules():
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "create or replace function profit_apply_classification_transitions" in sql
    assert "p_dry_run boolean default true" in sql
    assert "active_agreement_appears" in sql
    assert "first_matching_anchor_invoice_group_billed" in sql
    assert "first_matching_anchor_invoice_mid_cycle" in sql
    assert "cash_collected_group_parent" in sql
    assert "cash_collected_standalone_mid_cycle" in sql
    assert "settled_via_quickbooks_payment" not in sql
    assert "anchor_backfill_invoice" not in sql


def test_migration_026a_documents_match_dependency_and_cash_timing():
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "auto-transition correctness requires profit_fc_client_anchor_matches.anchor_relationship_id" in sql
    assert "will be skipped silently" in sql
    assert "profit_cash_collections" in sql
    assert "collected_at" in sql
    assert "allocation.loaded_at" not in sql


def test_migration_026a_locks_service_type_guards():
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "macro_service_type" in sql
    assert "recognition_pattern" in sql
    assert "service_period_rule" in sql
    assert "manual_review" in sql
    assert "service_period_rule = 'manual'" in sql
    assert "canonical_service_name is null" in sql
```

- [ ] **Step 2: Add failing fixture-behavior tests as SQL comments or static fixtures**

Because the repo does not have an isolated Supabase test database harness, lock behavioral fixture intent in a static test file that checks the migration contains named fixture comments and guard branches:

```python
def test_migration_026a_names_required_behavior_fixtures():
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "fixture: group_billed_priority_over_standalone" in sql
    assert "fixture: multiple_group_sibling_signals_insert_one_row" in sql
    assert "fixture: multi_service_type_ambiguity_skips" in sql
    assert "fixture: unresolved_canonical_service_skips" in sql
    assert "fixture: manual_review_rule_skips" in sql
    assert "fixture: manual_service_period_rule_skips" in sql
```

- [ ] **Step 3: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py tests/test_fulfillment_classification_sql.py -q
```

Expected: FAIL because migration 026a does not exist.

- [ ] **Step 4: Stop and report red test**

Report failing tests and confirm no migration has been written yet.

### Task 4: Expanded Apply Function Migration And Deploy

**Files:**

- Create: `supabase/sql/026a_profit_apply_classification_transitions_v2.sql`
- Test: `tests/test_pipeline_backend_sql.py`
- Test: `tests/test_fulfillment_classification_sql.py`

- [ ] **Step 1: Implement migration 026a**

Create migration with `CREATE OR REPLACE FUNCTION profit_apply_classification_transitions(...)` and the same return shape shipped in B.2.a.

Implementation requirements:

- Preserve B.2.a `active_agreement_appears` behavior for `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT`.
- Add the four C.a rules.
- Read enabled rules from `profit_classification_transition_rules`.
- Skip disabled rules.
- Skip classifications with no persisted anchor match for rules that require Anchor relationship context.
- Evaluate group-billed branch before standalone.
- Use `EXISTS` semantics for group siblings and fire once per classification.
- Enforce service-type guards:
  - exactly one distinct composite key,
  - no unresolved canonical service,
  - no `manual_review`,
  - no `service_period_rule = 'manual'`.
- Use `collection.collected_at > classified_at` for cash rules.
- Keep append-friendly behavior:
  - dry-run: zero writes, `would_create_classification_id is null`;
  - live: insert replacement classification, supersede source row, return created id.

- [ ] **Step 2: Run focused tests green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py tests/test_fulfillment_classification_sql.py -q
```

Expected: PASS.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/026a_profit_apply_classification_transitions_v2.sql root@104.225.220.36:/tmp/026a_profit_apply_classification_transitions_v2.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/026a_profit_apply_classification_transitions_v2.sql'
```

- [ ] **Step 4: Run deploy checkpoint queries**

```sql
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as args
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'profit_apply_classification_transitions';

select *
from profit_apply_classification_transitions(now(), true);

select verdict_code, count(*) as active_rows
from profit_classifications
where superseded_at is null
  and verdict_code in (
    'LEGACY_ENGAGEMENT_PRE_ANCHOR',
    'INVOICE_OUTSTANDING_PAYMENT_PENDING',
    'PENDING_ENGAGEMENT_DRAFT',
    'PENDING_ENGAGEMENT_SENT',
    'MIXED'
  )
group by verdict_code
order by verdict_code;
```

Expected:

- Function exists with same signature.
- Dry-run returns 0 rows on live data.
- Distribution confirms no live mutation occurred.

- [ ] **Step 5: Stop for orchestrator approval**

Report function signature, dry-run row count, and active classification distribution.

### Task 5: Match Reconcile Red Tests

**Files:**

- Modify: `tests/test_pipeline_backend_sql.py`
- Read: `supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql` after it exists

- [ ] **Step 1: Add failing tests for migration 026b**

Add tests:

```python
def test_migration_026b_defines_reconcile_function():
    sql = read_sql("supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql").lower()

    assert "create or replace function profit_reconcile_fc_client_anchor_matches" in sql
    assert "p_dry_run boolean default true" in sql
    assert "returns table" in sql
    assert "persisted_match_method" in sql
    assert "candidate_match_status" in sql
    assert "candidate_anchor_relationship_id" in sql
    assert "action text" in sql


def test_migration_026b_hard_deletes_only_auto_exact_and_protects_manual_override():
    sql = read_sql("supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql").lower()

    assert "match_method = 'auto_exact'" in sql
    assert "delete from profit_fc_client_anchor_matches" in sql
    assert "manual_override" in sql
    assert "manual override rows are protected" in sql


def test_migration_026b_locks_demote_cases_and_idempotency():
    sql = read_sql("supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql").lower()

    assert "candidate.match_status" in sql
    assert "<> 'auto_exact'" in sql
    assert "is distinct from" in sql
    assert "fixture: relationship_id_changed_branch" in sql
    assert "fixture: second_live_call_returns_zero" in sql
```

- [ ] **Step 2: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py -q
```

Expected: FAIL because migration 026b does not exist.

- [ ] **Step 3: Stop and report red test**

Report failing tests and confirm no migration has been written yet.

### Task 6: Match Reconcile Migration And Deploy

**Files:**

- Create: `supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql`
- Test: `tests/test_pipeline_backend_sql.py`

- [ ] **Step 1: Implement migration 026b**

Create `profit_reconcile_fc_client_anchor_matches(p_dry_run boolean default true)`.

Implementation requirements:

- Build a demote set from persisted `auto_exact` rows.
- Left join `profit_fc_client_anchor_match_candidates` by `fc_client_id`.
- Select rows where candidate is no longer `auto_exact` or candidate relationship differs.
- Return the full dry-run/live row shape.
- On live mode, hard-delete matching persisted rows.
- Include comments documenting:
  - manual override protection,
  - relationship-id changed branch,
  - idempotency,
  - C.b ordering after Workflow 25 upsert.

- [ ] **Step 2: Run focused tests green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py -q
```

Expected: PASS.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql root@104.225.220.36:/tmp/026b_profit_reconcile_fc_client_anchor_matches.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/026b_profit_reconcile_fc_client_anchor_matches.sql'
```

- [ ] **Step 4: Checkpoint A, dry-run**

```sql
select *
from profit_reconcile_fc_client_anchor_matches(true)
order by fc_client_name;
```

Expected:

- 2 rows.
- YV Enterprises HB LLC.
- YV Enterprises PSL LLC.
- `action = 'would_delete'`.

- [ ] **Step 5: Checkpoint B, live apply**

```sql
select *
from profit_reconcile_fc_client_anchor_matches(false)
order by fc_client_name;
```

Expected:

- 2 rows.
- Same YV rows.
- `action = 'deleted'`.

- [ ] **Step 6: Checkpoint C, idempotency and protected rows**

```sql
select *
from profit_reconcile_fc_client_anchor_matches(false)
order by fc_client_name;

select fc_client_id, match_method, anchor_relationship_id
from profit_fc_client_anchor_matches
where match_method = 'manual_override'
order by fc_client_id;

select count(*) as yv_persisted_matches
from profit_fc_client_anchor_matches match
join profit_fc_clients client
  on client.fc_client_id = match.fc_client_id
where client.name ilike any (array['%yv enterprises hb%', '%yv enterprises psl%']);
```

Expected:

- Second live call returns 0 rows.
- Manual override rows remain present.
- YV persisted matches count is 0.

- [ ] **Step 7: Stop for orchestrator approval**

Report dry-run rows, live rows, second live rows, manual-override verification, and YV persisted count.

### Task 7: Diagnostic Views Red Tests

**Files:**

- Modify: `tests/test_pipeline_backend_sql.py`
- Modify: `tests/test_fulfillment_audit_queries.py` if existing diagnostic tests should be grouped there
- Read: `supabase/sql/026c_profit_pipeline_diagnostic_views.sql` after it exists

- [ ] **Step 1: Add failing tests for migration 026c**

Add tests:

```python
def test_migration_026c_defines_pipeline_diagnostic_views():
    sql = read_sql("supabase/sql/026c_profit_pipeline_diagnostic_views.sql").lower()

    assert "create or replace view profit_pipeline_classification_transition_blockers" in sql
    assert "create or replace view profit_pipeline_due_reclassifications" in sql
    assert "create or replace view profit_pipeline_stuck_recognition_triggers" in sql


def test_migration_026c_locks_blocker_grain_and_reasons():
    sql = read_sql("supabase/sql/026c_profit_pipeline_diagnostic_views.sql").lower()

    assert "classification_id" in sql
    assert "signal_name" in sql
    assert "blocker_reason" in sql
    assert "no_anchor_match" in sql
    assert "multi_service_ambiguity" in sql
    assert "unresolved_canonical_service" in sql
    assert "manual_review_service_rule" in sql
    assert "one row per applicable transition rule" in sql


def test_migration_026c_hardcodes_stuck_threshold():
    sql = read_sql("supabase/sql/026c_profit_pipeline_diagnostic_views.sql").lower()

    assert "stuck threshold: pending revenue events older than 30 days are surfaced for triage" in sql
    assert "now() - interval '30 days'" in sql
    assert "threshold is operational policy; if changed, update this view rather than parameterizing" in sql
    assert "p_stuck_days" not in sql
```

- [ ] **Step 2: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py tests/test_fulfillment_audit_queries.py -q
```

Expected: FAIL because migration 026c does not exist.

- [ ] **Step 3: Stop and report red test**

Report failing tests and confirm no migration has been written yet.

### Task 8: Diagnostic Views Migration And Deploy

**Files:**

- Create: `supabase/sql/026c_profit_pipeline_diagnostic_views.sql`
- Test: `tests/test_pipeline_backend_sql.py`
- Test: `tests/test_fulfillment_audit_queries.py`

- [ ] **Step 1: Implement migration 026c**

Create:

- `profit_pipeline_classification_transition_blockers`
- `profit_pipeline_due_reclassifications`
- `profit_pipeline_stuck_recognition_triggers`

Implementation constraints:

- `profit_pipeline_classification_transition_blockers` emits one row per `(classification_id, signal_name, blocker_reason)`.
- `no_anchor_match` expands per applicable transition rule.
- `profit_pipeline_due_reclassifications` is a pipeline-facing wrapper over `profit_fulfillment_audit_candidates`.
- `profit_pipeline_stuck_recognition_triggers` hardcodes the 30-day threshold with the required comment.
- Do not create materialized views.
- Do not duplicate existing `profit_tax_recognition_ambiguities`, `profit_fulfillment_audit_qbo_category_gaps`, or `profit_unresolved_service_names`.

- [ ] **Step 2: Run focused tests green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_pipeline_backend_sql.py tests/test_fulfillment_audit_queries.py -q
```

Expected: PASS.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/026c_profit_pipeline_diagnostic_views.sql root@104.225.220.36:/tmp/026c_profit_pipeline_diagnostic_views.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/026c_profit_pipeline_diagnostic_views.sql'
```

- [ ] **Step 4: Run diagnostic deploy checkpoint**

```sql
select table_name
from information_schema.views
where table_schema = 'public'
  and table_name in (
    'profit_pipeline_classification_transition_blockers',
    'profit_pipeline_due_reclassifications',
    'profit_pipeline_stuck_recognition_triggers'
  )
order by table_name;

select count(*) as tax_ambiguities
from profit_tax_recognition_ambiguities;

select count(*) as qbo_category_gaps
from profit_fulfillment_audit_qbo_category_gaps;

select count(*) as unresolved_service_names
from profit_unresolved_service_names;

select blocker_reason, count(*) as rows
from profit_pipeline_classification_transition_blockers
group by blocker_reason
order by blocker_reason;

select signal_name, blocker_reason, count(*) as rows
from profit_pipeline_classification_transition_blockers
group by signal_name, blocker_reason
order by signal_name, blocker_reason;

select fc_client_name, current_verdict_code, re_evaluate_at
from profit_pipeline_due_reclassifications
order by re_evaluate_at, fc_client_name;

select recognition_status, recognition_rule, count(*) as rows
from profit_pipeline_stuck_recognition_triggers
group by recognition_status, recognition_rule
order by recognition_status, recognition_rule;
```

Expected:

- 3 new views exist.
- `profit_tax_recognition_ambiguities`: 2.
- `profit_fulfillment_audit_qbo_category_gaps`: 5.
- `profit_unresolved_service_names`: 5.
- `profit_pipeline_classification_transition_blockers`: 6, all `no_anchor_match`.
- `profit_pipeline_due_reclassifications`: 2 rows, Schmidli and West Coast Conference WMS.
- `profit_pipeline_stuck_recognition_triggers`: report live grouped baseline.

- [ ] **Step 5: Stop for orchestrator approval**

Report all six diagnostic counts and the stuck-trigger grouped baseline.

### Task 9: Documentation Updates

**Files:**

- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md`
- Modify: `tests/test_data_references_docs.py` only if needed for doc anchor checks

- [ ] **Step 1: Add failing doc/reference tests**

Add or extend static docs tests to assert the following phrases exist:

```python
def test_pipeline_backend_docs_reference_c_a_contracts():
    contract = (ROOT / "docs/data-contracts/fulfillment-classifications.md").read_text().lower()
    debt = (ROOT / "docs/tech-debt.md").read_text().lower()

    assert "pipeline run log schema" in contract
    assert "match reconciliation" in contract
    assert "apply transitions" in contract
    assert "auto-transition correctness requires profit_fc_client_anchor_matches.anchor_relationship_id" in contract
    assert "workflow 05 (anchor agreement sync) hardcodes limit=50" in debt
    assert "13 pending_sent seeded classifications remain pending review" in debt
```

- [ ] **Step 2: Run red docs tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: FAIL until docs are updated.

- [ ] **Step 3: Update data contract**

Extend `docs/data-contracts/fulfillment-classifications.md` with:

- **Pipeline Run Log Schema**
  - table purposes,
  - `triggered_by` convention,
  - `summary` and `details` JSONB conventions,
  - single-running-run constraint.
- **Apply Transitions V0.6.C.a**
  - list executable rules,
  - list deferred rules,
  - dry-run/live contract,
  - matches-table dependency limitation,
  - composite service-type key,
  - service guard skip conditions.
- **Match Reconciliation**
  - function purpose,
  - hard-delete derived `auto_exact` rows,
  - manual override protection,
  - C.b ordering after Workflow 25 upsert,
  - idempotency.
- **Pipeline Diagnostic Views**
  - the three new `profit_pipeline_*` views,
  - the three reused diagnostic surfaces,
  - expected consumers in V0.6.C.b.

- [ ] **Step 4: Update tech debt**

Revise or add:

- Replace the old "12 active reissued PENDING_SENT rows" entry with:

```text
13 PENDING_SENT seeded classifications remain pending review. Anchor /agreements API exposes only active/terminated states; DRAFT and SENT agreements are not visible (existing Anchor state visibility limitation). The original 2026-05-07 inspection note about ~12 active reissued agreements is not reproducible against current /agreements?limit=100 (verified 2026-05-08); those agreements either cancelled, never advanced past pre-active, or were observed via a different path. Rows transition automatically when an active agreement appears for the client. Until then, surface as standard pending review in the audit dashboard.
```

- Add Workflow 05 limit/pagination debt:

```text
Workflow 05 (Anchor agreement sync) hardcodes limit=50 with no pagination loop. Anchor /agreements?limit=100 currently returns 52 agreements; the 2 outside the first 50 (YV Enterprises HB LLC and YV Enterprises PSL LLC active reissues) get marked stale because they are not seen in Workflow 05's run. /agreements?limit=200 returns INVALID_PAGE_SIZE; offset=50 does not page and returns the first 50 again. V0.6.C.b will raise the limit to 100 as a short-term fix. Real pagination is blocked on Anchor API support; revisit when offset/cursor params work or once active agreement count approaches 100.
```

- Add or extend auto-transition no-anchor-match debt:

```text
Auto-transition apply skips classifications whose FC client has no persisted anchor_relationship_id in profit_fc_client_anchor_matches. Operationally, these surface as audit candidates with stale or null Anchor signals; manual classification or upstream Workflow 25/05 sync coverage is required before transitions can fire.
```

- Add C.a reconcile handoff debt:

```text
V0.6.C.a deploy executes profit_reconcile_fc_client_anchor_matches(false) once to clear YV Enterprises HB LLC and YV Enterprises PSL LLC stale auto_exact rows. V0.6.C.b wires the function into Workflow 25/26 for ongoing reconciliation. Pre-V0.6.C.b, the matches table can drift if Workflow 25 reruns without reconcile; surface as audit candidate ambiguity for manual review during the gap.
```

- [ ] **Step 5: Run docs tests green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: PASS.

- [ ] **Step 6: Stop for orchestrator approval**

Report doc sections changed and tech-debt entries revised/added.

### Task 10: Full Verification And Scope Boundary

**Files:**

- All C.a files

- [ ] **Step 1: Run targeted C.a tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest \
  tests/test_pipeline_backend_sql.py \
  tests/test_fulfillment_classification_sql.py \
  tests/test_fulfillment_audit_queries.py \
  tests/test_data_references_docs.py \
  -q
```

Expected: PASS.

- [ ] **Step 2: Run full pytest**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: PASS.

- [ ] **Step 3: Run final live checkpoint one-liner**

Run live queries confirming:

- Pipeline tables exist and contain 0 rows.
- `profit_apply_classification_transitions(now(), true)` returns 0 rows.
- `profit_reconcile_fc_client_anchor_matches(true)` returns 0 rows after Task 6 cleanup.
- New diagnostic views exist.
- Six diagnostic surface counts match/report baselines.
- Active classification distribution still respects append-friendly state.

Concrete SQL:

```sql
select 'pipeline_runs' as check_name, count(*)::text as value
from profit_pipeline_runs
union all
select 'pipeline_run_steps', count(*)::text
from profit_pipeline_run_steps
union all
select 'apply_dry_run_rows', count(*)::text
from profit_apply_classification_transitions(now(), true)
union all
select 'reconcile_dry_run_rows', count(*)::text
from profit_reconcile_fc_client_anchor_matches(true)
union all
select 'tax_ambiguities', count(*)::text
from profit_tax_recognition_ambiguities
union all
select 'qbo_category_gaps', count(*)::text
from profit_fulfillment_audit_qbo_category_gaps
union all
select 'unresolved_service_names', count(*)::text
from profit_unresolved_service_names
union all
select 'transition_blockers', count(*)::text
from profit_pipeline_classification_transition_blockers
union all
select 'due_reclassifications', count(*)::text
from profit_pipeline_due_reclassifications
union all
select 'stuck_recognition_triggers', count(*)::text
from profit_pipeline_stuck_recognition_triggers;

select verdict_code, count(*) as active_rows
from profit_classifications
where superseded_at is null
group by verdict_code
order by verdict_code;
```

- [ ] **Step 4: Check scope boundary**

Run:

```bash
git diff --name-only
```

Expected files only:

```text
docs/data-contracts/fulfillment-classifications.md
docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.C.a-pipeline-backend.md
docs/tech-debt.md
supabase/sql/026_profit_pipeline_runs.sql
supabase/sql/026a_profit_apply_classification_transitions_v2.sql
supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql
supabase/sql/026c_profit_pipeline_diagnostic_views.sql
tests/test_pipeline_backend_sql.py
tests/test_fulfillment_classification_sql.py
tests/test_fulfillment_audit_queries.py
tests/test_data_references_docs.py
```

Acceptable if one of the existing test files is not modified because coverage is centralized in `tests/test_pipeline_backend_sql.py`.

Must not show:

```text
app/frontend/**
profit_api/**
n8n/workflows/**
scripts/**
supabase/sql/030_*
package.json
package-lock.json
docs/audits/**
```

- [ ] **Step 5: Stop for orchestrator approval before commit**

Report targeted pytest, full pytest, live checkpoint summary, diagnostic baselines, active verdict distribution, and `git diff --name-only`.

### Task 11: Commit And Push

**Files:**

- Stage only approved C.a files.

- [ ] **Step 1: Final pytest sweep**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: PASS.

- [ ] **Step 2: Stage explicit file list**

Run:

```bash
git add \
  docs/data-contracts/fulfillment-classifications.md \
  docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.C.a-pipeline-backend.md \
  docs/tech-debt.md \
  supabase/sql/026_profit_pipeline_runs.sql \
  supabase/sql/026a_profit_apply_classification_transitions_v2.sql \
  supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql \
  supabase/sql/026c_profit_pipeline_diagnostic_views.sql \
  tests/test_pipeline_backend_sql.py \
  tests/test_fulfillment_classification_sql.py \
  tests/test_fulfillment_audit_queries.py \
  tests/test_data_references_docs.py
```

If a listed existing test file was not modified, omit it from `git add` rather than touching it.

- [ ] **Step 3: Commit**

Use this structure:

```bash
git commit -m "Add V0.6.C.a pipeline backend foundation

Add pipeline run logging tables with single-running-run enforcement,
ordered run steps, timestamp consistency checks, and documented JSONB
summary/details conventions for V0.6.C.b orchestration.

Expand profit_apply_classification_transitions while preserving the
existing dry-run/live contract and function signature. C.a activates
the safely-doable LEGACY_ENGAGEMENT_PRE_ANCHOR invoice transitions and
INVOICE_OUTSTANDING_PAYMENT_PENDING cash-collected transitions, with
group-billed priority, composite service-type guards, manual-review
skip rules, and append-friendly supersede semantics. SETTLED backfill
rules remain deferred to V0.6.D; inactive-client re-emergence remains
handled by scan v2.

Add profit_reconcile_fc_client_anchor_matches for dry-run/live cleanup
of stale auto_exact FC-to-Anchor matches while protecting manual
overrides. The C.a deploy clears YV Enterprises HB LLC and YV
Enterprises PSL LLC stale persisted matches and leaves ongoing Workflow
25 wiring to V0.6.C.b.

Add pipeline diagnostic views for transition blockers, due
reclassifications, and stuck recognition triggers, reusing existing tax
ambiguity, QBO category gap, and unresolved-service-name diagnostics.
Document Workflow 05 limit/pagination debt, the corrected PENDING_SENT
pending-review reality, match reconciliation ordering, and transition
matches-table limitations.

No frontend, profit_api, workflow JSON, cron, or V0.6.D scope included.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Push**

Run:

```bash
git push
```

- [ ] **Step 5: Final report**

Report:

- commit hash,
- final pytest result,
- live checkpoint one-liner,
- diagnostic baseline counts,
- confirmation that V0.6.C.b Workflow/API/dashboard-hook work is unblocked.

## Self-Review Checklist

- [ ] No frontend files modified.
- [ ] No `profit_api/**` files modified.
- [ ] No n8n Workflow JSON modified.
- [ ] No Workflow 05 limit fix implemented in C.a.
- [ ] No Workflow 26 or cron scope implemented.
- [ ] No alias seeding performed.
- [ ] No verdict lookup rows added, removed, or renamed.
- [ ] `profit_classifications` remains append-friendly; source rows are superseded only by apply-function live mode.
- [ ] `profit_apply_classification_transitions` keeps same name/signature and dry-run/live modes.
- [ ] Expanded apply function documents and enforces matches-table dependency.
- [ ] Group-billed transition priority over standalone is locked in tests.
- [ ] Multi-service, unresolved canonical service, manual-review pattern, and manual service-period skip paths are locked in tests.
- [ ] Cash transitions use `profit_cash_collections.collected_at`, never allocation load time.
- [ ] `profit_reconcile_fc_client_anchor_matches` hard-deletes only stale `auto_exact` rows and protects manual overrides.
- [ ] Reconcile dry-run/live/idempotency checkpoint completed.
- [ ] Pipeline tables are empty after synthetic deploy tests.
- [ ] Diagnostic final summary reports all six surfaces:
  - `profit_tax_recognition_ambiguities`
  - `profit_fulfillment_audit_qbo_category_gaps`
  - `profit_unresolved_service_names`
  - `profit_pipeline_classification_transition_blockers`
  - `profit_pipeline_due_reclassifications`
  - `profit_pipeline_stuck_recognition_triggers`
- [ ] `docs/data-contracts/fulfillment-classifications.md` documents run logs, apply v2, match reconciliation, and diagnostics.
- [ ] `docs/tech-debt.md` revises the PENDING_SENT entry and adds Workflow 05 pagination/limit debt.
- [ ] Final `git diff --name-only` matches C.a scope.

Plan ready for orchestrator review.
