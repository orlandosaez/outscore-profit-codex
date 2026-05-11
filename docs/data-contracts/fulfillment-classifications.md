# Fulfillment Classifications Data Contract

## Purpose

`profit_classifications` stores durable manual and system verdict history for fulfillment-leak audit rows. V0.6.B.1 seeds the completed 2026-05-04 audit and adds transition metadata; V0.6.B.2 builds audit query and UI surfaces on top.

## Verdict Lookup

`profit_classification_verdicts` is the source of truth for the canonical verdicts, labels, categories, default visibility, required re-evaluation behavior, and auto-transition eligibility. UI and API code must read `default_visibility` instead of hardcoding hidden verdict names.

The seeded canon includes operational verdicts even when the 2026-05-04 audit did not observe rows for every value. This keeps the picker and transition layer aligned with doctrine rather than with one audit's observed distribution.

### Manual Invoice Pending

V0.7.A adds `MANUAL_INVOICE_PENDING` for active Anchor agreements whose `raw->'profitSyncServiceSummary'` contains at least one service with `trigger = 'manual'` and no issued matching invoice yet. The verdict is visible by default and auto-transition enabled because it represents an operator action queue: issue the manual invoice in Anchor.

`profit_manual_invoice_pending_candidates` is the SQL source for these rows. It uses `profit_anchor_agreements.raw->>'link'` as the primary `action_url`, with a fallback to `https://app.sayanchor.com/home/relationship/<anchor_relationship_id>/agreement` only when Anchor omits the link.

Invoice state is intentionally narrow:

- `no_invoice`: no matching `profit_anchor_invoices` rows exist for the agreement.
- `draft_only`: one or more matching invoice rows exist, but every row still has `qbo_status is null`.

Draft-only rows remain pending. A manual invoice is considered issued only when at least one matching invoice row has `qbo_status is not null`; `display_status` is not used for this decision because historical invoice rows have that field empty.

## Classification History

`profit_classifications` is append-friendly. Changing a verdict inserts a new row and sets `superseded_at` and `superseded_by_classification_id` on the prior active row.

Seeded rows keep `source_audit_file` and `source_audit_row_hash` so the import is traceable back to the point-in-time audit artifact. `last_signal_hash` and `last_signal_at` are reserved for transition and re-emergence scans that need to record why a row re-entered manual review.

## Seed Behavior

The seed generator reads `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`, normalizes verdict strings into the 14-canon, preserves the raw verdict in `source_verdict_raw`, and writes deterministic SQL to `supabase/sql/024_profit_fulfillment_classification_seed_20260504.sql`.

`PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT` rows are cross-checked against live active Anchor agreements. If an active agreement exists at generation time, the row seeds as `MIXED` with a drift note and immediate `re_evaluate_at`.

The generator fails on unknown verdict strings after whitespace and casing normalization. It also reports rows seeded as captured, rows converted to `MIXED` due to drift, and total rows inserted; the migration header count must match the live seeded drift count.

## Transition Rules

`profit_classification_transition_rules` records eligible state-machine transitions. V0.6.B.1 seeds the rules; V0.6.C pipeline orchestration applies them.

Transition rules describe a signal-driven change, not direct UI behavior. When a rule fires, the prior classification is superseded and a new classification row is inserted or queued according to the rule's `to_verdict_code` and notes.

## Pipeline Run Log Schema

V0.6.C.a adds `profit_pipeline_runs` and `profit_pipeline_run_steps` as the durable backend log for future manual and cron pipeline executions.

`profit_pipeline_runs` records one row per pipeline execution. It enforces at most one `status = 'running'` row at a time through the partial unique index `idx_profit_pipeline_runs_one_running`. C.b API code should translate that unique-violation into a `409 Conflict` when a second run is requested while another run is active.

`triggered_by` is nullable text with these conventions:

- Manual runs use an operator identifier matching `profit_classifications.classified_by`, such as `orlando` or `beth`.
- Cron runs use `cron`.
- Synthetic checkpoint rows use `test` and are deleted during deploy verification.

`summary` is free-form JSONB. C.b/C.c should populate:

