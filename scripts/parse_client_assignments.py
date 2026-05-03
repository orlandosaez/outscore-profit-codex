from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from profit_import.assignments import (
    expand_service_owner_assignments,
    parse_assignment_workbook,
    summarize_owner_assignments,
    write_owner_assignments_csv,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize client/staff service-owner assignments.")
    parser.add_argument(
        "--input",
        default=ROOT / "docs/data-references/client-staff-assignments.xlsx",
        type=Path,
        help="Client/staff assignment workbook.",
    )
    parser.add_argument("--output", default="build/client_service_owners_staging.csv", help="CSV output path.")
    parser.add_argument(
        "--summary",
        default="build/client_service_owners_staging_summary.json",
        help="JSON summary path.",
    )
    args = parser.parse_args()

    source_rows = parse_assignment_workbook(Path(args.input))
    owners = expand_service_owner_assignments(source_rows)
    write_owner_assignments_csv(owners, args.output)

    summary_path = Path(args.summary)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(
        json.dumps(summarize_owner_assignments(owners), indent=2, sort_keys=True),
        encoding="utf-8",
    )

    print(f"source_rows={len(source_rows)}")
    print(f"owner_assignments={len(owners)}")
    print(f"csv={args.output}")
    print(f"summary={args.summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
