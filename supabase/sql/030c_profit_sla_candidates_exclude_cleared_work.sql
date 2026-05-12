-- Migration 030c: SLA candidate view excludes items where matching FC work is complete
-- V0.7.B.1 T6a — Correctness + Trust Restoration (deeper fix surfaced during T6 deploy)
--
-- Bug discovered during V0.7.B.1 T6 deploy verification:
-- After migration 030b's relaxed ILIKE successfully cleared 25 SLA_BREACHED
-- classifications via sla_task_complete, the candidate view STILL surfaced
-- those 25 items because `profit_sla_service_items.sla_state` doesn't flip
-- to 'on_track' or 'not_applicable' when an FC task is completed (it flips
-- only when revenue is recognized). Result: 25 candidates with NULL
-- classification_id stayed in the queue view, and the NEXT
-- apply_classification_transitions run would re-insert them as new
-- SLA_BREACHED classifications — churn.
--
-- Fix: extend profit_sla_breached_candidates with an additional WHERE
-- clause that excludes service items where the matching FC task is
-- complete OR the matching FC project is closed. The match predicate
-- mirrors the apply function's clearance branches (030b) bit-for-bit:
-- service-tag join when available, project_title ILIKE on the first
-- service_name token as fallback.
--
-- This is the ONLY change vs migration 030 / 030b. Function definitions
-- are not touched. Candidate-view column shape preserved.
--
-- Live verification: this migration passed scripts/predeploy_smoke.sh
-- (psql --single-transaction BEGIN/ROLLBACK) before commit per the
-- V0.7.B.1 T5 quality gate.
--
-- Depends on: 030 (source view definition copied verbatim, only
-- source_items CTE WHERE clause extended). Independent of 030b.
-- Does NOT apply the migration to any DB — deploy gate is V0.7.B.1 T6.

create or replace view profit_sla_breached_candidates as
with source_items as (
  select distinct on (item.anchor_relationship_id, item.service_name)
    item.anchor_relationship_id,
    item.anchor_client_business_name,
    item.fc_client_id,
    item.fc_client_name,
    item.service_name,
    item.macro_service_type,
    item.fc_tag,
    item.default_sla_day,
    item.target_sla_day,
    item.target_date,
    item.age_days,
    item.latest_workflow_status,
    item.assigned_staff_name,
    item.staff_source,
    item.sla_state,
    'sla_breached:' || item.fc_client_id::text || ':' || item.service_name as source_audit_row_hash
  from profit_sla_service_items item
  where item.sla_state in ('breached', 'at_risk')
    and item.default_sla_day is not null
    and item.target_sla_day is not null
    and item.target_date is not null
    -- V0.7.B.1 T6a: exclude items where matching FC task is complete OR
    -- matching FC project is closed. Predicate mirrors 030b clearance
    -- branches; uses split_part(service_name, ' ', 1) for project_title
    -- ILIKE fallback because the tag_type='service' bridge is empty
    -- pending V0.7.D FC sync expansion.
    and not exists (
      select 1
      from profit_fc_tasks task
      where task.fc_client_id = item.fc_client_id
        and (task.is_completed = true or task.completed_at is not null)
        and (
          task.fc_project_id in (
            select service_tag.fc_project_id
            from profit_fc_project_tags service_tag
            where service_tag.tag_type = 'service'
              and service_tag.tag_name = item.fc_tag
          )
          or task.project_title ilike '%' || split_part(item.service_name, ' ', 1) || '%'
        )
    )
    and not exists (
      select 1
      from profit_fc_projects project
      where project.fc_client_id = item.fc_client_id
        and (project.is_closed = true or project.closed_at is not null)
        and (
          project.fc_project_id in (
            select service_tag.fc_project_id
            from profit_fc_project_tags service_tag
            where service_tag.tag_type = 'service'
              and service_tag.tag_name = item.fc_tag
          )
          or project.title ilike '%' || split_part(item.service_name, ' ', 1) || '%'
        )
    )
  order by
    item.anchor_relationship_id,
    item.service_name,
    item.target_date asc nulls last,
    item.fc_client_id nulls last
),
active_sla_classification as (
  select distinct on (classification.fc_client_id, split_part(classification.source_audit_row_hash, ':', 3))
    classification.classification_id,
    classification.classified_at,
    classification.verdict_code,
    classification.fc_client_id,
    split_part(classification.source_audit_row_hash, ':', 3) as service_name,
    classification.source_audit_row_hash
  from profit_classifications classification
  where classification.verdict_code = 'SLA_BREACHED'
    and classification.superseded_at is null
    and classification.source_audit_file = 'system:sla_breached'
  order by
    classification.fc_client_id,
    split_part(classification.source_audit_row_hash, ':', 3),
    classification.classified_at desc,
    classification.classification_id desc
)
select
  active_sla_classification.classification_id,
  active_sla_classification.classified_at,
  coalesce(active_sla_classification.verdict_code, 'SLA_BREACHED') as verdict_code,
  item.fc_client_id,
  item.anchor_relationship_id,
  item.anchor_relationship_id as agreement_id,
  coalesce(item.fc_client_name, item.anchor_client_business_name) as client_name,
  item.service_name,
  item.macro_service_type,
  item.fc_tag,
  item.sla_state as breach_state,
  case
    when active_sla_classification.classified_at is null then null::integer
    else greatest(current_date - active_sla_classification.classified_at::date, 0)::integer
  end as age_days,
  greatest(current_date - item.target_date::date, 0)::integer as breach_age_days,
  item.age_days as work_age_days,
  item.target_date,
  item.target_sla_day,
  item.assigned_staff_name,
  item.staff_source,
  item.latest_workflow_status,
  open_task.fc_task_id,
  open_project.fc_project_id,
  coalesce(
    'https://app.financial-cents.com/tasks/' || open_task.fc_task_id,
    'https://app.financial-cents.com/projects/' || open_project.fc_project_id,
    'https://app.sayanchor.com/home/relationship/' || item.anchor_relationship_id || '/agreement'
  ) as action_url
from source_items item
left join active_sla_classification
  on active_sla_classification.fc_client_id = item.fc_client_id
 and active_sla_classification.service_name = item.service_name
left join lateral (
  select task.fc_task_id
  from profit_fc_tasks task
  where task.fc_client_id = item.fc_client_id
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
  order by task.due_date nulls last, task.updated_at desc nulls last, task.fc_task_id
  limit 1
) open_task on true
left join lateral (
  select project.fc_project_id
  from profit_fc_projects project
  join profit_fc_project_tags service_tag
    on service_tag.fc_project_id = project.fc_project_id
   and service_tag.tag_type = 'service'
   and service_tag.tag_name = item.fc_tag
  where project.fc_client_id = item.fc_client_id
    and coalesce(project.is_closed, false) = false
    and project.closed_at is null
  order by project.due_date nulls last, project.updated_at desc nulls last, project.fc_project_id
  limit 1
) open_project on true;

comment on view profit_sla_breached_candidates is
  'V0.7.B.1 T6a refinement: candidate view excludes items where matching FC task is complete or matching FC project is closed (mirrors apply function clearance branches). Eliminates the churn pattern where superseded SLA_BREACHED classifications would be re-detected on the next pipeline run. Other V0.7.B contract: source_audit_row_hash key sla_breached:<fc_client_id>:<service_name> for active classification dedupe. action_url falls back FC task -> FC project -> Anchor; Task 1 found zero open FC tasks across sampled clients, so FC-task tier is unreachable in current data. waiting_on_client + staff fallback + 1120 entity_type all deferred to V0.7.D.';
