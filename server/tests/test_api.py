from __future__ import annotations

import math

import pytest
from fastapi.testclient import TestClient

from conftest import AUTH, TOKEN

# The keys of the app's Run.toJson (lib/models/run.dart).
RUN_KEYS = {
    "id", "name", "project", "host", "status", "startedAt", "endedAt", "currentStep",
    "totalSteps", "currentEpoch", "totalEpochs", "hyperparameters", "architecture",
    "lossPreview", "statusMessage",
}
LAYER_KEYS = {
    "layerName", "activationMean", "activationStd", "gradNorm", "activationHistogram",
    "deadFraction",
}

ARCHITECTURE = {
    "name": "TinyNet",
    "type": "TinyNet",
    "ownParameters": 0,
    "children": [
        {"name": "fc1", "type": "Linear", "ownParameters": 80, "children": []},
        {"name": "fc2", "type": "Linear", "ownParameters": 11, "children": []},
    ],
    # The layers in the order they ran, for the app's network diagram: kept
    # as the logger sent them.
    "input": {"shape": [8], "tokens": False, "width": 8},
    "flow": [
        {"name": "fc1", "type": "Linear", "kind": "linear", "shape": [10], "width": 10,
         "parameters": 90},
        {"name": "fc2", "type": "Linear", "kind": "linear", "shape": [1], "width": 1,
         "parameters": 11},
    ],
}


# The data and the loss come first; the app shows them in this order.
HYPERPARAMETERS = {
    "Training samples": "50,000",
    "Validation samples": "10,000",
    "Loss": "CrossEntropyLoss",
    "Optimizer": "AdamW",
    "Learning rate": "0.0003",
}


def create_run(client, run_id="tiny-1", **fields):
    body = {
        "name": "tiny",
        "project": "tests",
        "host": "Sherlock",
        "totalSteps": 1000,
        "totalEpochs": 10,
        "hyperparameters": HYPERPARAMETERS,
        "architecture": ARCHITECTURE,
        **fields,
    }
    response = client.put(f"/api/runs/{run_id}", json=body)
    assert response.status_code == 200, response.text
    return response.json()


def send(client, events, run_id="tiny-1"):
    response = client.post(f"/api/runs/{run_id}/events", json={"events": events})
    assert response.status_code == 200, response.text
    return response.json()


def metrics(step, epoch=None, **values):
    event = {"type": "metrics", "step": step, "values": {k.replace("__", "/"): v for k, v in values.items()}}
    if epoch is not None:
        event["epoch"] = epoch
    return event


def layer(name, grad=0.5, step_value=1.0):
    return {
        "layerName": name,
        "activationMean": 0.1 * step_value,
        "activationStd": 1.0,
        "gradNorm": grad,
        "deadFraction": 0.25,
        "activationHistogram": {"min": -1.0, "max": 1.0, "counts": [1, 2, 3], "zeroCount": 4},
    }


def test_health_is_public_but_everything_else_needs_the_token(app):
    with TestClient(app) as anonymous:
        assert anonymous.get("/api/health").json()["status"] == "ok"
        assert anonymous.get("/api/runs").status_code == 401
        wrong = {"Authorization": "Bearer nope"}
        assert anonymous.get("/api/runs", headers=wrong).status_code == 401
        assert anonymous.get("/api/session", headers=AUTH).json()["ok"] is True
        assert anonymous.get("/api/runs", headers=AUTH).json() == []


