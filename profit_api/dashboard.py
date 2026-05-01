from __future__ import annotations

from typing import Protocol


DashboardRow = dict[str, object]


class SupabaseReader(Protocol):
    def read_view(self, view_name: str, **params: str | int) -> list[DashboardRow]:
        """Read rows from a Supabase REST view."""


class AdminDashboardService:
    def __init__(self, reader: SupabaseReader) -> None:
        self.reader = reader

    def snapshot(self) -> dict[str, object]:
        company_rows = self.reader.read_view(
            "profit_admin_company_dashboard_summary",
            limit=1,
        )
        return {
            "company": company_rows[0] if company_rows else {},
            "client_gp": self.reader.read_view(
                "profit_admin_client_gp_dashboard",
                order="period_month.desc,low_gp_rank.asc",
                limit=200,
            ),
            "staff_gp": self.reader.read_view(
                "profit_admin_staff_gp_dashboard",
                order="period_month.desc,staff_name.asc",
                limit=200,
            ),
            "comp_kicker_ledger": self.reader.read_view(
                "profit_admin_comp_kicker_ledger",
                order="period_month.desc,staff_name.asc",
                limit=200,
            ),
            "w2_candidates": self.reader.read_view(
                "profit_admin_w2_candidates",
                order="period_month.desc,staff_name.asc",
                limit=100,
            ),
            "fc_trigger_queue": self.reader.read_view(
                "profit_admin_fc_trigger_queue",
                order="completed_at.desc",
                limit=100,
            ),
        }

