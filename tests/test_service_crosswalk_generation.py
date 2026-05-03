from __future__ import annotations

import csv
import importlib.util
import re
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts/generate_service_crosswalk_seed.py"
ANCHOR_CSV = ROOT / "docs/data-references/anchor services.csv"
QBO_CSV = ROOT / "docs/data-references/qbo-product-services.csv"
MIGRATION = ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql"


def load_generator_module():
    spec = importlib.util.spec_from_file_location("generate_service_crosswalk_seed", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def anchor_service_tags() -> dict[str, str | None]:
    with ANCHOR_CSV.open(encoding="utf-8-sig", newline="") as file:
        rows = {
            row["Name"]: (row["Tag"].strip() or None)
            for row in csv.DictReader(file)
            if row["Type"] == "Service"
        }
    return rows


class ServiceCrosswalkGenerationTests(unittest.TestCase):
    def test_generator_reads_actual_anchor_fc_tags(self) -> None:
        generator = load_generator_module()
        rows = generator.load_anchor_services(ANCHOR_CSV)

        self.assertEqual(rows["Accounting Advanced"].fc_tag, "S BOOKA")
        self.assertEqual(rows["Accounting Essential"].fc_tag, "S BOOKE")
        self.assertEqual(rows["Accounting Plus"].fc_tag, "S BOOKP")
        self.assertEqual(rows["Sales Tax Compliance"].fc_tag, "S SALESTAX")
        self.assertEqual(rows["Payroll Service"].fc_tag, "S PAYROLL")
        self.assertIsNone(rows["Other Income"].fc_tag)
        self.assertIsNone(rows["Services"].fc_tag)
        self.assertIsNone(rows["Specialized Services"].fc_tag)

    def test_generator_joins_exact_qbo_product_matches(self) -> None:
        generator = load_generator_module()
        anchor_rows = generator.load_anchor_services(ANCHOR_CSV)
        qbo_rows = generator.load_qbo_products(QBO_CSV)
        crosswalk = generator.build_crosswalk_rows(anchor_rows, qbo_rows)

        self.assertEqual(crosswalk["Accounting Advanced"].qbo_product_name, "Accounting Advanced")
        self.assertEqual(crosswalk["Accounting Advanced"].qbo_category_path, "Accounting")
        self.assertEqual(crosswalk["1040 Advanced"].qbo_product_name, "1040 Advanced")
        self.assertEqual(crosswalk["1040 Advanced"].qbo_category_path, "Tax Work")

    def test_generated_migration_contains_all_anchor_services_and_matching_tags(self) -> None:
        sql = MIGRATION.read_text(encoding="utf-8")
        tags = anchor_service_tags()

        seed_service_names = set(re.findall(r"^\s+\('([^']+)'", sql, flags=re.MULTILINE))
        self.assertEqual(seed_service_names, set(tags))

        for service_name in [
            "Accounting Advanced",
            "Accounting Essential",
            "Accounting Plus",
            "1040 Advanced",
            "Audit Protection Business",
            "Sales Tax Compliance",
            "Payroll Service",
            "Year End Accounting Close",
        ]:
            expected_tag = tags[service_name]
            self.assertIn(f"'{service_name}',", sql)
            self.assertIn(f"'{expected_tag}'", sql)

        for service_name in ["Other Income", "Services", "Specialized Services"]:
            self.assertRegex(sql, rf"\('{re.escape(service_name)}', [^)]+, null, ")

    def test_generated_migration_includes_required_rule_columns_for_empty_table_insert(self) -> None:
        sql = MIGRATION.read_text(encoding="utf-8")

        for column in [
            "macro_service_type",
            "service_tier",
            "recognition_pattern",
            "service_period_rule",
            "default_sla_day",
            "form_type_pattern",
            "notes",
        ]:
            self.assertIn(column, sql)

        self.assertIn(
            "'Accounting Advanced', 'bookkeeping', 'Advanced', 'monthly_recurring', 'previous_month', 10",
            sql,
        )
        self.assertIn(
            "'1040 Advanced', 'tax', 'Advanced', 'tax_filing', 'tax_year_default'",
            sql,
        )

    def test_generated_migration_has_no_hallucinated_old_accounting_tags(self) -> None:
        sql = MIGRATION.read_text(encoding="utf-8")

        self.assertNotIn("S ACCA", sql)
        self.assertNotIn("S ACCE", sql)
        self.assertNotIn("S ACCP", sql)
        self.assertIn("S BOOKA", sql)
        self.assertIn("S BOOKE", sql)
        self.assertIn("S BOOKP", sql)
