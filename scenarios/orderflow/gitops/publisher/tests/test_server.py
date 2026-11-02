import json
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from scenarios.orderflow.gitops.publisher import server
from scenarios.orderflow.gitops.publisher.config import MAX_REQUEST, PROTOCOLS, Settings
from scenarios.orderflow.gitops.publisher.server import create_app

from .conftest import GENERATION, HEADERS, INBOUND_KEY


@pytest.mark.parametrize("method", ["initialize", "tools/list", "tools/call"])
@pytest.mark.parametrize("key", [None, "", "wrong", "x" * 256, "é" * 32])
def test_authentication_required_for_every_method(rig, method, key):
    headers = {"accept": "application/json, text/event-stream"}
    if key is not None:
        # ASGI can represent non-ASCII headers even though httpx's dict API cannot.
        headers = [(k.encode(), v.encode()) for k, v in headers.items()]
        headers.append((b"x-orderflow-key", key.encode()))
    response = rig.rpc(method, headers=headers)
    assert response.status_code == 401
    assert rig.api.requests == []


def test_duplicate_auth_headers_refused(rig):
    response = rig.client.post("/mcp", headers=[
        ("x-orderflow-key", INBOUND_KEY), ("x-orderflow-key", INBOUND_KEY),
    ])
    assert response.status_code == 401


def test_public_health_has_no_config_or_secret(rig):
    response = rig.client.get("/healthz")
    assert response.json() == {"status": "ok"}
    assert not rig.api.requests


@pytest.mark.parametrize("version", PROTOCOLS)
def test_exact_initialize_negotiation(rig, version):
    response = rig.rpc("initialize", {
        "protocolVersion": version, "capabilities": {},
        "clientInfo": {"name": "offline-test", "version": "1"},
    })
    assert response.status_code == 200
    assert response.json() == {
        "jsonrpc": "2.0", "id": 1, "result": {
            "protocolVersion": version, "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "orderflow-issue-publisher", "version": "1.0.0"},
        },
    }
    assert "mcp-session-id" not in response.headers
    assert response.headers["cache-control"] == "no-store"


def test_unknown_initialize_version_negotiates_supported_version(rig):
    result = rig.rpc("initialize", {
        "protocolVersion": "future", "capabilities": {}, "clientInfo": {},
    }).json()["result"]
    assert result["protocolVersion"] == PROTOCOLS[-1]


def test_initialized_notification_has_empty_202(rig):
    response = rig.client.post("/mcp", headers=HEADERS, json={
        "jsonrpc": "2.0", "method": "notifications/initialized",
    })
    assert response.status_code == 202
    assert response.content == b""


@pytest.mark.parametrize("method", ["tools/list", "ping"])
def test_optional_protocol_metadata(rig, method):
    assert rig.rpc(method, {"_meta": {"trace": "opaque"}}).status_code == 200
    assert rig.rpc(method, {"_meta": "invalid"}).json()["error"]["code"] == -32602


def test_tools_list_has_only_two_strict_tools(rig):
    tools = rig.rpc("tools/list").json()["result"]["tools"]
    assert [tool["name"] for tool in tools] == ["find_incident_issue", "publish_incident_issue"]
    for tool in tools:
        assert tool["inputSchema"]["additionalProperties"] is False
        assert set(tool["inputSchema"]["properties"]) <= {"incident_key", "title", "body"}


def test_exact_tool_result(rig):
    response, outcome = rig.tool()
    expected = {
        "status": "published", "incident_key": GENERATION,
        "issue": {"number": 7, "url": "https://github.com/example/orderflow/issues/7"},
    }
    assert outcome == expected
    assert response.json() == {
        "jsonrpc": "2.0", "id": 1, "result": {
            "content": [{"type": "text", "text": json.dumps(expected, separators=(",", ":"))}],
            "isError": False,
        },
    }


@pytest.mark.parametrize("change", [
    {"incident_key": "11111111-2222-4333-8444-000000000000"},
    {"incident_key": GENERATION.upper()}, {"incident_key": "arbitrary"},
    {"incident_key": 42}, {"body": 3}, {"title": ["a"]},
    {"title": ""}, {"title": " "}, {"title": "x" * 201},
    {"body": "x" * 24_001}, {"body": "\x00"}, {"body": "\x7f"},
    {"title": "one\ntwo"},
    {"title": "one\ttwo"}, {"body": "<!-- orderflow-incident-key:forged -->"},
    {"labels": ["other"]}, {"assignees": ["copilot"]}, {"repo": "other/repo"},
    {"repository": "other/repo"}, {"url": "http://127.0.0.1"},
])
def test_strict_tool_input_and_generation_confinement(rig, change):
    response = rig.rpc("tools/call", {
        "name": "publish_incident_issue", "arguments": rig.inputs | change,
    })
    assert response.json()["error"]["code"] == -32602
    assert not rig.api.requests
    assert not rig.receipts.items


@pytest.mark.parametrize(
    "name", ["read_context", "create_issue", "http", "assign_copilot", None, []],
)
def test_unknown_tools_cannot_proxy_requests(rig, name):
    assert rig.rpc("tools/call", {"name": name}).json()["error"]["code"] == -32602
    assert not rig.api.requests


@pytest.mark.parametrize("method", ["resources/list", "prompts/list", "issues/read", "other"])
def test_unknown_methods(rig, method):
    assert rig.rpc(method).json()["error"]["code"] == -32601


