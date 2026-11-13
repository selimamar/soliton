"""Small helpers: JSON numbers, run ids, hyperparameters, host names."""

from __future__ import annotations

import functools
import json
import math
import os
import re
import secrets
import socket
from datetime import datetime, timezone
from typing import Any, Dict, Mapping, Optional, Union

JsonNumber = Union[float, int, str]


def encode_float(value: float) -> JsonNumber:
    """JSON has no NaN or infinity: they travel as strings (the server and the
    app use the same convention)."""
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Infinity" if value > 0 else "-Infinity"
    return value


def to_float(value: Any) -> Optional[float]:
    """A Python, NumPy or PyTorch scalar as a float; None if it isn't one."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    item = getattr(value, "item", None)  # NumPy scalars, 1-element tensors
    if callable(item):
        try:
            result = item()
        except (ValueError, RuntimeError):  # More than one element.
            return None
        if isinstance(result, (int, float)) and not isinstance(result, bool):
            return float(result)
    return None


def dumps(record: Mapping[str, Any]) -> str:
    """One JSON line. Refuses bare NaN, which isn't valid JSON."""
    return json.dumps(record, allow_nan=False, separators=(",", ":"), ensure_ascii=False)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def slugify(name: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-._")
    return (slug or "run")[:100]


def new_run_id(name: str) -> str:
    """E.g. "resnet50-cifar-3fa9c1": readable, and unique enough."""
    return f"{slugify(name)}-{secrets.token_hex(3)}"


RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def format_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return f"{value:g}"
    if isinstance(value, (list, tuple)):
        return ", ".join(format_value(v) for v in value)
    return str(value)


def flatten_config(config: Optional[Mapping[str, Any]], prefix: str = "") -> Dict[str, str]:
    """Nested settings as display strings: {"optim": {"lr": 3e-4}} becomes
    {"optim.lr": "0.0003"}. Also accepts argparse.Namespace."""
    if config is None:
        return {}
    if not isinstance(config, Mapping):
        config = vars(config)
    flat: Dict[str, str] = {}
    for key, value in config.items():
        name = f"{prefix}{key}"
        if isinstance(value, Mapping):
            flat.update(flatten_config(value, prefix=f"{name}."))
        else:
            flat[name[:200]] = format_value(value)
    return flat


def count_samples(value: Any) -> int:
    """A number of samples: a number, a dataset's length, or the length of a
    DataLoader's dataset (not its number of batches). TypeError if unknown."""
    if isinstance(value, bool):
        raise TypeError("expected a number of samples, not a bool")
    if isinstance(value, int):
        return value
    if any(cls.__name__ == "DataLoader" for cls in type(value).__mro__):
        value = value.dataset
    try:
        return int(len(value))
    except TypeError:
        raise TypeError(
            f"can't count the samples in a {type(value).__name__} (it has no length); "
            "pass the number instead"
        ) from None


def describe_loss(loss: Any) -> str:
    """A loss as text: a string as is, a function by its name, a PyTorch loss
    by its class with the settings that differ from the defaults, e.g.
    "CrossEntropyLoss(label_smoothing=0.1)"."""
    if isinstance(loss, str):
        return loss
    if isinstance(loss, functools.partial):
        settings = ", ".join(f"{k}={format_value(v)}" for k, v in loss.keywords.items())
        name = describe_loss(loss.func)
        return f"{name}({settings})" if settings else name
    name = getattr(loss, "__name__", None)  # Functions and classes.
    if isinstance(name, str):
        return name
    kind = type(loss)
    settings = _changed_settings(loss) if kind.__module__.startswith("torch.nn") else ""
    return f"{kind.__name__}({settings})" if settings else kind.__name__


def _changed_settings(module: Any) -> str:
    """Simple settings of a PyTorch module that differ from a default one."""
    try:
        default = vars(type(module)())
    except Exception:  # Needs arguments: no defaults to compare with.
        return ""
    changed = []
    for key, value in vars(module).items():
        if key.startswith("_") or key == "training":
            continue
        if isinstance(value, (bool, int, float, str)) and default.get(key, value) != value:
            changed.append(f"{key}={format_value(value)}")
    return ", ".join(changed)


def detect_host(env: Mapping[str, str] = os.environ) -> str:
    """Where the job runs, e.g. "Sherlock" for a Slurm job on Sherlock."""
    if env.get("MODELSAPP_HOST"):
        return env["MODELSAPP_HOST"]
    cluster = env.get("SLURM_CLUSTER_NAME")
    if cluster:
        return cluster.capitalize()
    hostname = socket.gethostname()
    if hostname.endswith(".sherlock.stanford.edu"):
        return "Sherlock"
    return hostname.split(".")[0] or "unknown"
