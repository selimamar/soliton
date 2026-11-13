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


def _domain(extent, axes, dims: int) -> dict:
    """Validated `extent` and `axes` for a field of [dims] spatial axes."""
    out: dict = {}
    if extent is not None:
        pairs = [[float(a), float(b)] for a, b in extent]
        if len(pairs) != dims:
            raise ValueError(f"extent needs {dims} (start, end) pairs, one per axis")
        if any(not (math.isfinite(a) and math.isfinite(b)) or a == b for a, b in pairs):
            raise ValueError("each extent needs two different, finite ends")
        out["extent"] = pairs
    if axes is not None:
        names = [str(a)[:20] for a in axes]
        if len(names) != dims:
            raise ValueError(f"axes needs {dims} names, one per axis")
        out["axes"] = names
    return out


SPECTRUM_BINS = 64


def energy_spectrum(field) -> Optional[Tuple[List[float], List[float]]]:
    """The radially averaged energy spectrum of a 1D-3D field: energy summed
    over shells of integer wavenumber |k| = 1 .. n/2 (the mean removed).
    More than SPECTRUM_BINS shells are merged into log-spaced bins. None if
    the field is too small (under 8 points on an axis)."""
    np = _numpy()
    if min(field.shape) < 8:
        return None
    a = np.nan_to_num(np.asarray(field, dtype=np.float64), nan=0.0, posinf=0.0, neginf=0.0)
    a = a - a.mean()
    power = np.abs(np.fft.fftn(a) / a.size) ** 2
    grids = np.meshgrid(*[np.fft.fftfreq(n) * n for n in a.shape], indexing="ij")
    shell = np.rint(np.sqrt(sum(g**2 for g in grids))).astype(int).ravel()
    kmax = min(a.shape) // 2
    energy = np.bincount(shell, weights=power.ravel(), minlength=kmax + 1)[1 : kmax + 1]
    ks = np.arange(1, kmax + 1, dtype=np.float64)
    if kmax > SPECTRUM_BINS:
        edges = np.unique(np.rint(np.logspace(0, np.log10(kmax + 1), SPECTRUM_BINS + 1)).astype(int))
        sums = [energy[lo - 1 : hi - 1].sum() for lo, hi in zip(edges[:-1], edges[1:])]
        centres = [math.sqrt(lo * (hi - 1)) for lo, hi in zip(edges[:-1], edges[1:])]
        ks, energy = np.array(centres), np.array(sums)
    return [float(k) for k in ks], [float(e) for e in energy]


def _frame_physics(frames) -> Dict[str, list]:
    """Per frame: mean (e.g. mass), mean square (energy) and minimum
    (positivity), ignoring NaN."""
    np = _numpy()
    flat = frames.reshape(frames.shape[0], -1)
    with np.errstate(all="ignore"), warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return {
            "mean": [float(v) for v in np.nanmean(flat, axis=1)],
            "meanSquare": [float(v) for v in np.nanmean(flat**2, axis=1)],
            "min": [float(v) for v in np.nanmin(flat, axis=1)],
        }


def field_event(name: str, prediction: Any, target: Any = None, *, max_size: Optional[int] = None,
                rollout: bool = False, time_axis: int = 0, times: Optional[Sequence[float]] = None,
                max_frames: int = 64, max_points: int = DEFAULT_POINTS,
                extent: Optional[Sequence[Sequence[float]]] = None,
                axes: Optional[Sequence[str]] = None, spectrum: bool = True,
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

    domain = _domain(extent, axes, pred.ndim - 1)
    stats = {} if true is None else error_stats(pred, true)
    keep = _frame_indices(frame_count, max_frames)
    pred = pred[keep]
    true = None if true is None else true[keep]
    frame_stats: Dict[str, list] = {}
    if true is not None and rollout:
        per_frame = [error_stats(p, t) for p, t in zip(pred, true)]
        for key in ("relL2", "rmse", "maxError"):
            frame_stats[key] = [s.get(key, math.nan) for s in per_frame]
    if rollout:
        # Conservation and positivity along the rollout, on the full grid.
        frame_stats.update(_frame_physics(pred))
        if true is not None:
            frame_stats.update({f"target{k[0].upper()}{k[1:]}": v
                                for k, v in _frame_physics(true).items()})
    # The spectrum of the last frame (where a rollout's error is largest),
    # on the full grid: averaging down would cut off the high wavenumbers.
    spectra = None
    if spectrum:
        pred_spectrum = energy_spectrum(pred[-1])
        if pred_spectrum is not None:
            spectra = {"k": pred_spectrum[0], "prediction": pred_spectrum[1],
                       "target": None if true is None else energy_spectrum(true[-1])[1]}
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
        **domain,
    }
    if spectra is not None:
        event["spectrum"] = spectra
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
    event, _ = field_event(f"layers/{layer}", field, max_size=max_size, spectrum=False)
    event.update(kind="layer", layer=layer, position=position, reduction=how,
                 layerShape=sample_shape)
    return event


# The whole validation set ----------------------------------------------------------

HISTOGRAM_BINS = 24
MAX_WORST = 12


