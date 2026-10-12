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
SUBJECT = (
    "repo:rutgerpels@121695274/retailtx-agentic-ops-demo@1399486000"
    ":environment:sre-github-intake"
)
REPOSITORY = {
    "full_name": "rutgerpels/retailtx-agentic-ops-demo", "id": 1399486000,
    "owner": {"login": "rutgerpels", "id": 121695274},
}


@pytest.fixture
def config():
    value = json.loads(
        (intake.ROOT / "profiles" / "github" / "intake.example.json").read_text()
    )
    value["oidc"]["subject"] = (
        "repo:rutgerpels/retailtx-agentic-ops-demo:environment:sre-github-intake"
    )
    return value


def configure(config, path, api):
    return federation.configure(config, path, api, "swedencentral", EXPIRY, REPOSITORY)


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
    state = configure(config, state_path, api)
    assert state["phase"] == "ConfiguredOidcUnverified"
    assert state["principalId"] == PRINCIPAL
    assert len(api.writes) == 4
    configure(config, state_path, api)
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
        configure(config, state_path, api)


def test_unknown_put_never_replayed(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    api.uncertain = True
    with pytest.raises(TimeoutError):
        configure(config, state_path, api)
    with pytest.raises(RuntimeError, match="never replay"):
        configure(config, state_path, api)
    with pytest.raises(RuntimeError, match="no absence"):
        federation.remove(config, state_path, api)
    assert len(api.writes) == 1


def test_lost_successful_put_reconciles_get_only(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    api.lost = True
    with pytest.raises(TimeoutError):
        configure(config, state_path, api)
    configure(config, state_path, api)
    assert len(api.writes) == 4


def test_foreign_collision_and_role_drift_block_all_deletion(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    specs = federation.specifications(config, "swedencentral", EXPIRY)
    api.assets[federation.resource_path(specs[2])] = {"id": specs[2]["id"]}
    with pytest.raises(ValueError, match="collision"):
        configure(config, state_path, api)
    assert not api.writes
    assert not state_path.exists()
    api.assets.clear()
    state = configure(config, state_path, api)
    role = api.assets[federation.resource_path(state["assets"][2])]
    role["properties"]["permissions"][0]["dataActions"].append(
        "Microsoft.App/agents/threads/approve/action",
    )
    with pytest.raises(ValueError, match="drift"):
        federation.remove(config, state_path, api)
    assert len(api.writes) == 4


def test_manifest_path_change_and_identity_replacement_rejected(config, tmp_path):
    api, state_path = Arm(), tmp_path / "federation.json"
    state = configure(config, state_path, api)
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
    state = configure(config, state_path, api)
    saved = state_path.read_bytes()
    identity = api.assets[federation.resource_path(state["assets"][0])]
    identity["properties"][field] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    with pytest.raises(ValueError, match="changed"):
        if operation == "configure":
            configure(config, state_path, api)
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
        configure(config, state_path, api)
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
        configure(config, state_path, api)
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


def test_runtime_confirmed_immutable_subject_and_unchanged_native_specs(config):
    before = copy.deepcopy(config)
    config["oidc"]["subject"] = SUBJECT
    specs = federation.specifications(config, "swedencentral", EXPIRY)
    assert specs[1]["body"]["properties"]["subject"] == SUBJECT
    assert federation.repository_binding(config, REPOSITORY) == REPOSITORY
    old_specs = federation.specifications(before, "swedencentral", EXPIRY)
    old_specs[1]["body"]["properties"]["subject"] = SUBJECT
    assert specs == old_specs
    for factory in (intake.knowledge_specs, intake.investigator_spec, intake.trigger_spec):
        assert factory(config) == factory(before)


@pytest.mark.parametrize("subject", [
    SUBJECT.replace("rutgerpels@", "foreign@"),
    SUBJECT.replace("121695274", "41898282"),
    SUBJECT.replace("retailtx-agentic-ops-demo@", "foreign@"),
    SUBJECT.replace("1399486000", "1"),
    SUBJECT.replace("sre-github-intake", "production"),
    SUBJECT + ":job_workflow_ref:other",
    SUBJECT.replace("121695274", "0121695274"),
    "repo:*:environment:sre-github-intake",
    None,
])
def test_unverified_subject_shape_rejected(config, subject):
    config["oidc"]["subject"] = subject
    with pytest.raises(ValueError, match="subject"):
        federation.specifications(config, "swedencentral", EXPIRY)


@pytest.mark.parametrize("owner_id", [True, "121695274", 0, -1])
def test_owner_id_requires_positive_numeric_api_identity(config, owner_id):
    config["oidc"]["repositoryOwnerId"] = owner_id
    with pytest.raises(ValueError, match="positive numeric"):
        federation.specifications(config, "swedencentral", EXPIRY)


@pytest.mark.parametrize("field,value", [
    ("full_name", "foreign/retailtx-agentic-ops-demo"),
    ("id", 1), ("login", "foreign"), ("owner_id", 41898282),
])
def test_repository_api_binding_rejects_names_ids_and_actor_confusion(
    config, tmp_path, field, value,
):
    evidence = copy.deepcopy(REPOSITORY)
    if field in ("login", "owner_id"):
        evidence["owner"]["login" if field == "login" else "id"] = value
    else:
        evidence[field] = value
    config["oidc"]["subject"] = SUBJECT
    api = Arm()
    with pytest.raises(ValueError, match="Repository API"):
        federation.configure(
            config, tmp_path / "state.json", api, "swedencentral", EXPIRY, evidence,
        )
    assert not api.writes


def prepared_transition(config, path, api, *, legacy=True):
    before = configure(config, path, api)
    if legacy:
        config.pop("oidc")
        before["configHash"] = federation.binding_hash(config)
        federation.persist(path, before)
    target = copy.deepcopy(config)
    target["oidc"] = {"repositoryOwnerId": 121695274, "subject": SUBJECT}
    return before, target


@pytest.mark.parametrize("legacy", [False, True])
def test_explicit_pure_plan_subject_only_put_and_inverse(config, tmp_path, legacy):
    api, path = Arm(), tmp_path / "federation.json"
    before, target = prepared_transition(config, path, api, legacy=legacy)
    saved = path.read_bytes()
    plan = federation.subject_transition_spec(target, before, REPOSITORY)
    assert path.read_bytes() == saved and len(api.writes) == 4
    expected = copy.deepcopy(before)
    expected["assets"][1]["body"]["properties"]["subject"] = SUBJECT
    expected["configHash"] = federation.binding_hash(target)
    assert plan["after"] == expected
    assert plan["before"] == before
    assert all(before[key] == plan["after"][key] for key in (
        "clientId", "principalId", "tenantId", "ownerToken",
    ))
    with pytest.raises(ValueError, match="Foreign/changed"):
        federation.check(target, path, api)
    state = federation.transition_subject(target, path, api, REPOSITORY)
    assert api.writes[4:] == [("PUT", federation.resource_path(before["assets"][1]))]
    assert state["subjectTransition"]["phase"] == "Verified"
    assert state["subjectTransition"]["before"] == before
    assert len(state["subjectTransition"]["beforeReadback"]) == 4
    assert len(state["subjectTransition"]["readback"]) == 4
    federation.check(target, path, api)
    federation.transition_subject(target, path, api, REPOSITORY)
    assert len(api.writes) == 5
    with pytest.raises(ValueError, match="Foreign/changed"):
        federation.remove(config, path, api)
    federation.remove(target, path, api)
    assert not api.assets
    assert len(api.writes) == 9


def test_legacy_manifest_is_not_silently_migrated_and_remains_removable(config, tmp_path):
    api, path = Arm(), tmp_path / "federation.json"
    before, target = prepared_transition(config, path, api)
    assert before["assets"][1]["body"]["properties"]["subject"] != SUBJECT
    federation.check(config, path, api)
    configure(config, path, api)
    with pytest.raises(ValueError, match="Foreign/changed"):
        configure(target, path, api)
    assert len(api.writes) == 4
    federation.remove(config, path, api)
    assert not api.assets


def test_new_setup_requires_explicit_subject_and_owner_api_evidence(config, tmp_path):
    api, path = Arm(), tmp_path / "federation.json"
    with pytest.raises(ValueError, match="JSON object"):
        federation.configure(config, path, api, "swedencentral", EXPIRY)
    config.pop("oidc")
    with pytest.raises(ValueError, match="Explicit verified"):
        configure(config, path, api)
    assert not api.writes and not path.exists()


@pytest.mark.parametrize("field", ["clientId", "principalId", "tenantId", "subject", "role"])
def test_transition_live_drift_blocks_put(config, tmp_path, field):
    api, path = Arm(), tmp_path / "federation.json"
    before, target = prepared_transition(config, path, api)
    if field in ("clientId", "principalId", "tenantId"):
        live = api.assets[federation.resource_path(before["assets"][0])]
        live["properties"][field] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    elif field == "subject":
        api.assets[federation.resource_path(before["assets"][1])]["properties"][field] = "foreign"
    else:
        api.assets[federation.resource_path(before["assets"][2])]["properties"]["permissions"] = []
    saved = path.read_bytes()
    with pytest.raises(ValueError):
        federation.transition_subject(target, path, api, REPOSITORY)
    assert len(api.writes) == 4 and path.read_bytes() == saved


def test_transition_unknown_put_never_replays_or_allows_teardown(config, tmp_path):
    api, path = Arm(), tmp_path / "federation.json"
    _, target = prepared_transition(config, path, api)
    api.uncertain = True
    with pytest.raises(TimeoutError):
        federation.transition_subject(target, path, api, REPOSITORY)
    state = json.loads(path.read_text())
    assert state["phase"] == "SubjectTransitionRequested"
    assert state["subjectTransition"]["phase"] == "Requested"
    with pytest.raises(ValueError, match="drift"):
        federation.transition_subject(target, path, api, REPOSITORY)
    for current in (config, target):
        with pytest.raises(ValueError, match="transition uncertain"):
            federation.remove(current, path, api)
    assert len(api.writes) == 5


def test_transition_lost_response_and_readback_reconcile_get_only(config, tmp_path):
    api, path = Arm(), tmp_path / "federation.json"
    _, target = prepared_transition(config, path, api)
    api.lost = True
    with pytest.raises(TimeoutError):
        federation.transition_subject(target, path, api, REPOSITORY)
    saved = path.read_bytes()
    wrong = copy.deepcopy(REPOSITORY)
    wrong["owner"]["id"] = 41898282
    with pytest.raises(ValueError, match="Repository API"):
        federation.transition_subject(target, path, api, wrong)
    assert path.read_bytes() == saved
    federation.transition_subject(target, path, api, REPOSITORY)
    assert len(api.writes) == 5
    federation.check(target, path, api)


def test_transition_intent_must_be_durable_before_put(config, tmp_path, monkeypatch):
    api, path = Arm(), tmp_path / "federation.json"
    _, target = prepared_transition(config, path, api)
    saved = path.read_bytes()

    def fail_persist(*args):
        raise OSError("Disk unavailable")

    monkeypatch.setattr(federation, "persist", fail_persist)
    with pytest.raises(OSError):
        federation.transition_subject(target, path, api, REPOSITORY)
    assert len(api.writes) == 4 and path.read_bytes() == saved


def test_transition_rejects_other_readback_changes_and_old_subject_teardown(config, tmp_path):
    api, path = Arm(), tmp_path / "federation.json"
    before, target = prepared_transition(config, path, api)
    api.lost = True
    with pytest.raises(TimeoutError):
        federation.transition_subject(target, path, api, REPOSITORY)
    fic = api.assets[federation.resource_path(before["assets"][1])]
    fic["properties"]["additionalField"] = "unexpected"
    with pytest.raises(ValueError, match="other ARM fields"):
        federation.transition_subject(target, path, api, REPOSITORY)
    del fic["properties"]["additionalField"]
    federation.transition_subject(target, path, api, REPOSITORY)
    fic["properties"]["subject"] = before["assets"][1]["body"]["properties"]["subject"]
    with pytest.raises(ValueError, match="drift"):
        federation.remove(target, path, api)
    assert len(api.writes) == 5


@pytest.mark.parametrize("field", ["ownerToken", "environment", "repositoryId"])
def test_transition_rejects_changed_non_subject_configuration(config, tmp_path, field):
    api, path = Arm(), tmp_path / "federation.json"
    before, target = prepared_transition(config, path, api)
    if field == "ownerToken":
        target["binding"][field] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    elif field == "repositoryId":
        target[field] = 1
    else:
        target[field] = "demo02"
    with pytest.raises(ValueError):
        federation.subject_transition_spec(target, before, REPOSITORY)
    assert len(api.writes) == 4


def test_transition_http_failure_is_uncertain_and_never_replayed(config, tmp_path, monkeypatch):
    api, path = Arm(), tmp_path / "federation.json"
    _, target = prepared_transition(config, path, api)
    original = api.request

    def rejected(method, resource, body=None, **kwargs):
        if method == "PUT":
            api.writes.append((method, resource))
            return 503, None
        return original(method, resource, body, **kwargs)

    monkeypatch.setattr(api, "request", rejected)
    with pytest.raises(RuntimeError, match="uncertain"):
        federation.transition_subject(target, path, api, REPOSITORY)
    with pytest.raises(ValueError, match="drift"):
        federation.transition_subject(target, path, api, REPOSITORY)
    assert len(api.writes) == 5
    assert json.loads(path.read_text())["phase"] == "SubjectTransitionRequested"


def test_transition_completion_persist_failure_reconciles_without_put(
    config, tmp_path, monkeypatch,
):
    api, path = Arm(), tmp_path / "federation.json"
    _, target = prepared_transition(config, path, api)
    original = federation.persist
    calls = 0

    def fail_completion(destination, state):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("Completion not durable")
        original(destination, state)

    monkeypatch.setattr(federation, "persist", fail_completion)
    with pytest.raises(OSError):
        federation.transition_subject(target, path, api, REPOSITORY)
    assert json.loads(path.read_text())["phase"] == "SubjectTransitionRequested"
    federation.transition_subject(target, path, api, REPOSITORY)
    assert len(api.writes) == 5
    federation.check(target, path, api)


def test_transition_spec_cli_is_pure_and_exposes_exact_put(config, tmp_path, monkeypatch, capsys):
    api, path = Arm(), tmp_path / "federation.json"
    before, target = prepared_transition(config, path, api)
    config_path, evidence_path = tmp_path / "target.json", tmp_path / "repository.json"
    config_path.write_text(json.dumps(target))
    evidence_path.write_text(json.dumps(REPOSITORY))
    saved = path.read_bytes()
    monkeypatch.setattr("sys.argv", [
        "federation", "transition-spec", "--config", str(config_path), "--state", str(path),
        "--repository-evidence", str(evidence_path),
    ])

    def no_auth(*args):
        pytest.fail("Pure transition spec must not authenticate")

    monkeypatch.setattr(federation, "arm_token", no_auth)
    federation.main()
    plan = json.loads(capsys.readouterr().out)
    assert plan["before"] == before
    assert plan["after"]["assets"][1]["body"]["properties"]["subject"] == SUBJECT
    assert plan["after"]["assets"][1]["id"] == before["assets"][1]["id"]
    assert len(api.writes) == 4 and path.read_bytes() == saved
