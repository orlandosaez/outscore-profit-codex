# Profit Dashboard V0.7.B SLA Breaches As Verdicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert SLA breach and at-risk service items from the read-only V0.6.D SLA queue into persistent `profit_classifications` verdict rows that participate in the universal Weekly Review queue.

**Architecture:** V0.7.B reuses the proven V0.7.A pattern: seed one verdict, create one candidate view, extend `profit_apply_classification_transitions`, register the verdict in `profit_weekly_review_visible_verdicts`, and UNION the candidate shape into `profit_weekly_review_items`. SQL remains canonical for SLA state and clearance signals; FastAPI keeps Weekly Review filtering/actions; React renders both `MANUAL_INVOICE_PENDING` and SLA rows with the same Mark reviewed and Snooze controls.

**Tech Stack:** Supabase Postgres migrations/views/functions, existing `profit_classifications` verdict history, `profit_weekly_review_item_state`, FastAPI service layer, Supabase REST store, React/Vite admin frontend, Python static/service tests, `npm run build`, operator-run SSH + `psql` deploy gate.

---

## V0.7.B Context

V0.7.A shipped on 2026-05-11 at commit `56ae1ab` with:

- `MANUAL_INVOICE_PENDING` verdict seed.
- `profit_manual_invoice_pending_candidates`.
- `profit_weekly_review_visible_verdicts`.
- `profit_weekly_review_item_state`.
- `profit_weekly_review_items`.
- `/admin/weekly-review` frontend route and API actions for Mark reviewed and Snooze 7 days.

V0.6.D shipped the SLA infrastructure:

- `supabase/sql/028_profit_sla_core_views.sql`.
- `supabase/sql/028a_profit_sla_backfill_and_performance_views.sql`.
- `profit_api/sla.py`.
- `/admin/sla` and `/admin/sla/backfill`.

V0.7.B is the second proof of the universal queue pattern. The current `/admin/sla` "Breach and at-risk queue" is read-only. After this slice, actionable breached/at-risk SLA rows live in Weekly Review as persisted classifications. `/admin/sla` remains the analytics surface for client status, staff workload, 90-day performance, and Anchor backfill.

## V0.7 Milestone Goals

