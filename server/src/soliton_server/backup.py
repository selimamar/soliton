"""Backups of the server's SQLite database: a consistent copy, made while
the server runs (SQLite's online backup, all pages in one step, so a
snapshot of one moment), checked, and readable by its owner only.

`soliton-server --backup PATH` (cli.py) writes one to a folder or file;
the app's "Download a backup" (GET /api/storage/backup) streams one. A
PostgreSQL database is backed up with pg_dump instead (server/README.md).

The copy holds everything the runs logged, and the hashes of the main and
job tokens (not the tokens). It never overwrites a file, and is written
under a temporary name in the destination's folder, then renamed, so a
file with the final name is always a complete, checked copy.
"""

from __future__ import annotations

import os
import secrets
import shutil
import sqlite3
import time
from datetime import datetime
from pathlib import Path

from sqlalchemy.engine import Engine, make_url

TEMPORARY_PREFIX = ".soliton-backup-"
STALE_AFTER = 3600  # Seconds before a leftover temporary copy is removed.


class BackupError(Exception):
    """Why a backup couldn't be made, in words for the person asking."""


def backup_name(now: datetime | None = None) -> str:
    """A dated file name, e.g. soliton-2026-11-15-093012.db (local time)."""
    return f"soliton-{(now or datetime.now()):%Y-%m-%d-%H%M%S}.db"


def sqlite_file(database_url: str) -> Path | None:
    """The file of a SQLite database URL; None for PostgreSQL or a database
    in memory."""
    url = make_url(database_url)
    if url.get_backend_name() != "sqlite" or url.database in (None, "", ":memory:"):
        return None
    return Path(url.database)


def back_up_file(database: Path, destination: str | os.PathLike,
                 now: datetime | None = None) -> tuple[Path, int]:
    """Copies the SQLite database [database] to [destination]: a folder
    (the copy gets a dated name) or the path of a new file. Returns where it
    went and its size. Safe while the server runs."""
    database = Path(database)
    if not database.is_file():
        raise BackupError(f"There is no database at {database}")
    target = Path(destination).expanduser()
    if target.is_dir():
        folder, name = target, backup_name(now)
        target = folder / name
        for n in range(2, 100):  # Two in the same second: soliton-…-2.db.
            if not (target.exists() or target.is_symlink()):
                break
            target = folder / name.replace(".db", f"-{n}.db")
    elif str(destination).endswith(("/", os.sep)):
        raise BackupError(f"There is no folder {target}: create it first")
    if not target.parent.is_dir():
        raise BackupError(f"There is no folder {target.parent}: create it first")
    if target.exists() or target.is_symlink():
        raise BackupError(f"{target} already exists: give another file name, or a folder "
                          "to get a dated one")
    # Never next to the database under a name SQLite would take for its own
    # (soliton.db-wal, -shm, -journal): it would read it as part of the database.
    if (target.parent.resolve() == database.parent.resolve()
            and target.name.startswith(database.name)):
        raise BackupError(f"{target.name} is too close to the database's own file names: "
                          "choose another name or folder")
    try:
        source = sqlite3.connect(f"{database.resolve().as_uri()}?mode=rw", uri=True, timeout=30)
    except sqlite3.Error as error:
        raise BackupError(f"Couldn't open the database: {error}") from None
    try:
        size = _copy(source, target)
    finally:
        source.close()
    return target, size


def back_up_engine(engine: Engine, folder: Path) -> Path:
    """A copy of the server's own (SQLite) database, through [engine], in a
    new temporary file in [folder]: the caller removes it. Refused when the
    disk doesn't have room for it."""
    if engine.dialect.name != "sqlite":
        raise BackupError("This server keeps its data in PostgreSQL: back it up with "
                          "pg_dump (see the server README)")
    database = sqlite_file(str(engine.url))
    needed = sum(p.stat().st_size for p in _database_files(database)) if database else 0
    free = shutil.disk_usage(folder).free
    if free < needed + 64 * 1024 * 1024:
        raise BackupError(f"Not enough free disk space on the server for a copy "
                          f"({needed // 2**20 + 64} MB needed, {free // 2**20} MB free)")
    remove_stale(folder)
    target = folder / f"{TEMPORARY_PREFIX}{secrets.token_hex(8)}.db"
    connection = engine.raw_connection()
    try:
        _copy(connection.driver_connection, target)
    finally:
        connection.close()
    return target


def remove_stale(folder: Path, older_than: float = STALE_AFTER) -> None:
    """Removes temporary copies a crashed server or backup left behind."""
    limit = time.time() - older_than
    try:
        for path in folder.glob(f"{TEMPORARY_PREFIX}*"):
            if path.is_file() and not path.is_symlink() and path.stat().st_mtime < limit:
                path.unlink(missing_ok=True)
    except OSError:
        pass


def _copy(source: sqlite3.Connection, target: Path) -> int:
    """Writes a checked copy of [source] to the new file [target], readable
    by its owner only. Returns its size."""
    temporary = target.with_name(f"{TEMPORARY_PREFIX}{secrets.token_hex(8)}.db")
    # Created private before anything is written to it.
    os.close(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    try:
        copy = sqlite3.connect(temporary)
        try:
            source.backup(copy)  # All pages in one step: one consistent moment.
            # One self-contained file (the server's database is in WAL mode,
            # whose recent changes live in a second file).
            copy.execute("PRAGMA journal_mode=DELETE")
            check = copy.execute("PRAGMA quick_check").fetchone()[0]
        finally:
            copy.close()
        if check != "ok":
            raise BackupError(f"The copy failed SQLite's check: {check}")
        _place(temporary, target)
    except sqlite3.Error as error:
        _remove(temporary)
        raise BackupError(f"Couldn't copy the database: {error}") from None
    except BaseException:
        _remove(temporary)
        raise
    return target.stat().st_size


def _place(temporary: Path, target: Path) -> None:
    """Renames [temporary] to [target], never replacing an existing file."""
    try:
        os.link(temporary, target)  # Fails if [target] exists, even if just made.
    except FileExistsError:
        raise BackupError(f"{target} already exists") from None
    except OSError:  # A file system without hard links (e.g. exFAT, some network drives).
        if target.exists():
            raise BackupError(f"{target} already exists") from None
        os.replace(temporary, target)
        return
    temporary.unlink()


def _remove(path: Path) -> None:
    for leftover in (path, path.with_name(path.name + "-journal")):
        try:
            leftover.unlink(missing_ok=True)
        except OSError:
            pass


def _database_files(database: Path) -> list[Path]:
    return [p for p in (database, database.with_name(database.name + "-wal")) if p.exists()]
