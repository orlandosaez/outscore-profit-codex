from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class N8nWorkflowTests(unittest.TestCase):
    def test_revenue_event_candidate_loader_uses_valid_supabase_filters(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-15-load-revenue-event-candidates.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        urls = [
            node.get("parameters", {}).get("url", "")
            for node in workflow["nodes"]
        ]

        self.assertTrue(
            any("profit_anchor_line_item_classifications" in url for url in urls)
        )
        self.assertFalse(
            any("q=not.is.null" in url for url in urls),
            "Supabase REST filters should name a real column, not a stray q parameter.",
        )

    def test_apply_recognition_triggers_workflow_reads_ready_view_and_updates_events(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-16-apply-recognition-triggers.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("profit_revenue_events_ready_for_recognition", serialized)
        self.assertIn("profit_revenue_events?on_conflict=revenue_event_key", serialized)
        self.assertIn("recognized_amount_to_apply", serialized)
        self.assertIn("recognized_by_completion_trigger", serialized)

    def test_load_fc_completion_triggers_workflow_writes_approved_triggers(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-19-load-fc-completion-triggers.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("profit_fc_completion_triggers_ready_to_load", serialized)
        self.assertIn("profit_recognition_triggers?on_conflict=recognition_trigger_key", serialized)
        self.assertIn("fc_task_id", serialized)
        self.assertIn("recognition_trigger_key", serialized)
        self.assertIn("financial_cents", serialized)

    def test_fc_completion_trigger_inspect_workflow_reads_candidate_views(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-20-fc-completion-trigger-inspect.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("profit_fc_client_anchor_match_candidates", serialized)
        self.assertIn("profit_fc_completion_trigger_candidates", serialized)
        self.assertIn("profit_fc_completion_triggers_ready_to_load", serialized)
        self.assertIn("byClientMatchStatus", serialized)
        self.assertIn("byTriggerLoadStatus", serialized)
        self.assertIn("readyToLoadCount", serialized)

    def test_fc_tax_filed_approval_workflow_only_approves_matched_tax_filed_tasks(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-21-approve-matched-fc-tax-filed-triggers.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("profit_fc_completion_trigger_candidates", serialized)
        self.assertIn("suggested_trigger_type=eq.tax_filed", serialized)
        self.assertIn("anchor_relationship_id=not.is.null", serialized)
        self.assertIn("approval_status=eq.pending", serialized)
        self.assertIn("profit_fc_task_trigger_approvals?on_conflict=fc_task_id", serialized)
        self.assertIn("approval_status: 'approved'", serialized)

    def test_comp_w2_inspect_workflow_reads_comp_and_w2_views(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-22-comp-w2-inspect.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("profit_company_quarterly_gp_gate", serialized)
        self.assertIn("profit_staff_monthly_kicker_accruals", serialized)
        self.assertIn("profit_staff_monthly_w2_conversion_flags", serialized)
        self.assertIn("quarterlyGateCount", serialized)
        self.assertIn("kickerAccrualCount", serialized)
        self.assertIn("w2FlagCount", serialized)

    def test_admin_dashboard_inspect_workflow_reads_dashboard_views(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-23-admin-dashboard-inspect.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("profit_admin_company_dashboard_summary", serialized)
        self.assertIn("profit_admin_client_gp_dashboard", serialized)
        self.assertIn("profit_admin_staff_gp_dashboard", serialized)
        self.assertIn("profit_admin_comp_kicker_ledger", serialized)
        self.assertIn("profit_admin_w2_candidates", serialized)
        self.assertIn("profit_admin_fc_trigger_queue", serialized)
        self.assertIn("clientGpRowCount", serialized)
        self.assertIn("staffGpRowCount", serialized)

    def test_financial_cents_sync_workflow_fetches_fc_resources_and_upserts_raw_tables(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-17-financial-cents-sync.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("https://app.financial-cents.com/api/v1/clients", serialized)
        self.assertIn("https://app.financial-cents.com/api/v1/projects", serialized)
        self.assertIn("https://app.financial-cents.com/api/v1/tasks", serialized)
        self.assertNotIn("order_by=updated_at", serialized)
        self.assertIn("profit_fc_clients?on_conflict=fc_client_id", serialized)
        self.assertIn("profit_fc_projects?on_conflict=fc_project_id", serialized)
        self.assertIn("profit_fc_tasks?on_conflict=fc_task_id", serialized)
        self.assertIn("Financial Cents API - Production", serialized)

    def test_financial_cents_sync_uses_bounded_pagination_and_flattens_pages(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-17-financial-cents-sync.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        nodes_by_name = {node["name"]: node for node in workflow["nodes"]}

        self.assertIn("Build FC Client Page Requests", nodes_by_name)
        self.assertIn("Build FC Project Page Requests", nodes_by_name)
        self.assertIn("Build Completed FC Task Page Requests", nodes_by_name)
        self.assertIn("Array.from({ length: maxPages }", json.dumps(nodes_by_name["Build FC Client Page Requests"]))
        self.assertIn("$json.page", nodes_by_name["Fetch FC Clients"]["parameters"]["url"])
        self.assertIn("$json.page", nodes_by_name["Fetch FC Projects"]["parameters"]["url"])
        self.assertIn("$json.page", nodes_by_name["Fetch Completed FC Tasks"]["parameters"]["url"])
        self.assertTrue(nodes_by_name["Fetch FC Clients"]["parameters"]["url"].startswith("={{"))
        self.assertTrue(nodes_by_name["Fetch FC Projects"]["parameters"]["url"].startswith("={{"))
        self.assertTrue(nodes_by_name["Fetch Completed FC Tasks"]["parameters"]["url"].startswith("={{"))
        self.assertIn("$input.all().flatMap", nodes_by_name["Map FC Clients"]["parameters"]["jsCode"])
        self.assertIn("$input.all().flatMap", nodes_by_name["Map FC Projects"]["parameters"]["jsCode"])
        self.assertIn("$input.all().flatMap", nodes_by_name["Map Completed FC Tasks"]["parameters"]["jsCode"])

        for node_name in ("Fetch FC Clients", "Fetch FC Projects", "Fetch Completed FC Tasks"):
            batching = nodes_by_name[node_name]["parameters"]["options"]["batching"]["batch"]
            self.assertLessEqual(batching["batchSize"], 10)
            self.assertGreaterEqual(batching["batchInterval"], 8000)

    def test_financial_cents_sync_collapses_supabase_upserts_before_next_fc_call(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-17-financial-cents-sync.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        connections = workflow["connections"]

        self.assertEqual(
            connections["Manual Trigger"]["main"][0][0]["node"],
            "Build FC Client Page Requests",
        )
        self.assertEqual(
            connections["Build FC Client Page Requests"]["main"][0][0]["node"],
            "Fetch FC Clients",
        )
        self.assertEqual(
            connections["Upsert FC Clients"]["main"][0][0]["node"],
            "Summarize FC Client Upsert",
        )
        self.assertEqual(
            connections["Summarize FC Client Upsert"]["main"][0][0]["node"],
            "Build FC Project Page Requests",
        )
        self.assertEqual(
            connections["Build FC Project Page Requests"]["main"][0][0]["node"],
            "Fetch FC Projects",
        )
        self.assertEqual(
            connections["Upsert FC Projects"]["main"][0][0]["node"],
            "Summarize FC Project Upsert",
        )
        self.assertEqual(
            connections["Summarize FC Project Upsert"]["main"][0][0]["node"],
            "Build Completed FC Task Page Requests",
        )
        self.assertEqual(
            connections["Build Completed FC Task Page Requests"]["main"][0][0]["node"],
            "Fetch Completed FC Tasks",
        )

    def test_financial_cents_inspect_workflow_reads_fc_sync_tables(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-18-financial-cents-sync-inspect.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("profit_fc_clients?select=fc_client_id", serialized)
        self.assertIn("profit_fc_projects?select=fc_project_id", serialized)
        self.assertIn("profit_fc_tasks?select=fc_task_id", serialized)
        self.assertIn("fcClientCount", serialized)

    def test_qbo_collection_loader_writes_cash_and_allocation_tables(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-24-qbo-collection-loader.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("quickbooks", serialized.lower())
        self.assertIn("profit_cash_collections?on_conflict=collection_key", serialized)
        self.assertIn("profit_collection_revenue_allocations?on_conflict=collection_key,revenue_event_key", serialized)
        self.assertIn("profit_anchor_invoices", serialized)
        self.assertIn("profit_revenue_events", serialized)
        self.assertIn("customer_amount_date_window", serialized)
        self.assertIn("rounding_delta", serialized)

    def test_qbo_collection_loader_collapses_batch_fetches_between_http_nodes(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-24-qbo-collection-loader.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        nodes_by_name = {node["name"]: node for node in workflow["nodes"]}
        connections = workflow["connections"]

        for node_name in (
            "Collapse Anchor Invoices",
            "Collapse Anchor Agreements",
            "Collapse Revenue Events",
            "Collapse Existing Allocations",
            "Collapse Cash Collection Upsert",
        ):
            self.assertIn(node_name, nodes_by_name)
            self.assertIn("first().json", nodes_by_name[node_name]["parameters"]["jsCode"])

        self.assertEqual(
            connections["Fetch Anchor Invoices"]["main"][0][0]["node"],
            "Collapse Anchor Invoices",
        )
        self.assertEqual(
            connections["Collapse Anchor Invoices"]["main"][0][0]["node"],
            "Fetch Anchor Agreements",
        )
        self.assertEqual(
            connections["Fetch Anchor Agreements"]["main"][0][0]["node"],
            "Collapse Anchor Agreements",
        )
        self.assertEqual(
            connections["Collapse Anchor Agreements"]["main"][0][0]["node"],
            "Fetch Revenue Events",
        )
        self.assertEqual(
            connections["Fetch Revenue Events"]["main"][0][0]["node"],
            "Collapse Revenue Events",
        )
        self.assertEqual(
            connections["Collapse Revenue Events"]["main"][0][0]["node"],
            "Fetch Existing Allocations",
        )
        self.assertEqual(
            connections["Fetch Existing Allocations"]["main"][0][0]["node"],
            "Collapse Existing Allocations",
        )
        self.assertEqual(
            connections["Collapse Existing Allocations"]["main"][0][0]["node"],
            "Build Cash Collections And Allocations",
        )
        self.assertEqual(
            connections["Upsert Cash Collections"]["main"][0][0]["node"],
            "Collapse Cash Collection Upsert",
        )
        self.assertEqual(
            connections["Collapse Cash Collection Upsert"]["main"][0][0]["node"],
            "Upsert Collection Allocations",
        )


if __name__ == "__main__":
    unittest.main()
