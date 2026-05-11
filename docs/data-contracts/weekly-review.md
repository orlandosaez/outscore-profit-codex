# Weekly Review Data Contract

**V0.7.A — Manual Invoice Pending + Weekly Review skeleton**

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

| Verdict code seeded in V0.7.A |
|---|
| `MANUAL_INVOICE_PENDING` |

V0.7.B will add SLA-breach verdicts. V0.7.C will add Anchor backfill verdicts. V0.7.D will add stale recognition + pipeline failure verdicts.

---

## Views

### `profit_weekly_review_items`

Universal queue view. Joins candidate views (one per registered verdict type) with operator review state.

**Source in V0.7.A:** `profit_manual_invoice_pending_candidates` (from migration 029).

**Output columns:**

| Column | Description |
|---|---|
| `classification_id` | FK into `profit_classifications`. NULL for candidates not yet classified by the pipeline |
| `verdict_code` | E.g. `MANUAL_INVOICE_PENDING` |
| `item_type` | Category discriminator (mirrors verdict_code in V0.7.A; may diverge in V0.7.B+) |
| `anchor_relationship_id` | Anchor agreement identifier |
| `fc_client_id` | Financial Cents client ID (NULL if no match row) |
| `client_name` | `client_business_name` from the Anchor agreement |
| `service_name` | Concatenated manual-trigger service names |
| `invoice_state` | `no_invoice` or `draft_only` |
| `age_days` | Days since classification was created (or since `effective_date`) |
| `estimated_annual_revenue` | Sum of manual service prices from `profitSyncServiceSummary` |
| `action_url` | `raw->>'link'` from the agreement, fallback to hardcoded template |
| `reviewed_at` | NULL if not reviewed |
| `snoozed_until` | NULL if not snoozed |
| `operator_id` | Defaults to `'orlando'` |
| `practice_id` | NULL until V0.7.E |
| `sort_rank` | Integer row rank; **1 = most urgent**. Ordered: oldest age_days first → highest revenue → client name A-Z |

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

## Deferred Gaps

- **Stale MANUAL_INVOICE_PENDING cleanup** — if an agreement transitions outside of normal invoice issuance, orphaned state rows may remain. Scheduled cleanup deferred to V0.7.D.
- **Multi-user operator support** — `operator_id` is single-valued per state row; concurrent multi-user access deferred beyond V0.7.
- **Per-practice queue filtering** — deferred to V0.7.E.
