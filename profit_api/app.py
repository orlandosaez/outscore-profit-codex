from __future__ import annotations

import os
from typing import Any

from profit_api.dashboard import AdminDashboardService
from profit_api.periods import validate_period_month
from profit_api.supabase import SupabaseRestClient


def create_app(service: AdminDashboardService | None = None) -> Any:
    try:
        from fastapi import FastAPI, HTTPException
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "FastAPI is not installed. Install app/backend requirements before serving."
        ) from exc

    supabase_url = os.environ["SUPABASE_URL"]
    service_role_key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]

    app = FastAPI(title="Outscore Profit API")
    dashboard_service = service or AdminDashboardService(
        SupabaseRestClient(url=supabase_url, service_role_key=service_role_key)
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

    return app


app = create_app()
