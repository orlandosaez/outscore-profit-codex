from __future__ import annotations

import json
import os
import unittest

from fastapi.testclient import TestClient
from urllib.request import Request

from profit_api.supabase import SupabaseRestClient

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")


class FakeResponse:
    def __init__(self, payload: object, status: int = 200) -> None:
        self.payload = payload
        self.status = status

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return json.dumps(self.payload).encode("utf-8")


class RecordingOpener:
    def __init__(self, payload: object) -> None:
        self.payload = payload
        self.requests: list[Request] = []

    def __call__(self, request: Request, timeout: int = 30) -> FakeResponse:
        self.requests.append(request)
        return FakeResponse(self.payload)


class SupabaseWriteClientTest(unittest.TestCase):
    def test_insert_rows_posts_json_and_returns_rows(self) -> None:
        opener = RecordingOpener([{"id": "one"}])
        client = SupabaseRestClient(
            url="https://example.supabase.co",
            service_role_key="service-key",
            opener=opener,
        )

        rows = client.insert_rows("profit_recognition_triggers", [{"id": "one"}])

        request = opener.requests[0]
        self.assertEqual(request.get_method(), "POST")
        self.assertIn("/rest/v1/profit_recognition_triggers", request.full_url)
        self.assertEqual(request.headers["Prefer"], "return=representation")
        self.assertEqual(rows, [{"id": "one"}])

    def test_patch_rows_sends_filters_and_returns_rows(self) -> None:
        opener = RecordingOpener([{"revenue_event_key": "rev_1"}])
        client = SupabaseRestClient(
            url="https://example.supabase.co",
            service_role_key="service-key",
            opener=opener,
        )

        rows = client.patch_rows(
            "profit_revenue_events",
            filters={"revenue_event_key": "eq.rev_1"},
            payload={"recognition_status": "recognized_by_manual_override"},
        )

        request = opener.requests[0]
        self.assertEqual(request.get_method(), "PATCH")
        self.assertIn("revenue_event_key=eq.rev_1", request.full_url)
        self.assertEqual(request.headers["Prefer"], "return=representation")
        self.assertEqual(rows[0]["revenue_event_key"], "rev_1")


from profit_api.manual_recognition import (
    ManualRecognitionError,
    ManualRecognitionService,
)


class FakeManualRecognitionStore:
    def __init__(self, pending_rows: list[dict[str, object]]) -> None:
        self.pending_rows = pending_rows
        self.read_calls: list[tuple[str, dict[str, object]]] = []
        self.inserted: list[tuple[str, list[dict[str, object]], str | None]] = []
        self.patched: list[tuple[str, dict[str, str | int], dict[str, object]]] = []
        self.deleted: list[tuple[str, dict[str, str | int]]] = []

    def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
        self.read_calls.append((view_name, params))
        if view_name == "profit_manual_recognition_pending_events":
            key_filter = params.get("revenue_event_key")
            if isinstance(key_filter, str) and key_filter.startswith("in.("):
                keys = set(key_filter.removeprefix("in.(").removesuffix(")").split(","))
                return [
                    row
                    for row in self.pending_rows
                    if str(row.get("revenue_event_key")) in keys
                ]
            if isinstance(key_filter, str) and key_filter.startswith("eq."):
                key = key_filter.removeprefix("eq.")
                return [
                    row
                    for row in self.pending_rows
                    if row.get("revenue_event_key") == key
                ]
            return self.pending_rows
        if view_name == "profit_revenue_events_ready_for_recognition":
            return []
        if view_name == "profit_revenue_events":
            return []
        return []

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        self.inserted.append((table_name, rows, on_conflict))
        return rows

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        self.patched.append((table_name, filters, payload))
        return [
            {
                **payload,
                "revenue_event_key": str(filters["revenue_event_key"]).replace("eq.", ""),
            }
        ]

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
    ) -> list[dict[str, object]]:
        self.deleted.append((table_name, filters))
        return []


