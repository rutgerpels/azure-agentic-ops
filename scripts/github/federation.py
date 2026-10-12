"""Operator-owned ARM caller identity, federation and exact-agent invocation grant."""

from __future__ import annotations

import argparse
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
    utc,
    validate_config,
)
from scripts.github.lifecycle import get_optional, persist

IDENTITY_VERSION = "2023-01-31"
AUTH_VERSION = "2022-04-01"


def binding_hash(config: dict[str, Any]) -> str:
    return digest({key: config[key] for key in (
        "repository", "repositoryId", "environment", "binding",
    )})


def specifications(config: dict[str, Any], location: str, expires_at: str) -> list[dict[str, Any]]:
    validate_config(config, ready=False)
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
                "subject": f"repo:{config['repository']}:environment:sre-github-intake",
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
                    ],
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
    if (state.get("ownerToken") != config["binding"]["ownerToken"]
            or state.get("configHash") != binding_hash(config)):
        raise ValueError("Foreign/changed federation manifest")
    assets = state["assets"]
    if not isinstance(assets, list) or len(assets) != 4:
        raise ValueError("Incomplete federation manifest")
    desired = specifications(
        config, assets[0]["body"]["location"], assets[0]["body"]["tags"]["expiresAt"],
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
              location: str, expires_at: str) -> dict[str, Any]:
    desired = specifications(config, location, expires_at)
    if path.exists():
        state = manifest(config, path)
        normalized = json.loads(json.dumps(state["assets"]))
        normalized[-1]["body"]["properties"]["principalId"] = "<owned-identity-principal>"
        for asset in normalized:
            asset.pop("phase", None)
        if normalized != desired or state.get("phase") == "Removed":
            raise ValueError("Federation intent changed; no adoption/recreation")
    else:
        for asset in desired:
            if get_optional(api, resource_path(asset)) is not None:
                raise ValueError("Unowned federation collision; no adoption")
        state = {
            "schemaVersion": 1, "ownerToken": config["binding"]["ownerToken"],
            "configHash": binding_hash(config), "assets": desired, "phase": "Configuring",
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
    parser.add_argument("operation", choices=("spec", "configure", "check", "down"))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--location")
    parser.add_argument("--expires-at")
    args = parser.parse_args()
    config = validate_config(json.loads(args.config.read_text()), ready=False)
    if args.operation in ("spec", "configure") and not (args.location and args.expires_at):
        raise ValueError("Identity location and explicit retention expiry are required")
    if args.operation == "spec":
        print(json.dumps(specifications(config, args.location, args.expires_at), indent=2))
        return
    if args.state is None:
        raise ValueError("An ignored owner-only federation manifest is required")
    api = Api("https://management.azure.com", arm_token(config))
    lock = args.state.with_suffix(".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        if args.operation == "configure":
            configure(config, args.state, api, args.location, args.expires_at)
        elif args.operation == "check":
            check(config, args.state, api)
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
