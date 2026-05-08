# Profit Dashboard V0.6.B.2.a Audit Query Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the V0.6.B.2.a backend audit query layer: status-aware FC-to-Anchor matching, canonical fulfillment-audit helper views, inactive-client re-emergence scan v2, layered audit candidate views, and dry-run/apply transition execution.

**Architecture:** This is a SQL/data-layer and Workflow 25 slice only. It extends the V0.6.B.1 verdict persistence foundation without adding frontend routes or API endpoints. Helper views are canonical sources for repeated logic: FC inactive signals, QBO product leaf extraction, open invoice balance, QBO/category diagnostics, and audit candidate visibility.

**Tech Stack:** Supabase Postgres migrations/views/functions, n8n Workflow 25, static and SQL-shape `pytest`, live Supabase deploy through the existing VPS `psql` pattern, existing V0.6.A/B.1 FC/Anchor/QBO data foundation.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: locked V0.6 spec; use only the V0.6.B audit-query sections and transition-state-machine rules.
- `docs/superpowers/plans/2026-05-07-profit-dashboard-v0.6.B.1-verdict-persistence-and-seed.md`: structural template and B.1 persistence contract.
- `docs/data-contracts/fulfillment-classifications.md`: current data contract to extend with B.2.a scan and audit-query semantics.
- `docs/tech-debt.md`: B.2.a must resolve or explicitly carry forward the Workflow 25 reissuance gap, Workflow 25 scheduling gap, known PENDING_SENT staleness, Joy inactive criteria refinement, re-emergence transition guards, open-invoice timestamp limitation, and QBO category gaps.
- `supabase/sql/023_profit_fulfillment_classifications.sql`: verdict lookup, classification history, and transition rules.
- `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`: seeded 53 audit classifications.
- `supabase/sql/025a_profit_inactive_client_reemergence_scan.sql`: B.1 function to replace in `025c` using the same name/signature.
- `profit_anchor_agreements.display_status`: live `active` / `terminated` / `stale` agreement status from Workflow 05.
- `profit_fc_clients.is_archived` and `profit_fc_clients.archived_at`: direct FC inactive source; all 19 archived clients had `archived_at` populated during G2.
- `profit_anchor_invoices.amount_due`, `qbo_status`, `display_status`, and `raw->>'createdAt'`: canonical source for open invoice balance, not a nonexistent `profit_qbo_collections` table.

## Gate Decisions Locked Into This Plan

### G1: Workflow 25 Reissuance Gap

Decision: fix `profit_fc_client_anchor_match_candidates` in SQL and keep Workflow 25 as a thin canonical writer.

Status-rank truth table:

- Priority: `active > terminated > stale > null`.
- `auto_exact` requires exactly one active row after dedup.
- Two or more active rows under one normalized name -> `ambiguous`.
- One active plus one or more terminated and/or stale rows -> `auto_exact` to the active row.
- Terminated-only, whether single or multiple -> `ambiguous`.
- Stale-only -> `ambiguous`.

Immediate live impact after the fix is expected to be one active seeded PENDING row: Schmidli Enterprises LLC (`classification_id = 32`) becomes transition-eligible. E & O Automotive LLC becomes safer as terminated-only `ambiguous`, not `auto_exact`.

### G2: INACTIVE_FORMER_CLIENT Criteria Refinement

Decision: use direct `profit_fc_clients.archived_at` plus a one-day closure-grace window.

Canonical helper view must centralize this logic:

- `profit_audit_fc_inactive_signals`
- Includes `fc_is_archived`, `fc_archived_at`, `fc_unarchived_after_archive`, `has_post_archive_service_delivery`, and `archived_at_missing_for_archived_client`.
- Uses `interval '1 day'` with an inline comment: closure-batch task completions can fire seconds after `archived_at`; treat as offboarding artifact, not re-engagement.

### G3: Re-Emergence Scan V2

Decision: migration `025c_profit_inactive_client_reemergence_scan_v2.sql` uses `create or replace function profit_run_inactive_client_reemergence_scan(p_run_at timestamptz default now())` with the same signature.

Reason codes:

- `fc_client_unarchived`
- `fc_client_became_active`
- `active_anchor_agreement_created`
- `service_delivery_task_completed`
- `open_invoice_balance_returned`

Anchor limitation: `effective_date` is the best available activation proxy. Anchor does not expose true agreement create/sign timestamps. Backdated active agreements may not trigger scan v2, but the audit candidate view's any-active-signal filter must surface them for manual review.

### G4: NULL QBO Category Handling

Decision: use left joins and diagnostics; do not backfill the 10 QBO product rows whose `qbo_category_path` is null.

Canonical scalar function:

- `profit_qbo_product_leaf_name(text) returns text`
- `Tax Work:1120 Plus` -> `1120 Plus`
- `1120 Plus` -> `1120 Plus`
- `A:B:C` -> `C`
- `Tax Work:` -> empty string, which surfaces as `missing_qbo_product`
- `NULL` -> `NULL`, which surfaces as `missing_qbo_product`

Diagnostic view:

- `profit_fulfillment_audit_qbo_category_gaps`
- `qbo_product_match_status`: `matched`, `missing_qbo_product`, `missing_qbo_category`
- `gap_origin`: `qbo_product_missing`, `qbo_category_missing_on_product`, `canonical_service_name_unresolved`
- Sample arrays capped at five most recent revenue events.

### G5: Canonical Open-Balance Source

Decision: helper view name is `profit_audit_open_invoice_balance_per_client`.

Despite earlier wording around QBO, the source is Anchor invoice rows carrying QBO sync status and amount-due values. The public names must use "open invoice", not "qbo open balance".

Canonical currently-open predicate:

```sql
coalesce(invoice.amount_due, 0) > 0
and coalesce(invoice.qbo_status, '') <> 'voidSynced'
and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
```

For B.2.a, keep this predicate inline in the helper view with a SQL comment pointing at the existing Anchor-void propagation tech debt. Long-term `profit_anchor_invoice_is_currently_open(...)` is deferred.

The helper must return exactly one row per `fc_client_id`.

### G6: Stale PENDING_SENT Transition Flush

Decision: `025d_profit_apply_classification_transitions.sql` adds one function with dry-run support:

```sql
profit_apply_classification_transitions(
  p_run_at timestamptz default now(),
  p_dry_run boolean default true
)
```

Return shape:

- `classification_id bigint`
- `fc_client_id bigint`
- `fc_client_name text`
- `from_verdict_code text`
- `signal_name text`
- `to_verdict_code text`
- `anchor_relationship_id text`
- `anchor_client_business_name text`
- `evidence_summary jsonb`
- `would_create_classification_id bigint`

Dry-run contract: same selection logic, same rows, zero writes.

Behavioral coverage for dry-run zero-writes, disabled-rule behavior, and idempotency is enforced through live deploy-checkpoint SQL rather than pytest database fixtures. The repo's existing tests are static/file-based; B.2.a does not add a test-database harness.

Expected immediate live transition after Workflow 25 refresh and `025d`:

- Schmidli Enterprises LLC only.
- `PENDING_ENGAGEMENT_SENT`: `14 -> 13`
- `MIXED`: `1 -> 2`
- The 12 other seeded `PENDING_ENGAGEMENT_SENT` rows stay pending because their active reissued agreements are not currently surfaced in `profit_anchor_agreements`, even though direct Anchor API inspection on 2026-05-07 confirmed those active agreements exist. This is an upstream Anchor sync coverage gap, not B.2.a scope.

`025d` scope is intentionally narrow: it applies only `active_agreement_appears` for `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT`. The other nine B.1-seeded transition rules remain data-only in B.2.a and become executable in V0.6.C pipeline orchestration.

Migration `026` remains reserved for V0.6.C pipeline run tables.

## Scope

In scope:

- Migration `024a_profit_fc_client_anchor_match_candidates_status_rank.sql`.
- Workflow 25 rerun after `024a`; workflow JSON modification only if checkpoint summary columns require it.
- Migration for `profit_audit_fc_inactive_signals` helper view.
- Migration for `profit_qbo_product_leaf_name`, `profit_audit_open_invoice_balance_per_client`, and QBO/category diagnostic helpers.
- Migration `025c_profit_inactive_client_reemergence_scan_v2.sql`.
- Migration `025_profit_fulfillment_audit_views.sql` with layered B.2.a views.
- Migration `025d_profit_apply_classification_transitions.sql`.
- Tests for SQL shape and behavior locks.
- Documentation updates to fulfillment-classifications data contract and tech debt.

Out of scope:

- `/profit/admin/audit` React route, bulk classify UI, detail panel, frontend tests, or any `app/frontend/**` file.
- `profit_api/**` changes.
- V0.6.C pipeline orchestration, Workflow 26, cron, or pipeline run tables.
- V0.6.D SLA dashboard.
- Manual alias seeding from `docs/audits/2026-05-07-unresolved-service-names.csv`.
- Backfilling the 10 NULL `qbo_category_path` product rows.
- Adding QBO product rows such as `Strategic Advisory`.
- Changing the 14-verdict canon.
- Non-append classification updates outside approved supersede flows.

## Migration And Deploy Checkpoints

Stop after every deploy checkpoint and wait for orchestrator approval.

1. **024a match candidate-view checkpoint**
   - Apply `024a_profit_fc_client_anchor_match_candidates_status_rank.sql`.
   - Run Workflow 25 once.
   - Report match row-count delta, method/status distribution, newly persisted active matches, and corrected/ambiguous rows.
   - Do not apply classification transitions at this checkpoint.

2. **FC inactive signals helper checkpoint**
   - Apply helper migration.
   - Verify Joy stays inactive under the one-day closure-grace logic.
   - Verify unarchive-after-archive count is currently `0`.

3. **Open invoice/QBO diagnostic helpers checkpoint**
   - Apply helper migration.
   - Verify Celtic Auto Werks Inc open balance `900.00`.
   - Verify YV Enterprises SR LLC open balance `834.60`.
   - Verify Collectiv Inc open balance `0` because `SBC-00015` is `voidSynced`.
   - Verify helper grain: `count(*) = count(distinct fc_client_id)`.

4. **025c scan v2 checkpoint**
   - Apply `025c_profit_inactive_client_reemergence_scan_v2.sql`.
   - Verify function exists.
   - Verify `profit_run_inactive_client_reemergence_scan(now())` returns `0 rows` on current data.
   - Verify active `INACTIVE_FORMER_CLIENT` count remains `1`.

5. **025 audit views checkpoint**
   - Apply `025_profit_fulfillment_audit_views.sql`.
   - Verify layered views exist.
   - Report candidate count, default-visible count, hidden count, diagnostic counts, and known regression samples.

6. **025d transition function checkpoint**
   - Apply `025d_profit_apply_classification_transitions.sql`.
   - Dry-run first; expected row is Schmidli only.
   - Run disabled-rule preview before live apply, then restore the rule.
   - Live apply after dry-run approval inside the same checkpoint.
   - Report before/after counts: `PENDING_ENGAGEMENT_SENT 14 -> 13`, `MIXED 1 -> 2`, unless live data has changed and the dry-run evidence explains why.
   - Run live apply a second time and verify zero transitions for idempotency.

7. **Final B.2.a checkpoint before commit**
   - Targeted pytest.
   - Full pytest.
   - `git diff --name-only` scope boundary.
   - Live count summary.
   - Commit and push only after orchestrator approval.

## Files

Create:

- `supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql`
- `supabase/sql/025_profit_fulfillment_audit_views.sql`
- `supabase/sql/025b_profit_audit_helpers.sql`
- `supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql`
- `supabase/sql/025d_profit_apply_classification_transitions.sql`
- `tests/test_fulfillment_audit_queries.py`
- Optional if workflow summary needs richer output: `n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json`

Modify:

- `tests/test_fulfillment_classification_sql.py`
- `docs/data-contracts/fulfillment-classifications.md`
- `docs/tech-debt.md`
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.a-audit-query-refactor.md` while checking off tasks.

Do not modify:

- `app/frontend/**`
- `profit_api/**`
- `supabase/sql/026_*`
- `supabase/sql/027_*`
- `n8n/workflows/**` other than Workflow 25 if explicitly needed for checkpoint summaries.
- `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`
- `docs/audits/2026-05-07-unresolved-service-names.csv`
- Any V0.6.A workflow JSON except Workflow 25.

## Task 1: 024a Match Candidate View Red Tests

**Files:**
- Create `tests/test_fulfillment_audit_queries.py`
- Create later `supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql`

- [ ] **Step 1: Write failing SQL-shape tests**

Create `tests/test_fulfillment_audit_queries.py`:

```python
from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL_024A = ROOT / "supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql"
SQL_025 = ROOT / "supabase/sql/025_profit_fulfillment_audit_views.sql"
SQL_025B = ROOT / "supabase/sql/025b_profit_audit_helpers.sql"
SQL_025C = ROOT / "supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql"
SQL_025D = ROOT / "supabase/sql/025d_profit_apply_classification_transitions.sql"


class FulfillmentAuditQuerySqlTests(unittest.TestCase):
    def test_024a_match_candidates_rank_active_over_terminated_and_stale(self) -> None:
        sql = SQL_024A.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_fc_client_anchor_match_candidates", lower)
        self.assertIn("when agreement.display_status = 'active' then 1", lower)
        self.assertIn("when agreement.display_status = 'terminated' then 2", lower)
        self.assertIn("when agreement.display_status = 'stale' then 3", lower)
        self.assertIn("active_anchor_count = 1", lower)
        self.assertIn("active_anchor_count > 1", lower)
        self.assertIn("terminated-only", lower)
        self.assertIn("stale-only", lower)
        self.assertIn("E & O Automotive LLC", sql)
        self.assertIn("1415 Cortez Rd LLC", sql)
        self.assertIn("6712 Manatee Ave LLC", sql)
        self.assertIn("Kar Kraft Auto Repair LLC (TempleTerrace)", sql)
        self.assertIn("Kar Kraft Services LLC (Zephyrhills)", sql)
        self.assertIn("YV Enterprises HB LLC", sql)
        self.assertIn("YV Enterprises PSL LLC", sql)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: FAIL because `024a_profit_fc_client_anchor_match_candidates_status_rank.sql` does not exist.

## Task 2: Implement And Deploy 024a Status-Ranked Match Candidates

**Files:**
- Create `supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql`
- Test `tests/test_fulfillment_audit_queries.py`

- [ ] **Step 1: Create migration**

Create `supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql`:

```sql
create or replace view profit_fc_client_anchor_match_candidates as
with fc as (
  select
    client.fc_client_id,
    client.name as fc_client_name,
    profit_normalize_client_name(client.name) as normalized_client_name
  from profit_fc_clients client
),
anchor_candidates as (
  select
    fc.fc_client_id,
    fc.fc_client_name,
    fc.normalized_client_name,
    agreement.anchor_relationship_id,
    agreement.client_business_name as anchor_client_business_name,
    agreement.display_status,
    agreement.last_updated_at,
    count(*) filter (where agreement.display_status = 'active')
      over (partition by fc.fc_client_id) as active_anchor_count,
    count(*) filter (where agreement.display_status = 'terminated')
      over (partition by fc.fc_client_id) as terminated_anchor_count,
    count(*) filter (where agreement.display_status = 'stale')
      over (partition by fc.fc_client_id) as stale_anchor_count,
    count(*) filter (where agreement.anchor_relationship_id is not null)
      over (partition by fc.fc_client_id) as total_anchor_count,
    row_number() over (
      partition by fc.fc_client_id
      order by
        case
          when agreement.display_status = 'active' then 1
          when agreement.display_status = 'terminated' then 2
          when agreement.display_status = 'stale' then 3
          else 4
        end,
        agreement.last_updated_at desc nulls last,
        agreement.anchor_relationship_id
    ) as status_rank_row
  from fc
  left join profit_anchor_agreements agreement
    on agreement.client_business_name is not null
   and profit_normalize_client_name(agreement.client_business_name) = fc.normalized_client_name
),
ranked as (
  select *
  from anchor_candidates
  where status_rank_row = 1
)
select
  fc_client_id,
  fc_client_name,
  case when active_anchor_count = 1 then anchor_relationship_id end as anchor_relationship_id,
  case when active_anchor_count = 1 then anchor_client_business_name end as anchor_client_business_name,
  case
    when total_anchor_count = 0 then 'unmatched'
    when active_anchor_count = 1 then 'auto_exact'
    when active_anchor_count > 1 then 'ambiguous'
    -- terminated-only and stale-only rows remain ambiguous; do not lock stale matches.
    else 'ambiguous'
  end as match_status,
  case
    when active_anchor_count = 1 then 1.0
    else null
  end::numeric as match_confidence,
  normalized_client_name,
  display_status as selected_anchor_status,
  active_anchor_count,
  terminated_anchor_count,
  stale_anchor_count,
  total_anchor_count
from ranked;

comment on view profit_fc_client_anchor_match_candidates is
  'Status-ranked FC-to-Anchor match candidates. Truth table: active > terminated > stale > null; exactly one active row is auto_exact; multiple active rows are ambiguous; one active plus terminated/stale is auto_exact to active; terminated-only and stale-only stay ambiguous. Regression locks: E & O Automotive LLC, 1415 Cortez Rd LLC, 6712 Manatee Ave LLC, Kar Kraft Auto Repair LLC (TempleTerrace), Kar Kraft Services LLC (Zephyrhills), YV Enterprises HB LLC, YV Enterprises PSL LLC.';
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: PASS for the `024a` test.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql root@104.225.220.36:/tmp/024a_profit_fc_client_anchor_match_candidates_status_rank.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/024a_profit_fc_client_anchor_match_candidates_status_rank.sql'
```

Expected: `CREATE VIEW`, `COMMENT`.

- [ ] **Step 4: Run Workflow 25 once**

Import Workflow 25 only if the JSON changed. If unchanged, run the existing live `Profit - 25 Auto-Match FC Clients To Anchor` once.

- [ ] **Step 5: Deploy checkpoint**

Run:

```sql
select match_status, coalesce(selected_anchor_status, 'none') as selected_anchor_status, count(*)
from profit_fc_client_anchor_match_candidates
group by 1, 2
order by 1, 2;

select count(*) as persisted_match_rows,
       count(*) filter (where match_method = 'auto_exact') as auto_exact_rows,
       min(loaded_at) as oldest_loaded_at,
       max(loaded_at) as newest_loaded_at
from profit_fc_client_anchor_matches;

select match.fc_client_id,
       match.fc_client_name,
       match.anchor_relationship_id,
       agreement.client_business_name,
       agreement.display_status,
       match.loaded_at
from profit_fc_client_anchor_matches match
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = match.anchor_relationship_id
where match.loaded_at >= now() - interval '15 minutes'
order by match.fc_client_name;

select candidate.fc_client_id,
       candidate.fc_client_name,
       candidate.match_status,
       candidate.selected_anchor_status,
       candidate.active_anchor_count,
       candidate.terminated_anchor_count,
       candidate.stale_anchor_count
from profit_fc_client_anchor_match_candidates candidate
where candidate.fc_client_name in (
  'Schmidli Enterprises LLC',
  'E & O Automotive LLC',
  '1415 Cortez Rd LLC',
  '6712 Manatee Ave LLC',
  'Kar Kraft Auto Repair LLC (TempleTerrace)',
  'Kar Kraft Services LLC (Zephyrhills)',
  'YV Enterprises HB LLC',
  'YV Enterprises PSL LLC'
)
order by candidate.fc_client_name;
```

Expected:

- Schmidli is `auto_exact` to `active`.
- E & O is `ambiguous` if only terminated is visible.
- YV HB and YV PSL are `ambiguous` if stale-only.
- No transitions are applied in this checkpoint.

Stop and report before Task 3.

## Task 3: FC Inactive Signals Helper Red Tests

**Files:**
- Modify `tests/test_fulfillment_audit_queries.py`
- Create later `supabase/sql/025b_profit_audit_helpers.sql`

- [ ] **Step 1: Add failing test for FC inactive signals helper**

Append to `FulfillmentAuditQuerySqlTests`:

```python
    def test_025b_defines_fc_inactive_signals_with_closure_grace(self) -> None:
        sql = SQL_025B.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_audit_fc_inactive_signals", lower)
        self.assertIn("fc_is_archived", lower)
        self.assertIn("fc_archived_at", lower)
        self.assertIn("fc_unarchived_after_archive", lower)
        self.assertIn("has_post_archive_service_delivery", lower)
        self.assertIn("archived_at_missing_for_archived_client", lower)
        self.assertIn("interval '1 day'", lower)
        self.assertIn("closure-batch task completions", lower)
        self.assertIn("Joy Property Management LLC", sql)
```

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: FAIL because `025b_profit_audit_helpers.sql` does not exist or lacks the helper view.

## Task 4: Implement FC Inactive Signals Helper

**Files:**
- Create `supabase/sql/025b_profit_audit_helpers.sql`
- Test `tests/test_fulfillment_audit_queries.py`

- [ ] **Step 1: Create helper migration with FC inactive view**

Create `supabase/sql/025b_profit_audit_helpers.sql` with:

```sql
create or replace view profit_audit_fc_inactive_signals as
select
  client.fc_client_id,
  client.name as fc_client_name,
  coalesce(client.is_archived, false) as fc_is_archived,
  client.archived_at as fc_archived_at,
  (
    coalesce(client.is_archived, false) = false
    and client.archived_at is not null
  ) as fc_unarchived_after_archive,
  (
    coalesce(client.is_archived, false) = true
    and client.archived_at is null
  ) as archived_at_missing_for_archived_client,
  exists (
    select 1
    from profit_fc_task_delivery_classification task
    where task.fc_client_id = client.fc_client_id
      and task.task_kind = 'service_delivery'
      and task.is_completed = true
      -- Closure-batch task completions can fire seconds after archived_at; treat them as offboarding artifact, not re-engagement.
      and task.completed_at > client.archived_at + interval '1 day'
  ) as has_post_archive_service_delivery,
  (
    coalesce(client.is_archived, false) = true
    and client.archived_at is not null
    and not exists (
      select 1
      from profit_fc_task_delivery_classification task
      where task.fc_client_id = client.fc_client_id
        and task.task_kind = 'service_delivery'
        and task.is_completed = true
        and task.completed_at > client.archived_at + interval '1 day'
    )
  ) as qualifies_for_inactive_former_client_review
from profit_fc_clients client;

comment on view profit_audit_fc_inactive_signals is
  'Canonical FC inactive signal view for V0.6.B.2.a. Joy Property Management LLC remains inactive because closure-day 1065 completion happened at archived_at; Saez one-second closure jitter is ignored by the one-day grace.';
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: PASS for existing helper tests.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/025b_profit_audit_helpers.sql root@104.225.220.36:/tmp/025b_profit_audit_helpers.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/025b_profit_audit_helpers.sql'
```

- [ ] **Step 4: Deploy checkpoint**

Run:

```sql
select count(*) as helper_rows,
       count(*) filter (where fc_is_archived) as archived_rows,
       count(*) filter (where fc_unarchived_after_archive) as unarchived_after_archive_rows,
       count(*) filter (where archived_at_missing_for_archived_client) as archived_missing_archived_at_rows,
       count(*) filter (where has_post_archive_service_delivery) as post_archive_service_delivery_rows
from profit_audit_fc_inactive_signals;

select *
from profit_audit_fc_inactive_signals
where fc_client_name ilike '%joy%property%';

select fc_client_name, fc_archived_at, has_post_archive_service_delivery
from profit_audit_fc_inactive_signals
where fc_client_name in ('Saez, Benjamin P', 'Saez, Maggie  (1040)')
order by fc_client_name;
```

Expected:

- `unarchived_after_archive_rows = 0`.
- Joy has `fc_is_archived = true`, `has_post_archive_service_delivery = false`, `qualifies_for_inactive_former_client_review = true`.
- Saez one-second/two-second cases have `has_post_archive_service_delivery = false`.

Stop and report before Task 5.

## Task 5: QBO Leaf/Open Invoice Helper Red Tests

**Files:**
- Modify `tests/test_fulfillment_audit_queries.py`
- Modify later `supabase/sql/025b_profit_audit_helpers.sql`

- [ ] **Step 1: Add failing tests for QBO leaf function and open invoice helper**

Append:

```python
    def test_025b_defines_qbo_leaf_function_and_open_invoice_helper(self) -> None:
        sql = SQL_025B.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_qbo_product_leaf_name", lower)
        self.assertIn("returns text", lower)
        self.assertIn("immutable", lower)
        self.assertIn("Tax Work:1120 Plus", sql)
        self.assertIn("1120 Plus", sql)
        self.assertIn("A:B:C", sql)
        self.assertIn("Tax Work:", sql)
        self.assertIn("create or replace view profit_audit_open_invoice_balance_per_client", lower)
        self.assertIn("open_invoice_balance_amount", lower)
        self.assertIn("open_invoice_count", lower)
        self.assertIn("last_signal_at", lower)
        self.assertIn("voidSynced", sql)
        self.assertIn("not in ('voided', 'cancelled', 'void')", lower)
        self.assertIn("distinct on (client.fc_client_id)", lower)
        self.assertIn("Celtic Auto Werks Inc", sql)
        self.assertIn("YV Enterprises SR LLC", sql)
        self.assertIn("Collectiv Inc", sql)
```

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: FAIL until helper SQL is extended.

## Task 6: Implement QBO Leaf Function And Open Invoice Helper

**Files:**
- Modify `supabase/sql/025b_profit_audit_helpers.sql`
- Test `tests/test_fulfillment_audit_queries.py`

- [ ] **Step 1: Extend helper migration**

Append to `025b_profit_audit_helpers.sql`:

```sql
create or replace function profit_qbo_product_leaf_name(raw_qbo_product_name text)
returns text
language sql
immutable
as $$
  select case
    when raw_qbo_product_name is null then null
    when raw_qbo_product_name like '%:%'
      then split_part(
        raw_qbo_product_name,
        ':',
        array_length(string_to_array(raw_qbo_product_name, ':'), 1)
      )
    else raw_qbo_product_name
  end
$$;

comment on function profit_qbo_product_leaf_name(text) is
  'Extracts the leaf QBO product name from Anchor fully-qualified product strings. Examples: Tax Work:1120 Plus -> 1120 Plus; 1120 Plus -> 1120 Plus; A:B:C -> C; Tax Work: -> empty string; NULL -> NULL.';

create or replace view profit_audit_open_invoice_balance_per_client as
with ranked_matches as (
  select distinct on (client.fc_client_id)
    client.fc_client_id,
    client.name as fc_client_name,
    match.anchor_relationship_id,
    match.anchor_client_business_name,
    agreement.display_status as anchor_display_status
  from profit_fc_clients client
  left join profit_fc_client_anchor_matches match
    on match.fc_client_id = client.fc_client_id
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = match.anchor_relationship_id
  order by
    client.fc_client_id,
    case agreement.display_status
      when 'active' then 1
      when 'terminated' then 2
      when 'stale' then 3
      else 4
    end,
    match.loaded_at desc nulls last,
    match.anchor_relationship_id
),
open_invoice_balance as (
  select
    invoice.anchor_relationship_id,
    sum(greatest(coalesce(invoice.amount_due, 0), 0)) filter (
      where coalesce(invoice.amount_due, 0) > 0
        -- Canonical currently-open predicate for B.2.a. See tech debt: Anchor invoice voids do not propagate to revenue event status.
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    )::numeric as open_invoice_balance_amount,
    count(*) filter (
      where coalesce(invoice.amount_due, 0) > 0
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    )::integer as open_invoice_count,
    max(coalesce((invoice.raw->>'createdAt')::timestamptz, invoice.issue_date, invoice.last_seen_at)) filter (
      where coalesce(invoice.amount_due, 0) > 0
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    ) as last_signal_at,
    array_agg(invoice.invoice_number order by invoice.issue_date desc) filter (
      where coalesce(invoice.amount_due, 0) > 0
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    ) as open_invoice_numbers
  from profit_anchor_invoices invoice
  group by invoice.anchor_relationship_id
)
select
  ranked_matches.fc_client_id,
  ranked_matches.fc_client_name,
  ranked_matches.anchor_relationship_id,
  ranked_matches.anchor_client_business_name,
  coalesce(open_invoice_balance.open_invoice_balance_amount, 0)::numeric as open_invoice_balance_amount,
  coalesce(open_invoice_balance.open_invoice_count, 0)::integer as open_invoice_count,
  open_invoice_balance.last_signal_at,
  coalesce(open_invoice_balance.open_invoice_numbers, array[]::text[]) as open_invoice_numbers
from ranked_matches
left join open_invoice_balance
  on open_invoice_balance.anchor_relationship_id = ranked_matches.anchor_relationship_id;

comment on view profit_audit_open_invoice_balance_per_client is
  'One row per fc_client_id. Source is Anchor invoices, not a QBO collections table. Regression locks: Celtic Auto Werks Inc has only SBC-00134 for 900.00 because SBC-00135 is voidSynced; YV Enterprises SR LLC has 834.60; Collectiv Inc excludes voidSynced SBC-00015.';
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: PASS.

- [ ] **Step 3: Reapply helper migration live**

Run:

```bash
scp -P 2222 supabase/sql/025b_profit_audit_helpers.sql root@104.225.220.36:/tmp/025b_profit_audit_helpers.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/025b_profit_audit_helpers.sql'
```

- [ ] **Step 4: Deploy checkpoint**

Run:

```sql
select count(*) as helper_rows,
       count(distinct fc_client_id) as distinct_fc_clients
from profit_audit_open_invoice_balance_per_client;

select fc_client_name, anchor_relationship_id, open_invoice_balance_amount, open_invoice_count, last_signal_at, open_invoice_numbers
from profit_audit_open_invoice_balance_per_client
where fc_client_name in ('Celtic Auto Werks Inc', 'YV Enterprises SR LLC', 'Collectiv LLC')
order by fc_client_name;

select profit_qbo_product_leaf_name('Tax Work:1120 Plus') as tax_leaf,
       profit_qbo_product_leaf_name('1120 Plus') as no_colon_leaf,
       profit_qbo_product_leaf_name('A:B:C') as multi_colon_leaf,
       profit_qbo_product_leaf_name('Tax Work:') as trailing_colon_leaf,
       profit_qbo_product_leaf_name(null) as null_leaf;
```

Expected:

- `helper_rows = distinct_fc_clients`.
- Celtic `open_invoice_balance_amount = 900.00`, `open_invoice_count = 1`.
- YV Enterprises SR LLC `open_invoice_balance_amount = 834.60`.
- Collectiv `open_invoice_balance_amount = 0`.
- Leaf outputs: `1120 Plus`, `1120 Plus`, `C`, empty string, `NULL`.

Stop and report before Task 7.

## Task 7: Re-Emergence Scan V2 Red Tests

**Files:**
- Modify `tests/test_fulfillment_classification_sql.py`
- Create later `supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql`

- [ ] **Step 1: Add SQL-shape and behavior-lock assertions**

Extend `tests/test_fulfillment_classification_sql.py`:

```python
SQL_025C = ROOT / "supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql"
```

Add:

```python
    def test_migration_025c_replaces_reemergence_scan_with_v2_guards(self) -> None:
        sql = SQL_025C.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_run_inactive_client_reemergence_scan", lower)
        self.assertIn("profit_audit_fc_inactive_signals", lower)
        self.assertIn("profit_audit_open_invoice_balance_per_client", lower)
        self.assertIn("fc_client_unarchived", sql)
        self.assertIn("fc_client_became_active", sql)
        self.assertIn("active_anchor_agreement_created", sql)
        self.assertIn("service_delivery_task_completed", sql)
        self.assertIn("open_invoice_balance_returned", sql)
        self.assertIn("agreement.effective_date > record_to_scan.classified_at", lower)
        self.assertIn("task.completed_at > record_to_scan.classified_at", lower)
        self.assertIn("open_balance.last_signal_at > record_to_scan.classified_at", lower)
        self.assertIn("Joy Property Management LLC", sql)
        self.assertIn("backdated agreements", lower)
        self.assertIn("effective_date <= classified_at", lower)
```

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: FAIL because `025c` does not exist.

## Task 8: Implement And Deploy 025c Scan V2

**Files:**
- Create `supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql`
- Test `tests/test_fulfillment_classification_sql.py`

- [ ] **Step 1: Create migration**

Create `supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql`:

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
      classification.classified_at,
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
      from profit_audit_fc_inactive_signals signal
      where signal.fc_client_id = record_to_scan.fc_client_id
        and signal.fc_unarchived_after_archive = true
    ) then
      reason := 'fc_client_unarchived';
    elsif exists (
      select 1
      from profit_audit_fc_inactive_signals signal
      where signal.fc_client_id = record_to_scan.fc_client_id
        and signal.fc_is_archived = false
        and (
          signal.fc_archived_at < record_to_scan.classified_at
          or signal.fc_archived_at is null
        )
    ) then
      reason := 'fc_client_became_active';
    elsif exists (
      select 1
      from profit_fc_client_anchor_matches match
      join profit_anchor_agreements agreement
        on agreement.anchor_relationship_id = match.anchor_relationship_id
      where match.fc_client_id = record_to_scan.fc_client_id
        and agreement.display_status = 'active'
        and agreement.effective_date > record_to_scan.classified_at
    ) then
      reason := 'active_anchor_agreement_created';
    elsif exists (
      select 1
      from profit_fc_task_delivery_classification task
      where task.fc_client_id = record_to_scan.fc_client_id
        and task.task_kind = 'service_delivery'
        and task.is_completed = true
        and task.completed_at > record_to_scan.classified_at
        and task.completed_at >= (p_run_at - interval '365 days')
    ) then
      reason := 'service_delivery_task_completed';
    elsif exists (
      select 1
      from profit_audit_open_invoice_balance_per_client open_balance
      where open_balance.fc_client_id = record_to_scan.fc_client_id
        and open_balance.open_invoice_balance_amount > 0
        and open_balance.last_signal_at > record_to_scan.classified_at
    ) then
      reason := 'open_invoice_balance_returned';
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
        record_to_scan.source_audit_row_hash || ':reemergence-v2:' || p_run_at::date::text,
        'inactive_client_reemerged',
        record_to_scan.estimated_annual_revenue,
        'Re-emergence scan v2 superseded INACTIVE_FORMER_CLIENT because signal returned: ' || reason,
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

comment on function profit_run_inactive_client_reemergence_scan(timestamptz) is
  'V0.6.B.2.a scan v2. Supersedes active INACTIVE_FORMER_CLIENT rows only when post-classification signals return. Known limitation: backdated agreements with effective_date <= classified_at do not auto-fire because Anchor exposes no created/signed timestamp; audit candidate any-active-signal filter is the safety net. Regression locks: Joy Property Management LLC returns 0; backdated agreements are manual-review only.';
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: PASS.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql root@104.225.220.36:/tmp/025c_profit_inactive_client_reemergence_scan_v2.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/025c_profit_inactive_client_reemergence_scan_v2.sql'
```

- [ ] **Step 4: Deploy checkpoint**

Run:

```sql
select count(*) as reemergence_fn
from pg_proc
where proname = 'profit_run_inactive_client_reemergence_scan';

select count(*) as unarchived_after_archive
from profit_audit_fc_inactive_signals
where fc_unarchived_after_archive;

select *
from profit_run_inactive_client_reemergence_scan(now());

select count(*) as joy_reemergence_rows
from profit_run_inactive_client_reemergence_scan(now()) result
join profit_fc_clients client
  on client.fc_client_id = result.fc_client_id
where client.name ilike '%joy%property%';

select count(*) as active_inactive_former_client_rows
from profit_classifications
where verdict_code = 'INACTIVE_FORMER_CLIENT'
  and superseded_at is null;
```

Expected:

- Function count `1`.
- `unarchived_after_archive = 0`.
- Scan returns `0 rows`.
- `joy_reemergence_rows = 0`.
- Active `INACTIVE_FORMER_CLIENT` remains `1`.

Stop and report before Task 9.

## Task 9: Audit Views And Diagnostics Red Tests

**Files:**
- Modify `tests/test_fulfillment_audit_queries.py`
- Create later `supabase/sql/025_profit_fulfillment_audit_views.sql`

- [ ] **Step 1: Add failing audit view tests**

Append:

```python
    def test_025_defines_layered_audit_views_and_diagnostics(self) -> None:
        sql = SQL_025.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace view profit_fulfillment_audit_fc_activity", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_anchor_signals", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_group_signals", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_candidates", lower)
        self.assertIn("create or replace view profit_fulfillment_audit_qbo_category_gaps", lower)
        self.assertIn("any_active_signal", lower)
        self.assertIn("default_visibility", lower)
        self.assertIn("coalesce(verdict.default_visibility, 'show')", lower)
        self.assertIn("distinct on (client.fc_client_id)", lower)
        self.assertIn("profit_qbo_product_leaf_name", lower)
        self.assertIn("qbo_product_match_status", lower)
        self.assertIn("missing_qbo_product", lower)
        self.assertIn("missing_qbo_category", lower)
        self.assertIn("canonical_service_name_unresolved", lower)
        self.assertIn("sample_revenue_event_keys", lower)
        self.assertIn("sample_invoice_numbers", lower)
        self.assertIn("limit 5", lower)
        self.assertIn("Joy Property Management LLC", sql)
        self.assertIn("Hornauer", sql)
        self.assertIn("Inatsuka", sql)
```

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: FAIL because `025` does not exist.

## Task 9.5: Audit View Schema Sniff Gate

**Files:**
- No file changes

- [ ] **Step 1: Read live schemas before writing the audit view migration**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -P pager=off -c "\d+ profit_anchor_line_item_classifications" -c "\d+ profit_revenue_events" -c "\d+ profit_anchor_invoices"'
```

Confirm:

- `profit_anchor_line_item_classifications` exists.
- `profit_anchor_line_item_classifications.anchor_line_item_id` exists.
- `profit_anchor_line_item_classifications.qbo_product_name` exists.
- `profit_revenue_events.anchor_line_item_id` exists.
- `profit_anchor_invoices.invoice_number` exists.

- [ ] **Step 2: Stop and report schema findings**

If any column path differs, update Task 10's SQL before creating `025_profit_fulfillment_audit_views.sql`. Do not write migration `025` until this schema gate is approved.

## Task 10: Implement Layered Audit Views And Diagnostic View

**Files:**
- Create `supabase/sql/025_profit_fulfillment_audit_views.sql`
- Test `tests/test_fulfillment_audit_queries.py`

- [ ] **Step 1: Create audit views migration**

Create `supabase/sql/025_profit_fulfillment_audit_views.sql` with these view contracts:

```sql
create or replace view profit_fulfillment_audit_fc_activity as
select
  client.fc_client_id,
  client.name as fc_client_name,
  inactive.fc_is_archived,
  inactive.fc_archived_at,
  inactive.fc_unarchived_after_archive,
  inactive.has_post_archive_service_delivery,
  inactive.archived_at_missing_for_archived_client,
  count(task.*) filter (
    where task.task_kind = 'service_delivery'
      and task.is_completed = true
      and task.completed_at >= current_date - interval '365 days'
  )::integer as service_delivery_task_count_365d,
  max(task.completed_at) filter (
    where task.task_kind = 'service_delivery'
      and task.is_completed = true
  ) as latest_service_delivery_completed_at,
  exists (
    select 1
    from profit_fc_client_tags tag
    where tag.fc_client_id = client.fc_client_id
      and tag.tag_type in ('service', 'group')
  ) as has_fc_group_or_service_tag
from profit_fc_clients client
left join profit_audit_fc_inactive_signals inactive
  on inactive.fc_client_id = client.fc_client_id
left join profit_fc_task_delivery_classification task
  on task.fc_client_id = client.fc_client_id
group by client.fc_client_id, client.name, inactive.fc_is_archived, inactive.fc_archived_at,
  inactive.fc_unarchived_after_archive, inactive.has_post_archive_service_delivery,
  inactive.archived_at_missing_for_archived_client;

create or replace view profit_fulfillment_audit_anchor_signals as
with ranked_matches as (
  select distinct on (client.fc_client_id)
    client.fc_client_id,
    client.name as fc_client_name,
    match.anchor_relationship_id,
    match.anchor_client_business_name,
    agreement.display_status as anchor_display_status,
    agreement.effective_date as anchor_effective_date,
    match.loaded_at as match_loaded_at
  from profit_fc_clients client
  left join profit_fc_client_anchor_matches match
    on match.fc_client_id = client.fc_client_id
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = match.anchor_relationship_id
  order by
    client.fc_client_id,
    case agreement.display_status
      when 'active' then 1
      when 'terminated' then 2
      when 'stale' then 3
      else 4
    end,
    match.loaded_at desc nulls last,
    match.anchor_relationship_id
)
select
  ranked_matches.fc_client_id,
  ranked_matches.fc_client_name,
  ranked_matches.anchor_relationship_id,
  ranked_matches.anchor_client_business_name,
  ranked_matches.anchor_display_status,
  ranked_matches.anchor_effective_date,
  exists (
    select 1
    from profit_anchor_invoices invoice
    where invoice.anchor_relationship_id = ranked_matches.anchor_relationship_id
      and invoice.issue_date >= current_date - interval '365 days'
  ) as has_anchor_invoice_365d,
  open_balance.open_invoice_balance_amount,
  open_balance.open_invoice_count,
  open_balance.last_signal_at as open_invoice_last_signal_at
from ranked_matches
left join profit_audit_open_invoice_balance_per_client open_balance
  on open_balance.fc_client_id = ranked_matches.fc_client_id;

create or replace view profit_fulfillment_audit_group_signals as
select
  client.fc_client_id,
  client.name as fc_client_name,
  count(distinct member.group_id)::integer as group_count,
  array_agg(distinct group_table.group_name order by group_table.group_name) filter (
    where group_table.group_name is not null
  ) as group_names,
  bool_or(member.active) as has_active_group_membership
from profit_fc_clients client
left join profit_client_group_members member
  on member.fc_client_id = client.fc_client_id
left join profit_client_groups group_table
  on group_table.group_id = member.group_id
group by client.fc_client_id, client.name;

create or replace view profit_fulfillment_audit_qbo_category_gaps as
with event_products as (
  select
    event.revenue_event_key,
    event.anchor_invoice_id,
    event.source_amount,
    event.canonical_service_name,
    line.qbo_product_name as qbo_product_name_raw,
    profit_qbo_product_leaf_name(line.qbo_product_name) as qbo_product_leaf_name,
    product.qbo_product_id,
    product.qbo_product_name,
    product.qbo_category_path,
    product.active as qbo_product_active,
    invoice.invoice_number,
    invoice.issue_date,
    case
      when product.qbo_product_id is null then 'missing_qbo_product'
      when product.qbo_category_path is null then 'missing_qbo_category'
      else 'matched'
    end as qbo_product_match_status,
    case
      when product.qbo_product_id is null then 'qbo_product_missing'
      when product.qbo_category_path is null then 'qbo_category_missing_on_product'
      when event.canonical_service_name is null then 'canonical_service_name_unresolved'
      else null
    end as gap_origin
  from profit_revenue_events event
  left join profit_anchor_line_item_classifications line
    on line.anchor_line_item_id = event.anchor_line_item_id
  left join profit_qbo_product_services product
    on product.qbo_product_name = profit_qbo_product_leaf_name(line.qbo_product_name)
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
),
gaps as (
  select *
  from event_products
  where gap_origin is not null
)
select
  gap_origin,
  qbo_product_match_status,
  qbo_product_name_raw,
  qbo_product_leaf_name,
  qbo_product_id,
  qbo_product_name,
  qbo_category_path,
  qbo_product_active,
  count(*)::integer as revenue_event_count,
  count(*) filter (where canonical_service_name is null)::integer as canonical_unresolved_event_count,
  sum(source_amount)::numeric as total_source_amount,
  array(
    select recent.revenue_event_key
    from gaps recent
    where coalesce(recent.qbo_product_leaf_name, '') = coalesce(gaps.qbo_product_leaf_name, '')
      and recent.gap_origin = gaps.gap_origin
    order by recent.issue_date desc nulls last, recent.source_amount desc
    limit 5
  ) as sample_revenue_event_keys,
  array(
    select distinct recent.invoice_number
    from gaps recent
    where coalesce(recent.qbo_product_leaf_name, '') = coalesce(gaps.qbo_product_leaf_name, '')
      and recent.gap_origin = gaps.gap_origin
      and recent.invoice_number is not null
    order by recent.invoice_number
    limit 5
  ) as sample_invoice_numbers
from gaps
group by gap_origin, qbo_product_match_status, qbo_product_name_raw, qbo_product_leaf_name,
  qbo_product_id, qbo_product_name, qbo_category_path, qbo_product_active;

create or replace view profit_fulfillment_audit_candidates as
select
  client.fc_client_id,
  client.name as fc_client_name,
  classification.classification_id as current_classification_id,
  classification.verdict_code as current_verdict_code,
  coalesce(verdict.default_visibility, 'show') as default_visibility,
  classification.re_evaluate_at,
  fc_activity.fc_is_archived,
  fc_activity.fc_archived_at,
  fc_activity.fc_unarchived_after_archive,
  fc_activity.has_post_archive_service_delivery,
  fc_activity.archived_at_missing_for_archived_client,
  anchor.anchor_relationship_id,
  anchor.anchor_client_business_name,
  anchor.anchor_display_status,
  anchor.has_anchor_invoice_365d,
  anchor.open_invoice_balance_amount,
  group_signals.group_names,
  (
    coalesce(fc_activity.fc_is_archived, false) = false
    or coalesce(fc_activity.service_delivery_task_count_365d, 0) > 0
    or anchor.anchor_relationship_id is not null
    or anchor.has_anchor_invoice_365d
    or coalesce(anchor.open_invoice_balance_amount, 0) > 0
    or fc_activity.has_fc_group_or_service_tag
    or classification.re_evaluate_at <= current_date
  ) as any_active_signal
from profit_fc_clients client
left join lateral (
  select classification.*
  from profit_classifications classification
  where classification.fc_client_id = client.fc_client_id
    and classification.superseded_at is null
  order by classification.classified_at desc, classification.classification_id desc
  limit 1
) classification on true
left join profit_classification_verdicts verdict
  on verdict.verdict_code = classification.verdict_code
left join profit_fulfillment_audit_fc_activity fc_activity
  on fc_activity.fc_client_id = client.fc_client_id
left join profit_fulfillment_audit_anchor_signals anchor
  on anchor.fc_client_id = client.fc_client_id
left join profit_fulfillment_audit_group_signals group_signals
  on group_signals.fc_client_id = client.fc_client_id
where (
  coalesce(fc_activity.fc_is_archived, false) = false
  or coalesce(fc_activity.service_delivery_task_count_365d, 0) > 0
  or anchor.anchor_relationship_id is not null
  or anchor.has_anchor_invoice_365d
  or coalesce(anchor.open_invoice_balance_amount, 0) > 0
  or fc_activity.has_fc_group_or_service_tag
  or classification.re_evaluate_at <= current_date
);

comment on view profit_fulfillment_audit_candidates is
  'V0.6.B.2.a backend candidate view. Applies any-active-signal filter; UI default visibility must use profit_classification_verdicts.default_visibility. Unclassified candidates surface with default_visibility = show because they need manual classification by definition. Regression examples for B.2.b: Joy Property Management LLC hidden unless show-all/history; Hornauer/Wong healthy group-billed rows hidden by verdict; Inatsuka annual deliverables must not be satisfied by unrelated monthly parent billing.';

comment on view profit_fulfillment_audit_qbo_category_gaps is
  'QBO/product/category/canonical-service diagnostic view. Samples are capped at five most recent invoice rows per gap using issue_date desc then source_amount desc.';
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_audit_queries.py -q
```

Expected: PASS.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/025_profit_fulfillment_audit_views.sql root@104.225.220.36:/tmp/025_profit_fulfillment_audit_views.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/025_profit_fulfillment_audit_views.sql'
```

- [ ] **Step 4: Deploy checkpoint**

Run:

```sql
select count(*) from information_schema.views
where table_name in (
  'profit_fulfillment_audit_fc_activity',
  'profit_fulfillment_audit_anchor_signals',
  'profit_fulfillment_audit_group_signals',
  'profit_fulfillment_audit_candidates',
  'profit_fulfillment_audit_qbo_category_gaps'
);

select count(*) as candidate_count,
       count(*) filter (where default_visibility = 'show') as default_visible_count,
       count(*) filter (where default_visibility = 'hide') as hidden_count,
       count(*) filter (where any_active_signal) as active_signal_count
from profit_fulfillment_audit_candidates;

select count(*) as unclassified_visible
from profit_fulfillment_audit_candidates
where current_classification_id is null
  and default_visibility = 'show';

select count(*) as anchor_signal_rows,
       count(distinct fc_client_id) as distinct_anchor_signal_clients
from profit_fulfillment_audit_anchor_signals;

select gap_origin, qbo_product_match_status, count(*) as gap_rows, sum(revenue_event_count) as revenue_events
from profit_fulfillment_audit_qbo_category_gaps
group by 1, 2
order by 1, 2;

select *
from profit_fulfillment_audit_qbo_category_gaps
order by revenue_event_count desc
limit 20;

-- Hornauer/Wong group-billed rows should be hidden by default when classified as CONSOLIDATED_VIA_GROUP_BILLED.
select fc_client_name, current_verdict_code, default_visibility
from profit_fulfillment_audit_candidates
where fc_client_name ilike any (array['%hornauer%', '%ndh%', '%dvh%', '%knw%', '%wong%'])
order by fc_client_name;

-- Inatsuka annual deliverable: surface signals so monthly parent billing does not silently hide annual work.
select fc_client_name, current_verdict_code, default_visibility, anchor_display_status, has_anchor_invoice_365d
from profit_fulfillment_audit_candidates
where fc_client_name ilike '%inatsuka%'
   or fc_client_name ilike '%lti%'
order by fc_client_name;
```

Expected:

- All five views exist.
- Candidate count is nonzero and plausible.
- `unclassified_visible` is nonzero.
- `anchor_signal_rows = distinct_anchor_signal_clients`.
- QBO diagnostic view surfaces `missing_qbo_product` for Strategic Advisory and `canonical_service_name_unresolved` rows; NULL-category product rows may appear only if revenue-impacting.
- Hornauer/Wong regression query reports verdicts and visibility flags for spot-check.
- Inatsuka/LTI regression query reports annual-deliverable signal state for spot-check.

Stop and report before Task 11.

## Task 11: Transition Apply Function Red Tests

**Files:**
- Modify `tests/test_fulfillment_classification_sql.py`
- Create later `supabase/sql/025d_profit_apply_classification_transitions.sql`

- [ ] **Step 1: Add function-shape tests**

Extend `tests/test_fulfillment_classification_sql.py`:

```python
SQL_025D = ROOT / "supabase/sql/025d_profit_apply_classification_transitions.sql"
```

Add:

```python
    def test_migration_025d_defines_apply_transitions_with_dry_run(self) -> None:
        sql = SQL_025D.read_text(encoding="utf-8")
        lower = sql.lower()

        self.assertIn("create or replace function profit_apply_classification_transitions", lower)
        self.assertIn("p_dry_run boolean default true", lower)
        self.assertIn("classification_id bigint", lower)
        self.assertIn("fc_client_id bigint", lower)
        self.assertIn("fc_client_name text", lower)
        self.assertIn("from_verdict_code text", lower)
        self.assertIn("signal_name text", lower)
        self.assertIn("to_verdict_code text", lower)
        self.assertIn("anchor_relationship_id text", lower)
        self.assertIn("anchor_client_business_name text", lower)
        self.assertIn("evidence_summary jsonb", lower)
        self.assertIn("would_create_classification_id bigint", lower)
        self.assertIn("if not p_dry_run then", lower)
        self.assertIn("rule.enabled = true", lower)
        self.assertIn("superseded_at is null", lower)
        self.assertIn("active_agreement_appears", sql)
        self.assertIn("only active_agreement_appears", lower)
        self.assertIn("remaining seeded rules", lower)
        self.assertIn("Schmidli Enterprises LLC", sql)
        self.assertIn("E & O Automotive LLC", sql)
        self.assertIn("dry-run writes zero rows", lower)
        self.assertIn("idempotent", lower)
```

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: FAIL because `025d` does not exist.

## Task 12: Implement And Deploy 025d Apply Transitions

**Files:**
- Create `supabase/sql/025d_profit_apply_classification_transitions.sql`
- Test `tests/test_fulfillment_classification_sql.py`

- [ ] **Step 1: Create migration**

Create `supabase/sql/025d_profit_apply_classification_transitions.sql`:

```sql
create or replace function profit_apply_classification_transitions(
  p_run_at timestamptz default now(),
  p_dry_run boolean default true
)
returns table (
  classification_id bigint,
  fc_client_id bigint,
  fc_client_name text,
  from_verdict_code text,
  signal_name text,
  to_verdict_code text,
  anchor_relationship_id text,
  anchor_client_business_name text,
  evidence_summary jsonb,
  would_create_classification_id bigint
)
language plpgsql
as $$
declare
  transition_record record;
  inserted_id bigint;
begin
  for transition_record in
    select
      classification.classification_id,
      classification.fc_client_id,
      client.name as fc_client_name,
      classification.verdict_code as from_verdict_code,
      rule.signal_name,
      rule.to_verdict_code,
      match.anchor_relationship_id,
      match.anchor_client_business_name,
      jsonb_build_object(
        'anchor_relationship_id', match.anchor_relationship_id,
        'anchor_client_business_name', match.anchor_client_business_name,
        'display_status', agreement.display_status,
        'effective_date', agreement.effective_date
      ) as evidence_summary,
      classification.source_audit_file,
      classification.source_audit_row_hash,
      classification.estimated_annual_revenue
    from profit_classifications classification
    join profit_fc_clients client
      on client.fc_client_id = classification.fc_client_id
    join profit_classification_transition_rules rule
      on rule.from_verdict_code = classification.verdict_code
     and rule.signal_name = 'active_agreement_appears'
     and rule.enabled = true
    join profit_fc_client_anchor_matches match
      on match.fc_client_id = classification.fc_client_id
    join profit_anchor_agreements agreement
      on agreement.anchor_relationship_id = match.anchor_relationship_id
     and agreement.display_status = 'active'
    where classification.superseded_at is null
      and classification.verdict_code in ('PENDING_ENGAGEMENT_DRAFT', 'PENDING_ENGAGEMENT_SENT')
    order by classification.classification_id
  loop
    inserted_id := null;

    if not p_dry_run then
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
        transition_record.fc_client_id,
        transition_record.to_verdict_code,
        transition_record.from_verdict_code,
        transition_record.source_audit_file,
        transition_record.source_audit_row_hash || ':transition:' || transition_record.signal_name || ':' || p_run_at::date::text,
        'auto_transition_' || transition_record.signal_name,
        transition_record.estimated_annual_revenue,
        'Auto-transitioned from ' || transition_record.from_verdict_code || ' to ' || transition_record.to_verdict_code || ' because signal returned: ' || transition_record.signal_name,
        'system',
        p_run_at,
        p_run_at::date,
        transition_record.signal_name,
        p_run_at
      )
      returning profit_classifications.classification_id into inserted_id;

      update profit_classifications
      set
        superseded_at = p_run_at,
        superseded_by_classification_id = inserted_id,
        updated_at = now()
      where profit_classifications.classification_id = transition_record.classification_id
        and profit_classifications.superseded_at is null;
    end if;

    classification_id := transition_record.classification_id;
    fc_client_id := transition_record.fc_client_id;
    fc_client_name := transition_record.fc_client_name;
    from_verdict_code := transition_record.from_verdict_code;
    signal_name := transition_record.signal_name;
    to_verdict_code := transition_record.to_verdict_code;
    anchor_relationship_id := transition_record.anchor_relationship_id;
    anchor_client_business_name := transition_record.anchor_client_business_name;
    evidence_summary := transition_record.evidence_summary;
    would_create_classification_id := inserted_id;
    return next;
  end loop;
end;
$$;

comment on function profit_apply_classification_transitions(timestamptz, boolean) is
  'B.2.a scope: only active_agreement_appears is applied today; remaining seeded rules become live in V0.6.C. Applies enabled fulfillment classification transition rules for PENDING_ENGAGEMENT_DRAFT/SENT. Dry-run writes zero rows and returns the same selection. Live apply is append-friendly and idempotent because it only acts on superseded_at is null. Regression locks: Schmidli Enterprises LLC transitions PENDING_SENT -> MIXED; E & O Automotive LLC and unmatched PENDING_SENT rows do not transition.';
```

- [ ] **Step 2: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_fulfillment_classification_sql.py -q
```

Expected: PASS.

- [ ] **Step 3: Apply migration live**

Run:

```bash
scp -P 2222 supabase/sql/025d_profit_apply_classification_transitions.sql root@104.225.220.36:/tmp/025d_profit_apply_classification_transitions.sql
ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f /tmp/025d_profit_apply_classification_transitions.sql'
```

- [ ] **Step 4: Dry-run checkpoint**

Run:

```sql
select count(*) as classifications_before_dry_run
from profit_classifications;

select verdict_code, count(*)
from profit_classifications
where superseded_at is null
  and verdict_code in ('PENDING_ENGAGEMENT_SENT', 'PENDING_ENGAGEMENT_DRAFT', 'MIXED')
group by 1
order by 1;

select *
from profit_apply_classification_transitions(now(), true);

select count(*) as classifications_after_dry_run
from profit_classifications;
```

Expected dry-run:

- One row: Schmidli Enterprises LLC.
- `would_create_classification_id is null`.
- `classifications_before_dry_run = classifications_after_dry_run`.
- No counts changed.

- [ ] **Step 5: Disabled-rule behavior checkpoint**

Run before live apply:

```sql
update profit_classification_transition_rules
set enabled = false
where from_verdict_code = 'PENDING_ENGAGEMENT_SENT'
  and signal_name = 'active_agreement_appears';

select count(*) as transitions_when_sent_rule_disabled
from profit_apply_classification_transitions(now(), true);

update profit_classification_transition_rules
set enabled = true
where from_verdict_code = 'PENDING_ENGAGEMENT_SENT'
  and signal_name = 'active_agreement_appears';

select from_verdict_code, signal_name, enabled
from profit_classification_transition_rules
where from_verdict_code = 'PENDING_ENGAGEMENT_SENT'
  and signal_name = 'active_agreement_appears';
```

Expected:

- `transitions_when_sent_rule_disabled = 0`.
- The final state query returns `enabled = true`.

- [ ] **Step 6: Live apply checkpoint**

After orchestrator confirms the dry-run row list, run:

```sql
select count(*) as classifications_before_live_apply
from profit_classifications;

select *
from profit_apply_classification_transitions(now(), false);

select verdict_code, count(*)
from profit_classifications
where superseded_at is null
  and verdict_code in ('PENDING_ENGAGEMENT_SENT', 'PENDING_ENGAGEMENT_DRAFT', 'MIXED')
group by 1
order by 1;

select count(*) as classifications_after_live_apply
from profit_classifications;

select *
from profit_apply_classification_transitions(now(), false);

select count(*) as classifications_after_second_live_apply
from profit_classifications;
```

Expected:

- First live apply returns Schmidli with populated `would_create_classification_id`.
- Active `PENDING_ENGAGEMENT_SENT` changes `14 -> 13`.
- Active `MIXED` changes `1 -> 2`.
- Second live apply returns `0 rows`.
- `classifications_after_live_apply = classifications_before_live_apply + 1`.
- `classifications_after_second_live_apply = classifications_after_live_apply`.

Stop and report before Task 13.

## Task 13: Documentation Updates

**Files:**
- Modify `docs/data-contracts/fulfillment-classifications.md`
- Modify `docs/tech-debt.md`

- [ ] **Step 1: Update fulfillment classifications data contract**

Extend `docs/data-contracts/fulfillment-classifications.md` with:

```markdown
### Re-Emergence Scan V2

V0.6.B.2.a replaces `profit_run_inactive_client_reemergence_scan(timestamptz)` in place. The signature is unchanged. The scan reads canonical helper views instead of duplicating inactive or open-invoice predicates.

Reason codes:

- `fc_client_unarchived`
- `fc_client_became_active`
- `active_anchor_agreement_created`
- `service_delivery_task_completed`
- `open_invoice_balance_returned`

#### Known limitation: backdated agreements

Anchor does not expose a true agreement create/sign timestamp. Scan v2 uses `profit_anchor_agreements.effective_date > classified_at` as the activation proxy. Backdated agreements whose `effective_date <= classified_at` may not auto-supersede inactive classifications. The audit candidate view's any-active-signal filter is the safety net and must surface active agreements for manual review.

#### Known limitation: open-balance signal

`open_invoice_balance_returned` fires only when a currently open invoice was created after `classified_at`. If an existing invoice's balance changes from paid to unpaid, Anchor invoice payloads currently do not expose a reliable balance-change timestamp. The audit candidate view surfaces positive open invoice balance for manual review even when scan v2 cannot auto-supersede.

### Audit Query Helpers

- `profit_audit_fc_inactive_signals`: canonical FC archived/unarchived/offboarding signal source.
- `profit_qbo_product_leaf_name(text)`: canonical Anchor QBO product leaf extractor.
- `profit_audit_open_invoice_balance_per_client`: one row per FC client, sourced from Anchor invoices and Workflow 25 matches.
- `profit_fulfillment_audit_qbo_category_gaps`: QBO product/category and canonical-service diagnostic view.

### Apply Transitions

`profit_apply_classification_transitions(timestamptz, boolean)` supports dry-run and live apply using the same selection logic. When `p_dry_run = true`, it returns transition candidates and performs zero writes. When `p_dry_run = false`, it inserts a new `profit_classifications` row and supersedes the prior row.

B.2.a scope is narrow: only `active_agreement_appears` is applied for `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT`. The other nine transition rules seeded in B.1 remain inactive executable paths until V0.6.C pipeline orchestration.
```

- [ ] **Step 2: Add tech debt entries**

Add to `docs/tech-debt.md`:

```markdown
- `profit_anchor_agreements` does not yet surface active reissued agreements for roughly 12 of the V0.6.B.1-seeded `PENDING_ENGAGEMENT_SENT` rows. Direct Anchor API inspection on 2026-05-07 confirmed the active agreements exist; Workflow 05 Anchor agreement sync has not surfaced them. Once sync coverage improves or Workflow 05 is rerun against the full agreement set, the `active_agreement_appears` transition will fire on the next pipeline run and these rows will auto-flip to `MIXED` for manual reclassification. V0.6.B.2.b dashboard should surface them as standard pending review in the meantime.
- QBO product category gaps remain upstream cleanup work. G4 confirmed 10 QBO products with `qbo_category_path is null`: Accounting, Accounting and Tax Services Bundle, Advisory, Other, Payroll, Sales Tax Advanced (deleted), Sales Tax Essential (deleted), Sales Tax Plus (deleted), Tax Work, and TPP Florida. Current revenue events do not hit these rows after leaf-name matching, so they are diagnostic-only. Manual review or upstream QBO cleanup is needed.
- Anchor invoice raw payload does not expose `updatedAt`, `lastUpdatedAt`, or `paidAt`. `profit_audit_open_invoice_balance_per_client` derives `last_signal_at` from invoice `createdAt` as a proxy for new-open-invoice events. It cannot detect retroactive paid-to-unpaid balance changes. Revisit if Anchor exposes invoice update timestamps.
- Anchor agreement create/activation timestamp gap. `effective_date` is the begin date of the agreement, not its signing or creation timestamp. Scan v2 uses `effective_date > classified_at` as the activation proxy and may miss backdated active agreements. The audit candidate view's any-active-signal filter surfaces them as a fallback. Revisit if Anchor adds a `created_at` or `signed_at` field, or if backdated agreements become operationally common.
```

- [ ] **Step 3: Run doc/static tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py tests/test_fulfillment_audit_queries.py tests/test_fulfillment_classification_sql.py -q
```

Expected: PASS.

## Task 14: Full Verification And Scope Check

**Files:**
- All B.2.a files

- [ ] **Step 1: Run targeted B.2.a suite**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest \
  tests/test_fulfillment_audit_queries.py \
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

Expected files are limited to B.2.a:

```text
docs/data-contracts/fulfillment-classifications.md
docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.a-audit-query-refactor.md
docs/tech-debt.md
supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql
supabase/sql/025_profit_fulfillment_audit_views.sql
supabase/sql/025b_profit_audit_helpers.sql
supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql
supabase/sql/025d_profit_apply_classification_transitions.sql
tests/test_fulfillment_audit_queries.py
tests/test_fulfillment_classification_sql.py
```

Optional, only if changed for checkpoint summaries:

```text
n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json
```

Must not show:

```text
app/frontend/**
profit_api/**
supabase/sql/026_*
supabase/sql/027_*
docs/audits/2026-05-04-fulfillment-leaks-classification.csv
docs/audits/2026-05-07-unresolved-service-names.csv
```

- [ ] **Step 4: Final live checkpoint**

Run:

```sql
select count(*) from profit_fc_client_anchor_match_candidates;
select count(*) from profit_audit_fc_inactive_signals;
select count(*) from profit_audit_open_invoice_balance_per_client;
select count(*) from profit_fulfillment_audit_candidates;
select count(*) from profit_fulfillment_audit_qbo_category_gaps;
select * from profit_run_inactive_client_reemergence_scan(now());
select * from profit_apply_classification_transitions(now(), true);
select verdict_code, count(*)
from profit_classifications
where superseded_at is null
group by 1
order by 1;
```

Expected:

- All views/functions callable.
- Re-emergence scan returns `0 rows`.
- Transition dry-run returns `0 rows` if Schmidli was already applied, or Schmidli only if transition apply was deferred.

- [ ] **Step 5: Stop for final orchestrator spot-check**

Report:

- Targeted and full pytest results.
- Live checkpoint counts.
- Workflow 25 rerun effect.
- Schmidli transition effect or dry-run status.
- Scope boundary output.

Wait for approval before Task 15.

## Task 15: Commit And Push

**Files:**
- All approved B.2.a files

- [ ] **Step 1: Final pytest sweep**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Stage explicit files**

Use explicit file list:

```bash
git add docs/data-contracts/fulfillment-classifications.md \
        docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.a-audit-query-refactor.md \
        docs/tech-debt.md \
        supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql \
        supabase/sql/025_profit_fulfillment_audit_views.sql \
        supabase/sql/025b_profit_audit_helpers.sql \
        supabase/sql/025c_profit_inactive_client_reemergence_scan_v2.sql \
        supabase/sql/025d_profit_apply_classification_transitions.sql \
        tests/test_fulfillment_audit_queries.py \
        tests/test_fulfillment_classification_sql.py
```

Add Workflow 25 explicitly only if it changed:

```bash
git add n8n/workflows/profit-25-auto-match-fc-clients-to-anchor.json
```

- [ ] **Step 3: Commit**

Use a structured commit message:

```bash
git commit -m "Add V0.6.B.2.a fulfillment audit query backend"
```

Commit body should mention:

- Status-aware FC-to-Anchor match candidate ranking.
- Canonical helper views for inactive FC signals, QBO product leaf extraction, and open invoice balance.
- Re-emergence scan v2 with transition guards and open-invoice signal.
- Layered fulfillment audit views and QBO/category diagnostic view.
- Dry-run/live auto-transition apply function.
- No frontend/API/dashboard implementation.

- [ ] **Step 4: Push**

Run:

```bash
git push
```

- [ ] **Step 5: Final report**

Report:

- Commit hash.
- Pytest result.
- Live checkpoint one-liner.
- Confirmation that V0.6.B.2.b frontend/API work is now unblocked.

## Self-Review Checklist

- [ ] G1 truth table is implemented in `024a` and Workflow 25 remains the canonical writer.
- [ ] G2 inactive criteria live in one helper view, with one-day closure-grace comment and unarchive-after-archive boolean.
- [ ] G3 scan v2 keeps same function name/signature and documents the backdated-agreement limitation.
- [ ] G4 QBO product leaf extraction is a single scalar function; diagnostic samples are capped.
- [ ] G5 open invoice balance helper is one row per `fc_client_id`, uses Anchor invoices, excludes voids, and exposes `last_signal_at`.
- [ ] G6 transition function has dry-run/live modes, enabled-rule guard, idempotency, and evidence JSON.
- [ ] `025d` apply function only fires the `active_agreement_appears` signal; the other nine seeded transition rules remain inactive in B.2.a and are deferred to V0.6.C pipeline orchestration.
- [ ] Migration `026` remains unused/reserved for V0.6.C.
- [ ] No frontend, API, V0.6.C, V0.6.D, audit CSV, or alias-seeding files are touched.
- [ ] `profit_classifications` remains append-friendly: changes insert new rows and supersede old rows.
- [ ] Plan has concrete deploy commands and checkpoint queries for every live migration.
