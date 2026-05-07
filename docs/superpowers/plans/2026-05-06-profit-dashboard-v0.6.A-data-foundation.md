# Profit Dashboard V0.6.A Data Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the V0.5.x static/snapshot foundations with live source-of-truth data needed for V0.6 verdict classification: FC tags/groups, Anchor agreement status, QBO product metadata, canonical service aliases, task-delivery signals, and service-coverage diagnostics.

**Architecture:** V0.6.A is a data-foundation slice only. It adds migrations `020`-`022`, extends Workflow 17 to capture FC tags, and creates read-only diagnostic views that V0.6.B can consume. It deliberately does not create verdict tables, classification seed migrations, pipeline run tables, or SLA UI; those land in V0.6.B/C/D after live tag/status/canonical service data is trusted.

**Tech Stack:** Supabase Postgres migrations/views/functions, n8n Workflow 17 JSON, FastAPI-neutral SQL surfaces, Python `pytest` static coverage, existing VPS deploy with `psql`, existing n8n import/execute flow.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: locked V0.6 spec.
- `docs/superpowers/backlog/v0.6-sprint-backlog.md`: examples and operational requirements.
- `docs/data-references/client-staff-assignments.xlsx`: transitional FC tag/group/staff snapshot, used only for test fixtures and validation examples.
- `docs/data-references/anchor services.csv`: FC service tag reference already seeded into `profit_service_recognition_rules.fc_tag`.
- `/tmp/unresolved_service_names_20260504.csv`: alias-planning input only; do not seed aliases from it without Orlando review.
- `n8n/workflows/profit-17-financial-cents-sync.json`: FC sync workflow to extend.
- `supabase/sql/006_profit_financial_cents_sync.sql`: current FC clients/projects/tasks schema.
- `supabase/sql/018_profit_service_recognition_rules_crosswalk.sql`: existing service `fc_tag`, QBO product, and tag warning precedent.

## Scope

In scope:

- Migration `020_profit_name_normalization_and_fc_tags.sql`.
- Migration `021_profit_anchor_agreement_status_and_qbo_product_sync.sql`.
- Migration `022_profit_canonical_service_aliases.sql`.
- Workflow 17 extension to capture FC tag arrays from `client.raw.groups`.
- Workflow 05 modification to remove the `status=active` filter, sync API-visible `active` and `terminated` agreements, and mark rows missing from a full sync as `stale`.
- New QBO product sync workflow to populate `profit_qbo_product_services` from the QBO Item/Product API.
- Near-duplicate group detection view using required `pg_trgm` similarity.
- Service-delivery vs. admin task classifier view.
- Anchor service vs. FC project coverage detection view.
- Documentation updates for FC sync, recognition data contracts, and data-reference transition.
- Tests for SQL shape, workflow field capture, and generator/static data expectations.

Out of scope:

- Migrations `023`-`027`.
- `profit_classification_verdicts` or `profit_classifications`.
- Audit CSV seed migration.
- Leak/audit dashboard UI.
- Pipeline run orchestration or cron.
- SLA dashboard UI.
- Anchor service API sync workflow; the static `anchor services.csv` crosswalk remains in use after V0.6.A.
- Project-level FC tag capture in V0.6.A; project workflow status tags are deferred to V0.6.D where they become useful for SLA work.
- Task-level FC tag capture; FC does not expose task tags via the current completed-task endpoint, so this is deferred indefinitely pending alternate endpoint discovery.
- Manual alias mapping from `/tmp/unresolved_service_names_20260504.csv`.
- Automated Anchor agreement creation or FC project creation.

## Migration And Deploy Checkpoints

Each migration has its own checkpoint:

1. **Migration 020 checkpoint**
   - Apply locally/test statically.
   - Apply to live Supabase.
   - Verify parenthetical normalization with Kar Kraft examples.
   - Verify FC tag/group tables exist empty before Workflow 17 is updated.

2. **Workflow 17 checkpoint**
   - Import updated workflow.
   - Run live FC sync once.
   - Verify FC tag rows load from `client.raw.groups`.
   - Verify project/task tag tables remain intentionally empty in V0.6.A.
   - Verify no regressions to client/project/task row counts.

3. **Migration 021 checkpoint**
   - Apply to live Supabase.
   - Verify agreement status columns exist.
   - Verify `profit_qbo_product_services` exists and is empty before Workflow 28 runs.

4. **Workflow 05 checkpoint**
   - Import updated Anchor agreement sync workflow.
   - Run live once.
   - Verify agreement status distribution: `active`, `terminated`, and any `stale` rows.

5. **Migration 022 checkpoint**
   - Apply to live Supabase.
   - Run Workflow 11/15 as needed to refresh revenue events.
   - Verify `canonical_service_name` population counts: exact, prefix, alias, unresolved.
   - Verify unresolved raw service names remain visible, not blocked.

Stop after each checkpoint and report counts before proceeding to the next migration.

## Files

Create:

