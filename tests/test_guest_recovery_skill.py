"""Execute the skill's readable wrapper locally with all guest effects mocked."""

import base64
import io
import json
import re
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "docs" / "agent-context" / "skills" / "guest-service-recovery" / "SKILL.md"
CONTENT = SKILL.read_text(encoding="utf-8")
MATCH = re.search(r"```python\n(.*?)\n```", CONTENT, re.DOTALL)
assert MATCH is not None
WRAPPER = MATCH.group(1)
IDS = {
    "ownerToken": "11111111-1111-1111-1111-111111111111",
    "actionPrincipalId": "22222222-2222-2222-2222-222222222222",
    "runId": "33333333-3333-3333-3333-333333333333",
    "originalActor": "44444444-4444-4444-4444-444444444444",
}


class GuestRecoverySkillTests(unittest.TestCase):
    def script_for(self, ids=None):
        script = WRAPPER
        for name, value in (IDS if ids is None else ids).items():
            script = script.replace(f"<{name}>", value)
        return compile(script, "SKILL.md:readable-wrapper", "exec")

    def test_readable_wrapper_encodes_only_bound_controller_json(self):
        hashes = {"controller.py": "a" * 64}
        config = {"schemaVersion": 2, "ownerToken": IDS["ownerToken"], "sourceHashes": hashes}
        with (
            patch("builtins.open", return_value=io.StringIO(json.dumps(config))) as read,
            patch("subprocess.run") as run,
        ):
            exec(self.script_for(), {})
        read.assert_called_once_with("/opt/retailtx-guest/config.json", encoding="utf-8")
        run.assert_called_once()
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[:2], ["python3", "/opt/retailtx-guest/controller.py"])
        request = json.loads(base64.b64decode(arguments[2]))
        self.assertEqual(
            request,
            {
                "action": "repair",
                "ownerToken": IDS["ownerToken"],
                "actor": IDS["actionPrincipalId"],
                "runId": IDS["runId"],
                "expectedActor": IDS["originalActor"],
                "expectedFaultLifetime": "Manual",
                "sourceHashes": hashes,
            },
        )
        self.assertEqual(run.call_args.kwargs, {"check": True, "timeout": 90})
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_malformed_or_injected_uuid_fails_before_config_and_execution(self):
        for value in ("", "not-a-uuid", "';systemctl start other", "<runId>"):
            ids = {**IDS, "runId": value}
            with (
                self.subTest(value=value),
                patch("builtins.open") as read,
                patch("subprocess.run") as run,
                self.assertRaises(ValueError),
            ):
                exec(self.script_for(ids), {})
            read.assert_not_called()
            run.assert_not_called()

    def test_wrong_config_owner_or_legacy_lifetime_never_executes(self):
        for config in (
            {"schemaVersion": 1, "ownerToken": IDS["ownerToken"], "sourceHashes": {}},
            {"schemaVersion": 2, "ownerToken": IDS["runId"], "sourceHashes": {}},
        ):
            with (
                self.subTest(config=config),
                patch("builtins.open", return_value=io.StringIO(json.dumps(config))),
                patch("subprocess.run") as run,
                self.assertRaises(ValueError),
            ):
                exec(self.script_for(), {})
            run.assert_not_called()

    def test_missing_hash_manifest_is_not_a_success_fallback(self):
        config = {"schemaVersion": 2, "ownerToken": IDS["ownerToken"]}
        with (
            patch("builtins.open", return_value=io.StringIO(json.dumps(config))),
            patch("subprocess.run") as run,
            self.assertRaises(KeyError),
        ):
            exec(self.script_for(), {})
        run.assert_not_called()

    def test_tool_frontmatter_and_no_opaque_executable_script(self):
        frontmatter = CONTENT.split("---", 2)[1]
        self.assertEqual(
            re.findall(r"^  - (.+)$", frontmatter, re.MULTILINE),
            ["RunAzCliReadCommands", "RunAzCliWriteCommands"],
        )
        self.assertNotIn("base64 --decode", WRAPPER)
        self.assertNotIn("systemctl", WRAPPER)
        self.assertIn("--no-wait --output json", CONTENT)
        for required in (
            "three minutes",
            "30 seconds",
            "original actor",
            "correlationId",
            "operationId",
            "never replay",
            "recoveredBy",
            "service-only",
            "one human approval",
            "UNKNOWN",
        ):
            self.assertIn(required, CONTENT)

    def test_unexposed_metadata_does_not_invent_absent_approval_or_submission(self):
        outcome = CONTENT.split("## Independently check the outcome, without replay", 1)[1]
        for required in (
            "metadata not exposed",
            'not "no approval card", "not approved" or "not submitted"',
            "Only explicit card/decision evidence establishes approval status",
            "not\nsubmission start",
            "before-repair receipt",
            "proposal/card creation time or human approval time",
            "Azure execution\nevidence",
            "never as a known native CLI start",
            "discovery only",
            "exactly one correlation",
            "Do not move or widen it",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, outcome)

    def test_pre_action_receipts_and_ingestion_delay_require_pending_not_failure(self):
        outcome = CONTENT.split("## Independently check the outcome, without replay", 1)[1]
        for required in (
            "pending audit evidence",
            'not "no submission"',
            "A pre-action receipt cannot establish post-action failure",
            "strictly newer observation after",
            "pending recovery",
            "Only a same-run unhealthy observation after the correlated terminal operation",
            "at most three additional paired read-only LAW",
            "No repair replay, new card",
            "sleep/timer tool",
            "Stop at the fixed window's bound",
            "approval/execution provenance separate",
            "Alert acknowledgement events\nare a different operation",
            "outside the model's tool inventory",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, outcome)


if __name__ == "__main__":
    unittest.main()
