-- Migration 035c: Add entity_type metadata to service recognition rules (V0.7.D-1)
--
-- Purpose: enable 1120 C-corp vs S-corp deadline disambiguation per V0.7.D
-- gate G3 (operator-managed metadata on profit_service_recognition_rules).
-- Nullable column with no initial seed per OQ3 lock — operator populates
-- rows on demand when a specific 1120 case surfaces.
--
-- Background: V0.7.B day-one found ~24 1120 rows in the queue with March 15
-- target_date applied uniformly. April 15 → May 15 each year, C-corp clients
-- show as breached against the wrong deadline (C-corp uses April 15, S-corp
-- uses March 15). V0.7.D defers the actual target-date branching to a future
-- task that consumes this column — this migration just adds the metadata
-- slot so the catalog can carry the distinction.
--
-- Note: V0.7.D Task 1 found FC client raw->custom_fields contains an "Entity
-- Type" field too (1 client populated as "LLC", 29 blank, 107 with no
-- custom_fields exposed). That's a secondary source that could feed this
-- column automatically later, but the canonical source remains the service
-- catalog so different services for the same client can have different
-- target dates (1120 vs 1040 for an owner who's both employee and Schedule C).
--
-- No content-specific rules. Column is operator-managed metadata.
--
-- Depends on: profit_service_recognition_rules (V0.5.2.1).
-- Predeploy_smoke.sh gate must pass before live apply.

alter table profit_service_recognition_rules
  add column if not exists entity_type text;

comment on column profit_service_recognition_rules.entity_type is
  'V0.7.D-1: operator-managed entity-type metadata (e.g., ''C-corp'', ''S-corp'') for service recognition rules that need entity-aware target-date calculation. Nullable; no initial seed per OQ3 lock. Future task consumes this column to branch target_date computation (e.g., 1120 C-corp target = April 15, S-corp target = March 15). Secondary input source: FC client raw->custom_fields[*]->>"Entity Type" (when operator populates in FC).';
