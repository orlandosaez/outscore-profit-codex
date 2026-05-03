# Profit Dashboard V0.4 Prepaid Tile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the live prepaid liability split in the admin dashboard so Orlando can see the QBO Deferred Revenue JE number, trigger backlog, per-client balances, and audit ledger without confusing the reference total for a journal entry.

**Architecture:** Supabase remains the source of truth through `profit_prepaid_liability_summary`, `profit_prepaid_liability_balances`, and `profit_prepaid_liability_ledger`. FastAPI exposes a compact snapshot block plus two focused prepaid endpoints; React renders a point-in-time top tile, a filtered drill-down table, and an on-demand per-client ledger panel. Existing period-selector behavior stays intact because prepaid liability is current-state, not period-filtered.

**Tech Stack:** Supabase REST views, FastAPI, React/Vite, Python `unittest`/`pytest`, existing VPS deploy behind `/profit/api`.

---

## Period Semantics

Selector-controlled blocks:
- Company GP.
- Quarter Gate.
- Recognized.
- Pending.
- Ratio Summary.
- Company GP Trend context.
- Per-Client GP.
- Per-Staff GP.
- Comp Ledger.

Fixed-window/current-state blocks:
- FC Trigger Queue: live queue; not filtered by selected month.
- W2 Watch: latest trailing-8-month window; not filtered by selected month.
- Prepaid Liability: point-in-time balance; not filtered by selected month.

Prepaid liability tile, balances, and current totals always reflect "as of now" from the live prepaid views. The UI must label this explicitly as point-in-time and show `last_updated` when available. The per-client audit log defaults to full history; period filtering for the ledger is a V0.5 enhancement.

## Files

- Modify `profit_api/dashboard.py`: expose `prepaid_liability` snapshot summary and add service methods for prepaid balances and ledger.
- Modify `profit_api/app.py`: add prepaid balances and ledger routes.
- Modify `tests/test_profit_api_dashboard.py`: tighten snapshot prepaid summary contract and fixed-window metadata.
- Create `tests/test_profit_api_prepaid.py`: endpoint tests for balances and ledger validation.
- Modify `app/frontend/src/App.jsx`: replace provisional prepaid stat/panel with V0.4 tile, filterable balances table, and ledger detail panel.
- Modify `app/frontend/src/styles.css`: top-row prepaid tile layout, tooltips, filter chips, drill-down table, ledger panel.
- Modify `tests/test_profit_admin_frontend.py`: static coverage for the V0.4 labels, point-in-time language, tooltip strings, filters, and ledger labels.
- Modify `docs/profit-admin-portal-review-guide.md`: append V0.4 usage notes.
- Modify `docs/data-contracts/qbo-collections.md`: document new API surfaces and point-in-time semantics.

## API Route Names

Internal FastAPI routes:
- `GET /api/profit/admin/dashboard`
- `GET /api/profit/admin/prepaid/balances`
- `GET /api/profit/admin/prepaid/ledger?anchor_relationship_id=X&macro_service_type=Y`

External deployed routes through the `/profit/api` proxy:
- `GET /profit/api/profit/admin/dashboard`
- `GET /profit/api/profit/admin/prepaid/balances`
- `GET /profit/api/profit/admin/prepaid/ledger?anchor_relationship_id=X&macro_service_type=Y`

## Tile UX Rule

The top tile must show three separate lines and must never collapse prepaid liability into one JE-looking number:

```text
Prepaid Liability · point-in-time
Tax Deferred Revenue     $13,517.29
Trigger Backlog          $61,667.62
Total reference          $75,184.91
```

Required tooltip/help text:
- Tax Deferred Revenue: `Record this exact amount as Deferred Revenue in QuickBooks. Tax retainers held until return is filed or extended.`
- Trigger Backlog: pull `trigger_backlog_note` from `profit_prepaid_liability_summary` when available; fallback to `Delivered services with no recognition trigger loaded — not a QBO liability entry. Clears when FC completion triggers are approved.`
- Total reference: `Sum of both buckets. Do not record this as a single QBO entry.`

If the 5-column top row becomes cramped, implement the prepaid tile as a wider grid item spanning two columns at desktop widths. Do not collapse the tile to a single number.

## Tasks

### Task 1: Backend Snapshot Prepaid Contract

**Files:**
- Modify `tests/test_profit_api_dashboard.py`
- Modify `profit_api/dashboard.py`

- [ ] **Step 1: Write the failing snapshot test**

