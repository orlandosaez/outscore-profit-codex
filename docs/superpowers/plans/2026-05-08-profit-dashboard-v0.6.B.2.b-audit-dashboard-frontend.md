# Profit Dashboard V0.6.B.2.b Audit Dashboard Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the V0.6.B.2.b fulfillment audit dashboard at `/profit/admin/audit`, backed by `profit_api` endpoints that read the B.2.a audit views and append new `profit_classifications` rows through a bulk-classify workflow.

**Architecture:** This is a frontend/API slice only. The React route reads verdict metadata and audit rows from FastAPI, renders the default-visible audit queue from B.2.a views, supports row selection and bulk classification, and opens a composite detail panel for evidence review. The API preserves the append-friendly `profit_classifications` invariant by inserting new classification rows and superseding prior active rows through service-side rollback, without adding SQL migrations or views.

**Tech Stack:** React 19, Vite 6, React Router, lucide-react, custom CSS, FastAPI, Pydantic, existing Supabase REST client, Python static/API `pytest`, `npm run build`, existing VPS deploy script and curl spot-check pattern.

---

## Authoritative Inputs

- `docs/superpowers/plans/2026-05-06-profit-dashboard-v0.6-spec.md`: V0.6.B Audit Dashboard Spec, especially route, controls, columns, detail panel, and bulk classification primitive.
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.a-audit-query-refactor.md`: B.2.a backend plan and deployed view/function contracts.
- `docs/data-contracts/fulfillment-classifications.md`: append-friendly classification invariant, audit helper views, re-emergence scan v2, and apply-transition narrow scope.
- `docs/tech-debt.md`: UI-relevant caveats around unsynced active reissued agreements, Workflow 25 demotion, QBO/category gaps, and unresolved service aliases.
- `app/frontend/src/routes/ManualRecognition.jsx`: closest UI precedent for raw fetch, refetch, filters, side panel, disabled apply gating, toast/error feedback, and batch action rhythm.
- `profit_api/manual_recognition.py` and `profit_api/app.py`: closest API precedent for service module shape, validation, rollback, `create_app` injection, route registration, and 422 mapping.
- Deployed B.2.a data sources:
  - `profit_fulfillment_audit_candidates`
  - `profit_fulfillment_audit_fc_activity`
  - `profit_fulfillment_audit_anchor_signals`
  - `profit_fulfillment_audit_group_signals`
  - `profit_fulfillment_audit_qbo_category_gaps`
  - `profit_classification_verdicts`
  - `profit_classifications`
  - `profit_classification_transition_rules`
  - `profit_fc_task_delivery_classification`

## Gate Decisions Locked Into This Plan

### G1: Frontend Stack And Admin Shell

- Add `AuditDashboard.jsx` as a sibling route to `ManualRecognition.jsx`.
- Register one route in `app/frontend/src/App.jsx`: `/admin/audit`.
- Add one nav item in `app/frontend/src/components/PortalNav.jsx`: `Audit`.
- Reuse custom CSS and existing global utilities. Do not add a component library.
- Test coverage is Python static assertions in `tests/test_profit_admin_frontend.py`, plus `npm run build`, deploy, curl, and Orlando browser spot-check.
- Zero new npm dependencies or devDependencies.
- Reuse existing Nginx basic auth. Do not add React-side permission logic.

### G2: API Surface And Data-Fetching Pattern

- Add `profit_api/audit.py` with `AuditDashboardService`.
- Add `audit_service: AuditDashboardService | None = None` injection to `create_app`.
- Register six endpoints under the existing `/api/profit/admin/audit/*` path scheme:
  - `GET /api/profit/admin/audit/verdicts`
  - `GET /api/profit/admin/audit/filter-options`
  - `GET /api/profit/admin/audit/candidates`
  - `GET /api/profit/admin/audit/candidates/{fc_client_id}`
  - `POST /api/profit/admin/audit/classifications`
  - `GET /api/profit/admin/audit/qbo-category-gaps`
- List endpoints use `limit` clamp `1..200`, default `100`, and `offset >= 0`.
- Candidate filtering fetches the B.2.a candidate view and filters staff/service tags in Python using `profit_fc_client_tags`; do not add SQL columns or views.
- Frontend uses route-local `fetch` calls through `VITE_PROFIT_API_BASE`, matching Manual Recognition.

### G3: Bulk Classify

- Use one bulk POST endpoint with a client-generated UUID `request_id`.
- Request body:

```json
{
  "request_id": "00000000-0000-0000-0000-000000000000",
  "classified_by": "orlando",
  "rows": [
    {
      "fc_client_id": 123,
      "classification_id_to_supersede": null,
      "new_verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
      "re_evaluate_at": null,
      "notes": ""
    }
  ]
}
```

- Idempotency key:
  - `source_audit_file = 'manual:/profit/admin/audit'`
  - `source_audit_row_hash = 'manual:<request_id>:<fc_client_id>'`
- Store notes as `[req:<request_id>] <operator notes>`.
- UI strips the `[req:...]` prefix when rendering classification history.
- Validate `request_id` as a UUID.
- Reject empty row arrays and row arrays longer than `200` before database reads.
- Required notes rule reads `profit_classification_verdicts.category`; notes are required when category is `mixed`, `leak`, or `manual_review`.
- Optimistic-concurrency rule:
  - If client sends `classification_id_to_supersede = X` and current active classification is `X`, proceed.
  - If client sends `classification_id_to_supersede = X` and current active classification differs, return `409`.
  - If client sends `classification_id_to_supersede = null` and no active classification exists, first-classify.
  - If client sends `classification_id_to_supersede = null` and an active classification exists, return `409`.
- Use all-or-nothing service-side rollback matching Manual Recognition. True SQL transaction/RPC is out of scope and becomes tech debt.
- POST response is minimal:

```json
{
  "request_id": "00000000-0000-0000-0000-000000000000",
  "applied_count": 1,
  "rows": [
    {
      "classification_id": 56,
      "fc_client_id": 123,
      "verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW"
    }
  ]
}
```

- Frontend refetches candidates after success and clears all selection state.
- Frontend preserves selection after failure.

### G4: Unclassified Rows And NULL Verdicts

- Magic filter sentinel is exactly `__UNCLASSIFIED__`.
- `GET /candidates?verdict_code=__UNCLASSIFIED__` maps to `current_verdict_code is null`.
- Verdict filter options:
  - `{ value: "", label: "All" }`
  - `{ value: "__UNCLASSIFIED__", label: "Unclassified" }`
  - one option per `/verdicts` row, using `verdict_code`.
- If `verdict_code` query param is neither empty, `__UNCLASSIFIED__`, nor a real verdict code, return structured `422`.
- UI renders NULL current verdict as muted `Unclassified`.
- Unknown non-null verdict codes render raw code plus `Unknown verdict`.
- Detail panel renders `No prior classifications` when history is empty.
- First-classification path uses `classification_id_to_supersede: null`.
- Show-all and verdict matrix is the canonical filter test surface:

| Filter | Expected 2026-05-08 Live Count |
| --- | ---: |
| no verdict, `show_all=false` | 123 |
| no verdict, `show_all=true` | 137 |
| `__UNCLASSIFIED__`, `show_all=false` | 84 |
| `__UNCLASSIFIED__`, `show_all=true` | 84 |
| `MIXED`, `show_all=false` | 2 |
| `MIXED`, `show_all=true` | 2 |
| `INTERNAL_FAMILY`, `show_all=false` | 0 |
| `INTERNAL_FAMILY`, `show_all=true` | 6 |

If counts drift at deploy time, re-baseline with live evidence if data shifted; halt if implementation is wrong.

### G5: Detail Panel And Query Economy

- Detail endpoint is one composite API call:
  - `candidate`
  - `fc_activity`
  - `anchor_signals`
  - `group_signals`
  - `classification_history`
  - `classification_history_total_count`
  - `classification_history_truncated`
  - `transition_rules`
  - `recent_service_tasks`
- Cap `classification_history` at 100 most recent rows, include total count and truncation flag.
- Cap `recent_service_tasks` at 20.
- `transition_rules` rows carry:
  - `from_verdict_code`
  - `signal_name`
  - `to_verdict_code`
  - `enabled`
  - `signal_present`
  - `auto_apply_enabled_in_b2a`
  - `signal_reason`
- Signal-present derivation:
  - `active_agreement_appears`: true iff `anchor_signals.anchor_display_status = 'active'`.
  - `first_matching_anchor_invoice_mid_cycle`: true iff `anchor_signals.has_anchor_invoice_365d = true`; false reason `no Anchor invoice in last 365 days.`
  - `first_matching_anchor_invoice_group_billed`: true iff Anchor invoice exists and `group_signals.has_active_group_membership = true`; false reason names the missing leg.
  - `cash_collected_group_parent` and `cash_collected_standalone_mid_cycle`: false; reason `cash collection signal requires V0.6.C pipeline data.`
  - `anchor_backfill_invoice_*`: false; reason `V0.6.C pipeline scope.`
  - `any_active_signal_returns`: true iff `candidate.any_active_signal = true`.
- `auto_apply_enabled_in_b2a = true` only for `active_agreement_appears` from `PENDING_ENGAGEMENT_DRAFT` or `PENDING_ENGAGEMENT_SENT`.
- `signal_reason` is `null` when `signal_present = true`; it is populated with human-readable text only when `signal_present = false`.
- Detail endpoint errors:
  - Unknown `fc_client_id`: `404`.
  - Client exists but is absent from audit candidate surface: `404` with message `Client exists but is not in the audit candidate surface.`
- No new SQL migrations or views.

### G6: Manual Recognition UX Precedent

- Reuse Manual Recognition's raw fetch, route-local state, loading/error/toast, filters, side panel, disabled apply, Escape-to-close, and refetch-after-mutation rhythm.
- Deviate only where audit workflow needs it:
  - Table-level row checkboxes.
  - API-sourced verdict map.
  - Structured `422` and `409` parsing.
  - Richer detail evidence.
- Detail panel uses collapsible vertical sections, not tabs.
- Default-open sections: candidate summary, anchor signals, transition rules.
- Default-collapsed sections: classification history, recent service tasks.
- Use native `<details>/<summary>` or tiny custom state; zero new packages.
- Add `parseApiError(response, body)` helper returning:

```js
{
  status: 409,
  message: "Row updated since you loaded it. Refresh and retry.",
  field: undefined,
  row_index: 0,
  fc_client_id: 123,
  current_classification_id: 55,
  current_verdict_code: "MIXED",
  kind: "conflict"
}
```

- New CSS classes specific to this slice use `audit-` prefix. Reuse existing utility classes where possible and append new CSS at the bottom of `styles.css`.

## Scope

In scope:

- React route `/profit/admin/audit`.
- Audit nav link.
- FastAPI audit endpoints listed in G2.
- AuditDashboard service module.
- Candidate filters: show all, verdict, staff, service tag, group, re-evaluation due, free-text search.
- Table with row checkboxes and default-visible queue behavior.
- Bulk classify panel with verdict dropdown, optional `re_evaluate_at`, notes validation, and apply button.
- Detail panel with collapsible sections and composite payload.
- QBO/category diagnostic endpoint and side panel.
- Static frontend tests, API service/route tests, `npm run build`, deploy, curl spot-checks, and browser handoff.
- Data-contract updates for audit-dashboard API conventions.
- Tech-debt updates for service-side rollback, multi-user/concurrency limits, and possible detail-task enrichment performance.

Out of scope:

- New SQL migrations or views.
- Workflow JSON changes.
- V0.6.C pipeline orchestration, Workflow 26, cron, or pipeline run tables.
- V0.6.D SLA dashboard.
- Manual alias seeding from `docs/audits/2026-05-07-unresolved-service-names.csv`.
- New npm dependencies.
- Auth or permission changes.
- True SQL transaction/RPC for bulk classify.
- Optimistic UI updates across multi-user concurrency.
- Load-more UI for classification history beyond the 100-row cap.

## Deploy Checkpoints

Stop after every deploy checkpoint and wait for orchestrator approval.

1. **Route shell checkpoint**
   - Static frontend test green.
   - `npm run build` green.
   - Deploy app.
   - URL handoff: `https://app.outscore.com/profit/admin/audit`.
   - Orlando browser spot-check: nav link visible, page shell renders.

2. **Verdicts endpoint checkpoint**
   - API tests green.
   - Deploy API.
   - Curl `/api/profit/admin/audit/verdicts`; report 14 rows and sample categories.

3. **Candidates/filter-options checkpoint**
   - API tests green.
   - Deploy API.
   - Curl `/filter-options`.
   - Curl the eight show-all/verdict matrix cases and report counts.

4. **Composite detail checkpoint**
   - API tests green.
   - Deploy API.
   - Curl detail endpoint for Joy Property Management LLC, LTI Associates Inc, and Schmidli Enterprises LLC.
   - Report seven-key payload shape, history counts, and transition-rule signal flags.

5. **Bulk classify checkpoint**
   - API tests green.
   - Deploy API.
   - Step 5a performs validation-only curls: empty rows, oversize batch, invalid UUID, unknown verdict, missing required notes, and Schmidli stale-supersede `409`; no mutation happens before orchestrator approval.
   - Stop after Step 5a and wait for orchestrator approval.
   - Step 5b performs the first live mutation: first-classification regression for LTI Associates Inc using `BILLING_OUTSIDE_AUDIT_WINDOW`.
   - Refetch candidate and confirm current verdict populated after Step 5b.
   - Stop after Step 5b and wait for orchestrator approval.

6. **QBO diagnostics checkpoint**
   - API tests green.
   - Deploy API.
   - Curl `/qbo-category-gaps`; report row count and sample gap origins.

7. **Full dashboard checkpoint**
   - Static frontend tests green.
   - API tests green.
   - `npm run build` green.
   - Deploy app.
   - URL handoff with expected UI behavior: filters, table, bulk panel, detail panel, diagnostics panel, structured errors.
   - Orlando browser spot-check.

8. **Documentation/final verification checkpoint**
   - Targeted tests green.
   - Full pytest green.
   - `npm run build` green.
   - `git diff --name-only` exactly within B.2.b scope.
   - Final live curl summary.
   - Commit/push only after approval.

## Files

Create:

- `app/frontend/src/routes/AuditDashboard.jsx`: audit page, filters, table, bulk classify panel, detail panel, diagnostics panel, route-local fetch helpers, `parseApiError`, and note-prefix stripping helper.
- `profit_api/audit.py`: `AuditDashboardService`, request validation, filter handling, detail orchestration, bulk classify with rollback/idempotency, and diagnostic list methods.
- `tests/test_profit_api_audit.py`: FastAPI route and service behavior tests for audit endpoints.

Modify:

- `app/frontend/src/App.jsx`: import `AuditDashboard` and add `/admin/audit` route.
- `app/frontend/src/components/PortalNav.jsx`: add Audit nav item.
- `app/frontend/src/styles.css`: append `audit-` scoped styles only.
- `profit_api/app.py`: add Pydantic payloads, `AuditDashboardService` injection, and six route handlers.
- `tests/test_profit_admin_frontend.py`: static assertions for route, nav, endpoint strings, hard constraints, UI guards, `__UNCLASSIFIED__`, verdict API map, `parseApiError`, collapsible sections, note-prefix stripping, and selection clearing.
- `docs/data-contracts/fulfillment-classifications.md`: add Audit Dashboard API Conventions section.
- `docs/tech-debt.md`: add B.2.b carry-forward entries.

Do not modify:

- `supabase/sql/**`
- `n8n/workflows/**`
- `scripts/**`
- `docs/audits/2026-05-04-fulfillment-leaks-classification.csv`
- `docs/audits/2026-05-07-unresolved-service-names.csv`
- `package.json` / `package-lock.json` dependencies unless orchestrator approves a scope change.

## Tasks

### Task 1: Frontend Route Shell

**Files:**
- Create: `app/frontend/src/routes/AuditDashboard.jsx`
- Modify: `app/frontend/src/App.jsx`
- Modify: `app/frontend/src/components/PortalNav.jsx`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write failing static frontend test**

Add `test_audit_dashboard_route_shell_static_contract`:

```python
def test_audit_dashboard_route_shell_static_contract(self) -> None:
    app_source = (ROOT / "app/frontend/src/App.jsx").read_text(encoding="utf-8")
    nav_source = (ROOT / "app/frontend/src/components/PortalNav.jsx").read_text(encoding="utf-8")
    route_path = ROOT / "app/frontend/src/routes/AuditDashboard.jsx"

    self.assertTrue(route_path.exists())
    route_source = route_path.read_text(encoding="utf-8")
    source = app_source + "\n" + nav_source + "\n" + route_source

    self.assertIn("AuditDashboard", app_source)
    self.assertIn('/admin/audit', app_source)
    self.assertIn("Audit", nav_source)
    self.assertIn("Fulfillment Audit", route_source)
    self.assertIn("VITE_PROFIT_API_BASE", route_source)
    self.assertIn("/profit/admin/audit/candidates", route_source)
    self.assertIn("/profit/admin/audit/verdicts", route_source)
```

- [ ] **Step 2: Run red test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL because `AuditDashboard.jsx` does not exist and route/nav are not registered.

- [ ] **Step 3: Implement minimal route shell**

Create `AuditDashboard.jsx` with a page header, loading/error placeholders, and endpoint constants. Register route and nav link.

Route constants:

```js
const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const auditBase = `${apiBase}/profit/admin/audit`;
const candidatesEndpoint = `${auditBase}/candidates`;
const verdictsEndpoint = `${auditBase}/verdicts`;
```

- [ ] **Step 4: Run frontend static test and build**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: pytest and Vite build pass.

- [ ] **Step 5: Deploy and STOP**

Run:

```bash
scp -P 2222 -r app/frontend/dist root@104.225.220.36:/opt/agents/outscore_profit/frontend/
ssh -p 2222 root@104.225.220.36 "curl -k -I -s --resolve app.outscore.com:443:127.0.0.1 'https://app.outscore.com/profit/admin/audit' | head -n 8"
```

Expected: route returns Nginx auth response, not 404.

Stop and report deployed URL plus expected shell rendering.

### Task 2: Audit API Service Skeleton And Verdicts Endpoint

**Files:**
- Create: `profit_api/audit.py`
- Create: `tests/test_profit_api_audit.py`
- Modify: `profit_api/app.py`

- [ ] **Step 1: Write failing API tests**

Add tests with a fake store:

```python
def test_audit_verdicts_endpoint_returns_lookup_rows() -> None:
    service = AuditDashboardService(FakeStore({
        "profit_classification_verdicts": [
            {"verdict_code": "MIXED", "label": "Mixed", "category": "mixed", "default_visibility": "show"},
        ],
    }))
    app = create_app(service=FakeDashboardService(), manual_recognition_service=FakeRecognitionService(), audit_service=service)
    client = TestClient(app)

    response = client.get("/api/profit/admin/audit/verdicts")

    assert response.status_code == 200
    assert response.json()["rows"][0]["verdict_code"] == "MIXED"
```

Also assert `create_app` accepts `audit_service`.

- [ ] **Step 2: Run red API test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: FAIL because `profit_api.audit` and route wiring do not exist.

- [ ] **Step 3: Implement service skeleton and verdicts endpoint**

`AuditDashboardService.verdicts()` reads `profit_classification_verdicts`, ordered by category/label if the existing REST helper can express ordering; otherwise sort in Python by `category`, `label`, `verdict_code`.

Add route:

```python
@app.get("/api/profit/admin/audit/verdicts")
def audit_verdicts() -> dict[str, object]:
    return {"rows": audit_dashboard_service.verdicts()}
```

- [ ] **Step 4: Run focused API tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: PASS.

- [ ] **Step 5: Deploy API and STOP**

Run:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service && systemctl status profit-admin-api.service --no-pager"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/verdicts' | python3 -m json.tool | head -120"
```

Expected: JSON body with 14 verdict rows. Report row count and sample categories.

### Task 3: Candidates And Filter Options API

**Files:**
- Modify: `profit_api/audit.py`
- Modify: `profit_api/app.py`
- Modify: `tests/test_profit_api_audit.py`

- [ ] **Step 1: Write failing tests**

Cover:

- `GET /filter-options` returns `verdicts`, `staff`, `service_tags`, `groups`.
- `GET /candidates` clamps `limit` to `1..200`.
- `verdict_code=__UNCLASSIFIED__` returns NULL-verdict rows.
- Invalid `verdict_code` returns structured 422.
- `show_all=false` filters out hidden rows.
- Staff/service filters read `profit_fc_client_tags` and filter in Python.
- Candidate rows expose `service_tags` as a string array from `profit_fc_client_tags where tag_type = 'service'`.
- Candidate rows expose `estimated_annual_revenue` from the current classification row, keyed by `current_classification_id`; unclassified rows return `null`.

Expected assertion snippets:

```python
response = client.get("/api/profit/admin/audit/candidates?verdict_code=__UNCLASSIFIED__")
assert response.status_code == 200
assert all(row["current_verdict_code"] is None for row in response.json()["rows"])
assert "service_tags" in response.json()["rows"][0]
assert "estimated_annual_revenue" in response.json()["rows"][0]

response = client.get("/api/profit/admin/audit/candidates?verdict_code=NOT_A_VERDICT")
assert response.status_code == 422
assert response.json()["detail"]["field"] == "verdict_code"
```

- [ ] **Step 2: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: FAIL for missing endpoints/filter behavior.

- [ ] **Step 3: Implement candidate and filter-options methods**

Service behavior:

- Fetch candidates from `profit_fulfillment_audit_candidates`.
- Apply `show_all=false` by keeping `default_visibility == "show"`.
- Apply `verdict_code=__UNCLASSIFIED__` by keeping `current_verdict_code is None`.
- Apply regular verdict filters after validating against lookup rows.
- Apply free-text search against `fc_client_name` and `anchor_client_business_name`.
- Apply group filter against `group_names`.
- Apply re-evaluation due by `re_evaluate_at <= today`.
- Fetch `profit_fc_client_tags` for staff/service filters and filter candidates by matching `fc_client_id`.
- Merge `service_tags` into every candidate row from the same `profit_fc_client_tags` read. Use only rows where `tag_type = 'service'`; return an empty array when no service tags exist.
- Fetch `profit_classifications` for the current non-null `current_classification_id` set and merge `estimated_annual_revenue` into each candidate row. Return `null` for unclassified rows.
- Return `{ "rows": rows }`; no total count.

- [ ] **Step 4: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: PASS.

- [ ] **Step 5: Deploy and STOP with filter matrix**

Run:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/filter-options' | python3 -m json.tool | head -160"
ssh -p 2222 root@104.225.220.36 "for q in 'show_all=false' 'show_all=true' 'verdict_code=__UNCLASSIFIED__&show_all=false' 'verdict_code=__UNCLASSIFIED__&show_all=true' 'verdict_code=MIXED&show_all=false' 'verdict_code=MIXED&show_all=true' 'verdict_code=INTERNAL_FAMILY&show_all=false' 'verdict_code=INTERNAL_FAMILY&show_all=true'; do echo \$q; curl -s \"http://127.0.0.1:8010/api/profit/admin/audit/candidates?\$q&limit=200\" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"rows\"]))'; done"
```

Expected baseline: `123, 137, 84, 84, 2, 2, 0, 6` unless live data shifted. Report response bodies/counts.

### Task 4: Composite Detail Endpoint

**Files:**
- Modify: `profit_api/audit.py`
- Modify: `profit_api/app.py`
- Modify: `tests/test_profit_api_audit.py`

- [ ] **Step 1: Write failing tests**

Assert:

- Detail response has keys `candidate`, `fc_activity`, `anchor_signals`, `group_signals`, `classification_history`, `classification_history_total_count`, `classification_history_truncated`, `transition_rules`, `recent_service_tasks`.
- History caps at 100 and exposes total/truncated.
- Recent service tasks cap at 20.
- Unknown client returns 404.
- Existing client outside candidate surface returns 404 with exact message.
- Transition rules include `signal_present`, `auto_apply_enabled_in_b2a`, and `signal_reason`.
- Transition rules use `signal_reason is None` when `signal_present` is true, and a non-empty string when `signal_present` is false:

```python
for rule in response.json()["transition_rules"]:
    if rule["signal_present"]:
        assert rule["signal_reason"] is None
    else:
        assert isinstance(rule["signal_reason"], str)
        assert rule["signal_reason"]
```

- [ ] **Step 2: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: FAIL for missing detail endpoint.

- [ ] **Step 3: Implement detail service**

Read these sources:

- `profit_fc_clients` for existence check.
- `profit_fulfillment_audit_candidates`.
- `profit_fulfillment_audit_fc_activity`.
- `profit_fulfillment_audit_anchor_signals`.
- `profit_fulfillment_audit_group_signals`.
- `profit_classifications`.
- `profit_classification_transition_rules`.
- `profit_fc_task_delivery_classification`.

Recent service task columns to return:

- `fc_task_id`
- `fc_project_id`
- `fc_client_id`
- `client_name`
- `project_title`
- `task_title`
- `task_kind`
- `is_completed`
- `completed_at`

Do not add extra joins for assigned staff in B.2.b; the view does not expose staff and adding another REST call is not worth it for the first dashboard slice.

- [ ] **Step 4: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: PASS.

- [ ] **Step 5: Deploy and STOP with known-client detail curls**

Find IDs live if needed:

```bash
ssh -p 2222 root@104.225.220.36 "set -a; . /opt/agents/outscore_profit/.env; set +a; psql \"\$SUPABASE_DB_URL\" -P pager=off -c \"select fc_client_id, name from profit_fc_clients where name ilike any (array['%joy%property%', '%lti%', '%schmidli%']) order by name;\""
```

Then curl each detail endpoint:

```bash
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/candidates/<fc_client_id>' | python3 -m json.tool | head -220"
```

Expected:

- Joy may 404 if not in candidate surface; report exact behavior.
- LTI returns unclassified detail or current live state if Task 6 has not run yet.
- Schmidli returns classification history with superseded PENDING and current MIXED.

### Task 5: Bulk Classification API

**Files:**
- Modify: `profit_api/audit.py`
- Modify: `profit_api/app.py`
- Modify: `tests/test_profit_api_audit.py`

- [ ] **Step 1: Write failing tests**

Cover:

- Empty rows -> `422` `{detail: {field: "rows", message: "row count must be 1..200"}}`.
- More than 200 rows -> same 422.
- Invalid UUID -> `422`.
- Unknown verdict -> structured `422`.
- Notes required when category is `mixed`, `leak`, or `manual_review`.
- First-classification path accepts `classification_id_to_supersede=None` when no active row exists.
- Null supersede with active row returns `409`.
- Stale supersede ID returns `409` with current classification information.
- Existing request_id returns existing rows idempotently.
- Rollback deletes inserted rows when supersede patch fails.
- Validation order is locked:
  1. Schema: UUID format and row count -> `422` with `field=request_id` or `field=rows`.
  2. Verdict code lookup -> `422` with `field=new_verdict_code`.
  3. Required notes by category -> `422` with `field=notes`.
  4. Required `re_evaluate_at` -> `422` with `field=re_evaluate_at`.
  5. Optimistic concurrency -> `409`.
- Mixed-error precedence: when a request has both an unknown verdict and a stale supersede id, response is `422` with `field=new_verdict_code`, not `409`.

- [ ] **Step 2: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: FAIL for missing POST endpoint.

- [ ] **Step 3: Implement bulk classify service**

Implementation outline:

1. Validate `request_id` and `rows` size before database reads.
2. Load verdict lookup.
3. Validate each row, required notes by category, and `re_evaluate_at` for verdicts requiring it.
4. Load current active classifications for each `fc_client_id`.
5. Enforce optimistic-concurrency matrix from G3.
6. Build new classification rows:
   - `source_audit_file = 'manual:/profit/admin/audit'`
   - `source_audit_row_hash = f'manual:{request_id}:{fc_client_id}'`
   - `source_verdict_raw = new_verdict_code`
   - `notes = f'[req:{request_id}] {notes}'.strip()`
   - `classified_by = payload.classified_by or 'orlando'`
   - copy `re_evaluate_at`
7. Insert rows in one `insert_rows` call.
8. Patch prior active rows with `superseded_at` and `superseded_by_classification_id`.
9. On failure after insert, delete inserted rows by request key and raise.

- [ ] **Step 4: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: PASS.

- [ ] **Step 5a: Deploy and run validation-only curls, then STOP**

Run validation curls first:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service"
ssh -p 2222 root@104.225.220.36 "curl -s -X POST 'http://127.0.0.1:8010/api/profit/admin/audit/classifications' -H 'Content-Type: application/json' -d '{\"request_id\":\"00000000-0000-0000-0000-000000000000\",\"rows\":[]}' | python3 -m json.tool"
ssh -p 2222 root@104.225.220.36 "python3 - <<'PY'
import json
rows = [{'fc_client_id': i, 'classification_id_to_supersede': None, 'new_verdict_code': 'BILLING_OUTSIDE_AUDIT_WINDOW', 're_evaluate_at': None, 'notes': ''} for i in range(201)]
print(json.dumps({'request_id': '00000000-0000-0000-0000-000000000001', 'rows': rows}))
PY" >/tmp/audit_oversize_payload.json
scp -P 2222 /tmp/audit_oversize_payload.json root@104.225.220.36:/tmp/audit_oversize_payload.json
ssh -p 2222 root@104.225.220.36 "curl -s -X POST 'http://127.0.0.1:8010/api/profit/admin/audit/classifications' -H 'Content-Type: application/json' --data-binary @/tmp/audit_oversize_payload.json | python3 -m json.tool"
ssh -p 2222 root@104.225.220.36 "curl -s -X POST 'http://127.0.0.1:8010/api/profit/admin/audit/classifications' -H 'Content-Type: application/json' -d '{\"request_id\":\"not-a-uuid\",\"rows\":[{\"fc_client_id\":2426569,\"classification_id_to_supersede\":55,\"new_verdict_code\":\"BILLING_OUTSIDE_AUDIT_WINDOW\",\"re_evaluate_at\":null,\"notes\":\"\"}]}' | python3 -m json.tool"
ssh -p 2222 root@104.225.220.36 "curl -s -X POST 'http://127.0.0.1:8010/api/profit/admin/audit/classifications' -H 'Content-Type: application/json' -d '{\"request_id\":\"00000000-0000-0000-0000-000000000002\",\"rows\":[{\"fc_client_id\":2426569,\"classification_id_to_supersede\":55,\"new_verdict_code\":\"NOT_A_VERDICT\",\"re_evaluate_at\":null,\"notes\":\"\"}]}' | python3 -m json.tool"
ssh -p 2222 root@104.225.220.36 "curl -s -X POST 'http://127.0.0.1:8010/api/profit/admin/audit/classifications' -H 'Content-Type: application/json' -d '{\"request_id\":\"00000000-0000-0000-0000-000000000003\",\"rows\":[{\"fc_client_id\":2426569,\"classification_id_to_supersede\":55,\"new_verdict_code\":\"MIXED\",\"re_evaluate_at\":null,\"notes\":\"\"}]}' | python3 -m json.tool"
ssh -p 2222 root@104.225.220.36 "curl -s -X POST 'http://127.0.0.1:8010/api/profit/admin/audit/classifications' -H 'Content-Type: application/json' -d '{\"request_id\":\"00000000-0000-0000-0000-000000000004\",\"rows\":[{\"fc_client_id\":2426569,\"classification_id_to_supersede\":32,\"new_verdict_code\":\"BILLING_OUTSIDE_AUDIT_WINDOW\",\"re_evaluate_at\":null,\"notes\":\"\"}]}' | python3 -m json.tool"
```

Expected:

- Empty rows -> `422` with `field=rows`.
- More than 200 rows -> `422` with `field=rows`.
- Invalid UUID -> `422` with `field=request_id`.
- Unknown verdict -> `422` with `field=new_verdict_code`.
- Missing required notes for `MIXED` -> `422` with `field=notes`.
- Schmidli stale supersede (`fc_client_id=2426569`, `classification_id_to_supersede=32`) -> `409` with `current_classification_id=55`.

Stop here and report all validation response bodies. Wait for orchestrator approval before Step 5b.

- [ ] **Step 5b: Run LTI first-classification mutation, then STOP**

Prepare LTI first-classification regression:

```bash
ssh -p 2222 root@104.225.220.36 "set -a; . /opt/agents/outscore_profit/.env; set +a; psql \"\$SUPABASE_DB_URL\" -P pager=off -c \"select fc_client_id, fc_client_name, current_classification_id, current_verdict_code from profit_fulfillment_audit_candidates where fc_client_name ilike '%lti%';\""
```

If LTI is still unclassified, run one POST with `BILLING_OUTSIDE_AUDIT_WINDOW`, `classification_id_to_supersede: null`, and an empty notes string. If live state drifted and LTI is classified, stop and propose a new named unclassified fixture before mutating.

After successful POST:

```bash
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/candidates?search=LTI&show_all=true' | python3 -m json.tool"
```

Expected: LTI current verdict populated and `applied_count=1`.

Stop and report the POST request body, response body, and refetch evidence.

### Task 6: QBO Category Gaps Endpoint

**Files:**
- Modify: `profit_api/audit.py`
- Modify: `profit_api/app.py`
- Modify: `tests/test_profit_api_audit.py`

- [ ] **Step 1: Write failing tests**

Assert `GET /api/profit/admin/audit/qbo-category-gaps` returns `{rows}` from `profit_fulfillment_audit_qbo_category_gaps`, supports `limit` clamp `1..200`, and preserves `gap_origin`.

- [ ] **Step 2: Run red tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: FAIL for missing endpoint.

- [ ] **Step 3: Implement diagnostics endpoint**

Service reads `profit_fulfillment_audit_qbo_category_gaps` and returns rows, default limit 100.

- [ ] **Step 4: Run focused tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_audit.py -q
```

Expected: PASS.

- [ ] **Step 5: Deploy and STOP**

Run:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/qbo-category-gaps?limit=20' | python3 -m json.tool"
```

Expected: rows with `gap_origin` and `qbo_product_match_status`. Report row count and sample gap origins.

### Task 7: Audit Dashboard Filters, Table, And Verdict Map

**Files:**
- Modify: `app/frontend/src/routes/AuditDashboard.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write failing static tests**

Assert:

- `AuditDashboard.jsx` fetches `/verdicts`, `/filter-options`, and `/candidates`.
- It defines `UNCLASSIFIED_VERDICT = "__UNCLASSIFIED__"`.
- It builds a verdict map from API rows.
- It does not define a hardcoded 14-verdict array.
- It renders `Unclassified`.
- It renders `Unknown verdict`.
- It includes `show_all`.
- It renders table columns for `service_tags` and `estimated_annual_revenue`.
- It reads `row.service_tags` and `row.estimated_annual_revenue` from candidate row data.
- It clears selection after successful bulk classify.
- New CSS classes use `audit-` prefix.

- [ ] **Step 2: Run red frontend test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL for missing dashboard behavior.

- [ ] **Step 3: Implement filters/table shell**

Add:

- Fetch on mount for verdicts, filter options, candidates.
- Filters for show all, verdict, staff, service tag, group, due re-evaluation, search.
- Table columns:
  - select checkbox
  - client
  - verdict
  - service tags
  - estimated annual revenue
  - Anchor status
  - open invoice balance
  - group
  - re-evaluate at
  - signal summary
- Muted `Unclassified` label.
- Defensive unknown verdict warning.
- Row count text `Showing N rows`.

- [ ] **Step 4: Run frontend tests and build**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: PASS.

- [ ] **Step 5: Deploy and STOP for browser handoff**

Run:

```bash
scp -P 2222 -r app/frontend/dist root@104.225.220.36:/opt/agents/outscore_profit/frontend/
ssh -p 2222 root@104.225.220.36 "curl -k -I -s --resolve app.outscore.com:443:127.0.0.1 'https://app.outscore.com/profit/admin/audit' | head -n 8"
```

Expected URL: `https://app.outscore.com/profit/admin/audit`.

Stop for Orlando browser spot-check: filters render, table renders, unclassified rows are readable, verdict options come from API.

### Task 8: Bulk Classify Panel And Structured Error Handling UI

**Files:**
- Modify: `app/frontend/src/routes/AuditDashboard.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write failing static tests**

Assert:

- `parseApiError` exists.
- It handles `kind: "validation"` and `kind: "conflict"`.
- Bulk classify panel sends `request_id`.
- It sends `classification_id_to_supersede`.
- It sends `new_verdict_code`.
- It enforces notes for categories `mixed`, `leak`, `manual_review`.
- It uses `__UNCLASSIFIED__` filter sentinel.
- It strips `[req:...]` from rendered notes.
- It clears selected rows after success.
- It preserves selection after failure.

- [ ] **Step 2: Run red static test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL.

- [ ] **Step 3: Implement bulk panel**

Behavior:

- Generate `request_id` when the bulk panel opens.
- Reuse request ID on retry until success or panel reset.
- Disable apply with no selected rows, no verdict, missing required notes, or loading state.
- On success:
  - show toast with `applied_count`.
  - refetch candidates with current filters.
  - clear selected rows to `{}`.
- On `409`:
  - show conflict message and a Refresh action.
  - Refresh action refetches and clears selection.
- On `422`:
  - show row/field inline message when present.
  - preserve selection.

- [ ] **Step 4: Run static tests and build**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: PASS.

- [ ] **Step 5: Deploy and STOP for browser handoff**

Run:

```bash
scp -P 2222 -r app/frontend/dist root@104.225.220.36:/opt/agents/outscore_profit/frontend/
```

Stop for Orlando browser spot-check: select rows, see bulk panel, required-notes guard works, validation/conflict presentation is coherent.

### Task 9: Composite Detail Panel And Diagnostics Side Panel

**Files:**
- Modify: `app/frontend/src/routes/AuditDashboard.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Write failing static tests**

Assert:

- Detail endpoint string includes `/candidates/${`.
- Collapsible sections use `<details` or `audit-detail-section`.
- Default-open sections include candidate summary, anchor signals, transition rules.
- Detail panel renders `No prior classifications`.
- It renders `classification_history_total_count` and `classification_history_truncated`.
- It renders transition badges:
  - `Will auto-apply on next pipeline run`
  - `Eligible — manual apply only (V0.6.C will automate)`
  - `Not eligible:`
- QBO diagnostics endpoint string exists.
- Diagnostic panel renders `gap_origin`.

- [ ] **Step 2: Run red static test**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL.

- [ ] **Step 3: Implement detail and diagnostics panels**

Use collapsible vertical sections:

- Candidate summary: default open.
- FC activity.
- Anchor signals: default open.
- Group signals.
- Transition rules: default open.
- Classification history: default collapsed.
- Recent service tasks: default collapsed.

Add QBO/category diagnostic side panel that loads `/qbo-category-gaps` and groups rows by `gap_origin`.

- [ ] **Step 4: Run tests and build**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: PASS.

- [ ] **Step 5: Deploy and STOP for browser handoff**

Run:

```bash
scp -P 2222 -r app/frontend/dist root@104.225.220.36:/opt/agents/outscore_profit/frontend/
```

Stop for Orlando browser spot-check: open detail for Schmidli, LTI, and a hidden group-billed row; verify sections and diagnostics render.

### Task 10: Data Contract And Tech-Debt Updates

**Files:**
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md`
- Modify: `tests/test_data_references_docs.py` if existing doc tests need static assertions

- [ ] **Step 1: Write failing doc/static tests**

Add assertions that the data contract mentions:

- `__UNCLASSIFIED__`
- `/api/profit/admin/audit/candidates`
- `source_audit_file = 'manual:/profit/admin/audit'`
- `source_audit_row_hash = 'manual:<request_id>:<fc_client_id>'`
- required notes categories `mixed`, `leak`, `manual_review`
- service-side rollback
- no new SQL in B.2.b
- audit dashboard table omits staff primary/reviewer

- [ ] **Step 2: Run red doc tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: FAIL if assertions are new.

- [ ] **Step 3: Update docs**

Add `Audit Dashboard API Conventions` to the data contract:

- six endpoints.
- verdict map source.
- `__UNCLASSIFIED__` sentinel.
- show-all/default-visibility semantics.
- bulk classify append/supersede behavior.
- structured 409/422 behavior.
- detail payload caps.

Add tech-debt entries:

- Bulk classify uses service-side rollback; a SQL function with a true transaction would be more robust if rollback ever fails.
- Multi-user dashboard concurrency is guarded by 409 stale-snapshot checks but does not provide full collaborative locking.
- Audit dashboard table omits staff primary/reviewer column. Source data (assigned-staff per FC client) is not exposed in current views without an additional join. Defer to V0.6.D SLA work which already needs staff context, or add a small helper view in V0.6.C.
- Detail panel service tasks omit assigned staff unless exposed by existing views; revisit if SLA context needs staff in B.2.b+.
- Frontend preserves no selection after successful bulk apply; revisit if operators need multi-step batch workflows.

- [ ] **Step 4: Run doc tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_data_references_docs.py -q
```

Expected: PASS.

### Task 11: Full Dashboard Deploy Checkpoint

**Files:**
- No new code unless verification reveals a bug.

- [ ] **Step 1: Run targeted tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py tests/test_profit_api_audit.py tests/test_data_references_docs.py -q
```

Expected: PASS.

- [ ] **Step 2: Build frontend**

Run:

```bash
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: Vite build succeeds. `package.json` and lockfiles have no dependency changes.

- [ ] **Step 3: Deploy API and frontend**

Run:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
scp -P 2222 -r app/frontend/dist root@104.225.220.36:/opt/agents/outscore_profit/frontend/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service && systemctl status profit-admin-api.service --no-pager"
```

Expected: API service active.

- [ ] **Step 4: Curl live endpoints**

Run:

```bash
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/verdicts' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"rows\"]))'"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/candidates?limit=200' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"rows\"]))'"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/qbo-category-gaps?limit=20' | python3 -m json.tool | head -120"
ssh -p 2222 root@104.225.220.36 "curl -k -I -s --resolve app.outscore.com:443:127.0.0.1 'https://app.outscore.com/profit/admin/audit' | head -n 8"
```

Expected:

- 14 verdicts.
- Candidate count matches current live baseline.
- QBO gaps endpoint returns JSON.
- Audit route returns Nginx auth response, not 404.

Stop and hand URL to Orlando for browser spot-check.

### Task 12: Final Verification And Scope Boundary

**Files:**
- No new code unless verification reveals a bug.

- [ ] **Step 1: Run full pytest**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Run final frontend build**

Run:

```bash
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: build succeeds.

- [ ] **Step 3: Scope-boundary check**

Run:

```bash
git diff --name-only
```

Expected files only:

- `app/frontend/src/App.jsx`
- `app/frontend/src/components/PortalNav.jsx`
- `app/frontend/src/routes/AuditDashboard.jsx`
- `app/frontend/src/styles.css`
- `docs/data-contracts/fulfillment-classifications.md`
- `docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.b-audit-dashboard-frontend.md`
- `docs/tech-debt.md`
- `profit_api/app.py`
- `profit_api/audit.py`
- `tests/test_data_references_docs.py` if modified
- `tests/test_profit_admin_frontend.py`
- `tests/test_profit_api_audit.py`

Must not show:

- `supabase/sql/**`
- `n8n/workflows/**`
- `scripts/**`
- `app/frontend/package.json`
- `app/frontend/package-lock.json`
- `profit_api` migrations or unrelated services
- audit CSV files

- [ ] **Step 4: Final live summary**

Run final GET-only checks:

```bash
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/verdicts' | python3 -c 'import json,sys; rows=json.load(sys.stdin)[\"rows\"]; print(\"verdicts\", len(rows))'"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/candidates?show_all=true&limit=200' | python3 -c 'import json,sys; rows=json.load(sys.stdin)[\"rows\"]; print(\"candidates_show_all\", len(rows))'"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/audit/candidates?verdict_code=__UNCLASSIFIED__&limit=200' | python3 -c 'import json,sys; rows=json.load(sys.stdin)[\"rows\"]; print(\"unclassified\", len(rows))'"
```

Stop and report tests, build, scope diff, and live summary. Do not commit until orchestrator approves.

### Task 13: Commit And Push

**Files:**
- Stage only B.2.b files after approval.

- [ ] **Step 1: Final pytest sweep**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Stage explicit files**

Run:

```bash
git add \
  app/frontend/src/App.jsx \
  app/frontend/src/components/PortalNav.jsx \
  app/frontend/src/routes/AuditDashboard.jsx \
  app/frontend/src/styles.css \
  docs/data-contracts/fulfillment-classifications.md \
  docs/superpowers/plans/2026-05-08-profit-dashboard-v0.6.B.2.b-audit-dashboard-frontend.md \
  docs/tech-debt.md \
  profit_api/app.py \
  profit_api/audit.py \
  tests/test_profit_admin_frontend.py \
  tests/test_profit_api_audit.py
```

If `tests/test_data_references_docs.py` was modified, add it explicitly too.

- [ ] **Step 3: Commit**

Use a structured message:

```bash
git commit -m "Add V0.6.B.2.b audit dashboard frontend and API

Build the /profit/admin/audit React route and FastAPI audit endpoints
on top of the V0.6.B.2.a audit views. The dashboard reads verdicts
from profit_classification_verdicts, renders the default-visible
candidate queue, supports __UNCLASSIFIED__ filtering, opens a
composite evidence detail panel, and exposes QBO/category diagnostics.

Add AuditDashboardService endpoints for verdicts, filter options,
candidates, detail payloads, bulk classification, and diagnostic gaps.
Bulk classification preserves the append-friendly profit_classifications
invariant with deterministic request_id idempotency, optimistic 409
stale-snapshot detection, category-based required-notes validation, and
service-side rollback matching the Manual Recognition precedent.

No SQL migrations, workflow changes, frontend dependencies, V0.6.C
pipeline orchestration, or V0.6.D SLA work are included.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Push**

Run:

```bash
git push
```

- [ ] **Step 5: Final report**

Report:

- commit hash
- pytest result
- frontend build result
- live one-liner
- confirmation that V0.6.B.2.b is shipped and V0.6.C pipeline orchestration is unblocked

## Self-Review Checklist

- [ ] Plan includes all six gate resolutions as tasks or constraints.
- [ ] No new SQL migrations or views.
- [ ] No Workflow JSON changes.
- [ ] Zero new npm packages.
- [ ] 14 verdicts are read from API, never hardcoded in frontend.
- [ ] `__UNCLASSIFIED__` magic string is documented and tested.
- [ ] Show-all/verdict filter matrix is a deploy checkpoint.
- [ ] Required-notes validation is category-based: `mixed`, `leak`, `manual_review`.
- [ ] Bulk classify supports first-classification and reclassification.
- [ ] Optimistic-concurrency 409 detection is in API and UI handling.
- [ ] Service-side rollback is documented; true SQL transaction is tech debt.
- [ ] Detail endpoint is composite and capped: history 100, service tasks 20.
- [ ] Transition-rule `signal_present` and `auto_apply_enabled_in_b2a` mappings are explicit.
- [ ] Detail panel uses collapsible sections, not tabs.
- [ ] New CSS classes are `audit-` prefixed.
- [ ] Selection clears on successful bulk classify and is preserved on failure.
- [ ] Final scope check excludes `supabase/sql/**`, `n8n/workflows/**`, `scripts/**`, and audit CSVs.

Plan ready for orchestrator review.
