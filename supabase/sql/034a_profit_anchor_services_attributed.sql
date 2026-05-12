-- Migration 034a: Anchor services attributed to FC client via label
-- V0.7.B.4 T3 — labeled service attribution
--
-- For every (active agreement, service) in Anchor:
--   - Parse the service name via profit_parse_anchor_service_name (034)
--   - If no label  → attribute to agreement holder's FC client
--   - If label resolves to an FC client (via fuzzy match) → attribute to that FC client
--   - If label doesn't resolve → orphan + flag (label_unresolved=true), stay on agreement holder
--
-- No content-specific rules. The fuzzy resolver is the discriminator between
-- entity labels (Type 1: attribute) and annotations (Type 2: keep on agreement
-- holder). Type 3 (self-reference: label = agreement client name) collapses
-- naturally because resolver picks agreement holder.
--
-- Resolver strategies (in order, first match wins):
--   1. Normalized exact match
--   2. Normalized prefix match (label is a prefix of FC name) — catches
--      "Menist, Samuel" → "Menist, Samuel E (1040)"
--      "Sullivan, Chris" → "Sullivan, Christopher (1040)"
--      "Samdee RE - Spring Hill" → "Samdee RE (Spring Hill) LLC"
--   3. Reversed-name prefix match — catches "First Last" labels mapped to
--      "Last, First" FC clients:
--      "Lee Wolfson" → "Wolfson, Lee A (1040)"
--      "Roy Surber" → "Surber, Roy (1040)"
--
-- Verified against live data (V0.7.B.4 Task 1 diagnostic):
--   13 labeled services with entity attributions → expected ~all resolve
--   10 labeled services with descriptive annotations → expected all unresolved
--   2 labeled services self-reference → expected attribute to agreement holder
--
-- Live verification gate: scripts/predeploy_smoke.sh before commit.
-- Depends on: 034 (parser function), profit_anchor_agreements,
-- profit_fc_clients, profit_fc_client_anchor_matches.

-- ----------------------------------------------------------------------
-- Helper function: normalize a name string for matching
-- Lowercase, strip punctuation, collapse spaces, strip business-suffix noise.
-- ----------------------------------------------------------------------

create or replace function profit_normalize_name_for_match(p_name text)
returns text
language sql
immutable
as $$
  select
    trim(both from
      regexp_replace(
        regexp_replace(
          regexp_replace(
            lower(coalesce(p_name, '')),
            -- Strip "(1040)" or any trailing "(...)" suffix
            '\s*\([^)]*\)\s*$', ' ', 'g'
          ),
          -- Replace " and " with " " (handles "Dirk B and Veena" → "dirk b veena")
          '\s+and\s+', ' ', 'gi'
        ),
        -- Strip punctuation: , . & - ( )
        '[,.&\-()]', ' ', 'g'
      )
    )
$$;

-- Wrap that with collapsing of multiple spaces. Done as a wrapper because
-- regexp_replace ordering matters and chaining is easier than inline.

