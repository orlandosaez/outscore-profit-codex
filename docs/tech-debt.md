# Tech Debt

- Anchor invoice voids do not propagate to profit_revenue_events.recognition_status. Voided/cancelled invoices' revenue event candidates remain eligible for recognition unless manually excluded. The recognition-ready view (profit_revenue_events_ready_for_recognition from 005_profit_recognition_triggers.sql) does not join profit_anchor_invoices or filter on display_status / qbo_status. Structural fix options: (a) extend the ready view to filter display_status NOT IN ('voided', 'cancelled'); OR (b) have the Anchor sync flag candidates from voided invoices with a non-pending recognition_status at sync time. Discovered during Collectiv SBC-00015 cleanup (resolved manually 2026-05-02). Implement before next major Anchor billing cycle to avoid recurrence.
- If invoice note conventions are inconsistently applied, the classifier falls back to default matching and may recognize against the wrong tax year. The pipeline run log should flag any tax recognition where multiple pending events matched form type but only one was recognized — surfaces ambiguity for manual review. See `docs/anchor-invoice-note-conventions.md`.
- Anchor agreement payloads do not expose agreement-level QBO/payment-synced state. V0.6.A Task 4.5 inspected current `profit_anchor_agreements.raw` and found no `qbo`, `quickbooks`, `paymentSynced`, `displayStatus`, or `effectiveStatus` fields at agreement level. Invoice `paymentSynced` behavior remains invoice-specific; agreement-to-invoice payment reconciliation is deferred to V0.6.C pipeline/run-log views.
- Anchor agreements API does not expose DRAFT, SENT, VOIDED, SIGNED, EXPIRED, ARCHIVED, or CANCELLED states (confirmed via inspection 2026-05-06). Only `active` and `terminated` are API-visible. `PENDING_ENGAGEMENT_DRAFT` and `PENDING_ENGAGEMENT_SENT` verdicts in the V0.6 verdict taxonomy are therefore manual-classification-only with required `re_evaluate_at`. If Anchor adds API access to pre-active states in the future, the auto-transition state machine can be extended to derive these verdicts automatically.
- Workflow 25 reissuance and demotion handling gap. `Profit - 25 Auto-Match FC Clients To Anchor` uses normalized name equality and only upserts when there is exactly one Anchor row with that normalized name. This has three known gaps: (a) match logic does not rank `profit_anchor_agreements` by `display_status`, so a client whose only Anchor row is terminated can become `auto_exact` and persist a stale terminated match. Real example observed 2026-05-07: E & O Automotive LLC's only candidate is terminated; running Workflow 25 as-is would lock in the stale match. (b) When a client has both a terminated old agreement and a new active agreement sharing the same normalized name, the candidate view returns `normalized_anchor_count > 1` -> `ambiguous`, so the active reissued agreement is not upserted. Real examples observed 2026-05-07: 1415 Cortez Rd LLC, 6712 Manatee Ave LLC, and E & O Automotive LLC all confirmed via direct Anchor API to have active reissued agreements that `profit_fc_client_anchor_matches` does not surface. (c) Workflow 25 is upsert-only and does not clear or demote previously persisted `auto_exact` rows when the candidate view's status-aware truth table no longer marks them `auto_exact`. Observed 2026-05-08: YV Enterprises HB LLC and YV Enterprises PSL LLC remain persisted as `auto_exact` in `profit_fc_client_anchor_matches` even though migration `024a`'s candidate view correctly reports them as `ambiguous` (stale-only). Downstream consumers in V0.6.B.2.a filter on `profit_anchor_agreements.display_status = 'active'` and are not affected, but the matches table itself is stale. Fix in V0.6.C: Workflow 25 should rank candidates by active-over-terminated/stale, then diff the candidate view against persisted matches and supersede or delete demoted rows. A one-shot cleanup query is acceptable as the V0.6.C deploy step.
- Workflow 25 has no scheduled rerun. It is run on demand only. `profit_fc_client_anchor_matches` has 39 rows with `loaded_at` timestamps from 2026-05-02 through 2026-05-05, with no runs since then at the time of the 2026-05-07 inspection. Real example observed 2026-05-07: Schmidli Enterprises LLC has `auto_exact` -> active in the live candidate view but is not persisted because Workflow 25 has not run recently. V0.6.C recognition pipeline orchestration must include Workflow 25 in the chained run, after Anchor agreement sync and before audit candidate refresh.
- V0.6.B.1 seed accepts known matches-table staleness. V0.6.B.1 seeds 14 `PENDING_ENGAGEMENT_SENT` rows on 2026-05-07 based on the matches table's current state. At least three of those clients have active reissued agreements that the matches table does not surface (per the Workflow 25 reissuance handling gap above). These rows will seed as `PENDING_ENGAGEMENT_SENT` with `re_evaluate_at = current_date + 30`. They will surface in the V0.6.B.2 audit dashboard for manual reclassification once that slice ships, and will auto-resolve to `MIXED` via the `active_agreement_appears` transition once the matches table is refreshed after the Workflow 25 reissuance/scheduling fixes.
- V0.6 `INACTIVE_FORMER_CLIENT` assignment criteria need refinement. The spec's "no service-delivery FC tasks completed in last 365 days" rule is too strict. Real example observed 2026-05-07: Joy Property Management LLC was archived in FC on 2026-03-18 immediately after her 1065 close-out task completed; under the strict definition she would not qualify as `INACTIVE_FORMER_CLIENT`, but operational state (no longer a client, all balances zero, no Anchor) clearly matches the verdict's intent. V0.6.B.2 audit query should use "no new service-delivery tasks since `archived_at`" or similar transition-aware logic rather than a strict 365-day window.
- Re-emergence scan FC active and Anchor active checks use current-state matching, not transition matching. `is_archived = false` fires whether the client just became active or has always been `is_archived = false` with a stale `INACTIVE_FORMER_CLIENT` classification. At worst this creates manual-review prompts rather than silent supersedes. V0.6.B.2 audit query should add transition-timestamp guards, such as `archived_at < classified_at` or `archived_at is null`, to distinguish pre-existing state from true re-emergence.
- 13 PENDING_SENT seeded classifications remain pending review. Anchor `/agreements` API exposes only active/terminated states; DRAFT and SENT agreements are not visible (existing Anchor state visibility limitation). The `PENDING_ENGAGEMENT_SENT` verdict captures pre-active engagement state correctly. The original 2026-05-07 inspection note about roughly 12 active reissued agreements is not reproducible against current `/agreements?limit=100` (verified 2026-05-08); those agreements either cancelled, never advanced past pre-active, or were observed via a different path. Rows transition automatically when an active agreement appears for the client through the existing `active_agreement_appears -> MIXED` rule. Until then, surface as standard pending review in the audit dashboard.
- Workflow 05 (Anchor agreement sync) hardcodes limit=50 with no pagination loop. Anchor `/agreements?limit=100` currently returns 52 agreements; the 2 outside the first 50 (YV Enterprises HB LLC and YV Enterprises PSL LLC active reissues) get marked stale because they are not seen in Workflow 05's run. `/agreements?limit=200` returns `INVALID_PAGE_SIZE`; `offset=50` does not page and returns the first 50 again. V0.6.C.b will raise the limit to 100 as a short-term fix. Real pagination is blocked on Anchor API support; revisit when offset/cursor params work or once active agreement count approaches 100.
- Auto-transition apply skips classifications whose FC client has no persisted `anchor_relationship_id` in `profit_fc_client_anchor_matches`. Operationally, these surface as audit candidates with stale or null Anchor signals; manual classification or upstream Workflow 25/05 sync coverage is required before transitions can fire.
- V0.6.C.a deploy executes `profit_reconcile_fc_client_anchor_matches(false)` once to clear YV Enterprises HB LLC and YV Enterprises PSL LLC stale `auto_exact` rows. V0.6.C.b wires the function into Workflow 25/26 for ongoing reconciliation. Pre-V0.6.C.b, the matches table can drift if Workflow 25 reruns without reconcile; surface as audit candidate ambiguity for manual review during the gap.
- Workflow 25 `manual_override` protection logic was retrofitted in V0.6.C.b after a latent data-corruption bug was caught during reconcile wiring. The protection works at upsert time but does not prevent a future direct `INSERT`/`UPDATE` bypass. Long-term hardening could move the protection to a database trigger on `profit_fc_client_anchor_matches`; revisit if the matches table grows additional consumer paths.
- SupabaseRestError was extended in V0.6.C.b to preserve `postgres_code` and `constraint_name` so pipeline concurrency can map `idx_profit_pipeline_runs_one_running` violations to structured `409 Conflict` responses. Other `profit_api` code paths still parse generic error strings or treat Supabase failures as opaque errors; opportunistically migrate them to structured detection when touching error-handling logic.
- ~~Stuck pipeline run detection is deferred to V0.6.C.c.~~ **RESOLVED 2026-05-09 in V0.6.C.c:** `profit_finalize_stale_pipeline_runs(p_threshold interval DEFAULT '30 minutes')` (migration `027`) finalizes stale `status='running'` rows. Invoked pre-cron from Workflow `Profit - 29 Schedule Wrapper` (best-effort with continueOnFail) and available as on-demand RPC. Preserves existing `summary` keys via jsonb merge; sets `summary.error_summary='Stuck running detection - no progress for >30min'`.
- Manual pipeline refresh accepts free-text `triggered_by`. Multi-operator support is informal in V0.6: the operator types their identifier, defaulting to `orlando` in the UI. V0.7 should consider session-based identity once Supabase Auth replaces nginx basic auth.
- `auto_apply_enabled_in_b2a` in the detail endpoint `transition_rules` array is deprecated as of V0.6.C.b. Removal target: after V0.6 ships and after 30 days of dual emission with no observed legacy-only reads in API access logs. The frontend reads `auto_apply_enabled` with fallback to legacy; once frontend bundles are confirmed deployed everywhere, with no cached old bundles in browsers, the legacy field can be removed in V0.7. Track removal in the V0.7 backlog.
- ~~Pipeline webhook calls can return `404` if invoked immediately after an n8n restart...~~ **RESOLVED 2026-05-09 in V0.6.C.c:** `N8nPipelineWebhookClient.trigger` now retries up to 2 attempts with 3s backoff on transient HTTP failures (404, 502/503/504, connection errors, timeouts). Permanent failures (400/401/403) propagate immediately. Existing rollback semantics preserved on final failure.
- W16 (Profit - 16 Apply Recognition Triggers) fails when ready revenue events contain duplicate `revenue_event_key` values. Standalone reproduction 2026-05-09: 24 ready events totaling $21,970 included duplicate `rev_ili-z27H4dSkcSnw-2ZSgPjyIuro3oO6s`, causing `ON CONFLICT DO UPDATE` rejection (`command cannot affect row a second time`). Either deduplicate in W16 pre-upsert OR fix upstream W15 (Load Revenue Event Candidates) to not emit duplicates. Investigation deferred to non-C.b scope; pipeline runs status='failed' at step 5 until W16 is fixed.
- Pipeline UI uses technical terminology such as sub-workflow codes and snake_case step names. V0.6.C.b adds `docs/operator-guides/pipeline-glossary.md` and friendly UI excerpts, but long-term polish should consider step name display normalization and sub-workflow code to display-name mapping in the API or a shared frontend config. Defer deeper UX refinement to V0.6.D or a post-V0.6 polish slice.
- QBO product category gaps remain upstream cleanup work. G4 confirmed 10 QBO products with `qbo_category_path is null`: Accounting, Accounting and Tax Services Bundle, Advisory, Other, Payroll, Sales Tax Advanced (deleted), Sales Tax Essential (deleted), Sales Tax Plus (deleted), Tax Work, and TPP Florida. Current revenue events do not hit these rows after leaf-name matching, so they are diagnostic-only. Manual review or upstream QBO cleanup is needed.
- Anchor invoice raw payload does not expose `updatedAt`, `lastUpdatedAt`, or `paidAt`. `profit_audit_open_invoice_balance_per_client` derives `last_signal_at` from invoice `createdAt` as a proxy for new-open-invoice events. It cannot detect retroactive paid-to-unpaid balance changes. Revisit if Anchor exposes invoice update timestamps.
- Anchor agreement create/activation timestamp gap. `effective_date` is the begin date of the agreement, not its signing or creation timestamp. Scan v2 uses `effective_date > classified_at` as the activation proxy and may miss backdated active agreements. The audit candidate view's any-active-signal filter surfaces them as a fallback. Revisit if Anchor adds a `created_at` or `signed_at` field, or if backdated agreements become operationally common.
- Bulk classify uses service-side rollback. The V0.6.B.2.b audit dashboard validates all rows, inserts new `profit_classifications` rows, supersedes prior active rows, and deletes inserted rows by request key if a later service step fails. A SQL function with a true transaction would be more robust if rollback ever fails. Revisit if classification volume grows or rollback errors are observed.
- Multi-user dashboard concurrency is intentionally limited. The API rejects stale supersede targets with `409` so operators do not fork the active classification chain from an old snapshot, but there is no collaborative locking, presence, or optimistic UI merge. The append-friendly history preserves both operators' writes if they happen sequentially. Revisit for V0.7 if multiple reviewers use the dashboard simultaneously.
- Audit dashboard table omits staff primary/reviewer column. Source data (assigned-staff per FC client) is not exposed in current views without an additional join. Defer to V0.6.D SLA work which already needs staff context, or add a small helper view in V0.6.C.
- Detail panel service tasks omit assigned staff unless exposed by existing views. The V0.6.B.2.b detail payload uses the capped `profit_fc_task_delivery_classification` rows already available to the API. Revisit if SLA context needs assigned-staff or reviewer display in B.2.b+.
- Frontend clears all row selection after successful bulk apply. This keeps the operator in a clean triage state after each mutation, but it does not preserve unrelated selected rows for multi-step batch workflows. Revisit if reviewers need longer staged batches.

