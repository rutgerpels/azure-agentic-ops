"""External, durable receipts: an uncertain reservation is never permission to POST."""

import json
from typing import Any, Protocol

from azure.core.exceptions import AzureError, ResourceExistsError, ResourceNotFoundError
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient

from .config import Settings
from .github import OperationError


class Receipts(Protocol):
    def reserve(self, key: str) -> bool: ...
    def read(self, key: str) -> dict[str, Any] | None: ...
    def complete(self, key: str, issue: dict[str, Any]) -> None: ...


class BlobReceipts:
    def __init__(self, settings: Settings) -> None:
        self.credential = ManagedIdentityCredential(
            client_id=settings.managed_identity_client_id,
            connection_timeout=5, read_timeout=10, retry_total=0,
        )
        self.service = BlobServiceClient(
            account_url=settings.storage_url, credential=self.credential,
            retry_total=0, connection_timeout=5, read_timeout=10,
            logging_enable=False,
        )
        self.container = self.service.get_container_client(settings.storage_container)
        self.prefix = f"github-{settings.repository_id}/"

    def _blob(self, key: str) -> Any:
        return self.container.get_blob_client(f"{self.prefix}{key}.json")

    def reserve(self, key: str) -> bool:
        try:
            self._blob(key).upload_blob(
                json.dumps({"key": key, "issue": None}).encode(),
                overwrite=False, timeout=10, logging_enable=False,
            )
            return True
        except ResourceExistsError:
            return False
        except AzureError:
            raise OperationError("Receipt reservation outcome unknown; do not replay") from None

    def read(self, key: str) -> dict[str, Any] | None:
        try:
            # A bounded range prevents reading a misconfigured/modified giant blob.
            raw = self._blob(key).download_blob(
                offset=0, length=4097, timeout=10, logging_enable=False,
            ).readall()
            if len(raw) > 4096:
                raise OperationError("Invalid durable receipt")
            result = json.loads(raw)
            if not isinstance(result, dict) or set(result) != {"key", "issue"}:
                raise OperationError("Invalid durable receipt")
            if result["key"] != key:
                raise OperationError("Durable receipt key mismatch")
            issue = result["issue"]
            if issue is not None and (
                not isinstance(issue, dict) or set(issue) != {"number", "url"}
                or type(issue["number"]) is not int or issue["number"] <= 0
                or not isinstance(issue["url"], str)
            ):
                raise OperationError("Invalid durable receipt reference")
            return result
        except ResourceNotFoundError:
            return None
        except (AzureError, ValueError, RecursionError):
            raise OperationError("Durable receipt unavailable; do not replay") from None

    def complete(self, key: str, issue: dict[str, Any]) -> None:
        try:
            self._blob(key).upload_blob(
                json.dumps({"key": key, "issue": issue}).encode(),
                overwrite=True, timeout=10, logging_enable=False,
            )
        except AzureError:
            raise OperationError("Receipt confirmation unknown; do not replay") from None

    def close(self) -> None:
        self.service.close()
        self.credential.close()
