from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class TimeMatchingCliTests(unittest.TestCase):
    def test_match_time_entries_cli_writes_review_and_summary(self) -> None:
        review_path = ROOT / "build/test-time-entry-anchor-matches.csv"
        summary_path = ROOT / "build/test-time-entry-anchor-matches-summary.json"

        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/match_time_entries.py"),
                "--timesheets",
                str(ROOT / "timesheets"),
                "--agreements",
                str(ROOT / "anchor_agreements_export_1777160122406.csv"),
                "--assignments",
                str(ROOT / "Client-staff assignments.xlsx"),
                "--review-output",
                str(review_path),
                "--summary",
                str(summary_path),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("time_entries=", result.stdout)
        self.assertIn("matched_time_entries=", result.stdout)
        self.assertTrue(review_path.exists())
        self.assertTrue(summary_path.exists())
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        self.assertGreater(summary["time_entry_count"], 0)
        self.assertGreater(summary["admin_time_entry_count"], 0)


if __name__ == "__main__":
    unittest.main()
