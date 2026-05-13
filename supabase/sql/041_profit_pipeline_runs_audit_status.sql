-- Migration 041: V0.7.E.0.1 T4 — profit_pipeline_runs audit_status + RPC
--
-- Adds two columns to profit_pipeline_runs that the n8n pipeline workflow
-- post-step will populate at the end of every cron / manual run:
--
--   audit_status   text  CHECK in ('clean','alerts','critical')
--   audit_summary  jsonb  full breakdown by severity + category
--
-- Plus an RPC profit_record_audit_summary(run_id uuid) that:
--   1. Reads counts from profit_data_quality_alerts grouped by severity
--   2. Decides audit_status:
--        - any high-severity rows         → 'critical'
--        - no high but medium-severity    → 'alerts'
--        - nothing                        → 'clean'
--   3. Updates the target pipeline-run row with status + summary jsonb
--   4. Returns the summary jsonb (so n8n can log / surface it)
--
-- n8n workflow 26 will call this RPC immediately after
-- "Patch Pipeline Run Final Status" and before the webhook response.
-- See V0.7.E.0.1 plan T4 for the workflow JSON edit.

-- ----------------------------------------------------------------------
-- Schema additions
-- ----------------------------------------------------------------------
alter table profit_pipeline_runs
  add column if not exists audit_status   text
    check (audit_status is null or audit_status in ('clean','alerts','critical')),
  add column if not exists audit_summary  jsonb;

comment on column profit_pipeline_runs.audit_status is
  'V0.7.E.0.1 (041): self-audit verdict from profit_data_quality_alerts at run completion. clean=no findings; alerts=medium-only; critical=any high-severity.';
comment on column profit_pipeline_runs.audit_summary is
  'V0.7.E.0.1 (041): JSON breakdown — total / by_severity / by_category counts at run completion.';

create index if not exists idx_profit_pipeline_runs_audit_status
  on profit_pipeline_runs(audit_status);

-- ----------------------------------------------------------------------
-- RPC: profit_record_audit_summary(run_id uuid)
-- ----------------------------------------------------------------------
create or replace function profit_record_audit_summary(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_high     integer;
  v_medium   integer;
  v_low      integer;
  v_total    integer;
  v_status   text;
  v_summary  jsonb;
begin
  -- Tally by severity in one pass
  select
    count(*) filter (where severity = 'high'),
    count(*) filter (where severity = 'medium'),
    count(*) filter (where severity = 'low'),
    count(*)
  into v_high, v_medium, v_low, v_total
  from profit_data_quality_alerts;

  -- Decide verdict
  v_status := case
    when v_high > 0   then 'critical'
    when v_medium > 0 then 'alerts'
    else                   'clean'
  end;

  -- Build full breakdown including category counts (top 20 to keep jsonb small)
  v_summary := jsonb_build_object(
    'total',         v_total,
    'by_severity',   jsonb_build_object(
                       'high',   v_high,
                       'medium', v_medium,
                       'low',    v_low
                     ),
    'by_category',  coalesce(
      (
        select jsonb_object_agg(alert_category, cat_count)
        from (
          select alert_category, count(*) as cat_count
          from profit_data_quality_alerts
          group by alert_category
          order by count(*) desc
          limit 20
        ) cat_agg
      ),
      '{}'::jsonb
    ),
    'recorded_at',  now()
  );

  -- Patch the target pipeline-run row
  update profit_pipeline_runs
     set audit_status  = v_status,
         audit_summary = v_summary
   where pipeline_run_id = p_run_id;

  return v_summary;
end;
$$;

comment on function profit_record_audit_summary(uuid) is
  'V0.7.E.0.1 (041): RPC called by n8n workflow 26 post-step. Tallies profit_data_quality_alerts by severity + category, decides audit_status (clean | alerts | critical), patches profit_pipeline_runs.audit_summary, returns the jsonb summary.';

-- ----------------------------------------------------------------------
-- Backfill: tag historical runs as null (no audit was recorded). The
-- next pipeline run will be the first to populate this column.
-- ----------------------------------------------------------------------
-- (no UPDATE needed — columns default to NULL which is correct historical state)

-- ----------------------------------------------------------------------
-- Verify: dry-call the RPC against the most recent pipeline run to make
-- sure the function executes without error and returns a sensible shape.
-- Wrapped in DO so the smoke gate's BEGIN/ROLLBACK undoes the write.
-- ----------------------------------------------------------------------
do $$
declare
  v_test_run uuid;
  v_result   jsonb;
begin
  select pipeline_run_id into v_test_run
    from profit_pipeline_runs
   order by started_at desc nulls last
   limit 1;

  if v_test_run is not null then
    v_result := profit_record_audit_summary(v_test_run);
    raise notice '041 self-test: audit summary written to run % → %', v_test_run, v_result;
  else
    raise notice '041 self-test: no pipeline runs in DB yet — RPC compiled, deferred verification.';
  end if;
end $$;
