# Profit Dashboard V0.5.2.1 Service Crosswalk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the service recognition config with FC tag and QBO product crosswalk columns, and document `docs/data-references/` as the canonical home for reference artifacts.

**Architecture:** V0.5.2.1 layers crosswalk metadata onto `profit_service_recognition_rules` without changing recognition behavior. Migration `018` adds nullable `fc_tag`, `qbo_category_path`, and `qbo_product_name`, then idempotently updates existing service rows from the already-present reference CSVs. A lightweight warning view surfaces services that flowed into our system without an FC tag so V0.5.3 run logs can flag them.

**Tech Stack:** Supabase Postgres migrations/views, static CSV reference files, Markdown docs, Python `pytest`/`unittest`, existing VPS deploy flow with `psql`.

---

## Scope

In scope:
- Create `docs/data-references/README.md`.
- Add crosswalk columns to `profit_service_recognition_rules`.
- Seed `fc_tag` from `docs/data-references/anchor services.csv` using `Name` -> `Tag`.
- Seed QBO metadata from `docs/data-references/qbo-product-services.csv` using exact `Product/Service Name` match.
- Create `profit_anchor_services_without_tag`.
- Update docs to make FC tags and QBO crosswalk fields explicit.

Out of scope:
- Renaming, moving, or cleaning up reference files.
- Using `fc_tag` for recognition matching.
- FC API tag sync.
- Live Anchor service API sync.
- Live QBO product API sync.
- UI surfaces showing FC tag.

## Reference Data State

Files already exist and must not be moved or renamed in this slice:

```text
docs/data-references/
  anchor services.csv
  client-staff-assignments.xlsx
  qbo-product-services.csv
  sbc-profit-and-loss.csv
```

Observed headers:
- `anchor services.csv`: `Type,Name,Tag,Description,Billing Occurrence,...`
- `qbo-product-services.csv`: `Product/Service Name,Variant Name,...,Category,...`

Verified FC tag values from `docs/data-references/anchor services.csv`:

```text
1040 Advanced                         S 1040A
1040 Essentials                       S 1040E
1040 Plus                             S 1040P
1065 Advanced                         S 1065A
1065 Essential                        S 1065E
1065 Plus                             S 1065P
1099 Preparation                      S 1099
1120 Advanced                         S 1120A
1120 Essential                        S 1120E
1120 Plus                             S 1120P
990-EZ Short Form                     S 990EZ
990 Full Return Essential             S 990E
990 Full Return Plus                  S 990P
990-T Unrelated Business              S 990T
Accounting Advanced                   S BOOKA
Accounting Essential                  S BOOKE
Accounting Plus                       S BOOKP
Advisory                              S ADV
Annual Estimate Tax Review            S ETP
Audit Protection Business             S AUDITB
Audit Protection Individual           S AUDITI
Audit Support Service                 S AUDITS
Billable Expenses                     S BILL
Fractional CFO                        S CFO
Other Income
Payroll Service                       S PAYROLL
Payroll Tax Compliance                S PAYTAX
Remote Desktop Access                 S BILL
Remote QBD Access                     S BILL
Sales Tax Compliance                  S SALESTAX
Services
Setup and Onboarding                  S SETUP
Specialized Services
Tangible Property Tax                 S TPP
Work Comp Tax                         S WORKERS
Year End Accounting Close             S YECLOSE
```

## Crosswalk Semantics

`fc_tag`:
- Exact Financial Cents tag string from Anchor service catalog `Tag`.
- Nullable.
- Shared tags are allowed. `S BILL` can map to Billable Expenses, Remote Desktop Access, and Remote QBD Access.
- No unique constraint.

`qbo_category_path`:
- Full QBO category hierarchy from QBO export `Category`.
- Nullable when exact product-name match is absent.

`qbo_product_name`:
- Exact QBO `Product/Service Name`.
- Usually equals Anchor service name but remains separate for drift detection.
- Nullable when exact product-name match is absent.

`profit_anchor_services_without_tag`:
- Warning view for services seen in Anchor-derived data but missing `fc_tag` in the config table.
- Does not block recognition.
- Intended for V0.5.3 pipeline run logs.

## Files

