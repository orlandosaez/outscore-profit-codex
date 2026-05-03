from __future__ import annotations

import json
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


class SupabaseRestError(RuntimeError):
    pass


class SupabaseRestClient:
    def __init__(
        self,
        *,
        url: str,
        service_role_key: str,
        opener: Callable[..., object] = urlopen,
        timeout: int = 30,
    ) -> None:
        self.url = url.rstrip("/")
        self.service_role_key = service_role_key
        self.opener = opener
        self.timeout = timeout

    def read_view(self, view_name: str, **params: str | int) -> list[dict[str, object]]:
        query_items: list[tuple[str, str | int]] = [("select", "*")]
        query_items.extend(params.items())
        endpoint = f"{self.url}/rest/v1/{view_name}?{urlencode(query_items)}"
        request = Request(
            endpoint,
            headers={
                "apikey": self.service_role_key,
                "Authorization": f"Bearer {self.service_role_key}",
                "Accept": "application/json",
            },
            method="GET",
        )

        try:
            with self.opener(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError) as exc:
            raise SupabaseRestError(
                f"Supabase REST request failed for {view_name}: {exc}"
            ) from exc

        if not isinstance(payload, list):
            raise SupabaseRestError(
                f"Expected list payload from Supabase view {view_name}"
            )
        return payload

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        query_items: list[tuple[str, str | int]] = [("select", "*")]
        if on_conflict:
            query_items.append(("on_conflict", on_conflict))
        endpoint = f"{self.url}/rest/v1/{table_name}?{urlencode(query_items)}"
        return self._write_json(endpoint, "POST", rows)

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        query_items: list[tuple[str, str | int]] = [("select", "*")]
        query_items.extend(filters.items())
        endpoint = f"{self.url}/rest/v1/{table_name}?{urlencode(query_items)}"
        return self._write_json(endpoint, "PATCH", payload)

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, str | int],
    ) -> list[dict[str, object]]:
        query_items: list[tuple[str, str | int]] = [("select", "*")]
        query_items.extend(filters.items())
        endpoint = f"{self.url}/rest/v1/{table_name}?{urlencode(query_items)}"
        return self._write_json(endpoint, "DELETE", None)

    def _write_json(
        self,
        endpoint: str,
        method: str,
        payload: object,
    ) -> list[dict[str, object]]:
        request = Request(
            endpoint,
            data=None if payload is None else json.dumps(payload).encode("utf-8"),
            headers={
                "apikey": self.service_role_key,
                "Authorization": f"Bearer {self.service_role_key}",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
            method=method,
        )

        try:
            with self.opener(request, timeout=self.timeout) as response:
                body = response.read().decode("utf-8")
                response_payload = json.loads(body) if body else []
        except (HTTPError, URLError, TimeoutError) as exc:
            raise SupabaseRestError(
                f"Supabase REST write request failed: {exc}"
            ) from exc

        if not isinstance(response_payload, list):
            raise SupabaseRestError("Expected list payload from Supabase REST write")
        return response_payload
