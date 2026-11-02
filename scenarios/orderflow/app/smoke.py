"""In-network smoke test for the GitOps Container Apps job. Prints one JSON line."""

import json
import os
import sys
import time
from uuid import uuid4

import httpx
from common import Catalog, Health, Receipt

SMOKE_API = "http://orderflow-api"
TIMEOUT = 5
MAX_BYTES = 32768


class SmokeFailure(Exception):
    pass


def request(method, url, schema, body=None, transport=None):
    # Fresh client and connection per call; POST is never retried by the caller.
    with (
        httpx.Client(
            transport=transport or httpx.HTTPTransport(retries=0),
            timeout=httpx.Timeout(TIMEOUT, connect=2),
            follow_redirects=False,
            trust_env=False,
            headers={"Connection": "close", "X-OrderFlow-Request": "1"},
        ) as client,
        client.stream(method, url, json=body) as response,
    ):
        if response.status_code != 200:
            raise SmokeFailure(f"HTTP {response.status_code}")
        content = bytearray()
        for chunk in response.iter_bytes():
            content.extend(chunk)
            if len(content) > MAX_BYTES:
                raise SmokeFailure("response too large")
        return schema.model_validate_json(bytes(content))


def run(transport=None, base_url=None):
    base_url = os.getenv("SMOKE_API_URL", SMOKE_API) if base_url is None else base_url
    summary = {
        "smoke": "orderflow",
        "stage": os.getenv("ORDERFLOW_STAGE", ""),
        "deploySha": os.getenv("DEPLOY_SHA", ""),
        "result": "fail",
        "checks": {},
    }
    started = time.monotonic()
    check = "config"
    try:
        if base_url != SMOKE_API:
            raise SmokeFailure(f"SMOKE_API_URL must be exactly {SMOKE_API}")
        check = "health"
        request("GET", base_url + "/api/health", Health, transport=transport)
        summary["checks"][check] = "pass"
        check = "products"
        catalog = request("GET", base_url + "/api/products", Catalog, transport=transport)
        summary["checks"][check] = "pass"
        check = "order"
        request_id = str(uuid4())
        summary["requestId"] = request_id
        body = {"product_id": catalog.products[0].id, "quantity": 1, "request_id": request_id}
        receipt_url = f"{base_url}/api/orders/{request_id}"
        try:
            created = request("POST", base_url + "/api/orders", Receipt, body, transport)
        except Exception as error:
            # Unknown outcome: observe the receipt once for evidence, never replay the POST.
            try:
                request("GET", receipt_url, Receipt, transport=transport)
                summary["receiptAfterUnknown"] = "found"
            except Exception:
                summary["receiptAfterUnknown"] = "unconfirmed"
            raise SmokeFailure(f"order outcome unknown: {describe(error)}") from None
        summary["checks"][check] = "pass"
        check = "receipt"
        receipt = request("GET", receipt_url, Receipt, transport=transport)
        if receipt != created or str(receipt.request_id) != request_id:
            raise SmokeFailure("receipt mismatch")
        summary["checks"][check] = "pass"
        summary["result"] = "pass"
    except Exception as error:
        summary["checks"][check] = "fail"
        summary["failedCheck"] = check
        summary["error"] = describe(error)
    summary["durationMs"] = round((time.monotonic() - started) * 1000)
    return summary


def describe(error):
    if isinstance(error, SmokeFailure):
        return str(error)[:200]
    return type(error).__name__


def main(transport=None):
    summary = run(transport)
    print(json.dumps(summary, sort_keys=True), flush=True)
    return 0 if summary["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
