# Anchor API Resilience Patterns

## W05/W07 Three-Tier Agreement Discovery

W05 and W07 use a three-tier fallback pattern to survive Anchor list-endpoint serializer failures while preserving their existing downstream contracts.

- W05 preserves agreement detail fetches and `profit_anchor_agreements` upserts.
- W07 preserves per-agreement invoice discovery, invoice detail fetches, and `profit_anchor_invoices` / `profit_anchor_invoice_line_items` upserts.

1. Tier 1: call `GET /agreements?limit=100`.
   - This is the normal path and preserves the existing fast behavior when Anchor's list endpoint is healthy.
   - The HTTP node must use `continueOnFail: true` and `alwaysOutputData: true`; otherwise n8n stops on a 4xx before fallback logic can run.
   - W07 keeps its active-agreement filter on this tier because invoice refresh should target known active agreements.

2. Tier 2: if Tier 1 fails, paginate `GET /agreements?limit=1&page=N`.
   - Pages that return 400 are recorded in the fallback summary and skipped.
   - Discovery continues through the known `totalCount` when available, or through a bounded safe ceiling when Anchor does not return a usable count.
   - W07's paginated calls also keep the active-agreement filter.

3. Tier 3: compare Tier 2 results to `profit_anchor_agreements.anchor_relationship_id`.
   - Any known database relationship ID not discovered by Tier 2 is still sent through the per-agreement detail fetch.
   - IDs are de-duplicated before the shared `Fetch Agreement Detail` node so downstream mapping and upsert behavior stays idempotent.
   - W07 compares against known active agreement IDs and sends every missing ID through the shared per-agreement invoice fetch.

## Why `limit=1`

The May 2026 Anchor outage showed that one broken agreement could poison larger list responses while individual agreement fetches remained healthy. `limit=15` was observed to work during that incident, but it still batches multiple agreements into the same serializer response. If any one record in a page breaks Anchor's list serializer, the whole page can fail.

Using `limit=1` isolates each agreement list serialization attempt. A single broken page no longer hides other records, and W05 can still discover every non-broken record before filling known gaps from the database cache.

## Fallback Summary

Hardened workflows include a `fallbackSummary` object in output JSON:

```json
{
  "mode": "list_full | paginated_with_gaps | per_id_only",
  "failed_list_pages": [],
  "list_discovered_count": 0,
  "known_gap_count": 0,
  "per_id_fetched_count": 0,
  "per_id_failures": []
}
```

For W07, `per_id_fetched_count` and `per_id_failures` describe the Tier 3 invoice-list fetches for known active agreements that were not returned by the list tiers.

## Stale-Marking Safety Gate

W05 marks agreements stale only when the run has enough evidence that known agreements were refreshed safely.

The stale PATCH is gated behind `stale_reconciliation_allowed`, which is true when:

- Tier 1 succeeded, or
- fallback ran and every known database gap was successfully fetched through the per-agreement detail path.

If a known gap cannot be refreshed, stale marking is skipped for that run. This prevents archiving live agreements during partial Anchor availability.

W07 does not currently perform invoice stale marking. If stale invoice reconciliation is added later, it must use the same gate: allow stale marking only when Tier 1 succeeded or every known Tier 3 gap was refreshed successfully.

## Current Coverage

As of V0.7.M.1, W05 and W07 are hardened against the Anchor list-endpoint serializer bug class.
