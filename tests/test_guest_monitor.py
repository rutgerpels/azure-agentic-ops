"""Explicit public/private query contracts; no IMDS, DNS or Azure traffic."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("guest_monitor_query", ROOT / "scripts" / "guest" / "query.py")
query = importlib.util.module_from_spec(spec)
spec.loader.exec_module(query)


class Response:
    def __init__(self, value):
        self.value = value

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return json.dumps(self.value).encode()


class PrivateQueryTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "workspaceCustomerId": "11111111-1111-1111-1111-111111111111",
            "ownerToken": "22222222-2222-2222-2222-222222222222",
            "vmId": "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/test",
        }
        self.receipt = {"ownerToken": self.config["ownerToken"], "active": True}
        self.result = {"tables": [{"columns": [{"name": "receipt"}],
                                  "rows": [[json.dumps(self.receipt)]]}]}

    def test_public_dns_rejected_before_credentials_or_query(self):
        with patch.object(query.socket, "getaddrinfo", return_value=[(None, None, None, None, ("20.1.2.3", 443))]), \
                patch.object(query, "urlopen") as request:
            with self.assertRaisesRegex(ValueError, "selected transport"):
                query.query(self.config)
        request.assert_not_called()

    def test_private_query_uses_identity_and_exact_owner_and_vm(self):
        with patch.object(query.socket, "getaddrinfo", return_value=[(None, None, None, None, ("10.89.0.8", 443))]), \
                patch.object(query, "urlopen", side_effect=[Response({"access_token": "unit-test-placeholder"}),
                                                          Response(self.result)]) as requests:
            evidence = query.query(self.config)
        self.assertEqual(evidence["receipt"], self.receipt)
        self.assertEqual(evidence["queryAddresses"], ["10.89.0.8"])
        self.assertEqual(evidence["transport"], "Private")
        self.assertEqual(evidence["ingestionAddresses"], ["10.89.0.8"])
        identity_request = requests.call_args_list[0].args[0]
        self.assertEqual(identity_request.get_header("Metadata"), "true")
        kql = json.loads(requests.call_args_list[1].args[0].data)["query"]
        self.assertIn(self.config["ownerToken"], kql)
        self.assertIn(self.config["vmId"], kql)
        self.assertIn("arg_max(observedAt", kql)

    def test_public_query_uses_entra_and_validates_both_dns_endpoints(self):
        self.config["transport"] = "Public"
        with patch.object(query.socket, "getaddrinfo", return_value=[(None, None, None, None, ("20.1.2.3", 443))]) as dns, \
                patch.object(query, "urlopen", side_effect=[Response({"access_token": "unit-test-placeholder"}),
                                                          Response(self.result)]) as requests:
            evidence = query.query(self.config)
        self.assertEqual(evidence["transport"], "Public")
        self.assertEqual(evidence["queryAddresses"], ["20.1.2.3"])
        self.assertEqual(evidence["ingestionAddresses"], ["20.1.2.3"])
        self.assertEqual([call.args[0] for call in dns.call_args_list],
                         ["api.loganalytics.io", self.config["workspaceCustomerId"] + ".ods.opinsights.azure.com"])
        self.assertIn("resource=https%3A%2F%2Fapi.loganalytics.io", requests.call_args_list[0].args[0].full_url)
        self.assertEqual(requests.call_args_list[1].args[0].get_header("Authorization"),
                         "Bearer unit-test-placeholder")

    def test_public_query_rejects_private_reserved_or_mixed_dns_before_identity(self):
        self.config["transport"] = "Public"
        for addresses in ([], ["10.1.2.3"], ["127.0.0.1"], ["0.0.0.0"], ["192.0.2.4"],
                          ["169.254.169.254"], ["20.1.2.3", "10.1.2.3"]):
            with self.subTest(addresses=addresses), \
                    patch.object(query.socket, "getaddrinfo", return_value=[
                        (None, None, None, None, (address, 443)) for address in addresses]), \
                    patch.object(query, "urlopen") as request:
                with self.assertRaises(ValueError):
                    query.query(self.config)
            request.assert_not_called()
        with patch.object(query.socket, "getaddrinfo", side_effect=[
                [(None, None, None, None, ("20.1.2.3", 443))],
                [(None, None, None, None, ("10.1.2.3", 443))]]), \
                patch.object(query, "urlopen") as request:
            with self.assertRaises(ValueError):
                query.query(self.config)
        request.assert_not_called()

    def test_invalid_transport_rejected_without_network_or_identity(self):
        for transport in ("public", "Automatic", "", None):
            self.config["transport"] = transport
            with self.subTest(transport=transport), patch.object(query.socket, "getaddrinfo") as dns, \
                    patch.object(query, "urlopen") as request:
                with self.assertRaisesRegex(ValueError, "Invalid Monitor transport"):
                    query.query(self.config)
            dns.assert_not_called()
            request.assert_not_called()

    def test_partial_error_no_data_and_ambiguous_rows_rejected(self):
        for result in ({"error": {"code": "PartialError"}, **self.result},
                       {"tables": []},
                       {"tables": [{"columns": [{"name": "receipt"}], "rows": []}]},
                       {"tables": [{"columns": [{"name": "receipt"}], "rows": [["{}"], ["{}"]]}]}):
            with self.subTest(result=result), \
                    patch.object(query.socket, "getaddrinfo", return_value=[(None, None, None, None, ("10.89.0.8", 443))]), \
                    patch.object(query, "urlopen", side_effect=[Response({"access_token": "unit-test-placeholder"}),
                                                              Response(result)]):
                with self.assertRaises(ValueError):
                    query.query(self.config)

    def test_invalid_owner_and_kql_literal_rejected(self):
        self.config["ownerToken"] = "foreign"
        with self.assertRaises(ValueError):
            query.query(self.config)
        self.config["ownerToken"] = "22222222-2222-2222-2222-222222222222"
        self.config["vmId"] = "/subscriptions/test' | union Syslog"
        with self.assertRaises(ValueError):
            query.query(self.config)


if __name__ == "__main__":
    unittest.main()