## W17 FC Sync — Missing Stale-Record Sweep (V0.7.D-3 Part C, deferred)

**Discovered 2026-05-13 operator audit.** W17 (Financial Cents sync) does INSERT/UPDATE only. When a client is renamed or deleted in FC and FC's `/clients` endpoint stops returning the old record, W17 does nothing — the stale row in `profit_fc_clients` persists indefinitely with `is_archived = false` and a stale `last_seen_at`.

**Observed impact 2026-05-13:**
- `4385653 "Lee's Food Store of Sarasota Inc"` (no comma) — stale since 2026-05-09, swept manually via migration 038a
- `4385662 "Lee's Ice of Southwest Florida, Inc."` (trailing dot) — same
- Ghost records polluted V0.7.B.4 attribution and SLA candidate views until V0.7.D-3 Part B (migration 038b) added `is_archived = false` filter to the resolver

**Permanent fix (deferred to next FC-sync-touching slice):**
Add one step to the end of W17 workflow JSON (`n8n/workflows/profit-17-financial-cents-sync.json`):
```sql
UPDATE profit_fc_clients
   SET is_archived = true, archived_at = now()
 WHERE last_seen_at < <sync_start_timestamp - 5 minutes>
   AND is_archived = false;
```

**Safety guard needed:** only execute the sweep when the sync's pulled-record count is within 90% of the last successful sync's count. Otherwise an FC API glitch returning a partial result set would mass-archive real clients.

