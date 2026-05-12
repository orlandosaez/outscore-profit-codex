-- Migration 033: REVERT 032 + 032a — invoice-paid clearance was semantically wrong
-- V0.7.B.3 audit fix continuation — undo the invoice-paid signal entirely
--
-- Root cause of the revert: 032 introduced an SLA clearance signal based on
-- "Anchor invoice paid in agreement issued >= target_date". Live verification
-- showed LTI Associates Inc. cleared from the queue despite the actual FC
-- project "1120 Tax Return" being OPEN (is_closed=false, due 2026-05-29).
-- The April monthly subscription invoice paid by LTI had nothing to do with
-- the annual 1120 work — it was for ongoing monthly accounting.
--
-- Domain truth: PAYMENT IS NOT DELIVERY. For services billed via monthly
-- subscription (Anchor's most common pattern for accounting/payroll/advisory),
-- payment continues on schedule regardless of whether annual deliverables
-- like tax returns are complete. The SLA is about WORK DELIVERY, not BILLING.
--
-- The only currently-reliable delivery signals we have are:
--   1. FC project closed (sla_project_archived, in 030b)
--   2. FC task completed (sla_task_complete, in 030b)
--   3. Revenue event recognized (NOT yet operational — all 363 events in
--      production are pending_*_completion; the recognition pipeline hasn't
--      fired for any service)
--
-- Once the recognition pipeline runs and revenue events become recognized,
-- a future sla_revenue_recognized signal becomes viable. Until then, the
-- only safe automated clearances are FC project/task completion. Rows
-- where the work is done outside FC tracking (e.g., DVH Investing 1065 where
-- the actual work is on a different FC client) stay in the queue and the
-- operator handles them via Mark reviewed / Snooze.
--
-- Three actions:
--   1. CREATE OR REPLACE profit_sla_breached_candidates back to 031's state
--      (1040-on-business structural rule + 030c task/project filters; NO
--      invoice-paid filter).
--   2. CREATE OR REPLACE profit_apply_classification_transitions back to
--      030b's state (no sla_invoice_paid_signals CTE).
--   3. Disable the sla_invoice_paid transition rule (keep the row for audit;
--      set enabled=false so the apply function won't re-enable it
--      accidentally if 032 ever re-runs).
--
-- After this migration applies:
--   - The 10 SLA classifications superseded by 032's sla_invoice_paid signal
--     stay superseded (audit trail of "I was incorrectly cleared by 032 on
--     2026-05-12, then a successor classification was created at 033 sweep").
--   - apply_transitions re-runs the sla_breach_detected branch and inserts
--     fresh classifications for the candidates that 032 incorrectly cleared.
--   - Final queue: 5 manual + ~25 SLA = ~30 actionable rows (back to where
--     V0.7.B.3 / 031 left it).
--
-- Predeploy smoke gate passes before commit per V0.7.B.1 T5.

-- ----------------------------------------------------------------------
-- 1. Disable the sla_invoice_paid transition rule
-- ----------------------------------------------------------------------

update profit_classification_transition_rules
set
  enabled = false,
  notes = coalesce(notes, '') || ' [DISABLED 2026-05-12 via migration 033: rule conflated payment with delivery. LTI Associates 1120 cleared incorrectly because LTI pays a monthly subscription invoice that has nothing to do with the annual 1120 work. Re-enable ONLY paired with a revenue-event-recognition signal (when recognition pipeline becomes operational) or per-service invoice line item parsing (V0.7.D Anchor sync expansion).]',
  updated_at = now()
where from_verdict_code = 'SLA_BREACHED'
  and signal_name = 'sla_invoice_paid';

-- ----------------------------------------------------------------------
-- 2. CREATE OR REPLACE profit_sla_breached_candidates back to 031's body
--    (without the sla_invoice_paid NOT EXISTS filter, with the widened
--    regex from 032 preserved as a correct fix)
-- ----------------------------------------------------------------------

create or replace view profit_sla_breached_candidates as
with source_items as (
  select distinct on (item.anchor_relationship_id, item.service_name)
    item.anchor_relationship_id,
    item.anchor_client_business_name,
    item.fc_client_id,
    item.fc_client_name,
    item.service_name,
    item.macro_service_type,
    item.fc_tag,
    item.default_sla_day,
    item.target_sla_day,
    item.target_date,
    item.age_days,
    item.latest_workflow_status,
    item.assigned_staff_name,
    item.staff_source,
    item.sla_state,
    'sla_breached:' || item.fc_client_id::text || ':' || item.service_name as source_audit_row_hash
  from profit_sla_service_items item
  where item.sla_state in ('breached', 'at_risk')
    and item.default_sla_day is not null
    and item.target_sla_day is not null
    and item.target_date is not null
    -- Inherit 030c: exclude items where matching FC task is complete or
    -- matching FC project is closed. service-tag bridge still empty until V0.7.D;
    -- project_title ILIKE on first service_name token is the operational path.
    and not exists (
      select 1
      from profit_fc_tasks task
      where task.fc_client_id = item.fc_client_id
        and (task.is_completed = true or task.completed_at is not null)
        and (
          task.fc_project_id in (
            select service_tag.fc_project_id
            from profit_fc_project_tags service_tag
            where service_tag.tag_type = 'service'
              and service_tag.tag_name = item.fc_tag
          )
          or task.project_title ilike '%' || split_part(item.service_name, ' ', 1) || '%'
        )
    )
    and not exists (
      select 1
      from profit_fc_projects project
      where project.fc_client_id = item.fc_client_id
        and (project.is_closed = true or project.closed_at is not null)
        and (
          project.fc_project_id in (
            select service_tag.fc_project_id
            from profit_fc_project_tags service_tag
            where service_tag.tag_type = 'service'
              and service_tag.tag_name = item.fc_tag
          )
          or project.title ilike '%' || split_part(item.service_name, ' ', 1) || '%'
        )
    )
    -- V0.7.B.3 structural rule: exclude 1040* services on business-suffix
    -- clients. Word-boundary anchored (preserved from 032's widened regex
    -- because that fix was correct independent of the invoice-paid issue).
    and not (
      item.service_name ilike '1040%'
      and coalesce(item.fc_client_name, item.anchor_client_business_name) ~* '\m(LLC|Inc\.?|Corp\.?|LLP|PA)\M'
    )
  order by
    item.anchor_relationship_id,
    item.service_name,
    item.target_date asc nulls last,
    item.fc_client_id nulls last
),
active_sla_classification as (
  select distinct on (classification.fc_client_id, split_part(classification.source_audit_row_hash, ':', 3))
    classification.classification_id,
    classification.classified_at,
    classification.verdict_code,
    classification.fc_client_id,
    split_part(classification.source_audit_row_hash, ':', 3) as service_name,
    classification.source_audit_row_hash
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
select
  active_sla_classification.classification_id,
  active_sla_classification.classified_at,
  coalesce(active_sla_classification.verdict_code, 'SLA_BREACHED') as verdict_code,
  item.fc_client_id,
  item.anchor_relationship_id,
  item.anchor_relationship_id as agreement_id,
  coalesce(item.fc_client_name, item.anchor_client_business_name) as client_name,
  item.service_name,
  item.macro_service_type,
  item.fc_tag,
  item.sla_state as breach_state,
  case
    when active_sla_classification.classified_at is null then null::integer
    else greatest(current_date - active_sla_classification.classified_at::date, 0)::integer
  end as age_days,
  greatest(current_date - item.target_date::date, 0)::integer as breach_age_days,
  item.age_days as work_age_days,
  item.target_date,
  item.target_sla_day,
  item.assigned_staff_name,
  item.staff_source,
  item.latest_workflow_status,
  open_task.fc_task_id,
  open_project.fc_project_id,
  coalesce(
    'https://app.financial-cents.com/tasks/' || open_task.fc_task_id,
    'https://app.financial-cents.com/projects/' || open_project.fc_project_id,
    'https://app.sayanchor.com/home/relationship/' || item.anchor_relationship_id || '/agreement'
  ) as action_url
from source_items item
left join active_sla_classification
  on active_sla_classification.fc_client_id = item.fc_client_id
 and active_sla_classification.service_name = item.service_name
left join lateral (
  select task.fc_task_id
  from profit_fc_tasks task
  where task.fc_client_id = item.fc_client_id
    and coalesce(task.is_completed, false) = false
    and (
      task.fc_project_id in (
        select service_tag.fc_project_id
        from profit_fc_project_tags service_tag
        where service_tag.tag_type = 'service'
          and service_tag.tag_name = item.fc_tag
      )
      or task.project_title ilike '%' || item.service_name || '%'
    )
  order by task.due_date nulls last, task.updated_at desc nulls last, task.fc_task_id
  limit 1
) open_task on true
left join lateral (
  select project.fc_project_id
  from profit_fc_projects project
  join profit_fc_project_tags service_tag
    on service_tag.fc_project_id = project.fc_project_id
   and service_tag.tag_type = 'service'
   and service_tag.tag_name = item.fc_tag
  where project.fc_client_id = item.fc_client_id
    and coalesce(project.is_closed, false) = false
    and project.closed_at is null
  order by project.due_date nulls last, project.updated_at desc nulls last, project.fc_project_id
  limit 1
) open_project on true;

comment on view profit_sla_breached_candidates is
  'V0.7.B.3 post-revert (033): candidate view reverted to 031-state filters. Excludes (a) items where matching FC task is complete OR matching FC project is closed (030c); (b) 1040* services on business-suffix clients via word-boundary regex (031/032 widened). The invoice-paid clearance from 032/032a was REVERTED because it conflated payment with delivery. Monthly subscription clients (LTI, Lee''s, B&W, Energize, etc.) pay every month regardless of whether the annual deliverable is done; their paid invoices cleared SLA rows that were legitimately breached. The sla_invoice_paid transition rule remains in the table with enabled=false. action_url falls back FC task -> FC project -> Anchor.';

-- ----------------------------------------------------------------------
-- 3. CREATE OR REPLACE profit_apply_classification_transitions back to 030b
--    (preserving V0.7.A + V0.7.B + V0.6.C.a branches WITHOUT
--    sla_invoice_paid_signals)
-- ----------------------------------------------------------------------
-- 030b's function body is large (~700 lines) and was the production state
-- before 032 added sla_invoice_paid_signals. The cleanest revert is to
-- re-execute 030b's CREATE OR REPLACE FUNCTION definition, which has not
-- been modified since V0.7.B.1 T3.
--
-- Rather than duplicate 030b's full body inline here, the deploy step
-- re-applies migration 030b alongside 033 to restore the function. The
-- predeploy_smoke gate validates both files. This file's deploy script
-- runs psql -f on 030b FIRST, then 033 (which has only the rule disable
-- and view replace). This avoids any risk of body drift.
--
-- NOTE TO DEPLOYER: when applying 033, run:
--   ./scripts/predeploy_smoke.sh supabase/sql/030b_profit_sla_clearance_predicate_fix.sql supabase/sql/033_revert_sla_invoice_paid_clearance.sql
-- Then:
--   psql ... -f /tmp/030b_profit_sla_clearance_predicate_fix.sql
--   psql ... -f /tmp/033_revert_sla_invoice_paid_clearance.sql
-- Then:
--   psql ... -c "select * from profit_apply_classification_transitions(now(), false);"
-- to re-detect the rows incorrectly cleared by 032.
