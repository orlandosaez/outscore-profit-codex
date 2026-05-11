# Profit Dashboard V0.7.A Manual Invoice Verdict And Weekly Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface active manual-billing agreements with completed FC work and no issued Anchor invoice as `MANUAL_INVOICE_PENDING`, then show those rows in a universal `/profit/admin/weekly-review` queue.

**Architecture:** V0.7.A extends the existing classification verdict system. SQL owns manual-invoice detection, the new verdict seed, transition eligibility, review-state persistence, and the universal queue projection; FastAPI exposes a focused Weekly Review API; React renders a queue shell that V0.7.B-D can extend by registering additional visible verdict types. Task 1 is an operator-run live data profile gate before any migration work.

**Tech Stack:** Supabase Postgres migrations/views/functions, existing verdict classification tables and transition function, FastAPI service layer, existing Supabase REST client, React/Vite admin frontend, existing shared dashboard primitives, Python `pytest` static/service tests, `npm run build`.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: V0.6 verdict canon, route doctrine, transition doctrine, and audit/SLA dashboard conventions.
- `docs/data-contracts/fulfillment-classifications.md`: current verdict lookup, classification history, transition rules, pipeline apply function contract, and auto-transition semantics.
- `docs/superpowers/plans/2026-05-07-profit-dashboard-v0.6.B.1-verdict-persistence-and-seed.md`: migration/test style for verdict lookup and transition rule seeds.
- `docs/superpowers/plans/2026-05-09-profit-dashboard-v0.6.D-sla-dashboard.md`: task format, migration numbering precedent, operator-gated Task 1 pattern, and self-review structure.
- `supabase/sql/023_profit_fulfillment_classifications.sql`: current `profit_classification_verdicts`, `profit_classifications`, and `profit_classification_transition_rules` schema.
- `supabase/sql/024a_profit_fc_client_anchor_match_candidates_status_rank.sql`: active Anchor match candidate behavior and match-status ranking.
- `supabase/sql/025_profit_fulfillment_audit_views.sql`, `025b_profit_audit_helpers.sql`, `025c_profit_inactive_client_reemergence_scan_v2.sql`, `025d_profit_apply_classification_transitions.sql`: audit helper/view and transition precedents.
- `supabase/sql/026a_profit_apply_classification_transitions_v2.sql`: current function to replace in migration `029`.
- `supabase/sql/028_profit_sla_core_views.sql`, `028a_profit_sla_backfill_and_performance_views.sql`: latest SQL view layering and migration numbering precedent.
- `profit_api/audit.py`, `profit_api/sla.py`, `profit_api/app.py`: current API service, validation, route, and Supabase store patterns.
- `app/frontend/src/App.jsx`, `app/frontend/src/routes/AuditDashboard.jsx`, `app/frontend/src/routes/SlaDashboard.jsx`, `app/frontend/src/components/EmptyState.jsx`, `app/frontend/src/components/PortalNav.jsx`, `app/frontend/src/routes/Dashboard.jsx`: route, fetch, table, nav, shared component, and `Stat` usage patterns.
- `docs/data-contracts/anchor-sync.md`: Anchor agreement raw payload contains `profitSyncServiceSummary` with service `trigger`, `occurrence`, `status`, and billing metadata.
- `docs/data-references/anchor services.csv`: service-level `Billing Trigger` snapshot used only as profiling evidence.

## Gate Decisions Locked Into This Plan

### G1: Manual Billing Detection

LOCKED: Live `profit_anchor_agreements.raw->profitSyncServiceSummary[*].trigger = 'Manual'` (agreement-level). Task 1 validates the exact path. Service-level CSV is fallback only.

Reasoning:

- Runtime detection must use synced live Anchor agreement data, not a historical CSV.
- Agreement-level service summary wins over the service-level CSV when both signals are present.
- Task 1 still validates exact JSON syntax, casing, and coverage before migration `029` is written.

### G2: Auto-Clear Trigger

LOCKED: TWO CLEARANCE CONDITIONS:

- Primary: Auto-clear when matching Anchor invoice is issued (transitions verdict to `INVOICE_OUTSTANDING_PAYMENT_PENDING`).
- Secondary: Auto-clear when agreement is terminated (transitions verdict to a terminated-state equivalent - your call on which existing verdict to use, or document as a "no-op resolution" where the row is just superseded with no successor verdict).
- Both conditions land in the migration's `verdict_transitions` data + the `profit_apply_classification_transitions` function path.

Reasoning:

- Invoice issuance is the direct resolution of the missing manual-invoice action.
- Termination is a distinct clearance condition because the pending manual invoice row should not stay actionable after the agreement is no longer active.
- Draft invoices keep `MANUAL_INVOICE_PENDING`; only issued non-draft Anchor invoices clear the verdict.

### G3: Weekly Review Route Shape

LOCKED: Universal queue shell from day 1. V0.7.A shows only `MANUAL_INVOICE_PENDING` rows; the route is architected so V0.7.B-D verdicts plug in without rework. Use a `verdict_code` filter that defaults to all visible types - V0.7.A registers only the manual-invoice type.

Reasoning:

