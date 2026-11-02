import json
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization

from scenarios.orderflow.gitops.publisher import github as github_module
from scenarios.orderflow.gitops.publisher.config import LABEL, MAX_PAGES, MAX_RESPONSE
from scenarios.orderflow.gitops.publisher.github import marker
from scenarios.orderflow.gitops.publisher.service import FindInput, Publisher, PublishInput

from .conftest import GENERATION, MemoryReceipts


def test_publish_reserves_before_post_and_does_not_assign(rig):
    def check_reserved():
        assert rig.receipts.items[GENERATION] == {"key": GENERATION, "issue": None}

    rig.api.on_create = check_reserved
    _, outcome = rig.tool()
    assert outcome["status"] == "published"
    payload = json.loads(next(
        r.content for r in rig.api.requests
        if r.method == "POST" and r.url.path.endswith("/issues")
    ))
    assert payload == {
        "title": rig.inputs["title"], "body": rig.inputs["body"] + "\n\n" + marker(GENERATION),
        "labels": [LABEL],
    }
    assert rig.receipts.items[GENERATION] == {
        "key": GENERATION, "issue": outcome["issue"],
    }
    assert rig.inputs["body"] not in json.dumps(rig.receipts.items)


def test_duplicate_calls_and_restart_do_not_create_twice(rig):
    assert rig.tool()[1]["status"] == "published"
    assert rig.tool()[1]["status"] == "found"
    restarted = Publisher(rig.github, rig.receipts)
    result = restarted.publish(PublishInput(**rig.inputs))
    assert result["status"] == "found"
    assert rig.api.posts == 1
    assert rig.receipts.reservations == 1
    assert rig.api.requests[-1].url.path.endswith("/issues/7")


def test_find_is_read_only(rig):
    rig.receipts.reserve(GENERATION)
    rig.api.issues = [rig.api.issue()]
    before = json.dumps(rig.receipts.items)
    assert rig.tool("find_incident_issue", {"incident_key": GENERATION})[1]["status"] == "found"
    assert before == json.dumps(rig.receipts.items)
    assert not rig.api.posts


def test_find_not_found_and_existing_unreserved_issue(rig):
    _, result = rig.tool("find_incident_issue", {"incident_key": GENERATION})
    assert result == {"status": "not_found", "incident_key": GENERATION}
    assert not rig.receipts.items
    rig.api.issues = [rig.api.issue()]
    assert rig.tool()[1]["status"] == "found"
    assert rig.api.posts == 0


@pytest.mark.parametrize("after_create", [False, True])
def test_unknown_write_is_never_replayed(rig, after_create):
    rig.api.create_timeout = after_create
    rig.api.create_before_failure = not after_create
    response, result = rig.tool()
    assert result["status"] == "unknown"
    assert response.json()["result"]["isError"] is True
    assert rig.receipts.items[GENERATION]["issue"] is None
    rig.api.create_timeout = rig.api.create_before_failure = False
    expected = "found" if after_create else "unknown"
    assert rig.tool()[1]["status"] == expected
    assert rig.api.posts == 1
    if not after_create:
        assert "never submit a second POST" in rig.tool()[1]["message"]


def test_ambiguous_reservation_never_creates(rig):
    rig.receipts.reserve_error = True
    assert rig.tool()[1]["status"] == "unknown"
    rig.receipts.reserve_error = False
    assert rig.tool()[1]["status"] == "unknown"
    assert rig.api.posts == 0


def test_unavailable_storage_never_creates(rig):
    rig.receipts.read_error = True
    assert rig.tool()[1]["status"] == "unknown"
    assert rig.api.requests == []


def test_failed_receipt_confirmation_reconciles_without_second_post(rig):
    rig.receipts.complete_error = True
    assert rig.tool()[1]["status"] == "unknown"
    rig.receipts.complete_error = False
    assert rig.tool()[1]["status"] == "found"
    assert rig.receipts.items[GENERATION]["issue"]["number"] == 7
    assert rig.api.posts == 1


def test_completed_receipt_deleted_issue_is_unknown_not_recreated(rig):
    rig.tool()
    rig.api.issues.clear()
    assert rig.tool()[1]["status"] == "unknown"
    assert rig.api.posts == 1


def test_concurrent_replicas_only_reservation_winner_posts(rig):
    entered, finish = threading.Event(), threading.Event()

    def block():
        entered.set()
        assert finish.wait(5)

    rig.api.on_create = block
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(rig.publisher.publish, PublishInput(**rig.inputs))
        assert entered.wait(5)
        second = Publisher(rig.github, rig.receipts).publish(PublishInput(**rig.inputs))
        finish.set()
        assert first.result(timeout=5)["status"] == "published"
    assert second["status"] == "unknown"
    assert rig.api.posts == 1


def test_reservation_loser_reconciles(rig):
    original = rig.receipts.reserve

    def another_winner(key):
        assert original(key)
        rig.api.issues.append(rig.api.issue())
        return False

    rig.receipts.reserve = another_winner
    assert rig.tool()[1]["status"] == "found"
    assert rig.api.posts == 0


