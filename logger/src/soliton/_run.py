"""A training run: what `soliton.init()` returns."""

from __future__ import annotations

import atexit
import math
import os
import signal
import sys
import threading
import time
import traceback as tracebacks
import warnings
import weakref
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Optional, Sequence

from ._fields import (
    DEFAULT_POINTS,
    capture,
    curve_event,
    eval_events,
    field_event,
    fourier_weight_events,
    layer_event,
)
from ._datasets import Dataset
from ._output import OutputCapture
from ._datasets import describe as describe_dataset
from ._datasets import upload as upload_dataset
from ._system import SystemMonitor, framework_versions, system_info
from ._upload import ApiClient, RunFiles, Uploader
from ._util import (
    RUN_ID,
    count_samples,
    describe_loss,
    detect_host,
    encode_float,
    encode_floats,
    flatten_config,
    new_run_id,
    to_float,
    utc_now_iso,
)
from ._watch import LayerFilter, Watcher, architecture

MODES = ("online", "offline", "disabled")


def _say(message: str) -> None:
    print(f"soliton: {message}", file=sys.stderr, flush=True)


class Run:
    """One training run. Create it with `soliton.init()`.

    Use it as a context manager, or call `finish()` at the end. If the script
    dies with an exception, the run is marked as crashed with that error; if
    it simply ends, as finished.
    """

    def __init__(
        self,
        name: str,
        *,
        project: str = "",
        config: Optional[Mapping[str, Any]] = None,
        train_samples: Any = None,
        val_samples: Any = None,
        loss: Any = None,
        pde: Optional[Mapping[str, Any]] = None,
        datasets: Optional[Iterable[Any]] = None,
        tags: Optional[Iterable[str]] = None,
        notes: str = "",
        system_metrics: bool = True,
        system_interval: float = 15,
        capture_output: Optional[bool] = None,
        price_per_hour: Optional[float] = None,
        total_steps: int = 0,
        total_epochs: int = 0,
        host: Optional[str] = None,
        id: Optional[str] = None,
        server: Optional[str] = None,
        token: Optional[str] = None,
        mode: Optional[str] = None,
        dir: Optional[str] = None,
        _simulation: Optional[dict] = None,
    ) -> None:
        server = server or os.environ.get("SOLITON_SERVER")
        token = token or os.environ.get("SOLITON_TOKEN")
        mode = mode or os.environ.get("SOLITON_MODE") or ("online" if server else "offline")
        if mode not in MODES:
            raise ValueError(f"mode must be one of {', '.join(MODES)}, not {mode!r}")
        if mode == "online" and not (server and token):
            raise ValueError(
                "online mode needs a server and a token: pass server=... and token=..., or set "
                "SOLITON_SERVER and SOLITON_TOKEN (or use mode='offline')"
            )
        price = _price_per_hour(price_per_hour)
        run_id = id or new_run_id(name)
        if not RUN_ID.match(run_id):
            raise ValueError(f"invalid run id {run_id!r}: letters, digits, '.', '_' and '-' only")

        self.id = run_id
        self.name = name
        self.mode = mode
        self.directory = Path(dir or os.environ.get("SOLITON_DIR") or "soliton-runs") / run_id
        self._description = {
            "type": "run",
            "id": run_id,
            "name": name,
            "project": project,
            "host": host or detect_host(),
            "startedAt": utc_now_iso(),
            "totalSteps": int(total_steps),
            "totalEpochs": int(total_epochs),
            "hyperparameters": _hyperparameters(config, train_samples, val_samples, loss, pde),
            "architecture": None,
            "tags": _clean_tags(tags),
            "notes": str(notes or "")[:10_000],
            "system": _system_info(price) if mode != "disabled" else None,
        }
        if _simulation is not None:
            # What makes it a simulation (see _simulation.py).
            self._description["simulation"] = _simulation
        self._server, self._token = server, token
        if datasets is not None:
            self._description["datasets"] = [
                self._dataset_id(d, mode, dir) for d in datasets
            ][:20]
        # Added to the final status record, e.g. that a simulation diverged.
        self._status_extra: dict = {}
        self._files = RunFiles(self.directory)
        self._lock = threading.RLock()
        self._last_step = -1
        self._epoch: Optional[int] = None
        self._watcher: Optional[Watcher] = None
        self._warned: set = set()
        self._finished = mode == "disabled"
        self._uploader: Optional[Uploader] = None
        self._monitor: Optional[SystemMonitor] = None
        self._output: Optional[OutputCapture] = None
        if self._finished:
            return
        if system_interval < 1:
            raise ValueError("system_interval must be at least 1 second")

        self._files.append(self._description)
        if mode == "online":
            self._uploader = Uploader(self._files, ApiClient(server, token), _say)
            self._uploader.start()
        else:
            _say(f"saving run {run_id} to {self.directory} (offline); upload it with "
                 "`soliton sync`")
        if system_metrics:
            self._monitor = SystemMonitor(self._log_system, interval=system_interval)
            self._monitor.start()
        if _capture_output(capture_output):
            self._output = OutputCapture(self._log_output)
            self._output.start()
        _register(self)

    # Datasets -------------------------------------------------------------

    def _dataset_id(self, dataset: Any, mode: str, directory: Optional[str]) -> str:
        """A dataset's id: given, of a registered Dataset, or registered now
        from a path."""
        if isinstance(dataset, Dataset):
            return dataset.id
        if isinstance(dataset, (str, os.PathLike)) and Path(dataset).expanduser().exists():
            registered = describe_dataset(dataset)
            if mode != "disabled":
                upload_dataset(registered, self._server if mode == "online" else None,
                               self._token, directory)
            return registered.id
        text = str(dataset)
        if not RUN_ID.match(text):
            raise ValueError(f"datasets: {text!r} is neither a dataset id nor an existing path")
        return text

    def register_dataset(self, path: Any = None, **options: Any) -> Dataset:
        """Registers a dataset this run (or simulation) made, e.g. the
        snapshots a solver wrote: as `soliton.register_dataset`, with this
        run as its maker and this machine as where it was made."""
        dataset = describe_dataset(path, made_by=self.id,
                                   system=self._description.get("system") or None, **options)
        if self.mode != "disabled":
            upload_dataset(dataset, self._server if self.mode == "online" else None, self._token,
                           self.directory.parent)
        return dataset

    # Logging --------------------------------------------------------------

    def log(self, metrics: Mapping[str, Any], step: Optional[int] = None,
            epoch: Optional[int] = None) -> None:
        """Logs scalar metrics at [step] (default: the previous step + 1).

        Names the app gives dedicated charts: "train/loss", "val/loss",
        "val/accuracy", "optim/lr" and "optim/grad_norm"; any other name shows
        up under "Other metrics". Values may be Python, NumPy or PyTorch
        scalars, and may be NaN or infinite.

        When watching a model, call this after `loss.backward()`, so the
        layer statistics include gradients.
        """
        if self._finished:
            return
        with self._lock:
            step = self._last_step + 1 if step is None else int(step)
            if step < 0:
                raise ValueError("step must be 0 or more")
            self._last_step = max(self._last_step, step)
            if epoch is not None:
                self._epoch = int(epoch)
            values = {}
            for key, value in metrics.items():
                number = to_float(value)
                if number is None:
                    self._warn_once(f"type:{key}", f"skipping {key!r}: not a number ({type(value).__name__})")
                    continue
                values[str(key)[:200]] = encode_float(number)
            now = utc_now_iso()
            if values:
                event = {"type": "metrics", "step": step, "time": now, "values": values}
                if self._epoch is not None:
                    event["epoch"] = self._epoch
                self._files.append(event)
            if self._watcher is not None:
                layers = self._watcher.collect()
                if layers:
                    self._files.append({"type": "layers", "step": step, "time": now, "layers": layers})

    def log_field(self, name: str, prediction: Any, target: Any = None,
                  step: Optional[int] = None, *, max_size: Optional[int] = None,
                  max_points: int = DEFAULT_POINTS, extent: Optional[Sequence[Any]] = None,
                  axes: Optional[Sequence[str]] = None) -> None:
        """Logs a snapshot of a predicted field, e.g. a PDE solution, with the
        true one ([target]) to compare it with, at [step] (default: the
        latest step logged).

        Arrays may be NumPy arrays or PyTorch tensors, 1D, 2D or 3D once
        dimensions of size 1 are removed: log one sample and one channel.
        Log the same validation sample each time, so the app can show it
        improving. The app shows the prediction, the target and their
        difference (3D fields in a rotatable 3D view, or in slices), and the
        relative L2 error over training; the errors are computed on the full
        arrays, but the snapshot is averaged down to at most [max_size]
        points per axis (default 128) and [max_points] values in all
        (default 4M, at most 16M; 4M is about 11 MB to upload and to load in
        the app, per array).

        [extent]: the domain, one (start, end) per axis, e.g. [(0, 2*pi),
        (0, 1)]; [axes]: their names, e.g. ["x", "y"]. The app then shows
        coordinates instead of grid indices. The energy spectrum of the
        prediction and target is computed on the full arrays and sent along.

        Snapshots are larger than metrics: log one every few hundred steps
        (or every validation), not every step.
        """
        if self._finished:
            return
        event, warning = field_event(_field_name(name), prediction, target, max_size=max_size,
                                     max_points=max_points, extent=extent, axes=axes)
        self._append_field(event, step, warning)

    def log_rollout(self, name: str, prediction: Any, target: Any = None,
                    step: Optional[int] = None, *, times: Optional[Sequence[float]] = None,
                    time_axis: int = 0, max_size: Optional[int] = None,
                    max_frames: int = 64, max_points: int = DEFAULT_POINTS,
                    extent: Optional[Sequence[Any]] = None,
                    axes: Optional[Sequence[str]] = None) -> None:
        """Logs a rollout: a field over time, e.g. an autoregressive
        prediction of [frames, x, y] next to the true trajectory.

        [time_axis] is the axis of the arrays that counts frames (other axes
        of size 1 are dropped, leaving 1D to 3D per frame); [times] the time
        of each frame (default 0, 1, 2, ...). The app plays the rollout, and
        charts its error frame by frame, the usual way error builds up over
        a rollout. At most [max_frames] frames are kept, spread evenly
        (always the first and the last), each averaged down to at most
        [max_size] points per axis (default 128), and all frames together to
        at most [max_points] values (default 4M, at most 16M).

        Per frame, the mean (mass), mean square (energy) and minimum
        (positivity) of the prediction and the target are sent too, for the
        app's conservation checks; [extent] and [axes] as for log_field
        (space only).
        """
        if self._finished:
            return
        event, warning = field_event(_field_name(name), prediction, target, max_size=max_size,
                                     rollout=True, time_axis=time_axis, times=times,
                                     max_frames=max_frames, max_points=max_points,
                                     extent=extent, axes=axes)
        self._append_field(event, step, warning)

    def log_eval(self, name: str, predictions: Any, targets: Any, step: Optional[int] = None,
                 *, worst: int = 4, sample_axis: int = 0, max_size: int = 64,
                 extent: Optional[Sequence[Any]] = None,
                 axes: Optional[Sequence[str]] = None) -> None:
        """Logs how a whole validation set went: the relative L2 error of
        every sample (as a histogram and its median, 90th percentile and
        worst), and snapshots of the [worst] samples, so the app can show
        which inputs the model gets wrong.

        [predictions] and [targets]: one sample per entry along
        [sample_axis], each 1D-3D once dimensions of size 1 are dropped (one
        channel; log several names for several variables). Only the
        summary and the worst samples are sent, not the whole set.
        """
        if self._finished:
            return
        body, worst_fields = eval_events(_field_name(name), predictions, targets, worst=worst,
                                         sample_axis=sample_axis, max_size=max_size,
                                         extent=extent, axes=axes)
        with self._lock:
            step = self._step_for(step)
            for event in worst_fields:
                self._append_record({"type": "field", "step": step, **event})
            self._append_record({"type": "eval", "step": step, **body})

    def log_curve(self, name: str, x: Sequence[Any], y: Sequence[Any],
                  step: Optional[int] = None, *, x_label: str = "",
                  y_label: str = "Relative L2",
                  train_range: Optional[Sequence[float]] = None) -> None:
        """Logs a curve measured at one step, e.g. the error against the
        grid resolution (resolution invariance) or against a PDE parameter
        (generalization): run.log_curve("error vs resolution", [64, 128,
        256], errors, x_label="Resolution"). [train_range]: the (low, high)
        of x seen in training, shaded in the app so extrapolation stands
        out. The app shows each curve's latest step.
        """
        if self._finished:
            return
        body = curve_event(str(name).strip()[:200] or "curve", x, y, x_label=x_label,
                           y_label=y_label, train_range=train_range)
        with self._lock:
            self._append_record({"type": "curve", "step": self._step_for(step), **body})

    def log_fourier_weights(self, model, step: Optional[int] = None, *,
                            max_size: int = 64) -> None:
        """Logs how large each learned Fourier weight is: for every complex
        parameter with 3 or more axes (the spectral weights of FNO-style
        layers, in x out x modes), |w| averaged over the channels, as a map
        over the modes. Shows whether the kept modes are used, and whether
        more would help."""
        if self._finished:
            return
        for event in fourier_weight_events(model, max_size=max_size):
            self._append_field(event, step, None)

    @contextmanager
    def capture_layers(self, model, step: Optional[int] = None, *, layers: LayerFilter = None,
                       channel_axis: Optional[int] = None, reduce: str = "mean",
                       max_size: int = 64):
        """Records what each layer outputs during the forward passes in the
        `with` block, so the app can show the field as it goes through the
        network:

            with run.capture_layers(model, step=step):
                prediction = model(val_input[:1])

        Only the first sample of the batch, and each layer's first call, are
        kept. [layers]: module names, or a function (name, module) -> bool;
        default: the model's top-level modules, with ModuleList and
        Sequential opened one level (e.g. lifting, blocks.0-3, projection).

        Each output's channels are averaged ([reduce]="norm": their L2 norm)
        so what's left is 1D to 3D. Which axis holds the channels is
        guessed (the first or the last axis of a sample, whichever differs
        from the spatial axes between them); [channel_axis] says it, counted
        without the batch axis (0: channels-first, -1: channels-last).
        """
        if self._finished:
            yield
            return
        if reduce not in ("mean", "norm"):
            raise ValueError("reduce must be 'mean' or 'norm'")
        outputs = []

        def keep(position, name, output):
            if hasattr(output, "detach"):
                output = output.detach()
                if output.ndim >= 2:
                    output = output[:1]
                output = output.clone()  # In-place layers may change it later.
            outputs.append((position, name, output))

        with capture(model, layers, keep):
            yield
        for position, name, output in outputs:
            try:
                event = layer_event(position, name, output, max_size=max_size,
                                    axis=channel_axis, reduce=reduce)
            except (TypeError, ValueError) as error:
                self._warn_once(f"layer:{name}", f"not showing layer {name!r}: {error}")
                continue
            self._append_field(event, step, None)

    def _append_field(self, event: dict, step: Optional[int], warning: Optional[str]) -> None:
        if warning:
            self._warn_once(f"field:{event['name']}", warning)
        with self._lock:
            if self._finished:
                return
            self._append_record({"type": "field", "step": self._step_for(step), **event})

    def _step_for(self, step: Optional[int]) -> int:
        """[step], or the latest step logged; under the lock."""
        step = max(self._last_step, 0) if step is None else int(step)
        if step < 0:
            raise ValueError("step must be 0 or more")
        self._last_step = max(self._last_step, step)
        return step

    def _append_record(self, record: dict) -> None:
        """Saves (and so uploads) a record with its time and epoch; under
        the lock."""
        if self._finished:
            return
        # NaN and infinity (a diverged sample, an empty frame) as strings.
        record = encode_floats({**record, "time": utc_now_iso()})
        if self._epoch is not None:
            record["epoch"] = self._epoch
        self._files.append(record)

    def watch(self, model, every: int = 100, layers: LayerFilter = None, max_layers: int = 64) -> None:
        """Collects per-layer statistics from a PyTorch model.

        [every]: measure every n-th training forward pass. [layers]: names of
        the modules to watch, or a function (name, module) -> bool; default:
        every module that holds parameters, up to [max_layers].
        """
        if self._finished:
            return
        with self._lock:
            if self._watcher is not None:
                self._watcher.remove()
            if self._description.get("system") is not None:
                # PyTorch is imported by now: add its version if init() came first.
                self._description["system"].update(framework_versions())
            tree = architecture(model)
            self._watcher = Watcher(model, every=every, layers=layers, max_layers=max_layers,
                                    on_traced=lambda flow: self._add_flow(tree, flow))
            self._description["architecture"] = tree
            self._files.append(self._description)  # Updated description, with the model.

    def _log_system(self, values: Mapping[str, float]) -> None:
        """System metrics, at the step training is at (they're sampled in time)."""
        with self._lock:
            if self._finished:
                return
            event = {
                "type": "metrics",
                "step": max(self._last_step, 0),
                "time": utc_now_iso(),
                "values": {name: encode_float(float(v)) for name, v in values.items()},
            }
            if self._epoch is not None:
                event["epoch"] = self._epoch
            self._files.append(event)

    def _log_output(self, start: int, lines: list) -> None:
        """Lines the script printed, numbered from [start] (so a batch sent
        twice replaces itself)."""
        with self._lock:
            if self._finished:
                return
            self._files.append({"type": "output", "start": start, "lines": lines,
                                "time": utc_now_iso()})

    def _add_traceback(self, kind, error, traceback) -> None:
        """The error's traceback, to the output: Python prints it only after
        the run has ended."""
        if self._output is None or kind is None:
            return
        text = "".join(tracebacks.format_exception(kind, error, traceback))
        self._output.add(text.rstrip("\n").split("\n"))

    def _add_flow(self, tree: dict, flow: dict) -> None:
        """After the model's first forward pass: the layers in the order they
        ran, for the app's network diagram."""
        with self._lock:
            if self._finished or self._description["architecture"] is not tree:
                return
            self._description["architecture"] = {**tree, **flow}
            self._files.append(self._description)

    # Ending ---------------------------------------------------------------

    def finish(self, status: str = "finished", message: Optional[str] = None,
               timeout: float = 60) -> None:
        """Marks the run as finished (or "crashed") and uploads what's left,
        waiting up to [timeout] seconds."""
        if status not in ("finished", "crashed"):
            raise ValueError("status must be 'finished' or 'crashed'")
        output = self._output
        if output is not None and not self._finished:
            output.stop()  # The last lines, before the status (outside the lock).
        with self._lock:
            if self._finished:
                return
            self._finished = True
            if self._monitor is not None:
                self._monitor.stop()
            event = {"type": "status", "status": status, "time": utc_now_iso(),
                     **self._status_extra}
            if message:
                event["message"] = message[:2000]
            self._files.append(event)
            if self._watcher is not None:
                self._watcher.remove()
        _unregister(self)
        uploader = self._uploader
        if uploader is not None:
            done = uploader.flush(timeout)
            uploader.stop()
            if not done:
                _say(f"could not upload everything (server unreachable?); the run is saved in "
                     f"{self.directory}. Upload it later with: soliton sync {self.directory}")
        self._files.close()

    def __enter__(self) -> "Run":
        return self

    def __exit__(self, kind, error, _traceback) -> None:
        if error is None:
            self.finish()
        else:
            self._add_traceback(kind, error, _traceback)
            self.finish("crashed", _describe(kind, error))

    def _warn_once(self, key: str, message: str) -> None:
        if key not in self._warned:
            self._warned.add(key)
            warnings.warn(f"soliton: {message}", stacklevel=3)


