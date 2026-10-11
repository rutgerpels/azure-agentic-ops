import argparse

from retailtx.fault import backlog
from retailtx.settings import Settings
from retailtx.telemetry import configure


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Persistent posting pause; explicit --undo/reset/teardown required"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--inject", action="store_true")
    group.add_argument("--undo", action="store_true")
    args = parser.parse_args()
    settings = Settings.from_env()
    _ = settings.erp_dsn
    configure("backlog", settings)
    backlog(settings.erp_dsn, undo=args.undo)


if __name__ == "__main__":
    main()
