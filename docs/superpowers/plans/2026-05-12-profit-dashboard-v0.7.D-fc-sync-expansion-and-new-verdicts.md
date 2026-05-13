# Profit Dashboard V0.7.D FC Template Map And New Verdicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Orlando one Weekly Review place to see SLA routing/status gaps, stuck manual recognition approvals, and failed pipeline runs, while replacing brittle SLA project-title matching with an operator-managed FC template service map, derived preparer routing, and data-driven 1120 entity-type metadata.

**Architecture:** V0.7.D is a foundation-first slice. D-1 adds SQL-only SLA data contracts using FC project `template_id` metadata and completed-task assignee history; D-2 adds two new Weekly Review verdict families and stale cleanup after those joins are reliable. SQL remains the canonical state machine; existing n8n FC ingestion is unchanged; FastAPI exposes visibility only.

**Tech Stack:** Supabase/Postgres migrations, FastAPI `profit_api`, React admin frontend, pytest/static SQL contract tests, `scripts/predeploy_smoke.sh`, live Supabase verification.

---

## Strategic Context

V0.7.B day-one SLA profiling found three structural gaps that V0.7.B intentionally shipped around: every SLA row routed to `Unassigned`, `latest_workflow_status` stayed null, and SLA clearance fell back to `ILIKE '%' || split_part(service_name, ' ', 1) || '%'` against FC project titles because no reliable service bridge existed. V0.7.B.4 then moved SLA candidates onto the data-driven labeled-service attribution layer, making this bridge more important because every active Anchor service can now surface as an SLA row.

This plan respects the 2026-05-12 no-content-specific-rules principle. The plan does not add code that knows that a named client, form, service, or suffix means something special. Entity-type handling is metadata-driven. Staff routing reads derived completed-task assignee history. Service matching reads operator-managed FC template metadata and service catalog rows. Manual recognition and pipeline failure rows read durable system tables.

## Locked Decisions (turn 031)

### Gates

| Gate | Locked answer | Reasoning |
|---|---|---|
| G1 | REVISED: Use a derived primary-preparer view from completed-task `raw->assignees[0]->name` over the last 365 days per client. Do not use task `user_name` as assignee; it is the completer. | Task 1 found `user_name` is the completer and Orlando completed 97% of completed tasks. The real assignee is in `raw->assignees[0]->name`, and active open projects have zero open tasks to read. |
| G2 | REVISED: Use operator-seeded `profit_fc_template_service_map(template_id, fc_tag_prefix)` plus the existing ILIKE-title fallback for long-tail templates. Do not populate project service tags from FC. | Task 1 found FC has no project-level service tags; service mapping lives in `profit_fc_projects.template_id`, with a small number of templates covering most projects. |
| G3 | `entity_type` is operator-managed metadata on `profit_service_recognition_rules`, nullable by default. Add a sibling override table only if Task 1 proves one service row must support multiple entity types. | Keeps deadline behavior data-driven without service-name parsing or premature schema expansion. |
| G4 | `MANUAL_RECOGNITION_PENDING` candidates come from `profit_pipeline_stuck_recognition_triggers`, keyed by `revenue_event_key`. | Reuses the durable stuck-recognition diagnostic source instead of creating a second predicate. |
| G5 | `PIPELINE_RUN_FAILED` candidates are one row per failed/partial `pipeline_run_id`; auto-clear when a later run finishes `status='success'`; Mark reviewed remains review state only. | Preserves auditable failure context and lets system recovery, not operator review, clear the system-health verdict. |
| G6 | Wire `waiting_on_client` inside the SLA candidate/state CASE after the template-map bridge exists. Exclude `waiting_on_client` from `SLA_BREACHED` candidates by default. | Client-blocked work is non-actionable for Weekly Review, while still visible in SLA dashboard status/workload views. |
| G7 | Keep one V0.7.D plan and execute as D-1 (T1-T4 plus T_new SQL/SLA foundation) and D-2 (T5-T9 verdicts/cleanup/UI/docs), with a mid-sprint operator checkpoint between D-1 and D-2. | Reduces queue-taxonomy blast radius while preserving one coherent implementation plan. |

### Open Questions