- `supabase/sql/020_profit_name_normalization_and_fc_tags.sql`
- `supabase/sql/021_profit_anchor_agreement_status_and_qbo_product_sync.sql`
- `supabase/sql/022_profit_canonical_service_aliases.sql`
- `n8n/workflows/profit-28-qbo-product-sync.json`
- `tests/test_v06a_data_foundation_sql.py`
- `tests/test_fc_tag_sync.py`
- `tests/test_service_alias_resolution.py`

Modify:

- `n8n/workflows/profit-17-financial-cents-sync.json`
- `n8n/workflows/profit-05-anchor-agreements-sync.json`
- `tests/test_n8n_workflows.py`
- `tests/test_financial_cents_sql.py`
- `tests/test_revenue_classification.py`
- `docs/data-contracts/financial-cents-sync.md`
- `docs/data-contracts/recognition-triggers.md`
- `docs/data-contracts/revenue-events.md`
- `docs/data-references/README.md`
- `docs/tech-debt.md`

Do not modify in V0.6.A:

- `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`
- `supabase/sql/023_*`
- `supabase/sql/024_*`
- `supabase/sql/025_*`
- `supabase/sql/026_*`
- `supabase/sql/027_*`

## Task 1: SQL Tests For Migration 020

**Files:**
- Create `tests/test_v06a_data_foundation_sql.py`
- Create later `supabase/sql/020_profit_name_normalization_and_fc_tags.sql`

- [ ] **Step 1: Write failing migration-020 shape tests**

Add:

```python
from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class V06ADataFoundationSqlTests(unittest.TestCase):
    def test_migration_020_updates_name_normalization_and_fc_tag_tables(self) -> None:
        sql = (ROOT / "supabase/sql/020_profit_name_normalization_and_fc_tags.sql").read_text(encoding="utf-8").lower()

        self.assertIn("create or replace function profit_normalize_client_name", sql)
        self.assertIn("regexp_replace", sql)
        self.assertIn("\\\\s*\\\\([^)]*\\\\)", sql)
        self.assertIn("create table if not exists profit_fc_client_tags", sql)
        self.assertIn("create table if not exists profit_fc_project_tags", sql)
        self.assertIn("create table if not exists profit_fc_task_tags", sql)
        self.assertIn("tag_type text not null check", sql)
        self.assertIn("'service'", sql)
        self.assertIn("'group'", sql)
        self.assertIn("'staff'", sql)
        self.assertIn("'unknown'", sql)
        self.assertIn("primary key (fc_client_id, tag_name)", sql)
        self.assertIn("primary key (fc_project_id, tag_name)", sql)
        self.assertIn("primary key (fc_task_id, tag_name)", sql)
```

- [ ] **Step 2: Write failing group and task classifier tests**

Add:

```python
    def test_migration_020_defines_groups_near_duplicates_and_task_kind_view(self) -> None:
        sql = (ROOT / "supabase/sql/020_profit_name_normalization_and_fc_tags.sql").read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_client_groups", sql)
        self.assertIn("create table if not exists profit_client_group_members", sql)
        self.assertIn("create or replace view profit_fc_group_name_near_duplicates", sql)
        self.assertIn("create or replace function profit_refresh_client_groups", sql)
        self.assertIn("corey monaghan", sql)
        self.assertIn("corey monanghan", sql)
        self.assertIn("pg_trgm", sql)
        self.assertIn("create or replace view profit_fc_task_delivery_classification", sql)
        self.assertIn("'service_delivery'", sql)
        self.assertIn("'admin_onboarding'", sql)
        self.assertIn("'unknown'", sql)
        self.assertIn("close the books", sql)
        self.assertIn("file the tax return", sql)
        self.assertIn("onboarding", sql)
```

- [ ] **Step 3: Run tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py -q
```

Expected: fail because migration `020` does not exist.

## Task 2: Implement Migration 020

**Files:**
- Create `supabase/sql/020_profit_name_normalization_and_fc_tags.sql`
- Test `tests/test_v06a_data_foundation_sql.py`

- [ ] **Step 1: Create migration 020**

Migration must:

- Replace `profit_normalize_client_name` with parenthetical stripping before legal suffix/punctuation stripping.
- Include `create extension if not exists pg_trgm;` near the top of the file.
- Create `profit_fc_client_tags`, `profit_fc_project_tags`, and `profit_fc_task_tags`.
- Create indexes by `tag_name`, `normalized_tag`, and `tag_type`.
- Create `profit_client_groups` and `profit_client_group_members`.
- Create `profit_fc_group_name_near_duplicates`.
- Use `similarity(...) >= 0.82` unconditionally in `profit_fc_group_name_near_duplicates`; `pg_trgm` is required for typo detection.
- Create `profit_refresh_client_groups()` as an explicit RPC function. It must:
  - Insert new `profit_client_groups` rows for any `profit_fc_client_tags.tag_name` where `tag_type = 'group'` and the group does not already exist.
  - Insert `profit_client_group_members` rows for current `(group, fc_client_id)` pairs.
  - Set memberships `active = false` only when a full client tag sync flag is passed or otherwise persisted by the workflow; partial syncs must not deactivate memberships.
- Create `profit_fc_task_delivery_classification` with `task_kind in ('service_delivery', 'admin_onboarding', 'unknown')`.

Minimum task classifier behavior:

- `service_delivery`: close the books, monthly bookkeeping, file the tax return, tax extension filed, payroll processed, sales tax filed, advisory delivered/reviewed.
- `admin_onboarding`: onboarding, setup, data request, engagement letter, client setup, internal admin.
- `unknown`: everything else.

- [ ] **Step 2: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py -q
```

