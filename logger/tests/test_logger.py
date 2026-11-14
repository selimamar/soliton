from __future__ import annotations

import functools
import json
import math
import warnings
from argparse import Namespace

import pytest

import soliton
from soliton._util import (
    count_samples,
    describe_loss,
    detect_host,
    encode_float,
    flatten_config,
    new_run_id,
    slugify,
)


def records(run):
    lines = (run.directory / "events.jsonl").read_text().splitlines()
    return [json.loads(line) for line in lines]


def offline(tmp_path, name="tiny", **kwargs):
    # No usage sampling unless asked: its records would land between the ones tests count.
    kwargs.setdefault("system_metrics", False)
    return soliton.init(name, mode="offline", dir=str(tmp_path), host="test", **kwargs)


# Helpers ----------------------------------------------------------------------


def test_non_finite_numbers_become_strings():
    assert [encode_float(v) for v in (1.5, math.nan, math.inf, -math.inf)] == [
        1.5, "NaN", "Infinity", "-Infinity"
    ]


def test_hyperparameters_are_flattened_to_strings():
    config = {"optim": {"lr": 3e-4, "betas": (0.9, 0.95)}, "amp": True, "layers": 12}
    assert flatten_config(config) == {
        "optim.lr": "0.0003", "optim.betas": "0.9, 0.95", "amp": "true", "layers": "12",
    }
    assert flatten_config(Namespace(batch_size=64)) == {"batch_size": "64"}


def test_run_ids_are_readable_and_valid():
    assert slugify("ResNet-50 / CIFAR 10") == "ResNet-50-CIFAR-10"
    run_id = new_run_id("my run")
    assert run_id.startswith("my-run-") and len(run_id) == len("my-run-") + 6


def test_the_host_is_detected(tmp_path):
    nowhere = tmp_path / "plain"  # No cloud vendor files.
    assert detect_host({"SLURM_CLUSTER_NAME": "sherlock"}, nowhere) == "Sherlock"
    assert detect_host({"SOLITON_HOST": "Lab box", "SLURM_CLUSTER_NAME": "sherlock"}) == "Lab box"
    assert detect_host({}, nowhere) != ""


@pytest.mark.parametrize("variable, platform", [
    ("MODAL_TASK_ID", "Modal"), ("RUNPOD_POD_ID", "RunPod"), ("COLAB_RELEASE_TAG", "Colab"),
    ("KAGGLE_KERNEL_RUN_TYPE", "Kaggle"), ("SM_TRAINING_ENV", "SageMaker"),
    ("AWS_BATCH_JOB_ID", "AWS Batch"),
])
def test_platforms_are_recognized_by_their_environment(tmp_path, variable, platform):
    assert detect_host({variable: "x"}, tmp_path) == platform
    assert detect_host({variable: "x", "SOLITON_HOST": "Mine"}, tmp_path) == "Mine"


def vendor(tmp_path, sys_vendor, product=""):
    dmi = tmp_path / "sys/class/dmi/id"
    dmi.mkdir(parents=True, exist_ok=True)
    (dmi / "sys_vendor").write_text(sys_vendor + "\n")
    (dmi / "product_name").write_text(product + "\n")
    return tmp_path


def test_cloud_machines_are_recognized_by_their_vendor(tmp_path):
    assert detect_host({}, vendor(tmp_path / "a", "Amazon EC2", "m7g.large")) == "AWS"
    assert detect_host({}, vendor(tmp_path / "g", "Google", "Google Compute Engine")) == "GCP"
    assert detect_host({}, vendor(tmp_path / "z", "Microsoft Corporation", "Virtual Machine")) == "Azure"
    assert detect_host({}, vendor(tmp_path / "s", "Microsoft Corporation", "Surface Laptop")) != "Azure"
    # A Kubernetes pod on GKE: the cloud says more than "Kubernetes".
    k8s = {"KUBERNETES_SERVICE_HOST": "10.0.0.1"}
    assert detect_host(k8s, vendor(tmp_path / "k", "Google", "Google Compute Engine")) == "GCP"
    assert detect_host(k8s, tmp_path / "none") == "Kubernetes"


