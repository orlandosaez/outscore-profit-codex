from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping


CATEGORY_TO_MACRO = {
    "accounting": "bookkeeping",
    "tax work": "tax",
    "payroll": "payroll",
    "advisory": "advisory",
}

INCOME_ACCOUNT_TO_MACRO = {
    "accounting services": "bookkeeping",
    "tax services - business": "tax",
    "tax services - individual": "tax",
    "payroll service": "payroll",
    "strategic advisory": "advisory",
    "setup and onboarding": "advisory",
}

NON_SERVICE_INCOME_ACCOUNTS = {
    "billable expense",
    "quickbooks payments fees",
    "other service income",
    "uncategorized income",
}


@dataclass(frozen=True)
class QboProductMapping:
    product_name: str
    normalized_product_name: str
    category: str
    sku: str
    income_account: str
    macro_service_type: str
    include_in_revenue_allocation: bool


@dataclass(frozen=True)
class ClassifiedInvoiceLineItem:
    anchor_line_item_id: str
    anchor_invoice_id: str
    anchor_relationship_id: str | None
    parent_line_item_id: str | None
    qbo_product_name: str
    source_name: str
    amount: float | None
    revenue_amount: float
    macro_service_type: str
    include_in_revenue_allocation: bool
    classification_reason: str


def parse_qbo_products_csv(path: Path | str) -> dict[str, QboProductMapping]:
    file_path = Path(path)
    products: dict[str, QboProductMapping] = {}
    with file_path.open(newline="", encoding="utf-8-sig") as file:
        reader = csv.DictReader(file)
        for row in reader:
            product_name = (row.get("Product/Service Name") or "").strip()
            if not product_name:
                continue

            category = (row.get("Category") or "").strip()
            income_account = (row.get("Income Account") or "").strip()
            normalized = normalize_qbo_product_name(product_name)
            macro = _map_macro_service_type(category, income_account)
            include = macro in {"bookkeeping", "tax", "payroll", "advisory"} and not _is_non_service_row(
                product_name,
                category,
                income_account,
            )
            products[normalized] = QboProductMapping(
                product_name=product_name,
                normalized_product_name=normalized,
                category=category,
                sku=(row.get("SKU") or "").strip(),
                income_account=income_account,
                macro_service_type=macro,
                include_in_revenue_allocation=include,
            )
    return products


def normalize_qbo_product_name(value: str | None) -> str:
    text = (value or "").strip().lower()
    if ":" in text:
        text = text.split(":")[-1]
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def classify_invoice_line_items(
    rows: Iterable[Mapping[str, object]],
    products: Mapping[str, QboProductMapping],
) -> list[ClassifiedInvoiceLineItem]:
    source_rows = list(rows)
    parent_ids_with_children = {
        str(row.get("parent_line_item_id"))
        for row in source_rows
        if row.get("parent_line_item_id") not in (None, "")
    }

    classified: list[ClassifiedInvoiceLineItem] = []
    for row in source_rows:
        line_item_id = str(row.get("anchor_line_item_id") or "")
        qbo_product_name = str(row.get("qbo_product_name") or "")
        source_name = str(row.get("name") or "")
        amount = _parse_money(row.get("amount"))

        if _is_true(row.get("is_bundle_parent")) and line_item_id in parent_ids_with_children:
            classified.append(
                _make_classified_row(
                    row,
                    amount,
                    "bundle_parent",
                    False,
                    "bundle_parent_has_children",
                )
            )
            continue

        mapping = products.get(normalize_qbo_product_name(qbo_product_name)) or products.get(normalize_qbo_product_name(source_name))
        if mapping is None:
            macro_from_prefix = _macro_from_qbo_product_prefix(qbo_product_name)
            if macro_from_prefix:
                classified.append(
                    _make_classified_row(
                        row,
                        amount,
                        macro_from_prefix,
                        True,
                        "qbo_category_prefix",
                    )
                )
                continue

            classified.append(
                _make_classified_row(
                    row,
                    amount,
                    "unknown",
                    False,
                    "unclassified_qbo_product",
                )
            )
            continue

        classified.append(
            _make_classified_row(
                row,
                amount,
                mapping.macro_service_type,
                mapping.include_in_revenue_allocation,
                "qbo_product_mapping",
            )
        )

    return classified


