# Profit Admin Portal Review Guide

Purpose: this is a working reference for reviewing the current Profit Admin portal. It explains what each block means, how to use it in a monthly review, and where the surface is still incomplete.

Audience: Orlando, bookkeeper, and anyone helping review whether the dashboard is useful and trustworthy.

Status: initial reference. The portal is live, but several surfaces are still review tools rather than final management reports.

## Monthly Review Workflow

Use the portal in this order:

1. Start with the top company tiles to confirm whether the month and quarter look directionally right.
2. Review `Pending` and the `FC Trigger Queue` to see what work may be complete but not yet recognized.
3. Review `Per-Client GP` for negative, missing-owner, missing-revenue, or `other` service rows.
4. Review `Per-Staff GP` only after the client/service rows look reasonable.
5. Review `Comp Ledger` after recognition and client-owner assignments are cleaned up.
6. Review `W2 Watch` monthly as a staffing planning report, not as a payroll/legal conclusion.

Important: if a client row looks wrong, do not assume the client is unprofitable yet. First check whether the row is missing recognized revenue, missing owner assignment, or sitting in the `other` service bucket.

## Top Header

The header says `Outscore Advisory Group` and `Profit Admin`.

The refresh button reloads the dashboard data from the API. It does not run n8n syncs, reload Anchor, reload Financial Cents, or apply recognition. It only refreshes what is already in Supabase.

Use this when you know a sync or recognition process has already run and you want to reload the visible dashboard.

Still working on:

- showing last refresh time,
- showing data freshness by source,
- showing whether any n8n sync is currently stale or failed.

## Company GP

This tile shows the latest monthly gross profit percentage.

Formula:

```text
Company GP % = (recognized revenue - contractor labor cost) / recognized revenue
```

What it currently tells you:

- whether the latest recognized month is profitable after contractor labor,
- whether the company is directionally above or below the target profitability model,
- the GP dollars for the same latest month.

How to review it:

- Confirm the displayed month is the month you expected to review.
- Compare the GP % against your current target.
- If GP looks too high, check whether labor is missing or revenue was recognized without matching labor.
- If GP looks too low, check whether labor has been loaded before revenue was recognized.

Current limitation:

- This tile depends on recognized revenue. If tax returns are complete but not yet recognized, or if bookkeeping recognition has not been triggered, GP can look artificially low or high.

## Quarter Gate

This tile shows whether the company passed the compensation gate for the current quarter.

Current rule:

```text
Gate passes when company GP % is at or above 50%
```

It also shows the actual quarter GP % compared with the gate percentage.

How to review it:

- Use this as the first check before discussing performance-based kicker payouts.
- If the gate is open/not passed, staff kicker accruals may show zero even when individual clients look profitable.
- If the gate passed, review the Comp Ledger to see whether kicker amounts are actually accruing.

Current limitation:

- The dashboard does not yet explain the prior-quarter gate logic inside the UI. Some kicker rows may be zero because the prior quarter failed, even if the current quarter is passing.

## Recognized

This tile shows total recognized revenue and the count of recognized revenue events.

Recognized revenue is separate from invoices and cash collected. It is the amount the recognition rules say belongs in the period.

Examples:

- Tax revenue is recognized when a tax filing trigger is approved and applied.
- Bookkeeping revenue should eventually be recognized when monthly work is substantially complete.
- Payroll revenue should eventually be recognized in the service month when payroll is processed.

How to review it:

- Use this to confirm that completed work is actually flowing into revenue.
- If recognized revenue is lower than expected, check the FC Trigger Queue and pending revenue amount.
- If recognized revenue looks high, confirm that the underlying trigger/event is legitimate.

Current limitation:

- The portal does not yet show a drill-down from this tile to the specific RevenueEvents. That drill-down is needed before this becomes audit-friendly.

## Pending

This tile shows pending revenue and ready FC triggers.

Pending revenue means revenue event candidates exist but have not yet become recognized revenue.

Ready FC triggers are Financial Cents task completions that appear ready to load into the recognition trigger process.