- Validate that Weekly Review can host multiple verdict families without a bespoke route per workflow gap.
- Turn the noisiest SLA leak-prevention queue into an operator action queue with durable reviewed/snoozed state.
- Preserve SLA analytics on `/admin/sla`.
- Establish a repeatable extension contract for V0.7.C Anchor backfill verdicts and V0.7.D recognition/pipeline failure verdicts.
- Avoid broad taxonomy or multi-practice changes before V0.7.E.

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-11-profit-dashboard-v0.7.A-manual-invoice-verdict-and-weekly-review.md`: locked V0.7.A implementation pattern.
- `supabase/sql/029_profit_manual_invoice_pending_verdict.sql`: verdict seed, candidate view, transition-function precedent.
- `supabase/sql/029a_profit_weekly_review_items.sql`: Weekly Review state, visible verdict registry, queue view precedent.
- `supabase/sql/028_profit_sla_core_views.sql`: SLA state, breach queue, staff fallback, workflow-status semantics.
- `supabase/sql/028a_profit_sla_backfill_and_performance_views.sql`: performance and Anchor backfill views that remain on `/admin/sla`.
- `profit_api/sla.py`: SLA read-only service conventions.
- `profit_api/weekly_review.py`: Weekly Review API filtering/actions.
- `app/frontend/src/routes/SlaDashboard.jsx`: current SLA panels, including the queue panel to deprecate.
- `app/frontend/src/routes/WeeklyReview.jsx`: universal queue shell to extend.
- `docs/data-contracts/sla-dashboard.md`: V0.6.D state semantics.
- `docs/data-contracts/weekly-review.md`: queue extension contract.
- `docs/data-contracts/fulfillment-classifications.md`: verdict taxonomy and transition conventions.
- `docs/tech-debt.md`: carry-forward V0.7.A/V0.6.D items.

## Gate Decisions Locked Into This Plan

### G1: SLA State Coverage

Lock: include `breached` + `at_risk` only.

Impact: V0.7.B preserves the current panel's operational coverage while explicitly excluding `waiting_on_client` from verdict generation until V0.7.D.

### G2: Verdict Granularity

Lock: one umbrella verdict code, `SLA_BREACHED`.

Contract: both `breached` and `at_risk` rows use `SLA_BREACHED`; row state lives in `breach_state` metadata/display columns alongside `service_name`, `macro_service_type`, `target_date`, and staff context.

### G3: Verdict Clearance Signal

Lock: clear on FC task complete first; clear on FC project archived as fallback.

Primary predicate: clear active `SLA_BREACHED` when the underlying matching FC task reaches `completed_at is not null` or `is_completed = true`.

Secondary predicate: clear active `SLA_BREACHED` when the underlying matching FC project has `archived_at is not null` or equivalent archived signal from the synced FC project row.

Pattern: mirror the V0.7.A two-rule clearance pattern: one primary completion rule plus one fallback archival/termination-style rule. The candidate view still emits only currently `breached` or `at_risk` rows.

### G4: Queue Display For Co-Occurrence

Lock: show two distinct Weekly Review rows.

Contract: if the same agreement has both active `MANUAL_INVOICE_PENDING` and `SLA_BREACHED`, `profit_weekly_review_items` returns two rows, each keyed by its own `classification_id` and verdict.

### G5: V0.6.D SLA Dashboard Route Fate

Lock: keep `/admin/sla` for analytics and remove the read-only "Breach and at-risk queue" panel from `SlaDashboard.jsx`.

Contract: `/admin/sla` retains workload, 90-day performance, Anchor backfill, and analytics surfaces. Weekly Review becomes the only action queue for breached/at-risk SLA verdicts.

### G6: `waiting_on_client` Join Bug

Lock: Task 1 investigates; Task 2 fixes only if it is a cheap single-view repair with clear live evidence.

Trigger: if Task 1 confirms workflow-status tags exist for projects and a single join/path mismatch prevents `profit_sla_client_status.sla_state = 'waiting_on_client'`, include the repair in Task 2. If the issue requires new sync data, ambiguous workflow mapping, or broader project/task modeling, defer to V0.7.D with a tech-debt note.

Impact: V0.7.B does not generate `waiting_on_client` verdicts either way. A cheap repair improves `/admin/sla` analytics without widening Weekly Review scope.

### G7: Action Affordances On SLA Verdict Rows

Lock: Mark reviewed + Snooze 7 days only.

Impact: V0.7.B stays aligned with V0.7.A state persistence. Reassign staff and SLA target override controls remain out of scope and belong in V0.7.E or later.

## Open Questions Resolved For This Plan

### OQ1: Blank SLA Targets

Lock: exclude services where `default_sla_day is null` or the resolved target is null from `SLA_BREACHED` candidate generation.

Contract: Task 1 verifies Payroll Service and Fractional CFO produce 0 candidate rows. `docs/tech-debt.md` records the missing-default follow-up.

### OQ2: 1120 C/S Deadline Conflation

Lock: Task 1 profiles the 1120 C-corp/S-corp deadline conflation against live breached/at-risk candidates.

Contract: fix in V0.7.B only if the conflation produces false-positive `SLA_BREACHED` verdict candidates in current live data. Otherwise defer with a known-noise note in `docs/tech-debt.md`.

### OQ3: Action URL For SLA Rows

Lock: candidate view exposes one `action_url` column using a SQL fallback chain.

Contract: `action_url = fc_task_url` when available, else `fc_project_url`, else Anchor relationship URL.

### OQ4: Staff Context Display

Lock: expose `assigned_staff_name` and `staff_source` as separate candidate-view columns.

Contract: frontend renders both values inline for SLA rows, with the source as provenance context.

### OQ5: SLA Age Semantics

Lock: keep V0.7.A `age_days` as classification age and add SLA-specific age/date fields.

Contract:

- `age_days`: days since `profit_classifications.classified_at`, used by existing generic Weekly Review rows.
- `breach_age_days`: `greatest(current_date - target_date::date, 0)` for SLA rows.
- `work_age_days`: existing SLA service age from trigger date, exposed for context when available.
- `target_date`: SLA target date used to compute `breach_age_days`.
- Manual-invoice rows return null for SLA-specific fields.
- SLA rows return null for manual-invoice-specific fields.

UNION compatibility: `profit_weekly_review_items` keeps one row shape across manual-invoice and SLA rows using type-aware nullable columns.

## Migration Numbering

Lock: V0.7.B uses exactly these migration numbers:

- `supabase/sql/030_profit_sla_breached_verdict.sql`: seed `SLA_BREACHED`, create `profit_sla_breached_candidates`, seed transition rules, optionally repair cheap `waiting_on_client` join issue if Task 1 proves the fix, and replace `profit_apply_classification_transitions` with SLA detection/clearance branches while preserving all existing branches.
- `supabase/sql/030a_profit_weekly_review_sla_union.sql`: register `SLA_BREACHED` in `profit_weekly_review_visible_verdicts` and replace `profit_weekly_review_items` with `manual rows UNION ALL sla rows`.

## Scope

In scope:

- New verdict code `SLA_BREACHED`.
- Candidate view for currently `breached` and `at_risk` SLA service rows.
- Active-classification dedupe keyed by stable service/work item identity.
- Transition-function detection branch for new SLA candidates.
- Transition-function clearance branches for completed task and archived project.
- Weekly Review visible-verdict registry extension.
- Weekly Review queue UNION and frontend rendering for SLA-specific fields.
- Removal of the read-only breach/at-risk queue panel from `/admin/sla`.
- Data contracts and tech-debt updates.
- Task 1 live data profile gate, then final deploy gate.

Out of scope:

- `waiting_on_client` verdict generation.
- Pipeline failure verdicts.
- Anchor backfill verdicts.
- Manual recognition surface migration.
- Multi-practice routing.
- Reassign staff.
- Reset SLA target override UI.
- `/admin/sla` analytics enhancements beyond removing the duplicated action queue.
- Applying migrations, deploying, or committing during plan-draft review.

## File Structure

Create:

- `supabase/sql/030_profit_sla_breached_verdict.sql`: verdict seed, candidate view, transition rules, transition-function replacement, optional cheap SLA join repair.
- `supabase/sql/030a_profit_weekly_review_sla_union.sql`: visible verdict registration and `profit_weekly_review_items` UNION extension.

Modify:

- `tests/test_fulfillment_classification_sql.py`: static SQL tests for `030` and `030a`.
- `tests/test_weekly_review_api.py`: `SLA_BREACHED` allowed verdict filter and mixed-verdict list behavior.
- `tests/test_profit_admin_frontend.py`: Weekly Review SLA labels/columns/actions and SLA dashboard queue-panel removal.
- `tests/test_sla_dashboard_sql.py`: optional cheap `waiting_on_client` join repair coverage if included; otherwise docs-only deferral assertion.
- `profit_api/weekly_review.py`: add `SLA_BREACHED` to `VISIBLE_VERDICT_CODES`.
- `app/frontend/src/routes/WeeklyReview.jsx`: render SLA rows with service, staff, state, target date, breach age, and FC action link while preserving manual-invoice rows.
- `app/frontend/src/routes/SlaDashboard.jsx`: remove `queue` panel fetch/render and add a link to Weekly Review.
- `app/frontend/src/styles.css`: append route-scoped Weekly Review SLA styles if existing styles are insufficient.
- `docs/data-contracts/weekly-review.md`: document `SLA_BREACHED` row shape, age semantics, co-occurrence, registry extension.
- `docs/data-contracts/sla-dashboard.md`: document that the action queue moved to Weekly Review and `/admin/sla` remains analytics.
- `docs/data-contracts/fulfillment-classifications.md`: document `SLA_BREACHED`, detection coverage, and clearance semantics.
- `docs/tech-debt.md`: update carry-forward notes for blank SLA targets, 1120 C/S conflation decision, and any deferred `waiting_on_client` fix.

Do not modify:

- `profit_weekly_review_item_state` schema unless a failing test proves `classification_id` can be null for SLA rows. The intended path is to create classifications before operator actions.
- Existing V0.7.A manual-invoice detection semantics.
- `profit_api/sla.py` endpoint behavior except removing frontend dependency on the queue panel.
- n8n workflows.

## Task Breakdown

Each implementation task follows red test -> implement -> green test -> commit. Use one commit per task unless Orlando changes execution mode.

### Task 1: SLA Data Profile Gate

**Tier:** 3 (orchestrator-direct via SSH + `psql`)

**Purpose:** Profile live SLA rows before creating verdicts, validate stable keys/action URLs, quantify false-positive risks, and decide whether the `waiting_on_client` repair is cheap enough for V0.7.B.

**Files:**

- No committed file changes.
- Read/query live Supabase only.

**Required output contract:**

- Confirmed candidate count for `breached` + `at_risk` SLA states, excluding `waiting_on_client`.
- `waiting_on_client` join diagnosis in 1-2 paragraphs: root cause if found, or "not cheap-fixable, defer to V0.7.D".
- 1120 C-corp/S-corp deadline conflation live-data check: whether it produces false-positive V0.7.B verdict candidates in current data; list specific clients if yes.
- `default_sla_day is null` exclusion verification: confirm Payroll Service and Fractional CFO produce 0 candidate rows.
- FC task vs project URL availability for at least 3 sample breached rows.
- Staff context fallback coverage: among breached rows, count `assigned_staff_name` populated vs null.
- Day-one volume: total candidate count if V0.7.B were deployed today.

- [ ] **Step 1: Count current SLA states**

  Run via the established SSH + `psql` pattern from V0.7.A:

  ```sql
  select sla_state, count(*)::int
  from profit_sla_service_items
  group by sla_state
  order by sla_state;
  ```

  Expected: counts for `breached`, `at_risk`, `on_track`, `waiting_on_client`, `not_applicable`. If `waiting_on_client = 0` while workflow tags exist, continue profiling.

- [ ] **Step 2: Sample breach/at-risk queue rows**

  ```sql
  select
    anchor_relationship_id,
    fc_client_id,
    fc_client_name,
    service_name,
    macro_service_type,
    assigned_staff_name,
    staff_source,
    age_days,
    target_sla_day,
    trigger_date,
    target_date,
    latest_workflow_status,
    sla_state
  from profit_sla_breach_queue
  order by
    case sla_state when 'breached' then 1 when 'at_risk' then 2 else 3 end,
    target_date asc nulls last
  limit 50;
  ```

  Required evidence: row volume, service distribution, staff distribution, target-date reasonableness, and day-one candidate count for `breached` + `at_risk` after excluding null SLA targets.

- [ ] **Step 3: Validate stable work-item identity**

  Query matching open FC tasks and projects for sampled breach rows:

  ```sql
  select
    item.fc_client_id,
    item.service_name,
    item.fc_tag,
    task.fc_task_id,
    task.fc_project_id,
    task.project_title,
    task.title as task_title,
    task.user_name,
    task.is_completed,
    task.completed_at,
    task.due_date,
    project.title as project_title_from_project
  from profit_sla_service_items item
  left join profit_fc_tasks task
    on task.fc_client_id = item.fc_client_id
   and coalesce(task.is_completed, false) = false
   and (
     task.fc_project_id in (
       select service_tag.fc_project_id
       from profit_fc_project_tags service_tag
       where service_tag.tag_type = 'service'
         and service_tag.tag_name = item.fc_tag
     )
     or task.project_title ilike '%' || item.service_name || '%'
   )
  left join profit_fc_projects project
    on project.fc_project_id = task.fc_project_id
  where item.sla_state in ('breached', 'at_risk')
  order by item.fc_client_name, item.service_name, task.due_date nulls last
  limit 100;
  ```

  Lock validation: stable candidate key must prefer `fc_task_id` when present, else `fc_project_id`, else `anchor_relationship_id + service_name + target_date`.

  Required evidence: for at least 3 sample breached rows, record whether `fc_task_url`, `fc_project_url`, or Anchor fallback will populate `action_url`.

- [ ] **Step 4: Profile completion/archive clearance fields**

  ```sql
  select
    count(*) filter (where task.completed_at is not null or coalesce(task.is_completed, false) = true)::int as completed_task_count,
    count(*) filter (where project.archived_at is not null)::int as archived_project_count,
    count(*)::int as sampled_rows
  from profit_fc_tasks task
  left join profit_fc_projects project
    on project.fc_project_id = task.fc_project_id
  where task.fc_client_id in (
    select fc_client_id
    from profit_sla_service_items
    where sla_state in ('breached', 'at_risk')
      and fc_client_id is not null
  );
  ```

  If `profit_fc_projects.archived_at` does not exist in this checkout/schema, identify the synced archived field in `profit_fc_projects.raw` and record the exact predicate before Task 2.

- [ ] **Step 5: Investigate `waiting_on_client` join issue**

  ```sql
  select
    tag.tag_name,
    tag.tag_type,
    count(*)::int
  from profit_fc_project_tags tag
  where tag.tag_name = 'Waiting on Client'
     or profit_normalize_client_name(tag.tag_name) = profit_normalize_client_name('Waiting on Client')
  group by tag.tag_name, tag.tag_type
  order by count(*) desc;
  ```

  Then compare project/status/service joins for 20 tagged projects. If the bug is a single incorrect tag-name/tag-type/service-tag join in `profit_sla_service_items`, mark it in scope for Task 2. Otherwise record "not cheap-fixable, defer to V0.7.D" with a 1-2 paragraph diagnosis.

- [ ] **Step 6: Profile blank SLA targets**

  ```sql
  select service_name, macro_service_type, recognition_pattern, service_period_rule, default_sla_day, count(*)::int
  from profit_sla_service_items
  where target_sla_day is null
  group by service_name, macro_service_type, recognition_pattern, service_period_rule, default_sla_day
  order by service_name;
  ```

  Expected decision: exclude from SLA verdict candidates and document. Required evidence: Payroll Service and Fractional CFO both produce 0 V0.7.B candidate rows after the exclusion.

- [ ] **Step 7: Profile 1120 C/S conflation risk**

  Search for 1120 C-corp candidates in `breached`/`at_risk`. If live rows prove C-corp false positives caused solely by March 15 vs April 15, list the affected clients and add the narrow fix to Task 2. Otherwise defer with a known-noise tech-debt note.

- [ ] **Step 8: Profile staff fallback coverage**

  ```sql
  select
    count(*) filter (where assigned_staff_name is not null)::int as assigned_staff_populated,
    count(*) filter (where assigned_staff_name is null)::int as assigned_staff_null,
    count(*)::int as breached_rows
  from profit_sla_breach_queue
  where sla_state = 'breached'
    and target_sla_day is not null
    and target_date is not null;
  ```

  Required evidence: count breached rows with `assigned_staff_name` populated vs null, and sample the `staff_source` values seen.

- [ ] **Step 9: Checkpoint**

  Post the required output contract to Orlando. Do not write migrations until G1-G7 and OQ1-OQ5 remain accepted after profiling.

### Task 2: SQL Verdict Seed, Candidate View, And Optional SLA Join Repair

**Tier:** 1

**Purpose:** Add migration `030_profit_sla_breached_verdict.sql` with the `SLA_BREACHED` verdict seed, `profit_sla_breached_candidates`, two transition-rule seeds, and the apply-function branches that mirror V0.7.A.

**Files:**

- Create: `supabase/sql/030_profit_sla_breached_verdict.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`
- Modify if Task 1 proves cheap fix: `tests/test_sla_dashboard_sql.py`

- [ ] **Step 1: Write failing SQL static tests**

  Add tests that assert migration `030`:

  - exists.
  - seeds `SLA_BREACHED` in `profit_classification_verdicts`.
  - creates `profit_sla_breached_candidates`.
  - seeds two SLA transition-rule records for detection and clearance.
  - reads from `profit_sla_service_items`.
  - filters `sla_state in ('breached', 'at_risk')`.
  - excludes rows with null `default_sla_day`, null `target_sla_day`, or null `target_date`.
  - exposes `breach_state`, `breach_age_days`, `work_age_days`, `target_date`, `assigned_staff_name`, `staff_source`, `fc_task_id`, `fc_project_id`, and `action_url`.
  - includes active classification dedupe for `SLA_BREACHED`.

- [ ] **Step 2: Run tests to verify red**

  Run:

  ```bash
  pytest tests/test_fulfillment_classification_sql.py tests/test_sla_dashboard_sql.py -q
  ```

  Expected: FAIL because `030_profit_sla_breached_verdict.sql` does not exist and/or does not contain the required contract.

- [ ] **Step 3: Implement migration `030` candidate layer**

  Migration must:

  - insert/update `SLA_BREACHED` with category `pending`, default visibility `show`, `requires_re_evaluate_at = false`, `auto_transition_enabled = true`.
  - define `profit_sla_breached_candidates`.
  - use `profit_sla_service_items` as the source of truth for SLA state.
  - include only `breached` and `at_risk`.
  - exclude rows where `default_sla_day is null`, `target_sla_day is null`, or `target_date is null`.
  - prefer `fc_task_id` for stable work identity, then `fc_project_id`, then a deterministic fallback key.
  - expose `age_days` as classification age when an active classification exists.
  - expose `breach_age_days = greatest(current_date - target_date::date, 0)`.
  - expose `work_age_days = profit_sla_service_items.age_days`.
  - expose `action_url` using Task 1's confirmed FC task/project URL template, with Anchor fallback.
  - optionally repair `waiting_on_client` join only if Task 1 proved a cheap single-view fix.
  - seed two transition-rule records: `sla_breach_detected` and `sla_breach_cleared`.

- [ ] **Step 4: Run SQL static tests to verify green**

  Run:

  ```bash
  pytest tests/test_fulfillment_classification_sql.py tests/test_sla_dashboard_sql.py -q
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add supabase/sql/030_profit_sla_breached_verdict.sql tests/test_fulfillment_classification_sql.py tests/test_sla_dashboard_sql.py
  git commit -m "feat: add SLA breached verdict candidates"
  ```

### Task 3: SQL Transition Function Branches

**Tier:** 1

**Purpose:** Extend `profit_apply_classification_transitions` in migration `030` so SLA candidates create classifications and clear when task/project work is done.

**Files:**

- Modify: `supabase/sql/030_profit_sla_breached_verdict.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`

- [ ] **Step 1: Write failing transition tests**

  Extend static tests to require:

  - transition-rule seeds for `sla_breach_detected` and `sla_breach_cleared`.
  - apply-function branches for `sla_breach_detected`, `sla_task_completed`, and `sla_project_archived`.
  - the replacement function preserves V0.7.A signals: `manual_invoice_detected`, `manual_invoice_issued`, `manual_invoice_agreement_terminated`.
  - the replacement function preserves pre-V0.7.A audit transition signals.
  - the detection branch inserts no duplicate active `SLA_BREACHED` rows for the same stable SLA key.
  - dry-run still writes zero rows.

- [ ] **Step 2: Run tests to verify red**

  Run:

  ```bash
  pytest tests/test_fulfillment_classification_sql.py -q
  ```

  Expected: FAIL on missing transition-rule/function fragments.

- [ ] **Step 3: Implement transition branches**

  Update migration `030` to replace `profit_apply_classification_transitions` with all previous branches plus:

  - `sla_breach_detected`: creates `SLA_BREACHED` rows for candidates without an active classification.
  - `sla_task_completed`: supersedes active `SLA_BREACHED` when the stable `fc_task_id` is complete.
  - `sla_project_archived`: supersedes active `SLA_BREACHED` when the stable `fc_project_id` is archived.

  Evidence summary must include `breach_state`, `service_name`, `target_date`, `breach_age_days`, `work_age_days`, `assigned_staff_name`, `staff_source`, and stable work id.

- [ ] **Step 4: Run tests to verify green**

  Run:

  ```bash
  pytest tests/test_fulfillment_classification_sql.py -q
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add supabase/sql/030_profit_sla_breached_verdict.sql tests/test_fulfillment_classification_sql.py
  git commit -m "feat: transition SLA breaches into classifications"
  ```

### Task 4: Weekly Review SQL UNION Extension

**Tier:** 1

**Purpose:** Register `SLA_BREACHED` and replace `profit_weekly_review_items` with `manual rows UNION ALL sla rows` using type-aware nullable columns.

**Files:**

- Create: `supabase/sql/030a_profit_weekly_review_sla_union.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`

- [ ] **Step 1: Write failing SQL queue tests**

  Tests must require migration `030a` to:

  - insert `SLA_BREACHED` into `profit_weekly_review_visible_verdicts`.
  - replace `profit_weekly_review_items`.
  - include `profit_manual_invoice_pending_candidates`.
  - include `profit_sla_breached_candidates`.
  - use `union all`.
  - output common columns already documented in V0.7.A.
  - output SLA-specific columns: `breach_state`, `breach_age_days`, `work_age_days`, `target_date`, `assigned_staff_name`, `staff_source`.
  - output manual-invoice-specific columns from V0.7.A and return null for them on SLA rows.
  - return null for SLA-specific columns on manual-invoice rows.
  - left join `profit_weekly_review_item_state` by `classification_id`.
  - compute `sort_rank` as `row_number()` over a UNION-wide `ORDER BY`.

- [ ] **Step 2: Run tests to verify red**

  Run:

  ```bash
  pytest tests/test_fulfillment_classification_sql.py -q
  ```

  Expected: FAIL because `030a` is missing.

- [ ] **Step 3: Implement `030a`**

  Create migration that:

  - registers `SLA_BREACHED` in `profit_weekly_review_visible_verdicts`.
  - replaces `profit_weekly_review_items` with a UNION-compatible projection for manual-invoice rows and SLA rows.
  - keeps `classification_id` as the review-state key.
  - keeps `item_type = verdict_code`.
  - provides nulls for non-applicable columns per row family.
  - documents the column shape explicitly in SQL comments:
    - common columns from V0.7.A, including `classification_id`, `verdict_code`, `item_type`, `client_name`, `anchor_relationship_id`, `action_url`, `age_days`, revenue fields, review/snooze state, and `sort_rank`.
    - manual-invoice columns: invoice and billing fields from `profit_manual_invoice_pending_candidates`; SLA rows return null for these.
    - SLA columns: `breach_state`, `breach_age_days`, `work_age_days`, `target_date`, `service_name`, `macro_service_type`, `assigned_staff_name`, `staff_source`, `fc_task_id`, `fc_project_id`; manual-invoice rows return null for these.
  - computes `sort_rank` as `row_number()` over a UNION-wide `ORDER BY`: SLA breached first, then SLA at-risk, then manual-invoice; within SLA bands order by `breach_age_days desc nulls last`, revenue desc, client name asc; within manual-invoice order by `age_days desc nulls last`, revenue desc, client name asc.

- [ ] **Step 4: Run tests to verify green**

  Run:

  ```bash
  pytest tests/test_fulfillment_classification_sql.py -q
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add supabase/sql/030a_profit_weekly_review_sla_union.sql tests/test_fulfillment_classification_sql.py
  git commit -m "feat: add SLA rows to weekly review view"
  ```

### Task 5: Weekly Review API Contract

**Tier:** 1

**Purpose:** Keep `WeeklyReviewService` as the API owner, expand the verdict-code filter to accept both visible verdict codes, and verify mixed verdict rows retain review/snooze behavior.

**Files:**

- Modify: `profit_api/weekly_review.py`
- Modify: `tests/test_weekly_review_api.py`

- [ ] **Step 1: Write failing API tests**

  Add tests that:

  - `verdict_code=SLA_BREACHED` returns SLA rows.
  - `verdict_code=MANUAL_INVOICE_PENDING` still returns manual rows.
  - unsupported verdict codes still return 422.
  - mixed `MANUAL_INVOICE_PENDING` and `SLA_BREACHED` rows sort by SQL `sort_rank`.
  - `list_items` continues to filter visible rows through `profit_weekly_review_visible_verdicts`.
  - reviewed/snoozed filters apply identically to SLA rows.
  - Mark reviewed and Snooze still write only `profit_weekly_review_item_state`.

- [ ] **Step 2: Run tests to verify red**

  Run:

  ```bash
  pytest tests/test_weekly_review_api.py -q
  ```

  Expected: FAIL because `SLA_BREACHED` is not in `VISIBLE_VERDICT_CODES`.

- [ ] **Step 3: Implement API change**

  Add `SLA_BREACHED` to the accepted verdict-code filter. Keep `WeeklyReviewService` and `list_items` centered on `profit_weekly_review_visible_verdicts`. Do not add SLA-specific endpoints. Do not write to `profit_classifications` from Weekly Review actions.

- [ ] **Step 4: Run tests to verify green**

  Run:

  ```bash
  pytest tests/test_weekly_review_api.py -q
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add profit_api/weekly_review.py tests/test_weekly_review_api.py
  git commit -m "feat: allow SLA verdicts in weekly review API"
  ```

### Task 6: Frontend Weekly Review And SLA Dashboard

**Tier:** 2 (CC subagent)

**Purpose:** Render SLA verdict rows in Weekly Review and remove the duplicated read-only queue panel from `/admin/sla`.

**Files:**

- Modify: `app/frontend/src/routes/WeeklyReview.jsx`
- Modify: `app/frontend/src/routes/SlaDashboard.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write failing frontend static tests**

  Tests must require:

  - `WeeklyReview.jsx` contains `SLA_BREACHED`.
  - SLA rows conditionally show state, target date, breach age/overdue days, work age, staff name/source, service name, and action link.
  - manual-invoice rows do not render empty SLA-specific labels.
  - Weekly Review still contains Mark reviewed and Snooze 7 days.
  - `SlaDashboard.jsx` no longer fetches `/profit/admin/sla/queue`.
  - `SlaDashboard.jsx` no longer renders `id="sla-breach-queue"`.
  - `SlaDashboard.jsx` no longer references the `sla-breach-queue` scroll anchor.
  - SLA dashboard includes a link to `/admin/weekly-review`.
  - styles remain scoped with `.weekly-review` or `.sla-` prefixes.

