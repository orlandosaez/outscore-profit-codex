from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime
from typing import Iterable, Mapping

from profit_import.anchor_matching import normalize_client_name


@dataclass(frozen=True)
class QboPayment:
    qbo_payment_id: str
    txn_date: date
    total_amount: float
    customer_name: str
    memo: str
    linked_invoice_ids: list[str]
    raw_payload: Mapping[str, object]


@dataclass(frozen=True)
class PaymentInvoiceMatch:
    match_status: str
    match_reason: str
    candidate_count: int
    anchor_invoice_id: str | None
    anchor_relationship_id: str | None


@dataclass(frozen=True)
class RevenueEventCandidate:
    revenue_event_key: str
    anchor_invoice_id: str
    source_amount: float
    already_allocated_amount: float = 0.0


def build_cash_collection_row(
    payment: QboPayment,
    anchor_invoice_id: str | None = None,
    anchor_relationship_id: str | None = None,
) -> dict[str, object]:
    return {
        "collection_key": f"qbo_payment_{payment.qbo_payment_id}",
        "source_system": "qbo",
        "source_payment_id": payment.qbo_payment_id,
        "anchor_invoice_id": anchor_invoice_id,
        "anchor_relationship_id": anchor_relationship_id,
        "qbo_payment_id": payment.qbo_payment_id,
        "collected_at": payment.txn_date.isoformat(),
        "collected_amount": _money(payment.total_amount),
        "currency": "USD",
        "collection_status": "collected",
        "raw_payload": dict(payment.raw_payload),
    }


def match_payment_to_anchor_invoice(
    payment: QboPayment,
    anchor_invoices: Iterable[Mapping[str, object]],
    date_window_days: int = 14,
    qbo_invoice_to_anchor_invoice_ids: Mapping[str, str] | None = None,
) -> PaymentInvoiceMatch:
    invoices = list(anchor_invoices)
    by_invoice_id = {
        str(invoice.get("anchor_invoice_id")): invoice
        for invoice in invoices
        if invoice.get("anchor_invoice_id")
    }

    qbo_invoice_map = qbo_invoice_to_anchor_invoice_ids or {}
    for invoice_id in _candidate_invoice_ids(payment):
        mapped_anchor_invoice_id = qbo_invoice_map.get(invoice_id)
        if mapped_anchor_invoice_id and mapped_anchor_invoice_id in by_invoice_id:
            invoice = by_invoice_id[mapped_anchor_invoice_id]
            return _make_match("matched", "linked_qbo_invoice_id", [invoice], invoice)
        invoice = by_invoice_id.get(invoice_id)
        if invoice:
            return _make_match("matched", "linked_invoice_id", [invoice], invoice)

    fallback_candidates = [
        invoice
        for invoice in invoices
        if _customer_matches(payment.customer_name, invoice)
        and _amount_matches(payment.total_amount, invoice)
        and _date_matches(payment.txn_date, invoice, date_window_days)
    ]
    if len(fallback_candidates) == 1:
        return _make_match(
            "matched",
            "customer_amount_date_window",
            fallback_candidates,
            fallback_candidates[0],
        )
    if len(fallback_candidates) > 1:
        return _make_match(
            "ambiguous",
            "multiple_customer_amount_date_window",
            fallback_candidates,
            None,
        )
    return PaymentInvoiceMatch("unmatched", "no_invoice_match", 0, None, None)


def allocate_payment_to_revenue_events(
    collection_key: str,
    collected_amount: float,
    revenue_events: Iterable[RevenueEventCandidate],
) -> list[dict[str, object]]:
    remaining_events = [
        (event, _money(event.source_amount - event.already_allocated_amount))
        for event in revenue_events
        if _money(event.source_amount - event.already_allocated_amount) > 0
    ]
    total_remaining = _money(sum(amount for _, amount in remaining_events))
    target_total = _money(min(collected_amount, total_remaining))
    if target_total <= 0 or total_remaining <= 0:
        return []

    rows: list[dict[str, object]] = []
    allocated_so_far = 0.0
    for index, (event, remaining_amount) in enumerate(remaining_events):
        is_final = index == len(remaining_events) - 1
        exact_allocation = target_total * (remaining_amount / total_remaining)
        rounded_allocation = _money(exact_allocation)
        rounding_delta = 0.0
        if is_final:
            final_allocation = _money(target_total - allocated_so_far)
            rounding_delta = _money(final_allocation - rounded_allocation)
            rounded_allocation = final_allocation
        else:
            allocated_so_far = _money(allocated_so_far + rounded_allocation)

        if rounded_allocation <= 0:
            continue
        rows.append(
            {
                "allocation_key": f"alloc_{collection_key}_{event.revenue_event_key}",
                "collection_key": collection_key,
                "revenue_event_key": event.revenue_event_key,
                "allocated_amount": rounded_allocation,
                "allocation_method": "invoice_prorata_by_remaining_source_amount",
                "rounding_delta": rounding_delta,
            }
        )
    return rows


def _candidate_invoice_ids(payment: QboPayment) -> list[str]:
    candidates: list[str] = []
    candidates.extend(payment.linked_invoice_ids)
    candidates.extend(re.findall(r"invoice-[A-Za-z0-9_-]+", payment.memo or ""))

    deduped: list[str] = []
    for candidate in candidates:
        if candidate and candidate not in deduped:
            deduped.append(candidate)
    return deduped


def _customer_matches(customer_name: str, invoice: Mapping[str, object]) -> bool:
    customer = normalize_client_name(customer_name)
    invoice_customer = normalize_client_name(
        invoice.get("anchor_client_business_name") or invoice.get("client_business_name") or ""
    )
    return bool(customer and invoice_customer and (customer == invoice_customer or customer in invoice_customer))


def _amount_matches(payment_amount: float, invoice: Mapping[str, object]) -> bool:
    invoice_amount = invoice.get("invoice_total")
    if invoice_amount is None:
        invoice_amount = invoice.get("total_amount")
    if invoice_amount is None:
        return False
    return abs(_money(payment_amount) - _money(float(invoice_amount))) <= 0.01


def _date_matches(payment_date: date, invoice: Mapping[str, object], date_window_days: int) -> bool:
    raw_date = invoice.get("issue_date") or invoice.get("due_date")
    invoice_date = _parse_date(raw_date)
    if invoice_date is None:
        return False
    return abs((payment_date - invoice_date).days) <= date_window_days


def _parse_date(value: object) -> date | None:
    if isinstance(value, date):
        return value
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).date()
    except ValueError:
        return None


def _make_match(
    status: str,
    reason: str,
    candidates: list[Mapping[str, object]],
    invoice: Mapping[str, object] | None,
) -> PaymentInvoiceMatch:
    return PaymentInvoiceMatch(
        match_status=status,
        match_reason=reason,
        candidate_count=len(candidates),
        anchor_invoice_id=str(invoice.get("anchor_invoice_id")) if invoice and invoice.get("anchor_invoice_id") else None,
        anchor_relationship_id=str(invoice.get("anchor_relationship_id"))
        if invoice and invoice.get("anchor_relationship_id")
        else None,
    )


def _money(value: float) -> float:
    return round(float(value) + 0.000000001, 2)
