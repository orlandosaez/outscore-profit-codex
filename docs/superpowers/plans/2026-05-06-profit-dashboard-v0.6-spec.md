# Profit Dashboard V0.6 Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:writing-plans before turning this spec into implementation plans, then use superpowers:subagent-driven-development or superpowers:executing-plans to implement each approved slice task-by-task. This document is the V0.6 product/architecture spec, not an implementation checklist.

**Goal:** Replace the one-shot fulfillment-leak audit and static service crosswalks with live source-of-truth sync, persistent verdict classification, operational run logs, and audit/SLA dashboard surfaces.

**Architecture:** V0.6 ships as four slices. V0.6.A builds the data foundation first: live upstream fields, FC tags, canonical service resolution, and normalization improvements. V0.6.B builds persistent verdict classification and the leak audit UI on top of that foundation, seeded from the completed 2026-05-04 audit CSV. V0.6.C adds recognition pipeline orchestration and run logs. V0.6.D adds SLA workload/status surfaces using the same FC tag and service-rule foundation.

**Tech Stack:** Supabase Postgres migrations/views/functions, n8n workflow JSON, FastAPI admin endpoints, React/Vite admin UI, Python CSV/XLSX seed-generation scripts, `pytest` static and service tests.

---

## Authoritative Inputs

- `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`: source of truth for manually classified V0.6.B seed verdicts.
- `docs/superpowers/backlog/v0.6-sprint-backlog.md`: captured V0.6 requirements and real examples.
- `docs/audits/2026-05-07-unresolved-service-names.csv`: raw Anchor service-name alias backlog captured after migration 022 canonical resolution.
- `docs/data-references/anchor services.csv`: static Anchor service snapshot; replaced by Anchor service API sync.
- `docs/data-references/qbo-product-services.csv`: static QBO product/service snapshot; replaced by QBO product API sync.
- `docs/data-references/client-staff-assignments.xlsx`: transitional FC tag/group/staff snapshot; replaced by live FC tag sync.

## Decisions

### 1. Final Sub-Slice Decomposition

V0.6 should remain split into A → B → C → D. The slices are strongly ordered because B/C/D depend on live tags, agreement status, and canonical service resolution from A.

- **V0.6.A — Data Foundation Layer**
  - Anchor agreement status sync.
  - FC client-level tag sync from `client.raw.groups`.
  - FC group/service parsing from client tags.
  - QBO product/service sync.
  - Canonical service alias resolution.
  - `profit_normalize_client_name` parenthetical stripping.
  - Near-duplicate FC group/tag detection.
  - Service-delivery vs. admin-task classification signals.
  - Anchor service coverage vs. FC project coverage detection.

- **V0.6.B — Verdict-Driven Leak Detection**
  - Verdict lookup and classification persistence.
  - Seed from completed audit CSV.
  - Refactored audit candidate query.
  - Auto-transition state machine.
  - Dedicated leak/audit dashboard UI.
  - Bulk classification workflow.
  - Re-evaluation queue and healthy-row suppression.

- **V0.6.C — Pipeline Orchestration**
  - `Profit - 26 Recognition Pipeline` chained workflow.
  - `profit_pipeline_runs` and step-level run log.
  - On-demand refresh button.
  - Ambiguous tax, unclassified service, stuck trigger, and due reclassification surfacing.
  - Sales tax/monthly close attestation only if A/B land cleanly; otherwise split to V0.6.5.

- **V0.6.D — SLA Management Dashboard**
  - Top-level SLA route driven by live FC tags and `profit_service_recognition_rules`.
  - Per-staff workload and per-client SLA status.
  - Breach detection and trend rollups.

**Rationale:** V0.6.A removes the biggest source of false positives: spreadsheet snapshots and raw-name matching. V0.6.B should not be built on stale tag/group data. V0.6.C can orchestrate only once the data and classification outputs are durable. V0.6.D depends on FC tags and SLA defaults, so it follows A and can run in parallel with late C only after tag sync is stable.

### 2. Migration Ordering

Use strictly ordered migrations after `019_relax_revenue_events_service_name_fk.sql`:

1. `020_profit_name_normalization_and_fc_tags.sql`
   - Update `profit_normalize_client_name` to remove parenthetical suffixes before stripping legal suffixes/punctuation.
   - Add FC tag storage tables.
   - Add group/service/staff parsed tables or views.

2. `021_profit_anchor_agreement_status_and_qbo_product_sync.sql`
   - Add Anchor agreement status/effective status fields.
   - Add QBO product config tables and source metadata.

3. `022_profit_canonical_service_aliases.sql`
   - Add `profit_anchor_service_aliases`.
   - Add `canonical_service_name` to `profit_revenue_events`.
   - Backfill canonical names with exact/prefix/alias resolution.

4. `023_profit_fulfillment_classification_verdicts.sql`
   - Add `profit_classification_verdicts`.
   - Add `profit_classifications`.
   - Add audit seed support columns and indexes.

