# Profit Dashboard V0.5.2 Service-Aware Recognition Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codify Anchor service recognition rules in the data model, capture service names and invoice notes from Anchor, and make tax recognition match by service/form type instead of brittle month equality.

**Architecture:** V0.5.2 introduces `profit_service_recognition_rules` as a sync-ready config table seeded from `docs/service-recognition-rules.md`. Anchor invoice sync starts carrying service names and invoice notes into Supabase, and the recognition-ready view gains tax-specific matching that uses form type, invoice note conventions, and ambiguity guards. This is foundation only: orchestration, run logs, refresh buttons, and live Anchor service sync are deferred to V0.5.3/V0.6+.

**Tech Stack:** Supabase Postgres migrations and views, n8n workflow JSON, FastAPI data contracts, Python `pytest`/`unittest`, existing Vite/React admin deployment.

---

## Authoritative References

- `docs/service-recognition-rules.md`: Anchor service taxonomy, macro routing, recognition timing, SLA defaults.
- `docs/anchor-invoice-note-conventions.md`: `TY:YYYY`, `FY:YYYY-MM`, and `Amended` note conventions for tax edge cases.
- `docs/data-contracts/recognition-triggers.md`: current trigger table and ready-view behavior.

## Scope

V0.5.2 is a foundation slice. It should make the database and sync layer service-aware, but it should not add operational UI controls, run-log orchestration, or a full reconciliation agent.

In scope:
- Config table and idempotent seed for Anchor service recognition rules.
- `sla_day_override` column for per-engagement SLA exceptions.
- Anchor sync capture of `service_name` and `invoice_note`.
- Revenue event capture of `service_name`.
- Tax matching by form type and invoice-note hints.
- Ambiguity detection that keeps unsafe tax events pending.
- Documentation and tests proving seed completeness and core matching behavior.

Out of scope:
- Anchor service API sync workflow. Track as future `Profit - 27 Anchor Service Sync`.
- QBO product category sync and config table.
- FC tag capture and tag-based matching.
- Pipeline orchestration, run log, or refresh button.
- SLA dashboard.
- Audit/reconciliation agent.

## Design Decisions And Pushback

### Config Table Is Transitional

`profit_service_recognition_rules` is the V0.5.2 executable copy of `docs/service-recognition-rules.md`. The table is intentionally shaped for a future Anchor API sync with `source` and `last_synced_at`, but V0.5.2 seeds it statically with `source = 'manual_seed'`.

The seed must be idempotent:

```sql
insert into profit_service_recognition_rules (...)
values (...)
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
```

### Audit Protection Macro Mismatch

`docs/service-recognition-rules.md` describes Audit Protection as `insurance_accrual`, but the V0.5.2 table enum only allows:

```sql
('bookkeeping', 'tax', 'payroll', 'sales_tax', 'advisory', 'pass_through', 'other')
```

V0.5.2 should not silently invent a new enum. Default:
- Seed `Audit Protection Business` and `Audit Protection Individual` as `macro_service_type = 'other'`.
- Use `recognition_pattern = 'manual_review'`.
- Use `service_period_rule = 'manual'`.
- Put the doctrine note in `notes`: `Insurance-style accrual; enum does not yet include insurance_accrual. Review before automated recognition.`

If Orlando later wants this automated, add `insurance_accrual` as a deliberate enum expansion in a future migration.

### Sales Tax Must Not Be Income Tax

`Sales Tax Compliance` becomes `macro_service_type = 'sales_tax'`, not `tax`. This prevents annual tax filing logic from trying to match sales tax events to `tax_filed` triggers.

### Tax Matching Needs A Safe Ambiguity Rule

Default tax behavior:
- Extract form type from FC trigger context.
- Match pending tax revenue events under the same `anchor_relationship_id`.
- Match only events whose `service_name` / configured `form_type_pattern` matches the form type.
- If exactly one oldest candidate is safe, expose it through `profit_revenue_events_ready_for_recognition`.

Ambiguous behavior:
- If multiple pending candidates have the same relationship + form type and no invoice note disambiguates tax year/fiscal year/amended status, do not auto-recognize.
- Keep those events pending.
- Surface ambiguity in a companion view for V0.5.3 run logs, e.g. `profit_tax_recognition_ambiguities`.

