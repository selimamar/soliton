"""The logger against the real server, over HTTP."""

from __future__ import annotations

import socket
import threading
import time

import httpx2 as httpx
import pytest
import uvicorn

import soliton
from soliton.cli import main as cli_main
from soliton_server.app import create_app
from soliton_server.config import Settings

TOKEN = "logger-test-token"


class LiveServer:
    def __init__(self, database_url: str, port: int = 0) -> None:
        app = create_app(Settings(database_url=database_url, token=TOKEN), stale_check_seconds=0)
        self._socket = socket.socket()
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.bind(("127.0.0.1", port))
        self.port = self._socket.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}"
        self._server = uvicorn.Server(uvicorn.Config(app, log_level="warning"))
        self._thread = threading.Thread(
            target=self._server.run, kwargs={"sockets": [self._socket]}, daemon=True
        )

    def __enter__(self) -> "LiveServer":
        self._thread.start()
        deadline = time.monotonic() + 10
        while not self._server.started:
            if time.monotonic() > deadline:
                raise RuntimeError("server did not start")
            time.sleep(0.02)
        return self

    def __exit__(self, *_) -> None:
        self._server.should_exit = True
        self._thread.join(10)
        self._socket.close()

    def get(self, path: str):
        response = httpx.get(self.url + path, headers={"Authorization": f"Bearer {TOKEN}"})
        response.raise_for_status()
        return response.json()

    def wait_for_step(self, run_id: str, step: int, timeout: float = 10) -> None:
        """Uploads happen in the background, every couple of seconds."""
        deadline = time.monotonic() + timeout
        while True:
            response = httpx.get(f"{self.url}/api/runs/{run_id}",
                                 headers={"Authorization": f"Bearer {TOKEN}"})
            if response.status_code == 200 and response.json()["currentStep"] >= step:
                return
            assert time.monotonic() < deadline, f"step {step} never arrived"
            time.sleep(0.2)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def database_url(tmp_path):
    return f"sqlite:///{tmp_path / 'server.db'}"


def test_a_run_uploads_while_training(tmp_path, database_url):
    torch = pytest.importorskip("torch")
    with LiveServer(database_url) as server:
        model = torch.nn.Sequential(torch.nn.Linear(4, 8), torch.nn.ReLU(), torch.nn.Linear(8, 1))
        run = soliton.init("live", project="tests", server=server.url, token=TOKEN,
                             dir=str(tmp_path / "runs"), total_steps=20, host="test",
                             tags=["smoke-test"], notes="From the logger")
        run.watch(model, every=5)
        for step in range(20):
            model.zero_grad()
            loss = model(torch.randn(16, 4)).pow(2).mean()
            loss.backward()
            run.log({"train/loss": loss, "val/accuracy": 0.5}, step=step)

        server.wait_for_step(run.id, 19)
        assert server.get(f"/api/runs/{run.id}")["status"] == "live"

        run.finish()
        stored = server.get(f"/api/runs/{run.id}")
        assert stored["status"] == "finished"
        assert stored["architecture"]["type"] == "Sequential"
        assert (stored["tags"], stored["notes"]) == (["smoke-test"], "From the logger")
        assert len(stored["lossPreview"]) == 20
        metrics = {s["name"]: s for s in server.get(f"/api/runs/{run.id}/metrics")}
        assert len(metrics["train/loss"]["points"]) == 20
        layers = server.get(f"/api/runs/{run.id}/layers")
        assert [l["layerName"] for l in layers] == ["0", "2"]
        assert [p["step"] for p in layers[0]["gradNorm"]["points"]] == [0, 5, 10, 15]
        assert len(server.get(f"/api/runs/{run.id}/grad-norms")) == 2


