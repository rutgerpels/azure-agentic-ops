#!/usr/bin/env python3
"""Operator-only Log Analytics read using the VM's system identity."""
import base64
import ipaddress
import json
import re
import socket
import sys
import time
import uuid
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


class TelemetryQueryError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def http_error_receipt(error):
    code = "TelemetryHttpError"
    try:
        body = json.loads(error.read(4096))
        candidate = body.get("error", {}).get("code") if isinstance(body, dict) else None
        if isinstance(candidate, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,99}", candidate):
            code = candidate
    except (ValueError, AttributeError):
        code = "TelemetryHttpError"
    return {"status": error.code, "error": code}


def query(config, progress=None):
    def stage(name, operation):
        started = time.monotonic()
        if progress:
            progress({"stage": name, "status": "started"})
        result = operation()
        if progress:
            progress({"stage": name, "status": "completed",
                      "elapsedMs": round((time.monotonic() - started) * 1000)})
        return result

    transport = config.get("transport", "Private")
    if transport not in ("Public", "Private"):
        raise ValueError("Invalid Monitor transport")
    workspace = str(uuid.UUID(config["workspaceCustomerId"]))
    owner = str(uuid.UUID(config["ownerToken"]))
    resource = config["vmId"]
    if not resource.startswith("/subscriptions/") or "'" in resource or "\n" in resource:
        raise ValueError("Invalid VM resource ID")
    def resolve(host):
        addresses = sorted({item[4][0] for item in socket.getaddrinfo(host, 443, socket.AF_INET)})
        if not addresses:
            raise ValueError("Monitor endpoint has no IPv4 addresses")
        for value in addresses:
            ip = ipaddress.ip_address(value)
            if (transport == "Public" and not ip.is_global) or (
                transport == "Private" and not ip.is_private
            ):
                raise ValueError("Monitor endpoint DNS differs from selected transport")
        return addresses

    addresses = stage("query-dns", lambda: resolve("api.loganalytics.io"))
    ingestion_addresses = stage("ingestion-dns", lambda: resolve(f"{workspace}.ods.opinsights.azure.com"))
    token_uri = "http://169.254.169.254/metadata/identity/oauth2/token?" + urlencode({
        "api-version": "2018-02-01", "resource": "https://api.loganalytics.io"})
    def read_token():
        with urlopen(Request(token_uri, headers={"Metadata": "true"}), timeout=15) as response:
            return json.load(response)["access_token"]

    token = stage("identity", read_token)
    kql = (
        f"Syslog | where _ResourceId =~ '{resource}' and ProcessName == 'RetailTxGuest' "
        f"| extend receipt = parse_json(SyslogMessage) "
        f"| where tostring(receipt.ownerToken) == '{owner}' "
        "| extend observedAt = todatetime(receipt.observedAtUtc) "
        "| summarize arg_max(observedAt, *) "
        "| project receipt=tostring(receipt)"
    )
    body = json.dumps({"query": kql, "timespan": "PT10M"}).encode()
    request = Request(f"https://api.loganalytics.io/v1/workspaces/{workspace}/query", data=body,
                      headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    def read_query():
        with urlopen(request, timeout=60) as response:
            return json.load(response)

    result = stage("law-query", read_query)
    if "error" in result or len(result.get("tables", [])) != 1:
        raise ValueError("Incomplete or failed telemetry query")
    table = result["tables"][0]
    if len(table["rows"]) != 1 or [column["name"] for column in table["columns"]] != ["receipt"]:
        raise TelemetryQueryError("ObservationMissingOrAmbiguous", "No unambiguous service observation")
    value = table["rows"][0][0]
    if not isinstance(value, str) or not value.strip():
        raise TelemetryQueryError("ObservationMissing", "No service observation returned; AMA ingestion may still be warming up")
    receipt = json.loads(value)
    if not isinstance(receipt, dict) or not receipt:
        raise TelemetryQueryError("ObservationInvalid", "Telemetry receipt must be a nonempty JSON object")
    return {"workspaceCustomerId": workspace, "vmId": resource, "queryAddresses": addresses,
            "ingestionAddresses": ingestion_addresses, "transport": transport,
            "receipt": receipt}


if __name__ == "__main__":
    def progress(value):
        print("RETAILTX_QUERY_STAGE=" + json.dumps(value, separators=(",", ":")), flush=True)

    try:
        config = json.loads(base64.b64decode(sys.argv[1], validate=True))
        result = query(config, progress)
    except HTTPError as error:
        print(json.dumps(http_error_receipt(error), separators=(",", ":")), file=sys.stderr)
        raise SystemExit(1) from error
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": getattr(error, "code", type(error).__name__)},
                         separators=(",", ":")), file=sys.stderr)
        raise SystemExit(1) from error
    print("RETAILTX_TELEMETRY=" + json.dumps(result, separators=(",", ":")))
