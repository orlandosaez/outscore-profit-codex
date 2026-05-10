-- V0.6.D Task 3: secondary SLA performance and Anchor backfill surfaces.
-- Fixed 90-day scope: profit_sla_staff_service_performance_90d is intentionally
-- not parameterized. It uses completed FC tasks where finished_at is within
-- interval '90 days'. Staff fallback follows the Task 2 SLA convention:
-- task assignee first, then client staff tags, then Unassigned.
-- Service grain: service_name from profit_service_recognition_rules.fc_tag so
-- operators can compare performance by the same canonical service names used
-- in profit_sla_service_items.
-- Read-only backfill: profit_sla_anchor_backfill_queue is an operator queue for
-- current SETTLED_VIA_QUICKBOOKS_PAYMENT classifications. It exposes QBO cash
-- evidence, missing-Anchor state, aging, and auto-transition eligibility only;
-- it defines no write controls and performs no reclassification.

create or replace view profit_sla_staff_service_performance_90d as
with completed_tasks as (
  select
    task.fc_task_id,
    task.fc_client_id,
    task.fc_project_id,
    coalesce(task.user_name, task.completed_by_name) as task_staff_name,
    task.completed_at as finished_at,
    task.due_date,
    task.created_at,
    project.title as project_title,
    service_tag.tag_name as fc_tag
  from profit_fc_tasks task
  left join profit_fc_projects project
    on project.fc_project_id = task.fc_project_id
  left join profit_fc_project_tags service_tag
    on service_tag.fc_project_id = task.fc_project_id
   and service_tag.tag_type = 'service'
  where coalesce(task.is_completed, false) = true
    and task.completed_at is not null
),
service_context as (
  select
    completed_tasks.*,
    rule.service_name,
    rule.macro_service_type,
    coalesce(rule.default_sla_day, 0) as target_sla_day,
    coalesce(
      completed_tasks.due_date::date,
      completed_tasks.created_at::date + coalesce(rule.default_sla_day, 0)
    ) as target_date,
    coalesce(completed_tasks.created_at::date, completed_tasks.finished_at::date) as trigger_date
  from completed_tasks
  join profit_service_recognition_rules rule
    on rule.fc_tag = completed_tasks.fc_tag
),
staff_context as (
  select
    service_context.*,
    coalesce(
      service_context.task_staff_name,
      client_staff.tag_name,
      'Unassigned'
    ) as staff_name
  from service_context
  left join lateral (
    select tag.tag_name
    from profit_fc_client_tags tag
    where tag.fc_client_id = service_context.fc_client_id
      and tag.tag_type = 'staff'
    order by tag.synced_at desc nulls last, tag.tag_name
    limit 1
  ) client_staff on true
),
scoped as (
  select *
  from staff_context
  where finished_at >= now() - interval '90 days'
)
select
  staff_name,
  service_name,
  count(*)::integer as total_completed,
  count(*) filter (
    where target_date is not null
      and finished_at::date > target_date
  )::integer as total_breached,
  count(*) filter (
    where target_date is not null
      and finished_at::date <= target_date
      and finished_at::date >= target_date - 2
  )::integer as total_partial_or_at_risk,
  (
    count(*) filter (
      where target_date is not null
        and finished_at::date > target_date
    )::numeric / nullif(count(*), 0)
  )::numeric as breach_rate,
  avg((finished_at::date - trigger_date)::integer)::numeric as avg_age_days_to_complete,
  max(finished_at) as last_completed_at
from scoped
group by staff_name, service_name;

