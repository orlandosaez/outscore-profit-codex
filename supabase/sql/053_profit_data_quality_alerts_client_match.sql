-- Migration 053: V0.7.J J.4 client-match data-quality alerts.
--
-- Adds category L: client_match_suspected_dup_or_gap with three UNION ALL
-- branches. No new table, no subcategory column; L.1/L.2/L.3 are
-- encoded in subject_id and description text to preserve the 040-family row
-- shape. Also updates category B so active Anchor agreements awaiting W25
-- confirmation do not fire anchor_no_fc_match when an exact/alias/fuzzy
-- candidate already exists.

create or replace view profit_data_quality_alerts as
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
    || ' days — possible ghost (operator may have renamed/merged inside FC).' as description,
  'https://app.financial-cents.com/clients/' || fc.fc_client_id::text as action_url,
  now()                                                as detected_at
from profit_fc_clients fc
where fc.is_archived = false
  and fc.last_seen_at < now() - interval '7 days'

union all
-- B. anchor_no_fc_match
select 'anchor_no_fc_match', 'medium', 'anchor_agreement',
  ag.anchor_relationship_id, ag.client_business_name, null::bigint, ag.anchor_relationship_id,
  'Active Anchor agreement has no FC client match — billing + SLA tracking blind.',
  coalesce(ag.raw->>'link', 'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'),
  now()
from profit_anchor_agreements ag
left join profit_fc_client_anchor_matches m on m.anchor_relationship_id = ag.anchor_relationship_id
where ag.display_status = 'active'
  and m.fc_client_id is null
  and not exists (
    select 1
    from profit_fc_client_anchor_match_candidates candidate
    where candidate.anchor_relationship_id = ag.anchor_relationship_id
      and candidate.match_status in ('auto_exact', 'auto_fuzzy')
  )

union all
-- C. engagement_type_unclassified
select 'engagement_type_unclassified', 'medium', 'fc_client',
  fc.fc_client_id::text, fc.name, fc.fc_client_id, null::text,
  'FC client matched to active Anchor agreement but engagement_type is NULL — classification gates skip this client.',
  'https://app.financial-cents.com/clients/' || fc.fc_client_id::text,
  now()
from profit_fc_clients fc
join profit_fc_client_anchor_matches m on m.fc_client_id = fc.fc_client_id
join profit_anchor_agreements ag on ag.anchor_relationship_id = m.anchor_relationship_id and ag.display_status = 'active'
left join profit_fc_client_staff_from_custom_fields cf on cf.fc_client_id = fc.fc_client_id
where fc.is_archived = false and cf.engagement_type is null
group by fc.fc_client_id, fc.name

union all
-- D. subscription_with_manual_service
select 'subscription_with_manual_service', 'high', 'service_line',
  (ag.anchor_relationship_id || ':' || coalesce(s->>'service_id', s->>'name')),
  ag.client_business_name, cf.fc_client_id, ag.anchor_relationship_id,
  'Subscription client has manual-trigger Anchor line "' || coalesce(s->>'name', 'Unnamed manual service')
    || '" — T&C says Subscription is recurring-only; manual lines should not coexist.',
  coalesce(ag.raw->>'link', 'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'),
  now()
