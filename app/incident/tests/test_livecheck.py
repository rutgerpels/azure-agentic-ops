import json
import unittest
from datetime import UTC, datetime
from unittest.mock import patch

from helpers import settings

NOW = datetime(2026, 1, 1, 12, 0, tzinfo=UTC)


class FakeEvidence:
    def __init__(self, status="known", phase="fault-active"):
        self.status = status
        self.phase = phase

    def execute(self, name, arguments, scope, state):
        return {
            "evidenceId": "ev-live",
            "queriedAt": NOW.isoformat(),
            "observedAt": NOW.isoformat(),
            "source": "owned-checkout-log-analytics",
            "synthetic": False,
            "status": self.status,
            "reason": None if self.status == "known" else "missing_owned_arc_observation",
            "ageSeconds": 42.0,
            "maxAgeSeconds": 300,
            "serviceIncidentPhase": self.phase,
            "serviceActive": False,
            "serviceHealthy": False,
            "countries": [
                {
                    "country": "BE",
                    "health": "degraded",
                    "observedFailedCheckouts": 9,
                    "observedSuccessfulCheckouts": 0,
                    "observedFailedStores": ["BE-001"],
                    "sharedDependencyExposed": True,
                }
            ],
            "recoveryProven": False,
            "evidenceMode": "live",
        }


class FakeAgent:
    def __init__(self, tool_mode="live", tool_name="get_checkout_health"):
        self.closed = False
        self.tool_mode = tool_mode
        self.tool_name = tool_name

    def turn(self, history, message, scope, state):
        return {
            "answer": "PRIVATE-ANSWER-TEXT: BE and NL checkout is degraded.",
            "tools": [
                {
                    "name": self.tool_name,
                    "evidenceId": "ev-live-2",
                    "observedAt": NOW.isoformat(),
                    "status": "known",
                    "reason": None,
                    "evidenceMode": self.tool_mode,
                    "result": {"secret": "full tool result is never in the public receipt"},
                }
            ],
            "recoveryProven": False,
        }

    def close(self):
        self.closed = True


class LiveCheckTests(unittest.TestCase):
    def run_check(self, evidence, agent, cfg=None):
        import manage

        saved = {}

        def save(_settings, payload):
            saved.update(payload)
            return "/home/data/incident/private.json"

        with patch("manage.save_receipt", side_effect=save):
            result = manage.livecheck(cfg or settings(mode="live"), evidence, agent)
        return result, saved

    def test_requires_live_mode(self):
        import manage

        with self.assertRaisesRegex(ValueError, "livecheck_requires_live_mode"):
            manage.livecheck(settings(), FakeEvidence(), FakeAgent())

    def test_live_fault_observation_is_usable_and_answer_stays_private(self):
        agent = FakeAgent()
        result, saved = self.run_check(FakeEvidence(), agent)
        self.assertTrue(agent.closed)
        self.assertTrue(result["pass"])
        self.assertTrue(result["liveEvidenceUsable"])
        self.assertEqual("fault-active", result["health"]["serviceIncidentPhase"])
        self.assertFalse(result["health"]["recoveryProven"])
        public = json.dumps(result)
        self.assertNotIn("PRIVATE-ANSWER-TEXT", public)
        self.assertNotIn("never in the public receipt", public)
        self.assertNotIn("observedFailedStores", public)
        self.assertIn("PRIVATE-ANSWER-TEXT", saved["answer"])

    def test_unknown_or_non_live_evidence_is_not_usable(self):
        for evidence, agent, failed in (
            (FakeEvidence(status="unknown"), FakeAgent(), "evidenceKnown"),
            (FakeEvidence(), FakeAgent(tool_mode="fixture"), "agentUsedLiveEvidence"),
            (FakeEvidence(), FakeAgent(tool_name="get_store_context"), "agentUsedLiveEvidence"),
        ):
            with self.subTest(failed=failed):
                result, _ = self.run_check(evidence, agent)
                self.assertTrue(result["pass"])
                self.assertFalse(result["liveEvidenceUsable"])
                self.assertFalse(result["assertions"][failed])


if __name__ == "__main__":
    unittest.main()
