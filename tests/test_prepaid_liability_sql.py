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


if __name__ == "__main__":
    unittest.main()
