import asyncio
import json
import os
import tempfile
import threading
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from agent import FoundryAgent
from aiohttp.test_utils import TestClient, TestServer
from evidence import EvidenceService, LiveReader
from helpers import OPERATOR, TENANT, FakeResponses, call, live_settings, response, settings
from microsoft_agents.hosting.core import ClaimsIdentity
from teams import ReceiptStore, TeamsSettings, admit
from teams_server import create_teams_app
from telemetry import configure
from test_teams import BOT, payload


class FakeAdapter:
    def __init__(self):
        self.messages = []
        self.fail_send = False
        self.fail_delivery = False

    async def send(self, activity):
        if self.fail_send:
            raise TimeoutError("Private channel details must not be logged")
        self.messages.append(activity.text)

    async def process_activity(self, _claims, _activity, callback):
        await callback(SimpleNamespace(send_activity=self.send))

    async def continue_conversation(self, _client, _activity, callback):
        if self.fail_delivery:
            raise TimeoutError("Private outbound details must not be logged")
        await callback(SimpleNamespace(send_activity=self.send))


class TeamsHostTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = TeamsSettings(BOT, TENANT, OPERATOR, Path(self.directory.name))
        self.store = ReceiptStore(self.config.directory)
        self.adapter = FakeAdapter()
        self.agent = Mock()
        self.agent.turn.return_value = {"answer": "Synthetic evidence checked.", "tools": []}
        self.claims = ClaimsIdentity(
            {
                "iss": "https://api.botframework.com",
                "aud": BOT,
            },
            authentication_type="JWT",
        )
        self.auth = patch(
            "microsoft_agents.hosting.aiohttp.jwt_authorization_middleware._authorize_request",
            new=AsyncMock(side_effect=lambda *_args: self.claims),
        )
        self.auth.start()
        self.addCleanup(self.auth.stop)
        self.events = patch("teams_server.event").start()
        self.addCleanup(patch.stopall)
        with patch("teams_server.configure"):
            app = create_teams_app(settings(), self.config, self.agent, self.adapter, self.store)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)

    async def post(self, value, headers=None):
        return await self.client.post(
            "/api/messages",
            json=value,
            headers=headers if headers is not None else {"Authorization": "Bearer fixture-token"},
        )

    async def settled(self, message):
        for _ in range(100):
            receipt = self.store.read(self.store.path("receipt", message.operation))
            if receipt and receipt["status"] in ("delivered", "outcome-unknown"):
                return receipt
            await asyncio.sleep(0.01)
        self.fail("Bounded unit-test operation did not settle")

    async def test_only_constant_liveness_is_anonymous(self):
        response = await self.client.get("/health/live")
        self.assertEqual(await response.text(), '{"status":"ok"}')
        for path in ("/", "/api/chat", "/.auth/login/aad", "/health"):
            self.assertEqual((await self.client.get(path)).status, 404)
        self.assertEqual((await self.post(payload(), headers={})).status, 401)
        self.agent.turn.assert_not_called()

    async def test_real_sdk_middleware_rejects_forged_signature(self):
        self.auth.stop()
        response = await self.post(payload(), headers={"Authorization": "Bearer not-a-jwt"})
        self.assertEqual(response.status, 401)
        self.agent.turn.assert_not_called()

    async def test_verified_wrong_issuer_and_audience_cannot_invoke_agent(self):
        for claims in (
            {"iss": "https://login.microsoftonline.com/example/v2.0", "aud": BOT},
            {"iss": "https://api.botframework.com", "aud": OPERATOR},
        ):
            self.claims = ClaimsIdentity(claims, authentication_type="JWT")
            self.assertEqual((await self.post(payload())).status, 401)
        self.agent.turn.assert_not_called()

    async def test_tenant_user_and_channel_rejected_after_signature_boundary(self):
        for value in (
            payload(channelData={"tenant": {"id": BOT}}),
            payload(**{"from": {"aadObjectId": BOT}}),
            payload(conversation={"id": "x", "conversationType": "channel"}),
        ):
            self.assertEqual((await self.post(value)).status, 403)
        self.agent.turn.assert_not_called()

    async def test_delayed_answer_followup_and_duplicate_no_replay(self):
        value = payload()
        message = admit(value, self.config)
        self.assertEqual((await self.post(value)).status, 200)
        self.assertEqual((await self.settled(message))["status"], "delivered")
        self.assertIn("SYNTHETIC", self.adapter.messages[-1])
        self.assertEqual((await self.post(value)).status, 200)
        self.agent.turn.assert_called_once()
        followup = payload("What about the Netherlands?")
        self.assertEqual((await self.post(followup)).status, 200)
        await self.settled(admit(followup, self.config))
        self.assertEqual(self.agent.turn.call_count, 2)
        history, text, scope, fixture = self.agent.turn.call_args.args
        self.assertEqual(len(history), 2)
        self.assertEqual(text, followup["text"])
        self.assertEqual((scope, fixture), (["BE", "NL"], "healthy"))

    async def test_fixture_controls_do_not_invoke_model(self):
        value = payload("/fixture interrupted")
        self.assertEqual((await self.post(value)).status, 200)
        self.agent.turn.assert_not_called()
        question = payload()
        self.assertEqual((await self.post(question)).status, 200)
        await self.settled(admit(question, self.config))
        self.assertEqual(self.agent.turn.call_args.args[-1], "interrupted")

    async def test_personal_text_activity_with_html_presentation(self):
        value = payload(
            "Check the stores",
            attachments=[{"contentType": "text/html", "content": "<p>Check the stores</p>"}],
        )
        self.assertEqual((await self.post(value)).status, 200)
        await self.settled(admit(value, self.config))
        self.assertEqual(self.agent.turn.call_args.args[1], "Check the stores")

    async def test_delivery_failure_saved_result_is_not_replayed(self):
        self.adapter.fail_delivery = True
        value = payload()
        self.assertEqual((await self.post(value)).status, 200)
        message = admit(value, self.config)
        receipt = await self.settled(message)
        self.assertEqual(receipt["status"], "outcome-unknown")
        self.assertIn("Synthetic evidence checked", receipt["answer"])
        self.assertEqual((await self.post(value)).status, 200)
        self.agent.turn.assert_called_once()
        status = await self.post(payload("/status"))
        self.assertEqual(status.status, 200)
        self.assertIn("not a fresh observation", self.adapter.messages[-1])
        self.agent.turn.assert_called_once()

    async def test_ack_failure_does_not_start_inference(self):
        self.adapter.fail_send = True
        value = payload()
        self.assertEqual((await self.post(value)).status, 503)
        self.assertEqual(
            self.store.read(self.store.path("receipt", admit(value, self.config).operation))[
                "status"
            ],
            "outcome-unknown",
        )
        self.agent.turn.assert_not_called()
        self.assertFalse(self.store.lock.exists())

    async def test_sdk_default_raw_error_echo_is_replaced(self):
        with self.assertRaisesRegex(RuntimeError, "Private upstream"):
            await self.adapter.on_turn_error(
                SimpleNamespace(send_activity=self.adapter.send),
                RuntimeError("Private upstream details"),
            )
        self.assertEqual(self.adapter.messages, [])

    async def test_cancellation_keeps_claim_until_explicit_reset(self):
        entered, finish = threading.Event(), threading.Event()

        def blocked_turn(*_args):
            entered.set()
            finish.wait(timeout=5)
            return {"answer": "Finished", "tools": []}

        self.agent.turn.side_effect = blocked_turn
        value = payload()
        try:
            self.assertEqual((await self.post(value)).status, 200)
            self.assertTrue(await asyncio.to_thread(entered.wait, 2))
            task = next(
                task
                for task in asyncio.all_tasks()
                if task.get_coro().__qualname__.endswith(".run_turn")
            )
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            self.assertTrue(self.store.lock.exists())
            self.assertEqual((await self.post(value)).status, 200)
            self.agent.turn.assert_called_once()
        finally:
            finish.set()

    async def test_turn_limit_and_long_unicode_history(self):
        value = payload()
        message = admit(value, self.config)
        session = self.store.session(message)
        session["turns"] = 8
        self.store.save_session(message, session)
        self.assertEqual((await self.post(value)).status, 429)
        self.agent.turn.assert_not_called()
        self.assertEqual((await self.post(payload("/reset"))).status, 200)
        self.agent.turn.return_value = {"answer": "\U0001f600" * 12000, "tools": []}
        for _ in range(3):
            value = payload("\U0001f600" * 2000)
            self.assertEqual((await self.post(value)).status, 200)
            self.assertEqual((await self.settled(admit(value, self.config)))["status"], "delivered")
        self.assertLess(self.store.path("session", message.conversation).stat().st_size, 131072)

    async def test_background_failure_is_sanitized_and_never_retried(self):
        self.agent.turn.side_effect = RuntimeError("Secret raw upstream response")
        value = payload()
        self.assertEqual((await self.post(value)).status, 200)
        self.assertEqual(
            (await self.settled(admit(value, self.config)))["status"], "outcome-unknown"
        )
        self.assertNotIn("Secret raw", str(self.events.call_args_list))
        self.assertEqual((await self.post(value)).status, 200)
        self.agent.turn.assert_called_once()

    def test_live_mode_requires_a_complete_owned_binding(self):
        with self.assertRaisesRegex(Exception, "binding_missing_or_invalid"):
            create_teams_app(
                settings(mode="live"), self.config, self.agent, self.adapter, self.store
            )

    async def test_live_mode_controls_fresh_followup_and_status_preserve_no_replay(self):
        await self.client.close()
        with patch("teams_server.configure"):
            app = create_teams_app(
                live_settings(), self.config, self.agent, self.adapter, self.store
            )
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)
        self.assertEqual((await self.post(payload("/fixture interrupted"))).status, 200)
        self.assertIn("disabled", self.adapter.messages[-1])
        self.agent.turn.assert_not_called()
        value = payload("Check BE and NL checkout health")
        self.assertEqual((await self.post(value)).status, 200)
        await self.settled(admit(value, self.config))
        self.assertIn("Checking fresh live checkout", self.adapter.messages[-2])
        self.assertIn("LIVE EVIDENCE MODE", self.adapter.messages[-1])
        self.assertEqual((await self.post(value)).status, 200)
        self.agent.turn.assert_called_once()
        self.assertEqual((await self.post(payload("/status"))).status, 200)
        self.assertIn("not a fresh observation", self.adapter.messages[-1])
        self.agent.turn.assert_called_once()
        followup = payload("Check again with new BE/NL evidence")
        self.assertEqual((await self.post(followup)).status, 200)
        await self.settled(admit(followup, self.config))
        self.assertEqual(self.agent.turn.call_count, 2)
        self.assertEqual((await self.post(payload("/reset"))).status, 200)
        self.assertIn("Live evidence remains attached", self.adapter.messages[-1])

    async def live_agent_host(self, query, clock):
        await self.client.close()
        config = live_settings()
        reader = LiveReader(config, None)
        reader._query = Mock(side_effect=query)
        evidence = EvidenceService(config, clock=clock, live_reader=reader)
        fake = FakeResponses(
            [
                item
                for turn in range(2)
                for item in (
                    response(
                        f"r{turn}-tool",
                        [call("assess_store_impact", ["BE", "NL"], 60, f"c{turn}")],
                    ),
                    response(f"r{turn}-answer", text="Evidence reviewed; recovery is not proven."),
                )
            ]
        )
        self.agent = FoundryAgent(config, evidence, responses=fake)
        with patch("teams_server.configure"):
            app = create_teams_app(config, self.config, self.agent, self.adapter, self.store)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)
        return reader, fake

    async def test_mode_transitions_hide_saved_answers_without_replaying_old_activities(self):
        value = payload("Check BE/NL checkout health")
        self.assertEqual((await self.post(value)).status, 200)
        await self.settled(admit(value, self.config))
        claims_root = self.store.claims_root
        for index, config in enumerate((live_settings(), settings()), start=1):
            await self.client.close()
            self.store = ReceiptStore(
                Path(self.directory.name) / f"revision-{index}",
                claims_directory=claims_root,
            )
            with patch("teams_server.configure"):
                app = create_teams_app(config, self.config, self.agent, self.adapter, self.store)
            self.client = TestClient(TestServer(app))
            await self.client.start_server()
            self.addAsyncCleanup(self.client.close)
            self.assertEqual((await self.post(value)).status, 200)
            self.assertEqual(self.agent.turn.call_count, index)
            self.assertEqual((await self.post(payload("/status"))).status, 200)
            self.assertIn("No earlier question", self.adapter.messages[-1])
            fresh = payload("Check BE/NL with fresh evidence")
            self.assertEqual((await self.post(fresh)).status, 200)
            await self.settled(admit(fresh, self.config))
            self.assertEqual(self.agent.turn.call_args.args[0], [])

    async def test_real_live_assessment_followup_status_and_duplicate(self):
        now = datetime(2026, 10, 25, 13, 30, tzinfo=UTC)

        def query(text):
            if text.startswith("Syslog"):
                return [{"receipt": json.dumps(self.live_receipt(now))}]
            return [
                {
                    "country": country,
                    "store": f"{country}-001",
                    "failed": 2,
                    "succeeded": 10,
                    "latest": now.isoformat(),
                }
                for country in ("BE", "NL")
            ]

        reader, fake = await self.live_agent_host(query, lambda: now)
        value = payload("Which BE/NL stores need attention?")
        self.assertEqual((await self.post(value)).status, 200)
        await self.settled(admit(value, self.config))
        output = self.assessment_output(fake, 1)
        self.assertFalse(output["health"]["synthetic"])
        self.assertTrue(output["storeContext"]["synthetic"])
        priorities = {row["store"]: row for row in output["priorities"]}
        self.assertTrue(priorities["BE-001"]["observedCheckoutFailuresAtStore"])
        self.assertFalse(priorities["BE-002"]["observedCheckoutFailuresAtStore"])
        self.assertTrue(priorities["BE-002"]["exposedToSharedDependency"])
        self.assertFalse(output["recoveryProven"])
        self.assertEqual((await self.post(value)).status, 200)
        self.assertEqual((await self.post(payload("/status"))).status, 200)
        self.assertIn("not a fresh observation", self.adapter.messages[-1])
        self.assertEqual(reader._query.call_count, 2)
        self.assertEqual(len(fake.requests), 2)
        now += timedelta(seconds=1)
        followup = payload("Check BE/NL again with fresh evidence")
        self.assertEqual((await self.post(followup)).status, 200)
        await self.settled(admit(followup, self.config))
        fresh = self.assessment_output(fake, 3)
        self.assertNotEqual(output["evidenceId"], fresh["evidenceId"])
        self.assertNotEqual(output["queriedAt"], fresh["queriedAt"])
        self.assertEqual(reader._query.call_count, 4)

    @staticmethod
    def live_receipt(now):
        return {
            "schemaVersion": 1,
            "ownerToken": live_settings().checkout_owner,
            "event": "checkout-service-observation",
            "service": "retailtx-price-primary.service",
            "active": False,
            "healthy": False,
            "observedAtUtc": now.isoformat(),
            "marker": {"scenario": "service", "phase": "fault-active"},
        }

    @staticmethod
    def assessment_output(fake, request):
        outputs = [
            item
            for item in fake.requests[request]["input"]
            if item.get("type") == "function_call_output"
        ]
        return json.loads(outputs[-1]["output"])

    async def test_real_live_reader_failures_remain_unknown_without_fixture_fallback(self):
        now = datetime(2026, 10, 25, 13, 30, tzinfo=UTC)
        for failure in ("missing", "stale", "wrong-owner", "query-error"):
            with self.subTest(failure=failure):

                def query(_text, failure=failure):
                    if failure == "query-error":
                        raise TimeoutError("Private query details")
                    if failure == "missing":
                        return []
                    receipt = self.live_receipt(now)
                    if failure == "stale":
                        receipt["observedAtUtc"] = (now - timedelta(seconds=301)).isoformat()
                    else:
                        receipt["ownerToken"] = "unowned"
                    return [{"receipt": json.dumps(receipt)}]

                reader, fake = await self.live_agent_host(query, lambda: now)
                value = payload("Which BE/NL stores need attention?")
                with patch("evidence.fixture_health", side_effect=AssertionError("No fallback")):
                    self.assertEqual((await self.post(value)).status, 200)
                    await self.settled(admit(value, self.config))
                output = self.assessment_output(fake, 1)
                self.assertEqual(output["status"], "unknown")
                self.assertFalse(output["health"]["synthetic"])
                self.assertFalse(output["recoveryProven"])
                self.assertTrue(all(p["priority"] == "investigate" for p in output["priorities"]))
                self.assertEqual(reader._query.call_count, 1)

    def test_teams_exports_events_not_sdk_identifiers_or_exception_spans(self):
        with (
            patch.dict(os.environ, {"APPLICATIONINSIGHTS_CONNECTION_STRING": "test-only"}),
            patch("telemetry._CONFIGURED", False),
            patch("azure.monitor.opentelemetry.configure_azure_monitor") as exporter,
        ):
            configure(events_only=True)
            self.assertEqual(os.environ["OTEL_TRACES_EXPORTER"], "none")
            self.assertEqual(os.environ["OTEL_METRICS_EXPORTER"], "none")
            self.assertFalse(exporter.call_args.kwargs["enable_live_metrics"])
            self.assertFalse(exporter.call_args.kwargs["enable_performance_counters"])