- V0.7.B-D are expected to add more weekly-review verdict families.
- A universal SQL/API/UI contract is cheap if V0.7.A registers one visible type.
- The UI should not render empty future sections; it should only expose the generic queue shape.

### G4: Reviewed/Snooze Persistence

LOCKED: New table `profit_weekly_review_item_state`. Columns to include at minimum: `classification_id` (FK), `reviewed_at` (timestamptz, null = unreviewed), `snoozed_until` (date, null = not snoozed), `operator_id` (text, default 'orlando' until V0.7.E adds multi-operator), `practice_id` (text, null = legacy single-practice - see G6), `created_at`/`updated_at`. No write through classifications table.

Reasoning:

- Review state is queue/operator state, not classification history.
- Keeping state out of `profit_classifications` preserves audit semantics and keeps V0.7.E multi-operator work isolated.
- The queue can still join state by `classification_id` in V0.7.A because all visible items are classification verdicts.

### G5: Invoice Trigger Affordance

LOCKED: Link out to Anchor UI. URL template: `https://app.anchor.com/agreements/<agreement_id>` (or whatever Task 1 confirms is the correct Anchor URL structure). NO direct Anchor API call. Tech-debt note: proper deep-link discovery later.

Reasoning:

- Direct invoice issuance is externally visible financial behavior and adds authentication, idempotency, draft review, and error-recovery scope.
- Link-out preserves Orlando's manual Anchor workflow while V0.7.A focuses on detection and clearing.
- Task 1 may confirm a different raw URL or agreement URL pattern; if it does, the plan's URL construction should use that confirmed pattern.

### G6: Multi-Tenancy

LOCKED: Lightweight `practice_id` column on new contracts only: `profit_weekly_review_item_state` and any new SQL views you create for the Weekly Review. Default NULL. Do NOT retrofit `practice_id` onto existing tables (verdict_codes, profit_classifications, etc.) in V0.7.A. That's V0.7.E.

Reasoning:

- Full practice retrofitting belongs in V0.7.E.
- New V0.7.A contracts can carry nullable `practice_id` without changing existing table ownership.
- V0.7.A must not change global verdict-code or classification schemas for multi-tenancy.

### G7: Aging / Sort

LOCKED: Show all pending rows for the verdict types in scope, sorted by classification age (desc - oldest first). No threshold filter in V0.7.A.

Reasoning:

- A threshold would hide the leakage this slice is meant to expose.
- Classification age is available for every queue row and avoids overfitting to a Task 1-specific completion-date path.
- Revenue and client-name tie-breakers are allowed, but must not suppress any pending rows.

## Resolved Decisions

- **OQ1:** Agreement-level wins if both signals present. Service-level is fallback.
- **OQ2:** Draft invoices keep the verdict pending. Verdict clears only on issued non-draft Anchor invoice.
- **OQ3:** Hardcoded URL template `https://app.anchor.com/agreements/<agreement_id>` unless Task 1 confirms a better exact pattern from raw payload. Tech-debt note for deep-link API discovery.
- **OQ4:** Two distinct UI semantics: `Snooze 7 days` sets `snoozed_until = today + 7` and hides the row until the snooze date passes; `Mark Reviewed` sets `reviewed_at = now()` and hides the row until the classification state changes. A `Show reviewed` toggle surfaces reviewed rows.
- **OQ5:** Stale terminated/reopened cleanup transitions are deferred to V0.7.D. V0.7.A documents the gap in tech debt.

## Migration Numbering

Use the next available migration number after C.b `027`/`027a` and V0.6.D `028`/`028a`:

- `supabase/sql/029_profit_manual_invoice_pending_verdict.sql`: verdict seed, transition-rule data, manual-invoice candidate view, and `profit_apply_classification_transitions` replacement for issued-invoice and terminated-agreement clearance.
- `supabase/sql/029a_profit_weekly_review_items.sql`: `profit_weekly_review_item_state`, visible verdict registry if needed, and `profit_weekly_review_items` queue view.

Do not create `029b` in V0.7.A unless implementation discovers a real migration dependency that cannot be safely ordered inside `029`/`029a`; if that happens, stop and surface `DECISION NEEDED`.

## Scope

In scope:

- New verdict code `MANUAL_INVOICE_PENDING`.
- SQL detection view for active agreements with manual billing, completed FC work, and no issued matching Anchor invoice.
- SQL transition rules and transition-function logic for issued invoice and terminated agreement clearance.
- SQL Weekly Review projection view that defaults to all registered visible verdicts and registers only `MANUAL_INVOICE_PENDING` in V0.7.A.
- Review state persistence for `reviewed_at` and `snoozed_until`.
- FastAPI Weekly Review read endpoint plus reviewed/snooze mutations.
- Frontend route `/admin/weekly-review`, rendered at `/profit/admin/weekly-review`.
- Portal navigation link and optional dashboard summary tile if it fits without modifying shared V0.6.C.5 components or scroll anchors.
- Tests and data-contract updates.

Out of scope:

