import os
import unittest
from unittest.mock import patch

import telemetry


class TelemetryTests(unittest.TestCase):
    def test_configuration_is_process_idempotent(self):
        with (
            patch.object(telemetry, "_CONFIGURED", False),
            patch.dict(os.environ, {"APPLICATIONINSIGHTS_CONNECTION_STRING": "synthetic"}),
            patch("azure.monitor.opentelemetry.configure_azure_monitor") as configure_monitor,
        ):
            telemetry.configure()
            telemetry.configure()
            self.assertTrue(telemetry._CONFIGURED)
            configure_monitor.assert_called_once()
            self.assertEqual("retailtx.incident", configure_monitor.call_args.kwargs["logger_name"])

    def test_configuration_is_not_latched_until_exporter_setup_succeeds(self):
        with (
            patch.object(telemetry, "_CONFIGURED", False),
            patch.dict(os.environ, {}, clear=True),
            patch("azure.monitor.opentelemetry.configure_azure_monitor") as configure_monitor,
        ):
            telemetry.configure()
            self.assertFalse(telemetry._CONFIGURED)
            configure_monitor.assert_not_called()
            with patch.dict(os.environ, {"APPLICATIONINSIGHTS_CONNECTION_STRING": "synthetic"}):
                configure_monitor.side_effect = [RuntimeError("synthetic setup failure"), None]
                with self.assertRaises(RuntimeError):
                    telemetry.configure()
                self.assertFalse(telemetry._CONFIGURED)
                telemetry.configure()
                telemetry.configure()
                self.assertTrue(telemetry._CONFIGURED)
                self.assertEqual(2, configure_monitor.call_count)


if __name__ == "__main__":
    unittest.main()
