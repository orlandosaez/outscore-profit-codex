# Anchor Service Recognition Rules

Canonical reference for mapping Anchor service taxonomy to profit-system recognition behavior.

Source: `/Users/orlandosaez/agents/outscore-profit-cc/anchor services-2026-04-26.csv`.

This document is operating doctrine. V0.5.2 should encode these rules in a config table, but the rules live here first so the taxonomy, defaults, and exceptions are explicit before code touches them.

## Core Principles

- Anchor service names are the source taxonomy for revenue line-item classification.
- Macro service type controls recognition workflow routing.
- Recognition timing is based on service delivery, not invoice issue date, except for pass-through exclusions.
- Tier labels such as Essential, Plus, and Advanced usually describe complexity and price, not recognition timing.
- Any service not listed in this taxonomy defaults to `manual_review` and must surface in the V0.5.2 pipeline run log as `needs classification`.

## Recurring Monthly Services

For recurring monthly operational services, the service period rule is always **previous month** unless explicitly noted. A May completion task usually recognizes April revenue.

| Anchor service name | Macro service type | Monthly price | Service period rule | Default SLA day | Recognition rule / notes |
| --- | --- | ---: | --- | --- | --- |
| Accounting Advanced | bookkeeping | $900 | previous month | day 10 default | Recognize from FC bookkeeping completion for the prior month. Per-engagement SLA override allowed. |
| Accounting Plus | bookkeeping | $650 | previous month | day 10 | Recognize from FC bookkeeping completion for the prior month. |
| Accounting Essential | bookkeeping | $350 | previous month | day 20 | Recognize from FC bookkeeping completion for the prior month. |
| Sales Tax Compliance | tax | $30 | previous month | day 20 | Recognize from FC sales-tax filing/completion trigger for the prior month. V0.5.2 should avoid treating this as annual income-tax work. |
| Payroll Service | payroll | $110 | previous month | per cadence | Recognize by payroll processed trigger. SLA follows payroll cadence, not a fixed calendar day. |
| Tangible Property Tax | tax | $20 | previous month | TBD | Flag for review in V0.5.2; monthly billing exists but annual tangible-property filing cadence may require special treatment. |
| Audit Protection Business | insurance_accrual | $30 | previous month | no SLA | Insurance-style accrual. Do not wait on FC service completion. V0.5.2 should decide whether this is recognized monthly on coverage passage. |
| Audit Protection Individual | insurance_accrual | $5 | previous month | no SLA | Insurance-style accrual. Do not wait on FC service completion. V0.5.2 should decide whether this is recognized monthly on coverage passage. |
| Fractional CFO | advisory | $1,500-$4,500 | previous month | monthly meeting cadence | Recognize on advisory delivery/monthly meeting cadence. Price varies by tier: Starter $1,500, Growth $2,500, Scale $4,500. |
| 1099 Preparation | tax | $0 | previous month | review | Edge case for review. Anchor service is monthly at $0 but actual pricing is per-form/late-rate; V0.5.2 should require explicit classification before automatic recognition. |

## Quarterly Services

| Anchor service name | Macro service type | Price | Service period rule | Default SLA | Recognition rule / notes |
| --- | --- | ---: | --- | --- | --- |
| Payroll Tax Compliance | payroll | $85 quarterly | quarter just completed | federal/state deadline-driven | Recognize from FC payroll-tax filing/compliance trigger. Deadline is driven by federal/state quarterly payroll filing due dates, not a monthly close day. |

## Annual / Engagement-Driven Tax Services

Default recognition rule for annual tax services:

> Match FC `tax_filed` trigger by form type to the oldest pending revenue event under the same `anchor_relationship_id`.

The FC trigger service period may be the completion month. For annual tax events, V0.5.2 should not require a strict month equality join when matching filed returns. It should use form type + Anchor relationship + oldest pending event, because the invoice month and the filing/completion month often differ.

Tier names (`Essential`, `Plus`, `Advanced`) represent complexity and price. They do **not** affect recognition timing.

