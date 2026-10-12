"""All provider effects mocked. Deliberately no live authentication or application calls."""

import base64
import copy
import io
import json
import subprocess
import sys
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

from scripts.github import intake
from scripts.github import read_probe as probe
from scripts.github import read_probe_lifecycle as lifecycle

REAL_CAPTURE = probe.capture


@pytest.fixture(autouse=True)
def forbid_live(monkeypatch):
    def reject(*args, **kwargs):
        raise AssertionError("Live API/subprocess effect forbidden in mocked tests")

    monkeypatch.setattr(intake.Api, "request", reject)
    monkeypatch.setattr(probe, "capture", reject)
    monkeypatch.setattr(lifecycle, "capture", reject)


@pytest.fixture
def config():
    value = json.loads(
        (intake.ROOT / "profiles" / "github" / "read-probe.example.json").read_text()
    )
    value["expiresAt"] = (datetime.now(UTC) + timedelta(hours=1)).isoformat()
    return value


@pytest.fixture
def identities(config):
    return {
        caller: {
            "clientId": f"{index}3333333-3333-4333-8333-333333333333",
            "principalId": f"{index}4444444-4444-4444-8444-444444444444",
            "tenantId": config["tenantId"],
        }
        for index, caller in enumerate(probe.CALLERS, start=1)
    }


@pytest.fixture
def snapshot(config, identities):
    return probe.runtime_snapshot(config, identities, datetime.now(UTC).isoformat())


def jwt(value):
    encoded = base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return "header." + encoded + ".signature"


def access(config, identities, caller):
    now = int(datetime.now(UTC).timestamp())
    return {
        "aud": config["native"]["tokenAudience"], "tid": config["tenantId"],
        "oid": identities[caller]["principalId"], "appid": identities[caller]["clientId"],
        "iss": f"https://sts.windows.net/{config['tenantId']}/", "nbf": now - 10,
        "exp": now + 3600,
    }


def investigator(config):
    value = intake.investigator_spec(config["native"])
    for field in (
        "mcpTools", "commonTools", "agentsAsTools", "permissions", "connectors", "hooks",
        "commonPrompts", "criticPromptPath", "instructionsOverride", "userPromptOverride",
        "handoffPromptOverride",
    ):
        value["properties"][field] = None
    return value


def trigger(config):
    return {
        **intake.trigger_spec(config["native"]), "id": config["native"]["triggerId"],
        "triggerEnabled": False,
    }


def admit(monkeypatch, snapshot):
    native = snapshot["config"]["native"]
    for key, value in {
        "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REF": "refs/heads/main", "GITHUB_REF_TYPE": "branch",
        "GITHUB_REPOSITORY": native["repository"],
        "GITHUB_REPOSITORY_ID": str(native["repositoryId"]), "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_SHA": "a" * 40, probe.SLOTS[2]: snapshot["config"]["tenantId"],
        probe.SLOTS[0]: snapshot["identities"]["baseline"]["clientId"],
        probe.SLOTS[1]: snapshot["identities"]["candidate"]["clientId"],
    }.items():
        monkeypatch.setenv(key, value)


def test_pure_exact_roles_and_independent_names(config, identities):
    assets = probe.bound_assets(config, identities)
    assert len(assets) == 8
    baseline, candidate = assets[2], assets[6]
    base = baseline["body"]["properties"]["permissions"][0]
    cand = candidate["body"]["properties"]["permissions"][0]
    assert base == {
        "actions": ["Microsoft.App/agents/read"], "notActions": [],
        "dataActions": [probe.CONFIGURATION_READ], "notDataActions": [],
    }
    assert cand == {**base, "dataActions": [probe.CONFIGURATION_READ, probe.CANDIDATE_READ]}
    assert assets[3]["id"].startswith(config["native"]["binding"]["agentId"] + "/providers/")
    assert assets[7]["body"]["properties"]["principalId"] == identities["candidate"]["principalId"]
    assert assets[0]["id"] != assets[4]["id"]
    assert all("github-intake" not in item["id"] for item in assets)
    assert assets[1]["body"]["properties"]["subject"] == config["oidcSubject"]
    assert assets[5]["body"]["properties"]["subject"] == config["oidcSubject"]
    assert "threads/" not in json.dumps(assets)
    assert all("*" not in json.dumps(item["body"]) for item in assets)


def test_snapshot_rejects_role_delta_and_caller_replacement(snapshot):
    probe.validate_snapshot(snapshot, datetime.now(UTC))
    snapshot["assets"][6]["body"]["properties"]["permissions"][0]["dataActions"].append(
        "Microsoft.App/agents/threads/write",
    )
    with pytest.raises(ValueError):
        probe.validate_snapshot(snapshot, datetime.now(UTC))


