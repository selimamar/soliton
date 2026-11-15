from __future__ import annotations

import os
import sqlite3
import stat
import time
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from conftest import AUTH, TOKEN
from soliton_server import cli
from soliton_server.app import create_app
from soliton_server.backup import (
    TEMPORARY_PREFIX,
    BackupError,
    back_up_file,
    remove_stale,
    sqlite_file,
)
from soliton_server.config import Settings
from test_api import big_run, create_run

NOW = datetime(2026, 11, 15, 9, 30, 12)


def run_ids(path) -> set:
    with sqlite3.connect(path) as connection:
        return {row[0] for row in connection.execute("SELECT id FROM runs")}


@pytest.fixture
def sqlite_client(tmp_path, clock):
    settings = Settings(database_url=f"sqlite:///{tmp_path / 'data' / 'soliton.db'}",
                        token=TOKEN, stale_after=timedelta(minutes=10))
    (tmp_path / "data").mkdir()
    app = create_app(settings, clock=clock, stale_check_seconds=0)
    with TestClient(app, headers=AUTH) as client:
        yield client


def database(tmp_path):
    return tmp_path / "data" / "soliton.db"


# The command (soliton-server --backup) ---------------------------------------


def test_a_folder_gets_a_dated_private_complete_copy(sqlite_client, tmp_path):
    create_run(sqlite_client, "run-a")
    big_run(sqlite_client, "run-b", steps=200)
    folder = tmp_path / "backups"
    folder.mkdir()
    path, size = back_up_file(database(tmp_path), folder, now=NOW)
    assert path == folder / "soliton-2026-11-15-093012.db"
    assert size == path.stat().st_size > 0
    assert stat.S_IMODE(path.stat().st_mode) == 0o600, "it holds everything the runs logged"
    assert run_ids(path) == {"run-a", "run-b"}
    with sqlite3.connect(path) as copy:
        assert copy.execute("PRAGMA journal_mode").fetchone()[0] == "delete", "one file"
        assert copy.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert sorted(p.name for p in folder.iterdir()) == [path.name], "no temporary files left"


def test_a_copy_while_something_is_being_written_has_only_what_was_saved(sqlite_client, tmp_path):
    create_run(sqlite_client, "saved")
    writer = sqlite3.connect(database(tmp_path))
    writer.execute("BEGIN IMMEDIATE")
    writer.execute("UPDATE runs SET name = 'half-written' WHERE id = 'saved'")
    try:
        path, _ = back_up_file(database(tmp_path), tmp_path / "copy.db")
    finally:
        writer.rollback()
        writer.close()
    with sqlite3.connect(path) as copy:
        assert copy.execute("SELECT name FROM runs").fetchone()[0] != "half-written"


def test_two_backups_to_a_folder_in_the_same_second_both_keep(sqlite_client, tmp_path):
    first, _ = back_up_file(database(tmp_path), tmp_path, now=NOW)
    second, _ = back_up_file(database(tmp_path), tmp_path, now=NOW)
    assert (first.name, second.name) == ("soliton-2026-11-15-093012.db",
                                         "soliton-2026-11-15-093012-2.db")


def test_a_backup_never_replaces_a_file(sqlite_client, tmp_path):
    existing = tmp_path / "copy.db"
    existing.write_text("keep me")
    with pytest.raises(BackupError, match="already exists"):
        back_up_file(database(tmp_path), existing)
    assert existing.read_text() == "keep me"


@pytest.mark.parametrize("name", ["soliton.db", "soliton.db-wal", "soliton.db-journal"])
def test_a_backup_never_goes_where_sqlite_would_read_it_as_the_database(
        sqlite_client, tmp_path, name):
    target = tmp_path / "data" / name
    target.unlink(missing_ok=True)
    with pytest.raises(BackupError):
        back_up_file(database(tmp_path), target)


def test_a_missing_folder_or_database_is_said_plainly(sqlite_client, tmp_path):
    with pytest.raises(BackupError, match="no folder"):
        back_up_file(database(tmp_path), tmp_path / "nowhere" / "copy.db")
    with pytest.raises(BackupError, match="no folder"):
        back_up_file(database(tmp_path), f"{tmp_path / 'nowhere'}/")
    with pytest.raises(BackupError, match="no database"):
        back_up_file(tmp_path / "missing.db", tmp_path)
    assert not (tmp_path / "missing.db").exists(), "it doesn't create one"


