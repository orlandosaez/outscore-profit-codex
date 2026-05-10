import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/sql/028_profit_sla_core_views.sql"


class SlaDashboardCoreSqlTests(unittest.TestCase):
    def test_sla_core_migration_exists(self) -> None:
        self.assertTrue(MIGRATION.exists())

    def test_sla_core_views_are_defined(self) -> None:
        sql = MIGRATION.read_text().lower()

        for view_name in (
            "profit_sla_project_statuses",
            "profit_sla_service_items",
            "profit_sla_client_status",
            "profit_sla_staff_workload",
            "profit_sla_breach_queue",
        ):
            self.assertIn(f"create or replace view {view_name}", sql)

    def test_sla_state_contract_is_locked(self) -> None:
        sql = MIGRATION.read_text()

        for state in (
            "'on_track'",
            "'at_risk'",
            "'breached'",
            "'waiting_on_client'",
            "'not_applicable'",
        ):
            self.assertIn(state, sql)

        self.assertIn("greatest(target_sla_day - 2, ceil(target_sla_day * 0.8))", sql)
        self.assertIn("waiting on client", sql.lower())

    def test_workflow_status_tag_constraint_and_backfill_are_present(self) -> None:
        sql = MIGRATION.read_text().lower()

        self.assertIn("alter table profit_fc_project_tags", sql)
        self.assertIn("add constraint", sql)
        self.assertIn("workflow_status", sql)
        self.assertIn("insert into profit_fc_project_tags", sql)
        self.assertIn("'workflow_status'", sql)
        self.assertIn("on conflict", sql)

    def test_sla_comments_document_override_and_staff_fallback(self) -> None:
        sql = MIGRATION.read_text().lower()

        self.assertIn("sla_day_override", sql)
        self.assertIn("takes precedence", sql)
        self.assertIn("task assignee first", sql)
        self.assertIn("client staff tags", sql)

    def test_sla_migration_defines_no_functions(self) -> None:
        sql = MIGRATION.read_text().lower()

        self.assertNotIn("create function", sql)
