"""Print the deterministic OrderFlow GitOps image tag (stdlib only).

Usage: python image_tag.py [--root <repository root>]
"""

import argparse
import hashlib
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
APP = "scenarios/orderflow/app"
FILES = [f"{APP}/{name}" for name in
         ("backend.py", "common.py", "portal.py", "smoke.py", "requirements.txt")]
FILES.append("scenarios/orderflow/gitops/container/Dockerfile")


def inputs(root):
    paths = list(FILES)
    paths += [p.relative_to(root).as_posix() for p in (root / APP / "static").glob("*")
              if p.is_file()]
    return sorted(paths)


def compute(root=REPO_ROOT):
    root = Path(root)
    digest = hashlib.sha256()
    for relative in inputs(root):
        content = (root / relative).read_bytes().replace(b"\r\n", b"\n")
        # NUL separators keep path/content boundaries unambiguous.
        digest.update(relative.encode() + b"\0" + content + b"\0")
    return "sha-" + digest.hexdigest()[:16]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO_ROOT, type=Path)
    args = parser.parse_args(argv)
    try:
        print(compute(args.root))
    except OSError as error:
        print(f"image_tag: missing input: {error.filename}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
