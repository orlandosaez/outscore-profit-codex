from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_023 = ROOT / "supabase/sql/023_profit_fulfillment_classifications.sql"
SQL_025A = ROOT / "supabase/sql/025a_profit_inactive_client_reemergence_scan.sql"
SQL_025C = ROOT / "supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql"
SQL_025D = ROOT / "supabase/sql/025d_profit_apply_classification_transitions.sql"
SQL_029 = ROOT / "supabase/sql/029_profit_manual_invoice_pending_verdict.sql"
SQL_029A = ROOT / "supabase/sql/029a_profit_weekly_review_items.sql"
SQL_030 = ROOT / "supabase/sql/030_profit_sla_breached_verdict.sql"


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
    def _read_sql_030(self) -> str:
        self.assertTrue(SQL_030.exists(), "030 SLA breached migration file must exist")
        return SQL_030.read_text(encoding="utf-8")

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

    def test_migration_025c_replaces_reemergence_scan_with_v2_guards(self) -> None:
        sql = SQL_025C.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn(
            "create or replace function profit_run_inactive_client_reemergence_scan",
            lower,
        )
        self.assertIn("profit_audit_fc_inactive_signals", lower)
        self.assertIn("profit_audit_open_invoice_balance_per_client", lower)
        self.assertIn("fc_client_unarchived", sql)
        self.assertIn("fc_client_became_active", sql)
        self.assertIn("active_anchor_agreement_created", sql)
        self.assertIn("service_delivery_task_completed", sql)
        self.assertIn("open_invoice_balance_returned", sql)
        self.assertIn("agreement.effective_date > record_to_scan.classified_at", lower)
        self.assertIn("task.completed_at > record_to_scan.classified_at", lower)
        self.assertIn("open_balance.last_signal_at > record_to_scan.classified_at", lower)
        self.assertIn("Joy Property Management LLC", sql)
        self.assertIn("backdated agreements", lower)
        self.assertIn("effective_date <= classified_at", lower)

    def test_migration_025d_defines_apply_transitions_with_dry_run(self) -> None:
        sql = SQL_025D.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)
        self.assertIn("p_dry_run boolean default true", lower)
        self.assertIn("classification_id bigint", lower)
        self.assertIn("fc_client_id bigint", lower)
        self.assertIn("fc_client_name text", lower)
        self.assertIn("from_verdict_code text", lower)
        self.assertIn("signal_name text", lower)
        self.assertIn("to_verdict_code text", lower)
        self.assertIn("anchor_relationship_id text", lower)
        self.assertIn("anchor_client_business_name text", lower)
        self.assertIn("evidence_summary jsonb", lower)
        self.assertIn("would_create_classification_id bigint", lower)
        self.assertIn("if not p_dry_run then", lower)
        self.assertIn("rule.enabled = true", lower)
        self.assertIn("superseded_at is null", lower)
        self.assertIn("active_agreement_appears", sql)
        self.assertIn("only active_agreement_appears", lower)
        self.assertIn("remaining seeded rules", lower)
        self.assertIn("Schmidli Enterprises LLC", sql)
        self.assertIn("E & O Automotive LLC", sql)
        self.assertIn("dry-run writes zero rows", lower)
        self.assertIn("idempotent", lower)

    def test_migration_029_seeds_manual_invoice_pending_verdict_and_rules(self) -> None:
        sql = SQL_029.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("insert into profit_classification_verdicts", lower)
        self.assertIn("MANUAL_INVOICE_PENDING", sql)
        self.assertIn(
            "('MANUAL_INVOICE_PENDING', 'Manual invoice pending', 'pending', 'show', false, true",
            sql,
        )
        self.assertIn("on conflict (verdict_code) do update set", lower)

        self.assertIn("insert into profit_classification_transition_rules", lower)
        self.assertIn("manual_invoice_issued", sql)
        self.assertIn("INVOICE_OUTSTANDING_PAYMENT_PENDING", sql)
        self.assertIn("manual_invoice_agreement_terminated", sql)
        self.assertIn("no-op resolution", lower)
        self.assertIn("superseded_by_classification_id = null", lower)

    def test_migration_029_creates_manual_invoice_candidate_view_contract(self) -> None:
        sql = SQL_029.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn(
            "create or replace view profit_manual_invoice_pending_candidates",
            lower,
        )
        for relation in [
            "profit_anchor_agreements",
            "profit_anchor_invoices",
            "profit_classifications",
            "profit_fc_client_anchor_matches",
        ]:
            self.assertIn(relation, lower)

        self.assertIn("raw->'profitSyncServiceSummary'", sql)
        self.assertIn("s->>'trigger' = 'manual'", sql)
        self.assertNotIn("s->>'trigger' = 'Manual'", sql)
        self.assertIn("agreement.display_status = 'active'", lower)
        self.assertIn("qbo_status is not null", lower)
        self.assertIn("count(*) filter (where invoice.qbo_status is not null)", lower)
        self.assertIn("invoice_state", lower)
        self.assertIn("no_invoice", sql)
        self.assertIn("draft_only", sql)
        self.assertIn("raw->>'link'", sql)
        self.assertIn(
            "'https://app.sayanchor.com/home/relationship/' || agreement.anchor_relationship_id || '/agreement'",
            sql,
        )

        for column in [
            "classification_id",
            "classified_at",
            "verdict_code",
            "fc_client_id",
            "anchor_relationship_id",
            "agreement_id",
            "client_name",
            "service_name",
            "invoice_state",
            "age_days",
            "estimated_annual_revenue",
            "action_url",
        ]:
            self.assertIn(column, lower)

    def test_migration_029_replaces_apply_transitions_with_manual_invoice_branches(self) -> None:
        sql = SQL_029.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)
        self.assertIn("p_run_at timestamptz default now()", lower)
        self.assertIn("p_dry_run boolean default true", lower)
        self.assertIn("manual_invoice_pending_candidates", lower)
        self.assertIn("manual_invoice_detected", sql)
        self.assertIn("manual_invoice_issued", sql)
        self.assertIn("manual_invoice_agreement_terminated", sql)
        self.assertIn("agreement.terminated_at is not null", lower)

        for existing_signal in [
            "active_agreement_appears",
            "first_matching_anchor_invoice_group_billed",
            "first_matching_anchor_invoice_mid_cycle",
            "cash_collected_group_parent",
            "cash_collected_standalone_mid_cycle",
        ]:
            self.assertIn(existing_signal, sql)

    def test_migration_029a_creates_weekly_review_state_table(self) -> None:
        self.assertTrue(SQL_029A.exists(), "029a migration file must exist")
        sql = SQL_029A.read_text(encoding="utf-8")
        lower = sql.lower()

        # Table must be created
        self.assertIn("create table if not exists profit_weekly_review_item_state", lower)

        # Primary key + FK to profit_classifications
        self.assertIn("classification_id bigint", lower)
        self.assertIn("references profit_classifications", lower)

        # Review state columns
        self.assertIn("reviewed_at timestamptz", lower)
        self.assertIn("snoozed_until date", lower)

        # Operator + practice metadata
        self.assertIn("operator_id text not null default 'orlando'", lower)
        self.assertIn("practice_id text", lower)

        # Audit timestamps
        self.assertIn("created_at timestamptz", lower)
        self.assertIn("updated_at timestamptz", lower)

        # updated_at trigger or explicit mechanism
        self.assertTrue(
            "updated_at" in lower and ("trigger" in lower or "returns trigger" in lower),
            "029a must include an updated_at maintenance mechanism",
        )

    def test_migration_030_exists(self) -> None:
        self.assertTrue(SQL_030.exists(), "030 SLA breached migration file must exist")

    def test_migration_030_seeds_sla_breached_verdict_attributes(self) -> None:
        sql = self._read_sql_030()
        lower = sql.lower()

        self.assertIn("insert into profit_classification_verdicts", lower)
        self.assertIn("SLA_BREACHED", sql)
        self.assertIn(
            "('SLA_BREACHED', 'SLA breached', 'pending', 'show', false, true",
            sql,
        )
        self.assertIn("auto_transition_enabled", lower)
        self.assertIn("on conflict (verdict_code) do update set", lower)

    def test_migration_030_seeds_sla_clearance_transition_rules(self) -> None:
        sql = self._read_sql_030()
        lower = sql.lower()

        self.assertIn("insert into profit_classification_transition_rules", lower)
        self.assertIn("('SLA_BREACHED', 'sla_task_complete', 'SLA_BREACHED', false, true", sql)
        self.assertIn("('SLA_BREACHED', 'sla_project_archived', 'SLA_BREACHED', false, true", sql)
        self.assertIn("is_completed = true or completed_at is not null", lower)
        self.assertIn("is_closed = true or closed_at is not null", lower)

    def test_migration_030_creates_sla_breached_candidate_view_contract(self) -> None:
        sql = self._read_sql_030()
        lower = sql.lower()

        self.assertIn("create or replace view profit_sla_breached_candidates", lower)
        self.assertIn("from profit_sla_service_items", lower)
        self.assertIn("sla_state in ('breached', 'at_risk')", lower)
        self.assertIn("default_sla_day is not null", lower)
        self.assertIn("target_sla_day is not null", lower)
        self.assertIn("target_date is not null", lower)

        for column in [
            "classification_id",
            "classified_at",
            "verdict_code",
            "fc_client_id",
            "anchor_relationship_id",
            "agreement_id",
            "client_name",
            "service_name",
            "macro_service_type",
            "fc_tag",
            "breach_state",
            "age_days",
            "breach_age_days",
            "work_age_days",
            "target_date",
            "target_sla_day",
            "assigned_staff_name",
            "staff_source",
            "latest_workflow_status",
            "fc_task_id",
            "fc_project_id",
            "action_url",
        ]:
            self.assertIn(column, lower)

    def test_migration_030_candidate_view_dedupes_active_sla_classifications(self) -> None:
        sql = self._read_sql_030()
        lower = sql.lower()

        self.assertIn("active_sla_classification", lower)
        self.assertIn("classification.verdict_code = 'SLA_BREACHED'", sql)
        self.assertIn("classification.superseded_at is null", lower)
        self.assertIn("distinct on (classification.fc_client_id, split_part(classification.source_audit_row_hash, ':', 3))", lower)
        self.assertIn("'sla_breached:' || item.fc_client_id::text || ':' || item.service_name", lower)

    def test_migration_029a_creates_weekly_review_items_queue_view(self) -> None:
        self.assertTrue(SQL_029A.exists(), "029a migration file must exist")
        sql = SQL_029A.read_text(encoding="utf-8")
        lower = sql.lower()

        # Queue view must be created
        self.assertIn("create or replace view profit_weekly_review_items", lower)

        # Required output columns
        for column in [
            "practice_id",
            "item_type",
            "verdict_code",
            "classification_id",
            "reviewed_at",
            "snoozed_until",
            "operator_id",
            "action_url",
            "age_days",
            "sort_rank",
        ]:
            self.assertIn(column, lower)

        # Joins candidate view
        self.assertIn("profit_manual_invoice_pending_candidates", lower)

        # Left-joins review state
        self.assertIn("left join profit_weekly_review_item_state", lower)

        # Filters to registered visible verdicts (via visible_verdicts registry)
        self.assertIn("profit_weekly_review_visible_verdicts", lower)

        # MANUAL_INVOICE_PENDING seeded into visible_verdicts registry
        self.assertIn("manual_invoice_pending", lower)

        # View must not contain INSERT/UPDATE/DELETE (read-only)
        lower_stripped = lower.replace("-- ", "")
        self.assertNotIn("\ninsert into profit_classifications", lower_stripped)
        self.assertNotIn("\nupdate profit_classifications", lower_stripped)
        self.assertNotIn("\ndelete from profit_classifications", lower_stripped)

        # sort_rank must use row_number or rank window function
        self.assertTrue(
            "row_number()" in lower or "rank()" in lower,
            "sort_rank must be defined using a window function",
        )


if __name__ == "__main__":
    unittest.main()
