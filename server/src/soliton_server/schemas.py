"""Request bodies, validated. Field names match the app's JSON (camelCase)."""

from __future__ import annotations

import base64
import binascii
import json
import math
from datetime import datetime, timezone
from typing import Annotated, Literal, Optional, Union

from pydantic import (
    AfterValidator,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    StringConstraints,
    model_validator,
)

from .floats import decode_float


def _aware(value: Optional[datetime]) -> Optional[datetime]:
    """Times without a timezone are taken as UTC."""
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


# A number that may also be "NaN", "Infinity" or "-Infinity".
JsonFloat = Annotated[float, BeforeValidator(decode_float)]
Time = Annotated[Optional[datetime], AfterValidator(_aware)]
Name = Annotated[str, Field(min_length=1, max_length=200)]

RUN_ID_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"


def _distinct(tags: list[str]) -> list[str]:
    """Each tag once (ignoring case), in the order given."""
    seen: set[str] = set()
    kept = []
    for tag in tags:
        if tag.casefold() not in seen:
            seen.add(tag.casefold())
            kept.append(tag)
    return kept


Tag = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]
Tags = Annotated[list[Tag], Field(max_length=20), AfterValidator(_distinct)]
Notes = Annotated[str, Field(max_length=10_000)]


def _small(value: Optional[dict]) -> Optional[dict]:
    if value is not None and len(json.dumps(value)) > 20_000:
        raise ValueError("at most 20,000 characters of JSON")
    return value


SystemInfo = Annotated[Optional[dict], AfterValidator(_small)]


class _In(BaseModel):
    model_config = ConfigDict(extra="ignore")


class SimulationIn(_In):
    """What makes a run a simulation (see the logger's _simulation.py)."""

    # The simulated time it runs to (progress, time left).
    tEnd: Optional[Annotated[float, Field(gt=0, allow_inf_nan=False)]] = None
    # Drawn on the chart of a value named "cfl".
    cflLimit: Optional[Annotated[float, Field(gt=0, allow_inf_nan=False)]] = None
    # The value drawn on its card in the list.
    monitor: Optional[Name] = None


DatasetId = Annotated[str, StringConstraints(pattern=RUN_ID_PATTERN)]


class RunIn(_In):
    """A run's description, sent by the logger when the run starts."""

    name: Name
    project: str = Field(default="", max_length=200)
    host: str = Field(default="", max_length=200)
    startedAt: Time = None
    totalSteps: int = Field(default=0, ge=0)
    totalEpochs: int = Field(default=0, ge=0)
    hyperparameters: dict[str, str] = Field(default_factory=dict)
    architecture: Optional[dict] = None
    # Only used when the run is created: after that, they're edited in the app.
    tags: Tags = Field(default_factory=list)
    notes: Notes = ""
    # The machine, GPUs, software and Slurm job (see the logger's _system.py).
    system: SystemInfo = None
    # Set for a simulation (e.g. a PDE solve) rather than a training run.
    simulation: Optional[SimulationIn] = None
    # The datasets it trains or is evaluated on (their ids); None leaves
    # them as they are (an older logger).
    datasets: Optional[list[DatasetId]] = Field(default=None, max_length=20)


class RunNotesIn(_In):
    """An edit from the app: what is left out stays as it is."""

    tags: Optional[Tags] = None
    notes: Optional[Notes] = None


class MetricsEvent(_In):
    type: Literal["metrics"]
    step: int = Field(ge=0)
    epoch: Optional[int] = Field(default=None, ge=0)
    time: Time = None
    values: dict[Name, JsonFloat] = Field(max_length=1000)


class HistogramIn(_In):
    min: JsonFloat
    max: JsonFloat
    counts: list[int] = Field(max_length=1000)
    zeroCount: int = Field(default=0, ge=0)


class LayerIn(_In):
    layerName: Name
    activationMean: JsonFloat
    activationStd: JsonFloat
    # None for a layer without gradients (e.g. frozen).
    gradNorm: Optional[JsonFloat] = None
    deadFraction: JsonFloat
    activationHistogram: HistogramIn


class LayersEvent(_In):
    type: Literal["layers"]
    step: int = Field(ge=0)
    time: Time = None
    layers: list[LayerIn] = Field(max_length=1000)


FloatList = Annotated[list[JsonFloat], Field(max_length=1000)]


class SpectrumIn(_In):
    k: FloatList
    prediction: FloatList
    target: Optional[FloatList] = None


FIELD_MAX_SIZE = 512  # Points per axis.
FIELD_MAX_POINTS = 1 << 24  # Values per array, all frames together (~43 MB of JSON).
FIELD_MAX_FRAMES = 256
FieldStat = Annotated[str, StringConstraints(max_length=40)]
Axis = Annotated[int, Field(ge=1, le=FIELD_MAX_SIZE)]