def test_a_run_survives_the_server_being_down_and_syncs_later(tmp_path, database_url, capsys,
                                                              monkeypatch):
    port = free_port()
    url = f"http://127.0.0.1:{port}"  # Nothing is listening yet.
    run = soliton.init("offline-first", server=url, token=TOKEN, dir=str(tmp_path / "runs"),
                         host="test", system_metrics=False)  # Exact record counts below.
    for step in range(50):
        run.log({"train/loss": 1.0 / (step + 1)}, step=step)
    run.finish(timeout=1)
    assert "soliton sync" in capsys.readouterr().err

    with LiveServer(database_url, port=port) as server:
        monkeypatch.setenv("SOLITON_SERVER", url)
        monkeypatch.setenv("SOLITON_TOKEN", TOKEN)
        with pytest.raises(SystemExit) as exit_code:
            cli_main(["sync", str(tmp_path / "runs")])
        assert exit_code.value.code == 0
        assert "uploaded 52 records" in capsys.readouterr().out

        stored = server.get(f"/api/runs/{run.id}")
        assert stored["status"] == "finished" and stored["currentStep"] == 49

        # A second sync has nothing left to do.
        with pytest.raises(SystemExit):
            cli_main(["sync", str(tmp_path / "runs")])
        assert "up to date" in capsys.readouterr().out


def test_a_wrong_token_stops_uploading_but_keeps_the_run(tmp_path, database_url, capsys):
    with LiveServer(database_url) as server:
        run = soliton.init("wrong-token", server=server.url, token="nope",
                             dir=str(tmp_path / "runs"), host="test")
        run.log({"train/loss": 1.0}, step=0)
        run.finish(timeout=5)
        assert "HTTP 401" in capsys.readouterr().err
        assert server.get("/api/runs") == []
        assert (run.directory / "events.jsonl").exists()


def test_the_demo_runs_end_to_end(tmp_path, database_url, monkeypatch):
    pytest.importorskip("torch")
    with LiveServer(database_url) as server:
        monkeypatch.setenv("SOLITON_SERVER", server.url)
        monkeypatch.setenv("SOLITON_TOKEN", TOKEN)
        monkeypatch.setenv("SOLITON_DIR", str(tmp_path / "runs"))
        with pytest.raises(SystemExit):
            cli_main(["demo", "--steps", "120", "--delay", "0", "--name", "demo"])
        [stored] = server.get("/api/runs")
        assert stored["status"] == "finished"
        assert stored["lossPreview"][-1] < stored["lossPreview"][0], "the loss went down"
        names = {s["name"] for s in server.get(f"/api/runs/{stored['id']}/metrics")}
        assert {"train/loss", "val/loss", "val/accuracy", "optim/lr", "optim/grad_norm"} <= names
        assert list(stored["hyperparameters"])[:3] == ["Training samples", "Validation samples", "Loss"]
        assert stored["hyperparameters"]["Loss"] == "CrossEntropyLoss"
        drawn = [(f["type"], f["width"]) for f in stored["architecture"]["flow"] if f["kind"] == "linear"]
        assert drawn == [("Linear", 128), ("Linear", 128), ("Linear", 64), ("Linear", 10)]
        assert stored["architecture"]["input"]["width"] == 32
        assert stored["system"]["python"] and stored["system"]["cpuCores"] >= 1
        assert "system/memory_gb" in names, "sampled as soon as the run starts"


def test_a_crashing_demo_is_reported_as_crashed(tmp_path, database_url, monkeypatch):
    pytest.importorskip("torch")
    with LiveServer(database_url) as server:
        monkeypatch.setenv("SOLITON_SERVER", server.url)
        monkeypatch.setenv("SOLITON_TOKEN", TOKEN)
        monkeypatch.setenv("SOLITON_DIR", str(tmp_path / "runs"))
        with pytest.raises(FloatingPointError):
            cli_main(["demo", "--steps", "200", "--delay", "0", "--crash-at", "50"])
        [stored] = server.get("/api/runs")
        assert stored["status"] == "crashed"
        assert stored["statusMessage"].startswith("FloatingPointError: Loss became NaN")


