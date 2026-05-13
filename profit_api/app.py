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
from profit_api.data_quality import (
    DataQualityService,
    DataQualityValidationError,
)
from profit_api.manual_recognition import ManualRecognitionError, ManualRecognitionService
from profit_api.periods import validate_period_month
from profit_api.pipeline import (
    PipelineRunConflictError,
    PipelineService,
    PipelineTriggerError,
)
from profit_api.sla import SlaDashboardService, SlaDashboardValidationError
from profit_api.supabase import SupabaseRestClient
from profit_api.weekly_review import WeeklyReviewService, WeeklyReviewValidationError


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
    sla_service: SlaDashboardService | None = None,
    weekly_review_service: WeeklyReviewService | None = None,
    data_quality_service: DataQualityService | None = None,
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
    sla_dashboard_service = sla_service or SlaDashboardService(supabase_client)
    weekly_review_dashboard_service = weekly_review_service or WeeklyReviewService(supabase_client)
    data_quality_dashboard_service = data_quality_service or DataQualityService(supabase_client)

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

    # V0.7.E.0.1 T1 — self-audit data-quality alerts surface.
    # Reads profit_data_quality_alerts (11 alert categories A–K).
    @app.get("/api/profit/admin/data-quality-alerts")
    def data_quality_alerts(
        severity: str | None = None,
        category: str | None = None,
        limit: int = 200,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            return data_quality_dashboard_service.list_alerts(
                severity=severity,
                category=category,
                limit=min(max(limit, 1), 1000),
                offset=max(offset, 0),
            )
        except DataQualityValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/profit/admin/data-quality-alerts/summary")
    def data_quality_alerts_summary() -> dict[str, object]:
        return data_quality_dashboard_service.summary()

    @app.get("/api/profit/admin/sla/summary")
    def sla_summary() -> dict[str, object]:
        return sla_dashboard_service.summary()

    @app.get("/api/profit/admin/sla/clients")
    def sla_clients(
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            return sla_dashboard_service.clients(
                state=state,
                staff=staff,
                service=service,
                limit=limit,
                offset=offset,
            )
        except SlaDashboardValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.get("/api/profit/admin/sla/workload")
    def sla_workload(
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            return sla_dashboard_service.workload(
                state=state,
                staff=staff,
                service=service,
                limit=limit,
                offset=offset,
            )
        except SlaDashboardValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.get("/api/profit/admin/sla/queue")
    def sla_queue(
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            return sla_dashboard_service.queue(
                state=state,
                staff=staff,
                service=service,
                limit=limit,
                offset=offset,
            )
        except SlaDashboardValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.get("/api/profit/admin/sla/performance")
    def sla_performance(
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = 50,
        offset: int = 0,
        lookback_days: int | None = None,
    ) -> dict[str, object]:
        if lookback_days is not None:
            raise HTTPException(
                status_code=422,
                detail={
                    "field": "lookback_days",
                    "message": "performance lookback is fixed at 90 days",
                },
            )
        try:
            return sla_dashboard_service.performance(
                state=state,
                staff=staff,
                service=service,
                limit=limit,
                offset=offset,
            )
        except SlaDashboardValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.get("/api/profit/admin/sla/backfill")
    def sla_backfill(
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            return sla_dashboard_service.backfill(
                state=state,
                staff=staff,
                service=service,
                limit=limit,
                offset=offset,
            )
        except SlaDashboardValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.get("/api/profit/admin/weekly-review/items")
    def weekly_review_items(
        include_reviewed: bool = False,
        include_snoozed: bool = False,
        verdict_code: str | None = None,
        limit: int = 200,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            return weekly_review_dashboard_service.list_items(
                include_reviewed=include_reviewed,
                include_snoozed=include_snoozed,
                verdict_code=verdict_code,
                limit=limit,
                offset=offset,
            )
        except WeeklyReviewValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.post("/api/profit/admin/weekly-review/items/{classification_id}/reviewed")
    def weekly_review_mark_reviewed(classification_id: int) -> dict[str, object]:
        try:
            return weekly_review_dashboard_service.mark_reviewed(classification_id)
        except WeeklyReviewValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.post("/api/profit/admin/weekly-review/items/{classification_id}/snooze")
    def weekly_review_snooze(classification_id: int) -> dict[str, object]:
        try:
            return weekly_review_dashboard_service.snooze(classification_id)
        except WeeklyReviewValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.post("/api/profit/admin/weekly-review/items/{classification_id}/unsnooze")
    def weekly_review_unsnooze(classification_id: int) -> dict[str, object]:
        try:
            return weekly_review_dashboard_service.unsnooze(classification_id)
        except WeeklyReviewValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    @app.post("/api/profit/admin/weekly-review/items/{classification_id}/unreview")
    def weekly_review_unreview(classification_id: int) -> dict[str, object]:
        try:
            return weekly_review_dashboard_service.unreview(classification_id)
        except WeeklyReviewValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.detail) from exc

    return app


app = create_app()
