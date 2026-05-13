-- Migration 040: V0.7.E.0 self-audit view — profit_data_quality_alerts
--
-- Strategic context: Operator audit fatigue (2026-05-13). Orlando: "do I
-- need an audit layer outside of you?" — the right answer is YES, but
-- INSIDE the system. The dashboard already classifies operator-actionable
-- work (SLA_BREACHED, MANUAL_INVOICE_PENDING, etc.). This view classifies
-- DATA-QUALITY problems — the meta layer that surfaces issues BEFORE they
-- spawn false positives in the operator queue.
--
-- Each row is one suspicious row across the source-of-truth surface. The
-- categories below are rooted in patterns actually discovered through
-- manual audit during V0.7.B–D (Celtic, Sullivan, Kar Kraft, Lee's). The
-- view itself is admin-only and doesn't drive the weekly queue.
--
-- Alert categories:
--   A. fc_stale_record               — FC client present locally but W17
--                                      hasn't refreshed in 7+ days
--                                      (W17 stale-sweep gap — ghost detection
--                                      until V0.7.G permanent fix).
--   B. anchor_no_fc_match            — Active Anchor agreement has no FC link.
--   C. engagement_type_unclassified  — Matched FC client missing engagement_type
--                                      (V0.7.E.2 follow-up gap).
--   D. subscription_with_manual_service
--                                    — T&C conflict: Subscription client has a
--                                      non-completed manual-trigger Anchor line.
--   E. subscription_billing_gap      — Subscription engagement, no QBO-issued
--                                      invoice in 35+ days (Sullivan May pattern).
--   F. orphan_attribution_duplicate  — Same canonical service appears both
--                                      labeled + unlabeled on one agreement
--                                      (Celtic 1040 Sullivan pattern).
--
-- Common row shape (UNION ALL):
--   alert_category (text), severity (text: high|medium|low),
--   subject_kind (text), subject_id (text), subject_name (text),
--   fc_client_id (bigint, nullable),
--   anchor_relationship_id (text, nullable),
--   description (text), action_url (text, nullable),
--   detected_at (timestamptz)

create or replace view profit_data_quality_alerts as
-- ------------------------------------------------------------------------
-- A. fc_stale_record: W17 hasn't synced this client in 7+ days
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
    || extract(day from (now() - fc.last_seen_at))::int
    || ' days — possible ghost (operator may have renamed/merged inside FC).'
                                                       as description,
  'https://app.financial-cents.com/clients/' || fc.fc_client_id::text as action_url,
  now()                                                as detected_at
from profit_fc_clients fc
where fc.is_archived = false
  and fc.last_seen_at < now() - interval '7 days'

union all
-- ------------------------------------------------------------------------
-- B. anchor_no_fc_match: active agreement without an FC client link
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
-- C. engagement_type_unclassified: matched FC client missing engagement_type
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
-- D. subscription_with_manual_service: Subscription client has a
--    non-completed manual-trigger Anchor service line (T&C config conflict).
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
-- E. subscription_billing_gap: Subscription engagement, no QBO-issued
--    invoice in 35+ days. (Sullivan May 2026 $450 pattern.) Allows for
--    month-end variance; cycle is monthly so 35d means the operator
--    skipped or forgot one month.
-- ------------------------------------------------------------------------
select
  'subscription_billing_gap'::text,
  'high'::text,
  'anchor_agreement'::text,
  ag.anchor_relationship_id,
  ag.client_business_name,
  cf.fc_client_id,
  ag.anchor_relationship_id,
  'Subscription engagement with no QBO-issued invoice in '
    || coalesce(extract(day from (now() - max_issue.last_issued_at))::int::text, '∞')
    || ' days — recurring fee likely missed.',
  coalesce(
    ag.raw->>'link',
    'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'
  ),
  now()
from profit_anchor_agreements ag
join profit_fc_client_anchor_matches m
  on m.anchor_relationship_id = ag.anchor_relationship_id
join profit_fc_client_staff_from_custom_fields cf
  on cf.fc_client_id = m.fc_client_id
 and cf.engagement_type = 'Subscription'
left join lateral (
  select max(invoice.issue_date) as last_issued_at
  from profit_anchor_invoices invoice
  where invoice.anchor_relationship_id = ag.anchor_relationship_id
    and invoice.qbo_status is not null
) max_issue on true
where ag.display_status = 'active'
  and (
    max_issue.last_issued_at is null
    or max_issue.last_issued_at < now() - interval '35 days'
  )

union all
-- ------------------------------------------------------------------------
-- F. orphan_attribution_duplicate: same canonical service appears on one
--    agreement BOTH labeled AND unlabeled. (Celtic 1040 Sullivan pattern —
--    operator created a labeled child line but left a stale unlabeled
--    parent line untouched.) Excludes Anchor-completed lines.
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
  'V0.7.E.0 (040): self-audit / data-quality view. Surfaces 6 categories of
   issues rooted in patterns discovered during V0.7.B–D operator audit:
   stale FC records (ghost detection), Anchor agreements without FC link,
   engagement_type unclassified, Subscription-with-manual T&C conflict,
   Subscription billing gap (Sullivan May pattern), orphan attribution
   duplicates (Celtic 1040 Sullivan pattern). Admin-only — does not drive
   the weekly review queue. Treat each row as a yellow flag for operator
   triage BEFORE the issue becomes a false positive in the operator queue.';
