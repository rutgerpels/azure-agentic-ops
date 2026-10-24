"""Safe event-only instrumentation; no prompts, principals, bodies or raw SDK errors."""

import logging
import os
import threading

LOGGER = logging.getLogger("retailtx.incident")
LOGGER.setLevel(logging.INFO)
_CONFIGURED = False
_CONFIGURE_LOCK = threading.Lock()


def configure():
    global _CONFIGURED
    if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
        with _CONFIGURE_LOCK:
            if not _CONFIGURED:
                from azure.monitor.opentelemetry import configure_azure_monitor

                configure_azure_monitor(
                    logger_name="retailtx.incident",
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
