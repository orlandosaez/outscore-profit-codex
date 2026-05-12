-- Migration 035e: Authoritative client-staff assignments (V0.7.D-1 correction)
--
-- Critical context: Orlando maintains the canonical per-(client × service)
-- staff assignment in `docs/data-references/client-staff-assignments.xlsx`
-- (113 unique clients, 126 rows; 13 clients have per-service splits, e.g.,
-- YV Enterprises CS LLC: tax=Laura/Beth, bookkeeping=Julie/Laura).
--
-- Migration 035a/035d built a DERIVED preparer view from FC raw->assignees,
-- which is structurally wrong because FC licenses are shared across humans
-- (3 logins for 5+ staff). The XLSX is the actual source of truth.
--
-- This migration:
--   1. Creates table `profit_client_staff_assignments` (operator-managed
--      metadata, seeded from XLSX).
--   2. Seeds 126 rows verbatim from the spreadsheet (2026-05-12 snapshot).
--   3. Creates resolver view `profit_client_staff_assignment_resolved` that
--      joins to `profit_fc_clients` for fc_client_id resolution + retains
--      assignments whose client_name doesn't match an active FC client
--      (logged for operator review).
--
-- The assignments table KEYS on (client_name, service_tag) NOT just
-- client_name, because one client can have different staff for different
-- services (Laura on tax + Julie on bookkeeping for YV CS, etc).
--
-- Migration 035f (next) updates profit_sla_breached_candidates to consume
-- this authoritative source instead of the derived preparer view.
--
-- Future:
--   - When XLSX changes, re-seed via repeat of the INSERT...ON CONFLICT block
--     (we're not implementing upload UI in V0.7.D-1).
--   - When Orlando moves the assignments inside FC (e.g., via FC native
--     template roles + client custom fields per shared-license advisory),
--     this table becomes either a sync target or is dropped in favor of
--     reading FC raw payload directly.
--
-- No content-specific rules. Each row is operator-validated metadata.
-- Predeploy_smoke.sh gate must pass before live apply.

create table if not exists profit_client_staff_assignments (
  assignment_id   bigserial primary key,
  client_name     text   not null,
  fc_client_id    bigint,
  service_tags    text[] not null default '{}'::text[],
  group_tags      text[] not null default '{}'::text[],
  staff_primary   text,
  staff_reviewer  text,
  source          text   not null default 'docs/data-references/client-staff-assignments.xlsx',
  source_row      integer,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (client_name, source_row)
);

create index if not exists profit_client_staff_assignments_client_name_idx
  on profit_client_staff_assignments (client_name);
create index if not exists profit_client_staff_assignments_service_tags_idx
  on profit_client_staff_assignments using gin (service_tags);
create index if not exists profit_client_staff_assignments_staff_primary_idx
  on profit_client_staff_assignments (staff_primary);
create index if not exists profit_client_staff_assignments_fc_client_id_idx
  on profit_client_staff_assignments (fc_client_id);

comment on table profit_client_staff_assignments is
  'V0.7.D-1 (035e): authoritative per-(client × service) staff assignments. Seeded from outscore-profit-codex/docs/data-references/client-staff-assignments.xlsx (113 unique clients, 126 rows; 13 clients have per-service splits). Keys on (client_name, service_tags) so the same client can have different Primary/Reviewer for tax vs bookkeeping. Replaces the FC-raw->assignees-derived approach in 035a/035d which inherited shared-login distortion.';
comment on column profit_client_staff_assignments.service_tags is
  'Parsed from XLSX "Group& Service" column (e.g., "S 1120P", "S BOOKP"). Match against profit_service_recognition_rules.fc_tag.';
comment on column profit_client_staff_assignments.group_tags is
  'Non-service entries from XLSX "Group& Service" column (e.g., "Feig Group", "MIDAS Auto", cross-references like "DBH Air Corporation"). Captured for diagnostic visibility; not used by SLA join logic.';
comment on column profit_client_staff_assignments.staff_primary is
  'Actual human name (Beth / Laura / Wama / Julie / Noelle), NOT the FC login.';

-- =============================================================================
-- Seed: 126 rows from XLSX (2026-05-12 snapshot)
-- =============================================================================
insert into profit_client_staff_assignments
  (client_name, service_tags, group_tags, staff_primary, staff_reviewer, source_row)
values
  ('1415 Cortez Rd LLC', ARRAY['S 1120P','S BOOKP','S TPP'], ARRAY['Feig Group','MIDAS Auto'], 'Laura', 'Beth', 2),
  ('4565 Clark Rd LLC', ARRAY['S 1065E','S BOOKE'], ARRAY['Feig Group'], 'Laura', 'Beth', 3),
  ('6712 Manatee Ave LLC', ARRAY['S 1120P','S BOOKP','S TPP'], ARRAY['Feig Group','MIDAS Auto'], 'Laura', 'Beth', 4),
  ('Accelerated Contracting Services LLC', ARRAY['S 1120P'], ARRAY['Bennie Group'], 'Beth', 'Laura', 5),
  ('Advanced Consulting Solutions LLC', ARRAY['S 1120P'], ARRAY['Advanced Consulting'], 'Beth', 'Laura', 6),
  ('Ancom Systems Inc', ARRAY['S 1120P','S BOOKE'], ARRAY['Andrews Group'], 'Beth', 'Laura', 7),
  ('Andrews, Randall W (1040)', ARRAY['S 1040P'], ARRAY['Ancom Systems Inc'], 'Beth', 'Laura', 8),
  ('Ary-A Investments Ohio Ave LLC', ARRAY['S 1065E'], ARRAY['Ary-A Investments'], 'Laura', 'Beth', 9),
  ('B & W Services LLC', ARRAY['S 1120P','S 941'], ARRAY['Bennie Group'], 'Beth', 'Laura', 10),
  ('B&B Technology Inc. (SimpleSwitch.io)', ARRAY['S 1120A','S SETUP','S YECLOSE'], ARRAY['SimpleSwitch'], 'Laura', 'Beth', 11),
  ('Bailey, Jytte and Richard (1040)', ARRAY['S 1040P'], ARRAY['SimpleSwitch'], 'Laura', 'Beth', 12),
  ('Baranga, Cristina G  (1040)', ARRAY['S 1040E'], ARRAY[]::text[], 'Laura', 'Beth', 13),
  ('Bieryla, James (1040)', ARRAY['S 1040P'], ARRAY['JBLD Performance Transmission LLC'], 'Laura', 'Beth', 14),
  ('Blacklist Performance LLC', ARRAY['S 1120P','S TPP'], ARRAY['Hornauer Group'], 'Beth', 'Laura', 15),
  ('Celtic Auto Werks Inc', ARRAY['S 1120P'], ARRAY['Chris Sullivan'], 'Beth', 'Laura', 16),
  ('Celtic Auto Werks Inc', ARRAY['S BOOKE'], ARRAY['Chris Sullivan'], 'Wama', 'Beth', 17),
  ('Collectiv LLC', ARRAY['S BOOKA'], ARRAY['Collectiv'], 'Wama', 'Noelle', 18),
  ('Coraggio, Anna (1040)', ARRAY['S 1040P'], ARRAY['Energize Your Body'], 'Beth', 'Laura', 19),
  ('Corey Monaghan Consulting Inc', ARRAY['S 1120P'], ARRAY['Corey Monaghan'], 'Laura', 'Beth', 20),
  ('Daniel A Bachert and Marydenyse Ommert (1040)', ARRAY['S 1040P'], ARRAY['Bachert'], 'Beth', 'Laura', 21),
  ('Daniel, Ian M (1040)', ARRAY['S 1040P'], ARRAY['Ultimate Transmission II'], 'Laura', 'Beth', 22),
  ('Daniel, Lewis (1040)', ARRAY['S 1040P'], ARRAY['JBLD Performance Transmission LLC'], 'Laura', 'Beth', 23),
  ('DBH Air Corporation', ARRAY['S 1120P','S TPP'], ARRAY['Hornauer Group'], 'Beth', 'Laura', 24),
  ('DVH Investing LLC', ARRAY['S 1065E'], ARRAY['Hornauer Group'], 'Beth', 'Laura', 25),
  ('E & O Automotive LLC', ARRAY['S 1120P','S BOOKP','S TPP'], ARRAY['Feig Group','MIDAS Auto'], 'Laura', 'Beth', 26),
  ('E M Tempest LLC', ARRAY['S 1065E'], ARRAY['Tempest Group'], 'Beth', 'Laura', 27),
  ('Energize Your Body, Inc.', ARRAY['S 1120E','S BOOKE'], ARRAY['Energize Your Body'], 'Beth', 'Laura', 28),
  ('Essential Balance Holistic Wellness Center LLC', ARRAY['S 1120P'], ARRAY['Essential Balance'], 'Beth', 'Laura', 29),
  ('Feig, Ethan E (1040)', ARRAY['S 1040P'], ARRAY['Feig Group','6712 Manatee Ave LLC'], 'Laura', 'Beth', 30),
  ('Feig, Hadar Steven (1040)', ARRAY['S 1040P'], ARRAY['Feig Group','E & O Automotive LLC'], 'Laura', 'Beth', 31),
  ('Feig, Owen (1040)', ARRAY['S 1040P'], ARRAY['Feig Group','1415 Cortez Rd LLC'], 'Laura', 'Beth', 32),
  ('Flaskay, Nicholas (1040)', ARRAY['S 1040A'], ARRAY['Nicholas Group Enterprises Inc'], 'Beth', 'Laura', 33),
  ('Geesey, Robert B (1040)', ARRAY['S 1040P'], ARRAY['RB Geesey'], 'Beth', 'Laura', 34),
  ('Halprin, Christopher A & Jessica (1040)', ARRAY['S 1040E'], ARRAY['Ancom Systems Inc'], 'Beth', 'Laura', 35),
  ('Harvie Mike & Adrienne (1040)', ARRAY['S 1040P'], ARRAY[]::text[], 'Beth', 'Laura', 36),
  ('Holland, Merlin H (1040)', ARRAY['S 1040P'], ARRAY['Merlin Trucking'], 'Laura', 'Beth', 37),
  ('Hornauer, Dirk B and Veena (1040)', ARRAY['S 1040P'], ARRAY['Hornauer Group','DBH Air Corporation'], 'Beth', 'Laura', 38),
  ('Hornauer, Noah (1040)', ARRAY['S 1040E'], ARRAY['Hornauer Group','Blacklist Perfomance LLC'], 'Beth', 'Laura', 39),
  ('Ice of Central Florida, Inc', ARRAY['S 1120P'], ARRAY['Ice Group'], 'Beth', 'Laura', 40),
  ('ICON Supply Inc', ARRAY[]::text[], ARRAY[]::text[], 'Beth', 'Beth', 41),
  ('Inatsuka, Linda (1040)', ARRAY['S 1040P'], ARRAY['LTI Associates'], 'Laura', 'Beth', 42),
  ('JBLD Performance Transmission LLC', ARRAY['S 1120P','S TPP'], ARRAY['Lewis Daniel Group'], 'Laura', 'Beth', 43),
  ('JBLD Performance Transmission LLC', ARRAY['S BOOKE'], ARRAY['Lewis Daniel Group'], 'Wama', 'Laura', 44),
  ('JGC Management Inc', ARRAY['S 1120P'], ARRAY['Ciaccio Group'], 'Beth', 'Laura', 45),
  ('JLR Leasing LLC', ARRAY['S 1065E'], ARRAY['Andrews Group'], 'Beth', 'Laura', 46),
  ('Kam F and Choi L Wong', ARRAY['S 1040E'], ARRAY['KNW','KNW Properties and Assets LLC'], 'Laura', 'Beth', 47),
  ('Kar Kraft Auto Repair LLC (TempleTerrace)', ARRAY['S 1120P','S BOOKP','S TPP'], ARRAY['Kar Kraft Group','MIDAS Auto'], 'Beth', 'Laura', 48),
  ('Kar Kraft Auto Services LLC (closeout for 2025)', ARRAY['S 1120E'], ARRAY['Kar Kraft Group'], 'Beth', 'Laura', 49),
  ('Kar Kraft Real Est (goes into personal return)', ARRAY[]::text[], ARRAY['Kar Kraft Group'], 'Beth', 'Laura', 50),
  ('Kar Kraft Services LLC (Zephyrhills)', ARRAY['S 1120P','S BOOKP','S TPP'], ARRAY['Kar Kraft Group','MIDAS Auto'], 'Beth', 'Laura', 51),
  ('KNW Properties and Assets LLC', ARRAY['S 1065E'], ARRAY['KNW'], 'Laura', 'Beth', 52),
  ('Kodiak Enterprises LLC', ARRAY['S 1120P','S TPP'], ARRAY[]::text[], 'Laura', 'Beth', 53),
  ('Lee''s Food Store of Sarasota, Inc', ARRAY['S 1120P'], ARRAY['Ice Group'], 'Beth', 'Laura', 54),
  ('Lee''s Ice of Southwest Florida, Inc', ARRAY['S 1120P'], ARRAY['Ice Group'], 'Beth', 'Laura', 55),
  ('Lee''s Inc', ARRAY['S 1120E'], ARRAY['Ice Group'], 'Beth', 'Laura', 56),
  ('Legacy Bids LLC', ARRAY['S 1120E'], ARRAY[]::text[], 'Beth', 'Laura', 57),
  ('Legacy Bids LLC', ARRAY['S BOOKP'], ARRAY[]::text[], 'Noelle', 'Noelle', 58),
  ('LJD Performance Transmission Inc', ARRAY['S 1120P','S TPP'], ARRAY['LJD Performance'], 'Laura', 'Beth', 59),
  ('LJD Performance Transmission Inc', ARRAY['S BOOKE'], ARRAY['LJD Performance'], 'Wama', 'Laura', 60),
  ('LTI Associates Inc.', ARRAY['S 1120P'], ARRAY['LTI Associates'], 'Laura', 'Beth', 61),
  ('Mad Dawg Investment, LLC', ARRAY['S 1065E'], ARRAY['Bachert'], 'Beth', 'Laura', 62),
  ('Maria Mitchell and Ronald Scagliola (1040)', ARRAY['S 1040P'], ARRAY[]::text[], 'Laura', 'Beth', 63),
  ('Maria Victoria Schaffner (1040)', ARRAY['S 1040P'], ARRAY[]::text[], 'Laura', 'Beth', 64),
  ('Melville, Shanon R (1040)', ARRAY['S 1040A'], ARRAY['Schmidli Enterprises LLC'], 'Beth', 'Laura', 65),
  ('Menist, Samuel E (1040)', ARRAY['S 1040P'], ARRAY['Samdee Enterprises Inc'], 'Laura', 'Beth', 66),
  ('Merlin Trucking Inc', ARRAY['S 1120P','S BOOKE'], ARRAY['Merlin Trucking'], 'Laura', 'Beth', 67),
  ('Monaghan, Corey J (1040)', ARRAY['S 1040P'], ARRAY['Corey Monanghan'], 'Laura', 'Beth', 68),
  ('Nazario, Eric (1040)', ARRAY['S 1040P'], ARRAY['Scape Mate'], 'Beth', 'Laura', 69),
  ('NDH Holdings LLC', ARRAY['S 1065E'], ARRAY['Hornauer Group'], 'Beth', 'Laura', 70),
  ('Nicholas Group Enterprises Inc', ARRAY['S 1120E'], ARRAY['Nicholas Group'], 'Beth', 'Laura', 71),
  ('Northridge Academy LLC', ARRAY['S 1120P','S TPP'], ARRAY[]::text[], 'Beth', 'Laura', 72),
  ('Northridge Academy LLC', ARRAY['S BOOKP'], ARRAY[]::text[], 'Wama', 'Beth', 73),
  ('One Source Restoration and Building Services Inc', ARRAY['S 1120P'], ARRAY['One Source'], 'Beth', 'Laura', 74),
  ('Precision Metals Group Inc', ARRAY['S 1120P','S TPP'], ARRAY['Hornauer Group'], 'Beth', 'Laura', 75),
  ('Profitable Stewardship Inc', ARRAY['S 1120E'], ARRAY['Profitable Stewardship'], 'Beth', 'Laura', 76),
  ('RB Geesey and Associates Inc', ARRAY['S 1120P'], ARRAY['RB Geesey'], 'Beth', 'Laura', 77),
  ('Rossbach, Christopher (1040)', ARRAY['S 1040P'], ARRAY['Tropaholic'], 'Beth', 'Laura', 78),
  ('Saez, Orlando (1040)', ARRAY['S 1040P'], ARRAY[]::text[], 'Beth', 'Laura', 79),
  ('Saffold II, James (1040)', ARRAY['S 1040P'], ARRAY['Advanced Consulting Solutions LLC'], 'Beth', 'Laura', 80),
  ('Samdee Enterprises Automotive Group LLC (SpringHill)', ARRAY['S BOOKP'], ARRAY['SamDee','MIDAS Auto'], 'Laura', 'Beth', 81),
  ('SamDee Enterprises Inc (Lakeland)', ARRAY['S BOOKP'], ARRAY['SamDee','MIDAS Auto','C-CORP'], 'Laura', 'Beth', 82),
  ('Samdee Enterprises Automotive Group LLC (SpringHill)', ARRAY['S 1120P','S TPP'], ARRAY['SamDee','MIDAS Auto'], 'Laura', 'Beth', 83),
  ('SamDee Enterprises Inc (Lakeland)', ARRAY['S 1120P','S TPP'], ARRAY['SamDee','MIDAS Auto','C-CORP'], 'Laura', 'Beth', 84),
  ('Samdee RE (Spring Hill) LLC', ARRAY[]::text[], ARRAY['Samuel Menist'], 'Laura', 'Beth', 85),
  ('SBC Accounting and Tax LLC (Outscore)', ARRAY['S 1120P'], ARRAY[]::text[], 'Beth', 'Laura', 86),
  ('SBC Accounting and Tax LLC (Outscore)', ARRAY['S BOOKP'], ARRAY[]::text[], 'Noelle', 'Noelle', 87),
  ('Scape Mate LLC', ARRAY['S 1120P'], ARRAY['Scape Mate'], 'Beth', 'Laura', 88),
  ('Schmidli Enterprises LLC', ARRAY['S 1120E'], ARRAY['Schmidli'], 'Beth', 'Laura', 89),
  ('Sole Properties Florida LLC', ARRAY['S 1065E'], ARRAY['Feig Group'], 'Laura', 'Beth', 90),
  ('Sole Properties LLC', ARRAY['S 1065E'], ARRAY['Feig Group'], 'Laura', 'Beth', 91),
  ('Sullivan, Christopher (1040)', ARRAY['S 1040P'], ARRAY['Celtic Auto Werks Inc'], 'Beth', 'Laura', 92),
  ('Suncoast Aamco Marketing Pool Inc', ARRAY['S 1120E'], ARRAY[]::text[], 'Beth', 'Laura', 93),
  ('Surber, Roy (1040)', ARRAY['S 1040P'], ARRAY['Ice Group'], 'Beth', 'Laura', 94),
  ('Susan Keen', ARRAY[]::text[], ARRAY['Susan Keen'], null, null, 95),
  ('Sutherland, Markus H (1040)', ARRAY['S 1040P'], ARRAY['Essential Balance'], 'Beth', 'Laura', 96),
  ('Tempest Group Inc', ARRAY['S 1065E'], ARRAY['Norma Tempest'], 'Beth', 'Laura', 97),
  ('Tempest Technologies LLC', ARRAY['S 1120P','S 941'], ARRAY['Tempest Group'], 'Beth', 'Laura', 98),
  ('Tempest, Benjamin (1040)', ARRAY['S 1040E'], ARRAY['E M Tempest LLC'], 'Beth', 'Laura', 99),
  ('Tempest, Edward M (1040)', ARRAY['S 1040P'], ARRAY['Tempest Group','Tempest Technologies LLC'], 'Beth', 'Laura', 100),
  ('The Bachert Law Firm PA', ARRAY['S 1120E','S TPP'], ARRAY['Bachert'], 'Beth', 'Laura', 101),
  ('Todt, Erik L (1040)', ARRAY['S 1040P'], ARRAY['Kar Kraft Group','Kar Kraft'], 'Beth', 'Laura', 102),
  ('Tropaholic LLC', ARRAY['S 1065E'], ARRAY['Tropaholic'], 'Beth', 'Laura', 103),
  ('True, Taylor (1040)', ARRAY['S 1040P'], ARRAY['Truly Tailored'], 'Beth', 'Laura', 104),
  ('Truly Tailored Landscaping LLC', ARRAY['S 1120E'], ARRAY['Truly Tailored'], 'Beth', 'Laura', 105),
  ('Ultimate Transmissions II', ARRAY['S 1120P','S TPP'], ARRAY['Ultimate Transmissions','AAMCO Auto'], 'Laura', 'Beth', 106),
  ('Ultimate Transmissions II', ARRAY['S BOOKE'], ARRAY['Ultimate Transmissions','AAMCO Auto'], 'Wama', 'Beth', 107),
  ('VFW 10140 Veterans of Foreign Wars of the US Temple Terrace Post', ARRAY['S 990P'], ARRAY['VFW10140'], 'Beth', 'Beth', 108),
  ('VFW 424 Hatton-Gillette-Douglas Post', ARRAY['S 990P'], ARRAY['VFW424'], 'Beth', 'Beth', 109),
  ('VFW 4321 Veterans of Foreign Wars Russell P Harris Post', ARRAY['S 990P'], ARRAY['VFW4321'], 'Beth', 'Beth', 110),
  ('VFW 6287 Veterans of Foreign Wars of Ruskin Memorial Post', ARRAY['S 990P'], ARRAY['VFW6287'], 'Beth', 'Beth', 111),
  ('Victores, Yoel (1040)', ARRAY['S 1040P'], ARRAY['YV Group'], 'Laura', 'Beth', 112),
  ('West Coast Conference WMS Inc', ARRAY['S 990P'], ARRAY['WMS Inc'], 'Beth', 'Beth', 113),
  ('Williams, Bennie (1040)', ARRAY['S 1040P'], ARRAY['Bennie Group'], 'Beth', 'Laura', 114),
  ('Wolfson, Lee A (1040)', ARRAY['S 1040P'], ARRAY['Ice Group'], 'Beth', 'Laura', 115),
  ('Wolfson, Stephen T (1040)', ARRAY['S 1040P'], ARRAY['Ice Group'], 'Beth', 'Laura', 116),
  ('Wolfson, William I (1040)', ARRAY['S 1040P'], ARRAY['Ice Group'], 'Beth', 'Laura', 117),
  ('Wolfsonstein LLC', ARRAY['S 1065E'], ARRAY['Ice Group'], 'Beth', 'Laura', 118),
  ('Wong, Ken and Nancy (1040)', ARRAY['S 1040P'], ARRAY['KNW','KNW Properties and Assets LLC'], 'Laura', 'Beth', 119),
  ('YV Enterprises CS LLC', ARRAY['S 1120P','S PAYROLL','S TPP'], ARRAY[]::text[], 'Laura', 'Beth', 120),
  ('YV Enterprises CS LLC', ARRAY['S BOOKP'], ARRAY[]::text[], 'Julie', 'Laura', 121),
  ('YV Enterprises HB LLC', ARRAY['S 1120P','S PAYROLL','S TPP'], ARRAY[]::text[], 'Laura', 'Beth', 122),
  ('YV Enterprises HB LLC', ARRAY['S BOOKP'], ARRAY[]::text[], 'Julie', 'Laura', 123),
  ('YV Enterprises PSL LLC', ARRAY['S 1120P','S PAYROLL','S TPP'], ARRAY[]::text[], 'Laura', 'Beth', 124),
  ('YV Enterprises PSL LLC', ARRAY['S BOOKP'], ARRAY[]::text[], 'Julie', 'Laura', 125),
  ('YV Enterprises SR LLC', ARRAY['S 1120P','S PAYROLL','S TPP'], ARRAY[]::text[], 'Laura', 'Beth', 126),
  ('YV Enterprises SR LLC', ARRAY['S BOOKP'], ARRAY[]::text[], 'Julie', 'Laura', 127)
on conflict (client_name, source_row) do update set
  service_tags = excluded.service_tags,
  group_tags = excluded.group_tags,
  staff_primary = excluded.staff_primary,
  staff_reviewer = excluded.staff_reviewer,
  updated_at = now();

-- Backfill fc_client_id by matching client_name to profit_fc_clients.name.
update profit_client_staff_assignments a
   set fc_client_id = c.fc_client_id,
       updated_at = now()
  from profit_fc_clients c
 where c.is_archived = false
   and a.client_name = c.name
   and a.fc_client_id is distinct from c.fc_client_id;

-- =============================================================================
-- Resolver view: profit_client_staff_assignment_resolved
-- =============================================================================
-- One row per (assignment_id) with fc_client_id resolved + diagnostic flag for
-- rows whose client_name didn't match an active FC client (name drift in
-- spreadsheet vs FC).

