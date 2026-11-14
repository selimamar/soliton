"""soliton.simulate: simulations monitored like runs."""

from __future__ import annotations

import pytest

import soliton
from test_logger import records

np = pytest.importorskip("numpy")


def simulation(tmp_path, name="kh", **kwargs):
    kwargs.setdefault("system_metrics", False)
    return soliton.simulate(name, mode="offline", dir=str(tmp_path), host="test", **kwargs)


def test_a_simulation_describes_itself_and_logs_against_time(tmp_path):
    sim = simulation(tmp_path, t_end=10, cfl_limit=1, monitor="energy",
                     setup={"equation": "Navier-Stokes 2D", "grid": {"nx": 256}})
    sim.log({"energy": 1.0, "cfl": 0.4}, t=0.1, dt=0.1)
    sim.log({"energy": 0.99}, t=0.2, dt=0.1)
    sim.log_field("vorticity", np.ones((16, 16)))
    sim.finish()
    run, *events, status = records(sim)
    assert run["simulation"] == {"tEnd": 10.0, "cflLimit": 1.0, "monitor": "energy"}
    assert run["hyperparameters"] == {"equation": "Navier-Stokes 2D", "grid.nx": "256"}
    assert [e["values"] for e in events if e["type"] == "metrics"] == [
        {"energy": 1.0, "cfl": 0.4, "sim/t": 0.1, "sim/dt": 0.1},
        {"energy": 0.99, "sim/t": 0.2, "sim/dt": 0.1},
    ]
    field = next(e for e in events if e["type"] == "field")
    assert (field["name"], field["step"], field.get("target")) == ("vorticity", 1, None)
    assert status["status"] == "finished" and "diverged" not in status


def test_a_steady_solve_counts_iterations(tmp_path):
    sim = simulation(tmp_path, max_iterations=50)
    for i in range(3):
        sim.log({"residual": 10.0 ** -i})
    sim.finish()
    run, *events, _ = records(sim)
    assert run["totalSteps"] == 50 and run["simulation"] == {}
    assert [e["step"] for e in events] == [0, 1, 2]


def test_a_parameter_study_logs_a_curve(tmp_path):
    sim = simulation(tmp_path, max_iterations=10)
    sim.log({"residual": 1e-9})
    sim.log_curve("drag vs Re", [100, 200, 400], [1.4, 1.3, 1.2], x_label="Re", y_label="Drag")
    sim.finish()
    curve = next(r for r in records(sim) if r["type"] == "curve")
    assert (curve["name"], curve["step"], curve["xLabel"]) == ("drag vs Re", 0, "Re")


def test_the_first_nan_ends_it_as_diverged(tmp_path):
    sim = simulation(tmp_path, t_end=1)
    sim.log({"energy": 1.0}, t=0.5)
    sim.log({"energy": float("inf")}, t=0.83)
    sim.log({"energy": 2.0}, t=0.9)  # Ignored: it has ended.
    sim.finish()  # Keeps it diverged.
    *_, last, status = records(sim)
    assert last["values"]["energy"] == "Infinity", "the bad value is still recorded"
    assert status == {**status, "status": "crashed", "diverged": True,
                      "message": "Diverged at t = 0.83: energy is infinite"}
    assert sum(r["type"] == "status" for r in records(sim)) == 1


def test_a_field_with_nan_diverges_and_can_stop_the_simulation(tmp_path):
    sim = simulation(tmp_path, stop_on_divergence=True)
    field = np.zeros((8, 8))
    field[3, 3] = np.nan
    with pytest.raises(soliton.Diverged, match="step 0: u has NaN"):
        sim.log_field("u", field)
    assert records(sim)[-1]["diverged"] is True


def test_bad_settings(tmp_path):
    for bad in ({"t_end": 0}, {"t_end": float("nan")}, {"cfl_limit": -1}, {"max_iterations": -1}):
        with pytest.raises(ValueError):
            simulation(tmp_path, name="bad", **bad)
