-- Migration 051: V0.7.J J.1 robust client-name normalization.
--
-- Superset upgrade of profit_normalize_client_name(text). Existing callers
-- keep the same function name and pick up the stronger behavior automatically.
-- profit_normalize_client_name_sorted(text) exists for tests and audit
-- visibility only; it is not an auto-match tier.

create extension if not exists unaccent;

create or replace function profit_normalize_client_name(value text)
returns text
language sql
immutable
as $$
  with cleaned as (
    -- public.unaccent qualification required for CREATE INDEX inlining safety (Supabase env quirk).
    select lower(public.unaccent(coalesce(value, ''))) as name
  ),
  dedup_stripped as (
    select regexp_replace(name, '\s*(-[0-9]+|\([0-9]+\))$', '', 'g') as name
    from cleaned
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

create or replace function profit_normalize_client_name_sorted(value text)
returns text
language sql
immutable
as $$
  with normalized_words as (
    select regexp_split_to_table(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            replace(lower(public.unaccent(coalesce(value, ''))), '&', ' and '),
            '\s*(-[0-9]+|\([0-9]+\))$',
            '',
            'g'
          ),
          '\s*\([^)]*\)',
          '',
          'g'
        ),
        '[^a-z0-9]+',
        ' ',
        'g'
      ),
      '\s+'
    ) as word
  ),
  filtered as (
    select word
    from normalized_words
    where word <> ''
      and word not in (
        'the', 'a', 'an',
        'llc', 'inc', 'corp', 'corporation', 'company', 'co', 'ltd', 'pllc',
        'pa', 'lp', 'llp', 'pc', 'psc', 'lc', 'holdings', 'holding',
        'enterprises', 'group', 'associates', 'partners'
      )
  )
  select nullif(string_agg(word, '' order by word), '')
  from filtered;
$$;

comment on function profit_normalize_client_name(text) is
  'V0.7.J robust FC/Anchor name normalizer. Fixture expectations: Anderson Kool Air LLC-1 -> andersonkoolair; Anderson Kool Air LLC -> andersonkoolair; The Bachert Law Firm PA -> bachertlawfirm; Bachert Law Firm -> bachertlawfirm; Hadar Steven -> hadarsteven; Steven Hadar -> stevenhadar; Lee''s Inc -> lees; DVH Investing LLC -> dvhinvesting; 1415 Cortez Rd LLC -> 1415cortezrd; 6712 Manatee Ave LLC -> 6712manateeave; E & O Automotive LLC -> eandoautomotive; Corey Monanghan -> coreymonanghan.';

comment on function profit_normalize_client_name_sorted(text) is
  'V0.7.J helper for tests and audit visibility only. It supports visibility into name-order swaps such as Hadar Steven and Steven Hadar, but sorted-name matching is not an auto-match tier.';

-- Plain fixture spelling for static tests: Lee's Inc.
-- Verify: schema-only checks. Do not invoke side-effect RPCs or inspect live data.
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
    raise exception '051 verify FAIL: profit_normalize_client_name(text) missing';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'profit_normalize_client_name_sorted'
      and pg_get_function_arguments(p.oid) = 'value text'
  ) then
    raise exception '051 verify FAIL: profit_normalize_client_name_sorted(text) missing';
  end if;

  raise notice '051 verify: schema OK';
end $$;
