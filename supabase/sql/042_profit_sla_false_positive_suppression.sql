-- Migration 042: V0.7.E.0.2 — code-side false-positive suppression
--
-- Two audit signals from V0.7.E.0 (categories G + H of
-- profit_data_quality_alerts) reliably identify SLA queue false
-- positives. Per V0.7.E.0.2 plan, fold both signals BACK INTO the SLA
-- candidate view so the operator queue automatically drops:
--
--   G suppressor — parent-child 1040 false positive (1 row currently):
--     SLA breached on a 1040* service for a BUSINESS client AND a
--     personal-1040 sibling FC client (same client group, name matches
--     '%(1040)%') has a closed 1040 FC project AFTER the SLA target_date.
--     Likely: 1040 work was delivered under the personal entity.
--
--   H suppressor — paid Anchor invoice for same service_id (18 rows
--     currently): SLA breached BUT a paid Anchor invoice line item
--     (qbo_status='paymentSynced', amount_paid > 0) references the same
--     underlying Anchor service_id. Likely: service was billed + paid
--     out of band; operator just hasn't marked the Anchor line Completed.
--
-- Structural change:
--   1. Introduce profit_sla_breached_candidates_raw — exact canonical
--      body of the SLA candidate view from migration 039, renamed.
--      Column shape preserved verbatim.
--   2. Rewrite profit_sla_breached_candidates as a filtered passthrough
--      of _raw that excludes rows matching either suppressor.
--   3. Rewrite profit_data_quality_alerts categories G + H to read
--      from _raw (so the audit still shows the underlying state
--      mismatch even after the row drops from the operator queue).
--
-- Predicted impact: SLA queue 33 → ~14 rows (drops ~19 false positives).
-- Audit view total stays the same (~34 rows) since alerts G + H still
-- surface. Operator sees the audit category fire for suppressed rows.
--
-- Column-order preserved on both views per V0.7.B.4 constraint.