def test_snapshot_rejects_recorded_caller_replacement(snapshot):
    snapshot["identities"]["candidate"]["principalId"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    with pytest.raises(ValueError):
        probe.validate_snapshot(snapshot, datetime.now(UTC))


@pytest.mark.parametrize("field", ["clientId", "principalId"])
def test_shared_identity_forbidden(config, identities, field):
    identities["candidate"][field] = identities["baseline"][field]
    with pytest.raises(ValueError, match="share"):
        probe.bound_assets(config, identities)


@pytest.mark.parametrize("change", ["query", "host", "path", "trigger", "owner", "subject"])
def test_configuration_route_and_owner_bounds(config, change):
    if change == "query":
        config["native"]["endpoint"] += "?arbitrary=1"
    elif change == "host":
        config["native"]["endpoint"] = "https://attacker.example"
    elif change == "path":
        config["native"]["endpoint"] += "/api/v1/execute"
    elif change == "trigger":
        config["native"]["triggerId"] = "../execute?mode=write"
    elif change == "owner":
        config["ownerToken"] = config["native"]["binding"]["ownerToken"]
    else:
        config["oidcSubject"] += ":ref:refs/heads/feature"
    with pytest.raises(ValueError):
        probe.validate(config)


def test_only_two_native_get_routes_are_exposed(config, monkeypatch):
    calls = []

    class Api:
        def __init__(self, origin, token):
            assert origin == config["native"]["endpoint"]
            assert token == "private-token"

        def request(self, method, path):
            calls.append((method, path))
            return 403, None

    monkeypatch.setattr(probe, "Api", Api)
    reads = probe.NativeReads(config, "private-token")
    config["native"]["triggerId"] = "changed-after-snapshot"
    reads.investigator()
    reads.trigger()
    assert calls == [
        ("GET", "/api/v2/extendedAgent/agents/retailtx-github-demo01-investigator"),
        ("GET", "/api/v1/httptriggers/configure-owned-trigger"),
    ]
    assert not hasattr(reads, "request") and not hasattr(reads, "get")
    with pytest.raises(TypeError):
        reads.trigger("execute")


class Reads:
    def __init__(self, config, statuses=(403, 403)):
        self.config, self.statuses = config, iter(statuses)
        self.calls = []

    def investigator(self):
        self.calls.append("investigator")
        return 200, investigator(self.config)

    def trigger(self):
        self.calls.append("trigger")
        status = next(self.statuses)
        return status, trigger(self.config) if status == 200 else None


@pytest.mark.parametrize("status", [200, 403])
def test_repeated_route_contract_reads(config, status):
    reads = Reads(config, (status, status))
    assert probe.observe(config, "candidate", reads) == status
    assert reads.calls == ["investigator", "trigger", "investigator", "trigger"]


@pytest.mark.parametrize("statuses", [(200, 403), (403, 200), (401, 401), (429, 429),
                                     (404, 404), (500, 500), ("200", "200"), (True, True)])
def test_other_or_unstable_statuses_are_inconclusive(config, statuses):
    with pytest.raises(probe.Rejected):
        probe.observe(config, "candidate", Reads(config, statuses))


@pytest.mark.parametrize("field", ["id", "agent", "agentMode", "agentPrompt", "triggerEnabled"])
def test_successful_trigger_requires_exact_disabled_contract(config, field):
    value = trigger(config)
    value[field] = True if field == "triggerEnabled" else "foreign"
    with pytest.raises(ValueError):
        probe.trigger_contract(config, value)


@pytest.mark.parametrize("field", ["tools", "handoffs", "enableSkills", "mcpTools", "permissions"])
def test_extra_tools_and_config_drift_denied(config, field):
    value = investigator(config)
    value["properties"][field] = ["write-tool"]
    with pytest.raises(ValueError):
        probe.investigator_contract(config, value)


@pytest.mark.parametrize("pair,code,exit_code", [
    ((403, 200), probe.Code.DIFFERENCE, 0), ((200, 200), probe.Code.EQUAL, 2),
    ((403, 403), probe.Code.EQUAL, 2), ((200, 403), probe.Code.COMPARISON, 2),
    ((401, 200), probe.Code.COMPARISON, 2), ((429, 200), probe.Code.COMPARISON, 2),
    (("403", 200), probe.Code.COMPARISON, 2),
])
def test_comparison_is_not_fallback_success(pair, code, exit_code):
    assert probe.compare(*pair) == (code, exit_code)


@pytest.mark.parametrize("field", ["aud", "tid", "oid", "appid", "iss", "exp", "nbf", "scp"])
def test_access_identity_sanity_checks(config, identities, field):
    value = access(config, identities, "baseline")
    value[field] = 0 if field == "exp" else (
        int(datetime.now(UTC).timestamp()) + 1000 if field == "nbf" else "wrong-private-field"
    )
    with pytest.raises(ValueError):
        probe.access_claims(jwt(value), config, "baseline", identities, datetime.now(UTC))


def test_disabled_and_stale_admission_precede_authentication(snapshot, monkeypatch):
    monkeypatch.setattr(probe, "oidc_token", lambda *args: pytest.fail("No authentication allowed"))
    with pytest.raises(probe.Rejected) as failure:
        probe.run(snapshot)
    assert failure.value.code is probe.Code.DISABLED
    snapshot["checkedAt"] = (datetime.now(UTC) - timedelta(minutes=16)).isoformat()
    with pytest.raises(probe.Rejected) as failure:
        probe.run(snapshot)
    assert failure.value.code is probe.Code.ATTESTATION


@pytest.mark.parametrize("key,value", [
    ("GITHUB_REF", "refs/heads/unreviewed"), ("GITHUB_REF_TYPE", "tag"),
    ("GITHUB_RUN_ATTEMPT", "2"), ("GITHUB_EVENT_NAME", "issues"),
    ("GITHUB_REPOSITORY_ID", "9"), (probe.SLOTS[0], "wrong-caller"),
])
def test_main_manual_identity_admission(snapshot, monkeypatch, key, value):
    admit(monkeypatch, snapshot)
    monkeypatch.setenv(key, value)
    with pytest.raises(probe.Rejected):
        probe.admission(snapshot)


def test_oidc_claims_and_fixed_endpoint(config, monkeypatch):
    native = config["native"]
    epoch = int(datetime.now(UTC).timestamp())
    value = {
        "iss": probe.ISSUER, "aud": probe.EXCHANGE_AUDIENCE, "sub": config["oidcSubject"],
        "repository": native["repository"], "repository_id": str(native["repositoryId"]),
        "repository_owner_id": str(native["oidc"]["repositoryOwnerId"]),
        "ref": "refs/heads/main", "ref_type": "branch", "event_name": "workflow_dispatch",
        "environment": probe.ENVIRONMENT, "runner_environment": "github-hosted",
        "workflow_ref": f"{native['repository']}/{probe.WORKFLOW}@refs/heads/main",
        "workflow_sha": "a" * 40, "run_attempt": "1", "nbf": epoch - 10, "exp": epoch + 1000,
    }
    calls = []

    class Api:
        def __init__(self, origin, token):
            assert origin == "https://pipelines.actions.githubusercontent.com"
            assert token == "request-token"

        def get(self, path):
            calls.append(path)
            return {"value": jwt(value)}

    monkeypatch.setattr(probe, "Api", Api)
    monkeypatch.setenv("GITHUB_SHA", "a" * 40)
    monkeypatch.setenv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "request-token")
    monkeypatch.setenv(
        "ACTIONS_ID_TOKEN_REQUEST_URL",
        "https://pipelines.actions.githubusercontent.com/_apis/token?api-version=2.0",
    )
    assert probe.oidc_token(config, datetime.now(UTC)) == jwt(value)
    assert parse_qs(urlsplit(calls[0]).query)["audience"] == [probe.EXCHANGE_AUDIENCE]
    value["ref"] = "refs/heads/foreign"
    with pytest.raises(ValueError, match="claims"):
        probe.oidc_token(config, datetime.now(UTC))
    monkeypatch.setenv("ACTIONS_ID_TOKEN_REQUEST_URL", "https://attacker.example/token")
    with pytest.raises(ValueError, match="endpoint"):
        probe.oidc_token(config, datetime.now(UTC))


