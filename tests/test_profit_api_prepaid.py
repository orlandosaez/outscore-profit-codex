from __future__ import annotations

import unittest
import os

from fastapi.testclient import TestClient

from profit_api.dashboard import AdminDashboardService

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")

from profit_api.app import create_app


class FakePrepaidReader:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str | int]]] = []

    def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
        self.calls.append((view_name, params))
        if view_name == "profit_prepaid_liability_balances":
            return [
                {
                    "anchor_relationship_id": "relationship-tax",
                    "anchor_client_business_name": "Tax Client LLC",
                    "service_category": "tax_deferred_revenue",
                    "macro_service_type": "tax",
                    "balance": 13517.29,
                    "last_updated": "2026-05-03T01:37:24+00:00",
                },
                {
                    "anchor_relationship_id": "relationship-bookkeeping",
                    "anchor_client_business_name": "Bookkeeping Client LLC",
                    "service_category": "pending_recognition_trigger",
                    "macro_service_type": "bookkeeping",
                    "balance": 61667.62,
                    "last_updated": "2026-05-03T01:37:24+00:00",
                },
            ]
        if view_name == "profit_prepaid_liability_ledger":
            return [
                {
                    "event_at": "2026-01-19",
                    "ledger_entry_type": "revenue_recognized",
                    "amount_delta": -4000,
                    "source_payment_id": None,
                    "revenue_event_key": "rev_paid",
                    "anchor_relationship_id": "relationship-bookkeeping",
                    "macro_service_type": "bookkeeping",
                },
                {
                    "event_at": "2025-12-18",
                    "ledger_entry_type": "cash_collected",
                    "amount_delta": 4000,
                    "source_payment_id": "1272",
                    "revenue_event_key": "rev_paid",
                    "anchor_relationship_id": "relationship-bookkeeping",
                    "macro_service_type": "bookkeeping",
                },
            ]
        return []


class ProfitApiPrepaidTests(unittest.TestCase):
    def test_prepaid_balances_reads_full_view_ordered_by_balance(self) -> None:
        reader = FakePrepaidReader()
        rows = AdminDashboardService(reader).prepaid_balances()

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["service_category"], "tax_deferred_revenue")
        self.assertEqual(
            reader.calls[0],
            (
                "profit_prepaid_liability_balances",
                {"order": "balance.desc,anchor_client_business_name.asc", "limit": 1000},
            ),
        )

    def test_prepaid_balances_endpoint_returns_rows(self) -> None:
        app = create_app(service=AdminDashboardService(FakePrepaidReader()))
        client = TestClient(app)

        response = client.get("/api/profit/admin/prepaid/balances")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json()["rows"][0]["anchor_client_business_name"],
            "Tax Client LLC",
        )

    def test_prepaid_ledger_filters_by_relationship_and_macro_service(self) -> None:
        reader = FakePrepaidReader()
        rows = AdminDashboardService(reader).prepaid_ledger(
            anchor_relationship_id="relationship-bookkeeping",
            macro_service_type="bookkeeping",
        )

        self.assertEqual(len(rows), 2)
        self.assertEqual(
            reader.calls[-1],
            (
                "profit_prepaid_liability_ledger",
                {
                    "anchor_relationship_id": "eq.relationship-bookkeeping",
                    "macro_service_type": "eq.bookkeeping",
                    "order": "event_at.desc,ledger_entry_type.asc",
                    "limit": 1000,
                },
            ),
        )

    def test_prepaid_ledger_endpoint_requires_params(self) -> None:
        app = create_app(service=AdminDashboardService(FakePrepaidReader()))
        client = TestClient(app)

        response = client.get("/api/profit/admin/prepaid/ledger")

        self.assertEqual(response.status_code, 422)

    def test_prepaid_ledger_endpoint_returns_rows(self) -> None:
        app = create_app(service=AdminDashboardService(FakePrepaidReader()))
        client = TestClient(app)

        response = client.get(
            "/api/profit/admin/prepaid/ledger",
            params={
                "anchor_relationship_id": "relationship-bookkeeping",
                "macro_service_type": "bookkeeping",
            },
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["rows"][0]["ledger_entry_type"], "revenue_recognized")


if __name__ == "__main__":
    unittest.main()
