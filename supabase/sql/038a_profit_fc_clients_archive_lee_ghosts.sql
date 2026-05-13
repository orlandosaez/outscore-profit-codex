-- Migration 038a: archive 2 stale Lee's ghost FC records (V0.7.D-3 hotfix Part A)
--
-- Operator audit 2026-05-13 found 2 FC client records that haven't been
-- synced by W17 since 2026-05-09:
--   - 4385653 "Lee's Food Store of Sarasota Inc"     (no comma)
--   - 4385662 "Lee's Ice of Southwest Florida, Inc." (trailing dot)
--
-- Both 404 on FC API direct fetch: confirmed they no longer exist in FC.
-- Each was renamed/merged by operator inside FC; the canonical records
-- (2426555 "Lee's Food Store of Sarasota, Inc" and 2426556 "Lee's Ice of
-- Southwest Florida, Inc") are syncing fresh as of last W17 run.
--
-- Root cause: W17 does not detect locally-stale records (FC stops
-- returning a previously-known client). Tech-debt fix Part C documented
-- separately; this migration just sweeps the 2 known ghosts NOW so they
-- stop polluting the SLA queue + V0.7.B.4 attribution layer.
--
-- Migration 038b (Part B) tightens the attribution resolver to exclude
-- is_archived = true clients permanently.

update profit_fc_clients
   set is_archived = true,
       archived_at = now(),
       updated_at = now()
 where fc_client_id in (4385653, 4385662)
   and is_archived = false;

-- Verify: should return 0 active stale records for these names
do $$
declare
  active_count int;
begin
  select count(*) into active_count
    from profit_fc_clients
   where fc_client_id in (4385653, 4385662)
     and is_archived = false;
  if active_count > 0 then
    raise exception '038a: % stale Lee ghost records still active after sweep', active_count;
  end if;
end $$;
