-- Migration 034c: Expose attribution columns in Weekly Review queue view
-- V0.7.B.4 T7 step 1 — frontend prerequisite for label badges + grouping
--
-- profit_weekly_review_items is rebuilt to surface 3 new columns from the
-- SLA candidate view's attribution layer:
--   - label                          — the parsed label text (e.g., "Lee Wolfson")
--   - label_unresolved               — boolean; true when label doesn't resolve to FC client
--   - agreement_client_business_name — the source agreement holder (for "via {X}" badge)
--
-- Manual rows null-cast these columns (V0.7.A manual candidate view doesn't
-- yet use attribution; that's a future T5 if needed).
--
-- Column order: preserves the existing 28 columns then appends the 3 new ones,
-- so CREATE OR REPLACE VIEW is safe (no column rename).
--
-- Depends on: 030a (prior UNION view), 034b (SLA candidate view with attribution).

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
        when verdict_code = 'SLA_BREACHED' and breach_state = 'breached' then 1
        when verdict_code = 'SLA_BREACHED' and breach_state = 'at_risk'  then 2
        when verdict_code = 'MANUAL_INVOICE_PENDING'                     then 3
        else 4
      end asc,
      coalesce(breach_age_days, age_days) desc nulls last,
      estimated_annual_revenue desc nulls last,
      client_name asc nulls last
  )::integer as sort_rank,
  -- V0.7.B.4 T7 NEW attribution columns (appended):
  unioned.label,
  unioned.label_unresolved,
  unioned.agreement_client_business_name
from (
  -- Manual-invoice branch (no attribution yet; nulls)
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
    -- V0.7.B.4 T7 NEW (NULL for manual branch):
    null::text as label,
    null::boolean as label_unresolved,
    null::text as agreement_client_business_name
  from profit_manual_invoice_pending_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id

  union all

  -- SLA branch (passes attribution columns through from 034b candidate view)
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
    -- V0.7.B.4 T7 NEW (from candidate view):
    candidate.label,
    candidate.label_unresolved,
    candidate.agreement_client_business_name
  from profit_sla_breached_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id
) unioned;

comment on view profit_weekly_review_items is
  'V0.7.B.4 T7: Weekly Review queue view with attribution columns exposed (label, label_unresolved, agreement_client_business_name) for frontend label-badge rendering and parent-grouping UX. Same UNION ALL shape as 030a; new columns appended at end. Manual branch null-casts attribution columns (V0.7.A candidates don''t go through attribution layer yet). SLA branch passes through from profit_sla_breached_candidates which sources from profit_anchor_services_attributed.';
