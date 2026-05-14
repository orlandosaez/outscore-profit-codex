"""V0.7.E.3 — Subscription Service Reserve profitability surface.

Reads from the Postgres view ``profit_subscription_service_reserve``
(migration 045) and exposes it as JSON for the admin UI.
"""

from __future__ import annotations

from typing import Protocol


ReserveRow = dict[str, object]


VALID_STATES = {"overbudget", "breakeven", "profitable", "no_labor_recorded", "no_fee"}


class ReserveStore(Protocol):
    def read_view(self, view_name: str, **params: object) -> list[ReserveRow]:
        ...


class SubscriptionReserveValidationError(ValueError):
    """Raised when filter params fail validation."""


class SubscriptionReserveService:
    VIEW_NAME = "profit_subscription_service_reserve"

    def __init__(self, store: ReserveStore) -> None:
        self.store = store

    # ------------------------------------------------------------------
    def list_clients(
        self,
        *,
        state: str | None = None,
        engagement_type: str | None = None,
        limit: int = 200,
        offset: int = 0,
    ) -> dict[str, object]:
        filters: dict[str, object] = {
            # Default order: overbudget first, then by margin pct asc (most painful first)
            "order": "monthly_contribution_margin_pct.asc.nullslast",
            "limit": limit,
            "offset": offset,
        }
        if state:
            s = state.lower()
            if s not in VALID_STATES:
                raise SubscriptionReserveValidationError(
                    f"state must be one of {sorted(VALID_STATES)}"
                )
            filters["profitability_state"] = f"eq.{s}"
        if engagement_type:
            filters["engagement_type"] = f"eq.{engagement_type}"

        rows = self.store.read_view(self.VIEW_NAME, **filters)
        return {
            "rows": [self._row_payload(r) for r in rows],
            "limit": limit,
            "offset": offset,
            "filters": {"state": state, "engagement_type": engagement_type},
        }

    # ------------------------------------------------------------------
    def summary(self) -> dict[str, object]:
        rows = self.store.read_view(self.VIEW_NAME, limit=10000)

        totals = {
            "client_count": len(rows),
            "total_monthly_subscription_fee": 0.0,
            "total_monthly_avg_labor_cost": 0.0,
            "total_monthly_contribution_margin": 0.0,
        }
        by_state: dict[str, int] = {
            "overbudget": 0,
            "breakeven": 0,
            "profitable": 0,
            "no_labor_recorded": 0,
            "no_fee": 0,
        }
        by_engagement: dict[str, int] = {}

        for r in rows:
            totals["total_monthly_subscription_fee"] += float(r.get("monthly_subscription_fee") or 0)
            totals["total_monthly_avg_labor_cost"] += float(r.get("monthly_avg_labor_cost") or 0)
            totals["total_monthly_contribution_margin"] += float(r.get("monthly_contribution_margin") or 0)
            state = str(r.get("profitability_state") or "")
            if state in by_state:
                by_state[state] += 1
            eng = str(r.get("engagement_type") or "unclassified")
            by_engagement[eng] = by_engagement.get(eng, 0) + 1

        # Round to 2dp for the API payload
        for k in (
            "total_monthly_subscription_fee",
            "total_monthly_avg_labor_cost",
            "total_monthly_contribution_margin",
        ):
            totals[k] = round(totals[k], 2)

        # Aggregate margin pct = total margin / total fee (weighted)
        agg_margin_pct = None
        if totals["total_monthly_subscription_fee"] > 0:
            agg_margin_pct = round(
                (totals["total_monthly_contribution_margin"]
                 / totals["total_monthly_subscription_fee"]) * 100.0,
                1,
            )

        return {
            **totals,
            "aggregate_margin_pct": agg_margin_pct,
            "by_state": by_state,
            "by_engagement_type": dict(sorted(by_engagement.items(), key=lambda kv: kv[1], reverse=True)),
        }

    # ------------------------------------------------------------------
    @staticmethod
    def _row_payload(row: ReserveRow) -> ReserveRow:
        return {
            "anchor_relationship_id": row.get("anchor_relationship_id"),
            "fc_client_id": row.get("fc_client_id"),
            "client_name": row.get("client_name"),
            "anchor_business_name": row.get("anchor_business_name"),
            "engagement_type": row.get("engagement_type"),
            "recurring_service_count": row.get("recurring_service_count"),
            "monthly_subscription_fee": row.get("monthly_subscription_fee"),
            "last_90d_labor_cost": row.get("last_90d_labor_cost"),
            "monthly_avg_labor_cost": row.get("monthly_avg_labor_cost"),
            "last_90d_hours": row.get("last_90d_hours"),
            "monthly_contribution_margin": row.get("monthly_contribution_margin"),
            "monthly_contribution_margin_pct": row.get("monthly_contribution_margin_pct"),
            "profitability_state": row.get("profitability_state"),
            "distinct_staff": row.get("distinct_staff"),
            "last_entry_date": row.get("last_entry_date"),
        }
