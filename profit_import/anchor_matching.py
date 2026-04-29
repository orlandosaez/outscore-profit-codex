from __future__ import annotations

import csv
import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from profit_import.assignments import ServiceOwnerAssignment


ENTITY_SUFFIXES = (
    "limitedliabilitycompany",
    "corporation",
    "company",
    "incorporated",
    "llc",
    "inc",
    "corp",
    "co",
    "pa",
)


@dataclass(frozen=True)
class AnchorAgreement:
    anchor_relationship_id: str
    agreement_name: str
    client_business_name: str
    contact_email: str
    status: str
    effective_date: str


@dataclass(frozen=True)
class OwnerAssignmentMatch:
    match_status: str
    match_reason: str
    candidate_count: int
    anchor_relationship_id: str | None
    anchor_agreement_name: str | None
    anchor_client_business_name: str | None
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


def parse_anchor_agreements_csv(path: Path | str) -> list[AnchorAgreement]:
    file_path = Path(path)
    with file_path.open(newline="", encoding="utf-8-sig") as file:
        reader = csv.DictReader(file)
        return [
            AnchorAgreement(
                anchor_relationship_id=row["agreement_id"],
                agreement_name=row["agreement_name"],
                client_business_name=row["contact_company_name"],
                contact_email=row["contact_email"],
                status=row["status"],
                effective_date=row["effective_date"],
            )
            for row in reader
            if row.get("agreement_id")
        ]


def match_owner_assignments_to_anchor(
    assignments: Iterable[ServiceOwnerAssignment],
    agreements: Iterable[AnchorAgreement],
) -> list[OwnerAssignmentMatch]:
    agreements_by_normalized_name: dict[str, list[AnchorAgreement]] = {}
    for agreement in agreements:
        normalized = normalize_client_name(agreement.client_business_name)
        if normalized:
            agreements_by_normalized_name.setdefault(normalized, []).append(agreement)

    matches: list[OwnerAssignmentMatch] = []
    for assignment in assignments:
        normalized = normalize_client_name(assignment.client_raw)
        candidates = agreements_by_normalized_name.get(normalized, [])

        if len(candidates) == 1:
            agreement = candidates[0]
            matches.append(_make_match(assignment, "matched", "normalized_client_name", candidates, agreement))
        elif len(candidates) > 1:
            matches.append(_make_match(assignment, "ambiguous", "multiple_normalized_client_name", candidates, None))
        else:
            matches.append(_make_match(assignment, "unmatched", "no_normalized_client_name", [], None))

    return matches


def build_owner_load_rows(matches: Iterable[OwnerAssignmentMatch], effective_from: str = "2026-01-01") -> list[dict[str, object]]:
    grouped: dict[tuple[str, str, str], dict[str, object]] = {}

    for match in matches:
        if match.match_status != "matched" or not match.anchor_relationship_id:
            continue

        key = (match.anchor_relationship_id, match.macro_service_type, match.primary_staff)
        row = grouped.setdefault(
            key,
            {
                "anchor_relationship_id": match.anchor_relationship_id,
                "macro_service_type": match.macro_service_type,
                "primary_staff": match.primary_staff,
                "effective_from": effective_from,
                "effective_to": None,
                "source_assignment_count": 0,
                "source_service_codes": [],
                "source_clients": [],
            },
        )
        row["source_assignment_count"] = int(row["source_assignment_count"]) + 1
        row["source_service_codes"].append(match.service_code)
        row["source_clients"].append(match.client_raw)

    rows = []
    for row in grouped.values():
        rows.append(
            {
                **row,
                "source_service_codes": "; ".join(sorted(set(row["source_service_codes"]))),
                "source_clients": "; ".join(sorted(set(row["source_clients"]))),
            }
        )

    return sorted(rows, key=lambda row: (str(row["anchor_relationship_id"]), str(row["macro_service_type"]), str(row["primary_staff"])))


def summarize_owner_matches(matches: Iterable[OwnerAssignmentMatch]) -> dict[str, object]:
    rows = list(matches)
    status_counts = Counter(row.match_status for row in rows)
    macro_counts = Counter(row.macro_service_type for row in rows if row.match_status == "matched")

    return {
        "assignment_count": len(rows),
        "matched_assignment_count": status_counts.get("matched", 0),
        "unmatched_assignment_count": status_counts.get("unmatched", 0),
        "ambiguous_assignment_count": status_counts.get("ambiguous", 0),
        "matched_macro_service_type_counts": dict(sorted(macro_counts.items())),
    }


