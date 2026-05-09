/*
  Purpose: V0.6.C.c Task 2 / G2 stale pipeline-run finalizer.

  Database-owned cleanup unblocks idx_profit_pipeline_runs_one_running when a
  Workflow 26 execution leaves a run stuck in status='running'. The function is
  safe for cron and on-demand RPC use: it updates only rows still running, so a
  parallel Workflow 26 finalization wins without being overwritten.

  Return trade-off: emit one row with both finalized_count and pipeline_run_ids.
  Cron logs usually need only the count, while RPC/manual callers benefit from
  exact identifiers for audit and troubleshooting.
*/

create or replace function profit_finalize_stale_pipeline_runs(
  p_threshold interval default interval '30 minutes'
)
returns table (
  finalized_count integer,
  pipeline_run_ids uuid[]
)
language plpgsql
as $$
begin
  return query
  with finalized as (
    update profit_pipeline_runs
    set
      status = 'failed',
      finished_at = now(),
      summary = coalesce(summary, '{}'::jsonb)
        || jsonb_build_object(
          'error_summary',
          'Stuck running detection - no progress for >30min'
        )
    where status = 'running'
      and started_at < now() - p_threshold
    returning pipeline_run_id
  )
  select
    count(*)::integer as finalized_count,
    coalesce(
      array_agg(finalized.pipeline_run_id order by finalized.pipeline_run_id),
      array[]::uuid[]
    ) as pipeline_run_ids
  from finalized;
end;
$$;

comment on function profit_finalize_stale_pipeline_runs(interval) is
  'V0.6.C.c G2 stale-run cleanup. Marks running profit_pipeline_runs older than the threshold as failed, sets finished_at, preserves summary keys, and merges summary.error_summary. Idempotent because finalized rows no longer match status = running.';
