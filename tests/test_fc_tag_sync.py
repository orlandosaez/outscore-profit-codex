from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FinancialCentsTagSyncTests(unittest.TestCase):
    def test_workflow_17_syncs_client_level_service_and_group_tags_only(self) -> None:
        workflow = json.loads(
            (ROOT / "n8n/workflows/profit-17-financial-cents-sync.json").read_text(
                encoding="utf-8"
            )
        )
        serialized = json.dumps(workflow)

        self.assertIn(
            "profit_service_recognition_rules?select=service_name,fc_tag",
            serialized,
        )
        self.assertIn(
            "profit_fc_client_tags?on_conflict=fc_client_id,tag_name",
            serialized,
        )
        self.assertIn("'service'", serialized)
        self.assertIn("'group'", serialized)
        self.assertIn("/rest/v1/rpc/profit_refresh_client_groups", serialized)
        self.assertNotIn("profit_fc_project_tags?on_conflict", serialized)
        self.assertNotIn("profit_fc_task_tags?on_conflict", serialized)


if __name__ == "__main__":
    unittest.main()
