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
        invocation = re.search(r"```azurecli\n(az vm run-command invoke.*?)\n```", CONTENT, re.S)
        self.assertIsNotNone(invocation)
        assert invocation is not None
        self.assertEqual(invocation.group(1).count("--no-wait"), 1)
        self.assertTrue(invocation.group(1).endswith('PY" --no-wait --output json'))
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

    def test_pending_evidence_governs_the_entire_final_response(self):
        outcome = CONTENT.split("## Independently check the outcome, without replay", 1)[1]
        normalized = " ".join(outcome.split())
        for required in (
            "every heading, progress message, summary and incident note",
            'Never contradict a pending/UNKNOWN outcome with a later heading or sentence saying '
            '"Service remains stopped"',
            "An observation before human approval is necessarily pre-repair",
            "Exhausting the check budget does not turn UNKNOWN into failure",
            "Re-evaluate it after the last read",
            "The final headline, evidence description and summary must agree",
            "Current post-repair health: UNKNOWN.",
            "This is historical evidence, not confirmation that the service is still stopped",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, normalized)

    def test_final_headlines_distinguish_health_from_execution_evidence(self):
        gate = CONTENT.split("### Final-response evidence gate", 1)[1]
        for evidence, headline in (
            ("only a pre-action unhealthy receipt", "Recovery verification pending."),
            ("no observation after terminal completion", "Recovery verification pending."),
            ("completion is incomplete", "Service observed healthy; repair verification pending."),
            ("correlation Succeeded", "Service recovery verified."),
            ("terminal execution failure", "Repair execution failed."),
            ("strictly after that terminal timestamp", "Service unhealthy after repair."),
        ):
            with self.subTest(evidence=evidence):
                rows = [
                    line
                    for line in gate.splitlines()
                    if line.startswith("| ") and evidence in line.split("|")[1]
                ]
                self.assertEqual(len(rows), 1)
                self.assertIn(headline, rows[0])

    def test_pending_templates_preserve_observed_health(self):
        gate = " ".join(CONTENT.split("### Final-response evidence gate", 1)[1].split())
        for required in (
            "When only a pre-action unhealthy receipt is available",
            "For a fresh exact healthy receipt with missing execution provenance/completion",
            "use the healthy-but-pending form instead",
            "do not label observed health UNKNOWN",
            "Latest observation: active/healthy",
            "Missing execution evidence:",
            "Do not force those cases into a pre-action or healthy template",
            "Missing evidence is unavailable, never an invented observation or timestamp",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, gate)

    def test_missing_metadata_never_expands_the_verification_toolset(self):
        outcome = " ".join(
            CONTENT.split("## Independently check the outcome, without replay", 1)[1].split()
        )
        for required in (
            "Do not invent CLI commands",
            "use guest Run Command for a diagnostic lookup",
            "not approval/execution metadata lookups",
            "Read/query failures do not establish repair failure",
            "If audit and receipts conflict or cannot be ordered, report UNKNOWN",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, outcome)

    def test_direct_receipt_requires_health_provenance_and_freshness(self):
        outcome = " ".join(
            CONTENT.split("### Direct result from the approved action", 1)[1].split()
        )
        for required in (
            "exactly one complete",
            "RETAILTX_GUEST=<JSON receipt>",
            "same run and original actor",
            "Boolean active and healthy true",
            "sourceHashes",
            "Both times must follow the exposed native execution start",
            "only this returned output from the exact approved waiting invocation",
            "strictly after the retained before-repair observation",
            "A copied LAW receipt, another invocation",
            "Service health directly verified; Azure audit pending",
            "Do not downgrade valid direct health to UNKNOWN solely because LAW/audit is delayed",
            "Missing/truncated/malformed or multiple receipts",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, outcome)

    def test_waiting_timeout_never_becomes_a_second_repair(self):
        normalized = " ".join(CONTENT.split())
        self.assertIn("Never submit an asynchronous replacement", normalized)
        self.assertIn("not Azure delivery or the native tool", normalized)
        self.assertIn("Never retrieve it by running another guest command", normalized)

    def test_async_action_does_not_require_direct_output_or_waiting(self):
        normalized = " ".join(CONTENT.split())
        for required in (
            "Use `--no-wait`: return after submission",
            "A successful `--no-wait` tool result proves submission only, not guest recovery",
            "compatibility guidance for an already approved historical waiting invocation",
            "skip this section when none is returned and proceed to the LAW/audit checks",
            "Do not change the current invocation to waiting mode",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, normalized)

    def test_ignored_subscription_warning_never_establishes_rejection_or_retry(self):
        outcome = " ".join(
            CONTENT.split("## Independently check the outcome, without replay", 1)[1].split()
        )
        for required in (
            "option '--subscription' will be ignored due to use of '--ids'",
            "It is not an incompatibility error, local rejection or evidence of non-execution",
            "Never claim that this warning proves no approval card or no guest execution",
            "including in progress messages",
            "does not expose the underlying failure cause",
            "UNKNOWN, not an established timeout or local rejection",
            "Preserve explicit approval/execution evidence",
            "Do not resubmit with modified options",
            "generate a replacement card or repeat repair to remove the warning",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, outcome)

    def test_direct_receipt_manifest_and_later_evidence_are_required(self):
        direct = " ".join(
            CONTENT.split("### Direct result from the approved action", 1)[1]
            .split("Repeat the exact LAW query", 1)[0]
            .split()
        )
        for required in (
            "Always require a `sourceHashes` object with exactly these eight keys",
            "lowercase 64-character hexadecimal hash",
            "Missing, empty, incomplete or malformed returned manifests",
            "UNKNOWN even when no expected manifest is available",
            "report independent manifest comparison unavailable",
            "actual Azure Started/recovery timestamp ordering both pass",
            "If a later same-run observation is unhealthy",
            "do not keep a historical direct healthy result as the final current-health conclusion",
        ):
            with self.subTest(contract=required):
                self.assertIn(required, direct)


if __name__ == "__main__":
    unittest.main()
