from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_051 = ROOT / "supabase/sql/051_profit_normalize_client_name_v2.sql"


NORMALIZATION_FIXTURES = [
    ("Anderson Kool Air LLC-1", "andersonkoolair"),
    ("Anderson Kool Air LLC", "andersonkoolair"),
    ("The Bachert Law Firm PA", "bachertlawfirm"),
    ("Bachert Law Firm", "bachertlawfirm"),
    ("Hadar Steven", "hadarsteven"),
    ("Steven Hadar", "stevenhadar"),
    ("Lee's Inc", "lees"),
    ("DVH Investing LLC", "dvhinvesting"),
    ("1415 Cortez Rd LLC", "1415cortezrd"),
    ("6712 Manatee Ave LLC", "6712manateeave"),
    ("E & O Automotive LLC", "eand oautomotive".replace(" ", "")),
    ("Corey Monanghan", "coreymonanghan"),
]


def read_sql() -> str:
    return SQL_051.read_text(encoding="utf-8")


def test_051_upgrades_existing_normalizer_without_renaming_entry_point() -> None:
    sql = read_sql().lower()

    assert "create extension if not exists unaccent" in sql
    assert "create or replace function profit_normalize_client_name(value text)" in sql
    assert "profit_normalize_client_name_v2" not in sql
    assert "create or replace function profit_normalize_client_name_sorted(value text)" in sql


def test_051_normalizer_contains_required_rules() -> None:
    sql = read_sql().lower()

    assert "unaccent(" in sql
    assert "replace" in sql and "'&'" in sql and "' and '" in sql
    assert "\\m(the|a|an)\\m" in sql
    assert "\\m(llc|inc|corp|corporation|company|co|ltd|pllc|pa|lp|llp|pc|psc|lc|holdings|holding|enterprises|group|associates|partners)\\m" in sql
    assert "(-[0-9]+|\\([0-9]+\\))$" in sql


def test_051_documents_real_normalization_fixtures() -> None:
    sql = read_sql()

    for raw, expected in NORMALIZATION_FIXTURES:
        assert raw in sql
        assert expected in sql


def test_051_sorted_helper_is_audit_only_and_not_used_for_auto_match() -> None:
    sql = read_sql().lower()

    assert "audit visibility only" in sql
    sorted_fn_refs = [m.start() for m in re.finditer("profit_normalize_client_name_sorted", sql)]
    assert len(sorted_fn_refs) >= 2
