"""Unit tests for V0.7.E.0.1 T1 — DataQualityService + API routes."""

from __future__ import annotations

import os
import unittest

from fastapi.testclient import TestClient

from profit_api.data_quality import (
    DataQualityService,
    DataQualityValidationError,
)

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")


SAMPLE_ROWS = [
    {
        "alert_category": "paid_anchor_invoice_not_cleared",
        "severity": "high",
        "subject_kind": "service_line",
        "subject_id": "relationship-abc:1040 Plus",
        "subject_name": "LTI Associates Inc.",
        "fc_client_id": 1234,
        "anchor_relationship_id": "relationship-abc",
        "description": "SLA breached but paid invoice matches.",
        "action_url": "https://app.sayanchor.com/...",
        "detected_at": "2026-05-13T18:00:00Z",
    },
    {
        "alert_category": "anchor_no_fc_match",
        "severity": "medium",
        "subject_kind": "anchor_agreement",
        "subject_id": "relationship-xyz",
        "subject_name": "Anderson Kool Air LLC",
        "fc_client_id": None,
        "anchor_relationship_id": "relationship-xyz",
        "description": "Active Anchor agreement has no FC client match.",
        "action_url": "https://app.sayanchor.com/...",
        "detected_at": "2026-05-13T18:00:00Z",
    },
    {
        "alert_category": "anchor_no_fc_match",
        "severity": "medium",
        "subject_kind": "anchor_agreement",
        "subject_id": "relationship-def",
        "subject_name": "B&B Technology Solutions",
        "fc_client_id": None,
        "anchor_relationship_id": "relationship-def",
        "description": "Active Anchor agreement has no FC client match.",
        "action_url": "https://app.sayanchor.com/...",
        "detected_at": "2026-05-13T18:00:00Z",
    },
    {
        "alert_category": "client_match_suspected_dup_or_gap",
        "severity": "medium",
        "subject_kind": "fc_client",
        "subject_id": "L.1:2426001",
        "subject_name": "Anderson Kool Air LLC-1",
        "fc_client_id": 2426001,
        "anchor_relationship_id": None,
        "description": "L.1 FC client Anderson Kool Air LLC-1 looks like an auto-dedup of an existing record.",
        "action_url": "https://app.financial-cents.com/clients/2426001",
        "detected_at": "2026-05-23T18:00:00Z",
    },
    {
        "alert_category": "client_match_suspected_dup_or_gap",
        "severity": "medium",
        "subject_kind": "client_match_candidate",
        "subject_id": "L.2:2426002:relationship-bachert",
        "subject_name": "The Bachert Law Firm PA <> Bachert Law Firm",
        "fc_client_id": 2426002,
        "anchor_relationship_id": "relationship-bachert",
        "description": "L.2 FC The Bachert Law Firm PA and Anchor Bachert Law Firm look like the same client (similarity 0.89).",
        "action_url": "https://app.sayanchor.com/home/relationship/relationship-bachert/agreement",
        "detected_at": "2026-05-23T18:00:00Z",
    },
    {
        "alert_category": "client_match_suspected_dup_or_gap",
        "severity": "medium",
        "subject_kind": "anchor_agreement",
        "subject_id": "L.3:relationship-gap",
        "subject_name": "Unlinked Anchor Client LLC",
        "fc_client_id": None,
        "anchor_relationship_id": "relationship-gap",
        "description": "L.3 Anchor agreement relationship-gap for Unlinked Anchor Client LLC has no FC client link.",
        "action_url": "https://app.sayanchor.com/home/relationship/relationship-gap/agreement",
        "detected_at": "2026-05-23T18:00:00Z",
    },
]


class FakeStore:
    def __init__(self, rows: list[dict[str, object]]) -> None:
        self.rows = rows
        self.read_calls: list[tuple[str, dict[str, object]]] = []

    def read_view(self, view_name: str, **params: object) -> list[dict[str, object]]:
        self.read_calls.append((view_name, dict(params)))
        rows = [dict(row) for row in self.rows]
        for key, value in params.items():
            if isinstance(value, str) and value.startswith("eq."):
                expected = value.removeprefix("eq.")
                rows = [row for row in rows if str(row.get(key)) == expected]
        offset = int(params.get("offset") or 0)
        limit = params.get("limit")
        if limit is not None:
            rows = rows[offset : offset + int(limit)]
        elif offset:
            rows = rows[offset:]
        return rows


