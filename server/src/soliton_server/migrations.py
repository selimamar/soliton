"""Database migrations: numbered steps that bring an existing database up to
the current layout, so a server update keeps every run already stored.

How it works, on every start (`migrate`):

- New tables are created (`create_all` never changes a table that exists).
- A fresh database is marked as being at the latest version: it already
  has the current layout.
- An existing one runs, in order, each migration newer than the version it
  records (`schema_version`); a database from before migrations existed is
  version 0, the layout they started from.
- A database newer than this server (a later server ran on it) is refused,
  rather than used with a layout this code doesn't know.

To change an existing table: change its model in db.py, then append a
`Migration` with the next version that does the same to existing databases
(e.g. `add_column`). Never edit or reorder migrations already released.
New tables need no migration.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass

from sqlalchemy import Column, Connection, Engine, inspect, select, text
from sqlalchemy.schema import CreateColumn

from .db import Base, SchemaVersionRow


@dataclass(frozen=True)
class Migration:
    version: int
    description: str
    upgrade: Callable[[Connection], None]


def add_column(connection: Connection, table: str, column: Column) -> None:
    """ALTER TABLE ... ADD COLUMN, on SQLite and PostgreSQL. Give the column
    a default (server_default) or make it nullable: existing rows need a
    value."""
    if column.name in {c["name"] for c in inspect(connection).get_columns(table)}:
        return  # Already there (a half-finished earlier attempt).
    definition = CreateColumn(column).compile(dialect=connection.dialect)
    connection.execute(text(f"ALTER TABLE {table} ADD COLUMN {definition}"))


# The migrations, oldest first. None yet: version 0 is the layout of
# 2026-11-15 (every table in db.py then).
MIGRATIONS: Sequence[Migration] = ()


class DatabaseTooNew(Exception):
    """The database was upgraded by a newer server than this one."""


def latest(migrations: Sequence[Migration] = MIGRATIONS) -> int:
    return migrations[-1].version if migrations else 0


def migrate(engine: Engine, migrations: Sequence[Migration] = MIGRATIONS) -> int:
    """Brings the database up to date (see the module doc). Returns the
    version it is now at."""
    versions = [m.version for m in migrations]
    if versions != sorted(set(versions)) or (versions and versions[0] < 1):
        raise ValueError("migration versions must start at 1 and increase")
    fresh = not inspect(engine).has_table("runs")
    Base.metadata.create_all(engine)
    target = latest(migrations)
    with engine.begin() as connection:
        stored = connection.execute(select(SchemaVersionRow.version)).scalar()
        if stored is None:
            stored = target if fresh else 0
            connection.execute(SchemaVersionRow.__table__.insert().values(id=1, version=stored))
        if stored > target:
            raise DatabaseTooNew(
                f"The database is at version {stored}, newer than this server knows ({target}): "
                "update the server."
            )
        for migration in migrations:
            if migration.version > stored:
                migration.upgrade(connection)
                connection.execute(
                    SchemaVersionRow.__table__.update().values(version=migration.version)
                )
                stored = migration.version
    return stored
