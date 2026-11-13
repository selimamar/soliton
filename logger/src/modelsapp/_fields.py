"""Field snapshots: a model's predicted solution next to the true one.

A field is a 1D or 2D array (e.g. a PDE solution on a grid). It travels as
16-bit values between the snapshot's min and max (base64, little-endian),
after averaging blocks of grid points down to at most `max_size` per axis:
a 128 x 128 snapshot with its target is about 90 KB of JSON. The error
statistics are computed on the full arrays, before any of that.

NumPy is only needed here, and only when a field is logged.
"""

from __future__ import annotations

import base64
import math
from typing import Any, Dict, Optional, Tuple

NAN_CODE = 65535  # Quantized values are 0..65534; this one means NaN (or ±inf).
LEVELS = 65534
MAX_SIZE = 512  # Largest grid the server accepts, per axis.


def _numpy():
    try:
        import numpy
    except ImportError:  # pragma: no cover - NumPy comes with PyTorch.
        raise ImportError("log_field needs NumPy: pip install numpy") from None
    return numpy


def to_array(value: Any, what: str):
    """A NumPy, PyTorch or nested-list array as a float64 NumPy array, with
    dimensions of size 1 (batch, channel) removed."""
    np = _numpy()
    if hasattr(value, "detach"):  # PyTorch tensor (on any device, with grad).
        value = value.detach().float().cpu().numpy()
    try:
        array = np.asarray(value, dtype=np.float64)
    except (TypeError, ValueError):
        raise TypeError(f"{what}: expected an array, not {type(value).__name__}") from None
    array = array.squeeze()
    if array.ndim not in (1, 2):
        raise ValueError(
            f"{what}: a field must be 1D or 2D after removing dimensions of size 1, but its "
            f"shape is {tuple(array.shape)}. Log one sample, one channel and, in 3D, one "
            "slice, e.g. u[0, 0] or u[0, :, :, depth // 2]"
        )
    if array.size == 0:
        raise ValueError(f"{what}: the field is empty")
    return array


def shrink(array, max_size: int):
    """Averages blocks of points so no axis is longer than [max_size]. A few
    points at the far edge are dropped when the length isn't a multiple of
    the block size."""
    np = _numpy()
    for axis, length in enumerate(array.shape):
        factor = math.ceil(length / max_size)
        if factor <= 1:
            continue
        kept = (length // factor) * factor
        array = np.take(array, range(kept), axis=axis)
        shape = list(array.shape)
        shape[axis : axis + 1] = [kept // factor, factor]
        with np.errstate(invalid="ignore"):
            array = array.reshape(shape).mean(axis=axis + 1)
    return array


def error_stats(prediction, target) -> Dict[str, float]:
    """Relative L2 error, RMSE and the largest pointwise error, ignoring
    points where either array isn't finite."""
    np = _numpy()
    finite = np.isfinite(prediction) & np.isfinite(target)
    stats: Dict[str, float] = {"nonFinite": float(prediction.size - int(finite.sum()))}
    if not finite.any():
        return stats
    error = prediction[finite] - target[finite]
    norm = float(np.linalg.norm(target[finite]))
    error_norm = float(np.linalg.norm(error))
    stats["rmse"] = float(np.sqrt(np.mean(error**2)))
    stats["maxError"] = float(np.max(np.abs(error)))
    if norm > 0:
        stats["relL2"] = error_norm / norm
    return stats


def quantize(array, low: float, high: float) -> str:
    """[array] as base64 16-bit codes: 0 is [low], LEVELS is [high]."""
    np = _numpy()
    span = high - low
    finite = np.isfinite(array)
    scaled = np.zeros(array.shape) if span <= 0 else (np.where(finite, array, low) - low) / span
    codes = np.clip(np.rint(scaled * LEVELS), 0, LEVELS).astype("<u2")
    codes[~finite] = NAN_CODE
    return base64.b64encode(codes.tobytes()).decode("ascii")


def field_event(name: str, prediction: Any, target: Any, max_size: int) -> Tuple[dict, Optional[str]]:
    """The "field" event body (without step and time), and a warning if
    something was off but logged anyway."""
    if not 8 <= max_size <= MAX_SIZE:
        raise ValueError(f"max_size must be between 8 and {MAX_SIZE}")
    pred = to_array(prediction, "prediction")
    true = None if target is None else to_array(target, "target")
    if true is not None and true.shape != pred.shape:
        raise ValueError(
            f"prediction and target have different shapes: {tuple(pred.shape)} and "
            f"{tuple(true.shape)}"
        )
    stats = {} if true is None else error_stats(pred, true)
    original_shape = list(pred.shape)
    pred = shrink(pred, max_size)
    true = None if true is None else shrink(true, max_size)

    np = _numpy()
    values = pred if true is None else np.concatenate([pred.ravel(), true.ravel()])
    finite = values[np.isfinite(values)]
    warning = None
    if finite.size == 0:
        low = high = 0.0
        warning = f"field {name!r} has no finite values"
    else:
        low, high = float(finite.min()), float(finite.max())
    event = {
        "name": name,
        "shape": list(pred.shape),
        "originalShape": original_shape,
        "min": low,
        "max": high,
        "prediction": quantize(pred, low, high),
        "target": None if true is None else quantize(true, low, high),
        "stats": stats,
    }
    return event, warning
