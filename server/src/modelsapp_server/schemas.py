"""Request bodies, validated. Field names match the app's JSON (camelCase)."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Annotated, Literal, Optional, Union

from pydantic import AfterValidator, BaseModel, BeforeValidator, ConfigDict, Field, StringConstraints

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


class StatusEvent(_In):
    type: Literal["status"]
    status: Literal["finished", "crashed"]
    message: Optional[str] = Field(default=None, max_length=2000)
    time: Time = None


Event = Annotated[Union[MetricsEvent, LayersEvent, StatusEvent], Field(discriminator="type")]


class EventsIn(_In):
    events: list[Event] = Field(max_length=5000)