class DataQualityServiceTests(unittest.TestCase):
    def test_list_alerts_returns_normalized_payloads(self) -> None:
        store = FakeStore(SAMPLE_ROWS)
        service = DataQualityService(store)

        result = service.list_alerts()

        self.assertEqual(len(result["rows"]), 6)
        first = result["rows"][0]
        self.assertEqual(first["alert_category"], "paid_anchor_invoice_not_cleared")
        self.assertEqual(first["severity"], "high")
        # Confirm the view query went through with default ordering
        self.assertEqual(store.read_calls[0][0], "profit_data_quality_alerts")
        self.assertIn("order", store.read_calls[0][1])

    def test_list_alerts_severity_filter(self) -> None:
        store = FakeStore(SAMPLE_ROWS)
        service = DataQualityService(store)

        result = service.list_alerts(severity="medium")

        self.assertEqual(len(result["rows"]), 5)
        for row in result["rows"]:
            self.assertEqual(row["severity"], "medium")

    def test_list_alerts_category_filter(self) -> None:
        store = FakeStore(SAMPLE_ROWS)
        service = DataQualityService(store)

        result = service.list_alerts(category="anchor_no_fc_match")

        self.assertEqual(len(result["rows"]), 2)

    def test_list_alerts_rejects_invalid_severity(self) -> None:
        service = DataQualityService(FakeStore(SAMPLE_ROWS))
        with self.assertRaises(DataQualityValidationError):
            service.list_alerts(severity="urgent")

    def test_summary_counts_by_severity_and_category(self) -> None:
        service = DataQualityService(FakeStore(SAMPLE_ROWS))

        result = service.summary()

        self.assertEqual(result["total"], 6)
        self.assertEqual(result["audit_status"], "critical")
        self.assertEqual(result["by_severity"], {"high": 1, "medium": 5, "low": 0})
        self.assertEqual(
            result["by_category"],
            {
                "client_match_suspected_dup_or_gap": 3,
                "anchor_no_fc_match": 2,
                "paid_anchor_invoice_not_cleared": 1,
            },
        )

    def test_summary_clean_when_empty(self) -> None:
        service = DataQualityService(FakeStore([]))
        result = service.summary()
        self.assertEqual(result["audit_status"], "clean")
        self.assertEqual(result["total"], 0)

    def test_summary_alerts_when_only_medium(self) -> None:
        service = DataQualityService(FakeStore(SAMPLE_ROWS[1:]))  # both medium
        result = service.summary()
        self.assertEqual(result["audit_status"], "alerts")


class DataQualityRoutesTests(unittest.TestCase):
    def _build_client(self, rows: list[dict[str, object]]) -> TestClient:
        from profit_api.app import create_app

        store = FakeStore(rows)
        service = DataQualityService(store)
        app = create_app(data_quality_service=service)
        return TestClient(app)

    def test_get_alerts_returns_rows(self) -> None:
        client = self._build_client(SAMPLE_ROWS)
        response = client.get("/api/profit/admin/data-quality-alerts")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()["rows"]), 6)

    def test_get_alerts_with_severity_filter(self) -> None:
        client = self._build_client(SAMPLE_ROWS)
        response = client.get(
            "/api/profit/admin/data-quality-alerts?severity=medium"
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()["rows"]), 5)

    def test_get_alerts_rejects_invalid_severity(self) -> None:
        client = self._build_client(SAMPLE_ROWS)
        response = client.get(
            "/api/profit/admin/data-quality-alerts?severity=urgent"
        )
        self.assertEqual(response.status_code, 422)

    def test_get_summary(self) -> None:
        client = self._build_client(SAMPLE_ROWS)
        response = client.get(
            "/api/profit/admin/data-quality-alerts/summary"
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["total"], 6)
        self.assertEqual(body["audit_status"], "critical")

    def test_client_match_category_snapshots_l1_l2_l3_shape(self) -> None:
        service = DataQualityService(FakeStore(SAMPLE_ROWS))

        result = service.list_alerts(category="client_match_suspected_dup_or_gap")

        self.assertEqual(
            [row["subject_id"] for row in result["rows"]],
            [
                "L.1:2426001",
                "L.2:2426002:relationship-bachert",
                "L.3:relationship-gap",
            ],
        )
        self.assertEqual(
            {row["alert_category"] for row in result["rows"]},
            {"client_match_suspected_dup_or_gap"},
        )
        self.assertIn("auto-dedup", str(result["rows"][0]["description"]))
        self.assertIn("similarity 0.89", str(result["rows"][1]["description"]))
        self.assertIn("has no FC client link", str(result["rows"][2]["description"]))


if __name__ == "__main__":
    unittest.main()
