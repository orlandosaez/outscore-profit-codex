from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ClientAssignmentCliTests(unittest.TestCase):
    def test_parse_client_assignments_cli_writes_staging_csv_and_summary(self) -> None:
        output_path = ROOT / "build/test-client-service-owners-cli.csv"
        summary_path = ROOT / "build/test-client-service-owners-cli-summary.json"

        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/parse_client_assignments.py"),
                "--input",
                str(ROOT / "Client-staff assignments.xlsx"),
                "--output",
                str(output_path),
                "--summary",
                str(summary_path),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("owner_assignments=159", result.stdout)
        self.assertTrue(output_path.exists())
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        self.assertEqual(summary["assignment_count"], 159)
        self.assertEqual(summary["unmapped_service_codes"], [])


if __name__ == "__main__":
    unittest.main()
