# Profit Dashboard V0.5.1 Recognition UX Refinements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve the V0.5 Manual Recognition workflow based on real-data testing: Enter-to-filter, consolidated sibling batch approval, friendly success messages, and default hiding for zero-amount noise.

**Architecture:** Keep the V0.5 single-event recognition rail intact and add one narrow batch endpoint that inserts one audited trigger per selected sibling event using a shared `manual_override_batch_id`. React keeps the Manual Recognition route as the only UI surface, adding client-side sibling selection, zero-amount filtering, and friendly formatting without changing the dashboard architecture. The batch path must be transactional at the API/service level: validate all events first, insert/apply all recognized events only if every event is eligible, and report a 422 without partial recognition on any failure.

**Tech Stack:** Supabase Postgres migration, Supabase REST through `SupabaseRestClient`, FastAPI, React/Vite, Python `unittest`/`pytest`, existing VPS deploy behind `/profit/api`.

---

## Period Semantics

Manual recognition remains event-scoped, not dashboard-period scoped.

The main dashboard period selector remains unrelated to `/profit/admin/recognition`.

Manual Recognition route semantics for V0.5.1:
- `period_filter` filters pending events by `candidate_period_month` only when supplied.
- Pressing Enter in the client or period filter input triggers the same pending-event refresh as the `Apply filters` button.
- `Show tax-deferred events` remains off by default.
- `Show zero-amount events` is added and remains off by default.
- Consolidated sibling batch approval applies only to events sharing the exact same `(anchor_relationship_id, macro_service_type, candidate_period_month)` group.
- Recent overrides remain latest-first and are not tied to the dashboard period.

## Scope

In scope:
- Enter key support for client and period filter inputs.
- One batch endpoint for manual recognition of checked sibling events.
- Friendly single and batch success toast copy.
- Hide zero-amount pending rows by default, including zero-amount siblings.
- Docs/tests for these behaviors.

Out of scope:
- Monthly close actions for payroll/sales-tax cohorts. That is V0.5.5.
- Ice of Central Florida classification correction.
- New dashboard architecture or additional recognition surfaces.
- Undo/reverse batch approval. Same as V0.5, remediation remains manual exclusion if needed.
- Bulk approval outside consolidated sibling groups.

## Files

- Create `supabase/sql/015_profit_manual_recognition_batch.sql`: add `manual_override_batch_id` to `profit_recognition_triggers` and an index.
- Modify `profit_api/manual_recognition.py`: add batch request validation, sibling consistency check, batch trigger inserts, transactional rollback behavior, and friendly response payloads.
- Modify `profit_api/app.py`: add `POST /api/profit/admin/recognition/manual-override-batch`.
- Modify `profit_api/supabase.py`: add helper methods only if the service needs a delete/rollback or multi-row insert helper not already present.
- Modify `tests/test_profit_api_manual_recognition.py`: add batch endpoint/service tests.
- Modify `app/frontend/src/routes/ManualRecognition.jsx`: Enter key handling, sibling checkboxes, checked sibling state, batch submit, friendly toast formatter, zero-amount toggle/filter.
- Modify `app/frontend/src/styles.css`: sibling checkbox/list polish and zero-amount toggle spacing.
- Modify `tests/test_profit_admin_frontend.py`: static assertions for all four UX refinements.
- Modify `tests/test_prepaid_liability_sql.py`: SQL coverage for migration 015.
- Modify `docs/profit-admin-portal-review-guide.md`: V0.5.1 workflow notes.
- Modify `docs/data-contracts/recognition-triggers.md`: document `manual_override_batch_id`.

## API Route Names

Existing routes:
- `GET /api/profit/admin/recognition/pending`
- `POST /api/profit/admin/recognition/manual-override`
- `GET /api/profit/admin/recognition/manual-overrides`

New route:
- `POST /api/profit/admin/recognition/manual-override-batch`

External deployed route:
- `POST /profit/api/profit/admin/recognition/manual-override-batch`

## Batch Safety Rules

