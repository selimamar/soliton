"""Datasets: described from their files, registered, linked to runs."""

from __future__ import annotations

import json

import pytest

import soliton
from soliton._datasets import describe
from soliton.cli import main as cli_main
from test_logger import records

np = pytest.importorskip("numpy")


def vorticity(tmp_path, name="ns2d.npy", samples=10):
    data = np.random.default_rng(0).standard_normal((samples, 32, 32, 5)).astype(np.float32)
    path = tmp_path / name
    np.save(path, data)
    return path, data


def test_a_numpy_file_describes_itself(tmp_path):
    path, data = vorticity(tmp_path)
    dataset = describe(path, version="v3", source="Simulated", splits={"train": 8, "val": 2})
    info = dataset.description
    assert dataset.id == "ns2d-v3" and info["name"] == "ns2d"
    assert (info["samples"], info["sampleShape"], info["format"]) == (10, [32, 32, 5], "NumPy")
    assert info["sizeBytes"] == path.stat().st_size and info["files"] == 1
    assert info["splits"] == {"train": 8, "val": 2} and info["source"] == "Simulated"
    assert info["location"] == str(path.resolve()) and len(info["fingerprint"]) == 16
    (variable,) = info["variables"]
    assert variable["shape"] == [10, 32, 32, 5] and variable["dtype"] == "float32"
    assert variable["min"] == pytest.approx(float(data.min()))
    assert len(info["previews"]) == 4
    preview = info["previews"][0]
    assert preview["shape"] == [32, 32], "the last time step of a sample"
    assert preview["max"] == pytest.approx(float(data[0, ..., -1].max()))


def test_the_fingerprint_changes_with_the_files(tmp_path):
    path, _ = vorticity(tmp_path)
    before = describe(path).description["fingerprint"]
    assert describe(path).description["fingerprint"] == before
    vorticity(tmp_path, samples=12)
    assert describe(path).description["fingerprint"] != before


def test_npz_and_folders(tmp_path):
    np.savez(tmp_path / "pair.npz", a=np.zeros((4, 8)), u=np.ones((6, 16, 16)))
    info = describe(tmp_path / "pair.npz").description
    assert [v["name"] for v in info["variables"]] == ["a", "u"]
    assert (info["samples"], info["sampleShape"]) == (6, [16, 16]), "the biggest array"
    folder = tmp_path / "runs"
    folder.mkdir()
    for i in range(3):
        vorticity(folder, f"part{i}.npy", samples=2)
    (folder / "README.txt").write_text("not data")
    info = describe(folder, name="parts").description
    assert (info["files"], info["format"], info["samples"]) == (3, "NumPy", 2)


def test_what_is_given_wins_and_bad_input(tmp_path):
    info = describe(name="benchmark", samples=5, sample_shape=[64, 64],
                    variables=[{"name": "u", "unit": "m/s", "min": 0, "max": float("nan")}],
                    previews=[np.eye(4)]).description
    assert (info["samples"], info["sampleShape"]) == (5, [64, 64])
    assert info["variables"] == [{"name": "u", "unit": "m/s", "min": 0.0, "max": "NaN"}]
    assert info["previews"][0]["shape"] == [4, 4]
    with pytest.raises(FileNotFoundError):
        describe(tmp_path / "missing.h5")
    with pytest.raises(ValueError):
        describe()


def test_offline_datasets_are_saved_and_runs_name_theirs(tmp_path, monkeypatch):
    monkeypatch.delenv("SOLITON_SERVER", raising=False)
    path, _ = vorticity(tmp_path)
    runs = tmp_path / "runs"
    dataset = soliton.register_dataset(path, version="v1", dir=str(runs))
    saved = json.loads((runs / "datasets" / "ns2d-v1.json").read_text())
    assert saved["samples"] == 10
    run = soliton.init("fno", mode="offline", dir=str(runs), host="t", system_metrics=False,
                         datasets=[dataset, "benchmark-darcy", path])
    run.finish()
    assert records(run)[0]["datasets"] == ["ns2d-v1", "benchmark-darcy", "ns2d"]
    assert (runs / "datasets" / "ns2d.json").exists(), "a path is registered on the way"
    with pytest.raises(ValueError, match="neither"):
        soliton.init("x", mode="offline", dir=str(runs), datasets=["not an id/"])


def test_a_simulation_registers_what_it_wrote(tmp_path):
    path, _ = vorticity(tmp_path)
    sim = soliton.simulate("gen", mode="offline", dir=str(tmp_path / "runs"), host="t",
                             system_metrics=False)
    dataset = sim.register_dataset(path, name="snapshots", source="Simulated")
    sim.finish()
    assert dataset.description["madeBy"] == sim.id
    assert dataset.description["system"]["python"], "the machine it was made on"


def test_the_scan_command_saves_each_data_file(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("SOLITON_SERVER", raising=False)
    monkeypatch.setenv("SOLITON_DIR", str(tmp_path / "runs"))
    data = tmp_path / "data"
    data.mkdir()
    vorticity(data, "a.npy")
    vorticity(data, "b.npy", samples=3)
    (data / "notes.txt").write_text("not data")
    with pytest.raises(SystemExit) as exit:
        cli_main(["data", "scan", str(data), "--source", "Simulated"])
    assert exit.value.code == 0
    saved = sorted(p.name for p in (tmp_path / "runs" / "datasets").iterdir())
    assert saved == ["a.json", "b.json"]
    assert "b: " in capsys.readouterr().out