class DataLoader:
    """Looks like torch.utils.data.DataLoader: its length is the number of
    batches, its dataset's length the number of samples."""

    def __init__(self, dataset, batch_size):
        self.dataset, self.batch_size = dataset, batch_size

    def __len__(self):
        return math.ceil(len(self.dataset) / self.batch_size)


def test_samples_are_counted_from_numbers_datasets_and_loaders():
    assert count_samples(50_000) == 50_000
    assert count_samples(list(range(300))) == 300
    assert count_samples(DataLoader(list(range(300)), batch_size=64)) == 300, "samples, not batches"
    with pytest.raises(TypeError, match="pass the number"):
        count_samples(iter([1, 2]))
    with pytest.raises(TypeError):
        count_samples(True)


def cross_entropy(logits, targets, label_smoothing=0.0):
    return 0.0


def test_losses_are_described_by_name():
    assert describe_loss("Dice + BCE") == "Dice + BCE"
    assert describe_loss(cross_entropy) == "cross_entropy"
    assert describe_loss(functools.partial(cross_entropy, label_smoothing=0.1)) == (
        "cross_entropy(label_smoothing=0.1)"
    )

    class FocalLoss:
        gamma = 2

    assert describe_loss(FocalLoss()) == "FocalLoss"


# Runs -------------------------------------------------------------------------


def test_an_offline_run_is_saved_to_disk(tmp_path):
    run = offline(tmp_path, config={"lr": 0.1}, total_steps=10, total_epochs=2)
    run.log({"train/loss": 1.0}, step=0, epoch=0)
    run.log({"train/loss": float("nan"), "bad": "text"})  # step 1; "bad" is skipped
    run.finish()

    first, m0, m1, status = records(run)
    assert first["type"] == "run" and first["id"] == run.id
    assert first["hyperparameters"] == {"lr": "0.1"}
    assert (first["totalSteps"], first["totalEpochs"], first["host"]) == (10, 2, "test")
    assert m0 == {"type": "metrics", "step": 0, "time": m0["time"], "values": {"train/loss": 1.0}, "epoch": 0}
    assert m1["step"] == 1 and m1["values"] == {"train/loss": "NaN"} and m1["epoch"] == 0
    assert status["type"] == "status" and status["status"] == "finished"


def test_the_data_and_loss_come_first_among_the_hyperparameters(tmp_path):
    run = offline(tmp_path, config={"Optimizer": "AdamW", "Loss": "ignored"},
                  train_samples=DataLoader(list(range(50_000)), batch_size=256),
                  val_samples=10_000, loss="CrossEntropyLoss")
    run.finish()
    assert list(records(run)[0]["hyperparameters"].items()) == [
        ("Training samples", "50,000"),
        ("Validation samples", "10,000"),
        ("Loss", "CrossEntropyLoss"),
        ("Optimizer", "AdamW"),
    ]


def test_tags_and_notes_are_cleaned_up_as_the_server_takes_them(tmp_path):
    run = offline(tmp_path, tags=[" baseline ", "", "Baseline", "x" * 50] + [f"t{i}" for i in range(30)],
                  notes="first try")
    run.finish()
    description = records(run)[0]
    assert description["tags"][:3] == ["baseline", "x" * 40, "t0"]
    assert len(description["tags"]) == 20
    assert description["notes"] == "first try"
    run = offline(tmp_path, name="one", tags="sweep")
    run.finish()
    assert records(run)[0]["tags"] == ["sweep"], "a single string is one tag"


def test_uncountable_samples_are_left_out_with_a_warning(tmp_path):
    with pytest.warns(UserWarning, match="training samples: can't count"):
        run = offline(tmp_path, train_samples=iter(range(10)))
    run.finish()
    assert records(run)[0]["hyperparameters"] == {}


def test_without_data_or_loss_only_the_config_is_listed(tmp_path):
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        run = offline(tmp_path, config={"Batch size": 64})
    run.finish()
    assert records(run)[0]["hyperparameters"] == {"Batch size": "64"}


def test_finishing_twice_and_logging_after_finish_are_ignored(tmp_path):
    run = offline(tmp_path)
    run.finish()
    run.finish("crashed")
    run.log({"x": 1})
    assert [r["type"] for r in records(run)] == ["run", "status"]


