# Profit Dashboard V0.5 Manual Recognition Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a narrow, audited manual recognition override path so Orlando can recognize one pending revenue event at a time when an FC completion trigger cannot reasonably fire.

**Architecture:** Manual overrides become first-class rows in `profit_recognition_triggers`, not ad hoc revenue edits. FastAPI validates the override, inserts a manual trigger, reads the existing recognition-ready view for the selected event, applies the same recognition fields Workflow 16 would apply, and returns the post-state. React exposes a separate `/profit/admin/recognition` review route with pending-event filters, a single-event approval panel, and a read-only recent override audit trail.

**Tech Stack:** Supabase Postgres migrations and REST, FastAPI, React/Vite, Python `unittest`/`pytest`, existing VPS deploy behind `/profit/api`.

---

## Period Semantics

Manual recognition is event-scoped, not dashboard-period scoped.

Selector-controlled main dashboard blocks remain unchanged:
- Company GP.
- Quarter Gate.
- Recognized.
- Pending.
- Ratio Summary.
- Company GP Trend context.
- Per-Client GP.
- Per-Staff GP.
- Comp Ledger.

Fixed-window/current-state blocks remain unchanged:
- FC Trigger Queue: live queue; not filtered by selected month.
- W2 Watch: latest trailing-8-month window; not filtered by selected month.
- Prepaid Liability: point-in-time balance; not filtered by selected month.

Manual recognition route semantics:
- Pending-event list defaults to all currently pending revenue events eligible for manual override.
- `period_filter` filters by `candidate_period_month` only when supplied.
- Recent overrides show the latest 50 manual override approvals by `approved_at desc`; they are not tied to the main dashboard period selector.
- The override action recognizes exactly one `revenue_event_key`. Bulk approval is intentionally out of scope.

## Reason Code Decision

The user prompt says "Six allowed values" but lists eight codes. V0.5 will implement the eight listed values as the locked set:

| Code | When used |
| --- | --- |
| `backbill_pre_engagement` | Work delivered before Anchor agreement was signed |
| `client_operational_change` | Mid-engagement billing/structure/scope change broke recognition |
| `entity_restructure` | Client split, merged, renamed, or moved entities |
| `service_outside_fc_scope` | Service genuinely delivered but never tracked in FC |
| `fc_classifier_gap` | FC task exists/completed, classifier did not recognize it |
| `voided_invoice_replacement` | Voided invoice replaced with another, recognition follows replacement |
| `billing_amount_adjustment` | Credit/discount/extra charge needs override |
| `other` | Catch-all; require notes with at least 20 characters |

Use a Postgres `CHECK` constraint on `profit_recognition_triggers.manual_override_reason_code` rather than a Postgres enum. The local schema already uses text columns and check constraints; a check constraint is simpler to evolve if Orlando adds or renames a reason later.

## Files

- Create `supabase/sql/013_profit_manual_recognition_override.sql`: add manual override columns/constraints, update recognition-ready view, create pending and audit views, and update prepaid views to treat `recognized_by_manual_override` as recognized.
- Modify `profit_api/supabase.py`: add Supabase REST write methods for insert and patch operations.
- Create `profit_api/manual_recognition.py`: validation rules and `ManualRecognitionService`.
- Modify `profit_api/app.py`: wire the manual recognition service and endpoints.
- Create `tests/test_profit_api_manual_recognition.py`: backend route and service tests.
- Modify `tests/test_profit_admin_frontend.py`: static coverage for the new route labels, reason codes, and disabled-button logic.
- Create `app/frontend/src/routes/ManualRecognition.jsx`: route page for pending events, override modal/panel, and recent overrides.
- Modify `app/frontend/src/App.jsx`: add a lightweight route switch without adding `react-router` and add a subdued dashboard link to `/profit/admin/recognition`.
- Modify `app/frontend/src/styles.css`: manual recognition page, filters, table, side panel, toast, and audit section.
- Modify `docs/profit-admin-portal-review-guide.md`: append V0.5 usage guidance and cultural expectations.
- Modify `docs/data-contracts/recognition-triggers.md`: document manual override fields, reason codes, ready-view behavior, and audit trail.

## API Route Names

Internal FastAPI routes:
- `GET /api/profit/admin/recognition/pending`
- `POST /api/profit/admin/recognition/manual-override`
- `GET /api/profit/admin/recognition/manual-overrides`

External deployed routes through the `/profit/api` proxy:
- `GET /profit/api/profit/admin/recognition/pending`
- `POST /profit/api/profit/admin/recognition/manual-override`
- `GET /profit/api/profit/admin/recognition/manual-overrides`

## Core Design Rule

The API must never directly "fix" revenue numbers as a side-channel update. It must:

1. Validate that the event is pending and not excluded.
2. Insert one audited `profit_recognition_triggers` row with `trigger_type = 'manual_recognition_approved'`.
3. Read `profit_revenue_events_ready_for_recognition` for that same `revenue_event_key`.
4. Patch `profit_revenue_events` using only the ready-view output fields.
5. Return the updated revenue event.

This keeps manual override on the same recognition rail as FC and tax triggers while avoiding n8n shell-out from a web request.

Critical guard: manual triggers must match exactly one `revenue_event_key`. Migration 013 must add a ready-view join guard so `trigger.source_record_id = event.revenue_event_key` whenever `trigger.trigger_type = 'manual_recognition_approved'`. Without this, a future Workflow 16 run could recognize sibling events for the same client/service/month.

## Tasks

### Task 1: Schema And Recognition Views

**Files:**
- Create `supabase/sql/013_profit_manual_recognition_override.sql`
- Test `tests/test_prepaid_liability_sql.py`

- [ ] **Step 1: Write failing SQL coverage tests**

Extend `tests/test_prepaid_liability_sql.py` with assertions that migration 013 exists, locks the eight reason codes, updates the ready view, and treats manual recognition as recognized in prepaid views:

```python
def test_manual_recognition_migration_defines_reason_codes_and_views(self) -> None:
    sql = Path("supabase/sql/013_profit_manual_recognition_override.sql").read_text()

    for reason_code in [
        "backbill_pre_engagement",
        "client_operational_change",
        "entity_restructure",
        "service_outside_fc_scope",
        "fc_classifier_gap",
        "voided_invoice_replacement",
        "billing_amount_adjustment",
        "other",
    ]:
        self.assertIn(reason_code, sql)

    self.assertIn("manual_override_reason_code", sql)
    self.assertIn("manual_override_notes", sql)
    self.assertIn("manual_override_reference", sql)
    self.assertIn("approved_by", sql)
    self.assertIn("approved_at", sql)
    self.assertIn("manual_recognition_approved", sql)
    self.assertIn("recognized_by_manual_override", sql)
    self.assertIn("profit_manual_recognition_pending_events", sql)
    self.assertIn("profit_manual_recognition_override_audit", sql)
    self.assertIn("recognition_status like 'pending_%'", sql.lower())
    self.assertIn("trigger.source_record_id = event.revenue_event_key", sql)
```

