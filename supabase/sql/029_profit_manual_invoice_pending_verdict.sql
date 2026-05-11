insert into profit_classification_verdicts (
  verdict_code,
  label,
  category,
  default_visibility,
  requires_re_evaluate_at,
  auto_transition_enabled,
  description
) values
  ('MANUAL_INVOICE_PENDING', 'Manual invoice pending', 'pending', 'show', false, true, 'Active Anchor agreement has one or more manual-trigger services and no issued Anchor/QBO invoice yet. Operator action: issue the invoice in Anchor.')
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
  ('MANUAL_INVOICE_PENDING', 'manual_invoice_issued', 'INVOICE_OUTSTANDING_PAYMENT_PENDING', false, true, 'At least one matching Anchor invoice has qbo_status is not null for the agreement; manual invoice work is complete and cash collection is now the remaining state.'),
  ('MANUAL_INVOICE_PENDING', 'manual_invoice_agreement_terminated', 'MANUAL_INVOICE_PENDING', false, true, 'No-op resolution marker. Existing taxonomy has no terminated-agreement successor verdict, so the apply function supersedes the active row with superseded_by_classification_id = null when agreement.display_status = terminated and terminated_at is not null.')
on conflict (from_verdict_code, signal_name, to_verdict_code) do update set
  requires_service_type_match = excluded.requires_service_type_match,
  enabled = excluded.enabled,
  notes = excluded.notes,
  updated_at = now();

create or replace view profit_manual_invoice_pending_candidates as
with manual_services as (
  select
    agreement.anchor_relationship_id,
    string_agg(coalesce(nullif(s->>'name', ''), 'Unnamed manual service'), ', ' order by coalesce(s->>'name', '')) as service_name,
    sum(
      nullif(regexp_replace(coalesce(s->>'price', ''), '[^0-9.-]', '', 'g'), '')::numeric
    )::numeric as estimated_annual_revenue
  from profit_anchor_agreements agreement
  cross join lateral jsonb_array_elements(coalesce(agreement.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
  where s->>'trigger' = 'manual'
  group by agreement.anchor_relationship_id
),
invoice_rollup as (
  select
    invoice.anchor_relationship_id,
    count(*)::integer as invoice_count,
    count(*) filter (where invoice.qbo_status is not null)::integer as issued_invoice_count
  from profit_anchor_invoices invoice
  group by invoice.anchor_relationship_id
),
active_manual_classification as (
  select distinct on (classification.anchor_relationship_id)
    classification.classification_id,
    classification.classified_at,
    classification.verdict_code,
    classification.anchor_relationship_id
  from profit_classifications classification
  where classification.verdict_code = 'MANUAL_INVOICE_PENDING'
    and classification.superseded_at is null
  order by classification.anchor_relationship_id, classification.classified_at desc, classification.classification_id desc
)
select
  active_manual_classification.classification_id,
  active_manual_classification.classified_at,
  coalesce(active_manual_classification.verdict_code, 'MANUAL_INVOICE_PENDING') as verdict_code,
  match.fc_client_id,
  agreement.anchor_relationship_id,
  agreement.anchor_relationship_id as agreement_id,
  agreement.client_business_name as client_name,
  manual_services.service_name,
  case
    when coalesce(invoice_rollup.invoice_count, 0) = 0 then 'no_invoice'
    else 'draft_only'
  end as invoice_state,
  greatest(
    0,
    current_date - coalesce(active_manual_classification.classified_at::date, agreement.effective_date::date, current_date)
  )::integer as age_days,
  coalesce(manual_services.estimated_annual_revenue, 0)::numeric as estimated_annual_revenue,
  coalesce(
    agreement.raw->>'link',
    'https://app.sayanchor.com/home/relationship/' || agreement.anchor_relationship_id || '/agreement'
  ) as action_url
from profit_anchor_agreements agreement
join manual_services
  on manual_services.anchor_relationship_id = agreement.anchor_relationship_id
left join invoice_rollup
  on invoice_rollup.anchor_relationship_id = agreement.anchor_relationship_id
left join active_manual_classification
  on active_manual_classification.anchor_relationship_id = agreement.anchor_relationship_id
left join profit_fc_client_anchor_matches match
  on match.anchor_relationship_id = agreement.anchor_relationship_id
where agreement.display_status = 'active'
  and coalesce(invoice_rollup.issued_invoice_count, 0) = 0;

comment on view profit_manual_invoice_pending_candidates is
  'V0.7.A manual-invoice queue seed view. Active agreements with raw->profitSyncServiceSummary service trigger = lowercase manual stay pending while no matching invoice has qbo_status is not null. Draft-only/all-null invoice rows remain pending. action_url uses raw->>link with Anchor relationship fallback.';

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
        coalesce(match.anchor_client_business_name, agreement.client_business_name) as anchor_client_business_name
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
        current_classifications.estimated_annual_revenue
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
      from manual_invoice_issued_signals

      union all

      select *
      from manual_invoice_terminated_signals

      union all

      select *
      from active_agreement_signals

      union all

      select *
      from eligible_signals
    )
    select distinct on (
      coalesce(ranked_signals.classification_id::text, 'detect:' || ranked_signals.anchor_relationship_id)
    )
      ranked_signals.*
    from ranked_signals
    order by
      coalesce(ranked_signals.classification_id::text, 'detect:' || ranked_signals.anchor_relationship_id),
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
  'V0.7.A preserves V0.6.C.a enabled fulfillment classification transitions and adds manual-invoice detection plus issued/terminated clearance. Legacy/group/cash auto-transition correctness still depends on profit_fc_client_anchor_matches.anchor_relationship_id for FC-owned rows. Manual-invoice rows use the classification anchor_relationship_id directly, so unmatched Anchor agreements can still clear after invoice issue or agreement termination. Group-billed signals have priority over standalone signals. Service matching uses macro_service_type, recognition_pattern, and service_period_rule as a composite key, skips multi-service ambiguity, skips unresolved canonical_service_name is null signals, and skips rules where recognition_pattern = manual_review or service_period_rule = manual. Cash signal timing uses profit_cash_collections.collected_at::timestamptz via collection.collection_key = allocation.collection_key. Terminated manual-invoice clearance is a no-op resolution that sets superseded_by_classification_id = null.';