5. `024_profit_fulfillment_classification_seed_20260504.sql`
   - Seed one classification row per audit CSV row.
   - Use a generated SQL file, not hand-authored row tuples.

6. `025_profit_fulfillment_audit_views.sql`
   - Add refactored candidate, signal, group billing, and re-evaluation views.

7. `026_profit_pipeline_runs.sql`
   - Add pipeline run and pipeline run step tables for V0.6.C.

8. `027_profit_sla_views.sql`
   - Add SLA status views for V0.6.D.

### 3. UI Surfaces

Use dedicated routes for new operational surfaces. Do not overload the main dashboard or Manual Recognition page.

- `/profit/admin/audit`: fulfillment leak and classification dashboard.
- `/profit/admin/pipeline`: run log and refresh control. Can start as a section inside `/profit/admin/audit` if the UI is small, but route-ready components should be separate.
- `/profit/admin/sla`: SLA dashboard.

The main dashboard should get compact summary tiles linking to these routes:

- Leak Queue.
- Pipeline Runs.
- SLA Watch.

Manual Recognition remains focused on event-level revenue recognition. It can show FC tag/service polish from the backlog, but leak classification and SLA triage should live in their own routes.

### 4. Cron Cadence

Start with conservative cadence:

- Full recognition pipeline: nightly at 2:00 AM America/New_York.
- Due re-evaluation scan: nightly after pipeline run.
- Lightweight status refresh from dashboard button: manual, user-triggered.
- Optional mid-day pipeline: disabled by default until V0.6.C has run stability data.

Do not start with 4-hour cron. V0.6 will introduce multiple new state transitions; nightly is easier to audit while the system is learning. The UI refresh button covers urgent operational cases without multiplying automated side effects.

### 5. Re-Emergence Detection Sensitivity

Detect re-emergence immediately during each pipeline/audit refresh, not weekly. A classified row becomes due for review when any signal hash changes:

- New service-delivery FC task.
- New Anchor agreement.
- Anchor agreement status change.
- New Anchor invoice.
- New QBO cash allocation.
- FC active/inactive status change.
- `re_evaluate_at <= current_date`.

Weekly summaries can be a reporting layer later. The row-level state should update on every run.

### 6. Verdict Classification UI Primitive

Use checkbox selection plus a verdict dropdown for bulk classification. The dropdown is the right primitive because verdict count is 14 and includes operationally similar states; radio buttons would crowd the table.

Bulk panel fields:

- Verdict dropdown.
- Optional `re_evaluate_at`.
- Notes textarea.
- Apply to selected button.

Single-row detail panel:

- Same verdict dropdown.
- Signal summary.
- Current/manual history.
- Auto-transition eligibility.

Autocomplete is unnecessary for a locked enum. It can be added later for notes/reference fields if volume demands it.

### 7. SLA Dashboard Placement

Use a top-level route: `/profit/admin/sla`.

Reasoning: SLA is an operational workload surface, not a metric drill-down. It needs staff filters, service filters, breach states, and trend views. A dashboard tab would either be cramped or force the main dashboard to carry workflow controls.

## Settled Doctrine And Import Assumptions

### Verdict Canon

The V0.6 verdict canon is 14 values. The canon is not limited to the current audit CSV's observed distribution; `BILLING_SETUP_GAP` and `MIXED` are real operational states even though the 2026-05-04 audit has zero rows for them. `CONSOLIDATED_VIA_GROUP_BILLED` and `SETTLED_VIA_QUICKBOOKS_PAYMENT` are formal verdicts, not ad hoc CSV residue.

Canonical verdict list:

- `INTERNAL_FAMILY`
- `INACTIVE_FORMER_CLIENT`
- `PENDING_ENGAGEMENT_DRAFT` — Anchor agreement DRAFT, not sent. Manual classification only (Anchor API does not expose DRAFT state). Auto-transition triggers only when an `active` agreement appears for the client. Required `re_evaluate_at` (default 30 days) since mid-flight evolution cannot be passively detected.
- `PENDING_ENGAGEMENT_SENT` — Anchor agreement SENT, awaiting client. Manual classification only (Anchor API does not expose SENT state). Auto-transition triggers only when an `active` agreement appears for the client. Required `re_evaluate_at` (default 30 days).
- `INVOICE_OUTSTANDING_PAYMENT_PENDING`
- `LEGACY_ENGAGEMENT_PRE_ANCHOR`
- `ENGAGEMENT_DECLINED`
- `LEGITIMATE_LEAK`
- `BILLING_OUTSIDE_AUDIT_WINDOW`
- `BILLING_SETUP_GAP`
- `GROUP_DEFINITION_GAP`
- `MIXED`
- `CONSOLIDATED_VIA_GROUP_BILLED`
- `SETTLED_VIA_QUICKBOOKS_PAYMENT`

### CSV Column Name

The audit CSV uses `veredict`, not `verdict`. V0.6 seed generation should read `veredict` for backward compatibility and write `verdict_code` into the database.

### Casing Normalization

