-- Migration 035d: Operator-managed FC user alias (V0.7.D-1 refinement)
--
-- Purpose: Financial Cents licenses are shared in Orlando's account (3
-- licenses cover 5+ staff). The result: raw->assignees[0]->name reads the
-- LOGIN that closed the task, not the human who did the work.
--
-- Login-sharing pattern (Orlando, 2026-05-12):
--   Login: orlando@outscore.com  → Beth (only billable staff in account)
--   Login: noelle@outscore.com   → Wama OR Noelle (shared; Wama on Collectiv,
--                                   Noelle on others; cannot disambiguate
--                                   from FC data alone)
--   Login: laura@outscore.com    → Laura (solo)
--
-- Practical consequence for V0.7.D-1: profit_fc_client_primary_preparer
-- (migration 035a) emits "Orlando Saez" as the top assignee for ~21 SLA
-- clients. Those are Beth's hours, not Orlando's. Without this alias the
-- queue mislabels billable work.
--
-- This table is operator-managed metadata, not a content-specific code
-- rule. As Orlando hires staff, changes login-sharing patterns, or as
-- license counts evolve, rows are added/edited via SQL INSERT/UPDATE. No
-- code change required.
--
-- Future consumers (post V0.7.D):
--   - Hourly rate joins (Beth $45, Laura $60, Wama $16, Julie $30 per
--     coordination/memory). billable_staff_name is the join key.
--   - Workload routing (Wama on Collectiv-only vs Noelle on other clients —
--     requires per-client-segment disambiguation, deferred).
--   - Timesheet integration (Laura could log time via FC if needed; alias
--     table accommodates).
--
-- For V0.7.D-1, only display_label is consumed by 035b SLA candidate view.
--
-- Depends on: nothing structural.
-- Predeploy_smoke.sh gate must pass before live apply.