def test_field_snapshots_reach_the_server(tmp_path, database_url):
    np = pytest.importorskip("numpy")
    x, y = np.meshgrid(np.linspace(0, 1, 256), np.linspace(0, 1, 256))
    target = np.sin(2 * np.pi * x) * np.cos(2 * np.pi * y)
    with LiveServer(database_url) as server:
        run = soliton.init("fno", server=server.url, token=TOKEN, dir=str(tmp_path),
                             system_metrics=False)
        for step in (0, 100):
            run.log({"train/loss": 1.0 / (step + 1)}, step=step)
            run.log_field("u", target + 0.1 / (step + 1), target)
        run.finish()
        fields = server.get(f"/api/runs/{run.id}/fields")
        assert [f["name"] for f in fields] == ["u"]
        assert fields[0]["shape"] == [128, 128]
        assert [s["step"] for s in fields[0]["steps"]] == [0, 100]
        assert fields[0]["steps"][1]["stats"]["rmse"] == pytest.approx(0.1 / 101)
        snapshot = server.get(f"/api/runs/{run.id}/fields/snapshot?name=u")
        assert snapshot["step"] == 100
        assert snapshot["originalShape"] == [256, 256]


def test_rollouts_3d_fields_and_layers_reach_the_server(tmp_path, database_url):
    np = pytest.importorskip("numpy")
    torch = pytest.importorskip("torch")
    net = torch.nn.Sequential(torch.nn.Conv2d(1, 4, 3, padding=1), torch.nn.Conv2d(4, 1, 1))
    with LiveServer(database_url) as server:
        run = soliton.init("fno3", server=server.url, token=TOKEN, dir=str(tmp_path),
                             system_metrics=False)
        run.log_rollout("u", np.random.rand(8, 32, 32), np.random.rand(8, 32, 32), step=1)
        run.log_field("p", np.random.rand(40, 40, 40), np.random.rand(40, 40, 40), step=1)
        with run.capture_layers(net, step=1):
            net(torch.randn(1, 1, 16, 16))
        run.finish()
        fields = {f["name"]: f for f in server.get(f"/api/runs/{run.id}/fields")}
        assert list(fields) == ["p", "u", "layers/0", "layers/1"]
        assert fields["u"]["frames"] == 8
        assert fields["p"]["shape"] == [40, 40, 40]
        layer = server.get(f"/api/runs/{run.id}/fields/snapshot?name=layers/0")
        assert layer["reduction"] == "mean of 4 channels" and layer["shape"] == [16, 16]


def test_validation_sets_curves_and_spectra_reach_the_server(tmp_path, database_url):
    np = pytest.importorskip("numpy")
    rng = np.random.default_rng(0)
    targets = rng.random((20, 16, 16)) + 1
    predictions = targets * 1.05
    predictions[3] = np.nan
    with LiveServer(database_url) as server:
        run = soliton.init("eval", server=server.url, token=TOKEN, dir=str(tmp_path),
                             system_metrics=False, pde={"equation": "Darcy 2D"})
        run.log_field("u", predictions[0], targets[0], step=1, extent=[(0, 1), (0, 1)],
                      axes=["y", "x"])
        run.log_eval("u", predictions, targets, step=1, worst=2)
        run.log_curve("error vs resolution", [16, 32], [0.05, "NaN"], step=1)
        run.finish()
        (evals,) = server.get(f"/api/runs/{run.id}/evals")
        assert evals["steps"][0]["worst"][0] == {"rank": 1, "sample": 3, "relL2": "NaN"}
        assert server.get(f"/api/runs/{run.id}/curves")[0]["steps"][0]["y"] == [0.05, "NaN"]
        field = server.get(f"/api/runs/{run.id}/fields/snapshot?name=u")
        assert field["axes"] == ["y", "x"] and len(field["spectrum"]["k"]) == 8
        names = [f["name"] for f in server.get(f"/api/runs/{run.id}/fields")]
        assert names == ["u", "worst/u/1", "worst/u/2"]
        assert server.get(f"/api/runs/{run.id}")["hyperparameters"]["PDE"] == "Darcy 2D"


