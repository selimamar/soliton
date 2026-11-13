"""Small helpers: JSON numbers, run ids, hyperparameters, host names."""

from __future__ import annotations

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
