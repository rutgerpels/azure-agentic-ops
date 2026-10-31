"""Offline invariants for the OrderFlow GitOps GitHub Actions workflows (no PyYAML needed)."""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
WORKFLOWS = ROOT / ".github" / "workflows"
NAMES = ("ci", "test", "test-deploy", "cd", "handoff")
PINNED = re.compile(r"^[\w.-]+/[\w.-]+(/[\w./-]+)?@[0-9a-f]{40}(\s+#.*)?$")
UNTRUSTED = re.compile(
    r"github\.event\.(pull_request|issue|comment|review)\.(title|body)|github\.head_ref"
    r"|pull_request\.head\.(ref|label)|workflow_run\.(head_branch|display_title|head_commit)"
)


def text(name):
    return (WORKFLOWS / f"orderflow-gitops-{name}.yml").read_text(encoding="utf-8")


def run_blocks(source):
    """Return the script text of every `run:` key (inline or block scalar)."""
    blocks, lines = [], source.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", line)
        if not match:
            continue
        indent, rest = len(match.group(1)), match.group(2)
        if rest and rest[0] not in "|>":
            blocks.append(rest)
            continue
        body = []
        for following in lines[index + 1:]:
            if following.strip() and len(following) - len(following.lstrip()) <= indent:
                break
            body.append(following)
        blocks.append("\n".join(body))
    return blocks


def job(source, name):
    match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  \S|\Z)", source, re.M | re.S)
    assert match, f"job {name} missing"
    return match.group(1)


@pytest.mark.parametrize("name", NAMES)
def test_actions_are_pinned_to_full_shas(name):
    uses = re.findall(r"uses:\s*(\S.*)$", text(name), re.M)
    for value in uses:
        assert PINNED.match(value.strip()), value


@pytest.mark.parametrize("name", NAMES)
def test_checkout_never_persists_credentials(name):
    source = text(name)
    for match in re.finditer(r"uses: actions/checkout@", source):
        assert "persist-credentials: false" in source[match.end():match.end() + 200]


@pytest.mark.parametrize("name", NAMES)
def test_untrusted_text_never_reaches_scripts(name):
    blocks = run_blocks(text(name))
    assert blocks
    for block in blocks:
        assert "${{" not in block, block
    assert not UNTRUSTED.search(text(name))


@pytest.mark.parametrize("name", NAMES)
def test_least_privilege_and_timeouts(name):
    source = text(name)
    assert re.search(r"^permissions:( \{\}|\n  contents: read)\n", source, re.M)
    assert "write-all" not in source and "read-all" not in source
    jobs = re.findall(r"^  [\w-]+:\n", source.split("\njobs:\n", 1)[1], re.M)
    assert source.count("timeout-minutes:") >= len(jobs)


def test_ci_is_offline_and_complete():
    source = text("ci")
    assert "azure/login" not in source and "id-token" not in source
    assert "environment:" not in source
    assert "name: orderflow-gitops-ci" in source
    for expected in (
        "python -m pytest scenarios/orderflow/gitops/tests",
        "ruff check scenarios/orderflow",
        "tools/check_rules.py scenarios/orderflow/gitops/deploy/network-rules.json",
        "az bicep build --file",
        "Test-OrderFlowGitOps.ps1",
        "--require-hashes",
    ):
        assert expected in source, expected


def test_test_gate_is_unprivileged_and_checks_exact_scope():
    source = text("test")
    assert source.startswith("name: OrderFlow GitOps test gate\n")
    assert "types: [opened, synchronize, reopened, ready_for_review]" in source
    assert "- scenarios/orderflow/gitops/deploy/**" in source
    for forbidden in ("id-token", "environment:", "azure/login", ": write", "secrets."):
        assert forbidden not in source, forbidden
    gate = job(source, "gate")
    assert "github.event.pull_request.head.repo.full_name == github.repository" in gate
    assert "github.event.pull_request.user.login == 'Copilot'" in gate
    assert "github.event.pull_request.user.type == 'Bot'" in gate
    assert "contains(github.event.pull_request.labels.*.name, 'orderflow-test-deploy')" in gate
    assert "BASE_SHA: ${{ github.event.pull_request.base.sha }}" in gate
    assert "HEAD_SHA: ${{ github.event.pull_request.head.sha }}" in gate
    assert 'gh api "repos/${REPOSITORY}/compare/${BASE_SHA}...${HEAD_SHA}"' in gate
    assert '[ "$count" -ge 300 ]' in gate
    assert '[ "$changes" != "modified ${RULES_FILE}" ]' in gate
    assert "RULES_FILE: scenarios/orderflow/gitops/deploy/network-rules.json" in gate
    assert "gh pr diff" not in gate
    assert '?ref=${BASE_SHA}" > "$baseline"' in gate
    assert 'check_rules.py "$RULES_FILE" --baseline "$baseline"' in gate


def test_test_deploy_runs_only_from_workflow_run_on_main():
    source = text("test-deploy")
    on = source.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
    assert on.strip() == (
        'workflow_run:\n    workflows: ["OrderFlow GitOps test gate"]\n    types: [completed]'
    )
    assert re.search(r"^permissions:\n  contents: read\n\n", source, re.M)
    resolve = job(source, "resolve")
    for condition in (
        "github.event.workflow_run.conclusion == 'success'",
        "github.event.workflow_run.event == 'pull_request'",
        "github.event.workflow_run.head_repository.full_name == github.repository",
    ):
        assert condition in resolve
    assert "HEAD_SHA: ${{ github.event.workflow_run.head_sha }}" in resolve
    assert 'gh api "repos/${REPOSITORY}/commits/${HEAD_SHA}/pulls"' in resolve
    assert ".head.sha == $sha" in resolve and '.base.ref == "main"' in resolve
    assert '.user.login == "Copilot" and .user.type == "Bot"' in resolve
    assert 'index("orderflow-test-deploy")' in resolve
    assert 'gh api "repos/${REPOSITORY}/compare/main...${HEAD_SHA}"' in resolve
    assert '[ "$changes" != "modified ${RULES_FILE}" ]' in resolve
    assert "id-token" not in resolve and "environment:" not in resolve
    assert source.count("id-token: write") == 1 and source.count("environment:") == 1


