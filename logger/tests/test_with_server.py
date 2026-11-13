"""The logger against the real server, over HTTP."""

from __future__ import annotations

import socket
import threading
import time

import httpx2 as httpx
import pytest
import uvicorn

import modelsapp
from modelsapp.cli import main as cli_main
from modelsapp_server.app import create_app
from modelsapp_server.config import Settings

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
        run = modelsapp.init("live", project="tests", server=server.url, token=TOKEN,
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
    run = modelsapp.init("offline-first", server=url, token=TOKEN, dir=str(tmp_path / "runs"),
                         host="test", system_metrics=False)  # Exact record counts below.
    for step in range(50):
        run.log({"train/loss": 1.0 / (step + 1)}, step=step)
    run.finish(timeout=1)
    assert "modelsapp sync" in capsys.readouterr().err

    with LiveServer(database_url, port=port) as server:
        monkeypatch.setenv("MODELSAPP_SERVER", url)
        monkeypatch.setenv("MODELSAPP_TOKEN", TOKEN)
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
        run = modelsapp.init("wrong-token", server=server.url, token="nope",
                             dir=str(tmp_path / "runs"), host="test")
        run.log({"train/loss": 1.0}, step=0)
        run.finish(timeout=5)
        assert "HTTP 401" in capsys.readouterr().err
        assert server.get("/api/runs") == []
        assert (run.directory / "events.jsonl").exists()


def test_the_demo_runs_end_to_end(tmp_path, database_url, monkeypatch):
    pytest.importorskip("torch")
    with LiveServer(database_url) as server:
        monkeypatch.setenv("MODELSAPP_SERVER", server.url)
        monkeypatch.setenv("MODELSAPP_TOKEN", TOKEN)
        monkeypatch.setenv("MODELSAPP_DIR", str(tmp_path / "runs"))
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
        monkeypatch.setenv("MODELSAPP_SERVER", server.url)
        monkeypatch.setenv("MODELSAPP_TOKEN", TOKEN)
        monkeypatch.setenv("MODELSAPP_DIR", str(tmp_path / "runs"))
        with pytest.raises(FloatingPointError):
            cli_main(["demo", "--steps", "200", "--delay", "0", "--crash-at", "50"])
        [stored] = server.get("/api/runs")
        assert stored["status"] == "crashed"
        assert stored["statusMessage"].startswith("FloatingPointError: Loss became NaN")
