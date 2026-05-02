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

    def test_prepaid_liability_drawdown_is_capped_by_allocated_cash(self) -> None:
        sql_path = ROOT / "supabase/sql/010_profit_prepaid_liability.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("least(", sql)
        self.assertIn("event.recognized_amount", sql)
        self.assertIn("total_allocated_amount", sql)


if __name__ == "__main__":
    unittest.main()
