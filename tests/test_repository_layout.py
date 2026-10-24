"""Offline contracts for the named-scenario layout and its published entry points."""

import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = sorted(path for path in (ROOT / "scenarios").iterdir() if path.is_dir())
GUIDES = [
    ROOT / "README.md",
    *(ROOT / "docs").rglob("*.md"),
    *(ROOT / "scenarios").rglob("*.md"),
]


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda path: path.name)
def test_named_scenario_has_an_entry_point_and_scoped_instructions(scenario):
    assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", scenario.name)
    for filename in ("README.md", "AGENTS.md"):
        assert (scenario / filename).is_file()
    catalog = (ROOT / "README.md").read_text(encoding="utf-8")
    assert f"scenarios/{scenario.name}/README.md" in catalog


@pytest.mark.parametrize("guide", GUIDES, ids=lambda path: str(path.relative_to(ROOT)))
def test_relative_document_links_resolve(guide):
    text = guide.read_text(encoding="utf-8")
    for destination in re.findall(r"\[[^\]]*\]\(([^)\s]+)\)", text):
        parsed = urlsplit(destination)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        target = (guide.parent / unquote(parsed.path)).resolve()
        assert target.is_relative_to(ROOT), (guide, destination)
        assert target.exists(), (guide, destination)


def test_retailx_workflows_use_relocated_entry_points():
    scripts = {
        "checkout-deploy.yml": "Sync-CheckoutRoutes.ps1",
        "checkout-demo-reset.yml": "Invoke-CheckoutDemoRepo.ps1",
    }
    for workflow, script in scripts.items():
        text = (ROOT / ".github" / "workflows" / workflow).read_text(encoding="utf-8")
        entry_point = f"scenarios/retailx/scripts/{script}"
        assert f"./{entry_point}" in text
        assert (ROOT / entry_point).is_file()


def test_retailx_embedded_infrastructure_dependencies_resolve():
    infrastructure = ROOT / "scenarios" / "retailx" / "infra"
    for template in infrastructure.rglob("*.bicep"):
        text = template.read_text(encoding="utf-8")
        dependencies = re.findall(r"load(?:TextContent|FileAsBase64|JsonContent)\('([^']+)'", text)
        dependencies += re.findall(r"\bmodule\s+\w+\s+'([^']+)'", text)
        for dependency in dependencies:
            if dependency.startswith(("br:", "ts:")):
                continue
            assert (template.parent / dependency).is_file(), (template, dependency)
