from __future__ import annotations

import datetime
import os
import unittest

from fastapi.testclient import TestClient

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")

TODAY = datetime.date.today()
YESTERDAY = (TODAY - datetime.timedelta(days=1)).isoformat()
TOMORROW = (TODAY + datetime.timedelta(days=1)).isoformat()


def _week_out() -> str:
    return (TODAY + datetime.timedelta(days=7)).isoformat()


def _make_row(
    classification_id: int = 1,
    verdict_code: str = "MANUAL_INVOICE_PENDING",
    client_name: str = "Acme Corp",
    sort_rank: int = 1,
    reviewed_at: str | None = None,
    snoozed_until: str | None = None,
) -> dict[str, object]:
    return {
        "classification_id": classification_id,
        "verdict_code": verdict_code,
        "item_type": verdict_code,
        "anchor_relationship_id": f"relationship-test-{classification_id}",
        "fc_client_id": classification_id,
        "client_name": client_name,
        "service_name": "1120 Essential",
        "invoice_state": "no_invoice",
        "age_days": 30,
        "estimated_annual_revenue": 1500.0,
        "action_url": f"https://app.sayanchor.com/home/relationship/relationship-test-{classification_id}/agreement",
        "sort_rank": sort_rank,
        "reviewed_at": reviewed_at,
        "snoozed_until": snoozed_until,
        "operator_id": "orlando",
        "practice_id": None,
    }


class FakeWeeklyReviewStore:
    def __init__(self, rows_by_view: dict[str, list[dict[str, object]]]) -> None:
        self.rows_by_view = rows_by_view
        self.read_calls: list[tuple[str, dict[str, object]]] = []
        self.insert_calls: list[tuple[str, list[dict[str, object]]]] = []
        self.patch_calls: list[tuple[str, dict[str, object], dict[str, object]]] = []
        self._patch_returns_empty = False

    def read_view(self, view_name: str, **params: object) -> list[dict[str, object]]:
        self.read_calls.append((view_name, params))
        return [dict(row) for row in self.rows_by_view.get(view_name, [])]

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        if table_name == "profit_classifications":
            raise AssertionError("weekly review endpoints must not write to profit_classifications")
        self.insert_calls.append((table_name, rows))
        return list(rows)

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        if table_name == "profit_classifications":
            raise AssertionError("weekly review endpoints must not write to profit_classifications")
        self.patch_calls.append((table_name, filters, payload))
        if self._patch_returns_empty:
            return []
        return [{"classification_id": 1, **payload}]


class FakeDashboardService:
    pass


class FakeRecognitionService:
    pass


class FakeAuditService:
    pass


class FakePipelineService:
    pass


class FakeSlaService:
    pass


class WeeklyReviewApiListTests(unittest.TestCase):
    def build_client(
        self,
        rows_by_view: dict[str, list[dict[str, object]]],
    ) -> tuple[TestClient, FakeWeeklyReviewStore]:
        from profit_api.weekly_review import WeeklyReviewService
        import profit_api.app as app_module

        store = FakeWeeklyReviewStore(rows_by_view)
        service = WeeklyReviewService(store)
        app = app_module.create_app(
            service=FakeDashboardService(),
            manual_recognition_service=FakeRecognitionService(),
            audit_service=FakeAuditService(),
            pipeline_service=FakePipelineService(),
            sla_service=FakeSlaService(),
            weekly_review_service=service,
        )
        return TestClient(app), store

    def test_list_reads_profit_weekly_review_items_view(self) -> None:
        client, store = self.build_client(
            {"profit_weekly_review_items": [_make_row(1), _make_row(2)]}
        )
        resp = client.get("/api/profit/admin/weekly-review/items")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 2)
        self.assertEqual(store.read_calls[0][0], "profit_weekly_review_items")

    def test_list_default_excludes_reviewed_rows(self) -> None:
        rows = [
            _make_row(1, reviewed_at=None),
            _make_row(2, reviewed_at="2026-05-10T12:00:00Z"),
        ]
        client, _ = self.build_client({"profit_weekly_review_items": rows})
        resp = client.get("/api/profit/admin/weekly-review/items")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 1)
        self.assertEqual(resp.json()["rows"][0]["classification_id"], 1)

    def test_list_default_excludes_currently_snoozed_rows(self) -> None:
        rows = [
            _make_row(1, snoozed_until=None),
            _make_row(2, snoozed_until=TOMORROW),
        ]
        client, _ = self.build_client({"profit_weekly_review_items": rows})
        resp = client.get("/api/profit/admin/weekly-review/items")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 1)
        self.assertEqual(resp.json()["rows"][0]["classification_id"], 1)

    def test_list_resurfaces_rows_with_expired_snooze(self) -> None:
        rows = [_make_row(1, snoozed_until=YESTERDAY)]
        client, _ = self.build_client({"profit_weekly_review_items": rows})
        resp = client.get("/api/profit/admin/weekly-review/items")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 1)

    def test_list_include_reviewed_true_surfaces_reviewed_rows(self) -> None:
        rows = [
            _make_row(1, reviewed_at=None),
            _make_row(2, reviewed_at="2026-05-10T12:00:00Z"),
        ]
        client, _ = self.build_client({"profit_weekly_review_items": rows})
        resp = client.get("/api/profit/admin/weekly-review/items?include_reviewed=true")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 2)

    def test_list_include_snoozed_true_surfaces_snoozed_rows(self) -> None:
        rows = [
            _make_row(1, snoozed_until=None),
            _make_row(2, snoozed_until=TOMORROW),
        ]
        client, _ = self.build_client({"profit_weekly_review_items": rows})
        resp = client.get("/api/profit/admin/weekly-review/items?include_snoozed=true")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 2)

    def test_list_verdict_code_filter_accepts_manual_invoice_pending(self) -> None:
        rows = [_make_row(1, verdict_code="MANUAL_INVOICE_PENDING")]
        client, _ = self.build_client({"profit_weekly_review_items": rows})
        resp = client.get(
            "/api/profit/admin/weekly-review/items?verdict_code=MANUAL_INVOICE_PENDING"
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 1)

    def test_list_verdict_code_filter_rejects_unsupported_code(self) -> None:
        client, _ = self.build_client({"profit_weekly_review_items": []})
        resp = client.get(
            "/api/profit/admin/weekly-review/items?verdict_code=INVALID_VERDICT"
        )
        self.assertEqual(resp.status_code, 422)

    def test_list_limit_clamps_to_1_200(self) -> None:
        rows = [_make_row(i) for i in range(1, 6)]
        client, _ = self.build_client({"profit_weekly_review_items": rows})

        resp = client.get("/api/profit/admin/weekly-review/items?limit=2")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.json()["rows"]), 2)
        self.assertEqual(resp.json()["limit"], 2)

        resp = client.get("/api/profit/admin/weekly-review/items?limit=0")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["limit"], 1)

        resp = client.get("/api/profit/admin/weekly-review/items?limit=9999")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["limit"], 200)

    def test_list_sorting_uses_sql_provided_sort_rank(self) -> None:
        rows = [_make_row(1, sort_rank=3), _make_row(2, sort_rank=1), _make_row(3, sort_rank=2)]
        client, _ = self.build_client({"profit_weekly_review_items": rows})
        resp = client.get("/api/profit/admin/weekly-review/items")
        self.assertEqual(resp.status_code, 200)
        result_ids = [r["classification_id"] for r in resp.json()["rows"]]
        self.assertEqual(result_ids, [2, 3, 1])


