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


if __name__ == "__main__":
    unittest.main()