def test_the_command_copies_without_creating_a_token(tmp_path, monkeypatch, capsys):
    data = tmp_path / "data"
    monkeypatch.setenv("SOLITON_DATA_DIR", str(data))
    monkeypatch.delenv("SOLITON_DATABASE_URL", raising=False)
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(SystemExit) as exit:
        cli.main(["--backup", str(tmp_path)])
    assert exit.value.code == 1 and "no database" in capsys.readouterr().err
    assert not data.exists(), "a backup never creates the data folder or a token"

    data.mkdir()
    sqlite3.connect(data / "soliton.db").execute("CREATE TABLE runs (id TEXT)").connection.close()
    out = tmp_path / "out"
    out.mkdir()
    with pytest.raises(SystemExit) as exit:
        cli.main(["--backup", str(out)])
    assert exit.value.code == 0
    assert "Backed up" in capsys.readouterr().out
    assert len(list(out.glob("soliton-*.db"))) == 1
    assert not (data / "token").exists()


def test_the_command_points_postgres_to_pg_dump(monkeypatch, capsys):
    monkeypatch.setenv("SOLITON_DATABASE_URL", "postgres://user:secret@db.example/soliton")
    with pytest.raises(SystemExit) as exit:
        cli.main(["--backup", "."])
    err = capsys.readouterr().err
    assert exit.value.code == 1 and "pg_dump" in err and "secret" not in err


def test_only_old_leftover_temporary_copies_are_removed(tmp_path):
    old, recent, other = (tmp_path / f"{TEMPORARY_PREFIX}old.db",
                          tmp_path / f"{TEMPORARY_PREFIX}new.db", tmp_path / "soliton-old.db")
    for path in (old, recent, other):
        path.write_text("x")
    hours_ago = time.time() - 2 * 3600
    os.utime(old, (hours_ago, hours_ago))
    os.utime(other, (hours_ago, hours_ago))
    remove_stale(tmp_path)
    assert not old.exists() and recent.exists() and other.exists()


def test_sqlite_file_names_only_a_database_on_disk():
    assert str(sqlite_file("sqlite:////data/soliton.db")) == "/data/soliton.db"
    assert sqlite_file("sqlite://") is None and sqlite_file("sqlite:///:memory:") is None
    assert sqlite_file("postgresql+psycopg://u:p@host/db") is None


# The app's "Download a backup" (GET /api/storage/backup) --------------------


def test_downloading_a_backup_gives_the_whole_database_and_leaves_nothing(sqlite_client, tmp_path):
    create_run(sqlite_client, "run-a")
    reply = sqlite_client.get("/api/storage/backup")
    assert reply.status_code == 200
    assert reply.headers["content-type"] == "application/vnd.sqlite3"
    assert reply.headers["cache-control"] == "no-store"
    assert reply.headers["content-disposition"].startswith('attachment; filename="soliton-')
    assert int(reply.headers["content-length"]) == len(reply.content)
    saved = tmp_path / "downloaded.db"
    saved.write_bytes(reply.content)
    assert run_ids(saved) == {"run-a"}
    leftovers = [p.name for p in (tmp_path / "data").iterdir() if p.name.startswith(TEMPORARY_PREFIX)]
    assert leftovers == []


def test_a_downloaded_backup_restores_into_a_working_server(sqlite_client, tmp_path, clock):
    create_run(sqlite_client, "run-a")
    restored = tmp_path / "restored" / "soliton.db"
    restored.parent.mkdir()
    restored.write_bytes(sqlite_client.get("/api/storage/backup").content)
    settings = Settings(database_url=f"sqlite:///{restored}", token="another-token-0123456789",
                        stale_after=timedelta(minutes=10))
    app = create_app(settings, clock=clock, stale_check_seconds=0)
    with TestClient(app, headers={"Authorization": "Bearer another-token-0123456789"}) as client:
        assert [r["id"] for r in client.get("/api/runs").json()] == ["run-a"]


def test_only_the_main_token_can_download_a_backup(sqlite_client):
    job = sqlite_client.post("/api/job-token").json()["token"]
    assert sqlite_client.get("/api/storage/backup",
                             headers={"Authorization": f"Bearer {job}"}).status_code == 403
    assert sqlite_client.get("/api/storage/backup", headers={"Authorization": ""}).status_code == 401
    assert sqlite_client.get("/api/storage/backup",
                             headers={"Authorization": "Bearer wrong-token-0123456789"}
                             ).status_code == 401


def test_a_postgres_server_points_to_pg_dump(client, database_url):
    reply = client.get("/api/storage/backup")
    if database_url.startswith("sqlite"):
        assert reply.status_code == 200
    else:
        assert reply.status_code == 409 and "pg_dump" in reply.json()["detail"]


def test_a_full_disk_refuses_a_backup(sqlite_client, monkeypatch):
    import shutil

    from soliton_server import backup

    monkeypatch.setattr(backup.shutil, "disk_usage",
                        lambda _: shutil._ntuple_diskusage(100, 100, 1024))
    reply = sqlite_client.get("/api/storage/backup")
    assert reply.status_code == 409 and "disk space" in reply.json()["detail"]
