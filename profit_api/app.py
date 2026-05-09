from __future__ import annotations

import os
from typing import Any

from pydantic import BaseModel

from profit_api.audit import (
    AuditDashboardConflictError,
    AuditDashboardService,
    AuditDashboardValidationError,
)
from profit_api.dashboard import AdminDashboardService
from profit_api.manual_recognition import ManualRecognitionError, ManualRecognitionService
from profit_api.periods import validate_period_month
from profit_api.pipeline import (
    PipelineRunConflictError,
    PipelineService,
    PipelineTriggerError,
)
from profit_api.supabase import SupabaseRestClient


class ManualOverridePayload(BaseModel):
    revenue_event_key: str
    reason_code: str
    notes: str
    reference: str | None = None


class ManualOverrideBatchPayload(BaseModel):
    revenue_event_keys: list[str]
    reason_code: str
    notes: str
    reference: str | None = None


class AuditClassificationRowPayload(BaseModel):
    fc_client_id: int
    classification_id_to_supersede: int | None = None
    new_verdict_code: str
    re_evaluate_at: str | None = None
    notes: str = ""


class AuditClassificationPayload(BaseModel):
    request_id: str
    classified_by: str | None = None
    rows: list[AuditClassificationRowPayload]


class PipelineRunPayload(BaseModel):
    triggered_by: str | None = "orlando"