**Slot:** fold into V0.7.D-4 (FC sync expansion hardening) or V0.7.G polish, whichever comes first. Estimated: ~30 min n8n edit + careful import/activate.

## Source-Of-Truth Drift Across Business Rule Domains

Three categories of business rules currently live as static data in our DB but originate upstream. Each should eventually be synced from its source instead of statically seeded:

- `profit_service_recognition_rules`: seeded from `docs/service-recognition-rules.md` in V0.5.2. Source of truth: Anchor service definitions. Future: scheduled workflow `Profit - 27 Anchor Service Sync` reads service definitions via Anchor API and upserts into this table. Schema is sync-ready through `source` and `last_synced_at`. V0.5.2.1 adds `scripts/generate_service_crosswalk_seed.py`, which is the manual-seed-time mirror of the future Anchor/QBO API sync: it reads the current CSV exports and regenerates migration `018` instead of hand-maintaining seed tuples. V0.6.A intentionally leaves this static `anchor services.csv` crosswalk in use; live Anchor service API sync is deferred to V0.6.C or post-V0.6.
- QBO product to macro service classification: currently a hardcoded `prefixToMacro` / service map in the Anchor line item classifier. Source of truth: QBO product hierarchy. Future: sync QBO product categories and persist the mapping in a config table similar to V0.5.2's service-recognition pattern.
- FC tags to service and group identification: currently captured only from `client.raw.groups` in V0.6.A. Source of truth: FC tag system on clients, with project status tags and task tags handled separately if FC exposes reliable endpoints. Future: extend FC sync beyond client groups only after endpoint support is confirmed, then use those tags as parallel signals to Anchor service name during recognition matching and fulfillment-leak grouping.

