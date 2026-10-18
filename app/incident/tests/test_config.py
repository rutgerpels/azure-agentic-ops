import os
import unittest
from unittest.mock import patch
from uuid import UUID

from config import Settings
from helpers import OPERATOR, TENANT, principal

ENV = {
    "FOUNDRY_PROJECT_ENDPOINT": "https://incident-proof.services.ai.azure.com/api/projects/incident",
    "DEMO_TENANT_ID": TENANT,
    "DEMO_ALLOWED_OBJECT_ID": OPERATOR,
    "DEMO_OWNER_TOKEN": str(UUID(int=1)),
    "DEMO_RUN_ID": "test-run-123456",
    "DEMO_EVIDENCE_MODE": "fixture",
    "WEBSITE_HOSTNAME": "incident-proof.azurewebsites.net",
}


class ConfigTests(unittest.TestCase):
    def test_bootstrap_requires_no_agent_version(self):
        with patch.dict(os.environ, ENV, clear=True):
            self.assertEqual("", Settings.from_env(bootstrap=True).agent_version)
            with self.assertRaises(ValueError):
                Settings.from_env()

    def test_asgi_starts_without_version_but_chat_fails_closed(self):
        from fastapi.testclient import TestClient

        from app import create_app

        with patch.dict(os.environ, ENV, clear=True), patch("app.FoundryAgent") as factory:
            with TestClient(
                create_app(), base_url="https://incident-proof.azurewebsites.net"
            ) as client:
                liveness = client.get("/health/live")
                self.assertEqual(200, liveness.status_code)
                self.assertEqual({"status": "ok"}, liveness.json())
                self.assertIn(client.get("/api/session").status_code, (401, 403))
                client.headers["x-ms-client-principal"] = principal()
                self.assertEqual(200, client.get("/").status_code)
                response = client.get("/api/session")
                self.assertEqual(200, response.status_code)
                self.assertFalse(response.json()["agentConfigured"])
                chat = client.post(
                    "/api/chat",
                    json={"message": "Check BE checkout health."},
                    headers={
                        "Origin": "https://incident-proof.azurewebsites.net",
                        "X-CSRF-Token": response.json()["csrfToken"],
                    },
                )
                self.assertEqual(503, chat.status_code)
                self.assertEqual("agent_not_configured", chat.json()["error"])
                self.assertEqual(32, len(chat.json()["traceId"]))
            factory.assert_not_called()

    def test_runtime_requires_explicit_mode_and_version(self):
        with patch.dict(os.environ, {**ENV, "FOUNDRY_AGENT_VERSION": "7"}, clear=True):
            self.assertEqual("7", Settings.from_env().agent_version)
        for key, value in (
            ("DEMO_EVIDENCE_MODE", ""),
            ("DEMO_EVIDENCE_MODE", "auto"),
            ("FOUNDRY_PROJECT_ENDPOINT", "https://evil.example/api/projects/x"),
            (
                "FOUNDRY_PROJECT_ENDPOINT",
                "https://incident.ai.azure.com.evil.example/api/projects/x",
            ),
            ("FOUNDRY_PROJECT_ENDPOINT", "https://incident.ai.azure.com/api/projects/x?token=foo"),
            ("WEBSITE_HOSTNAME", "localhost"),
            ("DEMO_ALLOWED_OBJECT_ID", "not-a-guid"),
        ):
            with (
                self.subTest(key=key, value=value),
                patch.dict(
                    os.environ, {**ENV, key: value, "FOUNDRY_AGENT_VERSION": "7"}, clear=True
                ),
                self.assertRaises(ValueError),
            ):
                Settings.from_env()

    def test_regional_app_service_hostname(self):
        with patch.dict(
            os.environ,
            {
                **ENV,
                "FOUNDRY_AGENT_VERSION": "1",
                "WEBSITE_HOSTNAME": "incident-hash.swedencentral-01.azurewebsites.net",
            },
            clear=True,
        ):
            self.assertEqual(
                "incident-hash.swedencentral-01.azurewebsites.net", Settings.from_env().hostname
            )


if __name__ == "__main__":
    unittest.main()