| OQ | Locked answer | Reasoning |
|---|---|---|
| OQ1 | Reuse the existing 30-day stuck-recognition threshold. | Matches `profit_pipeline_stuck_recognition_triggers` and avoids maintaining a second threshold. |
| OQ2 | CLOSED: Do not change W17 for V0.7.D. D-1 is pure SQL: template map table, derived preparer view, SLA candidate rewrite, and nullable entity-type metadata. | Task 1 invalidated ingestion-side tag writes; the safer bridge uses existing FC project/template/task raw data already present in Postgres. |
| OQ3 | Ship `entity_type` nullable with no initial seed. | Operator can seed rows on demand when a concrete 1120 C-corp case surfaces; no urgent backfill is required. |
| OQ4 | Hide `waiting_on_client` rows from Weekly Review by default. | Client-blocked work is not operator-actionable weekly-review work; SLA dashboard retains visibility. |
| OQ5 | Use the simpler no-successor supersede pattern and add `manual_invoice_no_active_manual_trigger_services`. | Reuses the V0.7.A `manual_invoice_agreement_terminated` no-op resolution shape without introducing a scan v3. |
| OQ6 | Surface only `status='partial'` runs where `summary.total_steps_failed > 0`. | Filters out pure soft-step operational noise while preserving actionable partial failures. |
| OQ7 | Use no time window: include any unresolved failure since the last success. | Next successful run naturally bounds unresolved failures; a fixed window could hide outages. |
| OQ8 | CLOSED: Keep a single derived staff source from `profit_fc_client_primary_preparer`; divergence question is moot. | Task 1 found no second live staff source for active SLA rows because open projects have zero open tasks and task `user_name` is completer, not assignee. |
| OQ9 | Exclude blank-SLA-target services from V0.7.D scope; do not seed defaults and do not add `BILLING_SETUP_GAP` in this slice. Document Payroll Service and Year End Accounting Close in `weekly-review.md` Deferred Gaps. | Keeps V0.7.D focused on confirmed SLA targets and defers configuration-gap verdict design to V0.7.G polish. |

## Task 1 Findings & Adjustments (turn 032)

Full findings doc cross-reference: `coordination/task-1-V0.7.D-data-profile.md`.

Task 1 headline findings:

1. **FC has NO project-level service tags.** `profit_fc_project_tags.tag_type='service'` cannot be populated from FC. Service mapping lives in `profit_fc_projects.template_id` (~7-8 templates cover 225 of 391 projects).
2. **`user_name` is the COMPLETER, not the assignee** (Orlando 97% of completed tasks). Real assignee lives in `raw->assignees[0]->name`.
3. **All 143 open projects have ZERO open tasks.** Task-assignee staff routing for active SLA rows has nothing to read.
4. **Solution:** template-map table (~20 rows) + derived "primary preparer per client" view from last 12 months of completed-task `raw->assignees[0]->name`.

Approved adjustments:

**A1 - Replace project-service-tag sync with template-map table**

NEW SQL object: `profit_fc_template_service_map(template_id, fc_tag_prefix, notes, created_at, updated_at)`. Operator-seeded (~20 rows). Used as the primary join surface for SLA clearance: `project.template_id` -> `fc_tag_prefix` -> matches `recognition_rules.fc_tag LIKE prefix || '%'`.

DROP the previously-planned `profit_fc_project_tags(tag_type='service')` populate. FC doesn't expose that data.

**A2 - Initial seed comes from Task 1 + orchestrator draft + Orlando spot-check**

Orchestrator drafts the seed (~20 rows) from Task 1's template_id-to-title analysis. Orlando spot-checks before live apply. This is a one-time human-validated seed, NOT an autogen.

**A3 - Replace staff-tag sync with derived view**

NEW SQL object: `profit_fc_client_primary_preparer` view. Reads `raw->assignees[0]->name` from completed tasks in last 365 days per `fc_client_id`, aggregates count, picks most-frequent non-null assignee.

DROP the previously-planned `profit_fc_client_tags(tag_type='staff')` populate. No FC staff field exists.

**A4 - Keep ILIKE-title fallback**

SLA clearance retains `project.title ILIKE '%' || split_part(service_name, ' ', 1) || '%'` as fallback for projects whose `template_id` has no map row. Approximately 150 projects on small/long-tail templates fall here. Document as expected coverage.

The 80%-threshold rule from refinement-031 still applies but is reframed: "After T2 lands and live verification shows >=80% of active SLA candidate rows clear via the template-map join, KEEP the ILIKE fallback as documented coverage for long-tail templates. If template-map coverage is <80%, expand the seed map before removing fallback."

**A5 - Drop W17 workflow change from T2 entirely**

Original T2 modified `n8n/workflows/profit-17-financial-cents-sync.json` to add ingestion-side tag writes. **DROP.** All A1-A4 changes are pure SQL migrations + a view. W17 unchanged.

This is the biggest risk reduction: nightly ingestion stays untouched.

## Lock conflicts surfaced

None. G1 and G2 were revised by Task 1 findings, and OQ8 is closed as moot. The locked decisions remain data-driven. The two named blank-SLA services in OQ9 are documented as current rows excluded because `default_sla_day` is blank, not as code-level service-name exceptions.

## Scope Inclusions

