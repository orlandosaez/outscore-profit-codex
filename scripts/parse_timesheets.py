from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from profit_import.timesheets import (
    parse_timesheet_folder,
    summarize_time_entries,
    write_time_entries_csv,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Normalize staff timesheet workbooks into TimeEntry CSV.")
    parser.add_argument("--input-dir", default="timesheets", help="Folder containing .xlsx timesheets.")
    parser.add_argument("--output", default="build/normalized_time_entries.csv", help="CSV output path.")
    parser.add_argument("--summary", default="build/normalized_time_entries_summary.json", help="JSON summary path.")
    args = parser.parse_args()

    entries = parse_timesheet_folder(Path(args.input_dir))
    write_time_entries_csv(entries, args.output)

    summary_path = Path(args.summary)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summarize_time_entries(entries), indent=2, sort_keys=True), encoding="utf-8")

    print(f"normalized_entries={len(entries)}")
    print(f"csv={args.output}")
    print(f"summary={args.summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