def test_runtime_caches_are_isolated_and_removed(snapshot, monkeypatch):
    snapshot["config"]["enabled"] = True
    snapshot["assets"] = probe.bound_assets(snapshot["config"], snapshot["identities"])
    admit(monkeypatch, snapshot)
    monkeypatch.setattr(probe, "oidc_token", lambda *args: "private-assertion")
    directories, calls = [], []

    def capture(arguments, *, env, **kwargs):
        directories.append(Path(env["AZURE_CONFIG_DIR"]))
        directories[-1].joinpath("private-cache").write_text("private")
        calls.append(arguments)
        assert env["AZURE_CORE_OUTPUT"] == "none"
        if arguments[1] == "login":
            assert "--federated-token" in arguments and "--allow-no-subscriptions" in arguments
            return ""
        caller = "baseline" if directories[-1].name == "baseline" else "candidate"
        return jwt(access(snapshot["config"], snapshot["identities"], caller))

    monkeypatch.setattr(probe, "capture", capture)
    monkeypatch.setattr(probe, "azure_cli_executable", lambda: "absolute-az")

    class Native:
        def __init__(self, config, token):
            self.reads = Reads(config, (403, 403) if "baseline" in str(
                directories[-1]) else (200, 200))

        def investigator(self):
            return self.reads.investigator()

        def trigger(self):
            return self.reads.trigger()

    monkeypatch.setattr(probe, "NativeReads", Native)
    assert probe.run(snapshot) == 0
    assert directories[0] == directories[1] and directories[2] == directories[3]
    assert directories[0] != directories[2]
    assert all(not directory.exists() for directory in directories)
    assert all(command[0] == "absolute-az" for command in calls)


