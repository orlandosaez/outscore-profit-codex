-- Migration 040b: extend profit_data_quality_alerts with operator's 5
-- proposed audit checks (V0.7.E.0 completion)
--
-- Operator audit 2026-05-13: Orlando proposed 5 specific cross-table
-- consistency checks that I missed in the initial 040/040a slice. This
-- migration adds them as alert categories G–K. All are cross-source
-- false-positive / catalog-hygiene detectors that surface BEFORE the
-- weekly queue.
--
-- New categories:
--   G. parent_child_1040_false_positive
--      SLA breached on a 1040* service for a business client, BUT a
--      personal-1040 sibling FC client in the same client group has a
--      closed 1040 project after the SLA target date. Likely false
--      positive — work was done under the personal entity.
--   H. paid_anchor_invoice_not_cleared
--      SLA breached, but a paid Anchor invoice line item exists whose
--      service_id matches the SLA-breached row's underlying Anchor
--      service. Service is paid but the agreement / FC project state
--      didn't get cleared. PAID-NOT-CLEARED.
--   I. manual_invoice_already_invoiced
--      Row appears in profit_manual_invoice_pending_candidates BUT a
--      paid Anchor invoice exists within ±30 days of last project
--      closure. Predicate hole — 038c filter should have caught it.
--   J. catalog_gap_service_no_rule
--      profit_anchor_services_attributed has services whose
--      canonical_service_name has no row in
--      profit_service_recognition_rules. Invisible to SLA queue. Catalog
--      needs the rule before any SLA tracking can fire.
--   K. label_unresolved_with_sibling_candidate
--      Attribution.label_unresolved = true, but the FC client group has
--      at least one sibling whose name normalizes close to the unresolved
--      label. Operator likely needs to add the label or merge the
--      sibling — would unlock auto-resolution.
--
-- All checks ONLY consider Anchor service_status != 'completed' to avoid
-- noise on already-cleared work (consistent with 039).
--
-- Column shape preserved (union all with 040a).

create or replace view profit_data_quality_alerts as
-- ========================================================================
-- 040 / 040a categories (A–F) — unchanged
-- ========================================================================

-- A. fc_stale_record
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
-- B. anchor_no_fc_match
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
-- C. engagement_type_unclassified
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
-- D. subscription_with_manual_service
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
-- E. subscription_billing_gap
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
-- F. orphan_attribution_duplicate
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
  and coalesce(asa2.service_status, '') <> 'completed'

union all
-- ========================================================================
-- 040b NEW categories (G–K) — operator's 5 proposed audit checks
-- ========================================================================

-- ------------------------------------------------------------------------
-- G. parent_child_1040_false_positive
--    SLA breached on '1040*' canonical service for a business client,
--    AND a personal-1040 sibling (same client group, name matches
--    '%(1040)%') has a CLOSED FC 1040 project after the SLA target_date.
--    Strong indicator: the 1040 work was delivered under the personal
--    entity, not the business — current SLA row is a false positive.
-- ------------------------------------------------------------------------
select distinct
  'parent_child_1040_false_positive'::text,
  'high'::text,
  'service_line'::text,
  (sla.anchor_relationship_id || ':' || sla.service_name),
  sla.client_name,
  sla.fc_client_id,
  sla.anchor_relationship_id,
  'SLA breached on "' || sla.service_name || '" for ' || sla.client_name
    || ' — but personal-1040 sibling "' || sibling.name
    || '" has a closed 1040 FC project (closed ' || sibling_proj.closed_at::date::text
    || ', after SLA target ' || sla.target_date::text
    || '). Work likely done under personal entity.',
  sla.action_url,
  now()
from profit_sla_breached_candidates sla
join profit_client_group_members business_member
  on business_member.fc_client_id = sla.fc_client_id
 and business_member.active = true
