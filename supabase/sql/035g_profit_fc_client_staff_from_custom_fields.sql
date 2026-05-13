-- Migration 035g: FC custom_fields → canonical staff assignment view (V0.7.D-1.1)
--
-- Purpose: as of 2026-05-12, FC custom fields are the authoritative source
-- for "who works on client X." The 4 fields (Tax Preparer, Tax Reviewer,
-- Book Primary, Book Reviewer) were bulk-populated via FC Open API on
-- 2026-05-12. W17 nightly sync pulls FC raw payload into profit_fc_clients.
--
-- This view extracts the 4 values per client by walking
-- raw->'custom_fields'. Joining on field NAME (not ID) so it survives FC
-- field-ID changes in the unlikely event of a future delete/recreate.
--
-- Output: one row per fc_client_id (active and archived); fields are NULL
-- when not populated on that client. Empty-string values in FC are
-- normalized to NULL for cleaner downstream coalesce.
--
-- Consumers (post V0.7.D-1.1):
--   - profit_sla_breached_candidates (migration 035h) — primary join surface
--   - future workload routing, billing reconciliation, timesheet attribution
--
-- Architectural rule (Orlando 2026-05-12): all staff-assignment reads MUST
-- hit FC custom_fields first. profit_client_staff_assignments table
-- (migration 035e) is now a transitional cache, queued for deprecation.
--
-- No content-specific rules. View is fully data-driven from FC payload.
--
-- Depends on: profit_fc_clients.raw populated by W17 sync (within W26 step 4).
-- If raw->'custom_fields' is null or empty, all 4 columns return NULL.
-- Predeploy_smoke.sh gate must pass before live apply.

create or replace view profit_fc_client_staff_from_custom_fields as
with cf_rows as (
  -- Unnest raw->'custom_fields' into (fc_client_id, field_name, value) triples.
  select
    c.fc_client_id,
    c.name as fc_client_name,
    cf->'field'->>'name' as field_name,
    nullif(trim(both from coalesce(cf->>'value', '')), '') as value,
    cf->>'updated_at' as cf_updated_at
  from profit_fc_clients c
  cross join lateral jsonb_array_elements(coalesce(c.raw->'custom_fields', '[]'::jsonb)) cf
  where c.raw is not null
)
select
  c.fc_client_id,
  c.name as fc_client_name,
  c.is_archived,
  max(case when r.field_name = 'Tax Preparer'  then r.value end) as tax_preparer,
  max(case when r.field_name = 'Tax Reviewer'  then r.value end) as tax_reviewer,
  max(case when r.field_name = 'Book Primary'  then r.value end) as book_primary,
  max(case when r.field_name = 'Book Reviewer' then r.value end) as book_reviewer,
  -- Most-recent custom-field update across all 4 fields for staleness diagnostics
  max(case
    when r.field_name in ('Tax Preparer','Tax Reviewer','Book Primary','Book Reviewer')
    then r.cf_updated_at::timestamptz
  end) as last_assignment_updated_at,
  c.last_seen_at as fc_client_last_synced_at
from profit_fc_clients c
left join cf_rows r on r.fc_client_id = c.fc_client_id
group by c.fc_client_id, c.name, c.is_archived, c.last_seen_at;

comment on view profit_fc_client_staff_from_custom_fields is
  'V0.7.D-1.1 (035g): canonical staff assignment per FC client, extracted from raw->custom_fields. Source of truth as of 2026-05-12. Reads field VALUES by NAME (Tax Preparer / Tax Reviewer / Book Primary / Book Reviewer) so it survives FC field-ID changes. Empty-string FC values normalized to NULL. Consumers: profit_sla_breached_candidates, future workload/billing/timesheet features.';

comment on column profit_fc_client_staff_from_custom_fields.last_assignment_updated_at is
  'Most-recent FC-side update timestamp across the 4 staff fields. Use for staleness diagnostics — when this lags far behind fc_client_last_synced_at, the W17 sync has fresh data but no recent staff changes on this client.';

comment on column profit_fc_client_staff_from_custom_fields.fc_client_last_synced_at is
  'When W17 sync last pulled this client. If W17 last_seen_at lags by >24h after a known mid-day operator FC edit, run /api/profit/admin/audit/pipeline-runs manually to force a same-day refresh.';
