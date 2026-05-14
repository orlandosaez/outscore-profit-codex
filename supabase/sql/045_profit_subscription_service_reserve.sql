-- Migration 045: V0.7.E.3 Sprint E — Subscription Service Reserve labor-cost calc
--
-- Per the T&C revenue recognition principle: Subscription Monthly Fees
-- are earned-on-receipt, NOT GAAP liability. But operationally we need
-- to know whether each Subscription/Mixed client's labor cost matches
-- the fee we charge — i.e. are we under-pricing the relationship?
--
-- Two views introduced:
--
--   profit_anchor_subscription_services
--     Flattens profit_anchor_agreements.raw->profitSyncServiceSummary
--     into per-service rows for recurring (monthly/quarterly/yearly)
--     non-completed lines on active agreements. Reused for future
--     subscription-fee analytics.
--
--   profit_subscription_service_reserve
--     Per-client roll-up for Subscription + Mixed engagement_type:
--       - monthly_subscription_fee (sum of recurring service prices,
--         normalized to monthly basis: quarterly/3, yearly/12)
--       - monthly_avg_labor_cost (90-day trailing labor cost / 3)
--       - monthly_contribution_margin = fee - labor
--       - margin_pct
--       - profitability_state: profitable / breakeven / overbudget
--
-- "Reserve" semantic: operational cash buffer. If a Subscription
-- client's monthly labor cost > fee, we're spending the reserve faster
-- than we're collecting it. Margin > 0 means the relationship is
-- self-funding.
--
-- Sprint D limitation addressed: Mixed engagement clients (16) can now
-- be evaluated individually — operator can decide which to reclassify
-- to Project (book as Deferred Revenue) vs. keep as Subscription (book
-- as Service Reserve) based on labor pattern.

-- ============================================================
-- A. profit_anchor_subscription_services
-- ============================================================
create or replace view profit_anchor_subscription_services as
select
  agreement.anchor_relationship_id,
  agreement.client_business_name,
  s->>'name' as service_name,
  s->>'occurrence' as occurrence,
  s->>'trigger' as service_trigger,
  s->>'status' as service_status,
  nullif(regexp_replace(coalesce(s->>'price', ''), '[^0-9.-]', '', 'g'), '')::numeric as price,
  -- Normalize to monthly basis for direct comparison with labor cost.
  -- yearly/12 ≈ 8.33%, quarterly/3 ≈ 33.3%, monthly/1.
  case s->>'occurrence'
    when 'monthly' then nullif(regexp_replace(coalesce(s->>'price', ''), '[^0-9.-]', '', 'g'), '')::numeric
    when 'quarterly' then nullif(regexp_replace(coalesce(s->>'price', ''), '[^0-9.-]', '', 'g'), '')::numeric / 3.0
    when 'yearly' then nullif(regexp_replace(coalesce(s->>'price', ''), '[^0-9.-]', '', 'g'), '')::numeric / 12.0
    else null
  end::numeric as monthly_equivalent_price
