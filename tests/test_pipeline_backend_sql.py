from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def read_sql(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_migration_026_defines_pipeline_run_tables() -> None:
    sql = read_sql("supabase/sql/026_profit_pipeline_runs.sql").lower()

    assert "create table if not exists profit_pipeline_runs" in sql
    assert "pipeline_run_id uuid primary key default gen_random_uuid()" in sql
    assert "run_source text not null" in sql
    assert "check (run_source in ('cron', 'manual'))" in sql
    assert "status text not null" in sql
    assert "check (status in ('running', 'success', 'failed', 'partial'))" in sql
    assert "triggered_by text" in sql
    assert "summary jsonb not null default '{}'::jsonb" in sql

    assert "create table if not exists profit_pipeline_run_steps" in sql
    assert "step_order integer not null" in sql
    assert "primary key (pipeline_run_id, step_name)" in sql
    assert "unique (pipeline_run_id, step_order)" in sql
    assert "details jsonb not null default '{}'::jsonb" in sql


def test_migration_026_locks_run_concurrency_and_indexes() -> None:
    sql = read_sql("supabase/sql/026_profit_pipeline_runs.sql").lower()

    assert "where status = 'running'" in sql
    assert "unique index" in sql
    assert "idx_profit_pipeline_runs_started_at_desc" in sql
    assert "idx_profit_pipeline_runs_status_started_at_desc" in sql
    assert "idx_profit_pipeline_run_steps_run_order" in sql


def test_migration_026_documents_triggered_by_and_jsonb_conventions() -> None:
    sql = read_sql("supabase/sql/026_profit_pipeline_runs.sql").lower()

    assert "manual runs: operator identifier" in sql
    assert "cron runs: cron" in sql
    assert "synthetic checkpoint rows: test" in sql
    assert "total_steps_completed" in sql
    assert "total_steps_failed" in sql
    assert "total_rows_affected" in sql
    assert "notable_findings" in sql


def test_migration_026a_expands_apply_transition_rules() -> None:
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "create or replace function profit_apply_classification_transitions" in sql
    assert "p_dry_run boolean default true" in sql
    assert "active_agreement_appears" in sql
    assert "first_matching_anchor_invoice_group_billed" in sql
    assert "first_matching_anchor_invoice_mid_cycle" in sql
    assert "cash_collected_group_parent" in sql
    assert "cash_collected_standalone_mid_cycle" in sql
    assert "settled_via_quickbooks_payment" not in sql
    assert "anchor_backfill_invoice" not in sql


def test_migration_026a_documents_match_dependency_and_cash_timing() -> None:
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "auto-transition correctness requires profit_fc_client_anchor_matches.anchor_relationship_id" in sql
    assert "will be skipped silently" in sql
    assert "profit_cash_collections" in sql
    assert "collection.collection_key = allocation.collection_key" in sql
    assert "collected_at::timestamptz" in sql
    assert "allocation.loaded_at" not in sql


def test_migration_026a_locks_service_type_guards() -> None:
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "macro_service_type" in sql
    assert "recognition_pattern" in sql
    assert "service_period_rule" in sql
    assert "manual_review" in sql
    assert "service_period_rule = 'manual'" in sql
    assert "canonical_service_name is null" in sql


def test_migration_026a_names_required_behavior_fixtures() -> None:
    sql = read_sql("supabase/sql/026a_profit_apply_classification_transitions_v2.sql").lower()

    assert "fixture: group_billed_priority_over_standalone" in sql
    assert "fixture: multiple_group_sibling_signals_insert_one_row" in sql
    assert "fixture: multi_service_type_ambiguity_skips" in sql
    assert "fixture: unresolved_canonical_service_skips" in sql
    assert "fixture: manual_review_rule_skips" in sql
    assert "fixture: manual_service_period_rule_skips" in sql


def test_migration_026b_defines_reconcile_function() -> None:
    sql = read_sql("supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql").lower()

    assert "create or replace function profit_reconcile_fc_client_anchor_matches" in sql
    assert "p_dry_run boolean default true" in sql
    assert "returns table" in sql
    assert "persisted_match_method" in sql
    assert "candidate_match_status" in sql
    assert "candidate_anchor_relationship_id" in sql
    assert "action text" in sql


def test_migration_026b_hard_deletes_only_auto_exact_and_protects_manual_override() -> None:
    sql = read_sql("supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql").lower()

    assert "match_method = 'auto_exact'" in sql
    assert "delete from profit_fc_client_anchor_matches" in sql
    assert "manual_override" in sql
    assert "manual override rows are protected" in sql


def test_migration_026b_locks_demote_cases_and_idempotency() -> None:
    sql = read_sql("supabase/sql/026b_profit_reconcile_fc_client_anchor_matches.sql").lower()

    assert "candidate.match_status" in sql
    assert "<> 'auto_exact'" in sql
    assert "is distinct from" in sql
    assert "fixture: relationship_id_changed_branch" in sql
    assert "fixture: second_live_call_returns_zero" in sql


def test_migration_026c_defines_pipeline_diagnostic_views() -> None:
    sql = read_sql("supabase/sql/026c_profit_pipeline_diagnostic_views.sql").lower()

    assert "create or replace view profit_pipeline_classification_transition_blockers" in sql
    assert "create or replace view profit_pipeline_due_reclassifications" in sql
    assert "create or replace view profit_pipeline_stuck_recognition_triggers" in sql


def test_migration_026c_locks_blocker_grain_and_reasons() -> None:
    sql = read_sql("supabase/sql/026c_profit_pipeline_diagnostic_views.sql").lower()

    assert "classification_id" in sql
    assert "signal_name" in sql
    assert "blocker_reason" in sql
    assert "no_anchor_match" in sql
    assert "multi_service_ambiguity" in sql
    assert "unresolved_canonical_service" in sql
    assert "manual_review_service_rule" in sql
    assert "one row per applicable transition rule" in sql


def test_migration_026c_hardcodes_stuck_threshold() -> None:
    sql = read_sql("supabase/sql/026c_profit_pipeline_diagnostic_views.sql").lower()

    assert "stuck threshold: pending revenue events older than 30 days are surfaced for triage" in sql
    assert "now() - interval '30 days'" in sql
    assert "threshold is operational policy; if changed, update this view rather than parameterizing" in sql
    assert "p_stuck_days" not in sql


def test_migration_052_defines_alias_table_and_only_midas_seed_rows() -> None:
    sql = read_sql(
        "supabase/sql/052_profit_client_aliases_and_anchor_match_candidates_fuzzy.sql"
    )
    lower = sql.lower()

    assert "create table if not exists profit_client_aliases" in lower
    assert "manual_fka" in lower
    assert "manual_dba" in lower
    assert "manual_legal_to_dba" in lower
    assert "operator_note" in lower
    assert "1415 Cortez Rd LLC" in sql
    assert "Midas South Bradenton" in sql
    assert "6712 Manatee Ave LLC" in sql
    assert "Midas North Bradenton" in sql
    assert "Bachert" not in sql
    assert "Lee's" not in sql
    assert "DVH" not in sql
    assert "Hadar" not in sql
    assert "Anderson Kool Air LLC-1" not in sql


def test_migration_052_candidate_view_preserves_status_truth_table_under_fuzzy() -> None:
    sql = read_sql(
        "supabase/sql/052_profit_client_aliases_and_anchor_match_candidates_fuzzy.sql"
    )
    lower = sql.lower()

    assert "create or replace view profit_fc_client_anchor_match_candidates" in lower
    assert "when anchor_candidate.display_status = 'active' then 1" in lower
    assert "when anchor_candidate.display_status = 'terminated' then 2" in lower
    assert "when anchor_candidate.display_status = 'stale' then 3" in lower
    assert "active_anchor_count = 1" in lower
    assert "active_anchor_count > 1" in lower
    assert "terminated-only" in lower
    assert "stale-only" in lower


def test_migration_052_candidate_view_adds_candidate_only_fuzzy_tier() -> None:
    sql = read_sql(
        "supabase/sql/052_profit_client_aliases_and_anchor_match_candidates_fuzzy.sql"
    ).lower()

    assert "create extension if not exists pg_trgm" in sql
    assert "similarity(" in sql
    assert ">= 0.92" in sql
    assert "'auto_fuzzy'" in sql
    assert "match_confidence" in sql
    assert "not exists" in sql
    assert "profit_fc_client_anchor_matches" not in sql
    assert "manual_override" not in sql


def test_migration_052_names_gap_case_and_regression_fixtures() -> None:
    sql = read_sql(
        "supabase/sql/052_profit_client_aliases_and_anchor_match_candidates_fuzzy.sql"
    )

    for fixture in [
        "fixture: bachert_article_suffix_normalizes",
        "fixture: hadar_sorted_helper_audit_only",
        "fixture: anderson_dedup_suffix_normalizes",
        "fixture: midas_south_alias_auto_exact",
        "fixture: midas_north_alias_auto_exact",
        "fixture: lees_apostrophe_suffix_normalizes",
        "fixture: corey_monaghan_monanghan_fuzzy_candidate",
        "E & O Automotive LLC",
        "Kar Kraft Auto Repair LLC (TempleTerrace)",
        "Kar Kraft Services LLC (Zephyrhills)",
        "YV Enterprises HB LLC",
        "YV Enterprises PSL LLC",
    ]:
        assert fixture in sql


def test_migration_053_adds_l_category_without_new_subcategory_column() -> None:
    sql = read_sql("supabase/sql/053_profit_data_quality_alerts_client_match.sql")
    lower = sql.lower()

    assert "create or replace view profit_data_quality_alerts" in lower
    assert lower.count("'client_match_suspected_dup_or_gap'::text") == 3
    assert "'l.1:'" in lower
    assert "'l.2:'" in lower
    assert "'l.3:'" in lower
    assert " as subcategory" not in lower
    assert "subcategory text" not in lower
    assert "client_master" not in lower


def test_migration_053_l1_l2_l3_conditions_and_thresholds() -> None:
    sql = read_sql("supabase/sql/053_profit_data_quality_alerts_client_match.sql").lower()

    assert "fc.name ~ '-[0-9]+$'" in sql
    assert "similarity(" in sql
    assert "sim.score >= 0.85" in sql
    assert "sim.score < 0.92" in sql
    assert "ag.display_status = 'active'" in sql
    assert "profit_client_aliases" in sql
    assert "exact/alias/fuzzy fc candidate" in sql


def test_migration_053_anchor_no_fc_match_suppresses_pending_candidates() -> None:
    sql = read_sql("supabase/sql/053_profit_data_quality_alerts_client_match.sql").lower()

    assert "-- b. anchor_no_fc_match" in sql
    assert "profit_fc_client_anchor_match_candidates candidate" in sql
    assert "candidate.anchor_relationship_id = ag.anchor_relationship_id" in sql
    assert "candidate.match_status in ('auto_exact', 'auto_fuzzy')" in sql
    assert "awaiting w25 confirmation" in sql


def test_migration_054_category_e_only_fires_for_auto_trigger() -> None:
    sql = read_sql("supabase/sql/054_profit_billing_audit_frequency_aware.sql")
    lower = sql.lower()

    assert "create or replace view profit_data_quality_alerts" in lower
    assert "coalesce(service->'billing'->>'trigger', '') = 'auto'" in lower
    assert "coalesce(service->'status'->>'type', '') = 'approved'" in lower
    assert "service->'billing'->>'occurrence'" in lower
    assert "service->>'trigger'" not in lower
    assert "service->>'occurrence'" not in lower
    assert "service->>'status'" not in lower


def test_migration_054_category_e_threshold_per_occurrence() -> None:
    sql = read_sql("supabase/sql/054_profit_billing_audit_frequency_aware.sql").lower()

    fixtures = [
        ("monthly safe", "monthly", 30, False),
        ("monthly fire", "monthly", 50, True),
        ("quarterly safe", "quarterly", 90, False),
        ("quarterly fire", "quarterly", 110, True),
        ("yearly safe", "yearly", 200, False),
    ]
    thresholds = {"monthly": 45, "quarterly": 100}

    for _, occurrence, days_since_invoice, should_fire in fixtures:
        threshold = thresholds.get(occurrence, 380)
        assert (days_since_invoice > threshold) is should_fire

    assert "when 'monthly' then 45" in sql
    assert "when 'quarterly' then 100" in sql
    assert "else 380" in sql
    assert "> (cadence.threshold_days::text || ' days')::interval" in sql
    assert "'d threshold for '" in sql
    assert "'auto-billed service cadence violated: ' || violations.violating_services" in sql


def test_migration_054_category_m_fires_on_held_invoice() -> None:
    sql = read_sql("supabase/sql/054_profit_billing_audit_frequency_aware.sql").lower()

    # Anchor's raw.status whitelist post-2026-05-24 hotfix: only 'issued' or 'overdue'
    # invoices with amount_due > 0 and age > 30d fire M. Net-zero paid invoices
    # (e.g., SBC-00055: $650 charge + $650 credit memo) used to false-fire under
    # the prior amount_paid=0 + qbo_status filter. Now Anchor's authoritative
    # status is the primary signal.
    fixtures = [
        {
            "name": "issued > 30d fires",
            "anchor_status": "issued",
            "amount_due": 650,
            "days_old": 45,
            "fires": True,
        },
        {
            "name": "overdue > 30d fires",
            "anchor_status": "overdue",
            "amount_due": 650,
            "days_old": 45,
            "fires": True,
        },
        {
            "name": "issued recent safe (< 30d)",
            "anchor_status": "issued",
            "amount_due": 650,
            "days_old": 12,
            "fires": False,
        },
        {
            "name": "paid safe",
            "anchor_status": "paid",
            "amount_due": 0,
            "days_old": 45,
            "fires": False,
        },
        {
            "name": "voided safe",
            "anchor_status": "voided",
            "amount_due": 0,
            "days_old": 45,
            "fires": False,
        },
        {
            "name": "processing safe (in-flight ACH)",
            "anchor_status": "processing",
            "amount_due": 650,
            "days_old": 45,
            "fires": False,
        },
        {
            "name": "net-zero credit-balanced 'paid' invoice safe (SBC-00055 regression lock)",
            "anchor_status": "paid",
            "amount_due": 0,
            "days_old": 112,
            "fires": False,
        },
    ]
    fire_statuses = {"issued", "overdue"}

    for fixture in fixtures:
        fires = (
            fixture["anchor_status"] in fire_statuses
            and fixture["amount_due"] > 0
            and fixture["days_old"] > 30
        )
        assert fires is fixture["fires"], fixture["name"]

    assert "'held_invoice_unpaid'::text" in sql
    assert "'anchor_invoice'::text" in sql
    assert "coalesce(inv.raw->>'status', '') in ('issued', 'overdue')" in sql
    assert "coalesce(inv.amount_due, 0) > 0" in sql
    assert "now() - inv.issue_date::timestamptz > interval '30 days'" in sql


def test_migration_054_carries_forward_all_prior_categories() -> None:
    sql = read_sql("supabase/sql/054_profit_billing_audit_frequency_aware.sql")
    view_sql = sql.split("comment on view profit_data_quality_alerts", maxsplit=1)[0]
    categories = set(
        re.findall(
            r"(?:^|\n)select(?:\s+distinct)?\s+(?:\n\s*)?'([a-z0-9_]+)'(?:::text)?(?:\s+as\s+\w+)?\s*,",
            view_sql,
        )
    )

    assert categories == {
        "fc_stale_record",
        "anchor_no_fc_match",
        "engagement_type_unclassified",
        "subscription_with_manual_service",
        "subscription_billing_gap",
        "orphan_attribution_duplicate",
        "parent_child_1040_false_positive",
        "paid_anchor_invoice_not_cleared",
        "manual_invoice_already_invoiced",
        "catalog_gap_service_no_rule",
        "label_unresolved_with_sibling_candidate",
        "pipeline_cron_stale",
        "client_match_suspected_dup_or_gap",
        "held_invoice_unpaid",
    }

    assert len(categories) == 14