-- ============================================================
-- A. profit_sla_breached_candidates_raw — canonical pre-suppression view
--    (verbatim body from 039 — service_status='completed' filter included)
-- ============================================================
create or replace view profit_sla_breached_candidates_raw as
with source_items as (
  select
    asa.anchor_relationship_id,
    asa.attributed_fc_client_id as fc_client_id,
    asa.attributed_fc_client_name as fc_client_name,
    asa.agreement_client_business_name as anchor_client_business_name,
    asa.canonical_service_name as service_name,
    asa.raw_service_name,
    asa.label,
    asa.label_unresolved,
    asa.resolution_strategy,
    rule.macro_service_type,
    rule.recognition_pattern,
    rule.service_period_rule,
    rule.fc_tag,
    rule.default_sla_day,
    rule.default_sla_day as target_sla_day,
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date
      else null::date
    end as trigger_date,
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1) + (rule.default_sla_day - 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date + (rule.default_sla_day - 1)
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date + rule.default_sla_day
      else null::date
    end as target_date,
    'sla_breached:' || asa.attributed_fc_client_id::text || ':' || asa.canonical_service_name as source_audit_row_hash
  from profit_anchor_services_attributed asa
  left join profit_service_recognition_rules rule
    on rule.service_name = asa.canonical_service_name
  where coalesce(asa.service_status, '') <> 'completed'
),
project_workflow_status as (
  select
    p.fc_client_id,
    coalesce(m.fc_tag_prefix, 'NO_MAP') as fc_tag_prefix,
    p.title as project_title,
    pt.tag_name as workflow_status_name,
    case pt.tag_name
      when 'Waiting on Client'    then 1
      when 'In Preparation'       then 2
      when 'In Process'           then 3
      when 'Client info received' then 4
      else 5
    end as precedence
  from profit_fc_projects p
  left join profit_fc_template_service_map m on m.template_id = p.template_id
  inner join profit_fc_project_tags pt
    on pt.fc_project_id = p.fc_project_id
   and pt.tag_type = 'workflow_status'
  where p.is_closed = false
),
state_inputs as (
  select
    si.*,
    current_date - trigger_date as age_days,
    exists (
      select 1
      from project_workflow_status pws
      where pws.fc_client_id = si.fc_client_id
        and pws.workflow_status_name = 'Waiting on Client'
        and (
          si.fc_tag like pws.fc_tag_prefix || '%'
          or pws.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    ) as is_waiting_on_client,
    (
      select pws.workflow_status_name
      from project_workflow_status pws
      where pws.fc_client_id = si.fc_client_id
        and (
          si.fc_tag like pws.fc_tag_prefix || '%'
          or pws.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
      order by pws.precedence asc
      limit 1
    ) as derived_workflow_status,
    case
      when si.recognition_pattern in ('manual_review', 'pass_through')
        or si.service_period_rule in ('manual', 'pass_through')
        or si.default_sla_day is null
        or si.target_date is null
        then 'not_applicable'::text
      when exists (
        select 1
        from project_workflow_status pws
        where pws.fc_client_id = si.fc_client_id
          and pws.workflow_status_name = 'Waiting on Client'
          and (
            si.fc_tag like pws.fc_tag_prefix || '%'
            or pws.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
          )
      ) then 'waiting_on_client'::text
      when current_date > si.target_date
        then 'breached'::text
      when (current_date - si.trigger_date)::numeric
        >= greatest((si.target_sla_day - 2)::numeric, ceil(si.target_sla_day::numeric * 0.8))
        then 'at_risk'::text
      else 'on_track'::text
    end as sla_state
  from source_items si
),
filtered as (
  select *
  from state_inputs si
  where si.sla_state in ('breached', 'at_risk')
    and si.default_sla_day is not null
    and si.target_sla_day is not null
    and si.target_date is not null
    and si.fc_client_id is not null
    and not exists (
      select 1
      from profit_fc_tasks task
      left join profit_fc_projects task_project on task_project.fc_project_id = task.fc_project_id
      left join profit_fc_template_service_map task_map on task_map.template_id = task_project.template_id
      where task.fc_client_id = si.fc_client_id
        and (task.is_completed = true or task.completed_at is not null)
        and (
          (task_map.fc_tag_prefix is not null and si.fc_tag like task_map.fc_tag_prefix || '%')
          or task.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    )
    and not exists (
      select 1
      from profit_fc_projects project
      left join profit_fc_template_service_map proj_map on proj_map.template_id = project.template_id
      where project.fc_client_id = si.fc_client_id
        and (project.is_closed = true or project.closed_at is not null)
        and (
          (proj_map.fc_tag_prefix is not null and si.fc_tag like proj_map.fc_tag_prefix || '%')
          or project.title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    )
),
active_sla_classification as (
  select distinct on (classification.fc_client_id, split_part(classification.source_audit_row_hash, ':', 3))
    classification.classification_id,
    classification.classified_at,
    classification.verdict_code,
    classification.fc_client_id,
    split_part(classification.source_audit_row_hash, ':', 3) as service_name
  from profit_classifications classification
  where classification.verdict_code = 'SLA_BREACHED'
    and classification.superseded_at is null
    and classification.source_audit_file = 'system:sla_breached'
  order by
    classification.fc_client_id,
    split_part(classification.source_audit_row_hash, ':', 3),
    classification.classified_at desc,
    classification.classification_id desc
),
authoritative_assignment as (
  select
    csa.fc_client_id,
    csa.service_tags,
    csa.staff_primary,
    csa.staff_reviewer
  from profit_client_staff_assignment_resolved csa
  where csa.fc_client_id is not null
)
select distinct on (filtered.fc_client_id, filtered.service_name)
  active_sla_classification.classification_id,
  active_sla_classification.classified_at,
  coalesce(active_sla_classification.verdict_code, 'SLA_BREACHED') as verdict_code,
  filtered.fc_client_id,
  filtered.anchor_relationship_id,
  filtered.anchor_relationship_id as agreement_id,
  coalesce(filtered.fc_client_name, filtered.anchor_client_business_name) as client_name,
  filtered.service_name,
  filtered.macro_service_type,
  filtered.fc_tag,
  filtered.sla_state as breach_state,
  case
    when active_sla_classification.classified_at is null then null::integer
    else greatest(current_date - active_sla_classification.classified_at::date, 0)::integer
  end as age_days,
  greatest(current_date - filtered.target_date::date, 0)::integer as breach_age_days,
  filtered.age_days::integer as work_age_days,
  filtered.target_date,
  filtered.target_sla_day,
  coalesce(
    case
      when filtered.fc_tag like 'S BOOK%' then fc_cf.book_primary
      else fc_cf.tax_preparer
    end,
    auth.staff_primary,
    preparer.primary_preparer_display_label,
    'Unassigned'
  )::text as assigned_staff_name,
  case
    when filtered.fc_tag like 'S BOOK%' and fc_cf.book_primary is not null
      then 'fc_custom_field'::text
    when filtered.fc_tag not like 'S BOOK%' and fc_cf.tax_preparer is not null
      then 'fc_custom_field'::text
    when auth.staff_primary is not null
      then 'authoritative_assignment'::text
    when preparer.primary_preparer_display_label is not null
      then 'derived_primary_preparer'::text
    else 'unassigned'::text
  end as staff_source,
  filtered.derived_workflow_status as latest_workflow_status,
  null::bigint as fc_task_id,
  null::bigint as fc_project_id,
  'https://app.sayanchor.com/home/relationship/' || filtered.anchor_relationship_id || '/agreement' as action_url,
  filtered.label,
  filtered.label_unresolved,
  filtered.resolution_strategy,
  filtered.anchor_client_business_name as agreement_client_business_name
from filtered
left join active_sla_classification
  on active_sla_classification.fc_client_id = filtered.fc_client_id
 and active_sla_classification.service_name = filtered.service_name
left join profit_fc_client_staff_from_custom_fields fc_cf
  on fc_cf.fc_client_id = filtered.fc_client_id
left join lateral (
  select aa.staff_primary, aa.staff_reviewer
  from authoritative_assignment aa
  where aa.fc_client_id = filtered.fc_client_id
    and filtered.fc_tag = any(aa.service_tags)
  limit 1
) auth on true
left join profit_fc_client_primary_preparer preparer
  on preparer.fc_client_id = filtered.fc_client_id
order by
  filtered.fc_client_id,
  filtered.service_name,
  (filtered.label is null) desc,
  filtered.label_unresolved asc nulls first,
  filtered.target_date asc nulls last;

comment on view profit_sla_breached_candidates_raw is
  'V0.7.E.0.2 (042): canonical PRE-suppression SLA breach set. Mirrors the
   body of profit_sla_breached_candidates from 039 verbatim. Used by both
   the public profit_sla_breached_candidates view (which filters out
   known false-positive patterns) and profit_data_quality_alerts
   categories G + H (which surface the underlying state mismatch).';

-- ============================================================
-- B. profit_sla_breached_candidates — filtered passthrough
--    Drops two categories of known false positive:
--      - paid Anchor invoice matches the underlying service_id (H)
--      - parent-child 1040 sibling closed the 1040 project (G)
-- ============================================================
create or replace view profit_sla_breached_candidates as
select raw.*
from profit_sla_breached_candidates_raw raw
where
  -- Suppressor H: paid Anchor invoice line matches the same service_id.
  -- We resolve the service_id via profit_anchor_services_attributed
  -- (same (anchor_relationship_id, canonical_service_name) join used
  -- by the audit detector).
  not exists (
    select 1
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
  )
  -- Suppressor G: personal-1040 sibling has a closed 1040 FC project
  -- after this row's SLA target_date.
  and not exists (
    select 1
    from profit_client_group_members business_member
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
     and sibling_proj.closed_at::date >= raw.target_date
    where business_member.fc_client_id = raw.fc_client_id
      and business_member.active = true
      and raw.service_name ilike '1040%'
  );

comment on view profit_sla_breached_candidates is
  'V0.7.E.0.2 + 042: SLA breach queue with code-side false-positive
   suppression. Reads from profit_sla_breached_candidates_raw and drops:
   (1) rows where a paid Anchor invoice line item matches the same
   underlying service_id (paid-but-not-cleared), and (2) 1040* rows
   where a personal-1040 sibling has a closed 1040 FC project after
   the target_date (work done under the personal entity). Audit view
   profit_data_quality_alerts still surfaces both suppressors as
   categories H + G so operator sees the underlying state mismatch.';

-- ============================================================
-- C. profit_data_quality_alerts — categories G + H read from _raw
--    so they keep firing even after the public SLA view drops them.
-- ============================================================
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
-- G. parent_child_1040_false_positive (NOW READS FROM _raw)
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
-- H. paid_anchor_invoice_not_cleared (NOW READS FROM _raw, deduped)
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
  );

comment on view profit_data_quality_alerts is
  'V0.7.E.0 + 040a/b/c + 042: 11 alert categories. After 042, G + H
   read from profit_sla_breached_candidates_raw (the unfiltered SLA
   set) so they still fire for rows the public SLA view auto-suppresses.
   Operator sees the audit category for any row dropped by the
   suppressors — preserving cross-source visibility.';
