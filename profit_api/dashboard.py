from __future__ import annotations

from datetime import date
from typing import Protocol

from profit_api.supabase import SupabaseRestError


DashboardRow = dict[str, object]


class SupabaseReader(Protocol):
    def read_view(self, view_name: str, **params: str | int) -> list[DashboardRow]:
        """Read rows from a Supabase REST view."""


class AdminDashboardService:
    def __init__(self, reader: SupabaseReader) -> None:
        self.reader = reader

    def snapshot(self, period_month: str | None = None) -> dict[str, object]:
        available_periods = self.reader.read_view(
            "profit_company_monthly_gp_recognition_basis",
            order="period_month.desc",
            limit=24,
        )
        selected_period = period_month or _latest_period(available_periods)
        period_params = _period_params(selected_period)

        company_period_rows = self.reader.read_view(
            "profit_company_monthly_gp_recognition_basis",
            **period_params,
            limit=1,
        )
        company_period = company_period_rows[0] if company_period_rows else {}

        quarter_rows = self.reader.read_view(
            "profit_company_quarterly_gp_gate",
            quarter_start=f"eq.{_quarter_start(selected_period)}",
            limit=1,
        )
        quarter = quarter_rows[0] if quarter_rows else {}

        revenue_status_rows = self.reader.read_view(
            "profit_revenue_event_status_summary",
            **period_params,
            limit=1000,
        )
        company = _company_summary(
            selected_period=selected_period,
            period_row=company_period,
            quarter_row=quarter,
            revenue_status_rows=revenue_status_rows,
        )

        return {
            "selected_period_month": selected_period,
            "available_periods": [
                {"period_month": row.get("period_month")} for row in available_periods
            ],
            "company": company,
            "ratio_summary": _ratio_summary(company_period, selected_period),
            "fixed_windows": {
                "w2_candidates": "Latest trailing 8-month W2 watch window; not filtered by selected month.",
                "fc_trigger_queue": "Live FC trigger queue; not filtered by selected month.",
            },
            "prepaid_liability": _read_prepaid_liability(self.reader),
            "client_gp": self.reader.read_view(
                "profit_admin_client_gp_dashboard",
                **period_params,
                order="low_gp_rank.asc,anchor_client_business_name.asc",
                limit=200,
            ),
            "staff_gp": self.reader.read_view(
                "profit_admin_staff_gp_dashboard",
                **period_params,
                order="staff_name.asc",
                limit=200,
            ),
            "comp_kicker_ledger": self.reader.read_view(
                "profit_admin_comp_kicker_ledger",
                **period_params,
                order="staff_name.asc",
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


def _read_prepaid_liability(reader: SupabaseReader) -> dict[str, object]:
    basis_note = (
        "Prepaid liability is cash collected but not yet recognized; invoice/AR "
        "amounts are excluded until collection is allocated to revenue events."
    )
    default_summary = {
        "current_total_prepaid_liability": 0,
        "client_balance_count": 0,
        "last_updated": None,
    }

    try:
        summary_rows = reader.read_view("profit_prepaid_liability_summary", limit=1)
        balances = reader.read_view(
            "profit_prepaid_liability_balances",
            order="balance.desc,anchor_client_business_name.asc",
            limit=100,
        )
        ledger = reader.read_view(
            "profit_prepaid_liability_ledger",
            order="event_at.desc,anchor_relationship_id.asc",
            limit=100,
        )
    except SupabaseRestError:
        return {
            "summary": default_summary,
            "balances": [],
            "ledger": [],
            "basis_note": basis_note,
            "migration_status": "missing_prepaid_liability_views",
        }

    return {
        "summary": summary_rows[0] if summary_rows else default_summary,
        "balances": balances,
        "ledger": ledger,
        "basis_note": basis_note,
        "migration_status": "ready",
    }


def _latest_period(rows: list[DashboardRow]) -> str | None:
    if not rows:
        return None
    value = rows[0].get("period_month")
    return str(value) if value else None


def _period_params(period_month: str | None) -> dict[str, str]:
    return {"period_month": f"eq.{period_month}"} if period_month else {}


def _quarter_start(period_month: str | None) -> str:
    if not period_month:
        return ""
    year, month, _day = period_month.split("-")
    quarter_month = ((int(month) - 1) // 3) * 3 + 1
    return date(int(year), quarter_month, 1).isoformat()


def _company_summary(
    *,
    selected_period: str | None,
    period_row: DashboardRow,
    quarter_row: DashboardRow,
    revenue_status_rows: list[DashboardRow],
) -> dict[str, object]:
    recognized_amount = 0.0
    recognized_count = 0
    pending_amount = 0.0
    pending_count = 0

    for row in revenue_status_rows:
        status = str(row.get("recognition_status") or "")
        source_amount = _number(row.get("source_amount"))
        recognized_row_amount = _number(row.get("recognized_amount"))
        event_count = int(_number(row.get("event_count")))
        if status == "recognized" or recognized_row_amount:
            recognized_amount += recognized_row_amount
            recognized_count += event_count
        elif status.startswith("pending"):
            pending_amount += source_amount
            pending_count += event_count

    recognized_amount = _number(period_row.get("recognized_revenue_amount"))

    return {
        "latest_period_month": selected_period,
        "latest_month_gp_pct": period_row.get("gp_pct"),
        "latest_month_gp_amount": period_row.get("gp_amount"),
        "recognized_revenue_amount": recognized_amount,
        "recognized_revenue_event_count": recognized_count,
        "pending_revenue_amount": pending_amount,
        "pending_revenue_event_count": pending_count,
        "fc_ready_trigger_count": pending_count,
        "latest_quarter_gp_pct": quarter_row.get("gp_pct")
        if quarter_row.get("gp_pct") is not None
        else quarter_row.get("quarter_gp_pct"),
        "company_gate_gp_pct": quarter_row.get("company_gate_gp_pct"),
        "gate_passed": quarter_row.get("gate_passed"),
    }


def _ratio_summary(period_row: DashboardRow, period_month: str | None) -> dict[str, object]:
    revenue = _number(period_row.get("recognized_revenue_amount"))
    client_labor = _number(period_row.get("matched_labor_cost"))
    admin_labor = _number(period_row.get("admin_labor_cost"))
    unmatched_labor = _number(period_row.get("unmatched_labor_cost"))
    total_labor = _number(period_row.get("contractor_labor_cost"))

    return {
        "period_month": period_month,
        "recognized_revenue_amount": revenue,
        "client_labor_cost": client_labor,
        "admin_labor_cost": admin_labor,
        "unmatched_labor_cost": unmatched_labor,
        "total_labor_cost": total_labor,
        "client_labor_ler": _safe_div(client_labor, revenue),
        "admin_labor_ler": _safe_div(admin_labor, revenue),
        "unmatched_labor_ler": _safe_div(unmatched_labor, revenue),
        "total_labor_ler": _safe_div(total_labor, revenue),
        "gross_margin_pct": period_row.get("gp_pct"),
        "client_matched_pct": _safe_div(client_labor, total_labor),
        "admin_load_pct": period_row.get("admin_load_pct"),
    }


def _number(value: object) -> float:
    if value is None:
        return 0.0
    return float(value)


def _safe_div(numerator: float, denominator: float) -> float | None:
    if denominator == 0:
        return None
    return numerator / denominator
