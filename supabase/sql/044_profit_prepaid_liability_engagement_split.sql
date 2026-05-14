-- Migration 044: V0.7.E.1 Sprint D — Prepaid Liability split by engagement_type
--
-- Per T&C revenue recognition principle (load-bearing memory 2026-05-13):
--   Subscription Monthly Fees = earned-on-receipt; NOT GAAP liability.
--   Only Project Engagement prepayments are real Deferred Revenue.
--   Chart of accounts: 4010 Subscription / 4020 Project / 4030 Onboarding /
--     2050 Deferred Revenue – Project only. NO subscription deferral account.
--
-- The current dashboard tile labels ALL prepaid balances as "Prepaid
-- Liability" — operationally true but contradicts the signed T&C for
-- the Subscription portion. This migration splits the existing
-- tax_deferred_revenue bucket by engagement_type so the dashboard
-- can render two accurate tiles:
--
--   1. Deferred Revenue – Project        (real GAAP liability, account 2050)
--   2. Subscription Service Reserve       (operational cushion, NOT GAAP)
--
-- Mixed engagement_type clients (16 of 28 tax_deferred clients have a
-- foot in both Project + Subscription cadences) are conservatively
-- bucketed as Deferred Revenue – Project per accountant convention
-- (overstate liability rather than understate). Per-service allocation
-- deferred to V0.7.E.3 (Subscription Service Reserve labor-cost calc).
--
-- Unmatched clients (engagement_type IS NULL) are surfaced via the
-- self-audit view's engagement_type_unclassified category — they stay
-- in the same conservative Project bucket until classified.
--
-- Trigger backlog ($76,394 currently) is unchanged; it has its own
-- existing trigger_backlog_note clarifying it's not a QBO liability.
--
-- Schema changes (additive only, column-order preserved):
--   - profit_prepaid_liability_balances: add engagement_type, engagement_bucket
--   - profit_prepaid_liability_summary:
--       + deferred_revenue_project_balance
--       + subscription_service_reserve_balance
--       (existing columns preserved verbatim)

-- ============================================================
-- A. Enrich profit_prepaid_liability_balances with engagement context
-- ============================================================
create or replace view profit_prepaid_liability_balances as
with raw_balances as (
  select
    ledger.anchor_relationship_id,
    agreement.client_business_name as anchor_client_business_name,
    ledger.macro_service_type,
    ledger.service_category,
    sum(ledger.amount_delta)::numeric as balance,
    sum(ledger.collected_amount)::numeric as collected_amount,
    sum(ledger.recognized_drawdown_amount)::numeric as recognized_drawdown_amount,
    sum(ledger.rounding_delta)::numeric as rounding_delta,
    max(ledger.event_at) as last_updated,
    count(*)::integer as ledger_entry_count
  from profit_prepaid_liability_ledger ledger
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = ledger.anchor_relationship_id
  group by 1, 2, 3, 4
  having sum(ledger.amount_delta) <> 0
)
select
  -- Original columns (preserved verbatim, same order)
  raw_balances.anchor_relationship_id,
  raw_balances.anchor_client_business_name,
  raw_balances.macro_service_type,
  raw_balances.service_category,
  raw_balances.balance,
  raw_balances.collected_amount,
  raw_balances.recognized_drawdown_amount,
  raw_balances.rounding_delta,
  raw_balances.last_updated,
  raw_balances.ledger_entry_count,
  -- V0.7.E.1 NEW columns appended at end (preserves V0.7.B.4 column-order)
  cf.engagement_type,
  case
    -- Trigger backlog is operational, not a T&C-driven bucket
    when raw_balances.service_category = 'pending_recognition_trigger'
      then 'trigger_backlog'
    -- Conservative bucketing per T&C: Project + Mixed + unclassified → real liability
    when coalesce(cf.engagement_type, 'unclassified') in ('Project', 'Mixed', 'unclassified')
      then 'deferred_revenue_project'
    -- Pure Subscription → operational service reserve (NOT GAAP liability)
    when cf.engagement_type = 'Subscription'
      then 'subscription_service_reserve'
    else 'deferred_revenue_project'
  end as engagement_bucket
from raw_balances
left join profit_fc_client_anchor_matches m
  on m.anchor_relationship_id = raw_balances.anchor_relationship_id
