"""Keep independently packaged incident context aligned with checkout traffic."""

import ast
import runpy
from datetime import UTC, datetime
from pathlib import Path

SCENARIO = Path(__file__).resolve().parents[2]


def test_incident_store_map_matches_pos_simulator():
    simulator = ast.parse(
        (SCENARIO / "app" / "checkout" / "onprem" / "pos_sim.py").read_text(encoding="utf-8")
    )
    inventory = ast.literal_eval(
        next(
            node.value
            for node in simulator.body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "STORES" for target in node.targets
            )
        )
    )
    context = runpy.run_path(str(SCENARIO / "app" / "incident" / "evidence.py"))["store_context"](
        sorted(inventory), 60, datetime(2026, 10, 18, 12, tzinfo=UTC)
    )
    for country, stores in inventory.items():
        actual = [store["store"] for store in context["stores"] if store["country"] == country]
        assert sorted(stores) == sorted(actual)
    assert len(context["stores"]) == sum(len(stores) for stores in inventory.values())
    assert context["synthetic"]
    assert all(store["synthetic"] for store in context["stores"])