- Calling Anchor APIs to create, draft, send, or modify invoices.
- Folding SLA, audit due reclassifications, stuck triggers, or backfill queues into Weekly Review.
- Full V0.7.E M&A/practice configuration layer.
- Retrofitting `practice_id` onto existing verdict/classification/source tables.
- Modifying V0.6.C.5 shared components or scroll anchor ids on `Dashboard.jsx`.
- Manual Recognition UI polish.
- Stale terminated/reopened cleanup transitions beyond V0.7.A's locked clearance semantics and tech-debt note.
- Deploying, running migrations, or committing during this plan-only turn.

## File Structure

Create:

- `supabase/sql/029_profit_manual_invoice_pending_verdict.sql`: seeds `MANUAL_INVOICE_PENDING`, inserts transition-rule rows, creates `profit_manual_invoice_pending_candidates`, and replaces `profit_apply_classification_transitions` with manual-invoice clearance branches.
- `supabase/sql/029a_profit_weekly_review_items.sql`: creates `profit_weekly_review_item_state`, optional `profit_weekly_review_visible_verdicts`, and `profit_weekly_review_items`.
- `profit_api/weekly_review.py`: Weekly Review service, validation, queue read, mark-reviewed mutation, and snooze mutation.
- `app/frontend/src/routes/WeeklyReview.jsx`: universal queue route populated by `MANUAL_INVOICE_PENDING` in V0.7.A.
- `tests/test_weekly_review_api.py`: service and route tests for list/filter/action behavior.
- `docs/data-contracts/weekly-review.md`: queue contract, row shape, state semantics, registered visible verdicts, and future-extension rules.

Modify:

- `tests/test_fulfillment_classification_sql.py`: extend existing verdict/transition SQL static tests for migration `029`.
- `tests/test_profit_admin_frontend.py`: extend existing frontend static tests for route, nav, endpoints, toggles, and action controls.
- `tests/test_data_references_docs.py`: extend docs tests for Weekly Review and fulfillment-classification contract coverage.
- `profit_api/app.py`: register Weekly Review API routes and service injection.
- `app/frontend/src/App.jsx`: add `/admin/weekly-review`.
- `app/frontend/src/components/PortalNav.jsx`: add Weekly Review nav entry.
- `app/frontend/src/routes/Dashboard.jsx`: add a compact Weekly Review tile only if the existing grid can absorb one without touching shared C.5 components or scroll anchors.
- `app/frontend/src/styles.css`: append route-scoped styles under `/* === V0.7.A: Weekly review === */`.
- `docs/data-contracts/fulfillment-classifications.md`: document `MANUAL_INVOICE_PENDING`, clearance semantics, and deferred cleanup gap.
- `docs/tech-debt.md`: add deferred deep-link discovery and stale terminated/reopened cleanup notes.

Do not modify:

- `app/frontend/src/components/EmptyState.jsx`, `PipelineStatusBanner.jsx`, or other V0.6.C.5 shared component internals.
- Existing `Dashboard.jsx` scroll anchor ids.
- Existing Audit Dashboard bulk-classification UX.
- Existing SLA route behavior except optional nav/dashboard links.
- n8n workflows in V0.7.A unless Task 1 proves a sync gap that blocks detection; if so, stop and surface `DECISION NEEDED`.

## Sub-Decisions Made

- API path uses a new focused module, `profit_api/weekly_review.py`, because Weekly Review is a queue/action surface rather than an audit classification editor.
- SQL uses two migrations only: `029` for verdict/detection/transition core and `029a` for queue state/projection.
- Review state is keyed by `classification_id` in V0.7.A because the registered queue type is classification-only; future non-classification rows can add a stable review key in V0.7.B-D if needed.
- `practice_id` is nullable and defaults to `NULL` in new SQL contracts, matching the locked lightweight multi-tenancy decision.
- `operator_id` defaults to `'orlando'`; UI/API may pass an explicit operator later, but V0.7.A does not add multi-operator identity management.
- Agreement termination clearance should prefer an existing terminated/former-client verdict if Task 1 confirms the appropriate current code. If no existing verdict is semantically correct, implement and document the no-op resolution path.
- The route fetches all visible verdicts by default. V0.7.A may expose a verdict filter control, but its only populated option is `MANUAL_INVOICE_PENDING`.

## Sub-Decisions Surfaced As DECISION NEEDED

- None at plan-refinement time. During Task 1, stop and surface `DECISION NEEDED` only if live payload paths contradict the locked G1/G2/G5 assumptions or if the existing transition function cannot represent terminated-agreement no-op resolution without schema changes.

## Task Breakdown

Each implementation task below follows red test -> green implementation -> checkpoint verification -> commit. Do not combine commits across tasks unless Orlando explicitly changes the execution model. Task 1 is operator-direct and intentionally has no commit.

### Task 1: Operator Data Profile Gate

**Suggested tier:** 3 (orchestrator-direct)

**Reasoning:** No repo file changes; requires live Supabase/Anchor evidence and business interpretation before code paths are locked.

**Purpose:** Validate exact live Anchor paths and invoice/termination semantics before migration `029`.

**Files:**

- No committed file changes.
- Read/query live Supabase tables only.
- Do not write migrations, API code, frontend code, docs, or commits in this task.

