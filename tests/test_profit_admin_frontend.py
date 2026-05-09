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

    def test_audit_dashboard_route_shell_static_contract(self) -> None:
        app_path = ROOT / "app/frontend/src/App.jsx"
        nav_path = ROOT / "app/frontend/src/components/PortalNav.jsx"
        route_path = ROOT / "app/frontend/src/routes/AuditDashboard.jsx"
        app_source = app_path.read_text(encoding="utf-8")
        nav_source = nav_path.read_text(encoding="utf-8")

        self.assertTrue(route_path.exists())
        route_source = route_path.read_text(encoding="utf-8")
        source = app_source + "\n" + nav_source + "\n" + route_source

        self.assertIn("AuditDashboard", app_source)
        self.assertIn("/admin/audit", app_source)
        self.assertIn("Audit", nav_source)
        self.assertIn("Fulfillment Audit", route_source)
        self.assertIn("VITE_PROFIT_API_BASE", route_source)
        self.assertIn("/profit/admin/audit/candidates", route_source)
        self.assertIn("/profit/admin/audit/verdicts", route_source)

    def test_audit_dashboard_filters_table_and_verdict_map_static_contract(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/AuditDashboard.jsx"
        ).read_text(encoding="utf-8")
        styles_source = (ROOT / "app/frontend/src/styles.css").read_text(encoding="utf-8")

        self.assertIn("/profit/admin/audit/filter-options", route_source)
        self.assertIn('UNCLASSIFIED_VERDICT = "__UNCLASSIFIED__"', route_source)
        self.assertIn("verdictMap", route_source)
        self.assertIn("current_verdict_code", route_source)
        self.assertIn("Unknown verdict", route_source)
        self.assertIn("Unclassified", route_source)
        self.assertIn("show_all", route_source)
        self.assertIn("Showing", route_source)
        self.assertIn("service_tags", route_source)
        self.assertIn("estimated_annual_revenue", route_source)
        self.assertIn("group_names", route_source)
        self.assertIn("open_invoice_balance_amount", route_source)
        self.assertIn("re_evaluate_at", route_source)
        self.assertIn("filterOptions.staff.length > 0", route_source)
        self.assertIn("audit-table", route_source)
        self.assertIn(".audit-table", styles_source)
        self.assertNotIn("VERDICT_OPTIONS = [", route_source)

    def test_audit_dashboard_bulk_classify_and_error_static_contract(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/AuditDashboard.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("parseApiError", route_source)
        self.assertIn('kind: "validation"', route_source)
        self.assertIn('kind: "conflict"', route_source)
        self.assertIn("/profit/admin/audit/classifications", route_source)
        self.assertIn("crypto.randomUUID", route_source)
        self.assertIn("request_id", route_source)
        self.assertIn("classification_id_to_supersede", route_source)
        self.assertIn("new_verdict_code", route_source)
        self.assertIn("requiresNotes", route_source)
        self.assertIn('["mixed", "leak", "manual_review"]', route_source)
        self.assertIn("stripRequestPrefix", route_source)
        self.assertIn("req:", route_source)
        self.assertIn("setSelectedRows({})", route_source)
        self.assertIn("bulkRowError", route_source)
        self.assertIn("Row updated since you loaded it", route_source)

    def test_audit_dashboard_detail_and_diagnostics_static_contract(self) -> None:
        route_source = (
            ROOT / "app/frontend/src/routes/AuditDashboard.jsx"
        ).read_text(encoding="utf-8")

        self.assertIn("detailEndpoint", route_source)
        self.assertIn("/profit/admin/audit/qbo-category-gaps", route_source)
        self.assertIn("<details", route_source)
        self.assertIn("audit-detail-section", route_source)
        self.assertIn("Candidate summary", route_source)
        self.assertIn("Anchor signals", route_source)
        self.assertIn("Transition rules", route_source)
        self.assertIn("Classification history", route_source)
        self.assertIn("Recent service tasks", route_source)
        self.assertIn("No prior classifications", route_source)
        self.assertIn("classification_history_total_count", route_source)
        self.assertIn("classification_history_truncated", route_source)
        self.assertIn("Will auto-apply on next pipeline run", route_source)
        self.assertIn("auto_apply_enabled ?? rule.auto_apply_enabled_in_b2a", route_source)
        self.assertIn("Eligible — manual apply only", route_source)
        self.assertNotIn("V0.6.C will automate", route_source)
        self.assertIn("Not eligible:", route_source)
        self.assertIn("gap_origin", route_source)
        self.assertIn("qboCategoryGaps", route_source)

    def test_pipeline_frontend_surfaces_static_contract(self) -> None:
        app_source = (ROOT / "app/frontend/src/App.jsx").read_text(encoding="utf-8")
        nav_source = (
            ROOT / "app/frontend/src/components/PortalNav.jsx"
        ).read_text(encoding="utf-8")
        dashboard_source = (
            ROOT / "app/frontend/src/routes/Dashboard.jsx"
        ).read_text(encoding="utf-8")
        audit_source = (
            ROOT / "app/frontend/src/routes/AuditDashboard.jsx"
        ).read_text(encoding="utf-8")
        styles_source = (ROOT / "app/frontend/src/styles.css").read_text(encoding="utf-8")
        dialog_path = ROOT / "app/frontend/src/components/PipelineRefreshDialog.jsx"
        summary_path = ROOT / "app/frontend/src/components/PipelineStatusSummary.jsx"
        pipeline_path = ROOT / "app/frontend/src/routes/PipelineRuns.jsx"

        self.assertTrue(dialog_path.exists())
        self.assertTrue(summary_path.exists())
        self.assertTrue(pipeline_path.exists())
        dialog_source = dialog_path.read_text(encoding="utf-8")
        summary_source = summary_path.read_text(encoding="utf-8")
        pipeline_source = pipeline_path.read_text(encoding="utf-8")

        self.assertIn("/admin/pipeline", app_source)
        self.assertIn("/admin/pipeline/:pipelineRunId", app_source)
        self.assertIn("Pipeline", nav_source)
        for host_source in (dashboard_source, audit_source, pipeline_source):
            self.assertIn("PipelineRefreshDialog", host_source)
            self.assertIn("PipelineStatusSummary", host_source)

        self.assertIn('value={triggeredBy}', dialog_source)
        self.assertIn('useState("orlando")', dialog_source)
        self.assertIn("/profit/admin/audit/pipeline-runs", dialog_source)
        self.assertIn("useNavigate", dialog_source)
        self.assertIn("Pipeline already running", dialog_source)

        self.assertIn("setInterval", pipeline_source)
        self.assertIn("if (pipelineRunId &&", pipeline_source)
        self.assertIn("clearInterval", pipeline_source)
        self.assertIn("setInterval(loadRunDetail, 4000)", pipeline_source)
        self.assertIn("No pipeline runs to show. Trigger a manual refresh to start.", pipeline_source)
        self.assertIn("View details", pipeline_source)
        self.assertIn("details.sub_workflows", pipeline_source)
        self.assertIn("PIPELINE_STEP_LABELS", pipeline_source)
        self.assertIn("friendlyRunSummary", pipeline_source)
        self.assertIn("Show details", pipeline_source)
        self.assertIn("Show raw summary", pipeline_source)
        self.assertIn("Running step", pipeline_source)
        self.assertIn("of 8 —", pipeline_source)
        self.assertIn("Pipeline halted before any step ran", pipeline_source)
        self.assertIn("halted before further progress", pipeline_source)
        self.assertIn("halted at step", pipeline_source)
        self.assertNotIn("halted at step Unknown step", pipeline_source)
        self.assertIn("8 steps attempted", pipeline_source)
        self.assertIn("Steps Completed", pipeline_source)
        self.assertIn("Total Rows Affected", pipeline_source)
        self.assertNotIn("JSON.stringify(run.summary", pipeline_source)

        self.assertIn("Pipeline: No runs yet", summary_source)
        self.assertIn("No runs yet", dashboard_source)
        self.assertIn("No runs yet", audit_source)
        self.assertIn("pipeline-", dashboard_source + audit_source + pipeline_source + dialog_source + summary_source)
        self.assertIn(".pipeline-", styles_source)

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