def _field_name(name: Any) -> str:
    text = str(name).strip()[:200]
    if not text:
        raise ValueError("a field needs a name")
    if text.startswith("layers/"):
        raise ValueError("field names starting with 'layers/' are kept for capture_layers")
    return text


def _system_info(price_per_hour: Optional[float] = None) -> dict:
    try:
        info = system_info()
    except Exception:  # Never let this stop a run from starting.
        info = {}
    if price_per_hour is not None:
        info["pricePerHour"] = price_per_hour
    return info


def _price_per_hour(value: Optional[float]) -> Optional[float]:
    """The machine's price in dollars per hour: `value`, else
    SOLITON_PRICE_PER_HOUR, else None (the app estimates one from the
    GPUs)."""
    source = "price_per_hour"
    if value is None:
        text = os.environ.get("SOLITON_PRICE_PER_HOUR", "").strip()
        if not text:
            return None
        source = "SOLITON_PRICE_PER_HOUR"
        try:
            value = float(text.lstrip("$"))
        except ValueError:
            raise ValueError(f"{source} must be a number of dollars per hour, not {text!r}") from None
    try:
        if isinstance(value, (bool, str)):
            raise TypeError
        value = float(value)  # also NumPy and PyTorch scalars
    except (TypeError, ValueError):
        raise ValueError(f"{source} must be a number of dollars per hour, not {value!r}") from None
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"{source} must be zero or more dollars per hour, not {value!r}")
    return round(value, 4)


