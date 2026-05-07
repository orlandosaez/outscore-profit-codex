alter table profit_anchor_agreements
  add column if not exists display_status text,
  add column if not exists terminated_at timestamptz,
  add column if not exists status_synced_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profit_anchor_agreements_display_status_check'
  ) then
    alter table profit_anchor_agreements
      add constraint profit_anchor_agreements_display_status_check
      check (
        display_status in ('active', 'terminated', 'stale')
        or display_status is null
      );
  end if;
end $$;

create index if not exists idx_profit_anchor_agreements_display_status
  on profit_anchor_agreements (display_status);

comment on column profit_anchor_agreements.display_status is
  'API-visible Anchor agreement status from agreement.status. Anchor currently exposes active and terminated; stale is set by Workflow 05 reconciliation when a previously synced agreement is absent from a full API-visible sync.';

comment on column profit_anchor_agreements.terminated_at is
  'Set from Anchor lastUpdatedAt when agreement.status = terminated.';

comment on column profit_anchor_agreements.status_synced_at is
  'Timestamp for the Workflow 05 run that last observed this agreement in Anchor.';

create table if not exists profit_qbo_product_services (
  qbo_product_id text primary key,
  qbo_product_name text not null,
  qbo_category_path text,
  active boolean,
  raw jsonb,
  source text not null default 'qbo_api_sync',
  last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_profit_qbo_product_services_name
  on profit_qbo_product_services (qbo_product_name);

create index if not exists idx_profit_qbo_product_services_category_path
  on profit_qbo_product_services (qbo_category_path);

comment on table profit_qbo_product_services is
  'Live QBO product/service hierarchy mirror for V0.6.A+. Replaces docs/data-references/qbo-product-services.csv as the active source once Workflow 28 is running.';
