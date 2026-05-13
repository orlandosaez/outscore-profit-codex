-- Migration 036c: Weekly Review UNION extension for V0.7.D-2 verdicts
--
-- Adds 2 new branches to profit_weekly_review_items UNION:
--   - MANUAL_RECOGNITION_PENDING (from 036's candidate view)
--   - PIPELINE_RUN_FAILED (from 036a's candidate view)
--
-- Preserves V0.7.B.4 column order (CREATE OR REPLACE VIEW constraint).
-- Outer view columns 1-30 stay positionally identical to 034c:
--   1-26: base columns (classification_id ... age_days)
--   27:   sort_rank
--   28-30: label, label_unresolved, agreement_client_business_name
--
-- Sort priority CASE updated to include new verdicts:
--   1: PIPELINE_RUN_FAILED (system health — if pipeline fails, the rest of
--      the queue is unreliable until it's fixed)
--   2: SLA_BREACHED + breached
--   3: SLA_BREACHED + at_risk
--   4: MANUAL_INVOICE_PENDING (operator action — issue invoice)
--   5: MANUAL_RECOGNITION_PENDING (operator action — approve recognition)
--   6: else
--
-- Also inserts the 2 new verdict codes into profit_weekly_review_visible_verdicts
-- so the UI surfaces them. PIPELINE_RUN_FAILED gets sort_order 5 (highest)
-- and MANUAL_RECOGNITION_PENDING gets 30 (after SLA_BREACHED at 20).
--
-- No content-specific rules. New branches NULL-cast columns that don't apply
-- to system-level (PIPELINE_RUN_FAILED has no fc_client_id, no service) or
-- recognition-level (MANUAL_RECOGNITION_PENDING has no SLA target_date) work.
--
-- Depends on:
--   - 034c (prior UNION view definition; this CREATE OR REPLACE extends it)
--   - 036 (MANUAL_RECOGNITION_PENDING candidate view)
--   - 036a (PIPELINE_RUN_FAILED candidate view)
--   - 036b (apply function CTEs already in place to insert classifications)
-- Predeploy_smoke.sh gate must pass before live apply.

-- =============================================================================
-- Register the 2 new verdicts in the visible-verdicts table
-- =============================================================================
insert into profit_weekly_review_visible_verdicts (verdict_code, sort_order)
values
  ('PIPELINE_RUN_FAILED',         5),
  ('MANUAL_RECOGNITION_PENDING', 30)
on conflict (verdict_code) do update set
  sort_order = excluded.sort_order;

-- =============================================================================
-- Rebuild profit_weekly_review_items with 4-branch UNION
-- =============================================================================
drop view if exists profit_weekly_review_items;

create or replace view profit_weekly_review_items as
select
  unioned.classification_id,
  unioned.verdict_code,
  unioned.item_type,
  unioned.fc_client_id,
  unioned.anchor_relationship_id,
  unioned.client_name,
  unioned.action_url,
  unioned.reviewed_at,
  unioned.snoozed_until,
  unioned.operator_id,
  unioned.practice_id,
  unioned.invoice_state,
  unioned.estimated_annual_revenue,
  unioned.service_name,
  unioned.macro_service_type,
  unioned.fc_tag,
  unioned.breach_state,
  unioned.breach_age_days,
  unioned.work_age_days,
  unioned.target_date,
  unioned.target_sla_day,
  unioned.assigned_staff_name,
  unioned.staff_source,
  unioned.latest_workflow_status,
  unioned.fc_task_id,
  unioned.fc_project_id,
  unioned.age_days,
  row_number() over (
    order by
      case
        when verdict_code = 'PIPELINE_RUN_FAILED'                       then 1
        when verdict_code = 'SLA_BREACHED' and breach_state = 'breached' then 2
        when verdict_code = 'SLA_BREACHED' and breach_state = 'at_risk'  then 3
        when verdict_code = 'MANUAL_INVOICE_PENDING'                     then 4
        when verdict_code = 'MANUAL_RECOGNITION_PENDING'                 then 5
        else 6
      end asc,
      coalesce(breach_age_days, age_days) desc nulls last,
      estimated_annual_revenue desc nulls last,
      client_name asc nulls last
  )::integer as sort_rank,
  unioned.label,
  unioned.label_unresolved,
  unioned.agreement_client_business_name
from (
  -- Manual-invoice branch
  select
    candidate.classification_id,
    candidate.verdict_code,
    candidate.verdict_code as item_type,
    candidate.fc_client_id,
    candidate.anchor_relationship_id,
    candidate.client_name,
    candidate.action_url,
    state.reviewed_at,
    state.snoozed_until,
    coalesce(state.operator_id, 'orlando') as operator_id,
    state.practice_id,
    candidate.invoice_state,
    candidate.estimated_annual_revenue,
    candidate.service_name,
    null::text as macro_service_type,
    null::text as fc_tag,
    null::text as breach_state,
    null::integer as breach_age_days,
    null::integer as work_age_days,
    null::date as target_date,
    null::integer as target_sla_day,
    null::text as assigned_staff_name,
    null::text as staff_source,
    null::text as latest_workflow_status,
    null::bigint as fc_task_id,
    null::bigint as fc_project_id,
    candidate.age_days,
    null::text as label,
    null::boolean as label_unresolved,
    null::text as agreement_client_business_name
  from profit_manual_invoice_pending_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id

  union all

  -- SLA branch
  select
    candidate.classification_id,
    candidate.verdict_code,
    candidate.verdict_code as item_type,
    candidate.fc_client_id,
    candidate.anchor_relationship_id,
    candidate.client_name,
    candidate.action_url,
    state.reviewed_at,
    state.snoozed_until,
    coalesce(state.operator_id, 'orlando') as operator_id,
    state.practice_id,
    null::text as invoice_state,
    null::numeric as estimated_annual_revenue,
    candidate.service_name,
    candidate.macro_service_type,
    candidate.fc_tag,
    candidate.breach_state,
    candidate.breach_age_days,
    candidate.work_age_days,
    candidate.target_date,
    candidate.target_sla_day,
    candidate.assigned_staff_name,
    candidate.staff_source,
    candidate.latest_workflow_status,
    candidate.fc_task_id,
    candidate.fc_project_id,
    candidate.age_days,
    candidate.label,
    candidate.label_unresolved,
    candidate.agreement_client_business_name
  from profit_sla_breached_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id

  union all

  -- Manual recognition pending branch (V0.7.D-2 T5)
  -- Source: profit_manual_recognition_pending_candidates (migration 036)
  -- Has fc_client_id, service_name, macro_service_type, estimated_annual_revenue.
  -- No SLA columns (breach_state, target_date, fc_tag), no attribution columns.
  select
    candidate.classification_id,
    candidate.verdict_code,
    candidate.verdict_code as item_type,
    candidate.fc_client_id,
    candidate.anchor_relationship_id,
    candidate.client_name,
    candidate.action_url,
    state.reviewed_at,
    state.snoozed_until,
    coalesce(state.operator_id, 'orlando') as operator_id,
    state.practice_id,
    null::text as invoice_state,
    candidate.estimated_annual_revenue,
    candidate.service_name,
    candidate.macro_service_type,
    candidate.fc_tag,
    null::text as breach_state,
    null::integer as breach_age_days,
    null::integer as work_age_days,
    null::date as target_date,
    null::integer as target_sla_day,
    null::text as assigned_staff_name,
    null::text as staff_source,
    null::text as latest_workflow_status,
    null::bigint as fc_task_id,
    null::bigint as fc_project_id,
    candidate.age_days,
    null::text as label,
    null::boolean as label_unresolved,
    null::text as agreement_client_business_name
  from profit_manual_recognition_pending_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id

  union all

  -- Pipeline run failed branch (V0.7.D-2 T6)
  -- Source: profit_pipeline_run_failed_candidates (migration 036a)
  -- System-level verdict. NULL fc_client_id, NULL service columns, NULL
  -- attribution. client_name is synthesized as 'System: Pipeline <run_id>'.
  -- estimated_annual_revenue stays null (not money-denominated).
  select
    candidate.classification_id,
    candidate.verdict_code,
    candidate.verdict_code as item_type,
    candidate.fc_client_id,
    candidate.anchor_relationship_id,
    candidate.client_name,
    candidate.action_url,
    state.reviewed_at,
    state.snoozed_until,
    coalesce(state.operator_id, 'orlando') as operator_id,
    state.practice_id,
    null::text as invoice_state,
    null::numeric as estimated_annual_revenue,
    candidate.service_name,
    candidate.macro_service_type,
    candidate.fc_tag,
    null::text as breach_state,
    null::integer as breach_age_days,
    null::integer as work_age_days,
    null::date as target_date,
    null::integer as target_sla_day,
    null::text as assigned_staff_name,
    null::text as staff_source,
    null::text as latest_workflow_status,
    null::bigint as fc_task_id,
    null::bigint as fc_project_id,
    candidate.age_days,
    null::text as label,
    null::boolean as label_unresolved,
    null::text as agreement_client_business_name
  from profit_pipeline_run_failed_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id
) unioned;

comment on view profit_weekly_review_items is
  'V0.7.D-2 (036c): Weekly Review queue with 4 verdict branches: MANUAL_INVOICE_PENDING (V0.7.A), SLA_BREACHED (V0.7.B + attribution V0.7.B.4 + FC-custom-fields V0.7.D-1.1), MANUAL_RECOGNITION_PENDING (V0.7.D-2 T5), PIPELINE_RUN_FAILED (V0.7.D-2 T6). Column order preserved (30 cols, V0.7.B.4 contract). Sort priority: PIPELINE_RUN_FAILED first (system health), then SLA breaches, then operator-action verdicts.';
