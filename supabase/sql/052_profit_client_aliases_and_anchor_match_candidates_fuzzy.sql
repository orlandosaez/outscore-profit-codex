-- Migration 052: V0.7.J J.2/J.3 alias escape hatch + candidate-only fuzzy tier.
--
-- Option A: fuzzy rows are surfaced only in
-- profit_fc_client_anchor_match_candidates with match_status = 'auto_fuzzy'.
-- No fuzzy match is persisted by this migration or by the reconcile RPC.
--
-- Gap/regression fixtures:
--   fixture: bachert_article_suffix_normalizes
--   fixture: hadar_sorted_helper_audit_only
--   fixture: anderson_dedup_suffix_normalizes
--   fixture: midas_south_alias_auto_exact
--   fixture: midas_north_alias_auto_exact
--   fixture: lees_apostrophe_suffix_normalizes
--   fixture: corey_monaghan_monanghan_fuzzy_candidate
--   Regression locks: E & O Automotive LLC; 1415 Cortez Rd LLC;
--   6712 Manatee Ave LLC; Kar Kraft Auto Repair LLC (TempleTerrace);
--   Kar Kraft Services LLC (Zephyrhills); YV Enterprises HB LLC;
--   YV Enterprises PSL LLC; Corey Monaghan / Corey Monanghan.

create extension if not exists pg_trgm;

create table if not exists profit_client_aliases (
  fc_client_id bigint not null references profit_fc_clients(fc_client_id),
  alias text not null,
  alias_source text not null check (
    alias_source in (
      'manual_fka',
      'manual_dba',
      'manual_legal_to_dba',
      'operator_note'
    )
  ),
  created_at timestamptz not null default now(),
  primary key (fc_client_id, alias)
);

create index if not exists idx_profit_client_aliases_normalized_alias
  on profit_client_aliases (profit_normalize_client_name(alias));

insert into profit_client_aliases (fc_client_id, alias, alias_source)
select fc.fc_client_id, seed.alias, 'manual_legal_to_dba'
from (
  values
    ('1415 Cortez Rd LLC'::text, 'Midas South Bradenton'::text),
    ('6712 Manatee Ave LLC'::text, 'Midas North Bradenton'::text)
) as seed(fc_name, alias)
join profit_fc_clients fc
  on profit_normalize_client_name(fc.name) = profit_normalize_client_name(seed.fc_name)
on conflict (fc_client_id, alias) do update set
  alias_source = excluded.alias_source;

