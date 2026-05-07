from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ServiceAliasResolutionTests(unittest.TestCase):
    def test_migration_022_preserves_raw_service_and_adds_canonical_resolution(self) -> None:
        sql = (
            ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql"
        ).read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_anchor_service_aliases", sql)
        self.assertIn("raw_service_name text primary key", sql)
        self.assertIn(
            "canonical_service_name text not null references profit_service_recognition_rules(service_name)",
            sql,
        )
        self.assertIn("alter table profit_revenue_events", sql)
        self.assertIn("add column if not exists canonical_service_name text", sql)
        self.assertIn("references profit_service_recognition_rules(service_name)", sql)
        self.assertIn("create or replace function profit_resolve_canonical_service_name", sql)
        self.assertIn("exact", sql)
        self.assertIn("manual_alias", sql)
        self.assertIn("prefix", sql)
        self.assertIn("create or replace view profit_unresolved_service_names", sql)

    def test_migration_022_documents_unresolved_real_examples_without_guessing_aliases(self) -> None:
        sql = (
            ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql"
        ).read_text(encoding="utf-8")

        self.assertIn("Bookkeeping Services", sql)
        self.assertIn("1120 Plus - Proration for monthly billing", sql)
        self.assertIn("1040 Plus (Ken & Nancy Wong)", sql)
        self.assertIn("do not guess canonical mappings", sql.lower())
        self.assertNotIn("insert into profit_anchor_service_aliases", sql.lower())

    def test_prefix_resolution_uses_literal_boundaries_not_postgres_regex(self) -> None:
        sql = (
            ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql"
        ).read_text(encoding="utf-8").lower()

        self.assertIn("like lower(rule.service_name) || ' -%'", sql)
        self.assertIn("like lower(rule.service_name) || ' (%'", sql)
        self.assertIn("like lower(rule.service_name) || ',%'", sql)
        self.assertNotIn("regexp_replace", sql)
        self.assertNotIn("~*", sql)

    def test_prefix_resolution_regression_cases_are_locked_in_source(self) -> None:
        sql = (
            ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql"
        ).read_text(encoding="utf-8")

        self.assertIn("1120 Plus - Proration for monthly billing -> 1120 Plus", sql)
        self.assertIn("1040 Plus (Ken & Nancy Wong) -> 1040 Plus", sql)
        self.assertIn("Advisory, custom note -> Advisory", sql)
        self.assertIn("Accounting Plus -> Accounting Plus", sql)
        self.assertIn("990-EZ - amended return -> 990-EZ", sql)


if __name__ == "__main__":
    unittest.main()
