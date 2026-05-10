-- V0.6.D Task 2: core SLA dashboard surfaces.
-- SLA day precedence: profit_anchor_agreements.sla_day_override takes precedence
-- over profit_service_recognition_rules.default_sla_day.
-- SLA state precedence: not_applicable > waiting_on_client > breached > at_risk > on_track.
-- Staff fallback: task assignee first, then client staff tags. Client staff tags are
-- currently sparse, so the fallback is intentionally a documented no-op until populated.

alter table profit_fc_project_tags
  drop constraint if exists profit_fc_project_tags_tag_type_check;

alter table profit_fc_project_tags
  add constraint profit_fc_project_tags_tag_type_check
  check (tag_type in ('service', 'group', 'staff', 'workflow_status', 'unknown'));

alter table profit_fc_client_tags
  drop constraint if exists profit_fc_client_tags_tag_type_check;

alter table profit_fc_client_tags
  add constraint profit_fc_client_tags_tag_type_check
  check (tag_type in ('service', 'group', 'staff', 'workflow_status', 'unknown'));

alter table profit_fc_task_tags
  drop constraint if exists profit_fc_task_tags_tag_type_check;

alter table profit_fc_task_tags
  add constraint profit_fc_task_tags_tag_type_check
  check (tag_type in ('service', 'group', 'staff', 'workflow_status', 'unknown'));

insert into profit_fc_project_tags (
  fc_project_id,
  tag_name,
  tag_type,
  normalized_tag,
  synced_at
)
select distinct
  project.fc_project_id,
  raw_tag.tag_name,
  'workflow_status',
  profit_normalize_client_name(raw_tag.tag_name),
  now()
from profit_fc_projects project
cross join lateral (
  select tag_item->>'name' as tag_name
  from jsonb_array_elements(coalesce(project.raw->'tags', '[]'::jsonb)) tag_item
) raw_tag
where raw_tag.tag_name in (
  'Waiting on Client',
  'In Preparation',
  'Ready to Submit'
)
on conflict (fc_project_id, tag_name) do nothing;

create or replace view profit_sla_project_statuses as
select
  project.fc_project_id,
  project.fc_client_id,
  project.title as project_title,
  tag.tag_name as workflow_status,
  tag.synced_at,
  project.updated_at as project_updated_at
from profit_fc_project_tags tag
join profit_fc_projects project
  on project.fc_project_id = tag.fc_project_id
where tag.tag_type = 'workflow_status';

