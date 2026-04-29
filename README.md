# Outscore Profit Automation Workspace

This repository contains the Phase 0/1 working files for the Outscore profit dashboard and automation project.

Current contents:

- `n8n/workflows/` — importable n8n workflow JSON files for Anchor and Supabase setup.
- `profit_import/` — Python import/parsing helpers for Phase 0 data audit and backfill.
- `scripts/parse_timesheets.py` — normalizes uploaded staff timesheets into a TimeEntry CSV.
- Root CSV/XLSX files — current source exports used for data audit and initial mapping.
- `timesheets/` — uploaded staff timesheet samples for parser design and historical ingestion.

The n8n workflows are imported into the production n8n instance manually/over SSH and should be reviewed before activation.

## Local Verification

Use the bundled Codex Python runtime for now:

```bash
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest discover -s tests -v
/Users/orlandosaez/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/parse_timesheets.py
```

The parser writes ignored local outputs to `build/normalized_time_entries.csv` and `build/normalized_time_entries_summary.json`.
