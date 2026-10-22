import json
import unittest

from helpers import FakeResponses, call, response, settings
from probe import run, steps


class ProbeTests(unittest.TestCase):
    def failure(self, param="input[0].role"):
        error = RuntimeError("private-exception-text")
        error.status_code = 400
        error.body = {
            "error": {
                "code": "invalid_value",
                "param": param,
                "message": "private-response-message",
            }
        }
        return error

    def test_each_step_adds_a_single_feature_and_reports_without_content(self):
        cfg = settings()
        ladder = steps(cfg)
        ok = response(text="ok")
        agent_replies = [ok] * 3 + [self.failure()] + [ok] * 4 + [self.failure(), ok]
        agent_replies += [response(output=[call("get_store_context", horizon=60)]), ok]
        agent = FakeResponses(agent_replies)
        project = FakeResponses([response(text="private-model-answer")] * 2)
        result = run(
            cfg,
            {"agent_endpoint": agent, "project_endpoint": project},
            clock=iter(range(100)).__next__,
        )
        self.assertTrue(result["pass"])
        self.assertTrue(result["anyAccepted"])
        self.assertTrue(result["currentRuntimeRequestAccepted"])
        self.assertTrue(result["statelessToolLoopAccepted"])
        self.assertEqual(len(ladder) + 1, len(result["steps"]))
        developer = result["steps"][3]
        self.assertEqual("developer_message", developer["step"])
        self.assertFalse(developer["accepted"])
        self.assertEqual(400, developer["httpStatus"])
        self.assertEqual("input[0].role", developer["parameter"])
        self.assertIn("invalid_value", developer["sdkErrorCodes"])
        self.assertFalse(result["steps"][8]["accepted"])
        self.assertTrue(result["steps"][0]["answeredOk"])
        self.assertFalse(result["steps"][-2]["answeredOk"])
        self.assertTrue(result["steps"][-1]["answeredOk"])
        replay = agent.requests[-1]["input"]
        self.assertEqual("function_call", replay[1]["type"])
        self.assertEqual("function_call_output", replay[2]["type"])
        self.assertFalse(any(i.get("role") == "developer" for i in agent.requests[9]["input"]))
        self.assertEqual(
            {"agent": {"type": "agent_reference", "name": cfg.agent_name, "version": "1"}},
            project.requests[-1]["extra_body"],
        )
        self.assertTrue(all(request["timeout"] for request in agent.requests))
        output = json.dumps(result)
        self.assertNotIn("private-", output)
        self.assertNotIn("Reply with exactly", output)

    def test_unsafe_parameter_paths_are_redacted(self):
        from diagnostics import exception_metadata

        for param, expected in (
            ("input[3].content", "input[3].content"),
            ("input", "input"),
            ("input[0].private-field", None),
            ("input[0].role; private", None),
            ("input[99999].role", None),
        ):
            with self.subTest(param=param):
                self.assertEqual(expected, exception_metadata(self.failure(param))["parameter"])


if __name__ == "__main__":
    unittest.main()