join profit_client_group_members sibling_member
  on sibling_member.group_id = business_member.group_id
 and sibling_member.fc_client_id <> business_member.fc_client_id
 and sibling_member.active = true
join profit_fc_clients sibling
  on sibling.fc_client_id = sibling_member.fc_client_id
 and sibling.is_archived = false
 and sibling.name ilike '%(1040)%'
join profit_fc_projects sibling_proj
  on sibling_proj.fc_client_id = sibling.fc_client_id
 and sibling_proj.is_closed = true
 and sibling_proj.title ilike '%1040%'
 and sibling_proj.closed_at::date >= sla.target_date
where sla.service_name ilike '1040%'

union all
-- ------------------------------------------------------------------------
-- H. paid_anchor_invoice_not_cleared
--    SLA breached row whose underlying Anchor service_id matches a paid
--    Anchor invoice line item. The work was billed + paid but the FC
--    project / Anchor service_status was never flipped. PAID-NOT-CLEARED.
--    Limited to paymentSynced invoices with amount_paid > 0.
-- ------------------------------------------------------------------------
select distinct
  'paid_anchor_invoice_not_cleared'::text,
  'high'::text,
  'service_line'::text,
  (sla.anchor_relationship_id || ':' || sla.service_name),
  sla.client_name,
  sla.fc_client_id,
  sla.anchor_relationship_id,
  'SLA breached on "' || sla.service_name || '" but Anchor invoice '
    || inv.invoice_number || ' (issued ' || inv.issue_date::date::text
    || ', paid $' || coalesce(inv.amount_paid, 0)::text
    || ') has a line item matching the same Anchor service_id. '
    || 'Operator should mark service Completed in Anchor or close FC project.',
  sla.action_url,
  now()
from profit_sla_breached_candidates sla
join profit_anchor_services_attributed asa
  on asa.anchor_relationship_id = sla.anchor_relationship_id
 and asa.canonical_service_name = sla.service_name
join profit_anchor_invoice_line_items li
  on li.anchor_relationship_id = sla.anchor_relationship_id
 and li.service_id = asa.service_id
join profit_anchor_invoices inv
  on inv.anchor_invoice_id = li.anchor_invoice_id
 and inv.qbo_status = 'paymentSynced'
 and coalesce(inv.amount_paid, 0) > 0

union all
-- ------------------------------------------------------------------------
-- I. manual_invoice_already_invoiced
--    Row in profit_manual_invoice_pending_candidates with a paid Anchor
--    invoice (qbo_status=paymentSynced, amount_paid > 0) issued within
--    ±30 days of the last project closure. 038c filter C should have
--    dropped these — surfacing means the predicate has a hole or the
--    invoice was synced after the manual classification was made.
-- ------------------------------------------------------------------------
select distinct
  'manual_invoice_already_invoiced'::text,
  'high'::text,
  'anchor_agreement'::text,
  mip.anchor_relationship_id,
  mip.client_name,
  mip.fc_client_id,
  mip.anchor_relationship_id,
  'Manual Invoice Pending fired for ' || mip.client_name
    || ' but Anchor invoice ' || inv.invoice_number
    || ' (paid $' || coalesce(inv.amount_paid, 0)::text
    || ', issued ' || inv.issue_date::date::text
    || ') already covers a project closed near this date. Predicate hole.',
  mip.action_url,
  now()
from profit_manual_invoice_pending_candidates mip
join profit_anchor_invoices inv
  on inv.anchor_relationship_id = mip.anchor_relationship_id
 and inv.qbo_status = 'paymentSynced'
 and coalesce(inv.amount_paid, 0) > 0
join lateral (
  select max(p.closed_at) as last_closed_at
  from profit_fc_projects p
  join profit_fc_template_service_map tm on tm.template_id = p.template_id
  where p.fc_client_id = mip.fc_client_id
    and p.is_closed = true
) recent on true
where recent.last_closed_at is not null
  and inv.issue_date between (recent.last_closed_at - interval '30 days')
                         and (recent.last_closed_at + interval '30 days')

