-- Seed the FC tag taxonomy gap discovered during the V0.6.A Workflow 17
-- sample sweep. S 941 represents quarterly Form 941 payroll compliance.
-- Assumptions: use the existing quarterly_recurring / previous_quarter
-- recognition shape, keep service_tier/form_type_pattern null, and defer
-- actual quarterly recognition triggers to V0.6.C.

insert into profit_service_recognition_rules (
  service_name,
  macro_service_type,
  service_tier,
  recognition_pattern,
  service_period_rule,
  default_sla_day,
  form_type_pattern,
  notes,
  fc_tag,
  source,
  last_synced_at
) values (
  'form_941_quarterly',
  'payroll',
  null,
  'quarterly_recurring',
  'previous_quarter',
  30,
  null,
  'Quarterly Form 941 payroll compliance. Canonical seed added so FC tag S 941 classifies as service; recognition trigger logic deferred to V0.6.C.',
  'S 941',
  'manual_seed',
  now()
)
on conflict (service_name) do update set
  fc_tag = excluded.fc_tag,
  macro_service_type = excluded.macro_service_type,
  service_tier = excluded.service_tier,
  recognition_pattern = excluded.recognition_pattern,
  service_period_rule = excluded.service_period_rule,
  default_sla_day = excluded.default_sla_day,
  form_type_pattern = excluded.form_type_pattern,
  notes = excluded.notes,
  source = excluded.source,
  last_synced_at = now(),
  updated_at = now();

create or replace view profit_unmatched_s_prefixed_tags as
select
  ct.tag_name,
  count(*) as occurrences,
  count(distinct ct.fc_client_id) as distinct_clients,
  min(ct.synced_at) as first_seen,
  max(ct.synced_at) as last_seen
from profit_fc_client_tags ct
where ct.tag_name like 'S %'
  and ct.tag_type <> 'service'
group by ct.tag_name
order by occurrences desc;
