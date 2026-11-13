"""Reading and writing runs. Every response matches the app's `fromJson`.

All writes are idempotent: the logger may resend a batch (after a timeout,
or when `modelsapp sync` uploads a saved run), and points are keyed by
(run, metric, step), so a resent point replaces itself.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select
from sqlalchemy.orm import Session, sessionmaker

from .db import LayerPointRow, LayerRow, MetricPointRow, RunRow
from .floats import decode_float, downsample, encode_float, from_columns, to_columns
from .schemas import LayersEvent, MetricsEvent, RunIn, StatusEvent

TRAIN_LOSS = "train/loss"
LOSS_PREVIEW_POINTS = 60
_CHUNK = 500  # Rows per INSERT statement.


class RunNotFound(Exception):
    pass


@dataclass(frozen=True)
class Change:
    """Something that happened to a run, for live updates and notifications.

    [event] is "created", "updated", "finished", "crashed", "revived" (data
    arrived again after a lost contact) or "deleted".
    """

    run_id: str
    name: str
    event: str
    status: str
    message: str | None = None
    current_step: int = 0
    total_steps: int = 0

    def to_json(self) -> dict:
        return {
            "type": "run",
            "event": self.event,
            "runId": self.run_id,
            "name": self.name,
            "status": self.status,
            "statusMessage": self.message,
            "currentStep": self.current_step,
            "totalSteps": self.total_steps,
        }


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _change(row: RunRow, event: str) -> Change:
    return Change(
        run_id=row.id,
        name=row.name,
        event=event,
        status=row.status,
        message=row.status_message,
        current_step=row.current_step,
        total_steps=row.total_steps,
    )


def _upsert(session: Session, table, rows: list[dict], keys: Sequence[str]) -> None:
    """INSERT ... ON CONFLICT (keys) DO UPDATE, on SQLite or PostgreSQL."""
    if not rows:
        return
    dialect = session.get_bind().dialect.name
    if dialect == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
    else:
        from sqlalchemy.dialects.sqlite import insert
    for start in range(0, len(rows), _CHUNK):
        stmt = insert(table).values(rows[start : start + _CHUNK])
        updates = {c: stmt.excluded[c] for c in rows[0] if c not in keys}
        session.execute(stmt.on_conflict_do_update(index_elements=list(keys), set_=updates))


def _series(name: str, points: list[tuple[int, float]], max_points: int) -> dict:
    sampled = downsample(points, max_points, lambda p: p[1])
    return {
        "name": name,
        "points": [{"step": step, "value": encode_float(value)} for step, value in sampled],
    }


def _default_architecture(name: str) -> dict:
    return {"name": name, "type": "Model", "ownParameters": 0, "children": []}


class Store:
    def __init__(self, sessions: sessionmaker, clock: Callable[[], datetime] = utcnow):
        self._sessions = sessions
        self._clock = clock

    # Runs -----------------------------------------------------------------

    def put_run(self, run_id: str, body: RunIn) -> tuple[dict, Change]:
        """Creates the run, or updates its description if it exists."""
        now = self._clock()
        with self._sessions.begin() as session:
            row = session.get(RunRow, run_id)
            event = "updated"
            if row is None:
                started = min(body.startedAt or now, now)
                row = RunRow(
                    id=run_id,
                    status="live",
                    lost_contact=False,
                    started_at=started,
                    last_seen_at=now,
                    current_step=0,
                    current_epoch=0,
                )
                session.add(row)
                event = "created"
            elif body.startedAt is not None:
                row.started_at = min(body.startedAt, now)
            row.name = body.name
            row.project = body.project
            row.host = body.host
            row.total_steps = body.totalSteps
            row.total_epochs = body.totalEpochs
            row.hyperparameters = dict(body.hyperparameters)
            row.architecture = body.architecture or _default_architecture(body.name)
            session.flush()
            return self._run_json(session, row), _change(row, event)

    def list_runs(self) -> list[dict]:
        with self._sessions() as session:
            rows = session.scalars(select(RunRow).order_by(RunRow.started_at.desc())).all()
            return [self._run_json(session, row) for row in rows]

    def get_run(self, run_id: str) -> dict:
        with self._sessions() as session:
            return self._run_json(session, self._find(session, run_id))

    def delete_run(self, run_id: str) -> Change:
        with self._sessions.begin() as session:
            row = self._find(session, run_id)
            change = _change(row, "deleted")
            for table in (MetricPointRow, LayerPointRow, LayerRow):
                session.execute(delete(table).where(table.run_id == run_id))
            session.delete(row)
            return change

    # Ingest ---------------------------------------------------------------

    def ingest(self, run_id: str, events: Sequence) -> list[Change]:
        """Stores a batch of events. Returns what changed."""
        now = self._clock()
        changes: list[Change] = []
        with self._sessions.begin() as session:
            row = self._find(session, run_id)
            layers = {layer.name: layer for layer in session.scalars(
                select(LayerRow).where(LayerRow.run_id == run_id)
            )}
            metric_rows: list[dict] = []
            layer_point_rows: list[dict] = []
            for event in events:
                # Clamp to now: a clock running ahead mustn't keep a dead run alive.
                time = min(event.time or now, now)
                if isinstance(event, StatusEvent):
                    if row.status != event.status or row.lost_contact:
                        row.status = event.status
                        row.status_message = event.message
                        row.ended_at = time
                        row.lost_contact = False
                        changes.append(_change(row, event.status))
                    continue

                if row.lost_contact and time > (row.ended_at or row.started_at):
                    row.status, row.status_message, row.ended_at = "live", None, None
                    row.lost_contact = False
                    changes.append(_change(row, "revived"))
                row.last_seen_at = max(row.last_seen_at, time)

                if isinstance(event, MetricsEvent):
                    for name, value in event.values.items():
                        stored, code = to_columns(value)
                        metric_rows.append(
                            {"run_id": run_id, "name": name, "step": event.step,
                             "value": stored, "code": code}
                        )
                    if event.step >= row.current_step:
                        row.current_step = event.step
                        if event.epoch is not None:
                            row.current_epoch = event.epoch
                elif isinstance(event, LayersEvent):
                    for position, layer in enumerate(event.layers):
                        self._store_layer(
                            run_id, event.step, position, layer, layers, session, layer_point_rows
                        )
                    row.current_step = max(row.current_step, event.step)

            _upsert(session, MetricPointRow, metric_rows, ("run_id", "name", "step"))
            _upsert(session, LayerPointRow, layer_point_rows, ("run_id", "layer", "step"))
            changes.append(_change(row, "updated"))
        return changes

    @staticmethod
    def _store_layer(run_id, step, position, layer, layers, session, point_rows) -> None:
        grad = None if layer.gradNorm is None else encode_float(layer.gradNorm)
        point_rows.append({
            "run_id": run_id,
            "layer": layer.layerName,
            "step": step,
            "values": {
                "activationMean": encode_float(layer.activationMean),
                "activationStd": encode_float(layer.activationStd),
                "gradNorm": grad,
            },
        })
        histogram = layer.activationHistogram
        latest = {"deadFraction": encode_float(layer.deadFraction), "gradNorm": grad}
        histogram_json = {
            "min": encode_float(histogram.min),
            "max": encode_float(histogram.max),
            "counts": list(histogram.counts),
            "zeroCount": histogram.zeroCount,
        }
        existing = layers.get(layer.layerName)
        if existing is None:
            existing = LayerRow(
                run_id=run_id,
                name=layer.layerName,
                position=position,
                latest_step=step,
                histogram=histogram_json,
                latest=latest,
            )
            session.add(existing)
            layers[layer.layerName] = existing
        elif step >= existing.latest_step:
            existing.position = position
            existing.latest_step = step
            existing.histogram = histogram_json
            existing.latest = latest

    def mark_stale(self, stale_after: timedelta) -> list[Change]:
        """Marks live runs that went quiet as crashed ("lost contact")."""
        now = self._clock()
        cutoff = now - stale_after
        minutes = stale_after.total_seconds() / 60
        changes = []
        with self._sessions.begin() as session:
            rows = session.scalars(
                select(RunRow).where(RunRow.status == "live", RunRow.last_seen_at < cutoff)
            ).all()
            for row in rows:
                row.status = "crashed"
                row.lost_contact = True
                row.ended_at = row.last_seen_at
                row.status_message = (
                    f"Lost contact: no data for over {minutes:g} minutes. The job may have "
                    "been stopped (for example by a time limit) or lost its network "
                    "connection. It shows as live again if data arrives."
                )
                changes.append(_change(row, "crashed"))
        return changes

    # Time series ----------------------------------------------------------

    def metrics(self, run_id: str, max_points: int) -> list[dict]:
        with self._sessions() as session:
            self._find(session, run_id)
            result = session.execute(
                select(MetricPointRow.name, MetricPointRow.step,
                       MetricPointRow.value, MetricPointRow.code)
                .where(MetricPointRow.run_id == run_id)
                .order_by(MetricPointRow.name, MetricPointRow.step)
            )
            by_name: dict[str, list[tuple[int, float]]] = defaultdict(list)
            for name, step, value, code in result:
                by_name[name].append((step, from_columns(value, code)))
        return [_series(name, points, max_points) for name, points in by_name.items()]

    def layers(self, run_id: str, max_points: int) -> list[dict]:
        with self._sessions() as session:
            self._find(session, run_id)
            layer_rows = session.scalars(
                select(LayerRow)
                .where(LayerRow.run_id == run_id)
                .order_by(LayerRow.position, LayerRow.name)
            ).all()
            history: dict[str, dict[str, list[tuple[int, float]]]] = defaultdict(
                lambda: defaultdict(list)
            )
            for layer, step, values in session.execute(
                select(LayerPointRow.layer, LayerPointRow.step, LayerPointRow.values)
                .where(LayerPointRow.run_id == run_id)
                .order_by(LayerPointRow.layer, LayerPointRow.step)
            ):
                for key, value in values.items():
                    if value is not None:
                        history[layer][key].append((step, decode_float(value)))
        result = []
        for row in layer_rows:
            series = history[row.name]
            result.append({
                "layerName": row.name,
                "activationMean": _series(
                    f"{row.name}/act_mean", series["activationMean"], max_points
                ),
                "activationStd": _series(f"{row.name}/act_std", series["activationStd"], max_points),
                "gradNorm": _series(f"{row.name}/grad_norm", series["gradNorm"], max_points),
                "activationHistogram": row.histogram,
                "deadFraction": row.latest.get("deadFraction", 0),
            })
        return result

    def grad_norms(self, run_id: str) -> list[dict]:
        with self._sessions() as session:
            self._find(session, run_id)
            rows = session.scalars(
                select(LayerRow)
                .where(LayerRow.run_id == run_id)
                .order_by(LayerRow.position, LayerRow.name)
            ).all()
            return [
                {"layerName": row.name, "gradNorm": row.latest["gradNorm"]}
                for row in rows
                if row.latest.get("gradNorm") is not None
            ]

    # Helpers --------------------------------------------------------------

    @staticmethod
    def _find(session: Session, run_id: str) -> RunRow:
        row = session.get(RunRow, run_id)
        if row is None:
            raise RunNotFound(run_id)
        return row

    @staticmethod
    def _run_json(session: Session, row: RunRow) -> dict:
        losses = [
            from_columns(value, code)
            for value, code in session.execute(
                select(MetricPointRow.value, MetricPointRow.code)
                .where(MetricPointRow.run_id == row.id, MetricPointRow.name == TRAIN_LOSS)
                .order_by(MetricPointRow.step)
            )
        ]
        preview = downsample(losses, LOSS_PREVIEW_POINTS, lambda v: v)
        return {
            "id": row.id,
            "name": row.name,
            "project": row.project,
            "host": row.host,
            "status": row.status,
            "startedAt": iso(row.started_at),
            "endedAt": iso(row.ended_at),
            "currentStep": row.current_step,
            "totalSteps": row.total_steps,
            "currentEpoch": row.current_epoch,
            "totalEpochs": row.total_epochs,
            "hyperparameters": row.hyperparameters,
            "architecture": row.architecture,
            "lossPreview": [encode_float(v) for v in preview],
            "statusMessage": row.status_message,
        }