| Anchor service name | Macro service type | Price | Form type pattern | Recognition rule / notes |
| --- | --- | ---: | --- | --- |
| 1040 Essentials | tax | $200 | 1040 | Match FC `tax_filed` for individual return to oldest pending 1040 revenue event under same Anchor relationship. |
| 1040 Plus | tax | $350 | 1040 | Match FC `tax_filed` for individual return to oldest pending 1040 revenue event under same Anchor relationship. |
| 1040 Advanced | tax | $650 | 1040 | Match FC `tax_filed` for individual return to oldest pending 1040 revenue event under same Anchor relationship. |
| 1065 Essential | tax | $350 | 1065 | Match FC `tax_filed` for partnership return to oldest pending 1065 revenue event under same Anchor relationship. |
| 1065 Plus | tax | $650 | 1065 | Match FC `tax_filed` for partnership return to oldest pending 1065 revenue event under same Anchor relationship. |
| 1065 Advanced | tax | $1,100 | 1065 | Match FC `tax_filed` for partnership return to oldest pending 1065 revenue event under same Anchor relationship. |
| 1120 Essential | tax | $350 | 1120 / 1120S | Match FC `tax_filed` for corporate return to oldest pending 1120/1120S revenue event under same Anchor relationship. |
| 1120 Plus | tax | $550 | 1120 / 1120S | Match FC `tax_filed` for corporate return to oldest pending 1120/1120S revenue event under same Anchor relationship. |
| 1120 Advanced | tax | $1,100 | 1120 / 1120S | Match FC `tax_filed` for corporate return to oldest pending 1120/1120S revenue event under same Anchor relationship. |
| 990-EZ Short Form | tax | $350 | 990-EZ | Match FC `tax_filed` for nonprofit return to oldest pending 990-EZ revenue event under same Anchor relationship. |
| 990 Full Return Essential | tax | $600 | 990 | Match FC `tax_filed` for nonprofit return to oldest pending 990 revenue event under same Anchor relationship. |
| 990 Full Return Plus | tax | $1,200 | 990 | Match FC `tax_filed` for nonprofit return to oldest pending 990 revenue event under same Anchor relationship. |
| 990-T Unrelated Business | tax | $450 | 990-T | Match FC `tax_filed` for unrelated-business income return to oldest pending 990-T revenue event under same Anchor relationship. |
| Annual Estimate Tax Review | tax | $200 | estimate review | One-time delivery. Recognize when estimate review is delivered/completed, not on annual filing trigger. |

## One-Time / Project Services

Default recognition rule: recognize at delivery or billing when the project is completed and no continuing service obligation remains.

| Anchor service name | Macro service type | Price | Recognition rule / notes |
| --- | --- | ---: | --- |
| Advisory | advisory | $225/hr | Recognize at delivery. Hourly project/ad-hoc advisory, billed in 15-minute increments. |
| Setup and Onboarding | advisory | $850 | Recognize at onboarding delivery/completion. |
| Audit Support Service | advisory | $125/hr | Recognize at delivery. Audit support is work performed, not audit-protection insurance accrual. |
| Specialized Services | advisory | varies / $0 default | Recognize at delivery/billing after explicit review. Default $0 requires review before automated recognition. |
| Year End Accounting Close | bookkeeping | varies / $0 default | Recognize at delivery of year-end close package. Default $0 requires review before automated recognition. |
| Work Comp Tax | payroll | varies / $0 default | Recognize at delivery. Although named "tax," this is workers' comp/payroll-adjacent compliance; V0.5.2 should require explicit rule/config review. |

## Pass-Through / Non-Revenue Services

These services use `macro_service_type = pass_through` and are excluded from the recognition pipeline entirely. They should not create revenue events for GP or prepaid liability.

| Anchor service name | Macro service type | Price | Rule |
| --- | --- | ---: | --- |
| Billable Expenses | pass_through | $0 | Exclude. Out-of-pocket reimbursement/pass-through. |
| Other Income | pass_through | $0 | Exclude from service recognition. Review separately if management wants non-service income reporting. |
| Remote Desktop Access | pass_through | $200 yearly | Exclude. Client reimbursement / access cost recovery. |
| Remote QBD Access | pass_through | $200 yearly | Exclude. Client reimbursement / access cost recovery. |
| Services | pass_through | $0 | Exclude by default. Generic product should not enter recognition pipeline without explicit classification. |

## Implicit Rules

- Services not present in this taxonomy default to `manual_review`.
- V0.5.2 pipeline run logs must surface unknown services as `needs classification`.
- Adding a new Anchor service requires updating both this document and the corresponding config table seed.
- The config table seed should be treated as an executable copy of this doctrine; drift between the seed and this document is a bug.
- Services with `$0` default pricing are not automatically non-revenue. Some are true edge-case service products and must be reviewed before recognition automation.
- Pass-through services are different from `$0` service products. Pass-through items are excluded from recognition; `$0` service products are classification gaps until reviewed.

## Related Docs

- `docs/anchor-invoice-note-conventions.md` — planned companion doc for invoice note conventions and form/entity hints.
- `docs/data-contracts/recognition-triggers.md` — trigger table, ready-view behavior, FC trigger loading, and manual recognition overrides.
- `docs/data-contracts/qbo-collections.md` — cash collection, allocation, prepaid liability, and QBO collection-feed behavior.
