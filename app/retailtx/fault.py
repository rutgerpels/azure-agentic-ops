from typing import Any

from retailtx.db import connect
from retailtx.telemetry import event


def backlog(dsn: str, *, undo: bool = False) -> None:
    if type(undo) is not bool:
        raise ValueError("Undo must be a boolean")
    with connect(dsn) as conn:
        row = conn.execute(
            "SELECT *, heartbeat_at > clock_timestamp() - interval '15 seconds' AS alive "
            "FROM worker_control FOR UPDATE"
        ).fetchone()
        assert row is not None
        if not undo and not row["alive"]:
            raise RuntimeError("Poster heartbeat is missing or stale; refusing to inject a fault")
        conn.execute(
            "UPDATE worker_control SET fault_until = NULL, fault_active = %s",
            (not undo,),
        )
        updated = conn.execute("SELECT fault_until FROM worker_control").fetchone()
        assert updated is not None
        action = "backlog.undo" if undo else "backlog.inject"
        conn.execute(
            "INSERT INTO change_events (action, expires_at) VALUES (%s, %s)",
            (action, updated["fault_until"]),
        )
    event(action, fault_lifetime="Manual", expires_at=updated["fault_until"])


def heartbeat(dsn: str) -> bool:
    with connect(dsn) as conn:
        row = conn.execute("SELECT * FROM worker_control FOR UPDATE").fetchone()
        assert row is not None
        expired = conn.execute(
            "UPDATE worker_control SET fault_until = NULL "
            "WHERE fault_until <= clock_timestamp() RETURNING singleton"
        ).fetchone()
        if expired:
            conn.execute("INSERT INTO change_events (action) VALUES ('backlog.expired')")
            event("backlog.expired")
        updated = conn.execute(
            "UPDATE worker_control SET heartbeat_at = clock_timestamp(), worker_state = "
            "CASE WHEN fault_active OR fault_until IS NOT NULL THEN 'paused' ELSE 'running' END "
            "RETURNING worker_state"
        ).fetchone()
        assert updated is not None
    if row["worker_state"] != updated["worker_state"]:
        event("poster.state", state=updated["worker_state"])
    return bool(updated["worker_state"] == "paused")


def worker_status(dsn: str) -> dict[str, Any]:
    with connect(dsn) as conn:
        row = conn.execute(
            "SELECT *, heartbeat_at > clock_timestamp() - interval '15 seconds' AS alive, "
            "(fault_active OR coalesce(fault_until > clock_timestamp(), false)) AS paused "
            "FROM worker_control"
        ).fetchone()
    assert row is not None
    return row