- [ ] **Step 2: Run the SQL test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py -q
```

Expected: FAIL because `013_profit_manual_recognition_override.sql` does not exist.

- [ ] **Step 3: Create migration 013**

Create `supabase/sql/013_profit_manual_recognition_override.sql`:

```sql
alter table profit_recognition_triggers
  add column if not exists manual_override_reason_code text,
  add column if not exists manual_override_notes text,
  add column if not exists manual_override_reference text,
  add column if not exists approved_by text,
  add column if not exists approved_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profit_recognition_triggers_manual_reason_code_check'
  ) then
    alter table profit_recognition_triggers
      add constraint profit_recognition_triggers_manual_reason_code_check
      check (
        manual_override_reason_code is null
        or manual_override_reason_code in (
          'backbill_pre_engagement',
          'client_operational_change',
          'entity_restructure',
          'service_outside_fc_scope',
          'fc_classifier_gap',
          'voided_invoice_replacement',
          'billing_amount_adjustment',
          'other'
        )
      );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profit_recognition_triggers_manual_required_fields_check'
  ) then
    alter table profit_recognition_triggers
      add constraint profit_recognition_triggers_manual_required_fields_check
      check (
        trigger_type <> 'manual_recognition_approved'
        or (
          manual_override_reason_code is not null
          and manual_override_notes is not null
          and length(trim(manual_override_notes)) > 0
          and approved_by is not null
          and length(trim(approved_by)) > 0
          and approved_at is not null
        )
      );
  end if;
end $$;

create index if not exists idx_profit_recognition_triggers_manual_approved_at
  on profit_recognition_triggers (trigger_type, approved_at desc)
  where trigger_type = 'manual_recognition_approved';

drop view if exists profit_revenue_events_ready_for_recognition;

create or replace view profit_revenue_events_ready_for_recognition as
select
  event.revenue_event_key,
  event.anchor_line_item_id,
  event.anchor_invoice_id,
  event.anchor_relationship_id,
  event.macro_service_type,
  event.source_amount,
  event.recognition_status as current_recognition_status,
  event.recognition_rule,
  event.candidate_period_month,
  trigger.recognition_trigger_key,
  trigger.source_system,
  trigger.source_record_id,
  trigger.trigger_type,
  trigger.completion_date as recognition_date_to_apply,
  date_trunc('month', trigger.completion_date)::date as recognition_period_month_to_apply,
  case
    when trigger.recognition_action = 'recognize_zero' then 0
    else event.source_amount
  end::numeric as recognized_amount_to_apply,
  case
    when trigger.trigger_type = 'manual_recognition_approved'
      then 'recognized_by_manual_override'
    else 'recognized_by_completion_trigger'
  end::text as next_recognition_status,
  concat(trigger.source_system, ':', trigger.source_record_id)::text as trigger_reference_to_apply
from profit_revenue_events event
join profit_recognition_triggers trigger
  on trigger.anchor_relationship_id = event.anchor_relationship_id
  and trigger.macro_service_type = event.macro_service_type
  and (
    trigger.trigger_type <> 'manual_recognition_approved'
    or trigger.source_record_id = event.revenue_event_key
  )
  and (
    trigger.service_period_month is null
    or event.candidate_period_month = trigger.service_period_month
  )
where event.recognition_period_month is null
  and event.recognized_amount = 0
  and (
    (event.recognition_rule = 'bookkeeping_complete_required' and trigger.trigger_type = 'bookkeeping_complete')
    or (event.recognition_rule = 'payroll_processed_required' and trigger.trigger_type = 'payroll_processed')
    or (event.recognition_rule = 'tax_filed_or_extended_required' and trigger.trigger_type in ('tax_filed', 'tax_extension_filed'))
    or (event.recognition_rule = 'advisory_delivery_review_required' and trigger.trigger_type = 'advisory_delivered')
    or (
      trigger.trigger_type = 'manual_recognition_approved'
      and event.recognition_status like 'pending_%'
    )
  );

create or replace view profit_manual_recognition_pending_events as
select
  event.revenue_event_key,
  event.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  event.anchor_invoice_id,
  invoice.invoice_number,
  event.macro_service_type,
  event.candidate_period_month,
  event.source_amount,
  event.recognized_amount,
  event.recognition_status,
  event.recognition_rule,
  coalesce(sum(allocation.allocated_amount), 0)::numeric as cash_allocated
from profit_revenue_events event
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = event.anchor_relationship_id
left join profit_anchor_invoices invoice
  on invoice.anchor_invoice_id = event.anchor_invoice_id
left join profit_collection_revenue_allocations allocation
  on allocation.revenue_event_key = event.revenue_event_key
where event.recognition_status like 'pending_%'
  and event.recognition_period_month is null
  and event.recognized_amount = 0
group by 1,2,3,4,5,6,7,8,9,10,11;

create or replace view profit_manual_recognition_override_audit as
select
  trigger.approved_at,
  trigger.approved_by,
  trigger.recognition_trigger_key,
  trigger.source_record_id as revenue_event_key,
  event.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  event.macro_service_type,
  event.candidate_period_month,
  event.source_amount,
  event.recognized_amount,
  event.recognition_status,
  trigger.manual_override_reason_code,
  trigger.manual_override_notes,
  trigger.manual_override_reference
from profit_recognition_triggers trigger
join profit_revenue_events event
  on event.revenue_event_key = trigger.source_record_id
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = event.anchor_relationship_id
where trigger.trigger_type = 'manual_recognition_approved';

drop view if exists profit_prepaid_liability_summary;
drop view if exists profit_prepaid_liability_balances;
drop view if exists profit_prepaid_liability_ledger;

create or replace view profit_prepaid_liability_ledger as
with event_allocations as (
  select
    allocation.revenue_event_key,
    sum(allocation.allocated_amount)::numeric as total_allocated_amount
  from profit_collection_revenue_allocations allocation
  group by 1
),
cash_entries as (
  select
    collection.collected_at as event_at,
    date_trunc('month', collection.collected_at)::date as period_month,
    'cash_collected'::text as ledger_entry_type,
    case
      when event.recognition_status = 'pending_tax_completion' then 'tax_deferred_revenue'::text
      when event.recognition_status in (
        'pending_bookkeeping_completion',
        'pending_payroll_processed',
        'pending_advisory_review'
      ) then 'pending_recognition_trigger'::text
      when event.recognition_date is not null
        or event.recognized_amount > 0
        or event.recognition_status in ('recognized_by_completion_trigger', 'recognized_by_manual_override')
        then 'recognized'::text
      else 'pending_recognition_trigger'::text
    end as service_category,
    collection.collection_key,
    allocation.allocation_key,
    allocation.revenue_event_key,
    collection.source_system,
    collection.source_payment_id,
    collection.anchor_invoice_id,
    coalesce(event.anchor_relationship_id, collection.anchor_relationship_id) as anchor_relationship_id,
    event.macro_service_type,
    event.recognition_status,
    allocation.allocated_amount::numeric as amount_delta,
    allocation.allocated_amount::numeric as collected_amount,
    0::numeric as recognized_drawdown_amount,
    allocation.rounding_delta::numeric as rounding_delta,
    allocation.allocation_method
  from profit_collection_revenue_allocations allocation
  join profit_cash_collections collection
    on collection.collection_key = allocation.collection_key
  join profit_revenue_events event
    on event.revenue_event_key = allocation.revenue_event_key
),
recognition_entries as (
  select
    event.recognition_date as event_at,
    event.recognition_period_month as period_month,
    'revenue_recognized'::text as ledger_entry_type,
    'recognized'::text as service_category,
    collection.collection_key,
    allocation.allocation_key,
    allocation.revenue_event_key,
    collection.source_system,
    collection.source_payment_id,
    collection.anchor_invoice_id,
    coalesce(event.anchor_relationship_id, collection.anchor_relationship_id) as anchor_relationship_id,
    event.macro_service_type,
    event.recognition_status,
    -least(
      allocation.allocated_amount,
      event.recognized_amount
      * (allocation.allocated_amount / nullif(event_allocations.total_allocated_amount, 0))
    )::numeric as amount_delta,
    0::numeric as collected_amount,
    least(
      allocation.allocated_amount,
      event.recognized_amount
      * (allocation.allocated_amount / nullif(event_allocations.total_allocated_amount, 0))
    )::numeric as recognized_drawdown_amount,
    0::numeric as rounding_delta,
    allocation.allocation_method
  from profit_collection_revenue_allocations allocation
  join profit_cash_collections collection
    on collection.collection_key = allocation.collection_key
  join profit_revenue_events event
    on event.revenue_event_key = allocation.revenue_event_key
  join event_allocations
    on event_allocations.revenue_event_key = allocation.revenue_event_key
  where event.recognition_date is not null
    and event.recognized_amount > 0
)
select * from cash_entries
union all
select * from recognition_entries;