Expected: pass migration-020 tests.

- [ ] **Step 3: Add normalization regression tests**

Add static SQL assertions for examples:

```python
    def test_migration_020_documents_parenthetical_normalization_examples(self) -> None:
        sql = (ROOT / "supabase/sql/020_profit_name_normalization_and_fc_tags.sql").read_text(encoding="utf-8")

        self.assertIn("Kar Kraft Auto Repair LLC (TempleTerrace)", sql)
        self.assertIn("Kar Kraft Services LLC (Zephyrhills)", sql)
        self.assertIn("Samdee Enterprises Automotive Group LLC (SpringHill)", sql)
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py -q
```

Expected: pass.

- [ ] **Step 5: Stop for Migration 020 deploy checkpoint**

Before proceeding to Workflow 17, apply migration 020 to live Supabase and verify:

```sql
select profit_normalize_client_name('Kar Kraft Services LLC (Zephyrhills)') =
       profit_normalize_client_name('Kar Kraft Services LLC') as kar_kraft_matches;

select count(*) from profit_fc_client_tags;
select count(*) from profit_client_groups;
select * from profit_fc_group_name_near_duplicates limit 20;
```

Report results. Do not continue if normalization fails.

## Task 3: Workflow 17 FC Tag Capture Tests

**Files:**
- Modify `tests/test_n8n_workflows.py`
- Modify later `n8n/workflows/profit-17-financial-cents-sync.json`

- [ ] **Step 1: Add failing Workflow 17 tag tests**

Extend the Financial Cents workflow test:

```python
def test_financial_cents_sync_captures_fc_tags(self) -> None:
    workflow_path = ROOT / "n8n/workflows/profit-17-financial-cents-sync.json"
    workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
    serialized = json.dumps(workflow)

    self.assertIn(
        "profit_fc_client_tags?on_conflict=fc_client_id,tag_name",
        serialized,
    )
    self.assertIn(
        "profit_service_recognition_rules?select=service_name,fc_tag",
        serialized,
    )
    self.assertIn("'service'", serialized)
    self.assertIn("'group'", serialized)
    self.assertIn(
        "/rest/v1/rpc/profit_refresh_client_groups",
        serialized,
    )
```

- [ ] **Step 2: Run test and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py::N8nWorkflowTests::test_financial_cents_sync_captures_fc_tags -q
```

Expected: fail because Workflow 17 does not upsert tag tables yet.

## Task 3.5: Quarterly Compliance Recognition Seed And Unmatched-Tag Diagnostic

**Files:**
- Modify `tests/test_v06a_data_foundation_sql.py`
- Create `supabase/sql/020a_profit_seed_form_941_recognition_rule.sql`
- Modify `docs/data-contracts/recognition-triggers.md`
- Modify `docs/tech-debt.md`

- [ ] **Step 1: Add failing SQL tests**

Add coverage that migration `020a_profit_seed_form_941_recognition_rule.sql`:

- exists
- references `form_941_quarterly`
- references `S 941`
- sets `macro_service_type = payroll`
- sets `default_sla_day = 30`
- uses `on conflict (service_name) do update set`
- creates `profit_unmatched_s_prefixed_tags`

- [ ] **Step 2: Run focused tests and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py -q
```

Expected: fail because migration `020a` does not exist yet.

- [ ] **Step 3: Implement migration 020a**

Create `supabase/sql/020a_profit_seed_form_941_recognition_rule.sql`.

The migration must be idempotent and seed:

```text
service_name       = form_941_quarterly
fc_tag             = S 941
macro_service_type = payroll
default_sla_day    = 30
```

Use sensible defaults for other required recognition-rule columns and document assumptions in a migration comment. The expected defaults are:

- `recognition_pattern = quarterly_recurring`
- `service_period_rule = previous_quarter`
- `service_tier = null`
- `form_type_pattern = null`
- `source = manual_seed`

Also create:

```sql
create or replace view profit_unmatched_s_prefixed_tags as
select
  ct.tag_name,
  count(*) as occurrences,
  count(distinct ct.fc_client_id) as distinct_clients,
  min(ct.synced_at) as first_seen,
  max(ct.synced_at) as last_seen
from profit_fc_client_tags ct
where ct.tag_name like 'S %'
  and ct.tag_type <> 'service'
group by ct.tag_name
order by occurrences desc;
```

This view should be empty after Workflow 17 and migration `020a` deploy correctly. Any non-empty result catches the next service-tag taxonomy gap before it pollutes group classification.

