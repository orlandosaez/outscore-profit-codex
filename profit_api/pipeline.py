from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from typing import Protocol
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import UUID

from profit_api.supabase import SupabaseRestError


PipelineRow = dict[str, object]
WEBHOOK_MAX_ATTEMPTS = 2
WEBHOOK_RETRY_BACKOFF_SECONDS = 3


class PipelineStore(Protocol):
    def read_view(self, view_name: str, **params: object) -> list[PipelineRow]:
        ...

    def insert_rows(
        self,
        table_name: str,
        rows: list[PipelineRow],
        *,
        on_conflict: str | None = None,
    ) -> list[PipelineRow]:
        ...

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
    ) -> list[PipelineRow]:
        ...


class PipelineWebhookClient(Protocol):
    def trigger(self, payload: PipelineRow) -> PipelineRow:
        ...


class PipelineRunConflictError(ValueError):
    def __init__(self, detail: dict[str, object]) -> None:
        super().__init__(str(detail.get("message") or "pipeline already running"))
        self.detail = detail


class PipelineTriggerError(RuntimeError):
    def __init__(self, detail: dict[str, object]) -> None:
        super().__init__(str(detail.get("message") or "pipeline trigger failed"))
        self.detail = detail


class N8nPipelineWebhookClient:
    def __init__(
        self,
        *,
        url: str | None = None,
        secret: str | None = None,
        opener=urlopen,
        timeout: int = 10,
    ) -> None:
        self.url = url or os.environ.get("PROFIT_PIPELINE_WEBHOOK_URL", "")
        self.secret = secret or os.environ.get("PROFIT_PIPELINE_WEBHOOK_SECRET", "")
        self.opener = opener
        self.timeout = timeout

    def trigger(self, payload: PipelineRow) -> PipelineRow:
        if not self.url:
            raise PipelineTriggerError(
                {
                    "message": "pipeline webhook URL is not configured",
                    "kind": "webhook_not_configured",
                }
            )
        last_error: PipelineTriggerError | None = None
        for attempt in range(1, WEBHOOK_MAX_ATTEMPTS + 1):
            try:
                return self._trigger_once(payload)
            except PipelineTriggerError as exc:
                last_error = exc
                if not self._is_retryable_error(exc):
                    raise
                if attempt == WEBHOOK_MAX_ATTEMPTS:
                    detail = dict(exc.detail)
                    detail["message"] = (
                        "pipeline webhook call failed after "
                        f"{WEBHOOK_MAX_ATTEMPTS} attempts"
                    )
                    raise PipelineTriggerError(detail) from exc
                time.sleep(WEBHOOK_RETRY_BACKOFF_SECONDS)
        detail = dict(last_error.detail if last_error else {})
        detail["message"] = (
            f"pipeline webhook call failed after {WEBHOOK_MAX_ATTEMPTS} attempts"
        )
        raise PipelineTriggerError(detail)

    def _trigger_once(self, payload: PipelineRow) -> PipelineRow:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if self.secret:
            headers["X-Profit-Pipeline-Secret"] = self.secret
        request = Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with self.opener(request, timeout=self.timeout) as response:
                body = response.read().decode("utf-8")
                parsed = json.loads(body) if body else {}
        except HTTPError as exc:
            raise PipelineTriggerError(self._http_error_detail(exc)) from exc
        except (URLError, TimeoutError) as exc:
            raise PipelineTriggerError(
                {
                    "message": "pipeline webhook call failed",
                    "error": str(exc),
                    "kind": "webhook_connection_error",
                }
            ) from exc
        except json.JSONDecodeError as exc:
            raise PipelineTriggerError(
                {
                    "message": "pipeline webhook response was not valid JSON",
                    "error": str(exc),
                    "kind": "webhook_invalid_json",
                }
            ) from exc
        return parsed if isinstance(parsed, dict) else {}

    def _http_error_detail(self, exc: HTTPError) -> dict[str, object]:
        body: dict[str, object] = {}
        if exc.fp is not None:
            try:
                raw_body = exc.fp.read().decode("utf-8")
                parsed = json.loads(raw_body) if raw_body else {}
                if isinstance(parsed, dict):
                    body = parsed
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                body = {}
        return {
            "message": "pipeline webhook call failed",
            "error": str(exc),
            "status_code": exc.code,
            "kind": "webhook_http_error",
            "body": body,
        }

    def _is_retryable_error(self, exc: PipelineTriggerError) -> bool:
        status_code = exc.detail.get("status_code")
        if exc.detail.get("kind") == "webhook_connection_error":
            return True
        if not isinstance(status_code, int):
            return False
        if status_code == 404:
            return True
        if 500 <= status_code <= 599:
            return not self._is_intentional_failure(exc.detail.get("body"))
        return False

    def _is_intentional_failure(self, body: object) -> bool:
        if not isinstance(body, dict):
            return False
        encoded = json.dumps(body, sort_keys=True).lower()
        return any(
            marker in encoded
            for marker in (
                '"intentional": true',
                '"intentional_failure": true',
                "intentional failure",
            )
        )