def test_an_exception_marks_the_run_crashed(tmp_path):
    with pytest.raises(ValueError):
        with offline(tmp_path) as run:
            raise ValueError("CUDA out of memory\nmore details")
    status = records(run)[-1]
    assert status["status"] == "crashed"
    assert status["message"] == "ValueError: CUDA out of memory"


def test_disabled_runs_do_nothing(tmp_path):
    run = soliton.init("x", mode="disabled", dir=str(tmp_path))
    run.log({"x": 1})
    run.finish()
    assert not any(tmp_path.iterdir())


def test_online_mode_needs_a_server_and_token(tmp_path, monkeypatch):
    monkeypatch.delenv("SOLITON_SERVER", raising=False)
    monkeypatch.delenv("SOLITON_TOKEN", raising=False)
    with pytest.raises(ValueError, match="server and a token"):
        soliton.init("x", mode="online", dir=str(tmp_path))


# Field snapshots --------------------------------------------------------------

np = pytest.importorskip("numpy")


def decode_field(record, key="prediction"):
    import base64

    from soliton._fields import LEVELS, NAN_CODE

    codes = np.frombuffer(base64.b64decode(record[key]), dtype="<u2").reshape(record["shape"])
    values = record["min"] + codes / LEVELS * (record["max"] - record["min"])
    return np.where(codes == NAN_CODE, np.nan, values)


def test_a_field_snapshot_round_trips_through_16_bits(tmp_path):
    x, y = np.meshgrid(np.linspace(0, 1, 40), np.linspace(0, 1, 30))
    target = np.sin(2 * np.pi * x) * np.cos(np.pi * y)
    prediction = target + 0.01
    with offline(tmp_path) as run:
        run.log({"train/loss": 1.0}, step=7)
        run.log_field("u", prediction[None, None], target)  # Batch and channel dims dropped.
    record = [r for r in records(run) if r["type"] == "field"][0]
    assert record["step"] == 7, "the latest step"
    assert record["shape"] == [30, 40] == record["originalShape"]
    assert record["min"] == pytest.approx(target.min())
    assert record["max"] == pytest.approx(prediction.max())
    step = (record["max"] - record["min"]) / 65534
    assert np.abs(decode_field(record) - prediction).max() <= step
    assert np.abs(decode_field(record, "target") - target).max() <= step
    stats = record["stats"]
    assert stats["rmse"] == pytest.approx(0.01)
    assert stats["maxError"] == pytest.approx(0.01)
    assert stats["relL2"] == pytest.approx(0.01 / np.sqrt(np.mean(target**2)))


def test_big_fields_are_averaged_down_but_errors_use_the_full_grid(tmp_path):
    target = np.zeros((300, 256))
    prediction = np.zeros((300, 256))
    prediction[0, 0] = 1.0  # One bad point: averaged away, but not from maxError.
    with offline(tmp_path) as run:
        run.log_field("p", prediction, target, step=3, max_size=128)
    record = [r for r in records(run) if r["type"] == "field"][0]
    assert record["shape"] == [100, 128]  # Blocks of 3 x 2 points.
    assert record["originalShape"] == [300, 256]
    assert record["stats"]["maxError"] == 1.0
    assert decode_field(record).max() == pytest.approx(1 / 6, abs=1e-4)


def test_a_field_without_target_and_with_nan(tmp_path):
    values = np.array([0.0, np.nan, 2.0, np.inf])
    with offline(tmp_path) as run:
        run.log_field("u(x)", values, step=0)
    record = [r for r in records(run) if r["type"] == "field"][0]
    assert record["target"] is None and record["stats"] == {}
    decoded = decode_field(record)
    assert decoded[0] == 0 and decoded[2] == pytest.approx(2)
    assert np.isnan(decoded[1]) and np.isnan(decoded[3])
    json.dumps(record, allow_nan=False)


def test_fields_from_pytorch(tmp_path):
    torch = pytest.importorskip("torch")
    target = torch.randn(1, 16, 16)
    prediction = (target + 0.1).requires_grad_()
    with offline(tmp_path) as run:
        run.log_field("u", prediction, target, step=0)
    record = [r for r in records(run) if r["type"] == "field"][0]
    assert record["shape"] == [16, 16]
    assert record["stats"]["rmse"] == pytest.approx(0.1, rel=1e-4)