class ManualRecognitionValidationTest(unittest.TestCase):
    def test_invalid_reason_code_rejected(self) -> None:
        service = ManualRecognitionService(FakeManualRecognitionStore([]))

        with self.assertRaisesRegex(
            ManualRecognitionError,
            "Invalid manual override reason_code",
        ):
            service.apply_manual_recognition(
                revenue_event_key="rev_1",
                reason_code="not_real",
                notes="Clear notes",
                reference=None,
            )

    def test_empty_notes_rejected(self) -> None:
        service = ManualRecognitionService(FakeManualRecognitionStore([]))

        with self.assertRaisesRegex(
            ManualRecognitionError,
            "manual override notes are required",
        ):
            service.apply_manual_recognition(
                revenue_event_key="rev_1",
                reason_code="fc_classifier_gap",
                notes="   ",
                reference=None,
            )

    def test_other_requires_twenty_characters(self) -> None:
        service = ManualRecognitionService(FakeManualRecognitionStore([]))

        with self.assertRaisesRegex(
            ManualRecognitionError,
            "other requires notes of at least 20 characters",
        ):
            service.apply_manual_recognition(
                revenue_event_key="rev_1",
                reason_code="other",
                notes="too short",
                reference=None,
            )


class ManualRecognitionApplyTest(unittest.TestCase):
    def test_list_pending_filters_use_pending_view(self) -> None:
        store = FakeManualRecognitionStore(
            [
                {
                    "revenue_event_key": "pending_1",
                    "recognition_status": "pending_bookkeeping_completion",
                },
            ]
        )
        service = ManualRecognitionService(store)

        rows = service.list_pending_revenue_events(
            client_filter="veena",
            service_filter="tax",
            period_filter="2026-04-01",
            limit=25,
            offset=50,
        )

        self.assertEqual(rows[0]["revenue_event_key"], "pending_1")
        self.assertEqual(
            store.read_calls[0],
            (
                "profit_manual_recognition_pending_events",
                {
                    "order": "candidate_period_month.desc,anchor_client_business_name.asc",
                    "limit": 25,
                    "offset": 50,
                    "anchor_client_business_name": "ilike.*veena*",
                    "macro_service_type": "eq.tax",
                    "candidate_period_month": "eq.2026-04-01",
                },
            ),
        )

    def test_apply_rejects_event_not_pending(self) -> None:
        store = FakeManualRecognitionStore([])
        service = ManualRecognitionService(store)

        with self.assertRaisesRegex(
            ManualRecognitionError,
            "pending revenue event was not found",
        ):
            service.apply_manual_recognition(
                revenue_event_key="recognized_rev",
                reason_code="fc_classifier_gap",
                notes="FC task existed but classifier missed it.",
                reference=None,
            )

    def test_apply_writes_trigger_and_recognizes_event(self) -> None:
        class ReadyStore(FakeManualRecognitionStore):
            def read_view(
                self,
                view_name: str,
                **params: str | int,
            ) -> list[dict[str, object]]:
                self.read_calls.append((view_name, params))
                if view_name == "profit_manual_recognition_pending_events":
                    return [
                        {
                            "revenue_event_key": "rev_manual",
                            "anchor_relationship_id": "relationship-veena",
                            "macro_service_type": "tax",
                            "candidate_period_month": "2026-04-01",
                            "recognition_status": "pending_tax_completion",
                        }
                    ]
                if view_name == "profit_revenue_events_ready_for_recognition":
                    return [
                        {
                            "revenue_event_key": "rev_manual",
                            "recognized_amount_to_apply": 520,
                            "recognition_date_to_apply": "2026-05-03",
                            "recognition_period_month_to_apply": "2026-05-01",
                            "next_recognition_status": "recognized_by_manual_override",
                            "trigger_reference_to_apply": "manual_override:rev_manual",
                        }
                    ]
                if view_name == "profit_revenue_events":
                    return [
                        {
                            "revenue_event_key": "rev_manual",
                            "recognized_amount": 520,
                            "recognition_status": "recognized_by_manual_override",
                        }
                    ]
                return []

        store = ReadyStore([])
        service = ManualRecognitionService(store)

        result = service.apply_manual_recognition(
            revenue_event_key="rev_manual",
            reason_code="backbill_pre_engagement",
            notes=(
                "Veena sales tax compliance was paid and delivered before the "
                "service workflow existed."
            ),
            reference="Anchor SBC-00118/SBC-00119",
        )

        inserted_trigger = store.inserted[0][1][0]
        self.assertEqual(store.inserted[0][0], "profit_recognition_triggers")
        self.assertEqual(
            inserted_trigger["trigger_type"],
            "manual_recognition_approved",
        )
        self.assertEqual(
            inserted_trigger["manual_override_reason_code"],
            "backbill_pre_engagement",
        )
        self.assertEqual(inserted_trigger["approved_by"], "orlando")
        self.assertEqual(store.patched[0][0], "profit_revenue_events")
        self.assertEqual(
            store.patched[0][2]["recognition_status"],
            "recognized_by_manual_override",
        )
        self.assertEqual(result["revenue_event_key"], "rev_manual")

    def test_apply_manual_recognition_batch_rejects_mixed_sibling_groups(self) -> None:
        store = FakeManualRecognitionStore(
            [
                {
                    "revenue_event_key": "rev_a",
                    "anchor_relationship_id": "relationship-dvh",
                    "macro_service_type": "tax",
                    "candidate_period_month": "2026-04-01",
                    "source_amount": 650,
                    "recognition_status": "pending_tax_completion",
                },
                {
                    "revenue_event_key": "rev_b",
                    "anchor_relationship_id": "relationship-dvh",
                    "macro_service_type": "bookkeeping",
                    "candidate_period_month": "2026-04-01",
                    "source_amount": 350,
                    "recognition_status": "pending_bookkeeping_completion",
                },
            ]
        )
        service = ManualRecognitionService(store)

        with self.assertRaisesRegex(ManualRecognitionError, "same sibling group"):
            service.apply_manual_recognition_batch(
                revenue_event_keys=["rev_a", "rev_b"],
                reason_code="client_operational_change",
                notes="Veena email approved consolidated filing batch.",
                reference=None,
            )

    def test_apply_manual_recognition_batch_uses_one_batch_id_for_all_triggers(self) -> None:
        store = BatchReadyStore()
        service = ManualRecognitionService(store)

        result = service.apply_manual_recognition_batch(
            revenue_event_keys=["rev_650", "rev_350"],
            reason_code="client_operational_change",
            notes="Veena email 2026-04-26 approved consolidated filing batch.",
            reference="Veena email",
        )

        trigger_rows = store.inserted[0][1]
        batch_ids = {row["manual_override_batch_id"] for row in trigger_rows}
        self.assertEqual(len(batch_ids), 1)
        self.assertTrue(next(iter(batch_ids)))
        self.assertEqual(result["manual_override_batch_id"], next(iter(batch_ids)))

    def test_apply_manual_recognition_batch_prefixes_each_note_with_source_amount(self) -> None:
        store = BatchReadyStore()
        service = ManualRecognitionService(store)

        service.apply_manual_recognition_batch(
            revenue_event_keys=["rev_650", "rev_350"],
            reason_code="client_operational_change",
            notes="Veena email 2026-04-26 approved consolidated $1,000 batch.",
            reference=None,
        )

        notes = {
            row["source_record_id"]: row["manual_override_notes"]
            for row in store.inserted[0][1]
        }
        self.assertEqual(
            notes["rev_650"],
            "[$650] Veena email 2026-04-26 approved consolidated $1,000 batch.",
        )
        self.assertEqual(
            notes["rev_350"],
            "[$350] Veena email 2026-04-26 approved consolidated $1,000 batch.",
        )

    def test_apply_manual_recognition_batch_rolls_back_when_apply_fails(self) -> None:
        store = BatchReadyStore(fail_patch_for="rev_350")
        service = ManualRecognitionService(store)

        with self.assertRaisesRegex(ManualRecognitionError, "batch recognition failed"):
            service.apply_manual_recognition_batch(
                revenue_event_keys=["rev_650", "rev_350"],
                reason_code="client_operational_change",
                notes="Veena email 2026-04-26 approved consolidated filing batch.",
                reference=None,
            )

        self.assertEqual(store.deleted[0][0], "profit_recognition_triggers")
        self.assertIn("manual_override_batch_id", store.deleted[0][1])
        self.assertEqual(store.patched[-1][0], "profit_revenue_events")
        self.assertEqual(
            store.patched[-1][2]["recognition_status"],
            "pending_tax_completion",
        )

    def test_apply_manual_recognition_batch_returns_recognized_events(self) -> None:
        store = BatchReadyStore()
        service = ManualRecognitionService(store)

        result = service.apply_manual_recognition_batch(
            revenue_event_keys=["rev_650", "rev_350"],
            reason_code="client_operational_change",
            notes="Veena email 2026-04-26 approved consolidated filing batch.",
            reference=None,
        )

        self.assertEqual(
            [row["revenue_event_key"] for row in result["events"]],
            ["rev_650", "rev_350"],
        )
        self.assertEqual(result["events"][0]["anchor_client_business_name"], "DVH Investing LLC")