This resolves the apparent tension between "pick oldest pending" and "multiple matches without note." Picking oldest is safe when form type narrows to a single intended queue. When the same client has multiple pending events for the same form type and different years/edge cases, a note is required.

## Period Semantics

Recurring monthly services:
- `service_period_rule = 'previous_month'`.
- A completion in May generally recognizes April service revenue.

Quarterly recurring services:
- `service_period_rule = 'previous_quarter'`.
- SLA follows federal/state deadline context rather than a day-of-month default.

Annual tax services:
- `service_period_rule = 'tax_year_default'`.
- Do not require trigger month equality.
- Match by Anchor relationship + tax form type + invoice note scope when present.

One-time services:
- `service_period_rule = 'invoice_date'` or `manual`, depending on whether delivery can be inferred safely.

Pass-through services:
- `recognition_pattern = 'pass_through'`.
- Excluded from revenue-event creation and recognition pipeline.

## Files

- Create `supabase/sql/016_profit_service_recognition_rules.sql`: config table, SLA override column, service-name and invoice-note columns, idempotent seed.
- Create `supabase/sql/017_profit_tax_form_type_matching.sql`: helper functions/views and `profit_revenue_events_ready_for_recognition` replacement.
- Modify `n8n/workflows/profit-07-anchor-invoices-sync.json`: capture invoice note and line-item service name from Anchor payload.
- Modify `n8n/workflows/profit-11-classify-anchor-invoice-line-items.json`: classify from `profit_service_recognition_rules`-compatible service names and emit `service_name`.
- Modify `n8n/workflows/profit-15-load-revenue-event-candidates.json`: load `service_name` onto `profit_revenue_events`.
- Modify `docs/data-contracts/recognition-triggers.md`: describe service-aware matching, note parsing, ambiguity, and sync-ready config fields.
- Modify `docs/tech-debt.md`: add the three source-of-truth drift domains.
- Modify `tests/test_prepaid_liability_sql.py`: SQL migration and seed coverage.
- Modify `tests/test_recognition_triggers_sql.py`: ready-view tax matching coverage.
- Modify `tests/test_n8n_workflows.py`: workflow field-capture coverage.
- Modify `tests/test_revenue_classification.py`: service-rule mapping expectations.

## Task 1: SQL Coverage For Service Rules

**Files:**
- Modify `tests/test_prepaid_liability_sql.py`
- Create later: `supabase/sql/016_profit_service_recognition_rules.sql`

- [ ] **Step 1: Write failing migration coverage**

Add tests that assert the config table shape, sync-ready fields, idempotent seed pattern, SLA override, and key service rows:

```python
def test_service_recognition_rules_migration_defines_sync_ready_config(self) -> None:
    sql = Path("supabase/sql/016_profit_service_recognition_rules.sql").read_text()

    self.assertIn("create table if not exists profit_service_recognition_rules", sql)
    self.assertIn("service_name text primary key", sql)
    self.assertIn("macro_service_type in ('bookkeeping', 'tax', 'payroll', 'sales_tax', 'advisory', 'pass_through', 'other')", sql)
    self.assertIn("recognition_pattern in ('monthly_recurring', 'quarterly_recurring', 'tax_filing', 'one_time', 'pass_through', 'manual_review')", sql)
    self.assertIn("service_period_rule in ('previous_month', 'previous_quarter', 'tax_year_default', 'invoice_date', 'manual')", sql)
    self.assertIn("source text not null default 'manual_seed'", sql)
    self.assertIn("last_synced_at timestamptz not null default now()", sql)
    self.assertIn("sla_day_override integer", sql)
    self.assertIn("service_name text", sql)
    self.assertIn("invoice_note text", sql)
    self.assertIn("on conflict (service_name) do update set", sql.lower())
```

Add seed coverage:

