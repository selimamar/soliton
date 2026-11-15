"""Training health: notices, from the values a run logs, when training has
gone wrong, so the app can say so while there is still time to act.

Three problems, each reported once per process (job):

- "nan": a loss turned NaN or infinite.
- "divergence": a training loss climbed back up: to 10 times its lowest
  (smoothed) value and to at least 5% of where it started (so the noise of
  a loss that is already tiny doesn't count), or back to where it started
  after having halved.
- "gradient": a gradient norm (a name ending in "grad_norm") stayed at
  more than 10 times its usual size, or NaN or infinite, for 5 logs in a
  row. One-off spikes (clipped, or skipped by a gradient scaler) don't count.

Losses are names containing "loss"; validation losses (names starting with
val, valid, test or eval) only count for "nan", since they rising can be
overfitting rather than a broken run. Off with SOLITON_HEALTH=0.
"""

from __future__ import annotations

import math
import os
import statistics
from collections import deque
from typing import Mapping, Optional

WINDOW = 9  # Values in the smoothed (median) loss.
MIN_VALUES = 30  # Before a loss can count as diverging.
RISE = 10.0  # Times its lowest smoothed value,
SIGNIFICANT = 0.05  # and at least this share of where it started.
GRAD_HISTORY = 50  # Values a gradient norm is compared with.
GRAD_MIN_HISTORY = 20
GRAD_FACTOR = 10.0
GRAD_IN_A_ROW = 5

_VALIDATION = ("val", "valid", "validation", "test", "eval")


class Diverged(RuntimeError):
    """Raised when a run (started with `stop_on_divergence=True`) diverges:
    for a training run, a loss turned NaN or infinite; for a simulation, any
    value or field did."""


def enabled() -> bool:
    return os.environ.get("SOLITON_HEALTH", "1").strip().lower() not in ("0", "false", "no", "off")


def is_loss(name: str) -> bool:
    return "loss" in name.lower()


def is_training_loss(name: str) -> bool:
    if not is_loss(name):
        return False
    first = name.lower().replace("-", "_").split("/")[0].split("_")[0]
    return first not in _VALIDATION


def is_grad_norm(name: str) -> bool:
    last = name.lower().split("/")[-1].replace("-", "_")
    return last.endswith("grad_norm") or last.endswith("gradnorm")


class _Loss:
    def __init__(self) -> None:
        self.count = 0
        self.first: list = []
        self.recent: deque = deque(maxlen=WINDOW)
        self.lowest: Optional[float] = None

    def add(self, value: float) -> Optional[tuple]:
        """Returns (smoothed, lowest) once it has diverged."""
        self.count += 1
        if len(self.first) < WINDOW:
            self.first.append(value)
        self.recent.append(value)
        if len(self.recent) < WINDOW:
            return None
        smoothed = statistics.median(self.recent)
        if self.lowest is None or smoothed < self.lowest:
            self.lowest = smoothed
        if self.count < MIN_VALUES:
            return None
        start = statistics.median(self.first)
        lowest = self.lowest
        if start <= 0 or lowest <= 0:
            return None  # A loss that can be negative: no ratio to judge by.
        risen = smoothed >= RISE * lowest and smoothed >= SIGNIFICANT * start
        if risen or (lowest <= start / 2 and smoothed >= start):
            return smoothed, lowest
        return None


class _GradNorm:
    def __init__(self) -> None:
        self.history: deque = deque(maxlen=GRAD_HISTORY)
        self.in_a_row = 0
        self.since: Optional[int] = None

    def add(self, value: float, step: int) -> Optional[float]:
        """Returns the usual size once it has blown up (nan for non-finite)."""
        usual = statistics.median(self.history) if len(self.history) >= GRAD_MIN_HISTORY else None
        bad = not math.isfinite(value) or (usual is not None and usual > 0
                                           and value > GRAD_FACTOR * usual)
        if not bad:
            self.history.append(value)
            self.in_a_row, self.since = 0, None
            return None
        self.in_a_row += 1
        if self.since is None:
            self.since = step
        if self.in_a_row >= GRAD_IN_A_ROW:
            return usual if usual is not None else math.nan
        return None


class HealthCheck:
    """Fed every logged value; returns the problems it newly sees."""

    def __init__(self) -> None:
        self.reported: set = set()
        self.losses: dict = {}
        self.grads: dict = {}

    def check(self, values: Mapping[str, float], step: int) -> list:
        """[(kind, message)], each kind at most once."""
        problems = []
        for name, value in values.items():
            if is_loss(name):
                if not math.isfinite(value):
                    problems.append(("nan", f"{name} is {_text(value)} at step {step:,}"))
                    continue
                if is_training_loss(name):
                    diverged = self.losses.setdefault(name, _Loss()).add(value)
                    if diverged is not None:
                        smoothed, lowest = diverged
                        problems.append(("divergence", f"{name} climbed back up to {smoothed:.3g} "
                                                       f"at step {step:,}, from a low of {lowest:.3g}"))
            elif is_grad_norm(name):
                tracker = self.grads.setdefault(name, _GradNorm())
                usual = tracker.add(value, step)
                if usual is None:
                    continue
                if math.isnan(usual) or not math.isfinite(value):
                    message = (f"{name} has been NaN or infinite for {GRAD_IN_A_ROW} logs in a "
                               f"row, since step {tracker.since:,}")
                else:
                    message = (f"{name} blew up: {value:.3g} at step {step:,}, more than "
                               f"{GRAD_FACTOR:g} times its usual {usual:.3g} since step {tracker.since:,}")
                problems.append(("gradient", message))
        new = []
        for kind, message in problems:
            if kind not in self.reported:
                self.reported.add(kind)
                new.append((kind, message))
        return new


def _text(number: float) -> str:
    return "NaN" if math.isnan(number) else ("infinite" if number > 0 else "-infinite")
