from __future__ import annotations

import datetime
from typing import Protocol


WeeklyReviewRow = dict[str, object]

# Verdict codes registered in profit_weekly_review_visible_verdicts.
# V0.7.A: MANUAL_INVOICE_PENDING; V0.7.B: SLA_BREACHED.
# V0.7.C-D will add additional codes here alongside the SQL seed.
VISIBLE_VERDICT_CODES: frozenset[str] = frozenset({"MANUAL_INVOICE_PENDING", "SLA_BREACHED"})

DEFAULT_LIMIT = 200  # V0.7.B.1: raised from 50 after V0.7.B's 14x queue-volume jump (69 rows) silently truncated V0.7.A manual-invoice rows at sort_rank 65-69
MAX_LIMIT = 200
DEFAULT_OPERATOR_ID = "orlando"
DEFAULT_SNOOZE_DAYS = 7


class WeeklyReviewStore(Protocol):
    def read_view(self, view_name: str, **params: object) -> list[WeeklyReviewRow]:
        ...

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        ...

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        ...


class WeeklyReviewValidationError(ValueError):
    def __init__(self, detail: dict[str, object]) -> None:
        super().__init__(str(detail.get("message") or "validation failed"))
        self.detail = detail


class WeeklyReviewService:
    def __init__(self, store: WeeklyReviewStore) -> None:
        self.store = store

    def list_items(
        self,
        *,
        include_reviewed: bool = False,
        include_snoozed: bool = False,
        verdict_code: str | None = None,
        limit: int = DEFAULT_LIMIT,
        offset: int = 0,
    ) -> dict[str, object]:
        """Return the weekly review queue, applying default exclusion filters.

        Default behavior: excludes reviewed rows and currently-snoozed rows.
        Rows with an expired snoozed_until (< today) resurface automatically.
        """
        if verdict_code is not None and verdict_code not in VISIBLE_VERDICT_CODES:
            raise WeeklyReviewValidationError(
                {
                    "field": "verdict_code",
                    "message": "unsupported verdict_code",
                    "allowed": sorted(VISIBLE_VERDICT_CODES),
                }
            )

        clamped_limit = min(max(int(limit), 1), MAX_LIMIT)
        clamped_offset = max(int(offset), 0)
        today = datetime.date.today()

        rows = [dict(r) for r in self.store.read_view("profit_weekly_review_items")]

        filtered: list[WeeklyReviewRow] = []
        for row in rows:
            # verdict_code filter
            if verdict_code is not None and row.get("verdict_code") != verdict_code:
                continue

            # reviewed exclusion (default: hide reviewed rows)
            if not include_reviewed and row.get("reviewed_at") is not None:
                continue

            # snoozed exclusion (default: hide rows where snoozed_until >= today)
            if not include_snoozed:
                snoozed_until = row.get("snoozed_until")
                if snoozed_until is not None:
                    if isinstance(snoozed_until, str):
                        snoozed_date = datetime.date.fromisoformat(snoozed_until)
                    elif isinstance(snoozed_until, datetime.date):
                        snoozed_date = snoozed_until
                    else:
                        snoozed_date = datetime.date.fromisoformat(str(snoozed_until))
                    if snoozed_date >= today:
                        continue

            filtered.append(row)

        # Sort by SQL-provided sort_rank ascending (lower = more urgent), nulls last
        filtered.sort(key=lambda r: (r.get("sort_rank") is None, r.get("sort_rank") or 0))

        return {
            "rows": filtered[clamped_offset : clamped_offset + clamped_limit],
            "limit": clamped_limit,
            "offset": clamped_offset,
            "total_count": len(filtered),
        }

    def mark_reviewed(
        self,
        classification_id: int,
        *,
        operator_id: str = DEFAULT_OPERATOR_ID,
    ) -> dict[str, object]:
        """Mark a queue item as reviewed. Upserts profit_weekly_review_item_state."""
        if classification_id <= 0:
            raise WeeklyReviewValidationError(
                {
                    "field": "classification_id",
                    "message": "classification_id must be a positive integer",
                }
            )

        now_str = datetime.datetime.now(datetime.timezone.utc).isoformat()

        updated = self.store.patch_rows(
            "profit_weekly_review_item_state",
            filters={"classification_id": f"eq.{classification_id}"},
            payload={"reviewed_at": now_str, "updated_at": now_str},
        )
        if not updated:
            self.store.insert_rows(
                "profit_weekly_review_item_state",
                [
                    {
                        "classification_id": classification_id,
                        "reviewed_at": now_str,
                        "operator_id": operator_id,
                    }
                ],
                on_conflict="classification_id",
            )

        return {
            "classification_id": classification_id,
            "reviewed_at": now_str,
            "operator_id": operator_id,
        }

    def snooze(
        self,
        classification_id: int,
        *,
        days: int = DEFAULT_SNOOZE_DAYS,
        operator_id: str = DEFAULT_OPERATOR_ID,
    ) -> dict[str, object]:
        """Snooze a queue item for `days` days. Upserts profit_weekly_review_item_state."""
        if classification_id <= 0:
            raise WeeklyReviewValidationError(
                {
                    "field": "classification_id",
                    "message": "classification_id must be a positive integer",
                }
            )

        snoozed_until = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
        now_str = datetime.datetime.now(datetime.timezone.utc).isoformat()

        updated = self.store.patch_rows(
            "profit_weekly_review_item_state",
            filters={"classification_id": f"eq.{classification_id}"},
            payload={"snoozed_until": snoozed_until, "updated_at": now_str},
        )
        if not updated:
            self.store.insert_rows(
                "profit_weekly_review_item_state",
                [
                    {
                        "classification_id": classification_id,
                        "snoozed_until": snoozed_until,
                        "operator_id": operator_id,
                    }
                ],
                on_conflict="classification_id",
            )

        return {
            "classification_id": classification_id,
            "snoozed_until": snoozed_until,
            "operator_id": operator_id,
        }
