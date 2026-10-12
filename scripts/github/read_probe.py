"""Isolated, GET-only A/B diagnostic. No native invocation or remediation."""

from __future__ import annotations

import argparse
import base64
import copy
import http.client
import json
import os
import re
import subprocess
import tempfile
import threading
import uuid
from contextlib import suppress
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit

from scripts.github.federation import AUTH_VERSION, IDENTITY_VERSION
from scripts.github.intake import (
    Api,
    assert_no_extra_tools,
    azure_cli_executable,
    canonical,
    identifier,
    investigator_spec,
    object_value,
    positive_id,
    safe_http_status,
    trigger_spec,
    utc,
    validate_config,
)

ENVIRONMENT = "sre-read-probe"
WORKFLOW = ".github/workflows/sre-read-probe.yml"
ISSUER = "https://token.actions.githubusercontent.com"
EXCHANGE_AUDIENCE = "api://AzureADTokenExchange"
CONFIGURATION_READ = "Microsoft.App/agents/extendedagents/read"
CANDIDATE_READ = "Microsoft.App/agents/scheduledtasks/read"
CALLERS = ("baseline", "candidate")
SLOTS = (
    "SRE_READ_PROBE_BASELINE_CLIENT_ID", "SRE_READ_PROBE_CANDIDATE_CLIENT_ID",
    "SRE_READ_PROBE_TENANT_ID", "SRE_READ_PROBE_CONFIG",
)
MAX_ATTESTATION_SECONDS = 900


class Code(StrEnum):
    DISABLED = "disabled"
    ADMISSION = "admission_rejected"
    CONFIGURATION = "configuration_rejected"
    ATTESTATION = "attestation_stale"
    TOKEN = "token_rejected"
    ACQUISITION = "acquisition_failed"
    TRANSPORT = "transport_uncertain"
    CONTRACT = "contract_drift"
    HTTP = "http_observed"
    DIFFERENCE = "permission_effect_observed"
    EQUAL = "equal_results_inconclusive"
    COMPARISON = "comparison_inconclusive"
    UNCERTAIN = "operation_uncertain"
    LIFECYCLE = "lifecycle_checked"
    REMOVED = "absence_checked"


class Stage(StrEnum):
    CONFIGURATION = "configuration"
    ADMISSION = "admission"
    OWNERSHIP = "ownership"
    AUTHENTICATION = "authentication"
    INVESTIGATOR = "investigator_get"
    TRIGGER = "trigger_get"
    COMPARISON = "comparison"
    LIFECYCLE = "lifecycle"


class Rejected(RuntimeError):
    def __init__(self, stage: Stage, code: Code):
        super().__init__(code.value)
        self.stage, self.code = stage, code


def emit(stage: Stage, code: Code, *, caller: str = "none", status: Any = None) -> None:
    if type(stage) is not Stage or type(code) is not Code or caller not in (*CALLERS, "none"):
        raise ValueError("Only fixed public markers are supported")
    print(
        f"read_probe;caller={caller};stage={stage.value};code={code.value};"
        f"http_status={safe_http_status(status)}",
        flush=True,
    )


def guid(value: Any) -> str:
    if not isinstance(value, str) or str(uuid.UUID(value)) != value or uuid.UUID(value).int == 0:
        raise ValueError("Expected a nonzero canonical identity")
    return value


def validate(value: Any) -> dict[str, Any]:
    config = object_value(value)
    if set(config) != {
        "schemaVersion", "ownerToken", "tenantId", "location", "expiresAt", "enabled",
        "oidcSubject", "native",
    } or config["schemaVersion"] != 1 or type(config["enabled"]) is not bool:
        raise ValueError("Unknown probe configuration")
    owner, tenant = guid(config["ownerToken"]), guid(config["tenantId"])
    native = validate_config(config["native"], ready=False)
    identifier(native["triggerId"])
    if owner == native["binding"]["ownerToken"] or not tenant:
        raise ValueError("Probe ownership must be independent of the native fixture")
    if not re.fullmatch(r"[a-z][a-z0-9]{1,40}", config["location"]):
        raise ValueError("Invalid fixed identity location")
    utc(config["expiresAt"])
    oidc = object_value(native["oidc"])
    owner_id = positive_id(oidc["repositoryOwnerId"])
    repo = native["repository"]
    account, name = repo.split("/")
    subjects = (
        f"repo:{repo}:environment:{ENVIRONMENT}",
        f"repo:{account}@{owner_id}/{name}@{native['repositoryId']}:environment:{ENVIRONMENT}",
    )
    if config["oidcSubject"] not in subjects:
        raise ValueError("OIDC subject must bind the separate exact environment")
    return config


