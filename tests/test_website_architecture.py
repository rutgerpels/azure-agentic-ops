"""Cross-scenario UI evidence contracts; Node uses only its built-in modules."""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(
    shutil.which("node") is None, reason="Node required for browser-script contracts",
)
def test_website_architecture_evidence_and_interactions():
    result = subprocess.run(
        [shutil.which("node"), str(ROOT / "tests" / "website_architecture.cjs"), str(ROOT)],
        capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
