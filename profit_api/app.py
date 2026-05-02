from __future__ import annotations

import os
from typing import Any

from profit_api.dashboard import AdminDashboardService
from profit_api.supabase import SupabaseRestClient


def create_app() -> Any:
    try:
        from fastapi import FastAPI
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "FastAPI is not installed. Install app/backend requirements before serving."
        ) from exc

    supabase_url = os.environ["SUPABASE_URL"]
    service_role_key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]

    app = FastAPI(title="Outscore Profit API")
    service = AdminDashboardService(
        SupabaseRestClient(url=supabase_url, service_role_key=service_role_key)
    )

    @app.get("/api/profit/admin/dashboard")
    def admin_dashboard_snapshot(period: str | None = None) -> dict[str, object]:
        return service.snapshot(period_month=period)

    return app


app = create_app()
