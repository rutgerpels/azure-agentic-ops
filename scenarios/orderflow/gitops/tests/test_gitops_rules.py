"""Offline tests for the GitOps NSG rule policy checker and the predefined fault."""

import copy
import importlib.util
import json
from pathlib import Path

import pytest

GITOPS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "ofg_check_rules", GITOPS / "tools" / "check_rules.py"
)
check_rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_rules)

BASELINE = json.loads((GITOPS / "deploy" / "baseline" / "network-rules.json").read_text())
FAULT = json.loads((GITOPS / "faults" / "egress-lockdown.json").read_text())


def rule(name, priority, destination, access="Allow", port="443", protocol="Tcp", **extra):
    return {"name": name, "properties": {
        "priority": priority, "direction": "Outbound", "access": access, "protocol": protocol,
        "sourceAddressPrefix": "VirtualNetwork", "sourcePortRange": "*",
        "destinationAddressPrefix": destination, "destinationPortRange": port, **extra,
    }}


def with_rules(*rules):
    document = copy.deepcopy(BASELINE)
    document["rules"].extend(copy.deepcopy(list(rules)))
    return document


def faulted():
    return with_rules(FAULT["rule"])


def destinations(document, access):
    return {r["properties"]["destinationAddressPrefix"] for r in document["rules"]
            if r["properties"]["access"] == access}


def test_baseline_is_compliant_and_deployed_file_matches_baseline():
    assert check_rules.check(BASELINE, BASELINE) == []
    deployed = json.loads((GITOPS / "deploy" / "network-rules.json").read_text())
    assert deployed == BASELINE
    assert check_rules.main([]) == 0


def test_baseline_has_documented_allows_and_no_cosmos():
    expected = {
        "AllowAppsSubnetOutbound": (100, "VirtualNetwork", "*", "*"),
        "AllowMicrosoftContainerRegistry": (110, "MicrosoftContainerRegistry", "443", "Tcp"),
        "AllowAzureFrontDoorFirstParty": (120, "AzureFrontDoor.FirstParty", "443", "Tcp"),
        "AllowAzureActiveDirectory": (130, "AzureActiveDirectory", "443", "Tcp"),
        "AllowAzureMonitor": (140, "AzureMonitor", "443", "Tcp"),
        "AllowAzureContainerRegistry": (150, "AzureContainerRegistry", "443", "Tcp"),
        "AllowStorage": (160, "Storage", "443", "Tcp"),
        "AllowAzureDns": (170, "168.63.129.16", "53", "*"),
    }
    actual = {r["name"]: (r["properties"]["priority"],
                          r["properties"]["destinationAddressPrefix"],
                          r["properties"]["destinationPortRange"],
                          r["properties"]["protocol"]) for r in BASELINE["rules"]}
    assert actual == expected
    assert "AzureCosmosDB" not in json.dumps(BASELINE)
    assert destinations(BASELINE, "Deny") == set()


def test_fault_looks_valid_but_denies_internet_without_cosmos_allow():
    document = faulted()
    assert check_rules.check(document, BASELINE) == []
    assert "Internet" in destinations(document, "Deny")
    assert "AzureCosmosDB" not in destinations(document, "Allow")
    assert FAULT["rule"]["properties"]["priority"] == 4000
    assert FAULT["rule"]["properties"]["description"] == (
        "Enforce documented Container Apps egress allowlist")
    assert FAULT["title"] == "Harden OrderFlow egress: deny unlisted outbound internet traffic"
    assert FAULT["label"] == "orderflow-fault"
    assert FAULT["body"]
    assert FAULT["targetFile"] == "scenarios/orderflow/gitops/deploy/network-rules.json"


def test_fix_forward_and_revert_both_pass():
    fixed = with_rules(rule("AllowAzureCosmosDb", 180, "AzureCosmosDB"), FAULT["rule"])
    assert check_rules.check(fixed, BASELINE) == []
    assert "AzureCosmosDB" in destinations(fixed, "Allow")
    assert check_rules.check(copy.deepcopy(BASELINE), BASELINE) == []


@pytest.mark.parametrize("bad", [
    rule("AllowInternet", 200, "Internet"),
    rule("AllowAnything", 200, "*", port="*", protocol="*"),
    rule("AllowEverywhere", 200, "0.0.0.0/0"),
    rule("DenyDns", 200, "168.63.129.16", access="Deny", port="53", protocol="*"),
    rule("DenyPlatformDns", 200, "AzurePlatformDNS", access="Deny", port="53", protocol="*"),
    rule("DuplicatePriority", 170, "AzureCosmosDB"),
    rule("AllowStorage", 300, "Storage"),
    rule("TooLow", 99, "AzureCosmosDB"),
    rule("TooHigh", 4097, "AzureCosmosDB"),
    rule("BoolPriority", True, "AzureCosmosDB"),
    rule("BadPort", 200, "AzureCosmosDB", port="443;80"),
    rule("BadProtocol", 200, "AzureCosmosDB", protocol="Esp"),
    rule("ExtraKey", 200, "AzureCosmosDB", destinationAddressPrefixes=["Internet"]),
    rule("bad name!", 200, "AzureCosmosDB"),
    {"name": "Inbound", "properties": {**rule("x", 200, "AzureCosmosDB")["properties"],
                                       "direction": "Inbound"}},
    {"name": "AnySource", "properties": {**rule("x", 200, "AzureCosmosDB")["properties"],
                                         "sourceAddressPrefix": "0.0.0.0/0"}},
    {"name": "NoProperties"},
])
def test_forbidden_patterns_fail(bad):
    assert check_rules.check(with_rules(bad), BASELINE)


def test_removed_or_modified_baseline_allow_fails():
    missing = copy.deepcopy(BASELINE)
    missing["rules"] = [r for r in missing["rules"] if r["name"] != "AllowAzureMonitor"]
    assert any("missing" in e for e in check_rules.check(missing, BASELINE))
    modified = copy.deepcopy(BASELINE)
    modified["rules"][1]["properties"]["destinationPortRange"] = "80"
    assert any("modified" in e for e in check_rules.check(modified, BASELINE))
    described = copy.deepcopy(BASELINE)
    described["rules"][1]["properties"]["description"] = "Reworded"
    assert check_rules.check(described, BASELINE) == []


@pytest.mark.parametrize("document", [[], {"rules": []}, {"rules": "x"},
                                      {"rules": [], "extra": 1}])
def test_malformed_documents_fail(document):
    assert check_rules.check(document, BASELINE)


def test_cli_exit_codes(tmp_path, capsys):
    baseline = tmp_path / "baseline.json"
    baseline.write_text(json.dumps(BASELINE))
    good, bad, broken = tmp_path / "good.json", tmp_path / "bad.json", tmp_path / "broken.json"
    good.write_text(json.dumps(faulted()))
    bad.write_text(json.dumps(with_rules(rule("AllowInternet", 200, "Internet"))))
    broken.write_text("{")
    assert check_rules.main([str(good), "--baseline", str(baseline)]) == 0
    assert check_rules.main([str(bad), "--baseline", str(baseline)]) == 1
    assert "too broad" in capsys.readouterr().err
    assert check_rules.main([str(broken), "--baseline", str(baseline)]) == 2
    assert check_rules.main([str(tmp_path / "absent.json"), "--baseline", str(baseline)]) == 2
