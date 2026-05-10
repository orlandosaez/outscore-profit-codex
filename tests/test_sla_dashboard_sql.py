import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/sql/028_profit_sla_core_views.sql"
BACKFILL_MIGRATION = (
    ROOT / "supabase/sql/028a_profit_sla_backfill_and_performance_views.sql"
)


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


class SlaDashboardBackfillSqlTests(unittest.TestCase):
    def test_sla_backfill_migration_exists(self) -> None:
        self.assertTrue(BACKFILL_MIGRATION.exists())

    def test_staff_service_performance_view_is_fixed_90_days(self) -> None:
        sql = BACKFILL_MIGRATION.read_text().lower()

        self.assertIn(
            "create or replace view profit_sla_staff_service_performance_90d",
            sql,
        )
        self.assertIn("interval '90 days'", sql)
        self.assertIn("fixed 90-day", sql)
        self.assertIn("staff fallback", sql)

    def test_backfill_migration_defines_views_only(self) -> None:
        sql = BACKFILL_MIGRATION.read_text().lower()

        self.assertNotIn("create function", sql)
        self.assertNotIn("create or replace function", sql)

    def test_anchor_backfill_queue_view_contract(self) -> None:
        sql = BACKFILL_MIGRATION.read_text()
        lower_sql = sql.lower()

        self.assertIn(
            "create or replace view profit_sla_anchor_backfill_queue",
            lower_sql,
        )
        self.assertIn("'SETTLED_VIA_QUICKBOOKS_PAYMENT'", sql)
        self.assertIn("profit_cash_collections", lower_sql)
        self.assertIn("qbo_payment_id", lower_sql)
        self.assertIn("collected_at", lower_sql)
        self.assertIn("collected_amount", lower_sql)
        self.assertIn("profit_client_groups", lower_sql)
        self.assertIn("auto_transition_eligible", lower_sql)
        self.assertIn("read-only backfill", lower_sql)