from profit_anchor_agreements agreement
cross join lateral jsonb_array_elements(coalesce(agreement.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
where agreement.display_status = 'active'
  and coalesce(s->>'status', '') <> 'completed'
  and s->>'occurrence' in ('monthly', 'quarterly', 'yearly');

comment on view profit_anchor_subscription_services is
  'V0.7.E.3 (045): flattened recurring service lines from active Anchor
   agreements. monthly_equivalent_price normalizes to monthly basis
   (yearly/12, quarterly/3) for direct comparison with monthly labor cost.';

-- ============================================================
-- B. profit_subscription_service_reserve
-- ============================================================
create or replace view profit_subscription_service_reserve as
with monthly_fee_per_client as (
  select
    anchor_relationship_id,
    client_business_name,
    sum(monthly_equivalent_price)::numeric as monthly_subscription_fee,
    count(*)::integer as recurring_service_count
  from profit_anchor_subscription_services
  group by 1, 2
),
labor_90d as (
  select
    te.anchor_relationship_id,
    sum(te.labor_cost)::numeric as last_90d_labor_cost,
    sum(te.hours)::numeric as last_90d_hours,
    max(te.entry_date) as last_entry_date,
    count(distinct te.staff_name) as distinct_staff
  from profit_time_entries te
  where te.match_status = 'matched'
    and te.entry_date >= current_date - interval '90 days'
  group by 1
),
client_engagement as (
  select
    m.anchor_relationship_id,
    m.fc_client_id,
    coalesce(cf.engagement_type, 'unclassified') as engagement_type,
    fc.name as fc_client_name
  from profit_fc_client_anchor_matches m
  left join profit_fc_clients fc
    on fc.fc_client_id = m.fc_client_id and fc.is_archived = false
  left join profit_fc_client_staff_from_custom_fields cf
    on cf.fc_client_id = m.fc_client_id
)
select
  mfpc.anchor_relationship_id,
  ce.fc_client_id,
  coalesce(ce.fc_client_name, mfpc.client_business_name) as client_name,
  mfpc.client_business_name as anchor_business_name,
  coalesce(ce.engagement_type, 'unclassified') as engagement_type,
  mfpc.recurring_service_count,
  round(mfpc.monthly_subscription_fee, 2) as monthly_subscription_fee,
  round(coalesce(labor_90d.last_90d_labor_cost, 0), 2) as last_90d_labor_cost,
  round(coalesce(labor_90d.last_90d_labor_cost, 0) / 3.0, 2) as monthly_avg_labor_cost,
  round(coalesce(labor_90d.last_90d_hours, 0), 2) as last_90d_hours,
  round(mfpc.monthly_subscription_fee - coalesce(labor_90d.last_90d_labor_cost, 0) / 3.0, 2) as monthly_contribution_margin,
  case
    when mfpc.monthly_subscription_fee = 0 then null
    else round(
      ((mfpc.monthly_subscription_fee - coalesce(labor_90d.last_90d_labor_cost, 0) / 3.0)
        / mfpc.monthly_subscription_fee * 100.0)::numeric, 1)
  end as monthly_contribution_margin_pct,
  case
    when mfpc.monthly_subscription_fee = 0 then 'no_fee'
    when coalesce(labor_90d.last_90d_labor_cost, 0) = 0 then 'no_labor_recorded'
    when (coalesce(labor_90d.last_90d_labor_cost, 0) / 3.0) > mfpc.monthly_subscription_fee * 1.10
      then 'overbudget'
    when (coalesce(labor_90d.last_90d_labor_cost, 0) / 3.0) > mfpc.monthly_subscription_fee * 0.90
      then 'breakeven'
    else 'profitable'
  end as profitability_state,
  labor_90d.distinct_staff,
  labor_90d.last_entry_date
from monthly_fee_per_client mfpc
left join client_engagement ce on ce.anchor_relationship_id = mfpc.anchor_relationship_id
left join labor_90d on labor_90d.anchor_relationship_id = mfpc.anchor_relationship_id
where coalesce(ce.engagement_type, 'unclassified') in ('Subscription', 'Mixed', 'unclassified');

comment on view profit_subscription_service_reserve is
  'V0.7.E.3 (045): per-client labor cost vs. subscription fee for
   Subscription + Mixed (+ unclassified) engagement clients. Powers
   service-reserve profitability surface and informs Mixed engagement
   reclassification decisions (Sprint D limitation).
   monthly_avg_labor_cost = 90-day trailing labor / 3.
   profitability_state thresholds: overbudget if labor > 110% of fee,
   breakeven if 90–110%, profitable if < 90%.';

-- ============================================================
-- Verify: report top 5 overbudget + top 5 profitable clients
-- ============================================================
do $$
declare
  v_overbudget integer;
  v_breakeven  integer;
  v_profitable integer;
  v_no_labor   integer;
  v_total      integer;
begin
  select
    count(*) filter (where profitability_state = 'overbudget'),
    count(*) filter (where profitability_state = 'breakeven'),
    count(*) filter (where profitability_state = 'profitable'),
    count(*) filter (where profitability_state = 'no_labor_recorded'),
    count(*)
  into v_overbudget, v_breakeven, v_profitable, v_no_labor, v_total
  from profit_subscription_service_reserve;
  raise notice '045 verify: subscription_service_reserve has % clients (% overbudget, % breakeven, % profitable, % no_labor_recorded)',
    v_total, v_overbudget, v_breakeven, v_profitable, v_no_labor;
end $$;
