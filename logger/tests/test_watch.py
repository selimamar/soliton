"""Logger tests that need PyTorch: run.watch() and tensor values."""

from __future__ import annotations

import json

import pytest

from modelsapp._util import to_float
from test_logger import offline, records

torch = pytest.importorskip("torch")
nn = torch.nn


def test_scalars_of_any_kind_become_floats():
    assert to_float(3) == 3.0
    assert to_float(torch.tensor(2.0)) == 2.0
    assert to_float(torch.tensor(0.5).numpy() if hasattr(torch, "numpy") else 0.5) == 0.5
    assert to_float(torch.tensor([1.0, 2.0])) is None
    assert to_float("1.0") is None
    assert to_float(True) is None



class TinyNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv = nn.Conv2d(1, 4, 3, padding=1)
        self.act = nn.ReLU()
        self.head = nn.Linear(4 * 8 * 8, 3)

    def forward(self, x):
        return self.head(self.act(self.conv(x)).flatten(1))


def test_the_architecture_tree_counts_parameters(tmp_path):
    model = TinyNet()
    run = offline(tmp_path)
    run.watch(model)
    run.finish()
    tree = records(run)[1]["architecture"]  # The description is saved again with the model.
    assert tree["name"] == "TinyNet" and tree["type"] == "TinyNet"
    assert [c["name"] for c in tree["children"]] == ["conv", "act", "head"]
    assert [c["ownParameters"] for c in tree["children"]] == [4 * 9 + 4, 0, 256 * 3 + 3]
    total = sum(c["ownParameters"] for c in tree["children"])
    assert total == sum(p.numel() for p in model.parameters())


def test_watching_records_layer_statistics_every_n_forward_passes(tmp_path):
    torch.manual_seed(0)
    model = TinyNet()
    with torch.no_grad():
        model.conv.bias[0] = -100.0  # Channel 0 is always negative: after ReLU, dead.
    run = offline(tmp_path)
    run.watch(model, every=2, layers=["conv", "act", "head"])
    x = torch.randn(5, 1, 8, 8)
    for step in range(4):
        model.zero_grad()
        model(x).sum().backward()
        run.log({"train/loss": 1.0}, step=step)
    run.finish()

    layer_events = [r for r in records(run) if r["type"] == "layers"]
    assert [e["step"] for e in layer_events] == [0, 2], "forward passes 1 and 3"
    conv, act, head = layer_events[0]["layers"]
    assert [l["layerName"] for l in (conv, act, head)] == ["conv", "act", "head"]

    histogram = act["activationHistogram"]
    assert len(histogram["counts"]) == 32
    assert sum(histogram["counts"]) + histogram["zeroCount"] == 5 * 4 * 8 * 8
    assert histogram["zeroCount"] >= 5 * 8 * 8  # The whole dead channel, at least.
    assert act["deadFraction"] == pytest.approx(0.25)  # 1 of 4 channels.
    assert act["gradNorm"] is None, "ReLU has no parameters"

    expected = torch.linalg.vector_norm(
        torch.stack([model.conv.weight.grad.norm(), model.conv.bias.grad.norm()])
    )
    assert conv["gradNorm"] == pytest.approx(float(expected), rel=1e-5)
    output = model.conv(x)
    assert conv["activationMean"] == pytest.approx(float(output.detach().mean()), rel=1e-4)


def test_evaluation_passes_are_not_measured(tmp_path):
    model = TinyNet()
    run = offline(tmp_path)
    run.watch(model, every=1)
    model.eval()
    with torch.no_grad():
        model(torch.randn(2, 1, 8, 8))
    run.log({"val/loss": 1.0}, step=0)
    run.finish()
    assert not [r for r in records(run) if r["type"] == "layers"]


def test_non_finite_activations_are_reported_not_hidden(tmp_path):
    model = nn.Sequential(nn.Linear(4, 4))
    with torch.no_grad():
        model[0].weight.fill_(float("inf"))
    run = offline(tmp_path)
    run.watch(model, every=1)
    model(torch.randn(3, 4)).sum().backward()
    run.log({"train/loss": float("inf")}, step=0)
    run.finish()
    [event] = [r for r in records(run) if r["type"] == "layers"]
    [layer] = event["layers"]
    assert layer["activationMean"] in ("NaN", "Infinity", "-Infinity")
    json.dumps(event, allow_nan=False)  # Still valid JSON.


def test_too_many_layers_are_spread_over_the_model(tmp_path):
    model = nn.Sequential(*[nn.Linear(2, 2) for _ in range(10)])
    run = offline(tmp_path)
    with pytest.warns(UserWarning, match="watching 4 of them"):
        run.watch(model, max_layers=4)
    assert run._watcher.layer_names == ["0", "3", "6", "9"]
    run.finish()


def test_unknown_layer_names_are_an_error(tmp_path):
    run = offline(tmp_path)
    with pytest.raises(ValueError, match="no such layers"):
        run.watch(TinyNet(), layers=["conv", "nope"])
    run.finish()
