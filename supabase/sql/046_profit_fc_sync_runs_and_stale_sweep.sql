-- Migration 046: V0.7.G Sprint F — W17 stale-record permanent sweep
--
-- Closes tech debt documented in docs/tech-debt.md "W17 FC Sync — Missing
-- Stale-Record Sweep" section. Replaces the ad-hoc 038a Lee's-ghost
-- migration with a permanent, every-cycle auto-archive step embedded in
-- the W17 FC sync workflow.
--
-- Design:
--   1. profit_fc_sync_runs table — one row per W17 invocation. Captures
--      started_at, client_count, prior count, safety ratio, archive
--      outcome.
--   2. profit_fc_sync_start() RPC — called at the START of W17. Records
--      the sync's started_at and returns the prior successful run's
--      client_count (for the safety guard).
--   3. profit_fc_sync_complete(sync_id, client_count) RPC — called at the
--      END of W17. Computes pass_ratio = current/prior. If >= 0.9,
--      archives all profit_fc_clients rows whose last_seen_at predates
--      the sync's started_at (i.e. W17 didn't touch them this run).
--      Otherwise skips the sweep (safety_skipped) — protects against
--      partial-fetch FC API glitches that would mass-archive real
--      records.
--   4. profit_fc_sync_health view — surfaces last 10 runs for ops
--      monitoring + audit.
--
-- Operator-facing safety guarantees:
--   - First-ever run has no prior, ratio defaults to 1.0, sweeps clean.
--   - If FC returns a partial fetch (<90% of last run), no archive happens
--     and the operator can review profit_fc_sync_runs for the
--     safety_skipped row.
--   - All archives use the same is_archived=true + archived_at=now()
--     mechanic as 038a, so 038b's resolver-side exclusion continues
--     to apply automatically.
--   - Aligns with V0.7.E.0 self-audit category A (fc_stale_record):
--      that audit will now stay at 0 between W17 runs since W17 itself
--      archives stale records every cycle.

-- ============================================================
-- A. profit_fc_sync_runs table
-- ============================================================
create extension if not exists pgcrypto;

create table if not exists profit_fc_sync_runs (
  sync_id            uuid primary key default gen_random_uuid(),
  started_at         timestamptz not null default now(),
  completed_at       timestamptz,
  client_count       integer,
  prior_client_count integer,
  pass_ratio         numeric(6,4),
  archived_count     integer default 0,
  status             text not null default 'pending'
                       check (status in ('pending','success','safety_skipped','failed')),
  notes              text
);

create index if not exists idx_profit_fc_sync_runs_started_at
  on profit_fc_sync_runs (started_at desc);
create index if not exists idx_profit_fc_sync_runs_status
  on profit_fc_sync_runs (status);

comment on table profit_fc_sync_runs is
  'V0.7.G (046): one row per W17 invocation. Tracks safety ratio
   (current_count / prior_count) and archive outcome. status=safety_skipped
   means the safety guard prevented stale-record archive (current < 90% of
   prior); operator should investigate.';

