create or replace view profit_fc_client_anchor_match_candidates as
with fc as (
  select
    client.fc_client_id,
    client.name as fc_client_name,
    profit_normalize_client_name(client.name) as normalized_client_name
  from profit_fc_clients client
),
anchor_candidates as (
  select
    fc.fc_client_id,
    fc.fc_client_name,
    fc.normalized_client_name,
    agreement.anchor_relationship_id,
    agreement.client_business_name as anchor_client_business_name,
    agreement.display_status,
    agreement.last_updated_at,
    count(*) filter (where agreement.display_status = 'active')
      over (partition by fc.fc_client_id) as active_anchor_count,
    count(*) filter (where agreement.display_status = 'terminated')
      over (partition by fc.fc_client_id) as terminated_anchor_count,
    count(*) filter (where agreement.display_status = 'stale')
      over (partition by fc.fc_client_id) as stale_anchor_count,
    count(*) filter (where agreement.anchor_relationship_id is not null)
      over (partition by fc.fc_client_id) as total_anchor_count,
    row_number() over (
      partition by fc.fc_client_id
      order by
        case
          when agreement.display_status = 'active' then 1
          when agreement.display_status = 'terminated' then 2
          when agreement.display_status = 'stale' then 3
          else 4
        end,
        agreement.last_updated_at desc nulls last,
        agreement.anchor_relationship_id
    ) as status_rank_row
  from fc
  left join profit_anchor_agreements agreement
    on agreement.client_business_name is not null
   and profit_normalize_client_name(agreement.client_business_name) = fc.normalized_client_name
),
ranked as (
  select *
  from anchor_candidates
  where status_rank_row = 1
)
select
  fc_client_id,
  fc_client_name,
  case when active_anchor_count = 1 then anchor_relationship_id end as anchor_relationship_id,
  case when active_anchor_count = 1 then anchor_client_business_name end as anchor_client_business_name,
  case
    when total_anchor_count = 0 then 'unmatched'
    when active_anchor_count = 1 then 'auto_exact'
    when active_anchor_count > 1 then 'ambiguous'
    -- terminated-only and stale-only rows remain ambiguous; do not lock stale matches.
    else 'ambiguous'
  end as match_status,
  case
    when active_anchor_count = 1 then 1.0
    else null
  end::numeric as match_confidence,
  normalized_client_name,
  display_status as selected_anchor_status,
  active_anchor_count,
  terminated_anchor_count,
  stale_anchor_count,
  total_anchor_count
from ranked;

comment on view profit_fc_client_anchor_match_candidates is
  'Status-ranked FC-to-Anchor match candidates. Truth table: active > terminated > stale > null; exactly one active row is auto_exact; multiple active rows are ambiguous; one active plus terminated/stale is auto_exact to active; terminated-only and stale-only stay ambiguous. Regression locks: E & O Automotive LLC, 1415 Cortez Rd LLC, 6712 Manatee Ave LLC, Kar Kraft Auto Repair LLC (TempleTerrace), Kar Kraft Services LLC (Zephyrhills), YV Enterprises HB LLC, YV Enterprises PSL LLC.';