@pytest.mark.parametrize("prediction, target, message", [
    (np.zeros((2, 3, 4, 5)), None, "1D, 2D or 3D"),
    (np.zeros((4, 4)), np.zeros((4, 5)), "different shapes"),
    (np.zeros(0), None, "empty"),
    ("text", None, "expected an array"),
])
def test_fields_that_cannot_be_shown_are_refused(tmp_path, prediction, target, message):
    with offline(tmp_path) as run:
        with pytest.raises((ValueError, TypeError), match=message):
            run.log_field("u", prediction, target)


def field_records(run):
    return [r for r in records(run) if r["type"] == "field"]


def decode_frames(record, key="prediction"):
    values = decode_field({**record, "shape": [record["frames"], *record["shape"]]}, key)
    return values


def test_a_rollout_keeps_its_frames_times_and_errors_per_frame(tmp_path):
    x = np.linspace(0, 1, 50)
    t = np.linspace(0, 2, 10)
    target = np.sin(2 * np.pi * (x[None, :] - t[:, None]))       # [time, x]
    prediction = target + 0.01 * t[:, None]                        # Error grows with time.
    with offline(tmp_path) as run:
        run.log_rollout("u", prediction[:, None], target[:, None], step=4, times=t)
    record = field_records(run)[0]
    assert (record["frames"], record["shape"]) == (10, [50])
    assert record["times"] == pytest.approx(list(t))
    errors = record["frameStats"]["relL2"]
    assert len(errors) == 10 and errors[0] == 0 and errors == sorted(errors)
    assert record["stats"]["maxError"] == pytest.approx(0.02)
    assert np.abs(decode_frames(record) - prediction).max() < 1e-3


def test_a_rollout_with_time_last_and_too_many_frames(tmp_path):
    field = np.random.default_rng(0).random((16, 16, 300))  # [x, y, time]
    with offline(tmp_path) as run:
        run.log_rollout("w", field, field, time_axis=-1, max_frames=20)
    record = field_records(run)[0]
    assert record["shape"] == [16, 16]
    assert record["frames"] == 20
    assert record["times"][0] == 0 and record["times"][-1] == 299, "first and last kept"
    with pytest.raises(ValueError, match="times has 3 entries"):
        run2 = offline(tmp_path, name="other")
        run2.log_rollout("w", field, times=[0, 1, 2], time_axis=-1)


def test_3d_fields_are_averaged_down_to_128_per_axis(tmp_path):
    rng = np.random.default_rng(1)
    target = rng.random((200, 96, 64))
    with offline(tmp_path) as run:
        run.log_field("p", target + 0.1, target, step=0)
        run.log_field("small", target, step=0, max_points=32 ** 3)
    full, small = field_records(run)
    assert full["shape"] == [100, 96, 64]
    assert full["originalShape"] == [200, 96, 64]
    assert full["stats"]["rmse"] == pytest.approx(0.1)
    assert decode_field(full).shape == (100, 96, 64)
    assert np.prod(small["shape"]) <= 32 ** 3
    with pytest.raises(ValueError, match="max_points"):
        run2 = offline(tmp_path, name="other")
        run2.log_field("p", target, max_points=1 << 25)


def test_snapshots_stay_under_the_server_limit():
    from soliton._fields import MAX_POINTS, shrink

    small = shrink(np.zeros((4, 64, 64, 64)), 64, first_axis=1, max_points=4 * 32 ** 3)
    assert small.shape == (4, 32, 32, 32)
    assert np.prod(shrink(np.zeros((300, 300)), 512).shape) <= MAX_POINTS


def test_names_for_layers_are_kept_apart(tmp_path):
    with offline(tmp_path) as run:
        with pytest.raises(ValueError, match="layers/"):
            run.log_field("layers/x", np.zeros(4))


@pytest.mark.parametrize("shape, axis", [
    ([32, 64, 64], 0),        # Channels-first (Conv2d).
    ([64, 64, 32], 2),        # Channels-last (Linear on a grid).
    ([64, 64, 1], 2),         # One channel, last.
    ([1, 64, 64], 0),
    ([16, 128], 0),           # 1D, channels-first: the shorter axis.
    ([128, 16], 1),
    ([8, 32, 32, 32], 0),     # 3D, channels-first.
    ([100], None),            # Just features.
])
def test_the_channel_axis_is_guessed_from_the_shape(shape, axis):
    from soliton._fields import channel_axis

    assert channel_axis(shape) == axis