- Create `docs/data-references/README.md`: canonical reference artifact documentation.
- Create `scripts/generate_service_crosswalk_seed.py`: reads reference CSVs and writes migration `018`.
- Create `supabase/sql/018_profit_service_recognition_rules_crosswalk.sql`: crosswalk columns, idempotent seed updates, warning view.
- Modify `tests/test_prepaid_liability_sql.py`: migration/static SQL coverage.
- Create `tests/test_service_crosswalk_generation.py`: generator and CSV-driven seed coverage.
- Modify or create `tests/test_data_references_docs.py`: README and reference-file documentation coverage.
- Modify `docs/service-recognition-rules.md`: add FC tag column to taxonomy tables.
- Modify `docs/data-contracts/recognition-triggers.md`: document crosswalk columns, shared umbrella tags, and warning view.

## Task 1: README Coverage For Data References

**Files:**
- Create or modify `tests/test_data_references_docs.py`
- Create later: `docs/data-references/README.md`

- [ ] **Step 1: Write failing README test**

Create `tests/test_data_references_docs.py`:

```python
from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DataReferencesDocsTests(unittest.TestCase):
    def test_data_references_readme_documents_canonical_artifacts(self) -> None:
        readme = (ROOT / "docs/data-references/README.md").read_text(encoding="utf-8")

        self.assertIn("canonical home for reference artifacts", readme)
        self.assertIn("anchor services.csv", readme)
        self.assertIn("Anchor service catalog with FC tag mapping", readme)
        self.assertIn("client-staff-assignments.xlsx", readme)
        self.assertIn("Per-client staff ownership matrix", readme)
        self.assertIn("qbo-product-services.csv", readme)
        self.assertIn("QBO product/service hierarchy export", readme)
        self.assertIn("sbc-profit-and-loss.csv", readme)
        self.assertIn("Reference P&L for company-level GP validation", readme)
        self.assertIn("kebab-case filenames", readme)
        self.assertIn("anchor services.csv is the historical exception", readme)
        self.assertIn("V0.6+ will replace Anchor and QBO files with live API syncs", readme)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: fail because `docs/data-references/README.md` does not exist.

## Task 2: Create Data References README

**Files:**
- Create `docs/data-references/README.md`
- Test `tests/test_data_references_docs.py`

- [ ] **Step 1: Create README**

Create `docs/data-references/README.md`:

```markdown
# Data References

Purpose: canonical home for reference artifacts that seed config tables or serve as benchmarks for the profit system.

## `anchor services.csv`

Anchor service catalog with FC tag mapping. This file is the source for the V0.5.2 service recognition rules seed and the V0.5.2.1 `fc_tag` column on `profit_service_recognition_rules`. It should be replaced by Anchor service API sync in V0.6+; after that, this CSV becomes a historical snapshot.

## `client-staff-assignments.xlsx`

Per-client staff ownership matrix. This file maps clients/services to responsible staff owners and is consumed by the V0.6.A SLA dashboard planning path.

## `qbo-product-services.csv`

QBO product/service hierarchy export. This file is the source for the V0.5.2.1 `qbo_category_path` and `qbo_product_name` seed columns on `profit_service_recognition_rules`. It should be replaced by QBO product API sync in V0.6+; after that, this CSV becomes a historical snapshot.

## `sbc-profit-and-loss.csv`

Reference P&L for company-level GP validation. This is a benchmark for V0.6 audit/reconciliation work and is not a recurring seed source.

## Naming Convention

Use kebab-case filenames, no dates, and no spaces for reference artifacts. `anchor services.csv` is the historical exception and may be cleaned up later.

## Forward Direction

V0.6+ will replace Anchor and QBO files with live API syncs. Once those syncs land, update this README so the CSVs are clearly marked as historical snapshots rather than active seed sources.
```

- [ ] **Step 2: Run README test and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: pass.

## Task 3: Generator And Migration Coverage

**Files:**
- Modify `tests/test_prepaid_liability_sql.py`
- Create `tests/test_service_crosswalk_generation.py`
- Create later: `scripts/generate_service_crosswalk_seed.py`
- Create later: `supabase/sql/018_profit_service_recognition_rules_crosswalk.sql`

- [ ] **Step 1: Write failing generator tests**

Create `tests/test_service_crosswalk_generation.py`:

```python
from __future__ import annotations

import csv
import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts/generate_service_crosswalk_seed.py"
ANCHOR_CSV = ROOT / "docs/data-references/anchor services.csv"
QBO_CSV = ROOT / "docs/data-references/qbo-product-services.csv"
MIGRATION = ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql"