create or replace view profit_prepaid_liability_balances as
select
  ledger.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  ledger.macro_service_type,
  ledger.service_category,
  sum(ledger.amount_delta)::numeric as balance,
  sum(ledger.collected_amount)::numeric as collected_amount,
  sum(ledger.recognized_drawdown_amount)::numeric as recognized_drawdown_amount,
  sum(ledger.rounding_delta)::numeric as rounding_delta,
  max(ledger.event_at) as last_updated,
  count(*)::integer as ledger_entry_count
from profit_prepaid_liability_ledger ledger
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = ledger.anchor_relationship_id
group by 1, 2, 3, 4
having sum(ledger.amount_delta) <> 0;

create or replace view profit_prepaid_liability_summary as
with balance_summary as (
  select
    coalesce(sum(balance) filter (
      where service_category = 'tax_deferred_revenue'
    ), 0)::numeric as tax_deferred_revenue_balance,
    coalesce(sum(balance) filter (
      where service_category = 'pending_recognition_trigger'
    ), 0)::numeric as trigger_backlog_balance,
    coalesce(sum(balance) filter (
      where service_category in ('tax_deferred_revenue', 'pending_recognition_trigger')
    ), 0)::numeric as total_prepaid_liability_balance,
    count(*)::integer as client_balance_count,
    max(last_updated) as last_updated
  from profit_prepaid_liability_balances
),
collection_summary as (
  select
    count(*)::integer as collection_count
  from profit_cash_collections
)
select
  balance_summary.tax_deferred_revenue_balance,
  balance_summary.trigger_backlog_balance,
  balance_summary.total_prepaid_liability_balance,
  'Delivered services with no recognition trigger loaded — not a QBO liability entry. Clears when FC completion triggers are approved.'::text as trigger_backlog_note,
  balance_summary.client_balance_count,
  collection_summary.collection_count,
  balance_summary.last_updated
from balance_summary
cross join collection_summary;
```

- [ ] **Step 4: Run the SQL test and verify it passes**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_prepaid_liability_sql.py -q
```

Expected: PASS.

### Task 2: Supabase REST Write Client

**Files:**
- Create `tests/test_profit_api_manual_recognition.py`
- Modify `profit_api/supabase.py`

- [ ] **Step 1: Write failing write-client tests**

Create `tests/test_profit_api_manual_recognition.py` with focused client coverage:

```python
from __future__ import annotations

import io
import json
import unittest

from urllib.request import Request

from profit_api.supabase import SupabaseRestClient


class FakeResponse:
    def __init__(self, payload: object, status: int = 200) -> None:
        self.payload = payload
        self.status = status

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return json.dumps(self.payload).encode("utf-8")


class RecordingOpener:
    def __init__(self, payload: object) -> None:
        self.payload = payload
        self.requests: list[Request] = []

    def __call__(self, request: Request, timeout: int = 30) -> FakeResponse:
        self.requests.append(request)
        return FakeResponse(self.payload)


class SupabaseWriteClientTest(unittest.TestCase):
    def test_insert_rows_posts_json_and_returns_rows(self) -> None:
        opener = RecordingOpener([{"id": "one"}])
        client = SupabaseRestClient(
            url="https://example.supabase.co",
            service_role_key="service-key",
            opener=opener,
        )

        rows = client.insert_rows("profit_recognition_triggers", [{"id": "one"}])

        request = opener.requests[0]
        self.assertEqual(request.get_method(), "POST")
        self.assertIn("/rest/v1/profit_recognition_triggers", request.full_url)
        self.assertEqual(request.headers["Prefer"], "return=representation")
        self.assertEqual(rows, [{"id": "one"}])

    def test_patch_rows_sends_filters_and_returns_rows(self) -> None:
        opener = RecordingOpener([{"revenue_event_key": "rev_1"}])
        client = SupabaseRestClient(
            url="https://example.supabase.co",
            service_role_key="service-key",
            opener=opener,
        )

        rows = client.patch_rows(
            "profit_revenue_events",
            filters={"revenue_event_key": "eq.rev_1"},
            payload={"recognition_status": "recognized_by_manual_override"},
        )

        request = opener.requests[0]
        self.assertEqual(request.get_method(), "PATCH")
        self.assertIn("revenue_event_key=eq.rev_1", request.full_url)
        self.assertEqual(request.headers["Prefer"], "return=representation")
        self.assertEqual(rows[0]["revenue_event_key"], "rev_1")
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: FAIL because `insert_rows()` and `patch_rows()` do not exist.

- [ ] **Step 3: Add minimal write methods**

Modify `profit_api/supabase.py`:

```python
    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        query_items: list[tuple[str, str | int]] = [("select", "*")]
        if on_conflict:
            query_items.append(("on_conflict", on_conflict))
        endpoint = f"{self.url}/rest/v1/{table_name}?{urlencode(query_items)}"
        return self._write_json(endpoint, "POST", rows)

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        query_items: list[tuple[str, str | int]] = [("select", "*")]
        query_items.extend(filters.items())
        endpoint = f"{self.url}/rest/v1/{table_name}?{urlencode(query_items)}"
        return self._write_json(endpoint, "PATCH", payload)

    def _write_json(
        self,
        endpoint: str,
        method: str,
        payload: object,
    ) -> list[dict[str, object]]:
        request = Request(
            endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "apikey": self.service_role_key,
                "Authorization": f"Bearer {self.service_role_key}",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
            method=method,
        )

        try:
            with self.opener(request, timeout=self.timeout) as response:
                body = response.read().decode("utf-8")
                response_payload = json.loads(body) if body else []
        except (HTTPError, URLError, TimeoutError) as exc:
            raise SupabaseRestError(
                f"Supabase REST write request failed: {exc}"
            ) from exc

        if not isinstance(response_payload, list):
            raise SupabaseRestError("Expected list payload from Supabase REST write")
        return response_payload
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: PASS.

### Task 3: Manual Recognition Service Validation

**Files:**
- Modify `tests/test_profit_api_manual_recognition.py`
- Create `profit_api/manual_recognition.py`

- [ ] **Step 1: Add failing service validation tests**

Append tests:

```python
from profit_api.manual_recognition import (
    ManualRecognitionError,
    ManualRecognitionService,
)


class FakeManualRecognitionStore:
    def __init__(self, pending_rows: list[dict[str, object]]) -> None:
        self.pending_rows = pending_rows
        self.read_calls: list[tuple[str, dict[str, object]]] = []
        self.inserted: list[tuple[str, list[dict[str, object]], str | None]] = []
        self.patched: list[tuple[str, dict[str, str | int], dict[str, object]]] = []

    def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
        self.read_calls.append((view_name, params))
        if view_name == "profit_manual_recognition_pending_events":
            return self.pending_rows
        if view_name == "profit_revenue_events_ready_for_recognition":
            return []
        if view_name == "profit_revenue_events":
            return []
        return []

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        self.inserted.append((table_name, rows, on_conflict))
        return rows

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        self.patched.append((table_name, filters, payload))
        return [{**payload, "revenue_event_key": filters["revenue_event_key"].replace("eq.", "")}]


class ManualRecognitionValidationTest(unittest.TestCase):
    def test_invalid_reason_code_rejected(self) -> None:
        service = ManualRecognitionService(FakeManualRecognitionStore([]))

        with self.assertRaisesRegex(ManualRecognitionError, "Invalid manual override reason_code"):
            service.apply_manual_recognition(
                revenue_event_key="rev_1",
                reason_code="not_real",
                notes="Clear notes",
                reference=None,
            )

    def test_empty_notes_rejected(self) -> None:
        service = ManualRecognitionService(FakeManualRecognitionStore([]))

        with self.assertRaisesRegex(ManualRecognitionError, "manual override notes are required"):
            service.apply_manual_recognition(
                revenue_event_key="rev_1",
                reason_code="fc_classifier_gap",
                notes="   ",
                reference=None,
            )

    def test_other_requires_twenty_characters(self) -> None:
        service = ManualRecognitionService(FakeManualRecognitionStore([]))

        with self.assertRaisesRegex(ManualRecognitionError, "other requires notes of at least 20 characters"):
            service.apply_manual_recognition(
                revenue_event_key="rev_1",
                reason_code="other",
                notes="too short",
                reference=None,
            )
```

- [ ] **Step 2: Run the validation tests and verify they fail**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: FAIL because `profit_api.manual_recognition` does not exist.

- [ ] **Step 3: Create validation service skeleton**

Create `profit_api/manual_recognition.py`:

```python
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Protocol


ManualRecognitionRow = dict[str, object]

REASON_CODES = {
    "backbill_pre_engagement",
    "client_operational_change",
    "entity_restructure",
    "service_outside_fc_scope",
    "fc_classifier_gap",
    "voided_invoice_replacement",
    "billing_amount_adjustment",
    "other",
}


class ManualRecognitionError(ValueError):
    pass


class ManualRecognitionStore(Protocol):
    def read_view(self, view_name: str, **params: str | int) -> list[ManualRecognitionRow]:
        """Read rows from Supabase REST."""

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[ManualRecognitionRow]:
        """Insert rows through Supabase REST."""

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
        payload: dict[str, object],
    ) -> list[ManualRecognitionRow]:
        """Patch rows through Supabase REST."""


@dataclass(frozen=True)
class ManualRecognitionRequest:
    revenue_event_key: str
    reason_code: str
    notes: str
    reference: str | None = None


class ManualRecognitionService:
    def __init__(self, store: ManualRecognitionStore) -> None:
        self.store = store

    def list_pending_revenue_events(
        self,
        *,
        client_filter: str | None = None,
        service_filter: str | None = None,
        period_filter: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[ManualRecognitionRow]:
        params: dict[str, str | int] = {
            "order": "candidate_period_month.desc,anchor_client_business_name.asc",
            "limit": limit,
            "offset": offset,
        }
        if client_filter:
            params["anchor_client_business_name"] = f"ilike.*{client_filter}*"
        if service_filter:
            params["macro_service_type"] = f"eq.{service_filter}"
        if period_filter:
            params["candidate_period_month"] = f"eq.{period_filter}"
        return self.store.read_view("profit_manual_recognition_pending_events", **params)

    def recent_overrides(self, *, limit: int = 50) -> list[ManualRecognitionRow]:
        return self.store.read_view(
            "profit_manual_recognition_override_audit",
            order="approved_at.desc",
            limit=limit,
        )

    def apply_manual_recognition(
        self,
        *,
        revenue_event_key: str,
        reason_code: str,
        notes: str,
        reference: str | None,
    ) -> dict[str, object]:
        self._validate_request(
            ManualRecognitionRequest(
                revenue_event_key=revenue_event_key,
                reason_code=reason_code,
                notes=notes,
                reference=reference,
            )
        )
        raise ManualRecognitionError("manual recognition apply step not implemented")

    def _validate_request(self, request: ManualRecognitionRequest) -> None:
        if not request.revenue_event_key.strip():
            raise ManualRecognitionError("revenue_event_key is required")
        if request.reason_code not in REASON_CODES:
            raise ManualRecognitionError("Invalid manual override reason_code")
        if not request.notes.strip():
            raise ManualRecognitionError("manual override notes are required")
        if request.reason_code == "other" and len(request.notes.strip()) < 20:
            raise ManualRecognitionError(
                "other requires notes of at least 20 characters"
            )
```

- [ ] **Step 4: Run the validation tests and verify they pass**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: PASS for validation tests while apply-success tests have not been added yet.

### Task 4: Manual Recognition Service Apply Flow

**Files:**
- Modify `tests/test_profit_api_manual_recognition.py`
- Modify `profit_api/manual_recognition.py`

- [ ] **Step 1: Add failing pending-list and apply-flow tests**

Append tests:

