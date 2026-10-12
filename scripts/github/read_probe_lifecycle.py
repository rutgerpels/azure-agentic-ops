"""Operator-only finite lifecycle for new read-probe assets, never native configuration."""

from __future__ import annotations

import argparse
import json
import os
import shutil
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from scripts.github.federation import AUTH_VERSION, resource_path, validate_asset
from scripts.github.intake import Api, azure_cli_executable, canonical, digest, object_value, utc
from scripts.github.lifecycle import get_optional, persist
from scripts.github.read_probe import (
    CALLERS,
    ENVIRONMENT,
    SLOTS,
    Code,
    Stage,
    bound_assets,
    capture,
    emit,
    guid,
    runtime_snapshot,
    specifications,
    validate,
    validate_snapshot,
)

BRANCH_POLICY = {"name": "main", "type": "branch"}
ENVIRONMENT_BODY = {
    "wait_timer": 0, "reviewers": [],
    "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
}
CREATE_PHASES = ("CreateRequested", "Verified")
PHASES = (*CREATE_PHASES, "DeleteRequested", "Absent")


def environment_path(config: dict[str, Any]) -> str:
    return f"/repos/{config['native']['repository']}/environments/{ENVIRONMENT}"


def gh_executable() -> str:
    executable = shutil.which("gh")
    if executable is None:
        raise RuntimeError("Existing operator GitHub CLI authentication required")
    return str(Path(executable).resolve())


def set_secret(config: dict[str, Any], slot: str, value: str) -> None:
    if slot not in SLOTS:
        raise ValueError("Unexpected probe secret slot")
    capture([
        gh_executable(), "secret", "set", slot, "--repo", config["native"]["repository"],
        "--env", ENVIRONMENT,
    ], input_text=value)


def repository_check(config: dict[str, Any], github: Api) -> None:
    native = config["native"]
    repo = object_value(github.get(f"/repos/{native['repository']}"))
    if (
        repo.get("full_name") != native["repository"] or repo.get("id") != native["repositoryId"]
        or object_value(repo["owner"]).get("id") != native["oidc"]["repositoryOwnerId"]
        or repo["owner"].get("login") != native["repository"].split("/")[0]
        or repo.get("default_branch") != "main" or repo.get("private") is not False
    ):
        raise ValueError("Repository immutable/default branch binding drift")
    gate = get_optional(
        github, f"/repos/{native['repository']}/actions/variables/SRE_READ_PROBE_ENABLED",
    )
    if gate is not None and (
        gate.get("name") != "SRE_READ_PROBE_ENABLED" or gate.get("value") != "false"
    ):
        raise ValueError("Operator must unset/disable the repository probe gate first")


def list_values(api: Api, path: str, field: str) -> list[dict[str, Any]]:
    body = object_value(api.get(path))
    values = body.get(field)
    if not isinstance(values, list) or len(values) > 100:
        raise ValueError("Bounded complete inventory required")
    if body.get("nextLink") or body.get("total_count", len(values)) != len(values):
        raise ValueError("Incomplete inventory; no paging/truncation assumption")
    for value in values:
        object_value(value)
    return values


def environment_identity(live: dict[str, Any]) -> dict[str, Any]:
    if (
        live.get("name") != ENVIRONMENT or type(live.get("id")) is not int or live["id"] <= 0
        or not isinstance(live.get("node_id"), str) or not live["node_id"]
        or not isinstance(live.get("created_at"), str)
        or live.get("deployment_branch_policy") != ENVIRONMENT_BODY["deployment_branch_policy"]
        or not isinstance(live.get("protection_rules"), list)
        or any(rule.get("type") != "branch_policy" for rule in live["protection_rules"])
    ):
        raise ValueError("Probe environment identity/protection drift")
    return {key: live[key] for key in ("id", "node_id", "created_at", "protection_rules")}


