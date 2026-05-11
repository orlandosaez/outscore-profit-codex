-- Migration 030a: Weekly Review SLA UNION extension
-- V0.7.B — Add SLA_BREACHED rows to the Weekly Review queue view.
--
-- Depends on:
--   029a (profit_weekly_review_item_state, visible-verdicts registry, queue view)
--   030  (profit_sla_breached_candidates)
--
-- Does NOT apply the migration to any DB — deploy gate is Task 8.


-- ────────────────────────────────────────────────────────────────
-- 1. Register SLA_BREACHED in the Weekly Review visible-verdicts registry
-- ────────────────────────────────────────────────────────────────

insert into profit_weekly_review_visible_verdicts (verdict_code, sort_order)
values ('SLA_BREACHED', 20)
on conflict (verdict_code) do update set sort_order = excluded.sort_order;


-- ────────────────────────────────────────────────────────────────
-- 2. Weekly Review Items Queue View
--    Two-source UNION ALL:
--      - MANUAL_INVOICE_PENDING candidates from profit_manual_invoice_pending_candidates
--      - SLA_BREACHED candidates from profit_sla_breached_candidates
--
--    Manual rows retain the V0.7.A manual-invoice output contract. The
--    service_name column is common to both branches (concatenated manual
--    service names for MANUAL_INVOICE_PENDING rows; single SLA service name
--    for SLA_BREACHED rows). SLA-only columns are NULL-cast on manual rows;
--    manual-only columns are NULL-cast on SLA rows.
--
--    sort_rank is computed over the full union, not per source.
-- ────────────────────────────────────────────────────────────────

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
  )::integer as sort_rank
from (
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
    candidate.age_days
  from profit_manual_invoice_pending_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id

  union all

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
    candidate.age_days
  from profit_sla_breached_candidates candidate
  inner join profit_weekly_review_visible_verdicts visible
    on visible.verdict_code = candidate.verdict_code
  left join profit_weekly_review_item_state state
    on state.classification_id = candidate.classification_id
) unioned;

comment on view profit_weekly_review_items is
  'Weekly Review queue view. Contract: two-source UNION ALL of profit_manual_invoice_pending_candidates and profit_sla_breached_candidates, each filtered by an INNER JOIN to profit_weekly_review_visible_verdicts and enriched by a LEFT JOIN to profit_weekly_review_item_state on classification_id. Common columns include classification identity, verdict/item type, client/relationship display fields, action_url, review state, operator_id, nullable practice_id, and age_days. service_name is common to both branches (concatenated manual services for MANUAL_INVOICE_PENDING; single SLA service for SLA_BREACHED). Manual-only columns are invoice_state and estimated_annual_revenue; manual rows return NULL for SLA columns. SLA-only columns include macro_service_type, fc_tag, breach_state, breach_age_days, work_age_days, target_date, target_sla_day, assigned_staff_name, staff_source, latest_workflow_status, fc_task_id, and fc_project_id; SLA rows return NULL for manual-only columns. sort_rank is computed across the full union: SLA breached first, SLA at_risk second, manual-invoice third, then coalesced breach_age_days/age_days descending, estimated_annual_revenue descending, and client_name ascending. practice_id remains nullable until V0.7.E adds multi-practice routing.';