create or replace view profit_sla_service_items as
with scoped_services as (
  select
    event.anchor_relationship_id,
    agreement.client_business_name as anchor_client_business_name,
    match.fc_client_id,
    client.name as fc_client_name,
    event.canonical_service_name as service_name,
    max(invoice.issue_date)::date as latest_invoice_date,
    max(event.loaded_at) as latest_revenue_event_loaded_at
  from profit_revenue_events event
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = event.anchor_relationship_id
  left join profit_fc_client_anchor_matches match
    on match.anchor_relationship_id = event.anchor_relationship_id
  left join profit_fc_clients client
    on client.fc_client_id = match.fc_client_id
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
  where event.canonical_service_name is not null
  group by
    event.anchor_relationship_id,
    agreement.client_business_name,
    match.fc_client_id,
    client.name,
    event.canonical_service_name
),
sla_inputs as (
  select
    scoped.anchor_relationship_id,
    scoped.anchor_client_business_name,
    scoped.fc_client_id,
    scoped.fc_client_name,
    scoped.service_name,
    rule.macro_service_type,
    rule.recognition_pattern,
    rule.service_period_rule,
    rule.fc_tag,
    rule.default_sla_day,
    agreement.sla_day_override,
    coalesce(agreement.sla_day_override, rule.default_sla_day) as target_sla_day,
    scoped.latest_invoice_date,
    scoped.latest_revenue_event_loaded_at
  from scoped_services scoped
  join profit_service_recognition_rules rule
    on rule.service_name = scoped.service_name
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = scoped.anchor_relationship_id
),
dated_items as (
  select
    sla_inputs.*,
    case sla_inputs.service_period_rule
      when 'previous_month'
        then date_trunc('month', current_date)::date
      when 'previous_quarter'
        then date_trunc('quarter', current_date)::date
      when 'tax_year_default'
        then make_date(extract(year from current_date)::integer, 1, 1)
      when 'invoice_date'
        then sla_inputs.latest_invoice_date
      else null::date
    end as trigger_date,
    case sla_inputs.service_period_rule
      when 'previous_month'
        then date_trunc('month', current_date)::date + (sla_inputs.target_sla_day - 1)
      when 'previous_quarter'
        then date_trunc('quarter', current_date)::date + sla_inputs.target_sla_day
      when 'tax_year_default'
        then make_date(extract(year from current_date)::integer, 1, 1) + sla_inputs.target_sla_day
      when 'invoice_date'
        then sla_inputs.latest_invoice_date + sla_inputs.target_sla_day
      else null::date
    end as target_date
  from sla_inputs
),
project_context as (
  select
    dated_items.*,
    status.workflow_status as latest_workflow_status
  from dated_items
  left join lateral (
    select project_status.workflow_status
    from profit_fc_project_tags service_tag
    join profit_sla_project_statuses project_status
      on project_status.fc_project_id = service_tag.fc_project_id
    where service_tag.tag_type = 'service'
      and service_tag.tag_name = dated_items.fc_tag
      and service_tag.fc_project_id in (
        select project.fc_project_id
        from profit_fc_projects project
        where project.fc_client_id = dated_items.fc_client_id
      )
    order by
      project_status.synced_at desc nulls last,
      project_status.project_updated_at desc nulls last,
      project_status.workflow_status
    limit 1
  ) status on true
),
staff_context as (
  select
    project_context.*,
    coalesce(task_staff.user_name, client_staff.tag_name, 'Unassigned') as assigned_staff_name,
    case
      when task_staff.user_name is not null then 'task_assignee'
      when client_staff.tag_name is not null then 'client_staff_tag'
      else 'unassigned'
    end as staff_source
  from project_context
  left join lateral (
    select task.user_name
    from profit_fc_tasks task
    where task.fc_client_id = project_context.fc_client_id
      and coalesce(task.is_completed, false) = false
      and task.user_name is not null
      and (
        task.fc_project_id in (
          select service_tag.fc_project_id
          from profit_fc_project_tags service_tag
          where service_tag.tag_type = 'service'
            and service_tag.tag_name = project_context.fc_tag
        )
        or task.project_title ilike '%' || project_context.service_name || '%'
      )
    order by task.due_date nulls last, task.updated_at desc nulls last
    limit 1
  ) task_staff on true
  left join lateral (
    select tag.tag_name
    from profit_fc_client_tags tag
    where tag.fc_client_id = project_context.fc_client_id
      and tag.tag_type = 'staff'
    order by tag.synced_at desc nulls last, tag.tag_name
    limit 1
  ) client_staff on true
),
state_inputs as (
  select
    staff_context.*,
    (current_date - staff_context.trigger_date)::integer as age_days
  from staff_context
)
select
  anchor_relationship_id,
  anchor_client_business_name,
  fc_client_id,
  fc_client_name,
  service_name,
  macro_service_type,
  recognition_pattern,
  service_period_rule,
  fc_tag,
  default_sla_day,
  sla_day_override,
  target_sla_day,
  trigger_date,
  target_date,
  age_days,
  latest_invoice_date,
  latest_workflow_status,
  assigned_staff_name,
  staff_source,
  latest_revenue_event_loaded_at,
  case
    when recognition_pattern in ('manual_review', 'pass_through')
      or service_period_rule in ('manual', 'pass_through')
      or (default_sla_day is null and sla_day_override is null)
      then 'not_applicable'
    when latest_workflow_status = 'Waiting on Client'
      then 'waiting_on_client'
    when current_date > target_date
      then 'breached'
    when age_days >= greatest(target_sla_day - 2, ceil(target_sla_day * 0.8))
      then 'at_risk'
    else 'on_track'
  end as sla_state
