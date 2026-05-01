from __future__ import annotations

import json
import unittest
from urllib.error import HTTPError

from profit_api.supabase import SupabaseRestClient, SupabaseRestError


class FakeResponse:
    def __init__(self, status: int, body: object) -> None:
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return json.dumps(self._body).encode("utf-8")

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None


class CapturingUrlopen:
    def __init__(self, response: FakeResponse) -> None:
        self.response = response
        self.urls: list[str] = []
        self.headers: list[dict[str, str]] = []

    def __call__(self, request, timeout: int):  # type: ignore[no-untyped-def]
        self.urls.append(request.full_url)
        self.headers.append(dict(request.header_items()))
        return self.response


class SupabaseRestClientTests(unittest.TestCase):
    def test_read_view_builds_rest_url_and_auth_headers(self) -> None:
        opener = CapturingUrlopen(FakeResponse(200, [{"ok": True}]))
        client = SupabaseRestClient(
            url="https://example.supabase.co",
            service_role_key="secret",
            opener=opener,
        )

        rows = client.read_view(
            "profit_admin_client_gp_dashboard",
            order="period_month.desc,low_gp_rank.asc",
            limit=25,
        )

        self.assertEqual(rows, [{"ok": True}])
        self.assertEqual(
            opener.urls,
            [
                "https://example.supabase.co/rest/v1/"
                "profit_admin_client_gp_dashboard?select=%2A"
                "&order=period_month.desc%2Clow_gp_rank.asc&limit=25"
            ],
        )
        self.assertEqual(opener.headers[0]["Authorization"], "Bearer secret")
        self.assertEqual(opener.headers[0]["Apikey"], "secret")

    def test_read_view_rejects_non_list_payloads(self) -> None:
        opener = CapturingUrlopen(FakeResponse(200, {"ok": True}))
        client = SupabaseRestClient(
            url="https://example.supabase.co",
            service_role_key="secret",
            opener=opener,
        )

        with self.assertRaisesRegex(SupabaseRestError, "Expected list"):
            client.read_view("profit_admin_company_dashboard_summary")

    def test_read_view_wraps_http_errors_without_exposing_key(self) -> None:
        def opener(_request, timeout: int):  # type: ignore[no-untyped-def]
            raise HTTPError(
                url="https://example.supabase.co/rest/v1/bad",
                code=401,
                msg="Unauthorized",
                hdrs={},
                fp=None,
            )

        client = SupabaseRestClient(
            url="https://example.supabase.co",
            service_role_key="secret",
            opener=opener,
        )

        with self.assertRaises(SupabaseRestError) as ctx:
            client.read_view("bad")

        self.assertIn("Supabase REST request failed", str(ctx.exception))
        self.assertNotIn("secret", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
