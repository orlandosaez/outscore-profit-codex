# Profit Dashboard V0.7.B.1 — Correctness & Trust Restoration

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking. **Quality discipline:** every code-writing task MUST verify against live production data, not just static SQL pattern tests, before commit. V0.7.B shipped two latent schema mismatch bugs (`effective_date::date`, `project.project_title`) that static tests missed — V0.7.B.1 closes that gap.

**Goal:** Restore correctness and operator trust in `/admin/weekly-review` and `/admin/sla` after V0.7.B's volume-driven exposure of pre-existing flaws.

**Architecture:** V0.7.B.1 is NOT a verdict-family addition. It is a correctness pass. No new verdicts, no schema growth (one minor migration `030b` for a SQL predicate fix). Three classes of change: (a) API contract fix (limit + total_count exposure), (b) SQL clearance predicate fix, (c) frontend truthfulness (hide misleading column, banner the known FC-sync gap on SLA dashboard). Ship template upgraded with deploy-time `psql --single-transaction` dry-run + volume smoke gate + Opus diff audit.

**Tech Stack:** Same as V0.7.B (Supabase Postgres, FastAPI, React/Vite). No new dependencies.

---

## V0.7.B.1 Context

V0.7.B shipped 2026-05-11 at commit `51f779b`. Live state post-deploy:

- 69 Weekly Review rows: 5 MANUAL_INVOICE_PENDING + 64 SLA_BREACHED
- API default `limit=50` truncates the last 14 rows in default view
- After operator interaction state (5 mark-reviewed/snoozed during initial review): `total_count=64`, default visible = 50, manual-invoice rows at sort_rank 65-69 invisible
- SLA dashboard shows sparse data on per-client columns + 90-day performance panel

UX audit by independent reviewer captured 19 findings in `coordination/ui-feedback-v0.7.md`. Decomposition rules:
- V0.7.B.1 = correctness + trust (this plan)
- V0.7.B.2 = visibility + action affordance design (separate plan, after B.1 lands)
- V0.7.B.3 = Dispute/Reclassify architecture (separate plan, after B.2 lands)
- V0.7.G = polish slice (after V0.7.D ships)

## Quality Principles (locked for this sprint)

