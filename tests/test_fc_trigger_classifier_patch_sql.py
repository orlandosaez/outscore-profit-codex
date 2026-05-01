from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FcTriggerClassifierPatchSqlTests(unittest.TestCase):
    def test_classifier_patch_refreshes_completed_task_review_only(self) -> None:
        sql_path = ROOT / "supabase/sql/007a_profit_fc_completed_task_review_classifier_only.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create or replace view profit_fc_completed_task_review", sql)
        self.assertNotIn("create or replace view profit_fc_completion_trigger_candidates", sql)
        self.assertNotIn("create or replace view profit_fc_completion_triggers_ready_to_load", sql)

    def test_classifier_patch_includes_latest_tax_and_payroll_rules(self) -> None:
        sql_path = ROOT / "supabase/sql/007a_profit_fc_completed_task_review_classifier_only.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("file the tax return", sql)
        self.assertIn("then 'tax_filed'", sql)
        self.assertIn("not ilike '%provision%'", sql)
        self.assertIn("not ilike '%onboard%'", sql)
        self.assertIn("not ilike '%setup%'", sql)


if __name__ == "__main__":
    unittest.main()