Address these in V0.6+ as the recognition pipeline matures. For V0.5.2, the static seed is acceptable because the schema design anticipates migration to upstream sync.

## FC Tag Endpoint Limits

- FC task-level service/group tags are not exposed via the current completed-task endpoint. `profit_fc_task_tags` schema exists but is unused in V0.6.A. Investigate alternate FC endpoints, such as project-tasks listing, task-detail, or tag queries, before any V0.6.B/C/D work that depends on per-task tagging.
- ~~FC project-level workflow status tags (`Waiting on Client`, `Ready to Submit`, etc.) are exposed on `project.raw.tags` but deferred to V0.6.D SLA work. The `tag_type` check constraint on `profit_fc_project_tags` will need a `workflow_status` value added at V0.6.D time, or status tags can map to existing `unknown` if that design is cleaner.~~ **RESOLVED 2026-05-10 in V0.6.D:** SLA work extends `profit_fc_project_tags` to support `tag_type='workflow_status'`, backfills `Waiting on Client`, `In Preparation`, and `Ready to Submit`, and lets Workflow 17 maintain workflow-status tags directly.
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

## V0.7.B Deferred Items Kept Open (all consolidated into expanded V0.7.D scope)

V0.7.B Task 1 SLA profiling surfaced three structural V0.7.D dependencies. V0.7.D scope was expanded on 2026-05-11 to cover them alongside its original "manual recognition + pipeline failures" scope. Estimated effort grew from 1d to 2d.