- [ ] **Step 4: Run focused tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py -q
```

Expected: pass.

- [ ] **Step 5: Stop for migration 020a deploy checkpoint**

Apply migration `020a` to live Supabase and verify:

```sql
select service_name, fc_tag, macro_service_type, default_sla_day
from profit_service_recognition_rules
where service_name = 'form_941_quarterly';

select count(*) from profit_unmatched_s_prefixed_tags;
```

The first query must return one row with `form_941_quarterly`, `S 941`, `payroll`, and `30`. The second query must return `0` before Workflow 17 runs because client tags have not loaded yet.

Report results and wait for Orlando approval before resuming Task 4.

## Task 4: Extend Workflow 17 For FC Tags

**Files:**
- Modify `n8n/workflows/profit-17-financial-cents-sync.json`
- Modify `docs/data-contracts/financial-cents-sync.md`
- Test `tests/test_n8n_workflows.py`

- [ ] **Step 1: Inspect live FC payload shape before coding**

Run the existing inspect workflow or a scoped FC API request to confirm where tags appear in client/project/task payloads. The 2026-05-06 live inspection showed:

- `client.raw.groups` carries service tags and group tags bundled together. This is the primary V0.6.A source.
- `project.raw.tags` carries workflow status tags such as `Waiting on Client`, `In Preparation`, and `Ready to Submit`; these are deferred to V0.6.D SLA work.
- `task.raw.tags` is absent from the current completed-task endpoint and is deferred indefinitely.

Stop if a later FC payload inspection contradicts this shape before implementing.

- [ ] **Step 1.5: Sample sweep before mapping logic is finalized**

Pull `client.raw.groups` for 20-30 diverse FC clients across different sizes, FC active/inactive states, and FC service mixes.

Report distinct patterns observed:

- service tags (`S`-prefixed)
- group tags
- empty group arrays
- unparseable entries, if any

If anything other than service/group/empty appears, such as staff names, freeform notes, or custom labels, stop and bring the patterns back to Orlando before implementing mapping logic. Do not code around an unexpected pattern.

- [ ] **Step 2: Add service tag lookup node**

Add a Supabase GET node before tag mapping:

```text
GET /rest/v1/profit_service_recognition_rules?select=service_name,fc_tag&fc_tag=not.is.null
```

Use it to classify entries from `client.raw.groups`:

- exact `fc_tag` match → `service`
- any other non-empty entry → `group`
- blank/null → skip
- never `staff` in V0.6.A; staff sync is deferred
- `unknown` is reserved for genuinely unclassifiable entries that the sample sweep surfaces

- [ ] **Step 3: Map client tag rows**

Add JS mapping nodes that emit only `profit_fc_client_tags` rows shaped as:

```json
{
  "fc_client_id": 123,
  "tag_name": "S BOOKP",
  "tag_type": "service",
  "normalized_tag": "sbookp",
  "synced_at": "2026-05-06T00:00:00.000Z"
}
```

Do not emit project or task tag rows in V0.6.A.

- [ ] **Step 4: Upsert client tag rows**

Add one Supabase POST node:

- `profit_fc_client_tags?on_conflict=fc_client_id,tag_name`

Use `Prefer: resolution=merge-duplicates`.

- [ ] **Step 5: Refresh group tables from client tags via explicit RPC**

After all tag upserts complete, Workflow 17 must call the migration-020 RPC function via Supabase RPC:

```text
POST /rest/v1/rpc/profit_refresh_client_groups
```

Pass a full-sync flag only when all FC client pages completed successfully. The RPC owns group/member writes:

- upserts one `profit_client_groups` row per group tag.
- upserts one `profit_client_group_members` row per client/group tag.
- marks missing memberships inactive only when the full-sync flag is true.

Do not use triggers for group refresh. Keeping the refresh as an explicit RPC makes Workflow 17's control flow auditable and prevents hidden coupling during sync debugging.

- [ ] **Step 6: Update docs**

Update `docs/data-contracts/financial-cents-sync.md`:

- Workflow 17 now captures FC tags.
- Workflow 17 captures client-level FC tags only.
- Service vs. group classification reads `profit_service_recognition_rules.fc_tag`.
- FC tags are canonical for client-level service and group assignment.
- `client-staff-assignments.xlsx` is transitional only.
- Project-level workflow status tags are deferred to V0.6.D SLA work.
- Task-level tags are not exposed via the current FC endpoint and are deferred indefinitely.
- Tag tables and group tables are V0.6.A inputs for V0.6.B leak classification and V0.6.D SLA.

- [ ] **Step 7: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py tests/test_financial_cents_sql.py -q
```

Expected: pass.

- [ ] **Step 8: Stop for Workflow 17 deploy checkpoint**

Import Workflow 17, run it once live, and report:

```sql
select count(*) from profit_fc_client_tags;
select tag_type, count(*) from profit_fc_client_tags group by 1 order by 2 desc;
select count(*) from profit_fc_project_tags;  -- expected 0
select count(*) from profit_fc_task_tags;     -- expected 0
select count(*) from profit_client_groups;
select count(*) from profit_client_group_members where active = true;
select * from profit_fc_group_name_near_duplicates limit 20;
```

