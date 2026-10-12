"""Operator-only, exact-owned SRE assets. Never called by the issue workflow."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
from typing import Any

from scripts.github.intake import (
    Api,
    assert_native_ready,
    assert_no_extra_tools,
    canonical,
    digest,
    investigator_spec,
    knowledge_specs,
    object_value,
    sre_token,
    trigger_spec,
    validate_config,
)


def persist(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".pending")
    with temporary.open("w", encoding="utf-8") as file:
        file.write(canonical(state))
        file.flush()
        os.fsync(file.fileno())
    temporary.replace(path)
    if os.name == "posix":
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def get_optional(api: Api, path: str) -> dict[str, Any] | None:
    status, body = api.request("GET", path)
    if status == 404:
        return None
    if status != 200:
        raise RuntimeError(f"Owned asset read HTTP {status}; absence unproven")
    return object_value(body)


def check_asset(live: dict[str, Any], asset: dict[str, Any]) -> None:
    expected = asset["spec"]
    if asset["kind"] == "knowledge":
        properties = object_value(live["properties"])
        metadata = object_value(properties["extendedProperties"])
        content = base64.b64decode(expected["properties"]["extendedProperties"]["fileContent"])
        if (
            live.get("name") != expected["name"] or live.get("type") != "KnowledgeItem"
            or properties.get("dataConnectorType") != "KnowledgeFile"
            or properties.get("dataSource") != expected["name"]
            or metadata.get("metadata.filename")
            != expected["properties"]["extendedProperties"]["fileName"]
            or metadata.get("contentType") != "text/markdown"
            or metadata.get("fileSize") != len(content)
            or metadata.get("displayName")
            != expected["properties"]["extendedProperties"]["displayName"]
        ):
            raise ValueError("Owned knowledge metadata differs; no overwrite/delete")
        # Native GET omits file bytes. Ownership relies additionally on the journal and
        # exact scoped asset name. Metadata equality is never content/retrieval proof.
    elif asset["kind"] == "investigator":
        if live.get("name") != expected["name"]:
            raise ValueError("Investigator identity drift")
        properties = object_value(live["properties"])
        for key, value in expected["properties"].items():
            if properties.get(key) != value:
                raise ValueError(f"Investigator {key} drift; no overwrite/delete")
        assert_no_extra_tools(properties)
    else:
        for key, value in expected.items():
            if live.get(key) != value:
                raise ValueError(f"Trigger {key} drift; no overwrite/delete")
        if live.get("id") != asset["id"]:
            raise ValueError("Trigger ID differs from owned intent")


def inventory(api: Api) -> list[dict[str, Any]]:
    result = api.get("/api/v1/httptriggers")
    if not isinstance(result, list) or len(result) > 1000:
        raise ValueError("Unknown/incomplete native trigger inventory")
    return result


def initialize(config: dict[str, Any], path: Path, api: Api) -> dict[str, Any]:
    validate_config(config, ready=False)
    specs = knowledge_specs(config)
    investigator = investigator_spec(config)
    trigger = trigger_spec(config)
    desired: list[dict[str, Any]] = [
        {"kind": "knowledge", "spec": spec,
         "path": f"/api/v2/extendedAgent/connectors/{spec['name']}"}
        for spec in specs
    ] + [
        {"kind": "investigator", "spec": investigator,
         "path": f"/api/v2/extendedAgent/agents/{investigator['name']}"},
        {"kind": "trigger", "spec": trigger},
    ]
    if path.exists():
        state = object_value(json.loads(path.read_text(encoding="utf-8")))
        if (state.get("ownerToken") != config["binding"]["ownerToken"]
                or state.get("bindingHash") != digest(config["binding"])
                or state.get("endpoint") != config["endpoint"]
                or [{k: a[k] for k in ("kind", "spec")} for a in state["assets"]]
                != [{k: a[k] for k in ("kind", "spec")} for a in desired]
                or state.get("phase") == "Removed"):
            raise ValueError("Ownership/content changed; never adopt/recreate uncertain assets")
    else:
        # Validate ALL collisions before recording intent or creating the first object.
        for asset in desired[:-1]:
            if get_optional(api, asset["path"]) is not None:
                raise ValueError("Unowned asset collision; no adoption")
        if any(item.get("name") == trigger["name"] for item in inventory(api)):
            raise ValueError("Unowned trigger collision")
        state = {
            "schemaVersion": 1, "ownerToken": config["binding"]["ownerToken"],
            "bindingHash": digest(config["binding"]), "endpoint": config["endpoint"],
            "assets": desired, "phase": "Configuring",
        }
        persist(path, state)
    for asset in state["assets"]:
        phase = asset.get("phase")
        if asset["kind"] == "trigger":
            matches = [item for item in inventory(api) if item.get("name") == trigger["name"]]
            if len(matches) > 1:
                raise ValueError("Ambiguous trigger inventory")
            if matches:
                asset["id"] = matches[0]["id"]
                asset["path"] = f"/api/v1/httptriggers/{asset['id']}"
                live = get_optional(api, asset["path"])
            else:
                live = None
        else:
            live = get_optional(api, asset["path"])
        if live is not None:
            if phase is None:
                raise ValueError("Late unowned collision; no adoption")
            if asset["kind"] == "trigger" and phase == "Requested":
                disable_created_trigger(api, asset, live)
                live = get_optional(api, asset["path"])
                if live is None:
                    raise RuntimeError("Owned trigger disappeared during safe configuration")
            check_asset(live, asset)
        elif phase is not None:
            raise RuntimeError("Requested asset absent/uncertain; no create replay")
        else:
            asset["phase"] = "Requested"
            persist(path, state)
            if asset["kind"] == "trigger":
                status, _ = api.request("POST", "/api/v1/httptriggers/create", asset["spec"])
                if status not in (200, 201):
                    raise RuntimeError("Trigger create uncertain; reconcile GET, never replay POST")
                matches = [item for item in inventory(api) if item.get("name") == trigger["name"]]
                if len(matches) != 1:
                    raise RuntimeError("Created trigger identity unresolved; no replay")
                asset["id"] = matches[0]["id"]
                asset["path"] = f"/api/v1/httptriggers/{asset['id']}"
                persist(path, state)
            else:
                status, _ = api.request("PUT", asset["path"], asset["spec"])
                if status not in (200, 201, 204):
                    raise RuntimeError("Owned PUT uncertain; reconcile GET without blind replay")
            live = get_optional(api, asset["path"])
            if live is None:
                raise RuntimeError("Owned asset readback absent; no readiness")
            if asset["kind"] == "trigger":
                disable_created_trigger(api, asset, live)
                live = get_optional(api, asset["path"])
                if live is None:
                    raise RuntimeError("Owned trigger disappeared during safe configuration")
            check_asset(live, asset)
        asset["phase"] = "MetadataVerified" if asset["kind"] == "knowledge" else "Verified"
        persist(path, state)
    state["phase"] = "ConfiguredNotLiveAccepted"
    persist(path, state)
    return state


def disable_created_trigger(
    api: Api, asset: dict[str, Any], live: dict[str, Any]
) -> None:
    expected = asset["spec"]
    if (
        live.get("id") != asset["id"] or live.get("name") != expected["name"]
        or live.get("description") != expected["description"]
    ):
        raise ValueError("Cannot disable a foreign/unbound trigger")
    if live.get("triggerEnabled") is False:
        return
    if live.get("triggerEnabled") is not True:
        raise ValueError("Unknown native trigger enabled contract")
    status, _ = api.request("POST", asset["path"] + "/disable")
    if status not in (200, 204):
        raise RuntimeError("Owned trigger disable uncertain; no activation/readiness")
    disabled = get_optional(api, asset["path"])
    if disabled is None or disabled.get("triggerEnabled") is not False:
        raise RuntimeError("Owned trigger disabled state unverified")


def check(config: dict[str, Any], path: Path, api: Api, retrieval: Path) -> None:
    validate_config(config)
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    if (state["ownerToken"] != config["binding"]["ownerToken"]
            or state["bindingHash"] != digest(config["binding"])
            or state["endpoint"] != config["endpoint"] or state["phase"] == "Removed"):
        raise ValueError("Lifecycle manifest does not bind current configuration")
    for asset in state["assets"]:
        live = get_optional(api, asset["path"])
        if live is None:
            raise ValueError("Owned asset missing")
        check_asset(live, asset)
    assert_native_ready(api, config)
    evidence = object_value(json.loads(retrieval.read_text(encoding="utf-8")))
    expected_hashes = {
        asset["spec"]["name"]: hashlib.sha256(
            base64.b64decode(asset["spec"]["properties"]["extendedProperties"]["fileContent"])
        ).hexdigest()
        for asset in state["assets"] if asset["kind"] == "knowledge"
    }
    if (evidence.get("agentId") != config["binding"]["agentId"]
            or evidence.get("ownerToken") != state["ownerToken"]
            or evidence.get("sourceHashes") != expected_hashes
            or evidence.get("method") != "native-memory-search"
            or not isinstance(evidence.get("results"), list)
            or not 1 <= len(evidence["results"]) <= 100
            or any(not isinstance(result, str) or not result for result in evidence["results"])):
        raise ValueError("Missing exact-source native retrieval evidence")
    results = canonical(evidence["results"])
    required = [
        "native-fixture-observation-clock-v1", "native-fixture-differential-v1",
        *[f"knowledge_{name}.md" for name in expected_hashes],
        "github-investigation-v1",
    ]
    if not all(value in results for value in required):
        raise ValueError("Upload metadata/citations are not actual native knowledge retrieval")
    state["phase"] = "ConfigurationAndRetrievalCheckedNotLiveAccepted"
    persist(path, state)


def remove(config: dict[str, Any], path: Path, api: Api) -> None:
    state = object_value(json.loads(path.read_text(encoding="utf-8")))
    if (state["ownerToken"] != config["binding"]["ownerToken"]
            or state["bindingHash"] != digest(config["binding"])
            or state["endpoint"] != config["endpoint"]):
        raise ValueError("Foreign lifecycle manifest")
    assets = state["assets"]
    # Reconcile a once-submitted trigger whose create response was lost.
    for asset in assets:
        if asset["kind"] == "trigger" and "path" not in asset:
            matches = [item for item in inventory(api) if item.get("name") == asset["spec"]["name"]]
            if len(matches) > 1:
                raise ValueError("Ambiguous late trigger; no teardown")
            if matches:
                asset["id"] = matches[0]["id"]
                asset["path"] = f"/api/v1/httptriggers/{asset['id']}"
    live_assets = []
    for asset in assets:
        if "path" not in asset:
            continue
        live = get_optional(api, asset["path"])
        if live is not None:
            if not asset.get("phase"):
                raise ValueError("Unowned late collision; no deletion")
            check_asset(live, asset)
            live_assets.append(asset)
        elif asset.get("phase") == "Requested":
            raise RuntimeError("Requested asset still uncertain/absent; late creation not excluded")
    if any(asset.get("phase") == "Requested" and "path" not in asset for asset in assets):
        raise RuntimeError("Trigger create outcome unknown; no absence/removal claim")
    state["phase"] = "Removing"
    persist(path, state)
    for asset in reversed(live_assets):
        status, _ = api.request("DELETE", asset["path"])
        if status not in (200, 202, 204):
            raise RuntimeError("Owned deletion uncertain; preserve manifest for reconciliation")
        if get_optional(api, asset["path"]) is not None:
            raise RuntimeError("Owned absence unverified; no removed claim")
    # The last observation is complete, not merely successful DELETE status.
    for asset in assets:
        if "path" in asset and get_optional(api, asset["path"]) is not None:
            raise RuntimeError("Residual owned asset remains")
    if any(item.get("name") == assets[-1]["spec"]["name"] for item in inventory(api)):
        raise RuntimeError("Residual/late trigger remains")
    state["phase"] = "Removed"
    persist(path, state)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("configure", "check", "down"))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--retrieval-evidence", type=Path)
    args = parser.parse_args()
    config = validate_config(json.loads(args.config.read_text(encoding="utf-8")), ready=False)
    api = Api(config["endpoint"], sre_token(config))
    # Exclusive local admission across operator configure/check/down, not issue runtime.
    lock = args.state.with_suffix(".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        if args.operation == "configure":
            initialize(config, args.state, api)
        elif args.operation == "check":
            if args.retrieval_evidence is None:
                raise ValueError("Readiness requires separate native retrieval evidence")
            check(config, args.state, api, args.retrieval_evidence)
        else:
            remove(config, args.state, api)
    finally:
        os.close(descriptor)
        lock.unlink()


if __name__ == "__main__":
    main()
