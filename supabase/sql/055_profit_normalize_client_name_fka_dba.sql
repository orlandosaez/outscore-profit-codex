-- Migration 055: V0.7.J.1 hotfix — strip FKA / DBA / formerly-known-as markers.
--
-- Problem (discovered 2026-05-24): the V0.7.J normalizer (051) couldn't match
-- Anchor records whose business name embeds an FKA reference, e.g.:
--   FC:     "1415 Cortez Rd LLC"
--   Anchor: "1415 Cortez Rd LLC fka Midas South Bradenton LLC"
-- The pre-055 normalizer produced two different normalized strings
-- (1415cortezrd vs 1415cortezrdfkamidasouthbradenton), so exact-normalized
-- failed, the alias path failed (alias "Midas South Bradenton" did not equal
-- the full Anchor string), and trigram was well below 0.92.
--
-- V0.7.J's plan documented the workaround as "operator must rename the
-- Anchor business name to legal-name-only." On 2026-05-24 we learned Anchor
-- does not expose a rename action at the agreement level, so the operator
-- workaround is blocked. This migration fixes the normalizer instead.
--
-- Fix: strip "fka <anything>", "dba <anything>", and "formerly [known as]
-- <anything>" patterns BEFORE the existing normalization pipeline runs.
-- The marker must follow at least one whitespace character (so legal names
-- that genuinely start with a marker word — e.g., "Formerly Free Press LLC"
-- if that ever existed — are left alone), and we drop everything from the
-- marker to end-of-string.
--
-- Idempotent CREATE OR REPLACE FUNCTION; same entry point name and signature
-- as 051 so all existing callers pick up the new behavior transparently.
-- public.unaccent qualification preserved per the Supabase CREATE INDEX
-- inlining lesson from V0.7.J deploy.

create or replace function profit_normalize_client_name(value text)
returns text
language sql
immutable
as $$
  with cleaned as (
    -- public.unaccent qualification required for CREATE INDEX inlining safety.
    select lower(public.unaccent(coalesce(value, ''))) as name
  ),
  fka_dba_stripped as (
    -- V0.7.J.1: strip "fka <rest>", "dba <rest>", "formerly [known as] <rest>"
    -- including punctuated variants f/k/a, f.k.a., d/b/a, d.b.a.
    -- Leading \s+ ensures the marker is not the first word of the legal name.
    select regexp_replace(
      name,
      '\s+(fka|f[/.]k[/.]a\.?|dba|d[/.]b[/.]a\.?|formerly(\s+known\s+as)?)\M.*$',
      '',
      'g'
    ) as name
    from cleaned
  ),
  dedup_stripped as (
    select regexp_replace(name, '\s*(-[0-9]+|\([0-9]+\))$', '', 'g') as name
    from fka_dba_stripped
  ),
  parenthetical_stripped as (
    select regexp_replace(name, '\s*\([^)]*\)', '', 'g') as name
    from dedup_stripped
  ),
  ampersand_normalized as (
    select replace(name, '&', ' and ') as name
    from parenthetical_stripped
  ),
  article_stripped as (
    select regexp_replace(name, '\m(the|a|an)\M', '', 'g') as name
    from ampersand_normalized
  ),
  suffix_stripped as (
    select regexp_replace(
      name,
      '\m(llc|inc|corp|corporation|company|co|ltd|pllc|pa|lp|llp|pc|psc|lc|holdings|holding|enterprises|group|associates|partners)\M',
      '',
      'g'
    ) as name
    from article_stripped
  )
  select nullif(regexp_replace(name, '[^a-z0-9]+', '', 'g'), '')
  from suffix_stripped;
$$;

comment on function profit_normalize_client_name(text) is
  'V0.7.J.1 (055) FKA/DBA-aware normalizer. Fixture expectations: Anderson Kool Air LLC-1 -> andersonkoolair; The Bachert Law Firm PA -> bachertlawfirm; Hadar Steven -> hadarsteven; Lee''s Inc -> lees; DVH Investing LLC -> dvhinvesting; 1415 Cortez Rd LLC fka Midas South Bradenton LLC -> 1415cortezrd; 6712 Manatee Ave LLC FKA Midas North Bradenton LLC -> 6712manateeave; Smith Corp dba Smith Services -> smith; Beta LLC formerly known as Alpha Inc -> beta; Aka Industries LLC -> akaindustries (leading "Aka" not stripped because not preceded by whitespace).';

-- Verify: schema-only check. Do not invoke side-effect RPCs or inspect live data.
do $$
begin
  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'profit_normalize_client_name'
      and pg_get_function_arguments(p.oid) = 'value text'
  ) then
    raise exception '055 verify FAIL: profit_normalize_client_name(text) missing';
  end if;

  raise notice '055 verify: schema OK';
end $$;
