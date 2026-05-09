create or replace view profit_pipeline_classification_transition_blockers as
with active_targets as (
  select
    classification.classification_id,
    classification.fc_client_id,
    client.name as fc_client_name,
    classification.verdict_code as from_verdict_code,
    classification.classified_at,
    match.anchor_relationship_id,
    match.anchor_client_business_name
  from profit_classifications classification
  join profit_fc_clients client
    on client.fc_client_id = classification.fc_client_id
  left join profit_fc_client_anchor_matches match
    on match.fc_client_id = classification.fc_client_id
   and match.anchor_relationship_id is not null
  where classification.superseded_at is null
    and classification.verdict_code in (
      'LEGACY_ENGAGEMENT_PRE_ANCHOR',
      'INVOICE_OUTSTANDING_PAYMENT_PENDING'
    )
),
applicable_rules as (
  select
    active_targets.classification_id,
    active_targets.fc_client_id,
    active_targets.fc_client_name,
    active_targets.from_verdict_code,
    rule.signal_name,
    rule.to_verdict_code,
    active_targets.anchor_relationship_id,
    active_targets.anchor_client_business_name
  from active_targets
  join profit_classification_transition_rules rule
    on rule.from_verdict_code = active_targets.from_verdict_code
   and rule.enabled = true
   and rule.signal_name in (
     'first_matching_anchor_invoice_mid_cycle',
     'first_matching_anchor_invoice_group_billed',
     'cash_collected_group_parent',
     'cash_collected_standalone_mid_cycle'
   )
),
invoice_signal_events as (
  select
    active_targets.classification_id,
    case
      when group_relationships.anchor_relationship_id is not null
        then 'first_matching_anchor_invoice_group_billed'
      else 'first_matching_anchor_invoice_mid_cycle'
    end as signal_name,
    event.revenue_event_key,
    event.canonical_service_name,
    rule_service.macro_service_type,
    rule_service.recognition_pattern,
    rule_service.service_period_rule,
    rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule as service_type_key
  from active_targets
  left join lateral (
    select distinct sibling_match.anchor_relationship_id
    from profit_client_group_members source_member
    join profit_client_group_members sibling_member
      on sibling_member.group_id = source_member.group_id
     and sibling_member.active = true
     and sibling_member.fc_client_id <> active_targets.fc_client_id
    join profit_fc_client_anchor_matches sibling_match
      on sibling_match.fc_client_id = sibling_member.fc_client_id
     and sibling_match.anchor_relationship_id is not null
    where source_member.fc_client_id = active_targets.fc_client_id
      and source_member.active = true
  ) group_relationships on true
  join profit_anchor_invoices invoice
    on invoice.anchor_relationship_id = coalesce(group_relationships.anchor_relationship_id, active_targets.anchor_relationship_id)
   and invoice.issue_date > active_targets.classified_at
  join profit_revenue_events event
    on event.anchor_invoice_id = invoice.anchor_invoice_id
  left join profit_service_recognition_rules rule_service
    on rule_service.service_name = event.canonical_service_name
  where active_targets.from_verdict_code = 'LEGACY_ENGAGEMENT_PRE_ANCHOR'
),
cash_signal_events as (
  select
    active_targets.classification_id,
    case
      when group_relationships.anchor_relationship_id is not null
        then 'cash_collected_group_parent'
      else 'cash_collected_standalone_mid_cycle'
    end as signal_name,
    event.revenue_event_key,
    event.canonical_service_name,
    rule_service.macro_service_type,
    rule_service.recognition_pattern,
    rule_service.service_period_rule,
    rule_service.macro_service_type || '|' || rule_service.recognition_pattern || '|' || rule_service.service_period_rule as service_type_key
  from active_targets
  left join lateral (
    select distinct sibling_match.anchor_relationship_id
    from profit_client_group_members source_member
    join profit_client_group_members sibling_member
      on sibling_member.group_id = source_member.group_id
     and sibling_member.active = true
     and sibling_member.fc_client_id <> active_targets.fc_client_id
    join profit_fc_client_anchor_matches sibling_match
      on sibling_match.fc_client_id = sibling_member.fc_client_id
     and sibling_match.anchor_relationship_id is not null
    where source_member.fc_client_id = active_targets.fc_client_id
      and source_member.active = true
  ) group_relationships on true
  join profit_cash_collections collection
    on collection.anchor_relationship_id = coalesce(group_relationships.anchor_relationship_id, active_targets.anchor_relationship_id)
   and collection.collected_at::timestamptz > active_targets.classified_at
  join profit_collection_revenue_allocations allocation
    on collection.collection_key = allocation.collection_key
  join profit_revenue_events event
    on event.revenue_event_key = allocation.revenue_event_key
  left join profit_service_recognition_rules rule_service
    on rule_service.service_name = event.canonical_service_name
  where active_targets.from_verdict_code = 'INVOICE_OUTSTANDING_PAYMENT_PENDING'
),
signal_events as (
  select * from invoice_signal_events
  union all
  select * from cash_signal_events
),
signal_rollups as (
  select
    classification_id,
    signal_name,
    count(*) as signal_event_count,
    count(*) filter (where canonical_service_name is null) as unresolved_canonical_count,
    count(distinct service_type_key) filter (where service_type_key is not null) as service_type_count,
    bool_or(
      recognition_pattern = 'manual_review'
      or service_period_rule = 'manual'
    ) as has_manual_service_rule,
    jsonb_build_object(
      'signal_event_count', count(*),
      'sample_revenue_event_keys', (
        select jsonb_agg(sample.revenue_event_key order by sample.revenue_event_key)
        from (
          select event_sample.revenue_event_key
          from signal_events event_sample
          where event_sample.classification_id = signal_events.classification_id
            and event_sample.signal_name = signal_events.signal_name
          order by event_sample.revenue_event_key
          limit 5
        ) sample
      )
    ) as evidence_summary
  from signal_events
  group by classification_id, signal_name
),
blockers as (
  -- Grain: one row per applicable transition rule, classification_id, signal_name, blocker_reason.
  -- For no_anchor_match, emit one row per applicable transition rule so operators can see every blocked rule.
  select
    applicable_rules.classification_id,
    applicable_rules.fc_client_id,
    applicable_rules.fc_client_name,
    applicable_rules.from_verdict_code,
    applicable_rules.signal_name,
    applicable_rules.to_verdict_code,
    'no_anchor_match'::text as blocker_reason,
    applicable_rules.anchor_relationship_id,
    applicable_rules.anchor_client_business_name,
    jsonb_build_object('reason', 'no persisted anchor_relationship_id in profit_fc_client_anchor_matches') as evidence_summary
  from applicable_rules
  where applicable_rules.anchor_relationship_id is null

  union all

  select
    applicable_rules.classification_id,
    applicable_rules.fc_client_id,
    applicable_rules.fc_client_name,
    applicable_rules.from_verdict_code,
    applicable_rules.signal_name,
    applicable_rules.to_verdict_code,
    'multi_service_ambiguity'::text as blocker_reason,
    applicable_rules.anchor_relationship_id,
    applicable_rules.anchor_client_business_name,
    signal_rollups.evidence_summary
  from applicable_rules
  join signal_rollups
    on signal_rollups.classification_id = applicable_rules.classification_id
   and signal_rollups.signal_name = applicable_rules.signal_name
  where applicable_rules.anchor_relationship_id is not null
    and signal_rollups.service_type_count > 1

  union all

  select
    applicable_rules.classification_id,
    applicable_rules.fc_client_id,
    applicable_rules.fc_client_name,
    applicable_rules.from_verdict_code,
    applicable_rules.signal_name,
    applicable_rules.to_verdict_code,
    'unresolved_canonical_service'::text as blocker_reason,
    applicable_rules.anchor_relationship_id,
    applicable_rules.anchor_client_business_name,
    signal_rollups.evidence_summary
  from applicable_rules
  join signal_rollups
    on signal_rollups.classification_id = applicable_rules.classification_id
   and signal_rollups.signal_name = applicable_rules.signal_name
  where applicable_rules.anchor_relationship_id is not null
    and signal_rollups.unresolved_canonical_count > 0

  union all

  select
    applicable_rules.classification_id,
    applicable_rules.fc_client_id,
    applicable_rules.fc_client_name,
    applicable_rules.from_verdict_code,
    applicable_rules.signal_name,
    applicable_rules.to_verdict_code,
    'manual_review_service_rule'::text as blocker_reason,
    applicable_rules.anchor_relationship_id,
    applicable_rules.anchor_client_business_name,
    signal_rollups.evidence_summary
  from applicable_rules
  join signal_rollups
    on signal_rollups.classification_id = applicable_rules.classification_id
   and signal_rollups.signal_name = applicable_rules.signal_name
  where applicable_rules.anchor_relationship_id is not null
    and coalesce(signal_rollups.has_manual_service_rule, false) = true
)
select *
from blockers;