1. FC template service bridge: add operator-managed `profit_fc_template_service_map(template_id, fc_tag_prefix)` and use it as the primary SLA clearance join surface, retaining the documented ILIKE fallback for long-tail templates.
2. Derived preparer routing: add `profit_fc_client_primary_preparer` view from completed-task `raw->assignees[0]->name` over the last 365 days per client.
3. Service catalog entity type: add data-driven entity-type metadata for service recognition/SLA target-date calculation, especially 1120 C-corp vs S-corp deadline disambiguation.
4. Manual recognition verdict: surface stale manual recognition events in Weekly Review as `MANUAL_RECOGNITION_PENDING`.
5. Pipeline failure verdict: surface failed or partial Workflow 26 pipeline runs in Weekly Review as `PIPELINE_RUN_FAILED`.
6. `waiting_on_client` SLA wiring: use FC workflow-status + template-map bridge to set SLA state and keep it out of actionable breach rows by default.
7. Stale `MANUAL_INVOICE_PENDING` cleanup: supersede orphaned rows when the active classification no longer corresponds to an active manual-trigger service or a valid agreement state.

## Explicit Exclusions

- V0.7.C Anchor backfill verdicts.
- V0.7.E M&A configuration layer and multi-practice routing.
- V0.7.B.2 visibility/affordance polish, including F4/F7/F15/F16/F17/F18.
- AI-agent supplement layer for attribution orphans.
- Per-service `MANUAL_INVOICE_PENDING` rewrite.
- Anchor invoice line-item parsing for per-service invoice-paid clearance.
- Content-specific rules or client/service/form-name exceptions.
- Direct deploys, migrations, code edits, or commits during this plan-only turn.

## Read First For Implementation Turns

- `coordination/STATE.md` from the coordination repo, especially V0.7.B.4 ship state and expanded V0.7.D scope.
- `coordination/decisions.md`, 2026-05-12 entries for predeploy smoke and no content-specific rules.
- `coordination/task-1-V0.7.D-data-profile.md`.
- `coordination/task-1-V0.7.B-data-profile.md`.
- `docs/tech-debt.md`, V0.7.A/B/B.1/B.3/B.4 sections and V0.7.D-tagged entries.
- `docs/data-contracts/weekly-review.md`.
- `docs/data-contracts/fulfillment-classifications.md`.
- `docs/data-contracts/sla-dashboard.md`.
- `docs/data-contracts/financial-cents-sync.md`.
- `supabase/sql/028_profit_sla_core_views.sql`.
- `supabase/sql/029_profit_manual_invoice_pending_verdict.sql`.
- `supabase/sql/030_profit_sla_breached_verdict.sql`.
- `supabase/sql/034a_profit_anchor_services_attributed.sql`.
- `supabase/sql/034b_profit_sla_candidates_use_attribution.sql`.
- `supabase/sql/034c_profit_weekly_review_items_expose_attribution.sql`.
- `supabase/sql/026c_profit_pipeline_diagnostic_views.sql`.
- `profit_api/weekly_review.py`.
- `profit_api/manual_recognition.py`.
- `n8n/workflows/profit-26-pipeline-orchestration.json` only for understanding pipeline-run failure evidence; no workflow edits in V0.7.D-1.

## Gates To Review With Orlando

### G1 - Derived Preparer Routing

**LOCKED:** REVISED turn 032. Use a derived primary-preparer view from completed-task `raw->assignees[0]->name` over the last 365 days per client. Do not use task `user_name` as assignee; Task 1 found it is the completer.

**Recommendation:** Create `profit_fc_client_primary_preparer` as a view that groups completed tasks by `fc_client_id`, extracts non-null `raw->assignees[0]->name`, counts assignee frequency over the last 365 days, and selects the most frequent assignee per client.

**Reasoning:** Task 1 found `user_name` is the completer, not the assignee, and Orlando completed 97% of completed tasks. It also found all 143 open projects have zero open tasks, so active SLA rows cannot use open-task assignee routing. Completed-task assignee history is the only confirmed staff signal available in current FC raw data.

**Rejected alternative:** Populate `profit_fc_client_tags(tag_type='staff')` or route from task `user_name`. No FC staff field exists, and `user_name` would route nearly all rows to the completer.

### G2 - Template-Map Service Bridge

**LOCKED:** REVISED turn 032. Use operator-seeded `profit_fc_template_service_map(template_id, fc_tag_prefix)` as the primary join surface, with the existing project-title ILIKE fallback retained for long-tail templates.

**Recommendation:** Create `profit_fc_template_service_map(template_id, fc_tag_prefix, notes, created_at, updated_at)` and seed about 20 rows from Task 1's template-id/title analysis after Orlando spot-checks the draft. SLA clearance joins `profit_fc_projects.template_id` to this map and then matches `recognition_rules.fc_tag LIKE fc_tag_prefix || '%'`.

**Reasoning:** Task 1 found FC has no project-level service tags and `profit_fc_project_tags(tag_type='service')` cannot be populated from FC. Service mapping lives in `profit_fc_projects.template_id`; about 7-8 templates cover 225 of 391 projects, and a human-validated map is small enough to operate as metadata rather than content-specific logic.

