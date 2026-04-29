# Outscore Profit Automation Workspace

This repository contains the Phase 0/1 working files for the Outscore profit dashboard and automation project.

Current contents:

- `n8n/workflows/` — importable n8n workflow JSON files for Anchor and Supabase setup.
- `profit_import/` — Python import/parsing helpers for Phase 0 data audit and backfill.
- `scripts/parse_timesheets.py` — normalizes uploaded staff timesheets into a TimeEntry CSV.
- `scripts/parse_client_assignments.py` — normalizes client/staff owner mappings into a service-owner staging CSV.
- `scripts/match_client_assignments.py` — matches owner mappings to Anchor relationships and generates review/load files.
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
```

The parser writes ignored local outputs to `build/normalized_time_entries.csv` and `build/normalized_time_entries_summary.json`.
The owner parser writes ignored local outputs to `build/client_service_owners_staging.csv` and `build/client_service_owners_staging_summary.json`.
The owner matcher writes ignored local outputs to `build/client_service_owner_matches_review.csv`, `build/client_service_owner_load_staging.csv`, `build/client_service_owner_load.sql`, and `build/client_service_owner_matches_summary.json`.