~~**Deploy-time SQL fix (folded into V0.7.B ship commit):** Migration 030's `profit_apply_classification_transitions` referenced `project.project_title` in the `sla_project_archived` clearance branch, but `profit_fc_projects.project_title` does not exist (column is `title`). Caught at psql apply during Task 8; fixed to `project.title` and re-applied. Same V0.6.D/V0.7.A pattern of schema mismatch caught by live SQL rather than static tests. Consider adding a deploy-time `psql --dry-run` step to catch these earlier.~~ **RESOLVED 2026-05-12 in V0.7.B.1 T5:** `scripts/predeploy_smoke.sh` codifies the deploy-time `psql --single-transaction BEGIN/ROLLBACK` gate. Mandatory before any migration applies to live. See `coordination/decisions.md` 2026-05-12 entry.


- **FC sync expansion: `tag_type='service'` on `profit_fc_project_tags`.** Live data has ZERO rows of `tag_type='service'` on `profit_fc_project_tags` (only `tag_type='workflow_status'`). This bridge is required by the SLA staff fallback chain (task_assignee lookup uses `service_tag.tag_type='service' AND tag_name=item.fc_tag`) AND by the `latest_workflow_status` join. Until V0.7.D backfills these tags from FC sync, all `SLA_BREACHED` Weekly Review rows show `assigned_staff_name='Unassigned'` and `latest_workflow_status=NULL`. Affects 142+ FC projects.

- **FC client staff tag sync: `tag_type='staff'` on `profit_fc_client_tags`.** Live data has ZERO rows of `tag_type='staff'` on `profit_fc_client_tags` (only `service` and `group`). This is the client-level fallback when task-level staff lookup fails. Needed alongside the previous item to make SLA staff routing work end-to-end.

