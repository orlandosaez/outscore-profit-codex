from __future__ import annotations

import csv
import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import openpyxl


TIER_BY_SUFFIX = {
    "A": "advanced",
    "E": "essential",
    "P": "plus",
}

TIERED_PREFIXES = ("1040", "1065", "1120", "990", "BOOK")


@dataclass(frozen=True)
class AssignmentSourceRow:
    client_raw: str
    raw_group_service: str
    primary_staff: str
    reviewer_staff: str
    service_tokens: tuple[str, ...]
    context_tokens: tuple[str, ...]
    source_file: str
    source_sheet: str
    source_row: int


@dataclass(frozen=True)
class ServiceOwnerAssignment:
    client_raw: str
    service_token: str
    service_code: str
    macro_service_type: str
    service_tier: str | None
    primary_staff: str
    reviewer_staff: str
    context_tokens: tuple[str, ...]
    source_file: str
    source_sheet: str
    source_row: int


def parse_assignment_workbook(path: Path | str) -> list[AssignmentSourceRow]:
    file_path = Path(path)
    workbook = openpyxl.load_workbook(file_path, read_only=True, data_only=True)
    worksheet = workbook.worksheets[0]

    rows: list[AssignmentSourceRow] = []
    for row_number, row in enumerate(worksheet.iter_rows(min_row=2, values_only=True), start=2):
        client_raw = _clean_text(row[0] if len(row) > 0 else None)
        raw_group_service = _clean_text(row[1] if len(row) > 1 else None)
        if not client_raw:
            continue

        tokens = _split_group_service_tokens(raw_group_service)
        service_tokens = tuple(token for token in tokens if _is_service_token(token))
        context_tokens = tuple(token for token in tokens if not _is_service_token(token))

        rows.append(
            AssignmentSourceRow(
                client_raw=client_raw,
                raw_group_service=raw_group_service,
                primary_staff=_clean_text(row[2] if len(row) > 2 else None),
                reviewer_staff=_clean_text(row[3] if len(row) > 3 else None),
                service_tokens=service_tokens,
                context_tokens=context_tokens,
                source_file=file_path.name,
                source_sheet=worksheet.title,
                source_row=row_number,
            )
        )

    return rows


def expand_service_owner_assignments(rows: Iterable[AssignmentSourceRow]) -> list[ServiceOwnerAssignment]:
    assignments: list[ServiceOwnerAssignment] = []

    for row in rows:
        for service_token in row.service_tokens:
            service_code, macro_service_type, service_tier = service_code_details(service_token)
            assignments.append(
                ServiceOwnerAssignment(
                    client_raw=row.client_raw,
                    service_token=service_token,
                    service_code=service_code,
                    macro_service_type=macro_service_type,
                    service_tier=service_tier,
                    primary_staff=row.primary_staff,
                    reviewer_staff=row.reviewer_staff,
                    context_tokens=row.context_tokens,
                    source_file=row.source_file,
                    source_sheet=row.source_sheet,
                    source_row=row.source_row,
                )
            )

    return assignments


def service_code_details(token: str) -> tuple[str, str, str | None]:
    code = _service_code(token)
    tier = _service_tier(code)

    if code.startswith("BOOK") or code == "YECLOSE":
        return code, "bookkeeping", tier
    if code in {"PAYROLL", "941"}:
        return code, "payroll", tier
    if code == "SETUP":
        return code, "advisory", tier
    if code == "TPP" or code.startswith(("1040", "1065", "1099", "1120", "990")):
        return code, "tax", tier

    return code, "other", tier


def summarize_owner_assignments(assignments: Iterable[ServiceOwnerAssignment]) -> dict[str, object]:
    rows = list(assignments)
    macro_counts = Counter(row.macro_service_type for row in rows)
    owner_counts = Counter(row.primary_staff or "(blank)" for row in rows)
    unmapped_codes = sorted({row.service_code for row in rows if row.macro_service_type == "other"})

    return {
        "assignment_count": len(rows),
        "macro_service_type_counts": dict(sorted(macro_counts.items())),
        "primary_staff_counts": dict(sorted(owner_counts.items())),
        "unmapped_service_codes": unmapped_codes,
    }


def write_owner_assignments_csv(assignments: Iterable[ServiceOwnerAssignment], output_path: Path | str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "client_raw",
        "service_token",
        "service_code",
        "macro_service_type",
        "service_tier",
        "primary_staff",
        "reviewer_staff",
        "context_tokens",
        "source_file",
        "source_sheet",
        "source_row",
    ]

    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for assignment in assignments:
            writer.writerow(
                {
                    "client_raw": assignment.client_raw,
                    "service_token": assignment.service_token,
                    "service_code": assignment.service_code,
                    "macro_service_type": assignment.macro_service_type,
                    "service_tier": assignment.service_tier,
                    "primary_staff": assignment.primary_staff,
                    "reviewer_staff": assignment.reviewer_staff,
                    "context_tokens": "; ".join(assignment.context_tokens),
                    "source_file": assignment.source_file,
                    "source_sheet": assignment.source_sheet,
                    "source_row": assignment.source_row,
                }
            )


def _split_group_service_tokens(value: str) -> tuple[str, ...]:
    return tuple(token for token in (_clean_text(part) for part in value.split(";")) if token)


def _is_service_token(token: str) -> bool:
    return bool(re.match(r"^S\s+\S+", token, flags=re.IGNORECASE))


def _service_code(token: str) -> str:
    text = _clean_text(token).upper()
    match = re.match(r"^S\s+(.+)$", text)
    return _clean_text(match.group(1) if match else text).upper()


def _service_tier(code: str) -> str | None:
    if not code.startswith(TIERED_PREFIXES):
        return None
    return TIER_BY_SUFFIX.get(code[-1])


def _clean_text(value: object) -> str:
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value)).strip()
