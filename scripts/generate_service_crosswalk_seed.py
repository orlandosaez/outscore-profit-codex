from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANCHOR_CSV = ROOT / "docs/data-references/anchor services.csv"
QBO_CSV = ROOT / "docs/data-references/qbo-product-services.csv"
OUTPUT_SQL = ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql"


@dataclass(frozen=True)
class AnchorService:
    service_name: str
    fc_tag: str | None


@dataclass(frozen=True)
class QboProduct:
    product_name: str
    category_path: str | None


@dataclass(frozen=True)
class ServiceRule:
    macro_service_type: str
    service_tier: str | None
    recognition_pattern: str
    service_period_rule: str
    default_sla_day: int | None
    form_type_pattern: str | None
    notes: str | None


@dataclass(frozen=True)
class CrosswalkRow:
    service_name: str
    macro_service_type: str
    service_tier: str | None
    recognition_pattern: str
    service_period_rule: str
    default_sla_day: int | None
    form_type_pattern: str | None
    notes: str | None
    fc_tag: str | None
    qbo_category_path: str | None
    qbo_product_name: str | None


SERVICE_RULE_DEFAULTS: dict[str, ServiceRule] = {
    "Accounting Advanced": ServiceRule("bookkeeping", "Advanced", "monthly_recurring", "previous_month", 10, None, "Per-engagement SLA override allowed via profit_anchor_agreements.sla_day_override."),
    "Accounting Plus": ServiceRule("bookkeeping", "Plus", "monthly_recurring", "previous_month", 10, None, "Recognize from FC bookkeeping completion for prior month."),
    "Accounting Essential": ServiceRule("bookkeeping", "Essential", "monthly_recurring", "previous_month", 20, None, "Recognize from FC bookkeeping completion for prior month."),
    "Sales Tax Compliance": ServiceRule("sales_tax", None, "monthly_recurring", "previous_month", 20, None, "Sales tax compliance is not annual income tax; keep out of tax_filed matching."),
    "Payroll Service": ServiceRule("payroll", None, "monthly_recurring", "previous_month", None, None, "SLA follows payroll cadence; recognize by payroll processed trigger."),
    "Tangible Property Tax": ServiceRule("tax", None, "manual_review", "manual", None, None, "Monthly billing exists but annual tangible-property cadence requires review."),
    "Audit Protection Business": ServiceRule("other", "Business", "manual_review", "manual", None, None, "Insurance-style accrual; enum does not yet include insurance_accrual. Review before automated recognition."),
    "Audit Protection Individual": ServiceRule("other", "Individual", "manual_review", "manual", None, None, "Insurance-style accrual; enum does not yet include insurance_accrual. Review before automated recognition."),
    "Fractional CFO": ServiceRule("advisory", None, "monthly_recurring", "previous_month", None, None, "Recognize on advisory delivery/monthly meeting cadence."),
    "1099 Preparation": ServiceRule("tax", None, "manual_review", "manual", None, None, "Monthly $0 edge case; require explicit review before automation."),
    "Payroll Tax Compliance": ServiceRule("payroll", None, "quarterly_recurring", "previous_quarter", None, None, "Quarterly federal/state deadline-driven SLA."),
    "1040 Essentials": ServiceRule("tax", "Essentials", "tax_filing", "tax_year_default", None, "1040", "Tier is complexity, not timing."),
    "1040 Plus": ServiceRule("tax", "Plus", "tax_filing", "tax_year_default", None, "1040", "Tier is complexity, not timing."),
    "1040 Advanced": ServiceRule("tax", "Advanced", "tax_filing", "tax_year_default", None, "1040", "Tier is complexity, not timing."),
    "1065 Essential": ServiceRule("tax", "Essential", "tax_filing", "tax_year_default", None, "1065", "Tier is complexity, not timing."),
    "1065 Plus": ServiceRule("tax", "Plus", "tax_filing", "tax_year_default", None, "1065", "Tier is complexity, not timing."),
    "1065 Advanced": ServiceRule("tax", "Advanced", "tax_filing", "tax_year_default", None, "1065", "Tier is complexity, not timing."),
    "1120 Essential": ServiceRule("tax", "Essential", "tax_filing", "tax_year_default", None, "1120", "Matches 1120 and 1120S corporate returns."),
    "1120 Plus": ServiceRule("tax", "Plus", "tax_filing", "tax_year_default", None, "1120", "Matches 1120 and 1120S corporate returns."),
    "1120 Advanced": ServiceRule("tax", "Advanced", "tax_filing", "tax_year_default", None, "1120", "Matches 1120 and 1120S corporate returns."),
    "990-EZ Short Form": ServiceRule("tax", "Short Form", "tax_filing", "tax_year_default", None, "990-EZ", "Nonprofit short form."),
    "990 Full Return Essential": ServiceRule("tax", "Essential", "tax_filing", "tax_year_default", None, "990", "Nonprofit full return."),
    "990 Full Return Plus": ServiceRule("tax", "Plus", "tax_filing", "tax_year_default", None, "990", "Nonprofit full return."),
    "990-T Unrelated Business": ServiceRule("tax", None, "tax_filing", "tax_year_default", None, "990-T", "Unrelated business income return."),
    "Annual Estimate Tax Review": ServiceRule("tax", None, "one_time", "invoice_date", None, "estimate review", "Recognize when estimate review is delivered/completed."),
    "Advisory": ServiceRule("advisory", None, "one_time", "invoice_date", None, None, "Hourly project/ad-hoc advisory."),
    "Setup and Onboarding": ServiceRule("advisory", None, "one_time", "invoice_date", None, None, "Recognize at onboarding delivery/completion."),
    "Audit Support Service": ServiceRule("advisory", None, "one_time", "invoice_date", None, None, "Audit support is work performed, not audit protection."),
    "Specialized Services": ServiceRule("advisory", None, "manual_review", "manual", None, None, "Default $0/varies; review before automated recognition."),
    "Year End Accounting Close": ServiceRule("bookkeeping", None, "manual_review", "manual", None, None, "Default $0/varies; review before automated recognition."),
    "Work Comp Tax": ServiceRule("payroll", None, "manual_review", "manual", None, None, "Workers comp/payroll-adjacent compliance; review before automation."),
    "Billable Expenses": ServiceRule("pass_through", None, "pass_through", "manual", None, None, "Exclude from service revenue recognition."),
    "Other Income": ServiceRule("pass_through", None, "pass_through", "manual", None, None, "Exclude from service recognition unless separately reviewed."),
    "Remote Desktop Access": ServiceRule("pass_through", None, "pass_through", "manual", None, None, "Client reimbursement/access cost recovery."),
    "Remote QBD Access": ServiceRule("pass_through", None, "pass_through", "manual", None, None, "Client reimbursement/access cost recovery."),
    "Services": ServiceRule("pass_through", None, "pass_through", "manual", None, None, "Generic product excluded by default; explicit classification required."),
}