```python
def test_service_recognition_rules_seed_covers_doctrine_services(self) -> None:
    sql = Path("supabase/sql/016_profit_service_recognition_rules.sql").read_text()

    expected_services = [
        "Accounting Advanced",
        "Accounting Plus",
        "Accounting Essential",
        "Sales Tax Compliance",
        "Payroll Service",
        "Tangible Property Tax",
        "Audit Protection Business",
        "Audit Protection Individual",
        "Fractional CFO",
        "1099 Preparation",
        "Payroll Tax Compliance",
        "1040 Essentials",
        "1040 Plus",
        "1040 Advanced",
        "1065 Essential",
        "1065 Plus",
        "1065 Advanced",
        "1120 Essential",
        "1120 Plus",
        "1120 Advanced",
        "990-EZ Short Form",
        "990 Full Return Essential",
        "990 Full Return Plus",
        "990-T Unrelated Business",
        "Annual Estimate Tax Review",
        "Advisory",
        "Setup and Onboarding",
        "Audit Support Service",
        "Specialized Services",
        "Year End Accounting Close",
        "Work Comp Tax",
        "Billable Expenses",
        "Other Income",
        "Remote Desktop Access",
        "Remote QBD Access",
        "Services",
    ]

    for service_name in expected_services:
        self.assertIn(service_name, sql)

    self.assertIn("'Sales Tax Compliance', 'sales_tax'", sql)
    self.assertIn("'Billable Expenses', 'pass_through'", sql)
    self.assertIn("'Remote Desktop Access', 'pass_through'", sql)
    self.assertIn("'Audit Protection Business', 'other'", sql)
    self.assertIn("Insurance-style accrual", sql)
```

- [ ] **Step 2: Run the SQL tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py -q
```

Expected: fail because `supabase/sql/016_profit_service_recognition_rules.sql` does not exist yet.

## Task 2: Create Service Rule Config Migration

**Files:**
- Create `supabase/sql/016_profit_service_recognition_rules.sql`
- Test `tests/test_prepaid_liability_sql.py`

- [ ] **Step 1: Create table, columns, and indexes**

Create `supabase/sql/016_profit_service_recognition_rules.sql` with:

```sql
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

alter table profit_revenue_events
  add column if not exists service_name text;
```

Add a nullable FK only after the column exists:

```sql
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
```

- [ ] **Step 2: Add idempotent seed rows**

Seed all doctrine services in one `insert ... values ... on conflict` block.

Use these rows:

```sql
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
```

- [ ] **Step 3: Run focused tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py -q
```

Expected: pass.

## Task 3: Anchor Sync Field Capture

**Files:**
- Modify `n8n/workflows/profit-07-anchor-invoices-sync.json`
- Modify `n8n/workflows/profit-11-classify-anchor-invoice-line-items.json`
- Modify `n8n/workflows/profit-15-load-revenue-event-candidates.json`
- Modify `tests/test_n8n_workflows.py`
- Modify `tests/test_revenue_classification.py`

- [ ] **Step 1: Write failing workflow coverage**

Add assertions to `tests/test_n8n_workflows.py`:

```python
def test_anchor_invoice_sync_captures_invoice_note_and_service_name(self) -> None:
    workflow = Path("n8n/workflows/profit-07-anchor-invoices-sync.json").read_text()

    self.assertIn("invoice_note", workflow)
    self.assertIn("invoice.note", workflow)
    self.assertIn("service_name", workflow)
    self.assertIn("lineItem.name", workflow)


def test_revenue_event_loader_carries_service_name(self) -> None:
    workflow = Path("n8n/workflows/profit-15-load-revenue-event-candidates.json").read_text()

    self.assertIn("service_name", workflow)
    self.assertIn("profit_revenue_events", workflow)
```

Add classification expectations to `tests/test_revenue_classification.py` or create a new static test if the current classifier is only embedded in workflow JSON:

```python
def test_anchor_line_item_classifier_uses_service_rule_names(self) -> None:
    workflow = Path("n8n/workflows/profit-11-classify-anchor-invoice-line-items.json").read_text()

    self.assertIn("service_name", workflow)
    self.assertIn("Sales Tax Compliance", workflow)
    self.assertIn("sales_tax", workflow)
    self.assertIn("profit_service_recognition_rules", workflow)
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py tests/test_revenue_classification.py -q
```

Expected: fail because the workflows currently do not carry `invoice_note` and `service_name`.