class FieldEvent(_In):
    """A snapshot of a predicted field and its target (see the logger's
    _fields.py): base64 16-bit codes between [min] and [max], frame after
    frame, each frame row by row. [kind] "layer" is a layer's output inside
    the model (named "layers/<layer>"), with no target."""

    type: Literal["field"]
    step: int = Field(ge=0)
    epoch: Optional[int] = Field(default=None, ge=0)
    time: Time = None
    name: Name
    # "worst": one of a validation set's worst samples ("worst/<name>/<rank>");
    # "weights": a layer's learned Fourier weights ("weights/<param>").
    kind: Literal["output", "layer", "worst", "weights"] = "output"
    shape: list[Axis] = Field(min_length=1, max_length=3)
    originalShape: Optional[list[Annotated[int, Field(ge=1)]]] = Field(default=None, max_length=3)
    frames: int = Field(default=1, ge=1, le=FIELD_MAX_FRAMES)
    times: Optional[list[JsonFloat]] = Field(default=None, max_length=FIELD_MAX_FRAMES)
    min: JsonFloat
    max: JsonFloat
    prediction: str = Field(max_length=FIELD_MAX_POINTS * 3)
    target: Optional[str] = Field(default=None, max_length=FIELD_MAX_POINTS * 3)
    stats: dict[FieldStat, JsonFloat] = Field(default_factory=dict, max_length=20)
    # Per frame of a rollout, e.g. {"relL2": [0.01, 0.02, ...]}.
    frameStats: dict[FieldStat, list[JsonFloat]] = Field(default_factory=dict, max_length=10)
    layer: Optional[str] = Field(default=None, max_length=200)
    position: Optional[int] = Field(default=None, ge=0)  # The layer's order in the model.
    reduction: Optional[str] = Field(default=None, max_length=100)  # E.g. "mean of 32 channels".
    layerShape: Optional[list[Annotated[int, Field(ge=1)]]] = Field(default=None, max_length=8)
    # A worst sample: its index in the validation set, and which field it is of.
    sample: Optional[int] = Field(default=None, ge=0)
    worstOf: Optional[str] = Field(default=None, max_length=200)
    # The domain: (start, end) per axis, and the axes' names.
    extent: Optional[list[Annotated[list[JsonFloat], Field(min_length=2, max_length=2)]]] = Field(
        default=None, max_length=3
    )
    axes: Optional[list[Annotated[str, StringConstraints(max_length=20)]]] = Field(
        default=None, max_length=3
    )
    # Radial energy spectrum of the (last frame of the) prediction and target.
    spectrum: Optional[SpectrumIn] = None

    @model_validator(mode="after")
    def _sizes_match(self) -> "FieldEvent":
        points = self.frames * math.prod(self.shape)
        if points > FIELD_MAX_POINTS:
            raise ValueError(f"at most {FIELD_MAX_POINTS} values per snapshot, not {points}")
        if self.times is not None and len(self.times) != self.frames:
            raise ValueError(f"{len(self.times)} times for {self.frames} frames")
        for key, values in self.frameStats.items():
            if len(values) != self.frames:
                raise ValueError(f"frameStats.{key} has {len(values)} values for {self.frames} frames")
        if self.kind == "layer" and self.layer is None:
            raise ValueError("a layer snapshot needs its layer")
        for label, values in (("extent", self.extent), ("axes", self.axes)):
            if values is not None and len(values) != len(self.shape):
                raise ValueError(f"{label} needs one entry per axis ({len(self.shape)})")
        for label, data in (("prediction", self.prediction), ("target", self.target)):
            if data is None:
                continue
            try:
                size = len(base64.b64decode(data, validate=True))
            except (binascii.Error, ValueError):
                raise ValueError(f"{label} is not base64") from None
            if size != 2 * points:
                raise ValueError(
                    f"{label} has {size} bytes, but {self.frames} frame(s) of shape "
                    f"{self.shape} need {2 * points}"
                )
        return self


class HistogramOut(_In):
    edges: FloatList
    counts: list[Annotated[int, Field(ge=0)]] = Field(max_length=1000)


class WorstSample(_In):
    rank: int = Field(ge=1)
    sample: int = Field(ge=0)
    relL2: JsonFloat


class EvalEvent(_In):
    """A whole validation set: the error of every sample, summarized."""

    type: Literal["eval"]
    step: int = Field(ge=0)
    epoch: Optional[int] = Field(default=None, ge=0)
    time: Time = None
    name: Name
    count: int = Field(ge=1)
    stats: dict[FieldStat, JsonFloat] = Field(default_factory=dict, max_length=20)
    histogram: Optional[HistogramOut] = None
    worst: list[WorstSample] = Field(default_factory=list, max_length=20)


