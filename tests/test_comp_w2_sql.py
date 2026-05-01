from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CompW2SqlTests(unittest.TestCase):
    def test_comp_w2_migration_defines_config_comp_and_w2_views(self) -> None:
        sql_path = ROOT / "supabase/sql/008_profit_comp_w2.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_comp_plan_config", sql)
        self.assertIn("'floor_gp_pct'", sql)
        self.assertIn("'0.35'", sql)
        self.assertIn("'kicker_rate'", sql)
        self.assertIn("'0.20'", sql)
        self.assertIn("'company_gate_gp_pct'", sql)
        self.assertIn("'0.50'", sql)
        self.assertIn("'quarterly_target_step_pct'", sql)
        self.assertIn("'0.03'", sql)
        self.assertIn("'company_gp_target_cap_pct'", sql)
        self.assertIn("'0.65'", sql)
        self.assertIn("create or replace view profit_company_quarterly_gp_gate", sql)
        self.assertIn("create or replace view profit_staff_monthly_kicker_candidates", sql)
        self.assertIn("create or replace view profit_staff_monthly_kicker_accruals", sql)
        self.assertIn("create or replace view profit_staff_monthly_w2_conversion_flags", sql)

    def test_comp_views_use_recognition_basis_hard_gate_and_primary_owner(self) -> None:
        sql_path = ROOT / "supabase/sql/008_profit_comp_w2.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("profit_client_service_monthly_gp_recognition_basis", sql)
        self.assertIn("profit_company_monthly_gp_recognition_basis", sql)
        self.assertIn("primary_owner_staff_name", sql)
        self.assertIn("greatest(0", sql)
        self.assertIn("recognized_revenue_amount", sql)
        self.assertIn("gate_passed", sql)
        self.assertIn("case when coalesce(gate.gate_passed, false)", sql)
        self.assertIn("prior_company_gate_quarter", sql)

    def test_w2_flags_require_cost_and_consistency_triggers(self) -> None:
        sql_path = ROOT / "supabase/sql/008_profit_comp_w2.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("annualized_contractor_cost", sql)
        self.assertIn("55000", sql)
        self.assertIn("high_hour_month_count_8m >= 6", sql)
        self.assertIn("avg_weekly_hours >= 25", sql)
        self.assertIn("coalesce(scored.hours_cv_8m, 0) < 0.30", sql)
        self.assertIn("then 'convert'", sql)
        self.assertIn("then 'watch'", sql)


if __name__ == "__main__":
    unittest.main()