Batch recognition must:
1. Require at least two `revenue_event_keys`.
2. Fetch every requested event from `profit_manual_recognition_pending_events`.
3. Reject missing, recognized, excluded, or non-pending events.
4. Reject mixed sibling groups where `(anchor_relationship_id, macro_service_type, candidate_period_month)` differs.
5. Apply V0.5 validation once for `reason_code`, `notes`, and `reference`.
6. Generate one server-side UUID batch id.
7. Insert one `profit_recognition_triggers` row per event with the same `manual_override_batch_id`.
8. Prefix each stored note with the row amount, e.g. `[$650] Veena email 2026-04-26 approved consolidated $1,350 tax filing batch`.
9. Apply recognition for every row through the same ready-view path used in V0.5.
10. If any insert/apply step fails, roll back any rows changed during the request and return 422. No partial batch success.

Implementation note: Supabase REST is not a database transaction boundary. The service must validate all rows first, then keep enough inserted trigger keys and updated event snapshots to undo work if a later step fails. If rollback cannot be implemented safely with current REST helpers, stop and report before building a partial path.

## Tasks

### Task 1: SQL Migration For Batch IDs

**Files:**
- Create `supabase/sql/015_profit_manual_recognition_batch.sql`
- Modify `tests/test_prepaid_liability_sql.py`

- [ ] **Step 1: Write failing SQL test**

Add this test to `tests/test_prepaid_liability_sql.py`:

```python
def test_manual_recognition_batch_migration_adds_batch_id(self) -> None:
    sql = Path("supabase/sql/015_profit_manual_recognition_batch.sql").read_text()

    self.assertIn("manual_override_batch_id", sql)
    self.assertIn("alter table profit_recognition_triggers", sql.lower())
    self.assertIn("idx_profit_recognition_triggers_batch_id", sql)
    self.assertIn("where manual_override_batch_id is not null", sql.lower())
```

- [ ] **Step 2: Run test and confirm red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py -q
```

Expected: FAIL because migration 015 does not exist.

- [ ] **Step 3: Create migration 015**

Create `supabase/sql/015_profit_manual_recognition_batch.sql`:

```sql
alter table profit_recognition_triggers
  add column if not exists manual_override_batch_id text;

create index if not exists idx_profit_recognition_triggers_batch_id
  on profit_recognition_triggers (manual_override_batch_id)
  where manual_override_batch_id is not null;
```

- [ ] **Step 4: Run test and confirm green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py -q
```

Expected: PASS.

### Task 2: Backend Batch Recognition Service

**Files:**
- Modify `profit_api/manual_recognition.py`
- Modify `profit_api/supabase.py` if rollback helpers are needed
- Modify `tests/test_profit_api_manual_recognition.py`

- [ ] **Step 1: Write failing backend tests**

Add tests covering batch happy path and safety rules in `tests/test_profit_api_manual_recognition.py`.

Test names:

```python
def test_apply_manual_recognition_batch_rejects_mixed_sibling_groups(self) -> None:
    ...

def test_apply_manual_recognition_batch_uses_one_batch_id_for_all_triggers(self) -> None:
    ...

def test_apply_manual_recognition_batch_prefixes_each_note_with_source_amount(self) -> None:
    ...

def test_apply_manual_recognition_batch_rolls_back_when_apply_fails(self) -> None:
    ...

def test_apply_manual_recognition_batch_returns_recognized_events(self) -> None:
    ...
```

Core expectations:
- Mixed `(anchor_relationship_id, macro_service_type, candidate_period_month)` rows raise `ManualRecognitionError` / HTTP 422.
- Every inserted trigger has `trigger_type = "manual_recognition_approved"`.
- Every inserted trigger has the same non-empty `manual_override_batch_id`.
- Notes are stored as `[$650] user notes`, `[$350] user notes`, etc.
- If applying event 2 fails, event 1 is restored and inserted triggers from the request are removed or neutralized according to the rollback helper implemented in this task.
- Response includes an `events` array with client, service, period, source amount, and recognition status for every recognized event.

- [ ] **Step 2: Run tests and confirm red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: FAIL because the batch method/route does not exist.

- [ ] **Step 3: Implement service method**

In `profit_api/manual_recognition.py`, add:

```python
def apply_manual_recognition_batch(
    self,
    revenue_event_keys: list[str],
    reason_code: str,
    notes: str,
    reference: str | None = None,
) -> dict[str, Any]:
    ...
```

