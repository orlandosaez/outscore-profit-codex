# Time Entry Anchor Matching

Purpose: map normalized contractor timesheet rows to Anchor relationships before any GP calculation uses labor.

## Inputs

- `timesheets/*.xlsx`
- `Client-staff assignments.xlsx`
- live/exported Anchor agreements CSV

## Matching Rules

- Admin rows stay as `match_status=admin` and have no `anchor_relationship_id`.
- Client rows first use deterministic aliases from the owner workbook:
  - matched owner workbook client name
  - matched Anchor business name
  - unique context tokens from the owner workbook
- If no alias exists, client rows match directly on normalized Anchor business name.
- Unique agreement abbreviations are allowed only when unambiguous, such as `YV-SR` -> `YV Enterprises SR LLC`.
- Ambiguous or missing names stay unmatched for review.

## Outputs

Generated locally:

- `build/time_entry_anchor_matches_review.csv`
- `build/time_entry_anchor_matches_summary.json`
- `build/time_entry_anchor_matches_load.json`

Production/backfill load:

- `supabase/sql/002_profit_time_entries.sql` creates `profit_time_entries`
- `Profit - 12 Load Time Entries From File` reads `/tmp/time_entry_anchor_matches_load.json` in the n8n container
- n8n upserts rows through Supabase REST using `time_entry_key` as the idempotency key

Current live run:

- time entries: 586
- matched client entries: 363
- admin entries: 57
- unmatched entries: 166
- matched labor cost: 10,988.74
- admin labor cost: 2,043.79
- unmatched labor cost: 7,743.90

## Interpretation

Matched client labor can be used for directional Workstream B GP once loaded.

Unmatched labor should not be silently allocated. The largest current unmatched groups include inactive/non-Anchor clients, QBO-direct clients, and names needing explicit aliases, for example `1415 Cortez`, `6712 Manatee`, `E & O Automotive`, `JGC`, and `Sales Tax`.