**Rejected alternative:** Add W17 ingestion-side service-tag writes. FC does not expose the data required to write those tags, and changing nightly ingestion is unnecessary for this slice.

### G3 - Entity-type source

**LOCKED:** `entity_type` is operator-managed metadata on `profit_service_recognition_rules`, nullable by default. Add a sibling override table only if Task 1 proves one service row must support multiple entity types.

**Recommendation:** Add `entity_type` as operator-managed metadata on `profit_service_recognition_rules`, nullable by default, plus an optional override table only if Task 1 proves the same canonical service row must support multiple entity types simultaneously.

**Reasoning:** The lowest-friction operator path is to maintain the service catalog row that already owns `fc_tag`, recognition pattern, service period, and SLA day. The implementation can calculate target dates from metadata instead of matching service-name content. If "1120 Plus" can represent both C and S corp in the same row, a sibling table keyed by `(service_name, entity_type)` or an operator override table becomes necessary.

**Rejected alternative:** Infer C-corp vs S-corp from client suffix, tax form text, or heuristics. That is content-specific and would recreate the V0.7.B.3 failure mode.

### G4 - `MANUAL_RECOGNITION_PENDING` verdict shape

**LOCKED:** Source candidates from `profit_pipeline_stuck_recognition_triggers`, keyed by `revenue_event_key`, using the existing 30-day threshold from OQ1.

**Recommendation:** Source candidates from `profit_pipeline_stuck_recognition_triggers`, with verdict rows keyed by `revenue_event_key`, and use the existing 30-day diagnostic policy.

**Reasoning:** The diagnostic view already expresses "pending revenue events older than 30 days that are not ready for automatic recognition." It is durable, generic, and avoids inventing a second manual-recognition predicate. Weekly Review should show only stuck items that require operator approval or investigation, not every pending event.

**Rejected alternative:** Union every `profit_manual_recognition_pending_events` row into Weekly Review. That would flood the queue with normal pending events and collapse the distinction between ordinary deferred revenue and stuck work.

### G5 - `PIPELINE_RUN_FAILED` verdict shape

**LOCKED:** Use one row per failed/partial `pipeline_run_id`; auto-clear when a later Workflow 26 run finishes `status='success'`; Mark reviewed remains review-state only.

**Recommendation:** Surface the most recent unresolved `profit_pipeline_runs` rows with `status in ('failed', 'partial')`, one active classification per `pipeline_run_id`, auto-clear when a later Workflow 26 run finishes with `status='success'`, and keep operator Mark reviewed as a UI-only state.

**Reasoning:** The failure itself is system truth and should be durable until the next success proves the pipeline recovered. A one-row-per-run key preserves the exact failure context and avoids ambiguous per-day aggregation. The queue can filter to a recent window for candidates, but active classifications should resolve by success signal rather than time alone.

**Rejected alternative:** Only show the latest failed run per day. That hides multiple distinct failures and makes evidence harder to audit.

### G6 - `waiting_on_client` Wiring

**LOCKED:** Wire `waiting_on_client` inside the SLA candidate/state CASE once the template-map bridge exists. Exclude `waiting_on_client` from `SLA_BREACHED` candidates by default.

**Recommendation:** Reintroduce workflow-status integration inside the SLA candidate/state CASE once the template-map bridge exists, and exclude `waiting_on_client` from `SLA_BREACHED` candidates by default while preserving it in SLA dashboard workload/status views.

**Reasoning:** `waiting_on_client` is a legitimate non-actionable SLA state: work is blocked by the client, not by staff routing. SQL already owns SLA state precedence in `profit_sla_service_items`; `profit_sla_breached_candidates` should mirror that canonical state and avoid creating actionable breach verdicts for client-blocked rows.

**Rejected alternative:** Render `waiting_on_client` as muted rows inside Weekly Review. That creates UI ambiguity unless Orlando explicitly wants the operator to review blocked rows weekly.

### G7 - Migration Cadence

**LOCKED:** Keep one V0.7.D plan; execute as D-1 (SQL-only SLA foundation, T1-T4 plus T_new) and D-2 (new verdicts, cleanup, UI, docs, T5-T9). Include a mid-sprint operator review checkpoint between D-1 and D-2.

**Recommendation:** Keep one V0.7.D plan, but execute as D-1 and D-2 with SQL migrations first: template map, primary preparer view, SLA candidate rewrite, nullable entity-type column, then manual recognition, pipeline failure, stale cleanup, API/UI registry, and docs.

**Reasoning:** D-1 no longer changes ingestion and is therefore safe for orchestrator-direct execution with per-migration predeploy smoke gates. The new verdicts still depend on the existing Weekly Review shape and can stay in D-2 after Orlando reviews D-1 live coverage.

**Rejected alternative:** Ship all workstreams in one large migration. That couples SLA contract changes with queue taxonomy changes and makes live verification harder.