def _clean_tags(tags: Optional[Iterable[str]]) -> list:
    """As the server takes them: trimmed, at most 40 characters, each once,
    at most 20. A single string is one tag."""
    if tags is None:
        return []
    if isinstance(tags, str):
        tags = [tags]
    clean: list = []
    for tag in tags:
        text = str(tag).strip()[:40]
        if text and text.casefold() not in {t.casefold() for t in clean}:
            clean.append(text)
    return clean[:20]


def _pde_entries(pde: Optional[Mapping[str, Any]]) -> dict:
    """The PDE, as the app lists (and groups runs by) it: {"equation":
    "Navier-Stokes 2D", "viscosity": 1e-3} becomes {"PDE": "Navier-Stokes
    2D", "PDE viscosity": "0.001"}; nested dicts are flattened."""
    if not pde:
        return {}
    entries = {}
    for key, value in flatten_config(pde).items():
        short = key.split(".")[-1]
        if short.lower() in ("equation", "name", "pde"):
            entries["PDE"] = value
        else:
            entries[f"PDE {key.replace('.', ' ')}"[:200]] = value
    return entries


def _hyperparameters(config, train_samples, val_samples, loss, pde=None) -> dict:
    """The data, loss and PDE first, then the config."""
    first = {}
    for label, value in (("Training samples", train_samples),
                         ("Validation samples", val_samples)):
        if value is None:
            continue
        try:
            first[label] = f"{count_samples(value):,}"
        except TypeError as error:
            warnings.warn(f"soliton: {label.lower()}: {error}", stacklevel=4)
    if loss is not None:
        first["Loss"] = describe_loss(loss)
    first.update(_pde_entries(pde))
    return {**first, **{k: v for k, v in flatten_config(config).items() if k not in first}}