Zero rows in `profit_fc_project_tags` and `profit_fc_task_tags` is the expected green state in V0.6.A, not a warning. Do not continue if client tag counts are zero and FC payload inspection showed `client.raw.groups` should exist.

## Task 4.5: Inspect Anchor Agreement Status Payload

**Files:**
- Update Task 5 and Task 6 implementation notes before coding migration 021

- [x] **Step 1: Inspect Anchor agreement payload**

2026-05-06 live inspection result:

- Existing synced `profit_anchor_agreements.raw` rows contain `status` but no `qbo`, `quickbooks`, `paymentSynced`, `displayStatus`, or `effectiveStatus` field.
- Anchor's agreements API exposes only `active` and `terminated` as useful status values.
- No-filter `/agreements?limit=50` returned 49 agreements: 37 active and 12 terminated.
- Filtered requests for `status=draft`, `status=sent`, `status=voided`, `status=signed`, `status=expired`, `status=archived`, and `status=cancelled` did not return those UI states; they returned mixed active+terminated results.
- `limit=50` is accepted; `limit=100`/`500` can fail validation.

Use Anchor's `status` field as `display_status` in V0.6.A. DRAFT/SENT verdicts remain manual-classification-only in V0.6.B because those states are not API-visible.

- [x] **Step 2: Decide migration-021 test expectation**

Migration 021 tests and implementation must reflect the inspected payload shape:

- Migration 021 tests must not assert `paymentsynced`.
- Migration 021 must not add `effective_status`; Anchor's `status` is the canonical API-visible state.
- Payment-synced behavior remains invoice-specific.
- Agreement-to-invoice payment reconciliation is deferred to V0.6.C pipeline/run-log views.

This inspection gate prevents V0.6.A from smuggling invoice-state semantics into agreement-status tables without source payload evidence.

## Task 5: SQL Tests For Migration 021

**Files:**
- Modify `tests/test_v06a_data_foundation_sql.py`
- Create later `supabase/sql/021_profit_anchor_agreement_status_and_qbo_product_sync.sql`

- [ ] **Step 1: Add failing Anchor/QBO status tests**

Add:

```python
    def test_migration_021_adds_anchor_agreement_status_and_qbo_product_config(self) -> None:
        sql = (ROOT / "supabase/sql/021_profit_anchor_agreement_status_and_qbo_product_sync.sql").read_text(encoding="utf-8").lower()

        # 2026-05-06 Anchor API inspection found agreement.status exposes
        # only active/terminated. No agreement-level paymentSynced or
        # effectiveStatus field exists.
        self.assertIn("alter table profit_anchor_agreements", sql)
        self.assertIn("add column if not exists display_status text", sql)
        self.assertIn("add column if not exists terminated_at timestamptz", sql)
        self.assertIn("add column if not exists status_synced_at timestamptz", sql)
        self.assertIn("create table if not exists profit_qbo_product_services", sql)
        self.assertIn("qbo_product_id text primary key", sql)
        self.assertIn("qbo_category_path text", sql)
        self.assertIn("source text not null default 'qbo_api_sync'", sql)
        self.assertIn("'active'", sql)
        self.assertIn("'terminated'", sql)
```

- [ ] **Step 2: Run and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py -q
```

Expected: fail because migration `021` does not exist.

## Task 6: Implement Migration 021

**Files:**
- Create `supabase/sql/021_profit_anchor_agreement_status_and_qbo_product_sync.sql`
- Modify `docs/data-contracts/recognition-triggers.md`
- Modify `docs/data-references/README.md`
- Test `tests/test_v06a_data_foundation_sql.py`

- [ ] **Step 1: Create migration 021**

Migration must:

- Add agreement status fields to `profit_anchor_agreements`:
  - `display_status text` with a check constraint allowing `active`, `terminated`, `stale`, or null pending sync.
  - `terminated_at timestamptz` null.
  - `status_synced_at timestamptz` null.
- Add an index on `display_status` for fast filtering.
- Do not add `effective_status`; Anchor's `status` is canonical for API-visible states.
- Do not add agreement-level `paymentSynced`; Task 4.5 found no agreement-level payment-synced field. Agreement-to-invoice payment reconciliation is deferred to V0.6.C pipeline/run-log views.
- Create `profit_qbo_product_services`:
  - `qbo_product_id text primary key`
  - `qbo_product_name text not null`
  - `qbo_category_path text`
  - `active boolean`
  - `raw jsonb`
  - `source text not null default 'qbo_api_sync'`
  - `last_synced_at timestamptz not null default now()`
  - timestamps.
- Create indexes on `qbo_product_name` and `qbo_category_path`.

- [ ] **Step 2: Update docs**

Update:

- `docs/data-references/README.md`: QBO CSV becomes historical once live sync populates `profit_qbo_product_services`.
- `docs/data-contracts/recognition-triggers.md`: V0.6.A source-of-truth note for QBO products and Anchor agreement status.

- [ ] **Step 3: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py tests/test_data_references_docs.py -q
```

