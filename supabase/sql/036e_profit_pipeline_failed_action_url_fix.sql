-- Migration 036e: Fix PIPELINE_RUN_FAILED action_url (V0.7.D-2 hotfix)
--
-- Operator feedback 2026-05-13: clicking "View run details" on a pipeline
-- failure row routed to /admin/audit/pipeline-runs/<uuid> which n8n's URL
-- routing intercepts (since /admin/... is not prefixed with /profit/, nginx
-- routes it to n8n's admin surface). Result: operator lands on n8n's 404.
--
-- The correct internal route lives in the React app at /profit/admin/pipeline/<uuid>
-- (App.jsx Route path="/admin/pipeline/:pipelineRunId" + basename="/profit/").
--
-- CREATE OR REPLACE the candidate view with the corrected action_url.
-- Other columns unchanged.

create or replace view profit_pipeline_run_failed_candidates as
with latest_success as (
  select max(finished_at) as last_success_at
  from profit_pipeline_runs
  where status = 'success' and finished_at is not null
),
failed_runs as (
  select
    run.pipeline_run_id,
    run.run_source,
    run.status,
    run.started_at,
    run.finished_at,
    run.summary,
    run.triggered_by
  from profit_pipeline_runs run
  cross join latest_success ls
  where (
      run.status = 'failed'
      or (
        run.status = 'partial'
        and coalesce((run.summary->>'total_steps_failed')::int, 0) > 0
      )
    )
    and (ls.last_success_at is null or run.started_at > ls.last_success_at)
),
failed_steps as (
  select
    s.pipeline_run_id,
    string_agg(s.step_name, ', ' order by s.step_order, s.step_name)
      filter (where s.status = 'failed') as failed_step_names
  from profit_pipeline_run_steps s
  group by s.pipeline_run_id
),
active_pipeline_classification as (
  select distinct on (split_part(classification.source_audit_row_hash, ':', 2))
    classification.classification_id,
    classification.classified_at,
    classification.verdict_code,
    split_part(classification.source_audit_row_hash, ':', 2) as pipeline_run_id
  from profit_classifications classification
  where classification.verdict_code = 'PIPELINE_RUN_FAILED'
    and classification.superseded_at is null
    and classification.source_audit_file = 'system:pipeline_run_failed'
  order by
    split_part(classification.source_audit_row_hash, ':', 2),
    classification.classified_at desc,
    classification.classification_id desc
)
select
  active_pipeline_classification.classification_id,
  active_pipeline_classification.classified_at,
  coalesce(active_pipeline_classification.verdict_code, 'PIPELINE_RUN_FAILED') as verdict_code,
  null::bigint as fc_client_id,
  null::text as anchor_relationship_id,
  null::text as agreement_id,
  'System: Pipeline ' || run.pipeline_run_id::text as client_name,
  null::text as service_name,
  null::text as macro_service_type,
  null::text as fc_tag,
  null::text as invoice_state,
  null::text as breach_state,
  greatest(
    0,
    current_date - coalesce(active_pipeline_classification.classified_at::date, run.finished_at::date, run.started_at::date, current_date)
  )::integer as age_days,
  null::integer as breach_age_days,
  null::integer as work_age_days,
  null::date as target_date,
  null::integer as target_sla_day,
  null::text as assigned_staff_name,
  null::text as staff_source,
  null::text as latest_workflow_status,
  null::text as fc_task_id,
  null::text as fc_project_id,
  null::numeric as estimated_annual_revenue,
  -- V0.7.D-2 hotfix 036e: use /profit/admin/pipeline/<uuid> (internal React route)
  -- instead of /admin/audit/pipeline-runs/<uuid> (which nginx routes to n8n).
  '/profit/admin/pipeline/' || run.pipeline_run_id::text as action_url,
  run.pipeline_run_id,
  run.status,
  run.started_at,
  run.finished_at,
  run.summary,
  run.summary->>'error_summary' as error_summary,
  failed_steps.failed_step_names,
  'pipeline_run_failed:' || run.pipeline_run_id::text as source_audit_row_hash
from failed_runs run
left join failed_steps on failed_steps.pipeline_run_id = run.pipeline_run_id
left join active_pipeline_classification on active_pipeline_classification.pipeline_run_id = run.pipeline_run_id::text;

comment on view profit_pipeline_run_failed_candidates is
  'V0.7.D-2 + hotfix 036e: PIPELINE_RUN_FAILED candidate view. action_url corrected to /profit/admin/pipeline/<uuid> (internal React route, basename /profit/ aware) instead of /admin/audit/pipeline-runs/<uuid> which nginx routes to n8n.';
