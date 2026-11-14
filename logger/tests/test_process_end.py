"""How a run ends when its process ends, tested with real processes."""

from __future__ import annotations

import json
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest


def start(tmp_path: Path, body: str) -> subprocess.Popen:
    script = textwrap.dedent(f"""
        import time, soliton
        run = soliton.init("p", id="proc-run", mode="offline", dir={str(tmp_path)!r}, host="test")
        run.log({{"train/loss": 1.0}}, step=0)
        print("ready", flush=True)
    """) + textwrap.dedent(body)
    return subprocess.Popen(
        [sys.executable, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )


def last_status(tmp_path: Path) -> dict:
    lines = (tmp_path / "proc-run" / "events.jsonl").read_text().splitlines()
    return json.loads(lines[-1])


def test_a_script_that_simply_ends_is_finished(tmp_path):
    process = start(tmp_path, "")
    assert process.wait(30) == 0
    status = last_status(tmp_path)
    assert (status["type"], status["status"]) == ("status", "finished")


def test_an_uncaught_exception_marks_the_run_crashed(tmp_path):
    process = start(tmp_path, "raise RuntimeError('CUDA out of memory')")
    assert process.wait(30) == 1
    assert "RuntimeError: CUDA out of memory" in process.stderr.read(), "traceback still printed"
    status = last_status(tmp_path)
    assert (status["status"], status["message"]) == ("crashed", "RuntimeError: CUDA out of memory")


@pytest.mark.skipif(sys.platform == "win32", reason="no SIGTERM on Windows")
def test_sigterm_marks_the_run_crashed_and_still_ends_the_process(tmp_path):
    """What Slurm does at a time limit, or on scancel."""
    process = start(tmp_path, "time.sleep(60)")
    assert process.stdout.readline().strip() == "ready"
    time.sleep(0.2)
    process.send_signal(signal.SIGTERM)
    assert process.wait(30) == -signal.SIGTERM, "the signal still ends the process"
    status = last_status(tmp_path)
    assert status["status"] == "crashed"
    assert status["message"].startswith("Stopped by SIGTERM")


def test_a_script_with_its_own_sigterm_handler_keeps_it(tmp_path):
    process = subprocess.Popen(
        [sys.executable, "-c", textwrap.dedent(f"""
            import signal, sys, time, soliton
            signal.signal(signal.SIGTERM, lambda *_: (print("mine", flush=True), sys.exit(3)))
            run = soliton.init("p", id="proc-run", mode="offline", dir={str(tmp_path)!r}, host="t")
            print("ready", flush=True)
            time.sleep(60)
        """)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    assert process.stdout.readline().strip() == "ready"
    process.send_signal(signal.SIGTERM)
    assert process.wait(30) == 3
    assert "mine" in process.stdout.read()