create or replace view profit_client_staff_assignment_resolved as
select
  a.assignment_id,
  a.client_name,
  a.fc_client_id,
  a.service_tags,
  a.group_tags,
  a.staff_primary,
  a.staff_reviewer,
  case
    when a.fc_client_id is null then true
    else false
  end as client_name_unresolved,
  a.source,
  a.source_row,
  a.created_at,
  a.updated_at
from profit_client_staff_assignments a;

comment on view profit_client_staff_assignment_resolved is
  'V0.7.D-1 (035e): consumer view for SLA candidate + future workload routing. client_name_unresolved=true means the spreadsheet client_name did not match any active profit_fc_clients.name. Operator should reconcile (likely XLSX name drift after V0.7.B.4 entity splits).';

-- =============================================================================
-- Diagnostic: unresolved-name alert
-- =============================================================================
create or replace view profit_client_staff_assignment_unresolved_alert as
select client_name, count(*) as row_count, array_agg(distinct staff_primary) as staff_primary_set
from profit_client_staff_assignments
where fc_client_id is null
group by client_name
order by client_name;

comment on view profit_client_staff_assignment_unresolved_alert is
  'V0.7.D-1 (035e): diagnostic for assignment rows whose client_name did not resolve to an active FC client. Operator review needed; likely name drift (e.g., spreadsheet has "Lee''s Food Store of Sarasota, Inc" but FC has both that AND "Lee''s Food Store of Sarasota Inc" without comma after V0.7.B.4 entity attribution).';
