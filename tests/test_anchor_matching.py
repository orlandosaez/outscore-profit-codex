from __future__ import annotations

import unittest
from pathlib import Path

from profit_import.anchor_matching import (
    build_owner_load_rows,
    match_owner_assignments_to_anchor,
    normalize_client_name,
    parse_anchor_agreements_csv,
    summarize_owner_matches,
    write_owner_load_sql,
    write_owner_matches_csv,
)
from profit_import.assignments import expand_service_owner_assignments, parse_assignment_workbook


ROOT = Path(__file__).resolve().parents[1]


class AnchorMatchingTests(unittest.TestCase):
    def test_normalize_client_name_removes_parentheticals_suffixes_and_punctuation(self) -> None:
        self.assertEqual(normalize_client_name("Kar Kraft Auto Repair LLC (TempleTerrace)"), "karkraftautorepair")
        self.assertEqual(normalize_client_name("Collectiv Inc."), "collectiv")
        self.assertEqual(normalize_client_name("B & W Services LLC"), "bwservices")

    def test_match_owner_assignments_to_anchor_uses_normalized_business_name(self) -> None:
        agreements = parse_anchor_agreements_csv(ROOT / "anchor_agreements_export_1777160122406.csv")
        assignments = expand_service_owner_assignments(parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx"))
        matches = match_owner_assignments_to_anchor(assignments, agreements)

        kar_kraft = next(
            match
            for match in matches
            if match.client_raw == "Kar Kraft Auto Repair LLC (TempleTerrace)"
            and match.service_code == "BOOKP"
        )
        self.assertEqual(kar_kraft.match_status, "matched")
        self.assertEqual(kar_kraft.anchor_relationship_id, "relationship-z26do6jeiYCI-ZMAXueMMOGLu8Upt")
        self.assertEqual(kar_kraft.anchor_client_business_name, "Kar Kraft Auto Repair LLC")

        collectiv = next(match for match in matches if match.client_raw == "Collectiv LLC")
        self.assertEqual(collectiv.match_status, "matched")
        self.assertEqual(collectiv.anchor_relationship_id, "relationship-iYKcklY5Afc-lA8FYR3BzIkvzff0")
        self.assertEqual(collectiv.match_reason, "normalized_client_name")

        unmatched = next(match for match in matches if match.client_raw == "1415 Cortez Rd LLC")
        self.assertEqual(unmatched.match_status, "unmatched")
        self.assertIsNone(unmatched.anchor_relationship_id)

    def test_build_owner_load_rows_collapses_to_relationship_macro_owner(self) -> None:
        agreements = parse_anchor_agreements_csv(ROOT / "anchor_agreements_export_1777160122406.csv")
        assignments = expand_service_owner_assignments(parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx"))
        matches = match_owner_assignments_to_anchor(assignments, agreements)
        load_rows = build_owner_load_rows(matches)

        legacy_rows = [row for row in load_rows if row["anchor_relationship_id"] == "relationship-z26Ugzs2zAen-0tVZ6ErV61Xff72C"]
        self.assertEqual(
            sorted((row["macro_service_type"], row["primary_staff"], row["source_assignment_count"]) for row in legacy_rows),
            [("bookkeeping", "Noelle", 1), ("tax", "Beth", 1)],
        )

        samdee_tax = next(
            row
            for row in load_rows
            if row["anchor_relationship_id"] == "relationship-z26INMpy907F-h59Mhu7iscedmSoN"
            and row["macro_service_type"] == "tax"
        )
        self.assertEqual(samdee_tax["primary_staff"], "Laura")
        self.assertEqual(samdee_tax["source_assignment_count"], 2)

    def test_write_owner_load_sql_validates_staff_and_upserts_owner_rows(self) -> None:
        rows = [
            {
                "anchor_relationship_id": "relationship-abc",
                "macro_service_type": "tax",
                "primary_staff": "Beth",
                "effective_from": "2026-01-01",
                "effective_to": None,
                "source_assignment_count": 1,
                "source_service_codes": "1120P",
                "source_clients": "Example LLC",
            }
        ]

        output_path = ROOT / "build/test-client-service-owner-load.sql"
        write_owner_load_sql(rows, output_path)
        sql = output_path.read_text(encoding="utf-8")

        self.assertIn("create unique index if not exists", sql.lower())
        self.assertIn("missing staff in profit_staff", sql)
        self.assertIn("'relationship-abc', 'tax', 'Beth', '2026-01-01'::date, null::date", sql)
        self.assertIn("on conflict (anchor_relationship_id, macro_service_type, effective_from)", sql)

    def test_summary_and_csv_export_are_machine_readable(self) -> None:
        agreements = parse_anchor_agreements_csv(ROOT / "anchor_agreements_export_1777160122406.csv")
        assignments = expand_service_owner_assignments(parse_assignment_workbook(ROOT / "Client-staff assignments.xlsx"))
        matches = match_owner_assignments_to_anchor(assignments, agreements)
        summary = summarize_owner_matches(matches)

        self.assertGreater(summary["matched_assignment_count"], 0)
        self.assertGreater(summary["unmatched_assignment_count"], 0)
        self.assertEqual(summary["ambiguous_assignment_count"], 0)

        output_path = ROOT / "build/test-client-service-owner-matches.csv"
        write_owner_matches_csv(matches[:3], output_path)
        csv_text = output_path.read_text(encoding="utf-8")
        self.assertIn("match_status,client_raw,service_code,macro_service_type", csv_text)


if __name__ == "__main__":
    unittest.main()
