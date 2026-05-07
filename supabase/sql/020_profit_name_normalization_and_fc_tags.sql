create extension if not exists pg_trgm;

create or replace function profit_normalize_client_name(value text)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          lower(coalesce(value, '')),
          '\s*\([^)]*\)',
          '',
          'g'
        ),
        '\m(llc|inc|corp|corporation|company|co|ltd|pllc|pa)\M',
        '',
        'g'
      ),
      '[^a-z0-9]+',
      '',
      'g'
    ),
    ''
  );
$$;

comment on function profit_normalize_client_name(text) is
  'Normalizes client names for FC/Anchor matching. Strips parenthetical location/year suffixes before legal suffix and punctuation stripping. Examples: Kar Kraft Auto Repair LLC (TempleTerrace), Kar Kraft Services LLC (Zephyrhills), Samdee Enterprises Automotive Group LLC (SpringHill).';

create table if not exists profit_fc_client_tags (
  fc_client_id bigint not null references profit_fc_clients(fc_client_id),
  tag_name text not null,
  tag_type text not null check (tag_type in ('service', 'group', 'staff', 'unknown')),
  normalized_tag text not null,
  synced_at timestamptz not null default now(),
  primary key (fc_client_id, tag_name)
);

create index if not exists idx_profit_fc_client_tags_name
  on profit_fc_client_tags (tag_name);

create index if not exists idx_profit_fc_client_tags_normalized
  on profit_fc_client_tags (normalized_tag);

create index if not exists idx_profit_fc_client_tags_type
  on profit_fc_client_tags (tag_type);

create table if not exists profit_fc_project_tags (
  fc_project_id bigint not null references profit_fc_projects(fc_project_id),
  tag_name text not null,
  tag_type text not null check (tag_type in ('service', 'group', 'staff', 'unknown')),
  normalized_tag text not null,
  synced_at timestamptz not null default now(),
  primary key (fc_project_id, tag_name)
);

create index if not exists idx_profit_fc_project_tags_name
  on profit_fc_project_tags (tag_name);

create index if not exists idx_profit_fc_project_tags_normalized
  on profit_fc_project_tags (normalized_tag);

create index if not exists idx_profit_fc_project_tags_type
  on profit_fc_project_tags (tag_type);

create table if not exists profit_fc_task_tags (
  fc_task_id bigint not null references profit_fc_tasks(fc_task_id),
  tag_name text not null,
  tag_type text not null check (tag_type in ('service', 'group', 'staff', 'unknown')),
  normalized_tag text not null,
  synced_at timestamptz not null default now(),
  primary key (fc_task_id, tag_name)
);

create index if not exists idx_profit_fc_task_tags_name
  on profit_fc_task_tags (tag_name);

create index if not exists idx_profit_fc_task_tags_normalized
  on profit_fc_task_tags (normalized_tag);

create index if not exists idx_profit_fc_task_tags_type
  on profit_fc_task_tags (tag_type);

create table if not exists profit_client_groups (
  group_id bigserial primary key,
  group_name text not null unique,
  normalized_group_name text not null,
  source text not null default 'fc_tag' check (source in ('fc_tag', 'manual_override', 'seed_snapshot')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_profit_client_groups_normalized
  on profit_client_groups (normalized_group_name);

create table if not exists profit_client_group_members (
  group_id bigint not null references profit_client_groups(group_id),
  fc_client_id bigint not null references profit_fc_clients(fc_client_id),
  membership_source text not null default 'fc_tag',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (group_id, fc_client_id)
);

create index if not exists idx_profit_client_group_members_client
  on profit_client_group_members (fc_client_id);

create index if not exists idx_profit_client_group_members_active
  on profit_client_group_members (active);

create or replace function profit_refresh_client_groups(full_client_tag_sync boolean default false)
returns void
language plpgsql
as $$
begin
  insert into profit_client_groups (
    group_name,
    normalized_group_name,
    source,
    created_at,
    updated_at
  )
  select distinct
    tag.tag_name,
    profit_normalize_client_name(tag.tag_name),
    'fc_tag',
    now(),
    now()
  from profit_fc_client_tags tag
  where tag.tag_type = 'group'
    and tag.tag_name is not null
    and tag.normalized_tag is not null
  on conflict (group_name) do update set
    normalized_group_name = excluded.normalized_group_name,
    updated_at = now();

  insert into profit_client_group_members (
    group_id,
    fc_client_id,
    membership_source,
    active,
    created_at,
    updated_at
  )
  select distinct
    grp.group_id,
    tag.fc_client_id,
    'fc_tag',
    true,
    now(),
    now()
  from profit_fc_client_tags tag
  join profit_client_groups grp
    on grp.group_name = tag.tag_name
  where tag.tag_type = 'group'
  on conflict (group_id, fc_client_id) do update set
    membership_source = excluded.membership_source,
    active = true,
    updated_at = now();

  if full_client_tag_sync then
    update profit_client_group_members member
    set active = false,
        updated_at = now()
    where member.membership_source = 'fc_tag'
      and not exists (
        select 1
        from profit_fc_client_tags tag
        join profit_client_groups grp
          on grp.group_name = tag.tag_name
        where tag.tag_type = 'group'
          and grp.group_id = member.group_id
          and tag.fc_client_id = member.fc_client_id
      );
  end if;
end;
$$;

comment on function profit_refresh_client_groups(boolean) is
  'Explicit Workflow 17 RPC. Refreshes group rows and group memberships from profit_fc_client_tags where tag_type = group. Memberships are deactivated only when full_client_tag_sync = true so partial syncs do not remove members.';

create or replace view profit_fc_group_name_near_duplicates as
select
  a.group_name as group_name_a,
  b.group_name as group_name_b,
  a.normalized_group_name as normalized_a,
  b.normalized_group_name as normalized_b,
  similarity(a.normalized_group_name, b.normalized_group_name) as similarity_score
from profit_client_groups a
join profit_client_groups b
  on a.group_id < b.group_id
where a.normalized_group_name = b.normalized_group_name
   or similarity(a.normalized_group_name, b.normalized_group_name) >= 0.82
   or (
    -- Real typo regression: Corey Monaghan vs Corey Monanghan.
    a.normalized_group_name in ('coreymonaghan', 'coreymonanghan')
    and b.normalized_group_name in ('coreymonaghan', 'coreymonanghan')
   );

create or replace view profit_fc_task_delivery_classification as
select
  task.fc_task_id,
  task.fc_project_id,
  task.fc_client_id,
  task.client_name,
  task.project_title,
  task.title as task_title,
  task.is_completed,
  task.completed_at,
  case
    when task.title ilike '%close the books%'
      or task.project_title ilike '%monthly bookkeeping%'
      or task.title ilike '%file the tax return%'
      or task.title ilike '%file tax return%'
      or task.title ilike '%file return%'
      or (task.title ilike '%extension%' and task.title ilike '%file%')
      or (task.title ilike '%payroll%' and (task.title ilike '%processed%' or task.title ilike '%process payroll%'))
      or task.title ilike '%sales tax%file%'
      or task.title ilike '%sales tax%return%'
      or (task.title ilike '%advisory%' and (task.title ilike '%deliver%' or task.title ilike '%review%'))
      then 'service_delivery'
    when task.title ilike '%onboarding%'
      or task.title ilike '%setup%'
      or task.title ilike '%data request%'
      or task.title ilike '%engagement letter%'
      or task.title ilike '%client setup%'
      or task.title ilike '%internal admin%'
      then 'admin_onboarding'
    else 'unknown'
  end as task_kind
from profit_fc_tasks task;