- [ ] **Step 2: Run tests to verify red**

  Run:

  ```bash
  pytest tests/test_profit_admin_frontend.py -q
  ```

  Expected: FAIL on missing SLA Weekly Review rendering and duplicated SLA queue panel.

- [ ] **Step 3: Implement frontend changes**

  Update `WeeklyReview.jsx` to:

  - add label `SLA_BREACHED: "SLA Breached"`.
  - display `breach_state` badge for SLA rows.
  - show `breach_age_days` as overdue days for breached rows.
  - show `target_date`, `assigned_staff_name`, and `staff_source` when present.
  - render SLA-specific columns conditionally per row, not as global empty columns for manual rows.
  - make action-link text generic enough for FC links, e.g. `Open work item`.
  - keep manual-invoice rows readable with existing invoice/revenue fields.

  Update `SlaDashboard.jsx` to:

  - remove `queueEndpoint`.
  - remove `PANELS.queue`.
  - remove the `sla-breach-queue` scroll anchor.
  - remove `sortedQueueRows`.
  - remove the breach queue `PanelFrame`.
  - add a header link to `/admin/weekly-review`.

- [ ] **Step 4: Build and run frontend tests**

  Run:

  ```bash
  pytest tests/test_profit_admin_frontend.py -q
  npm --prefix app/frontend run build
  ```

  Expected: PASS and successful Vite build.

