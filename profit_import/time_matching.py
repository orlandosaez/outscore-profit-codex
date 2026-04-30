from __future__ import annotations

import csv
import hashlib
from dataclasses import asdict, dataclass
from datetime import date
from pathlib import Path
from typing import Iterable, Mapping

from profit_import.anchor_matching import AnchorAgreement, OwnerAssignmentMatch, normalize_client_name
from profit_import.timesheets import TimeEntry


@dataclass(frozen=True)
class TimeEntryAnchorMatch:
    time_entry_key: str
    match_status: str
    match_reason: str
    candidate_count: int
    anchor_relationship_id: str | None
    anchor_client_business_name: str | None
    staff_name: str
    entry_date: date
    client_raw: str
    task_raw: str
    hours: float
    hourly_rate: float
    labor_cost: float
    macro_service_type: str
    is_admin: bool
    source_file: str
    source_sheet: str
    source_row: int


def stable_time_entry_key(entry: TimeEntry) -> str:
    payload = "|".join(
        [
            entry.source_file,
            entry.source_sheet,
            str(entry.source_row),
            entry.staff_name,
            entry.entry_date.isoformat(),
            entry.client_raw,
            entry.task_raw,
            f"{entry.hours:.4f}",
        ]
    )
    return "te_" + hashlib.sha1(payload.encode("utf-8")).hexdigest()[:24]


def build_client_aliases_from_owner_matches(matches: Iterable[OwnerAssignmentMatch]) -> dict[str, AnchorAgreement]:
    alias_candidates: dict[str, dict[str, AnchorAgreement]] = {}
    for match in matches:
        if match.match_status != "matched" or not match.anchor_relationship_id or not match.anchor_client_business_name:
            continue
        agreement = AnchorAgreement(
            anchor_relationship_id=match.anchor_relationship_id,
            agreement_name=match.anchor_agreement_name or "",
            client_business_name=match.anchor_client_business_name,
            contact_email="",
            status="active",
            effective_date="",
        )
        for value in (match.client_raw, match.anchor_client_business_name, *match.context_tokens):
            for normalized in _normalized_alias_variants(value):
                alias_candidates.setdefault(normalized, {})[agreement.anchor_relationship_id] = agreement

    return {
        normalized: next(iter(candidates.values()))
        for normalized, candidates in alias_candidates.items()
        if len(candidates) == 1
    }


def match_time_entries_to_anchor(
    entries: Iterable[TimeEntry],
    agreements: Iterable[AnchorAgreement],
    client_aliases: Mapping[str, AnchorAgreement] | None = None,
) -> list[TimeEntryAnchorMatch]:
    agreements_by_name: dict[str, list[AnchorAgreement]] = {}
    for agreement in agreements:
        normalized = normalize_client_name(agreement.client_business_name)
        if normalized:
            agreements_by_name.setdefault(normalized, []).append(agreement)
    agreement_abbreviations = _build_unique_agreement_abbreviations(agreements)

    aliases = client_aliases or {}
    matches: list[TimeEntryAnchorMatch] = []
    for entry in entries:
        if entry.is_admin:
            matches.append(_make_match(entry, "admin", "company_overhead", [], None))
            continue

        normalized = normalize_client_name(entry.client_raw)
        alias = aliases.get(normalized)
        if alias:
            matches.append(_make_match(entry, "matched", "assignment_alias", [alias], alias))
            continue

        candidates = agreements_by_name.get(normalized, [])
        if len(candidates) == 1:
            matches.append(_make_match(entry, "matched", "normalized_client_name", candidates, candidates[0]))
            continue

        abbreviation = agreement_abbreviations.get(normalized)
        if abbreviation:
            matches.append(_make_match(entry, "matched", "agreement_abbreviation", [abbreviation], abbreviation))
        elif len(candidates) > 1:
            matches.append(_make_match(entry, "ambiguous", "multiple_normalized_client_name", candidates, None))
        else:
            matches.append(_make_match(entry, "unmatched", "no_normalized_client_name", [], None))

    return matches


def write_time_entry_matches_csv(matches: Iterable[TimeEntryAnchorMatch], output_path: Path | str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "time_entry_key",
        "match_status",
        "match_reason",
        "candidate_count",
        "anchor_relationship_id",
        "anchor_client_business_name",
        "staff_name",
        "entry_date",
        "client_raw",
        "task_raw",
        "hours",
        "hourly_rate",
        "labor_cost",
        "macro_service_type",
        "is_admin",
        "source_file",
        "source_sheet",
        "source_row",
    ]
    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for match in matches:
            writer.writerow(asdict(match))


