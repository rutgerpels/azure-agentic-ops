"""Offline policy check for OrderFlow GitOps NSG rule files (stdlib only).

Usage: python check_rules.py [rules.json] [--baseline baseline.json]
Exit codes: 0 compliant, 1 policy violations, 2 unreadable input.
"""

import argparse
import json
import re
import sys
from pathlib import Path

GITOPS = Path(__file__).resolve().parents[1]
DEFAULT_RULES = GITOPS / "deploy" / "network-rules.json"
DEFAULT_BASELINE = GITOPS / "deploy" / "baseline" / "network-rules.json"
REQUIRED = {"priority", "direction", "access", "protocol", "sourceAddressPrefix",
            "sourcePortRange", "destinationAddressPrefix", "destinationPortRange"}
OPTIONAL = {"description"}
PROTOCOLS = {"*", "Tcp", "Udp", "Icmp"}
PLATFORM_DNS = {"168.63.129.16", "168.63.129.16/32", "AzurePlatformDNS"}
BROAD = {"*", "Internet", "Any", "0.0.0.0/0", "::/0"}
NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,79}$")
PORT = re.compile(r"^(\*|\d{1,5}(-\d{1,5})?)$")


def check(document, baseline=None):
    """Return a list of policy violations; empty means compliant."""
    if not isinstance(document, dict) or set(document) - {"$schema-note", "rules"}:
        return ["document must be an object with only '$schema-note' and 'rules'"]
    rules = document.get("rules")
    if not isinstance(rules, list) or not rules:
        return ["'rules' must be a non-empty list"]
    errors, names, priorities = [], set(), set()
    for index, rule in enumerate(rules):
        label = f"rules[{index}]"
        if not isinstance(rule, dict) or set(rule) != {"name", "properties"}:
            errors.append(f"{label}: must contain exactly 'name' and 'properties'")
            continue
        name, props = rule["name"], rule["properties"]
        if not isinstance(name, str) or not NAME.match(name):
            errors.append(f"{label}: invalid name")
            continue
        label = name
        if name in names:
            errors.append(f"{label}: duplicate name")
        names.add(name)
        if not isinstance(props, dict):
            errors.append(f"{label}: properties must be an object")
            continue
        missing, extra = REQUIRED - set(props), set(props) - REQUIRED - OPTIONAL
        if missing or extra:
            errors.append(f"{label}: missing {sorted(missing)} unexpected {sorted(extra)}")
            continue
        if any(not isinstance(props[key], str) for key in REQUIRED - {"priority"}):
            errors.append(f"{label}: address, port and enum fields must be strings")
            continue
        priority = props["priority"]
        if type(priority) is not int or not 100 <= priority <= 4096:
            errors.append(f"{label}: priority must be an integer 100-4096")
        elif priority in priorities:
            errors.append(f"{label}: duplicate priority {priority}")
        else:
            priorities.add(priority)
        if props["direction"] != "Outbound":
            errors.append(f"{label}: only Outbound rules are managed here")
        if props["access"] not in ("Allow", "Deny"):
            errors.append(f"{label}: access must be Allow or Deny")
        if props["protocol"] not in PROTOCOLS:
            errors.append(f"{label}: unsupported protocol")
        if props["sourceAddressPrefix"] != "VirtualNetwork":
            errors.append(f"{label}: source must be VirtualNetwork")
        for key in ("sourcePortRange", "destinationPortRange"):
            if not PORT.match(props[key]):
                errors.append(f"{label}: invalid {key}")
        destination = props["destinationAddressPrefix"]
        if "0.0.0.0/0" in json.dumps(props):
            errors.append(f"{label}: 0.0.0.0/0 is forbidden")
        if props["access"] == "Deny" and destination in PLATFORM_DNS:
            errors.append(f"{label}: never deny Azure platform DNS")
        if props["access"] == "Allow" and destination in BROAD:
            errors.append(f"{label}: allow to '{destination}' is too broad")
    if baseline is not None:
        current = {r.get("name"): r.get("properties") for r in rules if isinstance(r, dict)}
        for required in baseline["rules"]:
            props = current.get(required["name"])
            if props is None:
                errors.append(f"{required['name']}: required baseline allow is missing")
            elif strip(props) != strip(required["properties"]):
                errors.append(f"{required['name']}: required baseline allow was modified")
    return errors


def strip(props):
    if not isinstance(props, dict):
        return props
    return {key: value for key, value in props.items() if key != "description"}


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("rules", nargs="?", type=Path, default=DEFAULT_RULES)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    args = parser.parse_args(argv)
    try:
        document, baseline = load(args.rules), load(args.baseline)
    except (OSError, ValueError) as error:
        print(f"check_rules: cannot read input: {error}", file=sys.stderr)
        return 2
    errors = check(document, baseline)
    for error in errors:
        print(f"check_rules: {error}", file=sys.stderr)
    if not errors:
        print(f"check_rules: {len(document['rules'])} rules compliant")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