def test_wrong_cached_principal_denied_and_cleaned(snapshot, monkeypatch):
    snapshot["config"]["enabled"] = True
    admit(monkeypatch, snapshot)
    monkeypatch.setattr(probe, "oidc_token", lambda *args: "private-assertion")
    directories = []

    def acquire(config, identities, caller, assertion, directory):
        directories.append(directory)
        directory.joinpath("cache").write_text("private")
        raise ValueError("private cached identity wrong")

    monkeypatch.setattr(probe, "acquire", acquire)
    with pytest.raises(probe.Rejected):
        probe.run(snapshot)
    assert all(not item.exists() for item in directories)


def test_public_failure_has_no_provider_data(monkeypatch, capsys):
    private = "private-url/private-id/token-private"
    monkeypatch.setenv(probe.SLOTS[3], json.dumps({"untrusted": private}))
    monkeypatch.delenv("GITHUB_ACTIONS", raising=False)
    monkeypatch.setattr(sys, "argv", ["read_probe", "run"])
    assert probe.main() == 2
    output = capsys.readouterr()
    assert private not in output.out + output.err
    assert output.err == ""
    assert output.out == (
        "read_probe;caller=none;stage=configuration;code=configuration_rejected;"
        "http_status=unknown\n"
    )


def test_individual_field_masks_escape_commands(monkeypatch, capsys):
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    probe.mask({"privateField": ["private-value", "value\n::error::injection", "percent%"]})
    assert capsys.readouterr().out.splitlines() == [
        "::add-mask::private-value",
        "::add-mask::value%0A::error::injection", "::add-mask::percent%25",
    ]


def test_private_masks_preserve_public_caller_and_status_markers(snapshot, monkeypatch, capsys):
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    probe.mask_snapshot(snapshot)
    output = capsys.readouterr().out
    assert "::add-mask::baseline\n" not in output
    assert "::add-mask::candidate\n" not in output
    assert "::add-mask::1\n" not in output
    assert "::add-mask::1399486000\n" in output
    for identity in snapshot["identities"].values():
        assert "::add-mask::" + identity["principalId"] in output


class CapturedProcess:
    def __init__(self, *, failed_stream=None, overflow=False, timeout=False):
        class FailedRead:
            def read(self, length):
                raise OSError("https://private-provider/private-token/private-id")

            def close(self):
                return None

        self.stdout = FailedRead() if failed_stream == "stdout" else io.BytesIO(
            b"x" * 131073 if overflow else b"private-token",
        )
        self.stderr = FailedRead() if failed_stream == "stderr" else io.BytesIO()
        self.stdin = io.BytesIO()
        self.returncode = 0
        self.killed, self.timeout, self.waits = False, timeout, 0

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def wait(self, timeout):
        self.waits += 1
        if self.timeout and self.waits == 1:
            self.returncode = None
            raise subprocess.TimeoutExpired("private-command", timeout)
        self.returncode = 0
        return 0

    def poll(self):
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = 0


@pytest.mark.parametrize("failure", ["stdout", "stderr", "overflow", "timeout"])
def test_real_capture_contains_read_errors_overflow_and_timeout(monkeypatch, capsys, failure):
    process = CapturedProcess(
        failed_stream=failure if failure in ("stdout", "stderr") else None,
        overflow=failure == "overflow", timeout=failure == "timeout",
    )
    monkeypatch.setattr(probe.subprocess, "Popen", lambda *args, **kwargs: process)
    with pytest.raises((RuntimeError, subprocess.TimeoutExpired)):
        REAL_CAPTURE(["fake-only"], env={"AZURE_CONFIG_DIR": "isolated"})
    output = capsys.readouterr()
    assert output.out == output.err == ""
    assert process.killed


def test_real_capture_failure_public_entry_has_no_traceback(snapshot, monkeypatch, capsys):
    snapshot["config"]["enabled"] = True
    admit(monkeypatch, snapshot)
    monkeypatch.setenv(probe.SLOTS[3], json.dumps(snapshot))
    monkeypatch.setattr(probe, "capture", REAL_CAPTURE)
    monkeypatch.setattr(probe, "oidc_token", lambda *args: "assertion-private")
    monkeypatch.setattr(probe, "azure_cli_executable", lambda: "fake-az")
    monkeypatch.setattr(
        probe.subprocess, "Popen",
        lambda *args, **kwargs: CapturedProcess(failed_stream="stderr"),
    )
    monkeypatch.setattr(sys, "argv", ["read_probe", "run"])
    assert probe.main() == 2
    output = capsys.readouterr()
    markers = [line for line in output.out.splitlines() if not line.startswith("::add-mask::")]
    assert output.err == ""
    assert markers == [
        "read_probe;caller=none;stage=authentication;code=acquisition_failed;http_status=unknown",
    ]
    assert "private-provider" not in output.out and "Traceback" not in output.out