- `total_steps_completed`
- `total_steps_failed`
- `total_rows_affected`
- `error_summary`, when the run fails or is partial
- `notable_findings`, when a run should surface operational context

`profit_pipeline_run_steps` records ordered per-step results. The `(pipeline_run_id, step_name)` primary key prevents duplicate named steps within one run, and `(pipeline_run_id, step_order)` keeps C.b UI/API ordering stable. `details` is free-form JSONB for step-specific payloads such as candidate counts, transition rows, error text, and notes.

Workflow 26 finalization reads named finish-node contexts rather than trusting the immediate upstream node payload. Each `Finish <step>` node owns the canonical step result, and `Finalize Pipeline Run Summary` aggregates those named contexts defensively, skipping finish nodes that did not execute because an earlier hard step failed. This protects finalization from lossy PostgREST patch responses and keeps hard-fail paths able to populate `profit_pipeline_runs.status`, `finished_at`, and `summary`.

## Pipeline Orchestration API

V0.6.C.b adds read/write orchestration endpoints under the existing audit admin API namespace. These endpoints do not add SQL objects; they consume the C.a `profit_pipeline_runs` and `profit_pipeline_run_steps` tables.

API surface:

- `POST /api/profit/admin/audit/pipeline-runs`
- `GET /api/profit/admin/audit/pipeline-runs`
- `GET /api/profit/admin/audit/pipeline-runs/{pipeline_run_id}`

`POST /pipeline-runs` inserts a `profit_pipeline_runs` row with `run_source = 'manual'`, `status = 'running'`, and operator-supplied `triggered_by`, then calls the Workflow 26 webhook with the `pipeline_run_id`. The API returns immediately with `{ "run": ... }`; it does not wait for the workflow to finish. If the webhook call fails after the row insert, the API deletes the just-created running row before returning a `500`, so the running-row partial unique index is not left blocked.

Concurrent manual refresh attempts are rejected via the C.a partial unique index `idx_profit_pipeline_runs_one_running`. The Supabase REST wrapper preserves PostgreSQL error metadata (`postgres_code`, `constraint_name`) so the service can map `23505` on that constraint to `409 Conflict` with `{ current_run_id, started_at, triggered_by, message }`. If the unique violation races with a run finishing before the follow-up select, the API retries the insert once.

`GET /pipeline-runs` returns `{ "rows": [...], "limit": N, "offset": M }`, ordered by `started_at desc`, with route-level limit/offset clamping. `GET /pipeline-runs/{pipeline_run_id}` returns `{ "run": {...}, "steps": [...] }`; a run with no step rows is still a `200` with `steps: []`. `duration_seconds` is computed on read from `finished_at - started_at` and is `null` while a run is still running.

The frontend polls `GET /pipeline-runs/{pipeline_run_id}` every four seconds only on the run-detail route while that run has `status = 'running'`. List routes and terminal run detail routes do not poll.

## Workflow 26 Run Log Semantics

Workflow 26 is the only workflow that writes to `profit_pipeline_runs` and `profit_pipeline_run_steps`. It receives a `pipeline_run_id` from the API webhook payload; it does not create the run row itself.

The C.b orchestration graph records eight effective steps:

1. `anchor_agreement_sync`
2. `anchor_invoice_revenue_sync`
3. `qbo_collection_loader`
4. `fc_completion_sync`
5. `recognition_trigger_apply`
6. `fc_anchor_match_refresh`
7. `fulfillment_audit_refresh`
8. `classification_transition_apply`

Steps 1-6 are hard dependencies: a failure updates the current step to `failed`, finalizes the run as `failed`, and halts later steps. Steps 7-8 are soft dependencies: failures are captured in step details and the run finalizes as `partial` after all soft steps that can run have completed. Reconcile inside step 6 is best-effort and does not fail the step when its own cleanup call errors.

Grouped steps run sub-workflows strictly sequentially. Step 2 executes W07 -> W11 -> W15. Step 4 executes W17 -> W21 -> W22 -> W19. Step-level `rows_affected` is the sum of sub-operation rows, and `details.sub_workflows` records per-sub-operation `{ name, status, rows_affected, finished_at, error? }`.