create or replace function profit_collapse_spaces(p_name text)
returns text
language sql
immutable
as $$
  select trim(both from regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'))
$$;

-- ----------------------------------------------------------------------
-- Attribution view
-- ----------------------------------------------------------------------

create or replace view profit_anchor_services_attributed as
with raw_services as (
  -- Every service from every active agreement, with parser applied
  select
    ag.anchor_relationship_id,
    ag.client_business_name as agreement_client_business_name,
    s->>'name' as raw_service_name,
    (profit_parse_anchor_service_name(s->>'name')).canonical_service_name as canonical_service_name,
    (profit_parse_anchor_service_name(s->>'name')).label as label,
    s->>'trigger' as service_trigger,
    s->>'occurrence' as service_occurrence,
    coalesce((s->>'is_billed_upfront')::boolean, false) as service_is_billed_upfront,
    nullif(regexp_replace(coalesce(s->>'price', ''), '[^0-9.-]', '', 'g'), '')::numeric as service_price,
    s->>'status' as service_status,
    s->>'service_id' as service_id
  from profit_anchor_agreements ag
  cross join lateral jsonb_array_elements(coalesce(ag.raw->'profitSyncServiceSummary', '[]'::jsonb)) s
  where ag.display_status = 'active'
),
deduplicated_services as (
  -- Collapse duplicates (e.g., Ultimate II has 4 "1040 Plus" entries)
  -- Keep one row per (anchor_relationship_id, canonical_service_name, label)
  select distinct on (anchor_relationship_id, canonical_service_name, coalesce(label, ''))
    *
  from raw_services
  order by anchor_relationship_id, canonical_service_name, coalesce(label, ''), service_id
),
agreement_holder as (
  -- Look up the agreement's FC client via match table
  select
    ds.*,
    match.fc_client_id as agreement_holder_fc_client_id,
    holder.name as agreement_holder_fc_client_name
  from deduplicated_services ds
  left join profit_fc_client_anchor_matches match
    on match.anchor_relationship_id = ds.anchor_relationship_id
  left join profit_fc_clients holder
    on holder.fc_client_id = match.fc_client_id
),
label_resolution_candidates as (
  -- For each labeled service, find FC client candidates via three strategies
  select
    ah.*,
    fc.fc_client_id as candidate_fc_client_id,
    fc.name as candidate_fc_client_name,
    case
      -- Strategy 1: normalized exact match
      when profit_collapse_spaces(profit_normalize_name_for_match(ah.label))
         = profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
        then 1
      -- Strategy 2: normalized prefix match (label is a prefix of FC name)
      when ah.label is not null
       and profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
           like profit_collapse_spaces(profit_normalize_name_for_match(ah.label)) || ' %'
        then 2
      -- Strategy 3: last-token-first reorder match (handles "First Last"
      -- and "First1 First2 Last" labels). FC convention puts last name first.
      -- Construct: <last_token> + ' ' + <all_other_tokens_in_order>.
      -- Match either prefix (allows middle initial after) or exact.
      -- Examples:
      --   "Lee Wolfson"     → "wolfson lee"      ~ "Wolfson, Lee A (1040)" ✓
      --   "Roy Surber"      → "surber roy"       ~ "Surber, Roy (1040)" ✓ (exact)
      --   "Ken & Nancy Wong"→ "wong ken nancy"   ~ "Wong, Ken and Nancy (1040)" ✓
      when ah.label is not null
       and ah.label !~ ','
       and array_length(regexp_split_to_array(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), ' '), 1) >= 2
       and (
         profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
           like (substring(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)) from '\S+\s*$')
                || ' '
                || regexp_replace(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), '\s+\S+\s*$', '')
                || ' %')
         or
         profit_collapse_spaces(profit_normalize_name_for_match(fc.name))
           = (substring(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)) from '\S+\s*$')
              || ' '
              || regexp_replace(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), '\s+\S+\s*$', ''))
       )
        then 3
      -- Strategy 4: token-prefix tolerance for shortened first names
      -- e.g. "Sullivan, Chris" → "Sullivan, Christopher" — last label token
      -- is a prefix of an FC name token in the same position.
      -- Applied conservatively: only matches when label has comma + first
      -- letter of last token matches FC client's corresponding token.
      when ah.label is not null
       and ah.label ~ ','
       and profit_collapse_spaces(profit_normalize_name_for_match(fc.name)) like
           (split_part(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), ' ', 1)
            || ' '
            || split_part(profit_collapse_spaces(profit_normalize_name_for_match(ah.label)), ' ', 2)
            || '%')
        then 4
      else null
    end as strategy_rank
  from agreement_holder ah
  cross join profit_fc_clients fc
  where ah.label is not null
),
label_resolutions as (
  -- Pick the best (lowest strategy_rank) FC client match per labeled service.
  -- Ties broken by closest length to label.
  select distinct on (anchor_relationship_id, canonical_service_name, coalesce(label, ''))
    *
  from label_resolution_candidates
  where strategy_rank is not null
  order by
    anchor_relationship_id,
    canonical_service_name,
    coalesce(label, ''),
    strategy_rank asc,
    abs(length(candidate_fc_client_name) - length(label)) asc,
    candidate_fc_client_name asc
)
select
  ah.anchor_relationship_id,
  ah.agreement_client_business_name,
  ah.agreement_holder_fc_client_id,
  ah.agreement_holder_fc_client_name,
  ah.raw_service_name,
  ah.canonical_service_name,
  ah.label,
  -- Attribution: if label resolved, use resolved FC client; else agreement holder
  coalesce(lr.candidate_fc_client_id, ah.agreement_holder_fc_client_id) as attributed_fc_client_id,
  coalesce(lr.candidate_fc_client_name, ah.agreement_holder_fc_client_name) as attributed_fc_client_name,
  -- label_unresolved: true when label exists but no FC client matched
  (ah.label is not null and lr.candidate_fc_client_id is null) as label_unresolved,
  -- Strategy used for resolution (for audit / debugging)
  lr.strategy_rank as resolution_strategy,
  ah.service_trigger,
  ah.service_occurrence,
  ah.service_is_billed_upfront,
  ah.service_price,
  ah.service_status,
  ah.service_id
from agreement_holder ah
left join label_resolutions lr
  on lr.anchor_relationship_id = ah.anchor_relationship_id
 and lr.canonical_service_name = ah.canonical_service_name
 and coalesce(lr.label, '') = coalesce(ah.label, '');

comment on view profit_anchor_services_attributed is
  'V0.7.B.4: every active Anchor service attributed to an FC client. Unlabeled services attribute to the agreement holder. Labeled services attempt fuzzy resolution against profit_fc_clients via three strategies (normalized exact, prefix, reversed-name prefix). Unresolved labels stay on agreement holder with label_unresolved=true flag. No content-specific rules; resolver is data-driven.';