def test_private_stdin_cannot_bypass_subprocess_timeout(monkeypatch, capsys):
    process = CapturedProcess(timeout=True)

    class Stdin:
        def write(self, value):
            pytest.fail("Never create a pipe feeder")

    process.stdin = Stdin()

    def launch(*args, **kwargs):
        assert kwargs["stdin"].read() == b"x" * 65536
        assert kwargs["bufsize"] == 0
        return process

    monkeypatch.setattr(probe.subprocess, "Popen", launch)
    monkeypatch.setattr(
        CapturedProcess, "__exit__", lambda *args: pytest.fail("No buffered Popen context cleanup"),
    )
    with pytest.raises(subprocess.TimeoutExpired):
        REAL_CAPTURE(["fake-only"], input_text="x" * 65536)
    assert process.killed
    assert capsys.readouterr().err == ""


def test_oversized_private_stdin_rejected_before_launch(monkeypatch):
    monkeypatch.setattr(
        probe.subprocess, "Popen",
        lambda *args, **kwargs: pytest.fail("No launch for invalid input"),
    )
    with pytest.raises(ValueError, match="Bounded"):
        REAL_CAPTURE(["fake-only"], input_text="x" * 65537)


def test_inherited_output_handle_cannot_block_cleanup(monkeypatch, capsys):
    released = threading.Event()
    process = CapturedProcess()

    class RawOutput:
        def read(self, count):
            released.wait(timeout=5)
            return b""

        def close(self):
            released.set()

    process.stderr = RawOutput()

    def launch(*args, **kwargs):
        assert kwargs["bufsize"] == 0
        return process

    monkeypatch.setattr(probe.subprocess, "Popen", launch)
    monkeypatch.setattr(
        CapturedProcess, "__exit__", lambda *args: pytest.fail("No buffered Popen context cleanup"),
    )
    with pytest.raises(RuntimeError, match="uncertain"):
        REAL_CAPTURE(["fake-only"], input_text="private-input")
    assert released.is_set()
    assert capsys.readouterr().err == ""


class Arm:
    def __init__(self, config, identities):
        self.config, self.identities = config, identities
        self.assets, self.writes = {}, []
        self.lose_put = self.unknown_put = self.lose_delete = self.pending_delete = False

    def request(self, method, path, body=None):
        if method == "GET":
            query = parse_qs(urlsplit(path).query)
            if "$filter" in query:
                principal = query["$filter"][0].split("'")[1]
                return 200, {"value": [copy.deepcopy(value) for value in self.assets.values()
                                      if value.get("properties", {}).get("principalId") == principal
                                      and "/roleAssignments/" in value["id"]]}
            if path.split("?")[0].endswith("/federatedIdentityCredentials"):
                return 200, {"value": [copy.deepcopy(value) for value in self.assets.values()
                                      if value["id"].startswith(path.split("?")[0] + "/")]}
            return (200, copy.deepcopy(self.assets[path])) if path in self.assets else (404, None)
        self.writes.append((method, path))
        if method == "DELETE":
            if self.pending_delete:
                return 202, None
            del self.assets[path]
            if self.lose_delete:
                self.lose_delete = False
                raise TimeoutError("private lost delete")
            return 204, None
        if self.unknown_put:
            raise TimeoutError("private create uncertain")
        value = {"id": path.split("?")[0], **copy.deepcopy(body)}
        if "userAssignedIdentities/" in path and "/federatedIdentityCredentials/" not in path:
            caller = "baseline" if "-baseline?" in path else "candidate"
            value["properties"] = copy.deepcopy(self.identities[caller])
        self.assets[path] = value
        if self.lose_put:
            self.lose_put = False
            raise TimeoutError("private lost put")
        return 201, copy.deepcopy(value)

    def get(self, path):
        status, value = self.request("GET", path)
        assert status == 200
        return value


class GitHub:
    def __init__(self, config):
        self.config = config
        self.env = None
        self.policies, self.secrets, self.variables, self.writes = [], {}, [], []
        self.lose_put = self.lose_policy = self.lose_delete = False

    def request(self, method, path, body=None):
        env_path = lifecycle.environment_path(self.config)
        if method == "GET":
            native = self.config["native"]
            if path == f"/repos/{native['repository']}":
                return 200, {
                    "id": native["repositoryId"], "full_name": native["repository"],
                    "owner": {"login": native["repository"].split("/")[0],
                              "id": native["oidc"]["repositoryOwnerId"]},
                    "default_branch": "main", "private": False,
                }
            if path == env_path:
                return (200, copy.deepcopy(self.env)) if self.env is not None else (404, None)
            if path.endswith("/deployment-branch-policies?per_page=100"):
                return 200, {"total_count": len(self.policies),
                             "branch_policies": copy.deepcopy(self.policies)}
            if path.endswith("/secrets?per_page=100"):
                return 200, {"total_count": len(self.secrets),
                             "secrets": copy.deepcopy(list(self.secrets.values()))}
            if path.endswith("/variables?per_page=100"):
                return 200, {"total_count": len(self.variables), "variables": self.variables}
            name = path.rsplit("/", 1)[1]
            return (200, copy.deepcopy(self.secrets[name])) if name in self.secrets else (404, None)
        self.writes.append((method, path))
        if method == "DELETE":
            assert path == env_path
            self.env, self.policies, self.secrets = None, [], {}
            if self.lose_delete:
                self.lose_delete = False
                raise TimeoutError("private lost delete")
            return 204, None
        if method == "PUT":
            assert path == env_path and body == lifecycle.ENVIRONMENT_BODY
            self.env = {
                "name": probe.ENVIRONMENT, "id": 101, "node_id": "ENV_owned",
                "created_at": "2026-01-01T00:00:00Z", "protection_rules": [],
                "deployment_branch_policy": copy.deepcopy(body["deployment_branch_policy"]),
            }
            if self.lose_put:
                self.lose_put = False
                raise TimeoutError("private lost environment")
            return 200, copy.deepcopy(self.env)
        assert method == "POST" and body == lifecycle.BRANCH_POLICY
        self.policies = [{"id": 202, **copy.deepcopy(body)}]
        if self.lose_policy:
            self.lose_policy = False
            raise TimeoutError("private lost policy")
        return 200, self.policies[0]

    def get(self, path):
        status, value = self.request("GET", path)
        assert status == 200
        return value