def load_generator_module():
    spec = importlib.util.spec_from_file_location("generate_service_crosswalk_seed", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def anchor_service_tags() -> dict[str, str | None]:
    with ANCHOR_CSV.open(encoding="utf-8-sig", newline="") as file:
        rows = {
            row["Name"]: (row["Tag"].strip() or None)
            for row in csv.DictReader(file)
            if row["Type"] == "Service"
        }
    return rows


class ServiceCrosswalkGenerationTests(unittest.TestCase):
    def test_generator_reads_actual_anchor_fc_tags(self) -> None:
        generator = load_generator_module()
        rows = generator.load_anchor_services(ANCHOR_CSV)

        self.assertEqual(rows["Accounting Advanced"].fc_tag, "S BOOKA")
        self.assertEqual(rows["Accounting Essential"].fc_tag, "S BOOKE")
        self.assertEqual(rows["Accounting Plus"].fc_tag, "S BOOKP")
        self.assertEqual(rows["Sales Tax Compliance"].fc_tag, "S SALESTAX")
        self.assertEqual(rows["Payroll Service"].fc_tag, "S PAYROLL")
        self.assertIsNone(rows["Other Income"].fc_tag)
        self.assertIsNone(rows["Services"].fc_tag)
        self.assertIsNone(rows["Specialized Services"].fc_tag)

    def test_generator_joins_exact_qbo_product_matches(self) -> None:
        generator = load_generator_module()
        anchor_rows = generator.load_anchor_services(ANCHOR_CSV)
        qbo_rows = generator.load_qbo_products(QBO_CSV)
        crosswalk = generator.build_crosswalk_rows(anchor_rows, qbo_rows)

        self.assertEqual(crosswalk["Accounting Advanced"].qbo_product_name, "Accounting Advanced")
        self.assertEqual(crosswalk["Accounting Advanced"].qbo_category_path, "Accounting")
        self.assertEqual(crosswalk["1040 Advanced"].qbo_product_name, "1040 Advanced")
        self.assertEqual(crosswalk["1040 Advanced"].qbo_category_path, "Tax Work")

    def test_generated_migration_contains_all_anchor_services_and_matching_tags(self) -> None:
        sql = MIGRATION.read_text(encoding="utf-8")
        tags = anchor_service_tags()

        seed_service_names = set(re.findall(r"^\s+\('([^']+)'", sql, flags=re.MULTILINE))
        self.assertEqual(seed_service_names, set(tags))

        for service_name in [
            "Accounting Advanced",
            "Accounting Essential",
            "Accounting Plus",
            "1040 Advanced",
            "Audit Protection Business",
            "Sales Tax Compliance",
            "Payroll Service",
            "Year End Accounting Close",
        ]:
            expected_tag = tags[service_name]
            self.assertIn(f"'{service_name}',", sql)
            self.assertIn(f"'{service_name}',", sql)
            self.assertIn(f"'{expected_tag}'", sql)

        for service_name in ["Other Income", "Services", "Specialized Services"]:
            self.assertRegex(sql, rf"\('{re.escape(service_name)}', [^\n]+, null, ")

    def test_generated_migration_has_no_hallucinated_old_accounting_tags(self) -> None:
        sql = MIGRATION.read_text(encoding="utf-8")

        self.assertNotIn("S ACCA", sql)
        self.assertNotIn("S ACCE", sql)
        self.assertNotIn("S ACCP", sql)
        self.assertIn("S BOOKA", sql)
        self.assertIn("S BOOKE", sql)
        self.assertIn("S BOOKP", sql)
```

- [ ] **Step 2: Write failing migration tests**

Add to `tests/test_prepaid_liability_sql.py`:

```python
def test_service_recognition_crosswalk_migration_adds_columns_and_seed_updates(self) -> None:
    sql = (ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql").read_text(
        encoding="utf-8"
    )

    self.assertIn("alter table profit_service_recognition_rules", sql.lower())
    self.assertIn("add column if not exists fc_tag text", sql.lower())
    self.assertIn("add column if not exists qbo_category_path text", sql.lower())
    self.assertIn("add column if not exists qbo_product_name text", sql.lower())
    self.assertIn("on conflict (service_name) do update set", sql.lower())
    self.assertIn("fc_tag = excluded.fc_tag", sql)
    self.assertIn("qbo_category_path = excluded.qbo_category_path", sql)
    self.assertIn("qbo_product_name = excluded.qbo_product_name", sql)


def test_service_recognition_crosswalk_seed_covers_fc_tags_and_qbo_matches(self) -> None:
    sql = (ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql").read_text(
        encoding="utf-8"
    )

    self.assertIn("'Accounting Advanced',", sql)
    self.assertIn("'S BOOKA'", sql)
    self.assertIn("'1040 Advanced', 'S 1040A'", sql)
    self.assertIn("'Billable Expenses', 'S BILL'", sql)
    self.assertIn("'Remote Desktop Access', 'S BILL'", sql)
    self.assertIn("'Remote QBD Access', 'S BILL'", sql)
    self.assertIn("'Other Income', null", sql)
    self.assertIn("'Services', null", sql)
    self.assertIn("'Specialized Services', null", sql)
    self.assertIn("'1040 Advanced', 'S 1040A', 'Tax Work', '1040 Advanced'", sql)
    self.assertIn("'Accounting Plus', 'S BOOKP', 'Accounting', 'Accounting Plus'", sql)
    self.assertNotIn("S ACCA", sql)
    self.assertNotIn("S ACCP", sql)


def test_service_recognition_crosswalk_warning_view_exists(self) -> None:
    sql = (ROOT / "supabase/sql/018_profit_service_recognition_rules_crosswalk.sql").read_text(
        encoding="utf-8"
    )

    self.assertIn("create or replace view profit_anchor_services_without_tag", sql.lower())
    self.assertIn("profit_service_recognition_rules", sql)
    self.assertIn("fc_tag is null", sql.lower())
```

- [ ] **Step 3: Run tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_service_crosswalk_generation.py tests/test_prepaid_liability_sql.py -q
```

Expected: fail because `scripts/generate_service_crosswalk_seed.py` and migration `018` do not exist.

## Task 4: Create Generator And Generated Migration

**Files:**
- Create `scripts/generate_service_crosswalk_seed.py`
- Create `supabase/sql/018_profit_service_recognition_rules_crosswalk.sql`
- Test `tests/test_service_crosswalk_generation.py`
- Test `tests/test_prepaid_liability_sql.py`

- [ ] **Step 1: Create generator script**

Create `scripts/generate_service_crosswalk_seed.py`:

```python
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
class CrosswalkRow:
    service_name: str
    fc_tag: str | None
    qbo_category_path: str | None
    qbo_product_name: str | None


def load_anchor_services(path: Path = ANCHOR_CSV) -> dict[str, AnchorService]:
    with path.open(encoding="utf-8-sig", newline="") as file:
        rows = {}
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
        rows = {}
        for row in csv.DictReader(file):
            product_name = (row.get("Product/Service Name") or "").strip()
            if not product_name:
                continue
            category = (row.get("Category") or "").strip() or None
            rows[product_name] = QboProduct(product_name=product_name, category_path=category)
    return rows


def build_crosswalk_rows(
    anchor_services: dict[str, AnchorService],
    qbo_products: dict[str, QboProduct],
) -> dict[str, CrosswalkRow]:
    rows = {}
    for service_name, anchor_service in sorted(anchor_services.items()):
        qbo_product = qbo_products.get(service_name)
        rows[service_name] = CrosswalkRow(
            service_name=service_name,
            fc_tag=anchor_service.fc_tag,
            qbo_category_path=qbo_product.category_path if qbo_product else None,
            qbo_product_name=qbo_product.product_name if qbo_product else None,
        )
    return rows


def sql_literal(value: str | None) -> str:
    if value is None:
        return "null"
    return "'" + value.replace("'", "''") + "'"


def render_sql(rows: dict[str, CrosswalkRow]) -> str:
    values = ",\n".join(
        "  ("
        + ", ".join(
            [
                sql_literal(row.service_name),
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

    return f"""alter table profit_service_recognition_rules
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
  fc_tag,
  qbo_category_path,
  qbo_product_name,
  source,
  last_synced_at
) values
{values}
on conflict (service_name) do update set
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
```

- [ ] **Step 2: Print CSV tag inventory before generating SQL**

Run this before generating migration output so the terminal log confirms the source values:

```bash
python3 - <<'PY'
import csv
from pathlib import Path
with Path("docs/data-references/anchor services.csv").open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        if row["Type"] == "Service":
            print(row["Name"], row["Tag"])
PY
```

Expected: Accounting tags are `S BOOKA`, `S BOOKE`, `S BOOKP`; empty tags remain blank for Other Income, Services, and Specialized Services.

- [ ] **Step 3: Generate migration from the script**

Run:

```bash
python3 scripts/generate_service_crosswalk_seed.py
```

Expected: `supabase/sql/018_profit_service_recognition_rules_crosswalk.sql` is created from the CSVs. Do not hand-edit seed tuples.

- [ ] **Step 4: Run SQL tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_service_crosswalk_generation.py tests/test_prepaid_liability_sql.py -q
```

Expected: pass.

## Task 5: Service Recognition Rules Doc Update

**Files:**
- Modify `docs/service-recognition-rules.md`
- Test: add doc string coverage to `tests/test_data_references_docs.py`

- [ ] **Step 1: Add failing doc coverage**

Extend `tests/test_data_references_docs.py`:

```python
def test_service_recognition_rules_document_fc_tag_column(self) -> None:
    doc = (ROOT / "docs/service-recognition-rules.md").read_text(encoding="utf-8")

    self.assertIn("FC tag", doc)
    self.assertIn("S BOOKA", doc)
    self.assertIn("S 1040A", doc)
    self.assertIn("S BILL", doc)
    self.assertIn("Shared umbrella tags", doc)
```

- [ ] **Step 2: Run test and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: fail until the doc includes FC tag references.

- [ ] **Step 3: Update taxonomy tables**

Update `docs/service-recognition-rules.md` tables by adding `FC tag` after `Anchor service name`.

Examples:

```markdown
| Anchor service name | FC tag | Macro service type | Monthly price | Service period rule | Default SLA day | Recognition rule / notes |
| Accounting Advanced | S BOOKA | bookkeeping | $900 | previous month | day 10 default | Recognize from FC bookkeeping completion for the prior month. Per-engagement SLA override allowed. |
```

For pass-through rows:

```markdown
| Billable Expenses | S BILL | pass_through | $0 | Exclude. Out-of-pocket reimbursement/pass-through. |
| Remote Desktop Access | S BILL | pass_through | $200 yearly | Exclude. Client reimbursement / access cost recovery. |
| Remote QBD Access | S BILL | pass_through | $200 yearly | Exclude. Client reimbursement / access cost recovery. |
```

Add a short note near Implicit Rules:

```markdown
Shared umbrella tags are valid. `S BILL` currently maps to Billable Expenses, Remote Desktop Access, and Remote QBD Access; `fc_tag` is not unique and should never receive a unique constraint.
```

- [ ] **Step 4: Run doc test and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: pass.

## Task 6: Recognition Trigger Data Contract Update

**Files:**
- Modify `docs/data-contracts/recognition-triggers.md`
- Test: extend `tests/test_data_references_docs.py`

- [ ] **Step 1: Add failing data-contract coverage**

Extend `tests/test_data_references_docs.py`:

```python
def test_recognition_triggers_contract_documents_service_crosswalk(self) -> None:
    doc = (ROOT / "docs/data-contracts/recognition-triggers.md").read_text(encoding="utf-8")

    self.assertIn("V0.5.2.1 Service Crosswalk", doc)
    self.assertIn("fc_tag", doc)
    self.assertIn("qbo_category_path", doc)
    self.assertIn("qbo_product_name", doc)
    self.assertIn("Shared umbrella tags", doc)
    self.assertIn("profit_anchor_services_without_tag", doc)
```

- [ ] **Step 2: Run test and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: fail until the data contract is updated.

- [ ] **Step 3: Append data contract section**

Append to `docs/data-contracts/recognition-triggers.md`:

```markdown
## V0.5.2.1 Service Crosswalk

`profit_service_recognition_rules` includes three nullable crosswalk columns:

- `fc_tag`: exact Financial Cents tag string from the Anchor service catalog.
- `qbo_category_path`: full QBO product/service category hierarchy from the QBO export.
- `qbo_product_name`: exact QBO product/service name, stored separately from Anchor `service_name` for drift detection.

Shared umbrella tags are valid. `S BILL` maps to Billable Expenses, Remote Desktop Access, and Remote QBD Access, so `fc_tag` must not be unique.

`profit_anchor_services_without_tag` lists configured services without an FC tag and is intended for V0.5.3 pipeline run logs. Missing tags do not block recognition in V0.5.2.1 because recognition still uses `service_name`.
```

- [ ] **Step 4: Run doc tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: pass.

## Task 7: Full Test Run

**Files:**
- Modify `docs/tech-debt.md`
- Test: use full suite after doc update.

- [ ] **Step 1: Update source-of-truth drift note**

Under the existing `Source-Of-Truth Drift Across Business Rule Domains` section in `docs/tech-debt.md`, add this sentence to the `profit_service_recognition_rules` bullet:

```markdown
V0.5.2.1 adds `scripts/generate_service_crosswalk_seed.py`, which is the manual-seed-time mirror of the future Anchor/QBO API sync: it reads the current CSV exports and regenerates migration `018` instead of hand-maintaining seed tuples.
```

- [ ] **Step 2: Run full suite**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass. If unrelated uncommitted V0.5.1/V0.5.2 work causes failures, stop and report before proceeding.

## Task 8: Deploy Checkpoint

**Files:**
- Apply `supabase/sql/018_profit_service_recognition_rules_crosswalk.sql` to live Supabase.

- [ ] **Step 1: Upload migration**

Run:

```bash
scp -P 2222 supabase/sql/018_profit_service_recognition_rules_crosswalk.sql root@104.225.220.36:/tmp/018_profit_service_recognition_rules_crosswalk.sql
```

- [ ] **Step 2: Apply migration**

Run on the VPS:

```bash
set -a; . /opt/agents/outscore_profit/.env; set +a
psql "$SUPABASE_DB_URL" -f /tmp/018_profit_service_recognition_rules_crosswalk.sql
```

Expected: columns added, seed upserted, view created.

- [ ] **Step 3: Verify idempotency**

Run the migration a second time:

```bash
psql "$SUPABASE_DB_URL" -f /tmp/018_profit_service_recognition_rules_crosswalk.sql
```

Expected: no duplicate rows and no unique constraint error from shared `S BILL`.

- [ ] **Step 4: Pull live counts**

Run:

```sql
select
  count(*) as total_rules,
  count(fc_tag) as rules_with_fc_tag,
  count(qbo_product_name) as rules_with_qbo_product
from profit_service_recognition_rules;

select fc_tag, count(*)
from profit_service_recognition_rules
where fc_tag = 'S BILL'
group by 1;

select service_name, fc_tag, qbo_category_path, qbo_product_name
from profit_service_recognition_rules
where service_name in (
  'Accounting Advanced',
  '1040 Advanced',
  'Billable Expenses',
  'Remote Desktop Access',
  'Remote QBD Access',
  'Other Income',
  'Services',
  'Specialized Services'
)
order by service_name;

select *
from profit_anchor_services_without_tag
order by service_name;
```

- [ ] **Step 5: Stop for deploy spot-check**

Report:
- migration apply status
- idempotency rerun status
- total rules / rules with FC tag / rules with QBO product
- `S BILL` row count
- sample rows listed above
- `profit_anchor_services_without_tag` output

Stop here for Orlando review before any commit.

## Task 9: Commit After Spot-Check Approval

**Files:** all V0.5.2.1 files.

- [ ] **Step 1: Re-run full tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Commit**

Use:

```bash
git add docs/data-references/README.md docs/service-recognition-rules.md docs/data-contracts/recognition-triggers.md docs/tech-debt.md docs/superpowers/plans/2026-05-04-profit-dashboard-v0.5.2.1-service-crosswalk.md scripts/generate_service_crosswalk_seed.py supabase/sql/018_profit_service_recognition_rules_crosswalk.sql tests/test_data_references_docs.py tests/test_prepaid_liability_sql.py tests/test_service_crosswalk_generation.py
git commit -m "Add service recognition crosswalk metadata (V0.5.2.1)" -m "Document canonical data references and extend profit_service_recognition_rules with fc_tag, qbo_category_path, and qbo_product_name. Seed crosswalk metadata idempotently from existing reference files and add a warning view for services missing FC tags."
```

- [ ] **Step 3: Push**

Run:

```bash
git push
```

Expected: branch pushed cleanly.

## Stop Checkpoints

1. After this plan doc is written: stop for review.
2. After migration is deployed and live crosswalk counts are pulled: stop for spot-check.
3. After spot-check approval: run tests, commit, push.