def test_a_training_problem_reaches_the_server(tmp_path, database_url):
    with LiveServer(database_url) as server:
        run = soliton.init("tiny", server=server.url, token=TOKEN, dir=str(tmp_path),
                           system_metrics=False, stop_on_divergence=True)
        run.log({"train/loss": 0.7})
        with pytest.raises(soliton.Diverged):
            run.log({"train/loss": float("nan")})
        stored = server.get(f"/api/runs/{run.id}")
        assert stored["status"] == "crashed"
        assert stored["statusMessage"] == "Diverged: train/loss is NaN at step 1"
        assert [(h["kind"], h["step"], h["message"]) for h in stored["health"]] == [
            ("nan", 1, "train/loss is NaN at step 1")]


def test_a_simulation_reaches_the_server_and_diverges_there(tmp_path, database_url):
    np = pytest.importorskip("numpy")
    with LiveServer(database_url) as server:
        sim = soliton.simulate("burgers", t_end=1, monitor="energy", cfl_limit=1,
                                 setup={"equation": "Burgers 1D"}, server=server.url,
                                 token=TOKEN, dir=str(tmp_path), system_metrics=False)
        for i in range(4):
            sim.log({"energy": 0.25 + 0.01 * i, "cfl": 0.5}, t=0.1 * i, dt=0.1)
        sim.log_field("u", np.sin(np.linspace(0, 6.28, 64)))
        sim.log({"energy": float("nan")}, t=0.4)
        sim.finish()
        stored = server.get(f"/api/runs/{sim.id}")
        assert stored["status"] == "crashed"
        assert stored["statusMessage"] == "Diverged at t = 0.4: energy is NaN"
        assert stored["simulation"] == {
            "tEnd": 1.0, "cflLimit": 1.0, "monitor": "energy", "diverged": True,
            "time": 0.4, "preview": [0.25, 0.26, 0.27, 0.28, "NaN"],
        }
        assert stored["hyperparameters"] == {"equation": "Burgers 1D"}
        assert [f["name"] for f in server.get(f"/api/runs/{sim.id}/fields")] == ["u"]


def test_datasets_reach_the_server_with_who_made_and_used_them(tmp_path, database_url,
                                                               monkeypatch):
    np = pytest.importorskip("numpy")
    path = tmp_path / "snapshots.npy"
    np.save(path, np.random.default_rng(1).standard_normal((6, 16, 16)))
    with LiveServer(database_url) as server:
        sim = soliton.simulate("gen", server=server.url, token=TOKEN, dir=str(tmp_path),
                                 system_metrics=False)
        dataset = sim.register_dataset(path, version="v1", source="Simulated")
        sim.finish()
        run = soliton.init("fno", server=server.url, token=TOKEN, dir=str(tmp_path),
                             system_metrics=False, datasets=[dataset])
        run.finish()
        stored = server.get(f"/api/datasets/{dataset.id}")
        assert (stored["samples"], stored["sampleShape"]) == (6, [16, 16])
        assert stored["madeBy"]["id"] == sim.id and stored["madeBy"]["simulation"] is True
        assert [r["id"] for r in stored["usedBy"]] == [run.id]
        assert len(stored["previews"]) == 4

        # Saved while offline, uploaded by `soliton sync`.
        monkeypatch.delenv("SOLITON_SERVER", raising=False)
        soliton.register_dataset(path, name="later", dir=str(tmp_path / "offline"))
        monkeypatch.setenv("SOLITON_SERVER", server.url)
        monkeypatch.setenv("SOLITON_TOKEN", TOKEN)
        with pytest.raises(SystemExit):
            cli_main(["sync", str(tmp_path / "offline")])
        assert server.get("/api/datasets/later")["samples"] == 6
        assert not list((tmp_path / "offline" / "datasets").iterdir()), "uploaded, then removed"