## Open Questions - DECISION NEEDED (now locked turn 031)

- **OQ1 LOCKED:** Reuse the existing 30-day stuck-recognition threshold from `profit_pipeline_stuck_recognition_triggers`.
- **OQ2 CLOSED:** Do not change W17 for V0.7.D. D-1 is pure SQL and uses existing FC project/template/task raw data.
- **OQ3 LOCKED:** Ship `entity_type` as nullable metadata with no initial seed.
- **OQ4 LOCKED:** Hide `waiting_on_client` rows from Weekly Review by default; keep visibility in SLA dashboard workload/status views.
- **OQ5 LOCKED:** Use the simpler no-successor supersede pattern and add `manual_invoice_no_active_manual_trigger_services`.
- **OQ6 LOCKED:** Surface only `status='partial'` runs where `summary.total_steps_failed > 0`.
- **OQ7 LOCKED:** Use no time window; include any unresolved failure since the last success.
- **OQ8 CLOSED:** Use the single derived primary-preparer source; the divergence question is moot because Task 1 found no second live staff source for active SLA rows.
- **OQ9 LOCKED:** Exclude blank-SLA-target services from V0.7.D scope. Do not seed defaults and do not create `BILLING_SETUP_GAP` in this slice; document Payroll Service and Year End Accounting Close in `weekly-review.md` Deferred Gaps.

## Estimated Effort

Estimated effort: **2.5 to 4.0 engineering days**, confidence medium.

This is smaller than turn 031 because D-1 no longer touches W17/n8n or Python. It still touches SLA SQL, transition function state, two new verdict families, API registry/tests, docs, and live-data verification. Recommended execution split:

- **V0.7.D-1:** SQL-only template map + preparer view + SLA/entity-type foundations, 1.0 to 1.75 days.
- **V0.7.D-2:** manual recognition verdict + pipeline failure verdict + stale cleanup + UI/API/docs, 1.5 to 2.25 days. T8 is parallel-eligible with T5/T6 after T1, reducing D-2 wall-clock if workers are available.

## Dependency Graph

```text
T1 COMPLETE -> T2 -> T3 -> T4 -> T_new -> operator review checkpoint -> D-2

D-2: T5, T6, T8 in any order -> T7 -> T9
```

## Migration Filename Plan

- `035_profit_fc_template_service_map.sql` - table DDL, indexes, and about 20 Orlando-spot-checked seed rows.
- `035a_profit_fc_client_primary_preparer.sql` - derived primary-preparer view from completed-task `raw->assignees[0]->name`.
- `035b_profit_sla_candidates_use_template_map.sql` - rebuild SLA candidate/state joins to use template map, primary preparer view, workflow status, and retained ILIKE fallback.
- `035c_profit_service_recognition_entity_type.sql` - add nullable entity-type metadata.
- `035d_profit_manual_recognition_pending_verdict.sql` - seed verdict/rules/candidate view/apply branch for stale recognition.
- `035e_profit_pipeline_run_failed_verdict.sql` - seed verdict/rules/candidate view/apply branch for failed/partial pipeline runs.
- `035f_profit_weekly_review_items_v0_7_d.sql` - rebuild visible verdict registry and queue UNION shape for all V0.7.D verdicts.
- `035g_profit_manual_invoice_pending_cleanup.sql` - stale manual-invoice cleanup transition branch, if not folded into `035d`/`035e` apply-function replacement.

Final numbering may compress if implementation finds fewer SQL object boundaries, but do not mix D-1 SLA foundation with new verdict taxonomy in the same migration.

## Quality Gates Inherited

- Run focused RED tests before implementation for every task.
- Run `pytest` or focused test modules after each task.
- Run `scripts/predeploy_smoke.sh` before every live migration apply.
- Perform live-data verification at each task gate: template-map coverage, primary-preparer coverage, SLA queue counts, verdict candidate counts, API totals, and representative row inspection.
- Run goal-backward verification before commit: start from Orlando's four known gaps plus two cleanup/new-verdict surfaces and prove each is addressed or explicitly deferred.
- Use independent audit between high-leverage tasks, especially code-reviewer subagent audit after T4 (`035b`) and after the transition-function replacement.
- Do not commit the plan file until the final ship commit pattern calls for it; through implementation it stays untracked.

## Task Breakdown

### Task 1: Live Data And FC API Surface Profiling

**Tier:** Tier 3 orchestrator-direct. COMPLETE in turn 032.

**Files:**
- Deliverable: `coordination/task-1-V0.7.D-data-profile.md`

- [x] **Step 1: Profile FC service mapping surface**

Finding: FC has no project-level service tags. Service mapping lives in `profit_fc_projects.template_id`.

- [x] **Step 2: Profile staff assignment surface**

Finding: task `user_name` is the completer, not assignee. Real assignee lives in completed-task `raw->assignees[0]->name`.

- [x] **Step 3: Profile active project/task availability**

