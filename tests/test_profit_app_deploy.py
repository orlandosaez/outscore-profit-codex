from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ProfitAppDeployTests(unittest.TestCase):
    def test_systemd_service_serves_profit_api_on_private_port(self) -> None:
        service = (ROOT / "app/deploy/profit-admin-api.service").read_text(
            encoding="utf-8"
        )

        self.assertIn("EnvironmentFile=/opt/agents/outscore_profit/.env", service)
        self.assertIn("uvicorn profit_api.app:app", service)
        self.assertIn("--host 127.0.0.1 --port 8010", service)

    def test_nginx_config_mounts_profit_frontend_and_api_under_subpath(self) -> None:
        nginx = (ROOT / "app/deploy/nginx-profit.conf").read_text(encoding="utf-8")

        self.assertIn("location /profit/", nginx)
        self.assertIn("alias /opt/agents/outscore_profit/frontend/dist/", nginx)
        self.assertIn("location /profit/api/", nginx)
        self.assertIn("proxy_pass http://127.0.0.1:8010/api/", nginx)

    def test_deploy_script_keeps_env_external_to_repo(self) -> None:
        script = (ROOT / "app/deploy/deploy_profit_app.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("APP_DIR=/opt/agents/outscore_profit", script)
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY=", script)
        self.assertNotIn("SUPABASE_URL=", script)


if __name__ == "__main__":
    unittest.main()
