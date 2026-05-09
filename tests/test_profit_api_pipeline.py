from __future__ import annotations

import json
import os
import unittest
from datetime import datetime, timezone
from io import BytesIO
from unittest.mock import patch
from pathlib import Path
from urllib.error import HTTPError

from fastapi.testclient import TestClient

from profit_api.pipeline import N8nPipelineWebhookClient
from profit_api.supabase import SupabaseRestError

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")
os.environ.setdefault(
    "PROFIT_PIPELINE_WEBHOOK_URL",
    "https://n8n.example.test/webhook/profit-26",
)
os.environ.setdefault("PROFIT_PIPELINE_WEBHOOK_SECRET", "test-secret")


RUN_ID = "11111111-1111-4111-8111-111111111111"
SECOND_RUN_ID = "22222222-2222-4222-8222-222222222222"
ROOT = Path(__file__).resolve().parents[1]
STALE_FINALIZER_MIGRATION = (
    ROOT / "supabase/sql/027_profit_finalize_stale_pipeline_runs.sql"
)
CRON_HEALTH_VIEW_MIGRATION = (
    ROOT / "supabase/sql/027a_profit_cron_pipeline_run_health.sql"
)
STALE_ERROR_SUMMARY = "Stuck running detection - no progress for >30min"


def read_stale_finalizer_sql() -> str:
    return STALE_FINALIZER_MIGRATION.read_text(encoding="utf-8")


def read_cron_health_view_sql() -> str:
    return CRON_HEALTH_VIEW_MIGRATION.read_text(encoding="utf-8")


class FakePipelineStore:
    def __init__(self, rows_by_table: dict[str, list[dict[str, object]]]) -> None:
        self.rows_by_table = rows_by_table
        self.read_calls: list[tuple[str, dict[str, object]]] = []
        self.insert_calls: list[tuple[str, list[dict[str, object]], str | None]] = []
        self.delete_calls: list[tuple[str, dict[str, object]]] = []
        self.fail_first_insert_with_running_conflict = False
        self.fail_all_inserts_with_running_conflict = False
        self.finish_running_before_select = False

    def read_view(self, view_name: str, **params: object) -> list[dict[str, object]]:
        self.read_calls.append((view_name, params))
        rows = [dict(row) for row in self.rows_by_table.get(view_name, [])]
        for key, value in params.items():
            if isinstance(value, str) and value.startswith("eq."):
                expected = value.removeprefix("eq.")
                rows = [row for row in rows if str(row.get(key)) == expected]
        if params.get("order") == "started_at.desc":
            rows.sort(key=lambda row: str(row.get("started_at") or ""), reverse=True)
        if params.get("order") == "step_order.asc":
            rows.sort(key=lambda row: int(row.get("step_order") or 0))
        offset = int(params.get("offset") or 0)
        limit = params.get("limit")
        if limit is not None:
            rows = rows[offset : offset + int(limit)]
        elif offset:
            rows = rows[offset:]
        return rows

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        self.insert_calls.append((table_name, rows, on_conflict))
        if table_name == "profit_pipeline_runs":
            if self.fail_all_inserts_with_running_conflict:
                raise self._running_conflict()
            if self.fail_first_insert_with_running_conflict:
                self.fail_first_insert_with_running_conflict = False
                if self.finish_running_before_select:
                    for row in self.rows_by_table.get("profit_pipeline_runs", []):
                        if row.get("status") == "running":
                            row["status"] = "success"
                            row["finished_at"] = "2026-05-08T12:05:00+00:00"
                raise self._running_conflict()

        returned = []
        for row in rows:
            if table_name == "profit_pipeline_runs":
                next_id = SECOND_RUN_ID if self.insert_calls.count((table_name, rows, on_conflict)) > 1 else RUN_ID
                returned_row = {
                    "pipeline_run_id": next_id,
                    "started_at": "2026-05-08T12:00:00+00:00",
                    "finished_at": None,
                    **row,
                }
            else:
                returned_row = dict(row)
            returned.append(returned_row)
        self.rows_by_table.setdefault(table_name, []).extend(returned)
        return returned

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
    ) -> list[dict[str, object]]:
        self.delete_calls.append((table_name, filters))
        return []

    def _running_conflict(self) -> SupabaseRestError:
        return SupabaseRestError(
            'duplicate key value violates unique constraint "idx_profit_pipeline_runs_one_running"',
            status_code=409,
            postgres_code="23505",
            constraint_name="idx_profit_pipeline_runs_one_running",
            body={"code": "23505"},
        )


class FakeWebhookClient:
    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.payloads: list[dict[str, object]] = []

    def trigger(self, payload: dict[str, object]) -> dict[str, object]:
        self.payloads.append(payload)
        if self.fail:
            raise RuntimeError("webhook unavailable")
        return {"accepted": True, "pipeline_run_id": payload["pipeline_run_id"]}


