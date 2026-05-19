-- Migration 049b: payroll compliance audit must scope to Payroll Tax Compliance only
--
-- Operator catch 2026-05-19: my 049 audit view flagged 8 clients as
-- "missing from sheet" but 7 were false positives. The bug:
-- profit_payroll_compliance_sheet_audit checked
--   canonical_service_name in ('Payroll Tax Compliance', 'Payroll Service')
-- but those are two distinct services:
--
--   Payroll Service          ($135-185/mo, auto/monthly)
--                             = recurring payroll RUNNING (paystubs,
--                               withholding mgmt, employee management)
--                             = different recognition pipeline; not
--                               what Beth's sheet tracks
--
--   Payroll Tax Compliance   ($41.67-$85/period, auto or manual)
--                             = quarterly tax-form FILINGS (941, 940,
--                               State Unemployment, W2, 1099)
--                             = THE service Beth's sheet tracks
--
-- Fix: drop 'Payroll Service' from the audit scope. Only check
-- 'Payroll Tax Compliance' against the sheet. Result: false positives
-- collapse from 8 → 1 (only Anderson Kool Air actually has Payroll Tax
-- Compliance and is not on the sheet).

create or replace view profit_payroll_compliance_sheet_audit as
with sheet_rows as (
  select * from profit_payroll_compliance_cycle_status
),
clients_in_anchor_with_compliance as (
  select distinct
    m.fc_client_id,
    fc.name as fc_client_name,
    asa.anchor_relationship_id,
    asa.agreement_client_business_name
  from profit_anchor_services_attributed asa
  join profit_anchor_agreements ag on ag.anchor_relationship_id = asa.anchor_relationship_id
   and ag.display_status = 'active'
  join profit_fc_client_anchor_matches m on m.anchor_relationship_id = asa.anchor_relationship_id
  join profit_fc_clients fc on fc.fc_client_id = m.fc_client_id
   and fc.is_archived = false
  -- 049b: scope strictly to Payroll Tax Compliance (the $85/quarter
  -- filing service Beth tracks). 'Payroll Service' is a different
  -- product (monthly running payroll) and is OUT of scope for the sheet.
  where asa.canonical_service_name = 'Payroll Tax Compliance'
    and coalesce(asa.service_status, '') <> 'completed'
)
-- Issue 1: sheet client → no Anchor match (unchanged from 049)
select
  'sheet_client_no_anchor_match'::text as issue_type,
  sr.cycle_period,
  sr.client_name_in_sheet,
  sr.status,
  null::bigint as fc_client_id,
  null::text as fc_client_name,
  null::text as anchor_relationship_id
from sheet_rows sr
where sr.fc_client_id is null
  and sr.client_name_in_sheet not in (
    'SBC Accounting and Tax LLC (Outscore)',
    'DBH Air Corporation'
  )

union all
-- Issue 2: Anchor client with Payroll Tax Compliance not on sheet
select
  'anchor_client_missing_from_sheet'::text,
  to_char(now(), 'YYYY') || '-Q' || ceil(extract(month from current_date) / 3.0)::int as cycle_period,
  a.fc_client_name as client_name_in_sheet,
  null::text as status,
  a.fc_client_id,
  a.fc_client_name,
  a.anchor_relationship_id
from clients_in_anchor_with_compliance a
where not exists (
  select 1 from sheet_rows sr
  where sr.fc_client_id = a.fc_client_id
);

comment on view profit_payroll_compliance_sheet_audit is
  'V0.7.H (049/049b): cross-source audit between Beth''s Payroll Tax
   Compliance Google Sheet and Anchor active agreements. Scoped strictly
   to the canonical service ''Payroll Tax Compliance'' (quarterly filing
   $85/qtr — what the sheet tracks). Excludes ''Payroll Service'' (monthly
   recurring payroll running — different product). Surfaces (1) sheet
   rows whose client name does not resolve to an FC client, and
   (2) Anchor agreements with Payroll Tax Compliance service not
   represented in the sheet.';

do $$
declare v_count integer; v_anderson integer;
begin
  select count(*) into v_count
    from profit_payroll_compliance_sheet_audit
   where issue_type = 'anchor_client_missing_from_sheet';
  select count(*) into v_anderson
    from profit_payroll_compliance_sheet_audit
   where issue_type = 'anchor_client_missing_from_sheet'
     and client_name_in_sheet = 'Anderson Kool Air LLC';
  raise notice '049b verify: % anchor-missing rows (expected 1, Anderson Kool Air). Anderson present = %', v_count, v_anderson;
end $$;
