-- Migration 047: add pipeline_stale_or_failed alert category to
-- profit_data_quality_alerts (V0.7.E.0 hotfix — 2026-05-18)
--
-- Operator-facing outage 2026-05-13 → 2026-05-18: nightly pipeline failed
-- silently for 5 days. Two intersecting bugs prevented recovery:
--   1. W29 cron used $env expression that n8n blocks by default
--      → cron fired every night but errored at the first node
--   2. W16 had a duplicate-key SQL conflict from
--      profit_revenue_events_ready_for_recognition emitting both manual
--      override + auto trigger for the same revenue_event_key
-- Both fixed in this commit cycle, but the silent-failure mode shows
-- we must surface pipeline health in the audit system itself.
--
-- This migration adds a new category 'pipeline_stale_or_failed' that fires
-- HIGH severity when EITHER:
--   - The most recent pipeline run has status='failed' (last 36 hours), OR
--   - No successful pipeline run completed in the last 30 hours
--
-- A complementary system cron (deployed separately) polls this view every
-- hour and emits a notification when high-severity rows appear. This makes
-- the audit layer the single source of truth for "is the pipeline healthy?"
-- regardless of which workflow component fails.

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
where ag.display_status = 'active' and m.fc_client_id is null

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
-- G. parent_child_1040_false_positive (reads from _raw for visibility post-suppression)
select distinct 'parent_child_1040_false_positive', 'high', 'service_line',
  (raw.anchor_relationship_id || ':' || raw.service_name), raw.client_name, raw.fc_client_id, raw.anchor_relationship_id,
  'SLA would breach on "' || raw.service_name || '" for ' || raw.client_name
    || ' — but personal-1040 sibling "' || sibling.name
    || '" has a closed 1040 FC project (closed ' || sibling_proj.closed_at::date::text
    || ', after SLA target ' || raw.target_date::text
    || '). Auto-suppressed from operator queue.',
  raw.action_url, now()
from profit_sla_breached_candidates_raw raw
join profit_client_group_members business_member
  on business_member.fc_client_id = raw.fc_client_id and business_member.active = true
join profit_client_group_members sibling_member
  on sibling_member.group_id = business_member.group_id
 and sibling_member.fc_client_id <> business_member.fc_client_id and sibling_member.active = true
join profit_fc_clients sibling
  on sibling.fc_client_id = sibling_member.fc_client_id
 and sibling.is_archived = false and sibling.name ilike '%(1040)%'
join profit_fc_projects sibling_proj
  on sibling_proj.fc_client_id = sibling.fc_client_id
 and sibling_proj.is_closed = true and sibling_proj.title ilike '%1040%'
 and sibling_proj.closed_at::date >= raw.target_date
where raw.service_name ilike '1040%'

union all
-- H. paid_anchor_invoice_not_cleared (deduped, reads from _raw for visibility post-suppression)
select
  'paid_anchor_invoice_not_cleared'::text,
  'high'::text,
  'service_line'::text,
  (raw.anchor_relationship_id || ':' || raw.service_name) as subject_id,
  raw.client_name as subject_name,
  raw.fc_client_id,
  raw.anchor_relationship_id,
  'SLA would breach on "' || raw.service_name || '" but ' || agg.paid_inv_count
    || ' paid Anchor invoice(s) match the underlying service_id (latest: '
    || agg.latest_invoice_number || ', paid $' || agg.latest_amount_paid::text
    || ' on ' || agg.latest_issue_date::date::text
    || '). Auto-suppressed from operator queue. Mark Anchor service Completed to clear.' as description,
  raw.action_url,
  now()
