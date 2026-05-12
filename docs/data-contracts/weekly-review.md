# Weekly Review Data Contract

**V0.7.A — Manual Invoice Pending + Weekly Review skeleton**
**V0.7.B — SLA Breached folded in (universal queue contract)**

---

## Purpose

The Weekly Review queue surfaces actionable revenue-at-risk items for the operator to review each week. Each item represents a classification verdict that has not yet resolved, grouped by type and ordered by urgency.

---

## Tables

### `profit_weekly_review_item_state`

Persists operator interaction state for each queue item. One row per active classification that has been interacted with (snoozed or reviewed). The pipeline does **not** write to this table.

| Column | Type | Notes |
|---|---|---|
| `classification_id` | `bigint PK FK → profit_classifications` | Primary key; only exists after `profit_apply_classification_transitions` creates the classification row |
| `reviewed_at` | `timestamptz` | When the operator last marked this item reviewed. NULL = not reviewed |
| `snoozed_until` | `date` | Inclusive date until which item is hidden. NULL = not snoozed. Standard action = **Snooze 7 days** |
| `operator_id` | `text NOT NULL DEFAULT 'orlando'` | Operator who owns the state row. Single-user for V0.7; multi-user expansion deferred |
| `practice_id` | `text` | Practice assignment for multi-firm routing. **Nullable until V0.7.E** adds the M&A configuration layer |
| `created_at` | `timestamptz` | Row creation timestamp |
| `updated_at` | `timestamptz` | Auto-updated by trigger on every UPDATE |

### `profit_weekly_review_visible_verdicts`

Registry table controlling which verdict codes appear in the queue. Insert a row here to enable a new verdict type in the UI; no code change required.

| Verdict code | Added in | sort_order |
|---|---|---|
| `MANUAL_INVOICE_PENDING` | V0.7.A | 10 |
| `SLA_BREACHED` | V0.7.B | 20 |

V0.7.C will add Anchor backfill verdicts. V0.7.D will add stale recognition + pipeline failure verdicts + FC sync expansion (service tags + staff tags) + service-catalog entity_type (1120 C/S disambiguation).

---

## Views

### `profit_weekly_review_items`

Universal queue view. **V0.7.B replaces this view with a `UNION ALL` of two candidate sources**, one per registered verdict type, each left-joined with operator review state.

**Sources (V0.7.B):**
- `profit_manual_invoice_pending_candidates` (from migration 029, V0.7.A)
- `profit_sla_breached_candidates` (from migration 030, V0.7.B)

**UNION column shape:** every branch SELECTs the same column list. Columns common to both branches are populated by each. Columns that only make sense for one verdict family are `NULL`-cast on the other branch. The frontend conditionally renders based on `verdict_code`.

**Common columns (both branches populate):**

| Column | Description |
|---|---|
| `classification_id` | FK into `profit_classifications`. NULL for candidates not yet classified |
| `verdict_code` | `MANUAL_INVOICE_PENDING` or `SLA_BREACHED` |
| `item_type` | Mirror of verdict_code; reserved for future cross-verdict grouping |
| `fc_client_id` | Financial Cents client ID (NULL if no match) |
| `anchor_relationship_id` | Anchor agreement identifier |
| `client_name` | Business name (FC or Anchor) |
| `service_name` | Concatenated manual services for MANUAL_INVOICE_PENDING; single SLA service name for SLA_BREACHED |
| `action_url` | Anchor relationship URL (manual) or FC task→project→Anchor fallback (SLA) |
| `age_days` | Days since classification was created |
| `reviewed_at` | NULL if not reviewed |
| `snoozed_until` | NULL if not snoozed |
| `operator_id` | Defaults to `'orlando'` |
| `practice_id` | NULL until V0.7.E |
| `sort_rank` | Integer row rank; **1 = most urgent** |

**Manual-invoice-only columns (NULL on SLA rows):**

| Column | Description |
|---|---|
| `invoice_state` | `no_invoice` or `draft_only` |
| `estimated_annual_revenue` | Sum of manual service prices |

**SLA-only columns (NULL on manual-invoice rows):**

| Column | Description |
|---|---|
| `breach_state` | `breached` or `at_risk` (the SLA state from `profit_sla_service_items`) |
| `breach_age_days` | `current_date - target_date::date`, clamped to ≥0 — operator-relevant "how overdue" measure |
| `work_age_days` | Underlying work-item age from `profit_sla_service_items` |
| `target_date` | The SLA target date (e.g. tax-return deadline + SLA grace) |
| `target_sla_day` | Day-of-year SLA target |
| `macro_service_type` | `tax`, `bookkeeping`, `payroll`, etc. |
| `fc_tag` | The service-tag string from FC |
| `assigned_staff_name` | NULL/'Unassigned' until V0.7.D fixes FC sync (see tech-debt) |
| `staff_source` | `task_assignee`, `client_staff_tag`, or `unassigned` |
| `latest_workflow_status` | NULL until V0.7.D backfills `tag_type='service'` rows |
| `fc_task_id` | NULL until V0.7.D (no open tasks in current data) |
| `fc_project_id` | Available where the FC service-tag join resolves |

