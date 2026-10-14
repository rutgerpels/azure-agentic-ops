"""Exercise the Bash launcher with a stubbed pwsh; never call Azure."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "scripts" / "guest-presenter.sh"
GIT_BASH = Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Git" / "bin" / "bash.exe"
BASH = str(GIT_BASH) if GIT_BASH.exists() else shutil.which("bash")
pytestmark = pytest.mark.skipif(not BASH, reason="Bash is not installed")


def run_launcher(*args, env=None):
    return subprocess.run(
        [BASH, str(LAUNCHER), *args],
        capture_output=True,
        text=True,
        timeout=20,
        env=env,
        check=False,
    )


def test_help_does_not_need_powershell():
    result = run_launcher("--help")
    assert result.returncode == 0
    assert "Configure|Ready|Fault|Status|Reset" in result.stdout


def test_unknown_operation_fails_without_launching():
    result = run_launcher("Repair")
    assert result.returncode == 2
    assert "Unknown presenter operation" in result.stderr


def test_preserves_arguments_and_exit_status(tmp_path):
    stub = tmp_path / "pwsh"
    stub.write_text('#!/bin/bash\nprintf "<%s>\\n" "$@"\nexit 17\n', encoding="utf-8")
    stub.chmod(0o755)
    # Git Bash needs a POSIX PATH entry for an executable script.
    prefix = str(tmp_path).replace("\\", "/")
    if os.name == "nt":
        prefix = f"/{prefix[0].lower()}{prefix[2:]}"
    env = {**os.environ, "PATH": f"{prefix}:{os.environ['PATH']}"}
    result = run_launcher(
        "Fault", "-PresenterTriggered", "-Profile", "path with spaces;not-code", env=env
    )
    assert result.returncode == 17
    assert "<-NoProfile>" in result.stdout
    assert "<-PresenterTriggered>" in result.stdout
    assert "<path with spaces;not-code>" in result.stdout
    assert "Invoke-GuestPresenter.ps1" in result.stdout
