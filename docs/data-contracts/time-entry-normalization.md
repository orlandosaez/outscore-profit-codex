# Time Entry Normalization Contract

The parser in `profit_import.timesheets` converts uploaded staff workbook formats into one row per staff time entry.

## Output Columns

- `staff_name` — canonical staff first name matching `STAFF_RATES`.
- `entry_date` — work date as `YYYY-MM-DD`.
- `client_raw` — client/admin label exactly cleaned from the workbook.
- `task_raw` — task or service note cleaned from the workbook.
- `hours` — decimal hours, rounded to two decimals.
- `hourly_rate` — contractor rate used for labor cost.
- `labor_cost` — `hours * hourly_rate`, rounded to two decimals.
- `service_type` — inferred directional type: `bookkeeping`, `tax`, `payroll`, `advisory`, `admin`, or `other`.
- `is_admin` — true for pure admin/company overhead rows.
- `source_file`, `source_sheet`, `source_row` — lineage back to the workbook cell row.
- `paid_marker` — Wama payment marker when present.

## Current Parser Rules

- Laura files use long format: `CLIENT`, `STAFF`, `HRS`, `DATE`.
- Wama uses `Time Log Sheet` only; rows marked `UPWORK`/`UPWORK?` are excluded, and only dates after `2025-09-15` are valid for analysis.
- Beth files use sparse rows with dates forward-filled. Known Dec/Jan year typos are normalized to December 2025 and January 2026.
- Julie files use wide daily columns and are unpivoted into one row per positive daily client hour.
- Excel lock files beginning with `~$` are ignored.

These rows are directional Workstream B inputs. They are not accounting recognition records.
