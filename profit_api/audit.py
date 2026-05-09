from __future__ import annotations

from datetime import date, datetime, timezone
from typing import Protocol
from uuid import UUID


AuditRow = dict[str, object]
UNCLASSIFIED_VERDICT = "__UNCLASSIFIED__"


class AuditDashboardStore(Protocol):
    def read_view(self, view_name: str, **params: object) -> list[AuditRow]:
        ...

    def insert_rows(
        self,
        table_name: str,
        rows: list[AuditRow],
        *,
        on_conflict: str | None = None,
    ) -> list[AuditRow]:
        ...

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
        payload: AuditRow,
    ) -> list[AuditRow]:
        ...

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
    ) -> list[AuditRow]:
        ...


class AuditDashboardValidationError(ValueError):
    def __init__(self, detail: dict[str, object]) -> None:
        super().__init__(str(detail.get("message") or "validation failed"))
        self.detail = detail


class AuditDashboardConflictError(ValueError):
    def __init__(self, detail: dict[str, object]) -> None:
        super().__init__(str(detail.get("message") or "conflict"))
        self.detail = detail


class AuditDashboardService:
    def __init__(self, store: AuditDashboardStore) -> None:
        self.store = store

    def verdicts(self) -> list[AuditRow]:
        rows = self.store.read_view("profit_classification_verdicts")
        return sorted(
            rows,
            key=lambda row: (
                str(row.get("category") or ""),
                str(row.get("label") or ""),
                str(row.get("verdict_code") or ""),
            ),
        )

    def filter_options(self) -> dict[str, object]:
        verdicts = self.verdicts()
        tags = self.store.read_view("profit_fc_client_tags")
        candidates = self.store.read_view("profit_fulfillment_audit_candidates")
        return {
            "verdicts": verdicts,
            "staff": self._sorted_tag_names(tags, "staff"),
            "service_tags": self._sorted_tag_names(tags, "service"),
            "groups": self._sorted_group_names(candidates),
        }

    def candidates(
        self,
        *,
        show_all: bool = False,
        verdict_code: str | None = None,
        staff: str | None = None,
        service_tag: str | None = None,
        group: str | None = None,
        re_evaluation_due: bool = False,
        search: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[AuditRow]:
        verdicts_by_code = {
            str(row.get("verdict_code")): row
            for row in self.verdicts()
            if row.get("verdict_code") is not None
        }
        if verdict_code and verdict_code != UNCLASSIFIED_VERDICT:
            if verdict_code not in verdicts_by_code:
                raise ValueError("invalid verdict_code")

        rows = [
            dict(row)
            for row in self.store.read_view("profit_fulfillment_audit_candidates")
        ]
        tags = self.store.read_view("profit_fc_client_tags")
        service_tags_by_client = self._tags_by_client(tags, "service")
        staff_by_client = self._tags_by_client(tags, "staff")
        revenue_by_classification = self._estimated_revenue_by_classification()

        enriched: list[AuditRow] = []
        for row in rows:
            fc_client_id = self._int_or_none(row.get("fc_client_id"))
            classification_id = self._int_or_none(row.get("current_classification_id"))
            row["service_tags"] = (
                service_tags_by_client.get(fc_client_id, []) if fc_client_id else []
            )
            row["estimated_annual_revenue"] = (
                revenue_by_classification.get(classification_id)
                if classification_id
                else None
            )
            enriched.append(row)

        filtered = [
            row
            for row in enriched
            if self._candidate_matches(
                row,
                show_all=show_all,
                verdict_code=verdict_code,
                staff=staff,
                service_tag=service_tag,
                group=group,
                re_evaluation_due=re_evaluation_due,
                search=search,
                staff_by_client=staff_by_client,
            )
        ]
        return filtered[offset : offset + limit]

    def candidate_detail(self, fc_client_id: int) -> dict[str, object]:
        clients = [
            row
            for row in self.store.read_view(
                "profit_fc_clients",
                fc_client_id=f"eq.{fc_client_id}",
            )
            if self._int_or_none(row.get("fc_client_id")) == fc_client_id
        ]
        if not clients:
            raise LookupError("Client was not found.")

        candidate = self._single_row(
            "profit_fulfillment_audit_candidates",
            fc_client_id,
        )
        if candidate is None:
            raise ValueError("Client exists but is not in the audit candidate surface.")

        fc_activity = self._single_row("profit_fulfillment_audit_fc_activity", fc_client_id)
        anchor_signals = self._single_row(
            "profit_fulfillment_audit_anchor_signals",
            fc_client_id,
        )
        group_signals = self._single_row(
            "profit_fulfillment_audit_group_signals",
            fc_client_id,
        )
        classification_history = self._classification_history(fc_client_id)
        recent_service_tasks = self._recent_service_tasks(fc_client_id)

        return {
            "candidate": candidate,
            "fc_activity": fc_activity or {},
            "anchor_signals": anchor_signals or {},
            "group_signals": group_signals or {},
            "classification_history": classification_history[:100],
            "classification_history_total_count": len(classification_history),
            "classification_history_truncated": len(classification_history) > 100,
            "transition_rules": self._transition_rules(
                candidate,
                fc_activity or {},
                anchor_signals or {},
                group_signals or {},
            ),
            "recent_service_tasks": recent_service_tasks[:20],
        }

    def apply_classifications(
        self,
        *,
        request_id: str,
        rows: list[AuditRow],
        classified_by: str | None = None,
    ) -> dict[str, object]:
        normalized_request_id = self._validate_request_id(request_id)
        self._validate_row_count(rows)
        verdicts_by_code = {
            str(row.get("verdict_code")): row
            for row in self.verdicts()
            if row.get("verdict_code") is not None
        }
        self._validate_bulk_rows(rows, verdicts_by_code)

        request_hashes = {
            self._request_hash(normalized_request_id, row.get("fc_client_id"))
            for row in rows
        }
        existing_for_request = self._existing_manual_rows(request_hashes)
        if existing_for_request:
            if len(existing_for_request) == len(rows):
                return {
                    "request_id": normalized_request_id,
                    "applied_count": 0,
                    "rows": self._response_rows(existing_for_request),
                }
            raise AuditDashboardValidationError(
                {
                    "field": "request_id",
                    "message": "request_id was partially applied; manual review required",
                }
            )

        current_by_client = self._current_classifications_by_client()
        self._validate_concurrency(rows, current_by_client)

        inserted: list[AuditRow] = []
        try:
            new_rows = [
                self._build_classification_row(
                    row,
                    request_id=normalized_request_id,
                    classified_by=classified_by or "orlando",
                )
                for row in rows
            ]
            inserted = self.store.insert_rows("profit_classifications", new_rows)
            self._supersede_prior_rows(rows, inserted, current_by_client)
        except Exception:
            for request_hash in request_hashes:
                self.store.delete_rows(
                    "profit_classifications",
                    filters={
                        "source_audit_file": "eq.manual:/profit/admin/audit",
                        "source_audit_row_hash": f"eq.{request_hash}",
                    },
                )
            raise

        return {
            "request_id": normalized_request_id,
            "applied_count": len(inserted),
            "rows": self._response_rows(inserted),
        }

    def qbo_category_gaps(self, *, limit: int = 100, offset: int = 0) -> list[AuditRow]:
        rows = [
            dict(row)
            for row in self.store.read_view(
                "profit_fulfillment_audit_qbo_category_gaps"
            )
        ]
        return rows[offset : offset + limit]

    def _candidate_matches(
        self,
        row: AuditRow,
        *,
        show_all: bool,
        verdict_code: str | None,
        staff: str | None,
        service_tag: str | None,
        group: str | None,
        re_evaluation_due: bool,
        search: str | None,
        staff_by_client: dict[int, list[str]],
    ) -> bool:
        if not show_all and row.get("default_visibility") != "show":
            return False
        if verdict_code == UNCLASSIFIED_VERDICT and row.get("current_verdict_code"):
            return False
        if verdict_code and verdict_code != UNCLASSIFIED_VERDICT:
            if row.get("current_verdict_code") != verdict_code:
                return False
        if staff:
            fc_client_id = self._int_or_none(row.get("fc_client_id"))
            if not fc_client_id or staff not in staff_by_client.get(fc_client_id, []):
                return False
        if service_tag and service_tag not in row.get("service_tags", []):
            return False
        if group and group not in (row.get("group_names") or []):
            return False
        if re_evaluation_due and not self._is_due(row.get("re_evaluate_at")):
            return False
        if search:
            haystack = " ".join(
                str(row.get(key) or "")
                for key in ("fc_client_name", "anchor_client_business_name")
            ).lower()
            if search.lower() not in haystack:
                return False
        return True

    def _validate_request_id(self, request_id: str) -> str:
        try:
            return str(UUID(str(request_id)))
        except (TypeError, ValueError):
            raise AuditDashboardValidationError(
                {"field": "request_id", "message": "request_id must be a valid UUID"}
            )

    def _validate_row_count(self, rows: list[AuditRow]) -> None:
        if not 1 <= len(rows) <= 200:
            raise AuditDashboardValidationError(
                {"field": "rows", "message": "row count must be 1..200"}
            )

    def _validate_bulk_rows(
        self,
        rows: list[AuditRow],
        verdicts_by_code: dict[str, AuditRow],
    ) -> None:
        for index, row in enumerate(rows):
            verdict_code = row.get("new_verdict_code")
            if verdict_code not in verdicts_by_code:
                raise AuditDashboardValidationError(
                    {
                        "row_index": index,
                        "field": "new_verdict_code",
                        "message": "unknown verdict_code",
                    }
                )
            verdict = verdicts_by_code[str(verdict_code)]
            notes = str(row.get("notes") or "").strip()
            if verdict.get("category") in ("mixed", "leak", "manual_review") and not notes:
                raise AuditDashboardValidationError(
                    {
                        "row_index": index,
                        "field": "notes",
                        "message": "notes are required for this verdict category",
                    }
                )
            if verdict.get("requires_re_evaluate_at") is True and not row.get("re_evaluate_at"):
                raise AuditDashboardValidationError(
                    {
                        "row_index": index,
                        "field": "re_evaluate_at",
                        "message": "re_evaluate_at is required for this verdict",
                    }
                )

    def _validate_concurrency(
        self,
        rows: list[AuditRow],
        current_by_client: dict[int, AuditRow],
    ) -> None:
        for index, row in enumerate(rows):
            fc_client_id = self._int_or_none(row.get("fc_client_id"))
            expected_id = self._int_or_none(row.get("classification_id_to_supersede"))
            current = current_by_client.get(fc_client_id or -1)
            current_id = self._int_or_none(current.get("classification_id")) if current else None
            if expected_id == current_id:
                continue
            if expected_id is None and current is None:
                continue
            raise AuditDashboardConflictError(
                {
                    "row_index": index,
                    "fc_client_id": fc_client_id,
                    "expected_classification_id_to_supersede": expected_id,
                    "current_classification_id": current_id,
                    "current_verdict_code": current.get("verdict_code") if current else None,
                    "message": "Row was updated since you loaded it. Refresh and retry.",
                }
            )

    def _current_classifications_by_client(self) -> dict[int, AuditRow]:
        result: dict[int, AuditRow] = {}
        for row in self.store.read_view("profit_classifications"):
            if row.get("superseded_at") is not None:
                continue
            fc_client_id = self._int_or_none(row.get("fc_client_id"))
            classification_id = self._int_or_none(row.get("classification_id")) or 0
            if not fc_client_id:
                continue
            existing_id = self._int_or_none(
                result.get(fc_client_id, {}).get("classification_id")
            ) or 0
            if classification_id >= existing_id:
                result[fc_client_id] = dict(row)
        return result

    def _existing_manual_rows(self, request_hashes: set[str]) -> list[AuditRow]:
        rows = []
        for row in self.store.read_view("profit_classifications"):
            if row.get("source_audit_file") == "manual:/profit/admin/audit":
                if row.get("source_audit_row_hash") in request_hashes:
                    rows.append(dict(row))
        return rows

    def _build_classification_row(
        self,
        row: AuditRow,
        *,
        request_id: str,
        classified_by: str,
    ) -> AuditRow:
        fc_client_id = self._int_or_none(row.get("fc_client_id"))
        notes = str(row.get("notes") or "").strip()
        return {
            "fc_client_id": fc_client_id,
            "verdict_code": row.get("new_verdict_code"),
            "source_verdict_raw": row.get("new_verdict_code"),
            "source_audit_file": "manual:/profit/admin/audit",
            "source_audit_row_hash": self._request_hash(request_id, fc_client_id),
            "notes": f"[req:{request_id}] {notes}".strip(),
            "classified_by": classified_by,
            "re_evaluate_at": row.get("re_evaluate_at"),
            "last_signal_hash": f"manual_classification:{request_id}",
            "last_signal_at": datetime.now(timezone.utc).isoformat(),
        }

    def _supersede_prior_rows(
        self,
        requested_rows: list[AuditRow],
        inserted_rows: list[AuditRow],
        current_by_client: dict[int, AuditRow],
    ) -> None:
        inserted_by_client = {
            self._int_or_none(row.get("fc_client_id")): row
            for row in inserted_rows
        }
        for requested in requested_rows:
            fc_client_id = self._int_or_none(requested.get("fc_client_id"))
            current = current_by_client.get(fc_client_id or -1)
            if not current:
                continue
            inserted = inserted_by_client.get(fc_client_id)
            if not inserted:
                continue
            self.store.patch_rows(
                "profit_classifications",
                filters={
                    "classification_id": f"eq.{current.get('classification_id')}",
                },
                payload={
                    "superseded_at": datetime.now(timezone.utc).isoformat(),
                    "superseded_by_classification_id": inserted.get("classification_id"),
                    "updated_at": datetime.now(timezone.utc).isoformat(),
                },
            )

    def _request_hash(self, request_id: str, fc_client_id: object) -> str:
        return f"manual:{request_id}:{fc_client_id}"

    def _response_rows(self, rows: list[AuditRow]) -> list[AuditRow]:
        return [
            {
                "classification_id": row.get("classification_id"),
                "fc_client_id": row.get("fc_client_id"),
                "verdict_code": row.get("verdict_code"),
            }
            for row in rows
        ]

    def _estimated_revenue_by_classification(self) -> dict[int, object]:
        rows = self.store.read_view("profit_classifications")
        result: dict[int, object] = {}
        for row in rows:
            classification_id = self._int_or_none(row.get("classification_id"))
            if classification_id:
                result[classification_id] = row.get("estimated_annual_revenue")
        return result

    def _single_row(self, view_name: str, fc_client_id: int) -> AuditRow | None:
        for row in self.store.read_view(view_name, fc_client_id=f"eq.{fc_client_id}"):
            if self._int_or_none(row.get("fc_client_id")) == fc_client_id:
                return dict(row)
        return None

    def _classification_history(self, fc_client_id: int) -> list[AuditRow]:
        rows = [
            dict(row)
            for row in self.store.read_view(
                "profit_classifications",
                fc_client_id=f"eq.{fc_client_id}",
            )
            if self._int_or_none(row.get("fc_client_id")) == fc_client_id
        ]
        return sorted(
            rows,
            key=lambda row: (
                str(row.get("classified_at") or ""),
                self._int_or_none(row.get("classification_id")) or 0,
            ),
            reverse=True,
        )

    def _recent_service_tasks(self, fc_client_id: int) -> list[AuditRow]:
        rows = [
            dict(row)
            for row in self.store.read_view(
                "profit_fc_task_delivery_classification",
                fc_client_id=f"eq.{fc_client_id}",
            )
            if self._int_or_none(row.get("fc_client_id")) == fc_client_id
            and row.get("task_kind") == "service_delivery"
            and row.get("is_completed") is True
        ]
        return sorted(
            rows,
            key=lambda row: str(row.get("completed_at") or ""),
            reverse=True,
        )

    def _transition_rules(
        self,
        candidate: AuditRow,
        fc_activity: AuditRow,
        anchor_signals: AuditRow,
        group_signals: AuditRow,
    ) -> list[AuditRow]:
        current_verdict_code = candidate.get("current_verdict_code")
        if not current_verdict_code:
            return []
        rules = [
            dict(row)
            for row in self.store.read_view("profit_classification_transition_rules")
            if row.get("from_verdict_code") == current_verdict_code
            and row.get("enabled") is True
        ]
        return [
            {
                **rule,
                **self._transition_signal_state(
                    rule,
                    candidate,
                    fc_activity,
                    anchor_signals,
                    group_signals,
                ),
                "auto_apply_enabled": self._auto_apply_enabled(rule),
                "auto_apply_enabled_in_b2a": (
                    rule.get("signal_name") == "active_agreement_appears"
                    and rule.get("from_verdict_code")
                    in ("PENDING_ENGAGEMENT_DRAFT", "PENDING_ENGAGEMENT_SENT")
                ),
            }
            for rule in rules
        ]

    def _auto_apply_enabled(self, rule: AuditRow) -> bool:
        if rule.get("enabled") is not True:
            return False
        return (
            str(rule.get("from_verdict_code") or ""),
            str(rule.get("signal_name") or ""),
        ) in {
            ("PENDING_ENGAGEMENT_DRAFT", "active_agreement_appears"),
            ("PENDING_ENGAGEMENT_SENT", "active_agreement_appears"),
            (
                "LEGACY_ENGAGEMENT_PRE_ANCHOR",
                "first_matching_anchor_invoice_mid_cycle",
            ),
            (
                "LEGACY_ENGAGEMENT_PRE_ANCHOR",
                "first_matching_anchor_invoice_group_billed",
            ),
            (
                "INVOICE_OUTSTANDING_PAYMENT_PENDING",
                "cash_collected_group_parent",
            ),
            (
                "INVOICE_OUTSTANDING_PAYMENT_PENDING",
                "cash_collected_standalone_mid_cycle",
            ),
        }

    def _transition_signal_state(
        self,
        rule: AuditRow,
        candidate: AuditRow,
        fc_activity: AuditRow,
        anchor_signals: AuditRow,
        group_signals: AuditRow,
    ) -> dict[str, object]:
        signal_name = rule.get("signal_name")
        if signal_name == "active_agreement_appears":
            return self._signal(
                anchor_signals.get("anchor_display_status") == "active",
                "no active Anchor agreement.",
            )
        if signal_name == "first_matching_anchor_invoice_mid_cycle":
            return self._signal(
                anchor_signals.get("has_anchor_invoice_365d") is True,
                "no Anchor invoice in last 365 days.",
            )
        if signal_name == "first_matching_anchor_invoice_group_billed":
            has_invoice = anchor_signals.get("has_anchor_invoice_365d") is True
            has_group = group_signals.get("has_active_group_membership") is True
            if has_invoice and has_group:
                return self._signal(True, "")
            missing = []
            if not has_invoice:
                missing.append("no Anchor invoice in last 365 days")
            if not has_group:
                missing.append("no active group membership")
            return self._signal(False, "; ".join(missing) + ".")
        if signal_name in ("cash_collected_group_parent", "cash_collected_standalone_mid_cycle"):
            return self._signal(False, "cash collection signal requires V0.6.C pipeline data.")
        if str(signal_name or "").startswith("anchor_backfill_invoice_"):
            return self._signal(False, "V0.6.C pipeline scope.")
        if signal_name == "any_active_signal_returns":
            active_signal_returned = (
                fc_activity.get("fc_unarchived_after_archive") is True
                or fc_activity.get("fc_is_archived") is False
                or fc_activity.get("has_post_archive_service_delivery") is True
                or anchor_signals.get("anchor_display_status") == "active"
                or float(anchor_signals.get("open_invoice_balance_amount") or 0) > 0
            )
            return self._signal(
                active_signal_returned,
                "no post-classification inactive re-emergence signal is present.",
            )
        return self._signal(False, "signal is not derived in V0.6.B.2.b.")

    def _signal(self, present: bool, reason: str) -> dict[str, object]:
        return {
            "signal_present": present,
            "signal_reason": None if present else reason,
        }

    def _sorted_tag_names(self, tags: list[AuditRow], tag_type: str) -> list[str]:
        return sorted(
            {
                str(row.get("tag_name"))
                for row in tags
                if row.get("tag_type") == tag_type and row.get("tag_name")
            }
        )

    def _sorted_group_names(self, rows: list[AuditRow]) -> list[str]:
        names: set[str] = set()
        for row in rows:
            for name in row.get("group_names") or []:
                if name:
                    names.add(str(name))
        return sorted(names)

    def _tags_by_client(
        self,
        tags: list[AuditRow],
        tag_type: str,
    ) -> dict[int, list[str]]:
        result: dict[int, list[str]] = {}
        for row in tags:
            fc_client_id = self._int_or_none(row.get("fc_client_id"))
            tag_name = row.get("tag_name")
            if fc_client_id and tag_name and row.get("tag_type") == tag_type:
                result.setdefault(fc_client_id, []).append(str(tag_name))
        return {key: sorted(set(values)) for key, values in result.items()}

    def _int_or_none(self, value: object) -> int | None:
        if value is None:
            return None
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    def _is_due(self, value: object) -> bool:
        if not value:
            return False
        return str(value)[:10] <= date.today().isoformat()
