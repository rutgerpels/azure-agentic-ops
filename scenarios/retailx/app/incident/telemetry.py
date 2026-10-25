"""Safe event-only instrumentation; no prompts, principals, bodies or raw SDK errors."""

import logging
import os
import threading

LOGGER = logging.getLogger("retailtx.incident")
LOGGER.setLevel(logging.INFO)
_CONFIGURED = False
_CONFIGURE_LOCK = threading.Lock()


def configure(*, events_only=False):
    global _CONFIGURED
    if events_only:
        os.environ["OTEL_TRACES_EXPORTER"] = "none"
        os.environ["OTEL_METRICS_EXPORTER"] = "none"
    if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
        with _CONFIGURE_LOCK:
            if not _CONFIGURED:
                from azure.monitor.opentelemetry import configure_azure_monitor

                configure_azure_monitor(
                    logger_name="retailtx.incident",
                    **(
                        {"enable_live_metrics": False, "enable_performance_counters": False}
                        if events_only
                        else {}
                    ),
                    instrumentation_options={
                        name: {"enabled": False}
                        for name in (
                            "azure_sdk",
                            "requests",
                            "urllib",
                            "urllib3",
                            "fastapi",
                            "psycopg2",
                        )
                    },
                )
                _CONFIGURED = True
    for name in ("azure", "openai", "httpx", "httpx2", "httpcore"):
        logging.getLogger(name).setLevel(logging.CRITICAL)


def event(name, **safe_fields):
    LOGGER.info(name, extra={"event": name, **safe_fields})