Add assertions that `snapshot()["prepaid_liability"]` returns only the summary block needed by the header tile, not full balances/ledger payloads:

```python
def test_snapshot_includes_point_in_time_prepaid_summary_only(self) -> None:
    snapshot = AdminDashboardService(FakeSupabaseReader()).snapshot(period_month="2026-03-01")

    prepaid = snapshot["prepaid_liability"]
    self.assertEqual(prepaid["window_label"], "Point-in-time balance; not filtered by selected month.")
    self.assertEqual(prepaid["summary"]["tax_deferred_revenue_balance"], 5000)
    self.assertEqual(prepaid["summary"]["trigger_backlog_balance"], 7500)
    self.assertEqual(prepaid["summary"]["total_prepaid_liability_balance"], 12500)
    self.assertEqual(prepaid["summary"]["last_updated"], "2026-04-30")
    self.assertNotIn("balances", prepaid)
    self.assertNotIn("ledger", prepaid)
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_dashboard.py -q
```

Expected: FAIL because the current snapshot still includes `balances` and `ledger` inside `prepaid_liability`.

- [ ] **Step 3: Implement the minimal snapshot change**

Change `_read_prepaid_liability()` so the dashboard snapshot returns:

```python
return {
    "summary": summary,
    "basis_note": basis_note,
    "window_label": "Point-in-time balance; not filtered by selected month.",
    "migration_status": "ready",
    "collection_feed_status": collection_feed_status,
}
```

Keep the existing missing-view fallback but return empty summary metadata only, not tables.

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_dashboard.py -q
```

Expected: PASS.

### Task 2: Backend Prepaid Balances Service And Endpoint

**Files:**
- Create `tests/test_profit_api_prepaid.py`
- Modify `profit_api/dashboard.py`
- Modify `profit_api/app.py`

- [ ] **Step 1: Write failing service and route tests**

Create `tests/test_profit_api_prepaid.py` with tests that use a fake reader and FastAPI `TestClient`:

```python
from __future__ import annotations

import os
import unittest

from fastapi.testclient import TestClient


class FakePrepaidReader:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str | int]]] = []

    def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
        self.calls.append((view_name, params))
        if view_name == "profit_prepaid_liability_balances":
            return [
                {
                    "anchor_relationship_id": "relationship-tax",
                    "anchor_client_business_name": "Tax Client LLC",
                    "service_category": "tax_deferred_revenue",
                    "macro_service_type": "tax",
                    "balance": 13517.29,
                    "last_updated": "2026-05-03T01:37:24+00:00",
                },
                {
                    "anchor_relationship_id": "relationship-bookkeeping",
                    "anchor_client_business_name": "Bookkeeping Client LLC",
                    "service_category": "pending_recognition_trigger",
                    "macro_service_type": "bookkeeping",
                    "balance": 61667.62,
                    "last_updated": "2026-05-03T01:37:24+00:00",
                },
            ]
        return []
```

Service assertion:

```python
def test_prepaid_balances_reads_full_view_ordered_by_balance(self) -> None:
    from profit_api.dashboard import AdminDashboardService

    reader = FakePrepaidReader()
    rows = AdminDashboardService(reader).prepaid_balances()

    self.assertEqual(len(rows), 2)
    self.assertEqual(rows[0]["service_category"], "tax_deferred_revenue")
    self.assertEqual(
        reader.calls[0],
        (
            "profit_prepaid_liability_balances",
            {"order": "balance.desc,anchor_client_business_name.asc", "limit": 1000},
        ),
    )
```

Route assertion:

```python
def test_prepaid_balances_endpoint_returns_rows(self) -> None:
    import profit_api.app as app_module

    app_module.service = AdminDashboardService(FakePrepaidReader())
    client = TestClient(app_module.app)

    response = client.get("/api/profit/admin/prepaid/balances")

    self.assertEqual(response.status_code, 200)
    self.assertEqual(response.json()["rows"][0]["anchor_client_business_name"], "Tax Client LLC")
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_prepaid.py -q
```

Expected: FAIL because `AdminDashboardService.prepaid_balances()` and the route do not exist.

- [ ] **Step 3: Add service method and route**

In `profit_api/dashboard.py` add:

```python
def prepaid_balances(self) -> list[DashboardRow]:
    return self.reader.read_view(
        "profit_prepaid_liability_balances",
        order="balance.desc,anchor_client_business_name.asc",
        limit=1000,
    )
