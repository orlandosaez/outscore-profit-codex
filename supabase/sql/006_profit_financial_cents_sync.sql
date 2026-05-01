create table if not exists profit_fc_clients (
  fc_client_id bigint primary key,
  company_id bigint,
  name text not null,
  is_archived boolean,
  archived_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  raw jsonb not null,
  last_seen_at timestamptz not null default now()
);

create index if not exists idx_profit_fc_clients_name
  on profit_fc_clients (name);

create table if not exists profit_fc_projects (
  fc_project_id bigint primary key,
  fc_client_id bigint,
  title text not null,
  template_id bigint,
  service_item_id bigint,
  is_closed boolean,
  closed_at timestamptz,
  start_date date,
  due_date date,
  accounting_period date,
  accounting_period_date date,
  computed_accounting_period date,
  created_at timestamptz,
  updated_at timestamptz,
  raw jsonb not null,
  last_seen_at timestamptz not null default now()
);

create index if not exists idx_profit_fc_projects_client
  on profit_fc_projects (fc_client_id);

create index if not exists idx_profit_fc_projects_title
  on profit_fc_projects (title);

create table if not exists profit_fc_tasks (
  fc_task_id bigint primary key,
  fc_project_id bigint,
  fc_client_id bigint,
  title text not null,
  project_title text,
  client_name text,
  user_name text,
  completed_by_name text,
  is_completed boolean not null default false,
  completed_at timestamptz,
  due_date timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  raw jsonb not null,
  last_seen_at timestamptz not null default now()
);

create index if not exists idx_profit_fc_tasks_project
  on profit_fc_tasks (fc_project_id);

create index if not exists idx_profit_fc_tasks_client
  on profit_fc_tasks (fc_client_id);

create index if not exists idx_profit_fc_tasks_completed_at
  on profit_fc_tasks (completed_at);

create index if not exists idx_profit_fc_tasks_title
  on profit_fc_tasks (title);

create table if not exists profit_fc_client_anchor_matches (
  fc_client_id bigint primary key,
  fc_client_name text not null,
  anchor_relationship_id text,
  anchor_client_business_name text,
  match_status text not null default 'review',
  match_confidence numeric,
  notes text,
  loaded_at timestamptz not null default now()
);

create index if not exists idx_profit_fc_client_anchor_matches_relationship
  on profit_fc_client_anchor_matches (anchor_relationship_id);

create or replace view profit_fc_completed_task_review as
select
  task.fc_task_id,
  task.fc_project_id,
  task.fc_client_id,
  task.client_name,
  task.project_title,
  task.title as task_title,
  task.completed_at,
  task.completed_by_name,
  match.anchor_relationship_id,
  match.anchor_client_business_name,
  match.match_status,
  case
    when task.title ilike '%bookkeep%' and task.title ilike '%complete%' then 'bookkeeping_complete'
    when task.title ilike '%payroll%' and (task.title ilike '%processed%' or task.title ilike '%complete%') then 'payroll_processed'
    when task.title ilike '%extension%' and task.title ilike '%file%' then 'tax_extension_filed'
    when task.title ilike '%return%' and task.title ilike '%file%' then 'tax_filed'
    else 'manual_review'
  end as suggested_trigger_type,
  case
    when task.title ilike '%bookkeep%' then 'bookkeeping'
    when task.title ilike '%payroll%' then 'payroll'
    when task.title ilike '%extension%' or task.title ilike '%return%' or task.project_title ilike '%tax%' then 'tax'
    else null
  end as suggested_macro_service_type,
  date_trunc('month', coalesce(task.completed_at, task.due_date, task.updated_at))::date as suggested_service_period_month
from profit_fc_tasks task
left join profit_fc_client_anchor_matches match
  on match.fc_client_id = task.fc_client_id
where task.is_completed = true
  and task.completed_at is not null;
