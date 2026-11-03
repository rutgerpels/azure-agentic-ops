"""Execute the handoff script with a fake gh client; no GitHub credentials or writes."""

import json
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
pytestmark = pytest.mark.skipif(
    os.name == "nt" or not shutil.which("bash") or not shutil.which("jq"),
    reason="Executes the Ubuntu Actions shell contract (bash and jq required)",
)
BOT = "orderflow-publisher[bot]"
GENERATION = "aaaaaaaa-2222-4333-8444-555555555555"


def issue():
    return {
        "state": "open",
        "user": {"login": BOT, "type": "Bot"},
        "labels": [{"name": "orderflow-incident"}],
        "assignees": [],
        "title": "$(exit 99)",
        "body": "Untrusted issue content must never become executable text.",
    }


def run_handoff(
    tmp_path, current, assignees=None, token="offline-placeholder", post_fails=False,
    comments=None, current_user=42, mode="", publisher_id="", generation="", login=BOT,
):
    source = (ROOT / ".github/workflows/orderflow-gitops-handoff.yml").read_text()
    script = textwrap.dedent(source.split("        run: |\n", 1)[1])
    script_path = tmp_path / "handoff.sh"
    script_path.write_text(script)
    fixture = tmp_path / "fixture.json"
    fixture.write_text(json.dumps({
        "issue": current,
        "assignment": {"assignees": assignees if assignees is not None else [
            {"login": "copilot-swe-agent[bot]"},
        ]},
        "post_fails": post_fails,
        "comments": comments or [],
        "current_user": current_user,
    }))
    mock = tmp_path / "mock_gh.py"
    mock.write_text(textwrap.dedent("""
        import json, os, sys
        from pathlib import Path
        fixture = json.loads(Path(os.environ["FIXTURE"]).read_text())
        post = "--method" in sys.argv
        payload = json.load(sys.stdin) if post else None
        path = next((a for a in sys.argv[1:] if a.startswith("repos/") or a == "user"), "")
        kind = ("assignment" if path.endswith("/assignees") else
                "comment" if "/comments" in path else "user" if path == "user" else "issue")
        with Path(os.environ["CALLS"]).open("a") as out:
            out.write(json.dumps({
                "post": post, "kind": kind, "args": sys.argv[1:], "payload": payload,
            }) + "\\n")
        if post and kind == "assignment" and fixture["post_fails"]:
            print("Unknown assignment outcome; inspect GitHub.", file=sys.stderr)
            sys.exit(1)
        if kind == "user":
            print(fixture["current_user"])
        elif kind == "comment":
            print(json.dumps({"id": 1} if post else fixture["comments"]))
        else:
            print(json.dumps(fixture["assignment" if post else "issue"]))
    """))
    gh = tmp_path / "gh"
    gh.write_text('#!/bin/bash\nexec "$MOCK_PYTHON" "$MOCK_GH" "$@"\n')
    gh.chmod(0o700)
    calls_path = tmp_path / "calls.jsonl"
    environment = {
        **os.environ,
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        "FIXTURE": str(fixture), "CALLS": str(calls_path),
        "MOCK_PYTHON": sys.executable, "MOCK_GH": str(mock),
        "GH_TOKEN": token, "REPOSITORY": "example/demo", "ISSUE_NUMBER": "123",
        "EXPECTED_LOGIN": login,
        "EXPECTED_USER_ID": "42",
        "AUTH_MODE": mode, "PUBLISHER_USER_ID": publisher_id, "GENERATION": generation,
    }
    result = subprocess.run(
        ["bash", str(script_path)], env=environment, capture_output=True, text=True, timeout=15,
    )
    calls = [json.loads(line) for line in calls_path.read_text().splitlines()] \
        if calls_path.exists() else []
    return result, calls


@pytest.mark.parametrize("change", ["closed", "wrong-author", "human", "unlabelled", "pr"])
def test_stale_event_cannot_assign(tmp_path, change):
    current = issue()
    if change == "closed":
        current["state"] = "closed"
    elif change == "wrong-author":
        current["user"]["login"] = "other-app[bot]"
    elif change == "human":
        current["user"]["type"] = "User"
    elif change == "unlabelled":
        current["labels"] = []
    else:
        current["pull_request"] = {}
    result, calls = run_handoff(tmp_path, current)
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1 and not calls[0]["post"]


@pytest.mark.parametrize("login", ["Copilot", "copilot-swe-agent", "copilot-swe-agent[bot]"])
def test_fresh_assignee_check_suppresses_duplicate(tmp_path, login):
    current = issue()
    current["assignees"] = [{"login": login}]
    result, calls = run_handoff(tmp_path, current)
    assert result.returncode == 0
    assert not any(call["post"] for call in calls)


def test_assignment_is_fixed_scope_and_verified(tmp_path):
    result, calls = run_handoff(tmp_path, issue())
    assert result.returncode == 0, result.stderr
    assignments = [call for call in calls if call["kind"] == "assignment"]
    assert len(assignments) == 1
    assert calls[-2]["kind"] == "comment" and calls[-2]["post"]
    payload = assignments[0]["payload"]
    assert payload["assignees"] == ["copilot-swe-agent[bot]"]
    assert payload["agent_assignment"]["target_repo"] == "example/demo"
    assert payload["agent_assignment"]["base_branch"] == "main"
    assert "network-rules.json" in payload["agent_assignment"]["custom_instructions"]
    assert "Untrusted issue" not in json.dumps(payload)


