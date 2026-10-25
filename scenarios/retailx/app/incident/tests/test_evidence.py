import json
import re
import unittest
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock

from evidence import (
    LIVE_MAX_AGE,
    MAX_AGE,
    TOOLS,
    EvidenceService,
    LiveReader,
    ToolArgumentError,
    fixture_health,
    fresh,
    parse_time,
    store_context,
    validate_arguments,
    validate_receipt,
)
from helpers import live_settings, settings

UTC = UTC
NOW = datetime(2026, 10, 18, 5, 30, tzinfo=UTC)
STORE_IDS = {
    "BE": ("BE-101", "BE-102", "BE-205", "BE-310"),
    "NL": ("NL-401", "NL-402", "NL-517", "NL-620"),
}


class ArgumentsTests(unittest.TestCase):
    def test_all_schemas_closed_and_required(self):
        for tool in TOOLS.values():
            schema = tool["parameters"]
            self.assertTrue(tool["strict"])
            self.assertFalse(schema["additionalProperties"])
            self.assertEqual(set(schema["properties"]), set(schema["required"]))

    def test_strict_tool_arguments(self):
        invalid = [
            ("shell", {"countries": ["BE"]}),
            ("get_checkout_health", {"countries": ["BE"], "query": "Syslog"}),
            ("get_checkout_health", {"countries": ["BE", "BE"]}),
            ("get_checkout_health", {"countries": ["US"]}),
            ("get_checkout_health", {"countries": "BE"}),
            ("get_checkout_health", {"countries": []}),
            ("get_checkout_health", {"countries": [True]}),
            ("get_store_context", {"countries": ["BE"]}),
            ("get_store_context", {"countries": ["BE"], "horizon_minutes": True}),
            ("get_store_context", {"countries": ["BE"], "horizon_minutes": 61}),
            ("get_store_context", {"countries": ["BE"], "horizon_minutes": 0}),
            ("get_store_context", {"countries": ["BE"], "horizon_minutes": 60.0}),
        ]
        for name, args in invalid:
            with self.subTest(name=name, args=args), self.assertRaises(ToolArgumentError):
                validate_arguments(name, args, ["BE", "NL"])
        with self.assertRaises(ToolArgumentError):
            validate_arguments("get_checkout_health", {"countries": ["NL"]}, ["BE"])
        self.assertEqual(
            ["BE"],
            validate_arguments(
                "get_store_context", {"countries": ["BE"], "horizon_minutes": 60}, ["BE"]
            ),
        )


