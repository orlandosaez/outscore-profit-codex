-- Migration 037: Extend client-staff view with engagement_type (V0.7.E.2)
--
-- Adds engagement_type to profit_fc_client_staff_from_custom_fields (035g).
-- Walks raw->custom_fields for the new FC field "Engagement Type" (id 111626,
-- created 2026-05-13 via FC Open API).
--
-- Bulk populated 2026-05-13: 38 clients (2 Subscription / 19 Mixed / 17 Project)
-- via /tmp/fc_bulk_engagement.py. Heuristic-derived from
-- profit_anchor_agreements.raw->'profitSyncServiceSummary'[*].trigger:
--   - Subscription = all services trigger != 'manual' (auto-billed recurring)
--   - Project      = all services trigger = 'manual' (manual per-deliverable)
--   - Mixed        = both trigger types in client's agreement set
--
-- ~72 personal 1040 clients without direct Anchor agreements left as NULL
-- (engagement_type unset). Their work is labeled FROM a parent business
-- agreement via V0.7.B.4 attribution; downstream views/features that need
-- to know engagement type for those clients should join through the
-- attribution to the parent business.
--
-- This is the foundation for:
--   - V0.7.D-3: Manual Invoice Pending semantic rewrite (filter to Project + Mixed)
--   - V0.7.E.1: Dashboard tile split (Deferred Revenue – Project / Subscription Service Reserve)
--   - V0.7.E.3: Subscription Service Reserve labor-cost forecast
--
-- See coordination memory tc_revenue_recognition_principle.md for full context.
-- Predeploy_smoke.sh gate must pass before live apply.

create or replace view profit_fc_client_staff_from_custom_fields as
with cf_rows as (
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
  -- Original column order preserved (V0.7.B.4 CREATE OR REPLACE VIEW constraint):
  c.fc_client_id,
  c.name as fc_client_name,
  c.is_archived,
  max(case when r.field_name = 'Tax Preparer'   then r.value end) as tax_preparer,
  max(case when r.field_name = 'Tax Reviewer'   then r.value end) as tax_reviewer,
  max(case when r.field_name = 'Book Primary'   then r.value end) as book_primary,
  max(case when r.field_name = 'Book Reviewer'  then r.value end) as book_reviewer,
  max(case
    when r.field_name in ('Tax Preparer','Tax Reviewer','Book Primary','Book Reviewer','Engagement Type')
    then r.cf_updated_at::timestamptz
  end) as last_assignment_updated_at,
  c.last_seen_at as fc_client_last_synced_at,
  -- V0.7.E.2 NEW column (appended; safe for CREATE OR REPLACE):
  max(case when r.field_name = 'Engagement Type' then r.value end) as engagement_type
from profit_fc_clients c
left join cf_rows r on r.fc_client_id = c.fc_client_id
group by c.fc_client_id, c.name, c.is_archived, c.last_seen_at;

comment on view profit_fc_client_staff_from_custom_fields is
  'V0.7.E.2 (037): adds engagement_type column to the FC custom-fields extraction view. Engagement Type is operator-managed in FC (Subscription/Project/Mixed) via the same pattern as the 4 staff fields. Authoritative source for downstream revenue-recognition features per the T&C-locked principle: subscription fees are earned-on-receipt, only project prepayments are GAAP Deferred Revenue.';

comment on column profit_fc_client_staff_from_custom_fields.engagement_type is
  'FC custom field "Engagement Type" (field id 111626). Allowed values: Subscription | Project | Mixed. NULL when not yet set (e.g., personal 1040 clients attributed from a parent business agreement — no direct engagement in their own name). Heuristic-bulk-populated 2026-05-13 from profit_anchor_agreements.raw->profitSyncServiceSummary[*].trigger.';