class BatchReadyStore(FakeManualRecognitionStore):
    def __init__(self, fail_patch_for: str | None = None) -> None:
        super().__init__(
            [
                {
                    "revenue_event_key": "rev_650",
                    "anchor_relationship_id": "relationship-dvh",
                    "anchor_client_business_name": "DVH Investing LLC",
                    "macro_service_type": "tax",
                    "candidate_period_month": "2026-04-01",
                    "source_amount": 650,
                    "recognition_status": "pending_tax_completion",
                },
                {
                    "revenue_event_key": "rev_350",
                    "anchor_relationship_id": "relationship-dvh",
                    "anchor_client_business_name": "DVH Investing LLC",
                    "macro_service_type": "tax",
                    "candidate_period_month": "2026-04-01",
                    "source_amount": 350,
                    "recognition_status": "pending_tax_completion",
                },
            ]
        )
        self.fail_patch_for = fail_patch_for

    def read_view(
        self,
        view_name: str,
        **params: str | int,
    ) -> list[dict[str, object]]:
        self.read_calls.append((view_name, params))
        if view_name == "profit_manual_recognition_pending_events":
            return FakeManualRecognitionStore.read_view(self, view_name, **params)
        if view_name == "profit_revenue_events_ready_for_recognition":
            key = str(params.get("revenue_event_key", "")).replace("eq.", "")
            source = next(row for row in self.pending_rows if row["revenue_event_key"] == key)
            return [
                {
                    "revenue_event_key": key,
                    "recognized_amount_to_apply": source["source_amount"],
                    "recognition_date_to_apply": "2026-05-03",
                    "recognition_period_month_to_apply": "2026-05-01",
                    "next_recognition_status": "recognized_by_manual_override",
                    "trigger_reference_to_apply": f"manual_override:{key}",
                }
            ]
        return []

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        key = str(filters["revenue_event_key"]).replace("eq.", "")
        if key == self.fail_patch_for and payload.get("recognition_status") == "recognized_by_manual_override":
            return []
        self.patched.append((table_name, filters, payload))
        source = next((row for row in self.pending_rows if row["revenue_event_key"] == key), {})
        return [{**source, **payload, "revenue_event_key": key}]


