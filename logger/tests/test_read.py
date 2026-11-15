from __future__ import annotations

import csv
import io
import json
import math
import urllib.error

import httpx2 as httpx
import pytest

import soliton
from soliton import _read
from soliton._read import higher_is_better

from test_with_server import TOKEN, LiveServer, database_url  # noqa: F401  (a fixture)


def train(server, name, *, project="sweep", tags=(), lr="1e-3", losses=(1.0, 0.5, 0.25), acc=None,
          tmp_path):
    run = soliton.init(name, project=project, tags=list(tags), config={"lr": lr},
                       server=server.url, token=TOKEN, dir=str(tmp_path), system_metrics=False,
                       capture_output=False, capture_code=False)
    for step, loss in enumerate(losses):
        values = {"train/loss": loss}
        if acc is not None:
            values["val/accuracy"] = acc[step]
        run.log(values, step=step * 10)
    run.finish()
    return run


@pytest.fixture
def server(database_url):  # noqa: F811
    with LiveServer(database_url) as live:
        yield live


def test_runs_come_back_filtered_newest_first(server, tmp_path):
    train(server, "fno-a", tags=["final"], tmp_path=tmp_path)
    train(server, "fno-b", tags=["final", "seed2"], tmp_path=tmp_path)
    train(server, "unet", project="other", tmp_path=tmp_path)
    everything = soliton.runs(server=server.url, token=TOKEN)
    assert [r.name for r in everything] == ["unet", "fno-b", "fno-a"]
    assert [r.name for r in soliton.runs("sweep", server=server.url, token=TOKEN)] == ["fno-b", "fno-a"]
    assert [r.name for r in soliton.runs(tags=["final", "seed2"], server=server.url, token=TOKEN)] == ["fno-b"]
    assert [r.name for r in soliton.runs(name="fno-*", status="finished", server=server.url,
                                         token=TOKEN)] == ["fno-b", "fno-a"]
    assert soliton.runs(status=["live", "crashed"], server=server.url, token=TOKEN) == []
    run = everything["fno-a"]
    assert (run.project, run.status, run.config["lr"], run.tags) == ("sweep", "finished", "1e-3", ["final"])
    assert run.started_at is not None and run.ended_at >= run.started_at


def test_a_metric_comes_back_whole_a_page_at_a_time(server, tmp_path, monkeypatch):
    losses = [1.0 / (i + 1) for i in range(250)] + [math.nan]
    made = train(server, "long", losses=losses, tmp_path=tmp_path)
    monkeypatch.setattr(_read, "PAGE", 40)
    curve = soliton.get_run(made.id, server=server.url, token=TOKEN).metric("train/loss")
    assert curve.steps == [i * 10 for i in range(251)], "every point, none thinned out"
    assert curve.values[:2] == [1.0, 0.5] and math.isnan(curve.values[-1])
    assert len(curve) == 251 and next(iter(curve)) == (0, 1.0)
    assert len(soliton.get_run(made.id, server=server.url, token=TOKEN).metric("nope")) == 0


def test_a_table_of_runs_with_their_final_and_best(server, tmp_path):
    train(server, "a", lr="1e-3", losses=(1.0, 0.2, 0.4), acc=(0.5, 0.9, 0.8), tmp_path=tmp_path)
    train(server, "b", lr="1e-2", losses=(1.0, 0.6, 0.3), tmp_path=tmp_path)
    runs = soliton.runs(server=server.url, token=TOKEN)
    table = runs.table(["train/loss", "val/accuracy"])
    a = next(row for row in table if row["name"] == "a")
    assert (a["lr"], a["train/loss"], a["train/loss best"], a["train/loss best step"]) == ("1e-3", 0.4, 0.2, 10)
    assert (a["val/accuracy"], a["val/accuracy best"]) == (0.8, 0.9), "accuracy: higher is better"
    b = next(row for row in table if row["name"] == "b")
    assert b["val/accuracy"] is None, "never logged"
    assert runs["a"].metrics == ["train/loss", "val/accuracy"]
    assert runs["a"].summary["train/loss"].count == 3
    path = tmp_path / "table.csv"
    table.to_csv(path)
    rows = list(csv.DictReader(path.open()))
    assert {row["name"] for row in rows} == {"a", "b"} and "train/loss best" in rows[0]


def test_to_pandas(server, tmp_path):
    pd = pytest.importorskip("pandas")
    made = train(server, "a", tmp_path=tmp_path)
    runs = soliton.runs(server=server.url, token=TOKEN)
    frame = runs.table("train/loss").to_pandas()
    assert frame.loc[made.id, "train/loss best"] == 0.25
    series = runs[0].metric("train/loss").to_pandas()
    assert isinstance(series, pd.Series) and list(series.index) == [0, 10, 20]


def test_the_job_token_cant_read_and_says_so(server, tmp_path):
    job_token = httpx.post(server.url + "/api/job-token",
                           headers={"Authorization": f"Bearer {TOKEN}"}).json()["token"]
    with pytest.raises(PermissionError, match="needs the server's main token"):
        soliton.runs(server=server.url, token=job_token)
    with pytest.raises(PermissionError, match="rejected the token"):
        soliton.runs(server=server.url, token="wrong-token-of-some-length")
    with pytest.raises(LookupError):
        soliton.get_run("no-such-run", server=server.url, token=TOKEN)


def test_without_a_server_or_reachable_one(monkeypatch):
    monkeypatch.delenv("SOLITON_SERVER", raising=False)
    monkeypatch.delenv("SOLITON_TOKEN", raising=False)
    with pytest.raises(ValueError, match="needs a server and its main token"):
        soliton.runs()
    with pytest.raises(ConnectionError, match="can't reach"):
        soliton.runs(server="http://127.0.0.1:9", token="x")


def test_which_metrics_are_better_higher():
    assert higher_is_better("val/accuracy") and higher_is_better("psnr") and higher_is_better("reward")
    assert not higher_is_better("train/loss") and not higher_is_better("val/rel_l2")
    assert not higher_is_better("perf/inference_s") and not higher_is_better("accuracy_loss")


def test_an_older_server_is_named_as_the_problem(server, tmp_path, monkeypatch):
    made = train(server, "a", tmp_path=tmp_path)
    run = soliton.get_run(made.id, server=server.url, token=TOKEN)

    def refuse(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {},
                                     io.BytesIO(json.dumps({"detail": "Not Found"}).encode()))

    monkeypatch.setattr(_read, "urlopen", refuse)
    with pytest.raises(RuntimeError, match="older than this logger"):
        run.metric("train/loss")


def test_a_thinned_run_says_so(server, tmp_path):
    made = train(server, "a", losses=[1.0 / (i + 1) for i in range(50)], tmp_path=tmp_path)
    assert soliton.get_run(made.id, server=server.url, token=TOKEN).thinned_at is None
    httpx.post(f"{server.url}/api/runs/{made.id}/thin", params={"maxPoints": 10},
               headers={"Authorization": f"Bearer {TOKEN}"}).raise_for_status()
    run = soliton.get_run(made.id, server=server.url, token=TOKEN)
    assert run.thinned_at is not None and run.thinned_to == 10
    assert len(run.metric("train/loss")) <= 10
