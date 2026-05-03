from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ProfitAdminFrontendTests(unittest.TestCase):
    def test_react_admin_page_fetches_dashboard_snapshot_endpoint(self) -> None:
        dashboard_path = ROOT / "app/frontend/src/routes/Dashboard.jsx"
        source = dashboard_path.read_text(encoding="utf-8")

        self.assertIn("VITE_PROFIT_API_BASE", source)
        self.assertIn("/profit/admin/dashboard", source)
        self.assertIn("Company GP", source)
        self.assertIn("Prepaid Liability", source)
        self.assertIn("Prepaid Liability · point-in-time", source)
        self.assertIn("Collection feed not yet loaded", source)
        self.assertIn("Deferred Revenue JE not ready", source)
        self.assertIn("Tax Deferred Revenue", source)
        self.assertIn("Record this exact amount as Deferred Revenue in QuickBooks", source)
        self.assertIn("Record this as Deferred Revenue in QBO", source)
        self.assertIn("Trigger Backlog", source)
        self.assertIn("Total reference", source)
        self.assertIn("Do not record this as a single QBO entry", source)
        self.assertNotIn("Pending Triggers", source)
        self.assertIn("Clears when completion triggers are approved", source)
        self.assertNotIn("current total prepaid liability as the Deferred Revenue JE balance", source)
        self.assertIn("Prepaid Liability Drilldown", source)
        self.assertIn("/profit/admin/prepaid/balances", source)
        self.assertIn("SERVICE_CATEGORY_LABEL", source)
        self.assertIn('tax_deferred_revenue: "Tax Deferred"', source)
        self.assertIn('pending_recognition_trigger: "Trigger Backlog"', source)
        self.assertIn("All", source)
        self.assertIn("Tax Deferred", source)
        self.assertIn("service_category !== \"recognized\"", source)
        self.assertIn("setPrepaidFilter", source)
        self.assertIn("/profit/admin/prepaid/ledger", source)
        self.assertIn("Running balance", source)
        self.assertIn("source_payment_id", source)
        self.assertIn("revenue_event_key", source)
        self.assertIn("QBO journal entry reconciliation trail", source)
        self.assertIn("Company GP Trend", source)
        self.assertIn("Last 12 available months", source)
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
        self.assertIn("fcQueueCount", source)

    def test_manual_recognition_route_static_contract(self) -> None:
        app_path = ROOT / "app/frontend/src/App.jsx"
        nav_path = ROOT / "app/frontend/src/components/PortalNav.jsx"
        route_path = ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        app_source = app_path.read_text(encoding="utf-8")
        nav_source = nav_path.read_text(encoding="utf-8")
        route_source = route_path.read_text(encoding="utf-8")
        source = app_source + "\n" + nav_source + "\n" + route_source

        self.assertIn("/profit/admin/recognition", source)
        self.assertIn("Manual Recognition", source)
        self.assertIn("Use only when FC trigger cannot fire automatically", source)
        self.assertIn("All approvals are logged", source)
        self.assertIn("/profit/admin/recognition/pending", source)
        self.assertIn("/profit/admin/recognition/manual-override", source)
        self.assertIn("/profit/admin/recognition/manual-overrides", source)

        for reason_code in [
            "backbill_pre_engagement",
            "client_operational_change",
            "entity_restructure",
            "service_outside_fc_scope",
            "fc_classifier_gap",
            "voided_invoice_replacement",
            "billing_amount_adjustment",
            "other",
        ]:
            self.assertIn(reason_code, source)

        self.assertIn("selectedReason", source)
        self.assertIn("notes.trim()", source)
        self.assertIn("approveDisabled", source)
        self.assertIn("Cancel", source)
        self.assertIn('aria-label="Close"', source)
        self.assertIn("Escape", source)
        self.assertIn("Recent overrides", source)

    def test_app_uses_react_router(self) -> None:
        app_source = (ROOT / "app/frontend/src/App.jsx").read_text(encoding="utf-8")

        self.assertIn("react-router-dom", app_source)
        self.assertIn("BrowserRouter", app_source)
        self.assertIn("Routes", app_source)
        self.assertIn("Route", app_source)

    def test_portal_nav_includes_admin_links(self) -> None:
        nav_source = (
            ROOT / "app/frontend/src/components/PortalNav.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("Dashboard", nav_source)
        self.assertIn("Manual Recognition", nav_source)
        self.assertIn("NavLink", nav_source)
        self.assertIn("portal-nav-link-active", nav_source)

    def test_dashboard_extracted_to_own_route(self) -> None:
        self.assertTrue((ROOT / "app/frontend/src/routes/Dashboard.jsx").exists())

    def test_manual_recognition_route_includes_reason_legend(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("Work delivered before Anchor agreement was signed", route_source)
        self.assertIn(
            "Mid-engagement billing/structure/scope change broke recognition",
            route_source,
        )
        self.assertIn("Client split, merged, renamed, or moved entities", route_source)
        self.assertIn(
            "Service genuinely delivered but never tracked in FC",
            route_source,
        )
        self.assertIn(
            "FC task exists/completed, classifier did not recognize it",
            route_source,
        )
        self.assertIn(
            "Voided invoice replaced with another, recognition follows replacement",
            route_source,
        )
        self.assertIn("Credit/discount/extra charge needs override", route_source)
        self.assertIn(
            "Catch-all (requires 20+ characters of notes)",
            route_source,
        )

    def test_manual_recognition_route_defaults_tax_deferred_events_hidden(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("showTaxDeferred", route_source)
        self.assertIn("setShowTaxDeferred", route_source)
        self.assertIn("Show tax-deferred events", route_source)
        self.assertIn("Tax-deferred events are hidden by default", route_source)
        self.assertIn("Prefer FC trigger approval", route_source)
        self.assertIn('row.recognition_status !== "pending_tax_completion"', route_source)

    def test_manual_recognition_route_includes_consolidated_billing_help(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("sibling_event_count", route_source)
        self.assertIn("Consolidated", route_source)
        self.assertIn("Consolidated billing pattern", route_source)
        self.assertIn("revenue events live under the BILLED entity", route_source)

    def test_manual_recognition_route_includes_consolidated_tooltip(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "One of N revenue events under the same Anchor relationship",
            route_source,
        )
        self.assertIn("Match by source amount when recognizing", route_source)

    def test_manual_recognition_route_auto_expands_help_for_consolidated(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("sibling_event_count", route_source)
        self.assertIn("hasConsolidated", route_source)

    def test_manual_recognition_panel_shows_sibling_events(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("Sibling events", route_source)
        self.assertIn(
            "This event is part of a consolidated invoice",
            route_source,
        )

    def test_polish_friendly_status_labels(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("STATUS_LABEL", route_source)
        self.assertIn("Pending bookkeeping", route_source)
        self.assertIn("Tax deferred", route_source)
        self.assertIn("Recognized (FC)", route_source)
        self.assertIn("Recognized (manual)", route_source)

    def test_polish_short_key_helper(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("shortKey", route_source)

    def test_polish_no_back_to_dashboard_link(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertNotIn("Back to dashboard", route_source)

    def test_manual_recognition_filters_submit_on_enter(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("handleFilterKeyDown", route_source)
        self.assertIn('event.key === "Enter"', route_source)
        self.assertIn("onKeyDown={handleFilterKeyDown}", route_source)

    def test_manual_recognition_supports_sibling_batch_selection(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("checkedSiblingKeys", route_source)
        self.assertIn("manual-override-batch", route_source)
        self.assertIn("Approve and Recognize (", route_source)
        self.assertIn("disabled", route_source)

    def test_manual_recognition_has_friendly_toast_formatter(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("formatRecognitionToast", route_source)
        self.assertIn(
            "Recognized DVH Investing LLC tax (Apr 2026) for $350",
            route_source,
        )
        self.assertIn(
            "Recognized 3 events for DVH Investing LLC totaling $1,350",
            route_source,
        )

    def test_manual_recognition_hides_zero_amount_events_by_default(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/ManualRecognition.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("showZeroAmount", route_source)
        self.assertIn("setShowZeroAmount", route_source)
        self.assertIn("Show $0 and negative-amount events", route_source)
        self.assertIn("Number(row.source_amount ?? 0) > 0", route_source)
        self.assertIn("typically credit memos or adjustments", route_source)

    def test_frontend_package_declares_profit_admin_app(self) -> None:
        package_path = ROOT / "app/frontend/package.json"
        source = package_path.read_text(encoding="utf-8")

        self.assertIn('"name": "outscore-profit-admin"', source)
        self.assertIn('"dev": "vite', source)
        self.assertIn('"react"', source)
        self.assertIn('"lucide-react"', source)
        self.assertIn('"react-router-dom"', source)

    def test_vite_config_supports_profit_subpath_deployments(self) -> None:
        config_path = ROOT / "app/frontend/vite.config.js"
        source = config_path.read_text(encoding="utf-8")

        self.assertIn("VITE_BASE_PATH", source)
        self.assertIn("proxy", source)


if __name__ == "__main__":
    unittest.main()