class TinyFNO:
    """Built lazily: torch is optional."""

    @staticmethod
    def make():
        torch = pytest.importorskip("torch")
        from torch import nn

        class Block(nn.Module):
            def __init__(self):
                super().__init__()
                self.w = nn.Conv2d(8, 8, 1)

            def forward(self, x):
                return torch.relu(self.w(x))

        class Net(nn.Module):
            def __init__(self):
                super().__init__()
                self.lifting = nn.Linear(3, 8)
                self.blocks = nn.ModuleList([Block(), Block()])
                self.projection = nn.Linear(8, 1)

            def forward(self, x):  # [batch, H, W, 3] -> [batch, H, W, 1]
                x = self.lifting(x).permute(0, 3, 1, 2)
                for block in self.blocks:
                    x = block(x)
                return self.projection(x.permute(0, 2, 3, 1))

        return torch, Net()


def test_capture_layers_records_each_layer_in_order(tmp_path):
    torch, net = TinyFNO.make()
    with offline(tmp_path) as run:
        with run.capture_layers(net, step=9):
            out = net(torch.randn(4, 24, 24, 3))
    layers = field_records(run)
    assert [r["name"] for r in layers] == [
        "layers/lifting", "layers/blocks.0", "layers/blocks.1", "layers/projection"
    ]
    assert [r["position"] for r in layers] == [0, 1, 2, 3]
    assert {r["kind"] for r in layers} == {"layer"}
    lifting, block, _, projection = layers
    assert lifting["layerShape"] == [24, 24, 8] and lifting["reduction"] == "mean of 8 channels"
    assert block["layerShape"] == [8, 24, 24] and block["shape"] == [24, 24]
    assert projection["reduction"] == "1 channel"
    assert projection["target"] is None and projection["step"] == 9
    # The projection's field is the model's output for the first sample.
    assert np.abs(decode_field(projection) - out[0, :, :, 0].detach().numpy()).max() < 1e-3
    assert all(not m._forward_hooks for m in net.modules()), "hooks are removed"


def test_capture_layers_by_name_and_channel_axis(tmp_path):
    torch, net = TinyFNO.make()
    with offline(tmp_path) as run:
        with run.capture_layers(net, layers=["blocks.1.w"], channel_axis=0, reduce="norm"):
            net(torch.randn(1, 8, 8, 3))
        with pytest.raises(ValueError, match="no such layers"):
            with run.capture_layers(net, layers=["nope"]):
                pass
    (record,) = field_records(run)
    assert record["layer"] == "blocks.1.w"
    assert record["reduction"] == "norm over 8 channels"


# Validation sets, curves, spectra, physics, domains, Fourier weights, PDE -----


def test_a_whole_validation_set_and_its_worst_samples(tmp_path):
    rng = np.random.default_rng(3)
    targets = rng.random((60, 1, 16, 16)) + 1
    noise = np.linspace(0.001, 0.1, 60)[:, None, None, None]   # Sample 59 is worst.
    predictions = targets * (1 + noise)                          # Relative L2 = noise, exactly.
    predictions[13] = np.nan                                     # Diverged: worst of all.
    with offline(tmp_path) as run:
        run.log_eval("u", predictions, targets, step=8, worst=3)
    evals = [r for r in records(run) if r["type"] == "eval"]
    worst = [r for r in field_records(run) if r["kind"] == "worst"]
    (summary,) = evals
    assert summary["count"] == 60 and summary["step"] == 8
    assert summary["stats"]["nonFinite"] == 1
    assert [w["sample"] for w in summary["worst"]][:2] == [13, 59]
    assert summary["worst"][0]["relL2"] == "NaN", "as JSON allows"
    assert sum(summary["histogram"]["counts"]) == 59
    assert summary["stats"]["median"] < summary["stats"]["p90"] < summary["stats"]["max"]
    assert [w["name"] for w in worst] == ["worst/u/1", "worst/u/2", "worst/u/3"]
    assert worst[1]["sample"] == 59 and worst[1]["worstOf"] == "u"
    assert worst[1]["shape"] == [16, 16]
    json.dumps(records(run), allow_nan=False)


