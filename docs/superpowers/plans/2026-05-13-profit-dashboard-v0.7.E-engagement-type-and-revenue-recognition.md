# Profit Dashboard V0.7.E — Engagement Type + Revenue Recognition Realignment

**Strategic context:** Outscore's signed Terms & Conditions (`docs/Outscore-T&C-5-6-26.pdf`, see `tc_revenue_recognition_principle.md` memory file for verbatim quotes) creates two distinct revenue regimes: Subscription (earned on receipt) and Project (earned on delivery). The current "Prepaid Liability" dashboard tile mislabels subscription cash as GAAP liability — contradicts the contract. V0.7.E corrects the surface, the chart of accounts, and the operator mental model.

**Authoritative principle:** Subscription Monthly Fees are NOT a GAAP liability. Only Project Engagement prepayments are real Deferred Revenue.

**Goal:** Realign dashboard labels + introduce engagement_type metadata so all downstream features (manual invoice signals, deferred revenue booking, labor-cost forecasting) treat the two regimes correctly.

**Tech Stack:** Supabase Postgres views/columns, FastAPI changes minimal, React frontend tile rewrite, FC Open API for bulk-populating the new engagement_type custom field. No content-specific rules.

---

## Locked Decisions (read first)

1. **engagement_type lives in FC custom_fields** — follows the same operator-managed-in-FC pattern locked 2026-05-12 for staff assignments. Field name: `Engagement Type`. Allowed values: `Subscription` / `Project` / `Mixed`. Populated via FC Open API (`POST /api/v1/about-fields` + bulk `PATCH /api/v1/clients/{cid}/about-fields/{field_id}`).
2. **Dashboard tile split** — replace one ambiguous "Prepaid Liability" tile with two: `Deferred Revenue (Project Engagements)` (true GAAP liability) and `Subscription Service Reserve` (management metric, labeled NOT-a-liability).
3. **Manual Invoice Pending semantic rewrite** — filter to Project Engagement clients only; trigger on FC `is_closed=TRUE` + no matching invoice. Subscription clients drop out of the candidate set entirely (their invoices are recurring/automatic).
4. **No new QBO liability account for subscription deferrals.** Period.
5. **Subscription Service Reserve quoted in labor cost (dollars or days)**, not collected cash. Reads `profit_service_recognition_rules` × hourly rate from `profit_client_staff_assignments` + `staff_rates`.

## Sub-Slice Sequence + Dependencies

```
V0.7.E.2 (engagement_type tagging)  ──┬──> V0.7.D-3 (Manual Invoice rewrite)
                                       ├──> V0.7.E.1 (tile split)
                                       └──> V0.7.E.3 (Subscription Service Reserve)
```

V0.7.E.2 is the foundation; nothing else can start without it. The other three are mostly parallel-eligible once E.2 ships.

---

## V0.7.E.2 — Engagement Type Tagging (Foundation)

**Goal:** Every active FC client carries an `Engagement Type` value: Subscription / Project / Mixed.

**Tier:** 3 orchestrator-direct (same pattern as 2026-05-12 FC custom-field bulk operation).

**Tasks:**

### E.2-T1: Create FC custom-field definitions
- `POST /api/v1/about-fields` with `{"name": "Engagement Type"}` → record new field_id
- Verify via `GET /api/v1/about-fields`
- Document the new field_id in `client_staff_assignments.md` memory alongside the existing 4 fields