- [ ] **Step 1: Profile manual trigger path**

  Query live `profit_anchor_agreements` samples for Schmidli and 10-20 active agreements with service summaries.

  Required evidence:

  - exact path for `raw->profitSyncServiceSummary[*].trigger`
  - casing for `Manual`
  - service identifiers/names available on each service row
  - agreement id field needed for the Anchor link template
  - row count for active agreements with at least one manual-trigger service

- [ ] **Step 2: Compare agreement-level and service-level signals**

  Check whether a separate agreement-level billing-trigger field exists in `raw`.

  Expected: agreement-level service summary is canonical. If a stronger agreement-level billing-trigger field exists and contradicts `profitSyncServiceSummary[*].trigger`, stop and report `DECISION NEEDED`.

- [ ] **Step 3: Profile issued vs draft invoice state**

  Query `profit_anchor_invoices` schema and representative rows for status/draft fields such as `display_status`, `qbo_status`, `issue_date`, `invoice_number`, `amount_due`, and raw status fields.

  Expected: identify the exact predicate for issued non-draft invoices. Draft invoices must not clear `MANUAL_INVOICE_PENDING`.

- [ ] **Step 4: Prove Schmidli wedge**

  Show Schmidli has an active agreement, a manual service, completed FC work, and zero issued matching Anchor invoice rows under the Step 3 predicate.

  Expected: sample rows are sufficient for implementation to encode the generic SQL without guessing.

- [ ] **Step 5: Profile termination signal**

  Confirm the exact live agreement status/date fields that indicate termination.

  Expected: document the SQL predicate for terminated agreement clearance and recommend either an existing terminated-state verdict or no-op resolution.

- [ ] **Step 6: Confirm Anchor link pattern**

  Confirm whether `https://app.anchor.com/agreements/<agreement_id>` opens the correct Anchor UI or whether raw payload contains a better URL field.

  Expected: final URL pattern for `action_url`; if no reliable pattern exists, stop and report `DECISION NEEDED`.

- [ ] **Step 7: Decision checkpoint**

  If all locked assumptions hold, report exact field paths, predicates, sample rows, and final G1/G2/G5 implementation notes.

  If any required source signal is absent or materially different, stop and report `DECISION NEEDED` with the specific table, column/path, and downstream task impacted.

- [ ] **Step 8: Commit**

  No commit for Task 1. Expected normal result: operational evidence only.

### Task 2: Verdict Seed, Candidate View, And Clearance Rules

**Suggested tier:** 1

**Reasoning:** Mostly static SQL contract work that extends existing verdict and transition patterns in one migration.

**Purpose:** Add the manual-invoice verdict, queue candidate view, transition-rule rows, and function branches in migration `029`.

**Files:**

- Create: `supabase/sql/029_profit_manual_invoice_pending_verdict.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`
- Modify: `docs/data-contracts/fulfillment-classifications.md`

- [ ] **Step 1: Write red static SQL tests**

  Extend `tests/test_fulfillment_classification_sql.py` proving:

  - `supabase/sql/029_profit_manual_invoice_pending_verdict.sql` exists.
  - The migration inserts `MANUAL_INVOICE_PENDING` into `profit_classification_verdicts`.
  - The migration inserts transition data for `manual_invoice_issued` -> `INVOICE_OUTSTANDING_PAYMENT_PENDING`.
  - The migration inserts transition data for `manual_invoice_agreement_terminated` or documents a no-op resolution path.
  - The migration creates `profit_manual_invoice_pending_candidates`.
  - The candidate view references `profit_anchor_agreements`, `profit_anchor_invoices`, `profit_classifications`, and the Task 1-confirmed manual-trigger JSON path.
  - The candidate view excludes issued non-draft matching invoices and keeps draft invoices pending.
  - The candidate view exposes `classification_id`, `classified_at`, `verdict_code`, `fc_client_id`, `anchor_relationship_id`, `agreement_id`, `client_name`, `service_name`, `invoice_state`, `age_days`, `estimated_annual_revenue`, and `action_url`.
  - The migration uses `create or replace function profit_apply_classification_transitions` with the existing function signature.

- [ ] **Step 2: Run red tests**

  Run: `pytest tests/test_fulfillment_classification_sql.py -q`

  Expected: FAIL because migration `029_profit_manual_invoice_pending_verdict.sql` does not exist or lacks required contracts.

- [ ] **Step 3: Implement migration `029`**

  Create `supabase/sql/029_profit_manual_invoice_pending_verdict.sql` with:

  - idempotent verdict seed for `MANUAL_INVOICE_PENDING`
  - enabled transition-rule rows for issued-invoice and terminated-agreement clearance
  - `profit_manual_invoice_pending_candidates` using Task 1-confirmed raw paths and issued-invoice predicate
  - `action_url` built from the Task 1-confirmed Anchor URL pattern
  - `age_days` based on classification age, sorted oldest-first downstream
  - `profit_apply_classification_transitions` replacement preserving existing V0.6.C.a branches and adding manual-invoice branches

- [ ] **Step 4: Update fulfillment classification contract**

  Modify `docs/data-contracts/fulfillment-classifications.md` to document:

  - `MANUAL_INVOICE_PENDING` semantics
  - draft invoice behavior
  - issued-invoice clearance
  - terminated-agreement clearance or no-op resolution
  - deferred stale terminated/reopened cleanup gap for V0.7.D