from profit_anchor_agreements ag
cross join lateral jsonb_array_elements(coalesce(ag.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
join profit_fc_client_anchor_matches m on m.anchor_relationship_id = ag.anchor_relationship_id
join profit_fc_client_staff_from_custom_fields cf on cf.fc_client_id = m.fc_client_id
where ag.display_status = 'active'
  and s->>'trigger' = 'manual'
  and coalesce(s->>'status', '') <> 'completed'
  and cf.engagement_type = 'Subscription'

union all
-- E. subscription_billing_gap
select 'subscription_billing_gap', 'high', 'anchor_agreement',
  ag.anchor_relationship_id, ag.client_business_name, m.fc_client_id, ag.anchor_relationship_id,
  'Recurring-fee agreement with no QBO-issued invoice in '
    || coalesce((now()::date - max_issue.last_issued_at::date)::text, 'EVER')
    || ' days — recurring billing likely missed.',
  coalesce(ag.raw->>'link', 'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'),
  now()
from profit_anchor_agreements ag
join profit_fc_client_anchor_matches m on m.anchor_relationship_id = ag.anchor_relationship_id
left join lateral (
  select max(invoice.issue_date) as last_issued_at
  from profit_anchor_invoices invoice
  where invoice.anchor_relationship_id = ag.anchor_relationship_id and invoice.qbo_status is not null
) max_issue on true
where ag.display_status = 'active'
  and exists (
    select 1 from jsonb_array_elements(coalesce(ag.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
    where s->>'occurrence' in ('monthly', 'quarterly', 'yearly')
      and coalesce(s->>'status', '') <> 'completed'
  )
  and (max_issue.last_issued_at is null or max_issue.last_issued_at < now() - interval '35 days')

union all
-- F. orphan_attribution_duplicate
select distinct 'orphan_attribution_duplicate', 'medium', 'anchor_agreement',
  (asa1.anchor_relationship_id || ':' || asa1.canonical_service_name),
  asa1.agreement_client_business_name, asa1.agreement_holder_fc_client_id, asa1.anchor_relationship_id,
  'Duplicate canonical service "' || asa1.canonical_service_name
    || '" on one agreement — labeled (' || asa1.label
    || ') AND unlabeled both active. Operator should retire one line.',
  'https://app.sayanchor.com/home/relationship/' || asa1.anchor_relationship_id || '/agreement',
  now()
from profit_anchor_services_attributed asa1
join profit_anchor_services_attributed asa2
  on asa2.anchor_relationship_id = asa1.anchor_relationship_id
 and asa2.canonical_service_name = asa1.canonical_service_name and asa2.label is null
where asa1.label is not null
  and coalesce(asa1.service_status, '') <> 'completed'
  and coalesce(asa2.service_status, '') <> 'completed'

union all
-- G. parent_child_1040_false_positive
select distinct 'parent_child_1040_false_positive', 'high', 'service_line',
  (sla.anchor_relationship_id || ':' || sla.service_name), sla.client_name, sla.fc_client_id, sla.anchor_relationship_id,
  'SLA breached on "' || sla.service_name || '" for ' || sla.client_name
    || ' — but personal-1040 sibling "' || sibling.name
    || '" has a closed 1040 FC project (closed ' || sibling_proj.closed_at::date::text
    || ', after SLA target ' || sla.target_date::text
    || '). Work likely done under personal entity.',
  sla.action_url, now()
from profit_sla_breached_candidates sla
join profit_client_group_members business_member
  on business_member.fc_client_id = sla.fc_client_id and business_member.active = true
join profit_client_group_members sibling_member
  on sibling_member.group_id = business_member.group_id
 and sibling_member.fc_client_id <> business_member.fc_client_id and sibling_member.active = true
join profit_fc_clients sibling
  on sibling.fc_client_id = sibling_member.fc_client_id
 and sibling.is_archived = false and sibling.name ilike '%(1040)%'
join profit_fc_projects sibling_proj
  on sibling_proj.fc_client_id = sibling.fc_client_id
 and sibling_proj.is_closed = true and sibling_proj.title ilike '%1040%'
 and sibling_proj.closed_at::date >= sla.target_date
where sla.service_name ilike '1040%'

union all
-- H. paid_anchor_invoice_not_cleared (DEDUPED via aggregation)
select
  'paid_anchor_invoice_not_cleared'::text,
  'high'::text,
  'service_line'::text,
  (sla.anchor_relationship_id || ':' || sla.service_name) as subject_id,
  sla.client_name as subject_name,
  sla.fc_client_id,
  sla.anchor_relationship_id,
  'SLA breached on "' || sla.service_name || '" but ' || agg.paid_inv_count
    || ' paid Anchor invoice(s) match the underlying service_id (latest: '
    || agg.latest_invoice_number || ', paid $' || agg.latest_amount_paid::text
    || ' on ' || agg.latest_issue_date::date::text
    || '). Operator should mark service Completed in Anchor or close FC project.' as description,
  sla.action_url,
  now()
from profit_sla_breached_candidates sla
join lateral (
  select
    count(distinct inv.anchor_invoice_id) as paid_inv_count,
    (array_agg(inv.invoice_number order by inv.issue_date desc nulls last))[1] as latest_invoice_number,
    (array_agg(coalesce(inv.amount_paid, 0) order by inv.issue_date desc nulls last))[1] as latest_amount_paid,
    max(inv.issue_date) as latest_issue_date
  from profit_anchor_services_attributed asa
  join profit_anchor_invoice_line_items li
    on li.anchor_relationship_id = sla.anchor_relationship_id
   and li.service_id = asa.service_id
  join profit_anchor_invoices inv
    on inv.anchor_invoice_id = li.anchor_invoice_id
   and inv.qbo_status = 'paymentSynced'
   and coalesce(inv.amount_paid, 0) > 0
  where asa.anchor_relationship_id = sla.anchor_relationship_id
    and asa.canonical_service_name = sla.service_name
) agg on true
where agg.paid_inv_count > 0

union all
-- I. manual_invoice_already_invoiced
select distinct 'manual_invoice_already_invoiced', 'high', 'anchor_agreement',
  mip.anchor_relationship_id, mip.client_name, mip.fc_client_id, mip.anchor_relationship_id,
  'Manual Invoice Pending fired for ' || mip.client_name
    || ' but Anchor invoice ' || inv.invoice_number
    || ' (paid $' || coalesce(inv.amount_paid, 0)::text
    || ', issued ' || inv.issue_date::date::text
    || ') already covers a project closed near this date. Predicate hole.',
  mip.action_url, now()
from profit_manual_invoice_pending_candidates mip
join profit_anchor_invoices inv
  on inv.anchor_relationship_id = mip.anchor_relationship_id
 and inv.qbo_status = 'paymentSynced' and coalesce(inv.amount_paid, 0) > 0
join lateral (
  select max(p.closed_at) as last_closed_at
  from profit_fc_projects p
  join profit_fc_template_service_map tm on tm.template_id = p.template_id
  where p.fc_client_id = mip.fc_client_id and p.is_closed = true
) recent on true
where recent.last_closed_at is not null
  and inv.issue_date between (recent.last_closed_at - interval '30 days') and (recent.last_closed_at + interval '30 days')

union all
-- J. catalog_gap_service_no_rule (one row per distinct canonical_service_name)
select
  'catalog_gap_service_no_rule'::text,
  'medium'::text,
  'service_line'::text,
  agg.canonical_service_name,
  ('appears on ' || agg.example_clients) as subject_name,
  null::bigint,
  null::text,
  'Active Anchor service "' || agg.canonical_service_name
    || '" appears on ' || agg.agreement_count
    || ' active agreement(s) but has no row in profit_service_recognition_rules — invisible to SLA queue. Examples: '
    || agg.example_clients,
  null::text,
  now()
from (
  select
    asa.canonical_service_name,
    count(distinct asa.anchor_relationship_id) as agreement_count,
    string_agg(distinct asa.agreement_client_business_name, ', ' order by asa.agreement_client_business_name) filter (where asa.agreement_client_business_name is not null) as example_clients
  from profit_anchor_services_attributed asa
  left join profit_service_recognition_rules r on r.service_name = asa.canonical_service_name
  where r.service_name is null
    and coalesce(asa.service_status, '') <> 'completed'
  group by asa.canonical_service_name
) agg

union all
-- K. label_unresolved_with_sibling_candidate
select distinct 'label_unresolved_with_sibling_candidate', 'medium', 'service_line',
  (asa.anchor_relationship_id || ':' || asa.canonical_service_name || ':' || coalesce(asa.label, '')),
  asa.agreement_client_business_name, asa.agreement_holder_fc_client_id, asa.anchor_relationship_id,
  'Unresolved label "' || asa.label || '" on service "' || asa.canonical_service_name
    || '" — sibling FC client "' || sibling.name
    || '" in same group has token overlap. Likely target.',
  'https://app.sayanchor.com/home/relationship/' || asa.anchor_relationship_id || '/agreement',
  now()
from profit_anchor_services_attributed asa
join profit_client_group_members holder_member
  on holder_member.fc_client_id = asa.agreement_holder_fc_client_id and holder_member.active = true
join profit_client_group_members sibling_member
  on sibling_member.group_id = holder_member.group_id
 and sibling_member.fc_client_id <> holder_member.fc_client_id and sibling_member.active = true
join profit_fc_clients sibling
  on sibling.fc_client_id = sibling_member.fc_client_id and sibling.is_archived = false
where asa.label_unresolved = true
  and coalesce(asa.service_status, '') <> 'completed'
  and exists (
    select 1
    from regexp_split_to_table(lower(regexp_replace(asa.label, '[^a-zA-Z ]', '', 'g')), '\s+') tok
    where length(tok) >= 3 and lower(sibling.name) like '%' || tok || '%'
  )

union all
-- L.1 client_match_suspected_dup_or_gap: FC auto-dedup suffix.
select
  'client_match_suspected_dup_or_gap'::text,
  'medium'::text,
  'fc_client'::text,
  ('L.1:' || fc.fc_client_id::text) as subject_id,
  fc.name as subject_name,
  fc.fc_client_id,
  null::text as anchor_relationship_id,
  'L.1 FC client "' || fc.name || '" looks like an auto-dedup of an existing record. Investigate origin (likely external integration creating duplicates) and merge into canonical FC client.' as description,
  'https://app.financial-cents.com/clients/' || fc.fc_client_id::text as action_url,
  now()
from profit_fc_clients fc
where fc.is_archived = false
  -- Narrowed to FC's actual auto-dedup pattern only: trailing -N.
  -- Original draft also matched (N) at the end, but that conflicts with the
  -- operator naming convention for personal tax engagements like "(1040)"
  -- (~43 false positives observed on first prod apply 2026-05-23).
  and fc.name ~ '-[0-9]+$'

union all
-- L.2 client_match_suspected_dup_or_gap: audit-only trigram band.
select
  'client_match_suspected_dup_or_gap'::text,
  'medium'::text,
  'client_match_candidate'::text,
  ('L.2:' || fc.fc_client_id::text || ':' || ag.anchor_relationship_id) as subject_id,
  (fc.name || ' <> ' || ag.client_business_name) as subject_name,
  fc.fc_client_id,
  ag.anchor_relationship_id,
  'L.2 FC "' || fc.name || '" and Anchor "' || ag.client_business_name
    || '" look like the same client (similarity '
    || round(sim.score::numeric, 2)::text
    || '). Confirm or add alias to profit_client_aliases.' as description,
  coalesce(ag.raw->>'link', 'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement') as action_url,
  now()
from profit_fc_clients fc
join profit_anchor_agreements ag
  on ag.display_status = 'active'
 and ag.client_business_name is not null
cross join lateral (
  select similarity(
    profit_normalize_client_name(fc.name),
    profit_normalize_client_name(ag.client_business_name)
  ) as score
) sim
where fc.is_archived = false
  and sim.score >= 0.85
  and sim.score < 0.92
  and not exists (
    select 1
    from profit_fc_client_anchor_matches m
    where m.fc_client_id = fc.fc_client_id
      and m.anchor_relationship_id = ag.anchor_relationship_id
  )

union all
-- L.3 client_match_suspected_dup_or_gap: Anchor agreement has no FC candidate.
select
  'client_match_suspected_dup_or_gap'::text,
  'medium'::text,
  'anchor_agreement'::text,
  ('L.3:' || ag.anchor_relationship_id) as subject_id,
  ag.client_business_name as subject_name,
  null::bigint as fc_client_id,
  ag.anchor_relationship_id,
  'L.3 Anchor agreement "' || ag.anchor_relationship_id || '" for "' || ag.client_business_name
    || '" has no FC client link. Either create FC client first (preferred per V0.7.J workflow) or add to profit_client_aliases.' as description,
  coalesce(ag.raw->>'link', 'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement') as action_url,
  now()
from profit_anchor_agreements ag
left join profit_fc_client_anchor_matches m
  on m.anchor_relationship_id = ag.anchor_relationship_id
where ag.display_status = 'active'
  and m.fc_client_id is null
  and not exists (
    select 1
    from profit_fc_client_anchor_match_candidates candidate
    where candidate.anchor_relationship_id = ag.anchor_relationship_id
      and candidate.match_status in ('auto_exact', 'auto_fuzzy')
  );

comment on view profit_data_quality_alerts is
  'V0.7.J: 12 alert categories A-K plus L client_match_suspected_dup_or_gap. L has three same-shape UNION ALL branches: L.1 FC auto-dedup suffix, L.2 audit-only 0.85 <= trigram < 0.92 across active FC clients and active Anchor agreements, L.3 active Anchor agreement with no exact/alias/fuzzy FC candidate. Category B suppresses active Anchor rows when a candidate exists awaiting W25 confirmation.';

-- Verify: schema-only check. Do not invoke side-effect RPCs or inspect live data.
do $$
begin
  if to_regclass('public.profit_data_quality_alerts') is null then
    raise exception '053 verify FAIL: profit_data_quality_alerts missing';
  end if;

  raise notice '053 verify: schema OK';
end $$;
