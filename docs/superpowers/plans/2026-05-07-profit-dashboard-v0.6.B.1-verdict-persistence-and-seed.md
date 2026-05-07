# Profit Dashboard V0.6.B.1 Verdict Persistence And Seed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the V0.6 fulfillment-audit verdict canon, seed the completed 2026-05-04 manual audit into durable classification history, and add the inactive-client re-emergence scan needed before V0.6.B.2 builds the audit UI.

**Architecture:** V0.6.B.1 is a SQL/data-layer slice only. Migration `023` creates the verdict lookup, classification history, and transition-rule tables; migration `024` is generated from the audited CSV by a deterministic script; migration `025a` adds the inactive-client re-emergence scan function without touching V0.6.B.2's planned `025` audit views. No UI, API route, pipeline orchestration, or audit candidate view ships in this slice.

**Tech Stack:** Supabase Postgres migrations/functions, Python CSV seed generator, `pytest` static and script coverage, live Supabase deploy through existing VPS `psql`, existing V0.6.A FC/Anchor/QBO data foundation.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: locked V0.6 spec and 14-verdict canon.
- `docs/superpowers/backlog/v0.6-sprint-backlog.md`: operational examples and verdict doctrine.
- `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`: seed source, committed separately in `4f51b7f`.
- `profit_anchor_agreements.display_status`: live `active` / `terminated` / `stale` agreement state from V0.6.A migration 021 and Workflow 05.
- `profit_fc_client_tags` and `profit_client_groups`: live FC group/service foundation from V0.6.A migration 020 and Workflow 17.
- `profit_revenue_events.canonical_service_name` and `profit_anchor_service_fc_project_coverage`: V0.6.A migration 022 data that V0.6.B.2 will consume after persistence exists.

## Scope

In scope:

- Migration `023_profit_fulfillment_classifications.sql`.
- `profit_classification_verdicts` lookup table with all 14 canonical verdicts seeded idempotently.
- `profit_classifications` append-friendly classification history table.
- `profit_classification_transition_rules` table with seeded auto-transition rules.
- Read-only hard gate: audit-CSV `PENDING_*` drift inspection before seed script work.
- `scripts/generate_fulfillment_classification_seed.py`.
- Generated migration `024_profit_fulfillment_classification_seed_20260504.sql`.
- Migration `025a_profit_inactive_client_reemergence_scan.sql`.
- `profit_run_inactive_client_reemergence_scan()` function.
- Tests for SQL shape, lookup seed attributes, transition rules, seed generation, CSV verdict hygiene, deterministic output, and re-emergence scan SQL.
- `docs/data-contracts/fulfillment-classifications.md`.

Out of scope:

- Migration `025` audit candidate/signal/group/re-evaluation views.
- Audit dashboard UI at `/profit/admin/audit`.
- Bulk classification UI primitive.
- Pipeline orchestration / cron / Workflow 26.
- SLA dashboard.
- Manual alias seeding from `docs/audits/2026-05-07-unresolved-service-names.csv`.
- QBO open-balance signal in inactive-client re-emergence scan; deferred to V0.6.B.2 once the audit signal view defines the canonical open-balance source.
- Changing V0.6.A workflows 05, 17, 28.
- Reclassifying any rows manually outside the generated seed.

## Migration And Deploy Checkpoints

Stop after every deploy checkpoint and wait for orchestrator approval.

1. **Migration 023 checkpoint**
   - Apply `023_profit_fulfillment_classifications.sql` to live Supabase.
   - Verify 14 verdict lookup rows.
   - Verify `default_visibility` and `auto_transition_enabled` matrices.
   - Verify classification table exists but has no rows before migration 024.
   - Verify transition rules are seeded and enabled.

2. **Audit-CSV PENDING drift inspection checkpoint**
   - Read the CSV and live `profit_anchor_agreements`.
   - Report DRAFT and SENT totals, active-agreement drift counts, and sample names.
   - Stop before writing the seed-generation script.

3. **Migration 024 checkpoint**
   - Run the generator.
   - Confirm generated SQL is deterministic.
   - Apply `024_profit_fulfillment_classification_seed_20260504.sql` to live Supabase.
   - Verify seeded classification counts by verdict.
   - Verify PENDING rows with active agreements were seeded as `MIXED`.

4. **Migration 025a checkpoint**
   - Apply `025a_profit_inactive_client_reemergence_scan.sql`.
   - Verify the function exists.
   - Run a no-op live invocation and report returned row count.
   - Do not create or modify V0.6.B.2 audit views.

5. **Final B.1 checkpoint before commit**
   - Full pytest.
   - Scope boundary check: no V0.6.B.2 UI/API/view files, no V0.6.C/D files, no edits to V0.6.A workflow JSON beyond already-shipped state.
   - Commit and push only after orchestrator approval.

## Files

Create:

- `supabase/sql/023_profit_fulfillment_classifications.sql`
- `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`
- `supabase/sql/025a_profit_inactive_client_reemergence_scan.sql`
- `scripts/generate_fulfillment_classification_seed.py`
- `tests/test_fulfillment_classification_sql.py`
- `tests/test_fulfillment_classification_seed.py`
- `docs/data-contracts/fulfillment-classifications.md`

Modify:

