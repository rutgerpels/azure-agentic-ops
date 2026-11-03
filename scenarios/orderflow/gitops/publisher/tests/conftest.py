import copy
import json
import threading
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from scenarios.orderflow.gitops.publisher.config import Settings
from scenarios.orderflow.gitops.publisher.github import GitHub, OperationError, marker
from scenarios.orderflow.gitops.publisher.server import create_app
from scenarios.orderflow.gitops.publisher.service import Publisher

GENERATION = "aaaaaaaa-2222-4333-8444-555555555555"
INBOUND_KEY = "test-only-random-key-not-for-deploy_123456789"
HEADERS = {
    "x-orderflow-key": INBOUND_KEY,
    "accept": "application/json, text/event-stream",
    "mcp-protocol-version": "2025-11-25",
}


@pytest.fixture(scope="session")
def private_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


@pytest.fixture
def settings(private_key):
    return Settings(
        repository="example/orderflow", repository_id=123, installation_id=456,
        app_id="Iv1.test", private_key=private_key, inbound_key=INBOUND_KEY,
        storage_url="https://orderflowtest.blob.core.windows.net",
        storage_container="incidents",
        managed_identity_client_id="00000000-0000-4000-8000-000000000001",
        generation=GENERATION, public_origin="https://publisher.example.com",
    )


class MemoryReceipts:
    def __init__(self):
        self.items = {}
        self.lock = threading.Lock()
        self.reserve_error = False
        self.complete_error = False
        self.read_error = False
        self.reservations = 0

    def read(self, key):
        if self.read_error:
            raise OperationError("Durable receipt unavailable; do not replay")
        return copy.deepcopy(self.items.get(key))

    def reserve(self, key):
        with self.lock:
            self.reservations += 1
            if key in self.items:
                return False
            self.items[key] = {"key": key, "issue": None}
            if self.reserve_error:
                raise OperationError("Receipt reservation outcome unknown; do not replay")
            return True

    def complete(self, key, issue):
        if self.complete_error:
            raise OperationError("Receipt confirmation unknown; do not replay")
        self.items[key] = {"key": key, "issue": copy.deepcopy(issue)}


class GitHubAPI:
    def __init__(self):
        self.requests = []
        self.issues = []
        self.overrides = {}
        self.posts = 0
        self.mints = 0
        self.create_timeout = False
        self.create_before_failure = False
        self.on_create = None

    def issue(self, number=7, key=GENERATION):
        return {
            "number": number, "body": "Evidence\n\n" + marker(key),
            "html_url": f"https://github.com/example/orderflow/issues/{number}",
        }

    def __call__(self, request):
        self.requests.append(request)
        path, method = request.url.path, request.method
        override = self.overrides.get((method, path))
        if override is not None:
            if callable(override):
                return override(request)
            return httpx.Response(override, json={"message": "SECRET_UPSTREAM_ERROR"})
        if path == "/app/installations/456/access_tokens" and method == "POST":
            self.mints += 1
            return httpx.Response(201, json={
                "token": f"SECRET_INSTALLATION_TOKEN_{self.mints}",
                "expires_at": (datetime.now(UTC) + timedelta(hours=1)).isoformat(),
            })
        if path == "/repos/example/orderflow" and method == "GET":
            return httpx.Response(200, json={"id": 123, "full_name": "example/orderflow"})
        if path == "/repos/example/orderflow/issues":
            if method == "GET":
                page = int(request.url.params["page"])
                return httpx.Response(200, json=self.issues[(page - 1) * 100:page * 100])
            if method == "POST":
                self.posts += 1
                if self.on_create:
                    self.on_create()
                if self.create_before_failure:
                    raise httpx.ConnectError("SECRET_TRANSPORT_ERROR")
                payload = json.loads(request.content)
                item = self.issue()
                item["body"] = payload["body"]
                self.issues.append(item)
                if self.create_timeout:
                    raise httpx.ReadTimeout("SECRET_TRANSPORT_ERROR")
                return httpx.Response(201, json=item)
        if method == "GET" and path.startswith("/repos/example/orderflow/issues/"):
            for item in self.issues:
                if str(item["number"]) == path.rsplit("/", 1)[1]:
                    return httpx.Response(200, json=item)
            return httpx.Response(404, json={"message": "SECRET_DELETED"})
        raise AssertionError(f"Unexpected outbound request: {method} {request.url}")


@dataclass
class Rig:
    api: GitHubAPI
    receipts: MemoryReceipts
    github: GitHub
    publisher: Publisher
    client: TestClient
    inputs: dict[str, Any] = field(default_factory=lambda: {
        "incident_key": GENERATION,
        "title": "Synthetic Cosmos dependency failure",
        "body": "Synthetic incident evidence; preserve the data-tier deny.",
    })

    def rpc(self, method, params=None, *, request_id=1, headers=None):
        return self.client.post(
            "/mcp", headers=HEADERS if headers is None else headers,
            json={"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}},
        )

    def tool(self, name="publish_incident_issue", arguments=None):
        response = self.rpc("tools/call", {
            "name": name, "arguments": self.inputs if arguments is None else arguments,
        })
        return response, json.loads(response.json()["result"]["content"][0]["text"])


@pytest.fixture
def rig(settings):
    api, receipts = GitHubAPI(), MemoryReceipts()
    with httpx.Client(transport=httpx.MockTransport(api)) as transport:
        github = GitHub(settings, transport)
        publisher = Publisher(github, receipts)
        with TestClient(
            create_app(settings, publisher), base_url=settings.public_origin,
        ) as client:
            yield Rig(api, receipts, github, publisher, client)