def specifications(value: Any) -> list[dict[str, Any]]:
    config = validate(value)
    native = config["native"]
    agent = native["binding"]["agentId"]
    group = agent.split("/providers/", 1)[0]
    subscription = native["binding"]["subscriptionId"]
    namespace = uuid.UUID(config["ownerToken"])
    assets = []
    for caller in CALLERS:
        suffix = f"{native['environment']}-{namespace.hex}-{caller}"
        identity = group + "/providers/Microsoft.ManagedIdentity/userAssignedIdentities/" + (
            f"retailtx-read-{suffix}"
        )
        role = (
            f"/subscriptions/{subscription}/providers/Microsoft.Authorization/roleDefinitions/"
            + str(uuid.uuid5(namespace, "read-probe-role:" + caller))
        )
        assignment = agent + "/providers/Microsoft.Authorization/roleAssignments/" + (
            str(uuid.uuid5(namespace, "read-probe-assignment:" + caller))
        )
        assets.extend([
            {
                "caller": caller, "kind": "identity", "id": identity,
                "apiVersion": IDENTITY_VERSION,
                "body": {"location": config["location"], "tags": {
                    "demo": "retailtx", "environmentId": native["environment"],
                    "profile": "sre-read-probe", "managedBy": "retailtx",
                    "ownerToken": config["ownerToken"], "caller": caller,
                    "expiresAt": config["expiresAt"],
                }},
            },
            {
                "caller": caller, "kind": "federation",
                "id": identity + "/federatedIdentityCredentials/read-probe",
                "apiVersion": IDENTITY_VERSION,
                "body": {"properties": {
                    "issuer": ISSUER, "subject": config["oidcSubject"],
                    "audiences": [EXCHANGE_AUDIENCE],
                }},
            },
            {
                "caller": caller, "kind": "role", "id": role, "apiVersion": AUTH_VERSION,
                "body": {"properties": {
                    "roleName": f"RetailTx read probe {namespace} {caller}",
                    "description": f"Unproven GET diagnostic; ownerToken={namespace};{caller}",
                    "type": "CustomRole", "assignableScopes": [group],
                    "permissions": [{
                        "actions": ["Microsoft.App/agents/read"], "notActions": [],
                        "dataActions": [CONFIGURATION_READ] + (
                            [CANDIDATE_READ] if caller == "candidate" else []
                        ),
                        "notDataActions": [],
                    }],
                }},
            },
            {
                "caller": caller, "kind": "assignment", "id": assignment,
                "apiVersion": AUTH_VERSION, "body": {"properties": {
                    "roleDefinitionId": role, "principalType": "ServicePrincipal",
                    "principalId": "<owned-principal>",
                }},
            },
        ])
    return assets


def bound_assets(config: dict[str, Any], identities: dict[str, Any]) -> list[dict[str, Any]]:
    if set(identities) != set(CALLERS):
        raise ValueError("Exactly two independently owned callers are required")
    for caller in CALLERS:
        identity = object_value(identities[caller])
        if set(identity) != {"clientId", "principalId", "tenantId"}:
            raise ValueError("Incomplete immutable caller identity")
        for field in identity:
            guid(identity[field])
        if identity["tenantId"] != config["tenantId"]:
            raise ValueError("Foreign caller tenant")
    if any(identities["baseline"][key] == identities["candidate"][key]
           for key in ("clientId", "principalId")):
        raise ValueError("A/B callers must not share identity")
    assets = specifications(config)
    for asset in assets:
        if asset["kind"] == "assignment":
            asset["body"]["properties"]["principalId"] = identities[asset["caller"]]["principalId"]
    return assets


def runtime_snapshot(config: dict[str, Any], identities: dict[str, Any],
                     checked_at: str) -> dict[str, Any]:
    return {
        "config": copy.deepcopy(config), "identities": copy.deepcopy(identities),
        "assets": bound_assets(config, identities), "checkedAt": checked_at,
    }


def validate_snapshot(value: Any, now: datetime) -> dict[str, Any]:
    snapshot = object_value(value)
    if set(snapshot) != {"config", "identities", "assets", "checkedAt"}:
        raise ValueError("Unknown runtime snapshot")
    config = validate(snapshot["config"])
    if snapshot["assets"] != bound_assets(config, snapshot["identities"]):
        raise ValueError("Exact A/B specification or assignment binding changed")
    age = (now - utc(snapshot["checkedAt"])).total_seconds()
    if not -30 <= age <= MAX_ATTESTATION_SECONDS or utc(config["expiresAt"]) <= now:
        raise Rejected(Stage.OWNERSHIP, Code.ATTESTATION)
    return snapshot