@pytest.fixture
def providers(config, identities, tmp_path, monkeypatch):
    arm, github, path = Arm(config, identities), GitHub(config), tmp_path / "ownership.json"

    def set_secret(config, slot, value):
        github.writes.append(("SECRET", slot))
        github.secrets[slot] = {
            "name": slot, "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
        }

    monkeypatch.setattr(lifecycle, "set_secret", set_secret)
    return arm, github, path


def test_repeatable_owned_setup_check_and_inverse(config, providers):
    arm, github, path = providers
    state = lifecycle.configure(config, path, arm, github)
    assert state["phase"] == "ProvisioningCheckedNotPermissionAccepted"
    assert len(arm.writes) == 8 and len(github.writes) == 6
    lifecycle.configure(config, path, arm, github)
    lifecycle.check(config, path, arm, github)
    assert len(arm.writes) == 8 and len(github.writes) == 6
    lifecycle.remove(config, path, arm, github)
    assert [item[1] for item in arm.writes[8:]] == [
        lifecycle.resource_path(asset) for asset in reversed(state["assets"])
    ]
    assert json.loads(path.read_text())["phase"] == "Removed"
    assert not arm.assets and github.env is None
    lifecycle.remove(config, path, arm, github)
    assert len(arm.writes) == 16 and len(github.writes) == 7
    with pytest.raises(ValueError, match="recreation"):
        lifecycle.configure(config, path, arm, github)


@pytest.mark.parametrize("collision", ["role", "environment"])
def test_unowned_collisions_before_writes(config, providers, collision):
    arm, github, path = providers
    if collision == "role":
        asset = probe.specifications(config)[2]
        arm.assets[lifecycle.resource_path(asset)] = {"id": asset["id"]}
    else:
        github.env = {"id": 9}
    with pytest.raises(ValueError, match="collision"):
        lifecycle.configure(config, path, arm, github)
    assert not arm.writes and not github.writes and not path.exists()


@pytest.mark.parametrize("operation", ["configure", "check", "remove"])
@pytest.mark.parametrize("field", ["clientId", "principalId", "tenantId"])
def test_immutable_principal_replacement_blocks_every_surface(config, providers, operation, field):
    arm, github, path = providers
    state = lifecycle.configure(config, path, arm, github)
    identity = arm.assets[lifecycle.resource_path(state["assets"][0])]
    identity["properties"][field] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    before = path.read_bytes()
    with pytest.raises(ValueError):
        getattr(lifecycle, operation)(config, path, arm, github)
    assert len(arm.writes) == 8 and len(github.writes) == 6
    assert path.read_bytes() == before


@pytest.mark.parametrize("drift", ["role", "condition", "scope", "tag", "policy",
                                 "secret", "variable", "environment", "manifest"])
def test_all_inverse_guards_checked_before_first_delete(config, providers, drift):
    arm, github, path = providers
    state = lifecycle.configure(config, path, arm, github)
    if drift == "role":
        arm.assets[lifecycle.resource_path(state["assets"][2])]["properties"]["permissions"][0][
            "dataActions"].append("Microsoft.App/agents/threads/write")
    elif drift in ("condition", "scope"):
        arm.assets[lifecycle.resource_path(state["assets"][3])]["properties"][drift] = "foreign"
    elif drift == "tag":
        arm.assets[lifecycle.resource_path(state["assets"][0])]["tags"]["ownerToken"] = "foreign"
    elif drift == "policy":
        github.policies.append({"id": 303, "name": "*", "type": "tag"})
    elif drift == "secret":
        github.secrets["FOREIGN"] = {"name": "FOREIGN"}
    elif drift == "variable":
        github.variables.append({"name": "FOREIGN", "value": "private"})
    elif drift == "environment":
        github.env["id"] += 1
    else:
        state["assets"][0]["id"] += "-foreign"
        path.write_text(json.dumps(state))
    with pytest.raises(ValueError):
        lifecycle.remove(config, path, arm, github)
    assert len(arm.writes) == 8 and len(github.writes) == 6