Finding: all 143 open projects have zero open tasks, so active SLA routing cannot rely on open-task assignees.

- [x] **Step 4: Produce approved adjustment set**

Outcome: Orlando approved A1-A5, including template-map table, derived primary-preparer view, retained ILIKE fallback, and dropping W17 changes.

### Task 2: Template Service Map Migration

**Tier:** Tier 3 orchestrator-direct. SQL-only migration with operator seed spot-check.

**Files:**
- Create: `supabase/sql/035_profit_fc_template_service_map.sql`

- [ ] **Step 1: Draft seed rows**

Draft about 20 rows from Task 1's template-id-to-title analysis:

```sql
create table if not exists profit_fc_template_service_map (
  template_id text primary key,
  fc_tag_prefix text not null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profit_fc_template_service_map_fc_tag_prefix_idx
  on profit_fc_template_service_map (fc_tag_prefix);
```

Seed rows must be human-validated metadata, not generated content-specific logic.

- [ ] **Step 2: Orlando spot-check**

Before live apply, Orlando spot-checks the seed rows. Do not apply if any high-volume template maps to an uncertain prefix.

- [ ] **Step 3: Smoke and apply**

Run:

```bash
scripts/predeploy_smoke.sh supabase/sql/035_profit_fc_template_service_map.sql
```

Expected: PASS before live `psql` apply.

- [ ] **Step 4: Verify coverage baseline**

Live SQL should report map row count, project coverage by template_id, and active SLA candidate coverage via the map.

### Task 3: Primary Preparer View Migration

**Tier:** Tier 3 orchestrator-direct. SQL-only derived view.

**Files:**
- Create: `supabase/sql/035a_profit_fc_client_primary_preparer.sql`

- [ ] **Step 1: Create derived view**

Create `profit_fc_client_primary_preparer` from completed tasks in the last 365 days per `fc_client_id`, extracting non-null assignee names:

```sql
raw->'assignees'->0->>'name'
```

Pick the most frequent assignee per client by count, with deterministic tie-breaking.

- [ ] **Step 2: Smoke and apply**

Run:

```bash
scripts/predeploy_smoke.sh supabase/sql/035a_profit_fc_client_primary_preparer.sql
```

Expected: PASS before live `psql` apply.

- [ ] **Step 3: Verify SLA-client coverage**

Report count of clients with a derived preparer and percentage of active SLA candidate clients covered. Null preparer remains allowed and should route to `Unassigned`.

### Task 4: SLA Candidates Template-Map Rewrite

**Tier:** Tier 3 orchestrator-direct. SQL-only view rewrite; highest-leverage D-1 change.

**Files:**
- Create: `supabase/sql/035b_profit_sla_candidates_use_template_map.sql`
- Modify: `docs/data-contracts/sla-dashboard.md`
- Modify: `docs/data-contracts/weekly-review.md`

- [ ] **Step 1: Rebuild candidate joins**

Update `profit_sla_breached_candidates` to use:

```text
project.template_id -> profit_fc_template_service_map.fc_tag_prefix
recognition_rules.fc_tag LIKE fc_tag_prefix || '%'
```

Retain fallback:

```sql
project.title ILIKE '%' || split_part(service_name, ' ', 1) || '%'
```

The fallback is expected coverage for about 150 projects on small/long-tail templates.

- [ ] **Step 2: Wire derived preparer and workflow state**

Use `profit_fc_client_primary_preparer.primary_preparer_name` for `assigned_staff_name`, falling back to `Unassigned`. Keep workflow-status handling and state precedence:

```text
not_applicable > waiting_on_client > breached > at_risk > on_track
```

Exclude `waiting_on_client` from `SLA_BREACHED` candidates by default per OQ4.

- [ ] **Step 3: Smoke and verify**

Run:

```bash
scripts/predeploy_smoke.sh supabase/sql/035b_profit_sla_candidates_use_template_map.sql
```

Live verification must report:

- active SLA candidate rows cleared via template-map join
- active SLA candidate rows still using ILIKE fallback
- active SLA candidate rows with derived primary preparer
- active SLA candidate rows still `Unassigned`
- `waiting_on_client` row count where workflow tags exist

If template-map coverage is below 80%, expand the seed map before removing fallback. If coverage is at least 80%, keep the fallback as documented long-tail coverage.

- [ ] **Step 4: Code-reviewer audit**

Run code-reviewer subagent audit after `035b` lands. The audit should focus on SLA clearance semantics, fallback retention, `waiting_on_client` exclusion, and preparer null behavior.

- [ ] **Step 5: Mid-sprint operator review checkpoint**

Review D-1 live coverage with Orlando before D-2 starts.

### Task New: Service Catalog Entity-Type Metadata

**Tier:** Tier 3 orchestrator-direct. SQL-only nullable column add.

**Files:**
- Create: `supabase/sql/035c_profit_service_recognition_entity_type.sql`