- [ ] **Step 5: Commit**

  ```bash
  git add app/frontend/src/routes/WeeklyReview.jsx app/frontend/src/routes/SlaDashboard.jsx app/frontend/src/styles.css tests/test_profit_admin_frontend.py
  git commit -m "feat: surface SLA verdicts in weekly review"
  ```

### Task 7: Data Contracts And Tech Debt

**Tier:** 3 (orchestrator-direct)

**Purpose:** Update docs so V0.7.B contracts are explicit and carry-forward findings are either addressed or deferred.

**Files:**

- Modify: `docs/data-contracts/weekly-review.md`
- Modify: `docs/data-contracts/sla-dashboard.md`
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md`
- Modify: `tests/test_data_references_docs.py`

- [ ] **Step 1: Write failing docs tests**

  Tests must require docs to mention:

  - `SLA_BREACHED`.
  - `breached` + `at_risk` coverage.
  - `waiting_on_client` exclusion and Task 1 repair/defer outcome.
  - blank SLA target exclusion.
  - Payroll Service and Fractional CFO as 0-row candidate exclusions when `default_sla_day is null`.
  - 1120 C/S fix-or-defer outcome.
  - `breach_age_days` vs `age_days`.
  - `profit_weekly_review_items` UNION column shape and type-aware nullable fields.
  - dual-row co-occurrence with `MANUAL_INVOICE_PENDING`.
  - `/admin/sla` keeps analytics but no longer owns the action queue.

- [ ] **Step 2: Run tests to verify red**

  Run:

  ```bash
  pytest tests/test_data_references_docs.py -q
  ```

  Expected: FAIL until docs are updated.

- [ ] **Step 3: Update docs**

  Update contracts with the decisions in this plan and Task 1 outcomes. Be explicit about any deferrals and the operational reason.

- [ ] **Step 4: Run docs tests to verify green**

  Run:

  ```bash
  pytest tests/test_data_references_docs.py -q
  ```

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add docs/data-contracts/weekly-review.md docs/data-contracts/sla-dashboard.md docs/data-contracts/fulfillment-classifications.md docs/tech-debt.md tests/test_data_references_docs.py
  git commit -m "docs: document SLA weekly review contract"
  ```

