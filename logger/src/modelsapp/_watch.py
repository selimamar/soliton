"""Per-layer statistics from a PyTorch model, collected with hooks.

Every `every`-th training forward pass, each watched layer's output is
summarised on its device (mean, std, a histogram, the share of dead units);
at the next `run.log()`, the gradient norm of each layer's parameters is
added and everything is saved. Other forward passes cost one counter
increment. Only modules in training mode are measured, so evaluation
passes don't count.
"""

from __future__ import annotations

import warnings
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple, Union

from ._util import encode_float

LayerFilter = Union[Sequence[str], Callable[[str, Any], bool], None]


def architecture(model, max_depth: int = 8) -> dict:
    """The model's module tree, with parameter counts, as the app reads it.

    Below [max_depth], a module's descendants are folded into it.
    """

    def node(name: str, module, depth: int) -> dict:
        children = list(module.named_children())
        if depth >= max_depth and children:
            own = sum(p.numel() for p in module.parameters())
            children = []
        else:
            own = sum(p.numel() for p in module.parameters(recurse=False))
        return {
            "name": name,
            "type": type(module).__name__,
            "ownParameters": int(own),
            "children": [
                node(f"{name}.{child_name}" if depth > 0 else child_name, child, depth + 1)
                for child_name, child in children
            ],
        }

    return node(type(model).__name__, model, 0)


def _default_layers(model) -> List[Tuple[str, Any]]:
    """Modules that hold parameters themselves (Conv, Linear, norms, ...)."""
    return [
        (name, module)
        for name, module in model.named_modules()
        if name and next(module.parameters(recurse=False), None) is not None
    ]


def select_layers(model, layers: LayerFilter, max_layers: int) -> List[Tuple[str, Any]]:
    if layers is None:
        selected = _default_layers(model)
    elif callable(layers):
        selected = [(n, m) for n, m in model.named_modules() if n and layers(n, m)]
    else:
        wanted = set(layers)
        selected = [(n, m) for n, m in model.named_modules() if n in wanted]
        missing = wanted - {n for n, _ in selected}
        if missing:
            raise ValueError(f"no such layers in the model: {', '.join(sorted(missing))}")
    if len(selected) > max_layers:
        # Spread evenly over the model, always including the first and last.
        step = (len(selected) - 1) / (max_layers - 1)
        picked = sorted({round(i * step) for i in range(max_layers)})
        warnings.warn(
            f"modelsapp: the model has {len(selected)} layers with parameters; watching "
            f"{len(picked)} of them spread over the model (raise max_layers, or pass "
            "layers=[...], to choose)",
            stacklevel=3,
        )
        selected = [selected[i] for i in picked]
    return selected


def _is_conv_like(module) -> bool:
    import torch.nn as nn

    conv_like = (nn.modules.conv._ConvNd, nn.modules.batchnorm._BatchNorm,
                 nn.modules.instancenorm._InstanceNorm, nn.GroupNorm)
    return isinstance(module, conv_like)


def _channel_dim(conv_like: bool, rank: int) -> int:
    """Which output dimension holds the units: channels (dimension 1) for
    convolutions, norms over channels, and any image-like output (4D, 5D,
    e.g. a ReLU after a convolution); features (last) for everything else,
    e.g. Linear layers and transformer blocks (batch, tokens, features)."""
    if rank < 2:
        return -1
    return 1 if conv_like or rank >= 4 else -1


def _first_tensor(output):
    import torch

    if isinstance(output, torch.Tensor):
        return output
    if isinstance(output, (tuple, list)):
        for item in output:
            if isinstance(item, torch.Tensor):
                return item
    return None


def activation_stats(tensor, channel_dim: int, bins: int = 32) -> Optional[dict]:
    """Summary of one layer output. Non-finite values poison the mean and std
    (on purpose: that's the signal) but are left out of the histogram."""
    import torch

    if not tensor.is_floating_point() or tensor.numel() == 0:
        return None
    x = tensor.detach().float()
    flat = x.reshape(-1)
    mean = flat.mean()
    std = flat.std(correction=0)
    is_zero = flat == 0
    zero_count = is_zero.sum()
    values = flat[torch.isfinite(flat) & ~is_zero]
    if values.numel() > 0:
        low, high = values.min(), values.max()
        if bool(low == high):
            low, high = low - 0.5, high + 0.5
        counts = torch.histc(values, bins=bins, min=float(low), max=float(high))
    else:
        low = high = torch.zeros((), device=x.device)
        counts = torch.zeros(bins, device=x.device)

    if x.dim() >= 2:
        units = x.transpose(channel_dim, 0).reshape(x.shape[channel_dim], -1)
        dead = 1.0 - (units != 0).any(dim=1).float().mean()
    else:
        dead = (x == 0).all().float()

    # One transfer to the CPU for everything.
    summary = torch.stack([mean, std, zero_count.float(), low.float(), high.float(), dead]).tolist()
    return {
        "activationMean": encode_float(summary[0]),
        "activationStd": encode_float(summary[1]),
        "deadFraction": encode_float(summary[5]),
        "activationHistogram": {
            "min": encode_float(summary[3]),
            "max": encode_float(summary[4]),
            "counts": [int(c) for c in counts.tolist()],
            "zeroCount": int(summary[2]),
        },
    }


def grad_norm(module) -> Optional[float]:
    """L2 norm of the gradients of the module's own parameters, or None."""
    import torch

    grads = [p.grad.detach() for p in module.parameters(recurse=False) if p.grad is not None]
    if not grads:
        return None
    norms = torch.stack([torch.linalg.vector_norm(g.float()) for g in grads])
    return float(torch.linalg.vector_norm(norms))


class Watcher:
    def __init__(self, model, every: int, layers: LayerFilter = None, max_layers: int = 64,
                 bins: int = 32) -> None:
        if every < 1:
            raise ValueError("every must be at least 1")
        self._every = every
        self._bins = bins
        self._layers = select_layers(model, layers, max_layers)
        self._forwards = 0
        self._armed = False
        self._captured: Dict[str, dict] = {}
        self._handles = [model.register_forward_pre_hook(self._count)]
        for name, module in self._layers:
            self._handles.append(module.register_forward_hook(self._capture(name, module)))

    @property
    def layer_names(self) -> List[str]:
        return [name for name, _ in self._layers]

    def _count(self, module, _inputs) -> None:
        if module.training:
            self._armed = self._forwards % self._every == 0
            self._forwards += 1
        else:
            self._armed = False

    def _capture(self, name: str, module) -> Callable:
        conv_like = _is_conv_like(module)

        def hook(mod, _inputs, output) -> None:
            if not self._armed or not mod.training:
                return
            tensor = _first_tensor(output)
            if tensor is None:
                return
            channel_dim = _channel_dim(conv_like, tensor.dim())
            stats = activation_stats(tensor, channel_dim, self._bins)
            if stats is not None:
                self._captured[name] = stats

        return hook

    def collect(self) -> List[dict]:
        """Layers measured since the last call, with their gradient norms."""
        if not self._captured:
            return []
        layers = []
        for name, module in self._layers:
            stats = self._captured.get(name)
            if stats is None:
                continue
            norm = grad_norm(module)
            layers.append({
                "layerName": name,
                **stats,
                "gradNorm": None if norm is None else encode_float(norm),
            })
        self._captured.clear()
        return layers

    def remove(self) -> None:
        for handle in self._handles:
            handle.remove()
        self._handles.clear()