Every Execute Workflow node and RPC-style HTTP node in W26 uses `alwaysOutputData = true` because n8n drops item streams when a sub-workflow or RPC returns zero rows. Dropped item streams can strand a step in `running` and bypass finalization. The graph treats output preservation as part of the run-log contract, not as a cosmetic workflow setting.

All terminal paths route through `Finalize Pipeline Run Summary`, followed by the final status patch. Happy path, hard-fail paths, and soft-fail/partial paths must populate `profit_pipeline_runs.status`, `finished_at`, and `summary`. A Workflow 26 n8n execution may show `success` even when the pipeline run status is `failed`; that means the workflow successfully executed its failure-routing path.

## Workflow 25 Standalone Run Behavior

Workflow 25 remains safe to trigger outside Workflow 26, but standalone runs are not represented in `profit_pipeline_runs` or `profit_pipeline_run_steps`. The run log is exclusively for Workflow 26 orchestration. Standalone Workflow 25 invocations are visible only in n8n execution history.

Workflow 25 must preserve `match_method = 'manual_override'` rows during upsert. The current implementation fetches existing manual override `fc_client_id` values and excludes them from the `auto_exact` upsert payload. The `protectedManualOverrideCount` field in Workflow 25's output reports how many manual rows were protected. This invariant prevents silent data corruption when an operator-set manual override would otherwise be overwritten by the candidate view's `auto_exact` recommendation.

Workflow 25 also calls `profit_reconcile_fc_client_anchor_matches(false)` after its upsert step. The output payload includes `upsertedFcClientMatchCount`, `reconciledDemotedMatchCount`, `reconcileStatus`, and `reconcileError`. Reconcile errors are captured as `reconcileStatus = 'error'` and do not fail the workflow; stale-match cleanup is best-effort during standalone execution and summarized by Workflow 26 when W25 is invoked as part of the chain.

## Auto Apply Enabled Field Migration

V0.6.C.b adds canonical `auto_apply_enabled` to each transition rule object returned by `GET /api/profit/admin/audit/candidates/{fc_client_id}`. The field is true when the rule is enabled and the current C.b pipeline can auto-apply that `(from_verdict_code, signal_name)` combination.

Canonical auto-apply combinations are:

- `PENDING_ENGAGEMENT_DRAFT` / `PENDING_ENGAGEMENT_SENT` + `active_agreement_appears`
- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_group_billed`
- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_mid_cycle`
- `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_group_parent`
- `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_standalone_mid_cycle`

The deprecated `auto_apply_enabled_in_b2a` field remains emitted on every transition rule row for backward compatibility and remains true only for the original B.2.a active-agreement PENDING rules. Frontend code must prefer `auto_apply_enabled` when present and fall back to `auto_apply_enabled_in_b2a` only for older payloads. The legacy field should remain dual-emitted until V0.7 removal criteria are met.

## Inactive Re-Emergence

`profit_run_inactive_client_reemergence_scan()` supersedes active `INACTIVE_FORMER_CLIENT` rows when an active signal returns. V0.6.B.1 emits `MIXED` rows for manual reclassification; V0.6.B.2 audit views surface those rows.

Re-emergence triggers only on signals that post-date `classified_at`, not on signals that existed at classification time. The service-delivery task signal therefore requires `task.completed_at > record_to_scan.classified_at` in addition to the rolling 365-day recency window.

The V0.6.B.1 scan checks FC active state, active Anchor agreement matches, and post-classification service-delivery tasks. QBO open-balance signal handling is deferred until V0.6.B.2 defines the canonical audit signal view.

### Re-Emergence Scan V2

V0.6.B.2.a replaces `profit_run_inactive_client_reemergence_scan(timestamptz)` in place. The signature is unchanged. The scan reads canonical helper views instead of duplicating inactive or open-invoice predicates.

Reason codes:

- `fc_client_unarchived`
- `fc_client_became_active`
- `active_anchor_agreement_created`
- `service_delivery_task_completed`
- `open_invoice_balance_returned`