def load_anchor_services(path: Path = ANCHOR_CSV) -> dict[str, AnchorService]:
    with path.open(encoding="utf-8-sig", newline="") as file:
        rows: dict[str, AnchorService] = {}
        for row in csv.DictReader(file):
            if row.get("Type") != "Service":
                continue
            service_name = (row.get("Name") or "").strip()
            if not service_name:
                continue
            tag = (row.get("Tag") or "").strip() or None
            rows[service_name] = AnchorService(service_name=service_name, fc_tag=tag)
    return rows


def load_qbo_products(path: Path = QBO_CSV) -> dict[str, QboProduct]:
    with path.open(encoding="utf-8-sig", newline="") as file:
        rows: dict[str, QboProduct] = {}
        for row in csv.DictReader(file):
            product_name = (row.get("Product/Service Name") or "").strip()
            if not product_name:
                continue
            category = (row.get("Category") or "").strip() or None
            rows[product_name] = QboProduct(
                product_name=product_name,
                category_path=category,
            )
    return rows


def build_crosswalk_rows(
    anchor_services: dict[str, AnchorService],
    qbo_products: dict[str, QboProduct],
) -> dict[str, CrosswalkRow]:
    rows: dict[str, CrosswalkRow] = {}
    for service_name, anchor_service in sorted(anchor_services.items()):
        rule = SERVICE_RULE_DEFAULTS.get(service_name)
        if rule is None:
            raise ValueError(f"No service recognition rule default for {service_name!r}")
        qbo_product = qbo_products.get(service_name)
        rows[service_name] = CrosswalkRow(
            service_name=service_name,
            macro_service_type=rule.macro_service_type,
            service_tier=rule.service_tier,
            recognition_pattern=rule.recognition_pattern,
            service_period_rule=rule.service_period_rule,
            default_sla_day=rule.default_sla_day,
            form_type_pattern=rule.form_type_pattern,
            notes=rule.notes,
            fc_tag=anchor_service.fc_tag,
            qbo_category_path=qbo_product.category_path if qbo_product else None,
            qbo_product_name=qbo_product.product_name if qbo_product else None,
        )
    return rows