- `docs/superpowers/plans/2026-05-07-profit-dashboard-v0.6.B.1-verdict-persistence-and-seed.md` while checking off tasks.
- `docs/tech-debt.md` only if implementation uncovers a new deferred source-of-truth gap.

Do not modify:

- `supabase/sql/025_*` audit views for V0.6.B.2.
- `app/frontend/**`.
- `profit_api/**`.
- `n8n/workflows/**`.
- `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`.
- `docs/audits/2026-05-07-unresolved-service-names.csv`.

## Task 1: Migration 023 SQL Shape Tests

**Files:**
- Create `tests/test_fulfillment_classification_sql.py`
- Create later `supabase/sql/023_profit_fulfillment_classifications.sql`

- [ ] **Step 1: Write failing tests for the verdict lookup and classification table**

Add:

```python
from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_023 = ROOT / "supabase/sql/023_profit_fulfillment_classifications.sql"
SQL_025A = ROOT / "supabase/sql/025a_profit_inactive_client_reemergence_scan.sql"


CANONICAL_VERDICTS = [
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
]


class FulfillmentClassificationSqlTests(unittest.TestCase):
    def test_migration_023_creates_verdict_lookup_and_classification_history(self) -> None:
        sql = SQL_023.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create table if not exists profit_classification_verdicts", lower)
        self.assertIn("verdict_code text primary key", lower)
        self.assertIn("default_visibility text not null", lower)
        self.assertIn("auto_transition_enabled boolean not null", lower)
        self.assertIn("create table if not exists profit_classifications", lower)
        self.assertIn("classification_id bigserial primary key", lower)
        self.assertIn("source_audit_file text", lower)
        self.assertIn("source_audit_row_hash text not null", lower)
        self.assertIn("last_signal_hash text", lower)
        self.assertIn("last_signal_at timestamptz", lower)
        self.assertIn("superseded_by_classification_id bigint references profit_classifications", lower)
        self.assertIn("unique (source_audit_file, source_audit_row_hash)", lower)
        for verdict in CANONICAL_VERDICTS:
            self.assertIn(verdict, sql)
```

- [ ] **Step 2: Write failing tests for lookup attributes and transition table**

Add:

```python
    def test_migration_023_seeds_visibility_and_transition_attribute_matrix(self) -> None:
        sql = SQL_023.read_text(encoding="utf-8")
        lower = sql.lower()

        expected_fragments = [
            "('INTERNAL_FAMILY', 'Internal family', 'suppressed', 'hide', false, false",
            "('INACTIVE_FORMER_CLIENT', 'Inactive former client', 'suppressed', 'hide', false, true",
            "('PENDING_ENGAGEMENT_DRAFT', 'Pending engagement draft', 'pending', 'show', true, true",
            "('PENDING_ENGAGEMENT_SENT', 'Pending engagement sent', 'pending', 'show', true, true",
            "('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'Invoice outstanding / payment pending', 'pending', 'show', false, true",
            "('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'Legacy engagement pre-Anchor', 'pending', 'show', false, true",
            "('ENGAGEMENT_DECLINED', 'Engagement declined', 'suppressed', 'hide', false, false",
            "('LEGITIMATE_LEAK', 'Legitimate leak', 'leak', 'show', false, false",
            "('BILLING_OUTSIDE_AUDIT_WINDOW', 'Billing outside audit window', 'pending', 'show', false, false",
            "('BILLING_SETUP_GAP', 'Billing setup gap', 'setup_gap', 'show', false, false",
            "('GROUP_DEFINITION_GAP', 'Group definition gap', 'setup_gap', 'show', false, false",
            "('MIXED', 'Mixed', 'mixed', 'show', false, false",
            "('CONSOLIDATED_VIA_GROUP_BILLED', 'Consolidated via group billed', 'healthy', 'hide', false, false",
            "('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'Settled via QuickBooks payment', 'backfill', 'hide', false, true",
        ]
        for fragment in expected_fragments:
            self.assertIn(fragment, sql)

        self.assertIn("on conflict (verdict_code) do update set", lower)
        self.assertIn("create table if not exists profit_classification_transition_rules", lower)
        self.assertIn("primary key (from_verdict_code, signal_name, to_verdict_code)", lower)
        self.assertIn("PENDING_ENGAGEMENT_DRAFT", sql)
        self.assertIn("active_agreement_appears", sql)
        self.assertIn("SETTLED_VIA_QUICKBOOKS_PAYMENT", sql)
        self.assertIn("anchor_backfill_invoice_cash_pending", sql)
```

- [ ] **Step 3: Run tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: FAIL because migration `023_profit_fulfillment_classifications.sql` does not exist.

## Task 2: Migration 023 Implementation

**Files:**
- Create `supabase/sql/023_profit_fulfillment_classifications.sql`
- Test `tests/test_fulfillment_classification_sql.py`

- [ ] **Step 1: Create migration 023 tables**

Create `supabase/sql/023_profit_fulfillment_classifications.sql` with:

```sql
create table if not exists profit_classification_verdicts (
  verdict_code text primary key,
  label text not null,
  category text not null check (category in ('suppressed', 'healthy', 'pending', 'leak', 'setup_gap', 'mixed', 'manual_review', 'backfill')),
  default_visibility text not null check (default_visibility in ('show', 'hide')),
  requires_re_evaluate_at boolean not null default false,
  auto_transition_enabled boolean not null default false,
  description text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists profit_classifications (
  classification_id bigserial primary key,
  fc_client_id bigint references profit_fc_clients(fc_client_id),
  anchor_relationship_id text references profit_anchor_agreements(anchor_relationship_id),
  group_id bigint references profit_client_groups(group_id),
  verdict_code text not null references profit_classification_verdicts(verdict_code),
  source_verdict_raw text,
  source_audit_file text,
  source_audit_row_hash text not null,
  suggested_classification text,
  estimated_annual_revenue numeric,
  notes text,
  classified_by text not null default 'orlando',
  classified_at timestamptz not null default now(),
  re_evaluate_at date,
  auto_transition_enabled boolean not null default true,
  last_signal_hash text,
  last_signal_at timestamptz,
  superseded_at timestamptz,
  superseded_by_classification_id bigint references profit_classifications(classification_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_audit_file, source_audit_row_hash)
);

create index if not exists idx_profit_classifications_current
  on profit_classifications (fc_client_id, verdict_code)
  where superseded_at is null;

create index if not exists idx_profit_classifications_re_evaluate
  on profit_classifications (re_evaluate_at)
  where superseded_at is null and re_evaluate_at is not null;

create index if not exists idx_profit_classifications_verdict
  on profit_classifications (verdict_code)
  where superseded_at is null;
```

- [ ] **Step 2: Add the 14-row idempotent verdict seed**

Append the exact `insert into profit_classification_verdicts (...) values ... on conflict (verdict_code) do update set ...` block from the locked V0.6 spec. The seed must include all 14 verdicts and the approved `default_visibility`, `requires_re_evaluate_at`, and `auto_transition_enabled` values.

- [ ] **Step 3: Add transition rules table and seed rows**

Append:

```sql
create table if not exists profit_classification_transition_rules (
  from_verdict_code text not null references profit_classification_verdicts(verdict_code),
  signal_name text not null,
  to_verdict_code text not null references profit_classification_verdicts(verdict_code),
  requires_service_type_match boolean not null default true,
  enabled boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (from_verdict_code, signal_name, to_verdict_code)
);

insert into profit_classification_transition_rules (
  from_verdict_code,
  signal_name,
  to_verdict_code,
  requires_service_type_match,
  enabled,
  notes
) values
  ('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'first_matching_anchor_invoice_mid_cycle', 'BILLING_OUTSIDE_AUDIT_WINDOW', true, true, 'First matching Anchor invoice exists; annual or one-time service remains mid-cycle.'),
  ('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'first_matching_anchor_invoice_group_billed', 'CONSOLIDATED_VIA_GROUP_BILLED', true, true, 'First matching Anchor invoice exists and matching service is delivered or billed through the group parent.'),
  ('PENDING_ENGAGEMENT_DRAFT', 'active_agreement_appears', 'MIXED', false, true, 'Anchor API cannot expose DRAFT. When an active agreement appears, supersede and force manual reclassification.'),
  ('PENDING_ENGAGEMENT_SENT', 'active_agreement_appears', 'MIXED', false, true, 'Anchor API cannot expose SENT. When an active agreement appears, supersede and force manual reclassification.'),
  ('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'cash_collected_group_parent', 'CONSOLIDATED_VIA_GROUP_BILLED', true, true, 'Cash collected and billed entity is a group parent.'),
  ('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'cash_collected_standalone_mid_cycle', 'BILLING_OUTSIDE_AUDIT_WINDOW', true, true, 'Cash collected on standalone billing and service remains mid-cycle.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'anchor_backfill_invoice_group_parent', 'CONSOLIDATED_VIA_GROUP_BILLED', true, true, 'Anchor backfill created agreement and first invoice for group-parent billing.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'anchor_backfill_invoice_standalone', 'BILLING_OUTSIDE_AUDIT_WINDOW', true, true, 'Anchor backfill created standalone agreement and first invoice.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'anchor_backfill_invoice_cash_pending', 'INVOICE_OUTSTANDING_PAYMENT_PENDING', true, true, 'Anchor backfill created agreement and invoice, but cash has not been collected.'),
  ('INACTIVE_FORMER_CLIENT', 'any_active_signal_returns', 'MIXED', false, true, 'Inactive client has a new signal; supersede and force manual reclassification.')
on conflict (from_verdict_code, signal_name, to_verdict_code) do update set
  requires_service_type_match = excluded.requires_service_type_match,
  enabled = excluded.enabled,
  notes = excluded.notes,
  updated_at = now();
```

- [ ] **Step 4: Run focused tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: PASS for migration 023 tests.

- [ ] **Step 5: Apply migration 023 to live Supabase**

Run through the existing VPS `psql` pattern:

```bash
scp -P 2222 supabase/sql/023_profit_fulfillment_classifications.sql root@104.225.220.36:/tmp/023_profit_fulfillment_classifications.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/023_profit_fulfillment_classifications.sql'
```

Use the repo-to-VPS file transfer pattern established in V0.6.A if direct file access is not already available.

- [ ] **Step 6: Migration 023 deploy checkpoint**

Run:

```sql
select count(*) as verdict_count from profit_classification_verdicts;

select verdict_code, default_visibility, requires_re_evaluate_at, auto_transition_enabled
from profit_classification_verdicts
order by verdict_code;

select count(*) as classification_count_before_seed
from profit_classifications;

select from_verdict_code, signal_name, to_verdict_code, enabled
from profit_classification_transition_rules
order by from_verdict_code, signal_name, to_verdict_code;
```

Expected:

- `verdict_count = 14`
- `classification_count_before_seed = 0`
- `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT` have `requires_re_evaluate_at = true` and `auto_transition_enabled = true`
- `INACTIVE_FORMER_CLIENT`, `LEGACY_ENGAGEMENT_PRE_ANCHOR`, `INVOICE_OUTSTANDING_PAYMENT_PENDING`, `PENDING_*`, and `SETTLED_VIA_QUICKBOOKS_PAYMENT` transition-enabled where specified
- Transition rules include `active_agreement_appears`, `any_active_signal_returns`, and all three `SETTLED_VIA_QUICKBOOKS_PAYMENT` backfill signals

Stop and report these results before Task 3.

## Task 3: Audit-CSV PENDING Drift Inspection Gate

**Files:**
- Read `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`
- No file writes in this task

- [ ] **Step 1: Pull PENDING rows from the CSV**

Run a local read-only script:

```bash
python3 - <<'PY'
import csv
from collections import defaultdict
from pathlib import Path

path = Path("docs/audits/2026-05-04-fulfillment-leaks-classification.csv")
rows = []
with path.open(newline="", encoding="utf-8") as handle:
    for row in csv.DictReader(handle):
        verdict = row["veredict"].strip().upper()
        if verdict in {"PENDING_ENGAGEMENT_DRAFT", "PENDING_ENGAGEMENT_SENT"}:
            rows.append(row)

by_verdict = defaultdict(list)
for row in rows:
    by_verdict[row["veredict"].strip().upper()].append(row)

print("total_pending_rows", len(rows))
for verdict, bucket in sorted(by_verdict.items()):
    print(verdict, len(bucket))
    for row in bucket[:5]:
        print(" ", row["fc_client_id"], row["fc_client_name"])
PY
```

Expected: `PENDING_ENGAGEMENT_DRAFT = 3`, `PENDING_ENGAGEMENT_SENT = 15`, `total_pending_rows = 18`.

- [ ] **Step 2: Cross-check those FC clients against active Anchor agreements**

Use the 18 `fc_client_id` values from Step 1 in a live read-only query:

```sql
with pending_csv(fc_client_id, fc_client_name, verdict_code) as (
  values
    -- generated from Step 1 output during execution
    ('2430343'::bigint, 'Saffold II, James (1040)', 'PENDING_ENGAGEMENT_DRAFT')
)
select
  pending.verdict_code,
  pending.fc_client_id,
  pending.fc_client_name,
  agreement.anchor_relationship_id,
  agreement.client_business_name,
  agreement.display_status
from pending_csv pending
left join profit_fc_client_anchor_matches match
  on match.fc_client_id = pending.fc_client_id
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = match.anchor_relationship_id
  and agreement.display_status = 'active'
order by pending.verdict_code, pending.fc_client_name;
```

The execution task should build the full `values` list from the CSV, not from hand-typed assumptions.

- [ ] **Step 3: Report the hard-gate summary**

Report:

```text
DRAFT rows total: 3
  with active agreement now: N
  without active agreement: 3 - N
  sample with active: [...]
  sample without active: [...]

SENT rows total: 15
  with active agreement now: M
  without active agreement: 15 - M
  sample with active: [...]
  sample without active: [...]
```

Save the findings as `/tmp/v06b1_pending_drift_20260507.json` in this exact format:

```json
{
  "<fc_client_id>": true,
  "<fc_client_id>": false
}
```

The value is `true` when the FC client has an active Anchor agreement today, and `false` otherwise. Include all 18 `fc_client_id` values from Step 1's `PENDING_*` rows. This file is the deterministic input to Task 5 Step 5's generator invocation, and generator idempotency depends on this file being byte-stable across reruns.

Stop here. Do not write the seed-generation script until Orlando approves the observed drift counts.

## Task 4: Seed Generator Tests

**Files:**
- Create `tests/test_fulfillment_classification_seed.py`
- Create later `scripts/generate_fulfillment_classification_seed.py`
- Generate later `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`

- [ ] **Step 1: Write failing tests for verdict normalization and unknown rejection**

Add:

```python
from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/generate_fulfillment_classification_seed.py"
OUTPUT = ROOT / "supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql"
AUDIT_CSV = ROOT / "docs/audits/2026-05-04-fulfillment-leaks-classification.csv"


class FulfillmentClassificationSeedTests(unittest.TestCase):
    def test_generator_source_contains_canon_and_normalization_rules(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("CANONICAL_VERDICTS", source)
        self.assertIn("CONSOLIDATED_VIA_GROUP_BILLED", source)
        self.assertIn("consolidated_via_group_billed", source)
        self.assertIn("strip()", source)
        self.assertIn("Unknown verdict", source)
        self.assertIn("PENDING_ENGAGEMENT_DRAFT", source)
        self.assertIn("PENDING_ENGAGEMENT_SENT", source)
        self.assertIn("Audit CSV captured this row as PENDING_ENGAGEMENT_* on 2026-05-04", source)

    def test_audit_csv_verdicts_normalize_to_14_canon(self) -> None:
        canon = {
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
        aliases = {"consolidated_via_group_billed": "CONSOLIDATED_VIA_GROUP_BILLED"}

        with AUDIT_CSV.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            normalized = []
            for row in reader:
                raw = row["veredict"]
                value = aliases.get(raw.strip(), raw.strip().upper())
                normalized.append(value)

        self.assertTrue(normalized)
        self.assertEqual(set(normalized) - canon, set())
```

