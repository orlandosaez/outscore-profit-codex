-- Migration 034: Anchor service name parser
-- V0.7.B.4 T2 — labeled service attribution
--
-- Pure SQL function: extract (canonical_service_name, label) from an Anchor
-- service's raw name field.
--
-- Three patterns recognized:
--   1. "<service> (<label>)"           — parenthetical label
--   2. "<service> - <label>"           — dash-separated label (requires
--                                         surrounding spaces to avoid false
--                                         positives on hyphenated words)
--   3. "<service>"                     — no label
--
-- Parser is purely structural: it doesn't decide whether the label is an
-- entity or annotation. That distinction is made downstream by the
-- attribution view's fuzzy resolver (Task 3). If the label resolves to an
-- FC client, treat as entity attribution. If it doesn't resolve, treat as
-- annotation and keep on the agreement holder.
--
-- No content-specific rules. No regex matching specific service names or
-- client patterns. Pattern extraction only.
--
-- Verified against live data (V0.7.B.4 Task 1 diagnostic):
--   "1120 Plus"                              → ("1120 Plus", NULL)
--   "1065 Essential - NDH Holdings LLC"      → ("1065 Essential", "NDH Holdings LLC")
--   "1065 Essential (Samdee RE - Spring Hill)" → ("1065 Essential", "Samdee RE - Spring Hill")
--   "1040 Plus - Menist, Samuel"             → ("1040 Plus", "Menist, Samuel")
--   "Accounting and Tax Services"            → ("Accounting and Tax Services", NULL)
--   "Year-End Close"                         → ("Year-End Close", NULL)  (hyphen, no spaces)
--   NULL                                     → (NULL, NULL)
--   ""                                       → ("", NULL)
--
-- Live verification gate: scripts/predeploy_smoke.sh before commit.
-- Depends on: none (pure function, no FK or table dependencies).

create or replace function profit_parse_anchor_service_name(p_name text)
returns table (
  canonical_service_name text,
  label text
)
language sql
immutable
as $$
  -- Discriminator: position-based precedence between dash and parens patterns.
  --   Case A: " - " appears BEFORE any "(" → dash is the outer separator.
  --           e.g. "Accounting Plus - YE Close (Apr-Dec)"  → "Accounting Plus", "YE Close (Apr-Dec)"
  --           e.g. "1040 Plus (w/ support) - Hornauer..."   → "1040 Plus (w/ support)", "Hornauer..."
  --   Case B: "(" appears first (or no " - " at all) and string ends with ")"
  --           → parens is the outer label.
  --           e.g. "1065 Essential (Samdee RE - Spring Hill)" → "1065 Essential", "Samdee RE - Spring Hill"
  --           e.g. "1040 Plus (Ken & Nancy Wong)"             → "1040 Plus", "Ken & Nancy Wong"
  --   Case C: neither pattern matches → no label.
  --           e.g. "1120 Plus" or "Year-End Close"
  with positions as (
    select
      p_name as raw,
      strpos(coalesce(p_name, ''), ' - ') as dash_pos
  ),
  paren_depth as (
    -- For the substring BEFORE the first " - ", count "(" vs ")".
    -- If counts are equal, the dash is at paren depth 0 (outside parens).
    -- If "(" count > ")" count, the dash is inside parens and should be ignored.
    select
      p.raw,
      p.dash_pos,
      case
        when p.dash_pos = 0 then 0
        else
          length(regexp_replace(substring(p.raw, 1, p.dash_pos), '[^(]', '', 'g'))
          - length(regexp_replace(substring(p.raw, 1, p.dash_pos), '[^)]', '', 'g'))
      end as depth_at_dash
    from positions p
  )
  select
    trim(both from coalesce(
      case
        -- Dash is outer separator (dash present AND outside parens)
        when dash_pos > 0 and depth_at_dash = 0
          then (regexp_match(raw, '^(.+?)\s+-\s+.+$'))[1]
        -- Parens are outer label (string ends with ")")
        when raw ~ '\(.+\)\s*$'
          then (regexp_match(raw, '^(.+?)\s+\(.+\)\s*$'))[1]
        -- No label
        else raw
      end,
      raw
    )) as canonical_service_name,

    trim(both from
      case
        when dash_pos > 0 and depth_at_dash = 0
          then (regexp_match(raw, '^.+?\s+-\s+(.+)$'))[1]
        when raw ~ '\(.+\)\s*$'
          then (regexp_match(raw, '^.+?\s+\((.+)\)\s*$'))[1]
        else null::text
      end
    ) as label
  from paren_depth;
$$;

comment on function profit_parse_anchor_service_name(text) is
  'V0.7.B.4: parse an Anchor service raw name into (canonical_service_name, label). Recognizes two label patterns: parenthetical "(<label>)" and space-dash-space " - <label>". No content-specific rules; structural pattern extraction only. Used by profit_anchor_services_attributed view to drive service-to-FC-client attribution.';
