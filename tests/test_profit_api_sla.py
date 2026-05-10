from __future__ import annotations

import os
import unittest

from fastapi.testclient import TestClient

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")


class FakeSlaStore:
    def __init__(self, rows_by_view: dict[str, list[dict[str, object]]]) -> None:
        self.rows_by_view = rows_by_view
        self.read_calls: list[tuple[str, dict[str, object]]] = []
        self.write_calls: list[str] = []

    def read_view(self, view_name: str, **params: object) -> list[dict[str, object]]:
        self.read_calls.append((view_name, params))
        rows = [dict(row) for row in self.rows_by_view.get(view_name, [])]
        offset = int(params.get("offset") or 0)
        limit = params.get("limit")
        if limit is not None:
            return rows[offset : offset + int(limit)]
        if offset:
            return rows[offset:]
        return rows

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        self.write_calls.append(f"insert:{table_name}")
        raise AssertionError("SLA endpoints must not write")

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        self.write_calls.append(f"patch:{table_name}")
        raise AssertionError("SLA endpoints must not write")

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
    ) -> list[dict[str, object]]:
        self.write_calls.append(f"delete:{table_name}")
        raise AssertionError("SLA endpoints must not write")


class FakeDashboardService:
    pass


class FakeRecognitionService:
    pass


class FakeAuditService:
    pass


class FakePipelineService:
    pass