- [ ] **Step 2: Write failing tests for deterministic output and generated SQL shape**

Add:

```python
    def test_generated_seed_sql_shape_is_idempotent_and_traceable(self) -> None:
        sql = OUTPUT.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("generated by scripts/generate_fulfillment_classification_seed.py", lower)
        self.assertIn("source audit file: docs/audits/2026-05-04-fulfillment-leaks-classification.csv", lower)
        self.assertIn("rows seeded as captured:", lower)
        self.assertIn("rows reclassified to mixed due to drift:", lower)
        self.assertIn("insert into profit_classifications", lower)
        self.assertIn("on conflict (source_audit_file, source_audit_row_hash) do update set", lower)
        self.assertIn("source_audit_row_hash", lower)
        self.assertIn("source_verdict_raw", lower)
        self.assertIn("estimated_annual_revenue", lower)
        self.assertIn("re_evaluate_at", lower)
```

- [ ] **Step 3: Run tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_seed.py -q
```

Expected: FAIL because the generator and output migration do not exist.

## Task 5: Seed Generator Implementation

**Files:**
- Create `scripts/generate_fulfillment_classification_seed.py`
- Create generated `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`
- Test `tests/test_fulfillment_classification_seed.py`

- [ ] **Step 1: Implement generator CLI and canon**

Create `scripts/generate_fulfillment_classification_seed.py` with:

```python
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
```

- [ ] **Step 2: Add pending drift input support**

The generator needs live drift information from the Task 3 hard gate but must remain deterministic. Implement a `--pending-drift-json` argument that points to a small JSON file shaped like:

```json
{
  "2430343": true,
  "2426526": false
}
```

where `true` means that FC client now has an active Anchor agreement.

Add:

```python
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
```

- [ ] **Step 3: Generate classification rows with PENDING drift logic**

Add row transformation:

```python
def transform_rows(rows: Iterable[dict[str, str]], pending_drift: dict[str, PendingDrift]) -> tuple[list[dict[str, object]], int, int]:
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
                re_evaluate_at = date.today().isoformat()
                drift_count += 1
            else:
                re_evaluate_at = (date.today() + timedelta(days=30)).isoformat()
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
```

- [ ] **Step 4: Emit deterministic SQL**

Generate SQL that:

- starts with a comment containing generator path, source audit file, total inserted, rows seeded as captured, and rows reclassified to MIXED due to drift;
- inserts each transformed row into `profit_classifications`;
- uses `fc_client_id` from the CSV;
- resolves `group_id` by normalized group name when `group_name` exists;
- leaves `anchor_relationship_id` null in the seed because B.2 signal views will derive current Anchor state;
- uses `source_audit_file = 'docs/audits/2026-05-04-fulfillment-leaks-classification.csv'`;
- uses `source_audit_row_hash`;
- preserves `source_verdict_raw`;
- uses `classified_by = 'orlando'`;
- uses `on conflict (source_audit_file, source_audit_row_hash) do update set ...`.

Use stable ordering by CSV row order. Re-running the generator against unchanged CSV and unchanged drift JSON must produce byte-identical SQL.

- [ ] **Step 5: Run the generator**

After Task 3 is approved, create a local drift JSON file from the inspection result:

```bash
python3 scripts/generate_fulfillment_classification_seed.py \
  --input docs/audits/2026-05-04-fulfillment-leaks-classification.csv \
  --pending-drift-json /tmp/v06b1_pending_drift_20260507.json \
  --output supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql
```

Expected stdout:

```text
rows seeded as captured:
rows reclassified to MIXED due to drift:
total inserted:
wrote supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql
```

- [ ] **Step 6: Verify generator idempotency**

Run:

```bash
python3 scripts/generate_fulfillment_classification_seed.py \
  --input docs/audits/2026-05-04-fulfillment-leaks-classification.csv \
  --pending-drift-json /tmp/v06b1_pending_drift_20260507.json \
  --output supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql
git diff -- supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql
```

Expected: zero diff after the second run.

- [ ] **Step 7: Run focused tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_seed.py -q
```

Expected: PASS.

## Task 6: Migration 024 Deploy

**Files:**
- Apply `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`

- [ ] **Step 1: Apply migration 024 to live Supabase**

Use the established VPS `psql` migration pattern. Do not edit the generated SQL by hand; fix the generator if SQL output needs to change.

- [ ] **Step 2: Migration 024 deploy checkpoint**

Run:

