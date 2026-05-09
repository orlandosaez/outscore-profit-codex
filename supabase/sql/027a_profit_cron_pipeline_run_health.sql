/*
  Purpose: V0.6.C.c Task 3 / G4 cron-stability monitoring view.

  Surfaces the latest two terminal scheduled pipeline runs for operator review.
  The consecutive-bad-run threshold stays caller-side: consumers check whether
  both returned rows have is_recent_cron_failure = true.
*/

create or replace view profit_cron_pipeline_run_health as
select
  pipeline_run_id,
  started_at,
  finished_at,
  status,
  summary->>'error_summary' as error_summary,
  summary,
  case
    when status in ('failed', 'partial') then true
    else false
  end as is_recent_cron_failure
from profit_pipeline_runs
where run_source = 'cron'
  and status in ('success', 'failed', 'partial')
order by started_at desc
limit 2;

comment on view profit_cron_pipeline_run_health is
  'V0.6.C.c G4 cron-stability view. Shows the latest two terminal cron profit_pipeline_runs with error_summary and is_recent_cron_failure; callers decide whether both rows crossing the failure flag requires escalation.';