- [ ] **Step 5: Run green static tests**

  Run: `pytest tests/test_fulfillment_classification_sql.py -q`

  Expected: PASS for existing classification SQL tests and new V0.7.A contracts.

- [ ] **Step 6: SQL checkpoint**

  Review `029` against `026a_profit_apply_classification_transitions_v2.sql` and confirm legacy/group/cash transition behavior was preserved.

  Expected: only the manual-invoice branches and related transition rules are new.

- [ ] **Step 7: Commit**

  Commit message: `feat: add manual invoice pending verdict`

### Task 3: Weekly Review State Table And Queue View

**Suggested tier:** 1

**Reasoning:** New SQL table/view with clear contracts and low API/UI coupling.

**Purpose:** Persist reviewed/snooze state and expose a universal queue view for visible verdicts.

**Files:**

- Create: `supabase/sql/029a_profit_weekly_review_items.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`
- Create: `docs/data-contracts/weekly-review.md`
- Modify: `tests/test_data_references_docs.py`

- [ ] **Step 1: Write red SQL tests**

  Extend `tests/test_fulfillment_classification_sql.py` proving:

  - `supabase/sql/029a_profit_weekly_review_items.sql` exists.
  - The migration creates `profit_weekly_review_item_state`.
  - The state table includes `classification_id bigint references profit_classifications`, `reviewed_at timestamptz`, `snoozed_until date`, `operator_id text not null default 'orlando'`, `practice_id text`, `created_at timestamptz`, and `updated_at timestamptz`.
  - The migration creates `profit_weekly_review_items`.
  - The queue view includes `practice_id`, `item_type`, `verdict_code`, `classification_id`, `reviewed_at`, `snoozed_until`, `operator_id`, `action_url`, `age_days`, and `sort_rank`.
  - The queue view filters to registered visible verdicts and V0.7.A registers only `MANUAL_INVOICE_PENDING`.
  - The queue view does not write to `profit_classifications`.

- [ ] **Step 2: Write red docs tests**

  Extend `tests/test_data_references_docs.py` proving docs mention:

  - `docs/data-contracts/weekly-review.md`
  - `profit_weekly_review_item_state`
  - `profit_weekly_review_items`
  - `Snooze 7 days`
  - `Show reviewed`
  - `MANUAL_INVOICE_PENDING`
  - `practice_id` nullable until V0.7.E

- [ ] **Step 3: Run red tests**

  Run:

  - `pytest tests/test_fulfillment_classification_sql.py -q`
  - `pytest tests/test_data_references_docs.py -q`

  Expected: FAIL because migration `029a` and `docs/data-contracts/weekly-review.md` do not exist.

- [ ] **Step 4: Implement migration `029a`**

  Create `supabase/sql/029a_profit_weekly_review_items.sql` with:

  - `profit_weekly_review_item_state`
  - an `updated_at` trigger or explicit update mechanism consistent with existing SQL style
  - optional `profit_weekly_review_visible_verdicts` registry seeded with `MANUAL_INVOICE_PENDING`
  - `profit_weekly_review_items` joined from `profit_manual_invoice_pending_candidates` and left-joined review state
  - `sort_rank` ordering oldest classifications first, then revenue desc nulls last, then client name asc

- [ ] **Step 5: Create Weekly Review data contract**

  Create `docs/data-contracts/weekly-review.md` documenting:

  - table/view responsibilities
  - queue row fields
  - default filtering rules for reviewed and snoozed rows
  - `Show reviewed` and `include_snoozed` semantics
  - nullable `practice_id`
  - future verdict-registration rules for V0.7.B-D

- [ ] **Step 6: Run green tests**

  Run:

  - `pytest tests/test_fulfillment_classification_sql.py -q`
  - `pytest tests/test_data_references_docs.py -q`

  Expected: PASS.

- [ ] **Step 7: Commit**

  Commit message: `feat: add weekly review queue state`

### Task 4: Transition Safety And Live SQL Checkpoint

**Suggested tier:** 3 (orchestrator-direct)

**Reasoning:** The transition function is high-leverage SQL and must be checked against live/manual evidence before API/UI work depends on it.

**Purpose:** Verify migration `029` transition semantics, especially terminated-agreement clearance and preservation of existing transition behavior.

**Files:**

- Modify only if gaps are found: `supabase/sql/029_profit_manual_invoice_pending_verdict.sql`
- Modify only if gaps are found: `tests/test_fulfillment_classification_sql.py`
- Modify only if gaps are found: `docs/data-contracts/fulfillment-classifications.md`

- [ ] **Step 1: Write or tighten red transition tests if needed**

  If Task 2 did not fully lock transition safety, extend `tests/test_fulfillment_classification_sql.py` proving:

  - `manual_invoice_issued` appears in transition data and function logic.
  - `manual_invoice_agreement_terminated` appears in transition data and function logic, or no-op resolution is explicitly documented in SQL comments.
  - Draft invoice status is excluded from the issued-invoice branch.
  - The function still contains existing V0.6.C.a transition signals.

