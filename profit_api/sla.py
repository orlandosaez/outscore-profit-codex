from __future__ import annotations

from typing import Protocol


SlaRow = dict[str, object]
SLA_STATES = {
    "on_track",
    "at_risk",
    "breached",
    "waiting_on_client",
    "not_applicable",
}
DEFAULT_LIMIT = 50
MAX_LIMIT = 200


class SlaDashboardStore(Protocol):
    def read_view(self, view_name: str, **params: object) -> list[SlaRow]:
        ...


class SlaDashboardValidationError(ValueError):
    def __init__(self, detail: dict[str, object]) -> None:
        super().__init__(str(detail.get("message") or "validation failed"))
        self.detail = detail


class SlaDashboardService:
    def __init__(self, store: SlaDashboardStore) -> None:
        self.store = store

    def summary(self) -> dict[str, object]:
        rows = self.store.read_view("profit_sla_client_status")
        states = {state: 0 for state in self._ordered_states()}
        for row in rows:
            state = row.get("sla_state")
            if state in states:
                states[str(state)] += 1
        return {
            "total_clients": len(rows),
            "states": states,
        }

    def clients(
        self,
        *,
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = DEFAULT_LIMIT,
        offset: int = 0,
    ) -> dict[str, object]:
        return self._list_view(
            "profit_sla_client_status",
            state=state,
            staff=staff,
            service=service,
            limit=limit,
            offset=offset,
        )

    def workload(
        self,
        *,
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = DEFAULT_LIMIT,
        offset: int = 0,
    ) -> dict[str, object]:
        return self._list_view(
            "profit_sla_staff_workload",
            state=state,
            staff=staff,
            service=service,
            limit=limit,
            offset=offset,
        )

    def queue(
        self,
        *,
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = DEFAULT_LIMIT,
        offset: int = 0,
    ) -> dict[str, object]:
        return self._list_view(
            "profit_sla_breach_queue",
            state=state,
            staff=staff,
            service=service,
            limit=limit,
            offset=offset,
        )

    def performance(
        self,
        *,
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = DEFAULT_LIMIT,
        offset: int = 0,
    ) -> dict[str, object]:
        payload = self._list_view(
            "profit_sla_staff_service_performance_90d",
            state=state,
            staff=staff,
            service=service,
            limit=limit,
            offset=offset,
        )
        payload["window_days"] = 90
        return payload

    def backfill(
        self,
        *,
        state: str | None = None,
        staff: str | None = None,
        service: str | None = None,
        limit: int = DEFAULT_LIMIT,
        offset: int = 0,
    ) -> dict[str, object]:
        return self._list_view(
            "profit_sla_anchor_backfill_queue",
            state=state,
            staff=staff,
            service=service,
            limit=limit,
            offset=offset,
        )

    def _list_view(
        self,
        view_name: str,
        *,
        state: str | None,
        staff: str | None,
        service: str | None,
        limit: int,
        offset: int,
    ) -> dict[str, object]:
        self._validate_state(state)
        clamped_limit = self._clamp_limit(limit)
        clamped_offset = self._clamp_offset(offset)
        rows = [dict(row) for row in self.store.read_view(view_name)]
        self._validate_filter_value(rows, "staff", staff)
        self._validate_filter_value(rows, "service", service)
        filtered = [
            row
            for row in rows
            if self._matches_state(row, state)
            and self._matches_staff(row, staff)
            and self._matches_service(row, service)
        ]
        return {
            "rows": filtered[clamped_offset : clamped_offset + clamped_limit],
            "limit": clamped_limit,
            "offset": clamped_offset,
            "total_count": len(filtered),
        }

    def _validate_state(self, state: str | None) -> None:
        if state is not None and state not in SLA_STATES:
            raise SlaDashboardValidationError(
                {
                    "field": "state",
                    "message": "state must be one of the locked SLA states",
                    "allowed": self._ordered_states(),
                }
            )

    def _validate_filter_value(
        self,
        rows: list[SlaRow],
        field: str,
        value: str | None,
    ) -> None:
        if value is None:
            return
        options = self._distinct_filter_values(rows, field)
        if value not in options:
            raise SlaDashboardValidationError(
                {
                    "field": field,
                    "message": f"unknown {field} filter",
                    "allowed": sorted(options),
                }
            )

    def _distinct_filter_values(self, rows: list[SlaRow], field: str) -> set[str]:
        keys = {
            "staff": ("assigned_staff_name", "staff_name"),
            "service": ("service_name",),
        }[field]
        values: set[str] = set()
        for row in rows:
            for key in keys:
                value = row.get(key)
                if value is not None:
                    values.add(str(value))
        return values

    def _matches_state(self, row: SlaRow, state: str | None) -> bool:
        return state is None or row.get("sla_state") == state

    def _matches_staff(self, row: SlaRow, staff: str | None) -> bool:
        if staff is None:
            return True
        return row.get("assigned_staff_name") == staff or row.get("staff_name") == staff

    def _matches_service(self, row: SlaRow, service: str | None) -> bool:
        return service is None or row.get("service_name") == service

    def _clamp_limit(self, limit: int) -> int:
        return min(max(int(limit), 1), MAX_LIMIT)

    def _clamp_offset(self, offset: int) -> int:
        return max(int(offset), 0)

    def _ordered_states(self) -> list[str]:
        return [
            "on_track",
            "at_risk",
            "breached",
            "waiting_on_client",
            "not_applicable",
        ]
