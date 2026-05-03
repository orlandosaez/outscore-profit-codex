from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PrepaidLiabilitySqlTests(unittest.TestCase):
    def test_prepaid_liability_migration_uses_cash_collections_not_invoices(self) -> None:
        sql_path = ROOT / "supabase/sql/010_profit_prepaid_liability.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_cash_collections", sql)
        self.assertIn("source_payment_id text not null", sql)
        self.assertIn("collected_at date not null", sql)
        self.assertIn("collected_amount numeric not null", sql)
        self.assertIn("create table if not exists profit_collection_revenue_allocations", sql)
        self.assertIn("references profit_cash_collections", sql)
        self.assertIn("references profit_revenue_events", sql)
        self.assertIn("allocated_amount numeric not null", sql)
        self.assertIn("create or replace view profit_prepaid_liability_ledger", sql)
        self.assertIn("'cash_collected'::text as ledger_entry_type", sql)
        self.assertIn("'revenue_recognized'::text as ledger_entry_type", sql)
        self.assertIn("create or replace view profit_prepaid_liability_balances", sql)
        self.assertIn("create or replace view profit_prepaid_liability_summary", sql)
        self.assertIn("collection_count", sql)
        self.assertIn("from profit_cash_collections", sql)
        self.assertIn("unique (source_system, source_payment_id)", sql)
        self.assertIn("create or replace view profit_unallocated_cash_collections", sql)

    def test_prepaid_liability_drawdown_is_capped_by_allocated_cash(self) -> None:
        sql_path = ROOT / "supabase/sql/010_profit_prepaid_liability.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("least(", sql)
        self.assertIn("event.recognized_amount", sql)
        self.assertIn("total_allocated_amount", sql)
        self.assertIn("create or replace function profit_validate_collection_revenue_allocation()", sql)
        self.assertIn("create or replace trigger trg_profit_validate_collection_revenue_allocation", sql)
        self.assertIn("allocated amount exceeds collected cash", sql)
        self.assertIn("allocated amount exceeds revenue event source amount", sql)

    def test_prepaid_liability_ledger_logs_rounding_delta(self) -> None:
        sql_path = ROOT / "supabase/sql/010_profit_prepaid_liability.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("rounding_delta numeric not null default 0", sql)
        self.assertIn("sum(ledger.rounding_delta)", sql)
        self.assertIn("rounding_delta", sql)

    def test_prepaid_liability_views_split_tax_deferred_from_trigger_backlog(self) -> None:
        sql_path = ROOT / "supabase/sql/010_profit_prepaid_liability.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("service_category", sql)
        self.assertIn("'tax_deferred_revenue'::text", sql)
        self.assertIn("'pending_recognition_trigger'::text", sql)
        self.assertIn("'recognized'::text", sql)
        self.assertIn("tax_deferred_revenue_balance", sql)
        self.assertIn("trigger_backlog_balance", sql)
        self.assertIn("total_prepaid_liability_balance", sql)
        self.assertIn("trigger_backlog_note", sql)
        self.assertIn("delivered services with no recognition trigger loaded", sql)
        self.assertNotIn("pending_trigger_balance", sql)

    def test_prepaid_liability_sql_does_not_reference_missing_revenue_event_period_column(self) -> None:
        sql_files = sorted((ROOT / "supabase/sql").glob("*.sql"))
        offenders: list[str] = []
        for sql_path in sql_files:
            sql = sql_path.read_text(encoding="utf-8").lower()
            if "profit_revenue_events.service_period_month" in sql:
                offenders.append(str(sql_path.relative_to(ROOT)))
            if "event.service_period_month" in sql:
                offenders.append(str(sql_path.relative_to(ROOT)))

        self.assertEqual(offenders, [])

    def test_manual_recognition_migration_defines_reason_codes_and_views(self) -> None:
        sql_path = ROOT / "supabase/sql/013_profit_manual_recognition_override.sql"
        sql = sql_path.read_text(encoding="utf-8")

        for reason_code in [
            "backbill_pre_engagement",
            "client_operational_change",
            "entity_restructure",
            "service_outside_fc_scope",
            "fc_classifier_gap",
            "voided_invoice_replacement",
            "billing_amount_adjustment",
            "other",
        ]:
            self.assertIn(reason_code, sql)

        self.assertIn("manual_override_reason_code", sql)
        self.assertIn("manual_override_notes", sql)
        self.assertIn("manual_override_reference", sql)
        self.assertIn("approved_by", sql)
        self.assertIn("approved_at", sql)
        self.assertIn("manual_recognition_approved", sql)
        self.assertIn("recognized_by_manual_override", sql)
        self.assertIn("profit_manual_recognition_pending_events", sql)
        self.assertIn("profit_manual_recognition_override_audit", sql)
        self.assertIn("recognition_status like 'pending_%'", sql.lower())
        self.assertIn("trigger.source_record_id = event.revenue_event_key", sql)

    def test_consolidated_billing_migration_extends_pending_view(self) -> None:
        sql_path = ROOT / "supabase/sql/014_profit_manual_recognition_consolidated_billing.sql"
        sql = sql_path.read_text(encoding="utf-8")

        self.assertIn("sibling_event_count", sql)
        self.assertIn("profit_manual_recognition_pending_events", sql)

    def test_manual_recognition_batch_migration_adds_batch_id(self) -> None:
        sql_path = ROOT / "supabase/sql/015_profit_manual_recognition_batch.sql"
        sql = sql_path.read_text(encoding="utf-8")

        self.assertIn("manual_override_batch_id", sql)
        self.assertIn("alter table profit_recognition_triggers", sql.lower())
        self.assertIn("idx_profit_recognition_triggers_batch_id", sql)
        self.assertIn("where manual_override_batch_id is not null", sql.lower())

    def test_service_recognition_rules_migration_defines_sync_ready_config(self) -> None:
        sql_path = ROOT / "supabase/sql/016_profit_service_recognition_rules.sql"
        sql = sql_path.read_text(encoding="utf-8")

        self.assertIn("create table if not exists profit_service_recognition_rules", sql)
        self.assertIn("service_name text primary key", sql)
        self.assertIn(
            "macro_service_type in ('bookkeeping', 'tax', 'payroll', 'sales_tax', 'advisory', 'pass_through', 'other')",
            sql,
        )
        self.assertIn(
            "recognition_pattern in ('monthly_recurring', 'quarterly_recurring', 'tax_filing', 'one_time', 'pass_through', 'manual_review')",
            sql,
        )
        self.assertIn(
            "service_period_rule in ('previous_month', 'previous_quarter', 'tax_year_default', 'invoice_date', 'manual')",
            sql,
        )
        self.assertIn("source text not null default 'manual_seed'", sql)
        self.assertIn("last_synced_at timestamptz not null default now()", sql)
        self.assertIn("sla_day_override integer", sql)
        self.assertIn("service_name text", sql)
        self.assertIn("invoice_note text", sql)
        self.assertIn("on conflict (service_name) do update set", sql.lower())

    def test_service_recognition_rules_seed_covers_doctrine_services(self) -> None:
        sql_path = ROOT / "supabase/sql/016_profit_service_recognition_rules.sql"
        sql = sql_path.read_text(encoding="utf-8")

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

    def test_service_rules_include_accounting_sla_defaults_and_override_column(self) -> None:
        sql_path = ROOT / "supabase/sql/016_profit_service_recognition_rules.sql"
        sql = sql_path.read_text(encoding="utf-8")

        self.assertIn("'Accounting Advanced', 'bookkeeping', 'Advanced', 'monthly_recurring', 'previous_month', 10", sql)
        self.assertIn("'Accounting Plus', 'bookkeeping', 'Plus', 'monthly_recurring', 'previous_month', 10", sql)
        self.assertIn("'Accounting Essential', 'bookkeeping', 'Essential', 'monthly_recurring', 'previous_month', 20", sql)
        self.assertIn("sla_day_override integer", sql)

    def test_service_recognition_crosswalk_migration_adds_columns_and_seed_updates(self) -> None:
        sql = (ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql").read_text(
            encoding="utf-8"
        )

        self.assertIn("alter table profit_service_recognition_rules", sql.lower())
        self.assertIn("add column if not exists fc_tag text", sql.lower())
        self.assertIn("add column if not exists qbo_category_path text", sql.lower())
        self.assertIn("add column if not exists qbo_product_name text", sql.lower())
        self.assertIn("on conflict (service_name) do update set", sql.lower())
        self.assertIn("macro_service_type", sql)
        self.assertIn("recognition_pattern", sql)
        self.assertIn("service_period_rule", sql)
        self.assertIn("fc_tag = excluded.fc_tag", sql)
        self.assertIn("qbo_category_path = excluded.qbo_category_path", sql)
        self.assertIn("qbo_product_name = excluded.qbo_product_name", sql)

    def test_service_recognition_crosswalk_seed_covers_fc_tags_and_qbo_matches(self) -> None:
        sql = (ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql").read_text(
            encoding="utf-8"
        )

        self.assertIn("'Accounting Advanced',", sql)
        self.assertIn("'S BOOKA'", sql)
        self.assertIn("'1040 Advanced', 'tax', 'Advanced', 'tax_filing', 'tax_year_default'", sql)
        self.assertIn("'1040 Advanced', 'tax', 'Advanced', 'tax_filing', 'tax_year_default', null, '1040', 'Tier is complexity, not timing.', 'S 1040A'", sql)
        self.assertIn("'Billable Expenses', 'pass_through', null, 'pass_through', 'manual', null, null, 'Exclude from service revenue recognition.', 'S BILL'", sql)
        self.assertIn("'Remote Desktop Access', 'pass_through', null, 'pass_through', 'manual', null, null, 'Client reimbursement/access cost recovery.', 'S BILL'", sql)
        self.assertIn("'Remote QBD Access', 'pass_through', null, 'pass_through', 'manual', null, null, 'Client reimbursement/access cost recovery.', 'S BILL'", sql)
        self.assertIn("'Other Income', 'pass_through', null, 'pass_through', 'manual', null, null, 'Exclude from service recognition unless separately reviewed.', null", sql)
        self.assertIn("'Services', 'pass_through', null, 'pass_through', 'manual', null, null, 'Generic product excluded by default; explicit classification required.', null", sql)
        self.assertIn("'Specialized Services', 'advisory', null, 'manual_review', 'manual', null, null, 'Default $0/varies; review before automated recognition.', null", sql)
        self.assertIn("'1040 Advanced', 'tax', 'Advanced', 'tax_filing', 'tax_year_default', null, '1040', 'Tier is complexity, not timing.', 'S 1040A', 'Tax Work', '1040 Advanced'", sql)
        self.assertIn("'Accounting Plus', 'bookkeeping', 'Plus', 'monthly_recurring', 'previous_month', 10, null, 'Recognize from FC bookkeeping completion for prior month.', 'S BOOKP', 'Accounting', 'Accounting Plus'", sql)
        self.assertNotIn("S ACCA", sql)
        self.assertNotIn("S ACCP", sql)

    def test_service_recognition_crosswalk_warning_view_exists(self) -> None:
        sql = (ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql").read_text(
            encoding="utf-8"
        )

        self.assertIn("create or replace view profit_anchor_services_without_tag", sql.lower())
        self.assertIn("profit_service_recognition_rules", sql)
        self.assertIn("fc_tag is null", sql.lower())


if __name__ == "__main__":
    unittest.main()