- [ ] **Step 3: Update invoice sync mapping**

In `n8n/workflows/profit-07-anchor-invoices-sync.json`, update the invoice mapper so `invoiceRows` includes:

```javascript
invoice_note:
  invoice.note ??
  invoice.notes ??
  invoice.memo ??
  invoice.description ??
  invoice.message ??
  null,
```

Update `flattenLineItems` so each line item includes a stable service name:

```javascript
service_name:
  lineItem.name ??
  lineItem.serviceName ??
  lineItem.service?.name ??
  lineItem.origin?.serviceBundle?.name ??
  lineItem.integrations?.quickbooks?.item?.name ??
  null,
```

Keep `qbo_product_name` unchanged; it remains useful for the QBO product drift work.

Ensure the Supabase upsert payload includes `invoice_note` in `profit_anchor_invoices` and `service_name` in `profit_anchor_invoice_line_items` only after migration 016 adds the columns.

- [ ] **Step 4: Update line item classifier**

In `n8n/workflows/profit-11-classify-anchor-invoice-line-items.json`, carry `service_name` through the classified rows:

```javascript
const serviceName =
  row.service_name ??
  row.name ??
  row.qbo_product_name ??
  null;
```

Replace the hard-coded `exactProductToMacro` as the primary classifier with an inline rule map that mirrors migration 016 for V0.5.2. Keep `prefixToMacro` only as a fallback and add a tech-debt note in docs later.

The classified row should include:

```javascript
service_name: serviceName,
macro_service_type: macroServiceType,
classification_reason: classificationReason,
```

Pass-through services should emit:

```javascript
macro_service_type: 'pass_through',
include_in_revenue_allocation: false,
revenue_amount: 0,
classification_reason: 'service_recognition_rule_pass_through',
```

Unknown services should emit:

```javascript
macro_service_type: 'other',
include_in_revenue_allocation: false,
revenue_amount: 0,
classification_reason: 'needs_classification',
```

- [ ] **Step 5: Update revenue event loader**

In `n8n/workflows/profit-15-load-revenue-event-candidates.json`, add `service_name` to the revenue event rows inserted/upserted into `profit_revenue_events`:

```javascript
service_name: row.service_name ?? null,
```

Pass-through rows should not produce revenue events. If the current loader filters by `include_in_revenue_allocation`, keep that behavior and ensure `pass_through` rows are excluded.

- [ ] **Step 6: Run workflow tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py tests/test_revenue_classification.py -q
```

Expected: pass.

## Task 4: Tax Form-Type Matching SQL Coverage

**Files:**
- Modify `tests/test_recognition_triggers_sql.py`
- Create later: `supabase/sql/017_profit_tax_form_type_matching.sql`

- [ ] **Step 1: Write failing SQL coverage**

Add static SQL coverage:

```python
def test_tax_form_type_matching_migration_updates_ready_view(self) -> None:
    sql = Path("supabase/sql/017_profit_tax_form_type_matching.sql").read_text()

    self.assertIn("create or replace function profit_extract_tax_form_type", sql)
    self.assertIn("create or replace function profit_extract_anchor_invoice_note_scope", sql)
    self.assertIn("profit_tax_recognition_ambiguities", sql)
    self.assertIn("tax_filed", sql)
    self.assertIn("tax_extension_filed", sql)
    self.assertIn("form_type_pattern", sql)
    self.assertIn("invoice_note", sql)
    self.assertIn("TY:", sql)
    self.assertIn("FY:", sql)
    self.assertIn("Amended", sql)
    self.assertIn("service_period_month", sql)
    self.assertIn("candidate_period_month", sql)
