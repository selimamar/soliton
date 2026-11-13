"""Field snapshots: a model's predicted solution next to the true one.

A field is a 1D, 2D or 3D array (e.g. a PDE solution on a grid), optionally
over time (a rollout: several frames). It travels as 16-bit values between
the snapshot's min and max (base64, little-endian), frame after frame, after
averaging blocks of grid points down to at most `max_size` per axis: a
128 x 128 snapshot with its target is about 90 KB of JSON, a 128^3 volume
about 11 MB. The error
statistics are computed on the full arrays, before any of that.

Layer snapshots (`Run.capture_layers`) are fields too: a layer's output for
one sample, with its channels averaged, so each layer can be drawn like the
solution.

NumPy is only needed here, and only when a field is logged.
"""

from __future__ import annotations

import base64
import math
import warnings
from contextlib import contextmanager
from typing import Any, Dict, Iterator, List, Optional, Sequence, Tuple

NAN_CODE = 65535  # Quantized values are 0..65534; this one means NaN (or ±inf).
LEVELS = 65534
MAX_SIZE = 512  # Largest axis the server accepts.
MAX_POINTS = 1 << 24  # Most values in one array (all frames) the server accepts: ~43 MB of JSON.
DEFAULT_POINTS = 1 << 22  # The default cap: 4M values, ~11 MB of JSON per array.
MAX_FRAMES = 256
MAX_LAYERS = 48


def _numpy():
    try:
        import numpy
    except ImportError:  # pragma: no cover - NumPy comes with PyTorch.
        raise ImportError("logging fields needs NumPy: pip install numpy") from None
    return numpy


def to_array(value: Any, what: str):
    """A NumPy, PyTorch or nested-list array as a float64 NumPy array."""
    np = _numpy()
    if hasattr(value, "detach"):  # PyTorch tensor (on any device, with grad).
        value = value.detach().float().cpu().numpy()
    try:
        return np.asarray(value, dtype=np.float64)
    except (TypeError, ValueError):
        raise TypeError(f"{what}: expected an array, not {type(value).__name__}") from None


def _spatial(array, what: str, frames: bool):
    """Drops dimensions of size 1 (batch, channel), except the leading time
    axis of a rollout. Checks what is left is 1D to 3D."""
    np = _numpy()
    if frames:
        if array.ndim == 0 or array.shape[0] == 0:
            raise ValueError(f"{what}: a rollout needs at least one frame")
        keep = [0] + [axis for axis in range(1, array.ndim) if array.shape[axis] != 1]
        array = array.reshape([array.shape[a] for a in keep])
        spatial = array.ndim - 1
    else:
        array = array.squeeze()
        spatial = array.ndim
    if spatial not in (1, 2, 3):
        shape = tuple(array.shape[1:] if frames else array.shape)
        raise ValueError(
            f"{what}: a field must be 1D, 2D or 3D after removing dimensions of size 1, but "
            f"its shape is {shape}. Log one sample and one channel, e.g. u[0, 0]"
        )
    if array.size == 0:
        raise ValueError(f"{what}: the field is empty")
    return np.ascontiguousarray(array)