Implementation requirements:
- Reject fewer than two keys.
- Reuse the existing reason/notes validation from single override.
- Fetch pending event records for every key.
- Confirm all keys were found.
- Confirm all found rows share one sibling group.
- Generate `manual_override_batch_id = str(uuid.uuid4())`.
- For each row, insert a manual trigger using trigger key `manual_override_{revenue_event_key}` and shared batch id.
- Prefix row notes with `[{format_currency_without_decimals(row["source_amount"])}]`.
- Apply recognition through the ready-view/apply helper used by the single-event path.
- Return:

```python
{
    "events": [...],
    "manual_override_batch_id": batch_id,
}
```

- [ ] **Step 4: Implement rollback helpers if needed**

If current `SupabaseRestClient` lacks enough methods for rollback, add focused helpers:

```python
def delete_rows(self, table: str, **params: str) -> list[dict[str, Any]]:
    ...

def patch_rows(self, table: str, payload: Mapping[str, Any], **params: str) -> list[dict[str, Any]]:
    ...
```

Use them only inside the batch failure rollback path.

- [ ] **Step 5: Run backend tests and confirm green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: PASS.

### Task 3: Batch API Route

**Files:**
- Modify `profit_api/app.py`
- Modify `tests/test_profit_api_manual_recognition.py`

- [ ] **Step 1: Write failing route test**

Add a route test that posts:

```python
{
    "revenue_event_keys": ["rev_a", "rev_b"],
    "reason_code": "client_operational_change",
    "notes": "Veena email 2026-04-26 approved consolidated $1,350 tax filing batch",
    "reference": None,
}
```

Expected response:
- HTTP 200
- JSON contains `manual_override_batch_id`
- JSON contains `events`

Also add a 422 test for `revenue_event_keys = ["rev_a"]`.

- [ ] **Step 2: Run route tests and confirm red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: FAIL because route is missing.

- [ ] **Step 3: Add FastAPI model and route**

In `profit_api/app.py`, add:

```python
class ManualRecognitionBatchRequest(BaseModel):
    revenue_event_keys: list[str]
    reason_code: str
    notes: str
    reference: str | None = None


@app.post("/api/profit/admin/recognition/manual-override-batch")
def apply_manual_recognition_batch(request: ManualRecognitionBatchRequest) -> dict[str, Any]:
    try:
        return manual_recognition_service().apply_manual_recognition_batch(
            revenue_event_keys=request.revenue_event_keys,
            reason_code=request.reason_code,
            notes=request.notes,
            reference=request.reference,
        )
    except ManualRecognitionError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
```

- [ ] **Step 4: Run backend tests and confirm green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: PASS.

### Task 4: Frontend Static Tests For UX Refinements

**Files:**
- Modify `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Add failing static tests**

Add tests:

```python
def test_manual_recognition_filters_submit_on_enter(self) -> None:
    route_source = Path("app/frontend/src/routes/ManualRecognition.jsx").read_text()

    self.assertIn("handleFilterKeyDown", route_source)
    self.assertIn('event.key === "Enter"', route_source)
    self.assertIn("onKeyDown={handleFilterKeyDown}", route_source)


def test_manual_recognition_supports_sibling_batch_selection(self) -> None:
    route_source = Path("app/frontend/src/routes/ManualRecognition.jsx").read_text()

    self.assertIn("checkedSiblingKeys", route_source)
    self.assertIn("manual-override-batch", route_source)
    self.assertIn("Approve and Recognize (", route_source)
    self.assertIn("disabled", route_source)


def test_manual_recognition_has_friendly_toast_formatter(self) -> None:
    route_source = Path("app/frontend/src/routes/ManualRecognition.jsx").read_text()

    self.assertIn("formatRecognitionToast", route_source)
    self.assertIn("Recognized DVH Investing LLC tax (Apr 2026) for $350", route_source)
    self.assertIn("Recognized 3 events for DVH Investing LLC totaling $1,350", route_source)


def test_manual_recognition_hides_zero_amount_events_by_default(self) -> None:
    route_source = Path("app/frontend/src/routes/ManualRecognition.jsx").read_text()

    self.assertIn("showZeroAmount", route_source)
    self.assertIn("setShowZeroAmount", route_source)
    self.assertIn("Show zero-amount events", route_source)
    self.assertIn("Number(row.source_amount ?? 0) > 0", route_source)