```

In `profit_api/app.py` add:

```python
@app.get("/api/profit/admin/prepaid/balances")
def prepaid_balances() -> dict[str, object]:
    return {"rows": service.prepaid_balances()}
```

- [ ] **Step 4: Run the new test and verify it passes**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_prepaid.py -q
```

Expected: PASS.

### Task 3: Backend Prepaid Ledger Service And Endpoint

**Files:**
- Modify `tests/test_profit_api_prepaid.py`
- Modify `profit_api/dashboard.py`
- Modify `profit_api/app.py`

- [ ] **Step 1: Add failing ledger tests**

Extend the fake reader to return ledger rows for `profit_prepaid_liability_ledger`:

```python
if view_name == "profit_prepaid_liability_ledger":
    return [
        {
            "event_at": "2026-01-19",
            "ledger_entry_type": "revenue_recognized",
            "amount_delta": -4000,
            "source_payment_id": None,
            "revenue_event_key": "rev_paid",
            "anchor_relationship_id": "relationship-bookkeeping",
            "macro_service_type": "bookkeeping",
        },
        {
            "event_at": "2025-12-18",
            "ledger_entry_type": "cash_collected",
            "amount_delta": 4000,
            "source_payment_id": "1272",
            "revenue_event_key": "rev_paid",
            "anchor_relationship_id": "relationship-bookkeeping",
            "macro_service_type": "bookkeeping",
        },
    ]
```

Add service assertion:

```python
def test_prepaid_ledger_filters_by_relationship_and_macro_service(self) -> None:
    from profit_api.dashboard import AdminDashboardService

    reader = FakePrepaidReader()
    rows = AdminDashboardService(reader).prepaid_ledger(
        anchor_relationship_id="relationship-bookkeeping",
        macro_service_type="bookkeeping",
    )

    self.assertEqual(len(rows), 2)
    self.assertEqual(
        reader.calls[-1],
        (
            "profit_prepaid_liability_ledger",
            {
                "anchor_relationship_id": "eq.relationship-bookkeeping",
                "macro_service_type": "eq.bookkeeping",
                "order": "event_at.desc,ledger_entry_type.asc",
                "limit": 1000,
            },
        ),
    )
```

Add route validation assertions:

```python
def test_prepaid_ledger_endpoint_requires_params(self) -> None:
    import profit_api.app as app_module

    app_module.service = AdminDashboardService(FakePrepaidReader())
    client = TestClient(app_module.app)

    response = client.get("/api/profit/admin/prepaid/ledger")

    self.assertEqual(response.status_code, 422)
```

```python
def test_prepaid_ledger_endpoint_returns_rows(self) -> None:
    import profit_api.app as app_module

    app_module.service = AdminDashboardService(FakePrepaidReader())
    client = TestClient(app_module.app)

    response = client.get(
        "/api/profit/admin/prepaid/ledger",
        params={
            "anchor_relationship_id": "relationship-bookkeeping",
            "macro_service_type": "bookkeeping",
        },
    )

    self.assertEqual(response.status_code, 200)
    self.assertEqual(response.json()["rows"][0]["ledger_entry_type"], "revenue_recognized")
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_prepaid.py -q
```

Expected: FAIL because `prepaid_ledger()` and the ledger route do not exist.

- [ ] **Step 3: Add service method and route**

In `profit_api/dashboard.py` add:

```python
def prepaid_ledger(
    self,
    *,
    anchor_relationship_id: str,
    macro_service_type: str,
) -> list[DashboardRow]:
    return self.reader.read_view(
        "profit_prepaid_liability_ledger",
        anchor_relationship_id=f"eq.{anchor_relationship_id}",
        macro_service_type=f"eq.{macro_service_type}",
        order="event_at.desc,ledger_entry_type.asc",
        limit=1000,
    )
```

In `profit_api/app.py` add:

```python
@app.get("/api/profit/admin/prepaid/ledger")
def prepaid_ledger(
    anchor_relationship_id: str | None = None,
    macro_service_type: str | None = None,
) -> dict[str, object]:
    if not anchor_relationship_id or not macro_service_type:
        raise HTTPException(
            status_code=422,
            detail="anchor_relationship_id and macro_service_type are required",
        )
    return {
        "rows": service.prepaid_ledger(
            anchor_relationship_id=anchor_relationship_id,
            macro_service_type=macro_service_type,
        )
    }
```