def _capture_output(value: Optional[bool]) -> bool:
    """capture_output=, else SOLITON_CAPTURE_OUTPUT (0, false, no or off
    turn it off); on by default."""
    if value is not None:
        return bool(value)
    setting = os.environ.get("SOLITON_CAPTURE_OUTPUT", "").strip().lower()
    return setting not in ("0", "false", "no", "off")


def _describe(kind, error) -> str:
    if kind is not None and issubclass(kind, KeyboardInterrupt):
        return "Interrupted (KeyboardInterrupt)"
    text = str(error).strip().splitlines()
    return f"{kind.__name__}: {text[0]}" if text else kind.__name__


# Ending runs when the script ends ---------------------------------------------

_active: "weakref.WeakSet[Run]" = weakref.WeakSet()
_installed = False


def _register(run: Run) -> None:
    global _installed
    _active.add(run)
    if _installed:
        return
    _installed = True
    previous_hook = sys.excepthook

    def excepthook(kind, error, traceback):
        for active in list(_active):
            active._add_traceback(kind, error, traceback)
            active.finish("crashed", _describe(kind, error), timeout=30)
        previous_hook(kind, error, traceback)

    sys.excepthook = excepthook
    atexit.register(_finish_all)

    # Slurm sends SIGTERM at the time limit and on scancel. Python would die
    # without running atexit; record why first. Only if nobody else handles it.
    if threading.current_thread() is threading.main_thread():
        try:
            if signal.getsignal(signal.SIGTERM) is signal.SIG_DFL:
                signal.signal(signal.SIGTERM, _on_sigterm)
        except (ValueError, OSError):
            pass