```

Add behavior-shape coverage:

```python
def test_tax_matching_has_ambiguity_guard_instead_of_blind_oldest_match(self) -> None:
    sql = Path("supabase/sql/017_profit_tax_form_type_matching.sql").read_text().lower()

    self.assertIn("count(*) over", sql)
    self.assertIn("candidate_rank", sql)
    self.assertIn("ambiguous", sql)
    self.assertIn("where candidate_count = 1", sql)
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_recognition_triggers_sql.py -q
```

Expected: fail because migration 017 does not exist.

## Task 5: Implement Tax Matching Migration

**Files:**
- Create `supabase/sql/017_profit_tax_form_type_matching.sql`
- Test `tests/test_recognition_triggers_sql.py`

- [ ] **Step 1: Create form type helper**

Create `profit_extract_tax_form_type`:

```sql
create or replace function profit_extract_tax_form_type(input_text text)
returns text
language sql
immutable
as $$
  select case
    when input_text ~* '\m990[- ]?t\M' then '990-T'
    when input_text ~* '\m990[- ]?ez\M' then '990-EZ'
    when input_text ~* '\m1120s?\M' then '1120'
    when input_text ~* '\m1065\M' then '1065'
    when input_text ~* '\m1040\M' then '1040'
    when input_text ~* '\m990\M' then '990'
    else null
  end;
$$;
```

- [ ] **Step 2: Create invoice note scope helper**

Create `profit_extract_anchor_invoice_note_scope`:

```sql
create or replace function profit_extract_anchor_invoice_note_scope(input_text text)
returns table (
  tax_year text,
  fiscal_year_end text,
  is_amended boolean
)
language sql
stable
as $$
  select
    substring(input_text from '(?i)TY:(\d{4})') as tax_year,
    substring(input_text from '(?i)FY:(\d{4}-\d{2})') as fiscal_year_end,
    coalesce(input_text ~* 'Amended', false) as is_amended;
$$;
```

- [ ] **Step 3: Create ambiguity view**

Create `profit_tax_recognition_ambiguities` that lists tax triggers with multiple possible matches:

```sql
create or replace view profit_tax_recognition_ambiguities as
with tax_triggers as (
  select
    trigger.trigger_key,
    trigger.anchor_relationship_id,
    trigger.trigger_type,
    trigger.service_period_month,
    trigger.source_record_id,
    profit_extract_tax_form_type(
      coalesce(trigger.source_record_title, '') || ' ' || coalesce(trigger.macro_service_type, '')
    ) as trigger_form_type
  from profit_recognition_triggers trigger
  where trigger.trigger_type in ('tax_filed', 'tax_extension_filed')
),
tax_candidates as (
  select
    trigger.trigger_key,
    event.revenue_event_key,
    event.anchor_relationship_id,
    event.candidate_period_month,
    event.source_amount,
    event.service_name,
    rule.form_type_pattern,
    invoice.invoice_note,
    count(*) over (partition by trigger.trigger_key) as candidate_count
  from tax_triggers trigger
  join profit_revenue_events event
    on event.anchor_relationship_id = trigger.anchor_relationship_id
    and event.macro_service_type = 'tax'
    and event.recognition_status like 'pending_%'
    and event.recognition_period_month is null
    and coalesce(event.recognized_amount, 0) = 0
  left join profit_service_recognition_rules rule
    on rule.service_name = event.service_name
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
  where trigger.trigger_form_type is not null
    and coalesce(rule.form_type_pattern, profit_extract_tax_form_type(event.service_name)) = trigger.trigger_form_type
    and coalesce(invoice.invoice_note, '') !~* '(TY|FY):\d{4}(-\d{2})?'
)
select *
from tax_candidates
where candidate_count > 1;
```

Implementation may refine the note-scope logic, but the ambiguity view must exist and keep ambiguous matches out of the ready view.

- [ ] **Step 4: Replace ready view**

Replace `profit_revenue_events_ready_for_recognition` with a union of:

1. Existing non-tax trigger behavior, preserving manual override exact-key guard from V0.5.
2. Tax trigger behavior using form-type matching and ambiguity guard.

Tax candidate shape:

```sql
with tax_trigger_candidates as (
  select
    trigger.trigger_key,
    trigger.trigger_type,
    trigger.anchor_relationship_id,
    trigger.service_period_month,
    event.revenue_event_key,
    event.anchor_line_item_id,
    event.anchor_invoice_id,
    event.macro_service_type,
    event.source_amount,
    event.candidate_period_month,
    event.service_name,
    rule.form_type_pattern,
    invoice.invoice_note,
    row_number() over (
      partition by trigger.trigger_key
      order by event.candidate_period_month asc, event.created_at asc, event.revenue_event_key asc
    ) as candidate_rank,
    count(*) over (partition by trigger.trigger_key) as candidate_count
  from profit_recognition_triggers trigger
  join profit_revenue_events event
    on event.anchor_relationship_id = trigger.anchor_relationship_id
    and event.macro_service_type = 'tax'
  left join profit_service_recognition_rules rule
    on rule.service_name = event.service_name
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
  where trigger.trigger_type in ('tax_filed', 'tax_extension_filed')
    and event.recognition_status like 'pending_%'
    and event.recognition_period_month is null
    and coalesce(event.recognized_amount, 0) = 0
    and coalesce(rule.form_type_pattern, profit_extract_tax_form_type(event.service_name)) =
      profit_extract_tax_form_type(coalesce(trigger.source_record_title, '') || ' ' || coalesce(trigger.notes, ''))
)
select ...
from tax_trigger_candidates
where candidate_rank = 1
  and candidate_count = 1;
