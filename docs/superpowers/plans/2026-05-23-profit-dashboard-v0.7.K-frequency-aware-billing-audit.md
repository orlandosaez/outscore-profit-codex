# V0.7.K — Frequency-Aware Billing Audit (single migration)

**Date:** 2026-05-23 (same day as V0.7.J)
**Status:** PROPOSED
**Estimated effort:** ~1.5 hours
**Sprint shape:** identical to V0.7.J — single SQL migration + focused tests

---

## Problem statement

Category E (`subscription_billing_gap`, from migrations 040a/040b/040c, preserved
in 053) fires at 35 days for any active agreement that hasn't seen a QBO invoice.
But it's frequency-blind. On 2026-05-23 review of prod data:

- 6 hits surfaced, all false positives
- 100% of the 6 hits are `service.billing.trigger = 'manual'` services
- These are annual tax returns (`occurrence = 'yearly'`) or one-time projects
- They naturally invoice once a year (at filing), not on a 35-day cadence

The 6 hits also obscured a real signal: 3 of them (Bachert / Lee's / West Coast)
have an **upfront invoice that was issued but never paid or QBO-synced** —
which is an AR-aging issue, not a billing cadence issue.

## Design principle

> Use Anchor's own data (`service.billing.occurrence` + `service.billing.trigger`).
> Don't invent heuristics when the source system already publishes the answer.

## Anchor's billing taxonomy (verified on prod 2026-05-23)

| occurrence | trigger | count | meaning |
|---|---|---|---|
| `monthly` | `auto` | 24 | Bookkeeping, payroll, monthly subs |
| `quarterly` | `auto` | 3 | Quarterly auto-billed |
| `yearly` | `manual` | 41 | Annual tax returns, billed by operator at filing |
| `one_time` | `manual` | 5 | One-time projects |

Per-service JSON shape:
```json
{
  "name": "990 Full Return Essential",
  "billing": {
    "trigger": "manual",
    "occurrence": "yearly",
    "isBilledUpfront": false
  },
  "status": { "type": "approved" }
}
```

## Scope

Two related changes in one migration (054):

### K.1 — Rewrite category E (`subscription_billing_gap`)

Replace agreement-level cadence check with service-level frequency-aware check:

```
Fire when:
  agreement.display_status = 'active'
  AND service.status.type = 'approved'
  AND service.billing.trigger = 'auto'
  AND days_since_last_invoice_on_agreement > threshold
WHERE threshold =
  service.billing.occurrence = 'monthly'   → 45 days
  service.billing.occurrence = 'quarterly' → 100 days
  (else)                                    → 380 days (safety net for unknown)
```

`manual`-trigger services (yearly returns, one-time projects) are excluded
because they're invoiced when work is delivered, not on a calendar cadence.

Subject_id stays at agreement level (one row per agreement with cadence-violating
auto service), to preserve current row shape; description must name the specific
service(s) and their cadence(s) that triggered the alert.

### K.2 — Add category M (`held_invoice_unpaid`)

Picks up the AR-aging signal that K.1 will no longer carry by accident:

```
Fire when:
  An Anchor invoice exists for an active agreement
  AND amount_paid = 0
  AND qbo_status NOT IN ('paymentSynced', 'paid', 'voided', 'voidedSynced')
  AND days_since_issued > 30
```

`subject_kind = 'anchor_invoice'`, `subject_id = invoice anchor_invoice_id`.
Description includes the customer name + invoice number (e.g., SBC-XXXXX) +
days held + current qbo_status.

This is the long-deferred `recognized_revenue_unpaid_30d` concept Orlando
queued as optional in earlier sprints. K.2 ships it cleanly because the
analysis is already done.

## Out of scope

- ❌ No re-architecture of how invoices are sourced (uses existing `profit_anchor_invoices`)
- ❌ No new tables
- ❌ No frontend changes (existing `/profit/admin/data-quality` page surfaces both categories automatically)
- ❌ No changes to other audit categories
- ❌ No tuning of K.1 thresholds beyond the 45/100/380 starting point — revisit only if real-world false positives recur

## Migrations + filenames

- `supabase/sql/054_profit_billing_audit_frequency_aware.sql` — single migration containing both K.1 (category E rewrite) and K.2 (category M addition). `CREATE OR REPLACE VIEW profit_data_quality_alerts AS ...` carrying forward ALL existing categories (A–K, pipeline_cron_stale, L1–L3) per the 053 hotfix lesson.

## Test plan

New + extended tests in `tests/test_pipeline_backend_sql.py`:

- `test_migration_054_category_e_only_fires_for_auto_trigger`
- `test_migration_054_category_e_threshold_per_occurrence` (4 fixtures: monthly@30d safe, monthly@50d fire, quarterly@90d safe, quarterly@110d fire, yearly@200d safe)
- `test_migration_054_category_m_fires_on_held_invoice` (3 fixtures: held > 30d fires, recent draft safe, paymentSynced safe)
- `test_migration_054_carries_forward_all_prior_categories` ← **load-bearing per 053 hotfix lesson**

New snapshot in `tests/test_profit_api_data_quality.py` for category M response shape.

## Verification on prod after deploy

```
-- Category E should drop from 6 hits to 0 (all current hits are manual-trigger)
select count(*) from profit_data_quality_alerts
 where alert_category = 'subscription_billing_gap';

-- Category M should fire for Bachert/Lee's/West Coast (held upfront invoices)
select subject_name, description from profit_data_quality_alerts
 where alert_category = 'held_invoice_unpaid';

-- Total alert categories should be 14 (was 13 after V0.7.J)
select count(distinct alert_category) from profit_data_quality_alerts;
```

## Memory updates on completion

- `self_audit_data_quality_alerts.md` — add category M; update category E description
- `client_matching_robustness.md` — no change needed
- `MEMORY.md` index — add brief V0.7.K reference

## Risks + rollback

| Risk | Mitigation |
|---|---|
| Category M over-fires on legitimately-in-flight invoices | 30-day grace; can raise to 45 if needed |
| Threshold 45/100/380 wrong for some edge case | Adjustable via single migration; no schema change |
| Carry-forward regression (dropped categories) | Explicit test `test_migration_054_carries_forward_all_prior_categories` |
| `service.billing.occurrence` ever returns unexpected value | Safety-net branch defaults to 380d (effectively never fires) |

Rollback: revert migration 054. Categories revert to current state (E too noisy, no M).

## Sequencing

Same day as V0.7.J. Single Codex CLI session, two phases (interpret → execute).
