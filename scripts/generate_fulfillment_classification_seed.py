from __future__ import annotations

import argparse
import csv
import hashlib
import json
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / "docs/audits/2026-05-04-fulfillment-leaks-classification.csv"
DEFAULT_OUTPUT = ROOT / "supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql"
SOURCE_AUDIT_FILE = "docs/audits/2026-05-04-fulfillment-leaks-classification.csv"

CANONICAL_VERDICTS = {
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
}

VERDICT_ALIASES = {
    "consolidated_via_group_billed": "CONSOLIDATED_VIA_GROUP_BILLED",
}

DRIFT_NOTE = (
    "Audit CSV captured this row as PENDING_ENGAGEMENT_* on 2026-05-04 "
    "but client now has an active agreement. Manual reclassification required."
)


@dataclass(frozen=True)
class PendingDrift:
    fc_client_id: str
    has_active_agreement: bool


def normalize_verdict(raw: str) -> str:
    stripped = raw.strip()
    verdict = VERDICT_ALIASES.get(stripped, stripped.upper())
    if verdict not in CANONICAL_VERDICTS:
        raise ValueError(f"Unknown verdict after normalization: {raw!r} -> {verdict!r}")
    return verdict


def sql_literal(value: object) -> str:
    if value is None:
        return "null"
    text = str(value)
    return "'" + text.replace("'", "''") + "'"


def decimal_or_null(raw: str) -> str:
    value = raw.strip()
    if not value:
        return "null"
    try:
        return str(Decimal(value))
    except InvalidOperation as exc:
        raise ValueError(f"Invalid estimated_annual_revenue: {raw!r}") from exc


def row_hash(row: dict[str, str]) -> str:
    payload = json.dumps(row, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def load_pending_drift(path: Path | None) -> dict[str, PendingDrift]:
    if path is None:
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {
        str(fc_client_id): PendingDrift(
            fc_client_id=str(fc_client_id),
            has_active_agreement=bool(has_active),
        )
        for fc_client_id, has_active in sorted(data.items())
    }


def transform_rows(
    rows: Iterable[dict[str, str]],
    pending_drift: dict[str, PendingDrift],
    *,
    run_date: date,
) -> tuple[list[dict[str, object]], int, int]:
    transformed: list[dict[str, object]] = []
    captured_count = 0
    drift_count = 0

    for index, row in enumerate(rows, start=1):
        source_raw = row["veredict"]
        verdict = normalize_verdict(source_raw)
        fc_client_id = row["fc_client_id"].strip()
        re_evaluate_at: str | None = None
        notes = row.get("needs_manual_review", "").strip()

        if verdict in {"PENDING_ENGAGEMENT_DRAFT", "PENDING_ENGAGEMENT_SENT"}:
            drift = pending_drift.get(fc_client_id)
            if drift and drift.has_active_agreement:
                verdict = "MIXED"
                notes = DRIFT_NOTE
                re_evaluate_at = run_date.isoformat()
                drift_count += 1
            else:
                re_evaluate_at = (run_date + timedelta(days=30)).isoformat()
                captured_count += 1
        else:
            captured_count += 1

        transformed.append(
            {
                "fc_client_id": fc_client_id,
                "fc_client_name": row["fc_client_name"].strip(),
                "group_name": row["group_name"].strip() or None,
                "verdict_code": verdict,
                "source_verdict_raw": source_raw,
                "source_audit_row_hash": row_hash(row),
                "suggested_classification": row["suggested_classification"].strip() or None,
                "estimated_annual_revenue": row["estimated_annual_revenue"].strip(),
                "notes": notes or None,
                "re_evaluate_at": re_evaluate_at,
                "source_row_number": index,
            }
        )

    return transformed, captured_count, drift_count


def read_audit_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def group_id_expression(group_name: object) -> str:
    if group_name is None:
        return "null"
    return (
        "(select group_id from profit_client_groups "
        f"where profit_normalize_client_name(group_name) = profit_normalize_client_name({sql_literal(group_name)}) "
        "order by group_name limit 1)"
    )


def render_sql(rows: list[dict[str, object]], captured_count: int, drift_count: int) -> str:
    lines = [
        "-- Generated by scripts/generate_fulfillment_classification_seed.py",
        f"-- Source audit file: {SOURCE_AUDIT_FILE}",
        f"-- Total inserted: {len(rows)}",
        f"-- Rows seeded as captured: {captured_count}",
        f"-- Rows reclassified to MIXED due to drift: {drift_count}",
        "",
        "insert into profit_classifications (",
        "  fc_client_id,",
        "  anchor_relationship_id,",
        "  group_id,",
        "  verdict_code,",
        "  source_verdict_raw,",
        "  source_audit_file,",
        "  source_audit_row_hash,",
        "  suggested_classification,",
        "  estimated_annual_revenue,",
        "  notes,",
        "  classified_by,",
        "  re_evaluate_at",
        ") values",
    ]

    value_lines = []
    for row in rows:
        value_lines.append(
            "  ("
            f"{row['fc_client_id']}::bigint, "
            "null, "
            f"{group_id_expression(row['group_name'])}, "
            f"{sql_literal(row['verdict_code'])}, "
            f"{sql_literal(row['source_verdict_raw'])}, "
            f"{sql_literal(SOURCE_AUDIT_FILE)}, "
            f"{sql_literal(row['source_audit_row_hash'])}, "
            f"{sql_literal(row['suggested_classification'])}, "
            f"{decimal_or_null(str(row['estimated_annual_revenue']))}, "
            f"{sql_literal(row['notes'])}, "
            "'orlando', "
            f"{sql_literal(row['re_evaluate_at'])}"
            ")"
        )

    lines.append(",\n".join(value_lines) + "\n")
    lines.extend(
        [
            "on conflict (source_audit_file, source_audit_row_hash) do update set",
            "  verdict_code = excluded.verdict_code,",
            "  source_verdict_raw = excluded.source_verdict_raw,",
            "  suggested_classification = excluded.suggested_classification,",
            "  estimated_annual_revenue = excluded.estimated_annual_revenue,",
            "  notes = excluded.notes,",
            "  re_evaluate_at = excluded.re_evaluate_at,",
            "  updated_at = now();",
            "",
        ]
    )
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--pending-drift-json", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--run-date", type=lambda value: date.fromisoformat(value), default=date.today())
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rows = read_audit_rows(args.input)
    pending_drift = load_pending_drift(args.pending_drift_json)
    transformed, captured_count, drift_count = transform_rows(
        rows,
        pending_drift,
        run_date=args.run_date,
    )
    sql = render_sql(transformed, captured_count, drift_count)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(sql, encoding="utf-8")

    print(f"rows seeded as captured: {captured_count}")
    print(f"rows reclassified to MIXED due to drift: {drift_count}")
    print(f"total inserted: {len(transformed)}")
    print(f"wrote {args.output.resolve().relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
