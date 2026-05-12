-- Migration 035a: Derived primary preparer per FC client (V0.7.D-1)
--
-- Purpose: V0.7.D Task 1 profiling confirmed the FC `user_name` column reads
-- raw->user.name (= the user who marked the task complete, ~97% Orlando).
-- The REAL assignee lives in raw->assignees[0]->name. Plus: all 143 currently-
-- open FC projects have ZERO open tasks, so reading "the open task's
-- assignee" gives nothing for SLA-breached rows.
--
-- Solution: derive a "primary preparer per FC client" from the last 365 days
-- of COMPLETED tasks' raw->assignees[0]->name. This gives staff routing for
-- ~22 of 23 SLA-breached clients today (Laura/Noelle/Orlando split observed
-- in Task 1 profiling).
--
-- View is per fc_client_id, picks the most frequent assignee in the window,
-- with deterministic tie-break by alphabetical name. Null assignees ("(none)")
-- are excluded from the count so a client whose only completed tasks were
-- unassigned still appears with primary_preparer_name = null (consumers should
-- coalesce to 'Unassigned' for display).
--
-- Inputs:  profit_fc_tasks.raw->'assignees'->0->>'name', completed_at
-- Outputs: profit_fc_client_primary_preparer (view)
--
-- No content-specific rules. Pure derived metric over existing data.
--
-- Depends on: profit_fc_tasks (raw payload + completed_at + fc_client_id).
-- Predeploy_smoke.sh gate must pass before live apply.

create or replace view profit_fc_client_primary_preparer as
with assignee_counts as (
  select
    t.fc_client_id,
    nullif(trim(both from coalesce(t.raw->'assignees'->0->>'name', '')), '') as assignee_name,
    count(*) as task_count
  from profit_fc_tasks t
  where t.is_completed = true
    and t.completed_at is not null
    and t.completed_at >= now() - interval '365 days'
    and t.fc_client_id is not null
  group by t.fc_client_id, nullif(trim(both from coalesce(t.raw->'assignees'->0->>'name', '')), '')
),
ranked as (
  select
    fc_client_id,
    assignee_name,
    task_count,
    row_number() over (
      partition by fc_client_id
      order by
        (assignee_name is null) asc,            -- prefer non-null assignees
        task_count desc,                          -- most frequent wins
        assignee_name asc nulls last              -- deterministic tie-break
    ) as rnk
  from assignee_counts
)
select
  fc_client_id,
  assignee_name as primary_preparer_name,
  task_count as primary_preparer_task_count,
  (select sum(task_count) from assignee_counts ac where ac.fc_client_id = ranked.fc_client_id) as total_completed_tasks_365d,
  current_date as derived_at
from ranked
where rnk = 1;

comment on view profit_fc_client_primary_preparer is
  'V0.7.D-1: derived primary preparer per FC client from raw->assignees[0]->name over last 365 days of completed tasks. Replaces FC client-staff-tag sync that was blocked by Task 1 finding (FC has no client-level staff field). Consumers should coalesce primary_preparer_name to ''Unassigned'' for display.';
