insert into profit_classification_verdicts (
  verdict_code,
  label,
  category,
  default_visibility,
  requires_re_evaluate_at,
  auto_transition_enabled,
  description
) values
  ('SLA_BREACHED', 'SLA breached', 'pending', 'show', false, true, 'Active service line is past its SLA target date with no clearance signal. Operator action: complete the underlying FC task or archive the FC project.')
on conflict (verdict_code) do update set
  label = excluded.label,
  category = excluded.category,
  default_visibility = excluded.default_visibility,
  requires_re_evaluate_at = excluded.requires_re_evaluate_at,
  auto_transition_enabled = excluded.auto_transition_enabled,
  description = excluded.description,
  updated_at = now();

insert into profit_classification_transition_rules (
  from_verdict_code,
  signal_name,
  to_verdict_code,
  requires_service_type_match,
  enabled,
  notes
) values
  ('SLA_BREACHED', 'sla_task_complete', 'SLA_BREACHED', false, true, 'No-op resolution marker. Existing taxonomy has no work-complete/outside-billing successor verdict, and SETTLED_VIA_QUICKBOOKS_PAYMENT is QBO-cash specific. The Task 3 apply function supersedes the active row with superseded_by_classification_id = null when an FC task with matching service tag has is_completed = true OR completed_at IS NOT NULL; underlying work is done.'),
  ('SLA_BREACHED', 'sla_project_archived', 'SLA_BREACHED', false, true, 'No-op resolution marker. Existing taxonomy has no work-complete/outside-billing successor verdict, and SETTLED_VIA_QUICKBOOKS_PAYMENT is QBO-cash specific. The Task 3 apply function supersedes the active row with superseded_by_classification_id = null when an FC project containing the service tag has is_closed = true OR closed_at IS NOT NULL; fallback clearance signal when task-level signal is unavailable.')
on conflict (from_verdict_code, signal_name, to_verdict_code) do update set
  requires_service_type_match = excluded.requires_service_type_match,
  enabled = excluded.enabled,
  notes = excluded.notes,
  updated_at = now();

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
  'V0.7.B SLA breached verdict candidate view. Source of truth is profit_sla_service_items at one row per client and service, filtered to breached/at_risk rows with default_sla_day, target_sla_day, and target_date present; this naturally excludes Payroll Service and Year End Accounting Close null-SLA rows found in Task 1. Active classification dedupe uses the system:sla_breached source hash key sla_breached:<fc_client_id>:<service_name> because profit_classifications has no service_name column. action_url falls back FC task -> FC project -> Anchor; Task 1 found zero open FC tasks across sampled clients, so the FC-task tier is unreachable in current data and rows resolve to FC project where available or Anchor. Task 3 clearance must use task is_completed = true OR completed_at IS NOT NULL and project is_closed = true OR closed_at IS NOT NULL. V0.7.D defers waiting_on_client tag joins, all-unassigned staff fallback repair, and 1120 C/S entity_type disambiguation.';