def shrink(array, max_size: int, first_axis: int = 0, max_points: int = MAX_POINTS):
    """Averages blocks of points so no axis from [first_axis] on is longer
    than [max_size], and the whole array has at most [max_points] values. A
    few points at the far edge are dropped when a length isn't a multiple of
    the block size."""
    np = _numpy()
    axes = range(first_axis, array.ndim)
    factors = {axis: math.ceil(array.shape[axis] / max_size) for axis in axes}

    def size() -> int:
        return math.prod(array.shape[a] // factors.get(a, 1) for a in range(array.ndim))

    while size() > max_points:
        longest = max(axes, key=lambda a: array.shape[a] // factors[a])
        factors[longest] += 1
    for axis, factor in factors.items():
        if factor <= 1:
            continue
        length = array.shape[axis]
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
    stats["rmse"] = float(np.sqrt(np.mean(error**2)))
    stats["maxError"] = float(np.max(np.abs(error)))
    if norm > 0:
        stats["relL2"] = float(np.linalg.norm(error)) / norm
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


def _frame_indices(count: int, max_frames: int) -> List[int]:
    """At most [max_frames] evenly spread frames, always the first and last."""
    if count <= max_frames:
        return list(range(count))
    np = _numpy()
    return sorted({int(round(i)) for i in np.linspace(0, count - 1, max_frames)})


def field_event(name: str, prediction: Any, target: Any = None, *, max_size: Optional[int] = None,
                rollout: bool = False, time_axis: int = 0, times: Optional[Sequence[float]] = None,
                max_frames: int = 64, max_points: int = DEFAULT_POINTS,
                ) -> Tuple[dict, Optional[str]]:
    """The "field" event body (without step and time), and a warning if
    something was off but logged anyway."""
    np = _numpy()
    if not 1 <= max_frames <= MAX_FRAMES:
        raise ValueError(f"max_frames must be between 1 and {MAX_FRAMES}")
    if not 1024 <= max_points <= MAX_POINTS:
        raise ValueError(f"max_points must be between 1024 and {MAX_POINTS:,}")
    pred = to_array(prediction, "prediction")
    true = None if target is None else to_array(target, "target")
    if rollout:
        if not -pred.ndim <= time_axis < pred.ndim:
            raise ValueError(f"time_axis {time_axis} is out of range for shape {pred.shape}")
        pred = np.moveaxis(pred, time_axis, 0)
        true = None if true is None else np.moveaxis(true, time_axis, 0)
    pred = _spatial(pred, "prediction", rollout)
    true = None if true is None else _spatial(true, "target", rollout)
    # Compared once dimensions of size 1 are gone: [1, 1, H, W] matches [H, W].
    if true is not None and true.shape != pred.shape:
        raise ValueError(
            f"prediction and target have different shapes: {tuple(pred.shape)} and "
            f"{tuple(true.shape)}"
        )
    if not rollout:
        pred, true = pred[None], (None if true is None else true[None])
    frame_count = pred.shape[0]
    if times is not None:
        times = [float(t) for t in times]
        if len(times) != frame_count:
            raise ValueError(f"times has {len(times)} entries, but the rollout has "
                             f"{frame_count} frames")
    if max_size is None:
        max_size = 128
    if not 8 <= max_size <= MAX_SIZE:
        raise ValueError(f"max_size must be between 8 and {MAX_SIZE}")

    stats = {} if true is None else error_stats(pred, true)
    keep = _frame_indices(frame_count, max_frames)
    pred = pred[keep]
    true = None if true is None else true[keep]
    frame_stats: Dict[str, list] = {}
    if true is not None and rollout:
        per_frame = [error_stats(p, t) for p, t in zip(pred, true)]
        for key in ("relL2", "rmse", "maxError"):
            frame_stats[key] = [s.get(key, math.nan) for s in per_frame]
    original_shape = list(pred.shape[1:])
    pred = shrink(pred, max_size, first_axis=1, max_points=max_points)
    true = None if true is None else shrink(true, max_size, first_axis=1, max_points=max_points)

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
        "kind": "output",
        "shape": list(pred.shape[1:]),
        "originalShape": original_shape,
        "frames": len(keep),
        "min": low,
        "max": high,
        "prediction": quantize(pred, low, high),
        "target": None if true is None else quantize(true, low, high),
        "stats": stats,
    }
    if rollout:
        event["times"] = [times[i] for i in keep] if times is not None else [float(i) for i in keep]
        if frame_stats:
            event["frameStats"] = frame_stats
    return event, warning


# Layer snapshots ----------------------------------------------------------------


def channel_axis(shape: Sequence[int]) -> Optional[int]:
    """Which axis of one sample's layer output holds channels (features),
    not space: None for a 1D output, else the first or the last axis.

    The one that differs from the axes between them is the channel axis
    (e.g. [32, 64, 64] is channels-first, [64, 64, 32] channels-last); if
    that doesn't tell, the shorter of the two (a tie: channels-first, as
    PyTorch's convolutions).
    """
    if len(shape) <= 1:
        return None
    first, last, middle = shape[0], shape[-1], shape[1:-1]
    if middle:
        if last in middle and first not in middle:
            return 0
        if first in middle and last not in middle:
            return len(shape) - 1
    return len(shape) - 1 if last < first else 0


def layer_field(output: Any, *, axis: Optional[int], reduce: str) -> Tuple[Any, str, List[int]]:
    """One sample of a layer's output as a 1D-3D field, its channels
    reduced: (field, how, the sample's shape). [axis] counts in the sample
    (without the batch axis)."""
    np = _numpy()
    array = to_array(output, "layer output")
    if array.ndim >= 2:
        array = array[0]  # The first sample of the batch.
    shape = list(array.shape)
    if array.ndim == 0 or array.size <= 1:
        raise ValueError("a single number")
    # Find the channel axis on the full shape: a [64, 64, 1] output is one
    # channel, not a 64-point line averaged over the other 64.
    if axis is None:
        axis = channel_axis(shape)
    elif axis < 0:
        axis += array.ndim
    if axis is not None and not 0 <= axis < array.ndim:
        raise ValueError(f"channel axis out of range for a sample of shape {tuple(shape)}")
    how = "as is"
    if axis is not None:
        channels = array.shape[axis]
        with np.errstate(invalid="ignore"):
            if reduce == "mean":
                array = array.mean(axis=axis)
                how = f"mean of {channels} channels" if channels > 1 else "1 channel"
            elif reduce == "norm":
                array = np.sqrt((array**2).sum(axis=axis))
                how = f"norm over {channels} channels" if channels > 1 else "1 channel, magnitude"
            else:
                raise ValueError("reduce must be 'mean' or 'norm'")
    array = array.reshape([n for n in array.shape if n != 1] or [1])
    if array.ndim > 3:
        raise ValueError(f"{array.ndim} dimensions are left after reducing the channels")
    return array, how, shape


def _default_layers(model) -> List[Tuple[str, Any]]:
    """The model's top-level modules, with containers (ModuleList,
    Sequential) opened one level: e.g. lifting, blocks.0, ..., projection."""
    import torch.nn as nn

    chosen = []
    for name, child in model.named_children():
        if isinstance(child, (nn.ModuleList, nn.Sequential)) and len(child) > 0:
            chosen.extend((f"{name}.{sub}", module) for sub, module in child.named_children())
        else:
            chosen.append((name, child))
    return chosen


def _select_layers(model, layers) -> List[Tuple[str, Any]]:
    if layers is None:
        chosen = _default_layers(model)
    else:
        named = dict(model.named_modules())
        if callable(layers):
            chosen = [(n, m) for n, m in named.items() if n and layers(n, m)]
        else:
            missing = [n for n in layers if n not in named]
            if missing:
                raise ValueError(f"no such layers in the model: {', '.join(missing)}")
            chosen = [(n, named[n]) for n in layers]
    if len(chosen) > MAX_LAYERS:
        warnings.warn(f"modelsapp: capturing the first {MAX_LAYERS} of {len(chosen)} layers",
                      stacklevel=4)
        chosen = chosen[:MAX_LAYERS]
    return chosen


@contextmanager
def capture(model, layers, on_output) -> Iterator[None]:
    """Calls on_output(position, name, output) for each chosen layer's first
    output while the block runs (one forward pass)."""
    handles = []
    seen = set()
    chosen = _select_layers(model, layers)

    def hook(position: int, name: str):
        def record(_module, _inputs, output):
            if name in seen:  # A layer called twice: keep the first.
                return
            seen.add(name)
            if isinstance(output, (tuple, list)) and output:
                output = output[0]
            on_output(position, name, output)

        return record

    for position, (name, module) in enumerate(chosen):
        handles.append(module.register_forward_hook(hook(position, name)))
    try:
        yield
    finally:
        for handle in handles:
            handle.remove()


def layer_event(position: int, layer: str, output: Any, *, max_size: int, axis: Optional[int],
                reduce: str) -> dict:
    """The "field" event body (without step and time) of a layer's output."""
    field, how, sample_shape = layer_field(output, axis=axis, reduce=reduce)
    # Named apart from output fields, which share the (run, name, step) key.
    event, _ = field_event(f"layers/{layer}", field, max_size=max_size)
    event.update(kind="layer", layer=layer, position=position, reduction=how,
                 layerShape=sample_shape)
    return event
