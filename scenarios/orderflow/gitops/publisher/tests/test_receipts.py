import json
from types import SimpleNamespace

import pytest
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError, ServiceRequestError

from scenarios.orderflow.gitops.publisher import receipts as module
from scenarios.orderflow.gitops.publisher.github import OperationError
from scenarios.orderflow.gitops.publisher.receipts import BlobReceipts

from .conftest import GENERATION


@pytest.fixture
def blob_rig(settings, monkeypatch):
    calls = {}

    class Blob:
        content = None
        failure = None

        def upload_blob(self, data, **kwargs):
            calls.setdefault("uploads", []).append((data, kwargs))
            if self.failure:
                raise self.failure
            self.content = data

        def download_blob(self, **kwargs):
            calls["download"] = kwargs
            if self.failure:
                raise self.failure
            if self.content is None:
                raise ResourceNotFoundError("SECRET_AZURE_RESPONSE")
            return SimpleNamespace(readall=lambda: self.content)

    blob = Blob()

    class Credential:
        def __init__(self, **kwargs):
            calls["credential"] = kwargs

        def close(self):
            calls["credential_closed"] = True

    class Service:
        def __init__(self, **kwargs):
            calls["service"] = kwargs

        def get_container_client(self, name):
            calls["container"] = name
            return self

        def get_blob_client(self, name):
            calls["blob"] = name
            return blob

        def close(self):
            calls["service_closed"] = True

    monkeypatch.setattr(module, "ManagedIdentityCredential", Credential)
    monkeypatch.setattr(module, "BlobServiceClient", Service)
    store = BlobReceipts(settings)
    return store, blob, calls


def test_blob_reservation_is_external_conditional_and_minimal(blob_rig, settings):
    store, _, calls = blob_rig
    assert store.reserve(GENERATION)
    data, kwargs = calls["uploads"][0]
    assert json.loads(data) == {"key": GENERATION, "issue": None}
    assert kwargs == {"overwrite": False, "timeout": 10, "logging_enable": False}
    assert calls["blob"] == f"github-123/{GENERATION}.json"
    assert calls["container"] == "incidents"
    assert calls["service"]["retry_total"] == 0
    assert calls["service"]["account_url"] == settings.storage_url
    assert calls["service"]["connection_timeout"] == 5
    assert calls["service"]["read_timeout"] == 10
    assert calls["credential"] == {
        "client_id": settings.managed_identity_client_id,
        "connection_timeout": 5, "read_timeout": 10, "retry_total": 0,
    }


def test_existing_reservation_is_not_overwritten(blob_rig):
    store, blob, calls = blob_rig
    blob.failure = ResourceExistsError("SECRET_AZURE_RESPONSE")
    assert store.reserve(GENERATION) is False
    assert len(calls["uploads"]) == 1
    assert calls["uploads"][0][1]["overwrite"] is False


def test_ambiguous_reservation_has_no_retry_or_error_leak(blob_rig):
    store, blob, calls = blob_rig
    blob.failure = ServiceRequestError("SECRET_AZURE_RESPONSE")
    with pytest.raises(OperationError, match="reservation outcome unknown") as error:
        store.reserve(GENERATION)
    assert "SECRET" not in str(error.value)
    assert len(calls["uploads"]) == 1


def test_blob_receipt_roundtrip_and_close(blob_rig):
    store, _, calls = blob_rig
    assert store.read(GENERATION) is None
    store.reserve(GENERATION)
    assert store.read(GENERATION) == {"key": GENERATION, "issue": None}
    issue = {"number": 7, "url": "https://github.com/example/orderflow/issues/7"}
    store.complete(GENERATION, issue)
    assert store.read(GENERATION) == {"key": GENERATION, "issue": issue}
    assert calls["download"] == {
        "offset": 0, "length": 4097, "timeout": 10, "logging_enable": False,
    }
    assert calls["uploads"][1][1]["overwrite"] is True
    store.close()
    assert calls["credential_closed"] and calls["service_closed"]


@pytest.mark.parametrize("data", [
    b"x" * 4097, b"not-json", b"\xff", b"[]", b"[" * 1500 + b"]" * 1500,
    json.dumps({"key": "other", "issue": None}).encode(),
    json.dumps({"key": GENERATION, "issue": None, "body": "not-allowed"}).encode(),
    json.dumps({"key": GENERATION, "issue": {"number": True, "url": "x"}}).encode(),
    json.dumps({"key": GENERATION, "issue": {"number": 0, "url": "x"}}).encode(),
    json.dumps({"key": GENERATION, "issue": {"number": 7}}).encode(),
    json.dumps({"key": GENERATION, "issue": {"number": 7, "url": 3}}).encode(),
])
def test_invalid_receipts_fail_closed(blob_rig, data):
    store, blob, _ = blob_rig
    blob.content = data
    with pytest.raises(OperationError):
        store.read(GENERATION)


def test_storage_read_and_completion_errors_are_redacted(blob_rig):
    store, blob, _ = blob_rig
    blob.failure = ServiceRequestError("SECRET_AZURE_RESPONSE")
    with pytest.raises(OperationError) as read_error:
        store.read(GENERATION)
    with pytest.raises(OperationError) as write_error:
        store.complete(GENERATION, {"number": 7, "url": "x"})
    assert "SECRET" not in str(read_error.value) + str(write_error.value)