def create_app(
    service: AdminDashboardService | None = None,
    manual_recognition_service: ManualRecognitionService | None = None,
    audit_service: AuditDashboardService | None = None,
    pipeline_service: PipelineService | None = None,
) -> Any:
    try:
        from fastapi import FastAPI, HTTPException
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "FastAPI is not installed. Install app/backend requirements before serving."
        ) from exc

    supabase_url = os.environ["SUPABASE_URL"]
    service_role_key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]

    app = FastAPI(title="Outscore Profit API")
    supabase_client = SupabaseRestClient(
        url=supabase_url,
        service_role_key=service_role_key,
    )
    dashboard_service = service or AdminDashboardService(supabase_client)
    recognition_service = manual_recognition_service or ManualRecognitionService(
        supabase_client
    )
    audit_dashboard_service = audit_service or AuditDashboardService(supabase_client)
    pipeline_dashboard_service = pipeline_service or PipelineService(supabase_client)

    @app.get("/api/profit/admin/dashboard")
    def admin_dashboard_snapshot(period: str | None = None) -> dict[str, object]:
        try:
            period_month = validate_period_month(period)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return dashboard_service.snapshot(period_month=period_month)

    @app.get("/api/profit/admin/prepaid/balances")
    def prepaid_balances() -> dict[str, object]:
        return {"rows": dashboard_service.prepaid_balances()}

    @app.get("/api/profit/admin/prepaid/ledger")
    def prepaid_ledger(
        anchor_relationship_id: str | None = None,
        macro_service_type: str | None = None,
    ) -> dict[str, object]:
        if not anchor_relationship_id or not macro_service_type:
            raise HTTPException(
                status_code=422,
                detail="anchor_relationship_id and macro_service_type are required",
            )
        return {
            "rows": dashboard_service.prepaid_ledger(
                anchor_relationship_id=anchor_relationship_id,
                macro_service_type=macro_service_type,
            )
        }

    @app.get("/api/profit/admin/recognition/pending")
    def pending_recognition_events(
        client_filter: str | None = None,
        service_filter: str | None = None,
        period_filter: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            validated_period = validate_period_month(period_filter)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return {
            "rows": recognition_service.list_pending_revenue_events(
                client_filter=client_filter,
                service_filter=service_filter,
                period_filter=validated_period,
                limit=min(max(limit, 1), 200),
                offset=max(offset, 0),
            )
        }

    @app.post("/api/profit/admin/recognition/manual-override")
    def manual_recognition_override(
        payload: ManualOverridePayload,
    ) -> dict[str, object]:
        try:
            event = recognition_service.apply_manual_recognition(
                revenue_event_key=payload.revenue_event_key,
                reason_code=payload.reason_code,
                notes=payload.notes,
                reference=payload.reference,
            )
        except ManualRecognitionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return {"event": event}

    @app.post("/api/profit/admin/recognition/manual-override-batch")
    def manual_recognition_override_batch(
        payload: ManualOverrideBatchPayload,
    ) -> dict[str, object]:
        try:
            return recognition_service.apply_manual_recognition_batch(
                revenue_event_keys=payload.revenue_event_keys,
                reason_code=payload.reason_code,
                notes=payload.notes,
                reference=payload.reference,
            )
        except ManualRecognitionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/profit/admin/recognition/manual-overrides")
    def recent_manual_recognition_overrides(limit: int = 50) -> dict[str, object]:
        return {
            "rows": recognition_service.recent_overrides(
                limit=min(max(limit, 1), 100),
            )
        }

    @app.get("/api/profit/admin/audit/verdicts")
    def audit_verdicts() -> dict[str, object]:
        return {"rows": audit_dashboard_service.verdicts()}

    @app.get("/api/profit/admin/audit/filter-options")
    def audit_filter_options() -> dict[str, object]:
        return audit_dashboard_service.filter_options()

    @app.get("/api/profit/admin/audit/candidates")
    def audit_candidates(
        show_all: bool = False,
        verdict_code: str | None = None,
        staff: str | None = None,
        service_tag: str | None = None,
        group: str | None = None,
        re_evaluation_due: bool = False,
        search: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            rows = audit_dashboard_service.candidates(
                show_all=show_all,
                verdict_code=verdict_code,
                staff=staff,
                service_tag=service_tag,
                group=group,
                re_evaluation_due=re_evaluation_due,
                search=search,
                limit=min(max(limit, 1), 200),
                offset=max(offset, 0),
            )
        except ValueError as exc:
            raise HTTPException(
                status_code=422,
                detail={"field": "verdict_code", "message": str(exc)},
            ) from exc
        return {"rows": rows}

    @app.get("/api/profit/admin/audit/candidates/{fc_client_id}")
    def audit_candidate_detail(fc_client_id: int) -> dict[str, object]:
        try:
            return audit_dashboard_service.candidate_detail(fc_client_id)
        except LookupError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/profit/admin/audit/classifications")
    def audit_classifications(payload: AuditClassificationPayload) -> dict[str, object]:
        try:
            return audit_dashboard_service.apply_classifications(
                request_id=payload.request_id,
                classified_by=payload.classified_by,
                rows=[row.model_dump() for row in payload.rows],
            )
        except AuditDashboardValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc
        except AuditDashboardConflictError as exc:
            raise HTTPException(status_code=409, detail=exc.detail) from exc

    @app.get("/api/profit/admin/audit/qbo-category-gaps")
    def audit_qbo_category_gaps(
        limit: int = 100,
        offset: int = 0,
    ) -> dict[str, object]:
        return {
            "rows": audit_dashboard_service.qbo_category_gaps(
                limit=min(max(limit, 1), 200),
                offset=max(offset, 0),
            )
        }

    @app.get("/api/profit/admin/audit/pipeline-runs")
    def audit_pipeline_runs(limit: int = 20, offset: int = 0) -> dict[str, object]:
        return pipeline_dashboard_service.list_runs(
            limit=min(max(limit, 1), 200),
            offset=max(offset, 0),
        )

    @app.get("/api/profit/admin/audit/pipeline-runs/{pipeline_run_id}")
    def audit_pipeline_run_detail(pipeline_run_id: str) -> dict[str, object]:
        try:
            return pipeline_dashboard_service.run_detail(pipeline_run_id)
        except (LookupError, ValueError) as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/profit/admin/audit/pipeline-runs")
    def audit_pipeline_run_trigger(payload: PipelineRunPayload) -> dict[str, object]:
        try:
            return pipeline_dashboard_service.trigger_manual_run(
                triggered_by=payload.triggered_by or "orlando",
            )
        except PipelineRunConflictError as exc:
            raise HTTPException(status_code=409, detail=exc.detail) from exc
        except PipelineTriggerError as exc:
            raise HTTPException(status_code=500, detail=exc.detail) from exc

    return app


app = create_app()
