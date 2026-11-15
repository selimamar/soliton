"""Migrations bring existing databases up to date and keep their runs."""

from __future__ import annotations

import pytest
from sqlalchemy import Column, String, inspect, select, text

from soliton_server.db import RunRow, SchemaVersionRow, make_engine
from soliton_server.migrations import (
    DatabaseTooNew, Migration, add_column, latest, migrate,
)

ADD_COLOR = Migration(
    1, "runs.color", lambda c: add_column(c, "runs", Column("color", String(16), server_default="none")),
)


def columns(engine, table):
    return {c["name"] for c in inspect(engine).get_columns(table)}


def version(engine):
    with engine.connect() as c:
        return c.execute(select(SchemaVersionRow.version)).scalar()


def test_a_fresh_database_starts_at_the_latest_version(database_url):
    engine = make_engine(database_url)
    assert migrate(engine, [ADD_COLOR]) == 1
    assert version(engine) == 1, "already the latest layout: nothing run"


def test_an_existing_database_is_upgraded_and_keeps_its_runs(database_url):
    engine = make_engine(database_url)
    migrate(engine)  # Today's layout, as an older server left it...
    with engine.begin() as c:
        c.execute(text("DROP TABLE schema_version"))  # ...from before migrations.
        c.execute(text(
            "INSERT INTO runs (id, name, project, host, status, lost_contact, started_at, "
            "last_seen_at, current_step, total_steps, current_epoch, total_epochs, "
            "hyperparameters, architecture) VALUES ('old', 'old', '', '', 'finished', false, "
            "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 5, 5, 0, 0, '{}', '{}')"
        ))
    assert migrate(engine, [ADD_COLOR]) == 1
    assert "color" in columns(engine, "runs")
    with engine.connect() as c:
        assert c.execute(text("SELECT id, color FROM runs")).all() == [("old", "none")]
    assert migrate(engine, [ADD_COLOR]) == 1, "nothing left to do"


def test_a_database_from_a_newer_server_is_refused(database_url):
    engine = make_engine(database_url)
    migrate(engine, [ADD_COLOR])
    with pytest.raises(DatabaseTooNew):
        migrate(engine, [])


def test_versions_must_start_at_1_and_increase(database_url):
    engine = make_engine(database_url)
    with pytest.raises(ValueError):
        migrate(engine, [ADD_COLOR, ADD_COLOR])
    with pytest.raises(ValueError):
        migrate(engine, [Migration(0, "zero", lambda c: None)])


def test_the_server_starts_on_a_database_from_before_migrations(app, client, database_url):
    """What every existing installation goes through once."""
    from soliton_server.app import create_app

    client.put("/api/runs/kept", json={"name": "kept"})
    engine = make_engine(database_url)
    with engine.begin() as c:
        c.execute(text("DROP TABLE schema_version"))
    create_app(app.state.settings, stale_check_seconds=0)
    assert version(engine) == latest()
    with engine.connect() as c:
        assert c.execute(select(RunRow.id)).scalars().all() == ["kept"]
