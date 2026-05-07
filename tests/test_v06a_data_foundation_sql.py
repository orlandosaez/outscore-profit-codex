from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class V06ADataFoundationSqlTests(unittest.TestCase):
    def test_migration_020_updates_name_normalization_and_fc_tag_tables(self) -> None:
        sql = (
            ROOT / "supabase/sql/020_profit_name_normalization_and_fc_tags.sql"
        ).read_text(encoding="utf-8").lower()

        self.assertIn("create or replace function profit_normalize_client_name", sql)
        self.assertIn("regexp_replace", sql)
        self.assertIn("\\s*\\([^)]*\\)", sql)
        self.assertIn("create table if not exists profit_fc_client_tags", sql)
        self.assertIn("create table if not exists profit_fc_project_tags", sql)
        self.assertIn("create table if not exists profit_fc_task_tags", sql)
        self.assertIn("tag_type text not null check", sql)
        self.assertIn("'service'", sql)
        self.assertIn("'group'", sql)
        self.assertIn("'staff'", sql)
        self.assertIn("'unknown'", sql)
        self.assertIn("primary key (fc_client_id, tag_name)", sql)
        self.assertIn("primary key (fc_project_id, tag_name)", sql)
        self.assertIn("primary key (fc_task_id, tag_name)", sql)

    def test_migration_020_defines_groups_near_duplicates_and_task_kind_view(self) -> None:
        sql = (
            ROOT / "supabase/sql/020_profit_name_normalization_and_fc_tags.sql"
        ).read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_client_groups", sql)
        self.assertIn("create table if not exists profit_client_group_members", sql)
        self.assertIn("create or replace view profit_fc_group_name_near_duplicates", sql)
        self.assertIn("create or replace function profit_refresh_client_groups", sql)
        self.assertIn("corey monaghan", sql)
        self.assertIn("corey monanghan", sql)
        self.assertIn("pg_trgm", sql)
        self.assertIn("create or replace view profit_fc_task_delivery_classification", sql)
        self.assertIn("'service_delivery'", sql)
        self.assertIn("'admin_onboarding'", sql)
        self.assertIn("'unknown'", sql)
        self.assertIn("close the books", sql)
        self.assertIn("file the tax return", sql)
        self.assertIn("onboarding", sql)

    def test_migration_020_documents_parenthetical_normalization_examples(self) -> None:
        sql = (
            ROOT / "supabase/sql/020_profit_name_normalization_and_fc_tags.sql"
        ).read_text(encoding="utf-8")

        self.assertIn("Kar Kraft Auto Repair LLC (TempleTerrace)", sql)
        self.assertIn("Kar Kraft Services LLC (Zephyrhills)", sql)
        self.assertIn("Samdee Enterprises Automotive Group LLC (SpringHill)", sql)

    def test_migration_020a_seeds_form_941_rule_and_unmatched_tag_view(self) -> None:
        sql = (
            ROOT / "supabase/sql/020a_profit_seed_form_941_recognition_rule.sql"
        ).read_text(encoding="utf-8").lower()

        self.assertIn("form_941_quarterly", sql)
        self.assertIn("s 941", sql)
        self.assertIn("payroll", sql)
        self.assertIn("default_sla_day", sql)
        self.assertIn("30", sql)
        self.assertIn("on conflict (service_name) do update set", sql)
        self.assertIn(
            "create or replace view profit_unmatched_s_prefixed_tags",
            sql,
        )

    def test_migration_021_adds_anchor_agreement_status_and_qbo_product_config(self) -> None:
        sql = (
            ROOT
            / "supabase/sql/021_profit_anchor_agreement_status_and_qbo_product_sync.sql"
        ).read_text(encoding="utf-8").lower()

        # 2026-05-06 Anchor API inspection found agreement.status exposes
        # only active/terminated. No agreement-level paymentSynced or
        # effectiveStatus field exists.
        self.assertIn("alter table profit_anchor_agreements", sql)
        self.assertIn("add column if not exists display_status text", sql)
        self.assertIn("add column if not exists terminated_at timestamptz", sql)
        self.assertIn("add column if not exists status_synced_at timestamptz", sql)
        self.assertIn("create table if not exists profit_qbo_product_services", sql)
        self.assertIn("qbo_product_id text primary key", sql)
        self.assertIn("qbo_category_path text", sql)
        self.assertIn("source text not null default 'qbo_api_sync'", sql)
        self.assertIn("'active'", sql)
        self.assertIn("'terminated'", sql)

    def test_v06a_defines_anchor_service_vs_fc_project_coverage_view(self) -> None:
        sql = (
            ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql"
        ).read_text(encoding="utf-8").lower()

        self.assertIn("create or replace view profit_anchor_service_fc_project_coverage", sql)
        self.assertIn("anchor_relationship_id", sql)
        self.assertIn("fc_client_id", sql)
        self.assertIn("canonical_service_name", sql)
        self.assertIn("fc_tag", sql)
        self.assertIn("coverage_status", sql)
        self.assertIn("'covered'", sql)
        self.assertIn("'missing_fc_project'", sql)
        self.assertIn("'unknown'", sql)


if __name__ == "__main__":
    unittest.main()
