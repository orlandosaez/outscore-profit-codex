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
    when task.project_title ilike '%Monthly Bookkeeping%'
      and task.title ilike '%close the books%' then 'bookkeeping_complete'
    when task.title ilike '%bookkeep%' and task.title ilike '%complete%' then 'bookkeeping_complete'
    when task.title ilike '%payroll%'
      and task.title not ilike '%provision%'
      and task.title not ilike '%onboard%'
      and task.title not ilike '%setup%'
      and (task.title ilike '%processed%' or task.title ilike '%process payroll%') then 'payroll_processed'
    when task.title ilike '%extension%' and task.title ilike '%file%' then 'tax_extension_filed'
    when task.title ilike '%file tax return%'
      or task.title ilike '%file the tax return%'
      or task.title ilike '%file return%' then 'tax_filed'
    else 'manual_review'
  end as suggested_trigger_type,
  case
    when task.project_title ilike '%Monthly Bookkeeping%'
      and task.title ilike '%close the books%' then 'bookkeeping'
    when task.title ilike '%bookkeep%' then 'bookkeeping'
    when task.title ilike '%payroll%' or task.project_title ilike '%payroll%' then 'payroll'
    when task.title ilike '%extension%' or task.title ilike '%return%' or task.project_title ilike '%tax%' then 'tax'
    else null
  end as suggested_macro_service_type,
  case
    when task.project_title ilike '%Monthly Bookkeeping%'
      and task.title ilike '%close the books%'
      then date_trunc('month', coalesce(task.completed_at, task.due_date, task.updated_at) - interval '1 month')::date
    else date_trunc('month', coalesce(task.completed_at, task.due_date, task.updated_at))::date
  end as suggested_service_period_month
from profit_fc_tasks task
left join profit_fc_client_anchor_matches match
  on match.fc_client_id = task.fc_client_id
where task.is_completed = true
  and task.completed_at is not null;
