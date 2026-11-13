"""Database tables. Works with SQLite (local) and PostgreSQL (server).

Tables are created on startup. There are no migrations yet: after a change
to an existing table, start from a fresh database (new tables are fine:
they are created in an existing database too).
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Double,
    Engine,
    ForeignKey,
    Integer,
    SmallInteger,
    String,
    Text,
    create_engine,
    event,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker
from sqlalchemy.types import TypeDecorator


class UtcDateTime(TypeDecorator):
    """Timezone-aware UTC datetimes on every database (SQLite drops the
    timezone, PostgreSQL keeps it)."""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError("naive datetime")
        return value.astimezone(timezone.utc)

    def process_result_value(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)


class Base(DeclarativeBase):
    pass


class RunRow(Base):
    __tablename__ = "runs"

    id: Mapped[str] = mapped_column(String(128), primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    project: Mapped[str] = mapped_column(String(200), default="")
    host: Mapped[str] = mapped_column(String(200), default="")
    status: Mapped[str] = mapped_column(String(16), default="live")
    status_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    # True while the run is "crashed" only because it stopped sending data.
    lost_contact: Mapped[bool] = mapped_column(Boolean, default=False)
    started_at: Mapped[datetime] = mapped_column(UtcDateTime)
    ended_at: Mapped[datetime | None] = mapped_column(UtcDateTime, nullable=True)
    last_seen_at: Mapped[datetime] = mapped_column(UtcDateTime)
    total_steps: Mapped[int] = mapped_column(Integer, default=0)
    total_epochs: Mapped[int] = mapped_column(Integer, default=0)
    current_step: Mapped[int] = mapped_column(Integer, default=0)
    current_epoch: Mapped[int] = mapped_column(Integer, default=0)
    hyperparameters: Mapped[dict] = mapped_column(JSON, default=dict)
    architecture: Mapped[dict] = mapped_column(JSON)


class MetricPointRow(Base):
    """One value of one scalar metric. Non-finite values: see floats.py."""

    __tablename__ = "metric_points"

    run_id: Mapped[str] = mapped_column(
        ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    name: Mapped[str] = mapped_column(String(200), primary_key=True)
    step: Mapped[int] = mapped_column(Integer, primary_key=True)
    value: Mapped[float | None] = mapped_column(Double, nullable=True)
    code: Mapped[int] = mapped_column(SmallInteger, default=0)


class RunNotesRow(Base):
    """What people add to a run: tags and a note. In a table of its own so
    the logger, which resends the run's description, never overwrites them."""

    __tablename__ = "run_notes"

    run_id: Mapped[str] = mapped_column(
        ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    tags: Mapped[list] = mapped_column(JSON, default=list)
    notes: Mapped[str] = mapped_column(Text, default="")
    updated_at: Mapped[datetime] = mapped_column(UtcDateTime)


class RunSystemRow(Base):
    """What the run trains on (machine, GPUs, software, Slurm job), as the
    logger describes it. In a table of its own so that older databases get
    it without a migration."""

    __tablename__ = "run_system"

    run_id: Mapped[str] = mapped_column(
        ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    info: Mapped[dict] = mapped_column(JSON)


class LayerRow(Base):
    """A watched layer, with its latest statistics."""

    __tablename__ = "layers"

    run_id: Mapped[str] = mapped_column(
        ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    name: Mapped[str] = mapped_column(String(200), primary_key=True)
    position: Mapped[int] = mapped_column(Integer)  # Order in the model.
    latest_step: Mapped[int] = mapped_column(Integer)
    # Histogram JSON as the app reads it; deadFraction/gradNorm as JSON
    # numbers (or "NaN" strings).
    histogram: Mapped[dict] = mapped_column(JSON)
    latest: Mapped[dict] = mapped_column(JSON)


class LayerPointRow(Base):
    """A layer's statistics at one step: activationMean, activationStd and
    gradNorm, as JSON numbers (or "NaN" strings)."""

    __tablename__ = "layer_points"

    run_id: Mapped[str] = mapped_column(
        ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    layer: Mapped[str] = mapped_column(String(200), primary_key=True)
    step: Mapped[int] = mapped_column(Integer, primary_key=True)
    values: Mapped[dict] = mapped_column(JSON)


class FieldRow(Base):
    """A field snapshot at one step (see schemas.FieldEvent). [meta] holds
    shape, originalShape, min, max and stats as JSON (stats may hold "NaN"
    strings); the data stays base64 text, as the app reads it."""

    __tablename__ = "field_snapshots"

    run_id: Mapped[str] = mapped_column(
        ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    name: Mapped[str] = mapped_column(String(200), primary_key=True)
    step: Mapped[int] = mapped_column(Integer, primary_key=True)
    meta: Mapped[dict] = mapped_column(JSON)
    prediction: Mapped[str] = mapped_column(Text)
    target: Mapped[str | None] = mapped_column(Text, nullable=True)


def make_engine(url: str) -> Engine:
    if url.startswith("sqlite"):
        engine = create_engine(url, connect_args={"check_same_thread": False, "timeout": 30})

        @event.listens_for(engine, "connect")
        def _sqlite_pragmas(dbapi_connection, _):
            cursor = dbapi_connection.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.execute("PRAGMA journal_mode=WAL")
            cursor.close()

        return engine
    if not url.startswith("postgresql"):
        raise ValueError("Only SQLite and PostgreSQL databases are supported")
    return create_engine(url, pool_pre_ping=True)


def make_sessionmaker(engine: Engine) -> sessionmaker:
    Base.metadata.create_all(engine)
    return sessionmaker(engine, expire_on_commit=False)