class FakeRouteService:
    def __init__(self) -> None:
        self.pending_calls: list[dict[str, object]] = []
        self.apply_calls: list[dict[str, object]] = []

    def list_pending_revenue_events(self, **kwargs: object) -> list[dict[str, object]]:
        self.pending_calls.append(kwargs)
        return [{"revenue_event_key": "rev_pending"}]

    def recent_overrides(self, *, limit: int = 50) -> list[dict[str, object]]:
        return [{"revenue_event_key": "rev_recent", "approved_by": "orlando"}]

    def apply_manual_recognition(self, **kwargs: object) -> dict[str, object]:
        self.apply_calls.append(kwargs)
        if kwargs["reason_code"] == "bad":
            raise ManualRecognitionError("Invalid manual override reason_code")
        return {
            "revenue_event_key": kwargs["revenue_event_key"],
            "recognition_status": "recognized_by_manual_override",
        }

    def apply_manual_recognition_batch(self, **kwargs: object) -> dict[str, object]:
        self.apply_calls.append(kwargs)
        if len(kwargs["revenue_event_keys"]) < 2:
            raise ManualRecognitionError("batch recognition requires at least two events")
        return {
            "manual_override_batch_id": "batch-123",
            "events": [
                {
                    "revenue_event_key": key,
                    "recognition_status": "recognized_by_manual_override",
                }
                for key in kwargs["revenue_event_keys"]
            ],
        }


