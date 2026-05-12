-- Migration 035b: SLA candidates use template-map + derived preparer + workflow status (V0.7.D-1 highest-leverage)
--
-- Purpose: rebuild profit_sla_breached_candidates to use:
--   1. profit_fc_template_service_map (migration 035) for project→service binding.
--      Replaces the empty profit_fc_project_tags(tag_type='service') lookup that
--      Task 1 found cannot be populated (FC has no project-level service tags).
--      ILIKE-title fallback retained for long-tail unmapped templates.
--   2. profit_fc_client_primary_preparer (migration 035a) for assigned_staff_name.
--      Replaces the hardcoded 'Unassigned' that all V0.7.B SLA rows have shown.
--   3. profit_fc_project_tags(tag_type='workflow_status') for waiting_on_client
--      state integration. Excludes waiting_on_client rows from candidates per
--      V0.7.D OQ4 lock (work blocked by client is not actionable for the
--      operator's weekly review).
--
-- Preserves V0.7.B.4 attribution layer (label, label_unresolved,
-- resolution_strategy, agreement_client_business_name). Column order
-- preserved EXACTLY for CREATE OR REPLACE VIEW safety (learned the hard way
-- in V0.7.B.4 T4).
--
-- State precedence: not_applicable > waiting_on_client > breached > at_risk > on_track.
-- Only 'breached' and 'at_risk' surface as candidates. 'waiting_on_client' is
-- a NEW state (V0.7.D) that hides client-blocked work from Weekly Review.
--
-- No content-specific rules. All matching is via operator-managed metadata
-- (template_service_map) or generic predicates (split_part ILIKE fallback).
--
-- Depends on: 034a (attribution view), 035 (template map), 035a (preparer view),
-- existing profit_fc_project_tags + profit_fc_projects + profit_fc_tasks.
-- Predeploy_smoke.sh gate must pass before live apply.

create or replace view profit_sla_breached_candidates as
with source_items as (
  -- Every attributed service joined to its recognition rule for SLA targets.
  -- One row per (anchor_relationship_id, canonical_service_name, label).
  select
    asa.anchor_relationship_id,
    asa.attributed_fc_client_id as fc_client_id,
    asa.attributed_fc_client_name as fc_client_name,
    asa.agreement_client_business_name as anchor_client_business_name,
    asa.canonical_service_name as service_name,
    asa.raw_service_name,
    asa.label,
    asa.label_unresolved,
    asa.resolution_strategy,
    rule.macro_service_type,
    rule.recognition_pattern,
    rule.service_period_rule,
    rule.fc_tag,
    rule.default_sla_day,
    rule.default_sla_day as target_sla_day,
    -- trigger_date: when the SLA clock starts
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date
      else null::date
    end as trigger_date,
    -- target_date: SLA deadline = trigger_date + default_sla_day (with period adjustments)
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1) + (rule.default_sla_day - 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date + (rule.default_sla_day - 1)
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date + rule.default_sla_day
      else null::date
    end as target_date,
    -- Build source_audit_row_hash matching V0.7.B's dedup scheme
    'sla_breached:' || asa.attributed_fc_client_id::text || ':' || asa.canonical_service_name as source_audit_row_hash
  from profit_anchor_services_attributed asa
  left join profit_service_recognition_rules rule
    on rule.service_name = asa.canonical_service_name
),
-- Workflow status precedence: derive the dominant workflow status across all
-- OPEN projects matching this (fc_client, service) pair. Used both for the
-- waiting_on_client state and for surfacing latest_workflow_status in the queue.
project_workflow_status as (
  select
    p.fc_client_id,
    coalesce(m.fc_tag_prefix, 'NO_MAP') as fc_tag_prefix,
    p.title as project_title,
    pt.tag_name as workflow_status_name,
    -- Precedence: Waiting on Client highest (forces SLA hidden), then In Process,
    -- then everything else. Used in the row_number partition to pick dominant.
    case pt.tag_name
      when 'Waiting on Client'    then 1
      when 'In Preparation'       then 2
      when 'In Process'           then 3
      when 'Client info received' then 4
      else 5
    end as precedence
  from profit_fc_projects p
  left join profit_fc_template_service_map m on m.template_id = p.template_id
  inner join profit_fc_project_tags pt
    on pt.fc_project_id = p.fc_project_id
   and pt.tag_type = 'workflow_status'
  where p.is_closed = false
),
state_inputs as (
  select
    si.*,
    current_date - trigger_date as age_days,
    -- waiting_on_client check: EXISTS an open project for this client matching
    -- this service (via template map prefix OR ILIKE fallback) with a
    -- "Waiting on Client" workflow status tag.
    exists (
      select 1
      from project_workflow_status pws
      where pws.fc_client_id = si.fc_client_id
        and pws.workflow_status_name = 'Waiting on Client'
        and (
          si.fc_tag like pws.fc_tag_prefix || '%'
          or pws.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    ) as is_waiting_on_client,
    -- Dominant workflow status across matching open projects for display.
    (
      select pws.workflow_status_name
      from project_workflow_status pws
      where pws.fc_client_id = si.fc_client_id
        and (
          si.fc_tag like pws.fc_tag_prefix || '%'
          or pws.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
      order by pws.precedence asc
      limit 1
    ) as derived_workflow_status,
    -- sla_state: mirrors V0.7.B.4 state machine + waiting_on_client integration.
    case
      when si.recognition_pattern in ('manual_review', 'pass_through')
        or si.service_period_rule in ('manual', 'pass_through')
        or si.default_sla_day is null
        or si.target_date is null
        then 'not_applicable'::text
      when exists (
        select 1
        from project_workflow_status pws
        where pws.fc_client_id = si.fc_client_id
          and pws.workflow_status_name = 'Waiting on Client'
          and (
            si.fc_tag like pws.fc_tag_prefix || '%'
            or pws.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
          )
      ) then 'waiting_on_client'::text
      when current_date > si.target_date
        then 'breached'::text
      when (current_date - si.trigger_date)::numeric
        >= greatest((si.target_sla_day - 2)::numeric, ceil(si.target_sla_day::numeric * 0.8))
        then 'at_risk'::text
      else 'on_track'::text
    end as sla_state
  from source_items si
),
filtered as (
  -- Keep only breached and at_risk (excludes waiting_on_client per OQ4 lock).
  -- Drop services where attributed client has a completed FC task OR closed FC
  -- project matching the canonical service via template-map prefix OR ILIKE
  -- fallback for long-tail unmapped templates.
  select *
  from state_inputs si
  where si.sla_state in ('breached', 'at_risk')
    and si.default_sla_day is not null
    and si.target_sla_day is not null
    and si.target_date is not null
    and si.fc_client_id is not null
    -- Clearance via completed task
    and not exists (
      select 1
      from profit_fc_tasks task
      left join profit_fc_projects task_project on task_project.fc_project_id = task.fc_project_id
      left join profit_fc_template_service_map task_map on task_map.template_id = task_project.template_id
      where task.fc_client_id = si.fc_client_id
        and (task.is_completed = true or task.completed_at is not null)
        and (
          -- Primary path: template-map prefix match against rule.fc_tag
          (task_map.fc_tag_prefix is not null and si.fc_tag like task_map.fc_tag_prefix || '%')
          -- Fallback path: ILIKE on project title for unmapped templates
          or task.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    )
    -- Clearance via closed project
    and not exists (
      select 1
      from profit_fc_projects project
      left join profit_fc_template_service_map proj_map on proj_map.template_id = project.template_id
      where project.fc_client_id = si.fc_client_id
        and (project.is_closed = true or project.closed_at is not null)
        and (
          (proj_map.fc_tag_prefix is not null and si.fc_tag like proj_map.fc_tag_prefix || '%')
          or project.title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    )
),
active_sla_classification as (
  select distinct on (classification.fc_client_id, split_part(classification.source_audit_row_hash, ':', 3))
    classification.classification_id,
    classification.classified_at,
    classification.verdict_code,
    classification.fc_client_id,
    split_part(classification.source_audit_row_hash, ':', 3) as service_name
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
-- Column order MUST match V0.7.B.4 exactly (26 columns). New behavior is
-- embedded in existing column values (assigned_staff_name + staff_source +
-- latest_workflow_status). No new columns appended.
select distinct on (filtered.fc_client_id, filtered.service_name)
  active_sla_classification.classification_id,
  active_sla_classification.classified_at,
  coalesce(active_sla_classification.verdict_code, 'SLA_BREACHED') as verdict_code,
  filtered.fc_client_id,
  filtered.anchor_relationship_id,
  filtered.anchor_relationship_id as agreement_id,
  coalesce(filtered.fc_client_name, filtered.anchor_client_business_name) as client_name,
  filtered.service_name,
  filtered.macro_service_type,
  filtered.fc_tag,
  filtered.sla_state as breach_state,
  case
    when active_sla_classification.classified_at is null then null::integer
    else greatest(current_date - active_sla_classification.classified_at::date, 0)::integer
  end as age_days,
  greatest(current_date - filtered.target_date::date, 0)::integer as breach_age_days,
  filtered.age_days::integer as work_age_days,
  filtered.target_date,
  filtered.target_sla_day,
  -- V0.7.D-1 NEW: derived primary preparer replaces hardcoded 'Unassigned'
  coalesce(preparer.primary_preparer_name, 'Unassigned')::text as assigned_staff_name,
  case
    when preparer.primary_preparer_name is not null then 'derived_primary_preparer'::text
    else 'unassigned'::text
  end as staff_source,
  -- V0.7.D-1 NEW: derived workflow status from matching open project tags
  filtered.derived_workflow_status as latest_workflow_status,
  null::bigint as fc_task_id,
  null::bigint as fc_project_id,
  'https://app.sayanchor.com/home/relationship/' || filtered.anchor_relationship_id || '/agreement' as action_url,
  -- V0.7.B.4 attribution columns preserved at end:
  filtered.label,
  filtered.label_unresolved,
  filtered.resolution_strategy,
  filtered.anchor_client_business_name as agreement_client_business_name
from filtered
left join active_sla_classification
  on active_sla_classification.fc_client_id = filtered.fc_client_id
 and active_sla_classification.service_name = filtered.service_name
left join profit_fc_client_primary_preparer preparer
  on preparer.fc_client_id = filtered.fc_client_id
order by
  filtered.fc_client_id,
  filtered.service_name,
  (filtered.label is null) desc,
  filtered.label_unresolved asc nulls first,
  filtered.target_date asc nulls last;

comment on view profit_sla_breached_candidates is
  'V0.7.D-1: SLA candidates use profit_fc_template_service_map for project→service binding (replaces empty fc_project_tags service-tag lookup), profit_fc_client_primary_preparer for staff routing (replaces hardcoded Unassigned), and profit_fc_project_tags(tag_type=''workflow_status'') for waiting_on_client state integration. Excludes waiting_on_client from candidates per OQ4 lock. ILIKE-title fallback retained for long-tail unmapped templates. Preserves V0.7.B.4 attribution layer (label, label_unresolved, resolution_strategy, agreement_client_business_name). No content-specific rules.';
