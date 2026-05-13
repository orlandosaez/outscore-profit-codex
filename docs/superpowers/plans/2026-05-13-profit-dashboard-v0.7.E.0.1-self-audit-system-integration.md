# V0.7.E.0.1 — Self-audit system integration

**Sprint:** V0.7.E.0.1 (closes the V0.7.E.0 slice)
**Source request:** Orlando 2026-05-13 — "please schedule this to be in the system, not just your memory. this is an important audit that must be run in every data refresh cycle and the results should surface somewhere clearly."
**Predecessor:** V0.7.E.0 (migrations 040 / 040a / 040b / 040c) — `profit_data_quality_alerts` view live on production.
**Status:** Planned. Ready for Codex execution.

## Why

The self-audit view exists in Postgres. Without integration, the only thing
between a data-quality regression and the operator's weekly review queue is
**Claude remembering to query it manually**. Operator explicitly called this
fragile and asked for a system-level guarantee.

## What

Four deliverables (executable independently; T1 unblocks T2 and T3):

### T1. API endpoint — `GET /api/profit/admin/data-quality-alerts`

**Location:** `profit_api/app.py` (route) + `profit_api/services/data_quality_dashboard_service.py` (service) + `profit_api/supabase.py` (DB client — already exists).

**Behavior:**
- Query `profit_data_quality_alerts` via `SupabaseRestClient`.
- Return JSON list with all 11 columns from the view.
- Support `?severity=high` and `?category=<code>` filters via query params.
- Group / count summary endpoint: `GET /api/profit/admin/data-quality-alerts/summary` → `{ total, by_severity: {high, medium, low}, by_category: {fc_stale_record: N, ...} }`.

**Acceptance:**
- `curl $API_BASE/api/profit/admin/data-quality-alerts | jq '. | length'` returns current alert count (28 at time of writing).
- `?severity=high` filters as expected.

### T2. Admin UI page — `/profit/admin/data-quality`

**Location:** `app/frontend/src/routes/DataQuality.jsx` + add route in `app/frontend/src/App.jsx` (or wherever route table lives — match `PipelineRuns.jsx` precedent).

**Behavior:**
- Hits `GET /api/profit/admin/data-quality-alerts/summary` on load → renders severity totals at top.
- Hits `GET /api/profit/admin/data-quality-alerts` → renders rows grouped by `alert_category` (collapsible sections, high-severity expanded by default).
- Each row shows: `subject_name`, `description`, `action_url` (as clickable link), `detected_at`.
- "Refresh" button that re-fetches.
- Link from main admin nav (whatever pattern matches `/profit/admin/pipeline`).

**Acceptance:**
- Operator can open `/profit/admin/data-quality` and see all 28 current alerts grouped by category.
- High-severity sections (paid_anchor_invoice_not_cleared, parent_child_1040_false_positive, subscription_billing_gap, subscription_with_manual_service, fc_stale_record) open by default.
- Action URLs link out to Anchor / FC.

### T3. Top-level dashboard alert chip

**Location:** Wherever the main dashboard renders (top-of-page summary tiles). Search frontend for the existing "Weekly Review" or "SLA" tile component.

**Behavior:**
- Small chip / badge near the dashboard header: "⚠️ Self-audit: N high-severity findings" if `summary.by_severity.high > 0`. Green checkmark if 0.
- Click → navigates to `/profit/admin/data-quality`.

**Why this matters:** Operator should not need to navigate to a deep admin page to know if the audit found something. The chip is the system-level guarantee Orlando asked for.

**Acceptance:**
- Open dashboard → see chip with current high-severity count.
- Click chip → land on `/profit/admin/data-quality` with high-severity rows already expanded.

### T4. Pipeline post-step — workflow 26 audit logging

**Location:** `n8n/workflows/profit-26-pipeline-orchestration.json` — add new node after `Patch Pipeline Run Final Status` (the current final status update node).

**Behavior:**
- New HTTP node: `POST` to `$SUPABASE_URL/rest/v1/rpc/profit_record_audit_summary` (or direct SQL via PostgREST) that computes `count(*) filter (where severity='high')`, `count(*) filter (where severity='medium')`, and `array_agg(distinct alert_category) filter (where severity='high')` from `profit_data_quality_alerts`.
- Result merged into `profit_pipeline_runs.summary->>'audit'`.
- Set new column `audit_status` on `profit_pipeline_runs`: `'clean' | 'alerts' | 'critical'` based on severity counts.

**New supporting migration:** `supabase/sql/041_profit_pipeline_runs_audit_status.sql` adds `audit_status text` + `audit_summary jsonb` columns to `profit_pipeline_runs` and an `RPC profit_record_audit_summary(run_id uuid)` function that executes the audit query + updates the row.

**Acceptance:**
- After next pipeline run, `select pipeline_run_id, audit_status, summary->'audit' from profit_pipeline_runs order by started_at desc limit 1` shows `audit_status='alerts'` and a JSON summary with counts.
- Admin UI pipeline-runs page (existing) renders the audit chip per run row.

## Sequence + ownership

| Task | Tier | Estimate | Blocks |
|---|---|---|---|
| T1 API endpoint | Codex (Tier 1) | 30 min | T2, T3 |
| T2 Admin UI page | Codex (Tier 1) | 45 min | T3 |
| T3 Dashboard chip | Codex (Tier 1) | 20 min | — |
| T4 Pipeline post-step + 041 migration | Orchestrator-direct + Codex split (Tier 3 for SQL, Tier 1 for n8n JSON edit) | 30 min | — |

**Total wall time:** ~2 hours with overlap.

## Predeploy + ship discipline

- Migration 041: predeploy smoke gate (`scripts/predeploy_smoke.sh`) before live apply.
- Frontend builds: VITE_BASE_PATH=/profit/ + VITE_PROFIT_API_BASE=/profit/api must both be set at build time (per earlier white-page postmortem).
- Safe-deploy pattern: scp assets first, sha256 verify, atomic index.html swap last.
- Test pipeline-run audit post-step on a manual cron trigger before letting it run on the next 5 AM scheduled run.

## Out of scope (V0.7.E.0.2+ candidates)

- Slack / email alerting on high-severity new findings (push channel — currently this slice is pull-only).
- Hard gate: pipeline marks `status='failed'` if `audit_status='critical'`. Risky without operator tuning of the severity threshold first.
- Historical trend view (alert counts over time). Useful once we've accumulated ≥2 weeks of run-level audit_summary data.

## Memory update

Once T1–T4 land, update `~/.claude/projects/-Users-orlandosaez-agents-outscore-profit-cc/memory/self_audit_data_quality_alerts.md` to remove the "must run manually" discipline note and replace with "audit runs automatically every pipeline cycle; results visible at /profit/admin/data-quality and on top-of-dashboard chip."
