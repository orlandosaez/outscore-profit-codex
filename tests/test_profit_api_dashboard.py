from __future__ import annotations

import unittest

from profit_api.dashboard import AdminDashboardService
from profit_api.supabase import SupabaseRestError


class FakeSupabaseReader:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str | int]]] = []

    def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
        self.calls.append((view_name, params))
        period_filter = params.get("period_month")
        selected_period = (
            str(period_filter).replace("eq.", "")
            if isinstance(period_filter, str)
            else None
        )
        rows: dict[str, list[dict[str, object]]] = {
            "profit_company_monthly_gp_recognition_basis": [
                {
                    "period_month": "2026-04-01",
                    "recognized_revenue_amount": 4750,
                    "contractor_labor_cost": 1526.42,
                    "gp_amount": 3223.58,
                    "gp_pct": 0.6786486486486486,
                    "matched_labor_cost": 1200,
                    "admin_labor_cost": 200,
                    "unmatched_labor_cost": 126.42,
                    "total_hours": 50,
                    "admin_hours": 5,
                    "admin_load_pct": 0.1,
                },
                {
                    "period_month": "2026-03-01",
                    "recognized_revenue_amount": 10000,
                    "contractor_labor_cost": 4200,
                    "gp_amount": 5800,
                    "gp_pct": 0.58,
                    "matched_labor_cost": 3000,
                    "admin_labor_cost": 800,
                    "unmatched_labor_cost": 400,
                    "total_hours": 100,
                    "admin_hours": 20,
                    "admin_load_pct": 0.2,
                }
            ],
            "profit_company_quarterly_gp_gate": [
                {
                    "quarter_start": "2026-01-01",
                    "gp_pct": 0.58,
                    "company_gate_gp_pct": 0.5,
                    "gate_passed": True,
                },
                {
                    "quarter_start": "2026-04-01",
                    "gp_pct": 0.6786486486486486,
                    "company_gate_gp_pct": 0.53,
                    "gate_passed": True,
                },
            ],
            "profit_revenue_event_status_summary": [
                {
                    "period_month": "2026-03-01",
                    "recognition_status": "recognized",
                    "source_amount": 10000,
                    "recognized_amount": 10000,
                    "event_count": 6,
                },
                {
                    "period_month": "2026-03-01",
                    "recognition_status": "pending_fc_trigger",
                    "source_amount": 2500,
                    "recognized_amount": 0,
                    "event_count": 2,
                },
            ],
            "profit_admin_client_gp_dashboard": [
                {
                    "period_month": selected_period or "2026-04-01",
                    "anchor_client_business_name": "Collectiv Inc.",
                    "macro_service_type": "bookkeeping",
                    "gp_amount": -200,
                }
            ],
            "profit_admin_staff_gp_dashboard": [
                {
                    "period_month": selected_period or "2026-04-01",
                    "staff_name": "Beth",
                    "owned_gp_amount": 1650,
                }
            ],
            "profit_admin_comp_kicker_ledger": [
                {
                    "period_month": selected_period or "2026-04-01",
                    "staff_name": "Beth",
                    "kicker_accrual_amount": 0,
                }
            ],
            "profit_admin_w2_candidates": [
                {
                    "staff_name": "Laura",
                    "w2_flag_status": "watch",
                }
            ],
            "profit_admin_fc_trigger_queue": [
                {
                    "client_name": "Maria V Schaffner",
                    "suggested_trigger_type": "tax_filed",
                }
            ],
            "profit_prepaid_liability_summary": [
                {
                    "tax_deferred_revenue_balance": 5000,
                    "trigger_backlog_balance": 7500,
                    "total_prepaid_liability_balance": 12500,
                    "trigger_backlog_note": "Delivered services with no recognition trigger loaded — not a QBO liability entry. Clears when FC completion triggers are approved.",
                    "client_balance_count": 3,
                    "collection_count": 4,
                    "last_updated": "2026-04-30",
                }
            ],
            "profit_prepaid_liability_balances": [
                {
                    "anchor_relationship_id": "relationship-collectiv",
                    "anchor_client_business_name": "Collectiv Inc.",
                    "macro_service_type": "tax",
                    "balance": 5000,
                    "last_updated": "2026-04-30",
                }
            ],
            "profit_prepaid_liability_ledger": [
                {
                    "anchor_relationship_id": "relationship-collectiv",
                    "macro_service_type": "tax",
                    "ledger_entry_type": "cash_collected",
                    "amount_delta": 5000,
                    "event_at": "2026-04-30",
                }
            ],
        }
        result = rows[view_name]
        if selected_period and view_name in {
            "profit_company_monthly_gp_recognition_basis",
            "profit_company_quarterly_gp_gate",
            "profit_revenue_event_status_summary",
        }:
            result = [
                row
                for row in result
                if row.get("period_month") == selected_period
                or row.get("quarter_start") == params.get("quarter_start", "").replace("eq.", "")
            ]
        return result


