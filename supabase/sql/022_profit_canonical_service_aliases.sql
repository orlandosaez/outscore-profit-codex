create table if not exists profit_anchor_service_aliases (
  raw_service_name text primary key,
  canonical_service_name text not null references profit_service_recognition_rules(service_name),
  alias_source text not null default 'manual_review' check (alias_source in ('manual_review', 'anchor_api_sync', 'qbo_api_sync')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table profit_anchor_service_aliases is
  'Manual alias table for mapping raw Anchor service descriptions to canonical service names. Migration 022 intentionally inserts no rows; do not guess canonical mappings from unresolved names without orchestrator review.';

alter table profit_revenue_events
  add column if not exists canonical_service_name text references profit_service_recognition_rules(service_name);

create index if not exists idx_profit_revenue_events_service_name
  on profit_revenue_events (service_name)
  where service_name is not null;

create index if not exists idx_profit_revenue_events_canonical_service
  on profit_revenue_events (canonical_service_name)
  where canonical_service_name is not null;

create index if not exists idx_profit_anchor_service_aliases_canonical
  on profit_anchor_service_aliases (canonical_service_name);

comment on column profit_revenue_events.service_name is
  'Raw service name from Anchor line item description. May include prorations, client name suffixes, or custom annotations. Not FK enforced.';

comment on column profit_revenue_events.canonical_service_name is
  'Nullable FK-safe service taxonomy key resolved from raw service_name by exact match, manual_alias, or prefix match.';

create or replace function profit_resolve_canonical_service_name(raw_service_name text)
returns text
language plpgsql
stable
as $$
declare
  cleaned text := nullif(btrim(raw_service_name), '');
  resolved text;
begin
  if cleaned is null then
    return null;
  end if;

  -- exact
  select rule.service_name
  into resolved
  from profit_service_recognition_rules rule
  where lower(rule.service_name) = lower(cleaned)
  order by length(rule.service_name) desc
  limit 1;

  if resolved is not null then
    return resolved;
  end if;

  -- manual_alias
  select alias.canonical_service_name
  into resolved
  from profit_anchor_service_aliases alias
  where lower(alias.raw_service_name) = lower(cleaned)
  limit 1;

  if resolved is not null then
    return resolved;
  end if;

  -- prefix: canonical name appears before " -", "(", ",", or line end.
  -- Regression boundaries, kept literal to avoid Postgres regex escaping bugs:
  -- 1120 Plus - Proration for monthly billing -> 1120 Plus
  -- 1040 Plus (Ken & Nancy Wong) -> 1040 Plus
  -- Advisory, custom note -> Advisory
  -- Accounting Plus -> Accounting Plus
  -- 990-EZ - amended return -> 990-EZ
  select rule.service_name
  into resolved
  from profit_service_recognition_rules rule
  where lower(cleaned) = lower(rule.service_name)
    or lower(cleaned) like lower(rule.service_name) || ' -%'
    or lower(cleaned) like lower(rule.service_name) || ' (%'
    or lower(cleaned) like lower(rule.service_name) || ',%'
  order by length(rule.service_name) desc
  limit 1;

  return resolved;
end;
$$;

comment on function profit_resolve_canonical_service_name(text) is
  'Resolves raw Anchor service text to canonical service taxonomy key. Resolution order: exact, manual_alias, prefix, null.';

update profit_revenue_events event
set canonical_service_name = profit_resolve_canonical_service_name(event.service_name)
where event.service_name is not null
  and event.canonical_service_name is null
  and profit_resolve_canonical_service_name(event.service_name) is not null;

create or replace view profit_unresolved_service_names as
select
  event.service_name as raw_service_name,
  event.macro_service_type,
  count(*)::integer as event_count,
  sum(event.source_amount)::numeric as total_source_amount,
  string_agg(distinct invoice.invoice_number, ', ' order by invoice.invoice_number) as sample_invoice_numbers
from profit_revenue_events event
left join profit_anchor_invoices invoice
  on invoice.anchor_invoice_id = event.anchor_invoice_id
where event.service_name is not null
  and event.canonical_service_name is null
group by event.service_name, event.macro_service_type
order by event_count desc, event.service_name;

comment on view profit_unresolved_service_names is
  'Raw Anchor service names that still need canonical alias review. Real unresolved examples captured 2026-05-04 include Bookkeeping Services, 1120 Plus - Proration for monthly billing, and 1040 Plus (Ken & Nancy Wong). These examples document scope only; do not guess canonical mappings in this migration.';

create or replace view profit_anchor_service_fc_project_coverage as
with anchor_services as (
  select
    event.anchor_relationship_id,
    agreement.client_business_name as anchor_client_business_name,
    event.canonical_service_name,
    event.service_name as raw_service_name,
    rule.fc_tag,
    event.macro_service_type,
    max(invoice.issue_date) as latest_anchor_invoice_date
  from profit_revenue_events event
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = event.anchor_relationship_id
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
  left join profit_service_recognition_rules rule
    on rule.service_name = event.canonical_service_name
  where event.service_name is not null
  group by
    event.anchor_relationship_id,
    agreement.client_business_name,
    event.canonical_service_name,
    event.service_name,
    rule.fc_tag,
    event.macro_service_type
),
matched_fc as (
  select
    match.anchor_relationship_id,
    match.fc_client_id,
    client.name as fc_client_name
  from profit_fc_client_anchor_matches match
  left join profit_fc_clients client
    on client.fc_client_id = match.fc_client_id
  where match.anchor_relationship_id is not null
),
fc_project_activity as (
  select
    project.fc_client_id,
    max(project.updated_at) as latest_fc_project_updated_at
  from profit_fc_projects project
  group by project.fc_client_id
)
select
  anchor.anchor_relationship_id,
  anchor.anchor_client_business_name,
  matched.fc_client_id,
  matched.fc_client_name,
  anchor.canonical_service_name,
  anchor.fc_tag,
  anchor.macro_service_type,
  case
    when anchor.canonical_service_name is null
      or matched.fc_client_id is null
      or anchor.fc_tag is null
      then 'unknown'
    when exists (
      select 1
      from profit_fc_client_tags tag
      where tag.fc_client_id = matched.fc_client_id
        and tag.tag_type = 'service'
        and tag.tag_name = anchor.fc_tag
    )
      then 'covered'
    else 'missing_fc_project'
  end as coverage_status,
  anchor.latest_anchor_invoice_date,
  project.latest_fc_project_updated_at
from anchor_services anchor
left join matched_fc matched
  on matched.anchor_relationship_id = anchor.anchor_relationship_id
left join fc_project_activity project
  on project.fc_client_id = matched.fc_client_id;
