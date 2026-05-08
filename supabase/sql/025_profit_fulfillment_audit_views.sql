create or replace view profit_fulfillment_audit_fc_activity as
select
  client.fc_client_id,
  client.name as fc_client_name,
  inactive.fc_is_archived,
  inactive.fc_archived_at,
  inactive.fc_unarchived_after_archive,
  inactive.has_post_archive_service_delivery,
  inactive.archived_at_missing_for_archived_client,
  count(task.*) filter (
    where task.task_kind = 'service_delivery'
      and task.is_completed = true
      and task.completed_at >= current_date - interval '365 days'
  )::integer as service_delivery_task_count_365d,
  max(task.completed_at) filter (
    where task.task_kind = 'service_delivery'
      and task.is_completed = true
  ) as latest_service_delivery_completed_at,
  exists (
    select 1
    from profit_fc_client_tags tag
    where tag.fc_client_id = client.fc_client_id
      and tag.tag_type in ('service', 'group')
  ) as has_fc_group_or_service_tag
from profit_fc_clients client
left join profit_audit_fc_inactive_signals inactive
  on inactive.fc_client_id = client.fc_client_id
left join profit_fc_task_delivery_classification task
  on task.fc_client_id = client.fc_client_id
group by client.fc_client_id, client.name, inactive.fc_is_archived, inactive.fc_archived_at,
  inactive.fc_unarchived_after_archive, inactive.has_post_archive_service_delivery,
  inactive.archived_at_missing_for_archived_client;

create or replace view profit_fulfillment_audit_anchor_signals as
with ranked_matches as (
  select distinct on (client.fc_client_id)
    client.fc_client_id,
    client.name as fc_client_name,
    match.anchor_relationship_id,
    match.anchor_client_business_name,
    agreement.display_status as anchor_display_status,
    agreement.effective_date as anchor_effective_date,
    match.loaded_at as match_loaded_at
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
)
select
  ranked_matches.fc_client_id,
  ranked_matches.fc_client_name,
  ranked_matches.anchor_relationship_id,
  ranked_matches.anchor_client_business_name,
  ranked_matches.anchor_display_status,
  ranked_matches.anchor_effective_date,
  exists (
    select 1
    from profit_anchor_invoices invoice
    where invoice.anchor_relationship_id = ranked_matches.anchor_relationship_id
      and invoice.issue_date >= current_date - interval '365 days'
  ) as has_anchor_invoice_365d,
  open_balance.open_invoice_balance_amount,
  open_balance.open_invoice_count,
  open_balance.last_signal_at as open_invoice_last_signal_at
from ranked_matches
left join profit_audit_open_invoice_balance_per_client open_balance
  on open_balance.fc_client_id = ranked_matches.fc_client_id;

create or replace view profit_fulfillment_audit_group_signals as
select
  client.fc_client_id,
  client.name as fc_client_name,
  count(distinct member.group_id)::integer as group_count,
  array_agg(distinct group_table.group_name order by group_table.group_name) filter (
    where group_table.group_name is not null
  ) as group_names,
  bool_or(member.active) as has_active_group_membership
from profit_fc_clients client
left join profit_client_group_members member
  on member.fc_client_id = client.fc_client_id
left join profit_client_groups group_table
  on group_table.group_id = member.group_id
group by client.fc_client_id, client.name;

create or replace view profit_fulfillment_audit_qbo_category_gaps as
with event_products as (
  select
    event.revenue_event_key,
    event.anchor_invoice_id,
    event.source_amount,
    event.canonical_service_name,
    line.qbo_product_name as qbo_product_name_raw,
    profit_qbo_product_leaf_name(line.qbo_product_name) as qbo_product_leaf_name,
    product.qbo_product_id,
    product.qbo_product_name,
    product.qbo_category_path,
    product.active as qbo_product_active,
    invoice.invoice_number,
    invoice.issue_date,
    case
      when product.qbo_product_id is null then 'missing_qbo_product'
      when product.qbo_category_path is null then 'missing_qbo_category'
      else 'matched'
    end as qbo_product_match_status,
    case
      when product.qbo_product_id is null then 'qbo_product_missing'
      when product.qbo_category_path is null then 'qbo_category_missing_on_product'
      when event.canonical_service_name is null then 'canonical_service_name_unresolved'
      else null
    end as gap_origin
  from profit_revenue_events event
  left join profit_anchor_line_item_classifications line
    on line.anchor_line_item_id = event.anchor_line_item_id
  left join profit_qbo_product_services product
    on product.qbo_product_name = profit_qbo_product_leaf_name(line.qbo_product_name)
  left join profit_anchor_invoices invoice
    on invoice.anchor_invoice_id = event.anchor_invoice_id
),
gaps as (
  select *
  from event_products
  where gap_origin is not null
)
select
  gap_origin,
  qbo_product_match_status,
  qbo_product_name_raw,
  qbo_product_leaf_name,
  qbo_product_id,
  qbo_product_name,
  qbo_category_path,
  qbo_product_active,
  count(*)::integer as revenue_event_count,
  count(*) filter (where canonical_service_name is null)::integer as canonical_unresolved_event_count,
  sum(source_amount)::numeric as total_source_amount,
  array(
    select recent.revenue_event_key
    from gaps recent
    where coalesce(recent.qbo_product_leaf_name, '') = coalesce(gaps.qbo_product_leaf_name, '')
      and recent.gap_origin = gaps.gap_origin
    order by recent.issue_date desc nulls last, recent.source_amount desc
    limit 5
  ) as sample_revenue_event_keys,
  array(
    select distinct recent.invoice_number
    from gaps recent
    where coalesce(recent.qbo_product_leaf_name, '') = coalesce(gaps.qbo_product_leaf_name, '')
      and recent.gap_origin = gaps.gap_origin
      and recent.invoice_number is not null
    order by recent.invoice_number
    limit 5
  ) as sample_invoice_numbers
