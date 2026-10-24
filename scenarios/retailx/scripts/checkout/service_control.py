#!/usr/bin/env python3
"""Fixed price-service fault and repair. Arc Run Command itself permits guest scripting."""

import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import syslog
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.request import urlopen

ROOT = Path("/opt/retailtx-checkout")
DATA = Path("/var/lib/retailtx-checkout")
SERVICE = "retailtx-price-primary.service"
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SOURCES = {
    "service_control.py": ROOT / "service_control.py",
    "price_backend.py": Path("/opt/retailtx/price_backend.py"),
    SERVICE: Path("/etc/systemd/system") / SERVICE,
    "retailtx-checkout-boot.service": Path("/etc/systemd/system/retailtx-checkout-boot.service"),
}


def utc():
    return datetime.now(UTC).isoformat()


def protected(path, *, directory=False):
    info = path.lstat()
    expected = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if info.st_uid != 0 or info.st_mode & 0o022 or not expected:
        raise ValueError(f"Unprotected checkout path: {path.name}")


def load(path):
    protected(path)
    return json.loads(path.read_text(encoding="utf-8"))


def save(state):
    staging = DATA / "state.next"
    if staging.exists() or staging.is_symlink():
        protected(staging)
        staging.unlink()
    descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(state, stream, separators=(",", ":"))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(staging, DATA / "state.json")
    descriptor = os.open(DATA, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def attest():
    protected(ROOT, directory=True)
    protected(DATA, directory=True)
    config = load(ROOT / "config.json")
    if (config["schemaVersion"] != 1 or not UUID.fullmatch(config["ownerToken"])
            or not UUID.fullmatch(config["actionPrincipalId"])
            or set(config["sourceHashes"]) != set(SOURCES)):
        raise ValueError("Invalid checkout source binding")
    for name, path in SOURCES.items():
        protected(path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != config["sourceHashes"][name]:
            raise ValueError(f"Checkout source changed: {name}")
    return config


def systemctl(action):
    if action not in ("is-active", "start", "stop"):
        raise ValueError("Unsupported service operation")
    result = subprocess.run(
        ["/usr/bin/systemctl", action, SERVICE], capture_output=True, text=True,
        timeout=20, check=False,
    )
    if action != "is-active" and result.returncode:
        raise RuntimeError(f"Price service {action} failed, exit {result.returncode}")
    return result.returncode == 0


def health():
    try:
        with urlopen("http://127.0.0.1:8080/health", timeout=2) as response:
            value = json.loads(response.read(1024))
            return response.status == 200 and value == {
                "status": "ok", "service": "erp-price-service",
            }
    except (OSError, ValueError):
        # A failed local probe is an observed unhealthy state, emitted in the receipt.
        return False


def routes(config):
    url = config["checkoutUrl"]
    if not re.fullmatch(r"https://[a-z0-9-]+\.azurewebsites\.net", url):
        raise ValueError("Unexpected checkout endpoint")
    with urlopen(f"{url}/health", timeout=5) as response:
        value = json.loads(response.read(4096))
    if value.get("status") != "ok" or value.get("routes") != {"BE": "primary", "NL": "primary"}:
        raise ValueError("Service fault requires baseline routes; undo latency first")


def inhibit(active):
    path = DATA / "fault-active"
    if path.exists() or path.is_symlink():
        protected(path)
    if active:
        if not path.exists():
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.close(descriptor)
    elif path.exists():
        path.unlink()


def boot_guard(state):
    marker = state["marker"]
    inhibit(bool(marker and marker["phase"] != "recovered"))


def execute(request, config, state):
    if not isinstance(request, dict):
        raise ValueError("Controller request must be an object")
    action = request.get("action")
    required = {"action", "ownerToken", "runId", "actor"}
    if action == "fault":
        required.add("startBeforeUtc")
    elif action == "repair":
        required.add("expectedActor")
    elif action != "reset":
        raise ValueError("Unsupported checkout action")
    if set(request) != required or request["ownerToken"] != config["ownerToken"]:
        raise ValueError("Exact checkout action and owner required")
    if any(not isinstance(request[key], str) or not UUID.fullmatch(request[key])
           for key in ("runId", "actor")):
        raise ValueError("Exact canonical run and actor UUIDs required")

    marker = state["marker"]
    if action == "fault":
        if marker and marker["phase"] != "recovered":
            raise ValueError("An outstanding service fault already exists")
        if request["runId"] in state["usedRunIds"] or len(state["usedRunIds"]) >= 128:
            raise ValueError("Fault replay or exhausted run history")
        deadline = datetime.fromisoformat(request["startBeforeUtc"])
        if deadline.tzinfo is None or not 0 < (deadline - datetime.now(UTC)).total_seconds() <= 180:
            raise ValueError("Fault admission expired or unbounded")
        routes(config)
        if not systemctl("is-active") or not health():
            raise ValueError("Price service must be healthy before injection")
        state["usedRunIds"].append(request["runId"])
        state["marker"] = {
            "scenario": "service", "runId": request["runId"], "actor": request["actor"],
            "phase": "prepared", "faultLifetime": "Manual", "startedAtUtc": utc(),
        }
        save(state)
        inhibit(True)
        if datetime.now(UTC) >= deadline:
            raise ValueError("Admission expired before service stop; exact-run reset required")
        systemctl("stop")
        if systemctl("is-active") or health():
            raise ValueError("Service stop not verified")
        state["marker"]["phase"] = "fault-active"
        save(state)
        return

    if not marker or marker["runId"] != request["runId"]:
        raise ValueError("Repair/reset does not match the current service run")
    if marker["phase"] == "recovered":
        if action == "reset" and systemctl("is-active") and health():
            return
        raise ValueError("Already recovered; repair replay refused")
    if action == "repair" and (
        marker["phase"] != "fault-active" or request["expectedActor"] != marker["actor"]
        or request["actor"] != config["actionPrincipalId"]
    ):
        raise ValueError(
            "Repair requires the current fault, original actor and bound SRE principal"
        )
    routes(config)
    marker["phase"] = "recovering"
    save(state)
    inhibit(False)
    try:
        systemctl("start")
        for _ in range(10):
            if systemctl("is-active") and health():
                break
            time.sleep(0.5)
        else:
            raise ValueError("Price service recovery not verified")
        marker.update(phase="recovered", recoveredAtUtc=utc(),
                      recoveredBy=request["actor"], recoveryReason=action)
        save(state)
    finally:
        # A new boot also restores this guard before systemd may start the service.
        inhibit(marker["phase"] != "recovered")


def receipt(config, state):
    return {
        "schemaVersion": 1, "event": "checkout-service-observation",
        "ownerToken": config["ownerToken"], "service": SERVICE,
        "observedAtUtc": utc(), "active": systemctl("is-active"), "healthy": health(),
        "marker": state["marker"],
    }


def main():
    syslog.openlog("RetailTxCheckout", syslog.LOG_PID, syslog.LOG_LOCAL0)
    config = attest()
    descriptor = os.open(DATA / "controller.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = DATA / "state.json"
        state = load(path) if path.exists() else {"marker": None, "usedRunIds": []}
        argument = sys.argv[1]
        if argument == "boot":
            boot_guard(state)
            return
        if argument != "status":
            execute(json.loads(argument), config, state)
        message = json.dumps(receipt(config, state), separators=(",", ":"))
        syslog.syslog(syslog.LOG_INFO, message)
        print(message)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        syslog.syslog(
            syslog.LOG_ERR, f"Checkout controller failed: {type(error).__name__}: {error}"
        )
        raise
