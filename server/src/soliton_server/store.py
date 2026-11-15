"""Reading and writing runs. Every response matches the app's `fromJson`.

All writes are idempotent: the logger may resend a batch (after a timeout,
or when `soliton sync` uploads a saved run), and points are keyed by
(run, metric, step), so a resent point replaces itself.
"""

from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session, sessionmaker

from .db import (
    DatasetRow,
    DatasetUseRow,
    FieldRow,
    LayerPointRow,
    LayerRow,
    MetricPointRow,
    RunItemRow,
    RunNotesRow,
    RunOutputRow,
    RunResumeRow,
    RunRow,
    RunSimulationRow,
    RunSystemRow,
    ServerSettingRow,
)
from .floats import decode_float, downsample, encode_float, from_columns, to_columns
from .schemas import (
    CurveEvent,
    DatasetIn,
    EvalEvent,
    FieldEvent,
    LayersEvent,
    MetricsEvent,
    OUTPUT_KEPT,
    OutputEvent,
    RunIn,
    RunNotesIn,
    StatusEvent,
)

TRAIN_LOSS = "train/loss"
SIM_TIME = "sim/t"  # A simulation's simulated time, logged as a metric.
LOSS_PREVIEW_POINTS = 60
_CHUNK = 500  # Rows per INSERT statement.


class RunNotFound(Exception):
    pass


class DatasetNotFound(Exception):
    pass