def test_unknown_arm_create_is_not_replayed_or_absence(config, providers):
    arm, github, path = providers
    arm.unknown_put = True
    with pytest.raises(TimeoutError):
        lifecycle.configure(config, path, arm, github)
    for operation in (lifecycle.configure, lifecycle.remove):
        with pytest.raises(RuntimeError, match="uncertain"):
            operation(config, path, arm, github)
    assert len(arm.writes) == 1 and not github.writes


@pytest.mark.parametrize("lost", ["arm", "environment", "policy"])
def test_lost_successful_creates_reconcile_without_replay(config, providers, lost):
    arm, github, path = providers
    if lost == "arm":
        arm.lose_put = True
    elif lost == "environment":
        github.lose_put = True
    else:
        github.lose_policy = True
    with pytest.raises(TimeoutError):
        lifecycle.configure(config, path, arm, github)
    lifecycle.configure(config, path, arm, github)
    assert len(arm.writes) == 8 and len(github.writes) == 6


def test_unknown_secret_cannot_be_reconciled_as_value_success(config, providers, monkeypatch):
    arm, github, path = providers

    def uncertain(config, slot, value):
        github.writes.append(("SECRET", slot))
        github.secrets[slot] = {
            "name": slot, "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
        }
        raise TimeoutError("Lost secret acknowledgement")

    monkeypatch.setattr(lifecycle, "set_secret", uncertain)
    with pytest.raises(TimeoutError):
        lifecycle.configure(config, path, arm, github)
    with pytest.raises(RuntimeError, match="never replay"):
        lifecycle.configure(config, path, arm, github)
    with pytest.raises(RuntimeError, match="uncertainty"):
        lifecycle.check(config, path, arm, github)
    assert len(github.writes) == 3
    lifecycle.remove(config, path, arm, github)
    assert not arm.assets and github.env is None


@pytest.mark.parametrize("lost", ["arm", "environment"])
def test_lost_delete_reconciles_absence_without_replay(config, providers, lost):
    arm, github, path = providers
    lifecycle.configure(config, path, arm, github)
    if lost == "arm":
        arm.lose_delete = True
    else:
        github.lose_delete = True
    with pytest.raises(TimeoutError):
        lifecycle.remove(config, path, arm, github)
    lifecycle.remove(config, path, arm, github)
    assert len(arm.writes) == 16 and len(github.writes) == 7


def test_pending_delete_keeps_residual_without_replay(config, providers):
    arm, github, path = providers
    lifecycle.configure(config, path, arm, github)
    arm.pending_delete = True
    with pytest.raises(RuntimeError, match="residual"):
        lifecycle.remove(config, path, arm, github)
    count = len(arm.writes)
    with pytest.raises(RuntimeError, match="no replay"):
        lifecycle.remove(config, path, arm, github)
    assert len(arm.writes) == count
    assert json.loads(path.read_text())["phase"] == "Removing"


def test_additional_assignment_and_incomplete_inventory_deny_readiness(config, providers):
    arm, github, path = providers
    state = lifecycle.configure(config, path, arm, github)
    assignment = copy.deepcopy(arm.assets[lifecycle.resource_path(state["assets"][3])])
    assignment["id"] += "-extra"
    arm.assets["extra"] = assignment
    with pytest.raises(ValueError, match="Extra"):
        lifecycle.check(config, path, arm, github)


@pytest.mark.parametrize("addition", ["assignment", "fic"])
def test_foreign_arm_children_block_teardown_before_every_delete(config, providers, addition):
    arm, github, path = providers
    state = lifecycle.configure(config, path, arm, github)
    index = 3 if addition == "assignment" else 1
    foreign = copy.deepcopy(arm.assets[lifecycle.resource_path(state["assets"][index])])
    foreign["id"] += "-foreign"
    arm.assets["foreign"] = foreign
    with pytest.raises(ValueError, match="Foreign"):
        lifecycle.remove(config, path, arm, github)
    assert len(arm.writes) == 8 and len(github.writes) == 6
    assert github.env is not None and "foreign" in arm.assets


def test_partial_create_teardown_allows_not_yet_created_owned_children(config, providers):
    arm, github, path = providers
    arm.lose_put = True
    with pytest.raises(TimeoutError):
        lifecycle.configure(config, path, arm, github)
    lifecycle.remove(config, path, arm, github)
    assert len(arm.writes) == 2 and not github.writes
    assert json.loads(path.read_text())["phase"] == "Removed"


@pytest.mark.parametrize("body", [
    {"value": [], "nextLink": "private-next-page"},
    {"value": [], "total_count": 1},
    {"value": [None]},
    {"value": [{}] * 101},
])
def test_incomplete_or_malformed_inventories_are_not_complete(body):
    class Api:
        def get(self, path):
            return body

    with pytest.raises(ValueError):
        lifecycle.list_values(Api(), "/fixed-inventory", "value")