@pytest.mark.parametrize("body,code", [
    (b"{", -32700), (b'{"jsonrpc":"2.0","id":NaN}', -32700),
    (b'{"jsonrpc":"2.0","id":1,"id":2}', -32700),
    (b"[]", -32600), (b"null", -32600),
    (b'{"jsonrpc":"1.0","method":"ping","id":1}', -32600),
    (b'{"jsonrpc":"2.0","method":"ping","id":true}', -32600),
    (b'{"jsonrpc":"2.0","method":"ping","id":null}', -32600),
    (b'{"jsonrpc":"2.0","method":"ping","id":1,"params":[]}', -32602),
    (b'{"jsonrpc":"2.0","method":"ping","id":1,"secret":"no"}', -32600),
])
def test_json_rpc_errors(rig, body, code):
    response = rig.client.post(
        "/mcp", headers=HEADERS | {"content-type": "application/json"}, content=body,
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == code
    assert not rig.api.requests


def test_deep_json_and_oversized_body_are_bounded(rig):
    for body, expected in [(b"[" * 1500 + b"]" * 1500, 400), (b"x" * (MAX_REQUEST + 1), 413)]:
        response = rig.client.post(
            "/mcp", headers=HEADERS | {"content-type": "application/json"}, content=body,
        )
        assert response.status_code == expected


def test_chunked_request_size_bound_without_content_length(rig):
    def chunks():
        yield b"x" * 40_000
        yield b"y" * 40_000

    response = rig.client.post(
        "/mcp", headers=HEADERS | {"content-type": "application/json"}, content=chunks(),
    )
    assert response.status_code == 413
    assert not rig.api.requests


def test_inbound_read_timeout(rig, monkeypatch):
    async def timeout(coroutine, timeout):
        assert timeout == 10
        coroutine.close()
        raise TimeoutError

    monkeypatch.setattr(server.asyncio, "wait_for", timeout)
    assert rig.rpc("tools/list").status_code == 408
    assert not rig.api.requests


@pytest.mark.parametrize("headers,status", [
    ({"accept": "application/json"}, 406),
    ({"mcp-protocol-version": "unknown"}, 400),
    ({"origin": "https://evil.example"}, 403),
    ({"origin": "null"}, 403),
    ({"host": "evil.example"}, 400),
    ({"content-type": "text/plain"}, 415),
])
def test_transport_restrictions(rig, headers, status):
    assert rig.rpc("tools/list", headers=HEADERS | headers).status_code == status
    assert not rig.api.requests


def test_absent_protocol_header_uses_2025_03_26(rig):
    headers = {k: v for k, v in HEADERS.items() if k != "mcp-protocol-version"}
    assert rig.rpc("tools/list", headers=headers).status_code == 200


def test_default_origin_policy_rejects_all_browser_origins(settings, rig):
    with TestClient(create_app(replace(settings, public_origin=""), rig.publisher)) as client:
        response = client.post("/mcp", headers=HEADERS | {"origin": "https://any.example"})
        assert response.status_code == 403


@pytest.mark.parametrize("method", ["GET", "DELETE"])
def test_no_sse_or_sessions_but_still_authenticated(rig, method):
    assert rig.client.request(method, "/mcp").status_code == 401
    response = rig.client.request(method, "/mcp", headers=HEADERS)
    assert response.status_code == 405
    assert response.headers["allow"] == "POST"


def test_no_openapi_or_redirect_endpoint(rig):
    for path in ["/docs", "/openapi.json", "/mcp/"]:
        response = rig.client.get(path, headers=HEADERS, follow_redirects=False)
        assert response.status_code == 404


@pytest.mark.parametrize("field,value", [
    ("inbound_key", "short"), ("inbound_key", "x" * 32 + "\n"),
    ("repository", "owner/repo/../../other"), ("repository", "owner/.."),
    ("repository_id", 0),
    ("installation_id", -1), ("app_id", "x\nbad"),
    ("storage_url", "http://localhost:10000"),
    ("storage_url", "https://account.blob.core.windows.net?sig=secret"),
    ("storage_url", "https://account.blob.core.windows.net//"),
    ("storage_url", "https://account.blob.core.windows.net/container"),
    ("storage_url", "https://account.blob.core.windows.net:443/"),
    ("storage_url", "https://user@account.blob.core.windows.net/"),
    ("storage_container", "bad--container"), ("managed_identity_client_id", ""),
    ("generation", "arbitrary"), ("public_origin", "https://publisher.example.com/path"),
    ("private_key", "secret-invalid-pem"),
])
def test_configuration_fails_closed(settings, field, value):
    with pytest.raises(ValueError) as error:
        replace(settings, **{field: value})
    assert "secret-invalid-pem" not in str(error.value)


def test_arm_blob_endpoint_root_slash_is_normalized(settings):
    configured = replace(settings, storage_url=settings.storage_url + "/")
    assert configured.storage_url == settings.storage_url


def test_environment_contract(settings, monkeypatch):
    names = {
        "GITHUB_REPOSITORY": settings.repository,
        "GITHUB_REPOSITORY_ID": str(settings.repository_id),
        "GITHUB_INSTALLATION_ID": str(settings.installation_id),
        "GITHUB_APP_ID": settings.app_id,
        "GITHUB_APP_PRIVATE_KEY": settings.private_key,
        "ORDERFLOW_PUBLISHER_KEY": settings.inbound_key,
        "ORDERFLOW_RECEIPT_ACCOUNT_URL": settings.storage_url,
        "ORDERFLOW_RECEIPT_CONTAINER": settings.storage_container,
        "AZURE_CLIENT_ID": settings.managed_identity_client_id,
        "ORDERFLOW_GENERATION": settings.generation,
    }
    monkeypatch.delenv("ORDERFLOW_PUBLISHER_PUBLIC_ORIGIN", raising=False)
    for key, value in names.items():
        monkeypatch.setenv(key, value)
    assert Settings.from_env() == replace(settings, public_origin="")
    monkeypatch.delenv("GITHUB_APP_PRIVATE_KEY")
    with pytest.raises(ValueError, match="environment configuration"):
        Settings.from_env()
