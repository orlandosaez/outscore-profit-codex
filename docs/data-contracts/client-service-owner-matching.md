# Client Service Owner Matching Contract

`scripts/match_client_assignments.py` links service-owner assignments from `Client-staff assignments.xlsx` to Anchor relationship IDs.

## Inputs

- Client owner workbook: `Client-staff assignments.xlsx`
- Anchor agreement list: either `anchor_agreements_export_1777160122406.csv` or a live Supabase export from `Profit - 08 Supabase Anchor Agreements Export`

## Match Rule

The matcher only accepts deterministic normalized business-name matches:

- removes parentheticals, such as `(TempleTerrace)`
- removes punctuation and spacing differences
- removes common entity suffixes, such as `LLC`, `Inc`, `Corporation`, `PA`
- treats `&`/`and` as non-essential

It does not fuzzy-match near names. Rows that do not match exactly after normalization stay in the review file.

## Outputs

- `build/client_service_owner_matches_review.csv` — every service assignment with `matched`, `unmatched`, or `ambiguous` status.
- `build/client_service_owner_load_staging.csv` — matched rows collapsed to one row per `anchor_relationship_id + macro_service_type + primary_staff`.
- `build/client_service_owner_load.sql` — SQL load file for Supabase.
- `build/client_service_owner_matches_summary.json` — counts by status and service type.

## Load SQL

The generated SQL:

- creates a temporary incoming table
- fails if any `primary_staff` name is missing from `profit_staff`
- creates a unique index on `(anchor_relationship_id, macro_service_type, effective_from)` if missing
- upserts rows into `profit_client_service_owners`

Review the unmatched rows before treating owner coverage as complete.