def _unregister(run: Run) -> None:
    _active.discard(run)


def _finish_all() -> None:
    for run in list(_active):
        run.finish(timeout=30)


def _on_sigterm(signum, _frame) -> None:
    for run in list(_active):
        run.finish("crashed", _sigterm_reason(run._description.get("system")), timeout=15)
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)


# SIGTERM this close to the job's time limit is the limit (the job may ask
# for it early, e.g. `#SBATCH --signal=B:TERM@60`).
_NEAR_LIMIT_S = 300


def _sigterm_reason(system: Optional[Mapping[str, Any]], now: Optional[float] = None) -> str:
    """Why SIGTERM came: the Slurm job's time limit if it is (nearly) there,
    else most likely scancel."""
    slurm = (system or {}).get("slurm") or {}
    limit = _unix_time(slurm.get("timeLimitAt"))
    if limit is not None and (time.time() if now is None else now) >= limit - _NEAR_LIMIT_S:
        return ("Stopped by its Slurm time limit (SIGTERM). Ask for more time (--time), or "
                "save checkpoints and continue the run in a new job.")
    return "Stopped by SIGTERM (for example scancel, or a Slurm time limit)"


def _unix_time(text: Any) -> Optional[float]:
    """"2026-11-14T18:32:22Z" as a Unix time, or None."""
    if not isinstance(text, str):
        return None
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()
