"""Mocked exact-owned ARM federation lifecycle; no Azure calls."""

import copy
import json
from types import SimpleNamespace

import pytest

from scripts.github import federation, intake

PRINCIPAL = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
CLIENT = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
TENANT = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
EXPIRY = "2030-01-01T00:00:00Z"


@pytest.fixture
def config():
    return json.loads(
        (intake.ROOT / "profiles" / "github" / "intake.example.json").read_text()
    )


class Arm:
    def __init__(self):
        self.assets = {}
        self.writes = []
        self.uncertain = False
        self.lost = False
        self.lost_delete = False

    def request(self, method, path, body=None, **kwargs):
        if method == "GET":
            return (200, copy.deepcopy(self.assets[path])) if path in self.assets else (404, None)
        self.writes.append((method, path))
        if method == "DELETE":
            del self.assets[path]
            if self.lost_delete:
                self.lost_delete = False
                raise TimeoutError("Lost successful delete response")
            return 204, None
        if self.uncertain:
            raise TimeoutError("Unknown ARM write")
        value = {"id": path.split("?")[0], **copy.deepcopy(body)}
        if "userAssignedIdentities" in path and "/federatedIdentityCredentials/" not in path:
            value["properties"] = {
                "clientId": CLIENT, "principalId": PRINCIPAL, "tenantId": TENANT,
            }
        self.assets[path] = value
        if self.lost:
            self.lost = False
            raise TimeoutError("Lost successful identity response")
        return 201, value


def test_exact_minimal_role_and_federation_spec(config):
    specs = federation.specifications(config, "swedencentral", EXPIRY)
    identity, fic, role, assignment = specs
    assert identity["id"].endswith("retailtx-github-intake-demo01")
    assert fic["body"]["properties"] == {
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:rutgerpels/retailtx-agentic-ops-demo:environment:sre-github-intake",
        "audiences": ["api://AzureADTokenExchange"],
    }
    assert assignment["id"].startswith(config["binding"]["agentId"] + "/providers/")
    permission = role["body"]["properties"]["permissions"][0]
    assert permission["actions"] == ["Microsoft.App/agents/read"]
    assert permission["dataActions"] == [
        "Microsoft.App/agents/threads/read", "Microsoft.App/agents/threads/write",
    ]
    assert permission["notActions"] == permission["notDataActions"] == []
    assert "approve" not in json.dumps(specs)
    assert "threads/delete" not in json.dumps(specs)


def test_repeat_setup_readiness_and_exact_owned_teardown(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    state = federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    assert state["phase"] == "ConfiguredOidcUnverified"
    assert state["principalId"] == PRINCIPAL
    assert len(api.writes) == 4
    federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    federation.check(config, state_path, api)
    config.update(runtimeVerified=True, knowledgeRetrievalVerified=True, triggerId="real-trigger")
    federation.check(config, state_path, api)
    assert len(api.writes) == 4
    federation.remove(config, state_path, api)
    assert len(api.writes) == 8
    assert [path for _, path in api.writes[4:]] == [
        federation.resource_path(asset) for asset in reversed(state["assets"])
    ]
    assert json.loads(state_path.read_text())["phase"] == "Removed"
    federation.remove(config, state_path, api)
    assert len(api.writes) == 8
    with pytest.raises(ValueError, match="recreation"):
        federation.configure(config, state_path, api, "swedencentral", EXPIRY)


def test_unknown_put_never_replayed(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    api.uncertain = True
    with pytest.raises(TimeoutError):
        federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    with pytest.raises(RuntimeError, match="never replay"):
        federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    with pytest.raises(RuntimeError, match="no absence"):
        federation.remove(config, state_path, api)
    assert len(api.writes) == 1


def test_lost_successful_put_reconciles_get_only(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    api.lost = True
    with pytest.raises(TimeoutError):
        federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    assert len(api.writes) == 4


def test_foreign_collision_and_role_drift_block_all_deletion(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    specs = federation.specifications(config, "swedencentral", EXPIRY)
    api.assets[federation.resource_path(specs[2])] = {"id": specs[2]["id"]}
    with pytest.raises(ValueError, match="collision"):
        federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    assert not api.writes
    assert not state_path.exists()
    api.assets.clear()
    state = federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    role = api.assets[federation.resource_path(state["assets"][2])]
    role["properties"]["permissions"][0]["dataActions"].append(
        "Microsoft.App/agents/threads/approve/action",
    )
    with pytest.raises(ValueError, match="drift"):
        federation.remove(config, state_path, api)
    assert len(api.writes) == 4


def test_manifest_path_change_and_identity_replacement_rejected(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    state = federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    state["assets"][2]["id"] += "-foreign"
    state_path.write_text(json.dumps(state))
    with pytest.raises(ValueError, match="paths"):
        federation.remove(config, state_path, api)
    assert len(api.writes) == 4


@pytest.mark.parametrize("operation", ["configure", "check", "remove"])
@pytest.mark.parametrize("field", ["clientId", "principalId", "tenantId"])
def test_live_identity_replacement_preserves_manifest_and_grants(
    config, tmp_path, operation, field,
):
    api, state_path = Arm(), tmp_path / "federation.json"
    state = federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    saved = state_path.read_bytes()
    identity = api.assets[federation.resource_path(state["assets"][0])]
    identity["properties"][field] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    with pytest.raises(ValueError, match="changed"):
        if operation == "configure":
            federation.configure(config, state_path, api, "swedencentral", EXPIRY)
        elif operation == "check":
            federation.check(config, state_path, api)
        else:
            federation.remove(config, state_path, api)
    assert len(api.writes) == 4
    assert state_path.read_bytes() == saved


def test_lost_identity_response_can_teardown_owned_intent_without_adoption(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    api.lost = True
    with pytest.raises(TimeoutError):
        federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    federation.remove(config, state_path, api)
    state = json.loads(state_path.read_text())
    assert state["clientId"] == CLIENT
    assert state["phase"] == "Removed"
    assert len(api.writes) == 2
    federation.remove(config, state_path, api)
    assert len(api.writes) == 2


def test_lost_identity_create_and_delete_responses_reconcile_without_writes(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    api.lost = True
    with pytest.raises(TimeoutError):
        federation.configure(config, state_path, api, "swedencentral", EXPIRY)
    api.lost_delete = True
    with pytest.raises(TimeoutError):
        federation.remove(config, state_path, api)
    state = json.loads(state_path.read_text())
    assert state["assets"][0]["phase"] == "Verified"
    assert state["phase"] == "Removing"
    federation.remove(config, state_path, api)
    federation.remove(config, state_path, api)
    assert len(api.writes) == 2
    assert json.loads(state_path.read_text())["phase"] == "Removed"


def test_arm_auth_resolves_cli_and_binds_subscription_without_shell(config, monkeypatch):
    calls = []
    monkeypatch.setattr(federation, "azure_cli_executable", lambda: "absolute-az.cmd")

    def acquire(arguments, **kwargs):
        calls.append((arguments, kwargs))
        return SimpleNamespace(returncode=0, stdout="test-arm-token\n")

    monkeypatch.setattr(federation.subprocess, "run", acquire)
    assert federation.arm_token(config) == "test-arm-token"
    arguments, options = calls[0]
    assert arguments[0] == "absolute-az.cmd"
    assert arguments[arguments.index("--subscription") + 1] == config["binding"]["subscriptionId"]
    assert arguments[arguments.index("--resource") + 1] == "https://management.azure.com/"
    assert options["shell"] is False
    assert options["timeout"] == 30
