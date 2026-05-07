from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_023 = ROOT / "supabase/sql/023_profit_fulfillment_classifications.sql"
SQL_025A = ROOT / "supabase/sql/025a_profit_inactive_client_reemergence_scan.sql"


CANONICAL_VERDICTS = [
    "INTERNAL_FAMILY",
    "INACTIVE_FORMER_CLIENT",
    "PENDING_ENGAGEMENT_DRAFT",
    "PENDING_ENGAGEMENT_SENT",
    "INVOICE_OUTSTANDING_PAYMENT_PENDING",
    "LEGACY_ENGAGEMENT_PRE_ANCHOR",
    "ENGAGEMENT_DECLINED",
    "LEGITIMATE_LEAK",
    "BILLING_OUTSIDE_AUDIT_WINDOW",
    "BILLING_SETUP_GAP",
    "GROUP_DEFINITION_GAP",
    "MIXED",
    "CONSOLIDATED_VIA_GROUP_BILLED",
    "SETTLED_VIA_QUICKBOOKS_PAYMENT",
]


class FulfillmentClassificationSqlTests(unittest.TestCase):
    def test_migration_023_creates_verdict_lookup_and_classification_history(self) -> None:
        sql = SQL_023.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create table if not exists profit_classification_verdicts", lower)
        self.assertIn("verdict_code text primary key", lower)
        self.assertIn("default_visibility text not null", lower)
        self.assertIn("auto_transition_enabled boolean not null", lower)
        self.assertIn("create table if not exists profit_classifications", lower)
        self.assertIn("classification_id bigserial primary key", lower)
        self.assertIn("source_audit_file text", lower)
        self.assertIn("source_audit_row_hash text not null", lower)
        self.assertIn("last_signal_hash text", lower)
        self.assertIn("last_signal_at timestamptz", lower)
        self.assertIn(
            "superseded_by_classification_id bigint references profit_classifications",
            lower,
        )
        self.assertIn("unique (source_audit_file, source_audit_row_hash)", lower)
        for verdict in CANONICAL_VERDICTS:
            self.assertIn(verdict, sql)

    def test_migration_023_seeds_visibility_and_transition_attribute_matrix(self) -> None:
        sql = SQL_023.read_text(encoding="utf-8")
        lower = sql.lower()

        expected_fragments = [
            "('INTERNAL_FAMILY', 'Internal family', 'suppressed', 'hide', false, false",
            "('INACTIVE_FORMER_CLIENT', 'Inactive former client', 'suppressed', 'hide', false, true",
            "('PENDING_ENGAGEMENT_DRAFT', 'Pending engagement draft', 'pending', 'show', true, true",
            "('PENDING_ENGAGEMENT_SENT', 'Pending engagement sent', 'pending', 'show', true, true",
            "('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'Invoice outstanding / payment pending', 'pending', 'show', false, true",
            "('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'Legacy engagement pre-Anchor', 'pending', 'show', false, true",
            "('ENGAGEMENT_DECLINED', 'Engagement declined', 'suppressed', 'hide', false, false",
            "('LEGITIMATE_LEAK', 'Legitimate leak', 'leak', 'show', false, false",
            "('BILLING_OUTSIDE_AUDIT_WINDOW', 'Billing outside audit window', 'pending', 'show', false, false",
            "('BILLING_SETUP_GAP', 'Billing setup gap', 'setup_gap', 'show', false, false",
            "('GROUP_DEFINITION_GAP', 'Group definition gap', 'setup_gap', 'show', false, false",
            "('MIXED', 'Mixed', 'mixed', 'show', false, false",
            "('CONSOLIDATED_VIA_GROUP_BILLED', 'Consolidated via group billed', 'healthy', 'hide', false, false",
            "('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'Settled via QuickBooks payment', 'backfill', 'hide', false, true",
        ]
        for fragment in expected_fragments:
            self.assertIn(fragment, sql)

        self.assertIn("on conflict (verdict_code) do update set", lower)
        self.assertIn(
            "create table if not exists profit_classification_transition_rules",
            lower,
        )
        self.assertIn(
            "primary key (from_verdict_code, signal_name, to_verdict_code)",
            lower,
        )
        self.assertIn("PENDING_ENGAGEMENT_DRAFT", sql)
        self.assertIn("active_agreement_appears", sql)
        self.assertIn("SETTLED_VIA_QUICKBOOKS_PAYMENT", sql)
        self.assertIn("anchor_backfill_invoice_cash_pending", sql)

    def test_migration_025a_defines_inactive_client_reemergence_scan(self) -> None:
        sql = SQL_025A.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn(
            "create or replace function profit_run_inactive_client_reemergence_scan",
            lower,
        )
        self.assertIn("returns table", lower)
        self.assertIn("INACTIVE_FORMER_CLIENT", sql)
        self.assertIn("MIXED", sql)
        self.assertIn("superseded_at", lower)
        self.assertIn("superseded_by_classification_id", lower)
        self.assertIn("classified_at", lower)
        self.assertIn("coalesce(client.is_archived, false) = false", lower)
        self.assertIn("profit_fc_task_delivery_classification", lower)
        self.assertIn("service_delivery", lower)
        self.assertIn("display_status = 'active'", lower)
        self.assertIn("task.completed_at > record_to_scan.classified_at", lower)
        self.assertIn("completed_at >= (p_run_at - interval '365 days')", lower)
        self.assertIn("Re-emergence scan superseded INACTIVE_FORMER_CLIENT", sql)


if __name__ == "__main__":
    unittest.main()
