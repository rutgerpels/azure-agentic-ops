"""Contract tests for the hybrid checkout latency scenario (no Azure required)."""

import importlib.util
import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

ROOT = Path(__file__).resolve().parents[2]


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


backend = load("checkout_price_backend", "app/checkout/onprem/price_backend.py")
chaos = load("checkout_latency_chaos", "chaos/checkout_latency.py")


@pytest.fixture
def price_server(monkeypatch):
    monkeypatch.setitem(backend.PROFILES, "legacy",
                        {"service": "legacy-price-gateway", "delay": (0, 0)})
    servers = {}
    for role in ("primary", "legacy"):
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.make_handler(role))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers[role] = f"http://127.0.0.1:{server.server_address[1]}"
    yield servers
    # Daemon threads end with the test process.


def get(url: str) -> tuple[int, dict]:
    try:
        with urllib.request.urlopen(url, timeout=5) as response:  # noqa: S310 - local test server
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def test_backend_roles_and_validation(price_server):
    status, body = get(f"{price_server['primary']}/price/MILK-1L?country=BE")
    assert status == 200 and body["service"] == "erp-price-service"
    status, body = get(f"{price_server['legacy']}/price/MILK-1L?country=NL")
    assert status == 200 and body["service"] == "legacy-price-gateway"
    assert get(f"{price_server['primary']}/price/MILK-1L?country=DE")[0] == 400
    assert get(f"{price_server['primary']}/price/bad_sku?country=BE")[0] == 404


def test_frontend_routes_per_country_and_tags_request_span(price_server, monkeypatch):
    monkeypatch.delenv("APPLICATIONINSIGHTS_CONNECTION_STRING", raising=False)
    monkeypatch.setenv("PRICE_PRIMARY_URL", price_server["primary"])
    monkeypatch.setenv("PRICE_LEGACY_URL", price_server["legacy"])
    monkeypatch.setenv("PRICE_ROUTE_BE", "legacy")
    monkeypatch.setenv("PRICE_ROUTE_NL", "primary")
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    sys.modules.pop("checkout_frontend", None)
    frontend = load("checkout_frontend", "app/checkout/frontend/app.py")
    monkeypatch.setattr(frontend, "tracer", provider.get_tracer("test"))
    client = TestClient(frontend.app)

    be = client.post("/checkout", json={"country": "BE", "store": "BE-101", "sku": "MILK-1L",
                                        "quantity": 2})
    nl = client.post("/checkout", json={"country": "NL", "store": "NL-201", "sku": "MILK-1L",
                                        "quantity": 1})
    assert be.status_code == 200 and be.json()["priceRoute"] == "legacy"
    assert nl.status_code == 200 and nl.json()["priceRoute"] == "primary"
    assert be.json()["total"] == 4.98
    assert client.post("/checkout", json={"country": "DE", "store": "DE-101", "sku": "MILK-1L",
                                          "quantity": 1}).status_code == 422
    peers = [span.attributes["peer.service"] for span in exporter.get_finished_spans()]
    assert peers == ["legacy-price-gateway", "erp-price-service"]
    assert client.get("/health").json()["routes"] == {"BE": "legacy", "NL": "primary"}


def test_unknown_route_falls_back_to_primary(monkeypatch):
    monkeypatch.setenv("PRICE_ROUTE_BE", "unexpected")
    sys.modules.pop("checkout_frontend", None)
    frontend = load("checkout_frontend", "app/checkout/frontend/app.py")
    assert frontend.route_table()["BE"] == "primary"


def test_web_till_page_channel_and_recent_feed(price_server, monkeypatch, tmp_path):
    monkeypatch.delenv("APPLICATIONINSIGHTS_CONNECTION_STRING", raising=False)
    monkeypatch.setenv("PRICE_PRIMARY_URL", price_server["primary"])
    monkeypatch.setenv("PRICE_LEGACY_URL", price_server["legacy"])
    monkeypatch.setenv("PRICE_ROUTE_BE", "legacy")
    monkeypatch.setenv("PRICE_ROUTE_NL", "primary")
    sys.modules.pop("checkout_frontend", None)
    frontend = load("checkout_frontend", "app/checkout/frontend/app.py")
    monkeypatch.setattr(frontend, "RECENT_DIR", tmp_path / "recent")
    client = TestClient(frontend.app)
    assert client.get("/api/config").json()["connectionString"] is None
    monkeypatch.setenv("APPLICATIONINSIGHTS_CONNECTION_STRING", "InstrumentationKey=test")

    pages = (("/", "text/html"), ("/till.js", "text/javascript"), ("/till.css", "text/css"))
    for path, media in pages:
        response = client.get(path)
        assert response.status_code == 200 and response.headers["content-type"].startswith(media)
        assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
        assert response.headers["x-content-type-options"] == "nosniff"
    assert client.get("/api/config").json()["connectionString"].startswith("InstrumentationKey=")

    def post(**fields) -> int:
        body = {"store": "BE-101", "sku": "MILK-1L", "quantity": 1, **fields}
        return client.post("/checkout", json=body).status_code

    assert post(country="BE", channel="web") == 200
    assert post(country="BE", channel="kiosk") == 422
    assert post(country="NL", store="NL-401") == 200
    feed = client.get("/api/recent").json()
    assert [(e["route"], e["channel"], e["ok"]) for e in feed["BE"]] == [("legacy", "web", True)]
    assert [(e["route"], e["channel"]) for e in feed["NL"]] == [("primary", "pos")]


@pytest.mark.parametrize("environment", ["Checkout01", "c1", "checkout01-x", "a" * 13])
def test_chaos_rejects_invalid_environment_before_azure(environment, monkeypatch):
    called = []
    monkeypatch.setattr(chaos, "az", lambda *args: called.append(args))
    monkeypatch.setattr(sys, "argv", ["checkout_latency.py", "--inject", "--subscription", "s",
                                      "--environment", environment])
    with pytest.raises(SystemExit):
        chaos.main()
    assert called == []


def test_chaos_inject_and_undo_settings(monkeypatch):
    calls = []

    def fake_az(*args):
        calls.append(args)
        return json.dumps(["app-test"]) if args[1] == "list" else ""

    monkeypatch.setattr(chaos, "az", fake_az)
    for flag, expected in (("--inject", ["PRICE_ROUTE_BE=legacy", "ROUTE_CHANGE_REF=CHG-1042"]),
                           ("--undo", ["PRICE_ROUTE_BE=primary", "ROUTE_CHANGE_REF=baseline"])):
        calls.clear()
        monkeypatch.setattr(sys, "argv", ["checkout_latency.py", flag, "--subscription", "s",
                                          "--environment", "checkout01"])
        chaos.main()
        settings = calls[-1][calls[-1].index("--settings") + 1:calls[-1].index("-o")]
        assert list(settings) == expected
        assert "rg-retailtx-checkout-checkout01-swedencentral" in calls[-1]
