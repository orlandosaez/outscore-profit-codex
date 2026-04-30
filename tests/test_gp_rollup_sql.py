from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class GpRollupSqlTests(unittest.TestCase):
    def test_gp_rollup_migration_defines_invoice_basis_views(self) -> None:
        sql_path = ROOT / "supabase/sql/003_profit_gp_invoice_basis_views.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create or replace view profit_client_service_monthly_gp_invoice_basis", sql)
        self.assertIn("create or replace view profit_company_monthly_gp_invoice_basis", sql)
        self.assertIn("profit_anchor_line_item_classifications", sql)
        self.assertIn("profit_time_entries", sql)
        self.assertIn("profit_client_service_owners", sql)
        self.assertIn("invoice_revenue_amount", sql)
        self.assertIn("matched_labor_cost", sql)
        self.assertIn("admin_load_pct", sql)
        self.assertIn("nullif", sql)


if __name__ == "__main__":
    unittest.main()
