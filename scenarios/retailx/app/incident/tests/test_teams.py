import json
import os
import struct
import tempfile
import time
import unittest
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4
from zipfile import ZipFile

from helpers import OPERATOR, TENANT, live_settings, settings
from teams import ReceiptStore, TeamsError, TeamsSettings, admit, control, reply_text
from teams_package import build_package

BOT = "33333333-3333-4333-8333-333333333333"


def payload(text="What is the checkout impact?", **changes):
    value = {
        "type": "message",
        "id": str(uuid4()),
        "channelId": "msteams",
        "timestamp": datetime.now(UTC).isoformat(),
        "serviceUrl": "https://smba.trafficmanager.net/emea/",
        "conversation": {"id": "personal-demo", "conversationType": "personal", "tenantId": TENANT},
        "channelData": {"tenant": {"id": TENANT}},
        "from": {"id": "29:demo", "aadObjectId": OPERATOR},
        "recipient": {"id": f"28:{BOT}"},
        "text": text,
    }
    value.update(changes)
    return value


class TeamsCoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.settings = TeamsSettings(BOT, TENANT, OPERATOR, Path(self.directory.name))
        self.store = ReceiptStore(self.settings.directory)

    def message(self, text="What happened?"):
        return admit(payload(text), self.settings)

    def test_personal_admission_and_hashed_storage_keys(self):
        message = self.message()
        self.assertEqual(len(message.conversation), 64)
        self.assertEqual(len(message.operation), 64)
        self.assertNotIn(OPERATOR, message.conversation)

    def test_rejects_wrong_identity_scope_and_recipient(self):
        mutations = [
            {"from": {"aadObjectId": BOT}},
            {"channelData": {"tenant": {"id": BOT}}},
            {"recipient": {"id": f"28:{OPERATOR}"}},
            {"recipient": {"id": f"28:{BOT}", "role": "agentic_identity"}},
            {"channelId": "directline"},
            {"conversation": {"id": "x", "conversationType": "channel"}},
            {"conversation": {"id": "x", "conversationType": "groupChat"}},
            {"conversation": {"id": "x", "conversationType": "personal", "tenantId": BOT}},
            {"attachments": [{"contentType": "application/pdf", "content": "not allowed"}]},
            {"value": {"command": "repair"}},
        ]
        for change in mutations:
            with self.subTest(change=change), self.assertRaises(TeamsError):
                admit(payload(**change), self.settings)

    def test_rejects_stale_future_and_malformed_activities(self):
        for delta in (-601, 61):
            timestamp = (datetime.now(UTC) + timedelta(seconds=delta)).isoformat()
            with self.assertRaises(TeamsError):
                admit(payload(timestamp=timestamp), self.settings)
        for change in (
            {"timestamp": "invalid"},
            {"timestamp": "2026-01-01T12:00:00"},
            {"channelData": []},
            {"from": None},
            {"id": "../escape"},
            {"text": ""},
            {"text": "x" * 2001},
            {"text": "\0"},
        ):
            # Activity IDs are opaque and hashed, so path-like IDs are safe.
            if change.get("id") == "../escape":
                self.assertEqual(len(admit(payload(**change), self.settings).operation), 64)
            else:
                with self.subTest(change=change), self.assertRaises(TeamsError):
                    admit(payload(**change), self.settings)

    def test_teams_html_presentation_is_ignored_not_rendered_or_fetched(self):
        html = '<p>Question <a href="https://untrusted.example/">link</a></p>'
        message = admit(
            payload("Plain question", attachments=[{"contentType": "text/html", "content": html}]),
            self.settings,
        )
        self.assertEqual(message.text, "Plain question")
        for attachments in (
            [{"contentType": "text/html", "content": html, "contentUrl": "https://example.com"}],
            [{"contentType": "text/html", "content": "x" * 16001}],
            [{"contentType": "application/vnd.microsoft.card.adaptive", "content": {}}],
            [{"contentType": "text/html", "content": html}] * 2,
        ):
            with self.subTest(attachments=attachments), self.assertRaises(TeamsError):
                admit(payload(attachments=attachments), self.settings)

    def test_service_url_does_not_allow_redirect_or_ssrf_targets(self):
        for url in (
            "http://smba.trafficmanager.net/emea/",
            "https://127.0.0.1/",
            "https://smba.trafficmanager.net.evil.example/",
            "https://user@smba.trafficmanager.net/",
            "https://smba.trafficmanager.net:444/",
            "https://smba.trafficmanager.net/?redirect=elsewhere",
            "https://smba.trafficmanager.net/#fragment",
            "https://[::1]/",
        ):
            with self.subTest(url=url), self.assertRaises(TeamsError):
                admit(payload(serviceUrl=url), self.settings)

    def test_duplicate_survives_restart_and_never_replays(self):
        message = self.message()
        self.assertTrue(self.store.claim(message))
        self.store.complete(message, "outcome-unknown")
        restarted = ReceiptStore(self.settings.directory)
        self.assertFalse(restarted.claim(message))

    def test_active_operation_survives_restart_and_needs_explicit_reset(self):
        message = self.message()
        self.store.acquire(message)
        restarted = ReceiptStore(self.settings.directory)
        with self.assertRaisesRegex(TeamsError, "request_in_progress"):
            restarted.acquire(self.message("/reset"))
        old = time.time() - 241
        os.utime(self.store.lock, (old, old))
        with self.assertRaisesRegex(TeamsError, "previous_outcome_unknown"):
            restarted.acquire(self.message())
        reset = self.message("/reset")
        restarted.acquire(reset)
        restarted.release(reset)
        self.assertFalse(self.store.lock.exists())

    def test_evidence_transition_retains_active_lock_and_accepted_status(self):
        message = self.message()
        self.store.acquire(message)
        transitioned = ReceiptStore(
            self.settings.directory / "new-evidence-revision",
            claims_directory=self.store.claims_root,
        )
        with self.assertRaisesRegex(TeamsError, "request_in_progress"):
            transitioned.acquire(self.message())
        self.store.release(message)
        fresh = self.message()
        self.assertTrue(transitioned.claim(fresh))
        transitioned.start(fresh)
        self.assertIn("Previous request: accepted", transitioned.status(fresh))
        self.assertFalse(self.store.claim(fresh))

    def test_status_controls_do_not_replace_last_question(self):
        message = self.message()
        self.store.start(message)
        self.store.complete(message, "outcome-unknown", "Saved evidence")
        help_message = self.message("/help")
        self.store.acquire(help_message)
        self.store.release(help_message)
        self.assertIn("Saved evidence", self.store.status(help_message))
        self.assertIn("not a fresh observation", self.store.status(help_message))
        receipt = self.store.read(self.store.path("latest", message.conversation))
        receipt["expires"] = time.time() - 1
        self.store.write(self.store.path("latest", message.conversation), receipt)
        self.assertIn("No earlier question", self.store.status(message))

    def test_rate_limit_and_expired_receipt_cleanup(self):
        for _ in range(6):
            self.assertTrue(self.store.claim(self.message()))
        with self.assertRaisesRegex(TeamsError, "rate_limited"):
            self.store.claim(self.message())
        old = time.time() - 3601
        for path in self.settings.directory.glob("receipt-*.json"):
            os.utime(path, (old, old))
        self.assertTrue(self.store.claim(self.message()))

    def test_session_and_serialized_state_bounds(self):
        message = self.message()
        for number in range(8):
            other = admit(
                payload(conversation={"id": str(number), "conversationType": "personal"}),
                self.settings,
            )
            self.store.save_session(other, self.store.session(other))
        with self.assertRaisesRegex(TeamsError, "session_limit"):
            self.store.session(message)
        with self.assertRaisesRegex(TeamsError, "state_limit"):
            self.store.write(self.store.path("session", message.conversation), {"x": "a" * 131072})
        with self.assertRaisesRegex(TeamsError, "invalid_store_key"):
            self.store.path("session", "../escape")

    def test_controls_only_change_synthetic_fixture(self):
        session = self.store.session(self.message())
        self.assertIn("no real resource", control("/fixture interrupted", session))
        self.assertEqual(session["fixture"], "interrupted")
        self.assertIn("healthy", control("/reset", session))
        self.assertEqual(session["fixture"], "healthy")
        for text in ("/fixture ownership-mismatch", "/repair", "/fixture live"):
            with self.assertRaises(TeamsError):
                control(text, session)

    def test_live_controls_cannot_select_fixture_or_claim_reset_recovery(self):
        session = self.store.session(self.message())
        session["history"] = [{"role": "assistant", "content": "Old observation"}]
        original = json.loads(json.dumps(session))
        answer = control("/fixture interrupted", session, "live")
        self.assertIn("disabled", answer)
        self.assertEqual(session, original)
        self.assertIn("Live checkout observations", control("/help", session, "live"))
        answer = control("/reset", session, "live")
        self.assertIn("Live evidence remains attached", answer)
        self.assertEqual(session["history"], [])
        self.assertIn("no recovery", answer)

    def test_environment_binding_and_revision_isolate_history_and_receipts(self):
        config = live_settings()
        env = {
            "TEAMS_BOT_CLIENT_ID": BOT,
            "TEAMS_ALLOWED_OBJECT_ID": OPERATOR,
            "TEAMS_EVIDENCE_REVISION": "66666666-6666-4666-8666-666666666666",
        }
        with patch.dict(os.environ, env):
            live = TeamsSettings.from_env(config)
            self.assertEqual(
                live.claims_directory, TeamsSettings.from_env(settings()).claims_directory
            )
            self.assertNotEqual(live.directory, TeamsSettings.from_env(settings()).directory)
            changed = replace(config, checkout_owner="77777777-7777-4777-8777-777777777777")
            self.assertNotEqual(live.directory, TeamsSettings.from_env(changed).directory)
            os.environ["TEAMS_EVIDENCE_REVISION"] = "88888888-8888-4888-8888-888888888888"
            self.assertNotEqual(live.directory, TeamsSettings.from_env(config).directory)
            del os.environ["TEAMS_EVIDENCE_REVISION"]
            with self.assertRaisesRegex(TeamsError, "revision_required"):
                TeamsSettings.from_env(config)

    def test_incomplete_or_cross_group_live_binding_fails_before_startup(self):
        config = live_settings()
        env = {"TEAMS_BOT_CLIENT_ID": BOT, "TEAMS_ALLOWED_OBJECT_ID": OPERATOR}
        for changes in (
            {"workspace": ""},
            {"workspace_resource": config.arc_resource},
            {"checkout_owner": "'| take 1"},
            {"app_resource": config.app_resource.replace("/checkout/", "/different/")},
        ):
            with (
                self.subTest(changes=changes),
                patch.dict(os.environ, env),
                self.assertRaisesRegex(TeamsError, "binding_missing_or_invalid"),
            ):
                TeamsSettings.from_env(replace(config, **changes))

    def test_short_default_and_explicit_technical_trail_with_byte_bound(self):
        result = {
            "answer": "Observed interruption.",
            "tools": [
                {
                    "name": "get_checkout_health",
                    "observedAt": "2026-01-01T12:00:00Z",
                    "queriedAt": "2026-01-01T12:00:01Z",
                    "evidenceId": "fixture:one",
                    "source": "synthetic-fixture",
                    "status": "known",
                }
            ],
        }
        text = reply_text(result)
        self.assertEqual(result["answer"], text)
        self.assertNotIn("fixture:one", text)
        self.assertNotIn("Tool observations", text)
        result["technicalDetails"] = True
        text = reply_text(result)
        self.assertIn("queried 2026-01-01", text)
        self.assertIn("fixture:one", text)
        result["answer"] = "\U0001f600" * 12000
        for technical in (False, True):
            result["technicalDetails"] = technical
            self.assertLessEqual(len(reply_text(result).encode()), 20000)

    def test_private_provenance_survives_delivery_status_without_leaking_to_status(self):
        message = self.message()
        self.store.start(message)
        tools = [{
            "name": "get_checkout_health", "evidenceId": "ev-private-receipt",
            "observedAt": "2026-10-26T18:39:36Z", "queriedAt": "2026-10-26T18:41:32Z",
            "source": "owned-checkout-log-analytics", "status": "known",
            "result": {"notNeededInReceipt": "do-not-copy"},
        }]
        self.store.complete(message, "delivery-started", "The latest checks look normal.", tools)
        self.store.complete(message, "outcome-unknown", "The latest checks look normal.")
        receipt = self.store.read(self.store.path("receipt", message.operation))
        self.assertEqual("ev-private-receipt", receipt["evidence"][0]["evidenceId"])
        self.assertNotIn("result", receipt["evidence"][0])
        self.assertNotIn("ev-private-receipt", self.store.status(message))
        self.assertIn("not a fresh observation", self.store.status(message))

    def test_personal_package_and_required_icon_dimensions(self):
        output = Path(self.directory.name) / "personal.zip"
        manifest = build_package(BOT, TENANT, "app-rtx-teams-demo-abcdef.azurewebsites.net", output)
        self.assertEqual(manifest["bots"][0]["scopes"], ["personal"])
        self.assertNotIn("webApplicationInfo", manifest)
        self.assertNotIn("permissions", manifest)
        with ZipFile(output) as archive:
            self.assertEqual(set(archive.namelist()), {"manifest.json", "color.png", "outline.png"})
            self.assertEqual(json.loads(archive.read("manifest.json")), manifest)
            for name, size in (("color", 192), ("outline", 32)):
                self.assertEqual(
                    struct.unpack(">II", archive.read(f"{name}.png")[16:24]), (size, size)
                )
        with self.assertRaises(ValueError):
            build_package(BOT, TENANT, "evil.example", output)
