"""Offline contract, fault and recovery tests. No Azure service is contacted."""

import asyncio
import importlib
import json
import logging
import socket
import sys
import threading
import time
import types
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
from fastapi.testclient import TestClient

APP = Path(__file__).parents[1] / "app"
sys.path.insert(0, str(APP))
backend = importlib.import_module("backend")
portal = importlib.import_module("portal")
common = importlib.import_module("common")
HEADERS = {"X-OrderFlow-Request": "1"}
HEALTH = {"status": "healthy", "dependency": "cosmos"}


class ExistsError(Exception):
    pass


class NotFoundError(Exception):
    pass


class Container:
    def __init__(self):
        self.items = {}
        self.fail = False
        self.timeout_after_write = False
        self.reads = 0
        self.writes = 0

    def read(self):
        self.reads += 1
        if self.fail:
            raise TimeoutError("sensitive provider diagnostic")
        return {"id": "orders"}

    def read_item(self, item, partition_key):
        self.read()
        if item not in self.items:
            raise NotFoundError()
        document = self.items[item]
        assert partition_key == document.get("category", document["id"])
        return dict(document)

    def create_item(self, document):
        if self.fail:
            raise TimeoutError("sensitive provider diagnostic")
        self.writes += 1
        if document["id"] in self.items:
            raise ExistsError()
        self.items[document["id"]] = dict(document)
        if self.timeout_after_write:
            raise TimeoutError("write result lost")
        return document


@pytest.fixture
def store(monkeypatch):
    errors = types.ModuleType("azure.cosmos.exceptions")
    errors.CosmosResourceExistsError = ExistsError
    errors.CosmosResourceNotFoundError = NotFoundError
    monkeypatch.setitem(sys.modules, "azure.cosmos.exceptions", errors)
    repository = backend.CosmosStore.__new__(backend.CosmosStore)
    repository.products = Container()
    repository.orders = Container()
    repository.close = lambda: None
    repository.seed()
    return repository


@pytest.fixture(autouse=True)
def offline_env(monkeypatch):
    monkeypatch.delenv("APPLICATIONINSIGHTS_CONNECTION_STRING", raising=False)
    monkeypatch.delenv("ORDER_API_URL", raising=False)


def order_body(**changes):
    return {"product_id": "field-kit", "quantity": 2, "request_id": str(uuid4()), **changes}


def response_receipt(body):
    return {
        "id": body["request_id"],
        "request_id": body["request_id"],
        "product_id": body["product_id"],
        "quantity": body["quantity"],
        "total_cents": 12900 * body["quantity"],
        "created_at": datetime.now(UTC).isoformat(),
        "status": "confirmed",
        "synthetic": True,
    }


def make_portal(handler, **kwargs):
    return portal.create_app(
        transport_factory=lambda: httpx.MockTransport(handler),
        probe_interval=0,
        **kwargs,
    )


def test_backend_catalog_health_and_idempotent_receipt(store):
    with TestClient(backend.create_app(store)) as client:
        assert client.get("/api/health").json() == HEALTH
        assert store.products.reads == 1
        assert store.orders.reads == 1
        catalog = client.get("/api/products")
        assert catalog.json()["products"] == backend.CATALOG
        body = order_body()
        first = client.post("/api/orders", json=body, headers=HEADERS)
        assert first.status_code == 200
        assert first.json()["total_cents"] == 25800
        assert first.json()["request_id"] == body["request_id"]
        second = client.post("/api/orders", json=body, headers=HEADERS)
        assert second.json() == first.json()
        assert len(store.orders.items) == 1
        assert client.get(f"/api/orders/{body['request_id']}").json() == first.json()
        conflict = client.post("/api/orders", json={**body, "quantity": 3}, headers=HEADERS)
        assert conflict.status_code == 409


def test_seed_never_overwrites_or_ignores_nonconflict_failure(store):
    original = dict(store.products.items)
    store.seed()
    assert store.products.items == original
    store.products.fail = True
    with pytest.raises(TimeoutError):
        store.seed()