class AdminDashboardServiceTests(unittest.TestCase):
    def test_snapshot_reads_dashboard_views_into_stable_sections(self) -> None:
        reader = FakeSupabaseReader()
        snapshot = AdminDashboardService(reader).snapshot()

        self.assertEqual(snapshot["company"]["latest_period_month"], "2026-04-01")
        self.assertEqual(len(snapshot["client_gp"]), 1)
        self.assertEqual(len(snapshot["staff_gp"]), 1)
        self.assertEqual(len(snapshot["comp_kicker_ledger"]), 1)
        self.assertEqual(len(snapshot["w2_candidates"]), 1)
        self.assertEqual(len(snapshot["fc_trigger_queue"]), 1)

        self.assertIn("available_periods", snapshot)
        self.assertEqual(snapshot["available_periods"][0]["period_month"], "2026-04-01")

    def test_snapshot_applies_dashboard_limits_and_ordering(self) -> None:
        reader = FakeSupabaseReader()
        AdminDashboardService(reader).snapshot(period_month="2026-03-01")

        self.assertEqual(
            reader.calls[0],
            (
                "profit_company_monthly_gp_recognition_basis",
                {"order": "period_month.desc", "limit": 24},
            ),
        )
        self.assertEqual(
            reader.calls[1],
            (
                "profit_company_monthly_gp_recognition_basis",
                {"period_month": "eq.2026-03-01", "limit": 1},
            ),
        )
        self.assertEqual(
            reader.calls[2],
            (
                "profit_company_quarterly_gp_gate",
                {"quarter_start": "eq.2026-01-01", "limit": 1},
            ),
        )
        self.assertEqual(
            reader.calls[3],
            (
                "profit_revenue_event_status_summary",
                {"period_month": "eq.2026-03-01", "limit": 1000},
            ),
        )

        calls_by_view = {view_name: params for view_name, params in reader.calls}
        self.assertEqual(
            calls_by_view["profit_admin_client_gp_dashboard"],
            {
                "period_month": "eq.2026-03-01",
                "order": "low_gp_rank.asc,anchor_client_business_name.asc",
                "limit": 200,
            },
        )
        self.assertEqual(
            calls_by_view["profit_admin_staff_gp_dashboard"],
            {"period_month": "eq.2026-03-01", "order": "staff_name.asc", "limit": 200},
        )
        self.assertEqual(
            calls_by_view["profit_admin_comp_kicker_ledger"],
            {"period_month": "eq.2026-03-01", "order": "staff_name.asc", "limit": 200},
        )
        self.assertEqual(
            calls_by_view["profit_admin_w2_candidates"],
            {"order": "period_month.desc,staff_name.asc", "limit": 100},
        )
        self.assertEqual(
            calls_by_view["profit_admin_fc_trigger_queue"],
            {"order": "completed_at.desc", "limit": 100},
        )

    def test_snapshot_computes_selected_period_ratio_summary(self) -> None:
        reader = FakeSupabaseReader()
        snapshot = AdminDashboardService(reader).snapshot(period_month="2026-03-01")

        self.assertEqual(snapshot["selected_period_month"], "2026-03-01")
        self.assertEqual(snapshot["company"]["latest_month_gp_pct"], 0.58)
        self.assertEqual(snapshot["company"]["recognized_revenue_amount"], 10000)
        self.assertEqual(snapshot["company"]["pending_revenue_amount"], 2500)
        self.assertEqual(snapshot["company"]["pending_revenue_event_count"], 2)
        self.assertEqual(snapshot["company"]["gate_passed"], True)

        self.assertEqual(
            snapshot["ratio_summary"],
            {
                "period_month": "2026-03-01",
                "recognized_revenue_amount": 10000,
                "client_labor_cost": 3000,
                "admin_labor_cost": 800,
                "unmatched_labor_cost": 400,
                "total_labor_cost": 4200,
                "client_labor_ler": 0.3,
                "admin_labor_ler": 0.08,
                "unmatched_labor_ler": 0.04,
                "total_labor_ler": 0.42,
                "gross_margin_pct": 0.58,
                "client_matched_pct": 3000 / 4200,
                "admin_load_pct": 0.2,
            },
        )

    def test_snapshot_labels_blocks_that_do_not_use_period_selector(self) -> None:
        snapshot = AdminDashboardService(FakeSupabaseReader()).snapshot(
            period_month="2026-03-01"
        )

        self.assertEqual(
            snapshot["fixed_windows"]["w2_candidates"],
            "Latest trailing 8-month W2 watch window; not filtered by selected month.",
        )
        self.assertEqual(
            snapshot["fixed_windows"]["fc_trigger_queue"],
            "Live FC trigger queue; not filtered by selected month.",
        )

    def test_snapshot_includes_cash_basis_prepaid_liability(self) -> None:
        snapshot = AdminDashboardService(FakeSupabaseReader()).snapshot()

        self.assertEqual(
            snapshot["prepaid_liability"]["summary"]["tax_deferred_revenue_balance"],
            5000,
        )
        self.assertEqual(
            snapshot["prepaid_liability"]["summary"]["trigger_backlog_balance"],
            7500,
        )
        self.assertEqual(
            snapshot["prepaid_liability"]["summary"]["total_prepaid_liability_balance"],
            12500,
        )
        self.assertIn(
            "not a QBO liability entry",
            snapshot["prepaid_liability"]["summary"]["trigger_backlog_note"],
        )
        self.assertNotIn("balances", snapshot["prepaid_liability"])
        self.assertNotIn("ledger", snapshot["prepaid_liability"])
        self.assertEqual(snapshot["prepaid_liability"]["collection_feed_status"], "loaded")
        self.assertIn(
            "cash collected but not yet recognized",
            snapshot["prepaid_liability"]["basis_note"],
        )

    def test_snapshot_includes_point_in_time_prepaid_summary_only(self) -> None:
        snapshot = AdminDashboardService(FakeSupabaseReader()).snapshot(
            period_month="2026-03-01"
        )

        prepaid = snapshot["prepaid_liability"]
        self.assertEqual(
            prepaid["window_label"],
            "Point-in-time balance; not filtered by selected month.",
        )
        self.assertEqual(prepaid["summary"]["tax_deferred_revenue_balance"], 5000)
        self.assertEqual(prepaid["summary"]["trigger_backlog_balance"], 7500)
        self.assertEqual(prepaid["summary"]["total_prepaid_liability_balance"], 12500)
        self.assertEqual(prepaid["summary"]["last_updated"], "2026-04-30")
        self.assertNotIn("balances", prepaid)
        self.assertNotIn("ledger", prepaid)

    def test_snapshot_tolerates_missing_prepaid_liability_views_until_migration_runs(self) -> None:
        class MissingPrepaidViewsReader(FakeSupabaseReader):
            def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
                if view_name.startswith("profit_prepaid_liability_"):
                    raise SupabaseRestError("missing view")
                return super().read_view(view_name, **params)

        snapshot = AdminDashboardService(MissingPrepaidViewsReader()).snapshot()

        self.assertEqual(
            snapshot["prepaid_liability"]["summary"]["tax_deferred_revenue_balance"],
            0,
        )
        self.assertEqual(
            snapshot["prepaid_liability"]["summary"]["trigger_backlog_balance"],
            0,
        )
        self.assertEqual(
            snapshot["prepaid_liability"]["summary"]["total_prepaid_liability_balance"],
            0,
        )
        self.assertNotIn("balances", snapshot["prepaid_liability"])
        self.assertNotIn("ledger", snapshot["prepaid_liability"])
        self.assertEqual(
            snapshot["prepaid_liability"]["collection_feed_status"],
            "not_loaded",
        )

    def test_snapshot_includes_company_gp_trend_from_available_periods(self) -> None:
        snapshot = AdminDashboardService(FakeSupabaseReader()).snapshot()

        self.assertEqual(
            snapshot["trends"]["company_gp"],
            [
                {
                    "period_month": "2026-03-01",
                    "gp_pct": 0.58,
                    "recognized_revenue_amount": 10000,
                    "contractor_labor_cost": 4200,
                },
                {
                    "period_month": "2026-04-01",
                    "gp_pct": 0.6786486486486486,
                    "recognized_revenue_amount": 4750,
                    "contractor_labor_cost": 1526.42,
                },
            ],
        )


if __name__ == "__main__":
    unittest.main()
