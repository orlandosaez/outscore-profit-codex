create table if not exists profit_time_entries (
  time_entry_key text primary key,
  staff_name text not null,
  entry_date date not null,
  client_raw text not null,
  task_raw text,
  hours numeric not null,
  hourly_rate numeric not null,
  labor_cost numeric not null,
  macro_service_type text not null,
  is_admin boolean not null default false,
  match_status text not null,
  match_reason text not null,
  candidate_count integer not null default 0,
  anchor_relationship_id text,
  anchor_client_business_name text,
  source_file text not null,
  source_sheet text not null,
  source_row integer not null,
  loaded_at timestamptz not null default now()
);

create index if not exists idx_profit_time_entries_period_staff
  on profit_time_entries (entry_date, staff_name);

create index if not exists idx_profit_time_entries_relationship_macro
  on profit_time_entries (anchor_relationship_id, macro_service_type)
  where match_status = 'matched';

create index if not exists idx_profit_time_entries_match_status
  on profit_time_entries (match_status);