def test_managed_identity_sdk_configuration_and_no_resource_provisioning(monkeypatch):
    seen = {}

    class Credential:
        def __init__(self, **options):
            seen["identity"] = options

    class Client:
        def __init__(self, endpoint, **options):
            seen["endpoint"] = endpoint
            seen["options"] = options

        def get_database_client(self, database):
            seen["database"] = database
            return self

        def get_container_client(self, container):
            seen.setdefault("containers", []).append(container)
            return Container()

    cosmos = types.ModuleType("azure.cosmos")
    cosmos.CosmosClient = Client
    identity = types.ModuleType("azure.identity")
    identity.ManagedIdentityCredential = Credential
    monkeypatch.setitem(sys.modules, "azure.cosmos", cosmos)
    monkeypatch.setitem(sys.modules, "azure.identity", identity)
    monkeypatch.setenv("AZURE_CLIENT_ID", "synthetic-client-id")
    monkeypatch.setenv("COSMOS_ENDPOINT", "https://synthetic.documents.azure.com:443/")
    monkeypatch.setenv("COSMOS_DATABASE", "orderflow")
    backend.CosmosStore()
    assert seen["identity"]["client_id"] == "synthetic-client-id"
    assert seen["identity"]["retry_total"] == 0
    assert seen["database"] == "orderflow"
    assert seen["containers"] == ["products", "orders"]
    for option in ("retry_total", "retry_connect", "retry_read", "retry_status", "retry_write"):
        assert seen["options"][option] == 0
    assert seen["options"]["timeout"] == 3
    assert seen["options"]["connection_timeout"] == 1
    assert seen["options"]["read_timeout"] == 2
    assert isinstance(seen["options"]["credential"], Credential)


def test_end_to_end_timeout_receipt_and_recovery_with_injected_cosmos(store):
    private_app = backend.create_app(store)
    public_app = portal.create_app(
        transport_factory=lambda: httpx.ASGITransport(app=private_app),
        probe_interval=0,
    )
    with TestClient(public_app) as client:
        assert client.get("/api/health").json() == HEALTH
        assert client.get("/api/products").json()["products"] == backend.CATALOG
        store.orders.timeout_after_write = True
        body = order_body()
        assert client.post("/api/orders", json=body, headers=HEADERS).status_code == 503
        store.orders.fail = True
        assert client.get("/api/health").status_code == 503
        assert client.get(f"/api/orders/{body['request_id']}").status_code == 503
        assert client.get("/healthz").status_code == 200
        store.orders.fail = False
        assert client.get("/api/health").status_code == 200
        receipt = client.get(f"/api/orders/{body['request_id']}")
        assert receipt.status_code == 200
        assert receipt.json()["request_id"] == body["request_id"]
        assert store.orders.writes == 1


def test_outage_no_fake_health_catalog_or_recovery(store):
    with TestClient(backend.create_app(store)) as client:
        assert client.get("/api/health").status_code == 200
        writes_before = store.products.writes
        store.products.fail = True
        for path in ("/api/health", "/api/products"):
            result = client.get(path)
            assert result.status_code == 503
            assert "sensitive" not in result.text
        assert store.products.writes == writes_before
        store.products.fail = False
        assert client.get("/api/health").status_code == 200
        store.orders.fail = True
        assert client.get("/api/health").status_code == 503


def test_committed_but_timed_out_order_is_read_without_replay(store):
    store.orders.timeout_after_write = True
    with TestClient(backend.create_app(store)) as client:
        body = order_body()
        result = client.post("/api/orders", json=body, headers=HEADERS)
        assert result.status_code == 503
        assert "unknown" in result.json()["detail"]
        assert store.orders.writes == 1
        receipt = client.get(f"/api/orders/{body['request_id']}")
        assert receipt.status_code == 200
        assert receipt.json()["request_id"] == body["request_id"]
        assert store.orders.writes == 1
        missing = client.get(f"/api/orders/{uuid4()}")
        assert missing.status_code == 404
        assert "unconfirmed" in missing.text