def parse_invoice_line_items_csv(path: Path | str) -> list[dict[str, object]]:
    file_path = Path(path)
    with file_path.open(newline="", encoding="utf-8-sig") as file:
        return list(csv.DictReader(file))


def summarize_classifications(rows: Iterable[ClassifiedInvoiceLineItem]) -> dict[str, object]:
    source_rows = list(rows)
    by_macro: dict[str, int] = {}
    unclassified = 0
    included_revenue_amount = 0.0
    for row in source_rows:
        by_macro[row.macro_service_type] = by_macro.get(row.macro_service_type, 0) + 1
        if row.classification_reason == "unclassified_qbo_product":
            unclassified += 1
        included_revenue_amount += row.revenue_amount

    return {
        "classified_line_items": len(source_rows),
        "unclassified_line_items": unclassified,
        "included_revenue_amount": round(included_revenue_amount, 2),
        "line_items_by_macro_service_type": dict(sorted(by_macro.items())),
    }


def write_classification_review_csv(rows: Iterable[ClassifiedInvoiceLineItem], output_path: Path | str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "anchor_line_item_id",
        "anchor_invoice_id",
        "anchor_relationship_id",
        "parent_line_item_id",
        "qbo_product_name",
        "source_name",
        "amount",
        "revenue_amount",
        "macro_service_type",
        "include_in_revenue_allocation",
        "classification_reason",
    ]
    with path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(_classification_as_dict(row))