def test_a_run_reads_back_in_the_apps_format(client, clock):
    created = create_run(client)
    assert set(created) == RUN_KEYS
    assert created["status"] == "live"
    assert created["startedAt"] == "2026-11-12T09:00:00Z"

    send(client, [metrics(s, epoch=s // 10, train__loss=2.0 - s / 100) for s in range(100)])
    send(client, [metrics(99, val__loss=1.5, val__accuracy=0.7)])

    [run] = client.get("/api/runs").json()
    assert set(run) == RUN_KEYS
    assert run["currentStep"] == 99
    assert run["currentEpoch"] == 9
    assert list(run["hyperparameters"].items()) == list(HYPERPARAMETERS.items())
    assert run["architecture"] == ARCHITECTURE
    assert 0 < len(run["lossPreview"]) <= 60
    assert run["lossPreview"][0] == pytest.approx(2.0)
    assert run["lossPreview"][-1] == pytest.approx(1.01)

    clock.advance(minutes=5)
    send(client, [{"type": "status", "status": "finished"}])
    run = client.get("/api/runs/tiny-1").json()
    assert run["status"] == "finished"
    assert run["endedAt"] == "2026-11-12T09:05:00Z"


def test_metrics_come_back_as_series(client):
    create_run(client)
    send(client, [metrics(s, train__loss=1.0 / (s + 1), optim__lr=0.001) for s in range(10)])

    series = {s["name"]: s for s in client.get("/api/runs/tiny-1/metrics").json()}
    assert set(series) == {"train/loss", "optim/lr"}
    assert [p["step"] for p in series["train/loss"]["points"]] == list(range(10))
    assert series["train/loss"]["points"][1]["value"] == pytest.approx(0.5)


def test_nan_and_infinity_survive_the_round_trip(client):
    create_run(client)
    send(client, [
        metrics(0, train__loss=1.0),
        metrics(1, train__loss="Infinity"),
        metrics(2, train__loss="-Infinity"),
        metrics(3, train__loss="NaN"),
    ])
    [series] = client.get("/api/runs/tiny-1/metrics").json()
    assert [p["value"] for p in series["points"]] == [1.0, "Infinity", "-Infinity", "NaN"]
    assert client.get("/api/runs/tiny-1").json()["lossPreview"] == [1.0, "Infinity", "-Infinity", "NaN"]


def test_a_resent_batch_does_not_duplicate_points(client):
    create_run(client)
    batch = [metrics(s, train__loss=float(s)) for s in range(5)]
    send(client, batch)
    send(client, batch)
    send(client, [metrics(4, train__loss=40.0)])
    [series] = client.get("/api/runs/tiny-1/metrics").json()
    assert [p["value"] for p in series["points"]] == [0.0, 1.0, 2.0, 3.0, 40.0]


def test_long_series_are_downsampled_keeping_spikes(client):
    create_run(client)
    values = [1.0] * 5000
    values[2500] = 99.0
    for start in range(0, 5000, 1000):
        send(client, [metrics(s, train__loss=values[s]) for s in range(start, start + 1000)])
    [series] = client.get("/api/runs/tiny-1/metrics?maxPoints=100").json()
    points = series["points"]
    assert len(points) <= 100
    assert points[0]["step"] == 0 and points[-1]["step"] == 4999
    assert {"step": 2500, "value": 99.0} in points


def test_layers_keep_model_order_and_the_latest_histogram(client):
    create_run(client)
    send(client, [{"type": "layers", "step": 0, "layers": [layer("fc2"), layer("fc1")]}])
    later = layer("fc1", grad=None, step_value=2.0)
    later["activationHistogram"]["counts"] = [9, 9, 9]
    send(client, [{"type": "layers", "step": 100, "layers": [layer("fc2", grad="NaN"), later]}])

    layers = client.get("/api/runs/tiny-1/layers").json()
    assert [l["layerName"] for l in layers] == ["fc2", "fc1"]
    assert set(layers[0]) == LAYER_KEYS
    fc1 = layers[1]
    assert fc1["activationHistogram"]["counts"] == [9, 9, 9]
    assert fc1["activationHistogram"]["zeroCount"] == 4
    assert [p["step"] for p in fc1["activationMean"]["points"]] == [0, 100]
    assert fc1["activationMean"]["name"] == "fc1/act_mean"
    assert [p["step"] for p in fc1["gradNorm"]["points"]] == [0], "no gradient at step 100"
    assert fc1["deadFraction"] == 0.25

    # fc1 had no gradient at its latest step, so it isn't compared.
    assert client.get("/api/runs/tiny-1/grad-norms").json() == [
        {"layerName": "fc2", "gradNorm": "NaN"}
    ]


def test_unknown_runs_and_bad_input(client):
    assert client.get("/api/runs/nope").status_code == 404
    assert client.get("/api/runs/nope/metrics").status_code == 404
    assert client.post("/api/runs/nope/events", json={"events": []}).status_code == 404
    assert client.put("/api/runs/bad id!", json={"name": "x"}).status_code in (404, 422)

    create_run(client)
    bad = client.post("/api/runs/tiny-1/events", json={"events": [metrics(0, train__loss="abc")]})
    assert bad.status_code == 422
    assert client.post(
        "/api/runs/tiny-1/events", json={"events": [{"type": "status", "status": "paused"}]}
    ).status_code == 422


def test_deleting_a_run(client):
    create_run(client)
    send(client, [metrics(0, train__loss=1.0), {"type": "layers", "step": 0, "layers": [layer("fc1")]}])
    assert client.delete("/api/runs/tiny-1").status_code == 204
    assert client.get("/api/runs").json() == []
    create_run(client)  # The id is free again, with no leftover data.
    assert client.get("/api/runs/tiny-1/metrics").json() == []


def test_a_quiet_run_is_marked_crashed_and_comes_back(app, client, clock, notifications):
    create_run(client)
    send(client, [metrics(0, train__loss=1.0)])
    store = app.state.store

    clock.advance(minutes=9)
    assert store.mark_stale(app.state.settings.stale_after) == []

    clock.advance(minutes=2)
    [change] = store.mark_stale(app.state.settings.stale_after)
    assert change.event == "crashed"
    run = client.get("/api/runs/tiny-1").json()
    assert run["status"] == "crashed"
    assert run["statusMessage"].startswith("Lost contact")
    assert run["endedAt"] == "2026-11-12T09:00:00Z"

    send(client, [metrics(1, train__loss=0.9)])
    run = client.get("/api/runs/tiny-1").json()
    assert run["status"] == "live"
    assert run["endedAt"] is None and run["statusMessage"] is None
    assert "revived" in [c.event for c in notifications]


def test_late_upload_of_an_old_run_does_not_revive_it(app, client, clock):
    """`modelsapp sync` may upload old data after the run was marked lost."""
    create_run(client)
    clock.advance(minutes=30)
    app.state.store.mark_stale(app.state.settings.stale_after)
    old = metrics(5, train__loss=1.0)
    old["time"] = "2026-11-12T08:59:00Z"
    send(client, [old])
    assert client.get("/api/runs/tiny-1").json()["status"] == "crashed"

    # The run's own final status replaces "lost contact".
    send(client, [{"type": "status", "status": "finished", "time": "2026-11-12T09:01:00Z"}])
    run = client.get("/api/runs/tiny-1").json()
    assert run["status"] == "finished" and run["statusMessage"] is None


def test_the_notifier_hears_about_finished_and_crashed_runs(client, notifications):
    create_run(client, "a")
    create_run(client, "b")
    send(client, [{"type": "status", "status": "finished"}], run_id="a")
    send(client, [{"type": "status", "status": "crashed", "message": "RuntimeError: CUDA out of memory"}], run_id="b")
    send(client, [{"type": "status", "status": "finished"}], run_id="a")  # Resent: no new event.

    events = [(c.run_id, c.event) for c in notifications if c.event in ("finished", "crashed")]
    assert events == [("a", "finished"), ("b", "crashed")]
    crash = next(c for c in notifications if c.event == "crashed")
    assert crash.message == "RuntimeError: CUDA out of memory"


def test_live_updates_need_the_token(client):
    with client.websocket_connect("/api/live") as ws:
        ws.send_json({"type": "auth", "token": "wrong"})
        assert ws.receive_json()["type"] == "error"


def test_live_updates_push_every_change(client):
    with client.websocket_connect("/api/live") as ws:
        ws.send_json({"type": "auth", "token": TOKEN})
        assert ws.receive_json()["type"] == "ready"

        create_run(client)
        message = ws.receive_json()
        assert message["type"] == "run"
        assert (message["event"], message["runId"], message["status"]) == ("created", "tiny-1", "live")

        send(client, [metrics(7, train__loss=1.0)])
        message = ws.receive_json()
        assert (message["event"], message["currentStep"]) == ("updated", 7)

        send(client, [{"type": "status", "status": "crashed", "message": "boom"}])
        events = [ws.receive_json(), ws.receive_json()]
        assert [m["event"] for m in events] == ["crashed", "updated"]
        assert events[0]["statusMessage"] == "boom"


def test_the_web_app_may_call_the_api(client):
    response = client.options(
        "/api/runs",
        headers={
            "Origin": "http://localhost:8787",
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "authorization",
        },
    )
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] in ("*", "http://localhost:8787")


def test_numbers_in_json_are_never_bare_nan(client):
    """Bare NaN isn't valid JSON: the app's parser would reject it."""
    create_run(client)
    send(client, [metrics(0, train__loss="NaN")])
    for path in ("/api/runs", "/api/runs/tiny-1/metrics"):
        assert "NaN" not in client.get(path).text.replace('"NaN"', "")
    assert math.isnan(float("nan"))  # (sanity: the check above would catch a bare NaN)