class CurveEvent(_In):
    """A curve measured at one step: e.g. error against resolution."""

    type: Literal["curve"]
    step: int = Field(ge=0)
    epoch: Optional[int] = Field(default=None, ge=0)
    time: Time = None
    name: Name
    x: FloatList
    y: FloatList
    xLabel: str = Field(default="", max_length=60)
    yLabel: str = Field(default="", max_length=60)
    trainRange: Optional[Annotated[list[JsonFloat], Field(min_length=2, max_length=2)]] = None

    @model_validator(mode="after")
    def _same_length(self) -> "CurveEvent":
        if len(self.x) != len(self.y) or not self.x:
            raise ValueError("x and y need the same, non-zero number of values")
        return self


PREVIEW_MAX_SIZE = 96  # Points per axis of a dataset's sample preview.
Label = Annotated[str, StringConstraints(max_length=200)]


class DatasetVariableIn(_In):
    """A variable in a dataset, e.g. the vorticity "w", with its range."""

    name: Name
    description: Label = ""
    unit: Annotated[str, StringConstraints(max_length=40)] = ""
    shape: Optional[list[Annotated[int, Field(ge=0)]]] = Field(default=None, max_length=8)
    dtype: Annotated[str, StringConstraints(max_length=40)] = ""
    min: Optional[JsonFloat] = None
    max: Optional[JsonFloat] = None
    mean: Optional[JsonFloat] = None
    std: Optional[JsonFloat] = None


class DatasetPreviewIn(_In):
    """One sample, small: a 1D or 2D array of 16-bit codes between [min]
    and [max], as field snapshots are sent (see FieldEvent)."""

    name: Name
    shape: list[Annotated[int, Field(ge=1, le=PREVIEW_MAX_SIZE)]] = Field(min_length=1, max_length=2)
    min: JsonFloat
    max: JsonFloat
    data: str = Field(max_length=PREVIEW_MAX_SIZE * PREVIEW_MAX_SIZE * 3)

    @model_validator(mode="after")
    def _size_matches(self) -> "DatasetPreviewIn":
        try:
            size = len(base64.b64decode(self.data, validate=True))
        except (binascii.Error, ValueError):
            raise ValueError("data is not base64") from None
        if size != 2 * math.prod(self.shape):
            raise ValueError(f"data has {size} bytes, but shape {self.shape} needs "
                             f"{2 * math.prod(self.shape)}")
        return self


class DatasetIn(_In):
    """What a dataset is and where it lives (the data itself stays where
    it is): sent by the logger's register_dataset or `soliton data`."""

    name: Name
    version: Annotated[str, StringConstraints(max_length=60)] = ""
    description: Annotated[str, StringConstraints(max_length=2000)] = ""
    samples: Optional[int] = Field(default=None, ge=0)
    # E.g. {"train": 8000, "val": 1000, "test": 1000}.
    splits: dict[Annotated[str, StringConstraints(min_length=1, max_length=40)],
                 Annotated[int, Field(ge=0)]] = Field(default_factory=dict, max_length=10)
    sampleShape: Optional[list[Annotated[int, Field(ge=0)]]] = Field(default=None, max_length=8)
    sizeBytes: Optional[int] = Field(default=None, ge=0)
    files: Optional[int] = Field(default=None, ge=0)
    format: Annotated[str, StringConstraints(max_length=40)] = ""
    # Where it is, e.g. "/scratch/users/me/ns2d/v3.h5", on [host] ("Sherlock").
    location: Annotated[str, StringConstraints(max_length=1000)] = ""
    host: Label = ""
    # How it was obtained, e.g. "Simulated", "Experiment", "FNO benchmark".
    source: Label = ""
    # Changes when the files do (their names, sizes and dates).
    fingerprint: Annotated[str, StringConstraints(max_length=100)] = ""
    # The machine it was made on, as a run's system (see _system.py).
    system: SystemInfo = None
    # The run or simulation that made it.
    madeBy: Optional[DatasetId] = None
    variables: list[DatasetVariableIn] = Field(default_factory=list, max_length=50)
    previews: list[DatasetPreviewIn] = Field(default_factory=list, max_length=8)


class StatusEvent(_In):
    type: Literal["status"]
    status: Literal["finished", "crashed"]
    message: Optional[str] = Field(default=None, max_length=2000)
    time: Time = None
    # A simulation that crashed because a value turned NaN or infinite.
    diverged: bool = False


OUTPUT_KEPT = 1000  # Lines of a run's output the server keeps (the latest).
OutputLine = Annotated[str, StringConstraints(max_length=2000)]


class OutputEvent(_In):
    """Lines the script printed, numbered from [start] in the whole output,
    so a batch sent twice replaces itself."""

    type: Literal["output"]
    start: int = Field(ge=0)
    time: Time = None
    lines: list[OutputLine] = Field(max_length=OUTPUT_KEPT)


Event = Annotated[
    Union[MetricsEvent, LayersEvent, FieldEvent, EvalEvent, CurveEvent, StatusEvent, OutputEvent],
    Field(discriminator="type"),
]


class EventsIn(_In):
    events: list[Event] = Field(max_length=5000)