The audit CSV uses `consolidated_via_group_billed` in lowercase while most verdicts are uppercase. V0.6 should canonicalize to uppercase `CONSOLIDATED_VIA_GROUP_BILLED` in the database and preserve the source value in `source_verdict_raw`.

### "Settled Via QuickBooks Payment"

`SETTLED_VIA_QUICKBOOKS_PAYMENT` is temporary suppression with an Anchor-backfill follow-up queue. It is hidden from the default leak surface, but it is not permanent suppression because V0.6 doctrine treats Anchor as the billing source of truth. These rows should converge out of the verdict when Anchor backfill catches up.

Auto-transition rule:

- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + new Anchor agreement created + first invoice fires + billed via group parent → `CONSOLIDATED_VIA_GROUP_BILLED`.
- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + new Anchor agreement created + first invoice fires + billed standalone → `BILLING_OUTSIDE_AUDIT_WINDOW`.
- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + new Anchor agreement created + invoice fired + cash not yet collected → `INVOICE_OUTSTANDING_PAYMENT_PENDING`.

UI placement: hide from the default leak surface, show in a separate Anchor backfill queue view in V0.6.D.

### Anchor Agreement State Visibility

Anchor's agreements API exposes only two states: `active` and `terminated`. DRAFT and SENT states exist in the Anchor UI but are not retrievable via the API (confirmed via live inspection 2026-05-06: filtered queries for `status=draft` / `sent` / `voided` / `signed` / `expired` / `archived` / `cancelled` return mixed active+terminated results, not the requested state).

Implications for V0.6 verdict logic:

- `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT` are manual-classification-only verdicts. Auto-derivation from API state changes is not possible.
- Auto-transition fires only when an `active` agreement appears for the client, signaling the pre-active state has resolved one way or another.
- Both verdicts require `re_evaluate_at` because we cannot passively detect mid-flight evolution.
- V0.6.B seed migration must cross-check each audit-CSV `PENDING_*` row against current Anchor data and reject rows that have already drifted past pre-active state.

## V0.6.A Data Foundation Spec

### FC Tag Storage

Add first-class FC tag capture. The FC API is the source of truth; `docs/data-references/client-staff-assignments.xlsx` becomes a historical snapshot.

Proposed schema:

```sql
create table if not exists profit_fc_client_tags (
  fc_client_id bigint not null references profit_fc_clients(fc_client_id),
  tag_name text not null,
  tag_type text not null check (tag_type in ('service', 'group', 'staff', 'unknown')),
  normalized_tag text not null,
  synced_at timestamptz not null default now(),
  primary key (fc_client_id, tag_name)
);

create table if not exists profit_fc_project_tags (
  fc_project_id bigint not null references profit_fc_projects(fc_project_id),
  tag_name text not null,
  tag_type text not null check (tag_type in ('service', 'group', 'staff', 'unknown')),
  normalized_tag text not null,
  synced_at timestamptz not null default now(),
  primary key (fc_project_id, tag_name)
);

create table if not exists profit_fc_task_tags (
  fc_task_id bigint not null references profit_fc_tasks(fc_task_id),
  tag_name text not null,
  tag_type text not null check (tag_type in ('service', 'group', 'staff', 'unknown')),
  normalized_tag text not null,
  synced_at timestamptz not null default now(),
  primary key (fc_task_id, tag_name)
);
```

FC payload structure (confirmed via live inspection 2026-05-06):

- `client.raw.groups` is the canonical source for both service tags and group tags. Service tags follow the `S <CODE>` convention (e.g. `S 1120P`, `S BOOKP`, `S PAYROLL`) and match `profit_service_recognition_rules.fc_tag`. Group tags are everything else in the array (e.g. `Feig Group`, `Andrews Group`, `Advanced Consulting`).
- `project.raw.tags` carries workflow status tags only (`Waiting on Client`, `In Preparation`, `Ready to Submit`). These are not service or group assignment tags. They are valuable for V0.6.D SLA workload tracking and will be wired up there.
- `task.raw.tags` is not exposed on the current completed-task endpoint. Per-task service/group tagging is deferred until an alternate endpoint is identified.

V0.6.A scope:

- Workflow 17 populates `profit_fc_client_tags` from `client.raw.groups`, classifying each entry against `profit_service_recognition_rules.fc_tag` (exact match -> `service`; otherwise -> `group`; truly ambiguous -> `unknown` for diagnostic surfacing).
- `profit_fc_project_tags` and `profit_fc_task_tags` remain in schema but are intentionally not populated in V0.6.A. The schema accommodates future use without further migration.
- Per-project service identification (which project belongs to which client service) becomes a V0.6.B problem. It must be solved via project name patterns, client service-tag set, and project closure timing rather than project tags.

### Structured Groups

Create live FC-derived group tables:

```sql
create table if not exists profit_client_groups (
  group_id bigserial primary key,
  group_name text not null unique,
  normalized_group_name text not null,
  source text not null default 'fc_tag' check (source in ('fc_tag', 'manual_override', 'seed_snapshot')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists profit_client_group_members (
  group_id bigint not null references profit_client_groups(group_id),
  fc_client_id bigint not null references profit_fc_clients(fc_client_id),
  membership_source text not null default 'fc_tag',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (group_id, fc_client_id)
);
```

