from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AdminDashboardSqlTests(unittest.TestCase):
    def test_admin_dashboard_migration_defines_dashboard_views(self) -> None:
        sql_path = ROOT / "supabase/sql/009_profit_admin_dashboard_views.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create or replace view profit_admin_company_dashboard_summary", sql)
        self.assertIn("create or replace view profit_admin_client_gp_dashboard", sql)
        self.assertIn("create or replace view profit_admin_staff_gp_dashboard", sql)
        self.assertIn("create or replace view profit_admin_comp_kicker_ledger", sql)
        self.assertIn("create or replace view profit_admin_w2_candidates", sql)
        self.assertIn("create or replace view profit_admin_fc_trigger_queue", sql)

    def test_admin_dashboard_views_use_recognition_basis_and_comp_views(self) -> None:
        sql_path = ROOT / "supabase/sql/009_profit_admin_dashboard_views.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("profit_company_monthly_gp_recognition_basis", sql)
        self.assertIn("profit_client_service_monthly_gp_recognition_basis", sql)
        self.assertIn("profit_company_quarterly_gp_gate", sql)
        self.assertIn("profit_staff_monthly_kicker_accruals", sql)
        self.assertIn("profit_staff_monthly_w2_conversion_flags", sql)
        self.assertIn("profit_fc_completion_trigger_candidates", sql)
        self.assertIn("pending_revenue_amount", sql)
        self.assertIn("recognized_revenue_amount", sql)
        self.assertIn("admin_load_pct", sql)


if __name__ == "__main__":
    unittest.main()