def manifest(config: dict[str, Any], path: Path) -> dict[str, Any]:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    if (
        state.get("schemaVersion") != 1 or state.get("configHash") != digest(validate(config))
        or state.get("ownerToken") != config["ownerToken"]
        or state.get("environmentPath") != environment_path(config)
    ):
        raise ValueError("Foreign or changed probe manifest")
    identities = object_value(state["identities"])
    if set(identities) - set(CALLERS):
        raise ValueError("Foreign caller")
    desired = specifications(config)
    for caller, identity in identities.items():
        if set(identity) != {"clientId", "principalId", "tenantId"}:
            raise ValueError("Malformed immutable identity journal")
        for value in identity.values():
            guid(value)
        if identity["tenantId"] != config["tenantId"]:
            raise ValueError("Foreign tenant")
        for asset in desired:
            if asset["caller"] == caller and asset["kind"] == "assignment":
                asset["body"]["properties"]["principalId"] = identity["principalId"]
    if len(identities) == 2:
        bound_assets(config, identities)
    assets = state["assets"]
    if (
        not isinstance(assets, list) or len(assets) != 8
        or [{key: value for key, value in item.items() if key != "phase"} for item in assets]
        != desired or any(item.get("phase") not in (None, *PHASES) for item in assets)
    ):
        raise ValueError("Probe intent paths, permissions or phases drift")
    env = object_value(state["github"])
    if env.get("phase") not in (None, *PHASES):
        raise ValueError("Unknown environment phase")
    if env["policy"].get("phase") not in (None, *CREATE_PHASES):
        raise ValueError("Unknown policy phase")
    if set(env["secrets"]) != set(SLOTS):
        raise ValueError("Unknown secret inventory")
    for item in env["secrets"].values():
        if item.get("phase") not in (None, "WriteRequested", "Acknowledged", "Verified"):
            raise ValueError("Unknown secret write phase")
    if "runtime" in state:
        expected = runtime_snapshot(config, identities, state["runtime"]["checkedAt"])
        if state["runtime"] != expected:
            raise ValueError("Private runtime snapshot drift")
    return state


def identity_binding(config: dict[str, Any], state: dict[str, Any],
                     asset: dict[str, Any], live: dict[str, Any]) -> None:
    validate_asset(asset, live)
    if asset["kind"] == "assignment":
        properties = live["properties"]
        if (
            properties.get("scope", config["native"]["binding"]["agentId"])
            != config["native"]["binding"]["agentId"]
            or properties.get("condition") is not None
            or properties.get("conditionVersion") is not None
            or properties.get("delegatedManagedIdentityResourceId") is not None
        ):
            raise ValueError("Conditional/delegated/foreign assignment")
    if asset["kind"] != "identity":
        return
    identity = {key: live["properties"][key] for key in ("clientId", "principalId", "tenantId")}
    for value in identity.values():
        guid(value)
    if identity["tenantId"] != config["tenantId"]:
        raise ValueError("Unexpected identity tenant")
    caller = asset["caller"]
    recorded = state["identities"].get(caller)
    if recorded is not None and recorded != identity:
        raise ValueError("Immutable client/principal/tenant changed; no adoption")
    other = state["identities"].get("candidate" if caller == "baseline" else "baseline")
    if other and any(other[key] == identity[key] for key in ("clientId", "principalId")):
        raise ValueError("Probe callers share identity")
    state["identities"][caller] = identity
    for owned in state["assets"]:
        if owned["caller"] == caller and owned["kind"] == "assignment":
            owned["body"]["properties"]["principalId"] = identity["principalId"]


def arm_observations(config: dict[str, Any], state: dict[str, Any], arm: Api,
                     *, complete: bool) -> list[dict[str, Any]]:
    live_assets = []
    for asset in state["assets"]:
        live = get_optional(arm, resource_path(asset))
        phase = asset.get("phase")
        if live is None:
            if phase in CREATE_PHASES or complete:
                raise RuntimeError("Create/missing outcome uncertain; no absence/readiness")
            continue
        if phase not in (*CREATE_PHASES, "DeleteRequested"):
            raise ValueError("Unowned late collision; no adoption/deletion")
        identity_binding(config, state, asset, live)
        live_assets.append(asset)
    return live_assets


