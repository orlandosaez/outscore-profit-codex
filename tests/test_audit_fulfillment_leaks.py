from __future__ import annotations

import unittest

from scripts.audit_fulfillment_leaks import (
    AssignmentRecord,
    BillingSummary,
    ServicePrice,
    classify_candidate,
    estimate_annual_revenue,
    parse_group_and_services,
)


class FulfillmentLeakAuditScriptTests(unittest.TestCase):
    def test_group_extraction_uses_first_non_service_token_any_position(self) -> None:
        group, services, related_entities = parse_group_and_services(
            "Feig Group; S 1120P; S BOOKP; MIDAS Auto"
        )
        self.assertEqual(group, "Feig Group")
        self.assertEqual(services, ["S 1120P", "S BOOKP"])
        self.assertEqual(related_entities, ["MIDAS Auto"])

        group, services, related_entities = parse_group_and_services("S 1040P; SimpleSwitch")
        self.assertEqual(group, "SimpleSwitch")
        self.assertEqual(services, ["S 1040P"])
        self.assertEqual(related_entities, [])

        group, services, related_entities = parse_group_and_services("S 1120P")
        self.assertIsNone(group)
        self.assertEqual(services, ["S 1120P"])
        self.assertEqual(related_entities, [])

        group, services, related_entities = parse_group_and_services("Susan Keen")
        self.assertEqual(group, "Susan Keen")
        self.assertEqual(services, [])
        self.assertEqual(related_entities, [])

    def test_classification_buckets_follow_audit_rules(self) -> None:
        self.assertEqual(
            classify_candidate(
                fc_client_name="SBC Accounting and Tax LLC (Outscore)",
                assignment=None,
                billing=BillingSummary(),
                anchor_match_exists=False,
            ),
            "internal_account",
        )
        self.assertEqual(
            classify_candidate(
                fc_client_name="Missing Client",
                assignment=None,
                billing=BillingSummary(),
                anchor_match_exists=False,
            ),
            "not_in_assignments_file",
        )
        grouped = AssignmentRecord(client_name="Child", group="Parent Group")
        self.assertEqual(
            classify_candidate(
                fc_client_name="Child",
                assignment=grouped,
                billing=BillingSummary(invoice_count=2, total_invoiced=1000),
                anchor_match_exists=False,
            ),
            "consolidated_via_group_billed",
        )
        self.assertEqual(
            classify_candidate(
                fc_client_name="Child",
                assignment=grouped,
                billing=BillingSummary(invoice_count=0),
                anchor_match_exists=False,
            ),
            "consolidated_via_group_unbilled",
        )
        standalone = AssignmentRecord(client_name="No Anchor", group=None)
        self.assertEqual(
            classify_candidate(
                fc_client_name="No Anchor",
                assignment=standalone,
                billing=BillingSummary(),
                anchor_match_exists=False,
            ),
            "standalone_no_anchor",
        )
        self.assertEqual(
            classify_candidate(
                fc_client_name="Name Drift LLC",
                assignment=standalone,
                billing=BillingSummary(),
                anchor_match_exists=True,
            ),
            "name_mismatch_anchor_exists",
        )

    def test_estimated_annual_revenue_uses_service_tag_prices(self) -> None:
        prices = {
            "S 1040P": [ServicePrice("1040 Plus", "S 1040P", 350)],
            "S BOOKP": [ServicePrice("Accounting Plus", "S BOOKP", 7800)],
            "S BILL": [
                ServicePrice("Billable Expenses", "S BILL", 0),
                ServicePrice("Remote Desktop Access", "S BILL", 2400),
            ],
        }

        self.assertEqual(
            estimate_annual_revenue(["S 1040P", "S BOOKP"], prices),
            8150,
        )
        self.assertEqual(
            estimate_annual_revenue(["S BILL"], prices),
            2400,
        )


if __name__ == "__main__":
    unittest.main()
