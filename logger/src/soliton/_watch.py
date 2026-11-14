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


def layer_kind(module) -> str:
    """What a module does, for the app's network diagram: "linear", "conv",
    "embedding", "recurrent" and "attention" are drawn as layers; "norm",
    "activation", "dropout", "pool" and "reshape" are noted on the layer
    before them; "other" is drawn as a layer if it has parameters."""
    import torch.nn as nn

    m = nn.modules
    norms = tuple(cls for cls in (
        m.batchnorm._BatchNorm, m.instancenorm._InstanceNorm, nn.GroupNorm, nn.LayerNorm,
        nn.LocalResponseNorm, getattr(nn, "RMSNorm", None),
    ) if cls is not None)
    if isinstance(module, m.conv._ConvNd):
        return "conv"
    if isinstance(module, (nn.Linear, nn.Bilinear)):
        return "linear"
    if isinstance(module, (nn.Embedding, nn.EmbeddingBag)):
        return "embedding"
    if isinstance(module, (m.rnn.RNNBase, m.rnn.RNNCellBase)):
        return "recurrent"
    if isinstance(module, nn.MultiheadAttention):
        return "attention"
    if isinstance(module, norms):
        return "norm"
    if isinstance(module, m.dropout._DropoutNd):
        return "dropout"
    if isinstance(module, (nn.Flatten, nn.Unflatten)):
        return "reshape"
    defined_in = type(module).__module__
    if defined_in == "torch.nn.modules.activation":
        return "activation"
    if defined_in == "torch.nn.modules.pooling":
        return "pool"
    return "other"


def _in_width(module) -> Optional[int]:
    """How many features or channels a layer takes, if it says."""
    for attribute in ("in_features", "in_channels", "input_size", "embed_dim", "in1_features"):
        value = getattr(module, attribute, None)
        if isinstance(value, int) and not isinstance(value, bool):
            return value
    return None


def _traced_modules(model) -> List[Tuple[str, Any]]:
    """The modules the diagram shows: leaves, plus attention modules as a
    whole (they don't call their own sub-layers' forward)."""
    import torch.nn as nn

    if next(model.children(), None) is None:
        return [(type(model).__name__, model)]
    traced, inside = [], []
    for name, module in model.named_modules():
        if not name or any(name.startswith(prefix) for prefix in inside):
            continue
        if isinstance(module, nn.MultiheadAttention):
            traced.append((name, module))
            inside.append(name + ".")
        elif next(module.children(), None) is None:
            traced.append((name, module))
    return traced


def _units(tensor, conv_like: bool, batch_first: bool = True) -> Tuple[List[int], Optional[int]]:
    """A layer output's shape without the batch dimension, and its width
    (channels or features)."""
    shape = list(tensor.shape)
    if not shape:
        return [], None
    width = shape[_channel_dim(conv_like, len(shape))] if len(shape) >= 2 else shape[0]
    batch_dim = 1 if not batch_first and len(shape) >= 3 else 0
    del shape[batch_dim]
    return [int(n) for n in shape], int(width)


class _Tracer:
    """Records, on the model's next forward pass, which layers run in which
    order and the shape of what each one returns. Then removes itself."""

    MAX_LAYERS = 2000

    def __init__(self, model, on_done: Callable[[dict], None]) -> None:
        self._on_done = on_done
        self._modules = _traced_modules(model)
        self._layers: List[dict] = []
        self._input: Optional[dict] = None
        # The layers' hooks first: when the model is a single layer, its own
        # output must be recorded before _end runs.
        self._handles = [
            module.register_forward_hook(self._record(name, module))
            for name, module in self._modules
        ]
        self._handles.append(model.register_forward_pre_hook(self._start))
        self._handles.append(model.register_forward_hook(self._end))

    def _start(self, _model, inputs) -> None:
        self._layers = []  # Also discards a pass that failed halfway.
        tensor = _first_tensor(inputs)
        if tensor is None:
            self._input = None
            return
        shape, _ = _units(tensor, conv_like=False)
        self._input = {"shape": shape, "tokens": not tensor.is_floating_point()}

    def _record(self, name: str, module) -> Callable:
        kind = layer_kind(module)
        conv_like = kind == "conv" or _is_conv_like(module)
        batch_first = getattr(module, "batch_first", True) is not False
        parameters = int(sum(p.numel() for p in module.parameters()))

        def hook(_mod, _inputs, output) -> None:
            tensor = _first_tensor(output)
            if tensor is None or len(self._layers) >= self.MAX_LAYERS:
                return
            shape, width = _units(tensor, conv_like, batch_first)
            self._layers.append({
                "name": name, "type": type(module).__name__, "kind": kind,
                "shape": shape, "width": width, "parameters": parameters,
            })

        return hook

    def _end(self, _model, _inputs, _output) -> None:
        self.remove()
        flow = {"input": self._input, "flow": self._layers}
        if self._input is not None:
            first = next((m for n, m in self._modules if n == self._first_layer()), None)
            width = _in_width(first) if first is not None else None
            if width is None and not self._input["tokens"] and self._input["shape"]:
                width = self._input["shape"][0 if len(self._input["shape"]) >= 3 else -1]
            self._input["width"] = width
        self._on_done(flow)

    def _first_layer(self) -> Optional[str]:
        drawn = ("linear", "conv", "embedding", "recurrent", "attention")
        for layer in self._layers:
            if layer["kind"] in drawn or (layer["kind"] == "other" and layer["parameters"]):
                return layer["name"]
        return None

    def remove(self) -> None:
        for handle in self._handles:
            handle.remove()
        self._handles.clear()


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
            f"soliton: the model has {len(selected)} layers with parameters; watching "
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
                 bins: int = 32, on_traced: Optional[Callable[[dict], None]] = None) -> None:
        """[on_traced]: called once, after the next forward pass, with the
        layers that ran (see _Tracer)."""
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
        self._tracer = _Tracer(model, on_traced) if on_traced is not None else None

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
        if self._tracer is not None:
            self._tracer.remove()
