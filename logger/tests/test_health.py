from __future__ import annotations

import math

import pytest

import soliton
from soliton._health import HealthCheck, is_grad_norm, is_training_loss

from test_logger import offline, records


def feed(check, name, values, start=0):
    problems = []
    for i, value in enumerate(values):
        problems += check.check({name: value}, start + i)
    return problems


def falling(n, start=2.0, end=0.1):
    return [start * (end / start) ** (i / (n - 1)) for i in range(n)]


def test_which_names_are_checked():
    assert is_training_loss("train/loss") and is_training_loss("loss") and is_training_loss("train/mse_loss")
    assert not is_training_loss("val/loss") and not is_training_loss("test_loss")
    assert not is_training_loss("eval-loss") and not is_training_loss("train/accuracy")
    assert is_grad_norm("optim/grad_norm") and is_grad_norm("grad-norm") and is_grad_norm("gradnorm")
    assert not is_grad_norm("optim/lr")


def test_a_nan_loss_is_reported_once():
    check = HealthCheck()
    assert check.check({"train/loss": 0.5}, 0) == []
    assert check.check({"train/loss": math.nan}, 1) == [("nan", "train/loss is NaN at step 1")]
    assert check.check({"val/loss": math.inf}, 2) == [], "once per run"


def test_a_nan_validation_loss_counts_too():
    assert HealthCheck().check({"val/loss": -math.inf}, 7) == [("nan", "val/loss is -infinite at step 7")]


def test_a_loss_that_keeps_falling_is_healthy():
    assert feed(HealthCheck(), "train/loss", falling(500)) == []


def test_a_noisy_loss_is_healthy():
    noisy = [v * (1.6 if i % 3 == 0 else 0.7) for i, v in enumerate(falling(300))]
    assert feed(HealthCheck(), "train/loss", noisy) == []


def test_a_loss_back_where_it_started_has_diverged():
    values = falling(100) + [2.5] * 20
    problems = feed(HealthCheck(), "train/loss", values)
    assert [kind for kind, _ in problems] == ["divergence"]
    assert "climbed back up to 2.5" in problems[0][1] and "from a low of 0.1" in problems[0][1]


def test_a_loss_ten_times_its_lowest_has_diverged():
    values = [1.0] * 40 + [0.9] * 40 + [9.5] * 10  # Never halved, but 10x its low.
    assert [kind for kind, _ in feed(HealthCheck(), "train/loss", values)] == ["divergence"]


def test_a_single_spike_isnt_divergence():
    values = falling(100) + [50.0] + [0.1] * 20
    assert feed(HealthCheck(), "train/loss", values) == []


def test_a_rising_validation_loss_is_overfitting_not_divergence():
    assert feed(HealthCheck(), "val/loss", falling(100) + [3.0] * 30) == []


def test_a_negative_loss_is_left_alone():
    assert feed(HealthCheck(), "train/loss", [-5.0 + i * 0.01 for i in range(200)] + [9.0] * 20) == []


def test_a_gradient_norm_that_stays_huge_has_blown_up():
    values = [1.0] * 30 + [50.0] * 5
    problems = feed(HealthCheck(), "optim/grad_norm", values)
    assert problems == [("gradient", "optim/grad_norm blew up: 50 at step 34, more than 10 times "
                                     "its usual 1 since step 30")]


def test_gradient_spikes_and_skipped_steps_are_fine():
    values = ([1.0] * 30 + [80.0, math.inf, 1.1, 1.0] * 20)
    assert feed(HealthCheck(), "optim/grad_norm", values) == []


def test_a_gradient_norm_nan_five_times_in_a_row_is_reported():
    problems = feed(HealthCheck(), "optim/grad_norm", [1.0] * 3 + [math.nan] * 5)
    assert problems == [("gradient", "optim/grad_norm has been NaN or infinite for 5 logs in a row, "
                                     "since step 3")]


def test_a_run_records_and_prints_what_it_sees(tmp_path, capsys):
    run = offline(tmp_path)
    run.log({"train/loss": 1.0})
    run.log({"train/loss": math.nan})
    run.finish()
    health = [r for r in records(run) if r["type"] == "health"]
    assert [(h["kind"], h["step"]) for h in health] == [("nan", 1)]
    assert "soliton: warning: train/loss is NaN at step 1" in capsys.readouterr().err
    assert records(run)[-1]["status"] == "finished", "it only warns by default"


def test_stop_on_divergence_ends_the_run_and_raises(tmp_path):
    run = offline(tmp_path, stop_on_divergence=True)
    run.log({"train/loss": 1.0})
    with pytest.raises(soliton.Diverged, match="train/loss is infinite at step 1"):
        run.log({"train/loss": math.inf})
    status = records(run)[-1]
    assert (status["status"], status["message"]) == ("crashed", "Diverged: train/loss is infinite at step 1")
    run.log({"train/loss": 1.0})  # Ended: ignored.


def test_health_checks_can_be_turned_off(tmp_path, monkeypatch):
    monkeypatch.setenv("SOLITON_HEALTH", "0")
    run = offline(tmp_path, stop_on_divergence=True)
    run.log({"train/loss": math.nan})
    run.finish()
    assert [r for r in records(run) if r["type"] == "health"] == []


def test_simulations_keep_their_own_divergence_check(tmp_path):
    sim = soliton.simulate("kh", mode="offline", dir=str(tmp_path), host="test", system_metrics=False)
    sim.log({"loss": math.nan}, t=0.1)
    assert [r["type"] for r in records(sim)].count("health") == 0
    assert records(sim)[-1]["status"] == "crashed"
