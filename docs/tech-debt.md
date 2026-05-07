# Tech Debt

- Anchor invoice voids do not propagate to profit_revenue_events.recognition_status. Voided/cancelled invoices' revenue event candidates remain eligible for recognition unless manually excluded. The recognition-ready view (profit_revenue_events_ready_for_recognition from 005_profit_recognition_triggers.sql) does not join profit_anchor_invoices or filter on display_status / qbo_status. Structural fix options: (a) extend the ready view to filter display_status NOT IN ('voided', 'cancelled'); OR (b) have the Anchor sync flag candidates from voided invoices with a non-pending recognition_status at sync time. Discovered during Collectiv SBC-00015 cleanup (resolved manually 2026-05-02). Implement before next major Anchor billing cycle to avoid recurrence.
- If invoice note conventions are inconsistently applied, the classifier falls back to default matching and may recognize against the wrong tax year. The pipeline run log should flag any tax recognition where multiple pending events matched form type but only one was recognized — surfaces ambiguity for manual review. See `docs/anchor-invoice-note-conventions.md`.
- Anchor agreement payloads do not expose agreement-level QBO/payment-synced state. V0.6.A Task 4.5 inspected current `profit_anchor_agreements.raw` and found no `qbo`, `quickbooks`, `paymentSynced`, `displayStatus`, or `effectiveStatus` fields at agreement level. Invoice `paymentSynced` behavior remains invoice-specific; agreement-to-invoice payment reconciliation is deferred to V0.6.C pipeline/run-log views.
- Anchor agreements API does not expose DRAFT, SENT, VOIDED, SIGNED, EXPIRED, ARCHIVED, or CANCELLED states (confirmed via inspection 2026-05-06). Only `active` and `terminated` are API-visible. `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT` verdicts in the V0.6 verdict taxonomy are therefore manual-classification-only with required `re_evaluate_at`. If Anchor adds API access to pre-active states in the future, the auto-transition state machine can be extended to derive these verdicts automatically.

## Source-Of-Truth Drift Across Business Rule Domains

Three categories of business rules currently live as static data in our DB but originate upstream. Each should eventually be synced from its source instead of statically seeded:

- `profit_service_recognition_rules`: seeded from `docs/service-recognition-rules.md` in V0.5.2. Source of truth: Anchor service definitions. Future: scheduled workflow `Profit - 27 Anchor Service Sync` reads service definitions via Anchor API and upserts into this table. Schema is sync-ready through `source` and `last_synced_at`. V0.5.2.1 adds `scripts/generate_service_crosswalk_seed.py`, which is the manual-seed-time mirror of the future Anchor/QBO API sync: it reads the current CSV exports and regenerates migration `018` instead of hand-maintaining seed tuples. V0.6.A intentionally leaves this static `anchor services.csv` crosswalk in use; live Anchor service API sync is deferred to V0.6.C or post-V0.6.
- QBO product to macro service classification: currently a hardcoded `prefixToMacro` / service map in the Anchor line item classifier. Source of truth: QBO product hierarchy. Future: sync QBO product categories and persist the mapping in a config table similar to V0.5.2's service-recognition pattern.
- FC tags to service and group identification: currently captured only from `client.raw.groups` in V0.6.A. Source of truth: FC tag system on clients, with project status tags and task tags handled separately if FC exposes reliable endpoints. Future: extend FC sync beyond client groups only after endpoint support is confirmed, then use those tags as parallel signals to Anchor service name during recognition matching and fulfillment-leak grouping.

Address these in V0.6+ as the recognition pipeline matures. For V0.5.2, the static seed is acceptable because the schema design anticipates migration to upstream sync.

## FC Tag Endpoint Limits

- FC task-level service/group tags are not exposed via the current completed-task endpoint. `profit_fc_task_tags` schema exists but is unused in V0.6.A. Investigate alternate FC endpoints, such as project-tasks listing, task-detail, or tag queries, before any V0.6.B/C/D work that depends on per-task tagging.
- FC project-level workflow status tags (`Waiting on Client`, `Ready to Submit`, etc.) are exposed on `project.raw.tags` but deferred to V0.6.D SLA work. The `tag_type` check constraint on `profit_fc_project_tags` will need a `workflow_status` value added at V0.6.D time, or status tags can map to existing `unknown` if that design is cleaner.
- Recognition trigger support for `form_941_quarterly` is deferred to V0.6.C alongside other quarterly and year-end compliance trigger work. The canonical recognition rule is seeded in migration `020a` so FC tag classification works correctly today.

## Transitional FC Tag Snapshot Audit

`scripts/audit_fulfillment_leaks.py` is transitional. The audit script reads `docs/data-references/client-staff-assignments.xlsx` as a snapshot of FC tags for service AND group classification. FC is the canonical source for both. V0.6.A begins replacing the spreadsheet by capturing client-level tags from `client.raw.groups`; project status tags and task tags remain deferred until the relevant FC endpoint support is confirmed. Once live FC-derived group/service classification is trusted, this audit script and the spreadsheet snapshot are retired in favor of Supabase-derived classification.

## Anchor Line Item Descriptions Vs. Canonical Service Names

Alias resolution needed in V0.6.

Migration 019 dropped the FK from `profit_revenue_events.service_name` to `profit_service_recognition_rules.service_name` because Anchor line item descriptions are operational text (e.g., "1120 Plus - Proration for monthly billing", "1040 Plus (Ken & Nancy Wong)", "Accounting Plus (2025 YE close Feb-Dec)") that won't always match canonical service names. The classifier currently passes raw text through, which broke Workflow 15.

V0.6 must add proper canonical service resolution:

- Add `canonical_service_name` column to `profit_revenue_events` (FK to `profit_service_recognition_rules.service_name`, nullable).
- Create `profit_anchor_service_aliases` table mapping raw line item descriptions to canonical `service_name`.
- Update Workflow 11 (line item classification) or Workflow 15 (revenue event candidates) to resolve canonical via:
  - Exact match in canonical taxonomy.
  - Lookup in alias table.
  - Prefix pattern match (canonical name appears as prefix before `-` or `(`).
  - Otherwise NULL canonical with raw preserved; surfaces for manual review.
- Joins to `profit_service_recognition_rules` should use `canonical_service_name`, not raw `service_name`.

Reference unresolved name list at the time of capture: `/tmp/unresolved_service_names_20260504.csv` (16 distinct names blocking Workflow 15 before relaxation).
