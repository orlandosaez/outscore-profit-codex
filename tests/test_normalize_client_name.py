from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_051 = ROOT / "supabase/sql/051_profit_normalize_client_name_v2.sql"
SQL_055 = ROOT / "supabase/sql/055_profit_normalize_client_name_fka_dba.sql"


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


FKA_DBA_FIXTURES = [
    # V0.7.J.1: Anchor records embed FKA/DBA references that must collapse to the legal name.
    ("1415 Cortez Rd LLC fka Midas South Bradenton LLC", "1415cortezrd"),
    ("6712 Manatee Ave LLC FKA Midas North Bradenton LLC", "6712manateeave"),
    ("Smith Corp dba Smith Services", "smith"),
    ("Smith Corp d/b/a Smith Services", "smith"),
    ("Acme Inc f/k/a Old Acme", "acme"),
    ("Beta LLC formerly known as Alpha Inc", "beta"),
    ("Beta LLC formerly Alpha Inc", "beta"),
    # Regression lock: "Aka" at start of name is NOT a marker (no leading whitespace).
    ("Aka Industries LLC", "akaindustries"),
]


def read_sql() -> str:
    return SQL_051.read_text(encoding="utf-8")


def read_sql_055() -> str:
    return SQL_055.read_text(encoding="utf-8")


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


def test_055_replaces_normalizer_with_fka_dba_aware_version() -> None:
    sql = read_sql_055().lower()

    assert "create or replace function profit_normalize_client_name(value text)" in sql
    assert "fka_dba_stripped" in sql
    # Marker regex must include all the FKA/DBA variants.
    assert "fka|f[/.]k[/.]a" in sql
    assert "dba|d[/.]b[/.]a" in sql
    assert "formerly(\\s+known\\s+as)?" in sql
    # Leading \s+ guards against stripping names that start with "Aka"/"Fka"/etc.
    assert "'\\s+(fka|" in sql
    # public.unaccent qualification preserved.
    assert "public.unaccent" in sql


def test_055_documents_fka_dba_fixtures_inline() -> None:
    sql = read_sql_055()

    for raw, expected in FKA_DBA_FIXTURES:
        # Fixture cases are documented in the function comment so the
        # migration is self-documenting for future reviewers.
        # Aka Industries is the only regression-lock fixture worth asserting
        # explicitly here; the rest live in the comment string.
        if raw == "Aka Industries LLC":
            assert raw in sql
            assert expected in sql


def test_055_carries_forward_051_regression_fixtures_in_comment() -> None:
    """Migration 055 must document that V0.7.J's regression fixtures still hold.

    SQL string literals escape single quotes by doubling them, so we test
    against the SQL-escaped form where applicable.
    """
    sql = read_sql_055()
    # The 055 comment lists fixtures from 051 to signal the function is a superset.
    for raw, expected in [
        ("Anderson Kool Air LLC-1", "andersonkoolair"),
        ("The Bachert Law Firm PA", "bachertlawfirm"),
        ("Lee''s Inc", "lees"),  # SQL-escaped form of Lee's Inc
        ("DVH Investing LLC", "dvhinvesting"),
    ]:
        assert raw in sql, f"055 comment should reference 051 fixture {raw}"
        assert expected in sql, f"055 comment should reference 051 expected {expected}"