```

If existing trigger rows do not have `source_record_title` or `notes`, inspect `profit_recognition_triggers` during implementation and use the actual title/source fields. The migration must not assume `service_period_month` equality for tax triggers.

- [ ] **Step 5: Run focused SQL tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_recognition_triggers_sql.py -q
```

Expected: pass.

## Task 6: Behavioral Tests For Tax Matching

**Files:**
- Modify `tests/test_recognition_triggers_sql.py`
- Optionally create `tests/test_tax_recognition_matching.py` if the repo already has a SQL simulation pattern.

- [ ] **Step 1: Add deterministic fixture-style tests**

If existing tests are static-only, add static assertions for the exact business cases:

```python
def test_tax_matching_documents_form_type_cases(self) -> None:
    sql = Path("supabase/sql/017_profit_tax_form_type_matching.sql").read_text()

    self.assertIn("990-T", sql)
    self.assertIn("990-EZ", sql)
    self.assertIn("1120", sql)
    self.assertIn("1065", sql)
    self.assertIn("1040", sql)
```

If the project has a local Postgres test helper, add real data tests:

```python
def test_1120_trigger_does_not_match_1040_event(db) -> None:
    # Seed one relationship, one 1120 service event, one 1040 service event,
    # and one 1120 tax_filed trigger.
    # Assert ready view returns only the 1120 revenue_event_key.
    ...


def test_invoice_note_ty_2024_scopes_to_2024_event(db) -> None:
    # Seed two 1040 pending events for different tax years under the same client.
    # Add invoice_note = 'TY:2024' to the intended invoice.
    # Assert ready view returns the TY:2024 event and not the other event.
    ...


def test_multiple_same_form_without_note_is_ambiguous(db) -> None:
    # Seed two 1040 pending events under the same client with no note.
    # Assert ready view returns zero rows and ambiguity view returns both candidates.
    ...
```

- [ ] **Step 2: Run the matching tests red/green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_recognition_triggers_sql.py -q
```

Expected after implementation: pass.

## Task 7: SLA Default And Override Coverage

**Files:**
- Modify `tests/test_prepaid_liability_sql.py`
- Migration already in `supabase/sql/016_profit_service_recognition_rules.sql`

- [ ] **Step 1: Add SLA coverage**

Add:

```python
def test_service_rules_include_accounting_sla_defaults_and_override_column(self) -> None:
    sql = Path("supabase/sql/016_profit_service_recognition_rules.sql").read_text()

    self.assertIn("'Accounting Advanced', 'bookkeeping', 'Advanced', 'monthly_recurring', 'previous_month', 10", sql)
    self.assertIn("'Accounting Plus', 'bookkeeping', 'Plus', 'monthly_recurring', 'previous_month', 10", sql)
    self.assertIn("'Accounting Essential', 'bookkeeping', 'Essential', 'monthly_recurring', 'previous_month', 20", sql)
    self.assertIn("sla_day_override integer", sql)
```

- [ ] **Step 2: Run focused test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py -q
```

Expected: pass.

## Task 8: Data Contract And Tech Debt Docs

