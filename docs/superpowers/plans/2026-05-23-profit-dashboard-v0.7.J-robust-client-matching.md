# V0.7.J — Robust Cross-System Client Matching (simple path)

**Date:** 2026-05-23
**Status:** PROPOSED
**Estimated effort:** ~3 hours
**Sprints superseded:** none

---

## Problem statement

Three systems (FC, Anchor, QBO) hold the same client under slightly different names. Today's matching (`profit_normalize_client_name()` + W25 exact-normalized join) fails silently on common variants — articles ("The Bachert Law Firm"), name-order swaps ("Hadar Steven"), trailing dedup suffixes ("Anderson Kool Air LLC-1"), FKA/DBA renames ("Midas South Bradenton" → "1415 Cortez Rd LLC"). When a silent fail occurs the pipeline routes recognition events to the wrong record, and the operator finds out via downstream symptoms instead of an audit chip.

We need:

1. Matching that survives realistic name variance without operator perfection.
2. Audit that surfaces residual gaps without being load-bearing for correctness.
3. An explicit hook for FKA / DBA renames (one row → many legitimate aliases).

We do **not** need a new client-master registry. `fc_client_id` is already the de-facto spine; FC is the CRM source of truth per the 2026-05-12 memory entry. Inventing a parallel master table multiplies failure modes and migration work for no net robustness gain at our current scale (~113 clients).

---

## Design principle

> Smallest viable change. FC remains the spine. Add fuzzy fallback + alias escape hatch only where exact-normalized fails. Audit is for visibility, never for correctness gating.

### What this plan deliberately does NOT do

- ❌ No `profit_client_master` table
- ❌ No new W30 matching workflow
- ❌ No `/profit/admin/client-matching` UI page
- ❌ No five-letter audit-category expansion (L–P)
- ❌ No hot-path view rewrite across all consumers

### What it DOES do

- ✅ Strengthen the existing normalizer to handle real-world suffixes/articles/dedup-noise
- ✅ Add **one** small alias table for operator-managed FKA/DBA rows
- ✅ Add a fuzzy-tier (trigram ≥ 0.92) fallback to the existing match-candidate view
- ✅ Add **one** audit category covering both intra-system dups ("X-1") and cross-system trigram-suspected dups
- ✅ Keep `profit_normalize_client_name` as the single normalization entry point (no v1/v2 split — superset upgrade)

---

## Tasks

### J.1 — Upgrade `profit_normalize_client_name()` (superset, no rename)

Add to existing function (migration `051_profit_normalize_client_name_v2.sql`):

- Strip leading articles: `the a an`
- Strip extended suffix list: `lp llp pc psc lc holdings holding enterprises group associates partners`
- Strip trailing dedup-noise: `-1 -2 -3 (2) (3)` from FC's auto-dedup
- Normalize `&` → `and`
- Apply `unaccent()` (enable extension if needed)

Add companion immutable function `profit_normalize_client_name_sorted(text)` returning words alphabetically sorted (catches "Hadar Steven" ↔ "Steven Hadar"). Two functions, not two columns; views call as needed.

