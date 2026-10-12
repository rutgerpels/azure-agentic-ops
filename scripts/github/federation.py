"""Operator-owned ARM caller identity, federation and exact-agent invocation grant."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

from scripts.github.intake import (
    Api,
    azure_cli_executable,
    digest,
    object_value,
    positive_id,
    utc,
    validate_config,
)
from scripts.github.lifecycle import get_optional, persist

IDENTITY_VERSION = "2023-01-31"
AUTH_VERSION = "2022-04-01"
ROLE_PROFILE = "investigator-read-v1"
CONFIGURATION_READ = "Microsoft.App/agents/extendedagents/read"


def federation_subject(config: dict[str, Any]) -> str:
    classic = f"repo:{config['repository']}:environment:sre-github-intake"
    if "oidc" not in config:
        # Preserve classic manifests for exact inverse checks, not new setup.
        return classic
    oidc = object_value(config["oidc"])
    if set(oidc) != {"repositoryOwnerId", "subject"}:
        raise ValueError("Explicit OIDC owner ID and verified subject are required")
    owner_id = positive_id(oidc["repositoryOwnerId"])
    owner, repository = config["repository"].split("/")
    immutable = (
        f"repo:{owner}@{owner_id}/{repository}@{config['repositoryId']}"
        ":environment:sre-github-intake"
    )
    subject = oidc["subject"]
    if not isinstance(subject, str) or subject not in (classic, immutable):
        raise ValueError("OIDC subject differs from exact repository/owner/environment binding")
    return subject


def repository_binding(config: dict[str, Any], evidence: Any) -> dict[str, Any]:
    federation_subject(config)
    if "oidc" not in config:
        raise ValueError("Explicit verified OIDC configuration is required")
    repository = object_value(evidence)
    owner = object_value(repository.get("owner"))
    if (
        repository.get("full_name") != config["repository"]
        or positive_id(repository.get("id")) != config["repositoryId"]
        or owner.get("login") != config["repository"].split("/")[0]
        or positive_id(owner.get("id")) != config["oidc"]["repositoryOwnerId"]
    ):
        raise ValueError("Repository API owner/name/ID differs from trusted OIDC binding")
    return {
        "full_name": repository["full_name"], "id": repository["id"],
        "owner": {"login": owner["login"], "id": owner["id"]},
    }


def binding_hash(config: dict[str, Any]) -> str:
    binding = {key: config[key] for key in (
        "repository", "repositoryId", "environment", "binding",
    )}
    if "oidc" in config:
        binding["oidc"] = config["oidc"]
    return digest(binding)


def role_profile(state: dict[str, Any]) -> str | None:
    if "roleProfile" not in state:
        return None
    if state["roleProfile"] != ROLE_PROFILE:
        raise ValueError("Unknown federation role profile; no adoption/migration")
    return ROLE_PROFILE


def specifications(config: dict[str, Any], location: str, expires_at: str, *,
                   profile: str | None = ROLE_PROFILE) -> list[dict[str, Any]]:
    validate_config(config, ready=False)
    if profile not in (None, ROLE_PROFILE):
        raise ValueError("Unknown federation role profile")
    if not re.fullmatch(r"[a-z][a-z0-9]{1,40}", location):
        raise ValueError("Invalid trusted identity location")
    utc(expires_at)
    binding = config["binding"]
    group = binding["agentId"].split("/providers/", 1)[0]
    identity = group + "/providers/Microsoft.ManagedIdentity/userAssignedIdentities/" + (
        f"retailtx-github-intake-{config['environment']}"
    )
    namespace = uuid.UUID(binding["ownerToken"])
    role = f"/subscriptions/{binding['subscriptionId']}/providers/Microsoft.Authorization/" + (
        "roleDefinitions/" + str(uuid.uuid5(namespace, "github-intake-role:" + binding["agentId"]))
    )
    assignment = binding["agentId"] + "/providers/Microsoft.Authorization/roleAssignments/" + (
        str(uuid.uuid5(namespace, "github-intake-assignment:" + identity))
    )
    return [
        {
            "kind": "identity", "id": identity, "apiVersion": IDENTITY_VERSION,
            "body": {"location": location, "tags": {
                "demo": "retailtx", "environmentId": config["environment"],
                "profile": "github-intake", "managedBy": "retailtx",
                "ownerToken": binding["ownerToken"], "expiresAt": expires_at,
            }},
        },
        {
            "kind": "federation", "id": identity + "/federatedIdentityCredentials/github-intake",
            "apiVersion": IDENTITY_VERSION,
            "body": {"properties": {
                "issuer": "https://token.actions.githubusercontent.com",
                "subject": federation_subject(config),
                "audiences": ["api://AzureADTokenExchange"],
            }},
        },
        {
            "kind": "role", "id": role, "apiVersion": AUTH_VERSION,
            "body": {"properties": {
                "roleName": f"RetailTx GitHub intake {config['environment']} {namespace}",
                "description": f"Proposal-only GitHub intake; ownerToken={namespace}",
                "type": "CustomRole", "assignableScopes": [group],
                "permissions": [{
                    "actions": ["Microsoft.App/agents/read"], "notActions": [],
                    "dataActions": [
                        "Microsoft.App/agents/threads/read", "Microsoft.App/agents/threads/write",
                    ] + ([CONFIGURATION_READ] if profile == ROLE_PROFILE else []),
                    "notDataActions": [],
                }],
            }},
        },
        {
            "kind": "assignment", "id": assignment, "apiVersion": AUTH_VERSION,
            "body": {"properties": {
                "roleDefinitionId": role, "principalType": "ServicePrincipal",
                "principalId": "<owned-identity-principal>",
            }},
        },
    ]


def resource_path(asset: dict[str, Any]) -> str:
    return f"{asset['id']}?api-version={asset['apiVersion']}"


def validate_asset(asset: dict[str, Any], live: dict[str, Any]) -> None:
    if str(live.get("id", "")).lower() != asset["id"].lower():
        raise ValueError("ARM asset identity differs from owned intent")
    for key, expected in asset["body"].items():
        actual = live.get(key)
        if isinstance(expected, dict):
            actual = object_value(actual)
            for field, value in expected.items():
                if actual.get(field) != value:
                    raise ValueError("Owned identity/federation/role drift; no overwrite/delete")
        elif actual != expected:
            raise ValueError("Owned ARM configuration differs")
    properties = object_value(live.get("properties", {}))
    if asset["kind"] == "identity":
        for key in ("clientId", "principalId", "tenantId"):
            value = properties[key]
            if not isinstance(value, str) or str(uuid.UUID(value)) != value:
                raise ValueError("Managed identity response lacks canonical identity IDs")
    if properties.get("provisioningState", "Succeeded") != "Succeeded":
        raise ValueError("Owned resource provisioning not verified")


def bind_identity(state: dict[str, Any], live: dict[str, Any], *, capture: bool = False) -> None:
    keys = ("clientId", "principalId", "tenantId")
    properties = object_value(live["properties"])
    recorded = [key in state for key in keys]
    if not any(recorded) and capture:
        state.update({key: properties[key] for key in keys})
    elif not all(recorded) or any(properties[key] != state[key] for key in keys):
        raise ValueError("Managed identity principal/client/tenant changed; no adoption/delete")


def manifest(config: dict[str, Any], path: Path) -> dict[str, Any]:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    return manifest_value(config, state)


def manifest_value(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    if state.get("phase") == "SubjectTransitionRequested":
        raise ValueError(
            "Subject transition uncertain; reconcile transition GET before reuse/delete",
        )
    if state.get("phase") == "RoleTransitionRequested":
        raise ValueError("Role transition uncertain; reconcile upgrade GET before reuse/delete")
    if "roleTransition" in state:
        role_transition_plan(config, state)
    if (state.get("ownerToken") != config["binding"]["ownerToken"]
            or state.get("configHash") != binding_hash(config)):
        raise ValueError("Foreign/changed federation manifest")
    assets = state["assets"]
    if not isinstance(assets, list) or len(assets) != 4:
        raise ValueError("Incomplete federation manifest")
    desired = specifications(
        config, assets[0]["body"]["location"], assets[0]["body"]["tags"]["expiresAt"],
        profile=role_profile(state),
    )
    principal = assets[-1]["body"]["properties"]["principalId"]
    allowed_principals = (state.get("principalId"), "<owned-identity-principal>")
    if principal not in allowed_principals or (
        assets[-1].get("phase") and principal != state.get("principalId")
    ):
        raise ValueError("Federation assignment principal changed")
    desired[-1]["body"]["properties"]["principalId"] = principal
    normalized = [{key: value for key, value in asset.items() if key != "phase"}
                  for asset in assets]
    if normalized != desired:
        raise ValueError("Federation manifest paths/specification changed")
    return state


def configure(config: dict[str, Any], path: Path, api: Api,
              location: str, expires_at: str, repository_evidence: Any = None) -> dict[str, Any]:
    if "oidc" in config or not path.exists():
        repository_binding(config, repository_evidence)
    if path.exists():
        state = manifest(config, path)
        desired = specifications(config, location, expires_at, profile=role_profile(state))
        normalized = json.loads(json.dumps(state["assets"]))
        normalized[-1]["body"]["properties"]["principalId"] = "<owned-identity-principal>"
        for asset in normalized:
            asset.pop("phase", None)
        if normalized != desired or state.get("phase") == "Removed":
            raise ValueError("Federation intent changed; no adoption/recreation")
    else:
        desired = specifications(config, location, expires_at)
        for asset in desired:
            if get_optional(api, resource_path(asset)) is not None:
                raise ValueError("Unowned federation collision; no adoption")
        state = {
            "schemaVersion": 1, "ownerToken": config["binding"]["ownerToken"],
            "configHash": binding_hash(config), "roleProfile": ROLE_PROFILE,
            "assets": desired, "phase": "Configuring",
        }
        persist(path, state)
    for asset in state["assets"]:
        if asset["kind"] == "assignment":
            asset["body"]["properties"]["principalId"] = state["principalId"]
        live = get_optional(api, resource_path(asset))
        if live is not None:
            if asset.get("phase") not in ("Requested", "Verified"):
                raise ValueError("Late unowned federation collision")
        elif asset.get("phase"):
            raise RuntimeError("ARM request absent/uncertain; never replay PUT")
        else:
            asset["phase"] = "Requested"
            persist(path, state)
            status, _ = api.request("PUT", resource_path(asset), asset["body"])
            if status not in (200, 201, 202):
                raise RuntimeError("ARM write uncertain; reconcile GET without replay")
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                live = get_optional(api, resource_path(asset))
                if live is not None and live.get("properties", {}).get(
                    "provisioningState", "Succeeded"
                ) == "Succeeded":
                    break
                time.sleep(min(2, max(0, deadline - time.monotonic())))
            if live is None:
                raise RuntimeError("Owned ARM resource creation not observed")
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live, capture=asset["phase"] == "Requested")
        asset["phase"] = "Verified"
        persist(path, state)
    state["phase"] = "ConfiguredOidcUnverified"
    persist(path, state)
    return state


def subject_transition_spec(config: dict[str, Any], state: dict[str, Any],
                            repository_evidence: Any) -> dict[str, Any]:
    """Pure, owner-reviewed classic-to-immutable plan; never authenticates or writes."""
    validate_config(config, ready=False)
    if "roleTransition" in state:
        raise ValueError("Role upgrade history cannot be rewritten by a subject transition")
    repository = repository_binding(config, repository_evidence)
    classic = f"repo:{config['repository']}:environment:sre-github-intake"
    if federation_subject(config) == classic:
        raise ValueError("Subject transition requires an explicit immutable target")
    previous = copy.deepcopy(config)
    previous.pop("oidc")
    if binding_hash(previous) != state.get("configHash"):
        previous["oidc"] = {**config["oidc"], "subject": classic}
    manifest_value(previous, state)
    if (
        state.get("phase") != "ConfiguredOidcUnverified"
        or any(asset.get("phase") != "Verified" for asset in state["assets"])
        or "subjectTransition" in state
    ):
        raise ValueError("Transition requires four verified assets and no previous transition")
    after = copy.deepcopy(state)
    after["assets"][1]["body"]["properties"]["subject"] = federation_subject(config)
    after["configHash"] = binding_hash(config)
    manifest_value(config, after)
    return {"before": copy.deepcopy(state), "after": after, "repository": repository}


def transition_readback(state: dict[str, Any], api: Api) -> list[dict[str, Any]]:
    snapshots = []
    for asset in state["assets"]:
        live = get_optional(api, resource_path(asset))
        if live is None:
            raise ValueError("Owned transition asset missing; no creation/adoption")
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live)
        snapshots.append(live)
    return snapshots


def transition_subject(config: dict[str, Any], path: Path, api: Api,
                       repository_evidence: Any) -> dict[str, Any]:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    if "roleTransition" in state or state.get("phase") == "RoleTransitionRequested":
        raise ValueError("Role upgrade history cannot be rewritten by a subject transition")
    journal = state.get("subjectTransition")
    if journal is None:
        plan = subject_transition_spec(config, state, repository_evidence)
        before_readback = transition_readback(plan["before"], api)
        journal = {
            "phase": "Requested", "before": plan["before"], "after": plan["after"],
            "repository": plan["repository"], "beforeReadback": before_readback,
        }
        state["phase"] = "SubjectTransitionRequested"
        state["subjectTransition"] = journal
        persist(path, state)
        asset = plan["after"]["assets"][1]
        status, _ = api.request("PUT", resource_path(asset), asset["body"])
        if status not in (200, 201):
            raise RuntimeError("Subject write uncertain; reconcile GET without replay")
    else:
        journal = object_value(journal)
        plan = subject_transition_spec(config, journal["before"], repository_evidence)
        if any(journal.get(key) != plan[key] for key in ("before", "after", "repository")):
            raise ValueError("Subject transition intent changed; no replay/adoption")
        for asset, live in zip(
            plan["before"]["assets"], journal["beforeReadback"], strict=True,
        ):
            validate_asset(asset, object_value(live))
            if asset["kind"] == "identity":
                bind_identity(plan["before"], live)
        expected = copy.deepcopy(plan["before"] if journal["phase"] == "Requested"
                                 else plan["after"])
        expected["phase"] = ("SubjectTransitionRequested" if journal["phase"] == "Requested"
                             else "ConfiguredOidcUnverified")
        expected["subjectTransition"] = journal
        if journal["phase"] not in ("Requested", "Verified") or state != expected:
            raise ValueError("Subject transition manifest changed; no replay/adoption")
    # Once intent is durable, every retry is GET-only, even if the old subject remains.
    readback = transition_readback(plan["after"], api)
    compare_transition_readbacks(
        journal["beforeReadback"], readback, 1, {"subject": federation_subject(config)},
    )
    state = copy.deepcopy(plan["after"])
    state["subjectTransition"] = {**journal, "phase": "Verified", "readback": readback}
    persist(path, state)
    return state


def role_upgrade_spec(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    """Pure, fixed legacy-to-configuration-read plan; no runtime config change."""
    validate_config(config, ready=False)
    if "roleTransition" in state:
        raise ValueError("Role upgrade requires original legacy state, not transition history")
    manifest_value(config, state)
    if (
        role_profile(state) is not None
        or type(state.get("schemaVersion")) is not int or state["schemaVersion"] != 1
        or state.get("phase") != "ConfiguredOidcUnverified"
        or any(asset.get("phase") != "Verified" for asset in state["assets"])
    ):
        raise ValueError("Role upgrade requires four verified legacy assets")
    for key in ("clientId", "principalId", "tenantId"):
        value = state.get(key)
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError("Role upgrade requires canonical recorded identity IDs")
    if "subjectTransition" in state:
        journal = object_value(state["subjectTransition"])
        if (
            set(journal) != {
                "phase", "before", "after", "repository", "beforeReadback", "readback",
            }
            or journal["phase"] != "Verified"
            or "subjectTransition" in object_value(journal["before"])
            or "roleTransition" in journal["before"]
        ):
            raise ValueError("Incomplete subject transition history; no role upgrade")
        subject_plan = subject_transition_spec(config, journal["before"], journal["repository"])
        if any(journal[key] != subject_plan[key] for key in ("before", "after", "repository")):
            raise ValueError("Subject transition history changed; no role upgrade")
        expected = copy.deepcopy(subject_plan["after"])
        expected["subjectTransition"] = journal
        if state != expected:
            raise ValueError("Subject transition manifest changed; no role upgrade")
        validate_snapshots(subject_plan["before"], journal["beforeReadback"])
        validate_snapshots(subject_plan["after"], journal["readback"])
        compare_transition_readbacks(
            journal["beforeReadback"], journal["readback"], 1,
            {"subject": federation_subject(config)},
        )
    after = copy.deepcopy(state)
    after["roleProfile"] = ROLE_PROFILE
    after["assets"][2]["body"]["properties"]["permissions"][0]["dataActions"].append(
        CONFIGURATION_READ,
    )
    return {"before": copy.deepcopy(state), "after": after}


def validate_snapshots(state: dict[str, Any], snapshots: Any) -> None:
    if not isinstance(snapshots, list) or len(snapshots) != 4:
        raise ValueError("Incomplete transition readbacks")
    for asset, live in zip(state["assets"], snapshots, strict=True):
        live = object_value(live)
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live)


def compare_transition_readbacks(before: list[dict[str, Any]], after: list[dict[str, Any]],
                                changed_index: int, properties: dict[str, Any]) -> None:
    for index, (original, current) in enumerate(zip(before, after, strict=True)):
        expected, actual = copy.deepcopy(original), copy.deepcopy(current)
        if index == changed_index:
            expected["properties"].update(properties)
            expected.pop("systemData", None)
            actual.pop("systemData", None)
            if changed_index == 2:
                # ARM owns these role update stamps, not the permission intent.
                for key in ("updatedBy", "updatedOn"):
                    expected["properties"].pop(key, None)
                    actual["properties"].pop(key, None)
        if expected != actual:
            raise ValueError("Transition changed other ARM fields; completion unverified")


def role_transition_plan(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    journal = object_value(state["roleTransition"])
    phase = journal.get("phase")
    required = {"phase", "before", "after", "beforeReadback"}
    if phase == "Verified":
        required.add("readback")
    if phase not in ("Requested", "Verified") or set(journal) != required:
        raise ValueError("Incomplete role transition journal; no replay/adoption")
    plan = role_upgrade_spec(config, object_value(journal["before"]))
    if any(journal[key] != plan[key] for key in ("before", "after")):
        raise ValueError("Role transition intent changed; no replay/adoption")
    validate_snapshots(plan["before"], journal["beforeReadback"])
    expected = copy.deepcopy(plan["before"] if phase == "Requested" else plan["after"])
    if phase == "Requested":
        expected["phase"] = "RoleTransitionRequested"
    elif state.get("phase") in ("Removing", "Removed"):
        expected["phase"] = state["phase"]
    expected["roleTransition"] = journal
    if state != expected:
        raise ValueError("Role transition manifest changed; no replay/adoption")
    if phase == "Verified":
        validate_snapshots(plan["after"], journal["readback"])
        compare_transition_readbacks(
            journal["beforeReadback"], journal["readback"], 2,
            plan["after"]["assets"][2]["body"]["properties"],
        )
    return plan


def upgrade_role(config: dict[str, Any], path: Path, api: Api) -> dict[str, Any]:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    if "roleTransition" not in state:
        plan = role_upgrade_spec(config, state)
        before_readback = transition_readback(plan["before"], api)
        journal = {
            "phase": "Requested", **plan, "beforeReadback": before_readback,
        }
        state["phase"] = "RoleTransitionRequested"
        state["roleTransition"] = journal
        persist(path, state)
        asset = plan["after"]["assets"][2]
        status, _ = api.request("PUT", resource_path(asset), asset["body"])
        if status not in (200, 201):
            raise RuntimeError("Role write uncertain; reconcile upgrade GET without replay")
    else:
        plan = role_transition_plan(config, state)
        journal = state["roleTransition"]
        if state["phase"] not in ("RoleTransitionRequested", "ConfiguredOidcUnverified"):
            raise ValueError("Role upgrade cannot reuse a removing/removed manifest")
    # Durable Requested intent is a dispatch boundary, even if the old role remains.
    readback = transition_readback(plan["after"], api)
    compare_transition_readbacks(
        journal["beforeReadback"], readback, 2,
        plan["after"]["assets"][2]["body"]["properties"],
    )
    if journal["phase"] == "Verified":
        return state
    state = copy.deepcopy(plan["after"])
    state["roleTransition"] = {**journal, "phase": "Verified", "readback": readback}
    persist(path, state)
    return state


def check(config: dict[str, Any], path: Path, api: Api) -> None:
    state = manifest(config, path)
    if state.get("phase") != "ConfiguredOidcUnverified" or len(state["assets"]) != 4:
        raise ValueError("Owned federation configuration is incomplete")
    for asset in state["assets"]:
        live = get_optional(api, resource_path(asset))
        if live is None:
            raise ValueError("Owned federation asset missing")
        validate_asset(asset, live)
        if asset["kind"] == "identity":
            bind_identity(state, live)
    # This is operator ARM readback, never proof of the actual workflow identity's access.


def remove(config: dict[str, Any], path: Path, api: Api) -> None:
    state = manifest(config, path)
    present = []
    for asset in state["assets"]:
        live = get_optional(api, resource_path(asset))
        if live is not None:
            if not asset.get("phase"):
                raise ValueError("Late unowned federation asset; no deletion")
            validate_asset(asset, live)
            if asset["kind"] == "identity":
                bind_identity(state, live, capture=asset["phase"] == "Requested")
            if asset["phase"] == "Requested":
                asset["phase"] = "Verified"
                persist(path, state)
            present.append(asset)
        elif asset.get("phase") == "Requested":
            raise RuntimeError("Uncertain ARM creation; no absence/removal claim")
    state["phase"] = "Removing"
    persist(path, state)
    for asset in reversed(present):
        status, _ = api.request("DELETE", resource_path(asset))
        if status not in (200, 202, 204):
            raise RuntimeError("Owned ARM deletion uncertain")
        deadline = time.monotonic() + 120
        while get_optional(api, resource_path(asset)) is not None:
            if time.monotonic() >= deadline:
                raise RuntimeError("Owned federation residual remains")
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    if any(get_optional(api, resource_path(asset)) is not None for asset in state["assets"]):
        raise RuntimeError("Owned federation final absence unverified")
    state["phase"] = "Removed"
    persist(path, state)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=(
        "spec", "configure", "check", "down", "transition-spec", "transition-subject",
        "role-upgrade-spec", "upgrade-role",
    ))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--location")
    parser.add_argument("--expires-at")
    parser.add_argument("--repository-evidence", type=Path)
    args = parser.parse_args()
    config = validate_config(json.loads(args.config.read_text()), ready=False)
    if args.operation in ("spec", "configure") and not (args.location and args.expires_at):
        raise ValueError("Identity location and explicit retention expiry are required")
    if args.operation == "spec":
        print(json.dumps(specifications(config, args.location, args.expires_at), indent=2))
        return
    if args.state is None:
        raise ValueError("An ignored owner-only federation manifest is required")
    evidence = (json.loads(args.repository_evidence.read_text(encoding="utf-8"))
                if args.repository_evidence else None)
    if args.operation == "transition-spec":
        state = object_value(json.loads(args.state.read_text(encoding="utf-8")))
        print(json.dumps(subject_transition_spec(config, state, evidence), indent=2))
        return
    if args.operation == "role-upgrade-spec":
        state = object_value(json.loads(args.state.read_text(encoding="utf-8")))
        print(json.dumps(role_upgrade_spec(config, state), indent=2))
        return
    api = Api("https://management.azure.com", arm_token(config))
    lock = args.state.with_suffix(".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        if args.operation == "configure":
            configure(config, args.state, api, args.location, args.expires_at, evidence)
        elif args.operation == "check":
            check(config, args.state, api)
        elif args.operation == "transition-subject":
            transition_subject(config, args.state, api, evidence)
        elif args.operation == "upgrade-role":
            upgrade_role(config, args.state, api)
        else:
            remove(config, args.state, api)
    finally:
        os.close(descriptor)
        lock.unlink()


def arm_token(config: dict[str, Any]) -> str:
    token = subprocess.run(
        [azure_cli_executable(), "account", "get-access-token",
         "--resource", "https://management.azure.com/",
         "--subscription", config["binding"]["subscriptionId"],
         "--query", "accessToken", "--output", "tsv"],
        capture_output=True, text=True, timeout=30, check=False, shell=False,
    )
    if token.returncode or not token.stdout.strip():
        raise RuntimeError("Operator ARM authentication failed; no alternate identity")
    return token.stdout.strip()


if __name__ == "__main__":
    main()
