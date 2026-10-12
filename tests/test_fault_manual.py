import os

import pytest
from psycopg.conninfo import conninfo_to_dict
from retailtx import fault
from retailtx.db import connect, migrate


def test_manual_pause_on_isolated_postgres():
    dsn = os.environ.get("RETAILTX_FAULT_TEST_DSN")
    if not dsn:
        pytest.skip(
            "Set RETAILTX_FAULT_TEST_DSN to a disposable loopback retailtx_fault_test database"
        )
    options = conninfo_to_dict(dsn)
    if options.get("host") != "127.0.0.1" or options.get("dbname") != "retailtx_fault_test":
        pytest.fail("Refusing to change a non-test database")
    migrate(dsn, "erp")
    migrate(dsn, "erp")
    with connect(dsn) as conn:
        conn.execute(
            "UPDATE worker_control SET fault_active = false, fault_until = NULL, "
            "heartbeat_at = NULL, worker_state = NULL"
        )
    with pytest.raises(RuntimeError, match="heartbeat"):
        fault.backlog(dsn)
    assert not fault.heartbeat(dsn)
    fault.backlog(dsn)
    assert fault.heartbeat(dsn)
    with connect(dsn) as conn:
        conn.execute("UPDATE worker_control SET fault_until = clock_timestamp() - interval '1 day'")
    assert fault.heartbeat(dsn)
    assert fault.worker_status(dsn)["paused"]
    with connect(dsn) as conn:
        row = conn.execute("SELECT fault_active, fault_until FROM worker_control").fetchone()
        assert row["fault_active"] and row["fault_until"] is None
    fault.backlog(dsn, undo=True)
    fault.backlog(dsn, undo=True)
    assert not fault.heartbeat(dsn)
    assert not fault.worker_status(dsn)["paused"]
    with pytest.raises(ValueError, match="boolean"):
        fault.backlog(dsn, undo=1)