def mask(value: Any) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    if isinstance(value, dict):
        for item in value.values():
            mask(item)
    elif isinstance(value, list):
        for item in value:
            mask(item)
    elif isinstance(value, str) and value and value not in (
        *CALLERS, ENVIRONMENT, *SLOTS, "main", "branch", "CustomRole", "ServicePrincipal",
        "retailtx", "sre-read-probe", "github-intake", "CAP", "ERP", "Manual", "review",
        "https://azuresre.dev", EXCHANGE_AUDIENCE, ISSUER,
        "59f0a04a-b322-4310-adc9-39ac41e9631e",
        "Microsoft.App/agents/read", CONFIGURATION_READ, CANDIDATE_READ,
        "2022-04-01", "2023-01-31",
    ):
        escaped = str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::add-mask::{escaped}", flush=True)

def mask_snapshot(value: Any) -> None:
    mask(value)
    if isinstance(value, dict):
        native = value.get("config", {}).get("native", {})
        mask(str(native.get("repositoryId", "")))
        mask(str(native.get("oidc", {}).get("repositoryOwnerId", "")))


def claims(token: str) -> dict[str, Any]:
    if not isinstance(token, str) or len(token) > 32768 or len(token.split(".")) != 3:
        raise ValueError("Malformed token")
    encoded = token.split(".")[1]
    return object_value(json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))))


def token_times(value: dict[str, Any], now: datetime) -> None:
    epoch = now.timestamp()
    if (
        type(value.get("exp")) is not int or value["exp"] <= epoch
        or type(value.get("nbf")) is not int or value["nbf"] > epoch + 30
    ):
        raise ValueError("Token not currently valid")


def access_claims(token: str, config: dict[str, Any], caller: str,
                  identities: dict[str, Any], now: datetime) -> None:
    value = claims(token)
    token_times(value, now)
    expected = identities[caller]
    if (
        value.get("aud") != config["native"]["tokenAudience"]
        or value.get("tid") != config["tenantId"] or value.get("oid") != expected["principalId"]
        or value.get("appid", value.get("azp")) != expected["clientId"]
        or value.get("iss") not in (
            f"https://sts.windows.net/{config['tenantId']}/",
            f"https://login.microsoftonline.com/{config['tenantId']}/v2.0",
        )
        or "scp" in value
    ):
        raise ValueError("Access token caller/audience/tenant differs")
    # This is sanity checking only. Entra and the SRE service verify signatures.


