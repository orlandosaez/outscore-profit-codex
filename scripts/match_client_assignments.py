from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from profit_import.anchor_matching import (
    build_owner_load_rows,
    match_owner_assignments_to_anchor,
    parse_anchor_agreements_csv,
    summarize_owner_matches,
    write_owner_load_sql,
    write_owner_load_rows_csv,
    write_owner_matches_csv,
)
from profit_import.assignments import expand_service_owner_assignments, parse_assignment_workbook


def main() -> int:
    parser = argparse.ArgumentParser(description="Match client service owners to Anchor relationship IDs.")
    parser.add_argument("--assignments", default="Client-staff assignments.xlsx", help="Client/staff assignment workbook.")
    parser.add_argument(
        "--agreements",
        default="anchor_agreements_export_1777160122406.csv",
        help="Anchor agreements CSV export.",
    )
    parser.add_argument(
        "--review-output",
        default="build/client_service_owner_matches_review.csv",
        help="All assignment match decisions.",
    )
    parser.add_argument(
        "--load-output",
        default="build/client_service_owner_load_staging.csv",
        help="Collapsed matched rows ready for staff ID lookup and Supabase load.",
    )
    parser.add_argument(
        "--sql-output",
        default="build/client_service_owner_load.sql",
        help="SQL file for loading collapsed matched owner rows into Supabase.",
    )
    parser.add_argument(
        "--summary",
        default="build/client_service_owner_matches_summary.json",
        help="JSON summary path.",
    )
    parser.add_argument("--effective-from", default="2026-01-01", help="Effective date for load staging rows.")
    args = parser.parse_args()

    assignment_rows = parse_assignment_workbook(Path(args.assignments))
    assignments = expand_service_owner_assignments(assignment_rows)
    agreements = parse_anchor_agreements_csv(Path(args.agreements))
    matches = match_owner_assignments_to_anchor(assignments, agreements)
    load_rows = build_owner_load_rows(matches, effective_from=args.effective_from)

    write_owner_matches_csv(matches, args.review_output)
    write_owner_load_rows_csv(load_rows, args.load_output)
    write_owner_load_sql(load_rows, args.sql_output)

    summary = summarize_owner_matches(matches)
    summary["source_assignment_row_count"] = len(assignment_rows)
    summary["anchor_agreement_count"] = len(agreements)
    summary["load_row_count"] = len(load_rows)

    summary_path = Path(args.summary)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")

    print(f"source_assignment_rows={len(assignment_rows)}")
    print(f"assignment_matches={len(matches)}")
    print(f"matched_assignments={summary['matched_assignment_count']}")
    print(f"unmatched_assignments={summary['unmatched_assignment_count']}")
    print(f"ambiguous_assignments={summary['ambiguous_assignment_count']}")
    print(f"load_rows={len(load_rows)}")
    print(f"review_csv={args.review_output}")
    print(f"load_csv={args.load_output}")
    print(f"sql={args.sql_output}")
    print(f"summary={args.summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
