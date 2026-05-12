# Profit Dashboard V0.7.B.4 — Labeled-Service Attribution Rule

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Quality discipline (inherited + reinforced):**
> 1. Every SQL change runs `scripts/predeploy_smoke.sh` BEFORE commit.
> 2. Every code-writing task verifies against live data, not just static SQL pattern tests.
> 3. **NEW for V0.7.B.4:** Before EACH task ships, document the operator-semantic the task is delivering in plain English. The V0.7.B.3 lesson: 4 iterative migrations shipped because I was patching syntax against latest understanding, not measuring each rule against operator semantics first.
> 4. Independent Opus audit between Task 3 (attribution view) and Task 4 (candidate views) — these are the highest-leverage tasks.

**Goal:** Implement Orlando's labeled-service attribution rule. When an Anchor agreement's service name carries a label (e.g., `"1065 Essential - NDH Holdings LLC"` or `"1065 Essential (Samdee RE - Spring Hill)"`), the SLA + Manual Invoice tracking attributes that service to the LABELED FC client, not to the agreement holder. Services with no label apply to the agreement client. This is a domain rule operator already encodes in Anchor; the system finally reads it.

**Strategic context:** V0.7.B.3 shipped 4 iterative migrations (031, 032, 032a, 033) trying to patch what turned out to be one missing semantic layer. Orlando's rule replaces all of them with a single coherent data-driven principle. V0.7.B.4 reverts V0.7.B.3's patches and ships the proper rule.

**Tech Stack:** Supabase Postgres (parsing function + attribution view + updated candidate views), FastAPI surface unchanged, React frontend minor enhancement (label badge), `scripts/predeploy_smoke.sh` mandatory at deploy.

---

## V0.7.B.4 Context

### What V0.7.B.3 got wrong

V0.7.B.3 attempted three different rules in 24 hours:
1. **031** — exclude `1040*` on business-suffix client names (LLC/Inc/Corp/LLP/PA at end of name). Too broad: hid Accelerated 1040 and others that operator wanted to see.
2. **032** — clear SLA on any paid Anchor invoice on the agreement. Conflated payment with delivery: monthly-subscription clients paid every month regardless of annual work status.
3. **032a** — tighten 032 to require invoice issued ≥ target_date. Still wrong: LTI's monthly subscription paid AFTER target but the annual 1120 work was still open in FC.
4. **033** — revert 032/032a entirely.

Net effect after revert: 24 SLA rows in queue (correct baseline before V0.7.B.4 begins).

### What the data already says (verified 2026-05-12)

Anchor agreement raw payloads carry labels in `profitSyncServiceSummary[*].name`:

| Label pattern | Live example | Resolves to |
|---|---|---|
| `"<service> - <label>"` (dash separator) | `"1065 Essential - NDH Holdings LLC"` on DVH's agreement | `NDH Holdings LLC` (fc_client_id 2426560) |
| `"<service> (<label>)"` (parentheses) | `"1065 Essential (Samdee RE - Spring Hill)"` on SamDee Lakeland's agreement | `Samdee RE (Spring Hill) LLC` (fc_client_id 2427741) |
| `"<service> - <Last, First>"` (individual) | `"1040 Plus - Menist, Samuel"` on SamDee's agreement | `Menist, Samuel E (1040)` (fc_client_id 2430341) |
| `"<service>"` (no label) | `"1120 Plus"` on Kodiak's agreement | Kodiak Enterprises LLC (agreement holder) |

### What this rule resolves

