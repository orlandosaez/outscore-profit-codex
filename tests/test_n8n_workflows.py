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

    def test_fc_bookkeeping_complete_approval_workflow_only_approves_past_matched_tasks(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-22-approve-matched-fc-bookkeeping-complete-triggers.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertEqual(
            workflow["name"],
            "Profit - 22 Approve Matched FC Bookkeeping Complete Triggers",
        )
        self.assertIn("profit_fc_completion_trigger_candidates", serialized)
        self.assertIn("suggested_trigger_type=eq.bookkeeping_complete", serialized)
        self.assertIn("trigger_type=eq.bookkeeping_complete", serialized)
        self.assertIn("anchor_relationship_id=not.is.null", serialized)
        self.assertIn("macro_service_type=not.is.null", serialized)
        self.assertIn("service_period_month=lt.", serialized)
        self.assertIn("approval_status=eq.pending", serialized)
        self.assertIn("profit_fc_task_trigger_approvals?on_conflict=fc_task_id", serialized)
        self.assertIn("approval_status: 'approved'", serialized)
        self.assertIn("codex_conservative_bookkeeping_complete_loader", serialized)

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

    def test_anchor_agreements_sync_fetches_all_api_visible_statuses(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-05-anchor-agreements-sync.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("https://api.sayanchor.com/agreements?limit=100", serialized)
        self.assertNotIn("https://api.sayanchor.com/agreements?limit=50", serialized)
        self.assertNotIn("status=active", serialized)
        self.assertIn("display_status", serialized)
        self.assertIn("terminated_at", serialized)
        self.assertIn("status_synced_at", serialized)

    def test_financial_cents_sync_captures_fc_tags(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-17-financial-cents-sync.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn(
            "profit_fc_client_tags?on_conflict=fc_client_id,tag_name",
            serialized,
        )
        self.assertIn(
            "profit_service_recognition_rules?select=service_name,fc_tag",
            serialized,
        )
        self.assertIn("'service'", serialized)
        self.assertIn("'group'", serialized)
        self.assertIn(
            "/rest/v1/rpc/profit_refresh_client_groups",
            serialized,
        )

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

        # V0.7.G (046/047): Manual Trigger now routes through Start FC Sync Run
        # before page-request building. Start FC Sync Run captures sync_id +
        # prior_client_count via profit_fc_sync_start RPC for the stale-record
        # safety guard.
        self.assertEqual(
            connections["Manual Trigger"]["main"][0][0]["node"],
            "Start FC Sync Run",
        )
        self.assertEqual(
            connections["Start FC Sync Run"]["main"][0][0]["node"],
            "Build FC Client Page Requests",
        )
        self.assertEqual(
            connections["Build FC Client Page Requests"]["main"][0][0]["node"],
            "Fetch FC Clients",
        )
        # Summarize FC Sync now hands off to Complete FC Sync Run which calls
        # profit_fc_sync_complete RPC. The RPC auto-archives stale rows if
        # current count >= 90% of prior; otherwise marks safety_skipped.
        self.assertEqual(
            connections["Summarize FC Sync"]["main"][0][0]["node"],
            "Complete FC Sync Run",
        )
        nodes_by_name_v07g = {node["name"]: node for node in workflow["nodes"]}
        self.assertIn("Start FC Sync Run", nodes_by_name_v07g)
        self.assertIn("Complete FC Sync Run", nodes_by_name_v07g)
        self.assertIn(
            "profit_fc_sync_start",
            nodes_by_name_v07g["Start FC Sync Run"]["parameters"]["url"],
        )
        self.assertIn(
            "profit_fc_sync_complete",
            nodes_by_name_v07g["Complete FC Sync Run"]["parameters"]["url"],
        )
        self.assertEqual(
            connections["Upsert FC Clients"]["main"][0][0]["node"],
            "Summarize FC Client Upsert",
        )
        self.assertEqual(
            connections["Summarize FC Client Upsert"]["main"][0][0]["node"],
            "Fetch FC Service Tag Rules",
        )
        self.assertEqual(
            connections["Fetch FC Service Tag Rules"]["main"][0][0]["node"],
            "Map FC Client Tags",
        )
        self.assertEqual(
            connections["Map FC Client Tags"]["main"][0][0]["node"],
            "Has FC Client Tag Rows",
        )
        self.assertEqual(
            connections["Has FC Client Tag Rows"]["main"][0][0]["node"],
            "Upsert FC Client Tags",
        )
        self.assertEqual(
            connections["Has FC Client Tag Rows"]["main"][1][0]["node"],
            "Refresh Client Groups",
        )
        self.assertEqual(
            connections["Upsert FC Client Tags"]["main"][0][0]["node"],
            "Refresh Client Groups",
        )
        self.assertEqual(
            connections["Refresh Client Groups"]["main"][0][0]["node"],
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
        nodes_by_name = {node["name"]: node for node in workflow["nodes"]}

        self.assertIn("quickbooks", serialized.lower())
        self.assertIn("profit_cash_collections?on_conflict=collection_key", serialized)
        self.assertIn("profit_collection_revenue_allocations?on_conflict=collection_key,revenue_event_key", serialized)
        self.assertIn("profit_anchor_invoices", serialized)
        self.assertIn("profit_revenue_events", serialized)
        self.assertIn("customer_amount_date_window", serialized)
        self.assertIn("rounding_delta", serialized)
        self.assertEqual(
            nodes_by_name["Fetch QuickBooks Payments"]["credentials"]["quickBooksOAuth2Api"]["name"],
            "QBO - Outscore Firm Books (Production)",
        )

    def test_qbo_product_sync_loads_items_into_product_config(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-28-qbo-product-sync.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertIn("Profit - 28 QBO Product Sync", serialized)
        self.assertIn("Item", serialized)
        self.assertIn(
            "profit_qbo_product_services?on_conflict=qbo_product_id",
            serialized,
        )
        self.assertIn("qbo_product_id", serialized)
        self.assertIn("qbo_product_name", serialized)
        self.assertIn("qbo_category_path", serialized)
        self.assertIn("qbo_api_sync", serialized)
        self.assertIn("last_synced_at", serialized)

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
            "Has Allocation Rows",
        )
        self.assertEqual(
            connections["Has Allocation Rows"]["main"][0][0]["node"],
            "Upsert Collection Allocations",
        )

        self.assertEqual(
            connections["Has Allocation Rows"]["main"][1][0]["node"],
            "Summarize QBO Collection Load",
        )
        self.assertTrue(nodes_by_name["Fetch Existing Allocations"]["alwaysOutputData"])
        self.assertIn("allocationRows.length", json.dumps(nodes_by_name["Has Allocation Rows"]))
        self.assertIn(
            "if (!row.revenue_event_key) return acc;",
            nodes_by_name["Build Cash Collections And Allocations"]["parameters"]["jsCode"],
        )
        self.assertIn(
            "event.already_allocated_amount = allocationsByEvent[allocation.revenue_event_key];",
            nodes_by_name["Build Cash Collections And Allocations"]["parameters"]["jsCode"],
        )
        self.assertIn(
            "try {",
            nodes_by_name["Summarize QBO Collection Load"]["parameters"]["jsCode"],
        )

    def test_anchor_invoice_sync_captures_invoice_note_and_service_name(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-07-anchor-invoices-sync.json"
        workflow = workflow_path.read_text(encoding="utf-8")

        self.assertIn("invoice_note", workflow)
        self.assertIn("invoice.note", workflow)
        self.assertIn("service_name", workflow)
        self.assertIn("lineItem.name", workflow)

    def test_revenue_event_loader_carries_service_name(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-15-load-revenue-event-candidates.json"
        workflow = workflow_path.read_text(encoding="utf-8")

        self.assertIn("service_name", workflow)
        self.assertIn("profit_revenue_events", workflow)

    def test_fc_auto_match_workflow_only_upserts_auto_exact_client_matches(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)

        self.assertEqual(workflow["name"], "Profit - 25 Auto-Match FC Clients To Anchor")
        self.assertIn("profit_fc_client_anchor_match_candidates", serialized)
        self.assertIn("match_status=eq.auto_exact", serialized)
        self.assertIn("profit_fc_client_anchor_matches?on_conflict=fc_client_id", serialized)
        self.assertIn("resolution=merge-duplicates,return=representation", serialized)
        self.assertIn("match_status: 'auto_exact'", serialized)
        self.assertIn("match_method: 'auto_exact'", serialized)
        self.assertIn("match_method=eq.manual_override", serialized)
        self.assertIn("protectedManualOverrideCount", serialized)

    def test_fc_auto_match_workflow_reconciles_demoted_auto_exact_matches(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)
        nodes_by_name = {node["name"]: node for node in workflow["nodes"]}

        self.assertIn("/rest/v1/rpc/profit_reconcile_fc_client_anchor_matches", serialized)
        self.assertIn("Reconcile Demoted FC Client Anchor Matches", nodes_by_name)
        reconcile_node = nodes_by_name["Reconcile Demoted FC Client Anchor Matches"]
        self.assertEqual(json.loads(reconcile_node["parameters"]["jsonBody"]), {"p_dry_run": False})
        self.assertTrue(reconcile_node.get("continueOnFail"))
        self.assertIn("reconciledDemotedMatchCount", serialized)
        self.assertIn("reconcileStatus", serialized)
        self.assertIn("reconcileError", serialized)
        self.assertNotIn("profit_pipeline_run_steps", serialized)

    def test_pipeline_orchestration_workflow_runs_eight_sequential_steps(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-26-pipeline-orchestration.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)
        nodes_by_name = {node["name"]: node for node in workflow["nodes"]}

        self.assertEqual(workflow["name"], "Profit - 26 Pipeline Orchestration")
        webhook = nodes_by_name["Pipeline Run Webhook"]
        self.assertEqual(webhook["type"], "n8n-nodes-base.webhook")
        self.assertEqual(webhook["parameters"]["authentication"], "headerAuth")
        self.assertEqual(
            webhook["credentials"]["httpHeaderAuth"]["name"],
            "Profit Pipeline X-Profit-Pipeline-Secret",
        )
        self.assertIn(webhook["parameters"]["responseMode"], {"onReceived", "responseNode"})
        if webhook["parameters"]["responseMode"] == "responseNode":
            respond_node = nodes_by_name["Respond Pipeline Run Accepted"]
            self.assertEqual(respond_node["type"], "n8n-nodes-base.respondToWebhook")
            self.assertEqual(respond_node["parameters"]["respondWith"], "json")
            self.assertIn("accepted", respond_node["parameters"]["responseBody"])
        else:
            self.assertIn("accepted", json.dumps(webhook["parameters"]))
        self.assertIn("X-Profit-Pipeline-Secret", webhook["credentials"]["httpHeaderAuth"]["name"])
        self.assertNotIn("$env.PROFIT_PIPELINE_WEBHOOK_SECRET", serialized)

        expected_steps = [
            "anchor_agreement_sync",
            "anchor_invoice_revenue_sync",
            "qbo_collection_loader",
            "fc_completion_sync",
            "recognition_trigger_apply",
            "fc_anchor_match_refresh",
            "fulfillment_audit_refresh",
            "classification_transition_apply",
        ]
        for step_name in expected_steps:
            self.assertIn(step_name, serialized)
            self.assertIn(f"Start {step_name}", nodes_by_name)
            self.assertIn(f"Finish {step_name}", nodes_by_name)

        execute_nodes = [
            node for node in workflow["nodes"] if node["type"] == "n8n-nodes-base.executeWorkflow"
        ]
        execute_node_names = {node["name"] for node in execute_nodes}
        self.assertEqual(
            execute_node_names,
            {
                "W05 Anchor Agreement Sync",
                "W07 Anchor Invoice Sync",
                "W11 Classify Anchor Line Items",
                "W15 Load Revenue Events",
                "W24 QBO Collection Loader",
                "W17 Financial Cents Sync",
                "W21 Approve Tax Filed Triggers",
                "W22 Approve Bookkeeping Complete Triggers",
                "W19 Load FC Completion Triggers",
                "W16 Apply Recognition Triggers",
                "W25 FC Anchor Match Refresh",
            },
        )
        for node in execute_nodes:
            self.assertTrue(
                node.get("alwaysOutputData"),
                f"{node['name']} must emit an item even when its sub-workflow returns no rows.",
            )
        self.assertIn("W07 Anchor Invoice Sync", nodes_by_name)
        self.assertIn("W11 Classify Anchor Line Items", nodes_by_name)
        self.assertIn("W15 Load Revenue Events", nodes_by_name)
        self.assertIn("W17 Financial Cents Sync", nodes_by_name)
        self.assertIn("W21 Approve Tax Filed Triggers", nodes_by_name)
        self.assertIn("W22 Approve Bookkeeping Complete Triggers", nodes_by_name)
        self.assertIn("W19 Load FC Completion Triggers", nodes_by_name)

        self.assertIn("profit_pipeline_run_steps", serialized)
        self.assertIn("profit_pipeline_runs", serialized)
        self.assertIn("details.sub_workflows", serialized)
        self.assertIn("total_steps_completed", serialized)
        self.assertIn("total_steps_failed", serialized)
        self.assertIn("total_rows_affected", serialized)
        self.assertIn("steps 1-6 are hard dependencies", serialized)
        self.assertIn("steps 7-8 are soft dependencies", serialized)

        hard_steps = expected_steps[:6]
        for step_name in hard_steps:
            failure_node_name = f"Hard failure after {step_name}"
            self.assertIn(failure_node_name, nodes_by_name)
            self.assertEqual(nodes_by_name[failure_node_name]["type"], "n8n-nodes-base.if")
            failure_node_serialized = json.dumps(nodes_by_name[failure_node_name])
            self.assertIn(f"$('Finish {step_name}')", failure_node_serialized)
            self.assertNotIn("$json.last_step_status", failure_node_serialized)
            self.assertIn(
                "Finalize Pipeline Run Summary",
                json.dumps(workflow["connections"][failure_node_name]),
            )

        self.assertTrue(nodes_by_name["Run Inactive Reemergence Scan"].get("alwaysOutputData"))
        self.assertTrue(nodes_by_name["Apply Classification Transitions"].get("alwaysOutputData"))
        rpc_nodes = [
            node for node in workflow["nodes"]
            if node["type"] == "n8n-nodes-base.httpRequest"
            and "/rest/v1/rpc/" in node.get("parameters", {}).get("url", "")
        ]
        self.assertEqual(
            {node["name"] for node in rpc_nodes},
            {
                "Run Inactive Reemergence Scan",
                "Apply Classification Transitions",
                # V0.7.E.0.1 T4 — self-audit post-step calls profit_record_audit_summary
                # after the final status patch on every pipeline run.
                "Record Audit Summary",
            },
        )
        for node in rpc_nodes:
            # Record Audit Summary is a post-step (after Patch Pipeline Run Final Status);
            # it doesn't need alwaysOutputData because no downstream node depends on its
            # output. The two recognition/classification RPC nodes do need it.
            if node["name"] == "Record Audit Summary":
                continue
            self.assertTrue(
                node.get("alwaysOutputData"),
                f"{node['name']} must emit an item even when the RPC returns zero rows.",
            )

        finalize_node = nodes_by_name["Finalize Pipeline Run Summary"]
        finalize_code = finalize_node["parameters"]["jsCode"]
        for step_name in expected_steps:
            self.assertIn(f"Finish {step_name}", finalize_code)
        self.assertIn("Validate Pipeline Webhook Payload", finalize_code)
        self.assertNotIn("$input.first()", finalize_code)
        self.assertIn("Workflow 26 halted on a hard-step failure.", serialized)

        insert_step_nodes = [
            node for node in workflow["nodes"]
            if node["name"].startswith("Insert ") and node["name"].endswith(" Step")
        ]
        for insert_node in insert_step_nodes:
            step_name = insert_node["name"].removeprefix("Insert ").removesuffix(" Step")
            downstream = json.dumps(workflow["connections"].get(insert_node["name"], {}))
            self.assertIn("Finish " + step_name, serialized)
            self.assertNotEqual(downstream, "{}")

        terminal_nodes = [
            node["name"]
            for node in workflow["nodes"]
            if not workflow["connections"].get(node["name"], {}).get("main")
        ]
        # V0.7.E.0.1 T4 — "Record Audit Summary" is now the terminal node:
        # the audit RPC fires AFTER the final status patch on every pipeline run.
        self.assertEqual(terminal_nodes, ["Record Audit Summary"])

        for node in workflow["nodes"]:
            if node["type"] == "n8n-nodes-base.if":
                self.assertNotIn("$json.last_step_status", json.dumps(node))

    def test_schedule_wrapper_finalizes_stale_runs_before_nightly_cron_pipeline_start(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-29-schedule-wrapper.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        serialized = json.dumps(workflow)
        nodes_by_name = {node["name"]: node for node in workflow["nodes"]}

        self.assertEqual(workflow["name"], "Profit - 29 Schedule Wrapper")
        self.assertFalse(workflow["active"])

        schedule_node = nodes_by_name["Nightly 2 AM ET Schedule"]
        self.assertEqual(schedule_node["type"], "n8n-nodes-base.scheduleTrigger")
        schedule_parameters = schedule_node["parameters"]
        self.assertEqual(schedule_parameters["timezone"], "America/New_York")
        self.assertIn("0 2 * * *", json.dumps(schedule_parameters))

        self.assertIn("Finalize Stale Pipeline Runs", nodes_by_name)
        stale_rpc_node = nodes_by_name["Finalize Stale Pipeline Runs"]
        self.assertEqual(stale_rpc_node["type"], "n8n-nodes-base.httpRequest")
        stale_rpc_parameters = stale_rpc_node["parameters"]
        self.assertEqual(stale_rpc_parameters["method"], "POST")
        self.assertIn(
            "/rest/v1/rpc/profit_finalize_stale_pipeline_runs",
            stale_rpc_parameters["url"],
        )
        self.assertEqual(stale_rpc_parameters["contentType"], "json")
        self.assertEqual(stale_rpc_parameters["specifyBody"], "json")
        self.assertEqual(json.loads(stale_rpc_parameters["jsonBody"]), {})
        self.assertTrue(
            stale_rpc_node.get("continueOnFail"),
            "Stale cleanup must be best-effort so cron still starts on transient RPC failure.",
        )
        self.assertTrue(
            stale_rpc_node.get("alwaysOutputData"),
            "Stale cleanup must emit an item for the downstream cron API call.",
        )

        request_node = nodes_by_name["Start Cron Pipeline Run"]
        self.assertEqual(request_node["type"], "n8n-nodes-base.httpRequest")
        request_parameters = request_node["parameters"]
        self.assertEqual(request_parameters["method"], "POST")
        self.assertIn(
            "/api/profit/admin/audit/pipeline-runs",
            request_parameters["url"],
        )
        # 2026-05-18: switched from env-var expression to hardcoded URL.
        # Previous {{ $env.PROFIT_API_BASE_URL || ... }} pattern failed silently
        # for 9+ days because n8n blocks env var access in expressions by default.
        # Detected by "access to env vars denied" in execution logs; cron fired
        # every night at 06:00 UTC and immediately errored. Hardcoded localhost
        # URL bypasses that class of failure entirely.
        self.assertIn("/api/profit/admin/audit/pipeline-runs", request_parameters["url"])
        self.assertNotIn("$env", request_parameters["url"])
        self.assertEqual(request_parameters["contentType"], "json")
        self.assertEqual(request_parameters["specifyBody"], "json")
        self.assertEqual(
            json.loads(request_parameters["jsonBody"]),
            {"run_source": "cron", "triggered_by": "cron"},
        )

        self.assertEqual(
            workflow["connections"]["Nightly 2 AM ET Schedule"]["main"][0][0]["node"],
            "Finalize Stale Pipeline Runs",
        )
        self.assertEqual(
            workflow["connections"]["Finalize Stale Pipeline Runs"]["main"][0][0]["node"],
            "Start Cron Pipeline Run",
        )
        self.assertNotIn("profit-pipeline-run", serialized)
        self.assertIn("profit_finalize_stale_pipeline_runs", serialized)


if __name__ == "__main__":
    unittest.main()