create or replace view profit_fc_client_anchor_match_candidates as
with fc as (
  select
    client.fc_client_id,
    client.name as fc_client_name,
    profit_normalize_client_name(client.name) as normalized_client_name
  from profit_fc_clients client
),
fc_alias as (
  select
    alias.fc_client_id,
    profit_normalize_client_name(alias.alias) as normalized_alias_name
  from profit_client_aliases alias
),
anchor_base as (
  select
    agreement.anchor_relationship_id,
    agreement.client_business_name as anchor_client_business_name,
    agreement.display_status,
    agreement.last_updated_at,
    profit_normalize_client_name(agreement.client_business_name) as normalized_anchor_name
  from profit_anchor_agreements agreement
  where agreement.client_business_name is not null
),
exact_candidates as (
  select distinct
    fc.fc_client_id,
    fc.fc_client_name,
    fc.normalized_client_name,
    anchor_base.anchor_relationship_id,
    anchor_base.anchor_client_business_name,
    anchor_base.display_status,
    anchor_base.last_updated_at,
    'exact'::text as match_tier,
    1.0::numeric as similarity_score
  from fc
  join anchor_base
    on anchor_base.normalized_anchor_name = fc.normalized_client_name
    or exists (
      select 1
      from fc_alias alias
      where alias.fc_client_id = fc.fc_client_id
        and alias.normalized_alias_name = anchor_base.normalized_anchor_name
    )
),
fuzzy_candidates as (
  select
    fc.fc_client_id,
    fc.fc_client_name,
    fc.normalized_client_name,
    anchor_base.anchor_relationship_id,
    anchor_base.anchor_client_business_name,
    anchor_base.display_status,
    anchor_base.last_updated_at,
    'fuzzy'::text as match_tier,
    similarity(fc.normalized_client_name, anchor_base.normalized_anchor_name)::numeric as similarity_score
  from fc
  join anchor_base
    on fc.normalized_client_name is not null
   and anchor_base.normalized_anchor_name is not null
   and similarity(fc.normalized_client_name, anchor_base.normalized_anchor_name) >= 0.92
  where not exists (
      select 1
      from exact_candidates exact
      where exact.fc_client_id = fc.fc_client_id
    )
    and not exists (
      select 1
      from exact_candidates exact
      where exact.anchor_relationship_id = anchor_base.anchor_relationship_id
    )
),
all_candidates as (
  select * from exact_candidates
  union all
  select * from fuzzy_candidates
),
ranked_candidates as (
  select
    fc.fc_client_id,
    fc.fc_client_name,
    fc.normalized_client_name,
    anchor_candidate.anchor_relationship_id,
    anchor_candidate.anchor_client_business_name,
    anchor_candidate.display_status,
    anchor_candidate.last_updated_at,
    anchor_candidate.match_tier,
    anchor_candidate.similarity_score,
    count(*) filter (where anchor_candidate.display_status = 'active')
      over (partition by fc.fc_client_id) as active_anchor_count,
    count(*) filter (where anchor_candidate.display_status = 'terminated')
      over (partition by fc.fc_client_id) as terminated_anchor_count,
    count(*) filter (where anchor_candidate.display_status = 'stale')
      over (partition by fc.fc_client_id) as stale_anchor_count,
    count(*) filter (where anchor_candidate.anchor_relationship_id is not null)
      over (partition by fc.fc_client_id) as total_anchor_count,
    row_number() over (
      partition by fc.fc_client_id
      order by
        case
          when anchor_candidate.display_status = 'active' then 1
          when anchor_candidate.display_status = 'terminated' then 2
          when anchor_candidate.display_status = 'stale' then 3
          else 4
        end,
        case
          when anchor_candidate.match_tier = 'exact' then 1
          when anchor_candidate.match_tier = 'fuzzy' then 2
          else 3
        end,
        anchor_candidate.similarity_score desc nulls last,
        anchor_candidate.last_updated_at desc nulls last,
        anchor_candidate.anchor_relationship_id
    ) as status_rank_row
  from fc
  left join all_candidates anchor_candidate
    on anchor_candidate.fc_client_id = fc.fc_client_id
),
ranked as (
  select *
  from ranked_candidates
  where status_rank_row = 1
)
select
  fc_client_id,
  fc_client_name,
  case when active_anchor_count = 1 then anchor_relationship_id end as anchor_relationship_id,
  case when active_anchor_count = 1 then anchor_client_business_name end as anchor_client_business_name,
  case
    when total_anchor_count = 0 then 'unmatched'
    when active_anchor_count = 1 and match_tier = 'exact' then 'auto_exact'
    when active_anchor_count = 1 and match_tier = 'fuzzy' then 'auto_fuzzy'
    when active_anchor_count > 1 then 'ambiguous'
    -- terminated-only and stale-only rows remain ambiguous; do not lock stale matches.
    else 'ambiguous'
  end as match_status,
  case
    when active_anchor_count = 1 and match_tier = 'exact' then 1.0
    when active_anchor_count = 1 and match_tier = 'fuzzy' then similarity_score
    else null
  end::numeric as match_confidence,
  normalized_client_name,
  display_status as selected_anchor_status,
  active_anchor_count,
  terminated_anchor_count,
  stale_anchor_count,
  total_anchor_count
from ranked;

comment on table profit_client_aliases is
  'V0.7.J operator-managed FC client aliases for confirmed FKA/DBA/legal-to-DBA names. Seeded only for the two Midas legal-name rows in this migration.';

comment on view profit_fc_client_anchor_match_candidates is
  'V0.7.J candidate-only fuzzy FC-to-Anchor matching. Status truth table preserved from 024a: active > terminated > stale > null; exactly one active row is auto_exact or auto_fuzzy by tier; multiple active rows are ambiguous; terminated-only and stale-only stay ambiguous. Fuzzy threshold is 0.92 and is not persisted automatically.';

-- Verify: schema-only checks. Do not invoke side-effect RPCs or inspect live data.
do $$
begin
  if to_regclass('public.profit_client_aliases') is null then
    raise exception '052 verify FAIL: profit_client_aliases missing';
  end if;

  if to_regclass('public.profit_fc_client_anchor_match_candidates') is null then
    raise exception '052 verify FAIL: profit_fc_client_anchor_match_candidates missing';
  end if;

  raise notice '052 verify: schema OK';
end $$;
