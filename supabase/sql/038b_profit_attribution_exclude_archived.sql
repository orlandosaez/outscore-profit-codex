-- Migration 038b: V0.7.B.4 attribution resolver excludes archived FC clients (V0.7.D-3 hotfix Part B)
--
-- Bug surfaced 2026-05-13 operator audit: Kar Kraft Auto Repair LLC SLA queue
-- row pointed at fc_client_id 4115780 (a duplicate FC client without the
-- "(TempleTerrace)" suffix that operator uses to disambiguate). The duplicate
-- was already marked is_archived=true in profit_fc_clients (W17 sync had
-- detected FC's archive state), but the V0.7.B.4 attribution resolver still
-- considered it a candidate because the cross-join on profit_fc_clients had
-- no is_archived filter.
--
-- Same fix prevents future ghost records (any FC client locally marked
-- archived) from outranking real records when names collide.
--
-- Change: add `and fc.is_archived = false` to the label_resolution_candidates
-- cross join. Also add `and holder.is_archived = false` to the agreement_holder
-- LEFT JOIN so attribution falls back cleanly when the agreement match points
-- at an archived FC client.
--
-- All other CTE shape preserved verbatim from 034a.

create or replace view profit_anchor_services_attributed as
with raw_services as (
  select
    ag.anchor_relationship_id,
    ag.client_business_name as agreement_client_business_name,
    s->>'name' as raw_service_name,
    (profit_parse_anchor_service_name(s->>'name')).canonical_service_name as canonical_service_name,
    (profit_parse_anchor_service_name(s->>'name')).label as label,
    s->>'trigger' as service_trigger,
    s->>'occurrence' as service_occurrence,
    coalesce((s->>'is_billed_upfront')::boolean, false) as service_is_billed_upfront,
    nullif(regexp_replace(coalesce(s->>'price', ''), '[^0-9.-]', '', 'g'), '')::numeric as service_price,
    s->>'status' as service_status,
    s->>'service_id' as service_id
  from profit_anchor_agreements ag
  cross join lateral jsonb_array_elements(coalesce(ag.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
  where ag.display_status = 'active'
),
deduplicated_services as (
  select distinct on (anchor_relationship_id, canonical_service_name, coalesce(label, ''))
    *
  from raw_services
  order by anchor_relationship_id, canonical_service_name, coalesce(label, ''), service_id
),
agreement_holder as (
  -- V0.7.D-3 Part B: pick the BEST single FC match per anchor agreement.
  -- profit_fc_client_anchor_matches can have multiple rows per anchor_relationship_id
  -- (one manual_override + one auto_exact pointing at a ghost duplicate, observed
  -- 2026-05-13 on Kar Kraft). Preference order:
  --   1. manual_override (operator-authored)
  --   2. auto_exact (Workflow 25 candidate)
  -- Both filtered to is_archived=false holders only.
  select
    ds.*,
    best_match.fc_client_id as agreement_holder_fc_client_id,
    best_match.fc_client_name as agreement_holder_fc_client_name
  from deduplicated_services ds
  left join lateral (
    select m.fc_client_id, h.name as fc_client_name
    from profit_fc_client_anchor_matches m
    join profit_fc_clients h
      on h.fc_client_id = m.fc_client_id
     and h.is_archived = false
    where m.anchor_relationship_id = ds.anchor_relationship_id
    order by
      case m.match_method when 'manual_override' then 1 when 'auto_exact' then 2 else 3 end,
      m.fc_client_id
    limit 1
  ) best_match on true
),
label_resolution_candidates as (
  select
    ah.*,
    fc.fc_client_id as candidate_fc_client_id,
    fc.name as candidate_fc_client_name,
    case
      when profit_collapse_spaces(profit_normalize_name_for_match(ah.label))
         = profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
        then 1
      when ah.label is not null
       and profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
           like profit_collapse_spaces(profit_normalize_name_for_match(ah.label)) || ' %'
        then 2
      when ah.label is not null
       and ah.label !~ ','
       and array_length(regexp_split_to_array(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), ' '), 1) >= 2
       and (
         profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
           like (substring(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)) from '\S+\s*$')
                || ' '
                || regexp_replace(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), '\s+\S+\s*$', '')
                || ' %')
         or
         profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
           = (substring(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)) from '\S+\s*$')
              || ' '
              || regexp_replace(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), '\s+\S+\s*$', ''))
       )
        then 3
      when ah.label is not null
       and ah.label ~ ','
       and profit_collapse_spaces(profit_normalize_name_for_match(fc.name)) like
           (split_part(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), ' ', 1)
            || ' '
            || split_part(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), ' ', 2)
            || '%')
        then 4
      else null
    end as strategy_rank
  from agreement_holder ah
  cross join profit_fc_clients fc
  where ah.label is not null
    -- V0.7.D-3 Part B: never resolve a label to an archived FC client.
    -- Without this, ghost records (renamed/merged inside FC, not yet
    -- locally archived OR locally archived but still in the resolver's
    -- candidate set) could outrank real records on exact-name match.
    and fc.is_archived = false
),
label_resolutions as (
  select distinct on (anchor_relationship_id, canonical_service_name, coalesce(label, ''))
    *
  from label_resolution_candidates
  where strategy_rank is not null
  order by
    anchor_relationship_id,
    canonical_service_name,
    coalesce(label, ''),
    strategy_rank asc,
    abs(length(candidate_fc_client_name) - length(label)) asc,
    candidate_fc_client_name asc
)
select
  ah.anchor_relationship_id,
  ah.agreement_client_business_name,
  ah.agreement_holder_fc_client_id,
  ah.agreement_holder_fc_client_name,
  ah.raw_service_name,
  ah.canonical_service_name,
  ah.label,
  coalesce(lr.candidate_fc_client_id, ah.agreement_holder_fc_client_id) as attributed_fc_client_id,
  coalesce(lr.candidate_fc_client_name, ah.agreement_holder_fc_client_name) as attributed_fc_client_name,
  (ah.label is not null and lr.candidate_fc_client_id is null) as label_unresolved,
  lr.strategy_rank as resolution_strategy,
  ah.service_trigger,
  ah.service_occurrence,
  ah.service_is_billed_upfront,
  ah.service_price,
  ah.service_status,
  ah.service_id
from agreement_holder ah
left join label_resolutions lr
  on lr.anchor_relationship_id = ah.anchor_relationship_id
 and lr.canonical_service_name = ah.canonical_service_name
 and coalesce(lr.label, '') = coalesce(ah.label, '');

comment on view profit_anchor_services_attributed is
  'V0.7.B.4 + V0.7.D-3 Part B (038b): every active Anchor service attributed to an FC client. Now excludes archived FC clients from the resolver candidate set (prevents ghost-record duplicates from outranking real records on exact-name match). Unlabeled services attribute to the agreement holder (skipped if holder is archived). Labeled services attempt fuzzy resolution against active profit_fc_clients via four strategies (normalized exact, prefix, reversed-name prefix, comma-format token prefix). Unresolved labels stay on agreement holder with label_unresolved=true flag. No content-specific rules.';
