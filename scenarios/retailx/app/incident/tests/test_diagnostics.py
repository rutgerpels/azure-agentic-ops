import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from diagnostics import ManagementDiagnostics, ResponsesDiagnostics, exception_metadata
from helpers import FakeResponses, settings


class DiagnosticFailure(RuntimeError):
    pass


class ManagementDiagnosticTests(unittest.TestCase):
    def test_denial_classification_requires_known_bounded_message_phrases(self):
        cases = (
            ("Access denied due to Virtual Network/Firewall rules.", "network_acl_denied"),
            ("Principal does not have access to action.", "rbac_denied"),
            ("Principal lacks required RBAC permissions.", "rbac_denied"),
            ("Forbidden", "unknown"),
            (None, "unknown"),
            ("x" * 4096 + " Access denied due to Virtual Network/Firewall rules", "unknown"),
            (
                "Access denied due to Virtual Network/Firewall rules; required RBAC permissions.",
                "ambiguous_denial",
            ),
        )
        for message, classification in cases:
            with self.subTest(classification=classification):
                error = RuntimeError("private-exception-text")
                error.status_code = 403
                error.code = "403"
                error.body = {"error": {"message": message}}
                error.headers = {
                    "private-header": "Access denied due to Virtual Network/Firewall rules"
                }
                metadata = exception_metadata(error)
                self.assertEqual(classification, metadata["classification"])
                self.assertIsNone(metadata["requiredAction"])
                output = json.dumps(metadata)
                self.assertNotIn("private-", output)
                self.assertNotIn("Virtual Network/Firewall", output)
                self.assertNotIn("required RBAC permissions", output)

    def test_required_action_is_allowlisted_exact_and_never_a_resource_identifier(self):
        prefix = "Microsoft.CognitiveServices/accounts/"
        known = [
            prefix + "AIServices/responses/write",
            prefix + "AIServices/agents/read",
            prefix + "OpenAI/deployments/chat/completions/action",
        ]
        for action in known:
            with self.subTest(action=action):
                error = RuntimeError("private-exception-text")
                error.status_code = 403
                error.body = {
                    "error": {
                        "message": f"private-principal does not have access to action '{action}' "
                        "at /subscriptions/private-resource."
                    }
                }
                metadata = exception_metadata(error)
                self.assertEqual("rbac_denied", metadata["classification"])
                self.assertEqual(action, metadata["requiredAction"])
                self.assertNotIn("private-", json.dumps(metadata))
        for action in (
            prefix + "AIServices/agents/delete",
            known[0] + "/private-suffix",
            "/subscriptions/private-resource/providers/" + known[0],
            known[0] + "' or '" + known[1],
        ):
            with self.subTest(action=action):
                error.body = {
                    "error": {"message": f"Principal does not have access to action '{action}'."}
                }
                metadata = exception_metadata(error)
                self.assertEqual("rbac_denied", metadata["classification"])
                self.assertIsNone(metadata["requiredAction"])
                self.assertNotIn("private-", json.dumps(metadata))

    def test_sdk_error_envelopes_only_export_allowlisted_codes_and_parameter_names(self):
        error = RuntimeError("private-exception-message")
        error.status_code = 403
        error.code = "403"
        error.body = {
            "error": {
                "code": "PermissionDenied",
                "innererror": {"code": "AuthorizationFailed"},
                "param": "agent_reference.version",
                "message": "private-response-message",
                "agent_reference.version": "private-parameter-value",
            }
        }
        metadata = exception_metadata(error)
        self.assertEqual(403, metadata["httpStatus"])
        self.assertEqual("403", metadata["sdkErrorCode"])
        self.assertEqual(
            ["403", "PermissionDenied", "AuthorizationFailed"], metadata["sdkErrorCodes"]
        )
        self.assertEqual("agent_reference.version", metadata["parameter"])
        self.assertNotIn("private-", json.dumps(metadata))
        error.code = "private-code-value"
        error.param = "private-parameter-name"
        error.body = {
            "code": "private-body-code",
            "param": "private-body-parameter",
            "message": "private-response-message",
        }
        metadata = exception_metadata(error)
        self.assertIsNone(metadata["sdkErrorCode"])
        self.assertEqual([], metadata["sdkErrorCodes"])
        self.assertIsNone(metadata["parameter"])
        self.assertNotIn("private-", json.dumps(metadata))

    def test_response_stages_have_per_call_timing_and_rounds(self):
        stream = io.StringIO()
        now = [0]
        diagnostics = ResponsesDiagnostics(stream=stream, clock=lambda: now[0])
        for round_number in (0, 1):
            with diagnostics.response(round_number):
                now[0] += 2
        records = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(
            ["started", "completed", "started", "completed"],
            [record["phase"] for record in records],
        )
        self.assertEqual([1, 1, 2, 2], [record["call"] for record in records])
        self.assertEqual([0, 0, 1, 1], [record["round"] for record in records])
        self.assertEqual(4, records[-1]["elapsedSeconds"])
        self.assertEqual(2, records[-1]["stageElapsedSeconds"])

    def test_evaluate_retains_original_failure_metadata_in_private_stderr(self):
        import manage
        from agent import FoundryAgent
        from evidence import EvidenceService

        stream = io.StringIO()
        failures = []
        for _ in range(13):
            failure = RuntimeError("private-evaluation-exception-text")
            failure.status_code = 403
            failure.code = "Forbidden"
            failures.append(failure)
        cfg = settings()
        agent = FoundryAgent(
            cfg,
            EvidenceService(cfg),
            responses=FakeResponses(failures),
            diagnostics=ResponsesDiagnostics(stream=stream),
        )
        with (
            patch("agent.FoundryAgent", return_value=agent),
            patch(
                "manage.save_receipt", return_value="/home/data/incident/synthetic-evaluation.json"
            ),
        ):
            result = manage.evaluate(cfg)
        self.assertFalse(result["pass"])
        self.assertEqual(13, len(result["cases"]))
        self.assertTrue(all(case["error"] == "foundry_request_failed" for case in result["cases"]))
        records = [json.loads(line) for line in stream.getvalue().splitlines()]
        diagnostic_failures = [
            record for record in records if record["event"] == "responses_failure"
        ]
        self.assertEqual(13, len(diagnostic_failures))
        self.assertTrue(
            all(
                record["exceptionType"] == "RuntimeError"
                and record["httpStatus"] == 403
                and record["sdkErrorCode"] == "Forbidden"
                for record in diagnostic_failures
            )
        )
        self.assertNotIn(
            "private-evaluation-exception-text", stream.getvalue() + json.dumps(result)
        )

    def test_stage_metadata_is_private_bounded_json(self):
        stream = io.StringIO()
        now = [0]
        diagnostics = ManagementDiagnostics("bootstrap", stream=stream, clock=lambda: now[0])
        stages = ["list_versions", "get", "create_version", "configure_endpoint"]
        for name in stages:
            with diagnostics.stage(name):
                now[0] += 1.5
        records = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(8, len(records))
        self.assertEqual(stages, [record["stage"] for record in records[::2]])
        self.assertTrue(all(record["phase"] == "started" for record in records[::2]))
        self.assertTrue(all(record["phase"] == "completed" for record in records[1::2]))
        self.assertEqual(6, records[-1]["elapsedSeconds"])
        self.assertEqual(1.5, records[-1]["stageElapsedSeconds"])
        with (
            self.assertRaisesRegex(ValueError, "invalid_management_stage"),
            diagnostics.stage("untrusted-label"),
        ):
            self.fail("Unrecognized management stage was accepted.")
        self.assertNotIn("untrusted-label", stream.getvalue())

    def test_failure_omits_exception_text_paths_locals_and_unknown_codes(self):
        for code, expected in (("Forbidden", "Forbidden"), ("Bearer private-value", None)):
            with self.subTest(code=code):
                stream = io.StringIO()
                diagnostics = ManagementDiagnostics("bootstrap", stream=stream)
                try:
                    with diagnostics.stage("create_version"):
                        private_local = "private-value-must-not-appear"
                        error = DiagnosticFailure(private_local)
                        error.status_code = 403
                        error.error = SimpleNamespace(code=code)
                        raise error
                except DiagnosticFailure as error:
                    diagnostics.failure(error)
                output = stream.getvalue()
                failure = json.loads(output.splitlines()[-1])
                self.assertEqual("management_failure", failure["event"])
                self.assertEqual("create_version", failure["stage"])
                self.assertEqual("DiagnosticFailure", failure["exceptionType"])
                self.assertEqual(403, failure["httpStatus"])
                self.assertEqual(expected, failure["sdkErrorCode"])
                self.assertTrue(failure["frames"])
                self.assertLessEqual(len(failure["frames"]), 24)
                for frame in failure["frames"]:
                    self.assertEqual({"function", "file", "line"}, set(frame))
                    self.assertNotIn("/", frame["file"])
                    self.assertNotIn("\\", frame["file"])
                    self.assertIsInstance(frame["line"], int)
                self.assertNotIn(private_local, output)
                self.assertNotIn("Bearer", output)

    def test_management_failure_preserves_safe_stdout_and_private_diagnostics(self):
        import manage

        stdout, stderr = io.StringIO(), io.StringIO()
        project, credential = Mock(), Mock()
        failure = DiagnosticFailure("raw-private-exception-text")
        failure.code = "Bearer private-value"
        failure.response = SimpleNamespace(status_code=504)
        failure.error = {"code": "GatewayTimeout"}

        def fail_bootstrap(settings, project, diagnostics):
            with diagnostics.stage("list_versions"):
                raise failure

        with (
            patch("sys.argv", ["manage.py", "bootstrap"]),
            patch("sys.stdout", stdout),
            patch("sys.stderr", stderr),
            patch("telemetry.configure"),
            patch("config.Settings.from_env", return_value=settings()),
            patch("agent.project_client", return_value=(project, credential)),
            patch("agent.bootstrap", side_effect=fail_bootstrap),
        ):
            self.assertEqual(1, manage.main())
        public = json.loads(stdout.getvalue())
        self.assertEqual(
            {"pass": False, "errorType": "DiagnosticFailure", "error": "management_command_failed"},
            public,
        )
        private = json.loads(stderr.getvalue().splitlines()[-1])
        self.assertEqual("list_versions", private["stage"])
        self.assertEqual(504, private["httpStatus"])
        self.assertEqual("GatewayTimeout", private["sdkErrorCode"])
        self.assertNotIn("raw-private-exception-text", stdout.getvalue() + stderr.getvalue())
        self.assertNotIn("Bearer private-value", stdout.getvalue() + stderr.getvalue())
        project.close.assert_called_once()
        credential.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