```

- [ ] **Step 2: Run frontend static tests and confirm red**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL on the new assertions.

### Task 5: Frontend Enter Filters And Zero-Amount Toggle

**Files:**
- Modify `app/frontend/src/routes/ManualRecognition.jsx`
- Modify `app/frontend/src/styles.css`
- Test `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Add shared filter handler and Enter key handler**

In `ManualRecognition.jsx`, replace direct `refreshPage` usage for filter submit with:

```jsx
function applyFilters() {
  refreshPage();
}

function handleFilterKeyDown(event) {
  if (event.key === "Enter") {
    event.preventDefault();
    applyFilters();
  }
}
```

Attach to both text inputs:

```jsx
<input
  value={clientFilter}
  onChange={(event) => setClientFilter(event.target.value)}
  onKeyDown={handleFilterKeyDown}
  placeholder="Client"
/>
...
<input
  value={periodFilter}
  onChange={(event) => setPeriodFilter(event.target.value)}
  onKeyDown={handleFilterKeyDown}
  placeholder="YYYY-MM-01"
/>
```

- [ ] **Step 2: Add zero-amount state and filters**

Add:

```jsx
const [showZeroAmount, setShowZeroAmount] = useState(false);
```

Update `eventCountLabel` and `visiblePendingRows` to use the same filtered rows:

```jsx
const visiblePendingRows = useMemo(
  () => pendingRows
    .filter((row) => showTaxDeferred || row.recognition_status !== "pending_tax_completion")
    .filter((row) => showZeroAmount || Number(row.source_amount ?? 0) > 0),
  [pendingRows, showTaxDeferred, showZeroAmount],
);

const eventCountLabel = useMemo(
  () => `${visiblePendingRows.length} pending events`,
  [visiblePendingRows],
);
```

Add toggle near `Show tax-deferred events`:

```jsx
<label className="inline-toggle">
  <input
    checked={showZeroAmount}
    onChange={(event) => setShowZeroAmount(event.target.checked)}
    type="checkbox"
  />
  Show zero-amount events
</label>
<span>Zero-amount events are usually classification artifacts and rarely need manual recognition. Toggle on if you need to inspect them.</span>
```

- [ ] **Step 3: Apply zero-amount filter to sibling list**

Change sibling list derivation:

```jsx
return pendingRows
  .filter((row) => showZeroAmount || Number(row.source_amount ?? 0) > 0)
  .filter((row) => (
    row.anchor_relationship_id === selectedEvent.anchor_relationship_id
    && row.macro_service_type === selectedEvent.macro_service_type
    && row.candidate_period_month === selectedEvent.candidate_period_month
  ))
  .sort((a, b) => Number(b.source_amount ?? 0) - Number(a.source_amount ?? 0));
```

- [ ] **Step 4: Run frontend tests and confirm partial green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: Enter and zero-amount tests pass; batch/toast tests still fail until Task 6.

### Task 6: Frontend Batch Selection And Friendly Toasts

**Files:**
- Modify `app/frontend/src/routes/ManualRecognition.jsx`
- Modify `app/frontend/src/styles.css`
- Test `tests/test_profit_admin_frontend.py`

- [ ] **Step 1: Add batch endpoint and checked state**

Add:

```jsx
const overrideBatchEndpoint = `${apiBase}/profit/admin/recognition/manual-override-batch`;
const [checkedSiblingKeys, setCheckedSiblingKeys] = useState([]);
```

When opening an event:

```jsx
function openEvent(row) {
  setSelectedEvent(row);
  setCheckedSiblingKeys([row.revenue_event_key]);
  resetApprovalForm();
  setToast("");
  setError("");
}
```

When dismissing:

```jsx
setCheckedSiblingKeys([]);
```

- [ ] **Step 2: Add sibling checkbox UI**

In sibling list rows, add a checkbox:

```jsx
<input
  checked={checkedSiblingKeys.includes(row.revenue_event_key)}
  disabled={row.revenue_event_key === selectedEvent.revenue_event_key}
  onChange={(event) => toggleSiblingKey(row.revenue_event_key, event.target.checked)}
  type="checkbox"
/>
```

Add:

```jsx
function toggleSiblingKey(key, checked) {
  setCheckedSiblingKeys((current) => {
    if (checked) return Array.from(new Set([...current, key]));
    return current.filter((value) => value !== key || value === selectedEvent?.revenue_event_key);
  });
}
```

