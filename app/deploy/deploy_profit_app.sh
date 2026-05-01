#!/usr/bin/env bash
set -euo pipefail

APP_DIR=/opt/agents/outscore_profit
REPO_DIR=${REPO_DIR:-/root/outscore-profit-codex}

mkdir -p "$APP_DIR/frontend"
cp -a "$REPO_DIR/profit_api" "$APP_DIR/"
cp "$REPO_DIR/app/backend/requirements.txt" "$APP_DIR/requirements.txt"
mkdir -p "$APP_DIR/frontend/dist"
cp -a "$REPO_DIR/app/frontend/dist/." "$APP_DIR/frontend/dist/"

python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

cp "$REPO_DIR/app/deploy/profit-admin-api.service" /etc/systemd/system/profit-admin-api.service
systemctl daemon-reload
systemctl enable profit-admin-api.service
systemctl restart profit-admin-api.service
systemctl status profit-admin-api.service --no-pager
