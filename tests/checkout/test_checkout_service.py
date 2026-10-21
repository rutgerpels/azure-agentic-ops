"""Checkout service controller contracts without Azure or systemd."""

import copy
import importlib.util
import sys
import types
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
OWNER = "11111111-1111-1111-1111-111111111111"
ACTOR = "22222222-2222-2222-2222-222222222222"
RUN = "33333333-3333-3333-3333-333333333333"
SRE = "44444444-4444-4444-4444-444444444444"
NEXT = "55555555-5555-5555-5555-555555555555"


@pytest.fixture
def control(monkeypatch):
    if sys.platform == "win32":
        monkeypatch.setitem(sys.modules, "fcntl", types.SimpleNamespace(LOCK_EX=2, LOCK_NB=4))
        monkeypatch.setitem(sys.modules, "syslog", types.SimpleNamespace())
    spec = importlib.util.spec_from_file_location(
        "checkout_control", ROOT / "scripts" / "checkout" / "service_control.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    machine = {"active": True, "inhibited": False, "routes": "primary", "calls": [], "saved": []}

    def systemctl(action):
        if action != "is-active":
            machine["calls"].append(action)
            machine["active"] = action == "start"
        return machine["active"]

    def routes(_):
        if machine["routes"] != "primary":
            raise ValueError("Service fault requires baseline routes; undo latency first")

    monkeypatch.setattr(module, "systemctl", systemctl)
    monkeypatch.setattr(module, "health", lambda: machine["active"])
    monkeypatch.setattr(module, "routes", routes)
    monkeypatch.setattr(module, "save", lambda state: machine["saved"].append(copy.deepcopy(state)))
    monkeypatch.setattr(module, "inhibit", lambda active: machine.update(inhibited=active))
    config = {"ownerToken": OWNER, "actionPrincipalId": SRE}
    state = {"marker": None, "usedRunIds": []}
    return module, machine, config, state


def request(action="fault", run=RUN, actor=ACTOR):
    value = {"action": action, "ownerToken": OWNER, "runId": run, "actor": actor}
    if action == "fault":
        value["startBeforeUtc"] = (datetime.now(UTC) + timedelta(seconds=90)).isoformat()
    elif action == "repair":
        value["expectedActor"] = ACTOR
    return value


def test_service_fault_repair_and_next_independent_run(control):
    module, machine, config, state = control
    module.execute(request(), config, state)
    assert machine["calls"] == ["stop"]
    assert not machine["active"] and machine["inhibited"]
    assert state["marker"]["phase"] == "fault-active"
    assert machine["saved"][0]["marker"]["phase"] == "prepared"
    module.boot_guard(state)
    assert machine["inhibited"] and machine["calls"] == ["stop"]
    module.execute(request("repair", actor=SRE), config, state)
    assert machine["calls"] == ["stop", "start"]
    assert machine["active"] and not machine["inhibited"]
    assert state["marker"]["recoveredBy"] == SRE
    module.execute(request(run=NEXT), config, state)
    assert machine["calls"] == ["stop", "start", "stop"]


def test_latency_must_be_reset_before_service_fault(control):
    module, machine, config, state = control
    machine["routes"] = "legacy"
    with pytest.raises(ValueError, match="undo latency"):
        module.execute(request(), config, state)
    assert not machine["calls"] and not state["usedRunIds"]
    machine["routes"] = "primary"
    module.execute(request(), config, state)
    assert machine["calls"] == ["stop"]


@pytest.mark.parametrize("field,value", [
    ("ownerToken", NEXT), ("runId", NEXT), ("expectedActor", NEXT), ("actor", ACTOR),
])
def test_repair_rejects_wrong_current_binding(control, field, value):
    module, machine, config, state = control
    module.execute(request(), config, state)
    repair = request("repair", actor=SRE)
    repair[field] = value
    with pytest.raises(ValueError):
        module.execute(repair, config, state)
    assert machine["calls"] == ["stop"]


def test_repair_replay_rejected_and_reset_is_idempotent(control):
    module, machine, config, state = control
    module.execute(request(), config, state)
    module.execute(request("repair", actor=SRE), config, state)
    with pytest.raises(ValueError, match="replay"):
        module.execute(request("repair", actor=SRE), config, state)
    module.execute(request("reset"), config, state)
    with pytest.raises(ValueError, match="replay"):
        module.execute(request(), config, state)
    assert machine["calls"] == ["stop", "start"]


def test_interrupted_repair_stays_inhibited_across_boot(control, monkeypatch):
    module, machine, config, state = control
    module.execute(request(), config, state)

    def failure(action):
        if action == "start":
            raise RuntimeError("Guest action failed")
        return False

    monkeypatch.setattr(module, "systemctl", failure)
    with pytest.raises(RuntimeError, match="Guest action"):
        module.execute(request("repair", actor=SRE), config, state)
    assert state["marker"]["phase"] == "recovering"
    assert machine["inhibited"]
    machine["inhibited"] = False
    module.boot_guard(state)
    assert machine["inhibited"]
    with pytest.raises(ValueError, match="current fault"):
        module.execute(request("repair", actor=SRE), config, state)


@pytest.mark.parametrize("seconds", [-1, 1000])
def test_fault_admission_is_bounded_not_fault_lifetime(control, seconds):
    module, machine, config, state = control
    fault = request()
    fault["startBeforeUtc"] = (datetime.now(UTC) + timedelta(seconds=seconds)).isoformat()
    with pytest.raises(ValueError, match="admission"):
        module.execute(fault, config, state)
    assert not machine["calls"]


def test_observer_and_boot_never_recover(control):
    module, machine, config, state = control
    module.execute(request(), config, state)
    observed = module.receipt(config, state)
    assert not observed["active"] and not observed["healthy"]
    module.boot_guard(state)
    assert machine["calls"] == ["stop"]
    assert observed["marker"]["faultLifetime"] == "Manual"
