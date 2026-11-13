"""Non-finite numbers and downsampling.

Diverging runs log NaN and infinity, which JSON has no syntax for. On the
wire they travel as the strings "NaN", "Infinity" and "-Infinity" (the app
and the logger use the same convention). SQLite turns NaN into NULL, so in
the database a non-finite value is stored as NULL plus a code.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from typing import TypeVar, Union

JsonNumber = Union[float, str]

_SPECIAL = {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}

# Storage codes for non-finite values (see to_columns).
FINITE, NAN, POS_INF, NEG_INF = 0, 1, 2, 3


def decode_float(value: object) -> float:
    """A JSON number, or one of the strings above, as a float."""
    if isinstance(value, bool):
        raise ValueError(f"not a number: {value!r}")
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str) and value in _SPECIAL:
        return _SPECIAL[value]
    raise ValueError(f"not a number: {value!r}")


def encode_float(value: float) -> JsonNumber:
    """A float as JSON: finite values as numbers, the rest as strings."""
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Infinity" if value > 0 else "-Infinity"
    return value


def to_columns(value: float) -> tuple[float | None, int]:
    """(value, code) database columns for a float."""
    if math.isfinite(value):
        return value, FINITE
    if math.isnan(value):
        return None, NAN
    return None, POS_INF if value > 0 else NEG_INF


def from_columns(value: float | None, code: int) -> float:
    if code == FINITE and value is not None:
        return value
    if code == POS_INF:
        return math.inf
    if code == NEG_INF:
        return -math.inf
    return math.nan


T = TypeVar("T")


def downsample(points: Sequence[T], max_points: int, value_of) -> list[T]:
    """At most [max_points] points that keep the shape of a curve.

    Same method as the app's `MetricSeries.downsampled`: the points between
    the first and the last are split into buckets, and each bucket keeps its
    lowest and highest value, so spikes survive. NaN counts as the highest
    value, so the step where a run blew up survives too.
    """
    if len(points) <= max_points:
        return list(points)
    if max_points < 4:
        return ([points[0]] if max_points >= 2 else []) + [points[-1]]

    def rank(i: int) -> float:
        v = value_of(points[i])
        return math.inf if math.isnan(v) else v

    inner = len(points) - 2
    buckets = (max_points - 2) // 2
    sampled = [points[0]]
    for b in range(buckets):
        start = 1 + b * inner // buckets
        end = 1 + (b + 1) * inner // buckets
        if start >= end:
            continue
        low = high = start
        for i in range(start + 1, end):
            r = rank(i)
            if r < rank(low):
                low = i
            if r > rank(high):
                high = i
        first, second = sorted((low, high))
        if first != second:
            sampled.append(points[first])
        sampled.append(points[second])
    sampled.append(points[-1])
    return sampled
