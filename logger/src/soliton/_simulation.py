"""Simulations: a PDE solve (or any computation that steps through time or
iterates to convergence), monitored like a training run.

A simulation is a run with a `simulation` entry in its description, so the
server and the app reuse everything runs have: live status, crash detection,
the machine and its use, fields, cost. What differs: progress is simulated
time (`t_end`) or iterations (`max_iterations`), values are logged against
the simulated time `t`, and a NaN or infinity ends it as diverged.
"""

from __future__ import annotations

import math
from typing import Any, Iterable, Mapping, Optional, Sequence

from ._fields import DEFAULT_POINTS, _numpy, to_array
from ._run import Run, _field_name
from ._util import to_float

# The simulated time and time step, logged as metrics with these names.
TIME = "sim/t"
TIME_STEP = "sim/dt"


class Diverged(RuntimeError):
    """Raised by `Simulation.log` when a value turns NaN or infinite, if the
    simulation was started with `stop_on_divergence=True`."""


class Simulation(Run):
    """A simulation being monitored. Start one with `soliton.simulate()`.

    Log values with `log({...}, t=t, dt=dt)`, fields with `log_field(...)`
    (or `log_rollout(...)` for several times at once), and call `finish()`
    at the end, or use it as a context manager.
    """

    def __init__(
        self,
        name: str,
        *,
        project: str = "",
        setup: Optional[Mapping[str, Any]] = None,
        t_end: Optional[float] = None,
        max_iterations: int = 0,
        monitor: Optional[str] = None,
        cfl_limit: Optional[float] = None,
        stop_on_divergence: bool = False,
        tags: Optional[Iterable[str]] = None,
        notes: str = "",
        system_metrics: bool = True,
        system_interval: float = 15,
        capture_output: Optional[bool] = None,
        price_per_hour: Optional[float] = None,
        host: Optional[str] = None,
        id: Optional[str] = None,
        server: Optional[str] = None,
        token: Optional[str] = None,
        mode: Optional[str] = None,
        dir: Optional[str] = None,
    ) -> None:
        info: dict = {}
        if t_end is not None:
            info["tEnd"] = _positive(t_end, "t_end")
        if cfl_limit is not None:
            info["cflLimit"] = _positive(cfl_limit, "cfl_limit")
        if monitor is not None:
            info["monitor"] = str(monitor)[:200]
        if int(max_iterations) < 0:
            raise ValueError("max_iterations must be 0 or more")
        self._stop_on_divergence = bool(stop_on_divergence)
        self._t: Optional[float] = None
        super().__init__(
            name,
            project=project,
            config=setup,
            tags=tags,
            notes=notes,
            system_metrics=system_metrics,
            system_interval=system_interval,
            capture_output=capture_output,
            price_per_hour=price_per_hour,
            total_steps=int(max_iterations),
            host=host,
            id=id,
            server=server,
            token=token,
            mode=mode,
            dir=dir,
            _simulation=info,
        )

    def log(self, values: Optional[Mapping[str, Any]] = None, *, t: Any = None,
            dt: Any = None, step: Optional[int] = None) -> None:
        """Logs [values] (e.g. {"energy": E, "cfl": c}) at simulated time
        [t] with time step [dt], at [step] (default: the previous step + 1;
        for a steady solve, the iteration).

        The app charts every value against t (or against the iteration
        when no t is logged). A value named like `cfl_limit`'s quantity
        ("cfl") is drawn with its limit; names containing "residual" or
        "error" on a log scale. The first NaN or infinity ends the
        simulation as diverged (see `stop_on_divergence`).
        """
        if self._finished:
            return
        values = dict(values or {})
        for key, value in ((TIME, t), (TIME_STEP, dt)):
            if value is not None:
                values[key] = value
        bad = None
        for key, value in values.items():
            number = to_float(value)
            if number is not None and not math.isfinite(number):
                bad = (key, number)
                break
        if t is not None and math.isfinite(to_float(t) or 0.0):
            self._t = to_float(t)
        super().log(values, step=step)
        if bad is not None:
            key, number = bad
            self._diverge(f"{_label(key)} is {_text(number)}")

    def log_field(self, name: str, field: Any, step: Optional[int] = None, *,
                  max_size: Optional[int] = None, max_points: int = DEFAULT_POINTS,
                  extent: Optional[Sequence[Any]] = None,
                  axes: Optional[Sequence[str]] = None) -> None:
        """Logs a snapshot of a field, e.g. the vorticity, at [step]
        (default: the latest step logged, so log `t` first). 1D, 2D or 3D;
        see `Run.log_field` for the sizes and [extent] and [axes]. A field
        with NaN or infinity in it ends the simulation as diverged."""
        if self._finished:
            return
        super().log_field(name, field, step=step, max_size=max_size, max_points=max_points,
                          extent=extent, axes=axes)
        np = _numpy()
        if not bool(np.isfinite(to_array(field, "field")).all()):
            self._diverge(f"{_field_name(name)} has NaN or infinite values")

    def _diverge(self, reason: str) -> None:
        where = f"t = {self._t:g}" if self._t is not None else f"step {max(self._last_step, 0):,}"
        message = f"Diverged at {where}: {reason}"
        self._status_extra = {"diverged": True}
        self.finish("crashed", message)
        if self._stop_on_divergence:
            raise Diverged(message)


def _positive(value: Any, name: str) -> float:
    number = to_float(value)
    if number is None or not math.isfinite(number) or number <= 0:
        raise ValueError(f"{name} must be a positive number, not {value!r}")
    return number


def _label(key: str) -> str:
    return {TIME: "t", TIME_STEP: "dt"}.get(key, key)


def _text(number: float) -> str:
    return "NaN" if math.isnan(number) else ("infinite" if number > 0 else "-infinite")
