# Fulfillment Classifications Data Contract

## Purpose

`profit_classifications` stores durable manual and system verdict history for fulfillment-leak audit rows. V0.6.B.1 seeds the completed 2026-05-04 audit and adds transition metadata; V0.6.B.2 builds audit query and UI surfaces on top.

## Verdict Lookup

`profit_classification_verdicts` is the source of truth for the 14 canonical verdicts, labels, categories, default visibility, required re-evaluation behavior, and auto-transition eligibility. UI and API code must read `default_visibility` instead of hardcoding hidden verdict names.

The seeded canon includes operational verdicts even when the 2026-05-04 audit did not observe rows for every value. This keeps the picker and transition layer aligned with doctrine rather than with one audit's observed distribution.

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
