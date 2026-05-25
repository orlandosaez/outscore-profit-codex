# Anchor API Resilience Patterns

## W05 Three-Tier Agreement Discovery

W05 uses a three-tier fallback pattern to survive Anchor list-endpoint serializer failures while preserving the existing downstream agreement detail and upsert contract.

1. Tier 1: call `GET /agreements?limit=100`.
   - This is the normal path and preserves the existing fast behavior when Anchor's list endpoint is healthy.
   - The HTTP node must use `continueOnFail: true` and `alwaysOutputData: true`; otherwise n8n stops on a 4xx before fallback logic can run.

2. Tier 2: if Tier 1 fails, paginate `GET /agreements?limit=1&page=N`.
   - Pages that return 400 are recorded in the fallback summary and skipped.
   - Discovery continues through the known `totalCount` when available, or through a bounded safe ceiling when Anchor does not return a usable count.

3. Tier 3: compare Tier 2 results to `profit_anchor_agreements.anchor_relationship_id`.
   - Any known database relationship ID not discovered by Tier 2 is still sent through the per-agreement detail fetch.
   - IDs are de-duplicated before the shared `Fetch Agreement Detail` node so downstream mapping and upsert behavior stays idempotent.

## Why `limit=1`

The May 2026 Anchor outage showed that one broken agreement could poison larger list responses while individual agreement fetches remained healthy. `limit=15` was observed to work during that incident, but it still batches multiple agreements into the same serializer response. If any one record in a page breaks Anchor's list serializer, the whole page can fail.

Using `limit=1` isolates each agreement list serialization attempt. A single broken page no longer hides other records, and W05 can still discover every non-broken record before filling known gaps from the database cache.

## Stale-Marking Safety Gate

W05 marks agreements stale only when the run has enough evidence that known agreements were refreshed safely.

The stale PATCH is gated behind `stale_reconciliation_allowed`, which is true when:

- Tier 1 succeeded, or
- fallback ran and every known database gap was successfully fetched through the per-agreement detail path.

If a known gap cannot be refreshed, stale marking is skipped for that run. This prevents archiving live agreements during partial Anchor availability.

## Next Candidate

W07 has the same exposure and is the next candidate to apply this pattern.
