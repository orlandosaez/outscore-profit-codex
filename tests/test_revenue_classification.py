from __future__ import annotations

import unittest
from pathlib import Path

from profit_import.revenue_classification import (
    classify_invoice_line_items,
    normalize_qbo_product_name,
    parse_qbo_products_csv,
)


ROOT = Path(__file__).resolve().parents[1]


class RevenueClassificationTests(unittest.TestCase):
    def test_parse_qbo_products_maps_income_categories_to_macro_service_types(self) -> None:
        products = parse_qbo_products_csv(ROOT / "QBO ProductsServicesList_SBC_Accounting_and_Tax,_LLC_4_26_2026.csv")

        self.assertEqual(products["accounting plus"].macro_service_type, "bookkeeping")
        self.assertEqual(products["1120 plus"].macro_service_type, "tax")
        self.assertEqual(products["payroll service"].macro_service_type, "payroll")
        self.assertEqual(products["fractional cfo"].macro_service_type, "advisory")
        self.assertFalse(products["billable expenses"].include_in_revenue_allocation)

    def test_normalize_qbo_product_name_strips_anchor_category_prefixes(self) -> None:
        self.assertEqual(normalize_qbo_product_name("Tax Work:1120 Plus"), "1120 plus")
        self.assertEqual(normalize_qbo_product_name("Accounting:Accounting Essential"), "accounting essential")
        self.assertEqual(normalize_qbo_product_name("Payroll:Payroll Service"), "payroll service")

    def test_classify_invoice_line_items_uses_children_not_bundle_parent(self) -> None:
        products = parse_qbo_products_csv(ROOT / "QBO ProductsServicesList_SBC_Accounting_and_Tax,_LLC_4_26_2026.csv")
        rows = [
            {
                "anchor_line_item_id": "parent-1",
                "anchor_invoice_id": "invoice-1",
                "anchor_relationship_id": "relationship-1",
                "parent_line_item_id": None,
                "qbo_product_name": "Accounting and Tax Services Bundle",
                "name": "Accounting and Tax Services Bundle",
                "amount": "1000.00",
                "is_bundle_parent": True,
            },
            {
                "anchor_line_item_id": "child-1",
                "anchor_invoice_id": "invoice-1",
                "anchor_relationship_id": "relationship-1",
                "parent_line_item_id": "parent-1",
                "qbo_product_name": "Accounting:Accounting Plus",
                "name": "Accounting Plus",
                "amount": "650.00",
                "is_bundle_parent": False,
            },
            {
                "anchor_line_item_id": "child-2",
                "anchor_invoice_id": "invoice-1",
                "anchor_relationship_id": "relationship-1",
                "parent_line_item_id": "parent-1",
                "qbo_product_name": "Tax Work:1120 Essential",
                "name": "1120 Essential",
                "amount": "350.00",
                "is_bundle_parent": False,
            },
        ]

        classified = classify_invoice_line_items(rows, products)

        parent = next(row for row in classified if row.anchor_line_item_id == "parent-1")
        self.assertFalse(parent.include_in_revenue_allocation)
        self.assertEqual(parent.classification_reason, "bundle_parent_has_children")

        child_macros = {
            row.anchor_line_item_id: (row.macro_service_type, row.include_in_revenue_allocation, row.revenue_amount)
            for row in classified
            if row.anchor_line_item_id.startswith("child-")
        }
        self.assertEqual(
            child_macros,
            {
                "child-1": ("bookkeeping", True, 650.00),
                "child-2": ("tax", True, 350.00),
            },
        )

    def test_unclassified_products_are_excluded_for_review(self) -> None:
        classified = classify_invoice_line_items(
            [
                {
                    "anchor_line_item_id": "line-1",
                    "anchor_invoice_id": "invoice-1",
                    "anchor_relationship_id": "relationship-1",
                    "parent_line_item_id": None,
                    "qbo_product_name": "Mystery Product",
                    "name": "Mystery Product",
                    "amount": "25.00",
                    "is_bundle_parent": False,
                }
            ],
            {},
        )

        self.assertEqual(classified[0].macro_service_type, "unknown")
        self.assertFalse(classified[0].include_in_revenue_allocation)
        self.assertEqual(classified[0].classification_reason, "unclassified_qbo_product")

    def test_known_qbo_category_prefix_classifies_when_product_name_is_not_exported(self) -> None:
        classified = classify_invoice_line_items(
            [
                {
                    "anchor_line_item_id": "line-1",
                    "anchor_invoice_id": "invoice-1",
                    "anchor_relationship_id": "relationship-1",
                    "parent_line_item_id": None,
                    "qbo_product_name": "Advisory:Strategic Advisory",
                    "name": "Strategic Advisory",
                    "amount": "840.00",
                    "is_bundle_parent": False,
                }
            ],
            {},
        )

        self.assertEqual(classified[0].macro_service_type, "advisory")
        self.assertTrue(classified[0].include_in_revenue_allocation)
        self.assertEqual(classified[0].classification_reason, "qbo_category_prefix")


if __name__ == "__main__":
    unittest.main()