def audit_callers(config: dict[str, Any], state: dict[str, Any], arm: Api) -> None:
    """Fresh subscription inventory for each new principal; no inherited/extra grants accepted."""
    prefix = f"/subscriptions/{config['native']['binding']['subscriptionId']}"
    for caller in CALLERS:
        principal = state["identities"][caller]["principalId"]
        query = urlencode({"api-version": AUTH_VERSION, "$filter": f"principalId eq '{principal}'"})
        assignments = list_values(
            arm, prefix + "/providers/Microsoft.Authorization/roleAssignments?" + query, "value",
        )
        expected = next(asset for asset in state["assets"]
                        if asset["caller"] == caller and asset["kind"] == "assignment")
        if len(assignments) != 1:
            raise ValueError("Extra/missing caller assignments; no controlled A/B comparison")
        identity_binding(config, state, expected, assignments[0])
        identity = next(asset for asset in state["assets"]
                        if asset["caller"] == caller and asset["kind"] == "identity")
        fics = list_values(
            arm, identity["id"] + "/federatedIdentityCredentials?api-version=" + (
                identity["apiVersion"]
            ), "value",
        )
        fic = next(asset for asset in state["assets"]
                   if asset["caller"] == caller and asset["kind"] == "federation")
        if len(fics) != 1:
            raise ValueError("Extra/missing federation; no controlled A/B comparison")
        validate_asset(fic, fics[0])


def audit_inverse(config: dict[str, Any], state: dict[str, Any], arm: Api) -> None:
    """Allow missing owned children during teardown, never foreign grants/federation."""
    prefix = f"/subscriptions/{config['native']['binding']['subscriptionId']}"
    for caller, recorded in state["identities"].items():
        query = urlencode({
            "api-version": AUTH_VERSION, "$filter": f"principalId eq '{recorded['principalId']}'",
        })
        assignments = list_values(
            arm, prefix + "/providers/Microsoft.Authorization/roleAssignments?" + query, "value",
        )
        expected = next(asset for asset in state["assets"]
                        if asset["caller"] == caller and asset["kind"] == "assignment")
        if len(assignments) > 1 or (assignments and expected.get("phase") not in (
            *CREATE_PHASES, "DeleteRequested",
        )):
            raise ValueError("Foreign assignment inventory; no inverse deletion")
        for assignment in assignments:
            identity_binding(config, state, expected, assignment)
        identity = next(asset for asset in state["assets"]
                        if asset["caller"] == caller and asset["kind"] == "identity")
        if get_optional(arm, resource_path(identity)) is None:
            continue
        fics = list_values(
            arm, identity["id"] + "/federatedIdentityCredentials?api-version=" + (
                identity["apiVersion"]
            ), "value",
        )
        fic = next(asset for asset in state["assets"]
                   if asset["caller"] == caller and asset["kind"] == "federation")
        if len(fics) > 1 or (fics and fic.get("phase") not in (
            *CREATE_PHASES, "DeleteRequested",
        )):
            raise ValueError("Foreign federation inventory; no parent deletion")
        for live in fics:
            validate_asset(fic, live)


def residual(path: Path, state: dict[str, Any], kind: str) -> None:
    state["residualKinds"] = sorted({*state.get("residualKinds", []), kind})
    persist(path, state)