create table if not exists profit_fc_user_alias (
  fc_user_name        text primary key,
  display_label       text not null,
  billable_staff_name text,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table profit_fc_user_alias is
  'V0.7.D-1: operator-managed alias for FC raw->assignees[0]->name. Compensates for FC license-sharing pattern (Orlando shares 3 licenses across 5+ staff). display_label is the human-meaningful name shown in Weekly Review SLA queue. billable_staff_name is the hourly-billable identity (NULL when ambiguous, e.g., shared logins covering multiple billable staff).';

comment on column profit_fc_user_alias.display_label is
  'Shown in Weekly Review assigned_staff_name. Format: "Real Name (FC login share)" when shared, "Real Name" when solo, "A/B (FC login share)" when ambiguous.';

comment on column profit_fc_user_alias.billable_staff_name is
  'Canonical billable staff identity for hourly-rate joins. NULL when the FC user maps to multiple billable identities and the SLA/task layer cannot disambiguate (e.g., Wama vs Noelle sharing a Collectiv-and-other-clients login).';

-- =============================================================================
-- Seed: 3 rows matching Orlando's 2026-05-12 login-sharing description
-- =============================================================================
insert into profit_fc_user_alias (fc_user_name, display_label, billable_staff_name, notes) values
  ('Orlando Saez',
   'Beth (FC login share)',
   'Beth',
   'Beth is the only billable staff in Orlando''s FC account. She logs under orlando@outscore.com to do all client work. The "Orlando Saez" appearing in raw->assignees represents Beth''s hours, not Orlando''s.'),

  ('Noelle Davids',
   'Wama/Noelle (FC login share)',
   null,
   'Shared login covering Wama (Collectiv work) and Noelle (other client responsibilities). Cannot disambiguate from FC user field alone; would require per-client-segment lookup or task-content inspection. billable_staff_name left NULL until disambiguation logic exists. Rates: Wama $16/hr, Noelle (rate TBD).'),

  ('Laura Sitkiewicz',
   'Laura',
   'Laura',
   'Solo FC login. Real-name == FC user name. Rate: Laura $60/hr.')

on conflict (fc_user_name) do update set
  display_label = excluded.display_label,
  billable_staff_name = excluded.billable_staff_name,
  notes = excluded.notes,
  updated_at = now();

-- =============================================================================
-- Update profit_fc_client_primary_preparer to expose aliased label
-- =============================================================================
-- Rebuild the view to LEFT JOIN profit_fc_user_alias. Consumers (035b SLA
-- candidate view) read primary_preparer_display_label instead of the raw
-- primary_preparer_name. The raw name remains exposed for diagnostic /
-- backward-compat purposes.

create or replace view profit_fc_client_primary_preparer as
with assignee_counts as (
  select
    t.fc_client_id,
    nullif(trim(both from coalesce(t.raw->'assignees'->0->>'name', '')), '') as assignee_name,
    count(*) as task_count
  from profit_fc_tasks t
  where t.is_completed = true
    and t.completed_at is not null
    and t.completed_at >= now() - interval '365 days'
    and t.fc_client_id is not null
  group by t.fc_client_id, nullif(trim(both from coalesce(t.raw->'assignees'->0->>'name', '')), '')
),
ranked as (
  select
    fc_client_id,
    assignee_name,
    task_count,
    row_number() over (
      partition by fc_client_id
      order by
        (assignee_name is null) asc,
        task_count desc,
        assignee_name asc nulls last
    ) as rnk
  from assignee_counts
)
select
  -- Original 035a column order preserved (positions 1-5):
  ranked.fc_client_id,
  ranked.assignee_name              as primary_preparer_name,
  ranked.task_count                 as primary_preparer_task_count,
  (select sum(task_count) from assignee_counts ac where ac.fc_client_id = ranked.fc_client_id) as total_completed_tasks_365d,
  current_date                      as derived_at,
  -- V0.7.D-1 035d NEW columns (appended; CREATE OR REPLACE VIEW safe):
  coalesce(alias.display_label, ranked.assignee_name) as primary_preparer_display_label,
  alias.billable_staff_name         as primary_preparer_billable_name
from ranked
left join profit_fc_user_alias alias
  on alias.fc_user_name = ranked.assignee_name
where ranked.rnk = 1;

comment on view profit_fc_client_primary_preparer is
  'V0.7.D-1 (refined 035d): derived primary preparer per FC client from raw->assignees[0]->name over last 365 days of completed tasks. Joined to profit_fc_user_alias to compensate for FC license-sharing pattern. Exposes primary_preparer_display_label (human-meaningful, e.g., "Beth (FC login share)") and primary_preparer_billable_name (canonical billable identity for hourly-rate joins).';

-- =============================================================================
-- Update profit_sla_breached_candidates to consume primary_preparer_display_label
-- =============================================================================
-- Column order MUST match V0.7.B.4 exactly. Only the SELECT-list value for
-- assigned_staff_name changes (reads display_label instead of raw preparer name).

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
  -- V0.7.D-1 035d: aliased display label (Beth/Wama-Noelle/Laura), not raw FC user name
  coalesce(preparer.primary_preparer_display_label, 'Unassigned')::text as assigned_staff_name,
  case
    when preparer.primary_preparer_display_label is not null then 'derived_primary_preparer'::text
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
left join profit_fc_client_primary_preparer preparer
  on preparer.fc_client_id = filtered.fc_client_id
order by
  filtered.fc_client_id,
  filtered.service_name,
  (filtered.label is null) desc,
  filtered.label_unresolved asc nulls first,
  filtered.target_date asc nulls last;

comment on view profit_sla_breached_candidates is
  'V0.7.D-1 (refined 035d): assigned_staff_name reads primary_preparer_display_label (aliased), correcting FC login-share distortion. "Orlando Saez" FC user appears as "Beth (FC login share)"; "Noelle Davids" FC user appears as "Wama/Noelle (FC login share)" (ambiguous); "Laura Sitkiewicz" appears as "Laura". All other columns unchanged from 035b.';
