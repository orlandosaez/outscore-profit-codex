-- Migration 040a: refinements to profit_data_quality_alerts (V0.7.E.0 hotfix)
--
-- Two issues caught immediately after 040 deploy on 2026-05-13:
--
-- 1. Alert E (subscription_billing_gap) was keyed on engagement_type =
--    'Subscription' only. Sullivan Christopher (1040) is the canonical
--    case driving this detector: he moved May 2026 to a $450 subscription
--    fee but his FC engagement_type is 'Mixed' (he still has a one-time
--    1040 line in scope). With the current detector he'd never trip.
--
--    Fix: detector now keys on agreement-level signal — "agreement has
--    at least one non-completed Anchor service line whose occurrence is
--    monthly/quarterly/yearly recurring." This catches both Subscription
--    and Mixed engagements automatically and ignores Project-only
--    engagements (where there's no recurring obligation).
--
-- 2. Alert A (fc_stale_record) day-count message used
--    `extract(day from interval)`, which returns the day-component (0-30)
--    not the total days elapsed. Fine for ghosts <30d old, splits at
--    month boundaries for older. Replaced with date-subtraction for an
--    accurate integer day count.
--
-- Same union-all column shape preserved.

create or replace view profit_data_quality_alerts as
-- ------------------------------------------------------------------------
-- A. fc_stale_record — accurate day count
-- ------------------------------------------------------------------------
select
  'fc_stale_record'::text                              as alert_category,
  'high'::text                                          as severity,
  'fc_client'::text                                    as subject_kind,
  fc.fc_client_id::text                                as subject_id,
  fc.name                                              as subject_name,
  fc.fc_client_id                                      as fc_client_id,
  null::text                                           as anchor_relationship_id,
  'FC client not refreshed by W17 in '
    || (now()::date - fc.last_seen_at::date)::text
    || ' days — possible ghost (operator may have renamed/merged inside FC).'
                                                       as description,
  'https://app.financial-cents.com/clients/' || fc.fc_client_id::text as action_url,
  now()                                                as detected_at
from profit_fc_clients fc
where fc.is_archived = false
  and fc.last_seen_at < now() - interval '7 days'

union all
-- ------------------------------------------------------------------------
-- B. anchor_no_fc_match (unchanged from 040)
-- ------------------------------------------------------------------------
select
  'anchor_no_fc_match'::text,
  'medium'::text,
  'anchor_agreement'::text,
  ag.anchor_relationship_id,
  ag.client_business_name,
  null::bigint,
  ag.anchor_relationship_id,
  'Active Anchor agreement has no FC client match — billing + SLA tracking blind.',
  coalesce(
    ag.raw->>'link',
    'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'
  ),
  now()
from profit_anchor_agreements ag
left join profit_fc_client_anchor_matches m
  on m.anchor_relationship_id = ag.anchor_relationship_id
where ag.display_status = 'active'
  and m.fc_client_id is null

union all
-- ------------------------------------------------------------------------
-- C. engagement_type_unclassified (unchanged from 040)
-- ------------------------------------------------------------------------
select
  'engagement_type_unclassified'::text,
  'medium'::text,
  'fc_client'::text,
  fc.fc_client_id::text,
  fc.name,
  fc.fc_client_id,
  null::text,
  'FC client matched to active Anchor agreement but engagement_type is NULL — '
    || 'classification gates (Manual Invoice Pending, Service Reserve) skip this client.',
  'https://app.financial-cents.com/clients/' || fc.fc_client_id::text,
  now()
from profit_fc_clients fc
join profit_fc_client_anchor_matches m
  on m.fc_client_id = fc.fc_client_id
join profit_anchor_agreements ag
  on ag.anchor_relationship_id = m.anchor_relationship_id
 and ag.display_status = 'active'
left join profit_fc_client_staff_from_custom_fields cf
  on cf.fc_client_id = fc.fc_client_id
where fc.is_archived = false
  and cf.engagement_type is null
group by fc.fc_client_id, fc.name

union all
-- ------------------------------------------------------------------------
-- D. subscription_with_manual_service (unchanged from 040)
-- ------------------------------------------------------------------------
select
  'subscription_with_manual_service'::text,
  'high'::text,
  'service_line'::text,
  (ag.anchor_relationship_id || ':' || coalesce(s->>'service_id', s->>'name')),
  ag.client_business_name,
  cf.fc_client_id,
  ag.anchor_relationship_id,
  'Subscription client has manual-trigger Anchor line "'
    || coalesce(s->>'name', 'Unnamed manual service')
    || '" — T&C says Subscription is recurring-only; manual lines should not coexist.',
  coalesce(
    ag.raw->>'link',
    'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'
  ),
  now()
from profit_anchor_agreements ag
cross join lateral jsonb_array_elements(coalesce(ag.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
join profit_fc_client_anchor_matches m
  on m.anchor_relationship_id = ag.anchor_relationship_id
join profit_fc_client_staff_from_custom_fields cf
  on cf.fc_client_id = m.fc_client_id
where ag.display_status = 'active'
  and s->>'trigger' = 'manual'
  and coalesce(s->>'status', '') <> 'completed'
  and cf.engagement_type = 'Subscription'

union all
-- ------------------------------------------------------------------------
-- E. subscription_billing_gap — keyed on agreement-level recurring signal
--    rather than client-level engagement_type. Catches both Subscription
--    AND Mixed engagements where any recurring service line is active.
--    Sullivan Christopher (1040) → Mixed engagement → must trip when his
--    $450 monthly subscription line goes 35+ days without a QBO invoice.
-- ------------------------------------------------------------------------
select
  'subscription_billing_gap'::text,
  'high'::text,
  'anchor_agreement'::text,
  ag.anchor_relationship_id,
  ag.client_business_name,
  m.fc_client_id,
  ag.anchor_relationship_id,
  'Recurring-fee agreement with no QBO-issued invoice in '
    || coalesce(
         (now()::date - max_issue.last_issued_at::date)::text,
         'EVER'
       )
    || ' days — recurring billing likely missed.',
  coalesce(
    ag.raw->>'link',
    'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'
  ),
  now()
from profit_anchor_agreements ag
join profit_fc_client_anchor_matches m
  on m.anchor_relationship_id = ag.anchor_relationship_id
left join lateral (
  select max(invoice.issue_date) as last_issued_at
  from profit_anchor_invoices invoice
  where invoice.anchor_relationship_id = ag.anchor_relationship_id
    and invoice.qbo_status is not null
) max_issue on true
where ag.display_status = 'active'
  -- Agreement must have at least one ACTIVE recurring service line.
  -- profitSyncServiceSummary[*].occurrence ∈ (monthly, quarterly, yearly) ≠ one_time
  -- and status ≠ completed.
  and exists (
    select 1
    from jsonb_array_elements(coalesce(ag.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
    where s->>'occurrence' in ('monthly', 'quarterly', 'yearly')
      and coalesce(s->>'status', '') <> 'completed'
  )
  and (
    max_issue.last_issued_at is null
    or max_issue.last_issued_at < now() - interval '35 days'
  )

union all
-- ------------------------------------------------------------------------
-- F. orphan_attribution_duplicate (unchanged from 040)
-- ------------------------------------------------------------------------
select distinct
  'orphan_attribution_duplicate'::text,
  'medium'::text,
  'anchor_agreement'::text,
  (asa1.anchor_relationship_id || ':' || asa1.canonical_service_name),
  asa1.agreement_client_business_name,
  asa1.agreement_holder_fc_client_id,
  asa1.anchor_relationship_id,
  'Duplicate canonical service "' || asa1.canonical_service_name
    || '" on one agreement — labeled (' || asa1.label
    || ') AND unlabeled both active. Operator should retire one line.',
  'https://app.sayanchor.com/home/relationship/' || asa1.anchor_relationship_id || '/agreement',
  now()
from profit_anchor_services_attributed asa1
join profit_anchor_services_attributed asa2
  on  asa2.anchor_relationship_id = asa1.anchor_relationship_id
  and asa2.canonical_service_name = asa1.canonical_service_name
  and asa2.label is null
where asa1.label is not null
  and coalesce(asa1.service_status, '') <> 'completed'
  and coalesce(asa2.service_status, '') <> 'completed';

comment on view profit_data_quality_alerts is
  'V0.7.E.0 + 040a: self-audit / data-quality view. 6 alert categories
   rooted in patterns discovered through V0.7.B–D operator audit. Alert E
   (subscription_billing_gap) keys on agreement-level recurring service
   line signal — catches Subscription AND Mixed engagement types where
   any non-completed monthly/quarterly/yearly Anchor service line goes
   35+ days without a QBO-issued invoice. Admin-only — does not drive
   weekly review queue.';
