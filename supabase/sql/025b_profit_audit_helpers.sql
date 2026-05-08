create or replace view profit_audit_fc_inactive_signals as
select
  client.fc_client_id,
  client.name as fc_client_name,
  coalesce(client.is_archived, false) as fc_is_archived,
  client.archived_at as fc_archived_at,
  (
    coalesce(client.is_archived, false) = false
    and client.archived_at is not null
  ) as fc_unarchived_after_archive,
  (
    coalesce(client.is_archived, false) = true
    and client.archived_at is null
  ) as archived_at_missing_for_archived_client,
  exists (
    select 1
    from profit_fc_task_delivery_classification task
    where task.fc_client_id = client.fc_client_id
      and task.task_kind = 'service_delivery'
      and task.is_completed = true
      -- Closure-batch task completions can fire seconds after archived_at; treat them as offboarding artifact, not re-engagement.
      and task.completed_at > client.archived_at + interval '1 day'
  ) as has_post_archive_service_delivery,
  (
    coalesce(client.is_archived, false) = true
    and client.archived_at is not null
    and not exists (
      select 1
      from profit_fc_task_delivery_classification task
      where task.fc_client_id = client.fc_client_id
        and task.task_kind = 'service_delivery'
        and task.is_completed = true
        and task.completed_at > client.archived_at + interval '1 day'
    )
  ) as qualifies_for_inactive_former_client_review
from profit_fc_clients client;

comment on view profit_audit_fc_inactive_signals is
  'Canonical FC inactive signal view for V0.6.B.2.a. Joy Property Management LLC remains inactive because closure-day 1065 completion happened at archived_at; Saez one-second closure jitter is ignored by the one-day grace.';

create or replace function profit_qbo_product_leaf_name(raw_qbo_product_name text)
returns text
language sql
immutable
as $$
  select case
    when raw_qbo_product_name is null then null
    when raw_qbo_product_name like '%:%'
      then split_part(
        raw_qbo_product_name,
        ':',
        array_length(string_to_array(raw_qbo_product_name, ':'), 1)
      )
    else raw_qbo_product_name
  end
$$;

comment on function profit_qbo_product_leaf_name(text) is
  'Extracts the leaf QBO product name from Anchor fully-qualified product strings. Examples: Tax Work:1120 Plus -> 1120 Plus; 1120 Plus -> 1120 Plus; A:B:C -> C; Tax Work: -> empty string; NULL -> NULL.';

create or replace view profit_audit_open_invoice_balance_per_client as
with ranked_matches as (
  select distinct on (client.fc_client_id)
    client.fc_client_id,
    client.name as fc_client_name,
    match.anchor_relationship_id,
    match.anchor_client_business_name,
    agreement.display_status as anchor_display_status
  from profit_fc_clients client
  left join profit_fc_client_anchor_matches match
    on match.fc_client_id = client.fc_client_id
  left join profit_anchor_agreements agreement
    on agreement.anchor_relationship_id = match.anchor_relationship_id
  order by
    client.fc_client_id,
    case agreement.display_status
      when 'active' then 1
      when 'terminated' then 2
      when 'stale' then 3
      else 4
    end,
    match.loaded_at desc nulls last,
    match.anchor_relationship_id
),
open_invoice_balance as (
  select
    invoice.anchor_relationship_id,
    sum(greatest(coalesce(invoice.amount_due, 0), 0)) filter (
      where coalesce(invoice.amount_due, 0) > 0
        -- Canonical currently-open predicate for B.2.a. See tech debt: Anchor invoice voids do not propagate to revenue event status.
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    )::numeric as open_invoice_balance_amount,
    count(*) filter (
      where coalesce(invoice.amount_due, 0) > 0
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    )::integer as open_invoice_count,
    max(coalesce((invoice.raw->>'createdAt')::timestamptz, invoice.issue_date, invoice.last_seen_at)) filter (
      where coalesce(invoice.amount_due, 0) > 0
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    ) as last_signal_at,
    array_agg(invoice.invoice_number order by invoice.issue_date desc) filter (
      where coalesce(invoice.amount_due, 0) > 0
        and coalesce(invoice.qbo_status, '') <> 'voidSynced'
        and coalesce(invoice.display_status, '') not in ('voided', 'cancelled', 'void')
    ) as open_invoice_numbers
  from profit_anchor_invoices invoice
  group by invoice.anchor_relationship_id
)
select
  ranked_matches.fc_client_id,
  ranked_matches.fc_client_name,
  ranked_matches.anchor_relationship_id,
  ranked_matches.anchor_client_business_name,
  coalesce(open_invoice_balance.open_invoice_balance_amount, 0)::numeric as open_invoice_balance_amount,
  coalesce(open_invoice_balance.open_invoice_count, 0)::integer as open_invoice_count,
  open_invoice_balance.last_signal_at,
  coalesce(open_invoice_balance.open_invoice_numbers, array[]::text[]) as open_invoice_numbers
from ranked_matches
left join open_invoice_balance
  on open_invoice_balance.anchor_relationship_id = ranked_matches.anchor_relationship_id;

comment on view profit_audit_open_invoice_balance_per_client is
  'One row per fc_client_id. Source is Anchor invoices, not a QBO collections table. Regression locks: Celtic Auto Werks Inc has only SBC-00134 for 900.00 because SBC-00135 is voidSynced; YV Enterprises SR LLC has 834.60; Collectiv Inc excludes voidSynced SBC-00015.';
