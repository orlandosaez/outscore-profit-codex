-- Migration 035f: SLA candidates use authoritative client-staff assignments (V0.7.D-1 correction)
--
-- Replaces the derived primary_preparer signal from 035a/035d with the
-- authoritative profit_client_staff_assignments table seeded from
-- docs/data-references/client-staff-assignments.xlsx (113 unique clients,
-- 126 rows, 98% resolved to FC clients).
--
-- Lookup priority for assigned_staff_name:
--   1. profit_client_staff_assignments match on (fc_client_id, fc_tag in service_tags)
--      → use staff_primary, set staff_source = 'authoritative_assignment'
--   2. profit_fc_client_primary_preparer (derived from FC raw->assignees[0]->name)
--      → use primary_preparer_display_label, set staff_source = 'derived_primary_preparer'
--   3. 'Unassigned' / 'unassigned'
--
-- This keeps 035a/035d as a FALLBACK for clients/services not in the
-- authoritative table (data hygiene drift, new clients before XLSX update).
-- For the 13 multi-row clients (per-service splits like YV CS tax vs bookkeeping),
-- the join naturally selects the row matching the SLA candidate's fc_tag.
--
-- Column order preserved (26 columns, V0.7.B.4 contract + 035b + 035d).
-- Predeploy_smoke.sh gate must pass before live apply.

create or replace view profit_sla_breached_candidates as
with source_items as (
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
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date
      else null::date
    end as trigger_date,
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1) + (rule.default_sla_day - 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date + (rule.default_sla_day - 1)
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date + rule.default_sla_day
      else null::date
    end as target_date,
    'sla_breached:' || asa.attributed_fc_client_id::text || ':' || asa.canonical_service_name as source_audit_row_hash
  from profit_anchor_services_attributed asa
  left join profit_service_recognition_rules rule
    on rule.service_name = asa.canonical_service_name
),
project_workflow_status as (
  select
    p.fc_client_id,
    coalesce(m.fc_tag_prefix, 'NO_MAP') as fc_tag_prefix,
    p.title as project_title,
    pt.tag_name as workflow_status_name,
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
  select *
  from state_inputs si
  where si.sla_state in ('breached', 'at_risk')
    and si.default_sla_day is not null
    and si.target_sla_day is not null
    and si.target_date is not null
    and si.fc_client_id is not null
    and not exists (
      select 1
      from profit_fc_tasks task
      left join profit_fc_projects task_project on task_project.fc_project_id = task.fc_project_id
      left join profit_fc_template_service_map task_map on task_map.template_id = task_project.template_id
      where task.fc_client_id = si.fc_client_id
        and (task.is_completed = true or task.completed_at is not null)
        and (
          (task_map.fc_tag_prefix is not null and si.fc_tag like task_map.fc_tag_prefix || '%')
          or task.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    )
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
),
-- V0.7.D-1 035f: authoritative assignment lookup keyed on (fc_client_id, fc_tag).
-- Falls back to derived view (preparer) only when no authoritative row exists.
authoritative_assignment as (
  select
    csa.fc_client_id,
    -- Pick first matching service_tag; ARRAY ANY semantics with DISTINCT ON for dedup.
    csa.service_tags,
    csa.staff_primary,
    csa.staff_reviewer
  from profit_client_staff_assignment_resolved csa
  where csa.fc_client_id is not null
)
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
  -- V0.7.D-1 035f: authoritative assignment wins; derived view is fallback.
  coalesce(
    auth.staff_primary,
    preparer.primary_preparer_display_label,
    'Unassigned'
  )::text as assigned_staff_name,
  case
    when auth.staff_primary is not null                       then 'authoritative_assignment'::text
    when preparer.primary_preparer_display_label is not null  then 'derived_primary_preparer'::text
    else 'unassigned'::text
  end as staff_source,
  filtered.derived_workflow_status as latest_workflow_status,
  null::bigint as fc_task_id,
  null::bigint as fc_project_id,
  'https://app.sayanchor.com/home/relationship/' || filtered.anchor_relationship_id || '/agreement' as action_url,
  filtered.label,
  filtered.label_unresolved,
  filtered.resolution_strategy,
  filtered.anchor_client_business_name as agreement_client_business_name
from filtered
left join active_sla_classification
  on active_sla_classification.fc_client_id = filtered.fc_client_id
 and active_sla_classification.service_name = filtered.service_name
left join lateral (
  select aa.staff_primary, aa.staff_reviewer
  from authoritative_assignment aa
  where aa.fc_client_id = filtered.fc_client_id
    and filtered.fc_tag = any(aa.service_tags)
  limit 1
) auth on true
left join profit_fc_client_primary_preparer preparer
  on preparer.fc_client_id = filtered.fc_client_id
order by
  filtered.fc_client_id,
  filtered.service_name,
  (filtered.label is null) desc,
  filtered.label_unresolved asc nulls first,
  filtered.target_date asc nulls last;

comment on view profit_sla_breached_candidates is
  'V0.7.D-1 (035f): assigned_staff_name reads profit_client_staff_assignments (authoritative XLSX seed) keyed on (fc_client_id, fc_tag in service_tags), with derived primary-preparer view (035a/035d) as fallback. Source labeled in staff_source: ''authoritative_assignment'' | ''derived_primary_preparer'' | ''unassigned''. The authoritative source correctly handles per-service splits (e.g., YV CS LLC tax=Laura, bookkeeping=Julie). Column order preserved (26 columns, V0.7.B.4 contract).';