class FieldNotFound(Exception):
    """The run exists, but has no such field (at that step)."""


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
    # False: nothing to alert about (e.g. a queued job you cancelled yourself).
    notify: bool = True

    def to_json(self) -> dict:
        return {
            **({} if self.notify else {"notify": False}),
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
    finite = [value for _, value in points if math.isfinite(value)]
    return {
        "name": name,
        "points": [{"step": step, "value": encode_float(value)} for step, value in sampled],
        # Over every point: downsampling keeps each bucket's extremes, so the
        # points' own mean leans toward (min + max) / 2.
        "mean": sum(finite) / len(finite) if finite else None,
    }


def _field_row(run_id: str, event: FieldEvent) -> dict:
    return {
        "run_id": run_id,
        "name": event.name,
        "step": event.step,
        "meta": {
            "kind": event.kind,
            "shape": list(event.shape),
            "originalShape": list(event.originalShape or event.shape),
            "frames": event.frames,
            "times": None if event.times is None else [encode_float(t) for t in event.times],
            "min": encode_float(event.min),
            "max": encode_float(event.max),
            "stats": {k: encode_float(v) for k, v in event.stats.items()},
            "frameStats": {
                k: [encode_float(v) for v in values] for k, values in event.frameStats.items()
            },
            "layer": event.layer,
            "position": event.position,
            "reduction": event.reduction,
            "layerShape": event.layerShape,
            "sample": event.sample,
            "worstOf": event.worstOf,
            "extent": None if event.extent is None else [
                [encode_float(a), encode_float(b)] for a, b in event.extent
            ],
            "axes": event.axes,
            "spectrum": None if event.spectrum is None else {
                "k": [encode_float(v) for v in event.spectrum.k],
                "prediction": [encode_float(v) for v in event.spectrum.prediction],
                "target": None if event.spectrum.target is None
                else [encode_float(v) for v in event.spectrum.target],
            },
        },
        "prediction": event.prediction,
        "target": event.target,
    }


def _item_row(run_id: str, event) -> dict:
    """An eval or curve, as the app reads it (non-finite numbers as strings)."""
    data = event.model_dump(exclude={"type", "step", "epoch", "time", "name"})
    return {"run_id": run_id, "type": event.type, "name": event.name, "step": event.step,
            "data": _encode_floats(data)}


def _encode_floats(value):
    if isinstance(value, float):
        return encode_float(value)
    if isinstance(value, dict):
        return {k: _encode_floats(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_encode_floats(v) for v in value]
    return value


def _default_architecture(name: str) -> dict:
    return {"name": name, "type": "Model", "ownParameters": 0, "children": []}


def _aware(moment: datetime) -> datetime:
    """[moment] in UTC: SQLite hands back stored times without a time zone."""
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


# A run quiet for this long after its Slurm job's time limit was stopped by it.
TIME_LIMIT_GRACE = timedelta(minutes=1)

# Warn that a run won't finish before its time limit only once its pace is
# worth trusting (past start-up: data loading, compiling), and only when
# it misses the limit by more than a rounding error.
PACE_AFTER = timedelta(minutes=10)
PACE_AFTER_PROGRESS = 0.02
TIME_LIMIT_MARGIN = timedelta(minutes=5)


def format_span(span: timedelta) -> str:
    """"3h 40m", "45m", "2d 4h": for messages."""
    minutes = max(0, round(span.total_seconds() / 60))
    days, minutes = divmod(minutes, 24 * 60)
    hours, minutes = divmod(minutes, 60)
    if days:
        return f"{days}d {hours}h" if hours else f"{days}d"
    if hours:
        return f"{hours}h {minutes}m" if minutes else f"{hours}h"
    return f"{minutes}m"


def _slurm(system: RunSystemRow | None) -> dict:
    """The Slurm job the logger described (`system.slurm`), or {}."""
    return _slurm_of(system.info if system is not None else None)


def _slurm_of(system: object) -> dict:
    """`slurm` of a system description, or {}."""
    slurm = system.get("slurm") if isinstance(system, dict) else None
    return slurm if isinstance(slurm, dict) else {}


def _parse_time(text: object) -> datetime | None:
    """"2026-11-14T18:32:22Z" as an aware datetime, or None."""
    if not isinstance(text, str):
        return None
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


class Store:
    def __init__(self, sessions: sessionmaker, clock: Callable[[], datetime] = utcnow):
        self._sessions = sessions
        self._clock = clock
        # (run id, time limit) already warned about, so each job warns once.
        # Kept in memory: after a restart a run may warn once more.
        self._time_limit_warned: set[tuple[str, str]] = set()

    # Runs -----------------------------------------------------------------

    def put_run(self, run_id: str, body: RunIn) -> tuple[dict, list[Change]]:
        """Creates the run, or updates its description if it exists.

        With `queued` (from `soliton sbatch` and `soliton queue`), a Slurm job
        still waiting to start. When it starts, its logger's description
        turns it live: the same run (`soliton sbatch --id`), or a new one
        that takes over from it (matched by Slurm job id)."""
        now = self._clock()
        changes: list[Change] = []
        with self._sessions.begin() as session:
            row = session.get(RunRow, run_id)
            if row is not None and body.queued:
                return self._requeue(session, row, body, now)
            event = "updated"
            if row is None:
                started = min(body.startedAt or now, now)
                row = RunRow(
                    id=run_id,
                    status="queued" if body.queued else "live",
                    lost_contact=False,
                    started_at=started,
                    last_seen_at=now,
                    current_step=0,
                    current_epoch=0,
                )
                session.add(row)
                event = "created"
            elif row.status == "queued":
                # Its job has started.
                row.status, row.status_message, row.ended_at = "live", None, None
                row.started_at = min(body.startedAt or now, now)
                row.last_seen_at = now
                event = "started"
                self._mark_resume(session, row)
            else:
                if body.startedAt is not None:
                    # A new process continuing a run that had ended (a job
                    # restarted from a checkpoint, `init(id=...)`): live again.
                    # Re-sending the run as it was (`soliton sync`) carries its
                    # original start, from before it ended, and changes nothing.
                    restarted = min(body.startedAt, now)
                    ended = row.ended_at
                    if row.status != "live" and ended is not None and _aware(restarted) > _aware(ended):
                        row.status, row.status_message, row.ended_at = "live", None, None
                        row.lost_contact = False
                        row.last_seen_at = now
                        event = "revived"
                        self._mark_resume(session, row)
                    row.started_at = restarted
            row.name = body.name
            row.project = body.project
            row.host = body.host
            row.total_steps = body.totalSteps
            row.total_epochs = body.totalEpochs
            row.hyperparameters = dict(body.hyperparameters)
            row.architecture = body.architecture or _default_architecture(body.name)
            if body.system is not None:
                system = session.get(RunSystemRow, run_id)
                if system is None:
                    session.add(RunSystemRow(run_id=run_id, info=body.system))
                else:
                    system.info = body.system
            if body.simulation is not None:
                info = body.simulation.model_dump(exclude_none=True)
                simulation = session.get(RunSimulationRow, run_id)
                if simulation is None:
                    session.add(RunSimulationRow(run_id=run_id, info=info))
                else:  # Resent: keep whether it diverged.
                    simulation.info = {**info, **{k: v for k, v in simulation.info.items()
                                                  if k == "diverged"}}
            if body.datasets is not None:
                session.execute(delete(DatasetUseRow).where(DatasetUseRow.run_id == run_id))
                session.flush()
                for dataset_id in dict.fromkeys(body.datasets):
                    session.add(DatasetUseRow(run_id=run_id, dataset_id=dataset_id))
            if (body.tags or body.notes) and session.get(RunNotesRow, run_id) is None:
                session.add(RunNotesRow(run_id=run_id, tags=list(body.tags), notes=body.notes,
                                        updated_at=now))
            session.flush()
            if event == "created" and not body.queued:
                changes = self._take_over_queued(session, run_id, body.system)
            return self._run_json(session, row), [_change(row, event), *changes]

    @classmethod
    def _mark_resume(cls, session: Session, row: RunRow) -> None:
        """Notes where [row] stands as a new process takes it over."""
        resume = session.get(RunResumeRow, row.id)
        if resume is None:
            resume = RunResumeRow(run_id=row.id)
            session.add(resume)
        resume.step = row.current_step
        resume.sim_time = cls._sim_time(session, row.id)

    @staticmethod
    def _sim_time(session: Session, run_id: str) -> float | None:
        """A simulation's latest simulated time (finite), or None."""
        values = session.execute(
            select(MetricPointRow.value, MetricPointRow.code)
            .where(MetricPointRow.run_id == run_id, MetricPointRow.name == SIM_TIME)
            .order_by(MetricPointRow.step.desc())
            .limit(1)
        ).first()
        time = None if values is None else from_columns(*values)
        return time if time is not None and math.isfinite(time) else None

    def _requeue(self, session: Session, row: RunRow, body: RunIn,
                 now: datetime) -> tuple[dict, list[Change]]:
        """A queued description for a run that exists: what Slurm now says of
        a waiting job (`soliton queue`), or a job continuing an ended run
        (`soliton sbatch --id`). Only its job changes: the description it
        logged stays. A run that has started stays as it is."""
        if row.status == "live":
            return self._run_json(session, row), []
        if row.status != "queued":
            row.status, row.status_message, row.ended_at = "queued", None, None
            row.lost_contact = False
            row.started_at = min(body.startedAt or now, now)
            row.last_seen_at = now
        if body.system is not None:
            system = session.get(RunSystemRow, row.id)
            if system is None:
                session.add(RunSystemRow(run_id=row.id, info=body.system))
            elif row.current_step == 0:
                system.info = body.system
            else:  # Keep the machine it last ran on; the job is the new one.
                system.info = {**system.info, "slurm": _slurm_of(body.system)}
        session.flush()
        return self._run_json(session, row), [_change(row, "updated")]

    def _take_over_queued(self, session: Session, run_id: str,
                          system: dict | None) -> list[Change]:
        """Deletes the queued placeholders (`soliton sbatch`) of the Slurm job
        a new run started in: the run takes their place."""
        slurm = _slurm_of(system)
        jobs = {str(slurm[key]) for key in ("jobId", "arrayJobId") if slurm.get(key)}
        if not jobs:
            return []
        changes = []
        for queued in session.scalars(select(RunRow).where(RunRow.status == "queued")).all():
            theirs = _slurm(session.get(RunSystemRow, queued.id))
            if queued.id == run_id or str(theirs.get("jobId")) not in jobs:
                continue
            if theirs.get("cluster") and slurm.get("cluster") and theirs["cluster"] != slurm["cluster"]:
                continue
            changes.append(_change(queued, "deleted"))
            for table in (RunNotesRow, RunSystemRow, RunSimulationRow, DatasetUseRow):
                session.execute(delete(table).where(table.run_id == queued.id))
            session.delete(queued)
        return changes

    def update_notes(self, run_id: str, body: RunNotesIn) -> tuple[dict, Change]:
        """Sets a run's tags and/or note (from the app)."""
        with self._sessions.begin() as session:
            row = self._find(session, run_id)
            notes = session.get(RunNotesRow, run_id)
            if notes is None:
                notes = RunNotesRow(run_id=run_id, tags=[], notes="")
                session.add(notes)
            if body.tags is not None:
                notes.tags = list(body.tags)
            if body.notes is not None:
                notes.notes = body.notes
            notes.updated_at = self._clock()
            session.flush()
            return self._run_json(session, row), _change(row, "updated")

    def list_runs(self, status: str | None = None) -> list[dict]:
        """Every run, newest first; only those with [status] if given."""
        with self._sessions() as session:
            query = select(RunRow).order_by(RunRow.started_at.desc())
            if status is not None:
                query = query.where(RunRow.status == status)
            return [self._run_json(session, row) for row in session.scalars(query).all()]

    # Server settings -------------------------------------------------------

    def setting(self, key: str) -> str | None:
        with self._sessions() as session:
            row = session.get(ServerSettingRow, key)
            return None if row is None else row.value

    def set_setting(self, key: str, value: str | None) -> None:
        """Saves [value] under [key]; None removes it."""
        with self._sessions.begin() as session:
            row = session.get(ServerSettingRow, key)
            if value is None:
                if row is not None:
                    session.delete(row)
            elif row is None:
                session.add(ServerSettingRow(key=key, value=value))
            else:
                row.value = value

    def get_run(self, run_id: str) -> dict:
        with self._sessions() as session:
            return self._run_json(session, self._find(session, run_id))

    def output(self, run_id: str) -> dict:
        """The latest lines the run's script printed, and how many it
        printed in all (older lines aren't kept)."""
        with self._sessions() as session:
            self._find(session, run_id)
            rows = session.execute(
                select(RunOutputRow.number, RunOutputRow.line)
                .where(RunOutputRow.run_id == run_id)
                .order_by(RunOutputRow.number)
            ).all()
            return {
                "lines": [line for _, line in rows],
                "total": rows[-1][0] + 1 if rows else 0,
            }

    @staticmethod
    def _trim_output(session: Session, run_id: str) -> None:
        last = session.scalar(
            select(func.max(RunOutputRow.number)).where(RunOutputRow.run_id == run_id)
        )
        if last is not None and last >= OUTPUT_KEPT:
            session.execute(delete(RunOutputRow).where(
                RunOutputRow.run_id == run_id, RunOutputRow.number <= last - OUTPUT_KEPT
            ))

    def delete_run(self, run_id: str) -> Change:
        with self._sessions.begin() as session:
            row = self._find(session, run_id)
            change = _change(row, "deleted")
            for table in (MetricPointRow, LayerPointRow, LayerRow, FieldRow, RunItemRow,
                          RunNotesRow, RunSystemRow, RunSimulationRow, DatasetUseRow,
                          RunOutputRow, RunResumeRow):
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
            field_rows: list[dict] = []
            item_rows: list[dict] = []
            output_rows: list[dict] = []
            for event in events:
                # Clamp to now: a clock running ahead mustn't keep a dead run alive.
                time = min(event.time or now, now)
                if isinstance(event, StatusEvent):
                    if row.status != event.status or row.lost_contact:
                        row.status = event.status
                        row.status_message = event.message
                        row.ended_at = time
                        row.lost_contact = False
                        change = _change(row, event.status)
                        changes.append(change if event.notify else replace(change, notify=False))
                    if event.diverged and event.status == "crashed":
                        simulation = session.get(RunSimulationRow, run_id)
                        if simulation is not None and not simulation.info.get("diverged"):
                            simulation.info = {**simulation.info, "diverged": True}
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
                elif isinstance(event, FieldEvent):
                    field_rows.append(_field_row(run_id, event))
                    row.current_step = max(row.current_step, event.step)
                elif isinstance(event, (EvalEvent, CurveEvent)):
                    item_rows.append(_item_row(run_id, event))
                    row.current_step = max(row.current_step, event.step)
                elif isinstance(event, OutputEvent):
                    output_rows.extend(
                        {"run_id": run_id, "number": event.start + i, "line": line}
                        for i, line in enumerate(event.lines)
                    )

            _upsert(session, MetricPointRow, metric_rows, ("run_id", "name", "step"))
            _upsert(session, LayerPointRow, layer_point_rows, ("run_id", "layer", "step"))
            _upsert(session, RunItemRow, item_rows, ("run_id", "type", "name", "step"))
            if output_rows:
                _upsert(session, RunOutputRow, output_rows, ("run_id", "number"))
                self._trim_output(session, run_id)
            # One at a time: each row is up to a megabyte or so.
            for field_row in field_rows:
                _upsert(session, FieldRow, [field_row], ("run_id", "name", "step"))
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
        """Marks live runs that went quiet as crashed: a minute after their
        Slurm job's time limit if they stopped there ("Stopped by its Slurm
        time limit"), otherwise after `stale_after` ("Lost contact").

        A run can't always say so itself: Slurm signals only the job script,
        so a Python started as its child is killed without reporting."""
        now = self._clock()
        cutoff = now - stale_after
        minutes = stale_after.total_seconds() / 60
        changes = []
        with self._sessions.begin() as session:
            quiet = select(RunRow).where(RunRow.status == "live")
            lost = {row.id for row in session.scalars(quiet.where(RunRow.last_seen_at < cutoff))}
            for row in session.scalars(quiet.where(RunRow.last_seen_at < now - TIME_LIMIT_GRACE)).all():
                slurm = _slurm(session.get(RunSystemRow, row.id))
                limit = _parse_time(slurm.get("timeLimitAt"))
                if limit is not None and now > limit + TIME_LIMIT_GRACE:
                    job = f" (job {slurm['jobId']})" if slurm.get("jobId") else ""
                    message = (
                        f"Stopped by its Slurm time limit{job}: no data since. Ask for more "
                        "time (--time), or save checkpoints and continue the run in a new job. "
                        "It shows as live again if data arrives."
                    )
                elif row.id in lost:
                    message = (
                        f"Lost contact: no data for over {minutes:g} minutes. The job may have "
                        "been stopped (for example by a time limit) or lost its network "
                        "connection. It shows as live again if data arrives."
                    )
                else:
                    continue
                row.status = "crashed"
                row.lost_contact = True
                row.ended_at = row.last_seen_at
                row.status_message = message
                changes.append(_change(row, "crashed"))
        return changes

    def warn_time_limits(self) -> list[Change]:
        """A "time-limit" change, once per job, for each live run that at
        its pace so far won't finish before its Slurm job's time limit:
        while there is still time to save a checkpoint."""
        now = self._clock()
        changes = []
        with self._sessions() as session:
            live = session.execute(
                select(RunRow, RunSystemRow)
                .join(RunSystemRow, RunSystemRow.run_id == RunRow.id)
                .where(RunRow.status == "live")
            ).all()
            for row, system in live:
                slurm = _slurm(system)
                limit = _parse_time(slurm.get("timeLimitAt"))
                if limit is None or now >= limit:
                    continue
                key = (row.id, slurm["timeLimitAt"])
                if key in self._time_limit_warned:
                    continue
                remaining = self._remaining(session, row, now)
                if remaining is None or now + remaining <= limit + TIME_LIMIT_MARGIN:
                    continue
                self._time_limit_warned.add(key)
                job = f" (job {slurm['jobId']})" if slurm.get("jobId") else ""
                message = (
                    f"At this pace it needs about {format_span(remaining)} more, but its Slurm "
                    f"time limit{job} is in {format_span(limit - now)}. Save a checkpoint "
                    "before then and continue in a new job, or it will be stopped."
                )
                changes.append(Change(
                    run_id=row.id, name=row.name, event="time-limit", status=row.status,
                    message=message, current_step=row.current_step, total_steps=row.total_steps,
                ))
        return changes

    @classmethod
    def _remaining(cls, session: Session, row: RunRow, now: datetime) -> timedelta | None:
        """Time left at the pace of its latest process (steps, or a
        simulation's simulated time, since it started or resumed), like the
        app's estimate; None until the pace can be trusted."""
        elapsed = now - _aware(row.started_at)
        if elapsed < PACE_AFTER:
            return None
        resume = session.get(RunResumeRow, row.id)
        simulation = session.get(RunSimulationRow, row.id)
        t_end = simulation.info.get("tEnd") if simulation is not None else None
        if t_end:
            time = cls._sim_time(session, row.id)
            start = (resume.sim_time if resume is not None else None) or 0.0
            if time is None or time <= start:
                return None
            done, left, whole = time - start, t_end - time, t_end - start
        elif row.total_steps > 0:
            start = resume.step if resume is not None else 0
            done = row.current_step - start
            left, whole = row.total_steps - row.current_step, row.total_steps - start
            if done <= 0:
                return None
        else:
            return None
        if whole <= 0 or done / whole < PACE_AFTER_PROGRESS:
            return None
        if left <= 0:
            return timedelta(0)
        return elapsed * (left / done)

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

    # Field snapshots ------------------------------------------------------

    def fields(self, run_id: str) -> list[dict]:
        """Every logged field, with the steps it was logged at and their
        error statistics; without the data itself."""
        with self._sessions() as session:
            self._find(session, run_id)
            result = session.execute(
                select(FieldRow.name, FieldRow.step, FieldRow.meta)
                .where(FieldRow.run_id == run_id)
                .order_by(FieldRow.name, FieldRow.step)
            )
            fields: dict[str, dict] = {}
            for name, step, meta in result:
                field = fields.setdefault(name, {"name": name, "steps": []})
                # Shape, frames and the layer's place: the latest step's.
                field.update(
                    kind=meta.get("kind", "output"),
                    shape=meta["shape"],
                    frames=meta.get("frames", 1),
                    layer=meta.get("layer"),
                    position=meta.get("position"),
                )
                if meta.get("worstOf") is not None:
                    field["worstOf"] = meta["worstOf"]
                field["steps"].append({"step": step, "stats": meta.get("stats", {})})
        # Outputs by name, then layers in model order, worst samples by rank,
        # Fourier weights in model order.
        kinds = {"output": 0, "layer": 1, "worst": 2, "weights": 3}
        return sorted(fields.values(), key=lambda f: (
            kinds.get(f["kind"], 4),
            f.get("worstOf") or "",
            f["position"] if f["position"] is not None else 0,
            f["name"],
        ))

    def items(self, run_id: str, kind: str) -> list[dict]:
        """A run's evals or curves: per name, every step logged, in order."""
        with self._sessions() as session:
            self._find(session, run_id)
            result = session.execute(
                select(RunItemRow.name, RunItemRow.step, RunItemRow.data)
                .where(RunItemRow.run_id == run_id, RunItemRow.type == kind)
                .order_by(RunItemRow.name, RunItemRow.step)
            )
            items: dict[str, dict] = {}
            for name, step, data in result:
                items.setdefault(name, {"name": name, "steps": []})["steps"].append(
                    {"step": step, **data}
                )
        return list(items.values())

    def latest_metrics(self, names: Sequence[str]) -> dict:
        """For every run that logged them: each metric's latest value (by
        step) and its lowest finite value. For sweeps across runs."""
        result: dict[str, dict] = defaultdict(dict)
        with self._sessions() as session:
            rows = session.execute(
                select(MetricPointRow.run_id, MetricPointRow.name, MetricPointRow.step,
                       MetricPointRow.value, MetricPointRow.code)
                .where(MetricPointRow.name.in_(list(names)))
                .order_by(MetricPointRow.run_id, MetricPointRow.name, MetricPointRow.step)
            )
            for run_id, name, _step, value, code in rows:
                number = from_columns(value, code)
                entry = result[run_id].setdefault(name, {"latest": number, "min": None})
                entry["latest"] = number
                if number == number and abs(number) != float("inf"):
                    entry["min"] = number if entry["min"] is None else min(entry["min"], number)
        return {
            run_id: {
                name: {"latest": encode_float(e["latest"]),
                       "min": None if e["min"] is None else encode_float(e["min"])}
                for name, e in metrics.items()
            }
            for run_id, metrics in result.items()
        }

    def field_snapshot(self, run_id: str, name: str, step: int | None) -> dict:
        """One snapshot; the latest one if [step] is None."""
        with self._sessions() as session:
            self._find(session, run_id)
            query = select(FieldRow).where(FieldRow.run_id == run_id, FieldRow.name == name)
            query = (query.order_by(FieldRow.step.desc()).limit(1) if step is None
                     else query.where(FieldRow.step == step))
            row = session.scalars(query).first()
            if row is None:
                raise FieldNotFound(name if step is None else f"{name} at step {step}")
            return {"name": row.name, "step": row.step, **row.meta,
                    "prediction": row.prediction, "target": row.target}

    # Helpers --------------------------------------------------------------

    @staticmethod
    def _find(session: Session, run_id: str) -> RunRow:
        row = session.get(RunRow, run_id)
        if row is None:
            raise RunNotFound(run_id)
        return row

    @staticmethod
    def _values(session: Session, run_id: str, name: str) -> list[float]:
        """A metric's values, in step order."""
        return [
            from_columns(value, code)
            for value, code in session.execute(
                select(MetricPointRow.value, MetricPointRow.code)
                .where(MetricPointRow.run_id == run_id, MetricPointRow.name == name)
                .order_by(MetricPointRow.step)
            )
        ]

    @classmethod
    def _simulation_json(cls, session: Session, run_id: str) -> dict | None:
        """A simulation's settings, with its latest simulated time and a
        preview of its monitored value; None for a training run."""
        row = session.get(RunSimulationRow, run_id)
        if row is None:
            return None
        latest = session.execute(
            select(MetricPointRow.value, MetricPointRow.code)
            .where(MetricPointRow.run_id == run_id, MetricPointRow.name == SIM_TIME)
            .order_by(MetricPointRow.step.desc())
            .limit(1)
        ).first()
        monitor = row.info.get("monitor")
        preview = (downsample(cls._values(session, run_id, monitor), LOSS_PREVIEW_POINTS,
                              lambda v: v) if monitor else [])
        resume = session.get(RunResumeRow, run_id)
        return {
            **row.info,
            "time": None if latest is None else encode_float(from_columns(*latest)),
            # Its simulated time when its latest process took over, for its pace.
            **({"resumedAtTime": resume.sim_time}
               if resume is not None and resume.sim_time is not None else {}),
            "preview": [encode_float(v) for v in preview],
        }

    @classmethod
    def _run_json(cls, session: Session, row: RunRow) -> dict:
        losses = cls._values(session, row.id, TRAIN_LOSS)
        preview = downsample(losses, LOSS_PREVIEW_POINTS, lambda v: v)
        notes = session.get(RunNotesRow, row.id)
        system = session.get(RunSystemRow, row.id)
        resume = session.get(RunResumeRow, row.id)
        return {
            "id": row.id,
            "name": row.name,
            "project": row.project,
            "host": row.host,
            "status": row.status,
            "startedAt": iso(row.started_at),
            "endedAt": iso(row.ended_at),
            "currentStep": row.current_step,
            # Where its latest process took over (a continued run), for its pace.
            "resumedAtStep": resume.step if resume else 0,
            "totalSteps": row.total_steps,
            "currentEpoch": row.current_epoch,
            "totalEpochs": row.total_epochs,
            "hyperparameters": row.hyperparameters,
            "architecture": row.architecture,
            "lossPreview": [encode_float(v) for v in preview],
            "statusMessage": row.status_message,
            "tags": list(notes.tags) if notes else [],
            "notes": notes.notes if notes else "",
            "system": system.info if system else None,
            "simulation": cls._simulation_json(session, row.id),
            "datasets": list(session.scalars(
                select(DatasetUseRow.dataset_id).where(DatasetUseRow.run_id == row.id)
                .order_by(DatasetUseRow.dataset_id)
            )),
        }

    # Datasets -------------------------------------------------------------

    def put_dataset(self, dataset_id: str, body: DatasetIn) -> dict:
        """Registers a dataset, or updates its description."""
        now = self._clock()
        # NaN and infinity (a variable's range) as strings, as JSON allows.
        info = _encode_floats(body.model_dump(exclude={"previews"}, exclude_none=True))
        previews = [_encode_floats(p.model_dump()) for p in body.previews]
        with self._sessions.begin() as session:
            row = session.get(DatasetRow, dataset_id)
            if row is None:
                row = DatasetRow(id=dataset_id, created_at=now)
                session.add(row)
            row.name, row.info, row.previews, row.updated_at = body.name, info, previews, now
            session.flush()
            return self._dataset_json(session, row, full=True)

    def list_datasets(self) -> list[dict]:
        with self._sessions() as session:
            rows = session.scalars(select(DatasetRow).order_by(DatasetRow.updated_at.desc()))
            return [self._dataset_json(session, row, full=False) for row in rows]

    def get_dataset(self, dataset_id: str) -> dict:
        with self._sessions() as session:
            row = session.get(DatasetRow, dataset_id)
            if row is None:
                raise DatasetNotFound(dataset_id)
            return self._dataset_json(session, row, full=True)

    def delete_dataset(self, dataset_id: str) -> None:
        """Forgets a dataset (the files aren't touched); runs keep naming it."""
        with self._sessions.begin() as session:
            row = session.get(DatasetRow, dataset_id)
            if row is None:
                raise DatasetNotFound(dataset_id)
            session.delete(row)

    @staticmethod
    def _run_summary(session: Session, run_id: str) -> dict | None:
        row = session.get(RunRow, run_id)
        if row is None:
            return None
        return {
            "id": row.id, "name": row.name, "project": row.project, "status": row.status,
            "simulation": session.get(RunSimulationRow, row.id) is not None,
        }

    @classmethod
    def _dataset_json(cls, session: Session, row: DatasetRow, *, full: bool) -> dict:
        """As the app reads it: the description, who made it, who used it;
        [full] adds the previews."""
        users = [
            summary for run_id in session.scalars(
                select(DatasetUseRow.run_id).where(DatasetUseRow.dataset_id == row.id)
            )
            if (summary := cls._run_summary(session, run_id)) is not None
        ]
        users.sort(key=lambda r: r["name"])
        made_by = row.info.get("madeBy")
        result = {
            **row.info,
            "id": row.id,
            "createdAt": iso(row.created_at),
            "updatedAt": iso(row.updated_at),
            "madeBy": None if made_by is None else (
                cls._run_summary(session, made_by) or {"id": made_by, "name": made_by}
            ),
            "usedBy": users,
        }
        if full:
            result["previews"] = row.previews
        return result
