from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Protocol
from uuid import uuid4


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

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
    ) -> list[ManualRecognitionRow]:
        """Delete rows through Supabase REST."""


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

        now = datetime.now(timezone.utc)
        recognition_trigger_key = f"manual_override_{request.revenue_event_key}"
        trigger_row = self._trigger_row(
            pending_event=pending_rows[0],
            recognition_trigger_key=recognition_trigger_key,
            reason_code=request.reason_code,
            notes=request.notes.strip(),
            reference=request.reference,
            approved_at=now,
        )
        self.store.insert_rows(
            "profit_recognition_triggers",
            [trigger_row],
            on_conflict="recognition_trigger_key",
        )

        return self._apply_ready_event(
            revenue_event_key=request.revenue_event_key,
            recognition_trigger_key=recognition_trigger_key,
        )

    def apply_manual_recognition_batch(
        self,
        *,
        revenue_event_keys: list[str],
        reason_code: str,
        notes: str,
        reference: str | None,
    ) -> dict[str, object]:
        clean_keys = [key.strip() for key in revenue_event_keys if key.strip()]
        if len(clean_keys) < 2:
            raise ManualRecognitionError("batch recognition requires at least two events")
        if len(set(clean_keys)) != len(clean_keys):
            raise ManualRecognitionError("batch recognition keys must be unique")

        self._validate_reason_and_notes(reason_code=reason_code, notes=notes)

        pending_rows = self.store.read_view(
            "profit_manual_recognition_pending_events",
            revenue_event_key=f"in.({','.join(clean_keys)})",
            limit=len(clean_keys),
        )
        by_key = {str(row.get("revenue_event_key")): row for row in pending_rows}
        missing = [key for key in clean_keys if key not in by_key]
        if missing:
            raise ManualRecognitionError(
                f"pending revenue events were not found: {', '.join(missing)}"
            )

        sibling_groups = {
            (
                row.get("anchor_relationship_id"),
                row.get("macro_service_type"),
                row.get("candidate_period_month"),
            )
            for row in by_key.values()
        }
        if len(sibling_groups) != 1:
            raise ManualRecognitionError(
                "batch manual recognition requires events in the same sibling group"
            )

        batch_id = str(uuid4())
        now = datetime.now(timezone.utc)
        base_notes = notes.strip()
        trigger_rows: list[dict[str, object]] = []
        trigger_key_by_event: dict[str, str] = {}
        for key in clean_keys:
            pending_event = by_key[key]
            trigger_key = f"manual_override_{key}"
            trigger_key_by_event[key] = trigger_key
            prefixed_notes = f"[{self._format_money(pending_event.get('source_amount'))}] {base_notes}"
            trigger_rows.append(
                self._trigger_row(
                    pending_event=pending_event,
                    recognition_trigger_key=trigger_key,
                    reason_code=reason_code,
                    notes=prefixed_notes,
                    reference=reference,
                    approved_at=now,
                    batch_id=batch_id,
                )
            )

        applied_events: list[ManualRecognitionRow] = []
        try:
            self.store.insert_rows(
                "profit_recognition_triggers",
                trigger_rows,
                on_conflict="recognition_trigger_key",
            )
            for key in clean_keys:
                applied_events.append(
                    self._apply_ready_event(
                        revenue_event_key=key,
                        recognition_trigger_key=trigger_key_by_event[key],
                    )
                )
        except Exception as exc:
            self._rollback_batch(
                batch_id=batch_id,
                pending_rows=[by_key[key] for key in clean_keys],
                applied_events=applied_events,
            )
            if isinstance(exc, ManualRecognitionError):
                raise ManualRecognitionError(
                    f"batch recognition failed and was rolled back: {exc}"
                ) from exc
            raise

        return {
            "events": applied_events,
            "manual_override_batch_id": batch_id,
        }

    def _validate_request(self, request: ManualRecognitionRequest) -> None:
        if not request.revenue_event_key.strip():
            raise ManualRecognitionError("revenue_event_key is required")
        self._validate_reason_and_notes(
            reason_code=request.reason_code,
            notes=request.notes,
        )

    def _validate_reason_and_notes(self, *, reason_code: str, notes: str) -> None:
        if reason_code not in REASON_CODES:
            raise ManualRecognitionError("Invalid manual override reason_code")
        if not notes.strip():
            raise ManualRecognitionError("manual override notes are required")
        if reason_code == "other" and len(notes.strip()) < 20:
            raise ManualRecognitionError(
                "other requires notes of at least 20 characters"
            )

    def _trigger_row(
        self,
        *,
        pending_event: ManualRecognitionRow,
        recognition_trigger_key: str,
        reason_code: str,
        notes: str,
        reference: str | None,
        approved_at: datetime,
        batch_id: str | None = None,
    ) -> dict[str, object]:
        row = {
            "recognition_trigger_key": recognition_trigger_key,
            "source_system": "manual_override",
            "source_record_id": pending_event["revenue_event_key"],
            "anchor_relationship_id": pending_event["anchor_relationship_id"],
            "macro_service_type": pending_event["macro_service_type"],
            "service_period_month": pending_event["candidate_period_month"],
            "completion_date": approved_at.date().isoformat(),
            "trigger_type": "manual_recognition_approved",
            "recognition_action": "recognize_full_source_amount",
            "notes": notes,
            "manual_override_reason_code": reason_code,
            "manual_override_notes": notes,
            "manual_override_reference": reference,
            "manual_override_batch_id": batch_id,
            "approved_by": "orlando",
            "approved_at": approved_at.isoformat(),
            "raw": {
                "revenue_event_key": pending_event["revenue_event_key"],
                "reason_code": reason_code,
                "reference": reference,
                "manual_override_batch_id": batch_id,
            },
        }
        return row

    def _apply_ready_event(
        self,
        *,
        revenue_event_key: str,
        recognition_trigger_key: str,
    ) -> ManualRecognitionRow:
        ready_rows = self.store.read_view(
            "profit_revenue_events_ready_for_recognition",
            revenue_event_key=f"eq.{revenue_event_key}",
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
            filters={"revenue_event_key": f"eq.{revenue_event_key}"},
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

    def _rollback_batch(
        self,
        *,
        batch_id: str,
        pending_rows: list[ManualRecognitionRow],
        applied_events: list[ManualRecognitionRow],
    ) -> None:
        self.store.delete_rows(
            "profit_recognition_triggers",
            filters={"manual_override_batch_id": f"eq.{batch_id}"},
        )
        pending_by_key = {
            row["revenue_event_key"]: row
            for row in pending_rows
        }
        for applied in applied_events:
            key = applied["revenue_event_key"]
            original = pending_by_key[key]
            self.store.patch_rows(
                "profit_revenue_events",
                filters={"revenue_event_key": f"eq.{key}"},
                payload={
                    "recognized_amount": 0,
                    "recognition_date": None,
                    "recognition_period_month": None,
                    "recognition_status": original["recognition_status"],
                    "trigger_reference": None,
                },
            )

    def _format_money(self, value: object) -> str:
        amount = float(value or 0)
        if amount.is_integer():
            return f"${amount:,.0f}"
        return f"${amount:,.2f}"
