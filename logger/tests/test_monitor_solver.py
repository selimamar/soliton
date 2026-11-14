"""skills/soliton/scripts/monitor_solver.py: a program run unchanged and
reported as a simulation, from what it writes and prints."""

import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "skills" / "soliton" / "scripts" / "monitor_solver.py"

# Appends to a diagnostics table whose header numbers the columns (the time
# is column 3, not 1) and prints "it=... t=... residual=..." lines.
SOLVER = textwrap.dedent("""
    import math, os, sys, time
    mode, start = sys.argv[1], float(sys.argv[2])
    os.makedirs("out", exist_ok=True)
    with open("out/diagnostics.dat", "a") as f:
        f.write("# 1:iteration 2:level 3:time 4:energy\\n")
        for i in range(20):
            t = start + i * 0.5
            energy = float("nan") if mode == "nan" and i == 15 else 1 - 0.01 * i
            f.write(f"{i} 0 {t} {energy}\\n"); f.flush()
            print(f"it={i}  t={t:.3f}  residual={math.exp(-i / 5):.3e}", flush=True)
            time.sleep(0.01)
    if mode == "error":
        print("ERROR: bad things", flush=True)
    sys.exit(3 if mode == "crash" else 0)
""")


def run(tmp_path, mode, *extra, start=0.0):
    (tmp_path / "solver.py").write_text(SOLVER)
    env = {**os.environ, "PYTHONPATH": str(ROOT / "logger" / "src"),
           "SOLITON_MODE": "offline", "SOLITON_DIR": str(tmp_path / "runs")}
    env.pop("SOLITON_SERVER", None)
    command = [sys.executable, str(SCRIPT), "--name", f"fake-{mode}", "--t-end", "20",
               "--interval", "0.2", "--table", "out/*.dat,t=3,energy=4",
               "--stdout", r"t=(?P<t>[0-9.]+)\s+residual=(?P<residual>[0-9.e+-]+)",
               "--error", "^ERROR", *extra, "--", sys.executable, "solver.py", mode, str(start)]
    done = subprocess.run(command, cwd=tmp_path, env=env, capture_output=True, text=True,
                          timeout=60)
    return done


def records(tmp_path, prefix):
    [folder] = (tmp_path / "runs").glob(prefix + "*")
    return [json.loads(line) for line in (folder / "events.jsonl").read_text().splitlines()]


def points(recs):
    return [r for r in recs if r["type"] == "metrics" and "sim/t" in r["values"]]


def status(recs):
    return [r for r in recs if r["type"] == "status"][-1]


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX shell behaviour")
def test_values_from_files_and_output_are_merged_by_time(tmp_path):
    done = run(tmp_path, "ok")
    assert done.returncode == 0
    assert "t=9.500" in done.stdout, "the program's output passes through"
    recs = records(tmp_path, "fake-ok")
    rows = points(recs)
    assert len(rows) == 20
    assert all({"energy", "residual"} <= set(r["values"]) for r in rows)
    times = [r["values"]["sim/t"] for r in rows]
    assert times == sorted(times)
    assert status(recs)["status"] == "finished"
    run_record = next(r for r in recs if r["type"] == "run")
    assert "solver.py" in run_record["hyperparameters"]["command"]


def test_a_failing_exit_code_crashes_the_run_and_is_kept(tmp_path):
    done = run(tmp_path, "crash")
    assert done.returncode == 3
    message = status(records(tmp_path, "fake-crash"))["message"]
    assert message.startswith("python") and "exited with code 3: it=19  t=9.500" in message


def test_an_error_line_crashes_the_run_even_with_exit_code_0(tmp_path):
    assert run(tmp_path, "error").returncode == 0
    recs = records(tmp_path, "fake-error")
    assert (status(recs)["status"], status(recs)["message"]) == ("crashed", "ERROR: bad things")


def test_nan_marks_the_simulation_diverged(tmp_path):
    run(tmp_path, "nan")
    recs = records(tmp_path, "fake-nan")
    assert status(recs)["message"] == "Diverged at t = 7.5: energy is NaN"


def test_id_continues_a_run_in_a_later_job(tmp_path):
    run(tmp_path, "ok", "--id", "sim-1")
    run(tmp_path, "ok", "--id", "sim-1", start=5.0)  # Restarted from t = 5: overlaps 5..9.5.
    rows = points(records(tmp_path, "sim-1"))
    steps = [r["step"] for r in rows]
    times = [r["values"]["sim/t"] for r in rows]
    assert steps == sorted(set(steps)), "no step is reused"
    assert times == sorted(set(times)) and times[-1] == 14.5
    assert len(rows) == 30


H5_SOLVER = textwrap.dedent("""
    import sys, time
    import h5py, numpy as np
    layout = sys.argv[1]
    with h5py.File("stats.h5", "w", libver="latest") as f:
        if layout == "compound":
            kind = np.dtype([("time", "f8"), ("energy", "f8"), ("error_l2", "f8")])
            d = f.create_dataset("series", shape=(0,), maxshape=(None,), dtype=kind)
        else:
            d = f.create_dataset("series", shape=(0, 3), maxshape=(None, 3), dtype="f8")
            if layout == "legend":
                d.attrs["Legend"] = np.array([b"Time", b"Energy", b"L2 error"])
        for i in range(10):
            d.resize(i + 1, axis=0)
            row = (i * 0.5, 1.0 - 0.01 * i, 1e-3 * 2.0 ** -i)
            d[i] = np.array(row, dtype=d.dtype) if layout == "compound" else row
            f.flush(); time.sleep(0.01)
""")