How to review it:

- Treat this as a work queue indicator.
- A large pending revenue amount means the dashboard may be under-recognizing revenue until triggers are approved/applied.
- A nonzero ready trigger count means there is likely completed work waiting to be moved into recognition.

Current limitation:

- Pending revenue is not yet broken down by client, service type, or reason in the top tile.
- The tile does not yet let you click into the pending detail.

## Per-Client GP

This is the main review table for client profitability.

Each row is currently:

```text
Period + Client + Service Type
```

This means the same client can appear multiple times in the same month if the client has labor or revenue split across bookkeeping, tax, payroll, advisory, or other.

Columns:

- `Period`: month being reviewed.
- `Client`: Anchor client/business name.
- `Service`: macro service type, such as bookkeeping, tax, payroll, advisory, or other.
- `Owner`: primary owner for that client/service combination.
- `Revenue`: recognized revenue for that client/service/month.
- `Labor`: matched contractor labor cost for that client/service/month.
- `GP`: recognized revenue minus labor.
- `GP %`: GP divided by recognized revenue.

How to explain `Unassigned`:

`Unassigned` means the dashboard could not find a primary owner for that exact Anchor client and service type. It does not mean no one worked on the client. It means the owner map is missing or not matched for that service bucket.

How to explain `other`:

`other` means the labor or revenue could not be confidently classified into bookkeeping, tax, payroll, or advisory. It is a review bucket. Rows in `other` should usually be cleaned up, reclassified, or intentionally marked as overhead/pass-through if appropriate.

How to review client rows:

- Start with negative GP rows at the top.
- For each negative row, ask:
  - Is revenue missing because recognition has not happened yet?
  - Is labor in the wrong service bucket?
  - Is owner assignment missing?
  - Is this real over-servicing?
  - Is this an internal/admin item incorrectly matched to a client?
- Do not judge performance from `GP % = n/a`. That usually means recognized revenue is zero, so the percentage cannot be calculated.

Example interpretation:

If `Collectiv Inc. / Apr 2026 / other` shows negative GP and owner `Unassigned`, that currently means labor was matched to Collectiv and classified as `other`, but no recognized revenue and no service-owner assignment exists for the `other` bucket. That is a cleanup/review signal before it is a profitability conclusion.

Current limitations:

- The table is not yet grouped by client-month with expandable service lines.
- It does not yet show review badges like `Missing owner`, `No recognized revenue`, `Other labor`, or `Needs classification`.
- It only shows the first visible slice of client GP rows, not a full paginated/searchable table.
- There is no drill-down yet to the underlying TimeEntries or RevenueEvents.
- It does not yet show whether a row is final, preliminary, or blocked by missing inputs.

## Per-Staff GP

This table rolls client/service profitability up to the primary owner.

Current logic:

```text
Staff GP = sum of GP for client/service rows where that staff member is primary owner
```

Columns:

- `Staff`: primary owner staff member.
- `Revenue`: recognized revenue on owned client/service rows.
- `Labor`: matched labor on owned client/service rows.
- `GP %`: owned GP divided by owned recognized revenue.
- `Clients`: count of owned client/service rows.

How to review it:

- Use this after reviewing client rows.
- If a staff member looks unusually good or bad, inspect the client/service rows feeding them.
- If many client rows are `Unassigned`, this table will understate staff ownership.
- If revenue recognition is incomplete, this table can mislead.

Current limitation:

- Multi-staff work is still attributed to the primary owner, per the current decision.
- Secondary staff contribution is not shown.
- The table does not yet show admin load by staff.
- The table does not yet show trend over time.

## Comp Ledger

This table shows potential and actual kicker accruals.

Columns:

- `Period`: month of the kicker calculation.
- `Staff`: staff member.
- `Gross`: kicker amount before company gate.
- `Accrual`: actual accrued kicker after gate logic.

How to review it:

- Compare `Gross` to `Accrual`.
- If `Gross` is positive and `Accrual` is zero, the company gate likely failed for the relevant gate period.
- Use this as an accrual review, not as a final payroll/payment approval yet.

Current limitation:

- The UI does not yet show the full formula per row.
- The UI does not yet show prior-quarter gate details beside each staff row.
- There is no approval/payment status workflow yet.
- This should not be used as final payout authorization until the client GP and owner assignments have been reviewed.

## W2 Watch

This table shows contractor-to-W2 conversion signals.

Current default logic:

- cost trigger: annualized contractor cost above the threshold,
- consistency trigger: sustained high weekly hours with low month-to-month variance,
- both triggers: convert flag,
- one trigger: watch flag.

Columns:

- `Staff`: contractor.
- `Status`: watch or convert.
- `Annualized`: estimated annualized contractor cost.
- `Avg Hrs/Wk`: average weekly hours in the review window.

How to review it:

- Use this as a staffing planning alert.
- A `watch` flag means the person may be trending toward employee-like economics or workload.
- Confirm with business context before making any decision.

Current limitation:

- This is directional, not legal advice.
- It does not yet include qualitative factors like control, exclusivity, tools, schedule, or IRS/state classification tests.
- It does not yet show the full trailing eight-month history in the UI.

## FC Trigger Queue

This block shows Financial Cents completed tasks that may drive revenue recognition.

Each item currently shows:

- client name,
- FC task title,
- approval status,
- trigger load status.

How to review it:

- Look for tax filing or completion tasks that are pending approval.
- Confirm whether the task represents a true recognition trigger.
- Confirm whether the client is matched to Anchor.
- Confirm whether the service type is correct.

Common statuses:

- `pending / pending_approval`: task needs review before it can drive recognition.
- `approved / ready_to_load`: task is approved and should be loadable into recognition triggers.
- `needs_client_match`: task cannot load because FC client is not matched to Anchor.
- `needs_trigger_type`: task is approved but the system does not know what recognition trigger type it should be.

Current limitation:

- The portal does not yet let you approve, reject, or override triggers.
- It only shows a short list, not a full queue with filters.
- It does not yet show why a row is blocked in a structured way.

## What Feedback Is Most Useful Right Now

For portal usefulness, please give feedback in this format:

```text
Block:
Client/staff/month:
What looks wrong or confusing:
What you expected:
What decision you were trying to make:
```

Examples:

```text
Block: Per-Client GP
Client/staff/month: Collectiv Inc. / Apr 2026
What looks wrong or confusing: same client appears three times; one row says other/unassigned
What I expected: one client row with expandable service detail
Decision: whether Collectiv is actually unprofitable or just misclassified
```

```text
Block: Comp Ledger
Client/staff/month: Beth / Apr 2026
What looks wrong or confusing: gross kicker exists but accrual is zero
What I expected: explanation of gate failure
Decision: whether to accrue a payout
```

## Known Surface Work Still Incomplete

These are the main items still being worked on or not yet built:

- Client-month grouping with expandable service lines.
- Review badges for missing owner, missing revenue, `other` labor, and blocked recognition.
- Drill-down from client GP rows to TimeEntries.
- Drill-down from client GP rows to RevenueEvents.
- Filters by month, client, service type, owner, and issue type.
- Full FC trigger approval workflow from the portal.
- Prepaid liability audit log surface.
- Admin load % detail by staff and by period.
- Staff-facing portal.
- Authentication via the existing app/Supabase auth model. Current protection is temporary Nginx basic auth.
- Clear “data freshness” indicators for Anchor, Financial Cents, time entry loads, and recognition runs.
- Final payout approval/payment workflow for comp.

## Practical Review Rule

For now, treat the portal as a review cockpit, not a final scorecard.

The most valuable current use is to find data-quality and process issues:

- missing owner mappings,
- service misclassification,
- completed work not yet recognized,
- labor loaded before revenue recognition,
- clients that may truly be over-serviced,
- contractor workload patterns that should be watched.

Once those review loops are clear, the same portal can become the monthly management dashboard.
