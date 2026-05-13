-- Migration 038: Manual Invoice Pending semantic rewrite (V0.7.D-3)
--
-- Replaces V0.7.A subscription-style candidate view with delivery-driven
-- semantic per Orlando's mental model + signed T&C constraints.
--
-- Strategic context: V0.7.A's MANUAL_INVOICE_PENDING fires for any active
-- agreement with a manual-trigger service summary line — even when no
-- work has been delivered yet. This results in operator confusion ("why
-- is Schmidli flagged for manual invoice when we haven't done anything
-- yet?") and false positives for Subscription clients whose Monthly Fee
-- is earned-on-receipt per T&C (not a per-deliverable invoice signal).
--
-- New semantic (V0.7.D-3):
--   1. Client engagement_type must NOT be 'Subscription' (per FC custom field
--      "Engagement Type" populated 2026-05-13 via V0.7.E.2 foundation)
--   2. At least one FC project must be is_closed = TRUE for this client
--      (delivery happened — bill it)
--   3. No matching QBO-issued invoice exists AFTER the most recent project
--      closure timestamp (work is done but invoice not yet issued)
--
-- Subscription clients drop from the candidate set entirely (their fees
-- are recurring + earned-on-receipt; no per-deliverable invoice signal).
--
-- Clients with engagement_type NULL (unclassified — typically personal
-- 1040s whose work is labeled FROM a parent business via V0.7.B.4
-- attribution) ALSO drop from the candidate set. Their billing flows
-- through the parent business agreement, not their own.
--
-- Anchor-agreement-level granularity preserved (one row per agreement
-- where condition 1+2+3 all hold). Existing apply-function CTE shape
-- continues to work; only the candidate view's predicate changes.
--
-- Column order preserved exactly per V0.7.B.4 CREATE OR REPLACE VIEW
-- constraint (10 cols total in V0.7.A canonical shape).
--
-- See coordination memory tc_revenue_recognition_principle.md for the
-- T&C principle. See plan file V0.7.E for full slice sequence.
-- Predeploy_smoke.sh gate must pass before live apply.

create or replace view profit_manual_invoice_pending_candidates as
with manual_services as (
  -- Same as V0.7.A: roll up manual-trigger services per agreement
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
-- V0.7.D-3 NEW: per-client FC project closure roll-up.
-- At least one closed project required for the candidate to surface.
client_project_closures as (
  select
    p.fc_client_id,
    count(*) filter (where p.is_closed = true) as closed_project_count,
    max(p.closed_at) filter (where p.is_closed = true) as last_closed_at
  from profit_fc_projects p
  group by p.fc_client_id
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
  -- Column order preserved exactly per V0.7.A canonical shape (V0.7.B.4 constraint):
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
-- V0.7.D-3 NEW: engagement_type filter (drop Subscription + unclassified clients)
left join profit_fc_client_staff_from_custom_fields cf
  on cf.fc_client_id = match.fc_client_id
-- V0.7.D-3 NEW: FC project closure required
left join client_project_closures closures
  on closures.fc_client_id = match.fc_client_id
where agreement.display_status = 'active'
  and coalesce(invoice_rollup.issued_invoice_count, 0) = 0
  -- V0.7.D-3 filter A: drop Subscription clients (Monthly Fees earned-on-receipt per T&C)
  and coalesce(cf.engagement_type, 'unclassified') in ('Project', 'Mixed')
  -- V0.7.D-3 filter B: require at least one FC project closure (delivery happened)
  and coalesce(closures.closed_project_count, 0) > 0
  -- V0.7.D-3 filter C: no invoice issued AFTER the most recent project closure
  --   If last_issued_at is null (no invoices ever) → surface.
  --   If last_closed_at > last_issued_at → surface (newer delivery, no follow-up invoice).
  --   Else → drop (existing invoice already covers latest delivery).
  and (
    invoice_rollup.last_issued_at is null
    or closures.last_closed_at > invoice_rollup.last_issued_at
  );

comment on view profit_manual_invoice_pending_candidates is
  'V0.7.D-3 (038): delivery-driven Manual Invoice Pending. Filters to clients with engagement_type IN (Project, Mixed) per FC custom field (V0.7.E.2 foundation), AND at least one FC project is_closed=TRUE, AND no QBO-issued invoice after the most recent project closure. Drops V0.7.A subscription-style behavior where flags fired from agreement-signing date. Column order preserved per V0.7.A + V0.7.B.4 constraint.';
