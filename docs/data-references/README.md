# Data References

Purpose: canonical home for reference artifacts that seed config tables or serve as benchmarks for the profit system.

## `anchor services.csv`

Anchor service catalog with FC tag mapping. This file is the source for the V0.5.2 service recognition rules seed and the V0.5.2.1 `fc_tag` column on `profit_service_recognition_rules`. It should be replaced by Anchor service API sync in V0.6+; after that, this CSV becomes a historical snapshot.

## `client-staff-assignments.xlsx`

Per-client staff ownership matrix. This file maps clients/services to responsible staff owners and is consumed by the V0.6.A SLA dashboard planning path.

## `qbo-product-services.csv`

QBO product/service hierarchy export. This file is the source for the V0.5.2.1 `qbo_category_path` and `qbo_product_name` seed columns on `profit_service_recognition_rules`. It should be replaced by QBO product API sync in V0.6+; after that, this CSV becomes a historical snapshot.

## `sbc-profit-and-loss.csv`

Reference P&L for company-level GP validation. This is a benchmark for V0.6 audit/reconciliation work and is not a recurring seed source.

## Naming Convention

Use kebab-case filenames, no dates, and no spaces for reference artifacts. anchor services.csv is the historical exception and may be cleaned up later.

## Updating the seed when reference data changes

When `anchor services.csv` or `qbo-product-services.csv` changes, regenerate the derived SQL seed with `python3 scripts/generate_service_crosswalk_seed.py`, review the diff, commit the regenerated migration, and re-apply `supabase/sql/018_profit_service_recognition_rules_crosswalk.sql` to Supabase. Do not regenerate during deploy unless the reference CSVs changed; the committed SQL migration is the deploy artifact.

## Forward Direction

V0.6+ will replace Anchor and QBO files with live API syncs. Once those syncs land, update this README so the CSVs are clearly marked as historical snapshots rather than active seed sources.