- [ ] **Step 2: Run red or regression tests**

  Run: `pytest tests/test_fulfillment_classification_sql.py tests/test_pipeline_backend_sql.py -q`

  Expected: FAIL only if Step 1 added stricter tests that expose a migration gap; otherwise PASS.

- [ ] **Step 3: Patch transition logic only if needed**

  Update `029_profit_manual_invoice_pending_verdict.sql` to satisfy the stricter transition contract without changing unrelated branches.

  Expected: issued-invoice and terminated-agreement clearance are both encoded, and existing transition priorities remain stable.

- [ ] **Step 4: Run green transition tests**

  Run: `pytest tests/test_fulfillment_classification_sql.py tests/test_pipeline_backend_sql.py -q`

  Expected: PASS.

- [ ] **Step 5: Live-safe SQL checkpoint**

  In an operator-approved environment after migrations are staged/applied for verification, run:

  - `select verdict_code from profit_classification_verdicts where verdict_code = 'MANUAL_INVOICE_PENDING';`
  - `select trigger_code, to_verdict_code from profit_classification_transition_rules where from_verdict_code = 'MANUAL_INVOICE_PENDING' order by trigger_code;`
  - `select * from profit_manual_invoice_pending_candidates limit 20;`
  - `select * from profit_apply_classification_transitions(now(), true) limit 20;`

  Expected: verdict and transition rules exist, candidate view queries, dry-run transition function returns rows or an empty set without errors.

- [ ] **Step 6: Commit**

  Commit message: `test: verify manual invoice transitions`

  Commit only if this task changed tests, docs, or SQL. If it only reports live evidence, no commit is required.

### Task 5: Weekly Review API

**Suggested tier:** 1

**Reasoning:** Small FastAPI extension using existing service and store patterns.

**Purpose:** Expose read and action endpoints for the Weekly Review queue.

**Files:**

- Create: `profit_api/weekly_review.py`
- Create: `tests/test_weekly_review_api.py`
- Modify: `profit_api/app.py`

- [ ] **Step 1: Write red API service tests**

  Add `tests/test_weekly_review_api.py` with a fake store proving:

  - list reads `profit_weekly_review_items`
  - default list excludes rows with `reviewed_at` populated
  - default list excludes rows with `snoozed_until >= current_date`
  - rows with `snoozed_until < current_date` resurface
  - `include_reviewed=true` includes reviewed rows
  - `include_snoozed=true` includes currently snoozed rows
  - `verdict_code` defaults to all visible types and accepts `MANUAL_INVOICE_PENDING`
  - `limit` clamps to 1-200
  - sorting uses SQL-provided `sort_rank`

- [ ] **Step 2: Write red API action tests**

  In `tests/test_weekly_review_api.py`, prove:

  - `POST /api/profit/admin/weekly-review/items/{classification_id}/reviewed` upserts `profit_weekly_review_item_state` with `reviewed_at = now()` and `operator_id = 'orlando'` by default.
  - `POST /api/profit/admin/weekly-review/items/{classification_id}/snooze` upserts `snoozed_until = current_date + 7`.
  - invalid `classification_id` returns 422.
  - unsupported `verdict_code` returns 422.
  - action routes do not insert/update `profit_classifications`.

- [ ] **Step 3: Run red API tests**

  Run: `pytest tests/test_weekly_review_api.py -q`

  Expected: FAIL because `profit_api.weekly_review` and routes do not exist.

- [ ] **Step 4: Implement service module**

  Create `profit_api/weekly_review.py` with:

  - `WeeklyReviewStore` protocol matching existing `read_view`, `insert_rows`, and `patch_rows`/upsert-equivalent usage
  - `WeeklyReviewService.list_items`
  - `WeeklyReviewService.mark_reviewed`
  - `WeeklyReviewService.snooze`
  - validation errors shaped consistently with `audit.py` and `sla.py`
  - default `operator_id = 'orlando'`

- [ ] **Step 5: Register API routes**

  Modify `profit_api/app.py` to add:

  - optional `weekly_review_service` injection to `create_app`
  - `GET /api/profit/admin/weekly-review/items`
  - `POST /api/profit/admin/weekly-review/items/{classification_id}/reviewed`
  - `POST /api/profit/admin/weekly-review/items/{classification_id}/snooze`
  - 422 mapping for validation errors

- [ ] **Step 6: Run green API tests and regression**

  Run:

  - `pytest tests/test_weekly_review_api.py -q`
  - `pytest tests/test_profit_api_audit.py tests/test_profit_api_sla.py tests/test_profit_api_dashboard.py tests/test_profit_api_pipeline.py -q`

  Expected: PASS; existing audit/SLA/dashboard/pipeline routes remain unchanged.

- [ ] **Step 7: Commit**

  Commit message: `feat: expose weekly review API`

### Task 6: Weekly Review Frontend Route

**Suggested tier:** 2

**Reasoning:** Bounded UI work touching route, nav, dashboard, styles, and static frontend tests.

**Purpose:** Add the universal Weekly Review route and V0.7.A manual-invoice actions.

**Files:**