from state_inputs;

create or replace view profit_sla_client_status as
with ranked as (
  select
    item.*,
    case item.sla_state
      when 'breached' then 5
      when 'at_risk' then 4
      when 'on_track' then 3
      when 'waiting_on_client' then 2
      else 1
    end as state_rank
  from profit_sla_service_items item
),
rollup as (
  select
    anchor_relationship_id,
    anchor_client_business_name,
    fc_client_id,
    fc_client_name,
    max(state_rank) as worst_state_rank,
    count(*)::integer as service_count,
    count(*) filter (where sla_state = 'breached')::integer as breached_count,
    count(*) filter (where sla_state = 'at_risk')::integer as at_risk_count,
    count(*) filter (where sla_state = 'waiting_on_client')::integer as waiting_on_client_count,
    count(*) filter (where sla_state = 'not_applicable')::integer as not_applicable_count,
    min(target_date) filter (where sla_state in ('breached', 'at_risk', 'on_track')) as next_target_date
  from ranked
  group by
    anchor_relationship_id,
    anchor_client_business_name,
    fc_client_id,
    fc_client_name
)
select
  anchor_relationship_id,
  anchor_client_business_name,
  fc_client_id,
  fc_client_name,
  case worst_state_rank
    when 5 then 'breached'
    when 4 then 'at_risk'
    when 3 then 'on_track'
    when 2 then 'waiting_on_client'
    else 'not_applicable'
  end as sla_state,
  service_count,
  breached_count,
  at_risk_count,
  waiting_on_client_count,
  not_applicable_count,
  next_target_date
from rollup;

create or replace view profit_sla_staff_workload as
select
  assigned_staff_name,
  staff_source,
  count(*) filter (where sla_state <> 'not_applicable')::integer as open_count,
  count(*) filter (where sla_state in ('on_track', 'at_risk', 'breached'))::integer as in_flight_count,
  count(*) filter (where sla_state = 'breached')::integer as breached_count,
  count(*) filter (where sla_state = 'at_risk')::integer as at_risk_count,
  count(*) filter (where sla_state = 'waiting_on_client')::integer as waiting_on_client_count
from profit_sla_service_items
group by assigned_staff_name, staff_source;

create or replace view profit_sla_breach_queue as
select
  anchor_relationship_id,
  anchor_client_business_name,
  fc_client_id,
  fc_client_name,
  service_name,
  macro_service_type,
  assigned_staff_name,
  staff_source,
  age_days,
  target_sla_day,
  trigger_date,
  target_date,
  latest_invoice_date,
  latest_workflow_status,
  sla_state
from profit_sla_service_items
where sla_state in ('breached', 'at_risk')
order by
  case sla_state
    when 'breached' then 1
    when 'at_risk' then 2
    else 3
  end,
  target_date asc nulls last,
  age_days desc nulls last;

comment on view profit_sla_project_statuses is
  'One row per FC project and workflow_status tag. Backfilled from profit_fc_projects.raw->tags for Waiting on Client, In Preparation, and Ready to Submit.';

comment on view profit_sla_service_items is
  'Canonical SLA item grain: one row per client, anchor_relationship_id, and service_name. Uses sla_day_override before default_sla_day and applies not_applicable, waiting_on_client, breached, at_risk, on_track precedence.';

comment on view profit_sla_client_status is
  'Per-client worst-state rollup from profit_sla_service_items.';

comment on view profit_sla_staff_workload is
  'Per-staff SLA workload. Staff attribution uses task assignee first, then client staff tags, then Unassigned.';

comment on view profit_sla_breach_queue is
  'Triage queue for breached and at_risk SLA service items.';
