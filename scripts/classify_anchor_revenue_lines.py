#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from profit_import.revenue_classification import (
    classify_invoice_line_items,
    parse_invoice_line_items_csv,
    parse_qbo_products_csv,
    summarize_classifications,
    write_classification_load_sql,
    write_classification_review_csv,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Classify Anchor invoice line items into Outscore profit service buckets.")
    parser.add_argument("--line-items", default=ROOT / "build/live_anchor_invoice_line_items.csv", type=Path)
    parser.add_argument(
        "--qbo-products",
        default=ROOT / "QBO ProductsServicesList_SBC_Accounting_and_Tax,_LLC_4_26_2026.csv",
        type=Path,
    )
    parser.add_argument("--review-output", default=ROOT / "build/anchor_line_item_classifications_review.csv", type=Path)
    parser.add_argument("--sql-output", default=ROOT / "build/anchor_line_item_classifications_load.sql", type=Path)
    args = parser.parse_args()

    products = parse_qbo_products_csv(args.qbo_products)
    line_items = parse_invoice_line_items_csv(args.line_items)
    classified = classify_invoice_line_items(line_items, products)
    summary = summarize_classifications(classified)

    write_classification_review_csv(classified, args.review_output)
    write_classification_load_sql(classified, args.sql_output)

    for key, value in summary.items():
        print(f"{key}={value}")
    print(f"review_csv={args.review_output}")
    print(f"sql={args.sql_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
