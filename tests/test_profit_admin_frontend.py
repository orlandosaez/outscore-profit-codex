from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ProfitAdminFrontendTests(unittest.TestCase):
    def test_react_admin_page_fetches_dashboard_snapshot_endpoint(self) -> None:
        app_path = ROOT / "app/frontend/src/App.jsx"
        source = app_path.read_text(encoding="utf-8")

        self.assertIn("VITE_PROFIT_API_BASE", source)
        self.assertIn("/profit/admin/dashboard", source)
        self.assertIn("Company GP", source)
        self.assertIn("Prepaid Liability", source)
        self.assertIn("Deferred Revenue JE balance", source)
        self.assertIn("Prepaid Liability Drilldown", source)
        self.assertIn("Period", source)
        self.assertIn("Ratio Summary", source)
        self.assertIn("Client Labor LER", source)
        self.assertIn("Admin Labor LER", source)
        self.assertIn("Unmatched Labor LER", source)
        self.assertIn("Total Labor LER", source)
        self.assertIn("Client-Matched %", source)
        self.assertIn("Per-Client GP", source)
        self.assertIn("Per-Staff GP", source)
        self.assertIn("Comp Ledger", source)
        self.assertIn("W2 Watch · Trailing 8-month window", source)
        self.assertIn("FC Trigger Queue · Live queue", source)

    def test_frontend_package_declares_profit_admin_app(self) -> None:
        package_path = ROOT / "app/frontend/package.json"
        source = package_path.read_text(encoding="utf-8")

        self.assertIn('"name": "outscore-profit-admin"', source)
        self.assertIn('"dev": "vite', source)
        self.assertIn('"react"', source)
        self.assertIn('"lucide-react"', source)

    def test_vite_config_supports_profit_subpath_deployments(self) -> None:
        config_path = ROOT / "app/frontend/vite.config.js"
        source = config_path.read_text(encoding="utf-8")

        self.assertIn("VITE_BASE_PATH", source)
        self.assertIn("proxy", source)


if __name__ == "__main__":
    unittest.main()
