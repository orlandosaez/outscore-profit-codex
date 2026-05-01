from __future__ import annotations

import unittest

from profit_api.dashboard import AdminDashboardService


class FakeSupabaseReader:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str | int]]] = []

    def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
        self.calls.append((view_name, params))
        rows: dict[str, list[dict[str, object]]] = {
            "profit_admin_company_dashboard_summary": [
                {
                    "latest_period_month": "2026-04-01",
                    "latest_month_gp_pct": 0.6786486486486486,
                    "gate_passed": True,
                }
            ],
            "profit_admin_client_gp_dashboard": [
                {
                    "anchor_client_business_name": "Collectiv Inc.",
                    "macro_service_type": "bookkeeping",
                    "gp_amount": -200,
                }
            ],
            "profit_admin_staff_gp_dashboard": [
                {
                    "staff_name": "Beth",
                    "owned_gp_amount": 1650,
                }
            ],
            "profit_admin_comp_kicker_ledger": [
                {
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
        }
        return rows[view_name]


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

        self.assertEqual(
            [call[0] for call in reader.calls],
            [
                "profit_admin_company_dashboard_summary",
                "profit_admin_client_gp_dashboard",
                "profit_admin_staff_gp_dashboard",
                "profit_admin_comp_kicker_ledger",
                "profit_admin_w2_candidates",
                "profit_admin_fc_trigger_queue",
            ],
        )

    def test_snapshot_applies_dashboard_limits_and_ordering(self) -> None:
        reader = FakeSupabaseReader()
        AdminDashboardService(reader).snapshot()

        self.assertEqual(reader.calls[0][1], {"limit": 1})
        self.assertEqual(
            reader.calls[1][1],
            {"order": "period_month.desc,low_gp_rank.asc", "limit": 200},
        )
        self.assertEqual(
            reader.calls[2][1],
            {"order": "period_month.desc,staff_name.asc", "limit": 200},
        )
        self.assertEqual(
            reader.calls[3][1],
            {"order": "period_month.desc,staff_name.asc", "limit": 200},
        )
        self.assertEqual(
            reader.calls[4][1],
            {"order": "period_month.desc,staff_name.asc", "limit": 100},
        )
        self.assertEqual(
            reader.calls[5][1],
            {"order": "completed_at.desc", "limit": 100},
        )


if __name__ == "__main__":
    unittest.main()
