"""Fail-closed, server-owned incident assistant configuration."""

import hashlib
import os
import re
from dataclasses import dataclass
from urllib.parse import urlsplit
from uuid import UUID


def managed_identity_credential():
    from azure.identity import ManagedIdentityCredential

    return ManagedIdentityCredential(retry_total=1, connection_timeout=5, read_timeout=30)


@dataclass(frozen=True)
class Settings:
    endpoint: str
    agent_name: str
    agent_version: str
    model: str
    tenant: str
    operator: str
    owner: str
    run: str
    mode: str
    hostname: str
    workspace: str = ""
    workspace_resource: str = ""
    checkout_owner: str = ""
    arc_resource: str = ""
    app_resource: str = ""
    sre_resource: str = ""
    sre_endpoint: str = ""
    sre_latency_rule: str = ""
    sre_service_rule: str = ""
    checkout_created_at: str = ""

    @property
    def owner_hash(self):
        return hashlib.sha256(self.owner.encode()).hexdigest()

    @classmethod
    def from_env(cls, bootstrap=False, allow_unpinned=False):
        def required(key):
            value = os.environ.get(key, "").strip()
            if not value:
                raise ValueError(f"missing_configuration:{key}")
            return value

        endpoint = required("FOUNDRY_PROJECT_ENDPOINT")
        parsed = urlsplit(endpoint)
        if (
            parsed.scheme != "https"
            or parsed.username
            or parsed.password
            or parsed.port not in (None, 443)
            or parsed.query
            or parsed.fragment
            or not re.fullmatch(
                r"[a-z0-9.-]+\.(?:ai|services\.ai)\.azure\.com", parsed.hostname or ""
            )
            or not re.fullmatch(r"/api/projects/[A-Za-z0-9_-]+/?", parsed.path)
        ):
            raise ValueError("invalid_project_endpoint")
        hostname = required("WEBSITE_HOSTNAME").lower()
        if not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)*\.azurewebsites\.net", hostname):
            raise ValueError("invalid_website_hostname")
        tenant = str(UUID(required("DEMO_TENANT_ID")))
        operator = str(UUID(required("DEMO_ALLOWED_OBJECT_ID")))
        owner = required("DEMO_OWNER_TOKEN")
        run = required("DEMO_RUN_ID")
        if not all(re.fullmatch(r"[A-Za-z0-9_-]{8,128}", v) for v in (owner, run)):
            raise ValueError("invalid_ownership_configuration")
        mode = required("DEMO_EVIDENCE_MODE")
        if mode not in ("fixture", "live"):
            raise ValueError("invalid_evidence_mode")
        name = os.environ.get("FOUNDRY_AGENT_NAME", "incident-manager")
        model = os.environ.get("FOUNDRY_MODEL_DEPLOYMENT", "incident-reasoner")
        if bootstrap:
            version = ""
        elif allow_unpinned:
            version = os.environ.get("FOUNDRY_AGENT_VERSION", "").strip()
        else:
            version = required("FOUNDRY_AGENT_VERSION")
        if (
            not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,61}[a-z0-9]", name)
            or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", model)
            or (version and not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", version))
        ):
            raise ValueError("invalid_agent_configuration")
        return cls(
            endpoint,
            name,
            version,
            model,
            tenant,
            operator,
            owner,
            run,
            mode,
            hostname,
            *[
                os.environ.get(key, "")
                for key in (
                    "CHECKOUT_WORKSPACE_ID",
                    "CHECKOUT_WORKSPACE_RESOURCE_ID",
                    "CHECKOUT_OWNER_TOKEN",
                    "CHECKOUT_ARC_RESOURCE_ID",
                    "CHECKOUT_APP_RESOURCE_ID",
                    "CHECKOUT_SRE_RESOURCE_ID",
                    "CHECKOUT_SRE_ENDPOINT",
                    "CHECKOUT_LATENCY_RULE_ID",
                    "CHECKOUT_SERVICE_RULE_ID",
                    "CHECKOUT_CREATED_AT",
                )
            ],
        )