- [ ] **Step 3: Add single vs batch submit**

Replace the approval call with:

```jsx
async function approveSelectedEvent() {
  if (approveDisabled) return;
  const selectedKeys = checkedSiblingKeys.length ? checkedSiblingKeys : [selectedEvent.revenue_event_key];
  const isBatch = selectedKeys.length > 1;
  const response = await fetch(isBatch ? overrideBatchEndpoint : overrideEndpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(isBatch ? {
      revenue_event_keys: selectedKeys,
      reason_code: selectedReason,
      notes,
      reference: reference || null,
    } : {
      revenue_event_key: selectedEvent.revenue_event_key,
      reason_code: selectedReason,
      notes,
      reference: reference || null,
    }),
  });
  ...
}
```

Button label:

```jsx
Approve and Recognize ({Math.max(1, checkedSiblingKeys.length)})
```

- [ ] **Step 4: Add friendly toast formatter**

Add this helper:

```jsx
const SERVICE_LABEL = {
  bookkeeping: "bookkeeping",
  payroll: "payroll",
  tax: "tax",
  advisory: "advisory",
  other: "other",
};

function formatRecognitionToast(payload) {
  const events = payload.events ?? (payload.event ? [payload.event] : []);
  if (events.length > 1) {
    const first = events[0];
    const total = events.reduce((sum, row) => sum + Number(row.source_amount ?? 0), 0);
    return `Recognized ${events.length} events for ${first.anchor_client_business_name ?? "Unassigned"} totaling ${formatMoney(total)}`;
  }
  const event = events[0];
  return `Recognized ${event.anchor_client_business_name ?? "Unassigned"} ${SERVICE_LABEL[event.macro_service_type] ?? event.macro_service_type} (${monthLabel(event.candidate_period_month)}) for ${formatMoney(event.source_amount)}`;
}

const toastExamples = [
  "Recognized DVH Investing LLC tax (Apr 2026) for $350",
  "Recognized 3 events for DVH Investing LLC totaling $1,350",
];
```

Use:

```jsx
setToast(formatRecognitionToast(payload));
```

- [ ] **Step 5: Run frontend tests and confirm green**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: PASS.

### Task 7: Docs

**Files:**
- Modify `docs/profit-admin-portal-review-guide.md`
- Modify `docs/data-contracts/recognition-triggers.md`

- [ ] **Step 1: Update review guide**

Append a V0.5.1 subsection under the Manual Recognition section:

```markdown
### V0.5.1 Usability Refinements

The client and period filters submit when Enter is pressed, matching the Apply filters button.

Zero-amount pending events are hidden by default because they are usually classification artifacts with nothing to recognize. Turn on `Show zero-amount events` only when reviewing source data quality.

For consolidated billing groups, the sibling list supports selecting multiple sibling events and approving them as one batch. The selected row is always included and locked. One reason code, notes field, and reference apply to every checked event. The system still writes one trigger row per revenue event and stores a shared `manual_override_batch_id`, with each row's notes prefixed by that row's source amount.

Batch approval is only allowed for true sibling events under the same Anchor relationship, service type, and period. Mixed groups are rejected.
```

- [ ] **Step 2: Update recognition trigger data contract**

Add:

```markdown
### Manual Override Batch ID

`manual_override_batch_id` is nullable and is populated only when multiple sibling revenue events are approved through the V0.5.1 batch path. Each recognized event still receives its own `profit_recognition_triggers` row and its own reason/notes audit trail. Rows in the same batch share one UUID-like batch id so the approval can be reviewed as a group.
```

- [ ] **Step 3: Run docs/static tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py tests/test_prepaid_liability_sql.py -q
```

Expected: PASS.

### Task 8: Full Verification, Migration, Deploy, Smoke, Stop

**Files:**
- No new code unless verification reveals a bug.

- [ ] **Step 1: Run full test suite**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Apply migration 015 to live Supabase**

Copy/apply migration from the VPS:

```bash
scp -P 2222 supabase/sql/015_profit_manual_recognition_batch.sql root@104.225.220.36:/tmp/015_profit_manual_recognition_batch.sql
ssh -p 2222 root@104.225.220.36 "set -a; . /opt/agents/outscore_profit/.env; set +a; psql \"\$SUPABASE_DB_URL\" -f /tmp/015_profit_manual_recognition_batch.sql"
```

Expected: `ALTER TABLE` and `CREATE INDEX`.

- [ ] **Step 3: Build frontend**

Run:

```bash
cd app/frontend
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