```python
class ManualRecognitionApplyTest(unittest.TestCase):
    def test_list_pending_filters_use_pending_view(self) -> None:
        store = FakeManualRecognitionStore(
            [
                {"revenue_event_key": "pending_1", "recognition_status": "pending_bookkeeping_completion"},
            ]
        )
        service = ManualRecognitionService(store)

        rows = service.list_pending_revenue_events(
            client_filter="veena",
            service_filter="tax",
            period_filter="2026-04-01",
            limit=25,
            offset=50,
        )

        self.assertEqual(rows[0]["revenue_event_key"], "pending_1")
        self.assertEqual(
            store.read_calls[0],
            (
                "profit_manual_recognition_pending_events",
                {
                    "order": "candidate_period_month.desc,anchor_client_business_name.asc",
                    "limit": 25,
                    "offset": 50,
                    "anchor_client_business_name": "ilike.*veena*",
                    "macro_service_type": "eq.tax",
                    "candidate_period_month": "eq.2026-04-01",
                },
            ),
        )

    def test_apply_rejects_event_not_pending(self) -> None:
        store = FakeManualRecognitionStore([])
        service = ManualRecognitionService(store)

        with self.assertRaisesRegex(ManualRecognitionError, "pending revenue event was not found"):
            service.apply_manual_recognition(
                revenue_event_key="recognized_rev",
                reason_code="fc_classifier_gap",
                notes="FC task existed but classifier missed it.",
                reference=None,
            )

    def test_apply_writes_trigger_and_recognizes_event(self) -> None:
        class ReadyStore(FakeManualRecognitionStore):
            def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
                self.read_calls.append((view_name, params))
                if view_name == "profit_manual_recognition_pending_events":
                    return [
                        {
                            "revenue_event_key": "rev_manual",
                            "anchor_relationship_id": "relationship-veena",
                            "macro_service_type": "tax",
                            "candidate_period_month": "2026-04-01",
                            "recognition_status": "pending_tax_completion",
                        }
                    ]
                if view_name == "profit_revenue_events_ready_for_recognition":
                    return [
                        {
                            "revenue_event_key": "rev_manual",
                            "recognized_amount_to_apply": 520,
                            "recognition_date_to_apply": "2026-05-03",
                            "recognition_period_month_to_apply": "2026-05-01",
                            "next_recognition_status": "recognized_by_manual_override",
                            "trigger_reference_to_apply": "manual_override:rev_manual",
                        }
                    ]
                if view_name == "profit_revenue_events":
                    return [
                        {
                            "revenue_event_key": "rev_manual",
                            "recognized_amount": 520,
                            "recognition_status": "recognized_by_manual_override",
                        }
                    ]
                return []

        store = ReadyStore([])
        service = ManualRecognitionService(store)

        result = service.apply_manual_recognition(
            revenue_event_key="rev_manual",
            reason_code="backbill_pre_engagement",
            notes="Veena sales tax compliance was paid and delivered before the service workflow existed.",
            reference="Anchor SBC-00118/SBC-00119",
        )

        inserted_trigger = store.inserted[0][1][0]
        self.assertEqual(store.inserted[0][0], "profit_recognition_triggers")
        self.assertEqual(inserted_trigger["trigger_type"], "manual_recognition_approved")
        self.assertEqual(inserted_trigger["manual_override_reason_code"], "backbill_pre_engagement")
        self.assertEqual(inserted_trigger["approved_by"], "orlando")
        self.assertEqual(store.patched[0][0], "profit_revenue_events")
        self.assertEqual(store.patched[0][2]["recognition_status"], "recognized_by_manual_override")
        self.assertEqual(result["revenue_event_key"], "rev_manual")
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: FAIL because `apply_manual_recognition()` still raises the temporary not-implemented error.

- [ ] **Step 3: Implement apply flow**

Replace `apply_manual_recognition()` in `profit_api/manual_recognition.py`:

```python
    def apply_manual_recognition(
        self,
        *,
        revenue_event_key: str,
        reason_code: str,
        notes: str,
        reference: str | None,
    ) -> dict[str, object]:
        request = ManualRecognitionRequest(
            revenue_event_key=revenue_event_key,
            reason_code=reason_code,
            notes=notes,
            reference=reference,
        )
        self._validate_request(request)

        pending_rows = self.store.read_view(
            "profit_manual_recognition_pending_events",
            revenue_event_key=f"eq.{request.revenue_event_key}",
            limit=1,
        )
        if not pending_rows:
            raise ManualRecognitionError("pending revenue event was not found")

        pending_event = pending_rows[0]
        now = datetime.now(timezone.utc)
        recognition_trigger_key = f"manual_override_{request.revenue_event_key}"
        trigger_row = {
            "recognition_trigger_key": recognition_trigger_key,
            "source_system": "manual_override",
            "source_record_id": request.revenue_event_key,
            "anchor_relationship_id": pending_event["anchor_relationship_id"],
            "macro_service_type": pending_event["macro_service_type"],
            "service_period_month": pending_event["candidate_period_month"],
            "completion_date": now.date().isoformat(),
            "trigger_type": "manual_recognition_approved",
            "recognition_action": "recognize_full_source_amount",
            "notes": request.notes.strip(),
            "manual_override_reason_code": request.reason_code,
            "manual_override_notes": request.notes.strip(),
            "manual_override_reference": request.reference,
            "approved_by": "orlando",
            "approved_at": now.isoformat(),
            "raw": {
                "revenue_event_key": request.revenue_event_key,
                "reason_code": request.reason_code,
                "reference": request.reference,
            },
        }
        self.store.insert_rows(
            "profit_recognition_triggers",
            [trigger_row],
            on_conflict="recognition_trigger_key",
        )

        ready_rows = self.store.read_view(
            "profit_revenue_events_ready_for_recognition",
            revenue_event_key=f"eq.{request.revenue_event_key}",
            recognition_trigger_key=f"eq.{recognition_trigger_key}",
            limit=1,
        )
        if not ready_rows:
            raise ManualRecognitionError(
                "manual override trigger did not produce a recognition-ready event"
            )

        ready = ready_rows[0]
        updated_rows = self.store.patch_rows(
            "profit_revenue_events",
            filters={"revenue_event_key": f"eq.{request.revenue_event_key}"},
            payload={
                "recognized_amount": ready["recognized_amount_to_apply"],
                "recognition_date": ready["recognition_date_to_apply"],
                "recognition_period_month": ready[
                    "recognition_period_month_to_apply"
                ],
                "recognition_status": ready["next_recognition_status"],
                "trigger_reference": ready["trigger_reference_to_apply"],
            },
        )
        if not updated_rows:
            raise ManualRecognitionError("manual recognition update returned no rows")
        return updated_rows[0]
```

- [ ] **Step 4: Run focused tests and verify they pass**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: PASS.

### Task 5: Manual Recognition API Routes

**Files:**
- Modify `tests/test_profit_api_manual_recognition.py`
- Modify `profit_api/app.py`

- [ ] **Step 1: Add failing FastAPI route tests**

Append tests:

```python
class FakeRouteService:
    def __init__(self) -> None:
        self.pending_calls: list[dict[str, object]] = []
        self.apply_calls: list[dict[str, object]] = []

    def list_pending_revenue_events(self, **kwargs: object) -> list[dict[str, object]]:
        self.pending_calls.append(kwargs)
        return [{"revenue_event_key": "rev_pending"}]

    def recent_overrides(self, *, limit: int = 50) -> list[dict[str, object]]:
        return [{"revenue_event_key": "rev_recent", "approved_by": "orlando"}]

    def apply_manual_recognition(self, **kwargs: object) -> dict[str, object]:
        self.apply_calls.append(kwargs)
        if kwargs["reason_code"] == "bad":
            raise ManualRecognitionError("Invalid manual override reason_code")
        return {
            "revenue_event_key": kwargs["revenue_event_key"],
            "recognition_status": "recognized_by_manual_override",
        }