def write_owner_matches_csv(matches: Iterable[OwnerAssignmentMatch], output_path: Path | str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "match_status",
        "client_raw",
        "service_code",
        "macro_service_type",
        "service_tier",
        "primary_staff",
        "reviewer_staff",
        "anchor_relationship_id",
        "anchor_client_business_name",
        "anchor_agreement_name",
        "match_reason",
        "candidate_count",
        "context_tokens",
        "source_file",
        "source_sheet",
        "source_row",
    ]

    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for match in matches:
            writer.writerow(
                {
                    "match_status": match.match_status,
                    "client_raw": match.client_raw,
                    "service_code": match.service_code,
                    "macro_service_type": match.macro_service_type,
                    "service_tier": match.service_tier,
                    "primary_staff": match.primary_staff,
                    "reviewer_staff": match.reviewer_staff,
                    "anchor_relationship_id": match.anchor_relationship_id,
                    "anchor_client_business_name": match.anchor_client_business_name,
                    "anchor_agreement_name": match.anchor_agreement_name,
                    "match_reason": match.match_reason,
                    "candidate_count": match.candidate_count,
                    "context_tokens": "; ".join(match.context_tokens),
                    "source_file": match.source_file,
                    "source_sheet": match.source_sheet,
                    "source_row": match.source_row,
                }
            )


def write_owner_load_rows_csv(rows: Iterable[dict[str, object]], output_path: Path | str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "anchor_relationship_id",
        "macro_service_type",
        "primary_staff",
        "effective_from",
        "effective_to",
        "source_assignment_count",
        "source_service_codes",
        "source_clients",
    ]
    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_owner_load_sql(rows: Iterable[dict[str, object]], output_path: Path | str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    rows_list = list(rows)

    values = ",\n".join(
        "  "
        + "("
        + ", ".join(
            [
                _sql_string(str(row["anchor_relationship_id"])),
                _sql_string(str(row["macro_service_type"])),
                _sql_string(str(row["primary_staff"])),
                f"{_sql_string(str(row['effective_from']))}::date",
                "null::date" if row.get("effective_to") in {None, ""} else f"{_sql_string(str(row['effective_to']))}::date",
            ]
        )
        + ")"
        for row in rows_list
    )

    sql = f"""begin;

create temp table tmp_profit_client_service_owner_load (
  anchor_relationship_id text not null,
  macro_service_type text not null,
  staff_name text not null,
  effective_from date not null,
  effective_to date
) on commit drop;

insert into tmp_profit_client_service_owner_load (
  anchor_relationship_id,
  macro_service_type,
  staff_name,
  effective_from,
  effective_to
)
values
{values};

do $$
begin
  if exists (
    select 1
    from tmp_profit_client_service_owner_load incoming
    left join profit_staff staff
      on lower(staff.name) = lower(incoming.staff_name)
    where staff.id is null
  ) then
    raise exception 'missing staff in profit_staff: %',
      (
        select string_agg(distinct incoming.staff_name, ', ' order by incoming.staff_name)
        from tmp_profit_client_service_owner_load incoming
        left join profit_staff staff
          on lower(staff.name) = lower(incoming.staff_name)
        where staff.id is null
      );
  end if;
end $$;

create unique index if not exists profit_client_service_owners_relationship_macro_effective_from_key
  on profit_client_service_owners (anchor_relationship_id, macro_service_type, effective_from);

insert into profit_client_service_owners (
  anchor_relationship_id,
  macro_service_type,
  staff_id,
  effective_from,
  effective_to
)
select
  incoming.anchor_relationship_id,
  incoming.macro_service_type,
  staff.id,
  incoming.effective_from,
  incoming.effective_to
from tmp_profit_client_service_owner_load incoming
join profit_staff staff
  on lower(staff.name) = lower(incoming.staff_name)
on conflict (anchor_relationship_id, macro_service_type, effective_from)
do update set
  staff_id = excluded.staff_id,
  effective_to = excluded.effective_to;

commit;
"""
    path.write_text(sql, encoding="utf-8")


def normalize_client_name(value: object) -> str:
    text = "" if value is None else str(value)
    text = re.sub(r"\([^)]*\)", " ", text)
    text = text.lower().replace("&", "and")
    text = re.sub(r"[^a-z0-9]+", " ", text)
    tokens = [token for token in text.split() if token not in {"and", "the"}]
    joined = "".join(tokens)

    changed = True
    while changed:
        changed = False
        for suffix in ENTITY_SUFFIXES:
            if joined.endswith(suffix) and len(joined) > len(suffix):
                joined = joined[: -len(suffix)]
                changed = True
                break

    return joined


def _sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _make_match(
    assignment: ServiceOwnerAssignment,
    match_status: str,
    match_reason: str,
    candidates: list[AnchorAgreement],
    agreement: AnchorAgreement | None,
) -> OwnerAssignmentMatch:
    return OwnerAssignmentMatch(
        match_status=match_status,
        match_reason=match_reason,
        candidate_count=len(candidates),
        anchor_relationship_id=agreement.anchor_relationship_id if agreement else None,
        anchor_agreement_name=agreement.agreement_name if agreement else None,
        anchor_client_business_name=agreement.client_business_name if agreement else None,
        client_raw=assignment.client_raw,
        service_token=assignment.service_token,
        service_code=assignment.service_code,
        macro_service_type=assignment.macro_service_type,
        service_tier=assignment.service_tier,
        primary_staff=assignment.primary_staff,
        reviewer_staff=assignment.reviewer_staff,
        context_tokens=assignment.context_tokens,
        source_file=assignment.source_file,
        source_sheet=assignment.source_sheet,
        source_row=assignment.source_row,
    )