- Create: `app/frontend/src/routes/WeeklyReview.jsx`
- Modify: `app/frontend/src/App.jsx`
- Modify: `app/frontend/src/components/PortalNav.jsx`
- Modify: `app/frontend/src/routes/Dashboard.jsx` only if tile fits without shared-component or anchor changes
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write red frontend route tests**

  Extend `tests/test_profit_admin_frontend.py` proving:

  - `App.jsx` imports `WeeklyReview`.
  - `App.jsx` registers `/admin/weekly-review`.
  - `PortalNav.jsx` links to `/admin/weekly-review` with label `Weekly Review`.
  - `WeeklyReview.jsx` exists.
  - `WeeklyReview.jsx` fetches `/profit/admin/weekly-review/items`.
  - `WeeklyReview.jsx` includes `MANUAL_INVOICE_PENDING`.
  - `WeeklyReview.jsx` includes controls for `Show reviewed`, `Snooze 7 days`, and `Mark reviewed`.
  - `WeeklyReview.jsx` uses `EmptyState` or existing empty/loading conventions.

- [ ] **Step 2: Write red frontend action/style tests**

  Extend `tests/test_profit_admin_frontend.py` proving:

  - `WeeklyReview.jsx` posts to `/weekly-review/items/` action endpoints.
  - `WeeklyReview.jsx` renders an Anchor link when `action_url` exists.
  - `styles.css` contains `/* === V0.7.A: Weekly review === */`.
  - route-scoped selectors are prefixed with `weekly-review` or `weekly-`.
  - `Dashboard.jsx` does not change existing scroll anchor ids if a tile is added.

- [ ] **Step 3: Run red frontend tests**

  Run: `pytest tests/test_profit_admin_frontend.py -q`

  Expected: FAIL because the route and registrations do not exist.

- [ ] **Step 4: Implement route shell and fetch state**

  Create `app/frontend/src/routes/WeeklyReview.jsx` with:

  - route-local loading/error/empty states
  - query state for `verdict_code`, `include_reviewed`, and `include_snoozed`
  - default fetch with no verdict filter or with all visible V0.7.A verdicts
  - summary strip using existing `Stat` pattern where practical
  - table columns for age, client, service, evidence, amount/revenue, action, and state

- [ ] **Step 5: Implement actions and navigation**

  Modify frontend files to:

  - register `/admin/weekly-review`
  - add PortalNav entry
  - optionally add a compact dashboard tile without modifying shared components or scroll anchors
  - post `Mark reviewed`
  - post `Snooze 7 days`
  - open Anchor via `action_url`
  - refresh the row list after successful actions

- [ ] **Step 6: Add scoped CSS**

  Append CSS under `/* === V0.7.A: Weekly review === */`.

  Expected styling constraints:

  - no cards inside cards
  - stable table/control dimensions
  - mobile-safe overflow for table rows
  - restrained operational dashboard layout
  - no modifications to V0.6.C.5 shared component internals

- [ ] **Step 7: Run green frontend tests and build**

  Run:

  - `pytest tests/test_profit_admin_frontend.py -q`
  - `cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build`

  Expected: PASS.

- [ ] **Step 8: Commit**

  Commit message: `feat: add weekly review route`

### Task 7: Integration, Docs, And Tech Debt Updates

**Suggested tier:** 3 (orchestrator-direct)

**Reasoning:** Cross-checks plan compliance, docs, deferred scope, and deployment readiness across SQL/API/UI.

**Purpose:** Ensure V0.7.A is coherent and future slices have the right contracts.

**Files:**