from gaps
group by gap_origin, qbo_product_match_status, qbo_product_name_raw, qbo_product_leaf_name,
  qbo_product_id, qbo_product_name, qbo_category_path, qbo_product_active;

create or replace view profit_fulfillment_audit_candidates as
select
  client.fc_client_id,
  client.name as fc_client_name,
  classification.classification_id as current_classification_id,
  classification.verdict_code as current_verdict_code,
  coalesce(verdict.default_visibility, 'show') as default_visibility,
  classification.re_evaluate_at,
  fc_activity.fc_is_archived,
  fc_activity.fc_archived_at,
  fc_activity.fc_unarchived_after_archive,
  fc_activity.has_post_archive_service_delivery,
  fc_activity.archived_at_missing_for_archived_client,
  anchor.anchor_relationship_id,
  anchor.anchor_client_business_name,
  anchor.anchor_display_status,
  anchor.has_anchor_invoice_365d,
  anchor.open_invoice_balance_amount,
  group_signals.group_names,
  (
    coalesce(fc_activity.fc_is_archived, false) = false
    or coalesce(fc_activity.service_delivery_task_count_365d, 0) > 0
    or anchor.anchor_relationship_id is not null
    or anchor.has_anchor_invoice_365d
    or coalesce(anchor.open_invoice_balance_amount, 0) > 0
    or fc_activity.has_fc_group_or_service_tag
    or classification.re_evaluate_at <= current_date
  ) as any_active_signal
from profit_fc_clients client
left join lateral (
  select classification.*
  from profit_classifications classification
  where classification.fc_client_id = client.fc_client_id
    and classification.superseded_at is null
  order by classification.classified_at desc, classification.classification_id desc
  limit 1
) classification on true
left join profit_classification_verdicts verdict
  on verdict.verdict_code = classification.verdict_code
left join profit_fulfillment_audit_fc_activity fc_activity
  on fc_activity.fc_client_id = client.fc_client_id
left join profit_fulfillment_audit_anchor_signals anchor
  on anchor.fc_client_id = client.fc_client_id
left join profit_fulfillment_audit_group_signals group_signals
  on group_signals.fc_client_id = client.fc_client_id
where (
  coalesce(fc_activity.fc_is_archived, false) = false
  or coalesce(fc_activity.service_delivery_task_count_365d, 0) > 0
  or anchor.anchor_relationship_id is not null
  or anchor.has_anchor_invoice_365d
  or coalesce(anchor.open_invoice_balance_amount, 0) > 0
  or fc_activity.has_fc_group_or_service_tag
  or classification.re_evaluate_at <= current_date
);

comment on view profit_fulfillment_audit_candidates is
  'V0.6.B.2.a backend candidate view. Applies any-active-signal filter; UI default visibility must use profit_classification_verdicts.default_visibility. Unclassified candidates surface with default_visibility = show because they need manual classification by definition. Regression examples for B.2.b: Joy Property Management LLC hidden unless show-all/history; Hornauer/Wong healthy group-billed rows hidden by verdict; Inatsuka annual deliverables must not be satisfied by unrelated monthly parent billing.';

comment on view profit_fulfillment_audit_qbo_category_gaps is
  'QBO/product/category/canonical-service diagnostic view. Samples are capped at five most recent invoice rows per gap using issue_date desc then source_amount desc.';
