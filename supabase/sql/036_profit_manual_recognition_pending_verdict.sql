-- Migration 036: MANUAL_RECOGNITION_PENDING verdict
-- V0.7.D-2 Task 5. Adds stuck-recognition queue verdict, candidate view,
-- and transition-function branches. Source diagnostic view owns the 30-day
-- staleness threshold.

insert into profit_classification_verdicts (
  verdict_code,
  label,
  category,
  default_visibility,
  requires_re_evaluate_at,
  auto_transition_enabled,
  description
) values
  ('MANUAL_RECOGNITION_PENDING', 'Manual recognition pending', 'pending', 'show', false, true, 'Pending revenue event older than 30 days that needs operator approval or investigation. Sourced from profit_pipeline_stuck_recognition_triggers.')
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
  ('MANUAL_RECOGNITION_PENDING', 'manual_recognition_pending_detected', 'MANUAL_RECOGNITION_PENDING', false, true, 'Self-detect rule used by profit_apply_classification_transitions to insert new stuck-recognition classifications surfaced by profit_pipeline_stuck_recognition_triggers.'),
  ('MANUAL_RECOGNITION_PENDING', 'recognition_event_recognized', 'MANUAL_RECOGNITION_PENDING', false, true, 'No-op resolution marker. Existing taxonomy has no post-recognition successor verdict, so the apply function supersedes the active row with superseded_by_classification_id = null when the revenue_event_key leaves pending_* recognition status or has recognized_amount > 0.')
on conflict (from_verdict_code, signal_name, to_verdict_code) do update set
  requires_service_type_match = excluded.requires_service_type_match,
  enabled = excluded.enabled,
  notes = excluded.notes,
  updated_at = now();

create or replace view profit_manual_recognition_pending_candidates as
with active_manual_recognition_classification as (
  select distinct on (split_part(classification.source_audit_row_hash, ':', 2))
    classification.classification_id,
    classification.classified_at,
    classification.verdict_code,
    split_part(classification.source_audit_row_hash, ':', 2) as revenue_event_key
  from profit_classifications classification
  where classification.verdict_code = 'MANUAL_RECOGNITION_PENDING'
    and classification.superseded_at is null
    and classification.source_audit_file = 'system:manual_recognition_pending'
  order by
    split_part(classification.source_audit_row_hash, ':', 2),
    classification.classified_at desc,
    classification.classification_id desc
)
select
  active_manual_recognition_classification.classification_id,
  active_manual_recognition_classification.classified_at,
  coalesce(active_manual_recognition_classification.verdict_code, 'MANUAL_RECOGNITION_PENDING') as verdict_code,
  match.fc_client_id,
  stuck.anchor_relationship_id,
  stuck.anchor_relationship_id as agreement_id,
  coalesce(agreement.client_business_name, client.name, stuck.anchor_relationship_id) as client_name,
  stuck.service_name,
  stuck.macro_service_type,
  null::text as fc_tag,
  null::text as invoice_state,
  null::text as breach_state,
  greatest(
    0,
    current_date - coalesce(active_manual_recognition_classification.classified_at::date, stuck.loaded_at::date, current_date)
  )::integer as age_days,
  null::integer as breach_age_days,
  null::integer as work_age_days,
  null::date as target_date,
  null::integer as target_sla_day,
  null::text as assigned_staff_name,
  null::text as staff_source,
  null::text as latest_workflow_status,
  null::text as fc_task_id,
  null::text as fc_project_id,
  stuck.source_amount::numeric as estimated_annual_revenue,
  coalesce(
    agreement.raw->>'link',
    'https://app.sayanchor.com/home/relationship/' || stuck.anchor_relationship_id || '/agreement'
  ) as action_url,
  stuck.revenue_event_key,
  stuck.anchor_invoice_id,
  stuck.invoice_number,
  stuck.canonical_service_name,
  stuck.source_amount,
  stuck.recognition_status,
  stuck.recognition_rule,
  stuck.candidate_period_month,
  stuck.loaded_at,
  stuck.evaluated_at,
  'manual_recognition_pending:' || stuck.revenue_event_key as source_audit_row_hash
