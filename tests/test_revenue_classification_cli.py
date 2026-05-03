from __future__ import annotations

import csv
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class RevenueClassificationCliTests(unittest.TestCase):
    def test_classify_anchor_revenue_lines_cli_writes_review_csv_and_sql(self) -> None:
        source_path = ROOT / "build/test-anchor-line-items-input.csv"
        review_path = ROOT / "build/test-anchor-line-items-classified.csv"
        sql_path = ROOT / "build/test-anchor-line-items-classified.sql"

        source_path.parent.mkdir(parents=True, exist_ok=True)
        with source_path.open("w", newline="", encoding="utf-8") as file:
            writer = csv.DictWriter(
                file,
                fieldnames=[
                    "anchor_line_item_id",
                    "anchor_invoice_id",
                    "anchor_relationship_id",
                    "parent_line_item_id",
                    "qbo_product_name",
                    "name",
                    "amount",
                    "is_bundle_parent",
                ],
            )
            writer.writeheader()
            writer.writerows(
                [
                    {
                        "anchor_line_item_id": "child-1",
                        "anchor_invoice_id": "invoice-1",
                        "anchor_relationship_id": "relationship-1",
                        "parent_line_item_id": "parent-1",
                        "qbo_product_name": "Accounting:Accounting Plus",
                        "name": "Accounting Plus",
                        "amount": "650.00",
                        "is_bundle_parent": "false",
                    },
                    {
                        "anchor_line_item_id": "line-2",
                        "anchor_invoice_id": "invoice-1",
                        "anchor_relationship_id": "relationship-1",
                        "parent_line_item_id": "",
                        "qbo_product_name": "Mystery Product",
                        "name": "Mystery Product",
                        "amount": "10.00",
                        "is_bundle_parent": "false",
                    },
                ]
            )

        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/classify_anchor_revenue_lines.py"),
                "--line-items",
                str(source_path),
                "--qbo-products",
                str(ROOT / "docs/data-references/qbo-product-services.csv"),
                "--review-output",
                str(review_path),
                "--sql-output",
                str(sql_path),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("classified_line_items=2", result.stdout)
        self.assertIn("unclassified_line_items=1", result.stdout)
        self.assertTrue(review_path.exists())
        self.assertTrue(sql_path.exists())

        review_text = review_path.read_text(encoding="utf-8")
        self.assertIn("child-1,invoice-1,relationship-1,parent-1,Accounting:Accounting Plus", review_text)
        sql_text = sql_path.read_text(encoding="utf-8")
        self.assertIn("create table if not exists profit_anchor_line_item_classifications", sql_text.lower())
        self.assertIn("'child-1', 'invoice-1', 'relationship-1', 'parent-1'", sql_text)
        self.assertIn("on conflict (anchor_line_item_id)", sql_text.lower())


if __name__ == "__main__":
    unittest.main()