```sql
select count(*) as seeded_classifications
from profit_classifications
where source_audit_file = 'docs/audits/2026-05-04-fulfillment-leaks-classification.csv';

select verdict_code, count(*)
from profit_classifications
where source_audit_file = 'docs/audits/2026-05-04-fulfillment-leaks-classification.csv'
group by 1
order by 2 desc, 1;

select source_verdict_raw, verdict_code, count(*)
from profit_classifications
where source_audit_file = 'docs/audits/2026-05-04-fulfillment-leaks-classification.csv'
  and source_verdict_raw ilike 'PENDING_ENGAGEMENT_%'
group by 1, 2
order by 1, 2;

select count(*) as pending_without_re_evaluate_at
from profit_classifications
where source_audit_file = 'docs/audits/2026-05-04-fulfillment-leaks-classification.csv'
  and verdict_code in ('PENDING_ENGAGEMENT_DRAFT', 'PENDING_ENGAGEMENT_SENT')
  and re_evaluate_at is null;

select count(*) as unknown_verdict_rows
from profit_classifications classification
left join profit_classification_verdicts verdict
  on verdict.verdict_code = classification.verdict_code
where verdict.verdict_code is null;

select count(*) as pending_rows_reclassified_to_mixed_due_to_drift
from profit_classifications
where source_audit_file = 'docs/audits/2026-05-04-fulfillment-leaks-classification.csv'
  and verdict_code = 'MIXED'
  and notes ilike 'Audit CSV captured this row as PENDING_ENGAGEMENT_* %';
```

Expected:

- Seeded row count equals the CSV row count.
- `unknown_verdict_rows = 0`
- `pending_without_re_evaluate_at = 0`
- PENDING rows with active agreement drift appear as `MIXED`, matching Task 3 expectations.
- `pending_rows_reclassified_to_mixed_due_to_drift` equals the generated SQL header comment's `rows reclassified to MIXED due to drift` count.
- If `pending_rows_reclassified_to_mixed_due_to_drift` and the generated SQL header count diverge, the generator has a bug. Halt and report.

Stop and report before Task 7.

## Task 7: Inactive Re-Emergence Scan Tests

**Files:**
- Modify `tests/test_fulfillment_classification_sql.py`
- Create later `supabase/sql/025a_profit_inactive_client_reemergence_scan.sql`

- [ ] **Step 1: Add failing tests for re-emergence scan SQL**

Add:

```python
    def test_migration_025a_defines_inactive_client_reemergence_scan(self) -> None:
        sql = SQL_025A.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_run_inactive_client_reemergence_scan", lower)
        self.assertIn("returns table", lower)
        self.assertIn("INACTIVE_FORMER_CLIENT", sql)
        self.assertIn("MIXED", sql)
        self.assertIn("superseded_at", lower)
        self.assertIn("superseded_by_classification_id", lower)
        self.assertIn("profit_fc_task_delivery_classification", lower)
        self.assertIn("service_delivery", lower)
        self.assertIn("display_status = 'active'", lower)
        self.assertIn("completed_at >= (p_run_at - interval '365 days')", lower)
        self.assertIn("Re-emergence scan superseded INACTIVE_FORMER_CLIENT", sql)
```

- [ ] **Step 2: Run tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: FAIL because `025a_profit_inactive_client_reemergence_scan.sql` does not exist.

## Task 7.5: Schema Verification For Re-Emergence Scan Signals

**Files:**
- Read live Supabase schema only
- Update Task 7 test assertions and Task 8 SQL plan text if schema diverges
- No migration implementation in this task

- [ ] **Step 1: Read live schemas**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "\d+ profit_fc_clients" -c "\d+ profit_fc_task_delivery_classification"'
```

Confirm and report whether these fields exist as direct columns:

- `profit_fc_clients.status`
- `profit_fc_task_delivery_classification.is_completed`
- `profit_fc_task_delivery_classification.completed_at`

- [ ] **Step 2: Adjust Task 7 assertions and Task 8 SQL based on findings**

If `profit_fc_clients.status` exists as a column, keep Task 8's scan using:

```sql
coalesce(lower(client.status), '') not in ('inactive', 'archived')
```

If FC client status lives in `raw` JSON instead, update Task 8's scan to use the actual field found in Step 1, for example:

```sql
coalesce(lower(client.raw->>'status'), '') not in ('inactive', 'archived')
```

If `profit_fc_task_delivery_classification` exposes `is_completed` and `completed_at`, keep Task 8's scan using the view directly:

```sql
from profit_fc_task_delivery_classification task
where task.fc_client_id = record_to_scan.fc_client_id
  and task.task_kind = 'service_delivery'
  and task.is_completed = true
  and task.completed_at >= (p_run_at - interval '365 days')
```

If `profit_fc_task_delivery_classification` does not expose `is_completed` or `completed_at`, refactor Task 8's third signal to join the view back to `profit_fc_tasks`:

```sql
from profit_fc_task_delivery_classification classified_task
join profit_fc_tasks task
  on task.fc_task_id = classified_task.fc_task_id
where classified_task.fc_client_id = record_to_scan.fc_client_id
  and classified_task.task_kind = 'service_delivery'
  and task.is_completed = true
  and task.completed_at >= (p_run_at - interval '365 days')