- Modify: `docs/data-contracts/weekly-review.md`
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md`
- Modify: `tests/test_data_references_docs.py`

- [ ] **Step 1: Write red docs/static tests for remaining contract gaps**

  Extend `tests/test_data_references_docs.py` if needed to prove:

  - Weekly Review docs mention default visible verdict filtering.
  - Weekly Review docs mention reviewed rows reappear via `Show reviewed`.
  - Fulfillment docs mention both clearance conditions.
  - Tech debt mentions Anchor deep-link discovery.
  - Tech debt mentions stale terminated/reopened cleanup deferred to V0.7.D.
  - Docs state `practice_id` is nullable in V0.7.A and full practice routing is deferred to V0.7.E.

- [ ] **Step 2: Run red or regression docs tests**

  Run: `pytest tests/test_data_references_docs.py -q`

  Expected: FAIL only if Step 1 found missing doc coverage; otherwise PASS.

- [ ] **Step 3: Patch docs**

  Update docs to close only V0.7.A contract gaps:

  - do not document future V0.7.B-D queue rows as implemented
  - do not claim Anchor API send support
  - do not claim full multi-practice support
  - keep stale terminated/reopened cleanup as deferred V0.7.D tech debt

- [ ] **Step 4: Run focused verification**

  Run:

  - `pytest tests/test_fulfillment_classification_sql.py tests/test_weekly_review_api.py tests/test_profit_admin_frontend.py tests/test_data_references_docs.py -q`
  - `cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build`

  Expected: PASS.

- [ ] **Step 5: Scope checkpoint**

  Confirm:

  - no V0.7.B-D queues were added
  - no Anchor invoice-send API mutation exists
  - no existing tables were retrofitted with `practice_id`
  - no V0.6.C.5 shared component internals changed
  - no `Dashboard.jsx` scroll anchor ids changed

- [ ] **Step 6: Commit**

  Commit message: `docs: document weekly review contracts`

  Commit only if docs/tests changed in this task.

### Task 8: Deploy And Live Verification

**Suggested tier:** 3 (orchestrator-direct)

**Reasoning:** Requires live migration application, environment access, and operator verification.

**Purpose:** Apply and verify the slice in the operator-approved environment after implementation is complete.

**Files:**

- No repo file changes expected.
- Release notes or PR body only if requested during execution.

- [ ] **Step 1: Run full focused verification**

  Run:

  - `pytest tests/test_fulfillment_classification_sql.py tests/test_pipeline_backend_sql.py tests/test_weekly_review_api.py tests/test_profit_admin_frontend.py tests/test_data_references_docs.py -q`
  - `cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build`

  Expected: PASS.

- [ ] **Step 2: Apply migrations in order**

  Apply only after operator approval:

  - `supabase/sql/029_profit_manual_invoice_pending_verdict.sql`
  - `supabase/sql/029a_profit_weekly_review_items.sql`

  Expected: both migrations apply without requiring `029b`.

- [ ] **Step 3: Live SQL smoke checkpoint**

  Run:

  - `select count(*) from profit_classification_verdicts where verdict_code = 'MANUAL_INVOICE_PENDING';`
  - `select trigger_code, to_verdict_code from profit_classification_transition_rules where from_verdict_code = 'MANUAL_INVOICE_PENDING' order by trigger_code;`
  - `select * from profit_manual_invoice_pending_candidates limit 20;`
  - `select * from profit_weekly_review_items where verdict_code = 'MANUAL_INVOICE_PENDING' limit 20;`
  - `select * from profit_apply_classification_transitions(now(), true) limit 20;`

  Expected: verdict exists once, both clearance rules are present or no-op termination is documented, views query, and transition dry-run does not error.

- [ ] **Step 4: Schmidli checkpoint**

  Verify Schmidli appears in `profit_manual_invoice_pending_candidates` and `profit_weekly_review_items`, or document the exact data reason it does not.

  Expected: no silent absence; evidence includes agreement id, manual trigger row, FC completion signal, and issued-invoice predicate result.

- [ ] **Step 5: API smoke checkpoint**

  Run curl/equivalent requests:

  - `GET /api/profit/admin/weekly-review/items`
  - `GET /api/profit/admin/weekly-review/items?include_reviewed=true`
  - `POST /api/profit/admin/weekly-review/items/<classification_id>/snooze`
  - `POST /api/profit/admin/weekly-review/items/<classification_id>/reviewed`

  Expected: GET returns rows or empty arrays; POST actions update only `profit_weekly_review_item_state`.

- [ ] **Step 6: Frontend smoke checkpoint**

  Deploy or run the frontend using the established Vite env vars, then verify:

  - `/profit/admin/weekly-review` loads
  - default view hides reviewed and currently snoozed rows
  - `Show reviewed` surfaces reviewed rows
  - `Snooze 7 days` hides a row until its snooze date
  - `Mark reviewed` hides a row from the default view
  - Anchor link opens the expected agreement URL

- [ ] **Step 7: Commit**

  No commit required if this task only runs verification/deploy actions. If execution added handoff docs, use commit message: `chore: verify weekly review slice`.

## Self-Review

- Spec coverage: G1-G7 are converted to locked decisions from Orlando's message; OQ1-OQ5 are moved into `Resolved Decisions`.
- Migration consistency: C.b shipped `027`/`027a`, V0.6.D shipped `028`/`028a`, so V0.7.A uses `029_profit_manual_invoice_pending_verdict.sql` and `029a_profit_weekly_review_items.sql`.
- File-path consistency: SQL uses `supabase/sql/029*.sql`; API uses new `profit_api/weekly_review.py`; frontend uses `app/frontend/src/routes/WeeklyReview.jsx`; tests extend `tests/test_fulfillment_classification_sql.py` and `tests/test_profit_admin_frontend.py` where appropriate.
- Tier mix: 3x Tier 1, 1x Tier 2, 4x Tier 3.
- Scope restraint: The plan does not modify V0.6.C.5 shared component internals, Dashboard scroll anchor ids, Manual Recognition UI, existing SLA behavior, or existing table schemas for multi-tenancy.
- Placeholder scan: No task uses unresolved implementation placeholders. Remaining uncertainty is isolated to Task 1 and routed as `DECISION NEEDED` only for live evidence contradicting locked assumptions.
- Type consistency: `MANUAL_INVOICE_PENDING`, `profit_weekly_review_item_state`, `profit_weekly_review_items`, `classification_id`, `reviewed_at`, `snoozed_until`, `operator_id`, `practice_id`, `verdict_code`, and `action_url` are named consistently across gates, files, tasks, and docs.
- TDD structure: Tasks 2-7 include red tests, green implementation, checkpoint verification, and commit steps; Tasks 1 and 8 are operator-direct and include no-code/no-commit or deploy-only handling.