from profit_pipeline_stuck_recognition_triggers stuck
left join active_manual_recognition_classification
  on active_manual_recognition_classification.revenue_event_key = stuck.revenue_event_key
left join profit_fc_client_anchor_matches match
  on match.anchor_relationship_id = stuck.anchor_relationship_id
left join profit_fc_clients client
  on client.fc_client_id = match.fc_client_id
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = stuck.anchor_relationship_id;

comment on view profit_manual_recognition_pending_candidates is
  'V0.7.D-2 stuck-recognition candidate view. Source is profit_pipeline_stuck_recognition_triggers, which owns the 30-day pending revenue event staleness threshold. Grain is one row per revenue_event_key.';

create or replace function profit_apply_classification_transitions(
  p_run_at timestamptz default now(),
  p_dry_run boolean default true
)
returns table (
  classification_id bigint,
  fc_client_id bigint,
  fc_client_name text,
  from_verdict_code text,
  signal_name text,
  to_verdict_code text,
  anchor_relationship_id text,
  anchor_client_business_name text,
  evidence_summary jsonb,
  would_create_classification_id bigint
)
language plpgsql
as $$
declare
  transition_record record;
  inserted_id bigint;
begin
  -- Fixture: group_billed_priority_over_standalone.
  -- Fixture: multiple_group_sibling_signals_insert_one_row.
  -- Fixture: multi_service_type_ambiguity_skips.
  -- Fixture: unresolved_canonical_service_skips.
  -- Fixture: manual_review_rule_skips.
  -- Fixture: manual_service_period_rule_skips.
  for transition_record in
    with manual_invoice_detection_signals as (
      select
        null::bigint as classification_id,
        candidate.fc_client_id,
        client.name as fc_client_name,
        null::bigint as group_id,
        null::text as from_verdict_code,
        'manual_invoice_detected'::text as signal_name,
        'MANUAL_INVOICE_PENDING'::text as to_verdict_code,
        candidate.anchor_relationship_id,
        candidate.client_name as anchor_client_business_name,
        jsonb_build_object(
          'anchor_relationship_id', candidate.anchor_relationship_id,
          'client_name', candidate.client_name,
          'service_name', candidate.service_name,
          'invoice_state', candidate.invoice_state,
          'action_url', candidate.action_url
        ) as evidence_summary,
        p_run_at as last_signal_at,
        'system:manual_invoice_pending'::text as source_audit_file,
        'manual_invoice_pending:' || candidate.anchor_relationship_id || ':detected:' || p_run_at::date::text as source_audit_row_hash,
        candidate.estimated_annual_revenue,
        candidate.service_name,
        5 as signal_priority
      from profit_manual_invoice_pending_candidates candidate
      left join profit_fc_clients client
        on client.fc_client_id = candidate.fc_client_id
      where candidate.classification_id is null
    ),
    current_classifications as (
      select
        classification.classification_id,
        classification.fc_client_id,
        client.name as fc_client_name,
        classification.group_id,
        classification.verdict_code as from_verdict_code,
        classification.classified_at,
        classification.source_audit_file,
        classification.source_audit_row_hash,
        classification.estimated_annual_revenue,
        coalesce(classification.anchor_relationship_id, match.anchor_relationship_id) as anchor_relationship_id,
        coalesce(match.anchor_client_business_name, agreement.client_business_name) as anchor_client_business_name,
        case
          when classification.source_audit_file = 'system:sla_breached' then split_part(classification.source_audit_row_hash, ':', 3)
          when classification.source_audit_file = 'system:manual_recognition_pending' then split_part(classification.source_audit_row_hash, ':', 2)
          else null::text
        end as service_name
      from profit_classifications classification
      left join profit_fc_clients client
        on client.fc_client_id = classification.fc_client_id
      left join profit_anchor_agreements agreement
        on agreement.anchor_relationship_id = classification.anchor_relationship_id
      left join profit_fc_client_anchor_matches match
        on match.fc_client_id = classification.fc_client_id
       and match.anchor_relationship_id is not null
      where classification.superseded_at is null
    ),
    group_relationships as (
      select distinct
        current_classifications.classification_id,
        sibling_match.anchor_relationship_id,
        sibling_match.anchor_client_business_name
      from current_classifications
      join profit_client_group_members source_member
        on source_member.fc_client_id = current_classifications.fc_client_id
       and source_member.active = true
      join profit_client_group_members sibling_member
        on sibling_member.group_id = source_member.group_id
       and sibling_member.active = true
       and sibling_member.fc_client_id <> current_classifications.fc_client_id
      join profit_fc_client_anchor_matches sibling_match
        on sibling_match.fc_client_id = sibling_member.fc_client_id
       and sibling_match.anchor_relationship_id is not null
    ),
    active_agreement_signals as (
      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        rule.to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        jsonb_build_object(
          'anchor_relationship_id', current_classifications.anchor_relationship_id,
          'anchor_client_business_name', current_classifications.anchor_client_business_name,
          'display_status', agreement.display_status,
          'effective_date', agreement.effective_date
        ) as evidence_summary,
        p_run_at as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        10 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'active_agreement_appears'
       and rule.enabled = true
      join profit_anchor_agreements agreement
        on agreement.anchor_relationship_id = current_classifications.anchor_relationship_id
       and agreement.display_status = 'active'
      where current_classifications.from_verdict_code in ('PENDING_ENGAGEMENT_DRAFT', 'PENDING_ENGAGEMENT_SENT')
    ),
    manual_invoice_issued_signals as (
      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        rule.to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        jsonb_build_object(
          'anchor_relationship_id', current_classifications.anchor_relationship_id,
          'issued_invoice_count', count(*),
          'first_invoice_issue_date', min(invoice.issue_date),
          'qbo_statuses', jsonb_agg(distinct invoice.qbo_status)
        ) as evidence_summary,
        max(coalesce(invoice.issue_date, invoice.last_seen_at, p_run_at)) as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        12 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'manual_invoice_issued'
       and rule.enabled = true
      join profit_anchor_invoices invoice
        on invoice.anchor_relationship_id = current_classifications.anchor_relationship_id
       and invoice.qbo_status is not null
      where current_classifications.from_verdict_code = 'MANUAL_INVOICE_PENDING'
      group by
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        rule.to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name
    ),
    manual_invoice_terminated_signals as (
      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        null::text as to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        jsonb_build_object(
          'anchor_relationship_id', current_classifications.anchor_relationship_id,
          'display_status', agreement.display_status,
          'terminated_at', agreement.terminated_at,
          'resolution', 'no-op resolution'
        ) as evidence_summary,
        agreement.terminated_at as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        13 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'manual_invoice_agreement_terminated'
       and rule.enabled = true
      join profit_anchor_agreements agreement
        on agreement.anchor_relationship_id = current_classifications.anchor_relationship_id
       and agreement.display_status = 'terminated'
       and agreement.terminated_at is not null
      where current_classifications.from_verdict_code = 'MANUAL_INVOICE_PENDING'
    ),
    manual_recognition_pending_detected_signals as (
      select
        null::bigint as classification_id,
        match.fc_client_id,
        client.name as fc_client_name,
        null::bigint as group_id,
        null::text as from_verdict_code,
        'manual_recognition_pending_detected'::text as signal_name,
        'MANUAL_RECOGNITION_PENDING'::text as to_verdict_code,
        candidate.anchor_relationship_id,
        coalesce(agreement.client_business_name, client.name, candidate.anchor_relationship_id) as anchor_client_business_name,
        jsonb_build_object(
          'revenue_event_key', candidate.revenue_event_key,
          'anchor_invoice_id', candidate.anchor_invoice_id,
          'invoice_number', candidate.invoice_number,
          'anchor_relationship_id', candidate.anchor_relationship_id,
          'service_name', candidate.service_name,
          'canonical_service_name', candidate.canonical_service_name,
          'macro_service_type', candidate.macro_service_type,
          'source_amount', candidate.source_amount,
          'recognition_status', candidate.recognition_status,
          'recognition_rule', candidate.recognition_rule,
          'candidate_period_month', candidate.candidate_period_month,
          'loaded_at', candidate.loaded_at
        ) as evidence_summary,
        coalesce(candidate.loaded_at, p_run_at) as last_signal_at,
        'system:manual_recognition_pending'::text as source_audit_file,
        'manual_recognition_pending:' || candidate.revenue_event_key as source_audit_row_hash,
        candidate.source_amount as estimated_annual_revenue,
        candidate.revenue_event_key as service_name,
        7 as signal_priority
      from profit_manual_recognition_pending_candidates candidate
      left join profit_fc_client_anchor_matches match
        on match.anchor_relationship_id = candidate.anchor_relationship_id
      left join profit_fc_clients client
        on client.fc_client_id = match.fc_client_id
      left join profit_anchor_agreements agreement
        on agreement.anchor_relationship_id = candidate.anchor_relationship_id
      where candidate.classification_id is null
    ),
    manual_recognition_event_recognized_signals as (
      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        null::text as to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        jsonb_build_object(
          'revenue_event_key', current_classifications.service_name,
          'recognition_status', event.recognition_status,
          'recognized_amount', event.recognized_amount,
          'recognition_period_month', event.recognition_period_month,
          'resolution', 'no-op resolution'
        ) as evidence_summary,
        p_run_at as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        16 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'recognition_event_recognized'
       and rule.enabled = true
      join profit_revenue_events event
        on event.revenue_event_key = current_classifications.service_name
       and (
         event.recognition_status not like 'pending_%'
         or coalesce(event.recognized_amount, 0) > 0
       )
      where current_classifications.from_verdict_code = 'MANUAL_RECOGNITION_PENDING'
        and current_classifications.service_name is not null
    ),
    sla_breach_detection_signals as (
      select
        null::bigint as classification_id,
        candidate.fc_client_id,
        client.name as fc_client_name,
        null::bigint as group_id,
        null::text as from_verdict_code,
        'sla_breach_detected'::text as signal_name,
        'SLA_BREACHED'::text as to_verdict_code,
        candidate.anchor_relationship_id,
        candidate.client_name as anchor_client_business_name,
        jsonb_build_object(
          'anchor_relationship_id', candidate.anchor_relationship_id,
          'service_name', candidate.service_name,
          'breach_state', candidate.breach_state,
          'target_date', candidate.target_date,
          'breach_age_days', candidate.breach_age_days,
          'work_age_days', candidate.work_age_days,
          'assigned_staff_name', candidate.assigned_staff_name,
          'staff_source', candidate.staff_source,
          'fc_task_id', candidate.fc_task_id,
          'fc_project_id', candidate.fc_project_id
        ) as evidence_summary,
        current_date::timestamptz as last_signal_at,
        'system:sla_breached'::text as source_audit_file,
        'sla_breached:' || candidate.fc_client_id::text || ':' || candidate.service_name as source_audit_row_hash,
        null::numeric as estimated_annual_revenue,
        candidate.service_name,
        6 as signal_priority
      from profit_sla_breached_candidates candidate
      left join profit_fc_clients client
        on client.fc_client_id = candidate.fc_client_id
      where candidate.classification_id is null
    ),
    sla_task_complete_signals as (
      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        null::text as to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        jsonb_build_object(
          'service_name', current_classifications.service_name,
          'fc_task_id', task.fc_task_id,
          'project_title', task.project_title,
          'completed_at', task.completed_at,
          'is_completed', task.is_completed,
          'resolution', 'no-op resolution'
        ) as evidence_summary,
        coalesce(task.completed_at, p_run_at) as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        14 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = 'SLA_BREACHED'
       and rule.signal_name = 'sla_task_complete'
       and rule.enabled = true
      left join lateral (
        select item.fc_tag
        from profit_sla_service_items item
        where item.fc_client_id = current_classifications.fc_client_id
          and item.service_name = current_classifications.service_name
        order by item.target_date asc nulls last
        limit 1
      ) service_item on true
      join profit_fc_tasks task
        on task.fc_client_id = current_classifications.fc_client_id
       and (task.is_completed = true or task.completed_at is not null)
       and (
         -- Task 1 found no tag_type='service' rows yet; until V0.7.D backfills them,
         -- project_title ILIKE is the only operational clearance path.
         task.fc_project_id in (
           select service_tag.fc_project_id
           from profit_fc_project_tags service_tag
           where service_tag.tag_type = 'service'
             and service_tag.tag_name = service_item.fc_tag
         )
         or task.project_title ilike '%' || split_part(current_classifications.service_name, ' ', 1) || '%'
       )
      where current_classifications.from_verdict_code = 'SLA_BREACHED'
        and current_classifications.service_name is not null
    ),
    sla_project_archived_signals as (
      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        null::text as to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        jsonb_build_object(
          'service_name', current_classifications.service_name,
          'fc_project_id', project.fc_project_id,
          'project_title', project.title,
          'closed_at', project.closed_at,
          'is_closed', project.is_closed,
          'resolution', 'no-op resolution'
        ) as evidence_summary,
        coalesce(project.closed_at, p_run_at) as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        15 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = 'SLA_BREACHED'
       and rule.signal_name = 'sla_project_archived'
       and rule.enabled = true
      left join lateral (
        select item.fc_tag
        from profit_sla_service_items item
        where item.fc_client_id = current_classifications.fc_client_id
          and item.service_name = current_classifications.service_name
        order by item.target_date asc nulls last
        limit 1
      ) service_item on true
      join profit_fc_projects project
        on project.fc_client_id = current_classifications.fc_client_id
       and (project.is_closed = true or project.closed_at is not null)
       and (
         -- Task 1 found no tag_type='service' rows yet; until V0.7.D backfills them,
         -- project_title ILIKE is the only operational clearance path.
         project.fc_project_id in (
           select service_tag.fc_project_id
           from profit_fc_project_tags service_tag
           where service_tag.tag_type = 'service'
             and service_tag.tag_name = service_item.fc_tag
         )
         or project.title ilike '%' || split_part(current_classifications.service_name, ' ', 1) || '%'
       )
      where current_classifications.from_verdict_code = 'SLA_BREACHED'
        and current_classifications.service_name is not null
    ),
    own_invoice_service_signals as (
      select
        current_classifications.classification_id,
        count(*) as signal_event_count,
        count(*) filter (where event.canonical_service_name is null) as unresolved_canonical_count,
        count(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule) as service_type_count,
        bool_or(
          rule_service.recognition_pattern = 'manual_review'
          or rule_service.service_period_rule = 'manual'
        ) as has_manual_service_rule,
        min(invoice.issue_date) as first_signal_at,
        jsonb_build_object(
          'anchor_relationship_id', current_classifications.anchor_relationship_id,
          'invoice_count', count(*),
          'first_invoice_issue_date', min(invoice.issue_date),
          'service_type_keys', jsonb_agg(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule)
        ) as evidence_summary
      from current_classifications
      join profit_anchor_invoices invoice
        on invoice.anchor_relationship_id = current_classifications.anchor_relationship_id
       and invoice.issue_date > current_classifications.classified_at
      join profit_revenue_events event
        on event.anchor_invoice_id = invoice.anchor_invoice_id
      left join profit_service_recognition_rules rule_service
        on rule_service.service_name = event.canonical_service_name
      where current_classifications.from_verdict_code = 'LEGACY_ENGAGEMENT_PRE_ANCHOR'
      group by current_classifications.classification_id, current_classifications.anchor_relationship_id
    ),
    group_invoice_service_signals as (
      select
        current_classifications.classification_id,
        count(*) as signal_event_count,
        count(*) filter (where event.canonical_service_name is null) as unresolved_canonical_count,
        count(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule) as service_type_count,
        bool_or(
          rule_service.recognition_pattern = 'manual_review'
          or rule_service.service_period_rule = 'manual'
        ) as has_manual_service_rule,
        min(invoice.issue_date) as first_signal_at,
        jsonb_build_object(
          'anchor_relationship_ids', jsonb_agg(distinct group_relationships.anchor_relationship_id),
          'invoice_count', count(*),
          'first_invoice_issue_date', min(invoice.issue_date),
          'service_type_keys', jsonb_agg(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule)
        ) as evidence_summary
      from current_classifications
      join group_relationships
        on group_relationships.classification_id = current_classifications.classification_id
      join profit_anchor_invoices invoice
        on invoice.anchor_relationship_id = group_relationships.anchor_relationship_id
       and invoice.issue_date > current_classifications.classified_at
      join profit_revenue_events event
        on event.anchor_invoice_id = invoice.anchor_invoice_id
      left join profit_service_recognition_rules rule_service
        on rule_service.service_name = event.canonical_service_name
      where current_classifications.from_verdict_code = 'LEGACY_ENGAGEMENT_PRE_ANCHOR'
      group by current_classifications.classification_id
    ),
    own_cash_service_signals as (
      select
        current_classifications.classification_id,
        count(*) as signal_event_count,
        count(*) filter (where event.canonical_service_name is null) as unresolved_canonical_count,
        count(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule) as service_type_count,
        bool_or(
          rule_service.recognition_pattern = 'manual_review'
          or rule_service.service_period_rule = 'manual'
        ) as has_manual_service_rule,
        min(collection.collected_at::timestamptz) as first_signal_at,
        jsonb_build_object(
          'anchor_relationship_id', current_classifications.anchor_relationship_id,
          'collection_count', count(distinct collection.collection_key),
          'first_collected_at', min(collection.collected_at),
          'service_type_keys', jsonb_agg(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule)
        ) as evidence_summary
      from current_classifications
      join profit_cash_collections collection
        on collection.anchor_relationship_id = current_classifications.anchor_relationship_id
       and collection.collected_at::timestamptz > current_classifications.classified_at
      join profit_collection_revenue_allocations allocation
        on collection.collection_key = allocation.collection_key
      join profit_revenue_events event
        on event.revenue_event_key = allocation.revenue_event_key
      left join profit_service_recognition_rules rule_service
        on rule_service.service_name = event.canonical_service_name
      where current_classifications.from_verdict_code = 'INVOICE_OUTSTANDING_PAYMENT_PENDING'
      group by current_classifications.classification_id, current_classifications.anchor_relationship_id
    ),
    group_cash_service_signals as (
      select
        current_classifications.classification_id,
        count(*) as signal_event_count,
        count(*) filter (where event.canonical_service_name is null) as unresolved_canonical_count,
        count(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule) as service_type_count,
        bool_or(
          rule_service.recognition_pattern = 'manual_review'
          or rule_service.service_period_rule = 'manual'
        ) as has_manual_service_rule,
        min(collection.collected_at::timestamptz) as first_signal_at,
        jsonb_build_object(
          'anchor_relationship_ids', jsonb_agg(distinct group_relationships.anchor_relationship_id),
          'collection_count', count(distinct collection.collection_key),
          'first_collected_at', min(collection.collected_at),
          'service_type_keys', jsonb_agg(distinct rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule)
        ) as evidence_summary
      from current_classifications
      join group_relationships
        on group_relationships.classification_id = current_classifications.classification_id
      join profit_cash_collections collection
        on collection.anchor_relationship_id = group_relationships.anchor_relationship_id
       and collection.collected_at::timestamptz > current_classifications.classified_at
      join profit_collection_revenue_allocations allocation
        on collection.collection_key = allocation.collection_key
      join profit_revenue_events event
        on event.revenue_event_key = allocation.revenue_event_key
      left join profit_service_recognition_rules rule_service
        on rule_service.service_name = event.canonical_service_name
      where current_classifications.from_verdict_code = 'INVOICE_OUTSTANDING_PAYMENT_PENDING'
      group by current_classifications.classification_id
    ),
    eligible_signals as (
      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        rule.to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        group_invoice_service_signals.evidence_summary,
        group_invoice_service_signals.first_signal_at as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        20 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'first_matching_anchor_invoice_group_billed'
       and rule.enabled = true
      join group_invoice_service_signals
        on group_invoice_service_signals.classification_id = current_classifications.classification_id
      where group_invoice_service_signals.signal_event_count > 0
        and group_invoice_service_signals.unresolved_canonical_count = 0
        and group_invoice_service_signals.service_type_count = 1
        and coalesce(group_invoice_service_signals.has_manual_service_rule, false) = false

      union all

      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        rule.to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        own_invoice_service_signals.evidence_summary,
        own_invoice_service_signals.first_signal_at as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        30 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'first_matching_anchor_invoice_mid_cycle'
       and rule.enabled = true
      join own_invoice_service_signals
        on own_invoice_service_signals.classification_id = current_classifications.classification_id
      where own_invoice_service_signals.signal_event_count > 0
        and own_invoice_service_signals.unresolved_canonical_count = 0
        and own_invoice_service_signals.service_type_count = 1
        and coalesce(own_invoice_service_signals.has_manual_service_rule, false) = false

      union all

      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        rule.to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        group_cash_service_signals.evidence_summary,
        group_cash_service_signals.first_signal_at as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        20 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'cash_collected_group_parent'
       and rule.enabled = true
      join group_cash_service_signals
        on group_cash_service_signals.classification_id = current_classifications.classification_id
      where group_cash_service_signals.signal_event_count > 0
        and group_cash_service_signals.unresolved_canonical_count = 0
        and group_cash_service_signals.service_type_count = 1
        and coalesce(group_cash_service_signals.has_manual_service_rule, false) = false

      union all

      select
        current_classifications.classification_id,
        current_classifications.fc_client_id,
        current_classifications.fc_client_name,
        current_classifications.group_id,
        current_classifications.from_verdict_code,
        rule.signal_name,
        rule.to_verdict_code,
        current_classifications.anchor_relationship_id,
        current_classifications.anchor_client_business_name,
        own_cash_service_signals.evidence_summary,
        own_cash_service_signals.first_signal_at as last_signal_at,
        current_classifications.source_audit_file,
        current_classifications.source_audit_row_hash,
        current_classifications.estimated_annual_revenue,
        current_classifications.service_name,
        30 as signal_priority
      from current_classifications
      join profit_classification_transition_rules rule
        on rule.from_verdict_code = current_classifications.from_verdict_code
       and rule.signal_name = 'cash_collected_standalone_mid_cycle'
       and rule.enabled = true
      join own_cash_service_signals
        on own_cash_service_signals.classification_id = current_classifications.classification_id
      where own_cash_service_signals.signal_event_count > 0
        and own_cash_service_signals.unresolved_canonical_count = 0
        and own_cash_service_signals.service_type_count = 1
        and coalesce(own_cash_service_signals.has_manual_service_rule, false) = false
    ),
    ranked_signals as (
      select *
      from manual_invoice_detection_signals

      union all

      select *
      from manual_recognition_pending_detected_signals

      union all

      select *
      from manual_invoice_issued_signals

      union all

      select *
      from manual_invoice_terminated_signals

      union all

      select *
      from sla_breach_detection_signals

      union all

      select *
      from manual_recognition_event_recognized_signals

      union all

      select *
      from sla_task_complete_signals

      union all

      select *
      from sla_project_archived_signals

      union all

      select *
      from active_agreement_signals

      union all

      select *
      from eligible_signals
    )
    select distinct on (
      coalesce(
        ranked_signals.classification_id::text,
        case
          -- SLA detection has one row per client-service, so anchor-only detection keys would collide.
          when ranked_signals.from_verdict_code is null and ranked_signals.signal_name = 'sla_breach_detected'
          then 'detect:sla:' || ranked_signals.fc_client_id::text || ':' || ranked_signals.service_name
          when ranked_signals.from_verdict_code is null and ranked_signals.signal_name = 'manual_recognition_pending_detected'
          then 'detect:manual_recognition:' || ranked_signals.service_name
          else 'detect:' || ranked_signals.anchor_relationship_id
        end
      )
    )
      ranked_signals.*
    from ranked_signals
    order by
      coalesce(
        ranked_signals.classification_id::text,
        case
          -- Keep this expression identical to DISTINCT ON so priority ordering is deterministic.
          when ranked_signals.from_verdict_code is null and ranked_signals.signal_name = 'sla_breach_detected'
          then 'detect:sla:' || ranked_signals.fc_client_id::text || ':' || ranked_signals.service_name
          when ranked_signals.from_verdict_code is null and ranked_signals.signal_name = 'manual_recognition_pending_detected'
          then 'detect:manual_recognition:' || ranked_signals.service_name
          else 'detect:' || ranked_signals.anchor_relationship_id
        end
      ),
      ranked_signals.signal_priority,
      ranked_signals.signal_name
  loop
    inserted_id := null;

    if not p_dry_run then
      if transition_record.to_verdict_code is not null then
        insert into profit_classifications (
          fc_client_id,
          anchor_relationship_id,
          group_id,
          verdict_code,
          source_verdict_raw,
          source_audit_file,
          source_audit_row_hash,
          suggested_classification,
          estimated_annual_revenue,
          notes,
          classified_by,
          classified_at,
          re_evaluate_at,
          last_signal_hash,
          last_signal_at
        ) values (
          transition_record.fc_client_id,
          transition_record.anchor_relationship_id,
          transition_record.group_id,
          transition_record.to_verdict_code,
          transition_record.from_verdict_code,
          transition_record.source_audit_file,
          transition_record.source_audit_row_hash || ':transition:' || transition_record.signal_name || ':' || p_run_at::date::text,
          'auto_transition_' || transition_record.signal_name,
          transition_record.estimated_annual_revenue,
          case
            when transition_record.from_verdict_code is null then
              'Auto-classified as ' || transition_record.to_verdict_code || ' because signal returned: ' || transition_record.signal_name
            else
              'Auto-transitioned from ' || transition_record.from_verdict_code || ' to ' || transition_record.to_verdict_code || ' because signal returned: ' || transition_record.signal_name
          end,
          'system',
          p_run_at,
          p_run_at::date,
          transition_record.signal_name,
          transition_record.last_signal_at
        )
        returning profit_classifications.classification_id into inserted_id;
      end if;

      update profit_classifications
      set
        superseded_at = p_run_at,
        superseded_by_classification_id = inserted_id,
        updated_at = now()
      where profit_classifications.classification_id = transition_record.classification_id
        and profit_classifications.superseded_at is null;
    end if;

    classification_id := transition_record.classification_id;
    fc_client_id := transition_record.fc_client_id;
    fc_client_name := transition_record.fc_client_name;
    from_verdict_code := transition_record.from_verdict_code;
    signal_name := transition_record.signal_name;
    to_verdict_code := transition_record.to_verdict_code;
    anchor_relationship_id := transition_record.anchor_relationship_id;
    anchor_client_business_name := transition_record.anchor_client_business_name;
    evidence_summary := transition_record.evidence_summary;
    would_create_classification_id := inserted_id;
    return next;
  end loop;
end;
$$;

comment on function profit_apply_classification_transitions(timestamptz, boolean) is
  'V0.7.D-2 adds MANUAL_RECOGNITION_PENDING detection and recognition_event_recognized no-op clearance. V0.7.B preserves V0.7.A manual-invoice branches and V0.6.C.a fulfillment classification transitions, and adds SLA_BREACHED detection plus task-complete/project-archived no-op clearance. SLA detection uses current_date::timestamptz as last_signal_at so breached candidates are evaluated at apply-run date. SLA detection dedupe uses detect:sla:<fc_client_id>:<service_name> because multiple breached services can share one Anchor relationship. SLA clearance branches set null::text to_verdict_code even though seeded rules self-point to satisfy the FK; this keeps the V0.7.A apply loop no-op resolution behavior unchanged. Task 1 found tag_type=service project tags are not populated yet, so project_title ILIKE is the only operational SLA clearance path until V0.7.D backfills tags.';