```

Update Task 7 Step 1 test assertions to match the actual schema path before writing migration `025a`.

- [ ] **Step 3: Stop and report findings**

Report:

```text
profit_fc_clients.status: present / absent
FC client status source to use in 025a: client.status / client.raw->>'...'
profit_fc_task_delivery_classification.is_completed: present / absent
profit_fc_task_delivery_classification.completed_at: present / absent
Task completion source to use in 025a: classification view direct columns / join to profit_fc_tasks
```

Stop here. Do not write migration `025a` until Orlando approves the schema findings and the selected SQL path.

## Task 8: Migration 025a Re-Emergence Scan Implementation

**Files:**
- Create `supabase/sql/025a_profit_inactive_client_reemergence_scan.sql`
- Test `tests/test_fulfillment_classification_sql.py`

- [ ] **Step 1: Create re-emergence scan function**

Create `supabase/sql/025a_profit_inactive_client_reemergence_scan.sql` with a function shaped as:

```sql
create or replace function profit_run_inactive_client_reemergence_scan(p_run_at timestamptz default now())
returns table (
  superseded_classification_id bigint,
  new_classification_id bigint,
  fc_client_id bigint,
  reemergence_reason text
)
language plpgsql
as $$
declare
  record_to_scan record;
  inserted_id bigint;
  reason text;
begin
  for record_to_scan in
    select
      classification.classification_id,
      classification.fc_client_id,
      classification.source_audit_file,
      classification.source_audit_row_hash,
      classification.estimated_annual_revenue
    from profit_classifications classification
    where classification.verdict_code = 'INACTIVE_FORMER_CLIENT'
      and classification.superseded_at is null
  loop
    reason := null;

    if exists (
      select 1
      from profit_fc_clients client
      where client.fc_client_id = record_to_scan.fc_client_id
        and coalesce(lower(client.status), '') not in ('inactive', 'archived')
    ) then
      reason := 'fc_client_became_active';
    elsif exists (
      select 1
      from profit_fc_client_anchor_matches match
      join profit_anchor_agreements agreement
        on agreement.anchor_relationship_id = match.anchor_relationship_id
      where match.fc_client_id = record_to_scan.fc_client_id
        and agreement.display_status = 'active'
    ) then
      reason := 'active_anchor_agreement_created';
    elsif exists (
      select 1
      from profit_fc_task_delivery_classification task
      where task.fc_client_id = record_to_scan.fc_client_id
        and task.task_kind = 'service_delivery'
        and task.is_completed = true
        and task.completed_at >= (p_run_at - interval '365 days')
    ) then
      reason := 'service_delivery_task_completed';
    end if;

    if reason is not null then
      insert into profit_classifications (
        fc_client_id,
        verdict_code,
        source_verdict_raw,
        source_audit_file,
        source_audit_row_hash,
        suggested_classification,
        estimated_annual_revenue,
        notes,
        classified_by,
        classified_at,
        re_evaluate_at,
        last_signal_hash,
        last_signal_at
      ) values (
        record_to_scan.fc_client_id,
        'MIXED',
        'INACTIVE_FORMER_CLIENT',
        record_to_scan.source_audit_file,
        record_to_scan.source_audit_row_hash || ':reemergence:' || p_run_at::date::text,
        'inactive_client_reemerged',
        record_to_scan.estimated_annual_revenue,
        'Re-emergence scan superseded INACTIVE_FORMER_CLIENT because signal returned: ' || reason,
        'system',
        p_run_at,
        p_run_at::date,
        reason,
        p_run_at
      )
      returning classification_id into inserted_id;

      update profit_classifications
      set
        superseded_at = p_run_at,
        superseded_by_classification_id = inserted_id,
        updated_at = now()
      where classification_id = record_to_scan.classification_id;

      superseded_classification_id := record_to_scan.classification_id;
      new_classification_id := inserted_id;
      fc_client_id := record_to_scan.fc_client_id;
      reemergence_reason := reason;
      return next;
    end if;
  end loop;
end;
$$;
```

This B.1 function handles FC active, Anchor active agreement, and recent service-delivery task signals. QBO open-balance signal in inactive-client re-emergence scan is deferred to V0.6.B.2 once the audit signal view defines the canonical open-balance source.

- [ ] **Step 2: Add function comment**

Append:

```sql
comment on function profit_run_inactive_client_reemergence_scan(timestamptz) is
  'Supersedes active INACTIVE_FORMER_CLIENT classifications when an active signal returns. V0.6.B.1 emits MIXED rows for manual reclassification; V0.6.B.2 audit views surface those rows in the review queue.';
```

- [ ] **Step 3: Run focused tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: PASS.

- [ ] **Step 4: Apply migration 025a to live Supabase**

Use the established VPS `psql` migration pattern.

- [ ] **Step 5: Migration 025a deploy checkpoint**

Run:

```sql
select count(*) as reemergence_fn
from pg_proc
where proname = 'profit_run_inactive_client_reemergence_scan';

select *
from profit_run_inactive_client_reemergence_scan(now())
limit 20;

select count(*) as active_inactive_former_client_rows
from profit_classifications
where verdict_code = 'INACTIVE_FORMER_CLIENT'
  and superseded_at is null;

select count(*) as reemerged_mixed_rows
from profit_classifications
where suggested_classification = 'inactive_client_reemerged';
```

Expected:

- `reemergence_fn = 1`
- The function call succeeds.
- Returned row count may be `0` if no currently seeded inactive clients have re-emerged; non-zero rows are valid if live signals changed.

Stop and report before Task 9.

## Task 9: Data Contract Documentation

**Files:**
- Create `docs/data-contracts/fulfillment-classifications.md`

- [ ] **Step 1: Write fulfillment classifications data contract**

Create `docs/data-contracts/fulfillment-classifications.md` with sections:

```markdown
# Fulfillment Classifications Data Contract

