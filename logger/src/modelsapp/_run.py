"""A training run: what `modelsapp.init()` returns."""

from __future__ import annotations

import atexit
import os
import signal
import sys
import threading
import warnings
import weakref
from pathlib import Path
from typing import Any, Iterable, Mapping, Optional

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
        }
        self._files = RunFiles(self.directory)
        self._lock = threading.RLock()
        self._last_step = -1
        self._epoch: Optional[int] = None
        self._watcher: Optional[Watcher] = None
        self._warned: set = set()
        self._finished = mode == "disabled"
        self._uploader: Optional[Uploader] = None
        if self._finished:
            return

        self._files.append(self._description)
        if mode == "online":
            self._uploader = Uploader(self._files, ApiClient(server, token), _say)
            self._uploader.start()
        else:
            _say(f"saving run {run_id} to {self.directory} (offline); upload it with "
                 "`modelsapp sync`")
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
            tree = architecture(model)
            self._watcher = Watcher(model, every=every, layers=layers, max_layers=max_layers,
                                    on_traced=lambda flow: self._add_flow(tree, flow))
            self._description["architecture"] = tree
            self._files.append(self._description)  # Updated description, with the model.

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
