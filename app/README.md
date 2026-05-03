# Outscore Profit App Scaffold

This is the first app-layer slice for the profit dashboard.

## Backend

Module: `profit_api`

Route:

- `GET /api/profit/admin/dashboard`

Environment:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`

Local run:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r app/backend/requirements.txt
uvicorn profit_api.app:app --reload --port 8010
```

The backend reads only from the stable admin views created by `supabase/sql/009_profit_admin_dashboard_views.sql`.

## Frontend

Path: `app/frontend`

Local run:

```bash
cd app/frontend
npm install
npm run dev
```

By default the React app calls `/api/profit/admin/dashboard`, so put it behind the FastAPI route or configure the deployed reverse proxy to forward `/api/profit/*` to the backend.

For `app.outscore.com/profit`, build with:

```bash
VITE_BASE_PATH=/profit/ VITE_PROFIT_API_BASE=/profit/api npm run build
```

## VPS Deployment Notes

Deployment files are in `app/deploy/`:

- `profit-admin-api.service` runs FastAPI on `127.0.0.1:8010`.
- `nginx-profit.conf` mounts the static app at `/profit/` and proxies `/profit/api/`.
- `deploy_profit_app.sh` copies the built app/API into `/opt/agents/outscore_profit`.

Before starting the service, create `/opt/agents/outscore_profit/.env` on the VPS:

```bash
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

For migrations and admin queries, also set `SUPABASE_DB_URL` in `/opt/agents/outscore_profit/.env` with file mode `600`, then source it with `set -a; . /opt/agents/outscore_profit/.env; set +a` before running `psql`. Run tests with `PYTHONPATH=. uvx --with-requirements requirements-dev.txt pytest`.

Also create an Nginx basic-auth file before enabling `/profit` publicly:

```bash
htpasswd -c /etc/nginx/.htpasswd-profit orlando
```

Use a strong password. This is a temporary admin-only protection layer until this dashboard is wired into the existing Supabase Auth session model.