def test_curves_are_sorted_and_keep_the_training_range(tmp_path):
    with offline(tmp_path) as run:
        run.log_curve("error vs viscosity", [1e-2, 1e-4, 1e-3], [0.3, 0.2, 0.05],
                      x_label="Viscosity", train_range=(2e-3, 5e-4), step=2)
        with pytest.raises(ValueError, match="x has 2 values"):
            run.log_curve("bad", [1, 2], [1])
    (curve,) = [r for r in records(run) if r["type"] == "curve"]
    assert curve["x"] == [1e-4, 1e-3, 1e-2] and curve["y"] == [0.2, 0.05, 0.3]
    assert curve["trainRange"] == [5e-4, 2e-3] and curve["xLabel"] == "Viscosity"


def test_fields_carry_their_spectrum_and_domain(tmp_path):
    x = np.linspace(0, 1, 64, endpoint=False)
    xx, yy = np.meshgrid(x, x, indexing="ij")
    field = np.sin(2 * np.pi * 3 * xx) + 0.1 * np.sin(2 * np.pi * 10 * yy)
    with offline(tmp_path) as run:
        run.log_field("u", field, field, extent=[(0, 1), (0, 2)], axes=["y", "x"], step=0)
        with pytest.raises(ValueError, match="2 names"):
            run.log_field("u", field, axes=["x"])
    (record,) = field_records(run)
    assert record["extent"] == [[0.0, 1.0], [0.0, 2.0]] and record["axes"] == ["y", "x"]
    spectrum = record["spectrum"]
    assert spectrum["k"][:3] == [1.0, 2.0, 3.0] and len(spectrum["k"]) == 32
    peaks = sorted(range(32), key=lambda i: -spectrum["target"][i])[:2]
    assert sorted(spectrum["k"][i] for i in peaks) == [3.0, 10.0]
    assert spectrum["prediction"] == spectrum["target"]


def test_a_rollout_carries_mass_energy_and_minimum_per_frame(tmp_path):
    frames = np.stack([np.full((8, 8), 1.0 + t) for t in range(4)])
    with offline(tmp_path) as run:
        run.log_rollout("rho", frames * 1.01, frames, step=0)
    stats = field_records(run)[0]["frameStats"]
    assert stats["targetMean"] == [1.0, 2.0, 3.0, 4.0]
    assert stats["mean"] == pytest.approx([1.01, 2.02, 3.03, 4.04])
    assert stats["targetMeanSquare"] == [1.0, 4.0, 9.0, 16.0]
    assert stats["min"] == pytest.approx(stats["mean"])


def test_fourier_weights_are_mapped_over_the_modes(tmp_path):
    torch = pytest.importorskip("torch")

    class Spectral(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.weights1 = torch.nn.Parameter(torch.ones(4, 6, 5, 3, dtype=torch.cfloat) * 2)
            self.bias = torch.nn.Parameter(torch.zeros(3))

    with offline(tmp_path) as run:
        run.log_fourier_weights(torch.nn.Sequential(Spectral()), step=4)
    (record,) = field_records(run)
    assert record["kind"] == "weights" and record["layer"] == "0.weights1"
    assert record["shape"] == [5, 3] and record["layerShape"] == [4, 6, 5, 3]
    assert record["reduction"] == "mean |w| over 4 × 6 channels"
    assert decode_field(record) == pytest.approx(np.full((5, 3), 2.0), abs=1e-3)


def test_the_pde_leads_the_hyperparameters(tmp_path):
    run = offline(tmp_path, pde={"equation": "Darcy flow 2D", "resolution": "85 x 85",
                                 "coefficients": {"contrast": 12}},
                  config={"modes": 12})
    hyperparameters = records(run)[0]["hyperparameters"]
    assert list(hyperparameters)[:3] == ["PDE", "PDE resolution", "PDE coefficients contrast"]
    assert hyperparameters["PDE"] == "Darcy flow 2D"
    assert hyperparameters["modes"] == "12"
    run.finish()
