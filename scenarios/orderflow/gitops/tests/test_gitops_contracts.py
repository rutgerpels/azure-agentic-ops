"""Offline GitOps packaging and infrastructure contracts (no Azure or GitHub calls)."""

import importlib.util
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
GITOPS = ROOT / "scenarios" / "orderflow" / "gitops"
APP = ROOT / "scenarios" / "orderflow" / "app"
INFRA = GITOPS / "infra"
spec = importlib.util.spec_from_file_location("ofg_image_tag", GITOPS / "tools" / "image_tag.py")
image_tag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image_tag)
TEMPLATES = sorted(INFRA.rglob("*.bicep"))


def text(path):
    return Path(path).read_text(encoding="utf-8")


def copy_inputs(target):
    for relative in image_tag.inputs(ROOT):
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, destination)


def test_image_tag_is_deterministic_and_well_formed(capsys):
    tag = image_tag.compute()
    assert re.fullmatch(r"sha-[0-9a-f]{16}", tag)
    assert image_tag.compute(ROOT) == tag
    assert image_tag.main([]) == 0
    assert capsys.readouterr().out.strip() == tag
    inputs = image_tag.inputs(ROOT)
    assert inputs == sorted(inputs)
    assert "scenarios/orderflow/app/smoke.py" in inputs
    assert "scenarios/orderflow/gitops/container/Dockerfile" in inputs
    assert "scenarios/orderflow/app/static/app.js" in inputs


