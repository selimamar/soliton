"""A training run: what `modelsapp.init()` returns."""

from __future__ import annotations

import atexit
import os
import signal
import sys
import threading
import warnings
import weakref
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterable, Mapping, Optional, Sequence

from ._fields import capture, field_event, layer_event
from ._system import SystemMonitor, framework_versions, system_info
from ._upload import ApiClient, RunFiles, Uploader
from ._util import (
    RUN_ID,
    count_samples,
    describe_loss,
    detect_host,
    encode_float,
    flatten_config,
    new_run_id,
    to_float,
    utc_now_iso,
)
from ._watch import LayerFilter, Watcher, architecture

MODES = ("online", "offline", "disabled")


def _say(message: str) -> None:
    print(f"modelsapp: {message}", file=sys.stderr, flush=True)


class Run:
    """One training run. Create it with `modelsapp.init()`.

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
        tags: Optional[Iterable[str]] = None,
        notes: str = "",
        system_metrics: bool = True,
        system_interval: float = 15,
        total_steps: int = 0,
        total_epochs: int = 0,
        host: Optional[str] = None,
        id: Optional[str] = None,
        server: Optional[str] = None,
        token: Optional[str] = None,
        mode: Optional[str] = None,
        dir: Optional[str] = None,
    ) -> None:
        server = server or os.environ.get("MODELSAPP_SERVER")
        token = token or os.environ.get("MODELSAPP_TOKEN")
        mode = mode or os.environ.get("MODELSAPP_MODE") or ("online" if server else "offline")
        if mode not in MODES:
            raise ValueError(f"mode must be one of {', '.join(MODES)}, not {mode!r}")
        if mode == "online" and not (server and token):
            raise ValueError(
                "online mode needs a server and a token: pass server=... and token=..., or set "
                "MODELSAPP_SERVER and MODELSAPP_TOKEN (or use mode='offline')"
            )
        run_id = id or new_run_id(name)
        if not RUN_ID.match(run_id):
            raise ValueError(f"invalid run id {run_id!r}: letters, digits, '.', '_' and '-' only")

        self.id = run_id
        self.name = name
        self.mode = mode
        self.directory = Path(dir or os.environ.get("MODELSAPP_DIR") or "modelsapp-runs") / run_id
        self._description = {
            "type": "run",
            "id": run_id,
            "name": name,
            "project": project,
            "host": host or detect_host(),
            "startedAt": utc_now_iso(),
            "totalSteps": int(total_steps),
            "totalEpochs": int(total_epochs),
            "hyperparameters": _hyperparameters(config, train_samples, val_samples, loss),
            "architecture": None,
            "tags": _clean_tags(tags),
            "notes": str(notes or "")[:10_000],
            "system": _system_info() if mode != "disabled" else None,
        }
        self._files = RunFiles(self.directory)
        self._lock = threading.RLock()
        self._last_step = -1
        self._epoch: Optional[int] = None
        self._watcher: Optional[Watcher] = None
        self._warned: set = set()
        self._finished = mode == "disabled"
        self._uploader: Optional[Uploader] = None
        self._monitor: Optional[SystemMonitor] = None
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
                 "`modelsapp sync`")
        if system_metrics:
            self._monitor = SystemMonitor(self._log_system, interval=system_interval)
            self._monitor.start()
        _register(self)

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
                  step: Optional[int] = None, *, max_size: Optional[int] = None) -> None:
        """Logs a snapshot of a predicted field, e.g. a PDE solution, with the
        true one ([target]) to compare it with, at [step] (default: the
        latest step logged).

        Arrays may be NumPy arrays or PyTorch tensors, 1D, 2D or 3D once
        dimensions of size 1 are removed: log one sample and one channel.
        Log the same validation sample each time, so the app can show it
        improving. The app shows the prediction, the target and their
        difference (3D fields as slices), and the relative L2 error over
        training; the errors are computed on the full arrays, but the
        snapshot is averaged down to at most [max_size] points per axis
        (default 128, or 64 in 3D).

        Snapshots are larger than metrics: log one every few hundred steps
        (or every validation), not every step.
        """
        if self._finished:
            return
        event, warning = field_event(_field_name(name), prediction, target, max_size=max_size)
        self._append_field(event, step, warning)

    def log_rollout(self, name: str, prediction: Any, target: Any = None,
                    step: Optional[int] = None, *, times: Optional[Sequence[float]] = None,
                    time_axis: int = 0, max_size: Optional[int] = None,
                    max_frames: int = 64) -> None:
        """Logs a rollout: a field over time, e.g. an autoregressive
        prediction of [frames, x, y] next to the true trajectory.

        [time_axis] is the axis of the arrays that counts frames (other axes
        of size 1 are dropped, leaving 1D to 3D per frame); [times] the time
        of each frame (default 0, 1, 2, ...). The app plays the rollout, and
        charts its error frame by frame, the usual way error builds up over
        a rollout. At most [max_frames] frames are kept, spread evenly
        (always the first and the last), each averaged down to at most
        [max_size] points per axis (default 64).
        """
        if self._finished:
            return
        event, warning = field_event(_field_name(name), prediction, target, max_size=max_size,
                                     rollout=True, time_axis=time_axis, times=times,
                                     max_frames=max_frames)
        self._append_field(event, step, warning)

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
            step = max(self._last_step, 0) if step is None else int(step)
            if step < 0:
                raise ValueError("step must be 0 or more")
            self._last_step = max(self._last_step, step)
            record = {"type": "field", "step": step, "time": utc_now_iso(), **event}
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
        with self._lock:
            if self._finished:
                return
            self._finished = True
            if self._monitor is not None:
                self._monitor.stop()
            event = {"type": "status", "status": status, "time": utc_now_iso()}
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
                     f"{self.directory}. Upload it later with: modelsapp sync {self.directory}")
        self._files.close()

    def __enter__(self) -> "Run":
        return self

    def __exit__(self, kind, error, _traceback) -> None:
        if error is None:
            self.finish()
        else:
            self.finish("crashed", _describe(kind, error))

    def _warn_once(self, key: str, message: str) -> None:
        if key not in self._warned:
            self._warned.add(key)
            warnings.warn(f"modelsapp: {message}", stacklevel=3)


def _field_name(name: Any) -> str:
    text = str(name).strip()[:200]
    if not text:
        raise ValueError("a field needs a name")
    if text.startswith("layers/"):
        raise ValueError("field names starting with 'layers/' are kept for capture_layers")
    return text


def _system_info() -> dict:
    try:
        return system_info()
    except Exception:  # Never let this stop a run from starting.
        return {}


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


def _hyperparameters(config, train_samples, val_samples, loss) -> dict:
    """The data and loss first, then the config."""
    first = {}
    for label, value in (("Training samples", train_samples),
                         ("Validation samples", val_samples)):
        if value is None:
            continue
        try:
            first[label] = f"{count_samples(value):,}"
        except TypeError as error:
            warnings.warn(f"modelsapp: {label.lower()}: {error}", stacklevel=4)
    if loss is not None:
        first["Loss"] = describe_loss(loss)
    return {**first, **{k: v for k, v in flatten_config(config).items() if k not in first}}


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
        run.finish(
            "crashed",
            "Stopped by SIGTERM (for example a Slurm time limit or scancel)",
            timeout=15,
        )
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
