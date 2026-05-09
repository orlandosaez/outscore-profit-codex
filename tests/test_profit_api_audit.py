from __future__ import annotations

import os
import unittest

from fastapi.testclient import TestClient

os.environ.setdefault("SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")


class FakeAuditStore:
    def __init__(self, rows_by_view: dict[str, list[dict[str, object]]]) -> None:
        self.rows_by_view = rows_by_view
        self.read_calls: list[tuple[str, dict[str, object]]] = []
        self.inserted: list[tuple[str, list[dict[str, object]], str | None]] = []
        self.patched: list[tuple[str, dict[str, object], dict[str, object]]] = []
        self.deleted: list[tuple[str, dict[str, object]]] = []

    def read_view(self, view_name: str, **params: object) -> list[dict[str, object]]:
        self.read_calls.append((view_name, params))
        return list(self.rows_by_view.get(view_name, []))

    def insert_rows(
        self,
        table_name: str,
        rows: list[dict[str, object]],
        *,
        on_conflict: str | None = None,
    ) -> list[dict[str, object]]:
        self.inserted.append((table_name, rows, on_conflict))
        next_id = 1000
        existing_ids = [
            int(row["classification_id"])
            for row in self.rows_by_view.get(table_name, [])
            if row.get("classification_id") is not None
        ]
        if existing_ids:
            next_id = max(existing_ids) + 1
        returned = []
        for index, row in enumerate(rows):
            returned.append({"classification_id": next_id + index, **row})
        self.rows_by_view.setdefault(table_name, []).extend(returned)
        return returned

    def patch_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
        payload: dict[str, object],
    ) -> list[dict[str, object]]:
        self.patched.append((table_name, filters, payload))
        classification_filter = str(filters.get("classification_id", ""))
        if classification_filter.startswith("eq."):
            classification_id = int(classification_filter.removeprefix("eq."))
            for row in self.rows_by_view.get(table_name, []):
                if row.get("classification_id") == classification_id:
                    row.update(payload)
                    return [dict(row)]
        return []

    def delete_rows(
        self,
        table_name: str,
        *,
        filters: dict[str, object],
    ) -> list[dict[str, object]]:
        self.deleted.append((table_name, filters))
        return []


class FakeDashboardService:
    pass


class FakeRecognitionService:
    pass


