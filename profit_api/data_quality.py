"""V0.7.E.0.1 T1 — self-audit data quality service.

Reads from the Postgres view `profit_data_quality_alerts` (V0.7.E.0,
migrations 040 / 040a / 040b / 040c) and exposes it as JSON for the
admin UI + dashboard chip.
"""

from __future__ import annotations

from typing import Protocol


AlertRow = dict[str, object]


VALID_SEVERITIES = {"high", "medium", "low"}


class DataQualityStore(Protocol):
    def read_view(self, view_name: str, **params: object) -> list[AlertRow]:
        ...


class DataQualityValidationError(ValueError):
    """Raised when query parameters fail validation."""


class DataQualityService:
    """Lists self-audit alerts and produces a summary breakdown."""

    VIEW_NAME = "profit_data_quality_alerts"

    def __init__(self, store: DataQualityStore) -> None:
        self.store = store

    # ------------------------------------------------------------------
    # list_alerts
    # ------------------------------------------------------------------
    def list_alerts(
        self,
        *,
        severity: str | None = None,
        category: str | None = None,
        limit: int = 200,
        offset: int = 0,
    ) -> dict[str, object]:
        filters: dict[str, object] = {
            "order": "severity.asc,alert_category.asc,subject_name.asc",
            "limit": limit,
            "offset": offset,
        }
        if severity:
            sev = severity.lower()
            if sev not in VALID_SEVERITIES:
                raise DataQualityValidationError(
                    f"severity must be one of {sorted(VALID_SEVERITIES)}"
                )
            filters["severity"] = f"eq.{sev}"
        if category:
            # Allow operator to filter by specific alert_category code
            filters["alert_category"] = f"eq.{category}"

        rows = self.store.read_view(self.VIEW_NAME, **filters)
        return {
            "rows": [self._row_payload(row) for row in rows],
            "limit": limit,
            "offset": offset,
            "filters": {
                "severity": severity,
                "category": category,
            },
        }

    # ------------------------------------------------------------------
    # summary — counts by severity + category for chip / dashboard
    # ------------------------------------------------------------------
    def summary(self) -> dict[str, object]:
        rows = self.store.read_view(self.VIEW_NAME, limit=10000)

        by_severity: dict[str, int] = {"high": 0, "medium": 0, "low": 0}
        by_category: dict[str, int] = {}
        for row in rows:
            sev = str(row.get("severity") or "").lower()
            if sev in by_severity:
                by_severity[sev] += 1
            cat = str(row.get("alert_category") or "unknown")
            by_category[cat] = by_category.get(cat, 0) + 1

        if by_severity["high"] > 0:
            status = "critical"
        elif by_severity["medium"] > 0:
            status = "alerts"
        else:
            status = "clean"

        return {
            "total": len(rows),
            "audit_status": status,
            "by_severity": by_severity,
            "by_category": dict(
                sorted(by_category.items(), key=lambda kv: kv[1], reverse=True)
            ),
        }

    # ------------------------------------------------------------------
    @staticmethod
    def _row_payload(row: AlertRow) -> AlertRow:
        # Pass through, but coerce known fields to safe types for the FE.
        return {
            "alert_category": row.get("alert_category"),
            "severity": row.get("severity"),
            "subject_kind": row.get("subject_kind"),
            "subject_id": row.get("subject_id"),
            "subject_name": row.get("subject_name"),
            "fc_client_id": row.get("fc_client_id"),
            "anchor_relationship_id": row.get("anchor_relationship_id"),
            "description": row.get("description"),
            "action_url": row.get("action_url"),
            "detected_at": row.get("detected_at"),
        }
