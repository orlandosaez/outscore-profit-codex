-- Migration 050: pipeline cron attempts visibility (Layer 1 + Layer 2)
--
-- Problem solved: /profit/admin/pipeline reads profit_pipeline_runs, but
-- rows in that table are written only AFTER the API endpoint is reached.
-- If the n8n scheduler (W29) fires but its HTTP call to our API fails
-- (e.g., ECONNREFUSED — what's happened every night since 2026-05-16),
-- no pipeline_run row is created and the page is silently blind.
--
-- This migration creates a separate ledger that records EVERY n8n
-- schedule fire — successful or failed — so failures are always visible.
--
-- Layer 1: profit_pipeline_cron_attempts table + indexes
-- Layer 2: pipeline_cron_stale audit category (3 sub-conditions)
--
-- W29 workflow changes (separate file): two new Supabase HTTP nodes,
-- one BEFORE the API call (records 'fired'), one AFTER (PATCHes to
-- 'handed_off' on success or 'failed_handoff' with error message).
--
-- Frontend (PipelineRuns.jsx separate change): adds a top section
-- "Nightly schedule fires (last 7 days)" with green/red status per row.

-- ============================================================
-- A. profit_pipeline_cron_attempts
-- ============================================================
create extension if not exists pgcrypto;

create table if not exists profit_pipeline_cron_attempts (
  cron_attempt_id    uuid primary key default gen_random_uuid(),
  fired_at           timestamptz not null default now(),
  schedule_source    text not null default 'w29_nightly_2am_et',
  handoff_status     text not null default 'fired'
    check (handoff_status in ('fired', 'handed_off', 'failed_handoff')),
  handoff_error      text,
  pipeline_run_id    uuid references profit_pipeline_runs(pipeline_run_id),
  http_status_code   integer,
  completed_at       timestamptz,
  raw_response       jsonb,
  notes              text
);

create index if not exists idx_profit_pipeline_cron_attempts_fired_at
  on profit_pipeline_cron_attempts (fired_at desc);
create index if not exists idx_profit_pipeline_cron_attempts_status
  on profit_pipeline_cron_attempts (handoff_status);
create index if not exists idx_profit_pipeline_cron_attempts_run_id
  on profit_pipeline_cron_attempts (pipeline_run_id)
  where pipeline_run_id is not null;

comment on table profit_pipeline_cron_attempts is
  'V0.7.I (050): one row per n8n schedule trigger fire (W29 nightly cron).
   Written by W29 BEFORE the HTTP call to the API (handoff_status=fired),
   then PATCHed AFTER the call (handed_off on success, failed_handoff on
   error). Closes the silent-failure gap where API-unreachable failures
   left profit_pipeline_runs empty.';

-- ============================================================
-- B. Audit category: pipeline_cron_stale
-- ============================================================
create or replace view profit_data_quality_alerts as
-- Existing categories from 040 + 040a/b/c (preserved verbatim)
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
select 'anchor_no_fc_match', 'medium', 'anchor_agreement',
  ag.anchor_relationship_id, ag.client_business_name, null::bigint, ag.anchor_relationship_id,
  'Active Anchor agreement has no FC client match — billing + SLA tracking blind.',
  coalesce(ag.raw->>'link', 'https://app.sayanchor.com/home/relationship/' || ag.anchor_relationship_id || '/agreement'),
  now()
from profit_anchor_agreements ag
left join profit_fc_client_anchor_matches m on m.anchor_relationship_id = ag.anchor_relationship_id
where ag.display_status = 'active' and m.fc_client_id is null

union all
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
-- 050 NEW: pipeline_cron_stale (3 sub-conditions)
-- Sub-condition A: latest cron attempt failed_handoff
select
  'pipeline_cron_stale'::text,
  'high'::text,
  'anchor_agreement'::text,  -- subject_kind placeholder
  ca.cron_attempt_id::text,
  'Nightly cron handoff failed' as subject_name,
  null::bigint,
  null::text,
  'Last n8n schedule fire at ' || to_char(ca.fired_at, 'YYYY-MM-DD HH24:MI')
    || ' UTC failed to reach the pipeline API: ' || coalesce(ca.handoff_error, '<no error captured>')
    || '. No pipeline_run was created. Paste this to Claude: "Pipeline page latest schedule fire failed at '
    || to_char(ca.fired_at, 'YYYY-MM-DD HH24:MI') || ' with ' || coalesce(ca.handoff_error, 'unknown') || '."',
  '/profit/admin/pipeline',
  now()
from (
  select * from profit_pipeline_cron_attempts
   where handoff_status = 'failed_handoff'
   order by fired_at desc
   limit 1
) ca
where ca.fired_at > now() - interval '30 hours'

union all
-- Sub-condition B: no cron attempt at all in last 26h
select
  'pipeline_cron_stale'::text,
  'high'::text,
  'anchor_agreement'::text,
  'no_cron_fire_in_26h'::text,
  'Nightly cron has not fired'::text,
  null::bigint,
  null::text,
  'No n8n schedule fire recorded in the last 26 hours. Either the cron trigger is disabled, '
    || 'or n8n is down. Paste this to Claude: "Pipeline page shows no schedule fires in last 26h. '
    || 'Check W29 status and n8n container health."',
  '/profit/admin/pipeline',
  now()
where not exists (
  select 1 from profit_pipeline_cron_attempts
   where fired_at > now() - interval '26 hours'
)

union all
-- Sub-condition C: no successful pipeline_run in last 30h
-- (catches the case where cron + handoff succeeded but the run itself never recorded success)
select
  'pipeline_cron_stale'::text,
  'high'::text,
  'anchor_agreement'::text,
  'no_successful_pipeline_run_in_30h'::text,
  'Pipeline has not run successfully'::text,
  null::bigint,
  null::text,
  'Latest successful pipeline_run is more than 30 hours old. Paste to Claude: '
    || '"Pipeline page latest success is YYYY-MM-DD HH:MM. Investigate why no fresh runs."',
  '/profit/admin/pipeline',
  now()
where not exists (
  select 1 from profit_pipeline_runs
   where status = 'success'
     and started_at > now() - interval '30 hours'
);

comment on view profit_data_quality_alerts is
  'V0.7.I (050): adds pipeline_cron_stale alert category (3 sub-conditions). '
  'Closes the silent-failure gap where W29 fires but the HTTP handoff to the '
  'API fails — operator now sees a row in the self-audit immediately.';

-- ============================================================
-- Verify
-- ============================================================
do $$
begin
  perform 1 from pg_tables where tablename = 'profit_pipeline_cron_attempts';
  if not found then raise exception '050 verify FAIL: cron_attempts table missing'; end if;
  perform 1 from pg_views where viewname = 'profit_data_quality_alerts';
  if not found then raise exception '050 verify FAIL: data_quality_alerts view missing'; end if;
  raise notice '050 verify: schema OK (table + view present)';
end $$;
