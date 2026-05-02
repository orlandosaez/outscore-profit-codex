# Profit Dashboard V0.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the live profit portal from a latest-month review surface into a selected-period monthly management dashboard with ratio context and clearly labeled fixed-window blocks.

**Architecture:** Keep the API as the dashboard assembly layer: Supabase remains the source for prebuilt views, while FastAPI selects the reporting month, computes lightweight ratio fields, and labels blocks that do not follow the selector. React stays a thin presentation layer that reloads the snapshot when the selected month changes. Prepaid liability remains a later Workstream A slice because its basis is confirmed as cash collected but not yet recognized, which requires reliable collection status from Anchor or QBO.

**Tech Stack:** Supabase REST views, FastAPI, React/Vite, Python `unittest`, existing deployed VPS service.

---

## Period Semantics

Selector-controlled blocks:
- Top KPI tiles: Company GP, Quarter Gate, Recognized, Pending.
- Ratio Summary: Client Labor LER, Admin Labor LER, Unmatched Labor LER, Total Labor LER, Gross Margin %, Client-Matched %, Admin Load %.
- Per-Client GP table.
- Per-Staff GP table.
- Comp Ledger.

Fixed-window/current-state blocks:
- FC Trigger Queue: live queue of matched completion triggers, not filtered by selected month.
- W2 Watch: latest trailing-8-month workload/cost window, not filtered by selected month.

## Files

- Modify `profit_api/dashboard.py`: selected-period snapshot assembly, ratio math, fixed-window metadata.
- Modify `profit_api/app.py`: optional `period` query parameter.
- Modify `tests/test_profit_api_dashboard.py`: backend selected-period and ratio tests.
- Modify `app/frontend/src/App.jsx`: month selector, ratio summary, labels.
- Modify `app/frontend/src/styles.css`: selector and ratio summary styles.
- Modify `tests/test_profit_admin_frontend.py`: frontend static coverage for new labels.
- Modify `docs/profit-admin-portal-review-guide.md`: add V0.2 block explanations after implementation.

## Tasks

### Task 1: Backend Selected Period Contract

- [x] Add failing tests showing `AdminDashboardService.snapshot(period_month="2026-03-01")` filters month-controlled views with `period_month=eq.2026-03-01`, reads the selected quarter gate, and leaves FC/W2 blocks unfiltered.
- [x] Run `python3 -m unittest tests.test_profit_api_dashboard -v` and confirm the new tests fail because `snapshot()` has no period argument and no fixed-window metadata.
- [x] Implement selected-period resolution from `profit_company_monthly_gp_recognition_basis`, defaulting to the latest available month when no period is supplied.
- [x] Return `available_periods` from `profit_company_monthly_gp_recognition_basis` so the frontend selector has an explicit source.
- [x] Derive the quarter gate from the quarter containing the selected month, not today's/current quarter.
- [x] Validate `period` query values as `YYYY-MM-01` and return a clear `422` for malformed input.
- [x] Add API route query parameter `period: str | None = None` and pass it to `snapshot(period_month=period)`.
- [x] Re-run backend tests and confirm they pass.

### Task 2: Backend Ratio Summary

- [x] Add failing tests for ratio output names and formulas:
  - `client_labor_ler = matched_labor_cost / recognized_revenue_amount`
  - `admin_labor_ler = admin_labor_cost / recognized_revenue_amount`
  - `unmatched_labor_ler = unmatched_labor_cost / recognized_revenue_amount`
  - `total_labor_ler = contractor_labor_cost / recognized_revenue_amount`
  - `gross_margin_pct = gp_pct`
  - `client_matched_pct = matched_labor_cost / contractor_labor_cost`
  - `admin_load_pct = admin_load_pct`
- [x] Run backend tests and confirm the ratio test fails before implementation.
- [x] Verify `admin_load_pct` exists in `profit_company_monthly_gp_recognition_basis`; it is computed as `admin_hours / total_hours`.
- [x] Implement safe division helpers that return `None` when the denominator is zero or missing.
- [x] Include raw amount fields in `ratio_summary` so the UI can later explain variance without another API change.
- [x] Re-run backend tests and confirm they pass.

### Task 3: Frontend Period Selector And Fixed-Window Labels

- [x] Add failing frontend test expectations for `Period`, `FC Trigger Queue · Live queue`, and `W2 Watch · Trailing 8-month window`.
- [x] Run frontend tests and confirm they fail before implementation.
- [x] Add `selectedPeriod` state, render a month selector from `data.available_periods`, and fetch `/profit/api/profit/admin/dashboard?period=YYYY-MM-01` when changed.
- [x] Label FC Trigger Queue and W2 Watch as fixed-window/current-state blocks.
- [x] Re-run frontend tests and confirm they pass.

### Task 4: Frontend Ratio Summary

- [x] Add failing frontend test expectations for `Ratio Summary`, `Client Labor LER`, `Admin Labor LER`, `Unmatched Labor LER`, `Total Labor LER`, and `Client-Matched %`.
- [x] Add a compact horizontal ratio summary between top tiles and Per-Client GP.
- [x] Use percent formatting for ratio values, and show `No data` when API fields are `null`.
- [x] Re-run frontend tests and confirm they pass.

### Task 5: Per-Client Cleanup

- [x] Add service-level and owner clarity in the Per-Client GP table without changing the underlying grouping.
- [x] Show `Needs owner mapping` instead of a bare `Unassigned` fallback.
- [x] Add visual review badges for zero revenue with labor, negative GP, and `other` service type.
- [x] Re-run tests and build.

### Task 6: Verify, Deploy, Smoke Test

- [x] Run Python tests with the bundled runtime.
- [x] Run Vite build with `VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api`.
- [x] Package and deploy the frontend/API to the VPS.
- [x] Restart `profit-admin-api.service`.
- [x] Smoke test the live API for default period and one explicit period.
- [ ] Commit and push the completed V0.2 slice.

## Deferred Workstream A Slice

Prepaid liability will be designed after period and ratio behavior is live. Confirmed basis: cash collected but not yet recognized, not invoice/AR. Required next implementation design: payment collection feed from Anchor or QBO, allocation from collected payment to service revenue components, and an audit ledger that can reconcile to QBO Deferred Revenue.