def test_image_tag_normalizes_crlf_and_tracks_content(tmp_path):
    copy_inputs(tmp_path)
    original = image_tag.compute(tmp_path)
    portal = tmp_path / "scenarios" / "orderflow" / "app" / "portal.py"
    portal.write_bytes(portal.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
    assert image_tag.compute(tmp_path) == original
    portal.write_bytes(portal.read_bytes() + b"# change\r\n")
    assert image_tag.compute(tmp_path) != original
    portal.write_bytes(portal.read_bytes()[: -len(b"# change\r\n")])
    (tmp_path / "scenarios" / "orderflow" / "app" / "static" / "extra.txt").write_text("x")
    assert image_tag.compute(tmp_path) != original


def test_image_tag_missing_input_exits_2(tmp_path):
    assert image_tag.main(["--root", str(tmp_path)]) == 2


def test_bicep_local_references_exist():
    assert {p.name for p in TEMPLATES} >= {"shared.bicep", "env.bicep", "sre.bicep"}
    for template in TEMPLATES:
        body = text(template)
        paths = re.findall(r"load(?:TextContent|JsonContent)\('([^']+)'\)", body)
        paths += re.findall(r"\bmodule\s+\w+\s+'([^']+)'", body)
        for path in paths:
            assert (template.parent / path).is_file(), (template, path)
    for params in (GITOPS / "deploy").glob("*.bicepparam"):
        using = re.search(r"^using '([^']+)'", text(params), re.M).group(1)
        assert (params.parent / using).resolve() == INFRA / "env.bicep"


def test_env_uses_inline_rules_and_process_only_probes():
    body = text(INFRA / "env.bicep")
    assert "loadJsonContent('../deploy/network-rules.json').rules" in body
    inline = ("securityRules: [for rule in networkRules: "
              "{ name: rule.name, properties: rule.properties }]")
    assert inline in body
    assert "networkSecurityGroups/securityRules@" not in body
    probes = body[body.index("func tcpProbes"):body.index("resource registry")]
    assert probes.count("tcpSocket") == 3
    for forbidden in ("httpGet", "cosmos", "/api/"):
        assert forbidden not in probes.lower()
    assert "httpGet" not in body
    assert body.count("probes: tcpProbes(") == 2
    assert body.count("activeRevisionsMode: 'Single'") == 2
    assert "{ name: 'DEPLOY_SHA', value: deploySha }" in body
    assert "var apiUrl = 'http://orderflow-api'" in body
    assert "triggerType: 'Manual'" in body and "replicaRetryLimit: 0" in body
    assert "replicaTimeout: 120" in body
    assert "workloadProfileType: 'Consumption'" in body
    assert "ipAddressRange: presenterRange" in body
    assert "if (alertsEnabled)" in body
    assert "roleAssignments" not in body
    assert "0.0.0.0/0" not in body


def test_shared_security_posture_and_least_privilege():
    body = text(INFRA / "shared.bicep")
    assert "disableLocalAuth: true" in body
    assert "adminUserEnabled: false" in body
    assert "anonymousPullEnabled: false" in body
    assert "EnableServerless" in body
    assert "scope: '${cosmos.id}/dbs/orderflow-${stage}'" in body
    assert "targetScope = 'resourceGroup'" in body
    assert "subscription()" not in body.replace("uniqueString(subscription().id", "")
    assert body.count("roles.acrPush)") == 2  # name guid + definition of one assignment
    assert "deployIdentities[0].properties.principalId" in body
    assert "https://token.actions.githubusercontent.com" in body
    assert "api://AzureADTokenExchange" in body
    assert "repo:${githubRepository}:environment:orderflow-prod" in body
    assert "repo:${githubRepository}:environment:orderflow-test" in body
    assert "roleIds: [roles.contributor]" in body


def test_sre_is_read_only():
    body = text(INFRA / "sre.bicep")
    for forbidden in ("b24988ac-6180-42a0-ab88-20f7382dd24c", "roleDefinitions@",
                      "securityRules", "4d97b98b-1d4f-4787-a291-c67834d212e7"):
        assert forbidden not in body
    assert "mode: 'Review'" in body
    assert "e79298df-d852-4c6d-84f9-5d13249d1e55" in body
    assert "Microsoft.App/agents@2026-01-01" in body


def test_dockerfile_is_non_root_and_copies_only_image_tag_inputs():
    body = text(GITOPS / "container" / "Dockerfile")
    assert body.startswith("# Build context: scenarios/orderflow/app")
    assert re.search(r"^FROM python:3\.12-slim", body, re.M)
    user = re.findall(r"^USER\s+(\S+)", body, re.M)
    assert user and user[-1] not in ("root", "0")
    assert "pip install --no-cache-dir -r requirements.txt" in body
    assert "|" not in body.replace("||", "")
    assert "curl" not in body and "wget" not in body
    assert "EXPOSE 8000 8080" in body
    assert 'CMD ["gunicorn", "portal:app"' in body
    copied = set()
    for line in re.findall(r"^COPY\s+(.+)$", body, re.M):
        copied.update(line.split()[:-1])
    assert copied == {"requirements.txt", "backend.py", "common.py", "portal.py", "smoke.py",
                      "static/"}
    for name in copied:
        assert (APP / name).exists()
    ignored = text(APP / ".dockerignore")
    assert ".venv/" in ignored and "tests/" in ignored


def test_app_targets_match_infrastructure():
    portal = text(APP / "portal.py")
    smoke = text(APP / "smoke.py")
    assert '"http://orderflow-api"' in portal
    assert 'SMOKE_API = "http://orderflow-api"' in smoke
    env = text(INFRA / "env.bicep")
    assert "command: ['python', 'smoke.py']" in env
    assert "args: ['backend:app', '--host', '0.0.0.0', '--port', '8080']" in env


def test_parameter_files_hold_no_live_identifiers():
    guid = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
    for name, prefix, alerts in (("prod", "10.60.0.0/24", "true"),
                                 ("test", "10.61.0.0/24", "false")):
        body = text(GITOPS / "deploy" / f"{name}.bicepparam")
        assert f"param stage = '{name}'" in body
        assert f"param addressPrefix = '{prefix}'" in body
        assert f"param alertsEnabled = {alerts}" in body
        assert not guid.search(body)
        assert "0.0.0.0/0" not in body
        for variable in ("ORDERFLOW_SHARED_RG", "ORDERFLOW_SUFFIX", "ORDERFLOW_PRESENTER_CIDR",
                         "ORDERFLOW_IMAGE_TAG", "ORDERFLOW_DEPLOY_SHA", "ORDERFLOW_OWNER_TOKEN",
                         "ORDERFLOW_ENVIRONMENT_NAME"):
            assert f"readEnvironmentVariable('{variable}')" in body