create or replace view profit_pipeline_due_reclassifications as
select
  candidate.current_classification_id as classification_id,
  candidate.fc_client_id,
  candidate.fc_client_name,
  candidate.current_verdict_code,
  candidate.default_visibility,
  candidate.re_evaluate_at,
  candidate.anchor_display_status,
  candidate.open_invoice_balance_amount
from profit_fulfillment_audit_candidates candidate
where candidate.current_classification_id is not null
  and candidate.re_evaluate_at <= current_date;

create or replace view profit_pipeline_stuck_recognition_triggers as
select
  event.revenue_event_key,
  event.anchor_invoice_id,
  event.anchor_relationship_id,
  event.macro_service_type,
  event.source_amount,
  event.recognition_status,
  event.recognition_rule,
  event.candidate_period_month,
  event.loaded_at,
  invoice.invoice_number,
  event.service_name,
  event.canonical_service_name,
  now() as evaluated_at
from profit_revenue_events event
left join profit_anchor_invoices invoice
  on invoice.anchor_invoice_id = event.anchor_invoice_id
left join profit_revenue_events_ready_for_recognition ready
  on ready.revenue_event_key = event.revenue_event_key
where event.recognition_status like 'pending_%'
  and event.recognition_period_month is null
  and coalesce(event.recognized_amount, 0) = 0
  and ready.revenue_event_key is null
  -- Stuck threshold: pending revenue events older than 30 days are surfaced for triage.
  -- Threshold is operational policy; if changed, update this view rather than parameterizing.
  and coalesce(event.loaded_at, now()) < now() - interval '30 days';

comment on view profit_pipeline_classification_transition_blockers is
  'V0.6.C.a diagnostic view for active classifications that expanded auto-transition rules cannot safely apply. Grain is one row per classification_id, signal_name, blocker_reason; no_anchor_match expands to one row per applicable transition rule.';

comment on view profit_pipeline_due_reclassifications is
  'V0.6.C.a pipeline-facing due reclassification surface. Thin wrapper over profit_fulfillment_audit_candidates where re_evaluate_at <= current_date.';

comment on view profit_pipeline_stuck_recognition_triggers is
  'V0.6.C.a diagnostic view for pending revenue events older than the hardcoded 30-day stuck threshold that are not currently ready for recognition.';