- [ ] **Step 4: Run backend tests and verify they pass**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_dashboard.py tests/test_profit_api_prepaid.py -q
```

Expected: PASS.

### Task 4: Frontend Top Tile

**Files:**
- Modify `tests/test_profit_admin_frontend.py`
- Modify `app/frontend/src/App.jsx`
- Modify `app/frontend/src/styles.css`

- [ ] **Step 1: Add failing static frontend assertions**

Add assertions for:

```python
self.assertIn("Prepaid Liability · point-in-time", source)
self.assertIn("Tax Deferred Revenue", source)
self.assertIn("Record this exact amount as Deferred Revenue in QuickBooks", source)
self.assertIn("Trigger Backlog", source)
self.assertIn("Total reference", source)
self.assertIn("Do not record this as a single QBO entry", source)
self.assertNotIn("Pending Triggers", source)
```

- [ ] **Step 2: Run frontend static test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL because the current tile still uses the provisional single-value stat and `Pending Triggers` wording.

- [ ] **Step 3: Replace the provisional stat with a dedicated prepaid tile**

Create `PrepaidLiabilityTile({ prepaidLiability })` in `App.jsx`. It should render three rows:

```jsx
<section className="stat prepaid-stat">
  <div className="stat-icon">
    <Landmark size={18} aria-hidden="true" />
  </div>
  <div className="prepaid-stat-body">
    <p>Prepaid Liability · point-in-time</p>
    <div className="prepaid-stat-row" title="Record this exact amount as Deferred Revenue in QuickBooks. Tax retainers held until return is filed or extended.">
      <span>Tax Deferred Revenue</span>
      <strong>{formatMoney(summary.tax_deferred_revenue_balance)}</strong>
    </div>
    <div className="prepaid-stat-row" title={summary.trigger_backlog_note ?? triggerBacklogFallback}>
      <span>Trigger Backlog</span>
      <strong>{formatMoney(summary.trigger_backlog_balance)}</strong>
    </div>
    <div className="prepaid-stat-row reference" title="Sum of both buckets. Do not record this as a single QBO entry.">
      <span>Total reference</span>
      <strong>{formatMoney(summary.total_prepaid_liability_balance)}</strong>
    </div>
    <small>{summary.last_updated ? `Current balance as of ${dateTimeLabel(summary.last_updated)}` : "Current point-in-time balance"}</small>
  </div>
</section>
```

If `collection_feed_status !== "loaded"`, keep the unambiguous empty state: `Collection feed not yet loaded` and `Deferred Revenue JE not ready`.

- [ ] **Step 4: Add responsive tile CSS**

Use a wider desktop tile:

```css
.prepaid-stat {
  grid-column: span 2;
}

.prepaid-stat-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 8px;
  align-items: baseline;
}

.prepaid-stat-row strong {
  font-size: 0.95rem;
}

.prepaid-stat-row.reference {
  border-top: 1px solid #e3e9ec;
  margin-top: 4px;
  padding-top: 4px;
}
```

Keep mobile behavior as one column.

- [ ] **Step 5: Run frontend static test and verify it passes**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: PASS.

### Task 5: Frontend Drill-Down Balances Table

**Files:**
- Modify `tests/test_profit_admin_frontend.py`
- Modify `app/frontend/src/App.jsx`
- Modify `app/frontend/src/styles.css`

- [ ] **Step 1: Add failing static assertions**

Add assertions for:

```python
self.assertIn("/profit/admin/prepaid/balances", source)
self.assertIn("SERVICE_CATEGORY_LABEL", source)
self.assertIn("tax_deferred_revenue: \"Tax Deferred\"", source)
self.assertIn("pending_recognition_trigger: \"Trigger Backlog\"", source)
self.assertIn("All", source)
self.assertIn("Tax Deferred", source)
self.assertIn("Trigger Backlog", source)
self.assertIn("service_category !== \"recognized\"", source)
self.assertIn("setPrepaidFilter", source)
```

- [ ] **Step 2: Run frontend static test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL because balances are still embedded in the snapshot and the filter chips do not exist.

- [ ] **Step 3: Fetch balances from the new endpoint**

Add state:

```jsx
const [prepaidBalances, setPrepaidBalances] = useState([]);
const [prepaidFilter, setPrepaidFilter] = useState("all");
const [selectedPrepaidRow, setSelectedPrepaidRow] = useState(null);
```

Add fetch helper:

```jsx
async function loadPrepaidBalances() {
  const response = await fetch(`${apiBase}/profit/admin/prepaid/balances`);
  if (!response.ok) throw new Error(`Prepaid balances request failed: ${response.status}`);
  const payload = await response.json();
  setPrepaidBalances(payload.rows ?? []);
}
```

Call `loadPrepaidBalances()` after the dashboard loads successfully.

- [ ] **Step 4: Render filter chips and default row filter**

Default rows:

```jsx
const visiblePrepaidBalances = prepaidBalances
  .filter((row) => row.service_category !== "recognized")
  .filter((row) => {
    if (prepaidFilter === "tax") return row.service_category === "tax_deferred_revenue";
    if (prepaidFilter === "trigger") return row.service_category === "pending_recognition_trigger";
    return true;
  });