- [ ] **Step 1: Add nullable metadata**

Add nullable `entity_type` to `profit_service_recognition_rules`. No seed in V0.7.D per OQ3 lock.

- [ ] **Step 2: Smoke and apply**

Run:

```bash
scripts/predeploy_smoke.sh supabase/sql/035c_profit_service_recognition_entity_type.sql
```

Expected: PASS before live `psql` apply.

- [ ] **Step 3: Verify schema**

Confirm the column exists and all current rows remain null until operator-managed metadata is intentionally seeded in a later task/slice.

### Task 5: `MANUAL_RECOGNITION_PENDING` Verdict

**Tier:** Tier 1 Codex. This adds a verdict, candidate view, transition-function branch, Weekly Review union fields, and API registry.

**Files:**
- Create: `supabase/sql/035d_profit_manual_recognition_pending_verdict.sql`
- Modify: `profit_api/weekly_review.py`
- Modify: backend tests for weekly review validation
- Modify: `docs/data-contracts/weekly-review.md`

- [ ] **Step 1: RED test**

Assert:

```text
MANUAL_RECOGNITION_PENDING is in profit_classification_verdicts
profit_manual_recognition_pending_candidates exists
profit_apply_classification_transitions includes manual_recognition_pending_detected
VISIBLE_VERDICT_CODES includes MANUAL_RECOGNITION_PENDING
```

Expected: FAIL.

- [ ] **Step 2: Implement candidate view**

Source from `profit_pipeline_stuck_recognition_triggers` using the existing 30-day threshold locked by OQ1. Candidate key:

```text
manual_recognition_pending:<revenue_event_key>
```

Clearance signal: the same `revenue_event_key` no longer has `recognition_status like 'pending_%'`, or has nonzero recognized amount / recognition period.

- [ ] **Step 3: GREEN and live verify**

Run focused tests and live count:

```sql
select count(*) from profit_manual_recognition_pending_candidates;
select verdict_code, count(*) from profit_weekly_review_items group by 1 order by 1;
```

### Task 6: `PIPELINE_RUN_FAILED` Verdict

**Tier:** Tier 1 Codex. This adds a system-health verdict and transition branch.

**Files:**
- Create: `supabase/sql/035e_profit_pipeline_run_failed_verdict.sql`
- Modify: `profit_api/weekly_review.py`
- Modify: backend tests for weekly review validation
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/data-contracts/sla-dashboard.md`

- [ ] **Step 1: RED test**

Assert:

```text
PIPELINE_RUN_FAILED is in profit_classification_verdicts
profit_pipeline_run_failed_candidates exists
PIPELINE_RUN_FAILED is visible in Weekly Review registry
success-after-failure clearance branch exists
```

Expected: FAIL.

- [ ] **Step 2: Implement candidate view**

Read `profit_pipeline_runs` where `status='failed'` or where `status='partial'` and `summary.total_steps_failed > 0` per G5/OQ6. Candidate key:

```text
pipeline_run_failed:<pipeline_run_id>
```

Evidence summary must include `pipeline_run_id`, `status`, `started_at`, `finished_at`, `summary.error_summary`, and failed step names when available.

- [ ] **Step 3: Implement clearance**

Auto-supersede active `PIPELINE_RUN_FAILED` rows when a later run has `status='success'` and `finished_at > failed.finished_at`. Operator Mark reviewed remains review state only.

- [ ] **Step 4: Verify**

Live SQL should show known W16 failure rows if still present, or zero candidates after a successful pipeline run.

### Task 7: Weekly Review API/UI Registry And Rendering

**Tier:** Tier 2 CC subagent. This should be mostly single-route React/API registry work after SQL shape is stable; escalate to Tier 1 if the queue view shape changes across more than three backend files.

**Files:**
- Modify: `profit_api/weekly_review.py`
- Modify: `app/frontend/src/routes/WeeklyReview.jsx`
- Modify: `app/frontend/src/routes/WeeklyReview.css`
- Modify: relevant frontend/backend tests
- Create: `supabase/sql/035f_profit_weekly_review_items_v0_7_d.sql`

- [ ] **Step 1: RED tests**

Backend: unsupported verdict validation should allow all four visible V0.7.D-era verdicts. Frontend: each new verdict code renders a label, age, action URL, and evidence fields without crashing.

- [ ] **Step 2: Rebuild queue UNION**

Append new columns rather than reordering existing columns. Existing V0.7.B.4 attribution columns must remain stable.

- [ ] **Step 3: UI rendering**

Use compact verdict-specific details:

```text
MANUAL_RECOGNITION_PENDING: invoice/event/client/service/amount/age
PIPELINE_RUN_FAILED: run id/status/finished_at/error summary
SLA_BREACHED: existing SLA details with staff/status now populated
MANUAL_INVOICE_PENDING: unchanged
```

Use the single `assigned_staff_name` field sourced from `profit_fc_client_primary_preparer`; OQ8 is closed as moot.

- [ ] **Step 4: Verify**

Run:

```bash
pytest tests -q
npm run build
```

If frontend build cannot run in the environment, document the blocker and run static backend tests.

### Task 8: Stale `MANUAL_INVOICE_PENDING` Cleanup

**Tier:** Tier 1 Codex. Apply-function CTE add. This task is parallel-eligible with T5/T6 after T1 because it depends only on Task 1 context and the existing V0.7.A apply-function shape in `029_profit_manual_invoice_pending_verdict.sql`.

**Files:**
- Create: `supabase/sql/035g_profit_manual_invoice_pending_cleanup.sql`
- Modify: transition SQL tests
- Modify: `docs/data-contracts/fulfillment-classifications.md`

- [ ] **Step 1: RED test**

Assert active `MANUAL_INVOICE_PENDING` rows are no-op superseded by `manual_invoice_no_active_manual_trigger_services` when no active agreement/manual-trigger service source remains, according to OQ5.

- [ ] **Step 2: Implement generic cleanup**

Use data-driven predicates only:

```text
agreement missing, agreement not active, or active agreement has no current manual-trigger service summary
```

Set `superseded_at` and leave `superseded_by_classification_id` null, matching the V0.7.A `manual_invoice_agreement_terminated` no-op resolution pattern.

Do not name clients or services.

- [ ] **Step 3: Verify**

Dry-run apply function first, inspect evidence summaries, then live apply only after Orlando approves if rows would supersede.

### Task 9: Docs, Tech-Debt Sweep, And Ship Verification

**Tier:** Tier 3 orchestrator-direct. Docs, live verification, and deploy coordination.

**Files:**
- Modify: `docs/tech-debt.md`
- Modify: `docs/data-contracts/weekly-review.md`
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/data-contracts/sla-dashboard.md`
- Modify: `docs/data-contracts/financial-cents-sync.md` if the template-map metadata contract belongs there; otherwise document only in SLA/Weekly Review contracts.

