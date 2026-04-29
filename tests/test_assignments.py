from __future__ import annotations

import unittest
from pathlib import Path

from profit_import.assignments import (
    expand_service_owner_assignments,
    parse_assignment_workbook,
    service_code_details,
    summarize_owner_assignments,
    write_owner_assignments_csv,
)


ROOT = Path(__file__).resolve().parents[1]


class ClientAssignmentParserTests(unittest.TestCase):
    def test_parse_assignment_workbook_preserves_client_rows_and_group_tokens(self) -> None:
        rows = parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx")

        self.assertEqual(len(rows), 126)
        first = rows[0]
        self.assertEqual(first.client_raw, "1415 Cortez Rd LLC")
        self.assertEqual(first.primary_staff, "Laura")
        self.assertEqual(first.reviewer_staff, "Beth")
        self.assertEqual(first.service_tokens, ("S 1120P", "S BOOKP", "S TPP"))
        self.assertEqual(first.context_tokens, ("Feig Group", "MIDAS Auto"))
        self.assertEqual(first.source_row, 2)

    def test_expand_service_owner_assignments_maps_service_codes_to_macro_types(self) -> None:
        rows = parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx")
        owners = expand_service_owner_assignments(rows)

        self.assertEqual(len(owners), 159)

        cortez = [owner for owner in owners if owner.client_raw == "1415 Cortez Rd LLC"]
        self.assertEqual(
            [(owner.service_code, owner.macro_service_type, owner.service_tier, owner.primary_staff) for owner in cortez],
            [
                ("1120P", "tax", "plus", "Laura"),
                ("BOOKP", "bookkeeping", "plus", "Laura"),
                ("TPP", "tax", None, "Laura"),
            ],
        )

        payroll = next(
            owner
            for owner in owners
            if owner.client_raw == "B & W Services LLC" and owner.service_code == "941"
        )
        self.assertEqual(payroll.macro_service_type, "payroll")
        self.assertEqual(payroll.primary_staff, "Beth")
        self.assertEqual(payroll.reviewer_staff, "Laura")

    def test_service_code_details_handles_one_time_and_accounting_codes(self) -> None:
        self.assertEqual(service_code_details("S SETUP"), ("SETUP", "advisory", None))
        self.assertEqual(service_code_details("S YECLOSE"), ("YECLOSE", "bookkeeping", None))
        self.assertEqual(service_code_details("S BOOKA"), ("BOOKA", "bookkeeping", "advanced"))
        self.assertEqual(service_code_details("S 1040E"), ("1040E", "tax", "essential"))

    def test_summary_and_csv_export_are_machine_readable(self) -> None:
        rows = parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx")
        owners = expand_service_owner_assignments(rows)
        summary = summarize_owner_assignments(owners)

        self.assertEqual(summary["assignment_count"], 159)
        self.assertEqual(
            summary["macro_service_type_counts"],
            {"advisory": 1, "bookkeeping": 24, "payroll": 6, "tax": 128},
        )
        self.assertEqual(summary["unmapped_service_codes"], [])

        output_path = ROOT / "build/test-client-service-owners.csv"
        write_owner_assignments_csv(owners[:3], output_path)
        csv_text = output_path.read_text(encoding="utf-8")
        self.assertIn("client_raw,service_token,service_code,macro_service_type", csv_text)
        self.assertIn("1415 Cortez Rd LLC,S 1120P,1120P,tax,plus,Laura,Beth", csv_text)


if __name__ == "__main__":
    unittest.main()