def summarize_time_entry_matches(matches: Iterable[TimeEntryAnchorMatch]) -> dict[str, object]:
    rows = list(matches)
    by_status: dict[str, int] = {}
    by_macro: dict[str, int] = {}
    for row in rows:
        by_status[row.match_status] = by_status.get(row.match_status, 0) + 1
        by_macro[row.macro_service_type] = by_macro.get(row.macro_service_type, 0) + 1

    return {
        "time_entry_count": len(rows),
        "matched_time_entry_count": by_status.get("matched", 0),
        "admin_time_entry_count": by_status.get("admin", 0),
        "unmatched_time_entry_count": by_status.get("unmatched", 0),
        "ambiguous_time_entry_count": by_status.get("ambiguous", 0),
        "by_status": dict(sorted(by_status.items())),
        "by_macro_service_type": dict(sorted(by_macro.items())),
        "matched_labor_cost": round(sum(row.labor_cost for row in rows if row.match_status == "matched"), 2),
        "admin_labor_cost": round(sum(row.labor_cost for row in rows if row.match_status == "admin"), 2),
        "unmatched_labor_cost": round(sum(row.labor_cost for row in rows if row.match_status == "unmatched"), 2),
    }


def build_time_entry_load_rows(matches: Iterable[TimeEntryAnchorMatch]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for match in matches:
        rows.append(
            {
                "time_entry_key": match.time_entry_key,
                "staff_name": match.staff_name,
                "entry_date": match.entry_date.isoformat(),
                "client_raw": match.client_raw,
                "task_raw": match.task_raw,
                "hours": match.hours,
                "hourly_rate": match.hourly_rate,
                "labor_cost": match.labor_cost,
                "macro_service_type": match.macro_service_type,
                "is_admin": match.is_admin,
                "match_status": match.match_status,
                "match_reason": match.match_reason,
                "candidate_count": match.candidate_count,
                "anchor_relationship_id": match.anchor_relationship_id,
                "anchor_client_business_name": match.anchor_client_business_name,
                "source_file": match.source_file,
                "source_sheet": match.source_sheet,
                "source_row": match.source_row,
            }
        )
    return rows


def _make_match(
    entry: TimeEntry,
    status: str,
    reason: str,
    candidates: list[AnchorAgreement],
    agreement: AnchorAgreement | None,
) -> TimeEntryAnchorMatch:
    return TimeEntryAnchorMatch(
        time_entry_key=stable_time_entry_key(entry),
        match_status=status,
        match_reason=reason,
        candidate_count=len(candidates),
        anchor_relationship_id=agreement.anchor_relationship_id if agreement else None,
        anchor_client_business_name=agreement.client_business_name if agreement else None,
        staff_name=entry.staff_name,
        entry_date=entry.entry_date,
        client_raw=entry.client_raw,
        task_raw=entry.task_raw,
        hours=entry.hours,
        hourly_rate=entry.hourly_rate,
        labor_cost=entry.labor_cost,
        macro_service_type=entry.service_type,
        is_admin=entry.is_admin,
        source_file=entry.source_file,
        source_sheet=entry.source_sheet,
        source_row=entry.source_row,
    )


def _build_unique_agreement_abbreviations(agreements: Iterable[AnchorAgreement]) -> dict[str, AnchorAgreement]:
    candidates: dict[str, dict[str, AnchorAgreement]] = {}
    for agreement in agreements:
        for alias in _agreement_abbreviation_aliases(agreement.client_business_name):
            normalized = normalize_client_name(alias)
            if normalized:
                candidates.setdefault(normalized, {})[agreement.anchor_relationship_id] = agreement

    return {
        normalized: next(iter(agreements_by_id.values()))
        for normalized, agreements_by_id in candidates.items()
        if len(agreements_by_id) == 1
    }


def _agreement_abbreviation_aliases(client_name: str) -> set[str]:
    tokens = [
        token
        for token in normalize_client_name(client_name).split()
        if token not in {"llc", "inc", "corp", "corporation", "company"}
    ]
    raw_tokens = [
        token.lower()
        for token in client_name.replace("&", " ").replace("-", " ").split()
        if token.strip()
    ]
    cleaned = [normalize_client_name(token) for token in raw_tokens]
    cleaned = [token for token in cleaned if token and token not in {"llc", "inc", "corp", "corporation", "company", "enterprises"}]

    aliases: set[str] = set()
    if len(cleaned) >= 2:
        aliases.add(" ".join(token[0] for token in cleaned if token))
        aliases.add(" ".join(cleaned))
    if len(cleaned) >= 3:
        aliases.add(cleaned[0] + " " + cleaned[-1])
        aliases.add(cleaned[0] + cleaned[-1])
    if tokens:
        aliases.add(" ".join(tokens))
    return aliases


def _normalized_alias_variants(value: str) -> set[str]:
    normalized = normalize_client_name(value)
    variants = {normalized} if normalized else set()
    if normalized.endswith("s"):
        variants.add(normalized[:-1])
    return variants