1. **Live-data verification is mandatory.** Every SQL change runs `psql --single-transaction --dry-run` against live before commit. Every API change verified with live `curl` calls. Every frontend change verified with Vite build + smoke test of the deployed bundle.
2. **No "fix if cheap".** Task 1 fully diagnoses F18's root causes before deciding what to fix in B.1 vs document vs defer.
3. **Each fix verified end-to-end before next fix starts.** No batching of unverified changes.
4. **Pre-deploy gate template upgraded permanently.** Future verdict-family additions inherit the new gates (psql dry-run + volume smoke + Opus diff audit).
5. **Independent Opus audit between tasks.** After Tasks 2/3/4 commit, Opus reviewer pass before next task. Catches drift between plan intent and Codex output.

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-11-profit-dashboard-v0.7.A-manual-invoice-verdict-and-weekly-review.md` — V0.7.A pattern
- `docs/superpowers/plans/2026-05-11-profit-dashboard-v0.7.B-sla-breaches-as-verdicts.md` — V0.7.B locked plan
- `coordination/task-1-V0.7.B-data-profile.md` — V0.7.B Task 1 SLA profiling
- `coordination/ui-feedback-v0.7.md` — UX audit findings F1-F19
- `supabase/sql/030_profit_sla_breached_verdict.sql` — current apply function with the strict ILIKE
- `supabase/sql/030a_profit_weekly_review_sla_union.sql` — current queue view
- `profit_api/weekly_review.py` — current API with `DEFAULT_LIMIT=50`
- `app/frontend/src/routes/WeeklyReview.jsx` — current frontend with `age_days` column
- `app/frontend/src/routes/SlaDashboard.jsx` — current dashboard with sparse data

## In-Scope Findings (9 of 19)

| ID | Finding | Root cause (verified) | Task |
|---|---|---|---|
| F13 | Manual rows missing from queue | Pure consequence of F14 (limit=50 truncates sort_rank 65-69) | T2 |
| F14 | Silent ~50-row cap | API `DEFAULT_LIMIT=50` inherited from V0.7.A | T2 |
| F1 | Kodiak + Legacy Bids stuck breached | `project_title ILIKE '%service_name%'` too strict (`'1120 Plus'` doesn't match `'O 1120 Tax Return'`) | T3 |
| F2 | `age_days` always 0 | Resets on classification creation; documented tech-debt | T4 |
| F18 | SLA dashboard sparse | Mixed: pre-V0.6.D `tag_type='service'` gap + suspected V0.7.B-caused | T1 + T4 |

Out-of-scope for V0.7.B.1, deferred:
- F3 (1120 C/S target date conflation) — needs service-catalog `entity_type`; V0.7.D
- F4 (promote service_name to column) — visibility concern, V0.7.B.2
- F5 (Dispute/Reclassify) — architectural; V0.7.B.3
- F6, F8, F9, F10, F11, F12, F19 — polish; V0.7.G
- F7 (FC URL primary for SLA) — affordance design; V0.7.B.2
- F15 (Mark reviewed undo toast) — feedback design; V0.7.B.2
- F16 (Snooze confirmation toast) — feedback design; V0.7.B.2
- F17 (Show reviewed visual treatment) — affordance design; V0.7.B.2

## Migration Numbering

- `supabase/sql/030b_profit_sla_clearance_predicate_fix.sql` — single REPLACE FUNCTION for `profit_apply_classification_transitions` updating ONLY the two `project_title ILIKE` predicates to use `split_part(service_name, ' ', 1)`. Everything else preserved bit-for-bit.

## File Structure

- Create: `supabase/sql/030b_profit_sla_clearance_predicate_fix.sql`
- Modify: `profit_api/weekly_review.py` (DEFAULT_LIMIT 50→200; ensure total_count always exposed correctly)
- Modify: `app/frontend/src/routes/WeeklyReview.jsx` (hide age_days column; "Showing N of M" header with conditional Load More)
- Modify: `app/frontend/src/routes/SlaDashboard.jsx` (banner per Task 1 findings)
- Modify: `app/frontend/src/styles.css` (banner styling)
- Modify: `tests/test_fulfillment_classification_sql.py` (assertions for 030b predicate change)
- Modify: `tests/test_weekly_review_api.py` (DEFAULT_LIMIT=200 assertion + total_count assertions)
- Modify: `tests/test_profit_admin_frontend.py` (assertions for column hide + dashboard banner)
- Create: `scripts/predeploy_smoke.sh` — ship template upgrade (psql dry-run + volume smoke gate)
- Modify: `docs/data-contracts/weekly-review.md` (limit contract update)
- Modify: `docs/data-contracts/sla-dashboard.md` (banner contract)
- Modify: `docs/tech-debt.md` (V0.7.B.1 deferrals + ship template upgrade note)

---

## Task Breakdown

### Task 1: F18 Deep Diagnostic Profile

**Tier:** 3 (orchestrator-direct)

**Purpose:** Fully diagnose `/admin/sla` sparsity. Distinguish (a) pre-V0.6.D regressions from (b) V0.7.B-caused regressions. Output: a decision matrix for which gaps to fix-in-B.1, banner-in-B.1, or defer-to-V.0.7.D.

**Files:**

- Create: `coordination/task-1-V0.7.B.1-sla-dashboard-diagnostic.md`

**Steps:**

- [ ] **Step 1: Catalog each SLA dashboard panel's data source**

  For each panel:
  - per-client status (`profit_sla_client_status`)
  - per-staff workload (`profit_sla_staff_workload`)
  - 90-day performance (`profit_sla_staff_service_performance_90d`)
  - anchor backfill (`profit_sla_anchor_backfill_queue`)

  Run `select count(*), count(*) filter (where <key_field> is not null) ...` against live. Identify which fields are NULL/sparse vs which rows are missing entirely.

- [ ] **Step 2: Check view dependencies**

  Verify whether V0.7.B's migration 030 or 030a inadvertently dropped or replaced an SLA view. Compare `pg_get_viewdef` for each SLA view against the V0.6.D migration 028/028a source.

- [ ] **Step 3: 90-day performance investigation**

  `profit_sla_staff_service_performance_90d` returned 0 rows. Trace the view definition. Common causes: completion task filter using `is_completed = true` without OR `completed_at IS NOT NULL`, staff context filter excluding 'Unassigned' rows, date filter using wrong field.

- [ ] **Step 4: Per-client column emptiness**

  Operator audit reports TARGET SLA DATE, AGE DAYS, STAFF, WORKFLOW STATUS columns empty. The view has all those fields, but joins may return NULL. Compare to the V0.6.D operator screenshots in `coordination/ui-sprint-handoff.md` and confirm whether this is pre-existing or new.

- [ ] **Step 5: Decision matrix**

  For each sparse field, classify:
  - **FIX in B.1** (V0.7.B regression, cheap to repair)
  - **BANNER in B.1** (pre-existing V0.6.D gap; surface explicitly to operator; defer fix to V0.7.D)
  - **DEFER to V0.7.D** (structural, requires FC sync expansion)
  - **DEFER to V0.7.G** (polish; cosmetic)

- [ ] **Step 6: Write findings to `coordination/task-1-V0.7.B.1-sla-dashboard-diagnostic.md`**

  Self-contained doc with: methodology, queries run, raw counts, view diffs, decision matrix, recommended T4 banner copy.

- [ ] **Step 7: Surface diagnostic to Orlando**

  If FIX category is non-trivial OR new architectural questions surface, STOP and ask. Otherwise proceed to Task 2.

**Expected output:** Diagnostic doc. No commits. No code changes.

### Task 2: API Limit + Total Count Contract

**Tier:** 1 (Codex execution; Opus directive)

**Purpose:** Fix F13 (manual rows visible) and F14 (silent truncation) by raising `DEFAULT_LIMIT` to 200 and ensuring `total_count` is always accurately reported. Frontend in T4 surfaces "Showing N of M".

**Files:**

- Modify: `profit_api/weekly_review.py` (DEFAULT_LIMIT 50→200)
- Modify: `tests/test_weekly_review_api.py`

**Steps:**

- [ ] **Step 1: RED test — assert DEFAULT_LIMIT=200**

  Add tests:
  - `DEFAULT_LIMIT == 200`
  - List of 200 rows: default request returns 200 (not 50), `total_count=200`, `limit=200`
  - List of 250 rows: default request returns 200, `total_count=250`, `limit=200`
  - Explicit `?limit=50` still works (returns 50, total_count=250)
  - Explicit `?limit=300` clamps to 200 (returns 200, total_count=250)
  - Mixed verdict rows: confirm both MANUAL_INVOICE_PENDING and SLA_BREACHED present at default limit when total < 200

  Run: `python3 -m unittest tests.test_weekly_review_api`. Expected: FAIL.

- [ ] **Step 2: Change DEFAULT_LIMIT**

  In `profit_api/weekly_review.py`:
  ```python
  DEFAULT_LIMIT = 200  # raised from 50 in V0.7.B.1 after volume-jump in V0.7.B
  ```
  `MAX_LIMIT` stays 200.

- [ ] **Step 3: Verify total_count semantics**

  Read the current `list_items` implementation. Confirm `total_count = len(filtered)` (after reviewed/snoozed/verdict_code filters, before limit/offset). This is correct semantics for "Showing N of M".

- [ ] **Step 4: GREEN**

  Run `python3 -m unittest discover -s tests`. Expected: full suite passes.

- [ ] **Step 5: Live verification BEFORE commit**

  Commit a temporary local test against the running production API:
  ```bash
  curl -sS "http://104.225.220.36/profit/api/profit/admin/weekly-review/items?limit=200" | python3 -c "..."
  ```
  Wait — the API isn't deployed yet. Skip this step until Task 6. Note in commit message that live verification happens at deploy.

- [ ] **Step 6: Commit**

  Commit message:
  ```
  fix: raise weekly review API DEFAULT_LIMIT to 200 (V0.7.B.1 Task 2)

  V0.7.A inherited DEFAULT_LIMIT=50 which silently truncated 14 rows of
  V0.7.B's 69-row queue, hiding all 5 V0.7.A manual-invoice rows at
  sort_rank 65-69. Raise to MAX_LIMIT (200) since the queue is operator-
  triaged, not paginated. total_count semantics unchanged. Future verdict
  family additions that push queue >200 will need true pagination (V0.7.D
  expanded scope captures this).
  ```

### Task 3: SLA Clearance Predicate Fix

**Tier:** 1 (Codex execution; Opus directive)

**Purpose:** Fix F1 by relaxing the `project_title ILIKE '%service_name%'` predicate to match on the first token of `service_name` (e.g. `'1120 Plus'` → `%1120%`). After deploy, run apply_transitions live to clear all currently-stuck completed work.

**Files:**

- Create: `supabase/sql/030b_profit_sla_clearance_predicate_fix.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`

**Background:** Migration 030's `sla_task_complete` and `sla_project_archived` branches use `project_title ILIKE '%' || service_name || '%'` as the fallback when the `tag_type='service'` bridge is missing (Task 1 found zero such rows; V0.7.D will fix). The predicate is too strict — service_name like `'1120 Plus'` doesn't appear in FC project titles like `'O 1120 Tax Return'`.

**Steps:**

- [ ] **Step 1: RED test**

  Add tests asserting that migration 030b:
  - Exists
  - Does `CREATE OR REPLACE FUNCTION profit_apply_classification_transitions(...)`
  - The replaced function uses `split_part(<service_name>, ' ', 1)` in the project_title ILIKE predicates
  - Preserves all V0.7.B + V0.7.A + V0.6.C.a signal names (manual_invoice_*, sla_*, active_agreement_appears, first_matching_anchor_invoice_*, cash_collected_*)
  - Does NOT introduce new transition rules or candidate views
  - Maintains the no-op resolution pattern (clearance branches use `null::text as to_verdict_code`)

  Run: `python3 -m unittest tests.test_fulfillment_classification_sql`. Expected: FAIL on 030b missing.

- [ ] **Step 2: Write migration 030b**

  Copy migration 030's `profit_apply_classification_transitions` function definition verbatim. Modify ONLY these two predicates (in `sla_task_complete_signals` and `sla_project_archived_signals` CTEs):

  ```sql
  -- BEFORE (V0.7.B):
  or task.project_title ilike '%' || current_classifications.service_name || '%'

  -- AFTER (V0.7.B.1):
  or task.project_title ilike '%' || split_part(current_classifications.service_name, ' ', 1) || '%'
  ```

  And similarly:

  ```sql
  -- BEFORE:
  or project.title ilike '%' || current_classifications.service_name || '%'

  -- AFTER:
  or project.title ilike '%' || split_part(current_classifications.service_name, ' ', 1) || '%'
  ```

  Add comment header documenting the change rationale and a reference to V0.7.B.1 plan.

- [ ] **Step 3: GREEN**

  Run `python3 -m unittest discover -s tests`. Expected: full suite passes.

- [ ] **Step 4: Live psql dry-run (NEW QUALITY GATE)**

  Before commit:
  ```bash
  scp -P 2222 supabase/sql/030b_profit_sla_clearance_predicate_fix.sql root@104.225.220.36:/tmp/
  ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a;
    psql "$SUPABASE_DB_URL" -P pager=off -v ON_ERROR_STOP=1 --single-transaction \
      -c "BEGIN;" \
      -f /tmp/030b_profit_sla_clearance_predicate_fix.sql \
      -c "ROLLBACK;"'
  ```

  Expected: zero errors. If schema mismatch surfaces, fix locally and re-run before commit. This gate catches the V0.7.A/V0.7.B class of bugs (`effective_date::date`, `project.project_title`) at TEST time, not deploy time.

- [ ] **Step 5: Commit**

  Commit message:
  ```
  fix: relax SLA clearance ILIKE to match first service_name token (V0.7.B.1 Task 3)

  V0.7.B's sla_task_complete and sla_project_archived clearance branches
  used `project_title ILIKE '%' || service_name || '%'`, requiring the
  full service_name (e.g. '1120 Plus') to appear in FC project titles
  (e.g. 'O 1120 Tax Return'). Kodiak Enterprises LLC and Legacy Bids LLC
  both have completed FC tasks (2026-04-30) but stayed in SLA_BREACHED
  state because the strict ILIKE never matched. Switch to split_part(
  service_name, ' ', 1) which matches the form prefix. Verified via psql
  dry-run; live apply_transitions rerun at Task 6 deploy.
  ```

### Task 4: Frontend Truthfulness (age_days column + SLA banner)

**Tier:** 2 (CC subagent execution; Opus directive)

**Purpose:** Hide the misleading `age_days` column from Weekly Review (F2). Add an honest banner to `/admin/sla` explaining the FC-sync data gap per Task 1's diagnostic findings (F18).

**Files:**

- Modify: `app/frontend/src/routes/WeeklyReview.jsx`
- Modify: `app/frontend/src/routes/SlaDashboard.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