@pytest.mark.parametrize(
    "changes",
    [
        {"quantity": 0}, {"quantity": 6}, {"quantity": True}, {"quantity": "2"},
        {"quantity": 1.5}, {"product_id": "other"}, {"request_id": "../health"},
        {"unexpected": "field"}, {"product_id": "<script>alert(1)</script>"},
    ],
)
def test_both_services_validate_before_dependency_io(store, changes):
    def forbidden(_request):
        pytest.fail("Invalid input reached the dependency")

    for app in (backend.create_app(store), make_portal(forbidden)):
        with TestClient(app) as client:
            result = client.post("/api/orders", json=order_body(**changes), headers=HEADERS)
            assert result.status_code == 422
            assert result.json() == {"detail": "Invalid request."}
            assert client.get("/api/orders/not-a-uuid").status_code == 422
    assert not store.orders.items


def test_portal_health_is_dependency_health_not_process_health(caplog):
    healthy = False

    def handler(request):
        assert request.headers["connection"] == "close"
        return httpx.Response(200, json=HEALTH) if healthy else httpx.Response(503)

    with TestClient(make_portal(handler)) as client, caplog.at_level(logging.INFO, "orderflow"):
        assert client.get("/healthz").json()["scope"] == "portal-process-only"
        assert client.get("/api/health").status_code == 503
        healthy = True
        assert client.get("/api/health").json() == HEALTH
        healthy = False
        assert client.get("/api/health").status_code == 503
    logs = [record for record in caplog.records if record.msg == "orderflow_dependency"]
    assert [record.success for record in logs] == ["false", "true", "false"]
    assert all(record.duration_ms >= 0 and record.operation == "api.health" for record in logs)


@pytest.mark.parametrize("failure", ["timeout", "disconnect", "redirect", "bad-json", "oversize"])
def test_portal_failures_are_503_and_post_is_never_retried(failure):
    calls = []

    def handler(request):
        calls.append(request)
        if failure == "timeout":
            raise httpx.ReadTimeout("sensitive", request=request)
        if failure == "disconnect":
            raise httpx.RemoteProtocolError("disconnected")
        if failure == "redirect":
            return httpx.Response(307, headers={"Location": "https://example.invalid"})
        if failure == "oversize":
            return httpx.Response(200, content=b"x" * 32769)
        return httpx.Response(200, content=b"not-json")

    with TestClient(make_portal(handler)) as client:
        body = order_body()
        result = client.post("/api/orders", json=body, headers=HEADERS)
        assert result.status_code == 503
        assert "unknown" in result.text
        assert "sensitive" not in result.text
        assert len(calls) == 1


def test_portal_wall_clock_timeout_and_reconcile():
    body = order_body()
    calls = []

    async def handler(request):
        calls.append(request.method)
        if request.method == "POST":
            await asyncio.sleep(.2)
        return httpx.Response(200, json=response_receipt(body))

    with TestClient(make_portal(handler, timeout=.03)) as client:
        started = time.monotonic()
        result = client.post("/api/orders", json=body, headers=HEADERS)
        assert result.status_code == 503
        assert time.monotonic() - started < 1
        result = client.get(f"/api/orders/{body['request_id']}")
        assert result.status_code == 200
        assert calls == ["POST", "GET"]


def test_portal_rejects_mismatched_receipt_and_missing_is_unconfirmed():
    body = order_body()
    with TestClient(make_portal(
        lambda _: httpx.Response(200, json=response_receipt(body))
    )) as client:
        assert client.get(f"/api/orders/{uuid4()}").status_code == 503
    with TestClient(make_portal(lambda _: httpx.Response(404))) as client:
        result = client.get(f"/api/orders/{uuid4()}")
        assert result.status_code == 404
        assert "unconfirmed" in result.text


