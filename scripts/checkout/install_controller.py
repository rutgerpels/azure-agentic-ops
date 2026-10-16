"""Install immutable checkout control sources before arming any service fault."""

import base64
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def main():
    payload = json.loads(base64.b64decode(sys.argv[1], validate=True))
    root = Path("/opt/retailtx-checkout")
    root.mkdir(mode=0o700, exist_ok=True)
    data = Path("/var/lib/retailtx-checkout")
    data.mkdir(mode=0o700, exist_ok=True)
    config_path = root / "config.json"
    names = {
        "service_control.py", "retailtx-price-primary.service",
        "retailtx-checkout-boot.service", "retailtx-checkout-observer.service",
        "retailtx-checkout-observer.timer",
    }
    if set(payload["files"]) != names:
        raise ValueError("Unexpected checkout deployment files")
    files = {}
    for name, encoded in payload["files"].items():
        path = root / name if name.endswith(".py") else Path("/etc/systemd/system") / name
        files[path] = base64.b64decode(encoded, validate=True)
    if config_path.exists():
        config = json.loads(config_path.read_text())
        if any(config[key] != payload[key]
               for key in ("ownerToken", "actionPrincipalId", "checkoutUrl")):
            raise ValueError("Controller deployment binding mismatch")
        changed = any(not path.exists() or path.read_bytes() != content
                      for path, content in files.items())
        if changed:
            raise ValueError("Installed sources changed; rebuild instead of replacing live control")
    else:
        if (data / "state.json").exists():
            raise ValueError("Refusing to replace a controller with retained fault state")
        for path, content in files.items():
            if path.is_symlink():
                raise ValueError("Refusing a symlinked checkout source")
            path.write_bytes(content)
            path.chmod(0o600 if path.suffix == ".py" else 0o644)
        protected = {"service_control.py", "retailtx-price-primary.service",
                     "retailtx-checkout-boot.service"}
        sources = {path.name: hashlib.sha256(content).hexdigest()
                   for path, content in files.items() if path.name in protected}
        sources["price_backend.py"] = hashlib.sha256(
            Path("/opt/retailtx/price_backend.py").read_bytes(),
        ).hexdigest()
        config = {
            "schemaVersion": 1, "ownerToken": payload["ownerToken"],
            "checkoutUrl": payload["checkoutUrl"],
            "actionPrincipalId": payload["actionPrincipalId"],
            "sourceHashes": sources,
        }
        config_path.write_text(json.dumps(config))
        config_path.chmod(0o600)
    subprocess.run(["systemctl", "daemon-reload"], check=True, timeout=20)
    subprocess.run(["systemctl", "enable", "--now", "retailtx-checkout-boot.service",
                    "retailtx-checkout-observer.timer"], check=True, timeout=20)
    subprocess.run(["python3", str(root / "service_control.py"), "status"], check=True, timeout=15)


if __name__ == "__main__":
    main()