**Files:** `supabase/sql/051_profit_normalize_client_name_v2.sql`
**Verify:** unit tests in `tests/test_normalize_client_name.py` covering 12 real cases from your client list (Anderson Kool Air LLC-1, Bachert Law Firm PA, Hadar Steven, Lee's Inc, DVH Investing LLC, The Bachert..., etc.).

**Estimated:** 30 min.

---

### J.2 — `profit_client_aliases` table (one table, three columns)

```sql
create table profit_client_aliases (
  fc_client_id  bigint not null references profit_fc_clients(fc_client_id),
  alias         text   not null,
  alias_source  text   not null check (alias_source in ('manual_fka', 'manual_dba', 'manual_legal_to_dba', 'operator_note')),
  created_at    timestamptz not null default now(),
  primary key (fc_client_id, alias)
);
```

Operator seeds rows manually for known renames. Match-candidate view (J.3) consults this table as an additional name source. No UI page in this sprint — admin can `INSERT` via existing `/profit/admin/data-quality` action queue or directly via SQL editor. UI-ification deferred to V0.7.K if needed.

**Files:** `supabase/sql/051_profit_client_aliases.sql`
**Initial seed** (operator-confirmed renames from current memory):
- `1415 Cortez Rd LLC` aliases `Midas South Bradenton`
- `6712 Manatee Ave LLC` aliases `Midas North Bradenton`

**Estimated:** 30 min.

---

### J.3 — Upgrade match-candidate view with fuzzy fallback

Replace `profit_fc_client_anchor_match_candidates` (mig 024a). Two-tier match logic:

| Tier | Condition | `match_status` | `match_confidence` |
|---|---|---|---|
| Exact | `normalize(fc.name) = normalize(anchor.name)` OR `normalize(anchor.name) IN (SELECT normalize(alias) FROM profit_client_aliases WHERE fc_client_id = fc.id)` | `auto_exact` | 1.0 |
| Fuzzy | `similarity(normalize(fc.name), normalize(anchor.name)) >= 0.92` AND no exact match exists for either side | `auto_fuzzy` | similarity score |
| Ambiguous | multiple candidates at any tier | `ambiguous` | NULL |
| Unmatched | no row | `unmatched` | 0.0 |

`profit_reconcile_fc_client_anchor_matches()` (mig 026b) already protects `manual_override` rows — keep as-is. Only add: when reconciling, treat `auto_fuzzy` rows as eligible for demotion if they fall below 0.92 on next pass.

**Files:** `supabase/sql/052_profit_fc_client_anchor_match_candidates_fuzzy.sql`
**Verify:** existing `tests/test_pipeline_backend_sql.py` regression locks still pass + new fixture rows for the seven gap cases (Bachert, Hadar Steven, Anderson Kool Air LLC-1, etc.).

**Estimated:** 45 min.

---

### J.4 — Add one audit category to `profit_data_quality_alerts`

Category **L: `client_match_suspected_dup_or_gap`** with three sub-conditions, each emitting its own row + ready-to-paste prompt:

| Sub | Fires when | Prompt |
|---|---|---|
| L.1 | FC client name matches regex `-[0-9]+$` OR `\([0-9]+\)$` | "FC client `<name>` looks like an auto-dedup of an existing record. Investigate origin (likely external integration creating duplicates) and merge into canonical FC client." |
| L.2 | Two `client_master` candidates with trigram ≥ 0.85 across FC/Anchor that don't currently link (i.e., would-have-been-fuzzy-but-below-threshold) | "FC `<a>` and Anchor `<b>` look like the same client (similarity X.XX). Confirm or add alias to `profit_client_aliases`." |
| L.3 | An Anchor agreement has `client_business_name` that doesn't match ANY FC client under either exact, fuzzy, or alias | "Anchor agreement `<id>` for `<name>` has no FC client link. Either create FC client first (preferred per V0.7.J workflow) or add to `profit_client_aliases`." |

**Files:** `supabase/sql/053_profit_data_quality_alerts_client_match.sql`
**Verify:** snapshot test in `tests/test_profit_api_data_quality.py` — given a fixture with Anderson Kool Air LLC-1 + Bachert near-dup, view emits expected rows.

**Estimated:** 45 min.

---

### J.5 — Threading: make every existing hot-path view see J.1 + J.2

Every view that calls `profit_normalize_client_name(...)` already picks up J.1 automatically (function superset). The only consumer that needs to touch aliases is the match-candidate view (J.3 already covers it).

**Verification audit only — no code changes expected.** Grep the codebase for callers of `profit_normalize_client_name` and confirm each one will behave correctly with the expanded normalization (e.g., does stripping "the" break any pinned regression case? Run full test suite.)

**Files:** none expected (audit-only)
**Verify:** full `pytest` green; spot-check 5 verdicts on dashboard pre-/post-deploy.

**Estimated:** 30 min.

---

## Total scope

| Task | Effort | New objects |
|---|---|---|
| J.1 | 30 min | 1 function upgrade + 1 new sort function |
| J.2 | 30 min | 1 table |
| J.3 | 45 min | 1 view replacement |
| J.4 | 45 min | 1 audit category (L) |
| J.5 | 30 min | 0 (verification only) |
| **Total** | **~3 hrs** | **3 SQL objects + 1 table** |

For comparison, the master-registry version was ~8 hrs and added 1 table + 1 workflow + 1 UI page + 5 audit categories + N view rewrites.

---

## Success criteria

1. `profit_normalize_client_name('Anderson Kool Air LLC-1') = profit_normalize_client_name('Anderson Kool Air LLC')`
2. `profit_normalize_client_name('The Bachert Law Firm PA') = profit_normalize_client_name('Bachert Law Firm')`
3. `profit_normalize_client_name_sorted('Hadar Steven') = profit_normalize_client_name_sorted('Steven Hadar')`
4. Match candidates view returns `auto_exact` for `1415 Cortez Rd LLC` ↔ Anchor `Midas South Bradenton` (via alias)
5. `profit_data_quality_alerts` surfaces Anderson Kool Air LLC-1 as L.1 the next pipeline run
6. All existing tests pass
7. No hot-path verdict changes for any of the 113 active clients except for newly-resolved formerly-unmatched cases (which is the point)

---

## Risks & rollback

| Risk | Mitigation |
|---|---|
| Stripping "the" or "&" produces unintended collisions (e.g., "The Capital LLC" ↔ "Capital LLC" — actually different) | Run pre/post normalization diff before deploy; manually whitelist collisions to `profit_client_aliases` with `alias_source='operator_note'` |
| Trigram threshold 0.92 too low → false fuzzy matches | Tier is **auto_fuzzy**, not **auto_exact** — reconcile + audit catch drift; can raise to 0.94 with one line change |
| Alias table not maintained → stale renames | L.3 audit category fires until operator adds alias |

**Rollback:** revert the three migration files (051, 052, 053). No data loss — `profit_client_aliases` content survives revert if you `DROP TABLE` is not in the down-migration.

---

## Sequencing & deploy

Single-session deploy (no inter-phase pause needed). Run order:

1. Migration 051 (normalizer + sort function)
2. Migration 052 (aliases table + match candidates view)
3. Migration 053 (audit category L)
4. Run `pytest tests/` — must be green
5. Trigger one manual pipeline run via `/profit/admin/pipeline` to validate
6. Spot-check `/profit/admin/data-quality` — expect Anderson Kool Air LLC-1 row to appear under L.1

Total deploy time: ~10 min after code lands.

---

## Out of scope (deferred or rejected)

- **Master client registry** — rejected as architectural overkill at 113-client scale; revisit only if cross-system identity becomes unmanageable
- **Operator UI for aliases** — deferred to V0.7.K if SQL-only proves painful
- **QBO-side matching** — Anchor handles QBO mapping internally; audit already catches `invoice_client_not_mapped`; no new code needed here
- **Metaphone / phonetic matching** — not needed if trigram + sorted normalizer covers the realistic variance set; revisit if specific phonetic typos slip through
- **Auto-merge of FC duplicates** — destructive; operator must merge in FC's native UI

---

## Test plan

New tests:

- `tests/test_normalize_client_name.py` — 12 normalization fixtures
- Extend `tests/test_pipeline_backend_sql.py` — 7 match-candidate fixtures (the gap cases)
- Extend `tests/test_profit_api_data_quality.py` — L.1, L.2, L.3 snapshot

Manual:

- Trigger pipeline run on prod
- Compare verdict count diff pre/post on `/profit/admin/dashboard` — should change only for previously-unmatched cases

---

## Memory entries to update on completion

- `client_staff_assignments.md` — note that FC remains the spine; J.2 aliases are operator-managed escape hatch
- `self_audit_data_quality_alerts.md` — add category L (3 sub-conditions) to the canonical list
- New entry: `client_matching_robustness.md` — document the two-tier match (exact/fuzzy) + alias precedence for future reference
