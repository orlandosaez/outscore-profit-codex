from __future__ import annotations

import os
from typing import Any

from pydantic import BaseModel

from profit_api.dashboard import AdminDashboardService
from profit_api.manual_recognition import ManualRecognitionError, ManualRecognitionService
from profit_api.periods import validate_period_month
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


def create_app(
    service: AdminDashboardService | None = None,
    manual_recognition_service: ManualRecognitionService | None = None,
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

    return app


app = create_app()
