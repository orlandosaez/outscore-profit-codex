from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DataReferencesDocsTests(unittest.TestCase):
    def test_data_references_readme_documents_canonical_artifacts(self) -> None:
        readme = (ROOT / "docs/data-references/README.md").read_text(encoding="utf-8")

        self.assertIn("canonical home for reference artifacts", readme)
        self.assertIn("anchor services.csv", readme)
        self.assertIn("Anchor service catalog with FC tag mapping", readme)
        self.assertIn("client-staff-assignments.xlsx", readme)
        self.assertIn("Per-client staff ownership matrix", readme)
        self.assertIn("qbo-product-services.csv", readme)
        self.assertIn("QBO product/service hierarchy export", readme)
        self.assertIn("sbc-profit-and-loss.csv", readme)
        self.assertIn("Reference P&L for company-level GP validation", readme)
        self.assertIn("kebab-case filenames", readme)
        self.assertIn("anchor services.csv is the historical exception", readme)
        self.assertIn("V0.6+ will replace Anchor and QBO files with live API syncs", readme)
        self.assertIn("Updating the seed when reference data changes", readme)
        self.assertIn("python3 scripts/generate_service_crosswalk_seed.py", readme)
        self.assertIn("commit the regenerated migration", readme)
        self.assertIn("re-apply", readme)

    def test_service_recognition_rules_document_fc_tag_column(self) -> None:
        doc = (ROOT / "docs/service-recognition-rules.md").read_text(encoding="utf-8")

        self.assertIn("FC tag", doc)
        self.assertIn("S BOOKA", doc)
        self.assertIn("S 1040A", doc)
        self.assertIn("S BILL", doc)
        self.assertIn("Shared umbrella tags", doc)

    def test_recognition_triggers_contract_documents_service_crosswalk(self) -> None:
        doc = (ROOT / "docs/data-contracts/recognition-triggers.md").read_text(encoding="utf-8")

        self.assertIn("V0.5.2.1 Service Crosswalk", doc)
        self.assertIn("fc_tag", doc)
        self.assertIn("qbo_category_path", doc)
        self.assertIn("qbo_product_name", doc)
        self.assertIn("Shared umbrella tags", doc)
        self.assertIn("profit_anchor_services_without_tag", doc)

    def test_fulfillment_classifications_contract_documents_audit_dashboard_api(self) -> None:
        contract = (
            ROOT / "docs/data-contracts/fulfillment-classifications.md"
        ).read_text(encoding="utf-8")
        tech_debt = (ROOT / "docs/tech-debt.md").read_text(encoding="utf-8")

        self.assertIn("Audit Dashboard API Conventions", contract)
        self.assertIn("__UNCLASSIFIED__", contract)
        self.assertIn("/api/profit/admin/audit/candidates", contract)
        self.assertIn("/api/profit/admin/audit/verdicts", contract)
        self.assertIn("/api/profit/admin/audit/filter-options", contract)
        self.assertIn("/api/profit/admin/audit/classifications", contract)
        self.assertIn("/api/profit/admin/audit/qbo-category-gaps", contract)
        self.assertIn("source_audit_file = 'manual:/profit/admin/audit'", contract)
        self.assertIn(
            "source_audit_row_hash = 'manual:<request_id>:<fc_client_id>'",
            contract,
        )
        self.assertIn("mixed", contract)
        self.assertIn("leak", contract)
        self.assertIn("manual_review", contract)
        self.assertIn("service-side rollback", contract)
        self.assertIn("no new SQL migrations or views", contract)
        self.assertIn("audit dashboard table omits staff primary/reviewer", contract)

        self.assertIn("Bulk classify uses service-side rollback", tech_debt)
        self.assertIn("Multi-user dashboard concurrency", tech_debt)
        self.assertIn("Audit dashboard table omits staff primary/reviewer column", tech_debt)
        self.assertIn("Detail panel service tasks omit assigned staff", tech_debt)
        self.assertIn("Frontend clears all row selection after successful bulk apply", tech_debt)

    def test_fulfillment_classifications_contract_documents_pipeline_backend(self) -> None:
        contract = (
            ROOT / "docs/data-contracts/fulfillment-classifications.md"
        ).read_text(encoding="utf-8")
        tech_debt = (ROOT / "docs/tech-debt.md").read_text(encoding="utf-8")
        glossary = (ROOT / "docs/operator-guides/pipeline-glossary.md").read_text(
            encoding="utf-8"
        )

        self.assertIn("Pipeline Run Log Schema", contract)
        self.assertIn("Pipeline Orchestration API", contract)
        self.assertIn("POST /api/profit/admin/audit/pipeline-runs", contract)
        self.assertIn("GET /api/profit/admin/audit/pipeline-runs/{pipeline_run_id}", contract)
        self.assertIn("Workflow 26 Run Log Semantics", contract)
        self.assertIn("Workflow 26 finalization reads named finish-node contexts", contract)
        self.assertIn("alwaysOutputData = true", contract)
        self.assertIn("Workflow 25 Standalone Run Behavior", contract)
        self.assertIn("Workflow 25 remains safe to trigger outside Workflow 26", contract)
        self.assertIn("Auto Apply Enabled Field Migration", contract)
        self.assertIn("auto_apply_enabled_in_b2a", contract)
        self.assertIn("Match Reconciliation", contract)
        self.assertIn("Apply Transitions V0.6.C.a", contract)
        self.assertIn(
            "Auto-transition correctness requires `profit_fc_client_anchor_matches.anchor_relationship_id`",
            contract,
        )
        self.assertIn("collected_at::timestamptz", contract)
        self.assertIn("Pipeline Diagnostic Views", contract)
        self.assertIn("profit_pipeline_classification_transition_blockers", contract)
        self.assertIn("profit_pipeline_due_reclassifications", contract)
        self.assertIn("profit_pipeline_stuck_recognition_triggers", contract)

        self.assertIn("Workflow 05 (Anchor agreement sync) hardcodes limit=50", tech_debt)
        self.assertIn("13 PENDING_SENT seeded classifications remain pending review", tech_debt)
        self.assertIn("not reproducible against current `/agreements?limit=100`", tech_debt)
        self.assertIn("Auto-transition apply skips classifications whose FC client has no persisted", tech_debt)
        self.assertIn("V0.6.C.a deploy executes `profit_reconcile_fc_client_anchor_matches(false)`", tech_debt)
        self.assertIn("SupabaseRestError was extended in V0.6.C.b", tech_debt)
        self.assertIn("Stuck pipeline run detection is deferred to V0.6.C.c", tech_debt)
        self.assertIn("Manual pipeline refresh accepts free-text `triggered_by`", tech_debt)
        self.assertIn("`auto_apply_enabled_in_b2a` in the detail endpoint", tech_debt)
        self.assertIn("Pipeline webhook calls can return `404`", tech_debt)
        self.assertIn("W16 (Profit - 16 Apply Recognition Triggers) fails when ready revenue events contain duplicate", tech_debt)
        self.assertIn("rev_ili-z27H4dSkcSnw-2ZSgPjyIuro3oO6s", tech_debt)
        self.assertIn("Pipeline UI uses technical terminology", tech_debt)

        self.assertIn("Pipeline Glossary", glossary)
        self.assertIn("Pipeline Steps", glossary)
        self.assertIn("Sub-workflow Code Reference", glossary)
        self.assertIn("Status Meanings", glossary)
        self.assertIn("Common Errors", glossary)
        self.assertIn("Field Glossary", glossary)
        self.assertIn("anchor_agreement_sync", glossary)
        self.assertIn("Pulls the latest list of Anchor agreements", glossary)
        self.assertIn("W05", glossary)
        self.assertIn("Profit - 05 Anchor Agreements Sync", glossary)
        self.assertIn("W16", glossary)
        self.assertIn("The service was not able to process your request", glossary)
        self.assertIn("duplicate `revenue_event_key`", glossary)
        self.assertIn("What To Do When A Run Fails", glossary)

    def test_sla_dashboard_contract_documents_v06d_operational_contracts(self) -> None:
        contract_path = ROOT / "docs/data-contracts/sla-dashboard.md"
        self.assertTrue(contract_path.exists())

        contract = contract_path.read_text(encoding="utf-8")
        tech_debt = (ROOT / "docs/tech-debt.md").read_text(encoding="utf-8")

        for state in (
            "on_track",
            "at_risk",
            "breached",
            "waiting_on_client",
            "not_applicable",
        ):
            self.assertIn(state, contract)

        self.assertIn(
            "age_days >= greatest(target_sla_day - 2, ceil(target_sla_day * 0.8))",
            contract,
        )
        self.assertIn("SQL", contract)
        self.assertIn("canonical", contract)
        self.assertIn("task assignee", contract)
        self.assertIn("client staff tags", contract)
        self.assertIn("90-day", contract)
        self.assertTrue(
            "fixed" in contract.lower() or "no parameterization" in contract.lower()
        )
        self.assertIn("/api/profit/admin/sla/backfill", contract)
        self.assertIn("SETTLED_VIA_QUICKBOOKS_PAYMENT", contract)
        self.assertIn("read-only", contract)

        self.assertIn(
            "W16 (Profit - 16 Apply Recognition Triggers) fails when ready revenue events contain duplicate",
            tech_debt,
        )
        self.assertIn("default_sla_day", tech_debt)
        self.assertIn("Recognized tile drill-down", tech_debt)
        self.assertIn('"Reviewed" tracking on review checklist', tech_debt)
        self.assertIn("Per-tile staleness badges", tech_debt)
        self.assertIn("Audit page service-tag density redesign", tech_debt)
        self.assertIn("Frontend test infrastructure", tech_debt)
        self.assertIn("Manual Recognition UI polish", tech_debt)


    def test_weekly_review_contract_documents_v07a_queue_semantics(self) -> None:
        contract_path = ROOT / "docs/data-contracts/weekly-review.md"
        self.assertTrue(contract_path.exists(), "docs/data-contracts/weekly-review.md must exist")

        contract = contract_path.read_text(encoding="utf-8")

        # Core tables and views
        self.assertIn("profit_weekly_review_item_state", contract)
        self.assertIn("profit_weekly_review_items", contract)

        # UI interaction semantics
        self.assertIn("Snooze 7 days", contract)
        self.assertIn("Show reviewed", contract)

        # V0.7.A verdict registered
        self.assertIn("MANUAL_INVOICE_PENDING", contract)

        # practice_id deferred
        self.assertIn("practice_id", contract)
        self.assertIn("V0.7.E", contract)


if __name__ == "__main__":
    unittest.main()
