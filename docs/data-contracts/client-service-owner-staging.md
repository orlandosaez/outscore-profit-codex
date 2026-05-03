# Client Service Owner Staging Contract

`profit_import.assignments` converts `docs/data-references/client-staff-assignments.xlsx` into one row per client service owner assignment for Workstream B profit sharing.

## Output Columns

- `client_raw` — client name exactly cleaned from the workbook.
- `service_token` — original workbook service marker, such as `S 1120P`.
- `service_code` — normalized code without the `S` prefix, such as `1120P`.
- `macro_service_type` — one of `bookkeeping`, `tax`, `payroll`, `advisory`, or `other`.
- `service_tier` — `essential`, `plus`, `advanced`, or blank when the code is not tiered.
- `primary_staff` — staff owner for GP attribution.
- `reviewer_staff` — reviewer from the workbook, retained for QA and future workflow surfacing.
- `context_tokens` — non-service tokens from `Group& Service`; these are group/alias hints, not services.
- `source_file`, `source_sheet`, `source_row` — lineage back to the workbook row.

## Current Mapping Defaults

- `BOOK*` and `YECLOSE` map to `bookkeeping`.
- `1040*`, `1065*`, `1099*`, `1120*`, `990*`, and `TPP` map to `tax`.
- `PAYROLL` and `941` map to `payroll`.
- `SETUP` maps to `advisory`.
- Tier suffixes are mapped only for known tiered families: `E = essential`, `P = plus`, `A = advanced`.

This is a staging artifact. It still needs Anchor relationship IDs before loading into `profit_client_service_owners`.
