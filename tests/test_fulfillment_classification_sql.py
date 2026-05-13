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
SQL_030A = ROOT / "supabase/sql/030a_profit_weekly_review_sla_union.sql"
SQL_030B = ROOT / "supabase/sql/030b_profit_sla_clearance_predicate_fix.sql"
SQL_030C = ROOT / "supabase/sql/030c_profit_sla_candidates_exclude_cleared_work.sql"
SQL_031 = ROOT / "supabase/sql/031_profit_sla_candidates_exclude_1040_on_business.sql"
SQL_032 = ROOT / "supabase/sql/032_profit_sla_widen_regex_and_invoice_paid_clearance.sql"
SQL_032A = ROOT / "supabase/sql/032a_profit_sla_invoice_paid_after_target_date.sql"
SQL_033 = ROOT / "supabase/sql/033_revert_sla_invoice_paid_clearance.sql"
SQL_034 = ROOT / "supabase/sql/034_profit_parse_anchor_service_name.sql"
SQL_034A = ROOT / "supabase/sql/034a_profit_anchor_services_attributed.sql"
SQL_034B = ROOT / "supabase/sql/034b_profit_sla_candidates_use_attribution.sql"
SQL_034C = ROOT / "supabase/sql/034c_profit_weekly_review_items_expose_attribution.sql"
SQL_036 = ROOT / "supabase/sql/036_profit_manual_recognition_pending_verdict.sql"
SQL_036A = ROOT / "supabase/sql/036a_profit_pipeline_run_failed_verdict.sql"
SQL_036B = ROOT / "supabase/sql/036b_profit_manual_invoice_pending_cleanup.sql"
FULFILLMENT_CONTRACT = ROOT / "docs/data-contracts/fulfillment-classifications.md"


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

    def _read_sql_030a(self) -> str:
        self.assertTrue(SQL_030A.exists(), "030a weekly review SLA union migration file must exist")
        return SQL_030A.read_text(encoding="utf-8")

    def _read_sql_030b(self) -> str:
        self.assertTrue(SQL_030B.exists(), "030b SLA clearance predicate fix migration file must exist")
        return SQL_030B.read_text(encoding="utf-8")

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

    def test_migration_030_replaces_apply_transitions_with_sla_branches(self) -> None:
        sql = self._read_sql_030()
        lower = sql.lower()

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)
        self.assertIn("p_run_at timestamptz default now()", lower)
        self.assertIn("p_dry_run boolean default true", lower)

        for signal in [
            "manual_invoice_detected",
            "manual_invoice_issued",
            "manual_invoice_agreement_terminated",
            "active_agreement_appears",
            "first_matching_anchor_invoice_group_billed",
            "first_matching_anchor_invoice_mid_cycle",
            "cash_collected_group_parent",
            "cash_collected_standalone_mid_cycle",
            "sla_breach_detected",
            "sla_task_complete",
            "sla_project_archived",
        ]:
            self.assertIn(signal, sql)

    def test_migration_030_sla_apply_branch_contracts(self) -> None:
        sql = self._read_sql_030()
        lower = sql.lower()

        self.assertIn("sla_breach_detection_signals as", lower)
        self.assertIn("from profit_sla_breached_candidates candidate", lower)
        self.assertIn("where candidate.classification_id is null", lower)
        self.assertIn("'system:sla_breached'::text as source_audit_file", lower)
        self.assertIn("'sla_breached:' || candidate.fc_client_id::text || ':' || candidate.service_name", lower)
        self.assertIn("null::numeric as estimated_annual_revenue", lower)

        self.assertIn("sla_task_complete_signals as", lower)
        self.assertIn("join profit_fc_tasks task", lower)
        self.assertIn("task.is_completed = true", lower)
        self.assertIn("task.completed_at is not null", lower)

        self.assertIn("sla_project_archived_signals as", lower)
        self.assertIn("join profit_fc_projects project", lower)
        self.assertIn("project.is_closed = true", lower)
        self.assertIn("project.closed_at is not null", lower)

        self.assertGreaterEqual(lower.count("null::text as to_verdict_code"), 3)
        self.assertIn("ranked_signals.signal_name = 'sla_breach_detected'", lower)
        self.assertIn("'detect:sla:' || ranked_signals.fc_client_id::text || ':' || ranked_signals.service_name", lower)

    def test_migration_030_apply_transitions_keeps_dry_run_write_guard(self) -> None:
        sql = self._read_sql_030()
        lower = sql.lower()

        self.assertIn("if not p_dry_run then", lower)
        guard_start = lower.index("if not p_dry_run then")
        guard_end = lower.index("classification_id :=", guard_start)
        guarded_block = lower[guard_start:guard_end]

        self.assertIn("insert into profit_classifications", guarded_block)
        self.assertIn("update profit_classifications", guarded_block)

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

    def test_migration_030a_exists(self) -> None:
        self.assertTrue(SQL_030A.exists(), "030a weekly review SLA union migration file must exist")

    def test_migration_030a_registers_sla_breached_visible_verdict(self) -> None:
        sql = self._read_sql_030a()
        lower = sql.lower()

        self.assertIn("insert into profit_weekly_review_visible_verdicts", lower)
        self.assertIn("values ('SLA_BREACHED', 20)", sql)
        self.assertIn("on conflict (verdict_code) do update set sort_order = excluded.sort_order", lower)

    def test_migration_030a_replaces_weekly_review_items_with_union_sources(self) -> None:
        sql = self._read_sql_030a()
        lower = sql.lower()

        self.assertIn("create or replace view profit_weekly_review_items", lower)
        self.assertIn("union all", lower)
        self.assertIn("profit_manual_invoice_pending_candidates", lower)
        self.assertIn("profit_sla_breached_candidates", lower)
        self.assertIn("left join profit_weekly_review_item_state", lower)
        self.assertIn("state.classification_id = candidate.classification_id", lower)
        self.assertIn("inner join profit_weekly_review_visible_verdicts", lower)

    def test_migration_030a_weekly_review_union_column_contract(self) -> None:
        sql = self._read_sql_030a()
        lower = sql.lower()

        for column in [
            "classification_id",
            "verdict_code",
            "item_type",
            "client_name",
            "anchor_relationship_id",
            "action_url",
            "reviewed_at",
            "snoozed_until",
            "operator_id",
            "practice_id",
            "age_days",
            "sort_rank",
        ]:
            self.assertIn(column, lower)

        for column in [
            "breach_state",
            "breach_age_days",
            "work_age_days",
            "target_date",
            "assigned_staff_name",
            "staff_source",
        ]:
            self.assertIn(column, lower)

    def test_migration_030a_weekly_review_union_null_casts_branch_specific_columns(self) -> None:
        sql = self._read_sql_030a()
        lower = sql.lower()

        self.assertIn("null::text as breach_state", lower)
        self.assertIn("null::text as invoice_state", lower)

    def test_migration_030a_weekly_review_sort_rank_uses_row_number(self) -> None:
        sql = self._read_sql_030a()
        lower = sql.lower()

        self.assertIn("row_number() over", lower)
        self.assertIn("when verdict_code = 'SLA_BREACHED' and breach_state = 'breached' then 1", sql)
        self.assertIn("when verdict_code = 'SLA_BREACHED' and breach_state = 'at_risk'  then 2", sql)
        self.assertIn("when verdict_code = 'MANUAL_INVOICE_PENDING'                     then 3", sql)
        self.assertIn("coalesce(breach_age_days, age_days) desc nulls last", lower)

    def test_migration_030b_exists(self) -> None:
        self.assertTrue(SQL_030B.exists(), "030b SLA clearance predicate fix migration file must exist")

    def test_migration_030b_replaces_apply_transitions_function(self) -> None:
        sql = self._read_sql_030b()
        lower = sql.lower()

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)

    def test_migration_030b_relaxes_sla_clearance_ilike_predicates(self) -> None:
        sql = self._read_sql_030b()

        self.assertIn(
            "task.project_title ilike '%' || split_part(current_classifications.service_name, ' ', 1) || '%'",
            sql,
        )
        self.assertIn(
            "project.title ilike '%' || split_part(current_classifications.service_name, ' ', 1) || '%'",
            sql,
        )
        self.assertNotIn(
            "task.project_title ilike '%' || current_classifications.service_name || '%'",
            sql,
        )
        self.assertNotIn(
            "project.title ilike '%' || current_classifications.service_name || '%'",
            sql,
        )

    def test_migration_030b_preserves_existing_transition_signals(self) -> None:
        sql = self._read_sql_030b()

        for signal in [
            "manual_invoice_detected",
            "manual_invoice_issued",
            "manual_invoice_agreement_terminated",
            "sla_breach_detected",
            "sla_task_complete",
            "sla_project_archived",
            "active_agreement_appears",
            "first_matching_anchor_invoice_group_billed",
            "first_matching_anchor_invoice_mid_cycle",
            "cash_collected_group_parent",
            "cash_collected_standalone_mid_cycle",
        ]:
            self.assertIn(signal, sql)

    def test_migration_030b_preserves_sla_clearance_no_op_resolution(self) -> None:
        sql = self._read_sql_030b()
        lower = sql.lower()

        self.assertIn("sla_task_complete_signals as", lower)
        self.assertIn("sla_project_archived_signals as", lower)
        self.assertGreaterEqual(lower.count("null::text as to_verdict_code"), 3)

    def test_migration_030b_does_not_add_rules_or_candidate_views(self) -> None:
        sql = self._read_sql_030b()
        lower = sql.lower()

        self.assertNotIn("insert into profit_classification_transition_rules", lower)
        self.assertNotIn("create or replace view profit_sla_breached_candidates", lower)

    def test_migration_030c_candidate_view_excludes_completed_work(self) -> None:
        """V0.7.B.1 T6a: candidate view must filter out service items where a
        matching FC task is complete or matching FC project is closed.
        Without this, the apply function re-detects already-cleared work on
        every pipeline run (churn)."""
        self.assertTrue(SQL_030C.exists(), "030c migration file must exist")
        sql = SQL_030C.read_text(encoding="utf-8")
        lower = sql.lower()

        # Re-defines the candidate view
        self.assertIn("create or replace view profit_sla_breached_candidates", lower)

        # Filters out completed tasks
        self.assertIn("not exists", lower)
        self.assertIn("profit_fc_tasks", lower)
        self.assertIn(
            "task.is_completed = true or task.completed_at is not null", lower
        )

        # Filters out closed projects
        self.assertIn("profit_fc_projects", lower)
        self.assertIn(
            "project.is_closed = true or project.closed_at is not null", lower
        )

        # Match predicate uses split_part on service_name (mirrors 030b clearance)
        self.assertIn(
            "task.project_title ilike '%' || split_part(item.service_name, ' ', 1) || '%'",
            lower,
        )
        self.assertIn(
            "project.title ilike '%' || split_part(item.service_name, ' ', 1) || '%'",
            lower,
        )

        # Service-tag bridge still attempted (V0.7.D will activate it)
        self.assertIn("tag_type = 'service'", lower)

        # Does NOT touch the apply function
        self.assertNotIn(
            "create or replace function profit_apply_classification_transitions", lower
        )

    def test_migration_031_candidate_view_excludes_1040_on_business_clients(self) -> None:
        """V0.7.B.3 (revised): encode the FC client-hierarchy structural rule
        directly in profit_sla_breached_candidates. 1040 services are
        individual personal returns; LLC/Inc/Corp/LLP/PA suffixes are
        business entities. A 1040 on a business client is structurally wrong
        (work happens on the owner's individual FC client per
        fc_client_hierarchy.md). Removing 16 of 40 day-one SLA queue rows
        without operator clicks."""
        self.assertTrue(SQL_031.exists(), "031 migration file must exist")
        sql = SQL_031.read_text(encoding="utf-8")
        lower = sql.lower()

        # Replaces the candidate view, not the apply function
        self.assertIn("create or replace view profit_sla_breached_candidates", lower)
        self.assertNotIn(
            "create or replace function profit_apply_classification_transitions", lower
        )

        # Filter encodes the 1040-on-business rule
        # Service must match 1040* pattern
        self.assertIn("1040", sql)
        self.assertIn("ilike '1040%'", lower)

        # Client name suffix pattern (all 5 business suffixes)
        for suffix in ["LLC", "Inc", "Corp", "LLP", "PA"]:
            self.assertIn(suffix, sql)

        # Anchored at end-of-name (avoids false positives like "Pacific" matching "PA")
        # Either uses ~* with anchored regex, or RIGHT() / LIKE % suffix pattern
        self.assertTrue(
            "$'" in sql or "rtrim" in lower or "regexp" in lower or "~*" in sql,
            "Migration must anchor business-suffix match at end of client name "
            "(use ~* '(...)$' regex or equivalent), not naive substring",
        )

        # Preserves 030c filters (completed task + closed project exclusions)
        self.assertIn("task.is_completed = true or task.completed_at is not null", lower)
        self.assertIn("project.is_closed = true or project.closed_at is not null", lower)

    def test_migration_032_widens_regex_and_adds_invoice_paid_clearance(self) -> None:
        """V0.7.B.3 audit fix: widen the 1040-on-business regex to match
        business suffixes anywhere in the name (e.g., 'SamDee Enterprises
        Inc (Lakeland)') AND add an Anchor-invoice-paid clearance signal
        because 15 of 25 active SLA rows have paid invoices but stay
        stuck."""
        self.assertTrue(SQL_032.exists(), "032 migration file must exist")
        sql = SQL_032.read_text(encoding="utf-8")
        lower = sql.lower()

        # === 1. Transition rule seed for sla_invoice_paid ===
        self.assertIn(
            "insert into profit_classification_transition_rules",
            lower,
        )
        self.assertIn("sla_invoice_paid", sql)

        # === 2. Candidate view CREATE OR REPLACE ===
        self.assertIn(
            "create or replace view profit_sla_breached_candidates",
            lower,
        )

        # Widened regex uses word-boundary anchor (\m or \y), not end-anchor only
        # Must match 'SamDee Enterprises Inc (Lakeland)' (Inc mid-name)
        self.assertTrue(
            "\\m" in sql or "\\y" in sql or "\\b" in sql,
            "Widened regex must use a word-boundary anchor to catch suffix mid-name",
        )

        # Old end-anchor regex (031) is NO LONGER the sole pattern
        # We keep it removed in favor of the wider pattern
        self.assertNotIn(
            "(llc|inc\\.?|corp\\.?|llp|pa)\\s*$",
            lower,
        )

        # New invoice-paid NOT EXISTS filter in candidate view
        self.assertIn("not exists", lower)
        self.assertIn("profit_anchor_invoices", lower)
        self.assertTrue(
            "paymentsynced" in lower or "amount_paid" in lower,
            "Invoice-paid filter must check qbo_status='paymentSynced' OR amount_paid > 0",
        )

        # === 3. Apply function CREATE OR REPLACE with new clearance branch ===
        self.assertIn(
            "create or replace function profit_apply_classification_transitions",
            lower,
        )
        # The new sla_invoice_paid clearance CTE must exist in the function body
        self.assertIn("sla_invoice_paid_signals", lower)

        # The function must still preserve all earlier signals
        for signal in [
            "manual_invoice_detected",
            "manual_invoice_issued",
            "manual_invoice_agreement_terminated",
            "sla_breach_detected",
            "sla_task_complete",
            "sla_project_archived",
            "active_agreement_appears",
            "first_matching_anchor_invoice_group_billed",
            "first_matching_anchor_invoice_mid_cycle",
            "cash_collected_group_parent",
            "cash_collected_standalone_mid_cycle",
        ]:
            self.assertIn(signal, sql, f"Signal {signal!r} must be preserved in 032")

        # SLA clearance branches use no-op resolution (null::text to_verdict_code)
        self.assertIn("null::text as to_verdict_code", lower)

        # Preserves 030c task+project filters via inheritance
        self.assertIn("task.is_completed = true or task.completed_at is not null", lower)
        self.assertIn("project.is_closed = true or project.closed_at is not null", lower)

    def test_migration_032a_tightens_invoice_paid_to_target_date_or_later(self) -> None:
        """032 over-cleared 7 of 10 sampled rows by matching prior-billing-cycle
        invoices. 032a tightens both the candidate view and apply function
        clearance to require invoice.issue_date >= target_date."""
        self.assertTrue(SQL_032A.exists(), "032a migration file must exist")
        sql = SQL_032A.read_text(encoding="utf-8")
        lower = sql.lower()

        # CREATE OR REPLACE candidate view
        self.assertIn("create or replace view profit_sla_breached_candidates", lower)

        # Candidate view's invoice-paid NOT EXISTS must require issue_date >= target_date
        self.assertIn("invoice.issue_date::date >= item.target_date", lower)

        # CREATE OR REPLACE apply function
        self.assertIn(
            "create or replace function profit_apply_classification_transitions",
            lower,
        )

        # Apply function's sla_invoice_paid_signals CTE must join target_date
        # via a lateral lookup against profit_sla_service_items and require
        # invoice.issue_date::date >= service_item.target_date
        self.assertIn("sla_invoice_paid_signals", lower)
        self.assertIn("from profit_sla_service_items item", lower)
        self.assertIn("invoice.issue_date::date >= service_item.target_date", lower)

        # All earlier signals preserved
        for signal in [
            "manual_invoice_detected",
            "sla_breach_detected",
            "sla_task_complete",
            "sla_project_archived",
            "sla_invoice_paid",
            "active_agreement_appears",
        ]:
            self.assertIn(signal, sql)

    def test_migration_034_creates_anchor_service_name_parser(self) -> None:
        """V0.7.B.4 T2: pure SQL function that extracts (canonical, label) from
        an Anchor service raw name. Foundation for the attribution view.
        Data-driven: no content-specific rules; just regex-based pattern
        extraction."""
        self.assertTrue(SQL_034.exists(), "034 parser migration must exist")
        sql = SQL_034.read_text(encoding="utf-8")
        lower = sql.lower()

        # Function exists with the locked signature
        self.assertIn(
            "create or replace function profit_parse_anchor_service_name",
            lower,
        )
        # Returns 2 columns: canonical text + label text
        self.assertIn("returns table", lower)
        self.assertIn("canonical_service_name", lower)
        self.assertIn("label", lower)

        # Both patterns documented
        # Parens pattern: "<service> (<label>)"
        self.assertIn("(", sql)
        # Dash pattern: "<service> - <label>" (must require surrounding spaces)
        self.assertTrue(
            " - " in sql or "\\s+-\\s+" in sql or "[[:space:]]+-[[:space:]]+" in sql,
            "Parser must require space-dash-space (not hyphenated words)",
        )

        # Uses regexp_match or regexp_matches (PostgreSQL pattern extraction)
        self.assertTrue(
            "regexp_match" in lower or "regexp_matches" in lower or "regexp_replace" in lower,
            "Parser must use PostgreSQL regex extraction",
        )

    def test_migration_034a_creates_attribution_view(self) -> None:
        """V0.7.B.4 T3: attribution view resolves labeled services to the
        correct FC client (orphan + flag if unresolved). Data-driven; no
        content-specific rules."""
        self.assertTrue(SQL_034A.exists(), "034a attribution view migration must exist")
        sql = SQL_034A.read_text(encoding="utf-8")
        lower = sql.lower()

        # View exists
        self.assertIn(
            "create or replace view profit_anchor_services_attributed",
            lower,
        )

        # Uses the parser function from 034
        self.assertIn("profit_parse_anchor_service_name", lower)

        # Sources from active anchor agreements
        self.assertIn("profit_anchor_agreements", lower)
        self.assertIn("profitsyncservicesummary", lower)

        # Joins to FC clients for resolution
        self.assertIn("profit_fc_clients", lower)

        # Joins to fc_client_anchor_matches for agreement-holder lookup
        self.assertIn("profit_fc_client_anchor_matches", lower)

        # Required output columns
        for col in [
            "anchor_relationship_id",
            "raw_service_name",
            "canonical_service_name",
            "label",
            "agreement_holder_fc_client_id",
            "attributed_fc_client_id",
            "label_unresolved",
            "service_trigger",
            "service_occurrence",
        ]:
            self.assertIn(col, lower)

        # DISTINCT ON to dedupe service duplicates (Ultimate II has 4 "1040 Plus")
        self.assertIn("distinct on", lower)

    def test_migration_034b_sla_candidates_use_attribution(self) -> None:
        """V0.7.B.4 T4: rewrite profit_sla_breached_candidates to source from
        attribution view + recognition rules. Drops V0.7.B.3 content-specific
        regex. Includes services without revenue events (ICE/Lee's manual
        annual services)."""
        self.assertTrue(SQL_034B.exists())
        sql = SQL_034B.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_sla_breached_candidates", lower)

        # Sources from attribution view (Orlando's rule)
        self.assertIn("profit_anchor_services_attributed", lower)

        # Joins to recognition rules for SLA target computation
        self.assertIn("profit_service_recognition_rules", lower)

        # No more 1040-on-business regex (V0.7.B.3 content-specific rule REMOVED)
        self.assertNotIn("(llc|inc\\.?|corp\\.?|llp|pa)", lower)
        self.assertNotIn("1040%'", lower)  # No 1040 literal in candidate logic

        # Inherits 030c/031 task + project completion clearance
        self.assertIn(
            "task.is_completed = true or task.completed_at is not null", lower
        )
        self.assertIn(
            "project.is_closed = true or project.closed_at is not null", lower
        )

        # sla_state breach computation inline
        self.assertIn("'breached'", sql)
        self.assertIn("'at_risk'", sql)

        # Required output columns (per V0.7.B contract)
        for col in [
            "classification_id",
            "verdict_code",
            "fc_client_id",
            "anchor_relationship_id",
            "client_name",
            "service_name",
            "breach_state",
            "breach_age_days",
            "target_date",
            "action_url",
        ]:
            self.assertIn(col, lower)

        # New attribution-aware columns surfaced
        self.assertIn("label", lower)
        self.assertIn("label_unresolved", lower)

        # Active classification dedup preserved
        self.assertIn("source_audit_row_hash", lower)
        self.assertIn("superseded_at is null", lower)

    def test_migration_034c_queue_view_exposes_attribution_columns(self) -> None:
        """V0.7.B.4 T7 step 1: UNION queue view exposes the 3 new attribution
        columns (label, label_unresolved, agreement_client_business_name) so
        the frontend can render label badges and grouping context."""
        self.assertTrue(SQL_034C.exists())
        sql = SQL_034C.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_weekly_review_items", lower)

        # New columns surfaced from SLA branch (passed through)
        for col in ["label", "label_unresolved", "agreement_client_business_name"]:
            self.assertIn(col, lower)

        # Manual branch null-casts these new columns
        self.assertIn("null::text as label", lower)

        # Preserves sort_rank computation
        self.assertIn("row_number()", lower)

        # Both sources still present
        self.assertIn("profit_manual_invoice_pending_candidates", lower)
        self.assertIn("profit_sla_breached_candidates", lower)

    def test_migration_036_manual_recognition_pending_verdict_contract(self) -> None:
        self.assertTrue(SQL_036.exists(), "036 manual recognition migration must exist")
        sql = SQL_036.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("insert into profit_classification_verdicts", lower)
        self.assertIn("MANUAL_RECOGNITION_PENDING", sql)
        self.assertIn(
            "('MANUAL_RECOGNITION_PENDING', 'Manual recognition pending', 'pending', 'show', false, true",
            sql,
        )

        self.assertIn("insert into profit_classification_transition_rules", lower)
        self.assertIn("manual_recognition_pending_detected", sql)
        self.assertIn("recognition_event_recognized", sql)
        self.assertIn("no-op resolution", lower)

        self.assertIn(
            "create or replace view profit_manual_recognition_pending_candidates",
            lower,
        )
        self.assertIn("from profit_pipeline_stuck_recognition_triggers", lower)
        self.assertIn("'manual_recognition_pending:' || stuck.revenue_event_key", lower)

    def test_migration_036_apply_function_adds_manual_recognition_signals(self) -> None:
        self.assertTrue(SQL_036.exists(), "036 manual recognition migration must exist")
        sql = SQL_036.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)
        self.assertIn("manual_recognition_pending_detected_signals as", lower)
        self.assertIn("manual_recognition_event_recognized_signals as", lower)
        self.assertIn("recognition_status not like 'pending_%'", lower)
        self.assertIn("coalesce(event.recognized_amount, 0) > 0", lower)
        self.assertIn("'system:manual_recognition_pending'::text as source_audit_file", lower)
        self.assertIn("'manual_recognition_pending:' || candidate.revenue_event_key", lower)

        for signal in [
            "manual_invoice_detected",
            "manual_invoice_issued",
            "manual_invoice_agreement_terminated",
            "sla_breach_detected",
            "sla_task_complete",
            "sla_project_archived",
            "active_agreement_appears",
        ]:
            self.assertIn(signal, sql)

    def test_migration_036a_pipeline_run_failed_verdict_contract(self) -> None:
        self.assertTrue(SQL_036A.exists(), "036a pipeline run failed migration must exist")
        sql = SQL_036A.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("insert into profit_classification_verdicts", lower)
        self.assertIn("PIPELINE_RUN_FAILED", sql)
        self.assertIn(
            "('PIPELINE_RUN_FAILED', 'Pipeline run failed', 'pending', 'show', false, true",
            sql,
        )

        self.assertIn("insert into profit_classification_transition_rules", lower)
        self.assertIn("pipeline_run_failed_detected", sql)
        self.assertIn("pipeline_run_succeeded_after_failure", sql)
        self.assertIn("no-op resolution", lower)

        self.assertIn("create or replace view profit_pipeline_run_failed_candidates", lower)
        self.assertIn("from profit_pipeline_runs run", lower)
        self.assertIn("run.status = 'failed'", lower)
        self.assertIn("run.status = 'partial'", lower)
        self.assertIn("(run.summary->>'total_steps_failed')::integer > 0", lower)
        self.assertIn("max(success.finished_at)", lower)
        self.assertIn("'System: Pipeline ' || run.pipeline_run_id::text", sql)
        self.assertIn("'pipeline_run_failed:' || run.pipeline_run_id::text", lower)

    def test_migration_036a_apply_function_adds_pipeline_run_failed_signals(self) -> None:
        self.assertTrue(SQL_036A.exists(), "036a pipeline run failed migration must exist")
        sql = SQL_036A.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)
        self.assertIn("pipeline_run_failed_detected_signals as", lower)
        self.assertIn("pipeline_run_succeeded_after_failure_signals as", lower)
        self.assertIn("later_success.status = 'success'", lower)
        self.assertIn("later_success.finished_at > failed_run.finished_at", lower)
        self.assertIn("'system:pipeline_run_failed'::text as source_audit_file", lower)
        self.assertIn("'pipeline_run_failed:' || candidate.pipeline_run_id::text", lower)

        for signal in [
            "manual_recognition_pending_detected",
            "recognition_event_recognized",
            "manual_invoice_detected",
            "sla_breach_detected",
            "active_agreement_appears",
        ]:
            self.assertIn(signal, sql)

    def test_migration_036b_manual_invoice_no_active_manual_trigger_cleanup(self) -> None:
        self.assertTrue(SQL_036B.exists(), "036b manual invoice cleanup migration must exist")
        sql = SQL_036B.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("insert into profit_classification_transition_rules", lower)
        self.assertIn(
            "('MANUAL_INVOICE_PENDING', 'manual_invoice_no_active_manual_trigger_services', 'MANUAL_INVOICE_PENDING', false, true",
            sql,
        )
        self.assertIn("no-op resolution", lower)

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)
        self.assertIn("manual_invoice_no_active_manual_trigger_services_signals as", lower)
        self.assertIn("not exists", lower)
        self.assertIn("profit_anchor_agreements active_agreement", lower)
        self.assertIn("active_agreement.display_status = 'active'", lower)
        self.assertIn(
            "active_agreement.raw->'profitSyncServiceSummary' @> '[{\"trigger\":\"manual\"}]'::jsonb",
            sql,
        )

        for signal in [
            "manual_recognition_pending_detected",
            "pipeline_run_failed_detected",
            "manual_invoice_agreement_terminated",
            "sla_breach_detected",
        ]:
            self.assertIn(signal, sql)

    def test_fulfillment_contract_documents_manual_invoice_no_active_cleanup(self) -> None:
        contract = FULFILLMENT_CONTRACT.read_text(encoding="utf-8")

        self.assertIn("manual_invoice_no_active_manual_trigger_services", contract)
        self.assertIn("no active agreement carrying a manual-trigger service", contract)
        self.assertIn("no-successor resolution", contract)


if __name__ == "__main__":
    unittest.main()
