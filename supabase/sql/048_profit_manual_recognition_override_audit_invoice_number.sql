-- Migration 048: expose invoice_number on profit_manual_recognition_override_audit
--
-- Operator UX 2026-05-18: the Manual Recognition admin page shows revenue
-- event keys (e.g. "...cuSnehWv") in BOTH the side-panel detail AND the
-- Recent overrides log. Operators map this back to Anchor manually by
-- looking at SBC-XXXXX invoice numbers. Add invoice_number to the audit
-- view so the UI can show "SBC-00065" instead of (or alongside) the
-- cryptic key. Side-panel display already updated separately (frontend
-- consumes invoice_number from profit_manual_recognition_pending_events,
-- which already exposes it).
--
-- Schema change: append anchor_invoice_id + invoice_number at the END of
-- the SELECT list. Existing column order preserved per CREATE OR REPLACE
-- VIEW constraint.

create or replace view profit_manual_recognition_override_audit as
select
  trigger.approved_at,
  trigger.approved_by,
  trigger.recognition_trigger_key,
  trigger.source_record_id as revenue_event_key,
  event.anchor_relationship_id,
  agreement.client_business_name as anchor_client_business_name,
  event.macro_service_type,
  event.candidate_period_month,
  event.source_amount,
  event.recognized_amount,
  event.recognition_status,
  trigger.manual_override_reason_code,
  trigger.manual_override_notes,
  trigger.manual_override_reference,
  -- 048: appended for operator readability — maps event_key → SBC-XXXXX
  event.anchor_invoice_id,
  invoice.invoice_number
from profit_recognition_triggers trigger
join profit_revenue_events event
  on event.revenue_event_key = trigger.source_record_id
left join profit_anchor_agreements agreement
  on agreement.anchor_relationship_id = event.anchor_relationship_id
left join profit_anchor_invoices invoice
  on invoice.anchor_invoice_id = event.anchor_invoice_id
where trigger.trigger_type = 'manual_recognition_approved'::text;

comment on view profit_manual_recognition_override_audit is
  '048: Recent manual override log. Adds anchor_invoice_id + invoice_number
   so UI can display SBC-XXXXX alongside revenue_event_key. Used by
   /admin/recognition Recent overrides panel.';

do $$
declare
  v_with_inv integer;
  v_total integer;
begin
  select count(*) filter (where invoice_number is not null), count(*)
    into v_with_inv, v_total
    from profit_manual_recognition_override_audit;
  raise notice '048 verify: % / % rows have invoice_number', v_with_inv, v_total;
end $$;