def github_observations(config: dict[str, Any], state: dict[str, Any], github: Api,
                        *, complete: bool) -> dict[str, Any] | None:
    path = environment_path(config)
    env = state["github"]
    live = get_optional(github, path)
    if live is None:
        if env.get("phase") in CREATE_PHASES or complete:
            raise RuntimeError("Environment create/absence uncertain")
        return None
    if env.get("phase") not in (*CREATE_PHASES, "DeleteRequested"):
        raise ValueError("Unowned environment collision")
    identity = environment_identity(live)
    if "identity" in env and identity != env["identity"]:
        raise ValueError("Immutable environment identity/protection replaced")
    env["identity"] = identity
    policies = list_values(
        github, path + "/deployment-branch-policies?per_page=100", "branch_policies",
    )
    policy = env["policy"]
    if policies:
        if len(policies) != 1 or policy.get("phase") not in CREATE_PHASES:
            raise ValueError("Unowned/extra branch policy")
        found = policies[0]
        if (
            any(found.get(key) != value for key, value in BRANCH_POLICY.items())
            or type(found.get("id")) is not int or found["id"] <= 0
            or ("id" in policy and policy["id"] != found["id"])
        ):
            raise ValueError("Main branch-only policy identity drift")
        policy["id"] = found["id"]
    elif policy.get("phase") in CREATE_PHASES or complete:
        raise RuntimeError("Branch policy create outcome uncertain")
    secrets = list_values(github, path + "/secrets?per_page=100", "secrets")
    if len({item.get("name") for item in secrets}) != len(secrets):
        raise ValueError("Ambiguous secret inventory")
    for item in secrets:
        slot = item["name"]
        if slot not in SLOTS or not env["secrets"][slot].get("phase"):
            raise ValueError("Unowned secret collision/addition")
        if any(not isinstance(item.get(key), str) for key in ("created_at", "updated_at")):
            raise ValueError("Incomplete secret metadata")
        recorded = env["secrets"][slot].get("metadata")
        if recorded is not None and recorded != item:
            raise ValueError("Acknowledged secret metadata drift")
    if complete and ({item["name"] for item in secrets} != set(SLOTS) or any(
        env["secrets"][slot].get("phase") != "Verified" for slot in SLOTS
    )):
        raise RuntimeError("Secret write uncertainty; metadata is not value verification")
    if list_values(github, path + "/variables?per_page=100", "variables"):
        raise ValueError("Unowned environment variables; no teardown")
    return live


