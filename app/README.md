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

