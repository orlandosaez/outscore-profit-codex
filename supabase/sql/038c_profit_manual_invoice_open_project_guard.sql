-- Migration 038c: Manual Invoice Pending — exclude when open work exists (V0.7.D-3 hotfix)
--
-- Operator audit 2026-05-13 found 3 false positives in MANUAL_INVOICE_PENDING:
--   1. Lee's Inc — has open "1120 Tax Return" project (status: waiting on client)
--      The trigger was the closed "2025 Outscore Updates" newsletter (template
--      10837357 — explicitly NOT in profit_fc_template_service_map). Newsletter
--      should never count as a delivery signal.
--   2. The Bachert Law Firm PA — has open "1120 Tax Return" project. The
--      closed projects (Onboarding + TPP) are different scope from 1120 work.
--   3. West Coast Conference WMS Inc — has open "990 Tax Return" (current year)
--      AND closed 990 (last year). Current work is open; row should drop.
--
-- Two bug categories:
--   A. Newsletter / non-service template closures incorrectly count as "delivery"
--   B. Predicate ignored whether RELEVANT open work still exists for the client
--
-- Fix:
--   A. Constrain client_project_closures CTE to projects whose template_id is
--      mapped in profit_fc_template_service_map (real service templates only).
--      Newsletter template 10837357 is intentionally excluded from the map.
--      Untemplated projects (e.g. ad-hoc onboarding) also excluded.
--   B. Add NOT EXISTS check: drop the row when the client has ANY open project
--      whose template_id IS mapped (i.e., real service work still in flight).
--
-- Edge cases handled:
--   - Closed 1120 + open Onboarding (no template) → row stays (Onboarding not in map)
--   - Closed 1120 + open Year End Close (mapped template) → row drops (over-conservative
--     but defensible: don't bill while staff is still working on anything in scope)
--   - Closed 1120 + only newsletter still open → row stays (newsletter not in map)
--
-- All other V0.7.D-3 (038) shape preserved.

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
    count(*) filter (where invoice.qbo_status is not null)::integer as issued_invoice_count,
    max(invoice.issue_date) filter (where invoice.qbo_status is not null) as last_issued_at
  from profit_anchor_invoices invoice
  group by invoice.anchor_relationship_id
),
-- V0.7.D-3 hotfix 038c: only count CLOSED projects whose template_id maps to
-- a real service template. Newsletter (10837357) and untemplated projects
-- are excluded — they're not delivery signals.
client_project_closures as (
  select
    p.fc_client_id,
    count(*) as closed_project_count,
    max(p.closed_at) as last_closed_at
  from profit_fc_projects p
  join profit_fc_template_service_map tm on tm.template_id = p.template_id
  where p.is_closed = true
  group by p.fc_client_id
),
-- V0.7.D-3 hotfix 038c: clients with ANY open project whose template_id maps
-- to a real service template. Used to DROP rows where staff is still
-- working on something in scope.
client_open_service_work as (
  select distinct p.fc_client_id
  from profit_fc_projects p
  join profit_fc_template_service_map tm on tm.template_id = p.template_id
  where p.is_closed = false
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
    current_date - coalesce(active_manual_classification.classified_at::date, closures.last_closed_at::date, agreement.effective_date::date, current_date)
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
left join profit_fc_client_staff_from_custom_fields cf
  on cf.fc_client_id = match.fc_client_id
left join client_project_closures closures
  on closures.fc_client_id = match.fc_client_id
where agreement.display_status = 'active'
  and coalesce(invoice_rollup.issued_invoice_count, 0) = 0
  and coalesce(cf.engagement_type, 'unclassified') in ('Project', 'Mixed')
  -- V0.7.D-3 hotfix 038c filter A: require closed service-mapped project (not newsletter)
  and coalesce(closures.closed_project_count, 0) > 0
  -- V0.7.D-3 hotfix 038c filter B: drop row if client has open service-mapped work
  and not exists (
    select 1 from client_open_service_work cosw
    where cosw.fc_client_id = match.fc_client_id
  )
  -- Existing filter C: no invoice issued AFTER the most recent service closure
  and (
    invoice_rollup.last_issued_at is null
    or closures.last_closed_at > invoice_rollup.last_issued_at
  );

comment on view profit_manual_invoice_pending_candidates is
  'V0.7.D-3 + hotfix 038c: only surfaces when (1) Project/Mixed engagement_type, (2) at least one closed FC project whose template_id maps to a real service in profit_fc_template_service_map, (3) NO open project whose template_id maps to a real service (no in-flight work), (4) no QBO-issued invoice after most recent service closure. Newsletter (10837357) and untemplated projects ignored on both closure + open-work checks.';