def write_classification_load_sql(rows: Iterable[ClassifiedInvoiceLineItem], output_path: Path | str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    values = ",\n".join(_classification_sql_tuple(row) for row in rows)
    if not values:
        values = "(''::text, ''::text, null::text, null::text, ''::text, ''::text, null::numeric, 0::numeric, 'unknown'::text, false, 'empty_load'::text)"

    sql = f"""begin;

create table if not exists profit_anchor_line_item_classifications (
  anchor_line_item_id text primary key,
  anchor_invoice_id text not null,
  anchor_relationship_id text,
  parent_line_item_id text,
  qbo_product_name text,
  source_name text,
  amount numeric,
  revenue_amount numeric not null default 0,
  macro_service_type text not null,
  include_in_revenue_allocation boolean not null default false,
  classification_reason text not null,
  classified_at timestamptz not null default now()
);

create temp table _profit_anchor_line_item_classifications_load (
  anchor_line_item_id text not null,
  anchor_invoice_id text not null,
  anchor_relationship_id text,
  parent_line_item_id text,
  qbo_product_name text,
  source_name text,
  amount numeric,
  revenue_amount numeric not null,
  macro_service_type text not null,
  include_in_revenue_allocation boolean not null,
  classification_reason text not null
) on commit drop;

insert into _profit_anchor_line_item_classifications_load (
  anchor_line_item_id,
  anchor_invoice_id,
  anchor_relationship_id,
  parent_line_item_id,
  qbo_product_name,
  source_name,
  amount,
  revenue_amount,
  macro_service_type,
  include_in_revenue_allocation,
  classification_reason
)
values
{values};

delete from _profit_anchor_line_item_classifications_load
where anchor_line_item_id = '' and classification_reason = 'empty_load';

insert into profit_anchor_line_item_classifications (
  anchor_line_item_id,
  anchor_invoice_id,
  anchor_relationship_id,
  parent_line_item_id,
  qbo_product_name,
  source_name,
  amount,
  revenue_amount,
  macro_service_type,
  include_in_revenue_allocation,
  classification_reason,
  classified_at
)
select
  anchor_line_item_id,
  anchor_invoice_id,
  anchor_relationship_id,
  parent_line_item_id,
  qbo_product_name,
  source_name,
  amount,
  revenue_amount,
  macro_service_type,
  include_in_revenue_allocation,
  classification_reason,
  now()
from _profit_anchor_line_item_classifications_load
on conflict (anchor_line_item_id)
do update set
  anchor_invoice_id = excluded.anchor_invoice_id,
  anchor_relationship_id = excluded.anchor_relationship_id,
  parent_line_item_id = excluded.parent_line_item_id,
  qbo_product_name = excluded.qbo_product_name,
  source_name = excluded.source_name,
  amount = excluded.amount,
  revenue_amount = excluded.revenue_amount,
  macro_service_type = excluded.macro_service_type,
  include_in_revenue_allocation = excluded.include_in_revenue_allocation,
  classification_reason = excluded.classification_reason,
  classified_at = excluded.classified_at;

commit;
"""
    path.write_text(sql, encoding="utf-8")


def _map_macro_service_type(category: str, income_account: str) -> str:
    category_key = category.strip().lower()
    income_key = income_account.strip().lower()
    return CATEGORY_TO_MACRO.get(category_key) or INCOME_ACCOUNT_TO_MACRO.get(income_key) or "other"


def _macro_from_qbo_product_prefix(value: str | None) -> str | None:
    text = (value or "").strip().lower()
    if ":" not in text:
        return None
    prefix = text.split(":", 1)[0].strip()
    return CATEGORY_TO_MACRO.get(prefix)


def _is_non_service_row(product_name: str, category: str, income_account: str) -> bool:
    name_key = product_name.strip().lower()
    category_key = category.strip().lower()
    income_key = income_account.strip().lower()
    return (
        income_key in NON_SERVICE_INCOME_ACCOUNTS
        or "expense" in name_key
        or "fee" in name_key
        or category_key == "other"
    )


def _make_classified_row(
    row: Mapping[str, object],
    amount: float | None,
    macro_service_type: str,
    include_in_revenue_allocation: bool,
    classification_reason: str,
) -> ClassifiedInvoiceLineItem:
    return ClassifiedInvoiceLineItem(
        anchor_line_item_id=str(row.get("anchor_line_item_id") or ""),
        anchor_invoice_id=str(row.get("anchor_invoice_id") or ""),
        anchor_relationship_id=_optional_string(row.get("anchor_relationship_id")),
        parent_line_item_id=_optional_string(row.get("parent_line_item_id")),
        qbo_product_name=str(row.get("qbo_product_name") or ""),
        source_name=str(row.get("name") or ""),
        amount=amount,
        revenue_amount=amount if include_in_revenue_allocation and amount is not None else 0.0,
        macro_service_type=macro_service_type,
        include_in_revenue_allocation=include_in_revenue_allocation,
        classification_reason=classification_reason,
    )


def _optional_string(value: object) -> str | None:
    if value in (None, ""):
        return None
    return str(value)


def _parse_money(value: object) -> float | None:
    if value in (None, ""):
        return None
    if isinstance(value, int | float):
        return float(value)
    cleaned = str(value).replace("$", "").replace(",", "").strip()
    if not cleaned:
        return None
    return float(cleaned)


def _is_true(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"true", "t", "1", "yes", "y"}
    return bool(value)


def _classification_as_dict(row: ClassifiedInvoiceLineItem) -> dict[str, object]:
    return {
        "anchor_line_item_id": row.anchor_line_item_id,
        "anchor_invoice_id": row.anchor_invoice_id,
        "anchor_relationship_id": row.anchor_relationship_id,
        "parent_line_item_id": row.parent_line_item_id,
        "qbo_product_name": row.qbo_product_name,
        "source_name": row.source_name,
        "amount": row.amount,
        "revenue_amount": row.revenue_amount,
        "macro_service_type": row.macro_service_type,
        "include_in_revenue_allocation": row.include_in_revenue_allocation,
        "classification_reason": row.classification_reason,
    }


def _classification_sql_tuple(row: ClassifiedInvoiceLineItem) -> str:
    return (
        f"({_sql_text(row.anchor_line_item_id)}, {_sql_text(row.anchor_invoice_id)}, "
        f"{_sql_text(row.anchor_relationship_id)}, {_sql_text(row.parent_line_item_id)}, "
        f"{_sql_text(row.qbo_product_name)}, {_sql_text(row.source_name)}, {_sql_numeric(row.amount)}, "
        f"{_sql_numeric(row.revenue_amount)}, {_sql_text(row.macro_service_type)}, "
        f"{_sql_bool(row.include_in_revenue_allocation)}, {_sql_text(row.classification_reason)})"
    )


def _sql_text(value: str | None) -> str:
    if value is None:
        return "null"
    return "'" + value.replace("'", "''") + "'"


def _sql_numeric(value: float | None) -> str:
    if value is None:
        return "null"
    return f"{value:.2f}"


def _sql_bool(value: bool) -> str:
    return "true" if value else "false"