```

Columns:
- Client: `anchor_client_business_name`
- Service category: `service_category`
- Macro service: `macro_service_type`
- Balance: `balance`
- Last updated: `last_updated`

Clicking a row sets `selectedPrepaidRow`.

Use a shared service-category label map for both chips and table cells:

```jsx
const SERVICE_CATEGORY_LABEL = {
  tax_deferred_revenue: "Tax Deferred",
  pending_recognition_trigger: "Trigger Backlog",
  recognized: "Recognized",
};
```

- [ ] **Step 5: Run frontend static test and verify it passes**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: PASS.

### Task 6: Frontend Per-Client Audit Ledger Panel

**Files:**
- Modify `tests/test_profit_admin_frontend.py`
- Modify `app/frontend/src/App.jsx`
- Modify `app/frontend/src/styles.css`

- [ ] **Step 1: Add failing static assertions**

Add assertions for:

```python
self.assertIn("/profit/admin/prepaid/ledger", source)
self.assertIn("Running balance", source)
self.assertIn("source_payment_id", source)
self.assertIn("revenue_event_key", source)
self.assertIn("QBO journal entry reconciliation trail", source)
```

- [ ] **Step 2: Run frontend static test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL because the ledger panel still renders the snapshot sample ledger and does not fetch per row.

- [ ] **Step 3: Add ledger fetch and running balance computation**

Add state:

```jsx
const [prepaidLedgerRows, setPrepaidLedgerRows] = useState([]);
```

Add helper:

```jsx
async function loadPrepaidLedger(row) {
  const params = new URLSearchParams({
    anchor_relationship_id: row.anchor_relationship_id,
    macro_service_type: row.macro_service_type,
  });
  const response = await fetch(`${apiBase}/profit/admin/prepaid/ledger?${params.toString()}`);
  if (!response.ok) throw new Error(`Prepaid ledger request failed: ${response.status}`);
  const payload = await response.json();
  setPrepaidLedgerRows(withRunningBalances(payload.rows ?? []));
}
```

Compute oldest-to-newest cumulative balances, then render newest first:

```jsx
function withRunningBalances(rows) {
  let running = 0;
  return [...rows]
    .sort((a, b) => String(a.event_at ?? "").localeCompare(String(b.event_at ?? "")))
    .map((row) => {
      running += Number(row.amount_delta ?? 0);
      return { ...row, running_balance: running };
    })
    .sort((a, b) => String(b.event_at ?? "").localeCompare(String(a.event_at ?? "")));
}
```

- [ ] **Step 4: Render ledger panel**

Panel columns:
- Date: `event_at`
- Type: `ledger_entry_type`
- Amount: `amount_delta`
- Source ref: `source_payment_id` for cash rows, otherwise `revenue_event_key`
- Running balance: computed `running_balance`

Panel note:

```text
QBO journal entry reconciliation trail. Cash collected increases the balance; revenue recognized draws it down.
```

- [ ] **Step 5: Run frontend static test and verify it passes**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: PASS.

### Task 7: Docs

**Files:**
- Modify `docs/profit-admin-portal-review-guide.md`
- Modify `docs/data-contracts/qbo-collections.md`

- [ ] **Step 1: Update portal review guide**

Append a `V0.4 Prepaid Liability` section explaining:
- Prepaid Liability is point-in-time and ignores the period selector.
- `Tax Deferred Revenue` is the exact QBO Deferred Revenue JE number.
- `Trigger Backlog` is not a QBO liability entry.
- `Total reference` is informational only and must not be posted as one JE.
- The drill-down table defaults to non-recognized categories.
- The ledger is the reconciliation trail.

- [ ] **Step 2: Update QBO collections data contract**

Add API surfaces:

```markdown
## API Surfaces

- `GET /api/profit/admin/dashboard`: includes `prepaid_liability.summary` for the top tile.
- `GET /api/profit/admin/prepaid/balances`: returns point-in-time per-client/service balances.
- `GET /api/profit/admin/prepaid/ledger?anchor_relationship_id=X&macro_service_type=Y`: returns full-history ledger rows for a selected client/service.

