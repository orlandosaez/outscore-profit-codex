from __future__ import annotations

import unittest
from datetime import date
from pathlib import Path

from profit_import.anchor_matching import (
    build_owner_load_rows,
    match_owner_assignments_to_anchor,
    parse_anchor_agreements_csv,
)
from profit_import.assignments import expand_service_owner_assignments, parse_assignment_workbook
from profit_import.time_matching import (
    build_client_aliases_from_owner_matches,
    match_time_entries_to_anchor,
    stable_time_entry_key,
)
from profit_import.timesheets import TimeEntry


ROOT = Path(__file__).resolve().parents[1]


class TimeMatchingTests(unittest.TestCase):
    def test_stable_time_entry_key_is_deterministic_from_source_identity(self) -> None:
        entry = TimeEntry(
            staff_name="Laura",
            entry_date=date(2026, 3, 16),
            client_raw="Kar Kraft Auto Repair",
            task_raw="Review T/R",
            hours=1.25,
            hourly_rate=60.0,
            labor_cost=75.0,
            service_type="tax",
            is_admin=False,
            source_file="Laura Timesheet 3.31.26.xlsx",
            source_sheet="3.31. TS",
            source_row=7,
        )

        self.assertEqual(stable_time_entry_key(entry), stable_time_entry_key(entry))
        self.assertTrue(stable_time_entry_key(entry).startswith("te_"))

    def test_aliases_from_owner_matches_help_match_timesheet_short_names(self) -> None:
        agreements = parse_anchor_agreements_csv(ROOT / "anchor_agreements_export_1777160122406.csv")
        assignments = expand_service_owner_assignments(parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx"))
        owner_matches = match_owner_assignments_to_anchor(assignments, agreements)
        aliases = build_client_aliases_from_owner_matches(owner_matches)

        entry = TimeEntry(
            staff_name="Laura",
            entry_date=date(2026, 3, 17),
            client_raw="Kar Kraft Auto Repair",
            task_raw="Review T/R",
            hours=1.25,
            hourly_rate=60.0,
            labor_cost=75.0,
            service_type="tax",
            is_admin=False,
            source_file="Laura Timesheet 3.31.26.xlsx",
            source_sheet="3.31. TS",
            source_row=7,
        )

        matches = match_time_entries_to_anchor([entry], agreements, aliases)

        self.assertEqual(matches[0].match_status, "matched")
        self.assertEqual(matches[0].anchor_relationship_id, "relationship-z26do6jeiYCI-ZMAXueMMOGLu8Upt")
        self.assertEqual(matches[0].macro_service_type, "tax")
        self.assertEqual(matches[0].match_reason, "assignment_alias")

    def test_admin_rows_are_kept_as_company_overhead_without_client_match(self) -> None:
        entry = TimeEntry(
            staff_name="Laura",
            entry_date=date(2026, 3, 2),
            client_raw="Admin",
            task_raw="",
            hours=2.25,
            hourly_rate=60.0,
            labor_cost=135.0,
            service_type="admin",
            is_admin=True,
            source_file="Laura - Timeshet 3.15.26.xlsx",
            source_sheet="Sheet1",
            source_row=55,
        )

        matches = match_time_entries_to_anchor([entry], [], {})

        self.assertEqual(matches[0].match_status, "admin")
        self.assertIsNone(matches[0].anchor_relationship_id)
        self.assertEqual(matches[0].macro_service_type, "admin")

    def test_unique_context_tokens_from_owner_workbook_match_common_short_names(self) -> None:
        agreements = parse_anchor_agreements_csv(ROOT / "anchor_agreements_export_1777160122406.csv")
        assignments = expand_service_owner_assignments(parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx"))
        owner_matches = match_owner_assignments_to_anchor(assignments, agreements)
        aliases = build_client_aliases_from_owner_matches(owner_matches)

        ultimate = TimeEntry(
            staff_name="Wama",
            entry_date=date(2026, 2, 1),
            client_raw="Ultimate Transmission",
            task_raw="Bank rec",
            hours=1.0,
            hourly_rate=16.0,
            labor_cost=16.0,
            service_type="bookkeeping",
            is_admin=False,
            source_file="Wama Hours Log - Outscore.xlsx",
            source_sheet="Sheet1",
            source_row=10,
        )

        samdee = TimeEntry(
            staff_name="Laura",
            entry_date=date(2026, 3, 1),
            client_raw="SamDee",
            task_raw="Bookkeeping",
            hours=1.0,
            hourly_rate=60.0,
            labor_cost=60.0,
            service_type="bookkeeping",
            is_admin=False,
            source_file="Laura - Timeshet 3.15.26.xlsx",
            source_sheet="Sheet1",
            source_row=9,
        )

        matches = match_time_entries_to_anchor([ultimate, samdee], agreements, aliases)

        self.assertEqual(matches[0].match_status, "matched")
        self.assertEqual(matches[0].anchor_relationship_id, "relationship-z26MOGeSon5g-QmdHBabesKlCfNJe")
        self.assertEqual(matches[0].match_reason, "assignment_alias")
        self.assertEqual(matches[1].match_status, "unmatched")

    def test_unique_agreement_abbreviations_match_yv_short_names(self) -> None:
        agreements = parse_anchor_agreements_csv(ROOT / "anchor_agreements_export_1777160122406.csv")
        entry = TimeEntry(
            staff_name="Julie",
            entry_date=date(2026, 3, 17),
            client_raw="YV-SR",
            task_raw="Bookkeeping",
            hours=0.5,
            hourly_rate=30.0,
            labor_cost=15.0,
            service_type="bookkeeping",
            is_admin=False,
            source_file="julie Timesheet thru March 16-27 2026.xlsx",
            source_sheet="Sheet1",
            source_row=20,
        )

        matches = match_time_entries_to_anchor([entry], agreements, {})

        self.assertEqual(matches[0].match_status, "matched")
        self.assertEqual(matches[0].anchor_relationship_id, "relationship-z26HG3JjP7o3-hp24Il1f1vCwNQGE")
        self.assertEqual(matches[0].match_reason, "agreement_abbreviation")

    def test_build_owner_rows_still_has_no_conflicting_owner_for_matched_relationship_macro(self) -> None:
        agreements = parse_anchor_agreements_csv(ROOT / "anchor_agreements_export_1777160122406.csv")
        assignments = expand_service_owner_assignments(parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx"))
        owner_matches = match_owner_assignments_to_anchor(assignments, agreements)
        owner_rows = build_owner_load_rows(owner_matches)

        keys = [(row["anchor_relationship_id"], row["macro_service_type"]) for row in owner_rows]
        self.assertEqual(len(keys), len(set(keys)))


if __name__ == "__main__":
    unittest.main()
