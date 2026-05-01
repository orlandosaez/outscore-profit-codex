from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FinancialCentsSqlTests(unittest.TestCase):
    def test_financial_cents_migration_defines_raw_sync_tables(self) -> None:
        sql_path = ROOT / "supabase/sql/006_profit_financial_cents_sync.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_fc_clients", sql)
        self.assertIn("fc_client_id bigint primary key", sql)
        self.assertIn("create table if not exists profit_fc_projects", sql)
        self.assertIn("fc_project_id bigint primary key", sql)
        self.assertIn("create table if not exists profit_fc_tasks", sql)
        self.assertIn("fc_task_id bigint primary key", sql)
        self.assertIn("profit_fc_client_anchor_matches", sql)
        self.assertIn("anchor_relationship_id text", sql)
        self.assertIn("create or replace view profit_fc_completed_task_review", sql)
        self.assertIn("completed_at", sql)
        self.assertIn("is_completed", sql)

    def test_financial_cents_trigger_loader_requires_review_approval(self) -> None:
        sql_path = ROOT / "supabase/sql/007_profit_fc_trigger_loader.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_fc_task_trigger_approvals", sql)
        self.assertIn("approval_status text not null default 'pending'", sql)
        self.assertIn("create or replace view profit_fc_client_anchor_match_candidates", sql)
        self.assertIn("create or replace view profit_fc_completion_trigger_candidates", sql)
        self.assertIn("create or replace view profit_fc_completion_triggers_ready_to_load", sql)
        self.assertIn("approval_status = 'approved'", sql)
        self.assertIn("suggested_trigger_type <> 'manual_review'", sql)
        self.assertIn("anchor_relationship_id is not null", sql)
        self.assertIn("macro_service_type is not null", sql)
        self.assertIn("provision", sql)
        self.assertIn("not ilike '%provision%'", sql)
        self.assertIn("file the tax return", sql)


if __name__ == "__main__":
    unittest.main()
