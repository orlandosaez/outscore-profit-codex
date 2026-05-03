alter table profit_recognition_triggers
  add column if not exists manual_override_batch_id text;

create index if not exists idx_profit_recognition_triggers_batch_id
  on profit_recognition_triggers (manual_override_batch_id)
  where manual_override_batch_id is not null;
