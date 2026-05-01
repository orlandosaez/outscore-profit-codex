create or replace function profit_normalize_client_name(value text)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(
      regexp_replace(
        lower(coalesce(value, '')),
        '\m(llc|inc|corp|corporation|company|co|ltd|pllc|pa)\M',
        '',
        'g'
      ),
      '[^a-z0-9]+',
      '',
      'g'
    ),
    ''
  );
$$;

create table if not exists profit_fc_task_trigger_approvals (
  fc_task_id bigint primary key,
  approval_status text not null default 'pending',
  override_anchor_relationship_id text,
  override_macro_service_type text,
  override_trigger_type text,
  override_service_period_month date,
  approved_by text,
  approved_at timestamptz,
  notes text,
  loaded_at timestamptz not null default now(),
  check (approval_status in ('pending', 'approved', 'ignored', 'rejected'))
);

create index if not exists idx_profit_fc_task_trigger_approvals_status
  on profit_fc_task_trigger_approvals (approval_status);

create or replace view profit_fc_client_anchor_match_candidates as
with fc as (
  select
    client.fc_client_id,
    client.name as fc_client_name,
    profit_normalize_client_name(client.name) as normalized_client_name
  from profit_fc_clients client
),
anchor_names as (
  select
    agreement.anchor_relationship_id,
    agreement.client_business_name as anchor_client_business_name,
    profit_normalize_client_name(agreement.client_business_name) as normalized_client_name
  from profit_anchor_agreements agreement
  where agreement.client_business_name is not null
),
anchor_unique as (
  select
    anchor_names.*,
    count(*) over (partition by anchor_names.normalized_client_name) as normalized_anchor_count
  from anchor_names
)
select
  fc.fc_client_id,
  fc.fc_client_name,
  anchor_unique.anchor_relationship_id,
  anchor_unique.anchor_client_business_name,
  case
    when anchor_unique.anchor_relationship_id is null then 'unmatched'
    when anchor_unique.normalized_anchor_count = 1 then 'auto_exact'
    else 'ambiguous'
  end as match_status,
  case
    when anchor_unique.anchor_relationship_id is not null
      and anchor_unique.normalized_anchor_count = 1 then 1.0
    else null
  end::numeric as match_confidence,
  fc.normalized_client_name
from fc
left join anchor_unique
  on anchor_unique.normalized_client_name = fc.normalized_client_name;

create or replace view profit_fc_completion_trigger_candidates as
select
  review.fc_task_id,
  review.fc_project_id,
  review.fc_client_id,
  review.client_name,
  review.project_title,
  review.task_title,
  review.completed_at,
  review.completed_by_name,
  review.suggested_trigger_type,
  review.suggested_macro_service_type,
  review.suggested_service_period_month,
  coalesce(
    approval.override_anchor_relationship_id,
    review.anchor_relationship_id,
    case when auto_match.match_status = 'auto_exact' then auto_match.anchor_relationship_id end
  ) as anchor_relationship_id,
  coalesce(
    review.anchor_client_business_name,
    auto_match.anchor_client_business_name
  ) as anchor_client_business_name,
  coalesce(
    approval.override_macro_service_type,
    review.suggested_macro_service_type
  ) as macro_service_type,
  coalesce(
    approval.override_trigger_type,
    review.suggested_trigger_type
  ) as trigger_type,
  coalesce(
    approval.override_service_period_month,
    review.suggested_service_period_month
  ) as service_period_month,
  review.completed_at::date as completion_date,
  coalesce(approval.approval_status, 'pending') as approval_status,
  approval.approved_by,
  approval.approved_at,
  approval.notes as approval_notes,
  case
    when coalesce(approval.approval_status, 'pending') in ('ignored', 'rejected') then coalesce(approval.approval_status, 'pending')
    when coalesce(approval.approval_status, 'pending') <> 'approved' then 'pending_approval'
    when coalesce(
      approval.override_anchor_relationship_id,
      review.anchor_relationship_id,
      case when auto_match.match_status = 'auto_exact' then auto_match.anchor_relationship_id end
    ) is null then 'needs_client_match'
    when coalesce(approval.override_macro_service_type, review.suggested_macro_service_type) is null then 'needs_macro_service_type'
    when coalesce(approval.override_trigger_type, review.suggested_trigger_type) = 'manual_review' then 'needs_trigger_type'
    else 'ready_to_load'
  end as trigger_load_status
from profit_fc_completed_task_review review
left join profit_fc_task_trigger_approvals approval
  on approval.fc_task_id = review.fc_task_id
left join profit_fc_client_anchor_match_candidates auto_match
  on auto_match.fc_client_id = review.fc_client_id;

create or replace view profit_fc_completion_triggers_ready_to_load as
select
  concat('fc_task_', candidate.fc_task_id)::text as recognition_trigger_key,
  'financial_cents'::text as source_system,
  candidate.fc_task_id::text as source_record_id,
  candidate.anchor_relationship_id,
  candidate.macro_service_type,
  candidate.service_period_month,
  candidate.completion_date,
  candidate.trigger_type,
  'recognize_full_source_amount'::text as recognition_action,
  concat(
    'Approved FC task trigger: ',
    candidate.task_title,
    ' / ',
    candidate.project_title
  )::text as notes,
  jsonb_build_object(
    'fc_task_id', candidate.fc_task_id,
    'fc_project_id', candidate.fc_project_id,
    'fc_client_id', candidate.fc_client_id,
    'client_name', candidate.client_name,
    'project_title', candidate.project_title,
    'task_title', candidate.task_title,
    'completed_at', candidate.completed_at,
    'completed_by_name', candidate.completed_by_name,
    'approval_status', candidate.approval_status,
    'approved_by', candidate.approved_by,
    'approved_at', candidate.approved_at
  ) as raw
from profit_fc_completion_trigger_candidates candidate
where candidate.approval_status = 'approved'
  and (candidate.suggested_trigger_type <> 'manual_review' or candidate.trigger_type <> 'manual_review')
  and candidate.anchor_relationship_id is not null
  and candidate.macro_service_type is not null
  and candidate.completion_date is not null
  and candidate.trigger_type <> 'manual_review'
  and candidate.trigger_load_status = 'ready_to_load';
