from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AnchorMatchingCliTests(unittest.TestCase):
    def test_match_client_assignments_cli_writes_review_and_load_outputs(self) -> None:
        review_path = ROOT / "build/test-client-service-owner-matches-cli.csv"
        load_path = ROOT / "build/test-client-service-owner-load-cli.csv"
        sql_path = ROOT / "build/test-client-service-owner-load-cli.sql"
        summary_path = ROOT / "build/test-client-service-owner-matches-cli-summary.json"

        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/match_client_assignments.py"),
                "--assignments",
                str(ROOT / "Client-staff assignments.xlsx"),
                "--agreements",
                str(ROOT / "anchor_agreements_export_1777160122406.csv"),
                "--review-output",
                str(review_path),
                "--load-output",
                str(load_path),
                "--sql-output",
                str(sql_path),
                "--summary",
                str(summary_path),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("assignment_matches=", result.stdout)
        self.assertIn("load_rows=", result.stdout)
        self.assertTrue(review_path.exists())
        self.assertTrue(load_path.exists())
        self.assertTrue(sql_path.exists())
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        self.assertGreater(summary["matched_assignment_count"], 0)
        self.assertGreater(summary["load_row_count"], 0)


if __name__ == "__main__":
    unittest.main()