#### Known Limitation: Backdated Agreements

Anchor does not expose a true agreement create/sign timestamp. Scan v2 uses `profit_anchor_agreements.effective_date > classified_at` as the activation proxy. Backdated agreements whose `effective_date <= classified_at` may not auto-supersede inactive classifications. The audit candidate view's any-active-signal filter is the safety net and must surface active agreements for manual review.

#### Known Limitation: Open-Balance Signal

`open_invoice_balance_returned` fires only when a currently open invoice was created after `classified_at`. If an existing invoice's balance changes from paid to unpaid, Anchor invoice payloads currently do not expose a reliable balance-change timestamp. The audit candidate view surfaces positive open invoice balance for manual review even when scan v2 cannot auto-supersede.

### Audit Query Helpers

- `profit_audit_fc_inactive_signals`: canonical FC archived/unarchived/offboarding signal source.
- `profit_qbo_product_leaf_name(text)`: canonical Anchor QBO product leaf extractor.
- `profit_audit_open_invoice_balance_per_client`: one row per FC client, sourced from Anchor invoices and Workflow 25 matches.
- `profit_fulfillment_audit_qbo_category_gaps`: QBO product/category and canonical-service diagnostic view.

### Apply Transitions

`profit_apply_classification_transitions(timestamptz, boolean)` supports dry-run and live apply using the same selection logic. When `p_dry_run = true`, it returns transition candidates and performs zero writes. When `p_dry_run = false`, it inserts a new `profit_classifications` row and supersedes the prior row.

V0.6.B.2.a scope is narrow: only `active_agreement_appears` is applied for `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT`. The other nine transition rules seeded in V0.6.B.1 remain inactive executable paths until V0.6.C pipeline orchestration.

### Apply Transitions V0.6.C.a

V0.6.C.a expands `profit_apply_classification_transitions(timestamptz, boolean)` in place. The function name, signature, dry-run behavior, live append-friendly supersede behavior, and B.2.b response contract remain unchanged.

Executable rules in C.a:

- `PENDING_ENGAGEMENT_DRAFT` / `PENDING_ENGAGEMENT_SENT` + `active_agreement_appears` -> `MIXED`
- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_group_billed` -> `CONSOLIDATED_VIA_GROUP_BILLED`
- `LEGACY_ENGAGEMENT_PRE_ANCHOR` + `first_matching_anchor_invoice_mid_cycle` -> `BILLING_OUTSIDE_AUDIT_WINDOW`
- `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_group_parent` -> `CONSOLIDATED_VIA_GROUP_BILLED`
- `INVOICE_OUTSTANDING_PAYMENT_PENDING` + `cash_collected_standalone_mid_cycle` -> `BILLING_OUTSIDE_AUDIT_WINDOW`

V0.7.A adds manual-invoice executable paths:

- active manual-trigger agreement with no issued invoice -> insert `MANUAL_INVOICE_PENDING`
- `MANUAL_INVOICE_PENDING` + `manual_invoice_issued` -> `INVOICE_OUTSTANDING_PAYMENT_PENDING`
- `MANUAL_INVOICE_PENDING` + `manual_invoice_agreement_terminated` -> no-successor resolution

The issued-invoice clearance requires at least one `profit_anchor_invoices` row for the agreement with `qbo_status is not null`. The terminated-agreement clearance requires `profit_anchor_agreements.display_status = 'terminated'` and `terminated_at is not null`.

The current verdict taxonomy has no terminated-agreement successor equivalent to `CLIENT_TERMINATED`. V0.7.A therefore resolves terminated manual-invoice rows by setting `superseded_at` while leaving `superseded_by_classification_id` null. This is a documented no-op resolution path, not a failed transition.

V0.7.B adds SLA-breach executable paths:

- breached or at-risk service item -> insert `SLA_BREACHED`
- `SLA_BREACHED` + `sla_task_complete` -> no-successor resolution
- `SLA_BREACHED` + `sla_project_archived` -> no-successor resolution

The SLA detection branch reads `profit_sla_breached_candidates` (migration 030) which filters `profit_sla_service_items` to `sla_state IN ('breached', 'at_risk')` and excludes rows where `default_sla_day IS NULL`, `target_sla_day IS NULL`, or `target_date IS NULL`. The `sla_task_complete` clearance fires when a matching FC task has `is_completed = true OR completed_at IS NOT NULL`; the `sla_project_archived` clearance fires when a matching FC project has `is_closed = true OR closed_at IS NOT NULL`. Both clearance branches use no-op resolution because the existing taxonomy has no clean "work-complete-outside-billing" successor; `SETTLED_VIA_QUICKBOOKS_PAYMENT` is QBO-cash-specific and is not appropriate here.

The matching FC task or project must share a service tag with the SLA service item via `profit_fc_project_tags.tag_type='service'`. Per V0.7.B Task 1 profiling, that bridge does not yet exist in live data (FC sync has not been extended to populate service tags); the apply function therefore falls back to `task.project_title ILIKE '%' || service_name || '%'` for task matching. The `tag_type='service'` data backfill is deferred to V0.7.D.

The `profit_apply_classification_transitions` ranked-signals UNION includes a SLA-aware dedup key (`'detect:sla:' || fc_client_id || ':' || service_name`) so multiple service rows for the same anchor relationship dedup independently.

Deferred rules:

- `SETTLED_VIA_QUICKBOOKS_PAYMENT` + `anchor_backfill_*` remains V0.6.D Anchor backfill queue work.
- `INACTIVE_FORMER_CLIENT` + `any_active_signal_returns` remains handled by the re-emergence scan v2, not by the generic apply function.
- Stale terminated/reopened cleanup for manual-invoice rows is deferred to V0.7.D. V0.7.A only clears rows with the confirmed terminated signal above; it does not attempt to repair historical stale/reopened agreement drift.
- SLA staff-routing and waiting_on_client repair require FC sync to populate `tag_type='service'` on `profit_fc_project_tags` and `tag_type='staff'` on `profit_fc_client_tags`. Both are deferred to V0.7.D.
- 1120 C-corp/S-corp entity_type disambiguation requires a service-catalog schema extension. Deferred to V0.7.D. V0.7.B surfaces all 1120 rows as SLA_BREACHED; operator triages C-corp false positives via Snooze if observed in the April 15 → May 15 window.

### QuickBooks-Settled Anchor Backfill

V0.6.D links `SETTLED_VIA_QUICKBOOKS_PAYMENT` classifications to the SLA dashboard's Anchor backfill queue. `profit_sla_anchor_backfill_queue` and the `/admin/sla/backfill` route surface QBO payment evidence, missing-Anchor settlement signal, and auto-transition eligibility as a read-only convergence queue. See [SLA Dashboard Data Contract](sla-dashboard.md) for the full queue and API contract.

Auto-transition correctness requires `profit_fc_client_anchor_matches.anchor_relationship_id` to be populated. Classifications without a persisted Anchor match are skipped silently by the function and surfaced through audit/dashboard diagnostics for manual review.

Rules with `requires_service_type_match = true` use the composite service-type key:

```sql
macro_service_type || '|' || recognition_pattern || '|' || service_period_rule
```

The function skips automatic transition when a signal set has multiple service-type keys, unresolved `canonical_service_name`, `recognition_pattern = 'manual_review'`, or `service_period_rule = 'manual'`.

Cash signal timing uses `profit_cash_collections.collected_at`, a `date` column, cast as `collected_at::timestamptz` before comparison with `profit_classifications.classified_at`. Do not compare `allocated.loaded_at` or any allocation load timestamp to `classified_at`.

Group-billed branches have priority over standalone branches. If both own-client and group-sibling signals exist for one active classification, the function emits the group-billed verdict.

### Match Reconciliation

V0.6.C.a adds `profit_reconcile_fc_client_anchor_matches(p_dry_run boolean default true)`.

The matches table is a derived projection of the status-aware candidate view plus manual overrides. Reconciliation hard-deletes persisted `auto_exact` rows that no longer qualify as `auto_exact`, or that now point at a different `anchor_relationship_id` than the candidate view. `manual_override` rows are protected.

The function is idempotent: dry-run returns the rows that would be deleted, live mode deletes those rows, and a second live call returns zero rows when no stale persisted rows remain.

V0.6.C.b orchestration should run reconciliation after Workflow 25's upsert step:

1. Workflow 05 Anchor agreement sync
2. Workflow 25 FC-to-Anchor match upsert
3. `profit_reconcile_fc_client_anchor_matches(false)`
4. Audit refresh
5. Re-emergence scan
6. Transition apply

### Pipeline Diagnostic Views

V0.6.C.a adds three `profit_pipeline_*` diagnostic views for C.b pipeline run logs and future dashboard surfacing:

- `profit_pipeline_classification_transition_blockers`: one row per `(classification_id, signal_name, blocker_reason)` for active classifications whose expanded apply rules cannot safely fire. `no_anchor_match` expands to one row per applicable transition rule so operators can see exactly which rules are blocked.
- `profit_pipeline_due_reclassifications`: thin wrapper over `profit_fulfillment_audit_candidates` for active classifications with `re_evaluate_at <= current_date`.
- `profit_pipeline_stuck_recognition_triggers`: pending revenue events older than the hardcoded 30-day stuck threshold that are not currently ready for recognition.

C.b should also reuse the three existing diagnostic surfaces rather than duplicating them:

- `profit_tax_recognition_ambiguities`
- `profit_fulfillment_audit_qbo_category_gaps`
- `profit_unresolved_service_names`

## Audit Dashboard API Conventions

V0.6.B.2.b adds the `/profit/admin/audit` dashboard as a frontend/API layer over the existing B.2.a views and B.1 classification tables. It adds no new SQL migrations or views.

The API surface is:

- `GET /api/profit/admin/audit/verdicts`
- `GET /api/profit/admin/audit/filter-options`
- `GET /api/profit/admin/audit/candidates`
- `GET /api/profit/admin/audit/candidates/{fc_client_id}`
- `POST /api/profit/admin/audit/classifications`
- `GET /api/profit/admin/audit/qbo-category-gaps`

The frontend builds its verdict map from `/api/profit/admin/audit/verdicts` at render time. It must not hardcode the 14 verdict canon or hidden verdict names. Candidate default queue visibility comes from `default_visibility`; unclassified rows coalesce to `show` and are rendered as manual-classification candidates.

`GET /api/profit/admin/audit/candidates` accepts the special verdict filter sentinel `__UNCLASSIFIED__`, which maps to `current_verdict_code is null`. Unknown verdict filters return a structured `422` instead of silently falling through. The `show_all` toggle composes with verdict filtering: hidden classified rows remain hidden unless `show_all=true`, while unclassified rows are visible by default.

`GET /api/profit/admin/audit/candidates/{fc_client_id}` returns the composite detail payload in one call. Classification history is capped at 100 rows and includes `classification_history_total_count` plus `classification_history_truncated`; recent service tasks are capped at 20 rows.

`POST /api/profit/admin/audit/classifications` supports first-classification and reclassification with the same request shape. Manual dashboard writes use:

- `source_audit_file = 'manual:/profit/admin/audit'`
- `source_audit_row_hash = 'manual:<request_id>:<fc_client_id>'`

The notes column stores `[req:<request_id>] <operator notes>` so the request remains recoverable from the row itself; the UI strips that prefix when rendering history.

Bulk classification remains append-friendly: the API inserts a new `profit_classifications` row and supersedes the prior active row when one exists. It uses service-side rollback to approximate all-or-nothing behavior; a true SQL transaction/RPC is deferred.

Validation order is schema, verdict lookup, required notes, required `re_evaluate_at`, then optimistic-concurrency checks. Required notes are enforced when the new verdict category is `mixed`, `leak`, or `manual_review`. Stale snapshots return `409` with the current active classification so the client can refetch.

The audit dashboard table omits staff primary/reviewer in V0.6.B.2.b because assigned-staff context is not exposed by the current audit views without an additional join. V0.6.D SLA work is the expected home for staff-enriched triage.
