-- Migration 029a: Weekly Review State Table + Queue View
-- V0.7.A — Manual Invoice Pending verdict + Weekly Review skeleton
--
-- Creates:
--   profit_weekly_review_item_state  — persists reviewed/snooze state per classification
--   profit_weekly_review_visible_verdicts — registry of verdicts surfaced in the queue
--   profit_weekly_review_items       — universal queue view joining candidates + state
--
-- Depends on: 023 (profit_classifications), 029 (profit_manual_invoice_pending_candidates)
-- Does NOT apply the migration to any DB — deploy gate is Task 8.


-- ────────────────────────────────────────────────────────────────
-- 1. Weekly Review Item State Table
-- ────────────────────────────────────────────────────────────────

create table if not exists profit_weekly_review_item_state (
  classification_id bigint primary key references profit_classifications(classification_id),
  reviewed_at timestamptz,
  snoozed_until date,
  operator_id text not null default 'orlando',
  practice_id text,          -- nullable until V0.7.E assigns multi-practice routing
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table profit_weekly_review_item_state is
  'Operator review state for items surfaced in the Weekly Review queue. One row per active classification. Reviewed and snooze state are set by the frontend; the pipeline does not write here.';

comment on column profit_weekly_review_item_state.practice_id is
  'Practice assignment for multi-firm routing. Nullable until V0.7.E adds the M&A configuration layer.';

comment on column profit_weekly_review_item_state.snoozed_until is
  'Date (inclusive) until which this item is hidden from the default queue view. NULL = not snoozed. Standard snooze = 7 days from today.';

comment on column profit_weekly_review_item_state.reviewed_at is
  'Timestamp when the operator last marked this item as reviewed. NULL = not reviewed. Show reviewed toggle surfaces these rows.';


-- ────────────────────────────────────────────────────────────────
-- 2. updated_at trigger for profit_weekly_review_item_state
-- ────────────────────────────────────────────────────────────────

create or replace function profit_weekly_review_item_state_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace trigger trg_profit_weekly_review_item_state_updated_at
  before update on profit_weekly_review_item_state
  for each row
  execute function profit_weekly_review_item_state_set_updated_at();


-- ────────────────────────────────────────────────────────────────
-- 3. Visible Verdicts Registry
--    Controls which verdict types appear in the queue.
--    V0.7.A seeds MANUAL_INVOICE_PENDING only.
--    V0.7.B-D will INSERT additional verdict codes here.
-- ────────────────────────────────────────────────────────────────

create table if not exists profit_weekly_review_visible_verdicts (
  verdict_code text primary key references profit_classification_verdicts(verdict_code),
  sort_order   int          not null default 0,
  created_at   timestamptz  not null default now()
);

comment on table profit_weekly_review_visible_verdicts is
  'Registry of verdict codes surfaced in the Weekly Review queue. Insert a row here to enable a verdict type in the UI. V0.7.A: MANUAL_INVOICE_PENDING only.';

insert into profit_weekly_review_visible_verdicts (verdict_code, sort_order)
values ('MANUAL_INVOICE_PENDING', 10)
on conflict (verdict_code) do update set
  sort_order = excluded.sort_order;


-- ────────────────────────────────────────────────────────────────
-- 4. Weekly Review Items Queue View
--    Universal queue — joins candidate views (one per registered
--    verdict type) with review state for the current operator.
--
--    Default filtering semantics (applied by API / frontend):
--      - Exclude snoozed_until >= current_date (hidden rows)
--      - Exclude rows where reviewed_at IS NOT NULL (unless "Show reviewed" is on)
--    The view itself returns ALL rows so the API can apply include_snoozed
--    and include_reviewed flags as needed.
--
--    sort_rank: oldest classifications first, then highest annual
--               revenue descending, then client name ascending.
-- ────────────────────────────────────────────────────────────────

create or replace view profit_weekly_review_items as
select
  -- identity
  candidate.classification_id,
  candidate.verdict_code,
  candidate.verdict_code                                   as item_type,
  candidate.anchor_relationship_id,
  candidate.fc_client_id,

  -- display
  candidate.client_name,
  candidate.service_name,
  candidate.invoice_state,
  candidate.age_days,
  candidate.estimated_annual_revenue,
  candidate.action_url,

  -- review state (null when no state row exists yet)
  state.reviewed_at,
  state.snoozed_until,
  coalesce(state.operator_id, 'orlando')                   as operator_id,
  state.practice_id,

  -- sort handle: oldest first → highest revenue → client name asc
  row_number() over (
    order by
      candidate.age_days              desc nulls last,
      candidate.estimated_annual_revenue desc nulls last,
      candidate.client_name           asc  nulls last
  )::integer                                               as sort_rank

from profit_manual_invoice_pending_candidates candidate

-- restrict to verdicts registered in the visible-verdicts registry
inner join profit_weekly_review_visible_verdicts visible
  on visible.verdict_code = candidate.verdict_code

-- left-join review state (only exists after operator interacts or classification is created)
left join profit_weekly_review_item_state state
  on state.classification_id = candidate.classification_id;
