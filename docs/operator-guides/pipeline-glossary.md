# Pipeline Glossary

This guide translates the pipeline run log into operator language. The UI still exposes some system names because the run log is also an audit trail, but operators should use the plain-English descriptions below when triaging a run.

## Pipeline Steps

| Step key | Plain English |
| --- | --- |
| Step 1: `anchor_agreement_sync` | Pulls the latest list of Anchor agreements, active and terminated, into the database. Source: Anchor `/agreements` API. |
| Step 2: `anchor_invoice_revenue_sync` | Pulls Anchor invoices, classifies their line items by service category, and creates revenue event candidates ready for recognition. Composed of three sub-workflows. |
| Step 3: `qbo_collection_loader` | Pulls QuickBooks Online cash payments and links them to the Anchor invoices they paid. |
| Step 4: `fc_completion_sync` | Pulls Financial Cents tasks and approves recognition triggers for completed tax-filing and bookkeeping work. Composed of four sub-workflows. |
| Step 5: `recognition_trigger_apply` | Applies approved recognition triggers, marking revenue events as recognized in the appropriate accounting period. |
| Step 6: `fc_anchor_match_refresh` | Re-evaluates which FC clients map to which Anchor agreements, then cleans up any stale matches. |
| Step 7: `fulfillment_audit_refresh` | Re-runs the inactive-client re-emergence scan to detect previously-classified-inactive clients who returned. |
| Step 8: `classification_transition_apply` | Auto-applies eligible classification transitions, such as PENDING to MIXED, when their signal conditions are met. |

## Sub-workflow Code Reference

| Code | Workflow name | Friendly name |
| --- | --- | --- |
| W05 | Profit - 05 Anchor Agreements Sync | Anchor Agreement Sync |
| W07 | Profit - 07 Anchor Invoices Sync | Anchor Invoice Sync |
| W11 | Profit - 11 Classify Anchor Invoice Line Items | Classify Anchor Line Items |
| W15 | Profit - 15 Load Revenue Event Candidates | Load Revenue Events |
| W16 | Profit - 16 Apply Recognition Triggers | Apply Recognition Triggers |
| W17 | Profit - 17 Financial Cents Sync | FC Sync |
| W19 | Profit - 19 Load FC Completion Triggers | Load Completion Triggers |
| W21 | Profit - 21 Approve Matched FC Tax Filed Triggers | Approve Tax Triggers |
| W22 | Profit - 22 Approve Matched FC Bookkeeping Complete Triggers | Approve Bookkeeping Triggers |
| W24 | Profit - 24 QBO Collection Loader | QBO Collection Loader |
| W25 | Profit - 25 Auto-Match FC Clients To Anchor | FC Client Match |
| W26 | Profit - 26 Pipeline Orchestration | Pipeline Orchestration |

## Status Meanings

| Status | Meaning | Operator implication |
| --- | --- | --- |
| `running` | The pipeline is currently executing. | Wait for it to finish. The refresh button will conflict while a run is active. |
| `success` | All operations in this step completed without error. | No immediate pipeline action needed. Review diagnostics only if counts look unusual. |
| `failed` | A required operation in this step encountered an error. For hard steps 1-6, this halts the run. For soft steps 7-8, the run continues. | Open the run detail, find the failed step, and follow the common-error guidance below. |
| `partial` | The run completed but at least one soft step, 7 or 8, failed. Hard steps 1-6 all succeeded. | Core data refresh likely completed. Review the failed soft step before relying on diagnostic counts. |
| `skipped` | Reserved; not currently emitted. | Confirm the skip reason in details if this ever appears. |

## Common Errors

| Error text | Likely cause | Triage |
| --- | --- | --- |
| `The service was not able to process your request` in Step 5 / W16 | Known data defect. W16 fails when the upsert batch contains duplicate `revenue_event_key` values. | No operator action required; safe to ignore until the W16 fix lands. Pipeline runs finalize as `failed` at step 5 until W16 is fixed. |
| `Pipeline already running` | Another run is in progress. | Wait for it to complete before retrying. |
| Webhook `404` immediately after n8n restart | n8n's webhook registration takes a moment after restart. | Retry after 10-30 seconds. If it persists, verify Workflow 26 is active. |
| Anchor, Financial Cents, or QuickBooks request failure | Upstream API or credential issue. | Check n8n execution details and upstream service availability before retrying. |

## Field Glossary

| Field | Meaning |
| --- | --- |
| `triggered_by` | Operator identifier typed into the manual refresh dialog. Defaults to `orlando`. |
| `run_source` | `manual` when an operator clicked refresh, or `cron` for scheduled runs. |
| `rows_affected` | Count reported by a pipeline step or sub-workflow. It can mean inserted, updated, loaded, or scanned rows depending on the step. |
| `details.sub_workflows` | Array showing each sub-workflow's individual status, rows, and any error. |
| `summary` | Run-level totals and notes written when the run finalizes. |
| `total_steps_completed` | Number of pipeline steps that finished successfully. |
| `total_steps_failed` | Number of pipeline steps that failed. |
| `total_rows_affected` | Sum of step-level row counts reported by Workflow 26. |
| `error_summary` | Plain-text summary of why the run failed or partialled. |
| `notable_findings` | Human-readable run notes worth surfacing to operators. |
| `last_step_status` | Internal control-flow signal used by W26 routing; not operator-facing. |

## What To Do When A Run Fails

1. Open `/profit/admin/pipeline` and choose the latest failed run.
2. Find the first failed step in the step table.
3. Read the friendly summary first; expand details only when you need raw error text.
4. If the failure is the known W16 duplicate-key error, do not retry immediately. Wait for the engineering fix.
5. If the failure is an upstream API or credential issue, verify the upstream service and n8n credentials before retrying.
6. If a run remains `running` for more than 30 minutes, escalate for SQL cleanup; stuck-run automation is deferred to V0.6.C.c.
