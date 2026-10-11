#!/usr/bin/env python3
"""Operator-only Log Analytics read using the VM's system identity."""
import base64
import ipaddress
import json
import socket
import sys
import uuid
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def query(config):
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

    addresses = resolve("api.loganalytics.io")
    ingestion_addresses = resolve(f"{workspace}.ods.opinsights.azure.com")
    token_uri = "http://169.254.169.254/metadata/identity/oauth2/token?" + urlencode({
        "api-version": "2018-02-01", "resource": "https://api.loganalytics.io"})
    with urlopen(Request(token_uri, headers={"Metadata": "true"}), timeout=15) as response:
        token = json.load(response)["access_token"]
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
    with urlopen(request, timeout=60) as response:
        result = json.load(response)
    if "error" in result or len(result.get("tables", [])) != 1:
        raise ValueError("Incomplete or failed telemetry query")
    table = result["tables"][0]
    if len(table["rows"]) != 1 or [column["name"] for column in table["columns"]] != ["receipt"]:
        raise ValueError("No unambiguous service observation")
    return {"workspaceCustomerId": workspace, "vmId": resource, "queryAddresses": addresses,
            "ingestionAddresses": ingestion_addresses, "transport": transport,
            "receipt": json.loads(table["rows"][0][0])}


if __name__ == "__main__":
    config = json.loads(base64.b64decode(sys.argv[1], validate=True))
    try:
        result = query(config)
    except HTTPError as error:
        print(json.dumps({"status": error.code, "error": error.read().decode("utf-8")},
                         separators=(",", ":")), file=sys.stderr)
        raise SystemExit(1) from error
    print("RETAILTX_TELEMETRY=" + json.dumps(result, separators=(",", ":")))