| Audit issue | Resolution via Orlando's rule |
|---|---|
| DVH 1065 in queue (work was on related entity) | Label `"- NDH Holdings LLC"` → SLA attributed to NDH, not DVH. Disappears from DVH's rows. |
| SamDee Lakeland 1065 in queue (operator says 1065 doesn't belong to Lakeland) | Label `"(Samdee RE - Spring Hill)"` → SLA attributed to Samdee RE. |
| Accelerated 1040 missing from queue (V0.7.B.3 over-broad rule) | No label → applies to Accelerated. Shows in queue. |
| Ultimate II 1040 in queue (operator agreed it should show) | No label → applies to Ultimate II. Stays in queue. |
| Kodiak 1040 (Veena's work done on Kodiak's owner's individual FC) | No label → applies to Kodiak. Operator triages via Mark reviewed once. Or operator adds label `"1040 Plus - Hornauer, Veena"` in Anchor to formalize the attribution. |

### What this rule does NOT resolve (still V0.7.D)

| Issue | Why Orlando's rule doesn't fix it |
|---|---|
| ICE of Central Florida missing entirely | The client has no Anchor agreement with auto-trigger services in SLA view. Not a label issue. V0.7.D investigation. |
| Lee's Food / Lee's Ice missing 1120/1040 rows | Same — V0.7.A's per-agreement MANUAL_INVOICE_PENDING coarseness OR SLA view doesn't track manual-trigger annual services. Separate scope. |
| Revenue events all `pending_*_completion` | Recognition pipeline not firing for any service. V0.7.D scope. |
| FC sync staleness (Lee's clients have new projects not synced) | V0.7.D Anchor sync expansion. |

### Edge cases to handle (locked decisions)

1. **Unresolved label** (label string doesn't fuzzy-match any FC client): orphan attribution — service stays under agreement holder with a `label_unresolved` flag exposed in the queue view. Operator sees it AND knows the label is unmapped. Better than silent hide.

2. **Duplicate services on same agreement** (e.g., Ultimate II has 4 `"1040 Plus"` entries): DISTINCT ON canonical_service_name. One row per (agreement, canonical_service). Document as Anchor-side data hygiene tech-debt.

3. **Joint individual names** (e.g., `"Daniel A Bachert and Marydenyse Ommert (1040)"` exists as FC client): the parsed label `"Bachert, Daniel"` or similar fuzzy-matches via normalized name. If the agreement uses `"Bachert"` only, the resolver hits the joint client. Acceptable.

4. **Label resolves to multiple FC clients** (ambiguous): treat as unresolved + flag. Operator clarifies in Anchor.

5. **Same label appears on multiple agreements** (e.g., one individual files 1040 for several LLCs they own): each labeled service attributes to the same FC client. SLA tracking aggregates the individual's overall 1040 work across all labeled instances. This is correct — operator sees the individual once with the right context.

## Migration Numbering

- `supabase/sql/034_profit_anchor_service_label_parser.sql` — pure SQL function `profit_parse_anchor_service_name(name text)` returns `(canonical text, label text)`.
- `supabase/sql/034a_profit_anchor_services_attributed.sql` — new view `profit_anchor_services_attributed` joining `profit_anchor_agreements.raw->profitSyncServiceSummary` with `profit_fc_clients` via fuzzy label resolver.
- `supabase/sql/034b_profit_sla_candidates_use_attributed.sql` — CREATE OR REPLACE `profit_sla_breached_candidates` to source from `profit_anchor_services_attributed` instead of attributing by agreement holder.
- `supabase/sql/034c_profit_manual_candidates_use_attributed.sql` — CREATE OR REPLACE `profit_manual_invoice_pending_candidates` similarly.
- `supabase/sql/034d_revert_v07_b3_patches.sql` — drop V0.7.B.3's contributions: disable `sla_invoice_paid` rule (already disabled by 033 — leave noted); drop the 1040-on-business filter from candidate views (no-op since 034b/034c rewrite them).

(Migrations 031, 032, 032a, 033 stay in repo as historical record; they're superseded by 034-series CREATE OR REPLACE statements.)

## File Structure

**SQL (Tier 1):**
- Create: 5 migrations above
- Modify: `tests/test_fulfillment_classification_sql.py`

**Frontend (Tier 2):**
- Modify: `app/frontend/src/routes/WeeklyReview.jsx` (label badge when service is attributed via label)
- Modify: `app/frontend/src/styles.css` (V0.7.B.4 CSS section)
- Modify: `tests/test_profit_admin_frontend.py`

**Docs (Tier 3):**
- Create: `docs/data-contracts/labeled-service-attribution.md`
- Modify: `docs/data-contracts/weekly-review.md`
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md` (close V0.7.B.3 entries; open V0.7.B.4 deferred items)
- Modify: `tests/test_data_references_docs.py`

**Deploy (Tier 3):**
- Uses: `scripts/predeploy_smoke.sh` for all 5 migrations
- New step: live operator walkthrough confirming DVH 1065 disappears, SamDee 1065 disappears, Accelerated 1040 appears.

---

## Task Breakdown

### Task 1: Diagnostic — Resolve 3 Edge Cases Against Live Data

**Tier:** 3 (orchestrator-direct, Opus)
**Purpose:** Eliminate ambiguity in 3 known edge cases BEFORE shipping a single line of code. The V0.7.B.3 lesson: ship-then-discover wasted 24 hours.

**Files:**
- Create: `coordination/task-1-V0.7.B.4-diagnostic.md`

**Steps:**

- [ ] **Step 1:** Catalog every labeled service across all 52 active Anchor agreements. Group by label pattern (dash vs parens vs individual-name-format). Count distinct labels.

- [ ] **Step 2:** For each distinct label, attempt fuzzy match to FC clients via:
  - Exact name match
  - Normalized name match (lowercase, strip punctuation, strip suffixes like "LLC" / "Inc")
  - Last-name-first-name reorder (for individual labels like `"Menist, Samuel"`)
  - Document the resolution rate (X% of labels resolve cleanly, Y% need disambiguation)

- [ ] **Step 3:** Sample 5 unresolved labels and trace them in Anchor + FC. Confirm the "orphan + flag" UX is the right choice vs alternative (silent hide, error to operator, etc.).

- [ ] **Step 4:** Resolve Edge Case #2 explicitly: how does the Bachert joint individual FC client `"Daniel A Bachert and Marydenyse Ommert (1040)"` interact with the Bachert Law Firm PA agreement? Does the Bachert agreement have labeled services pointing to the joint individual?

- [ ] **Step 5:** Resolve Edge Case #3: are ICE / Lee's Food / Lee's Ice missing from SLA tracking because (a) no Anchor agreement, (b) agreement exists but no SLA-trackable services, or (c) services exist but excluded by some upstream filter? Document root cause; defer FIX to V0.7.D if structural.

- [ ] **Step 6:** Surface diagnostic findings to Orlando. Wait for sign-off BEFORE Task 2.

**Expected output:** Self-contained diagnostic doc. No code. No commits.

### Task 2: Anchor Service Name Parser Function

**Tier:** 1 (Codex execution, Opus directive)
**Purpose:** Pure SQL function that extracts `(canonical_service_name, label)` from a raw service name. Foundation for all subsequent migrations.

**Files:**
- Create: `supabase/sql/034_profit_anchor_service_label_parser.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`

**Steps:**

- [ ] **Step 1: RED tests** asserting:
  - Function `profit_parse_anchor_service_name(text)` exists
  - Returns 2 columns: `canonical_service_name text`, `label text`
  - `"1120 Plus"` → `("1120 Plus", NULL)`
  - `"1065 Essential - NDH Holdings LLC"` → `("1065 Essential", "NDH Holdings LLC")`
  - `"1065 Essential (Samdee RE - Spring Hill)"` → `("1065 Essential", "Samdee RE - Spring Hill")`
  - `"1040 Plus - Menist, Samuel"` → `("1040 Plus", "Menist, Samuel")`
  - `"Accounting and Tax Services"` → `("Accounting and Tax Services", NULL)` (the " and " in middle does not trigger label parse)
  - `"1120 Essential - Schmidli Enterprises LLC"` → `("1120 Essential", "Schmidli Enterprises LLC")` (label same as agreement client; resolver later detects and treats as no-op)
  - NULL input → `(NULL, NULL)`
  - Empty string → `("", NULL)`

- [ ] **Step 2: Verify RED.** Run unittest, expect failure.

- [ ] **Step 3: Implement function.** Use regex / `regexp_match` to extract patterns. Preference order:
  1. Parenthetical at end: `^(.+?)\s+\((.+)\)\s*$`
  2. Dash-separated: `^(.+?)\s+-\s+(.+)$` (require " - " with surrounding spaces to avoid hyphenated-word false positives like "Year-End")
  3. Otherwise: return `(input, NULL)`

- [ ] **Step 4: GREEN tests.** Run full suite, all pass.

- [ ] **Step 5: Predeploy smoke gate** on 034.

- [ ] **Step 6: Live sample validation.** Run the function against all 52 agreements' service names. Spot-check 10 results for correctness. If unexpected results, fix locally BEFORE commit.

- [ ] **Step 7: Commit.**

### Task 3: Service Attribution View

**Tier:** 1 (Codex execution, Opus directive)
**Purpose:** Build `profit_anchor_services_attributed` that resolves each (agreement, service) to an `attributed_fc_client_id` using the label parser + a fuzzy FC client resolver.

**Files:**
- Create: `supabase/sql/034a_profit_anchor_services_attributed.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`

**Steps:**

- [ ] **Step 1: RED tests** asserting:
  - View `profit_anchor_services_attributed` exists
  - One row per (anchor_relationship_id, canonical_service_name) — DISTINCT ON dedupe handles Ultimate II's 4 duplicate "1040 Plus"
  - Output columns: `anchor_relationship_id`, `agreement_holder_fc_client_id`, `canonical_service_name`, `service_raw_name`, `label`, `attributed_fc_client_id`, `label_unresolved` (boolean)
  - Unlabeled service → `attributed_fc_client_id = agreement_holder_fc_client_id`, `label_unresolved = false`
  - Labeled service with resolved FC client → `attributed_fc_client_id = resolved_id`, `label_unresolved = false`
  - Labeled service with unresolved label → `attributed_fc_client_id = agreement_holder_fc_client_id`, `label_unresolved = true`
  - View preserves `trigger`, `occurrence`, `is_billed_upfront`, `price`, `status` from the source service object (needed by downstream views)

- [ ] **Step 2: Implement label resolver as CTE.** Match strategy:
  1. Exact match on `profit_fc_clients.name`
  2. Case-insensitive match
  3. Normalized match (strip "LLC", "Inc.", "Corp", punctuation, lowercase)
  4. For individual labels (pattern `"Lastname, Firstname"` or `"Firstname Lastname"`): match against FC client names containing `"Lastname"` AND `"Firstname"`
  5. Tie-break: prefer FC client whose name length is closest to label length

- [ ] **Step 3: View body.** UNNEST `raw->profitSyncServiceSummary` from active agreements, apply parser, join to resolver, output the attributed shape.

- [ ] **Step 4: GREEN tests.**

- [ ] **Step 5: Predeploy smoke gate.**

- [ ] **Step 6: Live sample validation.** Query the view for: DVH 1065 (should attribute to NDH), SamDee Lakeland 1065 (Samdee RE), Accelerated 1040 (Accelerated itself, no label). Document the labels-resolved rate and unresolved count.

- [ ] **Step 7: Commit.**

- [ ] **Step 8: Independent Opus audit checkpoint.** Spawn a fresh reviewer to audit 034 + 034a against the locked rule. Catch drift before Task 4 commits to the new attribution.

### Task 4: SLA Candidate View Uses Attribution

**Tier:** 1 (Codex execution, Opus directive)
**Purpose:** Rewrite `profit_sla_breached_candidates` to attribute services via `profit_anchor_services_attributed` instead of agreement holder. Drop V0.7.B.3's 1040-on-business filter (no longer needed).

**Files:**
- Create: `supabase/sql/034b_profit_sla_candidates_use_attributed.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`

**Steps:**

- [ ] **Step 1: RED tests** asserting:
  - `CREATE OR REPLACE VIEW profit_sla_breached_candidates` present in 034b
  - The view joins `profit_anchor_services_attributed`
  - The view's `fc_client_id` column is `attributed_fc_client_id`, NOT `agreement_holder_fc_client_id`
  - The 1040-on-business word-boundary regex from 031/032 is REMOVED
  - V0.7.B.1 T6a's completed-task + closed-project filters are PRESERVED
  - V0.7.B.3's `sla_invoice_paid` exclusion is NOT present (was reverted in 033)
  - View still outputs all current columns: `breach_state`, `breach_age_days`, `work_age_days`, `target_date`, `target_sla_day`, `assigned_staff_name`, `staff_source`, `latest_workflow_status`, `fc_task_id`, `fc_project_id`, `action_url`
  - NEW column: `label_unresolved` boolean (passed through from attribution view)
  - NEW column: `service_label` (the parsed label text, NULL for unlabeled services)

- [ ] **Step 2: Implement view.** Source from `profit_anchor_services_attributed` JOIN `profit_sla_service_items` ON `(attributed_fc_client_id, canonical_service_name)`. Preserve all existing filters (state in breached/at_risk, target_date NOT NULL, completed task NOT EXISTS, closed project NOT EXISTS).

- [ ] **Step 3: GREEN tests.**

- [ ] **Step 4: Predeploy smoke gate.**

- [ ] **Step 5: Live sample validation.** Query: DVH 1065 should NOT appear under DVH. SamDee Lakeland 1065 should NOT appear under SamDee Lakeland. Accelerated 1040 SHOULD appear under Accelerated. Confirm before commit.

- [ ] **Step 6: Commit.**

### Task 5: Manual Invoice Candidate View Uses Attribution

**Tier:** 1 (Codex execution, Opus directive)
**Purpose:** Same rewrite for `profit_manual_invoice_pending_candidates`. Bonus: this likely fixes the per-agreement vs per-service coarseness issue (Accelerated 1120/1040 will surface because they're tracked per-service per-attributed-client).

**Files:**
- Create: `supabase/sql/034c_profit_manual_candidates_use_attributed.sql`
- Modify: `tests/test_fulfillment_classification_sql.py`

**Steps:**

- [ ] **Step 1: RED tests** asserting:
  - `CREATE OR REPLACE VIEW profit_manual_invoice_pending_candidates`
  - Sources from `profit_anchor_services_attributed`
  - Per-service granularity (one row per `(attributed_fc_client_id, canonical_service_name)`), not per-agreement
  - Filters: `trigger = 'manual'`, no qbo-issued invoice for that specific service (within the agreement)
  - NEW column: `service_label` + `label_unresolved`

- [ ] **Step 2: Implement.** The qbo-issued check needs care — if invoices don't have line items, we use the agreement-level qbo_status as a coarse proxy. Document the coarseness. V0.7.D Anchor sync will tighten when line items are parsed.

- [ ] **Step 3: GREEN tests.**

- [ ] **Step 4: Predeploy smoke gate.**

- [ ] **Step 5: Live validation.** Confirm B&B's existing 5 manual-invoice rows still appear; Accelerated 1120 + 1040 surface (data quality permitting).

- [ ] **Step 6: Commit.**

### Task 6: Frontend — Label Badge + Attribution Display

**Tier:** 2 (CC subagent, Opus directive)
**Purpose:** When a queue row is attributed to a labeled FC client, show a small badge indicating "via label". When a label is unresolved, show an amber warning. Surface the canonical service name AND label inline.

**Files:**
- Modify: `app/frontend/src/routes/WeeklyReview.jsx`
- Modify: `app/frontend/src/styles.css`
- Modify: `tests/test_profit_admin_frontend.py`

**Steps:**

- [ ] **Step 1: RED tests** asserting:
  - `WeeklyReview.jsx` reads `row.service_label` and `row.label_unresolved`
  - Rendering shows the label inline when present (e.g., "1065 Essential · attributed via label" with the label visible)
  - When `label_unresolved=true`, show an amber warning ("label not resolved to a known client")
  - `styles.css` contains `/* === V0.7.B.4: Labeled service attribution === */`
  - New CSS classes: `weekly-review-label-badge`, `weekly-review-label-unresolved`

- [ ] **Step 2: Implement.** Inside the Type/Details cell, when `row.service_label` is non-null, render: `<span className="weekly-review-label-badge">via {row.service_label}</span>`. When `row.label_unresolved`, render the warning badge instead.

- [ ] **Step 3: Scoped CSS.**

- [ ] **Step 4: GREEN + Vite build.**

- [ ] **Step 5: Commit.**

### Task 7: Docs + Tech-Debt Updates

**Tier:** 3 (orchestrator-direct, Opus)
**Purpose:** New data contract for labeled service attribution. Close V0.7.B.3 tech-debt entries. Open V0.7.B.4 deferred items (per-service invoice line items, FC sync expansion, etc.).

**Files:**
- Create: `docs/data-contracts/labeled-service-attribution.md`
- Modify: `docs/data-contracts/weekly-review.md`
- Modify: `docs/data-contracts/fulfillment-classifications.md`
- Modify: `docs/tech-debt.md`
- Modify: `tests/test_data_references_docs.py`

**Steps:**

- [ ] **Step 1: RED test** asserting:
  - `labeled-service-attribution.md` exists and documents: parser function, attribution view, label resolver strategy, unresolved-label semantics, edge cases
  - `weekly-review.md` mentions label badge + unresolved warning
  - `fulfillment-classifications.md` notes the attribution layer between Anchor source and SLA/Manual candidate views
  - `tech-debt.md` lists V0.7.B.4 deferred items (per-service invoice line items in Anchor sync, etc.)
  - `tech-debt.md` STRIKETHROUGHs V0.7.B.3 entries (031/032/032a/033 superseded by 034-series)

- [ ] **Step 2: Write docs honestly.** No oversell. Acknowledge the 4 V0.7.B.3 false starts as a learning artifact.

- [ ] **Step 3: GREEN.**

- [ ] **Step 4: Commit.**

### Task 8: Deploy + Live Operator Verification

**Tier:** 3 (orchestrator-direct, Opus)
**Purpose:** Ship V0.7.B.4 via the predeploy_smoke gate. Operator-style live verification BEFORE declaring done.

**Steps:**

- [ ] **Step 1: Run predeploy smoke gate** for all 5 migrations: 034, 034a, 034b, 034c, 034d. Single invocation. Expected: all PASS.

- [ ] **Step 2: Apply migrations live in order.**

- [ ] **Step 3: Re-run `profit_apply_classification_transitions`.** Expected outcomes:
  - SLA detections for newly-visible candidates (Accelerated 1120/1040 may appear, etc.)
  - SLA clearances for candidates whose label resolved to a different fc_client_id (DVH 1065 disappears from DVH's rows)
  - Old V0.7.B.3 classifications stay superseded; new attribution-aware classifications get inserted

- [ ] **Step 4: Live queue verification.** Query `profit_weekly_review_items` and compare to expected:
  - DVH 1065 GONE (attributed to NDH)
  - SamDee Lakeland 1065 GONE (attributed to Samdee RE)
  - Accelerated 1040 PRESENT
  - Ultimate II 1040 PRESENT
  - Kodiak 1040 PRESENT (no label; operator handles via Mark reviewed)
  - Any new attributed rows for NDH, Samdee RE, Menist Samuel, etc. — these are tracked under their proper FC clients

- [ ] **Step 5: Deploy backend (no API change needed, but profit-admin-api still restarts to pick up any caching).**

- [ ] **Step 6: Build + deploy frontend.**

- [ ] **Step 7: Live operator-style verification.** Open `/admin/weekly-review`:
  - Confirm queue matches expected
  - Confirm label badges appear on rows attributed via label
  - Confirm any unresolved labels show amber warning
  - Tally total actionable rows; compare to operator-correct view

- [ ] **Step 8: Ship commit + STATE.md + runlog + push.**

- [ ] **Step 9: Independent Opus audit post-deploy.** Same fresh-reviewer protocol from V0.7.B.1.

## Task Count, Estimate, Tier Mix

- 8 tasks total
- ~1.5 days estimated (1 T3 diagnostic + 5 T1 SQL + 1 T2 frontend + 1 T3 deploy)
- Tier breakdown: 3× T3, 5× T1 (could compress 2-3 into one batch if appropriate), 1× T2

## Out-of-Scope (Deferred)

- ICE of Central Florida missing from SLA tracking entirely — V0.7.D
- Per-service invoice line item parsing (current MANUAL_INVOICE_PENDING coarseness) — V0.7.D Anchor sync expansion
- FC sync re-run for newly-created projects (Lee's clients) — operator runs FC sync manually for now; V0.7.D automates
- Revenue event recognition pipeline activation — V0.7.D investigation (why all 363 events are pending_*)
- Multi-practice routing — V0.7.E
- Per-attribution audit dashboard — V0.7.G polish

## Carry-Forward Items Addressed

- V0.7.B.3's 1040-on-business structural rule → REMOVED (replaced by Orlando's rule)
- V0.7.B.3's invoice-paid clearance → REMOVED (already reverted by 033)
- DVH 1065 false positive → RESOLVED (label `"- NDH Holdings LLC"` attributes correctly)
- SamDee Lakeland 1065 false positive → RESOLVED (label `"(Samdee RE - Spring Hill)"`)
- Accelerated 1040 missing → RESOLVED (no label = applies to Accelerated)
- Ultimate II 1040 → unchanged (correctly shown)

## Self-Review Checklist

Before declaring V0.7.B.4 shipped:

- [ ] All 8 tasks committed
- [ ] Pre-deploy smoke gate PASSED for ALL 5 migrations in a single invocation
- [ ] Live queue verification confirmed: DVH 1065 gone, SamDee Lakeland 1065 gone, Accelerated 1040 present
- [ ] Label badge rendering verified in operator UI
- [ ] Unresolved-label warning rendering verified
- [ ] Independent Opus audit returns APPROVE
- [ ] STATE.md + runlog updated
- [ ] Tech-debt.md V0.7.B.3 entries struck through
- [ ] Push to origin/main clean
- [ ] Orlando confirms via live UI that queue matches operator semantic