## Purpose

`profit_classifications` stores durable manual and system verdict history for fulfillment-leak audit rows. V0.6.B.1 seeds the completed 2026-05-04 audit and adds transition metadata; V0.6.B.2 builds audit query/UI surfaces on top.

## Verdict Lookup

`profit_classification_verdicts` is the source of truth for the 14 canonical verdicts, labels, categories, default visibility, required re-evaluation behavior, and auto-transition eligibility. UI and API code must read `default_visibility` instead of hardcoding hidden verdict names.

## Classification History

`profit_classifications` is append-friendly. Changing a verdict inserts a new row and sets `superseded_at` / `superseded_by_classification_id` on the prior active row.

## Seed Behavior

The seed generator reads `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`, normalizes verdict strings into the 14-canon, preserves the raw verdict in `source_verdict_raw`, and writes deterministic SQL to `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`.

`PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT` rows are cross-checked against live active Anchor agreements. If an active agreement exists at generation time, the row seeds as `MIXED` with a drift note and immediate `re_evaluate_at`.

## Transition Rules

`profit_classification_transition_rules` records eligible state-machine transitions. V0.6.B.1 seeds the rules; V0.6.C pipeline orchestration applies them.

## Inactive Re-Emergence

`profit_run_inactive_client_reemergence_scan()` supersedes active `INACTIVE_FORMER_CLIENT` rows when an active signal returns. V0.6.B.1 emits `MIXED` rows for manual reclassification; V0.6.B.2 audit views surface those rows.
```

- [ ] **Step 2: Run documentation/static tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py tests/test_fulfillment_classification_sql.py tests/test_fulfillment_classification_seed.py -q
```

Expected: PASS.

## Task 10: Full V0.6.B.1 Test Pass And Scope Check

**Files:**
- All V0.6.B.1 files

- [ ] **Step 1: Run targeted B.1 suite**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest \
  tests/test_fulfillment_classification_sql.py \
  tests/test_fulfillment_classification_seed.py \
  tests/test_data_references_docs.py \
  -q
```

Expected: PASS.

- [ ] **Step 2: Run full pytest**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 3: Verify scope boundary**

Run:

```bash
git diff --name-only
```

Expected files are limited to:

```text
docs/data-contracts/fulfillment-classifications.md
docs/superpowers/plans/2026-05-07-profit-dashboard-v0.6.B.1-verdict-persistence-and-seed.md
scripts/generate_fulfillment_classification_seed.py
supabase/sql/023_profit_fulfillment_classifications.sql
supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql
supabase/sql/025a_profit_inactive_client_reemergence_scan.sql
tests/test_fulfillment_classification_seed.py
tests/test_fulfillment_classification_sql.py
```

No `app/frontend/**`, `profit_api/**`, `n8n/workflows/**`, `supabase/sql/025_profit_*`, `supabase/sql/026_*`, or `supabase/sql/027_*` changes should appear.

- [ ] **Step 4: Stop for final orchestrator spot-check**

Report:

- Targeted and full pytest results.
- Migration 023/024/025a live checkpoint counts.
- Seed distribution by verdict.
- Number of PENDING rows converted to `MIXED` due to drift.
- Scope boundary output.

Wait for approval before Task 11.

## Task 11: Commit And Push

**Files:**
- All approved V0.6.B.1 files

- [ ] **Step 1: Final pytest sweep**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Commit**

Use a structured commit message:

```bash
git add docs/data-contracts/fulfillment-classifications.md \
        docs/superpowers/plans/2026-05-07-profit-dashboard-v0.6.B.1-verdict-persistence-and-seed.md \
        scripts/generate_fulfillment_classification_seed.py \
        supabase/sql/023_profit_fulfillment_classifications.sql \
        supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql \
        supabase/sql/025a_profit_inactive_client_reemergence_scan.sql \
        tests/test_fulfillment_classification_seed.py \
        tests/test_fulfillment_classification_sql.py

git commit -m "Add V0.6.B.1 fulfillment verdict persistence seed"
```

Commit body should mention:

- 14-verdict lookup table and attribute matrix.
- Append-friendly `profit_classifications`.
- Transition rules seed.
- Deterministic audit CSV seed generator with PENDING drift validation.
- Inactive-client re-emergence scan.
- No V0.6.B.2 UI/audit views included.

- [ ] **Step 3: Push**

Run:

```bash
git push
```

- [ ] **Step 4: Final report**

Report:

- Commit hash.
- Pytest result.
- Live seed row count and verdict distribution.
- Re-emergence scan result.

Then V0.6.B.1 is shipped and V0.6.B.2 planning can begin.

## Self-Review Checklist

- [ ] Migration `023` creates and seeds lookup rows before `024` references them.
- [ ] The seed generator validates against all 14 canonical verdicts and fails unknown values.
- [ ] `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT` require the hard-gate inspection before generator work.
- [ ] The generated seed preserves `source_verdict_raw` and deterministic `source_audit_row_hash`.
- [ ] `025a` is limited to re-emergence scan data-layer behavior and does not create B.2 audit views.
- [ ] Plan does not touch V0.6.B.2 UI/API, V0.6.C orchestration, V0.6.D SLA, or unresolved service alias seeding.