class FakeHttpResponse:
    def __init__(self, payload: dict[str, object] | None = None) -> None:
        self.payload = payload or {"accepted": True}

    def __enter__(self) -> "FakeHttpResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return json.dumps(self.payload).encode("utf-8")


class SequenceOpener:
    def __init__(self, outcomes: list[int | dict[str, object]]) -> None:
        self.outcomes = outcomes
        self.calls = 0

    def __call__(self, request: object, *, timeout: int) -> FakeHttpResponse:
        self.calls += 1
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, int):
            raise HTTPError(
                "https://n8n.example.test/webhook/profit-26",
                outcome,
                "webhook failed",
                hdrs=None,
                fp=BytesIO(b'{"message":"webhook failed"}'),
            )
        return FakeHttpResponse(outcome)


class FakeDashboardService:
    pass


class FakeRecognitionService:
    pass


class FakeAuditService:
    pass


class PipelineApiTests(unittest.TestCase):
    def build_client(
        self,
        store: FakePipelineStore,
        webhook: FakeWebhookClient | None = None,
    ) -> TestClient:
        from profit_api.pipeline import PipelineService
        import profit_api.app as app_module

        service = PipelineService(store, webhook_client=webhook or FakeWebhookClient())
        app = app_module.create_app(
            service=FakeDashboardService(),
            manual_recognition_service=FakeRecognitionService(),
            audit_service=FakeAuditService(),
            pipeline_service=service,
        )
        return TestClient(app)

    def build_client_with_opener(
        self,
        store: FakePipelineStore,
        opener: SequenceOpener,
    ) -> TestClient:
        from profit_api.pipeline import PipelineService
        import profit_api.app as app_module

        service = PipelineService(
            store,
            webhook_client=N8nPipelineWebhookClient(
                url="https://n8n.example.test/webhook/profit-26",
                secret="test-secret",
                opener=opener,
            ),
        )
        app = app_module.create_app(
            service=FakeDashboardService(),
            manual_recognition_service=FakeRecognitionService(),
            audit_service=FakeAuditService(),
            pipeline_service=service,
        )
        return TestClient(app)

    def test_list_pipeline_runs_returns_rows_limit_offset_and_duration(self) -> None:
        store = FakePipelineStore(
            {
                "profit_pipeline_runs": [
                    {
                        "pipeline_run_id": RUN_ID,
                        "run_source": "manual",
                        "status": "success",
                        "triggered_by": "orlando",
                        "started_at": "2026-05-08T12:00:00+00:00",
                        "finished_at": "2026-05-08T12:02:03+00:00",
                        "summary": {"total_rows_affected": 12},
                    }
                ]
            }
        )
        client = self.build_client(store)

        response = client.get("/api/profit/admin/audit/pipeline-runs?limit=500&offset=-2")

        self.assertEqual(response.status_code, 200, response.text)
        payload = response.json()
        self.assertEqual(payload["limit"], 200)
        self.assertEqual(payload["offset"], 0)
        self.assertEqual(payload["rows"][0]["duration_seconds"], 123)

    def test_run_detail_returns_200_with_empty_steps(self) -> None:
        store = FakePipelineStore(
            {
                "profit_pipeline_runs": [
                    {
                        "pipeline_run_id": RUN_ID,
                        "run_source": "manual",
                        "status": "running",
                        "triggered_by": "orlando",
                        "started_at": "2026-05-08T12:00:00+00:00",
                        "finished_at": None,
                        "summary": {},
                    }
                ],
                "profit_pipeline_run_steps": [],
            }
        )
        client = self.build_client(store)

        response = client.get(f"/api/profit/admin/audit/pipeline-runs/{RUN_ID}")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["run"]["pipeline_run_id"], RUN_ID)
        self.assertEqual(response.json()["run"]["duration_seconds"], None)
        self.assertEqual(response.json()["steps"], [])

    def test_run_detail_unknown_run_returns_404(self) -> None:
        client = self.build_client(FakePipelineStore({"profit_pipeline_runs": []}))

        response = client.get(f"/api/profit/admin/audit/pipeline-runs/{RUN_ID}")

        self.assertEqual(response.status_code, 404)

    def test_post_pipeline_run_inserts_row_calls_webhook_and_returns_immediately(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        webhook = FakeWebhookClient()
        client = self.build_client(store, webhook)

        response = client.post(
            "/api/profit/admin/audit/pipeline-runs",
            json={"triggered_by": "beth"},
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["run"]["pipeline_run_id"], RUN_ID)
        self.assertEqual(response.json()["run"]["status"], "running")
        self.assertEqual(webhook.payloads[0]["pipeline_run_id"], RUN_ID)
        self.assertEqual(webhook.payloads[0]["triggered_by"], "beth")

    def test_post_pipeline_run_deletes_running_row_when_webhook_fails(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        client = self.build_client(store, FakeWebhookClient(fail=True))

        response = client.post(
            "/api/profit/admin/audit/pipeline-runs",
            json={"triggered_by": "orlando"},
        )

        self.assertEqual(response.status_code, 500)
        self.assertEqual(store.delete_calls[0][0], "profit_pipeline_runs")
        self.assertIn("pipeline_run_id", store.delete_calls[0][1])

    def test_post_pipeline_run_maps_running_unique_violation_to_409(self) -> None:
        store = FakePipelineStore(
            {
                "profit_pipeline_runs": [
                    {
                        "pipeline_run_id": RUN_ID,
                        "run_source": "manual",
                        "status": "running",
                        "triggered_by": "orlando",
                        "started_at": "2026-05-08T12:00:00+00:00",
                        "finished_at": None,
                        "summary": {},
                    }
                ]
            }
        )
        store.fail_all_inserts_with_running_conflict = True
        client = self.build_client(store)

        response = client.post(
            "/api/profit/admin/audit/pipeline-runs",
            json={"triggered_by": "beth"},
        )

        self.assertEqual(response.status_code, 409, response.text)
        detail = response.json()["detail"]
        self.assertEqual(detail["current_run_id"], RUN_ID)
        self.assertEqual(detail["triggered_by"], "orlando")

    def test_post_pipeline_run_retries_once_when_conflict_row_finishes_before_select(self) -> None:
        store = FakePipelineStore(
            {
                "profit_pipeline_runs": [
                    {
                        "pipeline_run_id": RUN_ID,
                        "run_source": "manual",
                        "status": "running",
                        "triggered_by": "orlando",
                        "started_at": "2026-05-08T12:00:00+00:00",
                        "finished_at": None,
                        "summary": {},
                    }
                ]
            }
        )
        store.fail_first_insert_with_running_conflict = True
        store.finish_running_before_select = True
        webhook = FakeWebhookClient()
        client = self.build_client(store, webhook)

        response = client.post(
            "/api/profit/admin/audit/pipeline-runs",
            json={"triggered_by": "beth"},
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(store.insert_calls), 2)
        self.assertEqual(response.json()["run"]["status"], "running")
        self.assertEqual(webhook.payloads[0]["triggered_by"], "beth")

    def test_post_pipeline_run_returns_500_when_conflict_retry_has_no_current_row(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        store.fail_all_inserts_with_running_conflict = True
        client = self.build_client(store)

        response = client.post(
            "/api/profit/admin/audit/pipeline-runs",
            json={"triggered_by": "orlando"},
        )

        self.assertEqual(response.status_code, 500)
        self.assertIn("unique constraint fired but no running row", response.text)

    def test_webhook_retry_on_404_succeeds_second_attempt(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        opener = SequenceOpener([404, {"accepted": True}])
        client = self.build_client_with_opener(store, opener)

        with patch("profit_api.pipeline.time.sleep"):
            response = client.post(
                "/api/profit/admin/audit/pipeline-runs",
                json={"triggered_by": "orlando"},
            )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(opener.calls, 2)
        self.assertEqual(store.delete_calls, [])
        self.assertEqual(
            store.rows_by_table["profit_pipeline_runs"][0]["pipeline_run_id"],
            RUN_ID,
        )

    def test_webhook_retry_on_503_succeeds_second_attempt(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        opener = SequenceOpener([503, {"accepted": True}])
        client = self.build_client_with_opener(store, opener)

        with patch("profit_api.pipeline.time.sleep"):
            response = client.post(
                "/api/profit/admin/audit/pipeline-runs",
                json={"triggered_by": "orlando"},
            )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(opener.calls, 2)
        self.assertEqual(store.delete_calls, [])

    def test_webhook_no_retry_on_400(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        opener = SequenceOpener([400, {"accepted": True}])
        client = self.build_client_with_opener(store, opener)

        with patch("profit_api.pipeline.time.sleep") as sleep:
            response = client.post(
                "/api/profit/admin/audit/pipeline-runs",
                json={"triggered_by": "orlando"},
            )

        self.assertEqual(response.status_code, 500)
        self.assertEqual(opener.calls, 1)
        sleep.assert_not_called()
        self.assertEqual(store.delete_calls[0][0], "profit_pipeline_runs")

    def test_webhook_both_attempts_fail(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        opener = SequenceOpener([404, 404])
        client = self.build_client_with_opener(store, opener)

        with patch("profit_api.pipeline.time.sleep"):
            response = client.post(
                "/api/profit/admin/audit/pipeline-runs",
                json={"triggered_by": "orlando"},
            )

        self.assertEqual(response.status_code, 500)
        self.assertEqual(opener.calls, 2)
        self.assertEqual(store.delete_calls[0][0], "profit_pipeline_runs")

    def test_webhook_succeeds_first_attempt_no_retry(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        opener = SequenceOpener([{"accepted": True}, 503])
        client = self.build_client_with_opener(store, opener)

        with patch("profit_api.pipeline.time.sleep") as sleep:
            response = client.post(
                "/api/profit/admin/audit/pipeline-runs",
                json={"triggered_by": "orlando"},
            )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(opener.calls, 1)
        sleep.assert_not_called()
        self.assertEqual(store.delete_calls, [])

    def test_webhook_retry_backoff_observed(self) -> None:
        store = FakePipelineStore({"profit_pipeline_runs": []})
        opener = SequenceOpener([404, {"accepted": True}])
        client = self.build_client_with_opener(store, opener)

        with patch("profit_api.pipeline.time.sleep") as sleep:
            response = client.post(
                "/api/profit/admin/audit/pipeline-runs",
                json={"triggered_by": "orlando"},
            )

        self.assertEqual(response.status_code, 200, response.text)
        sleep.assert_called_once_with(3)


class FinalizeStalePipelineRunsSqlTests(unittest.TestCase):
    def test_finalize_stale_pipeline_runs_finalizes_old_running_row(self) -> None:
        sql = read_stale_finalizer_sql().lower()

        self.assertIn("create or replace function profit_finalize_stale_pipeline_runs", sql)
        self.assertIn("p_threshold interval default interval '30 minutes'", sql)
        self.assertIn("status = 'running'", sql)
        self.assertIn("started_at < now() - p_threshold", sql)
        self.assertIn("status = 'failed'", sql)
        self.assertIn("finished_at = now()", sql)
        self.assertIn(STALE_ERROR_SUMMARY.lower(), sql)

    def test_finalize_stale_pipeline_runs_skips_recent_running_row(self) -> None:
        sql = read_stale_finalizer_sql().lower()

        self.assertIn("started_at < now() - p_threshold", sql)
        self.assertNotIn("started_at <= now() - p_threshold", sql)

    def test_finalize_stale_pipeline_runs_skips_already_finalized(self) -> None:
        sql = read_stale_finalizer_sql().lower()

        self.assertIn("where status = 'running'", sql)
        self.assertNotIn("status in ('running'", sql)

    def test_finalize_stale_pipeline_runs_preserves_summary_keys(self) -> None:
        sql = read_stale_finalizer_sql().lower()

        self.assertIn("coalesce(summary, '{}'::jsonb)", sql)
        self.assertIn("|| jsonb_build_object", sql)
        self.assertIn("'error_summary'", sql)
        self.assertNotIn("summary = jsonb_build_object", sql)

    def test_finalize_stale_pipeline_runs_idempotent(self) -> None:
        sql = read_stale_finalizer_sql().lower()

        self.assertIn("where status = 'running'", sql)
        self.assertIn("return query", sql)

    def test_finalize_stale_pipeline_runs_returns_count_or_ids(self) -> None:
        sql = read_stale_finalizer_sql().lower()

        self.assertIn("returns table", sql)
        self.assertIn("finalized_count integer", sql)
        self.assertIn("pipeline_run_ids uuid[]", sql)
        self.assertIn("array_agg", sql)


class CronHealthViewSqlTests(unittest.TestCase):
    def test_cron_health_view_returns_only_cron_runs(self) -> None:
        sql = read_cron_health_view_sql().lower()

        self.assertIn("create or replace view profit_cron_pipeline_run_health", sql)
        self.assertIn("from profit_pipeline_runs", sql)
        self.assertIn("run_source = 'cron'", sql)
        self.assertNotIn("run_source = 'manual'", sql)

    def test_cron_health_view_returns_only_terminal_statuses(self) -> None:
        sql = read_cron_health_view_sql().lower()

        self.assertIn("status in ('success', 'failed', 'partial')", sql)
        self.assertNotIn("'running'", sql)

    def test_cron_health_view_limits_to_latest_two(self) -> None:
        sql = read_cron_health_view_sql().lower()

        self.assertIn("limit 2", sql)

    def test_cron_health_view_orders_by_started_at_desc(self) -> None:
        sql = read_cron_health_view_sql().lower()

        self.assertIn("order by started_at desc", sql)

    def test_cron_health_view_exposes_error_summary(self) -> None:
        sql = read_cron_health_view_sql().lower()

        self.assertIn("summary->>'error_summary' as error_summary", sql)
        self.assertRegex(sql, r"\bsummary\b")

    def test_cron_health_view_is_recent_cron_failure_flag(self) -> None:
        sql = read_cron_health_view_sql().lower()

        self.assertIn("is_recent_cron_failure", sql)
        self.assertIn("status in ('failed', 'partial')", sql)
        self.assertIn("else false", sql)


if __name__ == "__main__":
    unittest.main()
