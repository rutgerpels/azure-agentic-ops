"""Scenario isolation, packaging and reviewer-gate contracts (no cloud calls)."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCENARIO = ROOT / "scenarios" / "orderflow"


def test_baseline_has_one_narrow_connection():
    rule = json.loads((SCENARIO / "infra" / "network-baseline.json").read_text())
    assert rule["access"] == "Allow"
    assert rule["sourceAddressPrefix"] == "10.42.1.0/24"
    assert rule["destinationAddressPrefix"] == "10.42.2.4"
    assert rule["destinationPortRange"] == "8080"
    assert rule["priority"] == 200
    assert rule["direction"] == "Inbound"


def test_bicep_local_sources_exist():
    for template in (SCENARIO / "infra").glob("*.bicep"):
        text = template.read_text()
        paths = re.findall(r"load(?:TextContent|JsonContent)\('([^']+)'\)", text)
        paths += re.findall(r"\bmodule\s+\w+\s+'([^']+)'", text)
        for path in paths:
            assert (template.parent / path).is_file(), (template, path)


def test_cloud_init_has_no_public_management_or_fault():
    text = (SCENARIO / "infra" / "cloud-init.yml").read_text()
    assert "User=orderflow" in text
    assert "NoNewPrivileges=true" in text
    assert "COSMOS_DATABASE=orderflow" in text
    assert "AZURE_CLIENT_ID=__CLIENT_ID__" in text
    assert "Restart=on-failure" in text
    assert "stress-ng" not in text
    assert "curl |" not in text


def test_publish_is_manual_scoped_and_reviewed():
    text = (ROOT / ".github" / "workflows" / "orderflow-publish.yml").read_text()
    assert "workflow_dispatch:" in text
    assert "pull_request:" not in text
    assert "\n  push:" not in text
    assert "environment: orderflow-publish" in text
    assert "cancel-in-progress: false" in text
    assert "id-token: write" in text
    assert "persist-credentials: false" in text
    assert "ORDERFLOW_APPROVED_SHA" in text
    assert "runs-on: [self-hosted, orderflow]" in text
    assert "Invoke-OrderFlow.ps1" not in text
    for action in re.findall(r"uses:\s+([^\s#]+)", text):
        assert re.search(r"@[a-f0-9]{40}$", action), action


def test_validation_needs_no_cloud_identity():
    text = (ROOT / ".github" / "workflows" / "orderflow-validate.yml").read_text()
    assert "ubuntu-latest" in text
    assert "azure/login" not in text
    assert "id-token:" not in text
    assert "--require-hashes" in text
    assert "scenarios/orderflow/tests" in text
    assert "Test-OrderFlow.ps1" in text


def test_isolated_lifecycle_does_not_import_retailx():
    for script in (SCENARIO / "scripts").glob("*.ps*"):
        assert "scenarios/retailx" not in script.read_text()
        assert "scenarios\\retailx" not in script.read_text()