Prepaid endpoints do not accept `period`; balances are point-in-time. Ledger period filtering is deferred to V0.5.
```

- [ ] **Step 3: Run doc/static tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py tests/test_prepaid_liability_sql.py -q
```

Expected: PASS.

### Task 8: Full Verification, Deploy, Smoke Test Checkpoint

**Files:**
- No source edits expected unless verification fails.

- [ ] **Step 1: Run the full test suite**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: `93+ passed`.

- [ ] **Step 2: Build the frontend**

Run:

```bash
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: Vite build succeeds and `app/frontend/dist` updates.

- [ ] **Step 3: Deploy to VPS**

Run the existing deploy path used for prior slices:

```bash
app/deploy/deploy_profit_app.sh
ssh -p 2222 root@104.225.220.36 'systemctl restart profit-admin-api.service'
```

Expected: service restarts cleanly.

- [ ] **Step 4: Smoke test live API**

Run:

```bash
ssh -p 2222 root@104.225.220.36 'curl -s http://127.0.0.1:8010/api/profit/admin/dashboard | python3 -m json.tool | head -80'
ssh -p 2222 root@104.225.220.36 'curl -s http://127.0.0.1:8010/api/profit/admin/prepaid/balances | python3 -m json.tool | head -80'
ssh -p 2222 root@104.225.220.36 'curl -s "http://127.0.0.1:8010/api/profit/admin/prepaid/ledger?anchor_relationship_id=relationship-iYKcklY5Afc-lA8FYR3BzIkvzff0&macro_service_type=bookkeeping" | python3 -m json.tool | head -80'
```

Expected:
- dashboard summary includes `tax_deferred_revenue_balance`, `trigger_backlog_balance`, and `total_prepaid_liability_balance`.
- balances endpoint returns rows.
- ledger endpoint returns rows for Collectiv bookkeeping or an empty `rows` array without error if no current rows match.

- [ ] **Step 5: STOP for Orlando live UI review**

Stop after deploy/smoke test and ask Orlando to spot-check the live UI. Do not commit until Orlando confirms the tile wording/layout is usable.

### Task 9: Commit And Push After UI Approval

**Files:**
- All files changed by Tasks 1-8.

- [ ] **Step 1: Re-run tests after any review edits**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: PASS.

- [ ] **Step 2: Commit**

Run:

```bash
git add profit_api/dashboard.py profit_api/app.py tests/test_profit_api_dashboard.py tests/test_profit_api_prepaid.py app/frontend/src/App.jsx app/frontend/src/styles.css tests/test_profit_admin_frontend.py docs/profit-admin-portal-review-guide.md docs/data-contracts/qbo-collections.md
git commit -m "Surface prepaid liability in profit admin (V0.4)" -m "Add point-in-time prepaid liability tile with explicit Tax Deferred Revenue ($13,517.29 — QBO Deferred Revenue JE number), Trigger Backlog, and Total reference lines. Tile never collapses to a single JE-looking number." -m "Add /api/profit/admin/prepaid/balances and /api/profit/admin/prepaid/ledger endpoints backed by profit_prepaid_liability_balances and profit_prepaid_liability_ledger views." -m "Add filterable per-client drill-down (All / Tax Deferred / Trigger Backlog) and per-client audit ledger panel with running balance — the QBO journal entry reconciliation trail."
```

Adjust the dollar amount in the commit message if the live numbers shift between implementation start and commit time.

- [ ] **Step 3: Push**

Run:

```bash
git push
```

Expected: branch pushes cleanly.

## Out Of Scope For V0.4

- Period filtering on the audit log; default full history only. Consider V0.5 if the ledger grows too noisy.
- Trend chart for prepaid balance over time.
- Edit, override, approve, or exclude controls in the UI.
- Structural fix for voided invoice propagation. That remains tracked in `docs/tech-debt.md`.

## Self-Review

- Requirement A covered by Period Semantics, Task 1, Task 4, and Task 7.
- Requirement B covered by Tile UX Rule and Task 4.
- Requirement C covered by Task 2 and Task 5.
- Requirement D covered by Task 3 and Task 6.
- Requirement E covered by Tasks 1-3.
- Requirement F covered by Tasks 1-6 and Task 8.
- Requirement G covered by Task 7.
- Requirement H covered by Out Of Scope.
