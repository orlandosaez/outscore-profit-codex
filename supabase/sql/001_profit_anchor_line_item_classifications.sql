create table if not exists profit_anchor_line_item_classifications (
  anchor_line_item_id text primary key,
  anchor_invoice_id text not null,
  anchor_relationship_id text,
  parent_line_item_id text,
  qbo_product_name text,
  source_name text,
  amount numeric,
  revenue_amount numeric not null default 0,
  macro_service_type text not null,
  include_in_revenue_allocation boolean not null default false,
  classification_reason text not null,
  classified_at timestamptz not null default now()
);

create index if not exists idx_profit_anchor_line_item_classifications_invoice
  on profit_anchor_line_item_classifications (anchor_invoice_id);

create index if not exists idx_profit_anchor_line_item_classifications_relationship_macro
  on profit_anchor_line_item_classifications (anchor_relationship_id, macro_service_type)
  where include_in_revenue_allocation = true;