class OpeningTests(unittest.TestCase):
    def test_open_and_opening_soon(self):
        result = store_context(["BE", "NL"], 60, NOW)
        stores = {s["store"]: s for s in result["stores"]}
        self.assertEqual(
            {store for country in STORE_IDS.values() for store in country}, set(stores)
        )
        self.assertEqual(8, len(result["stores"]))
        self.assertTrue(stores["BE-101"]["isOpen"])
        self.assertTrue(stores["BE-102"]["opensWithinHorizon"])
        self.assertFalse(stores["BE-205"]["opensWithinHorizon"])
        self.assertTrue(stores["BE-310"]["isOpen"])
        self.assertTrue(stores["NL-620"]["isOpen"])
        self.assertEqual("Europe/Amsterdam", stores["NL-401"]["timezone"])
        self.assertTrue(result["synthetic"])
        self.assertTrue(all(s["synthetic"] for s in stores.values()))

    def test_documented_schedules_and_each_closing_boundary(self):
        stores = {s["store"]: s for s in store_context(["BE", "NL"], 60, NOW)["stores"]}
        hours = ((7, 22), (8, 20), (9, 21), (7, 22))
        for country, ids in STORE_IDS.items():
            for store_id, (opening, closing) in zip(ids, hours, strict=True):
                with self.subTest(store=store_id):
                    self.assertEqual(
                        opening, datetime.fromisoformat(stores[store_id]["openingToday"]).hour
                    )
                    self.assertEqual(
                        closing, datetime.fromisoformat(stores[store_id]["closingToday"]).hour
                    )
                    closing_utc = datetime(2026, 10, 18, closing - 2, tzinfo=UTC)
                    closed = store_context([country], 60, closing_utc)
                    store = next(s for s in closed["stores"] if s["store"] == store_id)
                    self.assertFalse(store["isOpen"])
                    self.assertFalse(store["opensWithinHorizon"])

    def test_exact_boundary_and_closing_exclusive(self):
        before = datetime(2026, 10, 18, 4, 0, tzinfo=UTC)
        store = store_context(["BE"], 60, before)["stores"][0]
        self.assertTrue(store["opensWithinHorizon"])
        self.assertFalse(store["isOpen"])
        opened = store_context(["BE"], 1, before + timedelta(hours=1))["stores"][0]
        self.assertTrue(opened["isOpen"])
        self.assertFalse(opened["opensWithinHorizon"])
        closed = store_context(["BE"], 60, datetime(2026, 10, 18, 20, tzinfo=UTC))["stores"][0]
        self.assertFalse(closed["isOpen"])

    def test_timezone_dst_and_midnight(self):
        summer = store_context(["NL"], 60, datetime(2026, 7, 1, 5, tzinfo=UTC))["stores"][0]
        winter = store_context(["NL"], 60, datetime(2026, 12, 1, 6, tzinfo=UTC))["stores"][0]
        self.assertTrue(summer["isOpen"])
        self.assertTrue(winter["isOpen"])
        self.assertTrue(summer["openingToday"].endswith("+02:00"))
        self.assertTrue(winter["openingToday"].endswith("+01:00"))
        midnight = store_context(["BE"], 60, datetime(2026, 10, 24, 23, 30, tzinfo=UTC))["stores"][
            0
        ]
        self.assertTrue(midnight["nextOpening"].startswith("2026-10-25T07:00"))
        self.assertTrue(midnight["nextOpening"].endswith("+01:00"))