### E.2-T2: Operator-supplied initial value mapping
- Orlando provides the Subscription/Project/Mixed classification for each active FC client
- Methods (operator's choice): (a) inline operator decision tree (each client a row), or (b) bulk classification by group/tag pattern, or (c) my heuristic + operator override (default to "Subscription" if `profit_anchor_agreements.raw->'subscription'` exists, else "Project")
- Surface to operator BEFORE bulk PATCH for spot-check (Gate 3 pattern from 2026-05-12)

### E.2-T3: Bulk PATCH `Engagement Type` on every client
- Same 1 req/sec throttle + checkpoint pattern as 2026-05-12 bulk staff PATCH
- Log to `/opt/agents/outscore_profit/logs/fc_bulk_engagement_type_<ts>.log`
- Operator approval gate before bulk run

### E.2-T4: Supabase view extracts engagement_type
- Migration `037_profit_fc_client_engagement_type.sql`: extends `profit_fc_client_staff_from_custom_fields` to include `engagement_type` column (or create sibling view `profit_fc_client_engagement_type`)
- Schema-mirroring with `tax_preparer`/`book_primary` etc.
- Trigger an immediate W26 sync after bulk PATCH so Supabase reflects the new values same-day

### E.2-T5: Verification
- Per-engagement-type client count (Subscription / Project / Mixed / unset)
- Spot-check: top 5 clients in each bucket match operator's mental model
- Document in `weekly-review.md` doc

**Acceptance:** every active FC client has a non-null `Engagement Type`; Supabase reflects it; the view is consumable by downstream slices.

---

## V0.7.D-3 — Manual Invoice Pending Semantic Rewrite (depends on E.2)

**Goal:** Replace the current subscription-style MANUAL_INVOICE_PENDING signal with a delivery-driven one matching the operator's mental model.

**Tier:** 1 Codex (SQL migration + apply function update).

**Current behavior (V0.7.A):**
- Surfaces when an active Anchor agreement has at least one `trigger='manual'` service in `profitSyncServiceSummary` AND no QBO-issued invoice for that agreement
- Per-AGREEMENT granularity
- Fires for Subscription clients with manual-trigger services (false positives — those don't need a per-deliverable invoice)

**Target behavior (V0.7.D-3):**
- Filters to clients with `engagement_type = 'Project'` or `'Mixed'` (excludes pure Subscription)
- Per-FC-PROJECT granularity (one signal per closed project)
- Predicate:
  - `profit_fc_projects.is_closed = TRUE`
  - Client's engagement_type ≠ 'Subscription'
  - No matching `profit_anchor_invoices` row issued AFTER the project's `closed_at`
- Clearance: matching invoice appears

**Migrations:**
- `038_profit_manual_invoice_pending_v2.sql` — new candidate view `profit_manual_invoice_pending_candidates_v2` (or CREATE OR REPLACE existing one). Drop the legacy agreement-level shape.
- Apply function rewrite: replace `manual_invoice_detection_signals` CTE to use the new per-project predicate.

**Frontend:** No changes (queue already renders MANUAL_INVOICE_PENDING; only the candidate set changes).

**Tier-1 plan-draft directive will spec full detail.**

---

## V0.7.E.1 — Dashboard Tile Split (depends on E.2)

**Goal:** Replace the "Prepaid Liability · point-in-time" block with two correctly-labeled tiles.

**Tier:** 2 CC subagent (single-route React + scoped CSS) + 1 Tier-3 SQL migration for the new tile data source.

**Tile A: Deferred Revenue (Project Engagements)**
- Source: `profit_prepaid_liability_summary` filtered to clients with `engagement_type IN ('Project', 'Mixed')`
- Subtitle: *"Cash collected for projects with work not yet delivered. Record this in QBO as Deferred Revenue."*
- Tooltip: link to QBO chart of accounts setup guide
- Drill-down: existing prepaid-liability drilldown panel, but filtered

**Tile B: Subscription Service Reserve · point-in-time**
- Source: NEW view `profit_subscription_service_reserve` (computed in V0.7.E.3)
- Subtitle: *"Forward labor cost for in-scope subscription deliverables not yet performed. Earned on receipt per T&C — not a QBO liability. Use for cash-flow planning."*
- Quoted in $X labor cost AND Y labor days
- No QBO instruction (explicit anti-instruction in tooltip)

**Migrations:**
- `039_profit_prepaid_liability_engagement_split.sql` — adds `engagement_type` join to the existing summary view; produces two distinct balance fields

**Frontend:**
- Modify `app/frontend/src/routes/Dashboard.jsx`: split the prepaid stat into two
- Modify `app/frontend/src/styles.css`: scoped styling for the new tiles (distinct color treatment — Project = red/orange "real liability", Subscription = blue/gray "internal metric")
- Drop the misleading "Record this as Deferred Revenue in QuickBooks" instruction from the subscription side

---

## V0.7.E.3 — Subscription Service Reserve Calculation (depends on E.2)

**Goal:** Compute the labor-cost forward exposure for in-scope subscription deliverables.

**Tier:** 1 Codex (SQL view with multi-table joins).

**Inputs:**
- Active Anchor agreements where client's `engagement_type IN ('Subscription', 'Mixed')`
- For each agreement: `profit_anchor_services_attributed` × `profit_service_recognition_rules` to know which deliverables are in scope and when they're expected
- For each deliverable: estimated labor cost = `default_sla_day` × estimated hours per service tier × billable rate from `profit_client_staff_assignments` joined to `staff_rates`
- Filter: only deliverables NOT YET PERFORMED (no matching FC project `is_closed=TRUE`)

**Output view:** `profit_subscription_service_reserve`
- Per-client: total embedded labor cost not yet performed (next 90 days + next 12 months projections)
- Firm-wide rollup: total forward labor commitment

**Operator use:**
- Owner distribution decision: don't distribute more than (cash on hand − Subscription Service Reserve − operating runway)
- Capacity planning: if reserve climbing faster than labor capacity → over-selling subscriptions relative to staffing

**Migrations:**
- `040_profit_subscription_service_reserve.sql` — new view + supporting calc

**Acceptance:** view returns realistic labor-cost forecasts; spot-check 3 representative clients (1 pure Subscription tax, 1 Mixed, 1 Subscription bookkeeping).

---

## Out of Scope (for V0.7.E)

- Subscription Service Reserve drill-down at the deliverable level (UX could land in V0.7.G polish)
- Auto-emit QBO journal entries (operator manually books the Deferred Revenue tile number — automation deferred)
- Per-engagement embedded labor reserve view in admin/audit (V0.7.F refactor)
- Discretionary Goodwill Credit booking automation (manual today; defer)

## Quality Gates Inherited

- `scripts/predeploy_smoke.sh` mandatory at every migration apply
- Live operator-style verification at each task gate
- FC API operations follow 2026-05-12 audit pattern (Gate 1-5)
- Memory `tc_revenue_recognition_principle.md` consulted at any revenue-recognition design decision
