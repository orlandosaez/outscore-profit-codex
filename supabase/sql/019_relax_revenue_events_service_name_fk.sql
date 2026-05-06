do $$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'profit_revenue_events_service_name_fkey'
  ) then
    alter table profit_revenue_events
      drop constraint profit_revenue_events_service_name_fkey;
  end if;
end $$;

comment on column profit_revenue_events.service_name is
  'Raw service name from Anchor line item description. May include prorations, client name suffixes, or custom annotations. Not enforced by FK. V0.6 will add canonical service resolution via alias table; until then, joins to profit_service_recognition_rules by exact name will only resolve cases where the descriptive name matches canonical exactly.';
