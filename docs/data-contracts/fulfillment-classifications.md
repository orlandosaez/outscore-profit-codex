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