@pytest.mark.parametrize("layout, columns", [
    ("compound", "t=time,energy=energy,error_l2=error_l2"),   # named fields
    ("legend", "t=Time,energy=Energy,error_l2=L2 error"),      # names in an attribute
    ("plain", "t=1,energy=2,error_l2=3"),                      # 1-based numbers
])
def test_hdf5_tables_in_any_common_layout(tmp_path, layout, columns):
    pytest.importorskip("h5py")
    (tmp_path / "h5_solver.py").write_text(H5_SOLVER)
    env = {**os.environ, "PYTHONPATH": str(ROOT / "logger" / "src"),
           "SOLITON_MODE": "offline", "SOLITON_DIR": str(tmp_path / "runs")}
    env.pop("SOLITON_SERVER", None)
    subprocess.run([sys.executable, str(SCRIPT), "--name", f"h5-{layout}", "--interval", "0.2",
                    "--h5", f"stats.h5,dataset=series,{columns}",
                    "--", sys.executable, "h5_solver.py", layout],
                   cwd=tmp_path, env=env, check=True, capture_output=True, timeout=60)
    rows = points(records(tmp_path, f"h5-{layout}"))
    assert len(rows) == 10
    assert rows[-1]["values"]["sim/t"] == 4.5
    assert rows[-1]["values"]["energy"] == pytest.approx(0.91)
    assert rows[-1]["values"]["error_l2"] == pytest.approx(1e-3 / 512)


def test_a_file_seen_through_a_symlinked_directory_is_read_once(tmp_path):
    (tmp_path / "out-0000").mkdir()
    (tmp_path / "out-active").symlink_to(tmp_path / "out-0000")
    (tmp_path / "out-0000" / "d.dat").write_text("# 1:time 2:energy\n0 1.0\n1 0.9\n\n2 0.8\n")
    env = {**os.environ, "PYTHONPATH": str(ROOT / "logger" / "src"),
           "SOLITON_MODE": "offline", "SOLITON_DIR": str(tmp_path / "runs")}
    subprocess.run([sys.executable, str(SCRIPT), "--name", "links", "--interval", "0.2",
                    "--table", "out-*/d.dat,t=1,energy=2", "--", "true"],
                   cwd=tmp_path, env=env, check=True, capture_output=True, timeout=60)
    rows = points(records(tmp_path, "links"))
    assert [r["values"]["sim/t"] for r in rows] == [0, 1, 2], "blank lines skipped, no repeats"


def test_derived_values_and_continue_codes(tmp_path):
    done = run(tmp_path, "crash", "--derive", "drop=1 - energy", "--continue-code", "3")
    assert done.returncode == 3, "the exit code is still the program's"
    recs = records(tmp_path, "fake-crash")
    last = points(recs)[-1]["values"]
    assert last["drop"] == pytest.approx(1 - last["energy"])
    assert (status(recs)["status"], status(recs)["message"]) == (
        "finished", "Stopped with exit code 3, to continue in a later job")


def _env(tmp_path):
    env = {**os.environ, "PYTHONPATH": str(ROOT / "logger" / "src"),
           "SOLITON_MODE": "offline", "SOLITON_DIR": str(tmp_path / "runs")}
    env.pop("SOLITON_SERVER", None)
    return env


def test_times_printed_with_fewer_digits_merge_within_the_tolerance(tmp_path):
    (tmp_path / "two.py").write_text(textwrap.dedent("""
        with open("a.dat", "w") as a, open("b.dat", "w") as b:
            for i in range(10):
                t = i / 3
                a.write(f"{t:.3f} {i}\\n")        # 3 decimals
                b.write(f"{t!r} {10 * i}\\n")     # full precision
    """))
    subprocess.run([sys.executable, str(SCRIPT), "--name", "rounded", "--interval", "0.2",
                    "--time-tolerance", "0.0005", "--derive", "ratio=b / max(a, 1)",
                    "--table", "a.dat,t=1,a=2", "--table", "b.dat,t=1,b=2",
                    "--", sys.executable, "two.py"],
                   cwd=tmp_path, env=_env(tmp_path), check=True, capture_output=True, timeout=60)
    rows = points(records(tmp_path, "rounded"))
    assert len(rows) == 10, "one record per output time"
    assert all({"a", "b", "ratio"} <= set(r["values"]) for r in rows)


def test_a_source_that_stops_does_not_hold_the_others_back(tmp_path):
    (tmp_path / "stops.py").write_text(textwrap.dedent("""
        import time
        with open("early.dat", "w") as f:              # stops after t = 1
            f.write("0 1\\n1 1\\n")
        with open("late.dat", "w") as f:
            for i in range(20):
                f.write(f"{i} {i}\\n"); f.flush(); time.sleep(0.1)
        time.sleep(4)                                    # still running, nothing new
    """))
    subprocess.run([sys.executable, str(SCRIPT), "--name", "stops", "--interval", "0.2",
                    "--hold", "1", "--table", "early.dat,t=1,early=2",
                    "--table", "late.dat,t=1,late=2", "--", sys.executable, "stops.py"],
                   cwd=tmp_path, env=_env(tmp_path), check=True, capture_output=True, timeout=60)
    recs = records(tmp_path, "stops")
    rows = points(recs)
    assert rows[-1]["values"]["sim/t"] == 19
    # Logged while the program was still running, not only at its end.
    from datetime import datetime
    def when(r):
        return datetime.fromisoformat(r["time"].replace("Z", "+00:00"))
    assert (when(status(recs)) - when(rows[-1])).total_seconds() > 2
