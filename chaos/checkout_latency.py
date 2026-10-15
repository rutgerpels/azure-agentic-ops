"""Belgium checkout-latency fault: route Belgian price lookups to the legacy gateway.

The fault is a real, logged configuration change on the Azure front end
(``Microsoft.Web/sites/config/write`` in the Activity Log). Manual lifetime: it
stays until ``--undo``, an approved SRE Agent rollback, or ``Invoke-CheckoutDemo Down``.
"""

import argparse
import json
import re
import shutil
import subprocess

CHANGE_REF = "CHG-1042"
TIMEOUT_SECONDS = 180


def az(*args: str) -> str:
    executable = shutil.which("az")
    if not executable:
        raise SystemExit("Azure CLI 'az' was not found on PATH.")
    result = subprocess.run(  # noqa: S603 - fixed executable, argument list, no shell
        [executable, *args, "--only-show-errors"],
        capture_output=True, text=True, timeout=TIMEOUT_SECONDS, check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"az {args[0]} {args[1]} failed: {result.stderr.strip()[:400]}")
    return result.stdout


def find_web_app(subscription: str, group: str) -> str:
    owned = "[?tags.component=='checkout-web' && tags.managedBy=='invoke-checkoutdemo'].name"
    apps = json.loads(az("webapp", "list", "--subscription", subscription,
                         "--resource-group", group, "--query", owned, "-o", "json"))
    if len(apps) != 1:
        raise SystemExit(
            f"Expected exactly one owned checkout web app in {group}, found {len(apps)}.")
    return apps[0]


def main() -> None:
    parser = argparse.ArgumentParser(description="Belgium checkout latency fault (manual lifetime)")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--inject", action="store_true")
    action.add_argument("--undo", action="store_true")
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--location", default="swedencentral")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9]{2,11}", args.environment):
        raise SystemExit(
            "Environment must be 3-12 lowercase letters/digits, starting with a letter.")
    group = f"rg-retailtx-checkout-{args.environment}-{args.location}"
    app = find_web_app(args.subscription, group)
    settings = ["PRICE_ROUTE_BE=legacy", f"ROUTE_CHANGE_REF={CHANGE_REF}"] if args.inject else \
        ["PRICE_ROUTE_BE=primary", "ROUTE_CHANGE_REF=baseline"]
    az("webapp", "config", "appsettings", "set", "--subscription", args.subscription,
       "--resource-group", group, "--name", app, "--settings", *settings, "-o", "none")
    if args.inject:
        state = "injected (BE -> legacy-price-gateway)"
    else:
        state = "undone (BE -> erp-price-service)"
    print(f"Checkout latency fault {state} on {app}.")


if __name__ == "__main__":
    main()