### Task 8: Integration Verification And Deploy Gate

**Tier:** 3 (orchestrator-direct via SSH + `psql` + `scp` + service restart)

**Purpose:** Run full local verification, apply migrations in the target environment, execute dry-run/live transition checks, and confirm Weekly Review row counts.

**Files:**

- No planned source changes.
- Commit only if deploy discovers a source-controlled fix that Orlando approves.

**Deploy pattern:** use the same V0.7.A operator path: SSH to target host, `scp` changed source/migration files as needed, apply SQL with `psql`, restart the FastAPI service, then smoke test the admin frontend.

- [ ] **Step 1: Full local verification**

  Run:

  ```bash
  pytest -q
  npm --prefix app/frontend run build
  ```

  Expected: PASS.

- [ ] **Step 2: Pre-deploy SQL smoke check**

  In the target Supabase environment, before applying migrations:

  ```sql
  select count(*)::int from profit_sla_breach_queue;
  select count(*)::int from profit_weekly_review_items;
  select verdict_code, count(*)::int
  from profit_classifications
  where superseded_at is null
  group by verdict_code
  order by verdict_code;
  ```

  Record baseline counts.

- [ ] **Step 3: Apply migrations**

  Copy migration files to the target host if the deploy flow requires it, then apply in order:

  ```bash
  scp supabase/sql/030_profit_sla_breached_verdict.sql "$PROFIT_HOST:/tmp/030_profit_sla_breached_verdict.sql"
  scp supabase/sql/030a_profit_weekly_review_sla_union.sql "$PROFIT_HOST:/tmp/030a_profit_weekly_review_sla_union.sql"
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/sql/030_profit_sla_breached_verdict.sql
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/sql/030a_profit_weekly_review_sla_union.sql
  ```

  Expected: both apply cleanly.