class ManualRecognitionRouteTest(unittest.TestCase):
    def test_pending_endpoint_returns_rows(self) -> None:
        import profit_api.app as app_module

        route_service = FakeRouteService()
        app = app_module.create_app(
            service=object(),
            manual_recognition_service=route_service,
        )
        client = TestClient(app)

        response = client.get(
            "/api/profit/admin/recognition/pending",
            params={
                "client_filter": "veena",
                "service_filter": "tax",
                "period_filter": "2026-04-01",
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(
            response.json()["rows"][0]["revenue_event_key"],
            "rev_pending",
        )
        self.assertEqual(
            route_service.pending_calls[0]["period_filter"],
            "2026-04-01",
        )

    def test_pending_endpoint_rejects_bad_period(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.get(
            "/api/profit/admin/recognition/pending",
            params={"period_filter": "2026-04"},
        )

        self.assertEqual(response.status_code, 422)

    def test_manual_override_endpoint_returns_422_for_validation_error(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.post(
            "/api/profit/admin/recognition/manual-override",
            json={
                "revenue_event_key": "rev_1",
                "reason_code": "bad",
                "notes": "Valid notes",
            },
        )

        self.assertEqual(response.status_code, 422)

    def test_manual_override_endpoint_returns_updated_event(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.post(
            "/api/profit/admin/recognition/manual-override",
            json={
                "revenue_event_key": "rev_1",
                "reason_code": "fc_classifier_gap",
                "notes": "FC task existed but the classifier missed it.",
                "reference": "FC task 123",
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(
            response.json()["event"]["recognition_status"],
            "recognized_by_manual_override",
        )

    def test_manual_override_batch_endpoint_returns_recognized_events(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.post(
            "/api/profit/admin/recognition/manual-override-batch",
            json={
                "revenue_event_keys": ["rev_a", "rev_b"],
                "reason_code": "client_operational_change",
                "notes": "Veena email 2026-04-26 approved consolidated $1,350 tax filing batch",
                "reference": None,
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["manual_override_batch_id"], "batch-123")
        self.assertEqual(len(response.json()["events"]), 2)

    def test_manual_override_batch_endpoint_rejects_single_event(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.post(
            "/api/profit/admin/recognition/manual-override-batch",
            json={
                "revenue_event_keys": ["rev_a"],
                "reason_code": "client_operational_change",
                "notes": "Veena email 2026-04-26 approved consolidated filing batch",
                "reference": None,
            },
        )

        self.assertEqual(response.status_code, 422)

    def test_recent_overrides_endpoint_returns_rows(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.get("/api/profit/admin/recognition/manual-overrides")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["rows"][0]["approved_by"], "orlando")


if __name__ == "__main__":
    unittest.main()