Near-duplicate group view:

```sql
create or replace view profit_fc_group_name_near_duplicates as
select
  a.group_name as group_name_a,
  b.group_name as group_name_b,
  a.normalized_group_name as normalized_a,
  b.normalized_group_name as normalized_b
from profit_client_groups a
join profit_client_groups b
  on a.group_id < b.group_id
where a.normalized_group_name = b.normalized_group_name
   or similarity(a.normalized_group_name, b.normalized_group_name) >= 0.82;
```

Migration 020 must enable `pg_trgm` with `create extension if not exists pg_trgm;` and use `similarity(...) >= 0.82` unconditionally. If Supabase blocks extension creation at deploy time, stop at the Migration 020 checkpoint and resolve extension access directly rather than designing around absent typo detection.

### Name Normalization

Update `profit_normalize_client_name` to strip parenthetical suffixes before legal suffix removal:

```sql
regexp_replace(input_name, '\s*\([^)]*\)', '', 'g')
```

This must happen before stripping punctuation so `Kar Kraft Services LLC (Zephyrhills)` and `Kar Kraft Services LLC` normalize together.

### Service Delivery Vs. Admin Tasks

Add a lightweight classifier view or table for FC tasks:

- `service_delivery`: completion task, tax filed/extension filed, close books, payroll processed, sales tax filed, advisory delivery.
- `admin_onboarding`: onboarding setup, data request, engagement admin, internal review, client setup.
- `unknown`: included in diagnostic views but not enough to create leak signal by itself.

V0.6.A should start with a view based on project/title/tag signals. If false positives persist, V0.6.B can promote it to a seeded config table.

### Canonical Service Resolution

Keep raw `profit_revenue_events.service_name` as operational text. Add nullable `canonical_service_name` with FK:

```sql
alter table profit_revenue_events
  add column if not exists canonical_service_name text references profit_service_recognition_rules(service_name);
```

Resolution order:

1. Exact match: `raw_service_name = service_name`.
2. Alias table: `profit_anchor_service_aliases.raw_service_name`.
3. Prefix pattern: canonical name appears before `-`, `(`, `,`, or line end.
4. NULL canonical; raw value remains and surfaces in run log/manual review.

Alias table:

```sql
create table if not exists profit_anchor_service_aliases (
  raw_service_name text primary key,
  canonical_service_name text not null references profit_service_recognition_rules(service_name),
  match_method text not null check (match_method in ('manual_alias', 'exact', 'prefix')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
```

Seed aliases from `docs/audits/2026-05-07-unresolved-service-names.csv` only after Orlando reviews the mapping. Do not guess canonical mappings in the migration.

## V0.6.B Verdict Persistence Spec

