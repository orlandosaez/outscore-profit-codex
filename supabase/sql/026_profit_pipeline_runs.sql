create extension if not exists pgcrypto;

create table if not exists profit_pipeline_runs (
  pipeline_run_id uuid primary key default gen_random_uuid(),
  run_source text not null check (run_source in ('cron', 'manual')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null check (status in ('running', 'success', 'failed', 'partial')),
  triggered_by text,
  summary jsonb not null default '{}'::jsonb,
  constraint profit_pipeline_runs_finished_at_status_check check (
    (status = 'running' and finished_at is null)
    or (status in ('success', 'failed', 'partial') and finished_at is not null)
  )
);

create table if not exists profit_pipeline_run_steps (
  pipeline_run_id uuid not null references profit_pipeline_runs(pipeline_run_id) on delete cascade,
  step_name text not null,
  step_order integer not null check (step_order > 0),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null check (status in ('running', 'success', 'failed', 'skipped')),
  rows_affected integer check (rows_affected is null or rows_affected >= 0),
  details jsonb not null default '{}'::jsonb,
  primary key (pipeline_run_id, step_name),
  unique (pipeline_run_id, step_order),
  constraint profit_pipeline_run_steps_finished_at_status_check check (
    (status = 'running' and finished_at is null)
    or (status in ('success', 'failed', 'skipped') and finished_at is not null)
  )
);

create unique index if not exists idx_profit_pipeline_runs_one_running
  on profit_pipeline_runs ((status))
  where status = 'running';

create index if not exists idx_profit_pipeline_runs_started_at_desc
  on profit_pipeline_runs (started_at desc);

create index if not exists idx_profit_pipeline_runs_status_started_at_desc
  on profit_pipeline_runs (status, started_at desc);

create index if not exists idx_profit_pipeline_run_steps_run_order
  on profit_pipeline_run_steps (pipeline_run_id, step_order);

comment on table profit_pipeline_runs is
  'V0.6.C pipeline run log. Enforces at most one running row at a time; C.b/C.c write manual and cron runs here.';

comment on table profit_pipeline_run_steps is
  'Ordered V0.6.C pipeline step log. Each run records one row per step name with step_order for stable UI/API ordering.';

comment on column profit_pipeline_runs.triggered_by is
  'Manual runs: operator identifier matching profit_classifications.classified_by convention (for example orlando or beth). Cron runs: cron. Synthetic checkpoint rows: test.';

comment on column profit_pipeline_runs.summary is
  'Free-form JSONB summary convention: total_steps_completed, total_steps_failed, total_rows_affected, optional error_summary, optional notable_findings.';

comment on column profit_pipeline_run_steps.details is
  'Free-form JSONB step details convention: step-specific payload, optional error, optional notes.';
