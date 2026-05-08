from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_024A = ROOT / "supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql"
SQL_025 = ROOT / "supabase/sql/025_profit_fulfillment_audit_views.sql"
SQL_025B = ROOT / "supabase/sql/025b_profit_audit_helpers.sql"
SQL_025C = ROOT / "supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql"
SQL_025D = ROOT / "supabase/sql/025d_profit_apply_classification_transitions.sql"


class FulfillmentAuditQuerySqlTests(unittest.TestCase):
    def test_024a_match_candidates_rank_active_over_terminated_and_stale(self) -> None:
        sql = SQL_024A.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_fc_client_anchor_match_candidates", lower)
        self.assertIn("when agreement.display_status = 'active' then 1", lower)
        self.assertIn("when agreement.display_status = 'terminated' then 2", lower)
        self.assertIn("when agreement.display_status = 'stale' then 3", lower)
        self.assertIn("active_anchor_count = 1", lower)
        self.assertIn("active_anchor_count > 1", lower)
        self.assertIn("terminated-only", lower)
        self.assertIn("stale-only", lower)
        self.assertIn("E & O Automotive LLC", sql)
        self.assertIn("1415 Cortez Rd LLC", sql)
        self.assertIn("6712 Manatee Ave LLC", sql)
        self.assertIn("Kar Kraft Auto Repair LLC (TempleTerrace)", sql)
        self.assertIn("Kar Kraft Services LLC (Zephyrhills)", sql)
        self.assertIn("YV Enterprises HB LLC", sql)
        self.assertIn("YV Enterprises PSL LLC", sql)

    def test_025b_defines_fc_inactive_signals_with_closure_grace(self) -> None:
        sql = SQL_025B.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_audit_fc_inactive_signals", lower)
        self.assertIn("fc_is_archived", lower)
        self.assertIn("fc_archived_at", lower)
        self.assertIn("fc_unarchived_after_archive", lower)
        self.assertIn("has_post_archive_service_delivery", lower)
        self.assertIn("archived_at_missing_for_archived_client", lower)
        self.assertIn("interval '1 day'", lower)
        self.assertIn("closure-batch task completions", lower)
        self.assertIn("Joy Property Management LLC", sql)

    def test_025b_defines_qbo_leaf_function_and_open_invoice_helper(self) -> None:
        sql = SQL_025B.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_qbo_product_leaf_name", lower)
        self.assertIn("returns text", lower)
        self.assertIn("immutable", lower)
        self.assertIn("Tax Work:1120 Plus", sql)
        self.assertIn("1120 Plus", sql)
        self.assertIn("A:B:C", sql)
        self.assertIn("Tax Work:", sql)
        self.assertIn("create or replace view profit_audit_open_invoice_balance_per_client", lower)
        self.assertIn("open_invoice_balance_amount", lower)
        self.assertIn("open_invoice_count", lower)
        self.assertIn("last_signal_at", lower)
        self.assertIn("voidSynced", sql)
        self.assertIn("not in ('voided', 'cancelled', 'void')", lower)
        self.assertIn("distinct on (client.fc_client_id)", lower)
        self.assertIn("Celtic Auto Werks Inc", sql)
        self.assertIn("YV Enterprises SR LLC", sql)
        self.assertIn("Collectiv Inc", sql)

    def test_025_defines_layered_audit_views_and_diagnostics(self) -> None:
        sql = SQL_025.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_fulfillment_audit_fc_activity", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_anchor_signals", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_group_signals", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_candidates", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_qbo_category_gaps", lower)
        self.assertIn("any_active_signal", lower)
        self.assertIn("default_visibility", lower)
        self.assertIn("coalesce(verdict.default_visibility, 'show')", lower)
        self.assertIn("distinct on (client.fc_client_id)", lower)
        self.assertIn("profit_qbo_product_leaf_name", lower)
        self.assertIn("qbo_product_match_status", lower)
        self.assertIn("missing_qbo_product", lower)
        self.assertIn("missing_qbo_category", lower)
        self.assertIn("canonical_service_name_unresolved", lower)
        self.assertIn("sample_revenue_event_keys", lower)
        self.assertIn("sample_invoice_numbers", lower)
        self.assertIn("limit 5", lower)
        self.assertIn("Joy Property Management LLC", sql)
        self.assertIn("Hornauer", sql)
        self.assertIn("Inatsuka", sql)


if __name__ == "__main__":
    unittest.main()
