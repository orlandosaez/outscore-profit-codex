-- Migration 031: SLA candidate view encodes the 1040-on-business structural rule
-- V0.7.B.3 (revised) — encode domain truth in SQL, not in operator clicks
--
-- Problem: post-V0.7.B.1 deploy verification, 16 of 40 active SLA queue rows
-- (40%) are `1040 *` services on LLC/Inc/Corp/LLP/PA business clients. These
-- are structurally wrong: 1040 = individual personal return; LLC/Inc/Corp/LLP/PA
-- = business entity. The actual 1040 work happens on the owner's separate
-- individual FC client (per docs/data-references and the user's
-- fc_client_hierarchy.md memory). No SQL predicate based on task/project
-- completion can resolve this, because the completed 1040 task lives under a
-- different fc_client_id than the LLC SLA row.
--
-- Original V0.7.B.3 design proposed a Reclassify button + override table
-- requiring the operator to click 16 times. Orlando push-back (2026-05-12):
-- "I shouldn't have to tell you what the data already knows." Correct.
-- This is a domain rule, not an operator task.
--
-- Rule encoded: 1040 services on business-suffix clients are excluded from
-- the SLA candidate view. The candidate view's filter `item.service_name
-- ILIKE '1040%'` paired with `coalesce(item.fc_client_name,
-- item.anchor_client_business_name) ~* '(LLC|Inc\.?|Corp\.?|LLP|PA)\s*$'`
-- removes them.
--
-- Pattern is anchored at end-of-name (regex `$`) to avoid false positives
-- (e.g., "Pacific" matching naively for "PA"). Case-insensitive.
--
-- Preserved from 030c: completed-FC-task exclusion + closed-FC-project
-- exclusion (mirrors apply function clearance branches).
--
-- Edge case acknowledged: a single-member LLC that elected disregarded-entity
-- treatment legitimately files 1040 under the LLC. Current data has zero such
-- cases. If they appear, we add an explicit exception or build the long-tail
-- Reclassify affordance (V0.7.B.4, deferred).
--
-- Live verification: this migration passed scripts/predeploy_smoke.sh
-- (psql --single-transaction BEGIN/ROLLBACK) before commit per V0.7.B.1 T5.
--
-- Depends on: 030c (source view definition copied verbatim, source_items CTE
-- WHERE clause extended with the structural-rule filter). Function definitions
-- and 031a/030a are untouched. Candidate-view column shape preserved.
-- Does NOT apply the migration to any DB — deploy gate runs predeploy_smoke
-- then psql -f at the end of V0.7.B.3.

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
    -- V0.7.B.3 structural rule: exclude 1040* services on business-suffix
    -- clients. 1040 = individual personal return; LLC/Inc/Corp/LLP/PA = business
    -- entity. The actual 1040 work is on the owner's separate individual FC
    -- client. Pattern anchored at end-of-name to avoid false positives like
    -- "Pacific" matching "PA". Case-insensitive via ~* regex operator.
    and not (
      item.service_name ilike '1040%'
      and coalesce(item.fc_client_name, item.anchor_client_business_name) ~* '(LLC|Inc\.?|Corp\.?|LLP|PA)\s*$'
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
  'V0.7.B.3 structural rule encoded: excludes 1040* services on business-suffix clients (LLC/Inc/Corp/LLP/PA, anchored at end-of-name) because 1040 = individual personal return while LLC/Inc = business entity; the 1040 work is on the owner''s separate FC client per fc_client_hierarchy.md. V0.7.B.1 T6a still active: excludes items where matching FC task is complete or matching FC project is closed (mirrors apply function clearance branches). Eliminates the churn pattern. source_audit_row_hash key sla_breached:<fc_client_id>:<service_name> for active classification dedupe. action_url falls back FC task -> FC project -> Anchor; Task 1 found zero open FC tasks across sampled clients, so FC-task tier is unreachable in current data. waiting_on_client + staff fallback + 1120 entity_type all deferred to V0.7.D. Long-tail Reclassify affordance (for cases this rule doesn''t catch) deferred to V0.7.B.4 if/when needed.';
