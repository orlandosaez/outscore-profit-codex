-- Migration 039: exclude Anchor-native service_status='completed' from SLA + Manual Invoice candidates
--
-- Discovery 2026-05-13: Anchor's agreement UI has a "Stopped and completed services"
-- section. Operator screenshot of Celtic Auto Werks Inc shows both:
--   - "1040 Plus - 2025 Individual Return Prep and Filing"     ($350) — Completed
--   - "1120 Plus - 2025 Tax Prep and Filing for Celtic Auto"   ($550) — Completed
--
-- Yet both lines still surfaced in our SLA queue because our views walk FC
-- project closure state but ignore Anchor's own service_status field.
--
-- System-wide query confirmed:
--   19 services across active agreements have service_status='completed'
--  130 services have service_status='approved'
--
-- Anchor's "completed" flag is the cleanest billing/delivery clearance signal
-- available — it's set by the operator inside Anchor when work is delivered
-- AND invoiced (i.e. the line item is officially closed out of the agreement
-- scope). Honoring it eliminates a class of false positives across BOTH SLA
-- and Manual Invoice Pending without needing FC project metadata at all.
--
-- Fix:
--   A. profit_sla_breached_candidates: skip rows whose underlying Anchor
--      service line is service_status='completed'. profit_anchor_services_attributed
--      already exposes service_status — just filter source_items.
--
--   B. profit_manual_invoice_pending_candidates: skip jsonb service-summary
--      entries whose s->>'status'='completed' inside the manual_services CTE.
--      A row only surfaces when there's still at least one non-completed
--      manual service on the agreement.
--
-- Verbatim preservation of 035h (SLA) and 038c (Manual Invoice) view bodies;
-- only the explicit filter lines added. CREATE OR REPLACE column-order
-- constraint observed — no columns added, removed, or reordered.

------------------------------------------------------------------------
-- A. SLA view — exclude Anchor-completed service lines
------------------------------------------------------------------------
create or replace view profit_sla_breached_candidates as
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
  -- V0.7.D-3 hotfix 039: skip Anchor-native "completed" service lines.
  -- Anchor's "Stopped and completed services" section sets service_status='completed'
  -- when the operator marks the line delivered + billed. That's a stronger
  -- clearance signal than FC project closure — and the only signal that
  -- covers cases where work was billed via QBO before FC project closure.
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
  -- XLSX-seeded transitional cache (035e/035f). Queued for deprecation.
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
  -- V0.7.D-1.1 (035h): FC custom_fields wins. Falls back to XLSX-seeded
  -- assignment (035e/035f), then derived FC-task preparer (035a/035d).
  -- For book-tagged SLAs (fc_tag starts with 'S BOOK'), read Book Primary;
  -- otherwise read Tax Preparer.
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

comment on view profit_sla_breached_candidates is
  'V0.7.D-1.1 + 039: SLA candidates with FC custom_fields staff routing AND Anchor-native service_status=''completed'' exclusion. Underlying Anchor service lines marked Completed in the agreement''s "Stopped and completed services" section never surface, regardless of FC project state.';

------------------------------------------------------------------------
-- B. Manual Invoice Pending view — exclude Anchor-completed manual lines
------------------------------------------------------------------------
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
    -- V0.7.D-3 hotfix 039: skip Anchor-native completed manual service lines.
    -- Once operator marks a manual line "Completed" in Anchor's "Stopped and
    -- completed services" section, it's billed + closed out of scope.
    and coalesce(s->>'status', '') <> 'completed'
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
  and coalesce(closures.closed_project_count, 0) > 0
  and not exists (
    select 1 from client_open_service_work cosw
    where cosw.fc_client_id = match.fc_client_id
  )
  and (
    invoice_rollup.last_issued_at is null
    or closures.last_closed_at > invoice_rollup.last_issued_at
  );

comment on view profit_manual_invoice_pending_candidates is
  'V0.7.D-3 + 038c + 039: Manual Invoice Pending now also honors Anchor-native service_status. Manual service lines marked "Completed" in Anchor''s Stopped and completed services section drop from the manual_services aggregate; a row only surfaces if the agreement still has at least one non-completed manual line AND closed-service-mapped FC project AND no open service-mapped FC work AND no QBO-issued invoice after last closure.';
