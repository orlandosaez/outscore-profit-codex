create or replace function profit_reconcile_fc_client_anchor_matches(
  p_dry_run boolean default true
)
returns table (
  fc_client_id bigint,
  fc_client_name text,
  anchor_relationship_id text,
  anchor_client_business_name text,
  persisted_match_status text,
  persisted_match_method text,
  candidate_match_status text,
  candidate_anchor_relationship_id text,
  candidate_anchor_client_business_name text,
  candidate_selected_anchor_status text,
  action text
)
language plpgsql
as $$
begin
  -- manual_override rows are protected: only persisted match_method = 'auto_exact'
  -- rows can be reconciled. Fixture: relationship_id_changed_branch.
  -- Fixture: second_live_call_returns_zero.
  return query
  with demote_candidates as (
    select
      persisted.fc_client_id,
      persisted.fc_client_name,
      persisted.anchor_relationship_id,
      persisted.anchor_client_business_name,
      persisted.match_status as persisted_match_status,
      persisted.match_method as persisted_match_method,
      coalesce(candidate.match_status, 'unmatched') as candidate_match_status,
      candidate.anchor_relationship_id as candidate_anchor_relationship_id,
      candidate.anchor_client_business_name as candidate_anchor_client_business_name,
      candidate.selected_anchor_status as candidate_selected_anchor_status
    from profit_fc_client_anchor_matches persisted
    left join profit_fc_client_anchor_match_candidates candidate
      on candidate.fc_client_id = persisted.fc_client_id
    where persisted.match_method = 'auto_exact'
      and (
        coalesce(candidate.match_status, 'unmatched') <> 'auto_exact'
        or candidate.anchor_relationship_id is distinct from persisted.anchor_relationship_id
      )
  ),
  deleted_rows as (
    delete from profit_fc_client_anchor_matches persisted
    using demote_candidates demote
    where p_dry_run = false
      and persisted.fc_client_id = demote.fc_client_id
      and persisted.match_method = 'auto_exact'
    returning persisted.fc_client_id
  )
  select
    demote.fc_client_id,
    demote.fc_client_name,
    demote.anchor_relationship_id,
    demote.anchor_client_business_name,
    demote.persisted_match_status,
    demote.persisted_match_method,
    demote.candidate_match_status,
    demote.candidate_anchor_relationship_id,
    demote.candidate_anchor_client_business_name,
    demote.candidate_selected_anchor_status,
    case
      when p_dry_run then 'would_delete'
      else 'deleted'
    end as action
  from demote_candidates demote
  where p_dry_run
     or exists (
       select 1
       from deleted_rows deleted
       where deleted.fc_client_id = demote.fc_client_id
     )
  order by demote.fc_client_name, demote.fc_client_id;
end;
$$;

comment on function profit_reconcile_fc_client_anchor_matches(boolean) is
  'V0.6.C.a dry-run/live reconciliation for derived FC-to-Anchor matches. Hard-deletes persisted auto_exact rows that no longer qualify per profit_fc_client_anchor_match_candidates, including status-downgraded rows and relationship-id changed rows. Manual override rows are protected. Idempotent: second live call returns zero rows. V0.6.C.b orchestration should run Workflow 05 sync, Workflow 25 upsert, then this reconcile function before downstream audit refresh, re-emergence scan, and transition apply.';