- [ ] **Step 1: Docs update**

Close V0.7.D-folded tech-debt entries only when live verification proves them fixed. Move unresolved decisions to deferred sections with explicit next slice names.

Document Payroll Service and Year End Accounting Close in `docs/data-contracts/weekly-review.md` Deferred Gaps as excluded from V0.7.D because they lack `default_sla_day`. Do not seed defaults and do not add a `BILLING_SETUP_GAP` verdict in this slice.

- [ ] **Step 2: Predeploy smoke**

Run `scripts/predeploy_smoke.sh` with every V0.7.D migration before live apply. Any failure blocks deploy.

- [ ] **Step 3: Goal-backward verification**

Verify:

```text
staff routing no longer universally Unassigned when completed-task assignee history exists
latest_workflow_status populated where the template-map bridge matches
SLA clearance uses template-map join as primary path while retaining documented title fallback for long-tail templates
1120 C/S behavior follows metadata, not service-name parsing
manual recognition pending rows surface or count is explainably zero
pipeline failed/partial rows surface or count is explainably zero
stale manual-invoice rows are superseded or dry-run evidence is reviewed
```

- [ ] **Step 4: Commit**

Commit implementation and docs. Keep this plan untracked until the ship-commit convention says to fold it in.

## Tier Mix

- Tier 1 Codex: Tasks 5, 6, 8 = 3 tasks.
- Tier 2 CC subagent: Task 7 = 1 task.
- Tier 3 orchestrator-direct: Tasks 1, 2, 3, 4, T_new, 9 = 6 tasks.

Task 7 is the only plausible Tier 2 because frontend rendering is scoped and should stay below about 200 lines if SQL shape is stable. Tasks 5, 6, and 8 are Tier 1 because each touches transition functions or multi-file backend contracts. Tasks 2, 3, 4, and T_new are Tier 3 after the turn 032 downgrade because they are small SQL-only migrations with no workflow or Python changes.

## Tech-Debt Sweep

Folded into V0.7.D:

- FC template service map.
- FC client primary-preparer derivation.
- SLA workflow-status / `waiting_on_client` repair.
- SLA staff routing repair.
- 1120 C/S entity-type disambiguation.
- Manual recognition stuck queue.
- Pipeline failure queue.
- Stale `MANUAL_INVOICE_PENDING` cleanup.

Deferred elsewhere:

- Blank Payroll Service / Year End Accounting Close target handling to V0.7.G polish because those services lack `default_sla_day` and V0.7.D will not seed defaults.
- Anchor backfill verdicts to V0.7.C.
- M&A practice routing to V0.7.E.
- Weekly Review visibility/affordance polish to V0.7.G.
- AI-agent supplement layer to post-V0.7.
- Per-service manual invoice rewrite until operator demand proves it necessary.
- Anchor invoice line-item parsing for per-service clearance.