class PipelineService:
    def __init__(
        self,
        store: PipelineStore,
        *,
        webhook_client: PipelineWebhookClient | None = None,
    ) -> None:
        self.store = store
        self.webhook_client = webhook_client or N8nPipelineWebhookClient()

    def list_runs(self, *, limit: int = 20, offset: int = 0) -> dict[str, object]:
        rows = self.store.read_view(
            "profit_pipeline_runs",
            order="started_at.desc",
            limit=limit,
            offset=offset,
        )
        return {
            "rows": [self._run_payload(row) for row in rows],
            "limit": limit,
            "offset": offset,
        }

    def run_detail(self, pipeline_run_id: str) -> dict[str, object]:
        self._validate_uuid(pipeline_run_id)
        rows = self.store.read_view(
            "profit_pipeline_runs",
            pipeline_run_id=f"eq.{pipeline_run_id}",
            limit=1,
        )
        if not rows:
            raise LookupError("pipeline run was not found")
        steps = self.store.read_view(
            "profit_pipeline_run_steps",
            pipeline_run_id=f"eq.{pipeline_run_id}",
            order="step_order.asc",
        )
        return {
            "run": self._run_payload(rows[0]),
            "steps": [self._step_payload(step) for step in steps],
        }

    def trigger_manual_run(self, *, triggered_by: str | None = None) -> dict[str, object]:
        row = self._insert_running_row_with_retry(triggered_by=triggered_by or "orlando")
        pipeline_run_id = str(row["pipeline_run_id"])
        payload = {
            "pipeline_run_id": pipeline_run_id,
            "run_source": "manual",
            "triggered_by": row.get("triggered_by") or "orlando",
            "requested_at": datetime.now(timezone.utc).isoformat(),
            "requested_by": "profit_api",
        }
        # Webhook target must be deployed before this endpoint is operationally usable;
        # pre-Task-9 calls return 500 after running-row cleanup.
        try:
            self.webhook_client.trigger(payload)
        except Exception as exc:
            self.store.delete_rows(
                "profit_pipeline_runs",
                filters={"pipeline_run_id": f"eq.{pipeline_run_id}"},
            )
            if isinstance(exc, PipelineTriggerError):
                raise
            raise PipelineTriggerError(
                {
                    "message": "pipeline webhook call failed; running lock was released",
                    "error": str(exc),
                }
            ) from exc
        return {"run": self._run_payload(row)}

    def _insert_running_row_with_retry(self, *, triggered_by: str) -> PipelineRow:
        try:
            return self._insert_running_row(triggered_by=triggered_by)
        except SupabaseRestError as exc:
            if not self._is_running_conflict(exc):
                raise
            current = self._current_running_row()
            if current:
                raise PipelineRunConflictError(self._conflict_detail(current)) from exc
            try:
                return self._insert_running_row(triggered_by=triggered_by)
            except SupabaseRestError as retry_exc:
                if self._is_running_conflict(retry_exc):
                    current_after_retry = self._current_running_row()
                    if current_after_retry:
                        raise PipelineRunConflictError(
                            self._conflict_detail(current_after_retry)
                        ) from retry_exc
                    raise PipelineTriggerError(
                        {
                            "message": (
                                "pipeline running unique constraint fired but no "
                                "running row was found"
                            )
                        }
                    ) from retry_exc
                raise

    def _insert_running_row(self, *, triggered_by: str) -> PipelineRow:
        rows = self.store.insert_rows(
            "profit_pipeline_runs",
            [
                {
                    "run_source": "manual",
                    "status": "running",
                    "triggered_by": triggered_by,
                    "summary": {},
                }
            ],
        )
        if not rows:
            raise PipelineTriggerError(
                {"message": "pipeline run insert returned no rows"}
            )
        return rows[0]

    def _current_running_row(self) -> PipelineRow | None:
        rows = self.store.read_view(
            "profit_pipeline_runs",
            status="eq.running",
            order="started_at.desc",
            limit=1,
        )
        return rows[0] if rows else None

    def _conflict_detail(self, row: PipelineRow) -> dict[str, object]:
        return {
            "message": "Pipeline already running. Refresh again when complete.",
            "current_run_id": row.get("pipeline_run_id"),
            "started_at": row.get("started_at"),
            "triggered_by": row.get("triggered_by"),
        }

    def _is_running_conflict(self, exc: SupabaseRestError) -> bool:
        return (
            exc.postgres_code == "23505"
            and exc.constraint_name == "idx_profit_pipeline_runs_one_running"
        )

    def _run_payload(self, row: PipelineRow) -> PipelineRow:
        return {**row, "duration_seconds": self._duration_seconds(row)}

    def _step_payload(self, row: PipelineRow) -> PipelineRow:
        return {**row, "duration_seconds": self._duration_seconds(row)}

    def _duration_seconds(self, row: PipelineRow) -> int | None:
        started_at = self._parse_datetime(row.get("started_at"))
        finished_at = self._parse_datetime(row.get("finished_at"))
        if not started_at or not finished_at:
            return None
        return int((finished_at - started_at).total_seconds())

    def _parse_datetime(self, value: object) -> datetime | None:
        if not value:
            return None
        try:
            return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None

    def _validate_uuid(self, value: str) -> None:
        UUID(str(value))