### Lookup Table

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
```

Canonical executable verdicts:

- `INTERNAL_FAMILY`
- `INACTIVE_FORMER_CLIENT`
- `PENDING_ENGAGEMENT_DRAFT`
- `PENDING_ENGAGEMENT_SENT`
- `INVOICE_OUTSTANDING_PAYMENT_PENDING`
- `LEGACY_ENGAGEMENT_PRE_ANCHOR`
- `ENGAGEMENT_DECLINED`
- `LEGITIMATE_LEAK`
- `BILLING_OUTSIDE_AUDIT_WINDOW`
- `BILLING_SETUP_GAP`
- `GROUP_DEFINITION_GAP`
- `MIXED`
- `CONSOLIDATED_VIA_GROUP_BILLED`
- `SETTLED_VIA_QUICKBOOKS_PAYMENT`

Migration 023 must seed the lookup table before migration 024 inserts classification rows. Use idempotent `insert ... on conflict (verdict_code) do update set ...` so the lookup can be safely re-run as labels, descriptions, or visibility rules are refined:

```sql
insert into profit_classification_verdicts (
  verdict_code,
  label,
  category,
  default_visibility,
  requires_re_evaluate_at,
  auto_transition_enabled,
  description
) values
  ('INTERNAL_FAMILY', 'Internal family', 'suppressed', 'hide', false, false, 'Saez family, SBC, or internal account. Permanent suppression.'),
  ('INACTIVE_FORMER_CLIENT', 'Inactive former client', 'suppressed', 'hide', false, true, 'Client churned. All four inactive conditions must be true; re-emergence scan supersedes this verdict if any signal returns.'),
  ('PENDING_ENGAGEMENT_DRAFT', 'Pending engagement draft', 'pending', 'show', true, true, 'Anchor agreement DRAFT, not sent. Manual classification only because Anchor API does not expose DRAFT state. Auto-transition fires when an active agreement appears for the client. re_evaluate_at default 30 days.'),
  ('PENDING_ENGAGEMENT_SENT', 'Pending engagement sent', 'pending', 'show', true, true, 'Anchor agreement SENT, awaiting client. Manual classification only because Anchor API does not expose SENT state. Auto-transition fires when an active agreement appears for the client. re_evaluate_at default 30 days.'),
  ('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'Invoice outstanding / payment pending', 'pending', 'show', false, true, 'Agreement and invoice exist; awaiting customer payment.'),
  ('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'Legacy engagement pre-Anchor', 'pending', 'show', false, true, 'Legacy engagement valid before Anchor agreement migration. Tracks migration health until first Anchor invoice fires.'),
  ('ENGAGEMENT_DECLINED', 'Engagement declined', 'suppressed', 'hide', false, false, 'Client declined this period; classification is year-aware and may re-emerge in future periods.'),
  ('LEGITIMATE_LEAK', 'Legitimate leak', 'leak', 'show', false, false, 'No agreement or billing trail exists while service work is being delivered.'),
  ('BILLING_OUTSIDE_AUDIT_WINDOW', 'Billing outside audit window', 'pending', 'show', false, false, 'Active agreement exists; annual cycle, extension, or first cycle billing is not yet due.'),
  ('BILLING_SETUP_GAP', 'Billing setup gap', 'setup_gap', 'show', false, false, 'Active agreement exists for recurring service, but recurring invoices are not firing.'),
  ('GROUP_DEFINITION_GAP', 'Group definition gap', 'setup_gap', 'show', false, false, 'The actually-billed parent is missing from the FC group definition.'),
  ('MIXED', 'Mixed', 'mixed', 'show', false, false, 'Partial billing pattern requiring manual review.'),
  ('CONSOLIDATED_VIA_GROUP_BILLED', 'Consolidated via group billed', 'healthy', 'hide', false, false, 'Work is covered by an Anchor invoice billed on a group parent entity. Informational, not a leak.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'Settled via QuickBooks payment', 'backfill', 'hide', false, true, 'Cash collected via QBO without an Anchor agreement/invoice trail. Temporary suppression; belongs in the Anchor backfill queue.')
on conflict (verdict_code) do update set
  label = excluded.label,
  category = excluded.category,
  default_visibility = excluded.default_visibility,
  requires_re_evaluate_at = excluded.requires_re_evaluate_at,
  auto_transition_enabled = excluded.auto_transition_enabled,
  description = excluded.description,
  updated_at = now();
```

`default_visibility` is the canon of truth for what appears in the default audit queue. UI and API code must read from `profit_classification_verdicts.default_visibility` instead of embedding hidden verdict names.

### Classification Table

Each audit CSV row becomes one classification record. Classifications are keyed to FC client plus optional service/group context, because the audit row originates from FC fulfillment risk.

```sql
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
```

The table is append-friendly. If a verdict changes manually, insert a new row and mark the prior row `superseded_at`, preserving audit history.

### Seed Migration

Create `scripts/generate_fulfillment_classification_seed.py`:

- Reads `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`.
- Reads the `veredict` column.
- Trims whitespace and canonicalizes casing.
- Maps `consolidated_via_group_billed` → `CONSOLIDATED_VIA_GROUP_BILLED`.
- Strips trailing whitespace so `INVOICE_OUTSTANDING_PAYMENT_PENDING ` imports as `INVOICE_OUTSTANDING_PAYMENT_PENDING`.
- Normalizes duplicate apparent values such as `ENGAGEMENT_DECLINED` with whitespace/case drift into one canonical code.
- Validates every normalized verdict against the 14-value canon and fails generation if any unknown value remains. Unknown verdicts are never silently accepted.
- Preserves raw value in `source_verdict_raw`.
- Generates `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`.
- Emits deterministic SQL; rerunning against unchanged CSV should produce zero diff.
- Stale-row check for `PENDING_*` verdicts: for every audit-CSV row classified as `PENDING_ENGAGEMENT_DRAFT` or `PENDING_ENGAGEMENT_SENT`, the seed-generation script must look up the corresponding `fc_client_id` in the live `profit_anchor_agreements` table.
  - If the client has an active agreement in `profit_anchor_agreements` (`display_status = 'active'`), the audit-CSV verdict is stale. Do not seed the `PENDING_*` verdict. Instead, emit a row in `profit_classifications` with `verdict_code = 'MIXED'` and `notes = 'Audit CSV captured this row as PENDING_ENGAGEMENT_* on 2026-05-04 but client now has an active agreement. Manual reclassification required.'` Set `re_evaluate_at = current_date`.
  - If the client has no active agreement, seed the `PENDING_*` verdict as captured. Set `re_evaluate_at = current_date + 30`.
  - The generation script must report counts for rows seeded as captured and rows reclassified to `MIXED` due to drift. Both counts go into the seed migration's summary comment.

Seed behavior:

```sql
insert into profit_classifications (...)
values (...)
on conflict (source_audit_file, source_audit_row_hash) do update set
  verdict_code = excluded.verdict_code,
  source_verdict_raw = excluded.source_verdict_raw,
  suggested_classification = excluded.suggested_classification,
  estimated_annual_revenue = excluded.estimated_annual_revenue,
  notes = excluded.notes,
  updated_at = now();
```

## V0.6.B Audit Query Refactor Spec

### Candidate Pipeline

> Per-project service identification: FC project tags are workflow status, not service assignment. V0.6.B audit query must derive per-service signals using:
> 1. Client service-tag set from `profit_fc_client_tags` (`tag_type = 'service'`).
> 2. Project name patterns matched against canonical service names.
> 3. Project completion timing aligned to service-aware audit windows.
>
> A future improvement is to add an explicit project-to-service mapping if FC introduces project-level service tags.

Create a layered view set:

1. `profit_fulfillment_audit_fc_activity`
   - FC clients with recent service-delivery tasks.
   - Excludes admin-only clients by default.

2. `profit_fulfillment_audit_anchor_signals`
   - Anchor agreement status, effective invoice status, latest invoice date, latest cash date, open balances.

3. `profit_fulfillment_audit_group_signals`
   - Group members, billed parent, group invoice counts, group service coverage.

4. `profit_fulfillment_audit_candidates`
   - One row per FC client/service/group context requiring visibility.
   - Applies `any-active-signal` pre-filter.
   - Applies service-type-aware windows.
   - Joins current classification, if any.

### Any-Active-Signal Filter

Rows do not enter the queue unless at least one is true:

- FC client is active.
- A service-delivery FC task completed inside the service-aware audit window.
- Anchor agreement exists.
- Anchor invoice exists inside the service-aware audit window.
- QBO open balance is nonzero.
- Client appears in live FC group/service tags.
- `re_evaluate_at <= current_date`.

This removes zero-signal rows such as Joy Property Management LLC from default intake. Previously classified `INACTIVE_FORMER_CLIENT` rows remain in history and are hidden unless "Show all" is enabled.

### Inactive-Client Re-Emergence Scan

`INACTIVE_FORMER_CLIENT` is the only hidden verdict whose rows can be zero-signal by definition. Because the candidate view intentionally excludes zero-signal rows, re-emergence for inactive clients must run as a dedicated nightly scan independent of the candidate view.

Scan all active classifications where:

```sql
verdict_code = 'INACTIVE_FORMER_CLIENT'
and superseded_at is null
```

For each row, compare current signals against the four AND-gated inactive conditions as of `classified_at`. If any condition has reversed, supersede the classification and force the row into the candidate view for manual reclassification:

- FC client became active.
- Anchor agreement was created.
- QBO open balance is now greater than 0.
- A service-delivery FC task completed in the last 365 days.

This scan runs as part of the nightly pipeline after step 11, "Refresh fulfillment audit candidates," and before step 12, "Apply eligible auto-transitions." That ordering lets step 12 pick up newly superseded rows and apply normal transition logic where appropriate.

Other hidden verdicts still surface through the candidate view when their underlying signals exist:

- `INTERNAL_FAMILY`
- `CONSOLIDATED_VIA_GROUP_BILLED`
- `SETTLED_VIA_QUICKBOOKS_PAYMENT`

### Service-Type-Aware Windows

- Monthly recurring services (`bookkeeping`, `payroll`, `sales_tax`, monthly advisory): 180 days.
- Annual tax and annual one-time filings: 365 days.
- Legacy/pre-Anchor rows: use the service's expected billing cycle plus `re_evaluate_at`.
- Unknown services: 180 days and require manual review.

Annual deliverables must be evaluated by service, not by parent billing activity. A parent's monthly bookkeeping invoice does not satisfy an individual's annual 1040 deliverable.

### Group Billing Rules

Healthy group-billed rows are hidden by default:

- `CONSOLIDATED_VIA_GROUP_BILLED` when a group member has invoice/cash in the relevant service window for the matching service type.
- Hornauer/NDH/DVH and Wong/KNW are the regression examples.

Do not classify annual deliverables as group-billed based only on unrelated monthly recurring invoices:

- Inatsuka/LTI is the regression example.

### Auto-Transition State Machine

Create transition rules as explicit SQL/data rows, not hard-coded UI behavior:

```sql
create table if not exists profit_classification_transition_rules (
  from_verdict_code text not null references profit_classification_verdicts(verdict_code),
  signal_name text not null,
  to_verdict_code text not null references profit_classification_verdicts(verdict_code),
  requires_service_type_match boolean not null default true,
  enabled boolean not null default true,
  notes text,
  primary key (from_verdict_code, signal_name, to_verdict_code)
);
```

Initial transitions:

- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + first matching Anchor invoice → `BILLING_OUTSIDE_AUDIT_WINDOW` for annual service still mid-cycle.
- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + first matching Anchor invoice + matching service delivered/billed in group → `CONSOLIDATED_VIA_GROUP_BILLED`.
- `PENDING_ENGAGEMENT_DRAFT` + active agreement appears for client → supersede classification and force into candidate view for manual reclassification.
- `PENDING_ENGAGEMENT_SENT` + active agreement appears for client → supersede classification and force into candidate view for manual reclassification.
- `INVOICE_OUTSTANDING_PAYMENT_PENDING` + cash collected → `CONSOLIDATED_VIA_GROUP_BILLED` when the billed entity is a group parent, otherwise `BILLING_OUTSIDE_AUDIT_WINDOW` when the billing is standalone and the service remains mid-cycle.
- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + new Anchor agreement created + first invoice fires + billed via group parent → `CONSOLIDATED_VIA_GROUP_BILLED`.
- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + new Anchor agreement created + first invoice fires + billed standalone → `BILLING_OUTSIDE_AUDIT_WINDOW`.
- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + new Anchor agreement created + invoice fired + cash not yet collected → `INVOICE_OUTSTANDING_PAYMENT_PENDING`.
- `INACTIVE_FORMER_CLIENT` + any active signal → supersede classification and return to manual review queue.

When a pre-active engagement state resolves, multiple downstream verdicts are possible (`BILLING_OUTSIDE_AUDIT_WINDOW`, `INVOICE_OUTSTANDING_PAYMENT_PENDING`, or `CONSOLIDATED_VIA_GROUP_BILLED`). The transition therefore returns the row to manual review rather than guessing the final verdict.

Every auto-transition inserts a new `profit_classifications` row and links the prior row through `superseded_by_classification_id`.

## V0.6.B Audit Dashboard Spec

Route: `/profit/admin/audit`.

Default view:

- Shows only rows whose current verdict has `default_visibility = 'show'`.
- Hides rows whose current verdict has `profit_classification_verdicts.default_visibility = 'hide'`.
- Applies the any-active-signal filter.

Controls:

- "Show all" toggle.
- Verdict filter.
- Staff filter.
- Service tag filter.
- Group filter.
- Re-evaluation due filter.
- Search by FC client/group/Anchor name.

Table columns:

- Select checkbox.
- FC client.
- Group.
- Service tags.
- Staff primary/reviewer.
- Anchor agreement signal.
- Invoice/cash signal.
- Estimated annual revenue.
- Current verdict.
- Re-evaluate date.
- Signal status.

Bulk classification:

- Select rows.
- Choose verdict from dropdown.
- Optional `re_evaluate_at`.
- Required notes when changing to `LEGITIMATE_LEAK`, `MIXED`, or any doctrine-only/manual-review state.
- Apply creates new classification rows and supersedes previous active rows.

Detail panel:

- Signal timeline.
- FC completed service tasks.
- Anchor agreement/invoice/cash summary.
- Group members and billed parent.
- Classification history.
- Auto-transition eligibility.

## V0.6.C Pipeline Orchestration Spec

Create `Profit - 26 Recognition Pipeline`:

1. Anchor agreement sync.
2. Anchor invoice sync.
3. QBO collection loader.
4. FC sync.
5. Auto-match FC clients to Anchor.
6. Classify Anchor line items.
7. Load revenue event candidates.
8. Approve conservative tax/bookkeeping triggers.
9. Load FC completion triggers.
10. Apply recognition triggers.
11. Refresh fulfillment audit candidates.
12. Run inactive-client re-emergence scan.
13. Apply eligible auto-transitions.

Run logs:

```sql
create table if not exists profit_pipeline_runs (
  pipeline_run_id uuid primary key default gen_random_uuid(),
  run_source text not null check (run_source in ('cron', 'manual')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null check (status in ('running', 'success', 'failed', 'partial')),
  triggered_by text,
  summary jsonb not null default '{}'::jsonb
);

create table if not exists profit_pipeline_run_steps (
  pipeline_run_id uuid not null references profit_pipeline_runs(pipeline_run_id),
  step_name text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null check (status in ('running', 'success', 'failed', 'skipped')),
  rows_affected integer,
  details jsonb not null default '{}'::jsonb,
  primary key (pipeline_run_id, step_name)
);
```

UI:

- Add compact pipeline status tile to main dashboard.
- Add run-log section to `/profit/admin/audit` or route-ready `/profit/admin/pipeline`.
- Manual refresh button triggers run with `run_source = 'manual'`.
- Button is disabled while a run is active.

## V0.6.D SLA Dashboard Spec

Route: `/profit/admin/sla`.

Until V0.6.D ships, `SETTLED_VIA_QUICKBOOKS_PAYMENT` rows are seeded into `profit_classifications` but have no dedicated UI. They are visible in V0.6.B's `/profit/admin/audit` only via the "Show all" toggle. The backfill queue is the long-term home; this is a known temporary gap, not a missing requirement.

V0.6.D also carries the Anchor backfill queue for rows classified as `SETTLED_VIA_QUICKBOOKS_PAYMENT`. This is intentionally separate from the default leak surface: it is not a current fulfillment leak, but it is a convergence queue because Anchor should become the billing source of truth. The queue should show client/group, QBO payment evidence, missing Anchor agreement/invoice state, aging, and auto-transition eligibility once Anchor backfill occurs.

Inputs:

- Live FC service tags.
- `profit_service_recognition_rules.default_sla_day`.
- `profit_anchor_agreements.sla_day_override`.
- FC task/project status.
- Anchor service coverage.

Views:

- Per-client SLA status.
- Per-staff workload.
- Breach/at-risk queue.
- Rolling SLA performance by staff/service type.

SLA state:

- `on_track`
- `at_risk`
- `breached`
- `waiting_on_client`
- `not_applicable`

This slice should not create write controls beyond filters. SLA remediation workflows can follow after the first read-only dashboard is trusted.

## Testing Strategy

V0.6 keeps the existing TDD/static-coverage pattern.

Minimum test files:

- `tests/test_fulfillment_classification_sql.py`
  - Verdict lookup shape.
  - Migration 023 seeds all 14 verdict lookup rows with the expected `default_visibility` and `auto_transition_enabled` matrix.
  - Classification table shape.
  - Transition rule table shape.
  - Seed migration references every CSV row hash.
  - Fixture: FC inactive + no Anchor + zero QBO balance + one service-delivery task completed in the last 90 days. Assertion: the auto-classifier must not produce `INACTIVE_FORMER_CLIENT`.
  - Parallel positive fixture: FC inactive + no Anchor + zero QBO balance + no service-delivery FC task completed in the last 365 days. Assertion: the auto-classifier produces `INACTIVE_FORMER_CLIENT`.
  - Re-emergence fixture: existing active `INACTIVE_FORMER_CLIENT` classification plus a newly completed FC service-delivery task. Run the nightly re-emergence scan. Assertion: original classification is superseded and the row appears in the candidate view for manual reclassification.

- `tests/test_fulfillment_audit_queries.py`
  - Any-active-signal filter excludes zero-signal rows.
  - Parenthetical suffix normalization matches Kar Kraft examples.
  - Annual deliverable not satisfied by parent monthly invoice.
  - Healthy group-billed rows are hidden by default and visible with "Show all".
  - Service-delivery tasks are distinguished from admin tasks.

- `tests/test_fc_tag_sync.py`
  - Workflow 17 captures tag arrays.
  - Service tags match `profit_service_recognition_rules.fc_tag`.
  - Near-duplicate group names are surfaced.

- `tests/test_service_alias_resolution.py`
  - Raw service names remain preserved.
  - Canonical service names resolve by exact, alias, and prefix.
  - Unresolved raw names surface for manual review.

- `tests/test_profit_admin_frontend.py`
  - `/profit/admin/audit` route and nav link.
  - Show all toggle.
  - Bulk classification dropdown.
  - `re_evaluate_at` field.
  - `/profit/admin/sla` route and nav link.

- `tests/test_pipeline_runs.py`
  - Pipeline run table/view definitions.
  - Run-log API shape.
  - Manual refresh endpoint refuses concurrent runs.

## Documentation Updates

- Update `docs/profit-admin-portal-review-guide.md` with V0.6 audit, pipeline, and SLA sections.
- Update `docs/data-contracts/recognition-triggers.md` to describe canonical service-name usage and pipeline run interactions.
- Add `docs/data-contracts/fulfillment-classifications.md` for verdicts, transitions, visibility, seed behavior, and re-emergence rules.
- Update `docs/data-references/README.md` to note that the XLSX/CSVs are historical snapshots once V0.6.A live sync is deployed.
- Update `docs/tech-debt.md` to remove or close items resolved by V0.6.A/B, leaving only deferred items.

## Deploy And Review Checkpoints

Each slice stops before commit at a live spot-check:

- V0.6.A: verify FC tags, agreement status, QBO products, and canonical service resolution counts in live Supabase.
- V0.6.B: verify audit dashboard default queue, "Show all", seeded verdicts, and re-evaluation flags against known examples.
- V0.6.C: verify one manual pipeline run, run log, and no accidental broad approvals.
- V0.6.D: verify SLA dashboard against a known staff/client sample.

## Out Of Scope For V0.6

- Undo/reverse classification workflow beyond superseding with a new classification row.
- Full AR collections workflow for `INVOICE_OUTSTANDING_PAYMENT_PENDING`.
- Automated Anchor agreement creation.
- Automated FC project creation for Anchor service coverage gaps.
- Insurance accrual automation for Audit Protection.
- Dedicated `SETTLED_VIA_QUICKBOOKS_PAYMENT` UI before V0.6.D ships.
- Anchor service API sync replacing the static `anchor services.csv` seed; deferred to V0.6.C or post-V0.6 with the rest of the live-sync hardening.
- Staff performance compensation logic.
- Replacing Anchor/QBO/FC APIs with a centralized data warehouse.

## Recommended Implementation Order

1. V0.6.A plan and implementation.
2. V0.6.B SQL persistence and seed.
3. V0.6.B audit query and UI.
4. V0.6.C pipeline run tables and manual run.
5. V0.6.C cron enablement after manual-run confidence.
6. V0.6.D SLA views and UI.

This ordering keeps the system from building dashboard behavior on stale snapshots, raw-name joins, or unpersisted manual classifications.
