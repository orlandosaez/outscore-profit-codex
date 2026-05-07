create table if not exists profit_classification_verdicts (
  verdict_code text primary key,
  label text not null,
  category text not null check (category in ('suppressed', 'healthy', 'pending', 'leak', 'setup_gap', 'mixed', 'manual_review', 'backfill')),
  default_visibility text not null check (default_visibility in ('show', 'hide')),
  requires_re_evaluate_at boolean not null default false,
  auto_transition_enabled boolean not null default false,
  description text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into profit_classification_verdicts (
  verdict_code,
  label,
  category,
  default_visibility,
  requires_re_evaluate_at,
  auto_transition_enabled,
  description
) values
  ('INTERNAL_FAMILY', 'Internal family', 'suppressed', 'hide', false, false, 'Saez family, SBC, or internal account. Permanent suppression.'),
  ('INACTIVE_FORMER_CLIENT', 'Inactive former client', 'suppressed', 'hide', false, true, 'Client churned. All four inactive conditions must be true; re-emergence scan supersedes this verdict if any signal returns.'),
  ('PENDING_ENGAGEMENT_DRAFT', 'Pending engagement draft', 'pending', 'show', true, true, 'Anchor agreement DRAFT, not sent. Manual classification only because Anchor API does not expose DRAFT state. Auto-transition fires when an active agreement appears for the client. re_evaluate_at default 30 days.'),
  ('PENDING_ENGAGEMENT_SENT', 'Pending engagement sent', 'pending', 'show', true, true, 'Anchor agreement SENT, awaiting client. Manual classification only because Anchor API does not expose SENT state. Auto-transition fires when an active agreement appears for the client. re_evaluate_at default 30 days.'),
  ('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'Invoice outstanding / payment pending', 'pending', 'show', false, true, 'Agreement and invoice exist; awaiting customer payment.'),
  ('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'Legacy engagement pre-Anchor', 'pending', 'show', false, true, 'Legacy engagement valid before Anchor agreement migration. Tracks migration health until first Anchor invoice fires.'),
  ('ENGAGEMENT_DECLINED', 'Engagement declined', 'suppressed', 'hide', false, false, 'Client declined this period; classification is year-aware and may re-emerge in future periods.'),
  ('LEGITIMATE_LEAK', 'Legitimate leak', 'leak', 'show', false, false, 'No agreement or billing trail exists while service work is being delivered.'),
  ('BILLING_OUTSIDE_AUDIT_WINDOW', 'Billing outside audit window', 'pending', 'show', false, false, 'Active agreement exists; annual cycle, extension, or first cycle billing is not yet due.'),
  ('BILLING_SETUP_GAP', 'Billing setup gap', 'setup_gap', 'show', false, false, 'Active agreement exists for recurring service, but recurring invoices are not firing.'),
  ('GROUP_DEFINITION_GAP', 'Group definition gap', 'setup_gap', 'show', false, false, 'The actually-billed parent is missing from the FC group definition.'),
  ('MIXED', 'Mixed', 'mixed', 'show', false, false, 'Partial billing pattern requiring manual review.'),
  ('CONSOLIDATED_VIA_GROUP_BILLED', 'Consolidated via group billed', 'healthy', 'hide', false, false, 'Work is covered by an Anchor invoice billed on a group parent entity. Informational, not a leak.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'Settled via QuickBooks payment', 'backfill', 'hide', false, true, 'Cash collected via QBO without an Anchor agreement/invoice trail. Temporary suppression; belongs in the Anchor backfill queue.')
on conflict (verdict_code) do update set
  label = excluded.label,
  category = excluded.category,
  default_visibility = excluded.default_visibility,
  requires_re_evaluate_at = excluded.requires_re_evaluate_at,
  auto_transition_enabled = excluded.auto_transition_enabled,
  description = excluded.description,
  updated_at = now();

create table if not exists profit_classifications (
  classification_id bigserial primary key,
  fc_client_id bigint references profit_fc_clients(fc_client_id),
  anchor_relationship_id text references profit_anchor_agreements(anchor_relationship_id),
  group_id bigint references profit_client_groups(group_id),
  verdict_code text not null references profit_classification_verdicts(verdict_code),
  source_verdict_raw text,
  source_audit_file text,
  source_audit_row_hash text not null,
  suggested_classification text,
  estimated_annual_revenue numeric,
  notes text,
  classified_by text not null default 'orlando',
  classified_at timestamptz not null default now(),
  re_evaluate_at date,
  auto_transition_enabled boolean not null default true,
  last_signal_hash text,
  last_signal_at timestamptz,
  superseded_at timestamptz,
  superseded_by_classification_id bigint references profit_classifications(classification_id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_audit_file, source_audit_row_hash)
);

create index if not exists idx_profit_classifications_current
  on profit_classifications (fc_client_id, verdict_code)
  where superseded_at is null;

create index if not exists idx_profit_classifications_re_evaluate
  on profit_classifications (re_evaluate_at)
  where superseded_at is null and re_evaluate_at is not null;

create index if not exists idx_profit_classifications_verdict
  on profit_classifications (verdict_code)
  where superseded_at is null;

comment on table profit_classification_verdicts is
  'Canonical fulfillment-audit verdict lookup. default_visibility and auto_transition_enabled are data, not UI hardcoding.';

comment on table profit_classifications is
  'Append-friendly fulfillment-audit verdict history seeded from manual audits and superseded by later manual or system classifications.';

create table if not exists profit_classification_transition_rules (
  from_verdict_code text not null references profit_classification_verdicts(verdict_code),
  signal_name text not null,
  to_verdict_code text not null references profit_classification_verdicts(verdict_code),
  requires_service_type_match boolean not null default true,
  enabled boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (from_verdict_code, signal_name, to_verdict_code)
);

insert into profit_classification_transition_rules (
  from_verdict_code,
  signal_name,
  to_verdict_code,
  requires_service_type_match,
  enabled,
  notes
) values
  ('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'first_matching_anchor_invoice_mid_cycle', 'BILLING_OUTSIDE_AUDIT_WINDOW', true, true, 'First matching Anchor invoice exists; annual or one-time service remains mid-cycle.'),
  ('LEGACY_ENGAGEMENT_PRE_ANCHOR', 'first_matching_anchor_invoice_group_billed', 'CONSOLIDATED_VIA_GROUP_BILLED', true, true, 'First matching Anchor invoice exists and matching service is delivered or billed through the group parent.'),
  ('PENDING_ENGAGEMENT_DRAFT', 'active_agreement_appears', 'MIXED', false, true, 'Anchor API cannot expose DRAFT. When an active agreement appears, supersede and force manual reclassification.'),
  ('PENDING_ENGAGEMENT_SENT', 'active_agreement_appears', 'MIXED', false, true, 'Anchor API cannot expose SENT. When an active agreement appears, supersede and force manual reclassification.'),
  ('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'cash_collected_group_parent', 'CONSOLIDATED_VIA_GROUP_BILLED', true, true, 'Cash collected and billed entity is a group parent.'),
  ('INVOICE_OUTSTANDING_PAYMENT_PENDING', 'cash_collected_standalone_mid_cycle', 'BILLING_OUTSIDE_AUDIT_WINDOW', true, true, 'Cash collected on standalone billing and service remains mid-cycle.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'anchor_backfill_invoice_group_parent', 'CONSOLIDATED_VIA_GROUP_BILLED', true, true, 'Anchor backfill created agreement and first invoice for group-parent billing.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'anchor_backfill_invoice_standalone', 'BILLING_OUTSIDE_AUDIT_WINDOW', true, true, 'Anchor backfill created standalone agreement and first invoice.'),
  ('SETTLED_VIA_QUICKBOOKS_PAYMENT', 'anchor_backfill_invoice_cash_pending', 'INVOICE_OUTSTANDING_PAYMENT_PENDING', true, true, 'Anchor backfill created agreement and invoice, but cash has not been collected.'),
  ('INACTIVE_FORMER_CLIENT', 'any_active_signal_returns', 'MIXED', false, true, 'Inactive client has a new signal; supersede and force manual reclassification.')
on conflict (from_verdict_code, signal_name, to_verdict_code) do update set
  requires_service_type_match = excluded.requires_service_type_match,
  enabled = excluded.enabled,
  notes = excluded.notes,
  updated_at = now();

comment on table profit_classification_transition_rules is
  'Data-driven auto-transition eligibility rules. V0.6.B.1 seeds rules; V0.6.C pipeline orchestration applies them.';