from profit_sla_breached_candidates_raw raw
join lateral (
  select
    count(distinct inv.anchor_invoice_id) as paid_inv_count,
    (array_agg(inv.invoice_number order by inv.issue_date desc nulls last))[1] as latest_invoice_number,
    (array_agg(coalesce(inv.amount_paid, 0) order by inv.issue_date desc nulls last))[1] as latest_amount_paid,
    max(inv.issue_date) as latest_issue_date
  from profit_anchor_services_attributed asa
  join profit_anchor_invoice_line_items li
    on li.anchor_relationship_id = raw.anchor_relationship_id
   and li.service_id = asa.service_id
  join profit_anchor_invoices inv
    on inv.anchor_invoice_id = li.anchor_invoice_id
   and inv.qbo_status = 'paymentSynced'
   and coalesce(inv.amount_paid, 0) > 0
  where asa.anchor_relationship_id = raw.anchor_relationship_id
    and asa.canonical_service_name = raw.service_name
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
-- J. catalog_gap_service_no_rule
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
-- L. pipeline_stale_or_failed (NEW — V0.7.G.1 047)
-- Fires when EITHER:
--   - the most recent pipeline_run (within last 36h) has status='failed'
--   - no successful run completed in the last 30h
-- Both indicate the data pipeline is broken; operator queue + dashboards
-- will go stale until resolved.
select
  'pipeline_stale_or_failed'::text                     as alert_category,
  'high'::text                                          as severity,
  'pipeline_run'::text                                  as subject_kind,
  coalesce(latest.pipeline_run_id::text, 'no-recent-run') as subject_id,
  case
    when latest.pipeline_run_id is null then 'No pipeline run in last 36h'
    when latest.status = 'failed' then 'Latest pipeline run failed'
    else 'Pipeline appears unhealthy'
  end                                                  as subject_name,
  null::bigint                                         as fc_client_id,
  null::text                                           as anchor_relationship_id,
  case
    when latest.pipeline_run_id is null then
      'No pipeline run in last 36 hours. Nightly cron at 06:00 UTC (2 AM ET) '
      || 'may have failed silently. Check W29 schedule trigger + n8n container '
      || 'status. Manually trigger via POST /api/profit/admin/audit/pipeline-runs.'
    when latest.status = 'failed' then
      'Latest pipeline run ' || latest.pipeline_run_id::text
      || ' (' || latest.triggered_by || ') failed at '
      || latest.started_at::text
      || '. Recovery: inspect failed step in profit_pipeline_run_steps, fix root '
      || 'cause, retrigger via POST /api/profit/admin/audit/pipeline-runs.'
    else 'Pipeline state unclear; investigate profit_pipeline_runs.'
  end                                                  as description,
  null::text                                           as action_url,
  now()                                                as detected_at
from (
  -- Most recent pipeline run (within 36h) — null if none exists
  select pr.pipeline_run_id, pr.status, pr.triggered_by, pr.started_at
  from profit_pipeline_runs pr
  where pr.started_at > now() - interval '36 hours'
  order by pr.started_at desc
  limit 1
) latest
where
  -- Fire alert if: no recent run, OR most recent failed, OR no successful in 30h
  latest.pipeline_run_id is null
  or latest.status = 'failed'
  or not exists (
    select 1 from profit_pipeline_runs s
    where s.status = 'success'
      and s.finished_at > now() - interval '30 hours'
  );

comment on view profit_data_quality_alerts is
  'V0.7.E.0 + 040a/b/c + 042 + 047: 12 alert categories (A-L). New L
   pipeline_stale_or_failed fires when latest pipeline run failed OR no
   successful run in last 30h. Polled hourly by /opt/agents/outscore_profit/
   scripts/check_pipeline_health.sh system cron to send notifications.';

-- Verify
do $$
declare
  v_pipeline_stale_count integer;
  v_total integer;
begin
  select count(*) into v_pipeline_stale_count
    from profit_data_quality_alerts
   where alert_category = 'pipeline_stale_or_failed';
  select count(*) into v_total from profit_data_quality_alerts;
  raise notice '047 verify: pipeline_stale_or_failed count = % (expected 0 after successful run 75ad7327); total alerts = %',
    v_pipeline_stale_count, v_total;
end $$;
