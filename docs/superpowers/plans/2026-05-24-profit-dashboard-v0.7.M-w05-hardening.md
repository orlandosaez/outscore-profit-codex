# V0.7.M — Harden W05 against Anchor list-serializer bugs

**Date:** 2026-05-24
**Status:** PROPOSED
**Estimated effort:** ~1.5–2 hours Codex
**Trigger:** 2026-05-24 outage where one Anchor agreement (B&B Technology Solutions) with pending amendments caused Anchor's `GET /agreements?limit=100` to return `400 record not found` for 18+ hours, blocking W05's first step and the entire W26 pipeline.

---

## Problem statement

W05 ("Profit – 05 Anchor Agreements Sync") currently has a single point of failure: the **`GET /agreements?limit=100`** discovery call. When that call 400s, the entire workflow halts at step 1, and downstream sync of agreement details never runs. W26 pipeline orchestration treats W05 as a hard dependency and halts as well.

On 2026-05-24, a single agreement entered a pending-amendment state that broke Anchor's list-endpoint serializer. The list returned 400 for any `limit ≥ 20`, but:

- `GET /agreements?limit=15` worked (paginating with smaller limits returned 55 of 56 agreements)
- `GET /agreements/{relationship_id}` worked for every individual agreement including the broken one
- The bug was 100% on Anchor's side, server-side serialization issue

The pipeline was offline for ~18 hours awaiting amendment auto-approval. Operator visibility was good (V0.7.I cron audit fired correctly), but the pipeline itself could have been kept running with a graceful fallback.

## Design goal

W05 should survive Anchor list-endpoint failures by falling back to per-agreement fetches using known relationship_ids from our database, while still discovering new agreements when the list endpoint works.

## Proposed fallback chain

1. **Try list endpoint at `limit=100`** (current behavior)
   - On 200: proceed as today
   - On 400/5xx: fall through
2. **Try list endpoint at `limit=15`** (proven safe even under today's bug)
   - Paginate page=1, page=2, … until totalCount reached
   - Skip pages that 400 (record their indices)
   - On all-pages-OK: combine and proceed
   - On any-page-fail: fall through with partial-list + known list of broken pages
3. **Per-ID fallback**: for any relationship_id known in `profit_anchor_agreements` (our DB cache) that wasn't returned by the list, call `GET /agreements/{id}` individually
   - This ensures we always sync every known agreement
   - Trade-off: doesn't discover NEW agreements created on Anchor side that we don't yet know about, but that's preferable to a full pipeline halt

## Out of scope

- ❌ No retry-on-transient-5xx logic (separate concern, network reliability)
- ❌ No rewrite of W05's downstream transformations (Materialize Agreements code node stays as-is)
- ❌ No changes to W07 (invoices), W17 (FC), or other workflows — even though they may have similar bugs, fix one workflow per sprint
- ❌ No fix on Anchor's side — that's Yair's team, separate from us

## Migrations + workflow changes

- **No SQL migrations.** This is purely an n8n workflow edit.
- **File: `n8n/workflows/profit-05-anchor-agreements-sync.json`**
- Add nodes:
  1. "Try list at limit=100" (existing) → If node → on 4xx/5xx, branch to fallback
  2. "Try list at limit=15 paginated" (new code node + HTTP loop)
  3. "Identify gaps" (compare Anchor's returned IDs to our DB's known IDs)
  4. "Per-ID fetch for gaps" (loop over missing IDs, fetch individually)
  5. "Combine results" (merge full-list + paginated + per-ID into one stream)
- Existing "Fetch Agreement Detail" node continues unchanged downstream

## Test plan

- Unit-style assertions on the workflow JSON structure (similar to existing `tests/test_n8n_workflows.py`):
  - W05 has a fallback branch after the list call
  - W05 has a code node that paginates at limit=15
  - W05 has a code node that fetches by ID for gaps
- Manual smoke test against prod:
  1. Trigger W05 manually while B&B (or any broken agreement) still has pending amendments
  2. Verify W05 completes successfully despite list-at-100 failing
  3. Verify all 56 agreements were synced to `profit_anchor_agreements`

## Success criteria

1. W05 succeeds end-to-end even when `GET /agreements?limit=100` returns 400
2. All known agreements (per `profit_anchor_agreements`) get refreshed every run
3. New agreements (added in Anchor since last sync) still get discovered when list endpoint is healthy
4. No regression: when list endpoint works at limit=100, W05 behaves exactly as today (no extra API calls, no extra time)
5. n8n workflow tests pass + smoke gate passes

## Risk + rollback

| Risk | Mitigation |
|---|---|
| Per-ID fetch loop adds load on Anchor's API when list is healthy | Only triggers on list-call failure; healthy path unchanged |
| Combining results from multiple sources could create duplicates | De-dup by relationship_id before downstream Materialize node |
| Workflow JSON gets more complex, harder to reason about | Keep fallback as a SEPARATE branch chain rather than wrapping the existing logic |

Rollback: revert workflow JSON to current state. No data loss possible since fallback is read-only from Anchor's perspective.

## Sequencing

Same-day deploy after Phase 2. Single workflow edit + re-import to n8n + smoke test against prod with B&B still in pending-amendment state (the bug window is open until ~20:30 UTC tomorrow, perfect natural test).

## Memory entries to update on completion

- `pipeline_troubleshooting_playbook.md` — add "list-endpoint failure fallback" diagnostic scenario (when W05 takes longer than usual but succeeds, fallback was invoked)
- New entry: `anchor_api_resilience_patterns.md` documenting the fallback chain so similar patterns can be applied to W07/W17 if needed later