**Files:**
- Modify `docs/data-contracts/recognition-triggers.md`
- Modify `docs/tech-debt.md`
- Modify `docs/service-recognition-rules.md`
- Test `tests/test_profit_admin_frontend.py` is not required; use doc assertions in `tests/test_prepaid_liability_sql.py` only if the repo already has doc tests.

- [ ] **Step 1: Update recognition trigger data contract**

Append a V0.5.2 section to `docs/data-contracts/recognition-triggers.md`:

```markdown
## V0.5.2 Service-Aware Tax Recognition

Tax completion triggers (`tax_filed`, `tax_extension_filed`) do not require month equality between `profit_recognition_triggers.service_period_month` and `profit_revenue_events.candidate_period_month`.

For tax triggers, the recognition-ready view matches by:

1. `anchor_relationship_id`
2. `macro_service_type = tax`
3. tax form type parsed from FC trigger context (`1040`, `1065`, `1120`, `990`, `990-EZ`, `990-T`)
4. `profit_revenue_events.service_name` joined to `profit_service_recognition_rules.form_type_pattern`
5. invoice-note scope when `profit_anchor_invoices.invoice_note` contains `TY:YYYY`, `FY:YYYY-MM`, or `Amended`

If multiple same-form pending events remain possible and no invoice note disambiguates the target, the ready view does not expose an auto-recognition row. The candidates surface through `profit_tax_recognition_ambiguities` for V0.5.3 run-log review.

`profit_service_recognition_rules.source` and `last_synced_at` are forward-compatible sync metadata. V0.5.2 seeds this table from `docs/service-recognition-rules.md` with `source = manual_seed`; a future Anchor service sync should upsert the same table with `source = anchor_api_sync`.
```

- [ ] **Step 2: Add source-of-truth drift tech debt**

Append to `docs/tech-debt.md`:

```markdown
## Source-Of-Truth Drift Across Business Rule Domains

Three categories of business rules currently live as static data in our DB but originate upstream. Each should eventually be synced from its source instead of statically seeded:

- `profit_service_recognition_rules`: seeded from `docs/service-recognition-rules.md` in V0.5.2. Source of truth: Anchor service definitions. Future: scheduled workflow `Profit - 27 Anchor Service Sync` reads service definitions via Anchor API and upserts into this table. Schema is sync-ready through `source` and `last_synced_at`.
- QBO product to macro service classification: currently a hardcoded `prefixToMacro` / service map in the Anchor line item classifier. Source of truth: QBO product hierarchy. Future: sync QBO product categories and persist the mapping in a config table similar to V0.5.2's service-recognition pattern.
- FC tags to service identification: currently not captured. Source of truth: FC tag system on tasks/projects. Future: extend Workflow 17 to capture tag arrays per task/project and use them as a parallel signal to Anchor service name during recognition matching.

Address these in V0.6+ as the recognition pipeline matures. For V0.5.2, the static seed is acceptable because the schema design anticipates migration to upstream sync.
```

- [ ] **Step 3: Reconcile Audit Protection doctrine with V0.5.2 seed**

Update `docs/service-recognition-rules.md` so Audit Protection rows match V0.5.2 seed reality:

```markdown
| Audit Protection Business | other | $30 | previous month | no SLA | V0.5.2 seeds this as `other` + `manual_review` because the macro enum does not yet include `insurance_accrual`. Future direction: add an explicit insurance/accrual macro when this product is automated. |
| Audit Protection Individual | other | $5 | previous month | no SLA | V0.5.2 seeds this as `other` + `manual_review` because the macro enum does not yet include `insurance_accrual`. Future direction: add an explicit insurance/accrual macro when this product is automated. |
```

