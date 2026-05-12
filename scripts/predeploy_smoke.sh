#!/usr/bin/env bash
# Pre-deploy smoke gate for profit migrations + queue volume.
#
# Codified after V0.7.A (effective_date::date) and V0.7.B (project.project_title)
# both shipped with schema mismatch bugs caught at psql apply time. Static SQL
# pattern tests don't exercise actual execution; this script does.
#
# Usage:
#   ./scripts/predeploy_smoke.sh <migration_file_1> [migration_file_2 ...]
#
# Behavior:
#   1. For each migration: scp to VPS /tmp/, apply inside BEGIN/ROLLBACK against
#      live Supabase via `psql --single-transaction -v ON_ERROR_STOP=1`. Schema
#      mismatches surface here, not at deploy time.
#   2. After all migrations dry-run cleanly: query live queue volume from
#      profit_weekly_review_items and compare to the API DEFAULT_LIMIT (200).
#      If queue >= DEFAULT_LIMIT, emit a warning recommending pagination or
#      DEFAULT_LIMIT increase before deploy.
#
# Exit codes:
#   0  all migrations dry-ran cleanly + queue volume below DEFAULT_LIMIT
#   1  one or more migrations failed dry-run
#   2  all migrations passed but queue volume >= DEFAULT_LIMIT (manual review)
#
# Required env / setup:
#   SSH access to root@104.225.220.36:2222
#   /opt/agents/outscore_profit/.env present on VPS with SUPABASE_DB_URL set

set -euo pipefail

VPS_HOST="root@104.225.220.36"
VPS_PORT="2222"
API_DEFAULT_LIMIT="${API_DEFAULT_LIMIT:-200}"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <migration_file_1> [migration_file_2 ...]" >&2
  exit 1
fi

echo "=== V0.7.B.1 pre-deploy smoke gate ==="
echo "API DEFAULT_LIMIT: $API_DEFAULT_LIMIT"
echo "VPS target: $VPS_HOST:$VPS_PORT"
echo ""

for migration in "$@"; do
  if [ ! -f "$migration" ]; then
    echo "FAIL: migration file not found: $migration" >&2
    exit 1
  fi

  echo "--- psql dry-run: $migration ---"
  basename_only=$(basename "$migration")

  scp -P "$VPS_PORT" "$migration" "$VPS_HOST:/tmp/" > /dev/null

  if ! ssh -p "$VPS_PORT" "$VPS_HOST" \
    "set -a; . /opt/agents/outscore_profit/.env; set +a; \
     psql \"\$SUPABASE_DB_URL\" -P pager=off -v ON_ERROR_STOP=1 --single-transaction \
       -c 'BEGIN;' \
       -f /tmp/$basename_only \
       -c 'ROLLBACK;'" 2>&1; then
    echo ""
    echo "FAIL: psql dry-run failed for $migration" >&2
    echo "Fix the migration locally before retrying deploy." >&2
    exit 1
  fi

  echo "PASS: $migration"
  echo ""
done

echo "--- queue volume smoke ---"
queue_count=$(ssh -p "$VPS_PORT" "$VPS_HOST" \
  "set -a; . /opt/agents/outscore_profit/.env; set +a; \
   psql \"\$SUPABASE_DB_URL\" -t -A -P pager=off \
     -c 'select count(*) from profit_weekly_review_items;'" 2>&1 | tr -d ' ')

echo "Live queue row count: $queue_count"
echo "API DEFAULT_LIMIT:    $API_DEFAULT_LIMIT"

ssh -p "$VPS_PORT" "$VPS_HOST" \
  "set -a; . /opt/agents/outscore_profit/.env; set +a; \
   psql \"\$SUPABASE_DB_URL\" -P pager=off \
     -c 'select verdict_code, count(*) from profit_weekly_review_items group by verdict_code order by verdict_code;'"

if [ "$queue_count" -ge "$API_DEFAULT_LIMIT" ]; then
  echo ""
  echo "WARN: queue volume ($queue_count) >= API DEFAULT_LIMIT ($API_DEFAULT_LIMIT)" >&2
  echo "      Default API response will truncate rows. Recommend pagination" >&2
  echo "      or DEFAULT_LIMIT increase before deploy." >&2
  exit 2
fi

echo ""
echo "=== smoke gate PASS — migrations + queue volume both healthy ==="
exit 0