union all
-- ------------------------------------------------------------------------
-- J. catalog_gap_service_no_rule
--    Active Anchor service line (status != completed) whose
--    canonical_service_name has no row in profit_service_recognition_rules.
--    These services are INVISIBLE to the SLA queue because they have no
--    recognition_pattern / target_date. Operator should add a rule.
-- ------------------------------------------------------------------------
select distinct
  'catalog_gap_service_no_rule'::text,
  'medium'::text,
  'service_line'::text,
  asa.canonical_service_name,
  asa.attributed_fc_client_name,
  asa.attributed_fc_client_id,
  asa.anchor_relationship_id,
  'Active Anchor service "' || asa.canonical_service_name
    || '" (raw: "' || asa.raw_service_name
    || '") has no row in profit_service_recognition_rules — invisible to SLA queue.'
    || ' Add recognition rule to track delivery.',
  'https://app.sayanchor.com/home/relationship/' || asa.anchor_relationship_id || '/agreement',
  now()
from profit_anchor_services_attributed asa
left join profit_service_recognition_rules r
  on r.service_name = asa.canonical_service_name
where r.service_name is null
  and coalesce(asa.service_status, '') <> 'completed'

union all
-- ------------------------------------------------------------------------
-- K. label_unresolved_with_sibling_candidate
--    profit_anchor_services_attributed.label_unresolved = true AND the
--    agreement holder's client group has a sibling whose normalized name
--    has token overlap with the unresolved label. Likely missing label
--    or merge candidate — would unlock auto-resolution. Token-overlap
--    heuristic: split label on space, check if any token ≥3 chars
--    appears in any sibling's normalized name.
-- ------------------------------------------------------------------------
select distinct
  'label_unresolved_with_sibling_candidate'::text,
  'medium'::text,
  'service_line'::text,
  (asa.anchor_relationship_id || ':' || asa.canonical_service_name
    || ':' || coalesce(asa.label, '')),
  asa.agreement_client_business_name,
  asa.agreement_holder_fc_client_id,
  asa.anchor_relationship_id,
  'Unresolved label "' || asa.label
    || '" on service "' || asa.canonical_service_name
    || '" — sibling FC client "' || sibling.name
    || '" in same group has token overlap. Likely target.',
  'https://app.sayanchor.com/home/relationship/' || asa.anchor_relationship_id || '/agreement',
  now()
from profit_anchor_services_attributed asa
join profit_client_group_members holder_member
  on holder_member.fc_client_id = asa.agreement_holder_fc_client_id
 and holder_member.active = true
join profit_client_group_members sibling_member
  on sibling_member.group_id = holder_member.group_id
 and sibling_member.fc_client_id <> holder_member.fc_client_id
 and sibling_member.active = true
join profit_fc_clients sibling
  on sibling.fc_client_id = sibling_member.fc_client_id
 and sibling.is_archived = false
where asa.label_unresolved = true
  and coalesce(asa.service_status, '') <> 'completed'
  and exists (
    -- token overlap heuristic: any ≥3-char token from label appears in sibling name
    select 1
    from regexp_split_to_table(lower(regexp_replace(asa.label, '[^a-zA-Z ]', '', 'g')), '\s+') tok
    where length(tok) >= 3
      and lower(sibling.name) like '%' || tok || '%'
  );

comment on view profit_data_quality_alerts is
  'V0.7.E.0 + 040a + 040b: self-audit view, 11 alert categories rooted in
   patterns from V0.7.B–D operator audit + Orlando''s 5 proposed cross-table
   consistency checks. A–F: stale/missing/duplicate detectors. G–K: false-
   positive + catalog-gap detectors (parent-child 1040, paid-not-cleared,
   already-invoiced, no-recognition-rule, label-missing-with-sibling).
   Admin-only; does not drive weekly queue.';