Expected: pass.

- [ ] **Step 4: Stop for Migration 021 deploy checkpoint**

Apply migration 021 and run the relevant sync/import path. Report:

```sql
select display_status, count(*)
from profit_anchor_agreements
group by 1
order by 2 desc;

select count(*) from profit_qbo_product_services;
```

`profit_qbo_product_services` is expected to be 0 until Task 7 imports and runs Workflow 28.

## Task 6.5: Workflow 05 Broaden Anchor Agreement Sync

**Files:**
- Modify `n8n/workflows/profit-05-anchor-agreements-sync.json`
- Modify `tests/test_n8n_workflows.py`
- Modify `docs/data-contracts/anchor-sync.md`

- [ ] **Step 1: Add failing Workflow 05 status tests**

Add a test asserting Workflow 05 fetches the API-visible agreement set without the `status=active` filter and writes `display_status`:

```python
def test_anchor_agreements_sync_fetches_all_api_visible_statuses(self) -> None:
    workflow_path = ROOT / "n8n/workflows/profit-05-anchor-agreements-sync.json"
    workflow = workflow_path.read_text(encoding="utf-8")

    self.assertNotIn("status=active", workflow)
    self.assertIn("display_status", workflow)
    self.assertIn("terminated_at", workflow)
    self.assertIn("status_synced_at", workflow)
```

- [ ] **Step 2: Run and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py -q
```

Expected: fail because Workflow 05 currently fetches `status=active` and does not map status columns.

- [ ] **Step 3: Modify Workflow 05**

Update `n8n/workflows/profit-05-anchor-agreements-sync.json`:

- Remove the `status=active` query parameter. Use the no-status-filter `/agreements` request shape that live inspection confirmed returns API-visible `active` and `terminated` agreements.
- Keep Anchor's accepted pagination limit; inspection showed `limit=50` works and `limit=100` can fail validation.
- Map Anchor's `status` field to `display_status`.
- Set `terminated_at = lastUpdatedAt` when `status = 'terminated'`, otherwise null.
- Set `status_synced_at = run_started_at` on every upserted row.

- [ ] **Step 4: Add stale-row reconciliation**

At the start of each Workflow 05 run, capture `run_started_at`. After all agreement upserts, mark any existing agreement whose `status_synced_at` is older than `run_started_at` as `display_status = 'stale'`.

Also include these stale rows in the workflow summary for orchestrator review. Stale rows represent agreements that were previously present locally but did not appear in the current Anchor API-visible result set.

- [ ] **Step 5: Run focused tests and verify green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py tests/test_v06a_data_foundation_sql.py -q
```

Expected: pass.

- [ ] **Step 6: Stop for Workflow 05 deploy checkpoint**

Import updated Workflow 05, run live once, and report:

```sql
select display_status, count(*)
from profit_anchor_agreements
group by 1
order by 2 desc;
```

Expected: roughly `active = 37`, `terminated = 12`, and `stale = 3`. The stale rows are the previously active rows that no longer appear in Anchor's current API-visible agreement list.

## Task 7: QBO Product Sync Workflow

**Files:**
- Modify `tests/test_n8n_workflows.py`
- Create `n8n/workflows/profit-28-qbo-product-sync.json`
- Modify `docs/data-references/README.md`

- [ ] **Step 1: Write failing QBO product workflow test**

Add:

```python
def test_qbo_product_sync_loads_items_into_product_config(self) -> None:
    workflow_path = ROOT / "n8n/workflows/profit-28-qbo-product-sync.json"
    workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
    serialized = json.dumps(workflow)

    self.assertIn("Profit - 28 QBO Product Sync", serialized)
    self.assertIn("Item", serialized)
    self.assertIn("profit_qbo_product_services?on_conflict=qbo_product_id", serialized)
    self.assertIn("qbo_product_id", serialized)
    self.assertIn("qbo_product_name", serialized)
    self.assertIn("qbo_category_path", serialized)
    self.assertIn("qbo_api_sync", serialized)
    self.assertIn("last_synced_at", serialized)
```

- [ ] **Step 2: Run and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py::N8nWorkflowTests::test_qbo_product_sync_loads_items_into_product_config -q
```

Expected: fail because the workflow file does not exist.

- [ ] **Step 3: Create QBO product sync workflow**

Create `n8n/workflows/profit-28-qbo-product-sync.json`.

Workflow behavior:

- Fetch QBO Item/Product-Service records using the existing QBO credential pattern from `Profit - 24 QBO Collection Loader`.
- Page through all active and inactive product/service items if QBO supports both; otherwise document the endpoint limitation in the workflow summary node.
- Map each QBO item to:
  - `qbo_product_id`
  - `qbo_product_name`
  - `qbo_category_path`
  - `active`
  - `raw`
  - `source = 'qbo_api_sync'`
  - `last_synced_at`
- Upsert to `profit_qbo_product_services?on_conflict=qbo_product_id`.
- Return a summary with fetched count, upserted count, categories, and sample rows.

Do not rewrite `profit_service_recognition_rules` from QBO in V0.6.A. This workflow only creates the live QBO reference table; crosswalk reconciliation comes through views and V0.6.B/C run logs.

- [ ] **Step 4: Update docs**

Update `docs/data-references/README.md`:

- `qbo-product-services.csv` is now a historical fallback once `Profit - 28 QBO Product Sync` is live.
- Future seed regeneration from CSV is only for local/offline recovery, not the normal source of truth.

- [ ] **Step 5: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_n8n_workflows.py tests/test_data_references_docs.py -q
```

