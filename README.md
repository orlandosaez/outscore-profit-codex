# Outscore Profit Automation Workspace

This repository contains the Phase 0/1 working files for the Outscore profit dashboard and automation project.

Current contents:

- `n8n/workflows/` — importable n8n workflow JSON files for Anchor and Supabase setup.
- `profit_import/` — Python import/parsing helpers for Phase 0 data audit and backfill.
- `scripts/parse_timesheets.py` — normalizes uploaded staff timesheets into a TimeEntry CSV.
- `scripts/parse_client_assignments.py` — normalizes client/staff owner mappings into a service-owner staging CSV.
- `scripts/match_client_assignments.py` — matches owner mappings to Anchor relationships and generates review/load files.
- `scripts/match_time_entries.py` — matches normalized contractor time entries to Anchor relationships for labor allocation review.
- `scripts/classify_anchor_revenue_lines.py` — classifies synced Anchor invoice line items into macro service buckets and generates review/load files.
- `supabase/sql/` — one-time Supabase schema migrations; dynamic row loads happen through n8n/Supabase REST.
- `supabase/sql/003_profit_gp_invoice_basis_views.sql` — first directional GP rollup views; invoice-basis, not recognition-basis.
- `supabase/sql/004_profit_revenue_events.sql` — recognition candidate ledger and recognition-basis GP views.
- `supabase/sql/005_profit_recognition_triggers.sql` — completion trigger ledger and ready-for-recognition view.
- `supabase/sql/006_profit_financial_cents_sync.sql` — Financial Cents raw sync tables and completed-task review view.
- `supabase/sql/007_profit_fc_trigger_loader.sql` — FC task approval, candidate, and approved-trigger loader views.
- `supabase/sql/008_profit_comp_w2.sql` — comp plan config, staff kicker accruals, and W2 conversion flag views.
- `supabase/sql/009_profit_admin_dashboard_views.sql` — stable admin dashboard read views over recognition, comp, W2, and FC trigger data.
- Root CSV/XLSX files — current source exports used for data audit and initial mapping.
- `timesheets/` — uploaded staff timesheet samples for parser design and historical ingestion.

The n8n workflows are imported into the production n8n instance manually/over SSH and should be reviewed before activation.

## Local Verification

Use the bundled Codex Python runtime for now:

```bash
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s tests -v
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/parse_timesheets.py
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/parse_client_assignments.py
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/match_client_assignments.py
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/match_time_entries.py
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/classify_anchor_revenue_lines.py
```

The parser writes ignored local outputs to `build/normalized_time_entries.csv` and `build/normalized_time_entries_summary.json`.
The owner parser writes ignored local outputs to `build/client_service_owners_staging.csv` and `build/client_service_owners_staging_summary.json`.
The owner matcher writes ignored local outputs to `build/client_service_owner_matches_review.csv`, `build/client_service_owner_load_staging.csv`, `build/client_service_owner_load.sql`, and `build/client_service_owner_matches_summary.json`.
The time-entry matcher writes ignored local outputs to `build/time_entry_anchor_matches_review.csv` and `build/time_entry_anchor_matches_summary.json`.
It also writes `build/time_entry_anchor_matches_load.json` for n8n/Supabase REST backfill loading.
The revenue classifier writes ignored local outputs to `build/anchor_line_item_classifications_review.csv` and `build/anchor_line_item_classifications_load.sql`.
Revenue event candidates are loaded dynamically through n8n workflow `Profit - 15 Load Revenue Event Candidates`; do not hand-load rows into Supabase for the live process.
Recognition triggers should be loaded into `profit_recognition_triggers`; n8n workflow `Profit - 16 Apply Recognition Triggers` applies only rows exposed by the ready view.
Financial Cents raw sync starts with n8n workflow `Profit - 17 Financial Cents Sync`; it needs a `Financial Cents API - Production` HTTP Header Auth credential before it can run.
Approved FC task completions are loaded into `profit_recognition_triggers` through n8n workflow `Profit - 19 Load FC Completion Triggers`; run `supabase/sql/007_profit_fc_trigger_loader.sql` first.
Use `Profit - 20 FC Completion Trigger Inspect` to review FC trigger candidates and `Profit - 21 Approve Matched FC Tax Filed Triggers` for the conservative matched-tax-filed starter approval path.
Comp/W2 reporting starts with `supabase/sql/008_profit_comp_w2.sql` and inspect workflow `Profit - 22 Comp W2 Inspect`.
Admin dashboard read surfaces start with `supabase/sql/009_profit_admin_dashboard_views.sql` and inspect workflow `Profit - 23 Admin Dashboard Inspect`.