class SlaDashboardApiTests(unittest.TestCase):
    def build_client(
        self,
        rows_by_view: dict[str, list[dict[str, object]]],
    ) -> tuple[TestClient, FakeSlaStore]:
        from profit_api.sla import SlaDashboardService
        import profit_api.app as app_module

        store = FakeSlaStore(rows_by_view)
        service = SlaDashboardService(store)
        app = app_module.create_app(
            service=FakeDashboardService(),
            manual_recognition_service=FakeRecognitionService(),
            audit_service=FakeAuditService(),
            pipeline_service=FakePipelineService(),
            sla_service=service,
        )
        return TestClient(app), store

    def test_summary_endpoint_returns_state_counts_from_client_status(self) -> None:
        client, store = self.build_client(
            {
                "profit_sla_client_status": [
                    {"fc_client_id": 1, "sla_state": "breached"},
                    {"fc_client_id": 2, "sla_state": "at_risk"},
                    {"fc_client_id": 3, "sla_state": "on_track"},
                    {"fc_client_id": 4, "sla_state": "waiting_on_client"},
                    {"fc_client_id": 5, "sla_state": "not_applicable"},
                    {"fc_client_id": 6, "sla_state": "breached"},
                ]
            }
        )

        response = client.get("/api/profit/admin/sla/summary")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(
            response.json(),
            {
                "total_clients": 6,
                "states": {
                    "on_track": 1,
                    "at_risk": 1,
                    "breached": 2,
                    "waiting_on_client": 1,
                    "not_applicable": 1,
                },
            },
        )
        self.assertEqual(store.read_calls[0][0], "profit_sla_client_status")

    def test_clients_endpoint_returns_client_status_rows(self) -> None:
        client, store = self.build_client(
            {
                "profit_sla_client_status": [
                    {
                        "fc_client_id": 1,
                        "fc_client_name": "Feig Client",
                        "sla_state": "breached",
                        "service_count": 2,
                    }
                ]
            }
        )

        response = client.get("/api/profit/admin/sla/clients?state=breached")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["rows"][0]["fc_client_name"], "Feig Client")
        self.assertEqual(response.json()["limit"], 50)
        self.assertEqual(response.json()["offset"], 0)
        self.assertEqual(store.read_calls[0][0], "profit_sla_client_status")

    def test_workload_endpoint_returns_staff_workload_rows(self) -> None:
        client, store = self.build_client(
            {
                "profit_sla_staff_workload": [
                    {
                        "assigned_staff_name": "Laura",
                        "open_count": 8,
                        "breached_count": 1,
                    }
                ]
            }
        )

        response = client.get("/api/profit/admin/sla/workload?staff=Laura")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["rows"][0]["assigned_staff_name"], "Laura")
        self.assertEqual(response.json()["rows"][0]["open_count"], 8)
        self.assertEqual(store.read_calls[0][0], "profit_sla_staff_workload")

    def test_queue_endpoint_returns_breach_queue_rows(self) -> None:
        client, store = self.build_client(
            {
                "profit_sla_breach_queue": [
                    {
                        "fc_client_id": 1,
                        "service_name": "Accounting Advanced",
                        "assigned_staff_name": "Laura",
                        "sla_state": "at_risk",
                    }
                ]
            }
        )

        response = client.get(
            "/api/profit/admin/sla/queue?service=Accounting%20Advanced"
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["rows"][0]["service_name"], "Accounting Advanced")
        self.assertEqual(store.read_calls[0][0], "profit_sla_breach_queue")

    def test_performance_endpoint_returns_fixed_90_day_rows(self) -> None:
        client, store = self.build_client(
            {
                "profit_sla_staff_service_performance_90d": [
                    {
                        "staff_name": "Laura",
                        "service_name": "Accounting Advanced",
                        "total_completed": 12,
                        "breach_rate": "0.0833",
                    }
                ]
            }
        )

        response = client.get("/api/profit/admin/sla/performance")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["window_days"], 90)
        self.assertEqual(response.json()["rows"][0]["staff_name"], "Laura")
        self.assertEqual(
            store.read_calls[0][0],
            "profit_sla_staff_service_performance_90d",
        )

    def test_backfill_endpoint_returns_anchor_backfill_rows(self) -> None:
        client, store = self.build_client(
            {
                "profit_sla_anchor_backfill_queue": [
                    {
                        "classification_id": 100,
                        "fc_client_name": "Legacy Client",
                        "verdict_code": "SETTLED_VIA_QUICKBOOKS_PAYMENT",
                        "auto_transition_eligible": True,
                    }
                ]
            }
        )

        response = client.get("/api/profit/admin/sla/backfill")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["rows"][0]["classification_id"], 100)
        self.assertEqual(store.read_calls[0][0], "profit_sla_anchor_backfill_queue")

    def test_invalid_state_filter_returns_422(self) -> None:
        client, _store = self.build_client({"profit_sla_client_status": []})

        response = client.get("/api/profit/admin/sla/clients?state=bogus")

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["detail"]["field"], "state")

    def test_invalid_staff_filter_returns_422_when_not_present(self) -> None:
        client, _store = self.build_client(
            {
                "profit_sla_staff_workload": [
                    {"assigned_staff_name": "Laura", "open_count": 4}
                ]
            }
        )

        response = client.get("/api/profit/admin/sla/workload?staff=Beth")

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["detail"]["field"], "staff")

    def test_invalid_service_filter_returns_422_when_not_present(self) -> None:
        client, _store = self.build_client(
            {
                "profit_sla_breach_queue": [
                    {"service_name": "Accounting Advanced", "sla_state": "breached"}
                ]
            }
        )

        response = client.get("/api/profit/admin/sla/queue?service=Payroll")

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["detail"]["field"], "service")

    def test_limit_and_offset_are_clamped(self) -> None:
        client, _store = self.build_client(
            {
                "profit_sla_client_status": [
                    {"fc_client_id": 1, "sla_state": "on_track"},
                    {"fc_client_id": 2, "sla_state": "on_track"},
                    {"fc_client_id": 3, "sla_state": "on_track"},
                ]
            }
        )

        high_response = client.get("/api/profit/admin/sla/clients?limit=999&offset=-1")
        low_response = client.get("/api/profit/admin/sla/clients?limit=0")

        self.assertEqual(high_response.status_code, 200, high_response.text)
        self.assertEqual(high_response.json()["limit"], 200)
        self.assertEqual(high_response.json()["offset"], 0)
        self.assertEqual(low_response.status_code, 200, low_response.text)
        self.assertEqual(low_response.json()["limit"], 1)

    def test_sla_endpoints_do_not_call_write_methods(self) -> None:
        client, store = self.build_client(
            {
                "profit_sla_client_status": [
                    {"fc_client_id": 1, "sla_state": "on_track"}
                ],
                "profit_sla_staff_workload": [{"assigned_staff_name": "Laura"}],
                "profit_sla_breach_queue": [{"sla_state": "at_risk"}],
                "profit_sla_staff_service_performance_90d": [{"staff_name": "Laura"}],
                "profit_sla_anchor_backfill_queue": [{"classification_id": 100}],
            }
        )

        for path in (
            "/api/profit/admin/sla/summary",
            "/api/profit/admin/sla/clients",
            "/api/profit/admin/sla/workload",
            "/api/profit/admin/sla/queue",
            "/api/profit/admin/sla/performance",
            "/api/profit/admin/sla/backfill",
        ):
            response = client.get(path)
            self.assertEqual(response.status_code, 200, response.text)

        self.assertEqual(store.write_calls, [])

    def test_performance_endpoint_rejects_lookback_days_query_param(self) -> None:
        client, _store = self.build_client(
            {"profit_sla_staff_service_performance_90d": []}
        )

        response = client.get("/api/profit/admin/sla/performance?lookback_days=30")

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["detail"]["field"], "lookback_days")


if __name__ == "__main__":
    unittest.main()