def capture(arguments: list[str], *, env: dict[str, str] | None = None,
            input_text: str | None = None) -> str:
    """Finite subprocess with capped in-memory stdout/stderr; never forward diagnostics."""
    input_bytes = None if input_text is None else input_text.encode()
    if input_bytes is not None and len(input_bytes) > 65536:
        raise ValueError("Bounded private input exceeded")
    with tempfile.TemporaryFile() as private_input:
        if input_bytes is not None:
            private_input.write(input_bytes)
            private_input.seek(0)
        # No stdin feeder or buffered pipe locks may outlive the deadline.
        process = subprocess.Popen(
            arguments, shell=False, env=env,
            stdin=private_input if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        buffers = [bytearray(), bytearray()]
        overflow = threading.Event()
        reader_failed = threading.Event()

        def drain(pipe: Any, target: bytearray) -> None:
            try:
                while chunk := pipe.read(4096):
                    if len(target) + len(chunk) > 131072:
                        overflow.set()
                        with suppress(OSError):
                            process.kill()
                        return
                    target.extend(chunk)
            except Exception:
                # Reader threads must never reach threading's public traceback handler.
                reader_failed.set()
                with suppress(OSError):
                    process.kill()

        workers = [threading.Thread(target=drain, args=(pipe, buffer), daemon=True)
                   for pipe, buffer in zip((process.stdout, process.stderr), buffers, strict=True)]

        for worker in workers:
            worker.start()
        try:
            process.wait(timeout=30)
            for worker in workers:
                worker.join(timeout=1)
            if (
                overflow.is_set() or reader_failed.is_set()
                or any(worker.is_alive() for worker in workers)
            ):
                raise RuntimeError("Subprocess output uncertain")
            if process.returncode:
                raise RuntimeError("Subprocess rejected")
            return buffers[0].decode("utf-8").strip()
        finally:
            try:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
            finally:
                for pipe in (process.stdout, process.stderr):
                    if pipe is not None:
                        with suppress(OSError):
                            pipe.close()


def oidc_token(config: dict[str, Any], now: datetime) -> str:
    request = urlsplit(os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"])
    if (
        request.scheme != "https" or not request.hostname
        or not request.hostname.endswith(".actions.githubusercontent.com")
        or request.port not in (None, 443) or request.username or request.password
        or request.fragment or "\\" in request.path or ".." in request.path
    ):
        raise ValueError("Unexpected Actions token endpoint")
    query = parse_qsl(request.query, keep_blank_values=True)
    if any(key == "audience" for key, _ in query):
        raise ValueError("Unexpected preselected OIDC audience")
    path = request.path + "?" + urlencode([*query, ("audience", EXCHANGE_AUDIENCE)])
    api = Api(f"https://{request.hostname}", os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"])
    token = object_value(api.get(path))["value"]
    if not isinstance(token, str):
        raise ValueError("Malformed OIDC assertion")
    mask(token)
    value = claims(token)
    token_times(value, now)
    native = config["native"]
    if any(value.get(key) != expected for key, expected in {
        "iss": ISSUER, "aud": EXCHANGE_AUDIENCE, "sub": config["oidcSubject"],
        "repository": native["repository"], "repository_id": str(native["repositoryId"]),
        "repository_owner_id": str(native["oidc"]["repositoryOwnerId"]),
        "ref": "refs/heads/main", "ref_type": "branch", "event_name": "workflow_dispatch",
        "environment": ENVIRONMENT, "runner_environment": "github-hosted",
        "workflow_ref": f"{native['repository']}/{WORKFLOW}@refs/heads/main",
        "workflow_sha": os.environ["GITHUB_SHA"],
        "run_attempt": "1",
    }.items()):
        raise ValueError("OIDC claims differ from fixed manual main workflow")
    return token


def acquire(config: dict[str, Any], identities: dict[str, Any], caller: str,
            assertion: str, directory: Path) -> str:
    environment = {**os.environ, "AZURE_CONFIG_DIR": str(directory), "AZURE_CORE_OUTPUT": "none"}
    executable = azure_cli_executable()
    capture([
        executable, "login", "--service-principal", "--username", identities[caller]["clientId"],
        "--tenant", config["tenantId"], "--federated-token", assertion,
        "--allow-no-subscriptions", "--output", "none", "--only-show-errors",
    ], env=environment)
    token = capture([
        executable, "account", "get-access-token", "--tenant", config["tenantId"],
        "--resource", config["native"]["tokenResource"], "--query", "accessToken",
        "--output", "tsv", "--only-show-errors",
    ], env=environment)
    mask(token)
    access_claims(token, config, caller, identities, datetime.now(UTC))
    return token


class NativeReads:
    """No method, path, URL, query, body or user-supplied ID argument is exposed."""

    def __init__(self, config: dict[str, Any], token: str):
        self.__config = copy.deepcopy(validate(config)["native"])
        self.__api = Api(self.__config["endpoint"], token)

    def investigator(self) -> tuple[int, Any]:
        name = investigator_spec(self.__config)["name"]
        return self.__api.request("GET", f"/api/v2/extendedAgent/agents/{name}")

    def trigger(self) -> tuple[int, Any]:
        return self.__api.request("GET", f"/api/v1/httptriggers/{self.__config['triggerId']}")


def investigator_contract(config: dict[str, Any], response: Any) -> None:
    value = object_value(response)
    expected = investigator_spec(config["native"])
    if value.get("name") != expected["name"]:
        raise ValueError("Investigator route/body identity drift")
    properties = object_value(value["properties"])
    if any(properties.get(key) != item for key, item in expected["properties"].items()):
        raise ValueError("Investigator content drift")
    assert_no_extra_tools(properties)


def trigger_contract(config: dict[str, Any], response: Any) -> None:
    value = object_value(response)
    if any(value.get(key) != item for key, item in trigger_spec(config["native"]).items()):
        raise ValueError("Trigger route/body binding drift")
    if value.get("id") != config["native"]["triggerId"] or value.get("triggerEnabled") is not False:
        raise ValueError("Exact disabled trigger required")


def observe(config: dict[str, Any], caller: str, reads: NativeReads) -> int:
    first_trigger = None
    for stage, getter, contract in (
        (Stage.INVESTIGATOR, reads.investigator, investigator_contract),
        (Stage.TRIGGER, reads.trigger, trigger_contract),
        (Stage.INVESTIGATOR, reads.investigator, investigator_contract),
        (Stage.TRIGGER, reads.trigger, trigger_contract),
    ):
        try:
            status, response = getter()
        except (OSError, RuntimeError, ValueError, http.client.HTTPException):
            raise Rejected(stage, Code.TRANSPORT) from None
        emit(stage, Code.HTTP, caller=caller, status=status)
        if status == 200 and type(status) is int:
            try:
                contract(config, response)
            except (ValueError, KeyError, TypeError):
                raise Rejected(stage, Code.CONTRACT) from None
        elif stage is not Stage.TRIGGER or type(status) is not int or status != 403:
            raise Rejected(stage, Code.COMPARISON)
        if stage is Stage.TRIGGER:
            if first_trigger is not None and first_trigger != status:
                raise Rejected(stage, Code.COMPARISON)
            first_trigger = status
    if first_trigger is None:
        raise Rejected(Stage.COMPARISON, Code.COMPARISON)
    return first_trigger


def compare(baseline: int, candidate: int) -> tuple[Code, int]:
    if type(baseline) is not int or type(candidate) is not int:
        return Code.COMPARISON, 2
    if baseline == 403 and candidate == 200:
        return Code.DIFFERENCE, 0
    if baseline == candidate and baseline in (200, 403):
        return Code.EQUAL, 2
    return Code.COMPARISON, 2


def admission(snapshot: dict[str, Any]) -> None:
    native = snapshot["config"]["native"]
    expected = {
        "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REF": "refs/heads/main", "GITHUB_REF_TYPE": "branch",
        "GITHUB_REPOSITORY": native["repository"],
        "GITHUB_REPOSITORY_ID": str(native["repositoryId"]), "GITHUB_RUN_ATTEMPT": "1",
    }
    if any(os.environ.get(key) != value for key, value in expected.items()):
        raise Rejected(Stage.ADMISSION, Code.ADMISSION)
    if not re.fullmatch(r"[0-9a-f]{40}", os.environ.get("GITHUB_SHA", "")):
        raise Rejected(Stage.ADMISSION, Code.ADMISSION)
    for slot, caller in zip(SLOTS[:2], CALLERS, strict=True):
        if os.environ.get(slot) != snapshot["identities"][caller]["clientId"]:
            raise Rejected(Stage.ADMISSION, Code.CONFIGURATION)
    if os.environ.get(SLOTS[2]) != snapshot["config"]["tenantId"]:
        raise Rejected(Stage.ADMISSION, Code.CONFIGURATION)


def run(snapshot: dict[str, Any]) -> int:
    snapshot = validate_snapshot(snapshot, datetime.now(UTC))
    config, identities = snapshot["config"], snapshot["identities"]
    if not config["enabled"]:
        raise Rejected(Stage.ADMISSION, Code.DISABLED)
    admission(snapshot)
    try:
        assertion = oidc_token(config, datetime.now(UTC))
    except (ValueError, KeyError, OSError, RuntimeError, http.client.HTTPException):
        raise Rejected(Stage.AUTHENTICATION, Code.TOKEN) from None
    results = []
    with tempfile.TemporaryDirectory(prefix="retailtx-read-probe-") as temporary:
        root = Path(temporary)
        for caller in CALLERS:
            directory = root / caller
            directory.mkdir(mode=0o700)
            try:
                token = acquire(config, identities, caller, assertion, directory)
            except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError):
                raise Rejected(Stage.AUTHENTICATION, Code.ACQUISITION) from None
            validate_snapshot(snapshot, datetime.now(UTC))
            results.append(observe(config, caller, NativeReads(config, token)))
    validate_snapshot(snapshot, datetime.now(UTC))
    code, exit_code = compare(*results)
    emit(Stage.COMPARISON, code)
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("spec", "run"))
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "spec":
            if args.config is None or os.environ.get("GITHUB_ACTIONS") == "true":
                raise Rejected(Stage.CONFIGURATION, Code.CONFIGURATION)
            config = validate(json.loads(args.config.read_text(encoding="utf-8")))
            print(canonical({
                "assets": specifications(config), "githubEnvironment": ENVIRONMENT,
                "branchPolicy": {"name": "main", "type": "branch"}, "secretSlots": list(SLOTS),
                "candidateMapping": "unconfirmed",
            }))
            return 0
        raw = os.environ.get(SLOTS[3], "")
        mask(raw)
        for slot in SLOTS[:3]:
            mask(os.environ.get(slot, ""))
        value = json.loads(raw)
        mask_snapshot(value)
        return run(value)
    except Rejected as error:
        emit(error.stage, error.code)
    except (
        ValueError, KeyError, TypeError, IndexError, AttributeError, OSError, RuntimeError,
        subprocess.SubprocessError, http.client.HTTPException,
    ):
        emit(Stage.CONFIGURATION, Code.CONFIGURATION)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