class ManualRecognitionRouteTest(unittest.TestCase):
    def test_pending_endpoint_returns_rows(self) -> None:
        import profit_api.app as app_module

        route_service = FakeRouteService()
        app = app_module.create_app(
            service=object(),
            manual_recognition_service=route_service,
        )
        client = TestClient(app)

        response = client.get(
            "/api/profit/admin/recognition/pending",
            params={"client_filter": "veena", "service_filter": "tax", "period_filter": "2026-04-01"},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["rows"][0]["revenue_event_key"], "rev_pending")
        self.assertEqual(route_service.pending_calls[0]["period_filter"], "2026-04-01")

    def test_pending_endpoint_rejects_bad_period(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.get(
            "/api/profit/admin/recognition/pending",
            params={"period_filter": "2026-04"},
        )

        self.assertEqual(response.status_code, 422)

    def test_manual_override_endpoint_returns_422_for_validation_error(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.post(
            "/api/profit/admin/recognition/manual-override",
            json={"revenue_event_key": "rev_1", "reason_code": "bad", "notes": "Valid notes"},
        )

        self.assertEqual(response.status_code, 422)

    def test_manual_override_endpoint_returns_updated_event(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.post(
            "/api/profit/admin/recognition/manual-override",
            json={
                "revenue_event_key": "rev_1",
                "reason_code": "fc_classifier_gap",
                "notes": "FC task existed but the classifier missed it.",
                "reference": "FC task 123",
            },
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["event"]["recognition_status"], "recognized_by_manual_override")

    def test_recent_overrides_endpoint_returns_rows(self) -> None:
        import profit_api.app as app_module

        app = app_module.create_app(
            service=object(),
            manual_recognition_service=FakeRouteService(),
        )
        client = TestClient(app)

        response = client.get("/api/profit/admin/recognition/manual-overrides")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["rows"][0]["approved_by"], "orlando")
```

- [ ] **Step 2: Run API tests and verify they fail**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: FAIL because `create_app()` does not accept `manual_recognition_service` and the routes do not exist.

- [ ] **Step 3: Add routes and service wiring**

Modify `profit_api/app.py` imports:

```python
from pydantic import BaseModel

from profit_api.manual_recognition import (
    ManualRecognitionError,
    ManualRecognitionService,
)
```

Update `create_app()` signature and wiring:

```python
def create_app(
    service: AdminDashboardService | None = None,
    manual_recognition_service: ManualRecognitionService | None = None,
) -> Any:
```

After `dashboard_service`:

```python
    supabase_client = SupabaseRestClient(
        url=supabase_url,
        service_role_key=service_role_key,
    )
    dashboard_service = service or AdminDashboardService(supabase_client)
    recognition_service = manual_recognition_service or ManualRecognitionService(
        supabase_client
    )
```

Add request model inside `create_app()` module scope:

```python
class ManualOverridePayload(BaseModel):
    revenue_event_key: str
    reason_code: str
    notes: str
    reference: str | None = None
```

Add routes:

```python
    @app.get("/api/profit/admin/recognition/pending")
    def pending_recognition_events(
        client_filter: str | None = None,
        service_filter: str | None = None,
        period_filter: str | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> dict[str, object]:
        try:
            validated_period = validate_period_month(period_filter)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return {
            "rows": recognition_service.list_pending_revenue_events(
                client_filter=client_filter,
                service_filter=service_filter,
                period_filter=validated_period,
                limit=min(max(limit, 1), 200),
                offset=max(offset, 0),
            )
        }

    @app.post("/api/profit/admin/recognition/manual-override")
    def manual_recognition_override(payload: ManualOverridePayload) -> dict[str, object]:
        try:
            event = recognition_service.apply_manual_recognition(
                revenue_event_key=payload.revenue_event_key,
                reason_code=payload.reason_code,
                notes=payload.notes,
                reference=payload.reference,
            )
        except ManualRecognitionError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return {"event": event}

    @app.get("/api/profit/admin/recognition/manual-overrides")
    def recent_manual_recognition_overrides(limit: int = 50) -> dict[str, object]:
        return {
            "rows": recognition_service.recent_overrides(limit=min(max(limit, 1), 100))
        }
```

- [ ] **Step 4: Run backend manual-recognition tests and verify they pass**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_api_manual_recognition.py -q
```

Expected: PASS.

### Task 6: Frontend Route And Static Coverage

**Files:**
- Modify `tests/test_profit_admin_frontend.py`
- Create `app/frontend/src/routes/ManualRecognition.jsx`
- Modify `app/frontend/src/App.jsx`
- Modify `app/frontend/src/styles.css`

- [ ] **Step 1: Add failing frontend static assertions**

Extend `tests/test_profit_admin_frontend.py` to read both `App.jsx` and `routes/ManualRecognition.jsx`:

```python
def test_manual_recognition_route_static_contract(self) -> None:
    app_source = Path("app/frontend/src/App.jsx").read_text()
    route_source = Path("app/frontend/src/routes/ManualRecognition.jsx").read_text()
    source = app_source + "\n" + route_source

    self.assertIn("/profit/admin/recognition", source)
    self.assertIn("Manual Recognition Override", source)
    self.assertIn("Use only when FC trigger cannot fire automatically", source)
    self.assertIn("All approvals are logged", source)
    self.assertIn("/profit/admin/recognition/pending", source)
    self.assertIn("/profit/admin/recognition/manual-override", source)
    self.assertIn("/profit/admin/recognition/manual-overrides", source)
    self.assertIn("href=\"/profit/admin/recognition\"", app_source)

    for reason_code in [
        "backbill_pre_engagement",
        "client_operational_change",
        "entity_restructure",
        "service_outside_fc_scope",
        "fc_classifier_gap",
        "voided_invoice_replacement",
        "billing_amount_adjustment",
        "other",
    ]:
        self.assertIn(reason_code, source)

    self.assertIn("selectedReason", source)
    self.assertIn("notes.trim()", source)
    self.assertIn("approveDisabled", source)
    self.assertIn("Recent overrides", source)
```

- [ ] **Step 2: Run frontend static test and verify it fails**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: FAIL because `routes/ManualRecognition.jsx` does not exist and `App.jsx` has no recognition route switch.

- [ ] **Step 3: Create route component**

Create `app/frontend/src/routes/ManualRecognition.jsx`:

```jsx
import { useEffect, useMemo, useState } from "react";
import { CheckCircle2, FileCheck2, RefreshCw, Search } from "lucide-react";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const pendingEndpoint = `${apiBase}/profit/admin/recognition/pending`;
const overrideEndpoint = `${apiBase}/profit/admin/recognition/manual-override`;
const overridesEndpoint = `${apiBase}/profit/admin/recognition/manual-overrides`;

const REASON_OPTIONS = [
  ["backbill_pre_engagement", "Backbill pre-engagement"],
  ["client_operational_change", "Client operational change"],
  ["entity_restructure", "Entity restructure"],
  ["service_outside_fc_scope", "Service outside FC scope"],
  ["fc_classifier_gap", "FC classifier gap"],
  ["voided_invoice_replacement", "Voided invoice replacement"],
  ["billing_amount_adjustment", "Billing amount adjustment"],
  ["other", "Other"],
];

const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

function formatMoney(value) {
  return money.format(Number(value ?? 0));
}

function monthLabel(value) {
  if (!value) return "n/a";
  return new Date(`${value}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    year: "numeric",
  });
}

