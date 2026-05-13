-- Migration 043a: V0.7.E.0.3 Sprint C T3 — catalog completion part 2
--
-- Two related changes per operator confirmation 2026-05-13:
--
-- A. NEW rule for B&B Technology Solutions' bundle line
--    "Onboarding, Quarterly review and Year End Accounting Close"
--    ($125 manual one_time). Operator: this $125 line is the
--    one-time onboarding fee for the engagement. → manual_review +
--    manual (operator handles billing; no SLA tracking on the line).
--    Closes 1 catalog_gap_service_no_rule audit finding.
--
-- B. UPDATE existing "Year End Accounting Close" rule. Previously
--    manual_review/manual with no SLA day. Operator: track at 90
--    days from January 1 = March 31 deadline for closing the prior
--    fiscal year. Translates to tax_year_default + sla_day=90 (target
--    = Jan 1 + 89 days = March 31 non-leap / April 1 leap year).
--    The existing fc_tag 'S YECLOSE' is preserved.
--
-- Predicted impact: catalog_gap_service_no_rule drops 3 → 2.
-- New rule for Year End Accounting Close means clients tagged 'S
-- YECLOSE' (whose FC project for YE Close isn't yet closed by March 31)
-- will start appearing in the SLA queue once the trigger date passes.

-- ----------------------------------------------------------------
-- A. Insert B&B onboarding-bundle rule
-- ----------------------------------------------------------------
insert into profit_service_recognition_rules
  (service_name, macro_service_type, recognition_pattern, service_period_rule,
   default_sla_day, fc_tag, qbo_category_path, qbo_product_name, entity_type,
   notes, source)
values
  (
    'Onboarding, Quarterly review and Year End Accounting Close',
    'advisory',
    'manual_review',
    'manual',
    null,
    null,
    null,
    null,
    null,
    'V0.7.E.0.3 (043a): one-time onboarding fee bundle line at B&B Technology. '
      || 'Operator handles billing trigger; no SLA tracking on the line. '
      || 'Recurring deliverables (quarterly review + YE close) tracked via '
      || 'separate canonical rules.',
    'manual_seed'
  )
on conflict (service_name) do update
   set recognition_pattern = excluded.recognition_pattern,
       service_period_rule = excluded.service_period_rule,
       default_sla_day     = excluded.default_sla_day,
       macro_service_type  = excluded.macro_service_type,
       notes               = excluded.notes,
       updated_at          = now();

-- ----------------------------------------------------------------
-- B. Update Year End Accounting Close to use tax_year_default
--    with sla_day=90 (March 31 deadline for prior-year close).
-- ----------------------------------------------------------------
-- recognition_pattern='tax_filing' is the existing annual-cadence pattern
-- (used by 1040 Plus, 1120 Plus, etc.). YE Close is bookkeeping but shares
-- the same annual cadence; reusing the pattern keeps the SLA-trigger logic
-- in source_items CTE consistent. If revenue categorization needs to
-- distinguish later, add a new pattern via CHECK constraint relaxation.
update profit_service_recognition_rules
   set recognition_pattern = 'tax_filing',
       service_period_rule = 'tax_year_default',
       default_sla_day     = 90,
       notes               = 'V0.7.E.0.3 (043a): updated from manual_review to '
                          || 'annual cadence. recognition_pattern=tax_filing '
                          || '(reused for the annual SLA semantic, not because '
                          || 'YE Close is a tax filing). SLA day 90 → target '
                          || 'March 31 (non-leap) / April 1 (leap) for closing '
                          || 'the prior fiscal year. Trigger = Jan 1 of '
                          || 'current year.',
       updated_at          = now()
 where service_name = 'Year End Accounting Close';

-- ----------------------------------------------------------------
-- Verify
-- ----------------------------------------------------------------
do $$
declare
  v_gap_count    integer;
  v_yeclose_row  record;
begin
  select count(*) into v_gap_count
    from profit_data_quality_alerts
   where alert_category = 'catalog_gap_service_no_rule';
  raise notice '043a verify: catalog_gap_service_no_rule rows remaining = % (expected 2)', v_gap_count;

  select recognition_pattern, service_period_rule, default_sla_day
    into v_yeclose_row
    from profit_service_recognition_rules
   where service_name = 'Year End Accounting Close';
  raise notice '043a verify: YE Close rule now = % / % / sla_day=%',
    v_yeclose_row.recognition_pattern,
    v_yeclose_row.service_period_rule,
    v_yeclose_row.default_sla_day;
end $$;
