-- Migration 034b: SLA candidate view sources from attribution layer
-- V0.7.B.4 T4 — labeled service attribution applied to SLA tracking
--
-- profit_sla_breached_candidates is rewritten to source from
-- profit_anchor_services_attributed (per Orlando's labeled-service rule)
-- rather than profit_sla_service_items (which only tracks services with
-- revenue events, missing all manual-trigger annual services).
--
-- Key changes from 031/030c:
--   - REMOVED the 1040-on-business regex (content-specific V0.7.B.3 rule).
--     Orlando's labeled-service rule supersedes it: if a 1040 service
--     should attribute to a different entity (e.g., the owner's individual
--     FC client), the Anchor agreement has a label. The attribution view
--     applies that. No code knows about "1040" or "LLC".
--   - SOURCE switched from profit_sla_service_items to
--     profit_anchor_services_attributed. The attribution view covers EVERY
--     active Anchor service, not just those with revenue events. This
--     surfaces ICE / Lee's / Accelerated manual-trigger annual services
--     that weren't previously SLA-tracked.
--   - sla_state computation MOVED inline (was in profit_sla_service_items).
--     Mirrors the same CASE logic verbatim. Drops not_applicable + waiting_on_client
--     special cases (V0.7.D will reintroduce via workflow_status sync).
--   - PRESERVED: V0.7.B.1 T6a clearance filters (completed task, closed project).
--   - PRESERVED: V0.7.B.1 T6a's active-classification dedup via
--     source_audit_row_hash + superseded_at IS NULL.
--   - NEW columns surfaced: label, label_unresolved (operator visibility for
--     orphan attributions).
--
-- No content-specific rules. The candidate view is fully data-driven:
-- recognition rules drive SLA targets; attribution drives client mapping;
-- task/project completion drives clearance.
--
-- Verified live (V0.7.B.4 T3): 17 of 29 labeled services resolved correctly,
-- 12 unresolved (Type 2 annotations) stay on agreement holder with flag.
--
-- Predeploy smoke gate must pass before commit (V0.7.B.1 T5).
-- Depends on: 034 (parser), 034a (attribution view).

create or replace view profit_sla_breached_candidates as
with source_items as (
  -- Every attributed service joined to its recognition rule for SLA targets.
  -- One row per (anchor_relationship_id, canonical_service_name, label).
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
    -- trigger_date: when the SLA clock starts
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date
      else null::date
    end as trigger_date,
    -- target_date: SLA deadline = trigger_date + default_sla_day (with period adjustments)
    case rule.service_period_rule
      when 'tax_year_default' then make_date(extract(year from current_date)::int, 1, 1) + (rule.default_sla_day - 1)
      when 'previous_month'   then date_trunc('month', current_date::timestamptz)::date + (rule.default_sla_day - 1)
      when 'previous_quarter' then date_trunc('quarter', current_date::timestamptz)::date + rule.default_sla_day
      else null::date
    end as target_date,
    -- Build source_audit_row_hash matching V0.7.B's dedup scheme
    'sla_breached:' || asa.attributed_fc_client_id::text || ':' || asa.canonical_service_name as source_audit_row_hash
  from profit_anchor_services_attributed asa
  left join profit_service_recognition_rules rule
    on rule.service_name = asa.canonical_service_name
),
state_inputs as (
  select
    si.*,
    current_date - trigger_date as age_days,
    -- sla_state: mirrors profit_sla_service_items' state machine, minus
    -- workflow_status integration (V0.7.D dependency).
    case
      when si.recognition_pattern in ('manual_review', 'pass_through')
        or si.service_period_rule in ('manual', 'pass_through')
        or si.default_sla_day is null
        or si.target_date is null
        then 'not_applicable'::text
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
  -- Keep only breached and at_risk; drop services where attributed client has
  -- a completed FC task or closed FC project matching the canonical service.
  -- Clearance match uses split_part(service_name, ' ', 1) for project_title
  -- ILIKE fallback (Task 1 found tag_type='service' bridge empty pending V0.7.D).
  select *
  from state_inputs si
  where si.sla_state in ('breached', 'at_risk')
    and si.default_sla_day is not null
    and si.target_sla_day is not null
    and si.target_date is not null
    and si.fc_client_id is not null  -- need an attributed client to surface
    and not exists (
      select 1 from profit_fc_tasks task
      where task.fc_client_id = si.fc_client_id
        and (task.is_completed = true or task.completed_at is not null)
        and (
          task.fc_project_id in (
            select t.fc_project_id from profit_fc_project_tags t
            where t.tag_type = 'service' and t.tag_name = si.fc_tag
          )
          or task.project_title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    )
    and not exists (
      select 1 from profit_fc_projects project
      where project.fc_client_id = si.fc_client_id
        and (project.is_closed = true or project.closed_at is not null)
        and (
          project.fc_project_id in (
            select t.fc_project_id from profit_fc_project_tags t
            where t.tag_type = 'service' and t.tag_name = si.fc_tag
          )
          or project.title ilike '%' || split_part(si.service_name, ' ', 1) || '%'
        )
    )
),
active_sla_classification as (
  -- Existing active classifications, keyed on (fc_client_id, service_name)
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
)
-- Column order MUST match prior view (031/030c) exactly to satisfy
-- CREATE OR REPLACE VIEW constraint. New attribution columns appended.
--
-- Collapse rule: DISTINCT ON (attributed_fc_client_id, canonical_service_name)
-- so a personal 1040 attributed from multiple business agreements (e.g., Lee
-- Wolfson on both Lee's Food + Lee's Ice) collapses to ONE queue row. Order
-- by: prefer unlabeled (label IS NULL) over labeled, prefer resolved over
-- unresolved, prefer earliest target_date. Annotation duplicates (e.g., YV's
-- "1040 Plus" + "1040 Plus - proration for monthly billing" both attributing
-- to YV) collapse to the unlabeled main entry.
select distinct on (filtered.fc_client_id, filtered.service_name)
  -- Existing columns (positions 1-22, must not reorder):
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
  'Unassigned'::text as assigned_staff_name,
  'unassigned'::text as staff_source,
  null::text as latest_workflow_status,
  null::bigint as fc_task_id,
  null::bigint as fc_project_id,
  'https://app.sayanchor.com/home/relationship/' || filtered.anchor_relationship_id || '/agreement' as action_url,
  -- V0.7.B.4 NEW columns (appended; safe for CREATE OR REPLACE):
  filtered.label,
  filtered.label_unresolved,
  filtered.resolution_strategy,
  filtered.anchor_client_business_name as agreement_client_business_name
from filtered
left join active_sla_classification
  on active_sla_classification.fc_client_id = filtered.fc_client_id
 and active_sla_classification.service_name = filtered.service_name
order by
  filtered.fc_client_id,
  filtered.service_name,
  (filtered.label is null) desc,           -- prefer unlabeled (main entry over annotation)
  filtered.label_unresolved asc nulls first,  -- among labeled, prefer resolved
  filtered.target_date asc nulls last;      -- prefer earlier target

comment on view profit_sla_breached_candidates is
  'V0.7.B.4 T4: rewritten to source from profit_anchor_services_attributed + profit_service_recognition_rules. Per Orlando''s labeled-service rule: services attribute to labeled FC client (if label resolves) or agreement holder (default/unresolved). Includes services WITHOUT revenue events (ICE/Lee''s manual annual services now surface). Drops V0.7.B.3 content-specific 1040-on-business regex. No content-specific rules anywhere in this view. Staff routing + workflow_status deferred to V0.7.D (returns "Unassigned" universally for now). label and label_unresolved exposed for frontend badge rendering.';
