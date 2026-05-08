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
  for transition_record in
    select
      classification.classification_id,
      classification.fc_client_id,
      client.name as fc_client_name,
      classification.verdict_code as from_verdict_code,
      rule.signal_name,
      rule.to_verdict_code,
      match.anchor_relationship_id,
      match.anchor_client_business_name,
      jsonb_build_object(
        'anchor_relationship_id', match.anchor_relationship_id,
        'anchor_client_business_name', match.anchor_client_business_name,
        'display_status', agreement.display_status,
        'effective_date', agreement.effective_date
      ) as evidence_summary,
      classification.source_audit_file,
      classification.source_audit_row_hash,
      classification.estimated_annual_revenue
    from profit_classifications classification
    join profit_fc_clients client
      on client.fc_client_id = classification.fc_client_id
    join profit_classification_transition_rules rule
      on rule.from_verdict_code = classification.verdict_code
     and rule.signal_name = 'active_agreement_appears'
     and rule.enabled = true
    join profit_fc_client_anchor_matches match
      on match.fc_client_id = classification.fc_client_id
    join profit_anchor_agreements agreement
      on agreement.anchor_relationship_id = match.anchor_relationship_id
     and agreement.display_status = 'active'
    where classification.superseded_at is null
      and classification.verdict_code in ('PENDING_ENGAGEMENT_DRAFT', 'PENDING_ENGAGEMENT_SENT')
    order by classification.classification_id
  loop
    inserted_id := null;

    if not p_dry_run then
      insert into profit_classifications (
        fc_client_id,
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
        transition_record.to_verdict_code,
        transition_record.from_verdict_code,
        transition_record.source_audit_file,
        transition_record.source_audit_row_hash || ':transition:' || transition_record.signal_name || ':' || p_run_at::date::text,
        'auto_transition_' || transition_record.signal_name,
        transition_record.estimated_annual_revenue,
        'Auto-transitioned from ' || transition_record.from_verdict_code || ' to ' || transition_record.to_verdict_code || ' because signal returned: ' || transition_record.signal_name,
        'system',
        p_run_at,
        p_run_at::date,
        transition_record.signal_name,
        p_run_at
      )
      returning profit_classifications.classification_id into inserted_id;

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
  'B.2.a scope: only active_agreement_appears is applied today; remaining seeded rules become live in V0.6.C. Applies enabled fulfillment classification transition rules for PENDING_ENGAGEMENT_DRAFT/SENT. Dry-run writes zero rows and returns the same selection. Live apply is append-friendly and idempotent because it only acts on superseded_at is null. Regression locks: Schmidli Enterprises LLC transitions PENDING_SENT -> MIXED; E & O Automotive LLC and unmatched PENDING_SENT rows do not transition.';