left join profit_fc_client_staff_from_custom_fields cf
  on cf.fc_client_id = m.fc_client_id;

comment on view profit_prepaid_liability_balances is
  'V0.7.B.4 + 044: per-client prepaid liability balances. 044 adds
   engagement_type (joined via FC custom-field view) + engagement_bucket
   (T&C-aligned classification: deferred_revenue_project = real GAAP
   liability, subscription_service_reserve = earned-on-receipt operational
   reserve, trigger_backlog = unrecognized delivery). Mixed engagement +
   unclassified default conservatively to deferred_revenue_project per
   accountant convention.';

-- ============================================================
-- B. Extend profit_prepaid_liability_summary with engagement_bucket totals
-- ============================================================
create or replace view profit_prepaid_liability_summary as
with balance_summary as (
  select
    coalesce(sum(balance) filter (
      where service_category = 'tax_deferred_revenue'
    ), 0)::numeric as tax_deferred_revenue_balance,
    coalesce(sum(balance) filter (
      where service_category = 'pending_recognition_trigger'
    ), 0)::numeric as trigger_backlog_balance,
    coalesce(sum(balance) filter (
      where service_category in ('tax_deferred_revenue', 'pending_recognition_trigger')
    ), 0)::numeric as total_prepaid_liability_balance,
    -- V0.7.E.1 NEW: T&C-aligned engagement bucketing
    coalesce(sum(balance) filter (
      where service_category = 'tax_deferred_revenue'
        and engagement_bucket = 'deferred_revenue_project'
    ), 0)::numeric as deferred_revenue_project_balance,
    coalesce(sum(balance) filter (
      where service_category = 'tax_deferred_revenue'
        and engagement_bucket = 'subscription_service_reserve'
    ), 0)::numeric as subscription_service_reserve_balance,
    count(*)::integer as client_balance_count,
    max(last_updated) as last_updated
  from profit_prepaid_liability_balances
),
collection_summary as (
  select
    count(*)::integer as collection_count
  from profit_cash_collections
)
select
  -- Original columns (preserved verbatim — V0.7.B.4 column-order)
  balance_summary.tax_deferred_revenue_balance,
  balance_summary.trigger_backlog_balance,
  balance_summary.total_prepaid_liability_balance,
  'Delivered services with no recognition trigger loaded — not a QBO liability entry. Clears when FC completion triggers are approved.'::text as trigger_backlog_note,
  balance_summary.client_balance_count,
  collection_summary.collection_count,
  balance_summary.last_updated,
  -- V0.7.E.1 NEW columns appended at end
  balance_summary.deferred_revenue_project_balance,
  balance_summary.subscription_service_reserve_balance,
  'Real GAAP liability per T&C — Project Engagement prepayments + Mixed/unclassified (conservative). QBO account 2050.'::text as deferred_revenue_project_note,
  'Operational cash cushion — Subscription Monthly Fees per T&C are earned-on-receipt, NOT GAAP liability. No QBO liability account.'::text as subscription_service_reserve_note
from balance_summary
cross join collection_summary;

comment on view profit_prepaid_liability_summary is
  'V0.7.B.4 + 044: company-wide prepaid summary. Adds deferred_revenue_project_balance
   + subscription_service_reserve_balance for the T&C-aligned dashboard tile
   split. Original tax_deferred_revenue_balance preserved (it equals
   deferred_revenue_project_balance + subscription_service_reserve_balance).';

-- ============================================================
-- Verify the new split numbers
-- ============================================================
do $$
declare
  v_drp numeric;
  v_ssr numeric;
  v_tdr numeric;
begin
  select deferred_revenue_project_balance, subscription_service_reserve_balance, tax_deferred_revenue_balance
    into v_drp, v_ssr, v_tdr
    from profit_prepaid_liability_summary;
  raise notice '044 verify: Deferred Revenue – Project = $%, Subscription Service Reserve = $%, sum = $%, tax_deferred_revenue_balance = $%',
    v_drp, v_ssr, v_drp + v_ssr, v_tdr;
  if abs((v_drp + v_ssr) - v_tdr) > 0.01 then
    raise exception '044 verify FAILED: project + reserve does not sum to tax_deferred_revenue_balance';
  end if;
end $$;