class WeeklyReviewApiActionTests(unittest.TestCase):
    def build_client(
        self,
        patch_returns_empty: bool = False,
    ) -> tuple[TestClient, FakeWeeklyReviewStore]:
        from profit_api.weekly_review import WeeklyReviewService
        import profit_api.app as app_module

        store = FakeWeeklyReviewStore({"profit_weekly_review_items": []})
        store._patch_returns_empty = patch_returns_empty
        service = WeeklyReviewService(store)
        app = app_module.create_app(
            service=FakeDashboardService(),
            manual_recognition_service=FakeRecognitionService(),
            audit_service=FakeAuditService(),
            pipeline_service=FakePipelineService(),
            sla_service=FakeSlaService(),
            weekly_review_service=service,
        )
        return TestClient(app), store

    def test_mark_reviewed_upserts_state_with_reviewed_at_and_orlando_operator(self) -> None:
        client, store = self.build_client()
        resp = client.post(
            "/api/profit/admin/weekly-review/items/42/reviewed"
        )
        self.assertEqual(resp.status_code, 200)
        # Should have patched profit_weekly_review_item_state
        patch_tables = [call[0] for call in store.patch_calls]
        self.assertIn("profit_weekly_review_item_state", patch_tables)
        # reviewed_at set in payload
        patch_payloads = [call[2] for call in store.patch_calls]
        self.assertTrue(any("reviewed_at" in p for p in patch_payloads))
        # response contains classification_id and reviewed_at
        body = resp.json()
        self.assertEqual(body["classification_id"], 42)
        self.assertIn("reviewed_at", body)
        self.assertEqual(body["operator_id"], "orlando")

    def test_mark_reviewed_inserts_new_row_when_no_existing_state(self) -> None:
        client, store = self.build_client(patch_returns_empty=True)
        resp = client.post("/api/profit/admin/weekly-review/items/99/reviewed")
        self.assertEqual(resp.status_code, 200)
        insert_tables = [call[0] for call in store.insert_calls]
        self.assertIn("profit_weekly_review_item_state", insert_tables)

    def test_snooze_upserts_state_with_snoozed_until_7_days_out(self) -> None:
        client, store = self.build_client()
        expected_until = _week_out()
        resp = client.post(
            "/api/profit/admin/weekly-review/items/55/snooze"
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        self.assertEqual(body["classification_id"], 55)
        self.assertEqual(body["snoozed_until"], expected_until)
        self.assertEqual(body["operator_id"], "orlando")

    def test_snooze_inserts_new_row_when_no_existing_state(self) -> None:
        client, store = self.build_client(patch_returns_empty=True)
        resp = client.post("/api/profit/admin/weekly-review/items/77/snooze")
        self.assertEqual(resp.status_code, 200)
        insert_tables = [call[0] for call in store.insert_calls]
        self.assertIn("profit_weekly_review_item_state", insert_tables)

    def test_action_routes_do_not_write_to_profit_classifications(self) -> None:
        # The FakeStore raises AssertionError if profit_classifications is written.
        # These calls should succeed without triggering that guard.
        client, store = self.build_client()
        resp1 = client.post("/api/profit/admin/weekly-review/items/1/reviewed")
        resp2 = client.post("/api/profit/admin/weekly-review/items/2/snooze")
        self.assertEqual(resp1.status_code, 200)
        self.assertEqual(resp2.status_code, 200)
        all_tables = (
            [c[0] for c in store.insert_calls]
            + [c[0] for c in store.patch_calls]
        )
        self.assertNotIn("profit_classifications", all_tables)


if __name__ == "__main__":
    unittest.main()