def test_a_crashed_runs_output_and_traceback_reach_the_server(tmp_path, database_url):
    with LiveServer(database_url) as server:
        with pytest.raises(RuntimeError):
            with soliton.init("crashy", server=server.url, token=TOKEN, dir=str(tmp_path),
                              system_metrics=False) as run:
                print("epoch 1: loss 0.5")
                raise RuntimeError("CUDA out of memory")
        got = server.get(f"/api/runs/{run.id}/output")
        assert got["lines"][0] == "epoch 1: loss 0.5"
        assert got["lines"][-1] == "RuntimeError: CUDA out of memory"
        assert got["total"] == len(got["lines"])
        assert server.get(f"/api/runs/{run.id}")["status"] == "crashed"


def test_the_apps_stop_button_reaches_the_training_loop(tmp_path, database_url):
    with LiveServer(database_url) as server:
        run = soliton.init("stoppable", server=server.url, token=TOKEN, dir=str(tmp_path / "runs"),
                           total_steps=10_000, host="test", system_metrics=False)
        run.log({"train/loss": 1.0}, step=0)
        server.wait_for_step(run.id, 0)
        response = httpx.post(f"{server.url}/api/runs/{run.id}/stop",
                              headers={"Authorization": f"Bearer {TOKEN}"})
        assert response.status_code == 200
        deadline = time.monotonic() + 15
        step = 0
        while not run.should_stop():  # As a training loop would.
            assert time.monotonic() < deadline, "the stop never arrived"
            step += 1
            run.log({"train/loss": 1.0 / step}, step=step)
            time.sleep(0.1)
        run.finish()
        stored = server.get(f"/api/runs/{run.id}")
        assert stored["status"] == "finished"
        assert stored["statusMessage"].startswith("Stopped from the app at step")
        assert stored["stopRequestedAt"] is None


def test_a_run_s_key_lets_only_its_own_folder_continue_it_with_a_job_token(tmp_path, database_url):
    """A leaked job token can't change a run; a job continuing the run from
    its folder can (it finds the key there)."""
    import stat

    from soliton._upload import ApiClient, UploadError

    with LiveServer(database_url) as server:
        main = ApiClient(server.url, TOKEN)
        job_token = main._request("POST", "/api/job-token")["token"]
        run = soliton.init("keyed", id="keyed-run", server=server.url, token=job_token,
                           dir=str(tmp_path / "runs"), system_metrics=False, capture_output=False)
        run.log({"loss": 1.0}, step=0)
        run.finish()
        key_file = tmp_path / "runs" / "keyed-run" / "key"
        assert stat.S_IMODE(key_file.stat().st_mode) == 0o600
        with pytest.raises(UploadError, match="403"):
            ApiClient(server.url, job_token).put_run("keyed-run", {"name": "hijacked"})
        again = soliton.init("keyed", id="keyed-run", server=server.url, token=job_token,
                             dir=str(tmp_path / "runs"), system_metrics=False, capture_output=False)
        again.log({"loss": 0.5}, step=1)
        again.finish()
        assert server.get("/api/runs/keyed-run")["currentStep"] == 1


def test_setup_tells_the_main_token_the_job_token_and_a_wrong_one_apart(database_url):
    from soliton._setup import JOB, MAIN, WRONG, check_token

    with LiveServer(database_url) as server:
        job = httpx.post(f"{server.url}/api/job-token",
                         headers={"Authorization": f"Bearer {TOKEN}"}).json()["token"]
        assert check_token(server.url, TOKEN)[0] == MAIN
        assert check_token(server.url, job)[0] == JOB
        assert check_token(server.url, "not-the-token-at-all")[0] == WRONG
