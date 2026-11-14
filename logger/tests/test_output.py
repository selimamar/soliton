"""The job's output: what the script prints, kept with the run."""

from __future__ import annotations

import sys

import pytest

import soliton
from soliton import _output
from test_logger import offline, records


def output_lines(run):
    """The output records' lines, checking they number on from each other."""
    lines = []
    for record in records(run):
        if record["type"] == "output":
            assert record["start"] == len(lines)
            lines += record["lines"]
    return lines


def test_what_is_printed_still_shows_and_is_kept(tmp_path, capsys):
    run = offline(tmp_path)
    print("epoch 1: loss 0.5")
    print("warning: slow", file=sys.stderr)
    sys.stdout.write("no newline at the end")
    run.finish()
    shown = capsys.readouterr()
    assert "epoch 1: loss 0.5" in shown.out and "warning: slow" in shown.err
    assert output_lines(run) == ["epoch 1: loss 0.5", "warning: slow", "no newline at the end"]
    statuses = [r["type"] for r in records(run)][-2:]
    assert statuses == ["output", "status"], "the last lines come before the status"


def test_streams_are_given_back(tmp_path):
    before = sys.stdout, sys.stderr
    run = offline(tmp_path)
    assert sys.stdout is not before[0]
    assert sys.stdout.encoding == before[0].encoding, "the rest is the stream's"
    run.finish()
    assert (sys.stdout, sys.stderr) == before


def test_a_crash_sends_its_traceback(tmp_path):
    with pytest.raises(ZeroDivisionError):
        with offline(tmp_path) as run:
            print("starting")
            1 / 0
    lines = output_lines(run)
    assert lines[0] == "starting"
    assert lines[1] == "Traceback (most recent call last):"
    assert lines[-1] == "ZeroDivisionError: division by zero"
    assert records(run)[-1]["status"] == "crashed"


def test_progress_bars_and_colours_are_cleaned(tmp_path):
    run = offline(tmp_path)
    sys.stdout.write("\r 10%|#         |")
    sys.stdout.write("\r 50%|#####     |")
    sys.stdout.write("\r100%|##########|\n")
    print("\x1b[31mred\x1b[0m text")
    print("x" * 5000)
    run.finish()
    lines = output_lines(run)
    assert lines[:2] == ["100%|##########|", "red text"]
    assert len(lines[2]) == _output.MAX_LINE + 2 and lines[2].endswith(" …")


def test_too_much_output_at_once_keeps_the_latest(tmp_path, monkeypatch):
    monkeypatch.setattr(_output, "MAX_PENDING", 10)
    run = offline(tmp_path)
    for i in range(25):
        print(f"line {i}")
    run.finish()
    lines = output_lines(run)
    assert lines[0] == "… 15 lines not kept (too much output at once) …"
    assert lines[1:] == [f"line {i}" for i in range(15, 25)]


def test_lines_are_sent_while_it_runs(tmp_path):
    run = offline(tmp_path)
    print("first")
    run._output.flush()
    print("second")
    run.finish()
    batches = [r for r in records(run) if r["type"] == "output"]
    assert [(b["start"], b["lines"]) for b in batches] == [(0, ["first"]), (1, ["second"])]


def test_it_can_be_turned_off(tmp_path, monkeypatch):
    run = offline(tmp_path, capture_output=False)
    print("private")
    run.finish()
    assert output_lines(run) == []
    monkeypatch.setenv("SOLITON_CAPTURE_OUTPUT", "0")
    run = offline(tmp_path, name="other")
    print("private")
    run.finish()
    assert output_lines(run) == []
    sim = soliton.simulate("sim", mode="offline", dir=str(tmp_path), host="t",
                           system_metrics=False, capture_output=True)
    print("kept")
    sim.finish()
    assert output_lines(sim) == ["kept"]