def test_failed_durable_create_intent_prevents_write(config, providers, monkeypatch):
    arm, github, path = providers
    persist = lifecycle.persist

    def fail_intent(path, state):
        if state["assets"][0].get("phase") == "CreateRequested":
            raise OSError("Private journal durability failure")
        persist(path, state)

    monkeypatch.setattr(lifecycle, "persist", fail_intent)
    with pytest.raises(OSError):
        lifecycle.configure(config, path, arm, github)
    assert not arm.writes and not github.writes


def test_failed_durable_secret_ack_never_replays(config, providers, monkeypatch):
    arm, github, path = providers
    persist = lifecycle.persist

    def fail_ack(path, state):
        if state["github"]["secrets"][probe.SLOTS[0]].get("phase") == "Acknowledged":
            raise OSError("Private journal acknowledgment failure")
        persist(path, state)

    monkeypatch.setattr(lifecycle, "persist", fail_ack)
    with pytest.raises(OSError):
        lifecycle.configure(config, path, arm, github)
    assert json.loads(path.read_text())["github"]["secrets"][probe.SLOTS[0]][
        "phase"] == "WriteRequested"
    monkeypatch.setattr(lifecycle, "persist", persist)
    with pytest.raises(RuntimeError, match="never replay"):
        lifecycle.configure(config, path, arm, github)
    assert len(github.writes) == 3


def test_live_gate_blocks_lifecycle_before_writes(config, providers, monkeypatch):
    arm, github, path = providers
    original = github.request

    def request(method, route, body=None):
        if route.endswith("/actions/variables/SRE_READ_PROBE_ENABLED"):
            return 200, {"name": "SRE_READ_PROBE_ENABLED", "value": "true"}
        return original(method, route, body)

    monkeypatch.setattr(github, "request", request)
    with pytest.raises(ValueError, match="gate"):
        lifecycle.configure(config, path, arm, github)
    assert not arm.writes and not github.writes


@pytest.mark.parametrize("kind", ["environment", "assignment"])
def test_failed_inverse_intent_persistence_prevents_corresponding_delete(
    config, providers, monkeypatch, kind,
):
    arm, github, path = providers
    lifecycle.configure(config, path, arm, github)
    persist = lifecycle.persist

    def fail_intent(path, state):
        blocked = state["github"].get("phase") == "DeleteRequested" if kind == "environment" else (
            any(asset.get("phase") == "DeleteRequested" for asset in state["assets"])
        )
        if blocked:
            raise OSError("Private inverse intent durability failure")
        persist(path, state)

    monkeypatch.setattr(lifecycle, "persist", fail_intent)
    with pytest.raises(OSError):
        lifecycle.remove(config, path, arm, github)
    assert len(arm.writes) == 8
    assert len(github.writes) == (6 if kind == "environment" else 7)


def test_pending_inverse_records_private_residual_kind(config, providers):
    arm, github, path = providers
    lifecycle.configure(config, path, arm, github)
    arm.pending_delete = True
    with pytest.raises(RuntimeError, match="residual"):
        lifecycle.remove(config, path, arm, github)
    state = json.loads(path.read_text())
    assert state["residualKinds"] == ["assignment"]
    assert state["phase"] == "Removing"


def test_lifecycle_public_boundary_no_traceback_or_private_diagnostics(
    config, providers, monkeypatch, capsys,
):
    _, _, path = providers
    config_path = path.with_name("config.json")
    config_path.write_text(json.dumps(config))
    monkeypatch.setattr(sys, "argv", [
        "lifecycle", "check", "--config", str(config_path), "--state", str(path),
    ])
    monkeypatch.delenv("GITHUB_ACTIONS", raising=False)

    def rejected(*args, **kwargs):
        raise RuntimeError("https://private-provider/error?secret=private-token")

    monkeypatch.setattr(lifecycle, "capture", rejected)
    assert lifecycle.main() == 2
    output = capsys.readouterr()
    assert output.err == ""
    assert "private" not in output.out and "https" not in output.out
    assert "code=operation_uncertain" in output.out


def test_workflow_manual_main_only_minimal_permissions_and_no_native_change():
    workflow = (intake.ROOT / probe.WORKFLOW).read_text()
    assert "workflow_dispatch:" in workflow
    assert "inputs:" not in workflow and "issues:" not in workflow
    assert "refs/heads/main" in workflow and "github.ref_type == 'branch'" in workflow
    assert "github.run_attempt == 1" in workflow
    assert "vars.SRE_READ_PROBE_ENABLED == 'true'" in workflow
    assert "environment: sre-read-probe" in workflow
    assert "contents: read" in workflow and "id-token: write" in workflow
    for absent in (
        "issues: write", "actions: write", "azure/login@", "upload-artifact", "GH_TOKEN",
    ):
        assert absent not in workflow
    assert "persist-credentials: false" in workflow
    assert "ref: ${{ github.sha }}" in workflow
    assert "scripts.github.read_probe run" in workflow