class AuditDashboardRouteTest(unittest.TestCase):
    def build_client(
        self,
        rows_by_view: dict[str, list[dict[str, object]]],
    ) -> TestClient:
        from profit_api.audit import AuditDashboardService
        import profit_api.app as app_module

        service = AuditDashboardService(FakeAuditStore(rows_by_view))
        app = app_module.create_app(
            service=FakeDashboardService(),
            manual_recognition_service=FakeRecognitionService(),
            audit_service=service,
        )
        return TestClient(app)

    def test_verdicts_endpoint_returns_lookup_rows(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {
                        "verdict_code": "MIXED",
                        "label": "Mixed",
                        "category": "mixed",
                        "default_visibility": "show",
                        "requires_re_evaluate_at": False,
                        "auto_transition_enabled": True,
                        "description": "Needs manual reclassification.",
                    }
                ]
            }
        )

        response = client.get("/api/profit/admin/audit/verdicts")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["rows"][0]["verdict_code"], "MIXED")
        self.assertEqual(response.json()["rows"][0]["label"], "Mixed")
        self.assertEqual(response.json()["rows"][0]["category"], "mixed")
        self.assertEqual(response.json()["rows"][0]["default_visibility"], "show")
        self.assertIn("requires_re_evaluate_at", response.json()["rows"][0])
        self.assertIn("auto_transition_enabled", response.json()["rows"][0])
        self.assertIn("description", response.json()["rows"][0])

    def test_filter_options_endpoint_returns_dropdown_sources(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {"verdict_code": "MIXED", "label": "Mixed", "category": "mixed"}
                ],
                "profit_fc_client_tags": [
                    {"fc_client_id": 1, "tag_name": "S 1120P", "tag_type": "service"},
                    {"fc_client_id": 1, "tag_name": "Laura", "tag_type": "staff"},
                    {"fc_client_id": 1, "tag_name": "Feig Group", "tag_type": "group"},
                ],
                "profit_fulfillment_audit_candidates": [
                    {"fc_client_id": 1, "group_names": ["Feig Group"]}
                ],
            }
        )

        response = client.get("/api/profit/admin/audit/filter-options")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["verdicts"][0]["verdict_code"], "MIXED")
        self.assertEqual(response.json()["staff"], ["Laura"])
        self.assertEqual(response.json()["service_tags"], ["S 1120P"])
        self.assertEqual(response.json()["groups"], ["Feig Group"])

    def test_candidates_endpoint_filters_and_enriches_rows(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {"verdict_code": "MIXED", "label": "Mixed", "category": "mixed"},
                    {
                        "verdict_code": "INTERNAL_FAMILY",
                        "label": "Internal family",
                        "category": "suppressed",
                    },
                ],
                "profit_fulfillment_audit_candidates": [
                    {
                        "fc_client_id": 1,
                        "fc_client_name": "Visible Client",
                        "current_classification_id": 10,
                        "current_verdict_code": "MIXED",
                        "default_visibility": "show",
                        "group_names": ["Feig Group"],
                    },
                    {
                        "fc_client_id": 2,
                        "fc_client_name": "Hidden Client",
                        "current_classification_id": 20,
                        "current_verdict_code": "INTERNAL_FAMILY",
                        "default_visibility": "hide",
                        "group_names": [],
                    },
                    {
                        "fc_client_id": 3,
                        "fc_client_name": "Unclassified Client",
                        "current_classification_id": None,
                        "current_verdict_code": None,
                        "default_visibility": "show",
                        "group_names": [],
                    },
                ],
                "profit_fc_client_tags": [
                    {"fc_client_id": 1, "tag_name": "S 1120P", "tag_type": "service"},
                    {"fc_client_id": 1, "tag_name": "Laura", "tag_type": "staff"},
                    {"fc_client_id": 2, "tag_name": "Beth", "tag_type": "staff"},
                ],
                "profit_classifications": [
                    {
                        "classification_id": 10,
                        "estimated_annual_revenue": 12000,
                    },
                    {
                        "classification_id": 20,
                        "estimated_annual_revenue": 5000,
                    },
                ],
            }
        )

        response = client.get("/api/profit/admin/audit/candidates?staff=Laura")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()["rows"]), 1)
        row = response.json()["rows"][0]
        self.assertEqual(row["fc_client_id"], 1)
        self.assertEqual(row["service_tags"], ["S 1120P"])
        self.assertEqual(row["estimated_annual_revenue"], 12000)

    def test_candidates_endpoint_supports_unclassified_sentinel(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {"verdict_code": "MIXED", "label": "Mixed", "category": "mixed"},
                ],
                "profit_fulfillment_audit_candidates": [
                    {
                        "fc_client_id": 1,
                        "current_verdict_code": "MIXED",
                        "default_visibility": "show",
                    },
                    {
                        "fc_client_id": 2,
                        "current_verdict_code": None,
                        "default_visibility": "show",
                    },
                ],
                "profit_fc_client_tags": [],
                "profit_classifications": [],
            }
        )

        response = client.get(
            "/api/profit/admin/audit/candidates?verdict_code=__UNCLASSIFIED__"
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()["rows"]), 1)
        self.assertIsNone(response.json()["rows"][0]["current_verdict_code"])

    def test_candidates_endpoint_rejects_invalid_verdict_code(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {"verdict_code": "MIXED", "label": "Mixed", "category": "mixed"},
                ],
                "profit_fulfillment_audit_candidates": [],
                "profit_fc_client_tags": [],
                "profit_classifications": [],
            }
        )

        response = client.get(
            "/api/profit/admin/audit/candidates?verdict_code=NOT_A_VERDICT"
        )

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["detail"]["field"], "verdict_code")

    def test_candidate_detail_endpoint_returns_composite_payload(self) -> None:
        client = self.build_client(
            {
                "profit_fc_clients": [
                    {"fc_client_id": 1, "name": "Schmidli Enterprises LLC"},
                ],
                "profit_fulfillment_audit_candidates": [
                    {
                        "fc_client_id": 1,
                        "current_verdict_code": "PENDING_ENGAGEMENT_SENT",
                        "anchor_display_status": "active",
                        "any_active_signal": True,
                    }
                ],
                "profit_fulfillment_audit_fc_activity": [
                    {"fc_client_id": 1, "service_delivery_task_count_365d": 2}
                ],
                "profit_fulfillment_audit_anchor_signals": [
                    {
                        "fc_client_id": 1,
                        "anchor_display_status": "active",
                        "has_anchor_invoice_365d": True,
                    }
                ],
                "profit_fulfillment_audit_group_signals": [
                    {"fc_client_id": 1, "has_active_group_membership": False}
                ],
                "profit_classifications": [
                    {
                        "classification_id": index,
                        "fc_client_id": 1,
                        "verdict_code": "PENDING_ENGAGEMENT_SENT",
                        "classified_at": f"2026-05-{index:02d}T00:00:00+00:00",
                    }
                    for index in range(1, 103)
                ],
                "profit_classification_transition_rules": [
                    {
                        "from_verdict_code": "PENDING_ENGAGEMENT_SENT",
                        "signal_name": "active_agreement_appears",
                        "to_verdict_code": "MIXED",
                        "enabled": True,
                    },
                    {
                        "from_verdict_code": "PENDING_ENGAGEMENT_SENT",
                        "signal_name": "cash_collected_group_parent",
                        "to_verdict_code": "CONSOLIDATED_VIA_GROUP_BILLED",
                        "enabled": True,
                    },
                ],
                "profit_fc_task_delivery_classification": [
                    {
                        "fc_task_id": index,
                        "fc_project_id": index + 1000,
                        "fc_client_id": 1,
                        "client_name": "Schmidli Enterprises LLC",
                        "project_title": "Tax",
                        "task_title": "File tax return",
                        "task_kind": "service_delivery",
                        "is_completed": True,
                        "completed_at": f"2026-04-{index:02d}T00:00:00+00:00",
                    }
                    for index in range(1, 23)
                ],
            }
        )

        response = client.get("/api/profit/admin/audit/candidates/1")

        self.assertEqual(response.status_code, 200, response.text)
        payload = response.json()
        for key in [
            "candidate",
            "fc_activity",
            "anchor_signals",
            "group_signals",
            "classification_history",
            "classification_history_total_count",
            "classification_history_truncated",
            "transition_rules",
            "recent_service_tasks",
        ]:
            self.assertIn(key, payload)
        self.assertEqual(len(payload["classification_history"]), 100)
        self.assertEqual(payload["classification_history_total_count"], 102)
        self.assertTrue(payload["classification_history_truncated"])
        self.assertEqual(len(payload["recent_service_tasks"]), 20)
        for rule in payload["transition_rules"]:
            self.assertIn("auto_apply_enabled", rule)
            self.assertIn("auto_apply_enabled_in_b2a", rule)
            if rule["signal_present"]:
                self.assertIsNone(rule["signal_reason"])
            else:
                self.assertIsInstance(rule["signal_reason"], str)
                self.assertTrue(rule["signal_reason"])

    def test_candidate_detail_transition_rules_dual_emit_canonical_auto_apply_flag(self) -> None:
        client = self.build_client(
            {
                "profit_fc_clients": [{"fc_client_id": 1, "name": "Legacy Client"}],
                "profit_fulfillment_audit_candidates": [
                    {
                        "fc_client_id": 1,
                        "current_verdict_code": "LEGACY_ENGAGEMENT_PRE_ANCHOR",
                    }
                ],
                "profit_fulfillment_audit_fc_activity": [{"fc_client_id": 1}],
                "profit_fulfillment_audit_anchor_signals": [
                    {
                        "fc_client_id": 1,
                        "has_anchor_invoice_365d": True,
                    }
                ],
                "profit_fulfillment_audit_group_signals": [
                    {"fc_client_id": 1, "has_active_group_membership": False}
                ],
                "profit_classifications": [
                    {
                        "classification_id": 10,
                        "fc_client_id": 1,
                        "verdict_code": "LEGACY_ENGAGEMENT_PRE_ANCHOR",
                        "classified_at": "2026-05-01T00:00:00+00:00",
                    }
                ],
                "profit_classification_transition_rules": [
                    {
                        "from_verdict_code": "LEGACY_ENGAGEMENT_PRE_ANCHOR",
                        "signal_name": "first_matching_anchor_invoice_mid_cycle",
                        "to_verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "enabled": True,
                    }
                ],
                "profit_fc_task_delivery_classification": [],
            }
        )

        response = client.get("/api/profit/admin/audit/candidates/1")

        self.assertEqual(response.status_code, 200, response.text)
        rule = response.json()["transition_rules"][0]
        self.assertTrue(rule["auto_apply_enabled"])
        self.assertFalse(rule["auto_apply_enabled_in_b2a"])

    def test_candidate_detail_endpoint_404s_for_unknown_client(self) -> None:
        client = self.build_client(
            {
                "profit_fc_clients": [],
                "profit_fulfillment_audit_candidates": [],
                "profit_fulfillment_audit_fc_activity": [],
                "profit_fulfillment_audit_anchor_signals": [],
                "profit_fulfillment_audit_group_signals": [],
                "profit_classifications": [],
                "profit_classification_transition_rules": [],
                "profit_fc_task_delivery_classification": [],
            }
        )

        response = client.get("/api/profit/admin/audit/candidates/999")

        self.assertEqual(response.status_code, 404)

    def test_candidate_detail_endpoint_404s_for_client_outside_candidate_surface(self) -> None:
        client = self.build_client(
            {
                "profit_fc_clients": [{"fc_client_id": 1, "name": "Quiet Client"}],
                "profit_fulfillment_audit_candidates": [],
                "profit_fulfillment_audit_fc_activity": [],
                "profit_fulfillment_audit_anchor_signals": [],
                "profit_fulfillment_audit_group_signals": [],
                "profit_classifications": [],
                "profit_classification_transition_rules": [],
                "profit_fc_task_delivery_classification": [],
            }
        )

        response = client.get("/api/profit/admin/audit/candidates/1")

        self.assertEqual(response.status_code, 404)
        self.assertEqual(
            response.json()["detail"],
            "Client exists but is not in the audit candidate surface.",
        )

    def test_candidate_detail_inactive_transition_ignores_broad_candidate_signal(self) -> None:
        client = self.build_client(
            {
                "profit_fc_clients": [{"fc_client_id": 1, "name": "Joy Property Management LLC"}],
                "profit_fulfillment_audit_candidates": [
                    {
                        "fc_client_id": 1,
                        "current_verdict_code": "INACTIVE_FORMER_CLIENT",
                        "any_active_signal": True,
                    }
                ],
                "profit_fulfillment_audit_fc_activity": [
                    {
                        "fc_client_id": 1,
                        "fc_is_archived": True,
                        "fc_unarchived_after_archive": False,
                        "has_post_archive_service_delivery": False,
                    }
                ],
                "profit_fulfillment_audit_anchor_signals": [
                    {
                        "fc_client_id": 1,
                        "anchor_display_status": None,
                        "open_invoice_balance_amount": 0,
                    }
                ],
                "profit_fulfillment_audit_group_signals": [
                    {"fc_client_id": 1, "has_active_group_membership": False}
                ],
                "profit_classifications": [
                    {
                        "classification_id": 46,
                        "fc_client_id": 1,
                        "verdict_code": "INACTIVE_FORMER_CLIENT",
                        "classified_at": "2026-05-07T00:00:00+00:00",
                    }
                ],
                "profit_classification_transition_rules": [
                    {
                        "from_verdict_code": "INACTIVE_FORMER_CLIENT",
                        "signal_name": "any_active_signal_returns",
                        "to_verdict_code": "MIXED",
                        "enabled": True,
                    }
                ],
                "profit_fc_task_delivery_classification": [],
            }
        )

        response = client.get("/api/profit/admin/audit/candidates/1")

        self.assertEqual(response.status_code, 200, response.text)
        rule = response.json()["transition_rules"][0]
        self.assertFalse(rule["signal_present"])
        self.assertEqual(
            rule["signal_reason"],
            "no post-classification inactive re-emergence signal is present.",
        )

    def test_candidate_detail_uses_fc_client_filters_for_large_views(self) -> None:
        from profit_api.audit import AuditDashboardService

        store = FakeAuditStore(
            {
                "profit_fc_clients": [{"fc_client_id": 1, "name": "Client"}],
                "profit_fulfillment_audit_candidates": [
                    {"fc_client_id": 1, "current_verdict_code": None}
                ],
                "profit_fulfillment_audit_fc_activity": [{"fc_client_id": 1}],
                "profit_fulfillment_audit_anchor_signals": [{"fc_client_id": 1}],
                "profit_fulfillment_audit_group_signals": [{"fc_client_id": 1}],
                "profit_classifications": [],
                "profit_classification_transition_rules": [],
                "profit_fc_task_delivery_classification": [],
            }
        )
        service = AuditDashboardService(store)

        service.candidate_detail(1)

        self.assertIn(
            (
                "profit_fc_task_delivery_classification",
                {"fc_client_id": "eq.1"},
            ),
            store.read_calls,
        )

    def test_bulk_classify_rejects_validation_before_concurrency(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {
                        "verdict_code": "MIXED",
                        "category": "mixed",
                        "requires_re_evaluate_at": False,
                    }
                ],
                "profit_classifications": [
                    {
                        "classification_id": 55,
                        "fc_client_id": 2426569,
                        "verdict_code": "MIXED",
                        "superseded_at": None,
                    }
                ],
            }
        )

        response = client.post(
            "/api/profit/admin/audit/classifications",
            json={
                "request_id": "00000000-0000-0000-0000-000000000002",
                "rows": [
                    {
                        "fc_client_id": 2426569,
                        "classification_id_to_supersede": 32,
                        "new_verdict_code": "NOT_A_VERDICT",
                        "re_evaluate_at": None,
                        "notes": "",
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["detail"]["field"], "new_verdict_code")

    def test_bulk_classify_rejects_schema_and_required_notes(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {
                        "verdict_code": "MIXED",
                        "category": "mixed",
                        "requires_re_evaluate_at": False,
                    },
                    {
                        "verdict_code": "PENDING_ENGAGEMENT_SENT",
                        "category": "pending",
                        "requires_re_evaluate_at": True,
                    },
                ],
                "profit_classifications": [],
            }
        )

        empty = client.post(
            "/api/profit/admin/audit/classifications",
            json={"request_id": "00000000-0000-0000-0000-000000000003", "rows": []},
        )
        bad_uuid = client.post(
            "/api/profit/admin/audit/classifications",
            json={
                "request_id": "not-a-uuid",
                "rows": [
                    {
                        "fc_client_id": 1,
                        "classification_id_to_supersede": None,
                        "new_verdict_code": "MIXED",
                        "re_evaluate_at": None,
                        "notes": "Required note",
                    }
                ],
            },
        )
        missing_notes = client.post(
            "/api/profit/admin/audit/classifications",
            json={
                "request_id": "00000000-0000-0000-0000-000000000004",
                "rows": [
                    {
                        "fc_client_id": 1,
                        "classification_id_to_supersede": None,
                        "new_verdict_code": "MIXED",
                        "re_evaluate_at": None,
                        "notes": "",
                    }
                ],
            },
        )
        missing_re_eval = client.post(
            "/api/profit/admin/audit/classifications",
            json={
                "request_id": "00000000-0000-0000-0000-000000000005",
                "rows": [
                    {
                        "fc_client_id": 1,
                        "classification_id_to_supersede": None,
                        "new_verdict_code": "PENDING_ENGAGEMENT_SENT",
                        "re_evaluate_at": None,
                        "notes": "",
                    }
                ],
            },
        )

        self.assertEqual(empty.status_code, 422)
        self.assertEqual(empty.json()["detail"]["field"], "rows")
        self.assertEqual(bad_uuid.status_code, 422)
        self.assertEqual(bad_uuid.json()["detail"]["field"], "request_id")
        self.assertEqual(missing_notes.status_code, 422)
        self.assertEqual(missing_notes.json()["detail"]["field"], "notes")
        self.assertEqual(missing_re_eval.status_code, 422)
        self.assertEqual(missing_re_eval.json()["detail"]["field"], "re_evaluate_at")

    def test_bulk_classify_rejects_stale_supersede_target_with_409(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {
                        "verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "category": "pending",
                        "requires_re_evaluate_at": False,
                    }
                ],
                "profit_classifications": [
                    {
                        "classification_id": 55,
                        "fc_client_id": 2426569,
                        "verdict_code": "MIXED",
                        "superseded_at": None,
                    }
                ],
            }
        )

        response = client.post(
            "/api/profit/admin/audit/classifications",
            json={
                "request_id": "00000000-0000-0000-0000-000000000006",
                "rows": [
                    {
                        "fc_client_id": 2426569,
                        "classification_id_to_supersede": 32,
                        "new_verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "re_evaluate_at": None,
                        "notes": "",
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["detail"]["current_classification_id"], 55)
        self.assertEqual(response.json()["detail"]["current_verdict_code"], "MIXED")

    def test_bulk_classify_first_classification_inserts_row(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {
                        "verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "category": "pending",
                        "requires_re_evaluate_at": False,
                    }
                ],
                "profit_classifications": [],
            }
        )

        response = client.post(
            "/api/profit/admin/audit/classifications",
            json={
                "request_id": "00000000-0000-0000-0000-000000000007",
                "rows": [
                    {
                        "fc_client_id": 2426558,
                        "classification_id_to_supersede": None,
                        "new_verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "re_evaluate_at": None,
                        "notes": "",
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["applied_count"], 1)
        self.assertEqual(response.json()["request_id"], "00000000-0000-0000-0000-000000000007")
        self.assertEqual(response.json()["rows"][0]["fc_client_id"], 2426558)
        self.assertEqual(
            response.json()["rows"][0]["verdict_code"],
            "BILLING_OUTSIDE_AUDIT_WINDOW",
        )

    def test_bulk_classify_reuses_existing_request_id(self) -> None:
        client = self.build_client(
            {
                "profit_classification_verdicts": [
                    {
                        "verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "category": "pending",
                        "requires_re_evaluate_at": False,
                    }
                ],
                "profit_classifications": [
                    {
                        "classification_id": 77,
                        "fc_client_id": 2426558,
                        "verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "source_audit_file": "manual:/profit/admin/audit",
                        "source_audit_row_hash": "manual:00000000-0000-0000-0000-000000000008:2426558",
                        "superseded_at": None,
                    }
                ],
            }
        )

        response = client.post(
            "/api/profit/admin/audit/classifications",
            json={
                "request_id": "00000000-0000-0000-0000-000000000008",
                "rows": [
                    {
                        "fc_client_id": 2426558,
                        "classification_id_to_supersede": None,
                        "new_verdict_code": "BILLING_OUTSIDE_AUDIT_WINDOW",
                        "re_evaluate_at": None,
                        "notes": "",
                    }
                ],
            },
        )

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["applied_count"], 0)
        self.assertEqual(response.json()["rows"][0]["classification_id"], 77)

    def test_qbo_category_gaps_endpoint_returns_diagnostic_rows(self) -> None:
        client = self.build_client(
            {
                "profit_fulfillment_audit_qbo_category_gaps": [
                    {
                        "gap_origin": "qbo_product_missing",
                        "qbo_product_match_status": "missing_qbo_product",
                        "qbo_product_name_raw": "Advisory:Strategic Advisory",
                        "qbo_product_leaf_name": "Strategic Advisory",
                    },
                    {
                        "gap_origin": "canonical_service_name_unresolved",
                        "qbo_product_match_status": "matched",
                        "qbo_product_name_raw": "Accounting:Accounting Advanced",
                        "qbo_product_leaf_name": "Accounting Advanced",
                    },
                ]
            }
        )

        response = client.get("/api/profit/admin/audit/qbo-category-gaps?limit=1")

        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()["rows"]), 1)
        self.assertEqual(response.json()["rows"][0]["gap_origin"], "qbo_product_missing")
        self.assertIn("qbo_product_match_status", response.json()["rows"][0])


if __name__ == "__main__":
    unittest.main()