create or replace view profit_sla_anchor_backfill_queue as
with active_svqp as (
  select
    classification.classification_id,
    classification.fc_client_id,
    classification.group_id as classification_group_id,
    classification.verdict_code,
    classification.classified_at,
    classification.notes,
    client.name as fc_client_name
  from profit_classifications classification
  join profit_fc_clients client
    on client.fc_client_id = classification.fc_client_id
  where classification.verdict_code = 'SETTLED_VIA_QUICKBOOKS_PAYMENT'
    and classification.superseded_at is null
),
group_context as (
  select
    active_svqp.*,
    coalesce(classification_group.group_id, membership_group.group_id) as group_id,
    coalesce(classification_group.group_name, membership_group.group_name) as group_name
  from active_svqp
  left join profit_client_groups classification_group
    on classification_group.group_id = active_svqp.classification_group_id
  left join profit_client_group_members member
    on member.fc_client_id = active_svqp.fc_client_id
   and member.active = true
  left join profit_client_groups membership_group
    on membership_group.group_id = member.group_id
),
match_context as (
  select
    group_context.*,
    match.anchor_relationship_id,
    match.anchor_client_business_name,
    match.match_status,
    agreement.display_status as anchor_display_status,
    agreement.terminated_at,
    agreement.status_synced_at,
    coalesce(agreement.display_status = 'active', false) as has_active_anchor_agreement,
    (
      match.fc_client_id is null
      or coalesce(agreement.display_status, 'terminated') in ('terminated', 'stale')
    ) as missing_anchor_signal
  from group_context
  left join profit_fc_client_anchor_matches match
    on match.fc_client_id = group_context.fc_client_id
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = match.anchor_relationship_id
),
cash_evidence as (
  select
    match_context.*,
    cash.collection_count,
    cash.oldest_qbo_payment_date,
    cash.latest_qbo_payment_date,
    cash.total_collected_amount,
    cash.sample_qbo_payment_id,
    cash.sample_collected_at,
    cash.sample_collected_amount
  from match_context
  left join lateral (
    select
      count(*)::integer as collection_count,
      min(collection.collected_at) as oldest_qbo_payment_date,
      max(collection.collected_at) as latest_qbo_payment_date,
      sum(collection.collected_amount)::numeric as total_collected_amount,
      (array_agg(collection.qbo_payment_id order by collection.collected_at nulls last))[1] as sample_qbo_payment_id,
      (array_agg(collection.collected_at order by collection.collected_at nulls last))[1] as sample_collected_at,
      (array_agg(collection.collected_amount order by collection.collected_at nulls last))[1] as sample_collected_amount
    from profit_cash_collections collection
    where collection.qbo_payment_id is not null
      and (
        collection.anchor_relationship_id = match_context.anchor_relationship_id
        or collection.raw_payload->>'fc_client_id' = match_context.fc_client_id::text
        or profit_normalize_client_name(collection.raw_payload->>'customer_name')
          = profit_normalize_client_name(match_context.fc_client_name)
      )
  ) cash on true
)
select
  classification_id,
  fc_client_id,
  fc_client_name,
  group_id,
  group_name,
  verdict_code,
  classified_at,
  notes,
  anchor_relationship_id,
  anchor_client_business_name,
  match_status,
  anchor_display_status,
  terminated_at,
  status_synced_at,
  missing_anchor_signal,
  collection_count,
  sample_qbo_payment_id as qbo_payment_id,
  sample_collected_at as collected_at,
  sample_collected_amount as collected_amount,
  oldest_qbo_payment_date,
  (current_date - oldest_qbo_payment_date)::integer as days_since_oldest_qbo_payment,
  latest_qbo_payment_date,
  total_collected_amount,
  has_active_anchor_agreement as auto_transition_eligible
from cash_evidence
where missing_anchor_signal = true
   or has_active_anchor_agreement = true
order by
  oldest_qbo_payment_date nulls last,
  classified_at;

comment on view profit_sla_staff_service_performance_90d is
  'Fixed 90-day rolling SLA performance summary for completed FC tasks. Lookback is intentionally not parameterized; staff fallback is task assignee, client staff tag, then Unassigned. Service grouping uses canonical profit_service_recognition_rules.service_name.';

comment on view profit_sla_anchor_backfill_queue is
  'Read-only backfill queue for current SETTLED_VIA_QUICKBOOKS_PAYMENT classifications. Surfaces client/group identity, QBO payment evidence from profit_cash_collections, missing Anchor state, aging, and active-Anchor auto-transition eligibility; it performs no writes.';
