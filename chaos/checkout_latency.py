"""Compatibility entry point for independently selected, manual checkout faults.

All mutations go through the common lifecycle, ownership and readiness gates.
The default remains latency; --scenario service selects the Arc service fault.
"""

import argparse
import re
import shutil
import subprocess
from pathlib import Path

TIMEOUT_SECONDS = 900
LIFECYCLE = Path(__file__).resolve().parents[1] / "scripts" / "Invoke-CheckoutDemo.ps1"


def main() -> None:
    parser = argparse.ArgumentParser(description="Independent checkout faults (manual lifetime)")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--inject", action="store_true")
    action.add_argument("--undo", action="store_true")
    parser.add_argument("--scenario", choices=("latency", "service"), default="latency")
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--location", default="swedencentral")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9]{2,11}", args.environment):
        raise SystemExit(
            "Environment must be 3-12 lowercase letters/digits, starting with a letter."
        )
    executable = shutil.which("pwsh")
    if not executable:
        raise SystemExit("PowerShell 7 'pwsh' is required for the guarded checkout lifecycle.")
    result = subprocess.run(
        [executable, "-NoProfile", "-File", str(LIFECYCLE),
         "Inject" if args.inject else "Undo", "-Scenario", args.scenario,
         "-SubscriptionId", args.subscription, "-EnvironmentName", args.environment,
         "-Location", args.location, "-Confirm:$false"],
        timeout=TIMEOUT_SECONDS, check=False,
    )
    if result.returncode:
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