- [ ] **Step 4: Run docs-adjacent tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py tests/test_recognition_triggers_sql.py -q
```

Expected: pass.

## Task 9: Full Test Run

**Files:** no new files.

- [ ] **Step 1: Run full suite**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass. If failures are unrelated to V0.5.2 and caused by current uncommitted V0.5.1 work, stop and report before proceeding.

## Task 10: Deploy Checkpoint

**Files:**
- Apply migrations to live Supabase.
- Import updated n8n workflow JSON into the VPS n8n instance.

- [ ] **Step 1: Apply migrations in order**

Run on the VPS after uploading SQL files:

```bash
set -a; . /opt/agents/outscore_profit/.env; set +a
psql "$SUPABASE_DB_URL" -f /tmp/016_profit_service_recognition_rules.sql
psql "$SUPABASE_DB_URL" -f /tmp/017_profit_tax_form_type_matching.sql
```

Expected: both migrations apply cleanly. Re-running `016` should not change row count unexpectedly.

- [ ] **Step 2: Confirm config table counts**

Run:

```sql
select macro_service_type, count(*)
from profit_service_recognition_rules
group by 1
order by 1;
```

Expected categories include `bookkeeping`, `tax`, `sales_tax`, `payroll`, `advisory`, `pass_through`, and `other`.

- [ ] **Step 3: Confirm seed idempotency**

Run migration `016` a second time, then:

```sql
select count(*) from profit_service_recognition_rules;
```

Expected: same count as before rerun.

- [ ] **Step 4: Import workflow updates**

Upload and import:

```bash
docker cp /tmp/profit-07-anchor-invoices-sync.json n8n-n8n-1:/tmp/profit-07-anchor-invoices-sync.json
docker cp /tmp/profit-11-classify-anchor-invoice-line-items.json n8n-n8n-1:/tmp/profit-11-classify-anchor-invoice-line-items.json
docker cp /tmp/profit-15-load-revenue-event-candidates.json n8n-n8n-1:/tmp/profit-15-load-revenue-event-candidates.json
docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/profit-07-anchor-invoices-sync.json --projectId=J4Lnhwk17jCXd7gS
docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/profit-11-classify-anchor-invoice-line-items.json --projectId=J4Lnhwk17jCXd7gS
docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/profit-15-load-revenue-event-candidates.json --projectId=J4Lnhwk17jCXd7gS
```

- [ ] **Step 5: Stop for live spot-check**

Report:
- migration apply status
- `profit_service_recognition_rules` count by macro
- whether `invoice_note` exists on `profit_anchor_invoices`
- whether `service_name` exists on `profit_revenue_events`
- whether `profit_tax_recognition_ambiguities` exists

Stop here for Orlando review before any commit.

## Task 11: Commit After Spot-Check Approval

**Files:** all V0.5.2 files.

- [ ] **Step 1: Re-run full tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Review git diff**

Run:

```bash
git status --short
git diff -- docs/superpowers/plans/2026-05-03-profit-dashboard-v0.5.2-service-aware-recognition-foundation.md supabase/sql/016_profit_service_recognition_rules.sql supabase/sql/017_profit_tax_form_type_matching.sql docs/data-contracts/recognition-triggers.md docs/tech-debt.md
```

Expected: only intentional V0.5.2 changes plus any already-approved V0.5.1 work if Orlando has explicitly approved including it.

- [ ] **Step 3: Commit**

Use:

```bash
git add supabase/sql/016_profit_service_recognition_rules.sql supabase/sql/017_profit_tax_form_type_matching.sql n8n/workflows/profit-07-anchor-invoices-sync.json n8n/workflows/profit-11-classify-anchor-invoice-line-items.json n8n/workflows/profit-15-load-revenue-event-candidates.json tests/test_prepaid_liability_sql.py tests/test_recognition_triggers_sql.py tests/test_n8n_workflows.py tests/test_revenue_classification.py docs/data-contracts/recognition-triggers.md docs/tech-debt.md docs/superpowers/plans/2026-05-03-profit-dashboard-v0.5.2-service-aware-recognition-foundation.md
git commit -m "Add service-aware recognition foundation (V0.5.2)" -m "Seed sync-ready Anchor service recognition rules, capture service names and invoice notes from Anchor, and add tax form-type matching with ambiguity safeguards. The config table is static for V0.5.2 but includes source and last_synced_at for future Anchor API sync."
```

- [ ] **Step 4: Push**

Run:

```bash
git push
```

Expected: branch pushed cleanly.

## Stop Checkpoints

1. After this plan doc is written: stop for Orlando review.
2. After migrations/workflows are deployed and smoke-tested: stop for Orlando spot-check.
3. After spot-check approval: run tests, commit, push.