def eval_events(name: str, predictions: Any, targets: Any, *, worst: int, sample_axis: int,
                max_size: int, extent=None, axes=None) -> Tuple[dict, List[dict]]:
    """The "eval" event body for a whole validation set (one sample per
    entry along [sample_axis]), and the "field" event bodies of its [worst]
    samples."""
    np = _numpy()
    if not 0 <= worst <= MAX_WORST:
        raise ValueError(f"worst must be between 0 and {MAX_WORST}")
    pred = to_array(predictions, "predictions")
    true = to_array(targets, "targets")
    if pred.shape != true.shape:
        raise ValueError(f"predictions and targets have different shapes: {pred.shape} and "
                         f"{true.shape}")
    if pred.ndim < 2:
        raise ValueError("predictions need a sample axis and at least one more")
    pred = np.moveaxis(pred, sample_axis, 0)
    true = np.moveaxis(true, sample_axis, 0)
    count = pred.shape[0]
    p = pred.reshape(count, -1)
    t = true.reshape(count, -1)
    finite = np.isfinite(p) & np.isfinite(t)
    diverged = ~finite.all(axis=1) & ~np.isfinite(p).any(axis=1)  # Nothing finite at all.
    error = np.where(finite, p - t, 0.0)
    norms = np.linalg.norm(np.where(finite, t, 0.0), axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.linalg.norm(error, axis=1) / norms
    rel[diverged | (norms == 0)] = math.nan
    known = rel[np.isfinite(rel)]
    stats: Dict[str, float] = {"nonFinite": float(count - known.size)}
    if known.size:
        stats.update(
            mean=float(known.mean()),
            median=float(np.median(known)),
            p90=float(np.percentile(known, 90)),
            max=float(known.max()),
            min=float(known.min()),
        )
    histogram = None
    positive = known[known > 0]
    if positive.size:
        low, high = np.log10(positive.min()), np.log10(positive.max())
        if high - low < 1e-9:
            low, high = low - 0.5, high + 0.5
        counts, edges = np.histogram(np.log10(positive), bins=HISTOGRAM_BINS, range=(low, high))
        histogram = {"edges": [float(10**e) for e in edges], "counts": [int(c) for c in counts]}
    # Worst first; a sample with no finite error at all (diverged) counts as worst.
    order = sorted(range(count), key=lambda i: -math.inf if not math.isfinite(rel[i]) else -rel[i])
    worst_samples = []
    worst_fields = []
    for rank, index in enumerate(order[:worst], start=1):
        value = float(rel[index])
        worst_samples.append({"rank": rank, "sample": index, "relL2": value})
        event, _ = field_event(f"worst/{name}/{rank}", pred[index], true[index],
                               max_size=max_size, extent=extent, axes=axes)
        event.update(kind="worst", layer=f"{name} #{rank}", position=rank, sample=index,
                     worstOf=name)
        worst_fields.append(event)
    body = {"name": name, "count": count, "stats": stats, "histogram": histogram,
            "worst": worst_samples}
    return body, worst_fields


# Curves: error against resolution, a PDE parameter, ... ---------------------------

MAX_CURVE_POINTS = 1000


def curve_event(name: str, x: Sequence[Any], y: Sequence[Any], *, x_label: str, y_label: str,
                train_range: Optional[Sequence[float]]) -> dict:
    xs = [to_float_or_nan(v) for v in x]
    ys = [to_float_or_nan(v) for v in y]
    if len(xs) != len(ys):
        raise ValueError(f"x has {len(xs)} values and y {len(ys)}")
    if not 1 <= len(xs) <= MAX_CURVE_POINTS:
        raise ValueError(f"a curve needs 1 to {MAX_CURVE_POINTS} points")
    if any(not math.isfinite(v) for v in xs):
        raise ValueError("x values must be finite numbers")
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    body = {"name": name, "x": [xs[i] for i in order], "y": [ys[i] for i in order],
            "xLabel": str(x_label)[:60], "yLabel": str(y_label)[:60]}
    if train_range is not None:
        low, high = (float(v) for v in train_range)
        body["trainRange"] = [min(low, high), max(low, high)]
    return body


def to_float_or_nan(value: Any) -> float:
    if hasattr(value, "item"):
        value = value.item()
    try:
        return float(value)
    except (TypeError, ValueError):
        raise TypeError(f"expected a number, not {type(value).__name__}") from None


# Learned Fourier weights ------------------------------------------------------------


def fourier_weight_events(model, *, max_size: int) -> List[dict]:
    """A "field" event body per complex-valued parameter with 3 or more
    axes (the spectral weights of FNO-style layers: in x out x modes...):
    |w| averaged over the two channel axes, as a 1D-3D map over the modes."""
    np = _numpy()
    events = []
    for position, (name, param) in enumerate(
        (n, p) for n, p in model.named_parameters() if p.is_complex() and p.ndim >= 3
    ):
        magnitude = param.detach().abs().float().cpu().numpy()
        channels = magnitude.shape[:2] if magnitude.ndim >= 4 else magnitude.shape[:1]
        modes = magnitude.reshape(-1, *magnitude.shape[len(channels):]).mean(axis=0)
        if modes.ndim > 3:
            continue
        event, _ = field_event(f"weights/{name}", modes, max_size=max_size, spectrum=False)
        event.update(kind="weights", layer=name, position=position,
                     reduction=f"mean |w| over {' × '.join(map(str, channels))} channels",
                     layerShape=list(param.shape))
        events.append(event)
    return events
