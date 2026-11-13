"""Request bodies, validated. Field names match the app's JSON (camelCase)."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Annotated, Literal, Optional, Union

from pydantic import AfterValidator, BaseModel, BeforeValidator, ConfigDict, Field

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
