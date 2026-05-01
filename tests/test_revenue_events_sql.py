from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class RevenueEventsSqlTests(unittest.TestCase):
    def test_revenue_events_migration_defines_candidate_table_and_gp_views(self) -> None:
        sql_path = ROOT / "supabase/sql/004_profit_revenue_events.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_revenue_events", sql)
        self.assertIn("revenue_event_key text primary key", sql)
        self.assertIn("recognition_status text not null", sql)
        self.assertIn("recognized_amount numeric not null default 0", sql)
        self.assertIn("anchor_line_item_id text", sql)
        self.assertIn("recognition_rule text not null", sql)
        self.assertIn("trigger_source text", sql)
        self.assertIn("create or replace view profit_client_service_monthly_gp_recognition_basis", sql)
        self.assertIn("create or replace view profit_company_monthly_gp_recognition_basis", sql)
        self.assertIn("profit_time_entries", sql)
        self.assertIn("profit_client_service_owners", sql)


if __name__ == "__main__":
    unittest.main()
