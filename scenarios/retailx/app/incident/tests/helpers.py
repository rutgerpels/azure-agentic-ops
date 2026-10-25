import base64
import json
from dataclasses import replace
from types import SimpleNamespace

from config import Settings

TENANT = "11111111-1111-4111-8111-111111111111"
OPERATOR = "22222222-2222-4222-8222-222222222222"


def settings(**changes):
    return replace(
        Settings(
            endpoint="https://incident-proof.services.ai.azure.com/api/projects/incident",
            agent_name="incident-manager",
            agent_version="1",
            model="incident-reasoner",
            tenant=TENANT,
            operator=OPERATOR,
            owner="test-owner-123456",
            run="test-run-123456",
            mode="fixture",
            hostname="incident-proof.azurewebsites.net",
        ),
        **changes,
    )


def live_settings():
    group = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/checkout"
    return settings(
        mode="live",
        workspace="44444444-4444-4444-8444-444444444444",
        workspace_resource=f"{group}/providers/Microsoft.OperationalInsights/workspaces/ops",
        checkout_owner="55555555-5555-4555-8555-555555555555",
        arc_resource=f"{group}/providers/Microsoft.HybridCompute/machines/checkout",
        app_resource=f"{group}/providers/Microsoft.Insights/components/checkout",
    )


def principal(oid=OPERATOR, tenant=TENANT, auth="aad", uri=False, extra=None):
    claims = [
        {
            "typ": "http://schemas.microsoft.com/identity/claims/objectidentifier"
            if uri
            else "oid",
            "val": oid,
        },
        {
            "typ": "http://schemas.microsoft.com/identity/claims/tenantid" if uri else "tid",
            "val": tenant,
        },
    ]
    claims.extend(extra or [])
    return base64.b64encode(json.dumps({"auth_typ": auth, "claims": claims}).encode()).decode()


def response(identifier="resp-test", output=None, text="Evidence reviewed.", status="completed"):
    return SimpleNamespace(id=identifier, status=status, output=output or [], output_text=text)


def call(name="get_checkout_health", countries=None, horizon=None, identifier="call-1"):
    args = {"countries": countries or ["BE"]}
    if horizon is not None:
        args["horizon_minutes"] = horizon
    return {
        "type": "function_call",
        "name": name,
        "arguments": json.dumps(args),
        "call_id": identifier,
        "id": "fc-" + identifier,
    }


class FakeResponses:
    def __init__(self, replies):
        self.replies = iter(replies)
        self.requests = []

    def create(self, **kwargs):
        # Copy because the caller appends to its stateless input list after create.
        self.requests.append(json.loads(json.dumps(kwargs)))
        reply = next(self.replies)
        if isinstance(reply, Exception):
            raise reply
        return reply
