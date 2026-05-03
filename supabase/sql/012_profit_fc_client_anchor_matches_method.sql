alter table profit_fc_client_anchor_matches
  add column if not exists match_method text;

update profit_fc_client_anchor_matches
set match_method = match_status
where match_method is null
  and match_status in ('auto_exact', 'manual_override');

alter table profit_fc_client_anchor_matches
  alter column match_method set default 'manual_override';

alter table profit_fc_client_anchor_matches
  drop constraint if exists chk_profit_fc_client_anchor_matches_method;

alter table profit_fc_client_anchor_matches
  add constraint chk_profit_fc_client_anchor_matches_method
  check (match_method in ('auto_exact', 'manual_override'));