def test_reservation_loser_missing_receipt_never_posts(rig):
    rig.receipts.reserve = lambda key: False
    assert rig.tool()[1]["status"] == "unknown"
    assert rig.api.posts == 0


def test_generation_checked_even_outside_http(rig):
    other = "00000000-2222-4333-8444-555555555555"
    result = rig.publisher.publish(PublishInput(**(rig.inputs | {"incident_key": other})))
    assert result["status"] == "unknown"
    assert rig.publisher.find(FindInput(incident_key=other))["status"] == "unknown"
    assert not rig.api.requests
    assert not rig.receipts.items


def test_token_jwt_and_repository_restriction(rig, settings):
    rig.tool()
    request = rig.api.requests[0]
    pem = serialization.load_pem_private_key(settings.private_key.encode(), password=None)
    claims = jwt.decode(
        request.headers["authorization"].split(" ", 1)[1], pem.public_key(), algorithms=["RS256"],
    )
    assert claims["iss"] == settings.app_id
    assert 500 <= claims["exp"] - datetime.now(UTC).timestamp() <= 540
    assert claims["iat"] < datetime.now(UTC).timestamp()
    assert json.loads(request.content) == {
        "repository_ids": [123], "permissions": {"issues": "write"},
    }
    assert rig.api.requests[1].url.path == "/repos/example/orderflow"
    for request in rig.api.requests:
        assert request.url.host == "api.github.com"
        assert request.url.scheme == "https"
        assert request.headers["x-github-api-version"] == "2026-03-10"
        assert request.extensions["timeout"] == {
            "connect": 5.0, "read": 15.0, "write": 15.0, "pool": 15.0,
        }


def test_token_cached_and_refreshed_before_expiry(rig):
    args = {"incident_key": GENERATION}
    rig.tool("find_incident_issue", args)
    rig.tool("find_incident_issue", args)
    assert rig.api.mints == 1
    rig.github._expires = datetime.now(UTC).timestamp() + 60
    rig.tool("find_incident_issue", args)
    assert rig.api.mints == 2
    assert [r.url.path for r in rig.api.requests].count("/repos/example/orderflow") == 2


def test_revoked_token_not_replayed_but_future_observation_can_refresh(rig):
    args = {"incident_key": GENERATION}
    rig.tool("find_incident_issue", args)
    rig.api.overrides[("GET", "/repos/example/orderflow/issues")] = 401
    assert rig.tool("find_incident_issue", args)[1]["status"] == "unknown"
    assert rig.api.mints == 1
    del rig.api.overrides[("GET", "/repos/example/orderflow/issues")]
    assert rig.tool("find_incident_issue", args)[1]["status"] == "not_found"
    assert rig.api.mints == 2


@pytest.mark.parametrize("payload", [
    {"id": 999, "full_name": "example/orderflow"},
    {"id": 123, "full_name": "attacker/other"},
    {"id": "123", "full_name": "example/orderflow"}, [], {},
])
def test_repository_identity_mismatch_never_reserves_or_posts(rig, payload):
    rig.api.overrides[("GET", "/repos/example/orderflow")] = lambda r: httpx.Response(
        200, json=payload,
    )
    assert rig.tool()[1]["status"] == "unknown"
    assert rig.api.posts == 0
    assert not rig.receipts.items


@pytest.mark.parametrize("status", [301, 302, 307, 401, 403, 429, 500, 503])
def test_issue_write_errors_are_redacted_not_retried(rig, status, caplog):
    rig.api.overrides[("POST", "/repos/example/orderflow/issues")] = status
    response, result = rig.tool()
    assert result["status"] == "unknown"
    assert "SECRET" not in response.text
    assert "SECRET" not in caplog.text
    assert "PRIVATE KEY" not in caplog.text
    rig.tool()
    writes = [r for r in rig.api.requests if r.method == "POST" and r.url.path.endswith("/issues")]
    assert len(writes) == 1
    assert rig.receipts.items[GENERATION]["issue"] is None


@pytest.mark.parametrize("path", [
    "/app/installations/456/access_tokens", "/repos/example/orderflow",
    "/repos/example/orderflow/issues",
])
def test_redirects_never_followed(rig, path):
    method = "POST" if path.endswith("access_tokens") else "GET"
    rig.api.overrides[(method, path)] = lambda r: httpx.Response(
        307, headers={"location": "https://attacker.example/steal"},
    )
    assert rig.tool()[1]["status"] == "unknown"
    assert all(r.url.host == "api.github.com" for r in rig.api.requests)
    assert not rig.receipts.items


def test_transport_exception_messages_and_text_never_returned(rig, caplog):
    rig.api.create_before_failure = True
    response, _ = rig.tool()
    assert "SECRET" not in response.text + caplog.text
    assert rig.inputs["body"] not in response.text + caplog.text


