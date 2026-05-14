-- Migration 043b: V0.7.E.0.3 Sprint C T2+T4 — final catalog gap closure
--
-- Final 2 catalog_gap_service_no_rule audit findings closed.
--
-- Operator confirmation 2026-05-13:
--
-- 1. Bookkeeping Services (Collectiv Inc., $4000/mo)
--    Operator: 10th day of the following month. Same cadence as
--    Accounting Plus (sla_day=10). Collectiv is the only client with
--    this exact canonical_service_name; their FC project is tracked
--    via the bookkeeping tag.
--    → monthly_recurring / previous_month / sla_day=10
--
-- 2. 1040 Plus (w/ support) (DVH Investing LLC, $650 yearly)
--    Operator: "same as 1040 rule, not special". Mirror plain 1040 Plus.
--    → tax_filing / tax_year_default / sla_day=104, fc_tag='S 1040P'
--
-- Predicted impact: catalog_gap_service_no_rule drops 2 → 0.
-- DVH's 1040 work becomes SLA-trackable (Apr 14 target).
-- Collectiv's monthly bookkeeping becomes SLA-trackable (10th of
-- next month target).

insert into profit_service_recognition_rules
  (service_name, macro_service_type, recognition_pattern, service_period_rule,
   default_sla_day, fc_tag, qbo_category_path, qbo_product_name, entity_type,
   notes, source)
values
  (
    'Bookkeeping Services',
    'bookkeeping',
    'monthly_recurring',
    'previous_month',
    10,
    'S BOOKP',
    null,
    null,
    null,
    'V0.7.E.0.3 (043b): monthly bookkeeping close. Same cadence as '
      || 'Accounting Plus (sla_day=10) per operator. Currently Collectiv '
      || 'Inc. is the only client with this canonical_service_name.',
    'manual_seed'
  ),
  (
    '1040 Plus (w/ support)',
    'tax',
    'tax_filing',
    'tax_year_default',
    104,
    'S 1040P',
    null,
    null,
    'individual',
    'V0.7.E.0.3 (043b): variant of 1040 Plus with bundled support hours. '
      || 'Same SLA cadence as plain 1040 Plus per operator (Apr 14 target). '
      || 'fc_tag S 1040P matches the parent 1040 Plus rule.',
    'manual_seed'
  )
on conflict (service_name) do update
   set recognition_pattern = excluded.recognition_pattern,
       service_period_rule = excluded.service_period_rule,
       default_sla_day     = excluded.default_sla_day,
       macro_service_type  = excluded.macro_service_type,
       fc_tag              = excluded.fc_tag,
       entity_type         = excluded.entity_type,
       notes               = excluded.notes,
       updated_at          = now();

-- Verify catalog gap fully closed
do $$
declare
  v_gap_count integer;
begin
  select count(*) into v_gap_count
    from profit_data_quality_alerts
   where alert_category = 'catalog_gap_service_no_rule';
  raise notice '043b verify: catalog_gap_service_no_rule rows remaining = % (expected 0)', v_gap_count;
end $$;
