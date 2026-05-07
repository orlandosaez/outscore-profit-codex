create or replace function profit_run_inactive_client_reemergence_scan(p_run_at timestamptz default now())
returns table (
  superseded_classification_id bigint,
  new_classification_id bigint,
  fc_client_id bigint,
  reemergence_reason text
)
language plpgsql
as $$
declare
  record_to_scan record;
  inserted_id bigint;
  reason text;
begin
  for record_to_scan in
    select
      classification.classification_id,
      classification.fc_client_id,
      classification.classified_at,
      classification.source_audit_file,
      classification.source_audit_row_hash,
      classification.estimated_annual_revenue
    from profit_classifications classification
    where classification.verdict_code = 'INACTIVE_FORMER_CLIENT'
      and classification.superseded_at is null
  loop
    reason := null;

    if exists (
      select 1
      from profit_fc_clients client
      where client.fc_client_id = record_to_scan.fc_client_id
        and coalesce(client.is_archived, false) = false
    ) then
      reason := 'fc_client_became_active';
    elsif exists (
      select 1
      from profit_fc_client_anchor_matches match
      join profit_anchor_agreements agreement
        on agreement.anchor_relationship_id = match.anchor_relationship_id
      where match.fc_client_id = record_to_scan.fc_client_id
        and agreement.display_status = 'active'
    ) then
      reason := 'active_anchor_agreement_created';
    elsif exists (
      select 1
      from profit_fc_task_delivery_classification task
      where task.fc_client_id = record_to_scan.fc_client_id
        and task.task_kind = 'service_delivery'
        and task.is_completed = true
        and task.completed_at > record_to_scan.classified_at
        and task.completed_at >= (p_run_at - interval '365 days')
    ) then
      reason := 'service_delivery_task_completed';
    end if;

    if reason is not null then
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
        record_to_scan.fc_client_id,
        'MIXED',
        'INACTIVE_FORMER_CLIENT',
        record_to_scan.source_audit_file,
        record_to_scan.source_audit_row_hash || ':reemergence:' || p_run_at::date::text,
        'inactive_client_reemerged',
        record_to_scan.estimated_annual_revenue,
        'Re-emergence scan superseded INACTIVE_FORMER_CLIENT because signal returned: ' || reason,
        'system',
        p_run_at,
        p_run_at::date,
        reason,
        p_run_at
      )
      returning classification_id into inserted_id;

      update profit_classifications
      set
        superseded_at = p_run_at,
        superseded_by_classification_id = inserted_id,
        updated_at = now()
      where classification_id = record_to_scan.classification_id;

      superseded_classification_id := record_to_scan.classification_id;
      new_classification_id := inserted_id;
      fc_client_id := record_to_scan.fc_client_id;
      reemergence_reason := reason;
      return next;
    end if;
  end loop;
end;
$$;

comment on function profit_run_inactive_client_reemergence_scan(timestamptz) is
  'Supersedes active INACTIVE_FORMER_CLIENT classifications when an active signal returns. V0.6.B.1 emits MIXED rows for manual reclassification; V0.6.B.2 audit views surface those rows.';