def test_bounded_listing_uses_get_not_search_and_handles_closed_issues(rig):
    rig.api.issues = [rig.api.issue(i, key="other") for i in range(1, 101)]
    rig.api.issues.append(rig.api.issue())
    assert rig.tool()[1]["status"] == "found"
    reads = [r for r in rig.api.requests if r.url.path.endswith("/issues")]
    assert len(reads) == 2
    assert all(r.method == "GET" for r in reads)
    assert all(r.url.params["state"] == "all" for r in reads)
    assert all(r.url.params["labels"] == LABEL for r in reads)
    assert all(r.url.params["per_page"] == "100" for r in reads)
    assert rig.api.posts == 0


def test_scan_truncation_fails_closed_even_with_matching_issue(rig):
    rig.api.issues = [rig.api.issue(i, key="other") for i in range(1, MAX_PAGES * 100 + 1)]
    rig.api.issues[0] = rig.api.issue()
    assert rig.tool()[1]["status"] == "unknown"
    assert not rig.receipts.items
    assert rig.api.posts == 0
    assert len([r for r in rig.api.requests if r.url.path.endswith("/issues")]) == MAX_PAGES


def test_duplicate_markers_and_pull_requests(rig):
    rig.api.issues = [rig.api.issue(), rig.api.issue(8)]
    assert rig.tool()[1]["status"] == "unknown"
    rig.api.issues = [rig.api.issue() | {"pull_request": {}}]
    assert rig.tool()[1]["status"] == "published"


@pytest.mark.parametrize("field,value", [
    ("html_url", "https://github.com/attacker/repo/issues/7"),
    ("html_url", None), ("number", "7"), ("number", True), ("number", -1),
])
def test_invalid_issue_reference_never_leaves_repository(rig, field, value):
    rig.api.issues = [rig.api.issue() | {field: value}]
    assert rig.tool()[1]["status"] == "unknown"
    assert rig.api.posts == 0


def test_marker_must_be_a_complete_line(rig):
    item = rig.api.issue()
    item["body"] = "Quoted inline: " + marker(GENERATION)
    rig.api.issues = [item]
    assert rig.tool()[1]["status"] == "published"


@pytest.mark.parametrize("payload", [
    [], {}, {"token": "", "expires_at": "bad"},
    {"token": "secret", "expires_at": "bad"},
    {"token": "secret", "expires_at": "2026-01-01T00:00:00"},
    {"token": "secret", "expires_at": (datetime.now(UTC) - timedelta(hours=1)).isoformat()},
])
def test_malformed_token_response_never_reserves(rig, payload):
    rig.api.overrides[("POST", "/app/installations/456/access_tokens")] = lambda r: httpx.Response(
        201, json=payload,
    )
    assert rig.tool()[1]["status"] == "unknown"
    assert not rig.receipts.items


def test_outbound_response_size_bound(rig):
    rig.api.overrides[("GET", "/repos/example/orderflow/issues")] = lambda r: httpx.Response(
        200, content=b"x" * (MAX_RESPONSE + 1),
    )
    assert rig.tool()[1]["status"] == "unknown"
    assert not rig.receipts.items


def test_compressed_responses_refused_before_decoding(rig):
    rig.api.overrides[("GET", "/repos/example/orderflow/issues")] = lambda r: httpx.Response(
        200, headers={"content-encoding": "gzip"}, stream=httpx.ByteStream(b"not-a-gzip-stream"),
    )
    assert rig.tool()[1]["status"] == "unknown"
    assert rig.api.requests[-1].headers["accept-encoding"] == "identity"
    assert not rig.receipts.items


def test_response_deadline_is_bounded(rig, monkeypatch):
    # Directly test the streaming deadline without coupling to the token clock.
    times = iter([100.0, 131.0])
    monkeypatch.setattr(github_module, "time", SimpleNamespace(monotonic=lambda: next(times)))
    with pytest.raises(github_module.OperationError, match="deadline exceeded"):
        rig.github._request("GET", "/repos/example/orderflow", "test-token")


@pytest.mark.parametrize("content", [b"\xff", b"not-json", b"{", b"[" * 1500 + b"]" * 1500])
def test_malformed_github_response_is_redacted(rig, content):
    rig.api.overrides[("GET", "/repos/example/orderflow/issues")] = lambda r: httpx.Response(
        200, content=content,
    )
    assert rig.tool()[1]["status"] == "unknown"
    assert not rig.receipts.items


def test_unexpected_programming_errors_not_swallowed(rig):
    def broken(key):
        raise RuntimeError("unexpected programmer error")

    rig.receipts.read = broken
    with pytest.raises(RuntimeError, match="unexpected programmer"):
        rig.publisher.publish(PublishInput(**rig.inputs))


def test_no_local_receipts_are_a_runtime_option():
    assert MemoryReceipts.__module__.endswith("conftest")
    with pytest.raises(TypeError):
        Publisher()
