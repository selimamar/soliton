"""Test fixtures: an API client on SQLite, and on a real PostgreSQL.

PostgreSQL comes from the `pgserver` package (a self-contained server in
.venv); its data lives in .cache/pg-tests and is wiped for every test.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine

from soliton_server.app import create_app
from soliton_server.config import Settings, normalize_database_url
from soliton_server.db import Base

TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class FakeClock:
    def __init__(self) -> None:
        self.now = datetime(2026, 11, 12, 9, 0, tzinfo=timezone.utc)

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **delta) -> None:
        self.now += timedelta(**delta)


@pytest.fixture(scope="session")
def postgres_url():
    """SOLITON_TEST_POSTGRES_URL if set, else a throwaway local server."""
    url = os.environ.get("SOLITON_TEST_POSTGRES_URL")
    if url:
        yield normalize_database_url(url)
        return
    try:
        import pgserver
    except ImportError:
        pytest.skip("pgserver is not installed")
    # Unix socket paths are limited to ~100 characters, so not under tmp_path.
    root = Path(os.environ.get("SOLITON_ROOT", Path(__file__).parents[2]))
    try:
        server = pgserver.get_server(root / ".cache" / "pg-tests", cleanup_mode="stop")
    except Exception:
        pytest.skip(
            "local PostgreSQL did not start (on macOS usually because other apps hold all "
            "System V shared memory segments); set SOLITON_TEST_POSTGRES_URL to use another"
        )
    yield normalize_database_url(server.get_uri())


@pytest.fixture(params=["sqlite", "postgres"])
def database_url(request, tmp_path):
    if request.param == "sqlite":
        return f"sqlite:///{tmp_path / 'test.db'}"
    url = request.getfixturevalue("postgres_url")
    engine = create_engine(url)
    Base.metadata.drop_all(engine)
    engine.dispose()
    return url


@pytest.fixture
def clock() -> FakeClock:
    return FakeClock()


@pytest.fixture
def notifications() -> list:
    return []


@pytest.fixture
def app(database_url, clock, notifications):
    settings = Settings(database_url=database_url, token=TOKEN, stale_after=timedelta(minutes=10))
    return create_app(settings, notifier=notifications.append, clock=clock, stale_check_seconds=0)


@pytest.fixture
def client(app):
    with TestClient(app, headers=AUTH) as client:
        yield client