**Steps:**

- [ ] **Step 1: RED tests**

  - `WeeklyReview.jsx` no longer contains `<th>Age (days)</th>` (or matching markup)
  - `WeeklyReview.jsx` no longer renders `row.age_days` in a table cell (it can still be in the payload, just not displayed)
  - `SlaDashboard.jsx` contains a banner element with `className="sla-data-gap-banner"` (or similar)
  - Banner text mentions `V0.7.D` and `FC sync` (the specific copy per Task 1's recommended language)
  - `styles.css` contains `/* === V0.7.B.1: SLA data gap banner === */`

- [ ] **Step 2: Implement age_days removal**

  In `WeeklyReview.jsx`:
  - Remove the `<th>Age (days)</th>` header
  - Remove the `<td>{textValue(row.age_days)}</td>` cell
  - Update colSpan on `<EmptyRow>` from 8 to 7
  - For SLA rows in the Details cell, `breach_age_days` is already shown as "X days overdue" — keep that
  - For manual-invoice rows, no age info shown — document in tech-debt that `agreement_age_days` (per V0.7.A note) is the right replacement for V0.7.D

- [ ] **Step 3: Implement SLA banner**

  In `SlaDashboard.jsx`:
  - Add a banner element above the panels, conditionally rendered when data is sparse OR always (per Task 1 decision)
  - Banner copy from Task 1's recommended language (something like: "Some staff routing and workflow status fields show as unassigned/empty. This is a known FC sync data gap scheduled for V0.7.D. The analytics shown reflect available data only.")
  - Add a link to `/admin/weekly-review` (already present per V0.7.B Task 6; verify)

- [ ] **Step 4: Scoped CSS**

  Append to `styles.css`:
  ```css
  /* === V0.7.B.1: SLA data gap banner === */
  .sla-data-gap-banner {
    /* warning amber */
    ...
  }
  ```

- [ ] **Step 5: GREEN tests + Vite build**

  ```bash
  python3 -m unittest discover -s tests
  cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
  ```

  Expected: full test suite passes; Vite build green; no console warnings.

- [ ] **Step 6: Commit**

  Commit message:
  ```
  fix: hide misleading age_days column + add SLA data-gap banner (V0.7.B.1 Task 4)

  Weekly Review: remove age_days column. age_days resets to 0 on
  classification creation (V0.7.A tech-debt), so the column was 0 on every
  row. SLA rows still show 'X days overdue' via breach_age_days in the
  Details cell. V0.7.D will reintroduce a truthful agreement_age_days field.

  SLA Dashboard: add amber banner explaining that staff routing + workflow
  status fields show empty because of the known FC sync gap (zero
  tag_type='service' rows on profit_fc_project_tags + zero tag_type='staff'
  rows on profit_fc_client_tags). Deferred to V0.7.D per scope expansion.
  ```

### Task 5: Ship Template Upgrade (Pre-Deploy Quality Gates)

**Tier:** 3 (orchestrator-direct)

**Purpose:** Permanent improvement to deploy template. After V0.7.A and V0.7.B both shipped with deploy-time SQL bugs caught only at `psql -f` time, codify a pre-deploy gate that catches schema drift and queue-volume issues in test, not production.

**Files:**

- Create: `scripts/predeploy_smoke.sh`
- Modify: `coordination/decisions.md` (record the gate)
- Modify: `docs/tech-debt.md` (resolve the open "deploy-time psql --dry-run" item from V0.7.B)

**Steps:**

- [ ] **Step 1: Write `scripts/predeploy_smoke.sh`**

  Script behavior:
  ```bash
  #!/usr/bin/env bash
  # Pre-deploy smoke gate for profit migrations + queue volume.
  # Usage: ./scripts/predeploy_smoke.sh <migration_file_1> [migration_file_2 ...]
  # Each migration is applied inside BEGIN/ROLLBACK against live Supabase.
  # Errors halt; success means migrations are safe to apply.
  # Then runs queue-volume check against live profit_weekly_review_items.

  set -euo pipefail

  for migration in "$@"; do
    echo "=== psql dry-run: $migration ==="
    scp -P 2222 "$migration" root@104.225.220.36:/tmp/
    basename_only=$(basename "$migration")
    ssh -p 2222 root@104.225.220.36 \
      "set -a; . /opt/agents/outscore_profit/.env; set +a; \
       psql \"\$SUPABASE_DB_URL\" -P pager=off -v ON_ERROR_STOP=1 --single-transaction \
         -c 'BEGIN;' \
         -f /tmp/$basename_only \
         -c 'ROLLBACK;'"
    echo "PASS: $migration"
  done

  echo "=== queue volume smoke ==="
  ssh -p 2222 root@104.225.220.36 \
    "set -a; . /opt/agents/outscore_profit/.env; set +a; \
     psql \"\$SUPABASE_DB_URL\" -P pager=off \
       -c 'select count(*) as queue_rows from profit_weekly_review_items;' \
       -c 'select verdict_code, count(*) from profit_weekly_review_items group by verdict_code order by verdict_code;'"

  echo "=== predeploy smoke complete ==="
  ```

  Make executable: `chmod +x scripts/predeploy_smoke.sh`.

- [ ] **Step 2: Update `coordination/decisions.md`**

  Add entry:
  ```
  ## 2026-05-11: Pre-deploy smoke gate (V0.7.B.1 Task 5)

  After V0.7.A (effective_date::date) and V0.7.B (project.project_title)
  both shipped with deploy-time schema mismatch bugs that static SQL
  pattern tests missed, the deploy template is upgraded with two
  mandatory pre-deploy gates:

  1. `scripts/predeploy_smoke.sh <migration1> [migration2 ...]` runs each
     migration inside BEGIN/ROLLBACK against live Supabase. Schema
     mismatches surface at gate time, not deploy time.

  2. Same script runs `select count(*) from profit_weekly_review_items`
     after each verdict-family addition. Compare projected queue size to
     API DEFAULT_LIMIT (currently 200). If queue >= DEFAULT_LIMIT, the
     deploy must either raise the limit, implement pagination, or document
     the truncation contract.

  All future Task 8 deploy steps must run this script before applying
  migrations. Failure to run is a coordination-protocol violation.
  ```

- [ ] **Step 3: Update `docs/tech-debt.md`**

  Resolve the V0.7.B "deploy-time psql --dry-run" tech-debt entry with strikethrough + RESOLVED note pointing to the new script.

- [ ] **Step 4: Test the script against current state**

  Run:
  ```bash
  ./scripts/predeploy_smoke.sh supabase/sql/030b_profit_sla_clearance_predicate_fix.sql
  ```
  Expected: PASS for 030b. Queue smoke shows 69 rows (or post-T3-applied count).

- [ ] **Step 5: Commit**

  Commit message:
  ```
  chore: add predeploy smoke gate script (V0.7.B.1 Task 5)

  Codify pre-deploy verification template after V0.7.A and V0.7.B both
  shipped with schema mismatch bugs caught at psql apply time. Script
  applies each queued migration inside BEGIN/ROLLBACK, then queries live
  queue size to flag DEFAULT_LIMIT/pagination drift. Coordination
  decisions.md updated; tech-debt entry resolved.
  ```

### Task 6: Deploy with Upgraded Ship Template + Live Verification

**Tier:** 3 (orchestrator-direct)

**Purpose:** Apply 030b live, scp updated backend + frontend, restart service. **All five fixes must be live-verified before ship commit.**

**Steps:**

- [ ] **Step 1: Run upgraded pre-deploy smoke gate**

  ```bash
  ./scripts/predeploy_smoke.sh supabase/sql/030b_profit_sla_clearance_predicate_fix.sql
  ```
  Expected: PASS. If anything fails here, STOP and fix.

- [ ] **Step 2: Apply 030b live**

  ```bash
  ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; \
    psql "$SUPABASE_DB_URL" -P pager=off -v ON_ERROR_STOP=1 \
      -f /tmp/030b_profit_sla_clearance_predicate_fix.sql'
  ```

- [ ] **Step 3: Rerun apply_transitions live**

  ```bash
  ssh -p 2222 root@104.225.220.36 'set -a; . /opt/agents/outscore_profit/.env; set +a; \
    psql "$SUPABASE_DB_URL" -P pager=off \
      -c "select signal_name, count(*) from profit_apply_classification_transitions(now(), false) group by signal_name order by signal_name;"'
  ```

  Expected: non-zero `sla_task_complete` (or `sla_project_archived`) counts. These represent classifications that NOW clear due to the relaxed ILIKE. Kodiak Enterprises LLC and Legacy Bids LLC should be among them. Verify:
  ```bash
  ssh -p 2222 root@104.225.220.36 '... psql ... -c "select fc_client_name, service_name, verdict_code, superseded_at from profit_classifications where fc_client_name ilike '\''%Kodiak%'\'' or fc_client_name ilike '\''%Legacy Bids%'\'' order by classified_at desc;"'
  ```

- [ ] **Step 4: Deploy backend**

  ```bash
  scp -P 2222 profit_api/weekly_review.py root@104.225.220.36:/opt/agents/outscore_profit/profit_api/
  ssh -p 2222 root@104.225.220.36 'systemctl restart profit-admin-api.service && sleep 2 && systemctl is-active profit-admin-api.service'
  ```

- [ ] **Step 5: Live API verification (F13/F14)**

  ```bash
  ssh -p 2222 root@104.225.220.36 'curl -sS "http://127.0.0.1:8010/api/profit/admin/weekly-review/items" | python3 -c "import sys,json;p=json.load(sys.stdin);print(f\"total={p[\"total_count\"]} returned={len(p[\"rows\"])} limit={p[\"limit\"]}\")"'
  ```

  Expected: `limit=200`, returned matches `total_count` (no silent truncation). Both verdict codes present.

- [ ] **Step 6: Build frontend + deploy**

  ```bash
  cd app/frontend && VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
  scp -P 2222 -r dist/* root@104.225.220.36:/opt/agents/outscore_profit/frontend/dist/
  ```

- [ ] **Step 7: Live frontend verification (F2, F18)**

  Operator opens `/admin/weekly-review`: no Age (days) column visible.
  Operator opens `/admin/sla`: banner present, copy honest, link to Weekly Review present.
  (Document expected operator-visible behavior in ship commit; Orlando confirms after deploy.)

- [ ] **Step 8: Ship commit**

  Commit message:
  ```
  Ship V0.7.B.1 correctness + trust restoration

  Deploy executed end-to-end with new ship template:
  - Pre-deploy smoke gate PASS (psql dry-run + queue volume check)
  - Migration 030b applied; apply_transitions rerun live; N classifications
    cleared (including Kodiak + Legacy Bids confirmed)
  - profit_api/weekly_review.py DEFAULT_LIMIT=200 deployed
  - Frontend bundle with age_days column hidden + SLA data-gap banner deployed
  - Live API smoke: total_count = returned (no truncation)

  Fixes: F1 (SLA clearance), F2 (age_days column), F13+F14 (API limit),
  F18 (SLA dashboard banner).

  Out of scope per 3-slice decomposition: F3 → V0.7.D, F4/F7/F15/F16/F17
  → V0.7.B.2, F5 → V0.7.B.3, F6/F8-F12/F19 → V0.7.G.

  Ship template upgrade is permanent: scripts/predeploy_smoke.sh now
  mandatory before any migration applies.
  ```

- [ ] **Step 9: Update STATE.md + runlog**

  STATE.md: V0.7.B.1 SHIPPED; current sprint = V0.7.B.2 plan-draft (or held pending Orlando).
  runlog.md: Append all V0.7.B.1 turns.

- [ ] **Step 10: Independent Opus audit post-deploy**

  Spawn an Opus reviewer agent to compare:
  - V0.7.B.1 plan intent vs commits landed
  - Operator audit findings F1, F2, F13, F14, F18 → fix status (fixed / banner / deferred)
  - Any new regressions in 297-test suite (now ~340 tests)

  Reviewer reports any drift. STATE.md updated based on findings.

## Task Count, Estimate, Tier Mix

- 6 tasks total
- ~0.5 day estimated (1 T3 diagnostic + 1 T1 API + 1 T1 SQL + 1 T2 frontend + 1 T3 ship template + 1 T3 deploy)
- Tier breakdown: 4× Tier 3, 1× Tier 1 (or 2 if T2/T3 split), 1× Tier 2

## Out-of-Scope Items Intentionally Not Added

- F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F15, F16, F17, F19 (per 3-slice decomposition)
- Any new verdict family
- Any change to V0.7.A or V0.7.B contracts beyond DEFAULT_LIMIT + SLA clearance ILIKE
- Frontend test framework (Vitest/Playwright) — deferred to V0.7.B.2
- Push to origin — separate orchestrator decision after V0.7.B.1 ships

## Carry-Forward Items Addressed

- F13/F14: silent truncation → fixed (API limit raised, total_count exposed)
- F1: stuck classifications → fixed (SQL predicate relaxed)
- F2: misleading column → hidden
- F18: sparse SLA dashboard → diagnosed (T1) + bannered (T4)
- Schema drift caught at deploy time → systemic fix (T5)
- Volume vs API limit drift → systemic fix (T5)

## Self-Review Checklist

Before declaring V0.7.B.1 shipped:

- [ ] All 6 tasks committed
- [ ] Pre-deploy smoke gate passed for 030b
- [ ] Live `apply_transitions` cleared Kodiak + Legacy Bids
- [ ] Live API smoke: `?limit=200` returns 69+ rows with both verdict codes
- [ ] Operator confirms /admin/weekly-review no longer shows Age (days) column
- [ ] Operator confirms /admin/sla shows banner
- [ ] Independent Opus audit returns APPROVE
- [ ] STATE.md + runlog updated
- [ ] Tech-debt.md updated (V0.7.B "psql --dry-run" item resolved + V0.7.B.1 deferrals listed)