**Attribution columns (V0.7.B.4, appended after `sort_rank`):**

| Column | Description |
|---|---|
| `label` | Parsed label text from the Anchor service name (e.g., `"Lee Wolfson"` from `"1040 Plus - Lee Wolfson"`). NULL on unlabeled services and on manual-invoice rows |
| `label_unresolved` | Boolean. TRUE when a label exists but the fuzzy resolver could not map it to an FC client (Type 2 annotations like `"proration for monthly billing"` land here). NULL on unlabeled services and manual-invoice rows |
| `agreement_client_business_name` | The source agreement holder's business name. Used by the UI for the `via {X}` badge and for parent-grouping rows |

The SLA branch sources these from `profit_anchor_services_attributed` (migration 034a); the manual-invoice branch null-casts them (V0.7.A candidates don't yet go through attribution). See [Attribution Layer (V0.7.B.4)](#attribution-layer-v07b4) below.

**`sort_rank` ordering (V0.7.B UNION-wide):**
1. SLA breached (band 1)
2. SLA at_risk (band 2)
3. MANUAL_INVOICE_PENDING (band 3)
4. Within band: `coalesce(breach_age_days, age_days) desc nulls last`
5. Tiebreak: `estimated_annual_revenue desc nulls last`, then `client_name asc`

---

## Default Filtering Rules

The view returns **all** rows. The API and frontend apply these default filters:

| Filter | Default | Toggle |
|---|---|---|
| Exclude snoozed items | ON (hide where `snoozed_until >= current_date`) | No UI toggle in V0.7.A |
| Exclude reviewed items | ON (hide where `reviewed_at IS NOT NULL`) | **Show reviewed** toggle in frontend |

### `Show reviewed`

When the operator enables **Show reviewed**, the API passes `include_reviewed=true` and the frontend renders reviewed rows with a muted style to distinguish them from actionable items.

### `include_snoozed`

API parameter (not exposed in V0.7.A UI). Reserved for future bulk-management workflows.

### Snooze 7 days

Standard operator action: sets `snoozed_until = current_date + 7` on the state row. The item disappears from the default queue for 7 days. After the snooze expires, the item reappears automatically (no job required — the view re-evaluates the date predicate on each query).

---

## `practice_id` — Nullable Until V0.7.E

`practice_id` is stored in `profit_weekly_review_item_state` and exposed in `profit_weekly_review_items` but is **always NULL** until V0.7.E adds the M&A configuration layer. V0.7.E will:
- Define the `profit_practices` table with one row per acquired firm.
- Backfill `practice_id` on existing state rows using the client-to-practice mapping.
- Enable per-practice queue filtering in the Weekly Review UI.

---

## Future Verdict Registration (V0.7.B-D)

To register a new verdict type in the queue:

1. Add the verdict code to `profit_classification_verdicts` (in its own migration).
2. Create a candidate view for that verdict (naming convention: `profit_<verdict_snake>_candidates`).
3. INSERT a row into `profit_weekly_review_visible_verdicts` with the verdict code.
4. Extend `profit_weekly_review_items` to UNION the new candidate view (or refactor the view to a dynamic dispatch pattern if more than 5 types are registered).

---

## Dual-Row Co-occurrence

Same client/agreement may appear in BOTH `MANUAL_INVOICE_PENDING` and `SLA_BREACHED` simultaneously (e.g. a Schmidli-like client whose tax return is past SLA and whose invoice was never issued). The `UNION ALL` produces two distinct rows. Each row tracks its own review/snooze state via its own `classification_id` so the operator can Mark reviewed or Snooze each verdict independently.

## Attribution Layer (V0.7.B.4)

**The labeled-service attribution rule (Orlando, 2026-05-12):**

> For every service NOT labeled, it applies to the agreement client name. Otherwise, if there is a label on the service name, the SLA/billing scope goes to the LABELED client as resolved within Financial Cents.

This rule is fully data-driven. No content-specific regex, no hardcoded client names. Operators encode attribution in Anchor by typing the FC client name into the service name; the system parses + resolves it.

### Migrations

| Migration | Object | Role |
|---|---|---|
| `034_profit_parse_anchor_service_name.sql` | `profit_parse_anchor_service_name(text)` | Pure SQL parser. Returns `(canonical_service_name, label)`. Paren-depth-aware so labels with nested parens (`"1065 Essential (Samdee RE - Spring Hill)"`) parse correctly |
| `034a_profit_anchor_services_attributed.sql` | view `profit_anchor_services_attributed` | Joins parsed services to FC clients via 4-strategy fuzzy resolver (normalized-exact / normalized-prefix / last-token-first reorder / comma-format token-prefix). One row per `(anchor_relationship_id, canonical_service_name, label)`. Emits `attributed_fc_client_id`, `attributed_fc_client_name`, `label`, `label_unresolved`, `resolution_strategy` |
| `034b_profit_sla_candidates_use_attribution.sql` | view `profit_sla_breached_candidates` (rewritten) | Sources from the attribution view instead of `profit_sla_service_items`. Surfaces every active Anchor service (not just those with revenue events). SLA state computed inline (mirrors `profit_sla_service_items`'s state machine; workflow_status integration deferred to V0.7.D) |
| `034c_profit_weekly_review_items_expose_attribution.sql` | view `profit_weekly_review_items` (rebuilt) | Appends the 3 attribution columns to the UNION shape. Manual branch null-casts them |

### Resolver strategies (4-tier deterministic fuzzy match)

| # | Strategy | Example |
|---|---|---|
| 1 | Normalized-exact (whitespace/case/punct-normalized) | `"NDH Holdings LLC"` ↔ FC `"NDH Holdings, LLC"` |
| 2 | Normalized-prefix | `"Menist, Samuel"` ↔ FC `"Menist, Samuel E (1040)"` |
| 3 | Last-token-first reorder (N-token) | `"Ken & Nancy Wong"` ↔ FC `"Wong, Ken & Nancy"`; also `"Roy Surber"` ↔ FC `"Surber, Roy"` |
| 4 | Comma-format token-prefix tolerance | `"Sullivan, Chris"` ↔ FC `"Sullivan, Christopher"` |

Strategy chosen recorded in `resolution_strategy`. Failed resolution (no FC match across all 4 strategies) keeps the row attributed to the agreement holder and sets `label_unresolved = TRUE` so operators can investigate.

### Collapse rule

Candidate view applies `DISTINCT ON (fc_client_id, service_name)` with `ORDER BY (label IS NULL) DESC, label_unresolved ASC NULLS FIRST, target_date ASC NULLS LAST`. Effect: if the same `(attributed-client, canonical-service)` pair appears multiple times (e.g., a personal 1040 attributed to Lee Wolfson from both Lee's Food and Lee's Ice agreements; or YV's `"1040 Plus"` plus its `"1040 Plus - proration..."` annotation), the queue shows ONE row, preferring the unlabeled main entry over the annotation duplicate.

### UI rendering rules

| Condition | Rendering |
|---|---|
| `label IS NULL` | No attribution badge. Row groups under `client_name` |
| `label IS NOT NULL AND label_unresolved = FALSE` | Gray badge `via {agreement_client_business_name}`. Row groups under the resolved FC client |
| `label IS NOT NULL AND label_unresolved = TRUE` | Amber ⚠ badge `via {agreement_client_business_name}` (orphan). Row groups under the agreement holder (since FC client didn't resolve) |

The flat-vs-grouped toggle is operator-controlled. Grouped view uses the resolved attribution client (or agreement holder for orphans) as the parent.

### What this rule does NOT do (deferred)

- **Per-service `MANUAL_INVOICE_PENDING`** — V0.7.A's `profit_manual_invoice_pending_candidates` is per-agreement (concatenated service names). Per-service rewrite deferred (T5 skipped this sprint; revisit only if operator surfaces specific gaps).
- **Workflow status integration** — `latest_workflow_status` still NULL until V0.7.D backfills `tag_type='service'` rows on `profit_fc_project_tags`.
- **AI-agent supplement** — soft-judgment cases (Samdee RE 1065 billing-convention vs operational handling) flagged for post-V0.7 consideration. Pure data rules cannot disambiguate; an agent layer reading conversational context may.

## Deferred Gaps

- **Stale MANUAL_INVOICE_PENDING cleanup** — if an agreement transitions outside of normal invoice issuance, orphaned state rows may remain. Scheduled cleanup deferred to V0.7.D.
- **SLA verdict staff routing** — V0.7.B SLA rows show `assigned_staff_name = 'Unassigned'` for ALL day-one rows because `profit_fc_project_tags` has no `tag_type='service'` rows and `profit_fc_client_tags` has no `tag_type='staff'` rows. FC sync expansion deferred to V0.7.D.
- **SLA verdict workflow_status** — same root cause as staff routing; `latest_workflow_status` is always NULL until V0.7.D backfills service tags.
- **1120 C/S entity_type disambiguation** — service catalog lacks entity_type metadata; ~24 1120 rows in current data may include C-corp false positives in the April 15 → May 15 window each year. Deferred to V0.7.D.
- **Multi-user operator support** — `operator_id` is single-valued per state row; concurrent multi-user access deferred beyond V0.7.
- **Per-practice queue filtering** — deferred to V0.7.E.