Expected: pass.

- [ ] **Step 6: Stop for QBO product sync checkpoint**

Import and run `Profit - 28 QBO Product Sync`. Report:

```sql
select count(*) from profit_qbo_product_services;
select qbo_category_path, count(*)
from profit_qbo_product_services
group by 1
order by 2 desc;

select qbo_product_name, active, qbo_category_path
from profit_qbo_product_services
order by qbo_product_name
limit 20;
```

Do not proceed to migration 022 if QBO auth or product endpoint access fails; report the exact error and keep the CSV crosswalk as the fallback until Orlando decides.

## Task 8: SQL Tests For Migration 022

**Files:**
- Create `tests/test_service_alias_resolution.py`
- Create later `supabase/sql/022_profit_canonical_service_aliases.sql`

- [ ] **Step 1: Add failing canonical service tests**

Create:

```python
from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ServiceAliasResolutionTests(unittest.TestCase):
    def test_migration_022_preserves_raw_service_and_adds_canonical_resolution(self) -> None:
        sql = (ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql").read_text(encoding="utf-8").lower()

        self.assertIn("create table if not exists profit_anchor_service_aliases", sql)
        self.assertIn("raw_service_name text primary key", sql)
        self.assertIn("canonical_service_name text not null references profit_service_recognition_rules(service_name)", sql)
        self.assertIn("alter table profit_revenue_events", sql)
        self.assertIn("add column if not exists canonical_service_name text", sql)
        self.assertIn("references profit_service_recognition_rules(service_name)", sql)
        self.assertIn("create or replace function profit_resolve_canonical_service_name", sql)
        self.assertIn("exact", sql)
        self.assertIn("manual_alias", sql)
        self.assertIn("prefix", sql)
        self.assertIn("create or replace view profit_unresolved_service_names", sql)
```

- [ ] **Step 2: Add failing unresolved examples test**

Add:

```python
    def test_migration_022_documents_unresolved_real_examples_without_guessing_aliases(self) -> None:
        sql = (ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql").read_text(encoding="utf-8")

        self.assertIn("Bookkeeping Services", sql)
        self.assertIn("1120 Plus - Proration for monthly billing", sql)
        self.assertIn("1040 Plus (Ken & Nancy Wong)", sql)
        self.assertIn("do not guess canonical mappings", sql.lower())
        self.assertNotIn("insert into profit_anchor_service_aliases", sql.lower())
```