- [ ] **Step 4: Dry-run transitions**

  ```sql
  select *
  from profit_apply_classification_transitions(now(), true)
  where to_verdict_code = 'SLA_BREACHED'
     or from_verdict_code = 'SLA_BREACHED'
  order by signal_name, fc_client_name
  limit 100;
  ```

  Expected: candidate count aligns with Task 1 breach/at-risk profile after exclusions.

- [ ] **Step 5: Live transition application**

  After Orlando approval of dry-run output:

  ```sql
  select *
  from profit_apply_classification_transitions(now(), false)
  where to_verdict_code = 'SLA_BREACHED'
     or from_verdict_code = 'SLA_BREACHED';
  ```

  Expected: active `SLA_BREACHED` classifications created for eligible candidates; no duplicate active rows for the same stable SLA key.

- [ ] **Step 6: Post-deploy queue verification**

  ```sql
  select verdict_code, count(*)::int
  from profit_weekly_review_items
  group by verdict_code
  order by verdict_code;

  select verdict_code, item_type, client_name, service_name, breach_state, breach_age_days, target_date, action_url
  from profit_weekly_review_items
  where verdict_code = 'SLA_BREACHED'
  order by sort_rank
  limit 20;
  ```

  Expected: `MANUAL_INVOICE_PENDING` remains visible and `SLA_BREACHED` rows appear with sensible sort/display fields.

