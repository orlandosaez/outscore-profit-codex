"""Unit tests for V0.7.E.3 — SubscriptionReserveService + API routes."""

from __future__ import annotations

import os
import unittest

from fastapi.testclient import TestClient

from profit_api.subscription_reserve import (
    SubscriptionReserveService,
    SubscriptionReserveValidationError,
)

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")


SAMPLE_ROWS = [
    {
        "anchor_relationship_id": "rel-001",
        "fc_client_id": 100,
        "client_name": "Collectiv LLC",
        "anchor_business_name": "Collectiv Inc.",
        "engagement_type": "Subscription",
        "recurring_service_count": 1,
        "monthly_subscription_fee": 4000.00,
        "last_90d_labor_cost": 2040.00,
        "monthly_avg_labor_cost": 680.00,
        "last_90d_hours": 127.5,
        "monthly_contribution_margin": 3320.00,
        "monthly_contribution_margin_pct": 83.0,
        "profitability_state": "profitable",
        "distinct_staff": 1,
        "last_entry_date": "2026-05-13",
    },
    {
        "anchor_relationship_id": "rel-002",
        "fc_client_id": 200,
        "client_name": "Overbudget Inc",
        "anchor_business_name": "Overbudget Inc",
        "engagement_type": "Mixed",
        "recurring_service_count": 2,
        "monthly_subscription_fee": 500.00,
        "last_90d_labor_cost": 2100.00,
        "monthly_avg_labor_cost": 700.00,
        "last_90d_hours": 15.0,
        "monthly_contribution_margin": -200.00,
        "monthly_contribution_margin_pct": -40.0,
        "profitability_state": "overbudget",
        "distinct_staff": 2,
        "last_entry_date": "2026-05-10",
    },
    {
        "anchor_relationship_id": "rel-003",
        "fc_client_id": 300,
        "client_name": "Dormant Co",
        "anchor_business_name": "Dormant Co",
        "engagement_type": "Mixed",
        "recurring_service_count": 1,
        "monthly_subscription_fee": 1000.00,
        "last_90d_labor_cost": 0,
        "monthly_avg_labor_cost": 0,
        "last_90d_hours": 0,
        "monthly_contribution_margin": 1000.00,
        "monthly_contribution_margin_pct": 100.0,
        "profitability_state": "no_labor_recorded",
        "distinct_staff": None,
        "last_entry_date": None,
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


class SubscriptionReserveServiceTests(unittest.TestCase):
    def test_list_clients_returns_payloads(self) -> None:
        service = SubscriptionReserveService(FakeStore(SAMPLE_ROWS))
        result = service.list_clients()
        self.assertEqual(len(result["rows"]), 3)
        self.assertEqual(result["rows"][0]["client_name"], "Collectiv LLC")

    def test_state_filter(self) -> None:
        service = SubscriptionReserveService(FakeStore(SAMPLE_ROWS))
        result = service.list_clients(state="overbudget")
        self.assertEqual(len(result["rows"]), 1)
        self.assertEqual(result["rows"][0]["profitability_state"], "overbudget")

    def test_engagement_type_filter(self) -> None:
        service = SubscriptionReserveService(FakeStore(SAMPLE_ROWS))
        result = service.list_clients(engagement_type="Mixed")
        self.assertEqual(len(result["rows"]), 2)

    def test_invalid_state_rejected(self) -> None:
        service = SubscriptionReserveService(FakeStore(SAMPLE_ROWS))
        with self.assertRaises(SubscriptionReserveValidationError):
            service.list_clients(state="bad")

    def test_summary_aggregates_correctly(self) -> None:
        service = SubscriptionReserveService(FakeStore(SAMPLE_ROWS))
        s = service.summary()
        self.assertEqual(s["client_count"], 3)
        self.assertEqual(s["total_monthly_subscription_fee"], 5500.00)
        self.assertEqual(s["total_monthly_avg_labor_cost"], 1380.00)
        self.assertEqual(s["total_monthly_contribution_margin"], 4120.00)
        # 4120 / 5500 = 74.9%
        self.assertEqual(s["aggregate_margin_pct"], 74.9)
        self.assertEqual(s["by_state"]["overbudget"], 1)
        self.assertEqual(s["by_state"]["profitable"], 1)
        self.assertEqual(s["by_state"]["no_labor_recorded"], 1)
        self.assertEqual(s["by_engagement_type"]["Mixed"], 2)
        self.assertEqual(s["by_engagement_type"]["Subscription"], 1)


class SubscriptionReserveRoutesTests(unittest.TestCase):
    def _client(self, rows: list[dict[str, object]]) -> TestClient:
        from profit_api.app import create_app

        service = SubscriptionReserveService(FakeStore(rows))
        app = create_app(subscription_reserve_service=service)
        return TestClient(app)

    def test_list_endpoint(self) -> None:
        c = self._client(SAMPLE_ROWS)
        r = c.get("/api/profit/admin/subscription-reserve")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()["rows"]), 3)

    def test_list_state_filter(self) -> None:
        c = self._client(SAMPLE_ROWS)
        r = c.get("/api/profit/admin/subscription-reserve?state=overbudget")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()["rows"]), 1)

    def test_list_invalid_state_returns_422(self) -> None:
        c = self._client(SAMPLE_ROWS)
        r = c.get("/api/profit/admin/subscription-reserve?state=bogus")
        self.assertEqual(r.status_code, 422)

    def test_summary_endpoint(self) -> None:
        c = self._client(SAMPLE_ROWS)
        r = c.get("/api/profit/admin/subscription-reserve/summary")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["client_count"], 3)
        self.assertEqual(body["total_monthly_subscription_fee"], 5500.00)


if __name__ == "__main__":
    unittest.main()