- **Service catalog `entity_type` column for 1120 C/S disambiguation.** `profit_service_recognition_rules` and the SLA target chain do not distinguish 1120 (C-corp, April 15 deadline) from 1120S (S-corp, March 15 deadline). Live data has 24 1120-related breached rows all flagged with `target_date = 2026-03-16`; some are likely C-corps that aren't truly overdue until May 15 each year. V0.7.D adds entity_type metadata + per-entity-type SLA target rules.

- **Blank SLA targets for Payroll Service + Year End Accounting Close.** Two services have `default_sla_day = NULL`: Payroll Service (9 rows) and Year End Accounting Close (1 row). V0.7.B excludes them from `SLA_BREACHED` candidates via the `default_sla_day IS NOT NULL AND target_sla_day IS NOT NULL AND target_date IS NOT NULL` predicate in `profit_sla_breached_candidates`. V0.7.D should decide per-service whether to seed defaults, leave excluded, or surface as `BILLING_SETUP_GAP` verdicts. (Note: V0.7.A locks anticipated Payroll Service + Fractional CFO; Task 1 corrected this to Payroll Service + Year End Accounting Close.)

- **`waiting_on_client` SLA state generation.** `profit_sla_service_items.sla_state` returns zero `waiting_on_client` rows despite 142 backfilled `workflow_status` tags. Root cause: the SLA view joins via `service_tag.tag_type='service'` (which doesn't exist in live data). Same root cause as the FC sync expansion item above. V0.7.D fixes via FC sync; no view-level repair needed once the service tags are populated.

- **Action URL FC-task tier unreachable in current data.** `profit_sla_breached_candidates.action_url` falls back FC task → FC project → Anchor. Live data has ZERO open FC tasks across all 67 sampled breach clients, so the FC-task tier is unreachable; rows resolve to FC-project (where available) or Anchor. Not a bug — documented contract behavior tied to the FC sync gap.

- **`age_days` semantics for SLA verdicts.** `profit_sla_breached_candidates.age_days` resets to 0 when `profit_apply_classification_transitions` first creates the classification. Operator-relevant "how overdue" is exposed separately as `breach_age_days = current_date - target_date::date`. Frontend renders both: `age_days` (sort tiebreak) and `breach_age_days` (operator label). No further action needed; documented in `docs/data-contracts/weekly-review.md`.

## V0.7.D-1.1 SHIPPED — FC custom_fields as authoritative staff-assignment source (2026-05-12)

**Background:** Orlando bulk-populated 4 FC custom fields (Tax Preparer, Tax Reviewer, Book Primary, Book Reviewer) on 2026-05-12 via FC Open API. The XLSX is retired as authoritative. Migration 035g extracts these fields per client; 035h rewrites `profit_sla_breached_candidates` to use them as primary source.

**Live impact (post-deploy):**
- SLA queue `staff_source` distribution: fc_custom_field 40 / derived_primary_preparer 1 / unassigned 8 (was authoritative_assignment 13 / derived 23 / unassigned 13)
- 82% of SLA rows now resolve to a named human directly from FC's source of truth.

**Tech-debt items opened by this shift:**

1. **Mid-day FC edit lag.** W17 sync runs nightly inside W26 step 4. If operator edits a custom field in FC mid-day, the SLA queue lags up to ~24h until the next pipeline run. Mitigation: manual trigger via `POST /api/profit/admin/audit/pipeline-runs`. Long-term fix: webhook or per-field push (defer to V0.7.E or beyond).

2. **`profit_client_staff_assignments` table queued for deprecation.** This table (migration 035e, XLSX-seeded) is now a transitional cache. After one sprint of stability (V0.7.D-2 or V0.7.G), drop it via `DROP TABLE` + remove the `authoritative_assignment` fallback branch in `profit_sla_breached_candidates`.

3. **Williams Bennie has 2 orphan custom_field rows** from the rename test on 2026-05-12 (about_field_id 111574/111575 deleted; value rows persist with field=null). Harmless (invisible in FC UI). Sweepable only via specific orphan-cleanup pattern; deferred.

4. **2 XLSX entries with FC name drift remain unresolved.** "Feig, Hadar Steven (1040)" should be updated in the XLSX to match FC's "Feig, Hadar Steven and Leora (1040)" for future bulk re-runs. "Kar Kraft Auto Services LLC (closeout for 2025)" is archived in FC; either remove from XLSX or unarchive. Confirmed correct in FC already per Orlando 2026-05-12.

**Files shipped:**
- `supabase/sql/035g_profit_fc_client_staff_from_custom_fields.sql` (view)
- `supabase/sql/035h_profit_sla_candidates_use_fc_custom_fields.sql` (SLA rewrite)
- `docs/data-contracts/weekly-review.md` — Staff Assignment Source of Truth section added

---

## V0.7.B.4 SHIPPED — Labeled-Service Attribution Rule (2026-05-12)

Implements Orlando's domain rule: Anchor service names carry labels (e.g., `"1065 Essential - NDH Holdings LLC"`, `"1040 Plus (Ken & Nancy Wong)"`). The system parses each label, fuzzy-matches it to an FC client, and attributes the service to the labeled entity instead of the agreement holder. Unresolved labels (descriptive annotations like `"proration for monthly billing"`) stay on the agreement holder with an `label_unresolved=true` flag for operator visibility.

**No content-specific rules** anywhere in the implementation (per `coordination/decisions.md` 2026-05-12 entry). The fuzzy resolver is the discriminator between entity labels (attribute) and annotations (keep on agreement holder).

**Migrations (5 total):**
- `034_profit_parse_anchor_service_name.sql` — pure SQL parser with paren-depth-aware discriminator
- `034a_profit_anchor_services_attributed.sql` — attribution view with 4-strategy fuzzy resolver
- `034b_profit_sla_candidates_use_attribution.sql` — SLA candidate view sources from attribution; drops V0.7.B.3 content rules
- `034c_profit_weekly_review_items_expose_attribution.sql` — UNION queue view surfaces 3 new attribution columns
- (skipped: T5 per-service MANUAL_INVOICE_PENDING — symmetric verdict-family duplication not operator-correct)

**Frontend:**
- Sortable column headers (Rank, Client, Services, Type)
- Parent grouping toggle (Flat ⇄ Grouped by agreement)
- Label badges (gray "via {agreement holder}" for resolved; amber ⚠ for unresolved)

**Live operator outcome (verified 2026-05-12):**
- Queue: ~59 visible rows (was 24 pre-V0.7.B.4 attribution)
- Attribution working: Wolfson Lee A / Stephen T / William I each surface as own FC client rows; Samdee RE 1065 moved from SamDee Lakeland; DVH 1065 cleared via FC post-mortem project
- ICE / Accelerated / Lee's tax services now visible (previously hidden by V0.6.D revenue-event-only filter)

**Supersedes V0.7.B.3 entirely:**

~~**V0.7.B.3 1040-on-business structural rule** (migration `031`)~~ — **SUPERSEDED 2026-05-12 in V0.7.B.4.** Content-specific regex (`client_name ~* '\m(LLC|Inc|Corp|LLP|PA)\M'` paired with `service_name ILIKE '1040%'`) replaced by data-driven labeled-service attribution. 031's view body is overwritten by 034b's `CREATE OR REPLACE VIEW profit_sla_breached_candidates`.

~~**V0.7.B.3 sla_invoice_paid clearance** (migrations `032`, `032a`, `033`)~~ — **DISABLED 2026-05-12 in V0.7.B.1 T3 via 033's UPDATE.** The transition rule `sla_invoice_paid` is set to `enabled=false` and stays that way. The candidate view + apply function reverted to pre-032 shape. Domain lesson: payment is not delivery.

**Architectural thought logged for future (Orlando 2026-05-12):** Soft-judgment cases like Samdee RE's "1065 for billing only; work flows via Sam's individual 1040" need a layer above deterministic rules. Possible future AI-agent supplement that reviews queue rows for operator-correct semantic alignment + flags anomalies. NOT V0.7 scope. Captured in `coordination/decisions.md`.

## V0.7.A Deferred Items Kept Open

- Stale `MANUAL_INVOICE_PENDING` cleanup is deferred to V0.7.D. V0.7.A clears manual-invoice classifications only via the two confirmed signals: `manual_invoice_issued` (matching `profit_anchor_invoices` row with `qbo_status is not null`) and `manual_invoice_agreement_terminated` (`profit_anchor_agreements.display_status = 'terminated'` and `terminated_at is not null`). It does not attempt to repair historical stale/reopened agreement drift, orphaned state rows from agreements that transitioned outside of these signals, or `MANUAL_INVOICE_PENDING` rows whose underlying agreement no longer has any manual-trigger services. V0.7.D will sweep these along with broader stale-classification cleanup.
- Anchor deep-link discovery: V0.7.A Task 1 profiling found that all 52 active agreements have a populated `raw->>'link'` field with shape `https://app.sayanchor.com/home/relationship/<anchor_relationship_id>/agreement`. The candidate view uses `raw->>'link'` directly with a hardcoded template fallback, which is better than the originally locked hardcoded-only approach: if Anchor changes their URL structure on sync, the field updates automatically. The hardcoded fallback template remains a small maintenance surface; revisit if Anchor changes URL shape or stops emitting `link`.
- Weekly Review API filters in Python, not Supabase. `WeeklyReviewService.list_items` reads the entire `profit_weekly_review_items` view and filters `include_reviewed`, `include_snoozed`, and `verdict_code` in application code. Acceptable at V0.7.A scale (5 day-one rows, single operator). Push filters to Supabase REST `?select=...&...=eq.` query params if the queue grows past 100 rows or multi-practice routing in V0.7.E adds combinatorial filters.
- Weekly Review buttons disabled for unclassified candidates. The candidate view can surface rows where `classification_id is null` (agreement matches manual-invoice predicate but `profit_apply_classification_transitions` has not yet inserted the classification row). The frontend disables Mark reviewed / Snooze for these rows with a tooltip explaining they become actionable after the next pipeline run. Steady-state operation does not hit this case; revisit if cold-start UX needs a first-run nudge.
- Weekly Review multi-operator support deferred beyond V0.7. `profit_weekly_review_item_state.operator_id` defaults to `'orlando'` and the API does not propagate authenticated user identity. Concurrency, presence indicators, and per-operator queue filtering are out of scope until Supabase Auth replaces nginx basic auth.
- `age_days` in `profit_manual_invoice_pending_candidates` resets to 0 when `profit_apply_classification_transitions` first creates the classification row. The view computes `current_date - coalesce(classified_at::date, effective_date::date, current_date)`, so once classified_at is populated the agreement-level effective_date age is masked. Observed during V0.7.A deploy: B&B Technology Solutions surfaced as `age_days=166` from the pre-classification candidate view, then dropped to `age_days=0` immediately after the deploy-time apply ran. Operator-relevant for "how long has this work been awaiting an invoice?" semantics — consider exposing a separate `agreement_age_days` field (`current_date - effective_date::date`) alongside `age_days` in V0.7.B or V0.7.D when the queue gains additional verdict types with different age semantics.

## V0.6.D Deferred Items Kept Open

- Service `default_sla_day` data quality remains a follow-up. The 13 `not_applicable` services and 2 blank/defaultless service rows reviewed during V0.6.D are intentional for the current SLA surface, but that does not close the gap forever; future service catalog changes can reintroduce missing or stale SLA defaults.
- Recognized tile drill-down remains deferred. The main dashboard's Recognized tile still does not link to the underlying RevenueEvents, so audit-friendly recognized-revenue drill-down is still out of scope for V0.6.D.
- "Reviewed" tracking on review checklist remains deferred. V0.6.D does not add a reviewed state, persistence, or operator identity to dashboard checklist items.
- Per-tile staleness badges remain deferred. V0.6.D does not add freshness badges to existing dashboard metric tiles.
- Audit page service-tag density redesign remains deferred. The audit dashboard keeps its existing service/tag density and does not add a compact redesign in V0.6.D.
- Frontend test infrastructure remains deferred. V0.6.D does not introduce a broader frontend test runner or component-test harness beyond the existing static/backend checks.
- Manual Recognition UI polish remains deferred. The four Manual Recognition polish items carried from V0.6.B.2.b are still outside V0.6.D's SLA dashboard scope.