def configure(config: dict[str, Any], path: Path, arm: Api, github: Api) -> dict[str, Any]:
    validate(config)
    if utc(config["expiresAt"]) <= datetime.now(UTC):
        raise ValueError("Retention expiry must be future")
    repository_check(config, github)
    if path.exists():
        state = manifest(config, path)
        if state["phase"] in ("Removing", "Removed"):
            raise ValueError("No recreation/reuse after teardown intent")
    else:
        assets = specifications(config)
        if any(get_optional(arm, resource_path(asset)) is not None for asset in assets):
            raise ValueError("Unowned ARM collision")
        if get_optional(github, environment_path(config)) is not None:
            raise ValueError("Unowned GitHub environment collision")
        state = {
            "schemaVersion": 1, "configHash": digest(config), "ownerToken": config["ownerToken"],
            "assets": assets, "identities": {}, "environmentPath": environment_path(config),
            "github": {"policy": {}, "secrets": {slot: {} for slot in SLOTS}},
            "phase": "Configuring",
        }
        persist(path, state)
    arm_observations(config, state, arm, complete=False)
    github_observations(config, state, github, complete=False)
    persist(path, state)
    for asset in state["assets"]:
        live = get_optional(arm, resource_path(asset))
        if live is not None:
            if asset.get("phase") not in CREATE_PHASES:
                raise ValueError("Late ARM collision")
            identity_binding(config, state, asset, live)
        elif asset.get("phase"):
            raise RuntimeError("ARM request uncertain; never replay")
        else:
            # Recheck all preceding bindings before adding another owned asset.
            arm_observations(config, state, arm, complete=False)
            asset["phase"] = "CreateRequested"
            persist(path, state)
            status, _ = arm.request("PUT", resource_path(asset), asset["body"])
            if status not in (200, 201, 204):
                raise RuntimeError("ARM write uncertain; reconcile GET only")
            live = get_optional(arm, resource_path(asset))
            if live is None:
                raise RuntimeError("ARM readback missing")
            identity_binding(config, state, asset, live)
        asset["phase"] = "Verified"
        persist(path, state)
    audit_callers(config, state, arm)
    env = state["github"]
    env_path = environment_path(config)
    live = github_observations(config, state, github, complete=False)
    if live is None:
        if env.get("phase"):
            raise RuntimeError("Environment request uncertain; never replay")
        env["phase"] = "CreateRequested"
        persist(path, state)
        status, _ = github.request("PUT", env_path, ENVIRONMENT_BODY)
        if status != 200:
            raise RuntimeError("Environment write uncertain")
        live = github_observations(config, state, github, complete=False)
        if live is None:
            raise RuntimeError("Environment readback missing")
    env["phase"] = "Verified"
    persist(path, state)
    policy = env["policy"]
    if "id" not in policy:
        if policy.get("phase"):
            raise RuntimeError("Policy request uncertain; never replay")
        github_observations(config, state, github, complete=False)
        policy["phase"] = "CreateRequested"
        persist(path, state)
        status, _ = github.request("POST", env_path + "/deployment-branch-policies", BRANCH_POLICY)
        if status != 200:
            raise RuntimeError("Policy create uncertain")
        github_observations(config, state, github, complete=False)
        if "id" not in policy:
            raise RuntimeError("Policy identity readback missing")
    policy["phase"] = "Verified"
    persist(path, state)
    if "runtime" not in state:
        # This attestation is intentionally short-lived and cannot be refreshed/replayed.
        arm_observations(config, state, arm, complete=True)
        audit_callers(config, state, arm)
        state["runtime"] = runtime_snapshot(
            config, state["identities"], datetime.now(UTC).isoformat(),
        )
        persist(path, state)
    values = {
        SLOTS[0]: state["identities"]["baseline"]["clientId"],
        SLOTS[1]: state["identities"]["candidate"]["clientId"],
        SLOTS[2]: config["tenantId"], SLOTS[3]: canonical(state["runtime"]),
    }
    for slot in SLOTS:
        item = env["secrets"][slot]
        github_observations(config, state, github, complete=False)
        current = get_optional(github, env_path + "/secrets/" + slot)
        if item.get("phase") == "Verified":
            if item["valueHash"] != digest(values[slot]) or current != item["metadata"]:
                raise ValueError("Secret acknowledgement/configuration drift")
            continue
        if item.get("phase") == "WriteRequested":
            raise RuntimeError("Unreadable secret write outcome unknown; never replay")
        if not item.get("phase"):
            if current is not None:
                raise ValueError("Unowned secret slot")
            item.update(phase="WriteRequested", valueHash=digest(values[slot]))
            persist(path, state)
            set_secret(config, slot, values[slot])
            item["phase"] = "Acknowledged"
            persist(path, state)
        if item.get("phase") != "Acknowledged":
            raise ValueError("Unknown slot phase")
        current = get_optional(github, env_path + "/secrets/" + slot)
        if current is None or current.get("name") != slot:
            raise RuntimeError("Acknowledged secret metadata missing")
        item.update(phase="Verified", metadata=current)
        persist(path, state)
    check(config, path, arm, github)
    return manifest(config, path)


def check(config: dict[str, Any], path: Path, arm: Api, github: Api) -> None:
    repository_check(config, github)
    state = manifest(config, path)
    if state["phase"] in ("Removing", "Removed"):
        raise ValueError("Teardown manifest is not probe readiness")
    arm_observations(config, state, arm, complete=True)
    audit_callers(config, state, arm)
    github_observations(config, state, github, complete=True)
    validate_snapshot(state["runtime"], datetime.now(UTC))
    state["phase"] = "ProvisioningCheckedNotPermissionAccepted"
    persist(path, state)


