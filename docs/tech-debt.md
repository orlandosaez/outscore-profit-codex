# Tech Debt

- Anchor invoice voids do not propagate to profit_revenue_events.recognition_status. Voided/cancelled invoices' revenue event candidates remain eligible for recognition unless manually excluded. The recognition-ready view (profit_revenue_events_ready_for_recognition from 005_profit_recognition_triggers.sql) does not join profit_anchor_invoices or filter on display_status / qbo_status. Structural fix options: (a) extend the ready view to filter display_status NOT IN ('voided', 'cancelled'); OR (b) have the Anchor sync flag candidates from voided invoices with a non-pending recognition_status at sync time. Discovered during Collectiv SBC-00015 cleanup (resolved manually 2026-05-02). Implement before next major Anchor billing cycle to avoid recurrence.
- If invoice note conventions are inconsistently applied, the classifier falls back to default matching and may recognize against the wrong tax year. The pipeline run log should flag any tax recognition where multiple pending events matched form type but only one was recognized — surfaces ambiguity for manual review. See `docs/anchor-invoice-note-conventions.md`.

## Source-Of-Truth Drift Across Business Rule Domains

Three categories of business rules currently live as static data in our DB but originate upstream. Each should eventually be synced from its source instead of statically seeded:

- `profit_service_recognition_rules`: seeded from `docs/service-recognition-rules.md` in V0.5.2. Source of truth: Anchor service definitions. Future: scheduled workflow `Profit - 27 Anchor Service Sync` reads service definitions via Anchor API and upserts into this table. Schema is sync-ready through `source` and `last_synced_at`. V0.5.2.1 adds `scripts/generate_service_crosswalk_seed.py`, which is the manual-seed-time mirror of the future Anchor/QBO API sync: it reads the current CSV exports and regenerates migration `018` instead of hand-maintaining seed tuples.
- QBO product to macro service classification: currently a hardcoded `prefixToMacro` / service map in the Anchor line item classifier. Source of truth: QBO product hierarchy. Future: sync QBO product categories and persist the mapping in a config table similar to V0.5.2's service-recognition pattern.
- FC tags to service and group identification: currently not captured. Source of truth: FC tag system on clients/tasks/projects. Future: extend Workflow 17 to capture tag arrays per client/task/project and use them as a parallel signal to Anchor service name during recognition matching and fulfillment-leak grouping.

Address these in V0.6+ as the recognition pipeline matures. For V0.5.2, the static seed is acceptable because the schema design anticipates migration to upstream sync.

## Transitional FC Tag Snapshot Audit

`scripts/audit_fulfillment_leaks.py` is transitional. The audit script reads `docs/data-references/client-staff-assignments.xlsx` as a snapshot of FC tags for service AND group classification. FC is the canonical source for both. The current FC sync (Workflow 17) does not yet capture tags. V0.6 must extend the FC sync to capture client/project/task tags directly into Supabase, then parse them into structured group memberships (`profit_client_groups`, `profit_client_group_members`) and service assignments. Once that lands, this audit script and the spreadsheet snapshot are retired in favor of live FC-derived classification.

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