Expected: Vite build succeeds.

- [ ] **Step 4: Deploy to VPS and restart API**

Run:

```bash
scp -P 2222 -r profit_api root@104.225.220.36:/opt/agents/outscore_profit/
scp -P 2222 -r app/frontend/dist root@104.225.220.36:/opt/agents/outscore_profit/frontend/
ssh -p 2222 root@104.225.220.36 "systemctl restart profit-admin-api.service && systemctl status profit-admin-api.service --no-pager"
```

Expected: `profit-admin-api.service` active.

- [ ] **Step 5: GET-only smoke tests, then STOP for live spot-check**

Run GET-only smoke checks:

```bash
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/recognition/pending?limit=1' | python3 -m json.tool"
ssh -p 2222 root@104.225.220.36 "curl -s 'http://127.0.0.1:8010/api/profit/admin/recognition/manual-overrides?limit=1' | python3 -m json.tool"
ssh -p 2222 root@104.225.220.36 "curl -k -I -s --resolve app.outscore.com:443:127.0.0.1 'https://app.outscore.com/profit/admin/recognition' | head -n 8"
```

Expected:
- Pending endpoint returns JSON.
- Manual overrides endpoint returns JSON.
- Recognition route returns Nginx auth response, not 404.

Stop here for Orlando spot-check. Do not commit yet.

Spot-check checklist:
- Pressing Enter in Client filter refreshes results.
- Pressing Enter in Period filter refreshes results.
- Zero-amount events are hidden by default and appear only when toggled on.
- Consolidated sibling list shows checkboxes.
- Selected sibling is checked and locked.
- Batch button count changes with checked siblings.
- Friendly single and batch toast copy is human-readable.

### Task 9: Commit And Push After Spot-Check Approval

**Files:**
- All files changed above.

- [ ] **Step 1: Re-run full tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: all tests pass.

- [ ] **Step 2: Commit**

Run:

```bash
git add supabase/sql/015_profit_manual_recognition_batch.sql profit_api/manual_recognition.py profit_api/app.py profit_api/supabase.py tests/test_profit_api_manual_recognition.py app/frontend/src/routes/ManualRecognition.jsx app/frontend/src/styles.css tests/test_profit_admin_frontend.py tests/test_prepaid_liability_sql.py docs/profit-admin-portal-review-guide.md docs/data-contracts/recognition-triggers.md docs/superpowers/plans/2026-05-03-profit-dashboard-v0.5.1-recognition-ux-refinements.md
git commit -m "Refine manual recognition UX (V0.5.1)" -m "Add Enter-to-filter behavior, default hiding for zero-amount pending events, friendly recognition toast copy, and consolidated sibling checkbox selection in the Manual Recognition route." -m "Add manual_override_batch_id support and a transactional sibling-only batch override endpoint that writes one audited trigger per event with shared batch id and per-row source amount note prefixes." -m "Document V0.5.1 batch semantics and recognition trigger data contract. Verified with full pytest before commit."
```

- [ ] **Step 3: Push**

Run:

```bash
git push
```

Expected: push succeeds.

## Self-Review

Spec coverage:
- A. Enter key filters: Tasks 4 and 5.
- B. Sibling batch approval: Tasks 1, 2, 3, 4, 6, 7.
- C. Friendly success toast: Tasks 4 and 6.
- D. Hide zero-amount events: Tasks 4 and 5.
- E. Anticipated files: Files section and Tasks 1-9.
- F. Out of scope: Scope section.
- G. Stop checkpoints: Tasks 8 and 9.

Placeholder scan:
- No `TBD`, `TODO`, or unspecified implementation steps intentionally left.

Type/name consistency:
- New column: `manual_override_batch_id`.
- New endpoint: `/api/profit/admin/recognition/manual-override-batch`.
- Frontend state: `showZeroAmount`, `checkedSiblingKeys`.
- Backend method: `apply_manual_recognition_batch`.
