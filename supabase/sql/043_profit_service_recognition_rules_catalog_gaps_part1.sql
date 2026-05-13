-- Migration 043: V0.7.E.0.3 Sprint C T1 — catalog completion (bundle parents + Advisory)
--
-- Closes 3 of the 6 catalog_gap_service_no_rule audit findings. Remaining 3
-- (Bookkeeping Services, Onboarding bundle, 1040 Plus w/ support) deferred
-- to 043a after operator confirms cadence/SLA day.
--
-- Operator confirmation 2026-05-13:
--
-- 1. Advisory Service (Northridge Academy LLC, $175 manual one_time)
--    Operator definition: pre-approved hour bank for a-la-carte work outside
--    main engagement scope. No fixed deliverable, no fixed due date; operator
--    bills hours as consumed. → manual_review + manual (no SLA tracking,
--    operator owns billing trigger). Matches precedent of "Specialized
--    Services" + "Audit Protection*".
--
-- 2. Accounting and Tax Services (16 active agreements, $442–$939/mo)
-- 3. Accounting, Tax and Payroll Bundle (Anderson Kool Air LLC, $726.67/mo)
--    Operator definition: bundle-parent service lines. Opaque to client
--    (one monthly price) but internally Anchor decomposes into component
--    children at invoice time (is_bundle_parent=true on parent, components
--    have parent_line_item_id). Each child posts to its own QBO revenue
--    account (Accounting:Accounting Plus, Tax Work:1040 Plus, Payroll:
--    Payroll Service, etc.) — verified via Northridge SBC-00130 invoice
--    where the $938.76 bundle splits exactly into $667.78 + $190.06 +
--    $49.45 + $31.47.
--    → pass_through + manual (system ignores the parent; children continue
--    SLA + revenue tracking via their existing rules). Matches precedent
--    of "Billable Expenses" + "Services".
--
-- Predicted audit impact: catalog_gap_service_no_rule drops from 6 → 3.
-- SLA queue unchanged (parent never had deliverable tracking; children
-- already tracked).

insert into profit_service_recognition_rules
  (service_name, macro_service_type, recognition_pattern, service_period_rule,
   default_sla_day, fc_tag, qbo_category_path, qbo_product_name, entity_type,
   notes, source)
values
  (
    'Advisory Service',
    'advisory',
    'manual_review',
    'manual',
    null,
    null,
    null,
    null,
    null,
    'V0.7.E.0.3 (043): pre-approved hour bank, operator-billed as consumed. '
      || 'No SLA tracking, no auto-revenue recognition. Matches precedent of '
      || 'Specialized Services / Audit Protection.',
    'manual_seed'
  ),
  (
    'Accounting and Tax Services',
    'pass_through',
    'pass_through',
    'manual',
    null,
    null,
    null,
    null,
    null,
    'V0.7.E.0.3 (043): bundle-parent line. Anchor decomposes into component '
      || 'children at invoice time (is_bundle_parent=true). Children carry '
      || 'their own SLA rules + QBO revenue accounts (Accounting:Accounting '
      || 'Plus, Tax Work:1040 Plus, Tax Work:1120 Plus, Payroll:Payroll '
      || 'Service). System ignores the parent.',
    'manual_seed'
  ),
  (
    'Accounting, Tax and Payroll Bundle',
    'pass_through',
    'pass_through',
    'manual',
    null,
    null,
    null,
    null,
    null,
    'V0.7.E.0.3 (043): bundle-parent line (Anderson Kool Air pattern). Same '
      || 'decomposition mechanic as Accounting and Tax Services — children '
      || 'carry SLA + revenue rules.',
    'manual_seed'
  )
on conflict (service_name) do update
   set recognition_pattern = excluded.recognition_pattern,
       service_period_rule = excluded.service_period_rule,
       default_sla_day     = excluded.default_sla_day,
       macro_service_type  = excluded.macro_service_type,
       notes               = excluded.notes,
       updated_at          = now();

-- Verify: catalog gap count should drop by 3 immediately
do $$
declare
  v_gap_count integer;
begin
  select count(*) into v_gap_count
    from profit_data_quality_alerts
   where alert_category = 'catalog_gap_service_no_rule';
  raise notice '043 verify: catalog_gap_service_no_rule rows remaining = % (expected 3)', v_gap_count;
end $$;