def sql_literal(value: str | None) -> str:
    if value is None:
        return "null"
    return "'" + value.replace("'", "''") + "'"


def sql_integer(value: int | None) -> str:
    if value is None:
        return "null"
    return str(value)


def render_sql(rows: dict[str, CrosswalkRow]) -> str:
    values = ",\n".join(
        "  ("
        + ", ".join(
            [
                sql_literal(row.service_name),
                sql_literal(row.macro_service_type),
                sql_literal(row.service_tier),
                sql_literal(row.recognition_pattern),
                sql_literal(row.service_period_rule),
                sql_integer(row.default_sla_day),
                sql_literal(row.form_type_pattern),
                sql_literal(row.notes),
                sql_literal(row.fc_tag),
                sql_literal(row.qbo_category_path),
                sql_literal(row.qbo_product_name),
                "'manual_seed'",
                "now()",
            ]
        )
        + ")"
        for row in rows.values()
    )

    return f"""-- Generated by scripts/generate_service_crosswalk_seed.py.
-- Source files:
--   docs/data-references/anchor services.csv
--   docs/data-references/qbo-product-services.csv

alter table profit_service_recognition_rules
  add column if not exists fc_tag text,
  add column if not exists qbo_category_path text,
  add column if not exists qbo_product_name text;

create index if not exists idx_profit_service_recognition_rules_fc_tag
  on profit_service_recognition_rules (fc_tag)
  where fc_tag is not null;

create index if not exists idx_profit_service_recognition_rules_qbo_product
  on profit_service_recognition_rules (qbo_product_name)
  where qbo_product_name is not null;

insert into profit_service_recognition_rules (
  service_name,
  macro_service_type,
  service_tier,
  recognition_pattern,
  service_period_rule,
  default_sla_day,
  form_type_pattern,
  notes,
  fc_tag,
  qbo_category_path,
  qbo_product_name,
  source,
  last_synced_at
) values
{values}
on conflict (service_name) do update set
  macro_service_type = excluded.macro_service_type,
  service_tier = excluded.service_tier,
  recognition_pattern = excluded.recognition_pattern,
  service_period_rule = excluded.service_period_rule,
  default_sla_day = excluded.default_sla_day,
  form_type_pattern = excluded.form_type_pattern,
  notes = excluded.notes,
  fc_tag = excluded.fc_tag,
  qbo_category_path = excluded.qbo_category_path,
  qbo_product_name = excluded.qbo_product_name,
  source = excluded.source,
  last_synced_at = now(),
  updated_at = now();

create or replace view profit_anchor_services_without_tag as
select
  rule.service_name,
  rule.macro_service_type,
  rule.recognition_pattern,
  rule.service_period_rule,
  rule.qbo_category_path,
  rule.qbo_product_name,
  rule.last_synced_at
from profit_service_recognition_rules rule
where rule.fc_tag is null
  and rule.macro_service_type <> 'pass_through'
order by rule.service_name;
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--anchor-csv", type=Path, default=ANCHOR_CSV)
    parser.add_argument("--qbo-csv", type=Path, default=QBO_CSV)
    parser.add_argument("--output", type=Path, default=OUTPUT_SQL)
    args = parser.parse_args()

    rows = build_crosswalk_rows(
        load_anchor_services(args.anchor_csv),
        load_qbo_products(args.qbo_csv),
    )
    args.output.write_text(render_sql(rows), encoding="utf-8")


if __name__ == "__main__":
    main()