export default function ManualRecognition() {
  const [pendingRows, setPendingRows] = useState([]);
  const [recentOverrides, setRecentOverrides] = useState([]);
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [clientFilter, setClientFilter] = useState("");
  const [serviceFilter, setServiceFilter] = useState("");
  const [periodFilter, setPeriodFilter] = useState("");
  const [selectedReason, setSelectedReason] = useState("");
  const [notes, setNotes] = useState("");
  const [reference, setReference] = useState("");
  const [toast, setToast] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const approveDisabled = !selectedEvent || !selectedReason || !notes.trim() || (selectedReason === "other" && notes.trim().length < 20);

  async function loadPending() {
    const params = new URLSearchParams();
    if (clientFilter.trim()) params.set("client_filter", clientFilter.trim());
    if (serviceFilter) params.set("service_filter", serviceFilter);
    if (periodFilter) params.set("period_filter", periodFilter);
    const response = await fetch(`${pendingEndpoint}?${params.toString()}`);
    if (!response.ok) throw new Error(`Pending recognition request failed: ${response.status}`);
    const payload = await response.json();
    setPendingRows(payload.rows ?? []);
  }

  async function loadRecentOverrides() {
    const response = await fetch(overridesEndpoint);
    if (!response.ok) throw new Error(`Recent overrides request failed: ${response.status}`);
    const payload = await response.json();
    setRecentOverrides(payload.rows ?? []);
  }

  async function refreshPage() {
    setLoading(true);
    setError("");
    try {
      await Promise.all([loadPending(), loadRecentOverrides()]);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Manual recognition refresh failed");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    refreshPage();
  }, []);

  function openEvent(row) {
    setSelectedEvent(row);
    setSelectedReason("");
    setNotes("");
    setReference("");
    setToast("");
    setError("");
  }

  async function approveSelectedEvent() {
    if (approveDisabled) return;
    setLoading(true);
    setError("");
    try {
      const response = await fetch(overrideEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          revenue_event_key: selectedEvent.revenue_event_key,
          reason_code: selectedReason,
          notes,
          reference: reference || null,
        }),
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail ?? "Manual override failed");
      setToast(`Recognized ${payload.event.revenue_event_key} as ${payload.event.recognition_status}`);
      setSelectedEvent(null);
      await refreshPage();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Manual override failed");
    } finally {
      setLoading(false);
    }
  }

  const eventCountLabel = useMemo(() => `${pendingRows.length} pending events`, [pendingRows.length]);

  return (
    <main className="manual-recognition-page">
      <header className="manual-recognition-hero">
        <div>
          <p>Manual Recognition Override</p>
          <h1>Recognition gaps</h1>
          <span>Use only when FC trigger cannot fire automatically. All approvals are logged.</span>
        </div>
        <button className="icon-button" onClick={refreshPage} disabled={loading} title="Refresh manual recognition data">
          <RefreshCw size={18} aria-hidden="true" />
        </button>
      </header>

      {toast ? <div className="success-toast"><CheckCircle2 size={16} aria-hidden="true" />{toast}</div> : null}
      {error ? <div className="error-toast">{error}</div> : null}

      <section className="panel manual-filter-panel">
        <div className="panel-title">
          <Search size={18} aria-hidden="true" />
          <h2>Pending revenue events</h2>
          <span>{eventCountLabel}</span>
        </div>
        <div className="manual-filters">
          <input value={clientFilter} onChange={(event) => setClientFilter(event.target.value)} placeholder="Client" />
          <select value={serviceFilter} onChange={(event) => setServiceFilter(event.target.value)}>
            <option value="">All services</option>
            <option value="bookkeeping">Bookkeeping</option>
            <option value="payroll">Payroll</option>
            <option value="tax">Tax</option>
            <option value="advisory">Advisory</option>
            <option value="other">Other</option>
          </select>
          <input value={periodFilter} onChange={(event) => setPeriodFilter(event.target.value)} placeholder="YYYY-MM-01" />
          <button onClick={refreshPage} disabled={loading}>Apply filters</button>
        </div>
        <table>
          <thead>
            <tr>
              <th>Client</th>
              <th>Service</th>
              <th>Period</th>
              <th>Source amount</th>
              <th>Cash allocated</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {pendingRows.map((row) => (
              <tr key={row.revenue_event_key} onClick={() => openEvent(row)}>
                <td>{row.anchor_client_business_name ?? "Unassigned"}</td>
                <td>{row.macro_service_type}</td>
                <td>{monthLabel(row.candidate_period_month)}</td>
                <td>{formatMoney(row.source_amount)}</td>
                <td>{formatMoney(row.cash_allocated)}</td>
                <td>{row.recognition_status}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {selectedEvent ? (
        <aside className="manual-override-panel">
          <div className="panel-title">
            <FileCheck2 size={18} aria-hidden="true" />
            <h2>Approve and Recognize</h2>
          </div>
          <dl>
            <dt>Revenue event</dt>
            <dd>{selectedEvent.revenue_event_key}</dd>
            <dt>Client</dt>
            <dd>{selectedEvent.anchor_client_business_name ?? "Unassigned"}</dd>
            <dt>Amount</dt>
            <dd>{formatMoney(selectedEvent.source_amount)}</dd>
          </dl>
          <label>
            Reason code
            <select value={selectedReason} onChange={(event) => setSelectedReason(event.target.value)}>
              <option value="">Select reason</option>
              {REASON_OPTIONS.map(([value, label]) => (
                <option value={value} key={value}>{label}</option>
              ))}
            </select>
          </label>
          <label>
            Notes
            <textarea value={notes} onChange={(event) => setNotes(event.target.value)} />
          </label>
          <label>
            Reference
            <input value={reference} onChange={(event) => setReference(event.target.value)} placeholder="Email subject, ticket, or link" />
          </label>
          <button onClick={approveSelectedEvent} disabled={approveDisabled}>Approve and Recognize</button>
        </aside>
      ) : null}

      <section className="panel">
        <div className="panel-title">
          <FileCheck2 size={18} aria-hidden="true" />
          <h2>Recent overrides</h2>
        </div>
        <table>
          <thead>
            <tr>
              <th>Approved</th>
              <th>Event</th>
              <th>Client</th>
              <th>Service</th>
              <th>Amount</th>
              <th>Reason</th>
              <th>Approved by</th>
            </tr>
          </thead>
          <tbody>
            {recentOverrides.map((row) => (
              <tr key={row.recognition_trigger_key}>
                <td>{row.approved_at}</td>
                <td>{row.revenue_event_key}</td>
                <td>{row.anchor_client_business_name ?? "Unassigned"}</td>
                <td>{row.macro_service_type}</td>
                <td>{formatMoney(row.source_amount)}</td>
                <td>{row.manual_override_reason_code}</td>
                <td>{row.approved_by}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </main>
  );
}
```

- [ ] **Step 4: Add lightweight route switch**
- [ ] **Step 4: Add lightweight route switch and dashboard link**

Modify `app/frontend/src/App.jsx` imports:

```jsx
import ManualRecognition from "./routes/ManualRecognition.jsx";
```

At the top of `App()`:

```jsx
  if (window.location.pathname.includes("/profit/admin/recognition")) {
    return <ManualRecognition />;
  }
```

Add a subdued link near the existing refresh controls in the dashboard header:

```jsx
<a className="subtle-nav-link" href="/profit/admin/recognition">
  Manual Recognition Override
</a>
```

- [ ] **Step 5: Add focused CSS**

Append to `app/frontend/src/styles.css`:

```css
.manual-recognition-page {
  min-height: 100vh;
  padding: 24px;
  background: #f5f7f8;
  color: #182126;
}

.manual-recognition-hero {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  align-items: center;
  margin-bottom: 18px;
}

.manual-recognition-hero p,
.manual-recognition-hero span {
  margin: 0;
  color: #657178;
}

.manual-recognition-hero h1 {
  margin: 4px 0;
  font-size: 1.8rem;
}

.manual-filters {
  display: grid;
  grid-template-columns: minmax(180px, 1fr) 180px 160px auto;
  gap: 10px;
  margin: 14px 0;
}

.manual-filters input,
.manual-filters select,
.manual-override-panel input,
.manual-override-panel select,
.manual-override-panel textarea {
  width: 100%;
  border: 1px solid #d5dde1;
  border-radius: 6px;
  padding: 9px 10px;
  font: inherit;
}

.manual-override-panel {
  position: fixed;
  top: 0;
  right: 0;
  width: min(420px, 100vw);
  height: 100vh;
  overflow: auto;
  background: #ffffff;
  border-left: 1px solid #d8e0e4;
  box-shadow: -12px 0 32px rgba(24, 33, 38, 0.16);
  padding: 22px;
  z-index: 20;
}

.manual-override-panel label {
  display: block;
  margin-top: 14px;
  font-weight: 600;
}

.manual-override-panel textarea {
  min-height: 120px;
  resize: vertical;
}

.success-toast,
.error-toast {
  display: flex;
  align-items: center;
  gap: 8px;
  border-radius: 6px;
  padding: 10px 12px;
  margin-bottom: 12px;
}

.success-toast {
  background: #e9f7ef;
  color: #1f6b3f;
}

.error-toast {
  background: #fdeeee;
  color: #8a2f2f;
}

.subtle-nav-link {
  color: #52626b;
  font-size: 0.9rem;
  text-decoration: none;
}

.subtle-nav-link:hover {
  color: #182126;
  text-decoration: underline;
}

@media (max-width: 780px) {
  .manual-filters {
    grid-template-columns: 1fr;
  }
}
```

- [ ] **Step 6: Run frontend static tests and verify they pass**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py -q
```

Expected: PASS.

### Task 7: Docs

**Files:**
- Modify `docs/profit-admin-portal-review-guide.md`
- Modify `docs/data-contracts/recognition-triggers.md`

- [ ] **Step 1: Add V0.5 guide section**

Append to `docs/profit-admin-portal-review-guide.md`:

```markdown
## V0.5 Manual Recognition Override

Manual Recognition Override lives at `/profit/admin/recognition`. It is for recognition gap cases only: backbills, off-system work, classifier misses, entity restructures, voided-invoice replacements, and similar cases where a normal FC completion trigger cannot fire. It is never a tool for fixing unmatched cash, replacing the FC classifier long-term, or bypassing the normal monthly review workflow.

Each override requires one pending revenue event, a locked reason code, notes, and an approval by Orlando. The system logs the approval in `profit_recognition_triggers` with `trigger_type = manual_recognition_approved`, then applies recognition through the same ready-view path used by automated completion triggers. Excessive use of a reason code is a management signal that the underlying workflow, classifier, or source data needs structural cleanup.

A manual override is a one-shot per revenue event. If the wrong reason code or notes were entered, contact the admin to exclude the event manually (same pattern as SBC-00015) before re-attempting recognition. Reversing a manual override is intentionally out of scope.
```

- [ ] **Step 2: Add recognition trigger contract section**

Append to `docs/data-contracts/recognition-triggers.md`:

```markdown
## Manual Recognition Overrides

V0.5 adds manual override support through `profit_recognition_triggers`, not through direct revenue edits. Manual rows use `trigger_type = manual_recognition_approved`, `source_system = manual_override`, and `source_record_id = <revenue_event_key>`.

Required manual fields:

- `manual_override_reason_code`: one of `backbill_pre_engagement`, `client_operational_change`, `entity_restructure`, `service_outside_fc_scope`, `fc_classifier_gap`, `voided_invoice_replacement`, `billing_amount_adjustment`, `other`.
- `manual_override_notes`: required non-empty explanation. When reason is `other`, the API requires at least 20 characters.
- `manual_override_reference`: optional external reference such as an email subject, ticket, or link.
- `approved_by`: currently `orlando`.
- `approved_at`: timestamp of approval.

The API inserts the manual trigger, reads `profit_revenue_events_ready_for_recognition`, and patches the selected event with the ready-view output. Manual overrides produce `recognition_status = recognized_by_manual_override`. The audit surface reads `profit_manual_recognition_override_audit`, latest approvals first.
```

- [ ] **Step 3: Run docs/static tests**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest tests/test_profit_admin_frontend.py tests/test_profit_api_manual_recognition.py tests/test_prepaid_liability_sql.py -q
```

Expected: PASS.

### Task 8: Deploy And Smoke-Test Checkpoint

**Files:**
- Live Supabase migration
- VPS API/frontend deploy process

- [ ] **Step 1: Run full test suite before deploy**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: PASS, at least 99 existing tests plus the new V0.5 tests.

- [ ] **Step 2: Apply migration 013 to live Supabase**

Run from the VPS:

```bash
ssh -p 2222 root@104.225.220.36
set -a; . /opt/agents/outscore_profit/.env; set +a
psql "$SUPABASE_DB_URL" -f /opt/agents/outscore_profit/supabase/sql/013_profit_manual_recognition_override.sql
```

Expected: migration completes without SQL errors.

- [ ] **Step 3: Restart/redeploy API and frontend**

Use the existing deployment path for this repo. After files are on the VPS, restart the API:

```bash
systemctl restart profit-admin-api.service
systemctl status profit-admin-api.service --no-pager
```

Expected: service is `active (running)`.

- [ ] **Step 4: Smoke-test endpoints without approving anything**

Run from the VPS:

```bash
set -a; . /opt/agents/outscore_profit/.env; set +a
curl -s "http://127.0.0.1:8010/api/profit/admin/recognition/pending?limit=5" | python3 -m json.tool
curl -s "http://127.0.0.1:8010/api/profit/admin/recognition/manual-overrides?limit=5" | python3 -m json.tool
```

Expected: both return JSON with `rows`. Do not call the POST endpoint during smoke testing.

- [ ] **Step 5: STOP for Orlando UI spot-check**

Open `https://app.outscore.com/profit/admin/recognition` and ask Orlando to spot-check:
- Pending event filters render.
- Table rows are understandable.
- Side panel requires reason and notes before the button enables.
- All eight reason codes appear.
- Recent overrides section renders.

Stop here before commit so Orlando can confirm the live UI before the override capability goes live.

### Task 9: Final Verification, Commit, And Push

**Files:**
- All files changed in Tasks 1-8

- [ ] **Step 1: Run full test suite after spot-check approval**

Run:

```bash
PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest
```

Expected: PASS.

- [ ] **Step 2: Commit with structured message**

Run:

```bash
git status --short
git add supabase/sql/013_profit_manual_recognition_override.sql \
  profit_api/supabase.py \
  profit_api/manual_recognition.py \
  profit_api/app.py \
  tests/test_profit_api_manual_recognition.py \
  tests/test_profit_admin_frontend.py \
  tests/test_prepaid_liability_sql.py \
  app/frontend/src/routes/ManualRecognition.jsx \
  app/frontend/src/App.jsx \
  app/frontend/src/styles.css \
  docs/profit-admin-portal-review-guide.md \
  docs/data-contracts/recognition-triggers.md
git commit -m "Add manual recognition override workflow (V0.5)" \
  -m "Add audited manual_recognition_approved triggers with locked reason codes, required notes, and a single-event apply path through profit_revenue_events_ready_for_recognition." \
  -m "Add /api/profit/admin/recognition/pending, /manual-override, and /manual-overrides endpoints plus the /profit/admin/recognition route for pending events, one-off approvals, and recent override audit history." \
  -m "Manual overrides recognize one revenue event at a time as recognized_by_manual_override; bulk approval, reversal, reconciliation agents, variance tiles, and sales-tax-specific trigger types remain out of scope for later versions."
```

- [ ] **Step 3: Push**

Run:

```bash
git push
```

Expected: push succeeds.

## Out Of Scope For V0.5

- Audit/reconciliation between FC and Anchor. This is V0.6.
- Variance tolerance tile. This is V0.7.
- Sales tax recognition trigger type. This is V0.8. V0.5 still unblocks Veena's `$520` via `backbill_pre_engagement` if Orlando chooses to recognize those events manually.
- Bulk override UI. Single-event approval is deliberate because each override needs its own reason.
- Reversing or un-recognizing an override. If needed, handle as a separate controlled cleanup, similar to the SBC-00015 exclusion.
