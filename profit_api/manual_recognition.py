from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Protocol


ManualRecognitionRow = dict[str, object]

REASON_CODES = {
    "backbill_pre_engagement",
    "client_operational_change",
    "entity_restructure",
    "service_outside_fc_scope",
    "fc_classifier_gap",
    "voided_invoice_replacement",
    "billing_amount_adjustment",
    "other",
}


class ManualRecognitionError(ValueError):
    pass


class ManualRecognitionStore(Protocol):
    def read_view(
        self,
        view_name: str,
        **params: str | int,
    ) -> list[ManualRecognitionRow]:
        """Read rows from Supabase REST."""

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[ManualRecognitionRow]:
        """Insert rows through Supabase REST."""

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
        payload: dict[str, object],
    ) -> list[ManualRecognitionRow]:
        """Patch rows through Supabase REST."""


@dataclass(frozen=True)
class ManualRecognitionRequest:
    revenue_event_key: str
    reason_code: str
    notes: str
    reference: str | None = None


class ManualRecognitionService:
    def __init__(self, store: ManualRecognitionStore) -> None:
        self.store = store

    def list_pending_revenue_events(
        self,
        *,
        client_filter: str | None = None,
        service_filter: str | None = None,
        period_filter: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[ManualRecognitionRow]:
        params: dict[str, str | int] = {
            "order": "candidate_period_month.desc,anchor_client_business_name.asc",
            "limit": limit,
            "offset": offset,
        }
        if client_filter:
            params["anchor_client_business_name"] = f"ilike.*{client_filter}*"
        if service_filter:
            params["macro_service_type"] = f"eq.{service_filter}"
        if period_filter:
            params["candidate_period_month"] = f"eq.{period_filter}"
        return self.store.read_view("profit_manual_recognition_pending_events", **params)

    def recent_overrides(self, *, limit: int = 50) -> list[ManualRecognitionRow]:
        return self.store.read_view(
            "profit_manual_recognition_override_audit",
            order="approved_at.desc",
            limit=limit,
        )

    def apply_manual_recognition(
        self,
        *,
        revenue_event_key: str,
        reason_code: str,
        notes: str,
        reference: str | None,
    ) -> dict[str, object]:
        request = ManualRecognitionRequest(
            revenue_event_key=revenue_event_key,
            reason_code=reason_code,
            notes=notes,
            reference=reference,
        )
        self._validate_request(request)

        pending_rows = self.store.read_view(
            "profit_manual_recognition_pending_events",
            revenue_event_key=f"eq.{request.revenue_event_key}",
            limit=1,
        )
        if not pending_rows:
            raise ManualRecognitionError("pending revenue event was not found")

        pending_event = pending_rows[0]
        now = datetime.now(timezone.utc)
        recognition_trigger_key = f"manual_override_{request.revenue_event_key}"
        trigger_row = {
            "recognition_trigger_key": recognition_trigger_key,
            "source_system": "manual_override",
            "source_record_id": request.revenue_event_key,
            "anchor_relationship_id": pending_event["anchor_relationship_id"],
            "macro_service_type": pending_event["macro_service_type"],
            "service_period_month": pending_event["candidate_period_month"],
            "completion_date": now.date().isoformat(),
            "trigger_type": "manual_recognition_approved",
            "recognition_action": "recognize_full_source_amount",
            "notes": request.notes.strip(),
            "manual_override_reason_code": request.reason_code,
            "manual_override_notes": request.notes.strip(),
            "manual_override_reference": request.reference,
            "approved_by": "orlando",
            "approved_at": now.isoformat(),
            "raw": {
                "revenue_event_key": request.revenue_event_key,
                "reason_code": request.reason_code,
                "reference": request.reference,
            },
        }
        self.store.insert_rows(
            "profit_recognition_triggers",
            [trigger_row],
            on_conflict="recognition_trigger_key",
        )

        ready_rows = self.store.read_view(
            "profit_revenue_events_ready_for_recognition",
            revenue_event_key=f"eq.{request.revenue_event_key}",
            recognition_trigger_key=f"eq.{recognition_trigger_key}",
            limit=1,
        )
        if not ready_rows:
            raise ManualRecognitionError(
                "manual override trigger did not produce a recognition-ready event"
            )

        ready = ready_rows[0]
        updated_rows = self.store.patch_rows(
            "profit_revenue_events",
            filters={"revenue_event_key": f"eq.{request.revenue_event_key}"},
            payload={
                "recognized_amount": ready["recognized_amount_to_apply"],
                "recognition_date": ready["recognition_date_to_apply"],
                "recognition_period_month": ready[
                    "recognition_period_month_to_apply"
                ],
                "recognition_status": ready["next_recognition_status"],
                "trigger_reference": ready["trigger_reference_to_apply"],
            },
        )
        if not updated_rows:
            raise ManualRecognitionError("manual recognition update returned no rows")
        return updated_rows[0]

    def _validate_request(self, request: ManualRecognitionRequest) -> None:
        if not request.revenue_event_key.strip():
            raise ManualRecognitionError("revenue_event_key is required")
        if request.reason_code not in REASON_CODES:
            raise ManualRecognitionError("Invalid manual override reason_code")
        if not request.notes.strip():
            raise ManualRecognitionError("manual override notes are required")
        if request.reason_code == "other" and len(request.notes.strip()) < 20:
            raise ManualRecognitionError(
                "other requires notes of at least 20 characters"
            )