-- ============================================================
-- B. profit_fc_sync_start() RPC
-- ============================================================
create or replace function profit_fc_sync_start()
returns table (
  sync_id            uuid,
  prior_client_count integer,
  started_at         timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prior   integer;
  v_id      uuid;
  v_started timestamptz := now();
begin
  -- Look up most recent successful run's client_count
  select client_count
    into v_prior
    from profit_fc_sync_runs
   where status = 'success'
   order by completed_at desc nulls last
   limit 1;

  insert into profit_fc_sync_runs (started_at, status, prior_client_count)
       values (v_started, 'pending', v_prior)
    returning profit_fc_sync_runs.sync_id into v_id;

  return query select v_id, v_prior, v_started;
end;
$$;

comment on function profit_fc_sync_start() is
  'V0.7.G (046): called at the start of W17. Records sync started_at,
   returns sync_id + prior_client_count for the safety guard. n8n stores
   sync_id and passes it to profit_fc_sync_complete at the end.';

-- ============================================================
-- C. profit_fc_sync_complete(sync_id, client_count) RPC
-- ============================================================
create or replace function profit_fc_sync_complete(
  p_sync_id        uuid,
  p_current_count  integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_started   timestamptz;
  v_prior     integer;
  v_ratio     numeric;
  v_archived  integer := 0;
  v_status    text;
  v_notes     text;
begin
  select started_at, prior_client_count
    into v_started, v_prior
    from profit_fc_sync_runs
   where sync_id = p_sync_id;

  if v_started is null then
    raise exception 'profit_fc_sync_complete: sync_id % not found', p_sync_id;
  end if;

  -- Safety ratio. First-ever run (prior IS NULL) defaults to 1.0 (no prior
  -- to compare against — sweep proceeds normally).
  v_ratio := case
    when v_prior is null or v_prior = 0 then 1.0::numeric
    else round(p_current_count::numeric / v_prior::numeric, 4)
  end;

  if v_ratio >= 0.9 then
    -- Sweep: archive every active row that W17 didn't touch this run.
    -- "Didn't touch" = last_seen_at < started_at (W17 sets last_seen_at = now()
    -- on every upsert, so any row predating started_at was not in this batch).
    update profit_fc_clients
       set is_archived = true,
           archived_at = now(),
           updated_at  = now()
     where is_archived = false
       and last_seen_at < v_started;
    get diagnostics v_archived = row_count;
    v_status := 'success';
    v_notes := format(
      'archived %s stale FC client(s) (pass ratio %s, current=%s, prior=%s)',
      v_archived, to_char(v_ratio, 'FM0.0000'), p_current_count, coalesce(v_prior, 0)
    );
  else
    v_status := 'safety_skipped';
    v_notes := format(
      'skipped archive: current_count %s is %s of prior %s (< 90%%); '
      || 'possible FC API partial fetch — operator review required',
      p_current_count, to_char(v_ratio, 'FM0.0000'), v_prior
    );
  end if;

  update profit_fc_sync_runs
     set completed_at   = now(),
         client_count   = p_current_count,
         pass_ratio     = v_ratio,
         archived_count = v_archived,
         status         = v_status,
         notes          = v_notes
   where sync_id = p_sync_id;

  return jsonb_build_object(
    'sync_id',            p_sync_id,
    'started_at',         v_started,
    'completed_at',       now(),
    'client_count',       p_current_count,
    'prior_client_count', v_prior,
    'pass_ratio',         v_ratio,
    'archived_count',     v_archived,
    'status',             v_status,
    'notes',              v_notes
  );
end;
$$;

comment on function profit_fc_sync_complete(uuid, integer) is
  'V0.7.G (046): called at the end of W17 with the run sync_id (from
   profit_fc_sync_start) + current FC client count. If current >= 90% of
   prior, archives stale rows whose last_seen_at predates the sync.
   Otherwise marks the run safety_skipped — operator review required.';

-- ============================================================
-- D. profit_fc_sync_health view (ops monitoring)
-- ============================================================
create or replace view profit_fc_sync_health as
select
  sync_id,
  started_at,
  completed_at,
  extract(epoch from (completed_at - started_at))::integer as duration_seconds,
  client_count,
  prior_client_count,
  pass_ratio,
  archived_count,
  status,
  notes
from profit_fc_sync_runs
order by started_at desc
limit 30;

comment on view profit_fc_sync_health is
  'V0.7.G (046): last 30 W17 sync runs with safety + archive outcome.
   Surface for ops monitoring + admin UI. status=safety_skipped means the
   sweep refused to run (probable FC API partial fetch).';

-- ============================================================
-- E. Verify schema landed (READ-ONLY — no behavioral test)
--    Lesson learned 2026-05-14: prior version of this block actually
--    invoked profit_fc_sync_complete inside the DO block. The smoke
--    gate wraps in BEGIN/ROLLBACK so it appeared safe; deploy path
--    doesn't, so the live apply archived 115 active clients before
--    being reverted. Behavioral testing now lives in the unit test
--    suite + n8n workflow integration, not in the migration file.
-- ============================================================
do $$
declare
  v_table_ok boolean;
  v_start_ok boolean;
  v_complete_ok boolean;
  v_view_ok  boolean;
begin
  select count(*) > 0 into v_table_ok
    from pg_tables where schemaname = 'public' and tablename = 'profit_fc_sync_runs';
  select count(*) > 0 into v_start_ok
    from pg_proc where proname = 'profit_fc_sync_start';
  select count(*) > 0 into v_complete_ok
    from pg_proc where proname = 'profit_fc_sync_complete';
  select count(*) > 0 into v_view_ok
    from pg_views where schemaname = 'public' and viewname = 'profit_fc_sync_health';

  if not v_table_ok then raise exception '046 verify FAIL: profit_fc_sync_runs table missing'; end if;
  if not v_start_ok then raise exception '046 verify FAIL: profit_fc_sync_start() function missing'; end if;
  if not v_complete_ok then raise exception '046 verify FAIL: profit_fc_sync_complete() function missing'; end if;
  if not v_view_ok then raise exception '046 verify FAIL: profit_fc_sync_health view missing'; end if;

  raise notice '046 verify: schema OK — table, 2 RPCs, view all present';
end $$;
