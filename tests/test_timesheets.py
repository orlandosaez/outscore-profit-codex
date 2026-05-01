from __future__ import annotations

import unittest
from datetime import date
from pathlib import Path

from profit_import.timesheets import (
    STAFF_RATES,
    infer_service_type,
    parse_timesheet_file,
    parse_timesheet_folder,
    summarize_time_entries,
    write_time_entries_csv,
)


ROOT = Path(__file__).resolve().parents[1]


class TimesheetParserTests(unittest.TestCase):
    def test_laura_long_format_splits_client_task_and_costs_labor(self) -> None:
        entries = parse_timesheet_file(ROOT / "timesheets/Laura - Timeshet 3.15.26.xlsx")

        first = entries[0]
        self.assertEqual(first.staff_name, "Laura")
        self.assertEqual(first.client_raw, "Daniel Ian")
        self.assertEqual(first.task_raw, "1040 Prep")
        self.assertEqual(first.entry_date, date(2026, 3, 1))
        self.assertEqual(first.hours, 0.75)
        self.assertEqual(first.hourly_rate, STAFF_RATES["Laura"])
        self.assertEqual(first.labor_cost, 45.0)

        tax_entry = next(
            entry
            for entry in entries
            if entry.client_raw == "1415 Cortez" and entry.task_raw == "T/R Prep"
        )
        self.assertEqual(tax_entry.service_type, "tax")
        self.assertFalse(tax_entry.is_admin)
        self.assertFalse(any(entry.entry_date.year == 2036 for entry in entries))
        self.assertTrue(
            any(
                entry.client_raw == "Admin"
                and entry.source_row == 59
                and entry.entry_date == date(2026, 3, 6)
                for entry in entries
            )
        )

    def test_wama_excludes_upwork_and_pre_cutoff_rows(self) -> None:
        entries = parse_timesheet_file(ROOT / "timesheets/Wama Hours Log - Outscore.xlsx")

        self.assertGreater(len(entries), 0)
        self.assertTrue(all(entry.staff_name == "Wama" for entry in entries))
        self.assertTrue(all(entry.entry_date > date(2025, 9, 15) for entry in entries))
        self.assertTrue(all("upwork" not in (entry.paid_marker or "").lower() for entry in entries))
        self.assertTrue(any(entry.client_raw == "Lighthouse" for entry in entries))
        self.assertTrue(any(entry.client_raw == "Internal" and entry.is_admin for entry in entries))

    def test_beth_sparse_format_forward_fills_dates_and_repairs_year_typos(self) -> None:
        entries = parse_timesheet_file(ROOT / "timesheets/beth Dec 15- Jan 28 Time sheets.xlsx")

        first = entries[0]
        self.assertEqual(first.staff_name, "Beth")
        self.assertEqual(first.entry_date, date(2025, 12, 18))
        self.assertEqual(first.client_raw, "Kar kraft Auto Repair")
        self.assertEqual(first.task_raw, "Payroll Tax Deposit")
        self.assertAlmostEqual(first.hours, 0.33)

        jan_entry = next(
            entry
            for entry in entries
            if entry.client_raw == "Kar kraft Auto Repair"
            and entry.task_raw == "Payroll Tax Deposit"
            and entry.entry_date == date(2026, 1, 11)
        )
        self.assertEqual(jan_entry.service_type, "payroll")

        admin_entry = next(entry for entry in entries if entry.client_raw == "SBC Meeting")
        self.assertTrue(admin_entry.is_admin)
        self.assertEqual(admin_entry.service_type, "admin")

    def test_julie_wide_format_unpivots_positive_daily_hours(self) -> None:
        entries = parse_timesheet_file(ROOT / "timesheets/julie Timesheet thru March 16-27 2026.xlsx")

        self.assertGreater(len(entries), 0)
        self.assertTrue(all(entry.staff_name == "Julie" for entry in entries))
        self.assertTrue(all(entry.hours > 0 for entry in entries))
        self.assertFalse(any(entry.client_raw == "Total hrs" for entry in entries))
        self.assertTrue(
            any(
                entry.client_raw == "Samdee Automotive"
                and entry.entry_date == date(2026, 3, 17)
                and entry.hours == 0.5
                for entry in entries
            )
        )

    def test_folder_parser_combines_real_timesheets_only(self) -> None:
        entries = parse_timesheet_folder(ROOT / "timesheets")
        staff_names = {entry.staff_name for entry in entries}

        self.assertEqual(staff_names, {"Beth", "Julie", "Laura", "Wama"})
        self.assertTrue(all("~$" not in entry.source_file for entry in entries))
        self.assertTrue(all(entry.labor_cost == round(entry.hours * entry.hourly_rate, 2) for entry in entries))

    def test_service_type_inference_covers_known_task_phrasing(self) -> None:
        self.assertEqual(infer_service_type("Feb bookkeeping", "client"), "bookkeeping")
        self.assertEqual(infer_service_type("Payroll Tax Deposit", "client"), "payroll")
        self.assertEqual(infer_service_type("1040 Prep", "client"), "tax")
        self.assertEqual(infer_service_type("Outscore meeting", "Outscore Meeting"), "admin")

    def test_summary_and_csv_export_are_machine_readable(self) -> None:
        entries = parse_timesheet_file(ROOT / "timesheets/Laura - Timeshet 3.15.26.xlsx")[:3]
        summary = summarize_time_entries(entries)

        self.assertEqual(summary["entry_count"], 3)
        self.assertEqual(summary["staff"]["Laura"]["entry_count"], 3)
        self.assertEqual(summary["staff"]["Laura"]["hours"], sum(entry.hours for entry in entries))
        self.assertEqual(summary["admin_hours"], 0)

        output_path = ROOT / "build/test-time-entries.csv"
        write_time_entries_csv(entries, output_path)
        csv_text = output_path.read_text(encoding="utf-8")
        self.assertIn("staff_name,entry_date,client_raw,task_raw,hours", csv_text)
        self.assertIn("Laura,2026-03-01,Daniel Ian,1040 Prep,0.75", csv_text)


if __name__ == "__main__":
    unittest.main()
