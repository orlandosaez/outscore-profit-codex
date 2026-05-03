from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class RecognitionTriggersSqlTests(unittest.TestCase):
    def test_recognition_trigger_migration_defines_trigger_table_and_ready_view(self) -> None:
        sql_path = ROOT / "supabase/sql/005_profit_recognition_triggers.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_recognition_triggers", sql)
        self.assertIn("recognition_trigger_key text primary key", sql)
        self.assertIn("source_system text not null", sql)
        self.assertIn("source_record_id text not null", sql)
        self.assertIn("anchor_relationship_id text not null", sql)
        self.assertIn("macro_service_type text not null", sql)
        self.assertIn("service_period_month date", sql)
        self.assertIn("completion_date date not null", sql)
        self.assertIn("trigger_type text not null", sql)
        self.assertIn("create or replace view profit_revenue_events_ready_for_recognition", sql)
        self.assertIn("profit_revenue_events event", sql)
        self.assertIn("profit_recognition_triggers trigger", sql)
        self.assertIn("recognized_amount_to_apply", sql)
        self.assertIn("next_recognition_status", sql)

    def test_tax_form_type_matching_migration_updates_ready_view(self) -> None:
        sql_path = ROOT / "supabase/sql/017_profit_tax_form_type_matching.sql"
        sql = sql_path.read_text(encoding="utf-8")

        self.assertIn("create or replace function profit_extract_tax_form_type", sql)
        self.assertIn("create or replace function profit_extract_anchor_invoice_note_scope", sql)
        self.assertIn("profit_tax_recognition_ambiguities", sql)
        self.assertIn("tax_filed", sql)
        self.assertIn("tax_extension_filed", sql)
        self.assertIn("form_type_pattern", sql)
        self.assertIn("invoice_note", sql)
        self.assertIn("TY:", sql)
        self.assertIn("FY:", sql)
        self.assertIn("Amended", sql)
        self.assertIn("service_period_month", sql)
        self.assertIn("candidate_period_month", sql)

    def test_tax_matching_has_ambiguity_guard_instead_of_blind_oldest_match(self) -> None:
        sql_path = ROOT / "supabase/sql/017_profit_tax_form_type_matching.sql"
        sql = sql_path.read_text(encoding="utf-8").lower()

        self.assertIn("count(*) over", sql)
        self.assertIn("candidate_rank", sql)
        self.assertIn("ambiguous", sql)
        self.assertIn("where candidate_count = 1", sql)

    def test_tax_matching_documents_form_type_cases(self) -> None:
        sql_path = ROOT / "supabase/sql/017_profit_tax_form_type_matching.sql"
        sql = sql_path.read_text(encoding="utf-8")

        self.assertIn("990-T", sql)
        self.assertIn("990-EZ", sql)
        self.assertIn("1120", sql)
        self.assertIn("1065", sql)
        self.assertIn("1040", sql)


if __name__ == "__main__":
    unittest.main()
