create table if not exists profit_service_recognition_rules (
  service_name text primary key,
  macro_service_type text not null check (
    macro_service_type in ('bookkeeping', 'tax', 'payroll', 'sales_tax', 'advisory', 'pass_through', 'other')
  ),
  service_tier text,
  recognition_pattern text not null check (
    recognition_pattern in ('monthly_recurring', 'quarterly_recurring', 'tax_filing', 'one_time', 'pass_through', 'manual_review')
  ),
  service_period_rule text not null check (
    service_period_rule in ('previous_month', 'previous_quarter', 'tax_year_default', 'invoice_date', 'manual')
  ),
  default_sla_day integer,
  form_type_pattern text,
  notes text,
  source text not null default 'manual_seed' check (source in ('manual_seed', 'anchor_api_sync', 'manual_override')),
  last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_profit_service_recognition_rules_macro
  on profit_service_recognition_rules (macro_service_type);

create index if not exists idx_profit_service_recognition_rules_pattern
  on profit_service_recognition_rules (recognition_pattern);

alter table profit_anchor_agreements
  add column if not exists sla_day_override integer;

alter table profit_anchor_invoices
  add column if not exists invoice_note text;

alter table profit_anchor_invoice_line_items
  add column if not exists service_name text;

alter table profit_anchor_line_item_classifications
  add column if not exists service_name text;

alter table profit_revenue_events
  add column if not exists service_name text;

insert into profit_service_recognition_rules (
  service_name,
  macro_service_type,
  service_tier,
  recognition_pattern,
  service_period_rule,
  default_sla_day,
  form_type_pattern,
  notes,
  source,
  last_synced_at
) values
  ('Accounting Advanced', 'bookkeeping', 'Advanced', 'monthly_recurring', 'previous_month', 10, null, 'Per-engagement SLA override allowed via profit_anchor_agreements.sla_day_override.', 'manual_seed', now()),
  ('Accounting Plus', 'bookkeeping', 'Plus', 'monthly_recurring', 'previous_month', 10, null, 'Recognize from FC bookkeeping completion for prior month.', 'manual_seed', now()),
  ('Accounting Essential', 'bookkeeping', 'Essential', 'monthly_recurring', 'previous_month', 20, null, 'Recognize from FC bookkeeping completion for prior month.', 'manual_seed', now()),
  ('Sales Tax Compliance', 'sales_tax', null, 'monthly_recurring', 'previous_month', 20, null, 'Sales tax compliance is not annual income tax; keep out of tax_filed matching.', 'manual_seed', now()),
  ('Payroll Service', 'payroll', null, 'monthly_recurring', 'previous_month', null, null, 'SLA follows payroll cadence; recognize by payroll processed trigger.', 'manual_seed', now()),
  ('Tangible Property Tax', 'tax', null, 'manual_review', 'manual', null, null, 'Monthly billing exists but annual tangible-property cadence requires review.', 'manual_seed', now()),
  ('Audit Protection Business', 'other', 'Business', 'manual_review', 'manual', null, null, 'Insurance-style accrual; enum does not yet include insurance_accrual. Review before automated recognition.', 'manual_seed', now()),
  ('Audit Protection Individual', 'other', 'Individual', 'manual_review', 'manual', null, null, 'Insurance-style accrual; enum does not yet include insurance_accrual. Review before automated recognition.', 'manual_seed', now()),
  ('Fractional CFO', 'advisory', null, 'monthly_recurring', 'previous_month', null, null, 'Recognize on advisory delivery/monthly meeting cadence.', 'manual_seed', now()),
  ('1099 Preparation', 'tax', null, 'manual_review', 'manual', null, null, 'Monthly $0 edge case; require explicit review before automation.', 'manual_seed', now()),
  ('Payroll Tax Compliance', 'payroll', null, 'quarterly_recurring', 'previous_quarter', null, null, 'Quarterly federal/state deadline-driven SLA.', 'manual_seed', now()),
  ('1040 Essentials', 'tax', 'Essentials', 'tax_filing', 'tax_year_default', null, '1040', 'Tier is complexity, not timing.', 'manual_seed', now()),
  ('1040 Plus', 'tax', 'Plus', 'tax_filing', 'tax_year_default', null, '1040', 'Tier is complexity, not timing.', 'manual_seed', now()),
  ('1040 Advanced', 'tax', 'Advanced', 'tax_filing', 'tax_year_default', null, '1040', 'Tier is complexity, not timing.', 'manual_seed', now()),
  ('1065 Essential', 'tax', 'Essential', 'tax_filing', 'tax_year_default', null, '1065', 'Tier is complexity, not timing.', 'manual_seed', now()),
  ('1065 Plus', 'tax', 'Plus', 'tax_filing', 'tax_year_default', null, '1065', 'Tier is complexity, not timing.', 'manual_seed', now()),
  ('1065 Advanced', 'tax', 'Advanced', 'tax_filing', 'tax_year_default', null, '1065', 'Tier is complexity, not timing.', 'manual_seed', now()),
  ('1120 Essential', 'tax', 'Essential', 'tax_filing', 'tax_year_default', null, '1120', 'Matches 1120 and 1120S corporate returns.', 'manual_seed', now()),
  ('1120 Plus', 'tax', 'Plus', 'tax_filing', 'tax_year_default', null, '1120', 'Matches 1120 and 1120S corporate returns.', 'manual_seed', now()),
  ('1120 Advanced', 'tax', 'Advanced', 'tax_filing', 'tax_year_default', null, '1120', 'Matches 1120 and 1120S corporate returns.', 'manual_seed', now()),
  ('990-EZ Short Form', 'tax', 'Short Form', 'tax_filing', 'tax_year_default', null, '990-EZ', 'Nonprofit short form.', 'manual_seed', now()),
  ('990 Full Return Essential', 'tax', 'Essential', 'tax_filing', 'tax_year_default', null, '990', 'Nonprofit full return.', 'manual_seed', now()),
  ('990 Full Return Plus', 'tax', 'Plus', 'tax_filing', 'tax_year_default', null, '990', 'Nonprofit full return.', 'manual_seed', now()),
  ('990-T Unrelated Business', 'tax', null, 'tax_filing', 'tax_year_default', null, '990-T', 'Unrelated business income return.', 'manual_seed', now()),
  ('Annual Estimate Tax Review', 'tax', null, 'one_time', 'invoice_date', null, 'estimate review', 'Recognize when estimate review is delivered/completed.', 'manual_seed', now()),
  ('Advisory', 'advisory', null, 'one_time', 'invoice_date', null, null, 'Hourly project/ad-hoc advisory.', 'manual_seed', now()),
  ('Setup and Onboarding', 'advisory', null, 'one_time', 'invoice_date', null, null, 'Recognize at onboarding delivery/completion.', 'manual_seed', now()),
  ('Audit Support Service', 'advisory', null, 'one_time', 'invoice_date', null, null, 'Audit support is work performed, not audit protection.', 'manual_seed', now()),
  ('Specialized Services', 'advisory', null, 'manual_review', 'manual', null, null, 'Default $0/varies; review before automated recognition.', 'manual_seed', now()),
  ('Year End Accounting Close', 'bookkeeping', null, 'manual_review', 'manual', null, null, 'Default $0/varies; review before automated recognition.', 'manual_seed', now()),
  ('Work Comp Tax', 'payroll', null, 'manual_review', 'manual', null, null, 'Workers comp/payroll-adjacent compliance; review before automation.', 'manual_seed', now()),
  ('Billable Expenses', 'pass_through', null, 'pass_through', 'manual', null, null, 'Exclude from service revenue recognition.', 'manual_seed', now()),
  ('Other Income', 'pass_through', null, 'pass_through', 'manual', null, null, 'Exclude from service recognition unless separately reviewed.', 'manual_seed', now()),
  ('Remote Desktop Access', 'pass_through', null, 'pass_through', 'manual', null, null, 'Client reimbursement/access cost recovery.', 'manual_seed', now()),
  ('Remote QBD Access', 'pass_through', null, 'pass_through', 'manual', null, null, 'Client reimbursement/access cost recovery.', 'manual_seed', now()),
  ('Services', 'pass_through', null, 'pass_through', 'manual', null, null, 'Generic product excluded by default; explicit classification required.', 'manual_seed', now())
on conflict (service_name) do update set
  macro_service_type = excluded.macro_service_type,
  service_tier = excluded.service_tier,
  recognition_pattern = excluded.recognition_pattern,
  service_period_rule = excluded.service_period_rule,
  default_sla_day = excluded.default_sla_day,
  form_type_pattern = excluded.form_type_pattern,
  notes = excluded.notes,
  source = excluded.source,
  last_synced_at = now(),
  updated_at = now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profit_revenue_events_service_name_fkey'
  ) then
    alter table profit_revenue_events
      add constraint profit_revenue_events_service_name_fkey
      foreign key (service_name)
      references profit_service_recognition_rules(service_name);
  end if;
end $$;