def pat_issue():
    current = issue()
    current["user"] = {"login": "demo-presenter", "id": 123, "type": "User"}
    current["body"] = f"Evidence\n<!-- orderflow-incident-key:{GENERATION} -->\n"
    return current


def test_pat_mode_automatically_assigns_pinned_user_issue(tmp_path):
    result, calls = run_handoff(
        tmp_path, pat_issue(), mode="PAT", login="demo-presenter",
        publisher_id="123", generation=GENERATION,
    )
    assert result.returncode == 0, result.stderr
    assert sum(call["kind"] == "assignment" for call in calls) == 1


@pytest.mark.parametrize("change", [
    "wrong-id", "bot", "wrong-login", "missing-marker", "wrong-generation",
    "inline-marker", "closed", "unlabelled", "pr",
])
def test_pat_mode_rechecks_trusted_identity_and_generation(tmp_path, change):
    current = pat_issue()
    if change == "wrong-id":
        current["user"]["id"] = 999
    elif change == "bot":
        current["user"]["type"] = "Bot"
    elif change == "wrong-login":
        current["user"]["login"] = "someone-else"
    elif change == "missing-marker":
        current["body"] = None
    elif change == "wrong-generation":
        current["body"] = current["body"].replace(GENERATION, "other-generation")
    elif change == "inline-marker":
        current["body"] = current["body"].replace("<!--", "quoted <!--")
    elif change == "closed":
        current["state"] = "closed"
    elif change == "unlabelled":
        current["labels"] = []
    else:
        current["pull_request"] = {}
    result, calls = run_handoff(
        tmp_path, current, mode="PAT", login="demo-presenter",
        publisher_id="123", generation=GENERATION,
    )
    assert result.returncode == 0, result.stderr
    assert not any(call["post"] for call in calls)


@pytest.mark.parametrize("mode,publisher_id,generation", [
    ("unknown", "123", GENERATION), ("PAT", "", GENERATION),
    ("PAT", "123", ""), ("PAT", "12x", GENERATION), ("PAT", "123", "bad"),
])
def test_invalid_authentication_configuration_fails_closed(
    tmp_path, mode, publisher_id, generation,
):
    result, calls = run_handoff(
        tmp_path, pat_issue(), mode=mode, login="demo-presenter",
        publisher_id=publisher_id, generation=generation,
    )
    assert result.returncode != 0
    assert not any(call["post"] for call in calls)


def test_pat_issue_requires_explicit_pat_opt_in(tmp_path):
    result, calls = run_handoff(tmp_path, pat_issue(), login="demo-presenter")
    assert result.returncode == 0
    assert not any(call["post"] for call in calls)


def test_pat_assignment_intent_still_blocks_unknown_outcome_replay(tmp_path):
    result, calls = run_handoff(
        tmp_path, pat_issue(), mode="PAT", login="demo-presenter",
        publisher_id="123", generation=GENERATION,
        comments=[{"user": {"id": 42}, "body": "<!-- orderflow-copilot-assignment:v1 -->"}],
    )
    assert result.returncode != 0
    assert not any(call["post"] for call in calls)


def test_unobserved_assignment_is_failure(tmp_path):
    result, calls = run_handoff(tmp_path, issue(), assignees=[])
    assert result.returncode != 0
    assert "Copilot assignment was not observed" in result.stdout
    assert sum(call["kind"] == "assignment" for call in calls) == 1


def test_unknown_assignment_is_never_replayed(tmp_path):
    result, calls = run_handoff(tmp_path, issue(), post_fails=True)
    assert result.returncode != 0
    assert sum(call["kind"] == "assignment" for call in calls) == 1


def test_prior_intent_blocks_replay_even_without_assignee(tmp_path):
    comments = [{"user": {"id": 42}, "body": "<!-- orderflow-copilot-assignment:v1 -->"}]
    result, calls = run_handoff(tmp_path, issue(), comments=comments)
    assert result.returncode != 0
    assert "no automatic replay" in result.stdout
    assert not any(call["post"] for call in calls)


def test_rotated_token_owner_cannot_bypass_historical_intent(tmp_path):
    comments = [{"user": {"id": 42}, "body": "<!-- orderflow-copilot-assignment:v1 -->"}]
    result, calls = run_handoff(tmp_path, issue(), comments=comments, current_user=43)
    assert result.returncode != 0
    assert "Handoff token owner changed" in result.stdout
    assert not any(call["post"] for call in calls)


def test_later_workflow_observes_prior_unknown_assignment(tmp_path):
    first = tmp_path / "first"
    first.mkdir()
    result, calls = run_handoff(first, issue(), post_fails=True)
    assert result.returncode != 0
    intent = next(call for call in calls if call["kind"] == "comment" and call["post"])
    second = tmp_path / "second"
    second.mkdir()
    comments = [{"user": {"id": 42}, "body": intent["payload"]["body"]}]
    result, later_calls = run_handoff(second, issue(), comments=comments)
    assert result.returncode != 0
    assert not any(call["post"] for call in later_calls)


def test_missing_secret_fails_before_api_call(tmp_path):
    result, calls = run_handoff(tmp_path, issue(), token="")
    assert result.returncode != 0
    assert calls == []