def remove(config: dict[str, Any], path: Path, arm: Api, github: Api) -> None:
    repository_check(config, github)
    state = manifest(config, path)
    live_assets = arm_observations(config, state, arm, complete=False)
    live_env = github_observations(config, state, github, complete=False)
    audit_inverse(config, state, arm)
    # Persist newly reconciled immutable identities before any inverse write.
    state["phase"] = "Removing"
    persist(path, state)
    if live_env is not None:
        if state["github"].get("phase") == "DeleteRequested":
            residual(path, state, "environment")
            raise RuntimeError("Environment delete pending/uncertain; no replay")
        state["github"]["phase"] = "DeleteRequested"
        persist(path, state)
        status, _ = github.request("DELETE", environment_path(config))
        if status != 204:
            residual(path, state, "environment")
            raise RuntimeError("Environment deletion uncertain")
        if get_optional(github, environment_path(config)) is not None:
            residual(path, state, "environment")
            raise RuntimeError("Environment residual")
    state["github"]["phase"] = "Absent"
    persist(path, state)
    for asset in reversed(live_assets):
        if asset.get("phase") == "DeleteRequested":
            residual(path, state, asset["kind"])
            raise RuntimeError("ARM delete pending/uncertain; no replay")
        live = get_optional(arm, resource_path(asset))
        if live is None:
            raise RuntimeError("Owned asset disappeared before inverse intent")
        identity_binding(config, state, asset, live)
        asset["phase"] = "DeleteRequested"
        persist(path, state)
        status, _ = arm.request("DELETE", resource_path(asset))
        if status not in (200, 202, 204):
            residual(path, state, asset["kind"])
            raise RuntimeError("ARM deletion uncertain")
        if get_optional(arm, resource_path(asset)) is not None:
            residual(path, state, asset["kind"])
            raise RuntimeError("ARM residual")
        asset["phase"] = "Absent"
        persist(path, state)
    residuals = []
    for asset in state["assets"]:
        if get_optional(arm, resource_path(asset)) is not None:
            residuals.append(asset["kind"])
        elif asset.get("phase") == "CreateRequested":
            raise RuntimeError("Late ARM creation not excluded")
        else:
            asset["phase"] = "Absent"
    if get_optional(github, environment_path(config)) is not None:
        residuals.append("environment")
    audit_inverse(config, state, arm)
    state["residualKinds"] = residuals
    persist(path, state)
    if residuals:
        raise RuntimeError("Probe residuals remain")
    state["phase"] = "Removed"
    persist(path, state)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("configure", "check", "down"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    try:
        if os.environ.get("GITHUB_ACTIONS") == "true":
            raise ValueError("Lifecycle is operator-only")
        config = validate(json.loads(args.config.read_text(encoding="utf-8")))
        arm = Api("https://management.azure.com", capture([
            azure_cli_executable(), "account", "get-access-token", "--resource",
            "https://management.azure.com/", "--subscription",
            config["native"]["binding"]["subscriptionId"], "--query", "accessToken",
            "--output", "tsv", "--only-show-errors",
        ]))
        github = Api("https://api.github.com", capture([
            gh_executable(), "auth", "token", "--hostname", "github.com",
        ]), github=True)
        lock = args.state.with_suffix(".lock")
        lock.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            if args.operation == "configure":
                configure(config, args.state, arm, github)
            elif args.operation == "check":
                check(config, args.state, arm, github)
            else:
                remove(config, args.state, arm, github)
        finally:
            os.close(descriptor)
            lock.unlink()
        emit(Stage.LIFECYCLE, Code.REMOVED if args.operation == "down" else Code.LIFECYCLE)
        return 0
    except Exception:
        # Boundary emits a fixed failure, never provider diagnostics/private ownership data.
        emit(Stage.LIFECYCLE, Code.UNCERTAIN)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