class EvidenceTests(unittest.TestCase):
    def test_age_and_future_guards(self):
        self.assertTrue(fresh(NOW - timedelta(seconds=MAX_AGE), NOW))
        self.assertFalse(fresh(NOW - timedelta(seconds=MAX_AGE + 1), NOW))
        self.assertTrue(fresh(NOW + timedelta(seconds=30), NOW))
        self.assertFalse(fresh(NOW + timedelta(seconds=31), NOW))
        with self.assertRaises(ValueError):
            parse_time("2026-10-18T05:30:00")

    def test_unknown_sources_never_healthy(self):
        for state in ("stale", "unknown", "unavailable", "ownership-mismatch"):
            result = fixture_health(["BE", "NL"], state, NOW)
            self.assertEqual("unknown", result["status"])
            self.assertTrue(result["reason"])
            self.assertFalse(result["recoveryProven"])
            self.assertTrue(all(c["health"] == "unknown" for c in result["countries"]))

    def test_new_evidence_on_recovery_not_recovery_proof(self):
        service = EvidenceService(settings(), clock=lambda: NOW)
        args = {"countries": ["BE"]}
        interrupted = service.execute("get_checkout_health", args, ["BE"], "interrupted")
        healthy = service.execute("get_checkout_health", args, ["BE"], "healthy")
        self.assertNotEqual(interrupted["evidenceId"], healthy["evidenceId"])
        self.assertEqual(0, healthy["countries"][0]["observedFailedCheckouts"])
        self.assertFalse(healthy["recoveryProven"])
        self.assertEqual("healthy", healthy["fixtureState"])

    def test_deterministic_observed_versus_exposed(self):
        for state in ("interrupted", "recovering"):
            with self.subTest(state=state):
                result = EvidenceService(settings(), clock=lambda: NOW).execute(
                    "assess_store_impact",
                    {"countries": ["BE", "NL"], "horizon_minutes": 60},
                    ["BE", "NL"],
                    state,
                )
                priorities = {p["store"]: p for p in result["priorities"]}
                for direct in ("BE-101", "NL-401"):
                    self.assertEqual("P1", priorities[direct]["priority"])
                    self.assertTrue(priorities[direct]["observedCheckoutFailuresAtStore"])
                for exposed in ("BE-102", "BE-310", "NL-402", "NL-620"):
                    self.assertEqual("P2", priorities[exposed]["priority"])
                    self.assertFalse(priorities[exposed]["observedCheckoutFailuresAtStore"])
                    self.assertTrue(priorities[exposed]["exposedToSharedDependency"])
                self.assertTrue(all(not p["storeOutageProven"] for p in priorities.values()))

    def test_healthy_store_priorities_remain_monitor(self):
        result = EvidenceService(settings(), clock=lambda: NOW).execute(
            "assess_store_impact",
            {"countries": ["BE", "NL"], "horizon_minutes": 60},
            ["BE", "NL"],
            "healthy",
        )
        self.assertEqual(8, len(result["priorities"]))
        self.assertTrue(all(p["priority"] == "monitor" for p in result["priorities"]))
        self.assertTrue(
            all(
                not p["observedCheckoutFailuresAtStore"] and not p["exposedToSharedDependency"]
                for p in result["priorities"]
            )
        )
        self.assertFalse(result["recoveryProven"])

    def test_stale_impact_not_prioritized_as_known_failure(self):
        result = EvidenceService(settings(), clock=lambda: NOW).execute(
            "assess_store_impact", {"countries": ["NL"], "horizon_minutes": 60}, ["NL"], "stale"
        )
        self.assertEqual("unknown", result["status"])
        self.assertTrue(all(p["priority"] == "investigate" for p in result["priorities"]))

    def test_live_binding_missing_is_explicit_unknown(self):
        result = LiveReader(settings(mode="live"), None).health(["BE"], NOW)
        self.assertEqual("unknown", result["status"])
        self.assertEqual("live_binding_missing_or_invalid", result["reason"])
        self.assertFalse(result["synthetic"])
        self.assertEqual([], result["countries"])

    def test_owner_marker_schema_and_age_receipts(self):
        config = settings(checkout_owner="checkout-owner-test")
        valid = {
            "schemaVersion": 1,
            "ownerToken": config.checkout_owner,
            "event": "checkout-service-observation",
            "service": "retailtx-price-primary.service",
            "active": True,
            "healthy": True,
            "observedAtUtc": NOW.isoformat(),
            "marker": None,
        }
        self.assertIsNone(validate_receipt(valid, config, NOW))
        # Any presenter run is observed; the incident assistant run is not a binding.
        for phase in ("prepared", "fault-active", "recovering", "recovered"):
            marker = {"scenario": "service", "runId": "presenter-run", "phase": phase}
            self.assertIsNone(validate_receipt({**valid, "marker": marker}, config, NOW))
        # Live ingestion lag is tolerated up to the live limit.
        lagged = (NOW - timedelta(seconds=LIVE_MAX_AGE - 1)).isoformat()
        self.assertIsNone(validate_receipt({**valid, "observedAtUtc": lagged}, config, NOW))
        for field, value, reason in (
            ("ownerToken", "someone-else", "ownership_mismatch"),
            ("marker", "fault", "invalid_service_marker"),
            ("marker", {"scenario": "latency", "phase": "prepared"}, "invalid_service_marker"),
            ("marker", {"scenario": "service", "phase": "done"}, "invalid_service_marker"),
            ("schemaVersion", True, "invalid_service_receipt"),
            ("active", 1, "invalid_service_receipt"),
            (
                "observedAtUtc",
                (NOW - timedelta(seconds=LIVE_MAX_AGE + 1)).isoformat(),
                "stale_or_future_service_observation",
            ),
            (
                "observedAtUtc",
                (NOW + timedelta(seconds=31)).isoformat(),
                "stale_or_future_service_observation",
            ),
        ):
            with self.subTest(field=field, value=value):
                self.assertEqual(reason, validate_receipt({**valid, field: value}, config, NOW))

    def test_live_fixed_query_and_sanitized_results(self):
        cfg = settings(
            mode="live",
            workspace="33333333-3333-4333-8333-333333333333",
            workspace_resource="/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/demo/providers/Microsoft.OperationalInsights/workspaces/ops",
            checkout_owner="checkout-owner-test",
            arc_resource="/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/demo/providers/Microsoft.HybridCompute/machines/erp",
            app_resource="/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/demo/providers/Microsoft.Insights/components/checkout",
        )
        receipt = {
            "schemaVersion": 1,
            "event": "checkout-service-observation",
            "ownerToken": cfg.checkout_owner,
            "marker": {
                "scenario": "service",
                "runId": "77777777-7777-4777-8777-777777777777",
                "actor": "88888888-8888-4888-8888-888888888888",
                "phase": "fault-active",
                "startedAtUtc": NOW.isoformat(),
            },
            "service": "retailtx-price-primary.service",
            "active": False,
            "healthy": False,
            "observedAtUtc": NOW.isoformat(),
        }
        queries = []
        reader = LiveReader(cfg, None)

        def query(text):
            queries.append(text)
            if text.startswith("Syslog"):
                return [{"receipt": json.dumps(receipt)}]
            return [
                {
                    "country": "BE",
                    "store": "BE-101",
                    "failed": 2,
                    "succeeded": 10,
                    "latest": NOW.isoformat(),
                }
            ]

        reader._query = query
        result = reader.health(["BE"], NOW)
        self.assertEqual("known", result["status"])
        self.assertEqual("degraded", result["countries"][0]["health"])
        self.assertTrue(result["countries"][0]["sharedDependencyExposed"])
        self.assertEqual(["BE-101"], result["countries"][0]["observedFailedStores"])
        self.assertEqual("fault-active", result["serviceIncidentPhase"])
        self.assertEqual(LIVE_MAX_AGE, result["maxAgeSeconds"])
        self.assertFalse(result["recoveryProven"])
        self.assertEqual(2, len(queries))
        self.assertIn(cfg.arc_resource, queries[0])
        self.assertIn(cfg.app_resource, queries[1])
        self.assertIn("ago(5m)", queries[1])
        rendered = json.dumps(result)
        for secret in (
            cfg.checkout_owner,
            cfg.workspace,
            cfg.arc_resource,
            receipt["marker"]["runId"],
            receipt["marker"]["actor"],
        ):
            self.assertNotIn(secret, rendered)
        receipt.update(
            active=True,
            healthy=True,
            marker={
                **receipt["marker"],
                "phase": "recovered",
                "recoveredAtUtc": NOW.isoformat(),
            },
        )
        recovered = reader.health(["BE"], NOW)
        self.assertEqual("recovered", recovered["serviceIncidentPhase"])
        self.assertFalse(recovered["recoveryProven"])
        # Recent failures keep the country degraded even after a recorded repair.
        self.assertEqual("degraded", recovered["countries"][0]["health"])
        receipt["marker"] = None
        baseline = reader.health(["BE"], NOW)
        self.assertEqual("no-fault-recorded", baseline["serviceIncidentPhase"])
        receipt["marker"] = {"scenario": "service", "phase": "unknown-phase"}
        self.assertEqual("unknown", reader.health(["BE"], NOW)["status"])

    def test_live_simulator_store_failures_join_opening_priorities(self):
        config = live_settings()
        for now, expected_priority in (
            (NOW + timedelta(hours=1), "P1"),
            (datetime(2026, 10, 18, 12, tzinfo=UTC), "P1"),
            (datetime(2026, 10, 18, 22, tzinfo=UTC), "P3"),
        ):
            receipt = {
                "schemaVersion": 1,
                "event": "checkout-service-observation",
                "ownerToken": config.checkout_owner,
                "service": "retailtx-price-primary.service",
                "active": False,
                "healthy": False,
                "observedAtUtc": now.isoformat(),
                "marker": {"scenario": "service", "phase": "fault-active"},
            }
            for country, stores in STORE_IDS.items():
                for failed_store in stores:
                    with self.subTest(now=now, failed_store=failed_store):
                        rows = [
                            {
                                "country": c,
                                "store": store,
                                "failed": 2 if store == failed_store else 0,
                                "succeeded": 10,
                                "latest": now.isoformat(),
                            }
                            for c, ids in STORE_IDS.items()
                            for store in ids
                        ]
                        reader = LiveReader(config, None)
                        reader._query = Mock(side_effect=[[{"receipt": json.dumps(receipt)}], rows])
                        result = EvidenceService(
                            config, clock=lambda now=now: now, live_reader=reader
                        ).execute(
                            "assess_store_impact",
                            {"countries": ["BE", "NL"], "horizon_minutes": 60},
                            ["BE", "NL"],
                            "healthy",
                        )
                        self.assertEqual("known", result["status"])
                        self.assertFalse(result["synthetic"])
                        self.assertFalse(result["health"]["synthetic"])
                        self.assertTrue(result["storeContext"]["synthetic"])
                        self.assertFalse(result["recoveryProven"])
                        priorities = {p["store"]: p for p in result["priorities"]}
                        self.assertEqual(8, len(priorities))
                        direct = priorities[failed_store]
                        self.assertEqual(expected_priority, direct["priority"])
                        self.assertTrue(direct["observedCheckoutFailuresAtStore"])
                        self.assertEqual(country, direct["country"])
                        self.assertFalse(direct["storeOutageProven"])
                        for store, priority in priorities.items():
                            self.assertTrue(priority["exposedToSharedDependency"])
                            if store != failed_store:
                                self.assertFalse(priority["observedCheckoutFailuresAtStore"])
                                self.assertEqual(
                                    "P2" if expected_priority == "P1" else "monitor",
                                    priority["priority"],
                                )

    def test_live_group_overflow_cannot_hide_failures_after_first_fifty(self):
        cfg = settings(
            mode="live",
            workspace="33333333-3333-4333-8333-333333333333",
            workspace_resource="/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/demo/providers/Microsoft.OperationalInsights/workspaces/ops",
            checkout_owner="checkout-owner-test",
            arc_resource="/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/demo/providers/Microsoft.HybridCompute/machines/erp",
            app_resource="/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/demo/providers/Microsoft.Insights/components/checkout",
        )
        receipt = {
            "schemaVersion": 1,
            "event": "checkout-service-observation",
            "ownerToken": cfg.checkout_owner,
            "marker": None,
            "service": "retailtx-price-primary.service",
            "active": True,
            "healthy": True,
            "observedAtUtc": NOW.isoformat(),
        }
        for group_count in (50, 51, 80):
            with self.subTest(group_count=group_count):
                rows = [
                    {
                        "country": "BE",
                        "store": f"BE-{number:03}",
                        "failed": 7 if number > 50 else 0,
                        "succeeded": 10,
                        "latest": NOW.isoformat(),
                    }
                    for number in range(1, group_count + 1)
                ]
                reader = LiveReader(cfg, None)
                queries = []

                def query(text, queries=queries, rows=rows):
                    if text.startswith("Syslog"):
                        return [{"receipt": json.dumps(receipt)}]
                    queries.append(text)
                    limit = re.search(r"\btake ([0-9]+)$", text)
                    self.assertIsNotNone(limit)
                    # Honor the actual KQL limit: the old take-50 query would hide
                    # every failure in these overflow cases and report healthy.
                    return rows[: int(limit.group(1))]

                reader._query = query
                result = reader.health(["BE"], NOW)
                self.assertTrue(queries[0].endswith("take 51"))
                if group_count == 50:
                    self.assertEqual("known", result["status"])
                    self.assertEqual("healthy", result["countries"][0]["health"])
                else:
                    self.assertEqual("unknown", result["status"])
                    self.assertEqual("request_group_limit_exceeded", result["reason"])
                    self.assertEqual([], result["countries"])
                    self.assertFalse(result["recoveryProven"])


if __name__ == "__main__":
    unittest.main()
