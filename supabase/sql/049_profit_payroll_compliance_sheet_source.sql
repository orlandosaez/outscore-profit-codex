-- Migration 049: Payroll Compliance — Google Sheet as source of truth
--
-- Sprint H (2026-05-18). Replaces per-client FC project tracking for
-- payroll compliance with a single sheet-driven workflow:
--
--   Beth maintains a Google Sheet ("Payroll Tax, W2, 1099 Admin",
--   id 1RAbsAPsskrzYVnTpnH8GW_ihu7gyNv3lqzoyGMgZhY4) with one row per
--   payroll-compliance client + one column per quarter cycle (2026-Q1,
--   2026-Q2, etc.). When she marks a cell DONE, the recognition
--   pipeline picks it up and clears the matching pending payroll
--   revenue events for that quarter.
--
-- Architecture:
--   1. profit_payroll_compliance_cycle_status — raw mirror of sheet
--      rows. One row per (cycle_period, client_name_in_sheet).
--   2. profit_payroll_compliance_cycle_quarter_bounds — date helpers
--      mapping cycle_period strings ('2026-Q1') to month ranges.
--   3. Trigger function profit_payroll_compliance_fire_recognition
--      — fires when status flips to 'done' AND fc_client_id is
--      resolved. Walks pending payroll revenue events for the client
--      in the cycle's month range, inserts a
--      profit_recognition_triggers row per event with
--      trigger_type='payroll_compliance_completed'. W16 picks these
--      up on next run.
--   4. View profit_payroll_compliance_sheet_audit — exposes mismatch
--      diagnostics (sheet client → no Anchor match, etc.) so the
--      self-audit can pick them up.
--
-- Operator workflow goes from "create FC project per client per
-- quarter, close it" to "update one cell in the sheet."

create table if not exists profit_payroll_compliance_cycle_status (
  cycle_period             text       not null,
  client_name_in_sheet     text       not null,
  fc_client_id             bigint     references profit_fc_clients(fc_client_id),
  ein                      text,
  cycle_label              text,
  status                   text       not null
    check (status in ('pending', 'done', 'skipped', 'unknown')),
  source_sheet_id          text       not null default '1RAbsAPsskrzYVnTpnH8GW_ihu7gyNv3lqzoyGMgZhY4',
  sheet_row_data           jsonb,
  triggers_loaded          boolean    not null default false,
  triggers_loaded_count    integer    not null default 0,
  triggers_loaded_at       timestamptz,
  last_synced_at           timestamptz not null default now(),
  notes                    text,
  primary key (cycle_period, client_name_in_sheet)
);

create index if not exists idx_profit_payroll_compliance_fc_client
  on profit_payroll_compliance_cycle_status (fc_client_id);

create index if not exists idx_profit_payroll_compliance_status
  on profit_payroll_compliance_cycle_status (cycle_period, status);

comment on table profit_payroll_compliance_cycle_status is
  'V0.7.H (049): mirror of Beth''s payroll compliance Google Sheet.
   One row per (quarter, client). Status flipping to ''done'' triggers
   automatic recognition for the client''s pending payroll revenue
   events in that quarter via profit_payroll_compliance_fire_recognition.';

-- -------------------------------------------------------------
-- Helper: parse cycle_period like '2026-Q1' → (start_date, end_date)
-- -------------------------------------------------------------
create or replace function profit_payroll_compliance_cycle_bounds(p_cycle_period text)
returns table (cycle_start date, cycle_end date)
language plpgsql immutable as $$
declare
  v_year int;
  v_q    int;
  v_start_month int;
begin
  v_year := substring(p_cycle_period from 1 for 4)::int;
  v_q    := substring(p_cycle_period from 7 for 1)::int;
  v_start_month := ((v_q - 1) * 3) + 1;
  cycle_start := make_date(v_year, v_start_month, 1);
  cycle_end   := (make_date(v_year, v_start_month, 1) + interval '3 months - 1 day')::date;
  return next;
end;
$$;

comment on function profit_payroll_compliance_cycle_bounds(text) is
  'V0.7.H (049): parse cycle_period string (2026-Q1) into date bounds.
   Q1 = Jan-Mar, Q2 = Apr-Jun, Q3 = Jul-Sep, Q4 = Oct-Dec.';

-- -------------------------------------------------------------
-- Trigger function: on status flip to 'done', create recognition
-- triggers for all pending payroll revenue events in cycle range.
-- -------------------------------------------------------------
create or replace function profit_payroll_compliance_fire_recognition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bounds   record;
  v_event    record;
  v_loaded   integer := 0;
  v_trigger_key text;
