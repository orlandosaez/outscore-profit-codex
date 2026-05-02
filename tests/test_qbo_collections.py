from __future__ import annotations

import unittest
from datetime import date

from profit_import.qbo_collections import (
    QboPayment,
    RevenueEventCandidate,
    allocate_payment_to_revenue_events,
    build_cash_collection_row,
    match_payment_to_anchor_invoice,
)


class QboCollectionTests(unittest.TestCase):
    def test_build_cash_collection_row_uses_qbo_as_cash_source_of_truth(self) -> None:
        payment = QboPayment(
            qbo_payment_id="987",
            txn_date=date(2026, 4, 30),
            total_amount=1250.0,
            customer_name="Collective",
            memo="Anchor invoice invoice-abc123",
            linked_invoice_ids=["invoice-abc123"],
            raw_payload={"Id": "987"},
        )

        row = build_cash_collection_row(payment, anchor_invoice_id="invoice-abc123")

        self.assertEqual(row["collection_key"], "qbo_payment_987")
        self.assertEqual(row["source_system"], "qbo")
        self.assertEqual(row["source_payment_id"], "987")
        self.assertEqual(row["qbo_payment_id"], "987")
        self.assertEqual(row["anchor_invoice_id"], "invoice-abc123")
        self.assertEqual(row["collected_at"], "2026-04-30")
        self.assertEqual(row["collected_amount"], 1250.0)
        self.assertEqual(row["collection_status"], "collected")

    def test_match_payment_prefers_linked_anchor_invoice_id(self) -> None:
        payment = QboPayment(
            qbo_payment_id="987",
            txn_date=date(2026, 4, 30),
            total_amount=1250.0,
            customer_name="Collective",
            memo="Paid via Anchor",
            linked_invoice_ids=["invoice-abc123"],
            raw_payload={},
        )

        result = match_payment_to_anchor_invoice(
            payment,
            anchor_invoices=[
                {
                    "anchor_invoice_id": "invoice-abc123",
                    "anchor_relationship_id": "relationship-collective",
                    "anchor_client_business_name": "Collective",
                    "invoice_total": 1250.0,
                    "issue_date": "2026-04-29",
                }
            ],
        )

        self.assertEqual(result.anchor_invoice_id, "invoice-abc123")
        self.assertEqual(result.match_status, "matched")
        self.assertEqual(result.match_reason, "linked_invoice_id")

    def test_match_payment_maps_qbo_linked_invoice_id_to_anchor_invoice(self) -> None:
        payment = QboPayment(
            qbo_payment_id="987",
            txn_date=date(2026, 4, 30),
            total_amount=250.0,
            customer_name="Collective",
            memo="Partial payment",
            linked_invoice_ids=["712"],
            raw_payload={},
        )

        result = match_payment_to_anchor_invoice(
            payment,
            anchor_invoices=[
                {
                    "anchor_invoice_id": "invoice-abc123",
                    "anchor_relationship_id": "relationship-collective",
                    "anchor_client_business_name": "Collective",
                    "invoice_total": 1250.0,
                    "issue_date": "2026-04-29",
                }
            ],
            qbo_invoice_to_anchor_invoice_ids={"712": "invoice-abc123"},
        )

        self.assertEqual(result.anchor_invoice_id, "invoice-abc123")
        self.assertEqual(result.match_status, "matched")
        self.assertEqual(result.match_reason, "linked_qbo_invoice_id")

    def test_match_payment_falls_back_to_customer_amount_and_date_window(self) -> None:
        payment = QboPayment(
            qbo_payment_id="988",
            txn_date=date(2026, 4, 30),
            total_amount=1250.0,
            customer_name="Collective",
            memo="",
            linked_invoice_ids=[],
            raw_payload={},
        )

        result = match_payment_to_anchor_invoice(
            payment,
            anchor_invoices=[
                {
                    "anchor_invoice_id": "invoice-abc123",
                    "anchor_relationship_id": "relationship-collective",
                    "anchor_client_business_name": "Collective LLC",
                    "invoice_total": 1250.0,
                    "issue_date": "2026-04-18",
                }
            ],
            date_window_days=20,
        )

        self.assertEqual(result.anchor_invoice_id, "invoice-abc123")
        self.assertEqual(result.match_status, "matched")
        self.assertEqual(result.match_reason, "customer_amount_date_window")

    def test_match_payment_leaves_ambiguous_fallback_unallocated(self) -> None:
        payment = QboPayment(
            qbo_payment_id="989",
            txn_date=date(2026, 4, 30),
            total_amount=1250.0,
            customer_name="Collective",
            memo="",
            linked_invoice_ids=[],
            raw_payload={},
        )

        result = match_payment_to_anchor_invoice(
            payment,
            anchor_invoices=[
                {
                    "anchor_invoice_id": "invoice-abc123",
                    "anchor_client_business_name": "Collective",
                    "invoice_total": 1250.0,
                    "issue_date": "2026-04-18",
                },
                {
                    "anchor_invoice_id": "invoice-def456",
                    "anchor_client_business_name": "Collective",
                    "invoice_total": 1250.0,
                    "issue_date": "2026-04-20",
                },
            ],
        )

        self.assertIsNone(result.anchor_invoice_id)
        self.assertEqual(result.match_status, "ambiguous")
        self.assertEqual(result.match_reason, "multiple_customer_amount_date_window")

    def test_allocate_payment_prorates_partial_payment_and_logs_rounding_delta(self) -> None:
        allocations = allocate_payment_to_revenue_events(
            collection_key="qbo_payment_987",
            collected_amount=100.0,
            revenue_events=[
                RevenueEventCandidate("rev_a", "invoice-abc123", 33.33, 0.0),
                RevenueEventCandidate("rev_b", "invoice-abc123", 33.33, 0.0),
                RevenueEventCandidate("rev_c", "invoice-abc123", 33.34, 0.0),
            ],
        )

        self.assertEqual([row["allocated_amount"] for row in allocations], [33.33, 33.33, 33.34])
        self.assertEqual(allocations[-1]["rounding_delta"], 0.0)
        self.assertEqual(sum(row["allocated_amount"] for row in allocations), 100.0)

    def test_allocate_payment_caps_at_remaining_revenue_event_amount(self) -> None:
        allocations = allocate_payment_to_revenue_events(
            collection_key="qbo_payment_990",
            collected_amount=250.0,
            revenue_events=[
                RevenueEventCandidate("rev_a", "invoice-abc123", 100.0, 25.0),
                RevenueEventCandidate("rev_b", "invoice-abc123", 50.0, 0.0),
            ],
        )

        self.assertEqual(sum(row["allocated_amount"] for row in allocations), 125.0)
        self.assertEqual([row["allocated_amount"] for row in allocations], [75.0, 50.0])


if __name__ == "__main__":
    unittest.main()
