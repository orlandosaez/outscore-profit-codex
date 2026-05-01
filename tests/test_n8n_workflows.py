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

    def test_financial_cents_sync_collapses_supabase_upserts_before_next_fc_call(self) -> None:
        workflow_path = ROOT / "n8n/workflows/profit-17-financial-cents-sync.json"
        workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
        connections = workflow["connections"]

        self.assertEqual(
            connections["Upsert FC Clients"]["main"][0][0]["node"],
            "Summarize FC Client Upsert",
        )
        self.assertEqual(
            connections["Summarize FC Client Upsert"]["main"][0][0]["node"],
            "Fetch FC Projects",
        )
        self.assertEqual(
            connections["Upsert FC Projects"]["main"][0][0]["node"],
            "Summarize FC Project Upsert",
        )
        self.assertEqual(
            connections["Summarize FC Project Upsert"]["main"][0][0]["node"],
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


if __name__ == "__main__":
    unittest.main()
