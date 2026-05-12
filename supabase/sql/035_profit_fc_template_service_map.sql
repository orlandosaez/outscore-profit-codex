-- Migration 035: FC template -> service-tag-prefix mapping (V0.7.D-1)
--
-- Purpose: V0.7.D Task 1 profiling confirmed that Financial Cents projects
-- do NOT expose service tags in `raw->tags` (those are workflow-status tags
-- like "In Process", "Waiting on Client"). The actual project-to-service
-- binding lives in `profit_fc_projects.template_id` — 7 templates cover
-- ~225 of 391 projects with clean service mappings.
--
-- This table is OPERATOR-MANAGED metadata. Orlando clones FC templates for
-- distinct client segments (Midas Auto vs Real Estate Brokerage, etc.) and
-- will continue to do so. Architecture:
--   - New unmapped templates fall back to ILIKE-title parsing automatically
--     (preserved in profit_sla_breached_candidates via migration 035b).
--   - Orchestrator/operator adds map rows over time via plain SQL INSERTs.
--   - Diagnostic view profit_fc_unmapped_template_alert (this migration)
--     surfaces unmapped templates with active projects so operator can
--     extend the map when FC churns.
--
-- No content-specific rules. Each row is operator-validated metadata that
-- says "template X delivers services with fc_tag prefix Y." The map is
-- USED via LIKE matching against profit_service_recognition_rules.fc_tag,
-- so a single prefix row catches all tier variants (S 1040A/E/P → S 1040).
--
-- Seed: 20 rows from V0.7.D Task 1 template-id-to-title analysis (see
-- coordination/task-1-V0.7.D-data-profile.md in sibling repo).
-- Orlando spot-checked the seed on 2026-05-12 before live apply.
--
-- Depends on: nothing structural; reads profit_fc_projects.template_id
-- which has existed since V0.6.A.
-- Predeploy_smoke.sh gate must pass before live apply.

create table if not exists profit_fc_template_service_map (
  template_id   bigint primary key,
  fc_tag_prefix text   not null,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists profit_fc_template_service_map_fc_tag_prefix_idx
  on profit_fc_template_service_map (fc_tag_prefix);

comment on table profit_fc_template_service_map is
  'V0.7.D-1: operator-managed FC template_id -> fc_tag_prefix mapping. Used by profit_sla_breached_candidates clearance join. Architecture supports template churn: unmapped templates fall back to project.title ILIKE match. Diagnostic view profit_fc_unmapped_template_alert surfaces unmapped templates with active projects.';

comment on column profit_fc_template_service_map.fc_tag_prefix is
  'Service-tag prefix matched against profit_service_recognition_rules.fc_tag via LIKE prefix || ''%''. Allows one map row to cover all tiers of a service family (e.g., S 1040 covers S 1040A/E/P).';

-- =============================================================================
-- Seed: 20 rows covering ~225 of 391 active+closed FC projects
-- =============================================================================
-- Tax return templates
insert into profit_fc_template_service_map (template_id, fc_tag_prefix, notes) values
  ( 7780505, 'S 1040',    '1040 Tax Returns (covers S 1040A/E/P tiers). 39 projects all titled "1040 Tax Return".'),
  (11645141, 'S 1120',    '1120 / 1120S Tax Returns (covers S 1120A/E/P tiers). Template also carries some 1065 work — 1065-specific projects clear via ILIKE-title fallback to avoid cross-contamination when client has both 1120 and 1065 SLAs.'),
  (10826580, 'S 990',     '990 Tax Returns. 2 projects.'),

  -- Bookkeeping templates (Anchor service: "Accounting"; FC title: "Bookkeeping").
  -- These are the templates where ILIKE fallback FAILS because terminology diverges.
  -- The map is essential here.
  ( 7780503, 'S BOOK',    'Monthly/Annual Bookkeeping. 31 projects mixed Monthly/Annual.'),
  (10858403, 'S BOOK',    'Bookkeeping (Energize/Feig/Kar Kraft/Merlin/Ultimate/YV cluster). 25 projects.'),
  (11004347, 'S BOOK',    'Bookkeeping (Samdee/YV variants). 36 projects.'),
  (11009201, 'S BOOK',    'Bookkeeping (Celtic/JBLD/LJD/Ultimate Transmissions). 20 projects.'),
  (10965887, 'S BOOK',    'Bookkeeping (Collectiv). 6 projects.'),
  (11009259, 'S BOOK',    'Bookkeeping (Energize Your Body). 6 projects.'),
  (11008765, 'S BOOK',    'Bookkeeping (Merlin). 5 projects.'),
  (11009234, 'S BOOK',    'Bookkeeping (Ancom). 5 projects.'),
  (11201072, 'S BOOK',    'Bookkeeping (LegacyBids). 5 projects.'),
  (11047651, 'S BOOK',    'Bookkeeping (Kar Kraft Monthly). 6 projects.'),
  (12462283, 'S BOOK',    'Bookkeeping (Northridge Academy). 3 projects.'),
  (10936830, 'S BOOK',    'Bookkeeping (LegacyBids 2nd template). 2 projects.'),

  -- TPP (Tangible Personal Property)
  (12444095, 'S TPP',     'Tangible Personal Property Tax (Florida only). 22 projects.'),

  -- Year End Close
  (10662750, 'S YECLOSE', 'Year End Close. 4 projects.'),

  -- Payroll setup
  (11266558, 'S PAYROLL', 'ADP RUN Payroll Onboarding. 2 projects.')

on conflict (template_id) do update set
  fc_tag_prefix = excluded.fc_tag_prefix,
  notes = excluded.notes,
  updated_at = now();

-- EXCLUDED templates (not service deliverables, no map row needed):
--   10837357 — "2025 Outscore Updates and New Client Portal Announcement"
--              67 projects but it's a newsletter/announcement, not a service deliverable.
--              Excluded with confidence; no SLA clearance implication.

-- =============================================================================
-- Diagnostic view: profit_fc_unmapped_template_alert
-- =============================================================================
-- Surfaces unmapped templates that have active (non-closed) projects so
-- operator can extend the map as FC templates churn. Architecture commits
-- to template-extensibility per Orlando 2026-05-12.

create or replace view profit_fc_unmapped_template_alert as
select
  p.template_id,
  count(distinct p.fc_project_id)            as active_project_count,
  count(distinct p.fc_client_id)             as fc_client_count,
  array_agg(distinct p.title order by p.title)
    filter (where p.title is not null)        as sample_titles
from profit_fc_projects p
left join profit_fc_template_service_map m
  on m.template_id = p.template_id
where p.template_id is not null
  and m.template_id is null
  and p.is_closed = false
group by p.template_id
order by active_project_count desc;

comment on view profit_fc_unmapped_template_alert is
  'V0.7.D-1: diagnostic for template extensibility. Lists FC template_ids with active projects but no row in profit_fc_template_service_map. Operator queries this when extending the map for new cloned templates. Unmapped templates still work via ILIKE-title fallback in profit_sla_breached_candidates; the map is an optimization, not a hard dependency.';