def test_same_origin_size_rate_and_security_headers(store):
    for app in (backend.create_app(store), make_portal(lambda _: httpx.Response(503))):
        with TestClient(app) as client:
            assert client.post("/api/orders", json=order_body()).status_code == 403
            assert client.post("/api/orders", json=order_body(), headers={
                **HEADERS, "Origin": "https://attacker.invalid",
            }).status_code == 403
            assert client.post("/api/orders", json=order_body(), headers={
                **HEADERS, "Sec-Fetch-Site": "cross-site",
            }).status_code == 403
            assert client.post("/api/orders", content="x" * 1025, headers={
                **HEADERS, "Content-Type": "application/json",
            }).status_code == 413
            assert client.post("/api/orders", content="x", headers=HEADERS).status_code == 415
            for _ in range(20):
                result = client.post("/api/orders", json=order_body(quantity=0), headers=HEADERS)
            assert result.status_code == 429
            assert result.headers["cache-control"] == "no-store"
            assert result.headers["x-content-type-options"] == "nosniff"
            assert "frame-ancestors 'none'" in result.headers["content-security-policy"]


@pytest.mark.parametrize("url", [
    "https://10.42.2.4:8080", "http://10.42.2.4:8080/", "http://127.0.0.1:8080",
    "http://10.42.2.4:8080@attacker.invalid", "http://10.42.2.4:8080/?url=x",
])
def test_portal_has_no_configurable_ssrf_target(monkeypatch, url):
    monkeypatch.setenv("ORDER_API_URL", url)
    with pytest.raises(ValueError):
        portal.create_app()


def test_static_assets_and_no_public_admin():
    with TestClient(make_portal(lambda _: httpx.Response(503))) as client:
        for path in ("/", "/static/app.js", "/static/styles.css"):
            result = client.get(path)
            assert result.status_code == 200
            assert "unsafe-inline" not in result.headers["content-security-policy"]
        for path in ("/api/admin", "/api/fix", "/api/fault", "/api/proxy", "/docs"):
            assert client.get(path).status_code == 404
    script = (APP / "static" / "app.js").read_text()
    assert "innerHTML" not in script
    assert "setTimeout(pollHealth, 5000)" in script
    assert "sessionStorage.setItem" in script


def test_independent_probe_and_clean_shutdown(caplog):
    count = 0

    def handler(_request):
        nonlocal count
        count += 1
        return httpx.Response(503)

    app = portal.create_app(
        transport_factory=lambda: httpx.MockTransport(handler), probe_interval=.01
    )
    with caplog.at_level(logging.INFO, "orderflow"):
        with TestClient(app):
            deadline = time.monotonic() + 1
            while count < 2 and time.monotonic() < deadline:
                time.sleep(.01)
            assert count >= 2
        assert app.state.probe_task.done()
    assert any(record.operation == "api.probe" and record.success == "false"
               for record in caplog.records if record.msg == "orderflow_dependency")


def test_actual_socket_disconnect_and_fresh_connections():
    peers = []
    disconnect = False

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            peers.append(self.client_address)
            if disconnect:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            body = json.dumps(HEALTH).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    class LocalTransport(httpx.AsyncHTTPTransport):
        async def handle_async_request(self, request):
            request.url = request.url.copy_with(host="127.0.0.1", port=server.server_port)
            return await super().handle_async_request(request)

    try:
        with TestClient(portal.create_app(
            transport_factory=lambda: LocalTransport(retries=0), probe_interval=0,
        )) as client:
            assert client.get("/api/health").status_code == 200
            assert client.get("/api/health").status_code == 200
            assert peers[0][1] != peers[1][1]
            disconnect = True
            assert client.get("/api/health").status_code == 503
            assert len(peers) == 3
            disconnect = False
            assert client.get("/api/health").status_code == 200
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
