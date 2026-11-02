"""Deployment-only configuration; no caller can choose destinations or permissions."""

import os
import re
from dataclasses import dataclass, field
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey

LABEL = "orderflow-incident"
KEY_PATTERN = r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}"
PROTOCOLS = ("2025-03-26", "2025-06-18", "2025-11-25")
MAX_REQUEST = 65_536
MAX_RESPONSE = 8 * 1024 * 1024
MAX_PAGES = 5


@dataclass(frozen=True)
class Settings:
    repository: str
    repository_id: int
    installation_id: int
    app_id: str
    private_key: str = field(repr=False)
    inbound_key: str = field(repr=False)
    storage_url: str
    storage_container: str
    managed_identity_client_id: str
    generation: str
    public_origin: str = ""

    def __post_init__(self) -> None:
        if (
            not re.fullmatch(r"[A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100}", self.repository)
            or self.repository.rsplit("/", 1)[-1] in (".", "..")
        ):
            raise ValueError("Invalid configured GitHub repository")
        if type(self.repository_id) is not int or self.repository_id <= 0:
            raise ValueError("Invalid configured repository ID")
        if type(self.installation_id) is not int or self.installation_id <= 0:
            raise ValueError("Invalid configured installation ID")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", self.app_id):
            raise ValueError("Invalid configured GitHub App ID")
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", self.inbound_key):
            raise ValueError("Inbound key must contain 32-256 random base64url characters")
        if not re.fullmatch(
            r"https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/?", self.storage_url,
        ):
            raise ValueError(
                "Storage URL must be a fixed public Azure Blob account URL, without SAS"
            )
        object.__setattr__(self, "storage_url", self.storage_url.removesuffix("/"))
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]", self.storage_container):
            raise ValueError("Invalid receipt container")
        if not re.fullmatch(
            r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
            self.managed_identity_client_id,
        ):
            raise ValueError("A user-assigned managed identity client ID is required")
        if not re.fullmatch(KEY_PATTERN, self.generation):
            raise ValueError("A canonical lowercase owner generation GUID is required")
        origin = urlsplit(self.public_origin)
        if self.public_origin and (
            origin.scheme != "https"
            or not origin.hostname
            or origin.netloc != origin.hostname
            or origin.path
            or origin.query
            or origin.fragment
        ):
            raise ValueError("Public origin must be an HTTPS origin without a path or port")
        try:
            key = serialization.load_pem_private_key(self.private_key.encode(), password=None)
        except (ValueError, TypeError):
            raise ValueError("Invalid GitHub App RSA private key") from None
        if not isinstance(key, RSAPrivateKey) or key.key_size < 2048:
            raise ValueError("GitHub App requires an RSA private key of at least 2048 bits")

    @classmethod
    def from_env(cls) -> "Settings":
        try:
            return cls(
                repository=os.environ["GITHUB_REPOSITORY"],
                repository_id=int(os.environ["GITHUB_REPOSITORY_ID"]),
                installation_id=int(os.environ["GITHUB_INSTALLATION_ID"]),
                app_id=os.environ["GITHUB_APP_ID"],
                private_key=os.environ["GITHUB_APP_PRIVATE_KEY"],
                inbound_key=os.environ["ORDERFLOW_PUBLISHER_KEY"],
                storage_url=os.environ["ORDERFLOW_RECEIPT_ACCOUNT_URL"],
                storage_container=os.environ["ORDERFLOW_RECEIPT_CONTAINER"],
                managed_identity_client_id=os.environ["AZURE_CLIENT_ID"],
                generation=os.environ["ORDERFLOW_GENERATION"],
                public_origin=os.environ.get("ORDERFLOW_PUBLISHER_PUBLIC_ORIGIN", ""),
            )
        except (KeyError, ValueError):
            raise ValueError("Missing or invalid publisher environment configuration") from None