begin
  -- Resolve fc_client_id by exact name match if not already set.
  -- Operator-side name reconciliation (sheet to match Anchor) handles
  -- the bulk of cases; archived clients excluded.
  if NEW.fc_client_id is null and NEW.client_name_in_sheet is not null then
    select fc.fc_client_id
      into NEW.fc_client_id
      from profit_fc_clients fc
     where lower(trim(fc.name)) = lower(trim(NEW.client_name_in_sheet))
       and fc.is_archived = false
     limit 1;
  end if;

  -- Only fire when transitioning to 'done' on a resolved client.
  -- Skip if no change in status (avoid double-firing on metadata updates).
  if NEW.status <> 'done' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status = 'done' then
    return NEW;
  end if;
  if NEW.fc_client_id is null then
    NEW.notes := coalesce(NEW.notes || E'\n', '')
              || 'No fc_client_id resolved from name "' || NEW.client_name_in_sheet || '". Recognition not fired.';
    return NEW;
  end if;

  select cycle_start, cycle_end
    into v_bounds
    from profit_payroll_compliance_cycle_bounds(NEW.cycle_period);

  -- Walk pending payroll revenue events for this client in cycle range
  for v_event in
    select
      e.revenue_event_key,
      e.anchor_relationship_id,
      e.candidate_period_month,
      e.source_amount
    from profit_revenue_events e
    join profit_fc_client_anchor_matches m
      on m.anchor_relationship_id = e.anchor_relationship_id
    where m.fc_client_id = NEW.fc_client_id
      and e.macro_service_type = 'payroll'
      and e.recognition_status like 'pending_%'
      and e.candidate_period_month between v_bounds.cycle_start and v_bounds.cycle_end
  loop
    v_trigger_key := 'payroll_compliance_' || NEW.cycle_period || '_' || v_event.revenue_event_key;
    insert into profit_recognition_triggers (
      recognition_trigger_key,
      source_system,
      source_record_id,
      anchor_relationship_id,
      macro_service_type,
      service_period_month,
      completion_date,
      trigger_type,
      recognition_action,
      notes,
      raw,
      loaded_at,
      approved_by,
      approved_at
    ) values (
      v_trigger_key,
      'payroll_compliance_sheet',
      v_event.revenue_event_key,
      v_event.anchor_relationship_id,
      'payroll',
      v_event.candidate_period_month,
      v_bounds.cycle_end,
      'payroll_compliance_completed',
      'recognize_full_source_amount',
      'Recognized by ''Payroll Tax, W2, 1099 Admin'' sheet for cycle ' || NEW.cycle_period
        || ' (operator: Beth McGuire). Sheet row marked DONE on '
        || to_char(now(), 'YYYY-MM-DD'),
      jsonb_build_object(
        'cycle_period', NEW.cycle_period,
        'client_name_in_sheet', NEW.client_name_in_sheet,
        'sheet_id', NEW.source_sheet_id,
        'ein', NEW.ein,
        'cycle_label', NEW.cycle_label
      ),
      now(),
      'sheet:Beth McGuire',
      now()
    )
    on conflict (source_system, source_record_id) do nothing;
    if FOUND then
      v_loaded := v_loaded + 1;
    end if;
  end loop;

  NEW.triggers_loaded := (v_loaded > 0);
  NEW.triggers_loaded_count := v_loaded;
  NEW.triggers_loaded_at := now();
  return NEW;
end;
$$;

drop trigger if exists profit_payroll_compliance_recognition_trigger
  on profit_payroll_compliance_cycle_status;
create trigger profit_payroll_compliance_recognition_trigger
  before insert or update on profit_payroll_compliance_cycle_status
  for each row execute function profit_payroll_compliance_fire_recognition();

comment on function profit_payroll_compliance_fire_recognition() is
  'V0.7.H (049): BEFORE INSERT/UPDATE trigger on
   profit_payroll_compliance_cycle_status. Auto-resolves fc_client_id
   by exact name match if NULL; on status=''done'' transitions, walks
   pending payroll revenue events for the client within the cycle
   period and creates profit_recognition_triggers rows. W16 picks
   them up on next pipeline run.';

-- -------------------------------------------------------------
-- Audit view: surface mismatches for the self-audit system
-- -------------------------------------------------------------
create or replace view profit_payroll_compliance_sheet_audit as
with sheet_rows as (
  select * from profit_payroll_compliance_cycle_status
),
clients_in_anchor_with_payroll as (
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
  where asa.canonical_service_name in ('Payroll Tax Compliance', 'Payroll Service')
    and coalesce(asa.service_status, '') <> 'completed'
)
-- Issue 1: sheet client → no Anchor match
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
    'DBH Air Corporation'  -- known internal/inactive, ignore
  )

union all
-- Issue 2: Anchor client has Payroll Compliance service → not in sheet
select
  'anchor_client_missing_from_sheet'::text,
  to_char(now(), 'YYYY') || '-Q' || ceil(extract(month from current_date) / 3.0)::int as cycle_period,
  a.fc_client_name as client_name_in_sheet,
  null::text as status,
  a.fc_client_id,
  a.fc_client_name,
  a.anchor_relationship_id
from clients_in_anchor_with_payroll a
where not exists (
  select 1 from sheet_rows sr
  where sr.fc_client_id = a.fc_client_id
);

comment on view profit_payroll_compliance_sheet_audit is
  'V0.7.H (049): cross-source audit between Beth''s payroll compliance
   sheet and Anchor active agreements. Surfaces (1) sheet rows whose
   client name does not resolve to an FC client (operator must fix
   sheet name), (2) Anchor agreements with Payroll Compliance service
   not represented in the sheet (operator must add row to sheet).';

-- -------------------------------------------------------------
-- Verify
-- -------------------------------------------------------------
do $$
declare
  v_table_ok boolean;
  v_trigger_ok boolean;
  v_view_ok  boolean;
begin
  select count(*) > 0 into v_table_ok
    from pg_tables where schemaname = 'public'
      and tablename = 'profit_payroll_compliance_cycle_status';
  select count(*) > 0 into v_trigger_ok
    from pg_trigger where tgname = 'profit_payroll_compliance_recognition_trigger';
  select count(*) > 0 into v_view_ok
    from pg_views where viewname = 'profit_payroll_compliance_sheet_audit';
  if not v_table_ok then raise exception '049 verify FAIL: table missing'; end if;
  if not v_trigger_ok then raise exception '049 verify FAIL: trigger missing'; end if;
  if not v_view_ok then raise exception '049 verify FAIL: audit view missing'; end if;
  raise notice '049 verify: schema OK';
end $$;
