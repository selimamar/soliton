from __future__ import annotations

import functools
import json
import math
import warnings
from argparse import Namespace

import pytest

import modelsapp
from modelsapp._util import (
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
    return modelsapp.init(name, mode="offline", dir=str(tmp_path), host="test", **kwargs)


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


def test_the_host_is_detected():
    assert detect_host({"SLURM_CLUSTER_NAME": "sherlock"}) == "Sherlock"
    assert detect_host({"MODELSAPP_HOST": "AWS", "SLURM_CLUSTER_NAME": "sherlock"}) == "AWS"
    assert detect_host({}) != ""


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
    run = modelsapp.init("x", mode="disabled", dir=str(tmp_path))
    run.log({"x": 1})
    run.finish()
    assert not any(tmp_path.iterdir())


def test_online_mode_needs_a_server_and_token(tmp_path, monkeypatch):
    monkeypatch.delenv("MODELSAPP_SERVER", raising=False)
    monkeypatch.delenv("MODELSAPP_TOKEN", raising=False)
    with pytest.raises(ValueError, match="server and a token"):
        modelsapp.init("x", mode="online", dir=str(tmp_path))