- [ ] **Step 7: Restart service**

  Use the same service restart command used in V0.7.A on the target host.

  Expected: FastAPI restarts cleanly and `/profit/admin/weekly-review` serves the expanded verdict filter.

- [ ] **Step 8: Browser smoke test**

  Open `/admin/weekly-review` and `/admin/sla`.

  Expected:

  - Weekly Review shows manual-invoice and SLA rows when present.
  - SLA rows have Mark reviewed and Snooze 7 days controls after classifications exist.
  - `/admin/sla` still shows analytics/backfill access and no duplicated breach queue panel.

- [ ] **Step 9: Commit deploy notes only if source docs changed**

  If deployment reveals no source changes, do not commit. If docs need a post-deploy count note and Orlando approves:

  ```bash
  git add docs/tech-debt.md
  git commit -m "docs: record SLA weekly review deploy notes"
  ```

## Task Count, Estimate, Tier Mix

8 tasks, approximately 1.5 days.

Tier breakdown:

- 4 x Tier 1: SQL candidate/verdict, transition function, Weekly Review UNION, API allow-list.
- 1 x Tier 2: frontend Weekly Review + SLA dashboard panel removal.
- 3 x Tier 3: data profile gate, docs/integration contract, deploy gate.

## Out-of-Scope Items Intentionally Not Added

