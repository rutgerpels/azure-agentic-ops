"""Offline tests for the in-network smoke job. Fake transports only; no network."""

import importlib
import json
import sys
from pathlib import Path
from uuid import UUID

import httpx
import pytest

APP = Path(__file__).resolve().parents[2] / "app"
sys.path.insert(0, str(APP))
smoke = importlib.import_module("smoke")
backend = importlib.import_module("backend")


class FakeApi:
    def __init__(self):
        self.calls = []
        self.orders = {}
        self.fail = {}

    def __call__(self, request):
        self.calls.append(request)
        assert request.url.host == "orderflow-api"
        assert request.headers["connection"] == "close"
        key = (request.method, request.url.path.rsplit("/", 1)[0]
               if request.url.path.startswith("/api/orders/") else request.url.path)
        failure = self.fail.get(key)
        if isinstance(failure, Exception):
            raise failure
        if failure:
            return httpx.Response(failure)
        if key == ("GET", "/api/health"):
            return httpx.Response(200, json={"status": "healthy", "dependency": "cosmos"})
        if key == ("GET", "/api/products"):
            return httpx.Response(200, json={"products": backend.CATALOG})
        if key == ("POST", "/api/orders"):
            assert request.headers["x-orderflow-request"] == "1"
            assert request.headers["content-type"] == "application/json"
            body = json.loads(request.content)
            receipt = {
                "id": body["request_id"], "request_id": body["request_id"],
                "product_id": body["product_id"], "quantity": body["quantity"],
                "total_cents": 12900, "created_at": "2026-01-01T00:00:00+00:00",
                "status": "confirmed", "synthetic": True,
            }
            self.orders[body["request_id"]] = receipt
            return httpx.Response(200, json=receipt)
        request_id = request.url.path.rsplit("/", 1)[1]
        if request_id in self.orders:
            return httpx.Response(200, json=self.orders[request_id])
        return httpx.Response(404)

    def methods(self):
        return [(c.method, c.url.path) for c in self.calls]


@pytest.fixture(autouse=True)
def smoke_env(monkeypatch):
    monkeypatch.delenv("SMOKE_API_URL", raising=False)
    monkeypatch.setenv("ORDERFLOW_STAGE", "test")
    monkeypatch.setenv("DEPLOY_SHA", "synthetic-sha")


def run(api, capsys):
    code = smoke.main(httpx.MockTransport(api))
    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 1
    return code, json.loads(lines[0])


def test_smoke_passes_full_order_round_trip(capsys):
    api = FakeApi()
    code, summary = run(api, capsys)
    assert code == 0
    assert summary["result"] == "pass"
    assert summary["checks"] == {"health": "pass", "products": "pass", "order": "pass",
                                 "receipt": "pass"}
    assert summary["stage"] == "test" and summary["deploySha"] == "synthetic-sha"
    UUID(summary["requestId"])
    assert [m for m, _ in api.methods()] == ["GET", "GET", "POST", "GET"]
    assert api.methods()[-1][1] == f"/api/orders/{summary['requestId']}"


@pytest.mark.parametrize("url", ["http://10.42.2.4:8080", "http://orderflow-api/",
                                 "https://orderflow-api", "http://attacker.invalid"])
def test_smoke_target_is_fixed(monkeypatch, capsys, url):
    monkeypatch.setenv("SMOKE_API_URL", url)
    api = FakeApi()
    code, summary = run(api, capsys)
    assert code == 1
    assert summary["failedCheck"] == "config"
    assert api.calls == []


@pytest.mark.parametrize("status", [503, 307])
def test_dependency_failure_stops_before_ordering(capsys, status):
    api = FakeApi()
    api.fail[("GET", "/api/health")] = status
    code, summary = run(api, capsys)
    assert code == 1
    assert summary["failedCheck"] == "health"
    assert summary["error"] == f"HTTP {status}"
    assert len(api.calls) == 1


def test_connect_timeout_is_reported_without_details(capsys):
    api = FakeApi()
    api.fail[("GET", "/api/health")] = httpx.ConnectTimeout("sensitive detail")
    code, summary = run(api, capsys)
    assert code == 1
    assert summary["error"] == "ConnectTimeout"
    assert "sensitive" not in json.dumps(summary)


@pytest.mark.parametrize("found", [True, False])
def test_unknown_order_outcome_reads_receipt_once_and_never_replays(capsys, found):
    api = FakeApi()
    original = api.__call__

    def handler(request):
        if request.method == "POST":
            if found:
                original(request)  # committed, but the response is lost
            else:
                api.calls.append(request)
            raise httpx.ReadTimeout("lost", request=request)
        return original(request)

    code = smoke.main(httpx.MockTransport(handler))
    summary = json.loads(capsys.readouterr().out)
    assert code == 1
    assert summary["failedCheck"] == "order"
    assert summary["receiptAfterUnknown"] == ("found" if found else "unconfirmed")
    assert [m for m, _ in api.methods()] == ["GET", "GET", "POST", "GET"]


def test_receipt_mismatch_fails(capsys):
    api = FakeApi()
    original = api.__call__

    def handler(request):
        response = original(request)
        if request.method == "GET" and request.url.path.startswith("/api/orders/"):
            tampered = {**response.json(), "quantity": 2}
            return httpx.Response(200, json=tampered)
        return response

    code = smoke.main(httpx.MockTransport(handler))
    summary = json.loads(capsys.readouterr().out)
    assert code == 1
    assert summary["failedCheck"] == "receipt"


@pytest.mark.parametrize("payload", [b"not-json", b"x" * 40000,
                                     b'{"status": "degraded", "dependency": "cosmos"}'],
                         ids=["not-json", "oversized", "degraded"])
def test_invalid_or_oversized_responses_fail(capsys, payload):
    def handler(_request):
        return httpx.Response(200, content=payload)

    code = smoke.main(httpx.MockTransport(handler))
    summary = json.loads(capsys.readouterr().out)
    assert code == 1
    assert summary["failedCheck"] == "health"