def test_test_deploy_never_executes_pull_request_code():
    source = text("test-deploy")
    deploy = job(source, "deploy")
    assert "needs: resolve" in deploy
    assert "if: needs.resolve.outputs.eligible == 'true'" in deploy
    assert "environment: orderflow-test" in deploy
    assert "id-token: write" in deploy and "contents: read" in deploy
    assert "group: orderflow-test\n      cancel-in-progress: false" in deploy
    checkout = deploy.split("actions/checkout@", 1)[1].split("- uses:", 1)[0]
    assert "ref:" not in checkout and "persist-credentials: false" in checkout
    assert source.count("actions/checkout@") == 1
    fetches = re.findall(r"repos/\$\{REPOSITORY\}/contents/(\S+)\?ref=", source)
    assert fetches == ["${RULES_FILE}"]
    assert "RULES_FILE: scenarios/orderflow/gitops/deploy/network-rules.json" in deploy
    assert "Accept: application/vnd.github.raw" in deploy
    assert "python -m json.tool" in deploy
    assert deploy.index("json.tool") < deploy.index("check_rules.py") < deploy.index("azure/login")
    assert "ORDERFLOW_DEPLOY_SHA: ${{ needs.resolve.outputs.head_sha }}" in deploy
    assert "deploy/test.bicepparam" in deploy and "prod.bicepparam" not in deploy
    assert "rg-ofgitops-*-test" in deploy
    assert deploy.index("what-if") < deploy.index("az deployment group create")
    assert "az acr repository show" in deploy
    for forbidden in ("docker", "git fetch", "git checkout", "pip install"):
        assert forbidden not in source, forbidden


def test_test_deploy_report_handles_every_outcome():
    report = job(text("test-deploy"), "report")
    assert "needs: [resolve, deploy]" in report
    assert "if: always() && needs.resolve.outputs.eligible == 'true'" in report
    assert "pull-requests: write" in report
    assert "azure/login" not in report and "id-token" not in report
    assert '"open ${HEAD_SHA}"' in report and "superseded" in report
    success, rest = report.split('elif [ "$DEPLOY_RESULT" = "failure" ]', 1)
    failure, other = rest.split("\n          else\n", 1)
    assert "gh pr ready" in success and "@copilot" not in success
    assert '[ "$SMOKE_STATUS" = "Succeeded" ]' in success
    assert 'if [ "$IS_COPILOT" = "true" ]; then mention="@copilot "' in failure
    assert "exit 1" in failure
    assert "@copilot" not in other and "exit 1" not in other
    assert report.count("@copilot") == 1


@pytest.mark.parametrize("name", ("test-deploy", "cd"))
def test_smoke_polling_is_bounded_and_fails_visibly(name):
    source = text(name)
    assert "az containerapp job start --name orderflow-smoke" in source
    assert "--query name -o tsv" in source
    assert "az containerapp job execution show --name orderflow-smoke" in source
    assert "deadline=$((SECONDS + 600))" in source
    assert 'if [ "$status" != "Succeeded" ]' in source and "exit 1" in source
    assert "--template-file scenarios/orderflow/gitops/infra/env.bicep" in source
    assert "python scenarios/orderflow/gitops/tools/image_tag.py" in source


def test_cd_builds_and_deploys_production_from_main_only():
    source = text("cd")
    assert "branches: [main]" in source and "workflow_dispatch:" in source
    assert "pull_request" not in source
    assert "if: github.ref == 'refs/heads/main'" in source
    assert "environment: orderflow-prod" in source
    assert "group: orderflow-prod\n      cancel-in-progress: false" in source
    assert "deploy/prod.bicepparam" in source and "test.bicepparam" not in source
    assert "az acr login --name" in source and "docker build" in source
    assert "-f scenarios/orderflow/gitops/container/Dockerfile" in source
    assert "runs-on: ubuntu-latest" in source


def test_handoff_is_disabled_by_default_and_tightly_gated():
    source = text("handoff")
    assert "types: [opened, labeled]" in source
    assert "permissions: {}" in source
    assignment = job(source, "assign-copilot")
    assert "vars.ORDERFLOW_HANDOFF_FALLBACK == 'true'" in assignment
    assert "github.event.issue.user.login == vars.ORDERFLOW_SRE_GITHUB_LOGIN" in assignment
    assert "contains(github.event.issue.labels.*.name, 'orderflow-incident')" in assignment
    assert "!contains(github.event.issue.assignees.*.login, 'Copilot')" in assignment
    assert "secrets.ORDERFLOW_COPILOT_ASSIGN_TOKEN" in assignment
    assert "copilot-swe-agent[bot]" in assignment and "agent_assignment" in assignment
    assert "actions/checkout" not in source and "azure/login" not in source


def test_azure_login_uses_environment_variables_only():
    for name in ("test-deploy", "cd"):
        source = text(name)
        for key in ("client-id", "tenant-id", "subscription-id"):
            assert re.search(rf"{key}: \$\{{\{{ vars\.AZURE_", source), (name, key)
        assert "client-secret" not in source and "creds:" not in source