- [ ] **Step 3: Run and verify red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_service_alias_resolution.py -q
```

Expected: fail because migration `022` does not exist.

## Task 9: Implement Migration 022

**Files:**
- Create `supabase/sql/022_profit_canonical_service_aliases.sql`
- Modify `docs/data-contracts/revenue-events.md`
- Modify `docs/data-contracts/recognition-triggers.md`
- Test `tests/test_service_alias_resolution.py`

- [ ] **Step 1: Create migration 022**

Migration must:

- Create `profit_anchor_service_aliases`.
- Add nullable `profit_revenue_events.canonical_service_name` FK to `profit_service_recognition_rules(service_name)`.
- Create indexes for raw/canonical service lookups.
- Create `profit_resolve_canonical_service_name(raw_service_name text)` with resolution order:
  1. exact service-name match
  2. alias lookup
  3. prefix match before `-`, `(`, `,`, or line end
  4. null
- Backfill `profit_revenue_events.canonical_service_name` where resolution is non-null.
- Create `profit_unresolved_service_names` view using raw `service_name` and null `canonical_service_name`.
- Include comments listing real unresolved examples from `/tmp/unresolved_service_names_20260504.csv`.
- Do not insert guessed alias rows.

- [ ] **Step 2: Update docs**

Update:

- `docs/data-contracts/revenue-events.md`: `service_name` is raw Anchor operational text; `canonical_service_name` is the FK-safe taxonomy key.
- `docs/data-contracts/recognition-triggers.md`: joins to service rules should use `canonical_service_name` when present.

- [ ] **Step 3: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_service_alias_resolution.py tests/test_revenue_classification.py -q
```

Expected: pass.

- [ ] **Step 4: Stop for Migration 022 deploy checkpoint**

Apply migration 022 and report:

```sql
select
  count(*) filter (where canonical_service_name is not null) as canonical_resolved,
  count(*) filter (where service_name is not null and canonical_service_name is null) as canonical_unresolved
from profit_revenue_events;

select *
from profit_unresolved_service_names
order by event_count desc
limit 30;
```

Do not continue if the migration reintroduces FK failures on raw `service_name`.

## Task 10: Anchor Service Vs. FC Project Coverage Detection

**Files:**
- Modify `tests/test_v06a_data_foundation_sql.py`
- Modify `supabase/sql/022_profit_canonical_service_aliases.sql`

- [ ] **Step 1: Write failing coverage-view test**

Add:

```python
    def test_v06a_defines_anchor_service_vs_fc_project_coverage_view(self) -> None:
        sql = (ROOT / "supabase/sql/022_profit_canonical_service_aliases.sql").read_text(encoding="utf-8").lower()

        self.assertIn("create or replace view profit_anchor_service_fc_project_coverage", sql)
        self.assertIn("anchor_relationship_id", sql)
        self.assertIn("fc_client_id", sql)
        self.assertIn("canonical_service_name", sql)
        self.assertIn("fc_tag", sql)
        self.assertIn("coverage_status", sql)
        self.assertIn("'covered'", sql)
        self.assertIn("'missing_fc_project'", sql)
        self.assertIn("'unknown'", sql)
```

- [ ] **Step 2: Implement view in migration 022**

Add the view to migration 022 after `profit_resolve_canonical_service_name` is defined and after `canonical_service_name` backfill logic exists.

The view should compare:

- Anchor agreement/revenue service coverage by `anchor_relationship_id + canonical_service_name`.
- FC project/tag coverage by matched FC client/group and service `fc_tag`.

Output columns:

- `anchor_relationship_id`
- `anchor_client_business_name`
- `fc_client_id`
- `fc_client_name`
- `canonical_service_name`
- `fc_tag`
- `macro_service_type`
- `coverage_status`
- `latest_anchor_invoice_date`
- `latest_fc_project_updated_at`

Coverage statuses:

- `covered`: Anchor service has matching FC project/tag coverage.
- `missing_fc_project`: Anchor service exists but no FC project/tag coverage found.
- `unknown`: service cannot be canonicalized or FC matching is missing.

- [ ] **Step 3: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_v06a_data_foundation_sql.py -q
```

Expected: pass.

## Task 11: Full V0.6.A Test Pass

**Files:** all V0.6.A touched files.

- [ ] **Step 1: Run targeted suite**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest \
  tests/test_v06a_data_foundation_sql.py \
  tests/test_fc_tag_sync.py \
  tests/test_service_alias_resolution.py \
  tests/test_financial_cents_sql.py \
  tests/test_n8n_workflows.py \
  tests/test_revenue_classification.py \
  tests/test_data_references_docs.py \
  -q
```

Expected: pass.

- [ ] **Step 2: Run full suite**

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

Expected:

- V0.6.A files only.
- No `supabase/sql/023_*` through `027_*`.
- No edits to audit CSV classifications.

## Task 12: Live Deploy And Smoke Check

**Files:** no new files unless deploy notes need updating.

- [ ] **Step 1: Apply migrations in order**

Apply:

```bash
psql "$SUPABASE_DB_URL" -f supabase/sql/020_profit_name_normalization_and_fc_tags.sql
psql "$SUPABASE_DB_URL" -f supabase/sql/021_profit_anchor_agreement_status_and_qbo_product_sync.sql
psql "$SUPABASE_DB_URL" -f supabase/sql/022_profit_canonical_service_aliases.sql
```

- [ ] **Step 2: Import/update Workflow 17**

Import the updated `n8n/workflows/profit-17-financial-cents-sync.json`.

- [ ] **Step 3: Run Workflow 17**

Run live FC sync and report counts from the Workflow 17 checkpoint query.

- [ ] **Step 4: Run Anchor/QBO sync paths**

Run the updated Anchor agreement sync and the new `Profit - 28 QBO Product Sync`. Report counts from the Workflow 05, Migration 021, and QBO product sync checkpoint queries.

- [ ] **Step 5: Run revenue candidate/canonical refresh**

Run the existing revenue candidate path as needed and report counts from the Migration 022 checkpoint query.

- [ ] **Step 6: Stop for Orlando spot-check**

Report:

- FC tag counts by table and type.
- Group count and near-duplicate sample.
- Agreement `display_status` counts.
- QBO product counts by category.
- Canonical service resolved/unresolved counts.
- Anchor service vs. FC project coverage sample.

Wait for Orlando approval before committing.

## Task 13: Commit After Approval

**Files:** all approved V0.6.A files.

- [ ] **Step 1: Re-run full pytest**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Commit**

Commit message:

```text
Add V0.6.A data foundation for live tags and service resolution

Capture FC tags from Workflow 17, add live group/service tag tables,
strip parenthetical suffixes in client-name normalization, add Anchor
agreement status and QBO product sync foundations, and introduce
canonical service alias resolution for revenue events.

This is the data foundation for V0.6.B verdict classification; it does
not add verdict tables, classification seeds, pipeline runs, or SLA UI.
```

- [ ] **Step 3: Push**

Run:

```bash
git push
```

Stop after push and report commit hash, tests, and live checkpoint summary.
