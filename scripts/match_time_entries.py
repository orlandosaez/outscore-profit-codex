#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from profit_import.anchor_matching import match_owner_assignments_to_anchor, parse_anchor_agreements_csv
from profit_import.assignments import expand_service_owner_assignments, parse_assignment_workbook
from profit_import.time_matching import (
    build_client_aliases_from_owner_matches,
    match_time_entries_to_anchor,
    summarize_time_entry_matches,
    write_time_entry_matches_csv,
)
from profit_import.timesheets import parse_timesheet_folder


def main() -> int:
    parser = argparse.ArgumentParser(description="Match normalized timesheet rows to Anchor relationship IDs.")
    parser.add_argument("--timesheets", default=ROOT / "timesheets", type=Path)
    parser.add_argument("--agreements", default=ROOT / "anchor_agreements_export_1777160122406.csv", type=Path)
    parser.add_argument("--assignments", default=ROOT / "Client-staff assignments.xlsx", type=Path)
    parser.add_argument("--review-output", default=ROOT / "build/time_entry_anchor_matches_review.csv", type=Path)
    parser.add_argument("--summary", default=ROOT / "build/time_entry_anchor_matches_summary.json", type=Path)
    args = parser.parse_args()

    entries = parse_timesheet_folder(args.timesheets)
    agreements = parse_anchor_agreements_csv(args.agreements)
    assignments = expand_service_owner_assignments(parse_assignment_workbook(args.assignments))
    owner_matches = match_owner_assignments_to_anchor(assignments, agreements)
    aliases = build_client_aliases_from_owner_matches(owner_matches)
    matches = match_time_entries_to_anchor(entries, agreements, aliases)
    summary = summarize_time_entry_matches(matches)

    write_time_entry_matches_csv(matches, args.review_output)
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")

    print(f"time_entries={summary['time_entry_count']}")
    print(f"matched_time_entries={summary['matched_time_entry_count']}")
    print(f"admin_time_entries={summary['admin_time_entry_count']}")
    print(f"unmatched_time_entries={summary['unmatched_time_entry_count']}")
    print(f"review_csv={args.review_output}")
    print(f"summary={args.summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