- Pipeline failure verdicts for V0.7.D.
- Anchor backfill verdicts for V0.7.C.
- Manual recognition queue migration for V0.7.D.
- Multi-practice routing for V0.7.E.
- Reassign staff from Weekly Review.
- Reset SLA target override controls.
- New SLA analytics or performance-window enhancements.
- `waiting_on_client` verdict generation.

## Carry-Forward Items Addressed

- `waiting_on_client`: Task 1 investigates; Task 2 fixes only if the live issue is a cheap single-view join repair. Verdict generation excludes it in V0.7.B.
- Blank SLA targets: excluded from verdict candidates; docs/tech debt retain Payroll Service and Fractional CFO as data-quality follow-up.
- 1120 C/S conflation: Task 1 profiles live false-positive risk; fix narrowly only if it affects V0.7.B generated verdicts, otherwise defer with explicit known-risk note.
- `age_days` semantics: universal `age_days` remains classification age; SLA rows add `breach_age_days`, `work_age_days`, and `target_date`.
- `MANUAL_INVOICE_PENDING` co-occurrence: dual rows in Weekly Review, one per verdict classification.

## Self-Review Checklist

- Spec coverage: G1-G7 and OQ1-OQ5 are locked above and mapped to tasks.
- Placeholder scan: no implementation task uses placeholder language; Task 1 gates specify exact evidence required.
- Type consistency: plan uses one verdict code, `SLA_BREACHED`, one candidate view, `profit_sla_breached_candidates`, and one queue view extension migration, `030a_profit_weekly_review_sla_union.sql`.
- No code execution requested here: this document is the only file created during the plan-draft turn.
