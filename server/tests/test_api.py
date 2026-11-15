from __future__ import annotations

import math

import pytest
from fastapi.testclient import TestClient

from conftest import AUTH, TOKEN

# The keys of the app's Run.toJson (lib/models/run.dart).
RUN_KEYS = {
    "id", "name", "project", "host", "status", "startedAt", "endedAt", "currentStep",
    "totalSteps", "currentEpoch", "totalEpochs", "hyperparameters", "architecture",
    "lossPreview", "statusMessage", "tags", "notes", "system", "simulation",
    "datasets", "resumedAtStep", "stopRequestedAt", "jobs", "health", "thinnedAt", "thinnedTo",
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


# What the run trains on ---------------------------------------------------------

SYSTEM = {
    "hostname": "sh03-12n07.int", "os": "Rocky Linux 8.10 (Linux 4.18.0)", "python": "3.12.4",
    "cpu": "AMD EPYC 7543 32-Core Processor", "cpuCores": 8, "memoryGb": 64.0,
    "gpus": [{"name": "NVIDIA A100-SXM4-80GB", "memoryGb": 80.0}], "gpuDriver": "550.54.15",
    "torch": "2.5.1", "cuda": "12.4", "slurm": {"jobId": "12345678", "partition": "gpu"},
}


def test_the_system_a_run_trains_on_is_kept(client):
    assert create_run(client)["system"] is None, "an older logger sends none"
    assert create_run(client, system=SYSTEM)["system"] == SYSTEM
    # A description without it (e.g. from an older logger) keeps it.
    assert create_run(client)["system"] == SYSTEM
    newer = {**SYSTEM, "torch": "2.6.0"}
    assert create_run(client, system=newer)["system"]["torch"] == "2.6.0"
    assert client.get("/api/runs").json()[0]["system"] == newer


def test_system_metrics_are_ordinary_metrics(client):
    create_run(client)
    send(client, [metrics(0, **{"system/gpu.0.utilization": 97.0, "system/memory_gb": 12.5})])
    names = {s["name"] for s in client.get("/api/runs/tiny-1/metrics").json()}
    assert names == {"system/gpu.0.utilization", "system/memory_gb"}


def test_a_huge_system_description_is_rejected(client):
    body = {"name": "tiny", "system": {"cpu": "x" * 30_000}}
    assert client.put("/api/runs/tiny-1", json=body).status_code == 422


# Tags and notes ---------------------------------------------------------------


def test_a_new_run_has_no_tags_or_notes(client):
    run = create_run(client)
    assert (run["tags"], run["notes"]) == ([], "")


def test_the_app_edits_tags_and_notes(client):
    create_run(client)
    response = client.patch("/api/runs/tiny-1", json={
        "tags": [" baseline ", "cifar", "Baseline"], "notes": "LR too high?\nTry 1e-4.",
    })
    assert response.status_code == 200, response.text
    assert response.json()["tags"] == ["baseline", "cifar"], "trimmed, each once"
    assert response.json()["notes"] == "LR too high?\nTry 1e-4."

    # What's left out stays as it is.
    assert client.patch("/api/runs/tiny-1", json={"notes": ""}).json()["tags"] == ["baseline", "cifar"]
    run = client.get("/api/runs/tiny-1").json()
    assert (run["tags"], run["notes"]) == (["baseline", "cifar"], "")
    assert client.get("/api/runs").json()[0]["tags"] == ["baseline", "cifar"]


def test_tags_and_notes_from_the_logger_only_start_the_run(client):
    run = create_run(client, tags=["sweep-3"], notes="Started from a script")
    assert (run["tags"], run["notes"]) == (["sweep-3"], "Started from a script")
    client.patch("/api/runs/tiny-1", json={"tags": ["best"]})
    # The logger sends the description again (e.g. after run.watch()).
    run = create_run(client, tags=["sweep-3"], notes="Started from a script")
    assert run["tags"] == ["best"], "the app's edit wins"


def test_bad_tags_and_notes_are_rejected(client):
    create_run(client)
    for body in ({"tags": [""]}, {"tags": ["x" * 41]}, {"tags": [f"t{i}" for i in range(21)]},
                 {"notes": "x" * 10_001}):
        assert client.patch("/api/runs/tiny-1", json=body).status_code == 422, body
    assert client.patch("/api/runs/nope", json={"notes": "hi"}).status_code == 404


def test_editing_notes_is_announced_live(client):
    create_run(client)
    with client.websocket_connect("/api/live") as ws:
        ws.send_json({"type": "auth", "token": TOKEN})
        assert ws.receive_json()["type"] == "ready"
        client.patch("/api/runs/tiny-1", json={"notes": "hi"})
        message = ws.receive_json()
        assert (message["event"], message["runId"]) == ("updated", "tiny-1")


def test_deleting_a_run_deletes_its_notes(client):
    create_run(client)
    client.patch("/api/runs/tiny-1", json={"tags": ["old"], "notes": "old"})
    client.delete("/api/runs/tiny-1")
    run = create_run(client)
    assert (run["tags"], run["notes"]) == ([], "")


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


def test_a_run_quiet_after_its_slurm_time_limit_is_marked_stopped_by_it(app, client, clock):
    """Slurm can kill a job at its limit before the logger says so."""
    slurm = {"jobId": "12345679", "timeLimitAt": "2026-11-12T09:05:00Z"}
    create_run(client, system={"slurm": slurm})
    create_run(client, "no-limit")
    store = app.state.store

    clock.advance(minutes=5, seconds=30)   # Past the limit, but not by a minute yet.
    assert store.mark_stale(app.state.settings.stale_after) == []

    clock.advance(minutes=1)
    [change] = store.mark_stale(app.state.settings.stale_after)
    assert change.run_id == "tiny-1" and change.event == "crashed"
    run = client.get("/api/runs/tiny-1").json()
    assert run["statusMessage"].startswith("Stopped by its Slurm time limit (job 12345679)")
    assert run["endedAt"] == "2026-11-12T09:00:00Z"
    # Without a time limit: still the 10 minutes, as "lost contact".
    assert client.get("/api/runs/no-limit").json()["status"] == "live"


def test_a_run_that_wont_finish_before_its_time_limit_warns_once(app, client, clock):
    """While there's still time to save a checkpoint (see warn_time_limits)."""
    slurm = {"jobId": "12345680", "timeLimitAt": "2026-11-12T11:00:00Z"}
    create_run(client, system={"slurm": slurm})  # 1,000 steps, from 09:00.
    store = app.state.store

    clock.advance(minutes=5)
    send(client, [metrics(100, train__loss=1.0)])
    assert store.warn_time_limits() == [], "too early to trust its pace"

    clock.advance(minutes=15)
    send(client, [metrics(100, train__loss=0.9)])  # 10% in 20 minutes: 3 hours to go.
    [change] = store.warn_time_limits()
    assert (change.run_id, change.event, change.status) == ("tiny-1", "time-limit", "live")
    assert change.message.startswith(
        "At this pace it needs about 3h more, but its Slurm time limit (job 12345680) is in 1h 40m."
    )
    assert store.warn_time_limits() == [], "once per job"


def test_a_run_on_pace_for_its_time_limit_doesnt_warn(app, client, clock):
    create_run(client, system={"slurm": {"timeLimitAt": "2026-11-12T11:00:00Z"}})
    create_run(client, "no-limit")
    clock.advance(minutes=20)
    send(client, [metrics(300, train__loss=0.9)])
    send(client, [metrics(10, train__loss=0.9)], run_id="no-limit")
    assert app.state.store.warn_time_limits() == []


def test_a_run_still_logging_past_its_time_limit_stays_live(app, client, clock):
    """E.g. a limit extended with scontrol: data keeps arriving."""
    create_run(client, system={"slurm": {"timeLimitAt": "2026-11-12T09:05:00Z"}})
    clock.advance(minutes=8)
    send(client, [metrics(1, train__loss=0.5)])
    assert app.state.store.mark_stale(app.state.settings.stale_after) == []


def test_a_new_process_continuing_an_ended_run_makes_it_live_again(client, clock, notifications):
    """A job restarted from a checkpoint calls init(id=...) again."""
    create_run(client)
    send(client, [{"type": "status", "status": "crashed", "message": "Stopped by SIGTERM"}])
    clock.advance(minutes=30)
    run = create_run(client, startedAt="2026-11-12T09:30:00Z")
    assert (run["status"], run["statusMessage"], run["endedAt"]) == ("live", None, None)
    assert "revived" in [c.event for c in notifications]


def test_re_sending_an_ended_run_as_it_was_does_not_revive_it(client, clock):
    """`soliton sync` sends the run again with its original start."""
    create_run(client, startedAt="2026-11-12T08:00:00Z")
    send(client, [{"type": "status", "status": "finished", "time": "2026-11-12T09:00:00Z"}])
    clock.advance(minutes=30)
    run = create_run(client, startedAt="2026-11-12T08:00:00Z")
    assert run["status"] == "finished"


def test_late_upload_of_an_old_run_does_not_revive_it(app, client, clock):
    """`soliton sync` may upload old data after the run was marked lost."""
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


# Field snapshots ----------------------------------------------------------------


def field(step, name="u", shape=(2, 3), target=True, frames=1, **stats):
    import base64
    import struct

    count = frames * math.prod(shape)
    data = base64.b64encode(struct.pack(f"<{count}H", *(i % 65535 for i in range(count)))).decode()
    return {"type": "field", "step": step, "name": name, "kind": "output", "shape": list(shape),
            "originalShape": [s * 2 for s in shape], "frames": frames, "min": -1.0, "max": 1.0,
            "prediction": data, "target": data if target else None,
            "stats": stats or {"relL2": 0.5 / (step + 1)}}


def layer_field(step, layer, position):
    event = field(step, name=f"layers/{layer}", target=False)
    event.update(kind="layer", layer=layer, position=position, reduction="mean of 32 channels",
                 layerShape=[32, 2, 3], stats={})
    return event


SUMMARY = {"kind": "output", "shape": [2, 3], "frames": 1, "layer": None, "position": None}


def test_field_snapshots_are_listed_without_their_data(client):
    create_run(client)
    send(client, [field(0), field(100), field(100, name="p", target=False, relL2="NaN")])
    fields = client.get("/api/runs/tiny-1/fields").json()
    assert fields == [
        {"name": "p", **SUMMARY, "steps": [{"step": 100, "stats": {"relL2": "NaN"}}]},
        {"name": "u", **SUMMARY, "steps": [
            {"step": 0, "stats": {"relL2": 0.5}},
            {"step": 100, "stats": {"relL2": 0.5 / 101}},
        ]},
    ]
    assert client.get("/api/runs/tiny-1").json()["currentStep"] == 100


def test_a_field_snapshot_reads_back_whole(client):
    create_run(client)
    sent = field(100)
    send(client, [field(0), sent])
    latest = client.get("/api/runs/tiny-1/fields/snapshot", params={"name": "u"}).json()
    defaults = {"times": None, "frameStats": {}, "layer": None, "position": None,
                "reduction": None, "layerShape": None, "sample": None, "worstOf": None,
                "extent": None, "axes": None, "spectrum": None}
    assert latest == {**defaults, **{k: v for k, v in sent.items() if k != "type"}}
    first = client.get("/api/runs/tiny-1/fields/snapshot", params={"name": "u", "step": 0})
    assert first.json()["step"] == 0
    missing = client.get("/api/runs/tiny-1/fields/snapshot", params={"name": "u", "step": 5})
    assert missing.status_code == 404
    assert client.get("/api/runs/tiny-1/fields/snapshot", params={"name": "v"}).status_code == 404
    assert client.get("/api/runs/nope/fields").status_code == 404


def test_a_resent_snapshot_replaces_itself(client):
    create_run(client)
    send(client, [field(0, relL2=0.9)])
    send(client, [field(0, relL2=0.1)])
    assert client.get("/api/runs/tiny-1/fields").json()[0]["steps"] == [
        {"step": 0, "stats": {"relL2": 0.1}}
    ]


@pytest.mark.parametrize("change", [
    {"shape": [2, 4]},                 # Data too short for the shape.
    {"shape": [1, 1, 2, 3]},           # 4D.
    {"shape": [513, 1]},               # Too big.
    {"frames": 2},                     # Data for one frame only.
    {"times": [0.0, 1.0]},             # Two times, one frame.
    {"frameStats": {"relL2": [1, 2]}},
    {"kind": "layer"},                 # Without its layer.
    {"prediction": "not base64!"},
    {"target": "AAAA"},                # Target of another size.
])
def test_bad_field_snapshots_are_rejected(client, change):
    create_run(client)
    response = client.post("/api/runs/tiny-1/events", json={"events": [{**field(0), **change}]})
    assert response.status_code == 422


def test_deleting_a_run_deletes_its_fields(client):
    create_run(client)
    send(client, [field(0)])
    client.delete("/api/runs/tiny-1")
    create_run(client)
    assert client.get("/api/runs/tiny-1/fields").json() == []


def test_rollouts_and_3d_fields(client):
    create_run(client)
    rollout = {**field(0, name="u(t)", frames=4), "times": [0, 0.1, 0.2, 0.3],
               "frameStats": {"relL2": [0.01, 0.02, 0.04, "NaN"]}}
    volume = field(0, name="p", shape=(4, 5, 6))
    send(client, [rollout, volume])
    fields = {f["name"]: f for f in client.get("/api/runs/tiny-1/fields").json()}
    assert (fields["u(t)"]["frames"], fields["p"]["shape"]) == (4, [4, 5, 6])
    back = client.get("/api/runs/tiny-1/fields/snapshot", params={"name": "u(t)"}).json()
    assert back["times"] == [0, 0.1, 0.2, 0.3]
    assert back["frameStats"] == {"relL2": [0.01, 0.02, 0.04, "NaN"]}
    # 65 frames of 512 x 512: over the 16M cap (checked before the data is read).
    huge = {**field(1, name="big", target=False), "shape": [512, 512], "frames": 65}
    assert client.post("/api/runs/tiny-1/events", json={"events": [huge]}).status_code == 422


def test_layer_snapshots_come_after_outputs_in_model_order(client):
    create_run(client)
    send(client, [layer_field(0, "projection", 5), field(0), layer_field(0, "lifting", 0),
                  layer_field(0, "blocks.0", 1)])
    fields = client.get("/api/runs/tiny-1/fields").json()
    assert [f["name"] for f in fields] == ["u", "layers/lifting", "layers/blocks.0",
                                           "layers/projection"]
    assert fields[1]["layer"] == "lifting" and fields[1]["kind"] == "layer"
    snapshot = client.get("/api/runs/tiny-1/fields/snapshot",
                          params={"name": "layers/blocks.0"}).json()
    assert snapshot["reduction"] == "mean of 32 channels"
    assert snapshot["layerShape"] == [32, 2, 3]


# Validation sets, curves, and what's needed for sweeps -------------------------


def test_a_field_keeps_its_domain_and_spectrum(client):
    create_run(client)
    sent = {**field(0), "extent": [[0, 6.28], [0, 1]], "axes": ["x", "y"],
            "spectrum": {"k": [1, 2, 3], "prediction": [1.0, 0.1, "NaN"], "target": [1.0, 0.2, 0.01]}}
    send(client, [sent])
    back = client.get("/api/runs/tiny-1/fields/snapshot", params={"name": "u"}).json()
    assert back["extent"] == [[0, 6.28], [0, 1]] and back["axes"] == ["x", "y"]
    assert back["spectrum"]["prediction"] == [1.0, 0.1, "NaN"]
    bad = {**field(1), "axes": ["x"]}  # One name for two axes.
    assert client.post("/api/runs/tiny-1/events", json={"events": [bad]}).status_code == 422


def test_a_validation_set_and_its_worst_samples(client):
    create_run(client)
    worst = {**field(5, name="worst/u/1"), "kind": "worst", "layer": "u #1", "position": 1,
             "sample": 17, "worstOf": "u"}
    summary = {"type": "eval", "step": 5, "name": "u", "count": 200,
               "stats": {"median": 0.02, "p90": 0.05, "max": "NaN"},
               "histogram": {"edges": [0.01, 0.1, 1], "counts": [150, 50]},
               "worst": [{"rank": 1, "sample": 17, "relL2": 0.3}]}
    send(client, [field(5), worst, summary])
    assert client.get("/api/runs/tiny-1/evals").json() == [{"name": "u", "steps": [
        {"step": 5, "count": 200, "stats": {"median": 0.02, "p90": 0.05, "max": "NaN"},
         "histogram": {"edges": [0.01, 0.1, 1], "counts": [150, 50]},
         "worst": [{"rank": 1, "sample": 17, "relL2": 0.3}]},
    ]}]
    fields = client.get("/api/runs/tiny-1/fields").json()
    assert [f["name"] for f in fields] == ["u", "worst/u/1"], "worst samples after outputs"
    assert fields[1]["worstOf"] == "u" and fields[1]["kind"] == "worst"


def test_curves_and_fourier_weights(client):
    create_run(client)
    curve = {"type": "curve", "step": 3, "name": "error vs resolution", "x": [32, 64, 128],
             "y": [0.03, 0.02, "NaN"], "xLabel": "Resolution", "yLabel": "Relative L2",
             "trainRange": [32, 64]}
    weights = {**field(3, name="weights/blocks.0.weights1", target=False), "kind": "weights",
               "layer": "blocks.0.weights1", "position": 0, "stats": {}}
    send(client, [curve, weights])
    (stored,) = client.get("/api/runs/tiny-1/curves").json()
    assert stored["steps"][0]["y"] == [0.03, 0.02, "NaN"]
    assert stored["steps"][0]["trainRange"] == [32, 64]
    assert client.get("/api/runs/tiny-1/fields").json()[0]["kind"] == "weights"
    bad = {**curve, "y": [1]}
    assert client.post("/api/runs/tiny-1/events", json={"events": [bad]}).status_code == 422


def test_latest_and_best_metrics_across_runs(client):
    create_run(client, run_id="a")
    create_run(client, run_id="b")
    send(client, [metrics(0, val__rel_l2=0.5), metrics(10, val__rel_l2=0.1),
                  metrics(20, val__rel_l2=0.2, perf__inference_s=0.01)], run_id="a")
    send(client, [metrics(0, val__rel_l2="NaN")], run_id="b")
    latest = client.get("/api/metrics/latest", params={"names": "val/rel_l2,perf/inference_s"})
    assert latest.json() == {
        "a": {"val/rel_l2": {"latest": 0.2, "min": 0.1},
              "perf/inference_s": {"latest": 0.01, "min": 0.01}},
        "b": {"val/rel_l2": {"latest": "NaN", "min": None}},
    }


def test_deleting_a_run_deletes_its_evals_and_curves(client):
    create_run(client)
    send(client, [{"type": "curve", "step": 0, "name": "c", "x": [1], "y": [2]}])
    client.delete("/api/runs/tiny-1")
    create_run(client)
    assert client.get("/api/runs/tiny-1/curves").json() == []


def test_a_simulation_is_a_run_with_its_simulated_time(client):
    assert create_run(client)["simulation"] is None, "a training run"
    sim = {"tEnd": 10, "cflLimit": 1.0, "monitor": "energy"}
    created = create_run(client, "kh-1", hyperparameters={"Re": "10000"}, totalSteps=0,
                         simulation=sim)
    assert created["simulation"] == {**sim, "time": None, "preview": []}
    send(client, [metrics(i, sim__t=0.5 * i, energy=1.0 - 0.01 * i, cfl=0.4) for i in range(5)],
         run_id="kh-1")
    run = client.get("/api/runs/kh-1").json()
    assert run["simulation"]["time"] == 2.0, "the latest simulated time"
    assert run["simulation"]["preview"] == [1.0, 0.99, 0.98, 0.97, 0.96]
    assert run["lossPreview"] == []
    names = {s["name"] for s in client.get("/api/runs/kh-1/metrics").json()}
    assert {"sim/t", "energy", "cfl"} <= names, "values are ordinary metrics"


def test_a_diverged_simulation_stays_diverged(client):
    create_run(client, "burgers", simulation={"tEnd": 1})
    send(client, [metrics(0, sim__t=0.8, energy="NaN"),
                  {"type": "status", "status": "crashed", "diverged": True,
                   "message": "Diverged at t = 0.8: energy is NaN"}], run_id="burgers")
    run = client.get("/api/runs/burgers").json()
    assert run["status"] == "crashed" and run["simulation"]["diverged"] is True
    assert run["statusMessage"].startswith("Diverged")
    # The logger resending the description doesn't forget it.
    assert create_run(client, "burgers", simulation={"tEnd": 1})["simulation"]["diverged"] is True
    # A training run's crash is never a divergence.
    create_run(client)
    send(client, [{"type": "status", "status": "crashed", "diverged": True}])
    assert client.get("/api/runs/tiny-1").json()["simulation"] is None
    client.delete("/api/runs/burgers")
    assert client.get("/api/runs/burgers").status_code == 404


def test_bad_simulation_settings_are_rejected(client):
    for bad in ({"tEnd": 0}, {"tEnd": "NaN"}, {"cflLimit": -1}, {"monitor": ""}):
        response = client.put("/api/runs/s", json={"name": "s", "simulation": bad})
        assert response.status_code == 422, bad


PREVIEW = {"name": "sample 0, w", "shape": [2, 2], "min": -1.0, "max": 1.0,
           "data": "AAD//wAA//8="}
DATASET = {
    "name": "ns2d-vorticity", "version": "v3", "samples": 10000,
    "splits": {"train": 8000, "val": 1000, "test": 1000}, "sampleShape": [64, 64, 50],
    "sizeBytes": 42_000_000_000, "format": "HDF5", "location": "/scratch/ns2d/v3.h5",
    "host": "Sherlock", "source": "Simulated", "fingerprint": "a41f",
    "variables": [{"name": "w", "description": "vorticity", "min": -4.1, "max": "NaN"}],
    "previews": [PREVIEW],
}


def test_a_dataset_is_registered_and_listed_without_its_previews(client):
    assert client.get("/api/datasets").json() == []
    stored = client.put("/api/datasets/ns2d-vorticity-v3", json=DATASET).json()
    assert stored["id"] == "ns2d-vorticity-v3" and stored["previews"] == [PREVIEW]
    assert stored["variables"][0]["max"] == "NaN"
    assert stored["usedBy"] == [] and stored["madeBy"] is None
    (listed,) = client.get("/api/datasets").json()
    assert "previews" not in listed and listed["samples"] == 10000
    assert client.get("/api/datasets/nope").status_code == 404


def test_runs_that_use_a_dataset_and_the_simulation_that_made_it(client):
    create_run(client, "gen", simulation={"tEnd": 1})
    client.put("/api/datasets/ns2d", json={**DATASET, "madeBy": "gen"})
    # A run may name a dataset before it is registered.
    assert create_run(client, "fno-1", datasets=["ns2d", "ns2d", "later"])["datasets"] == [
        "later", "ns2d"]
    create_run(client, "fno-2", datasets=["ns2d"])
    dataset = client.get("/api/datasets/ns2d").json()
    assert dataset["madeBy"] == {"id": "gen", "name": "tiny", "project": "tests",
                                 "status": "live", "simulation": True}
    assert [r["id"] for r in dataset["usedBy"]] == ["fno-1", "fno-2"]
    # Resent without datasets (an older logger): kept. With: replaced.
    assert create_run(client, "fno-1")["datasets"] == ["later", "ns2d"]
    assert create_run(client, "fno-1", datasets=[])["datasets"] == []
    client.delete("/api/runs/fno-2")
    assert client.get("/api/datasets/ns2d").json()["usedBy"] == []
    assert client.delete("/api/datasets/ns2d").status_code == 204
    assert client.get("/api/datasets/ns2d").status_code == 404


def test_bad_datasets_are_rejected(client):
    for bad in ({"name": ""}, {**DATASET, "samples": -1},
                {**DATASET, "previews": [{**PREVIEW, "shape": [3, 3]}]},
                {**DATASET, "previews": [{**PREVIEW, "shape": [200, 200]}]}):
        assert client.put("/api/datasets/d", json=bad).status_code == 422
    assert client.put("/api/datasets/bad id", json=DATASET).status_code in (404, 422)


def test_dataset_changes_are_announced_live(client):
    with client.websocket_connect("/api/live") as socket:
        socket.send_json({"type": "auth", "token": TOKEN})
        assert socket.receive_json()["type"] == "ready"
        client.put("/api/datasets/d", json=DATASET)
        assert socket.receive_json() == {"type": "dataset", "event": "updated", "datasetId": "d"}


def output(start, *lines):
    return {"type": "output", "start": start, "lines": list(lines)}


def test_a_runs_output_is_kept_in_order_and_resending_is_harmless(client):
    create_run(client)
    assert client.get("/api/runs/tiny-1/output").json() == {"lines": [], "total": 0}
    send(client, [output(0, "epoch 1", "epoch 2")])
    send(client, [output(2, "Traceback (most recent call last):", "RuntimeError: NaN")])
    send(client, [output(2, "Traceback (most recent call last):", "RuntimeError: NaN")])
    got = client.get("/api/runs/tiny-1/output").json()
    assert got == {
        "lines": ["epoch 1", "epoch 2", "Traceback (most recent call last):",
                  "RuntimeError: NaN"],
        "total": 4,
    }
    assert client.get("/api/runs/nope/output").status_code == 404


def test_only_the_latest_output_lines_are_kept(client):
    create_run(client)
    send(client, [output(0, *[f"line {i}" for i in range(1000)])])
    send(client, [output(1000, *[f"line {i}" for i in range(1000, 1500)])])
    got = client.get("/api/runs/tiny-1/output").json()
    assert got["total"] == 1500 and len(got["lines"]) == 1000
    assert (got["lines"][0], got["lines"][-1]) == ("line 500", "line 1499")


def test_every_point_of_a_metric_reads_back_a_page_at_a_time(client):
    create_run(client)
    send(client, [metrics(step, train__loss=1.0 / (step + 1)) for step in range(25)]
         + [metrics(25, train__loss="NaN")])
    first = client.get("/api/runs/tiny-1/metrics/points",
                       params={"name": "train/loss", "limit": 10}).json()
    assert first["steps"] == list(range(10)) and first["next"] == 9
    assert first["values"][:2] == [1.0, 0.5]
    steps, values, after = [], [], -1
    while after is not None:
        page = client.get("/api/runs/tiny-1/metrics/points",
                          params={"name": "train/loss", "after": after, "limit": 10}).json()
        steps += page["steps"]
        values += page["values"]
        after = page["next"]
    assert steps == list(range(26)) and values[-1] == "NaN", "nothing thinned out"
    empty = client.get("/api/runs/tiny-1/metrics/points", params={"name": "nope"}).json()
    assert empty == {"name": "nope", "steps": [], "values": [], "next": None}
    assert client.get("/api/runs/missing/metrics/points", params={"name": "x"}).status_code == 404


def test_a_runs_metrics_summarised(client):
    create_run(client)
    send(client, [metrics(0, train__loss=2.0, val__accuracy=0.1), metrics(5, train__loss=0.5),
                  metrics(9, train__loss=0.7, val__accuracy=0.9), metrics(10, train__loss="NaN")])
    summary = client.get("/api/runs/tiny-1/metrics/summary").json()
    assert summary["train/loss"] == {"count": 4, "first": 2.0, "firstStep": 0, "final": "NaN",
                                     "finalStep": 10, "min": 0.5, "minStep": 5,
                                     "max": 2.0, "maxStep": 0}
    assert (summary["val/accuracy"]["max"], summary["val/accuracy"]["maxStep"]) == (0.9, 9)


# Storage ---------------------------------------------------------------------------

def big_run(client, run_id, steps=3000, fields=3, status="finished"):
    create_run(client, run_id)
    events = [metrics(step, train__loss=1.0 / (step + 1)) for step in range(steps)]
    if steps > 1500:
        events[1500] = metrics(1500, train__loss="NaN")  # A spike that must survive.
    events += [field(s) for s in range(fields)]
    for start in range(0, len(events), 4000):
        send(client, events[start:start + 4000], run_id=run_id)
    if status:
        send(client, [{"type": "status", "status": status}], run_id=run_id)


def test_storage_lists_runs_largest_first(client):
    big_run(client, "big")
    big_run(client, "small", steps=10, fields=1)
    report = client.get("/api/storage").json()
    assert [r["runId"] for r in report["runs"]] == ["big", "small"]
    big = report["runs"][0]
    assert (big["points"], big["snapshots"], big["thinnedAt"]) == (3000, 3, None)
    assert big["thinnable"] and not report["runs"][1]["thinnable"], "small: nothing to thin"
    assert big["bytes"] > report["runs"][1]["bytes"] > 0
    assert report["database"]["engine"] in ("sqlite", "postgresql")
    assert report["thinPoints"] == 1000


def test_thinning_keeps_the_shape_and_the_latest_snapshot(client, notifications):
    big_run(client, "big")
    reply = client.post("/api/runs/big/thin").json()
    assert reply["freed"] > 0 and reply["run"]["thinnedAt"] and reply["run"]["thinnedTo"] == 1000
    curve = client.get("/api/runs/big/metrics/points", params={"name": "train/loss", "limit": 5000}).json()
    assert len(curve["steps"]) <= 1000
    assert curve["steps"][0] == 0 and curve["steps"][-1] == 2999, "the ends survive"
    assert "NaN" in curve["values"], "so does the spike"
    fields = client.get("/api/runs/big/fields").json()
    assert [[st["step"] for st in f["steps"]] for f in fields] == [[2]]
    row = next(r for r in client.get("/api/storage").json()["runs"] if r["runId"] == "big")
    assert row["points"] == len(curve["steps"]) and row["snapshots"] == 1
    assert not row["thinnable"], "nothing left to thin"
    assert ("big", "updated") in [(c.run_id, c.event) for c in notifications]
    again = client.post("/api/runs/big/thin").json()
    assert again["freed"] == 0, "thinning twice changes nothing"


def test_only_an_ended_run_can_be_thinned(client):
    big_run(client, "live", steps=10, status=None)
    assert client.post("/api/runs/live/thin").status_code == 409
    assert client.post("/api/runs/missing/thin").status_code == 404


def test_thinning_runs_that_ended_long_ago(client, clock):
    big_run(client, "old")
    clock.advance(days=40)
    big_run(client, "recent")
    big_run(client, "running", status=None)
    reply = client.post("/api/storage/thin", params={"olderThanDays": 30}).json()
    assert reply["thinned"] == 1 and reply["freed"] > 0
    runs = {r["runId"]: r["thinnedAt"] for r in client.get("/api/storage").json()["runs"]}
    assert runs["old"] and not runs["recent"] and not runs["running"]
    assert client.post("/api/storage/thin", params={"olderThanDays": 30}).json()["thinned"] == 0


def test_compacting_gives_space_back(client, database_url):
    big_run(client, "big", steps=20_000)
    client.post("/api/runs/big/thin")
    reply = client.post("/api/storage/compact").json()
    if database_url.startswith("sqlite"):
        assert reply["after"]["free"] == 0
        assert reply["after"]["bytes"] < reply["before"]["bytes"]


def test_deleting_a_run_deletes_its_thinning(client):
    big_run(client, "big", steps=10)
    client.post("/api/runs/big/thin")
    client.delete("/api/runs/big")
    create_run(client, "big")
    assert client.get("/api/runs/big").json()["thinnedAt"] is None


def test_deleting_a_run_deletes_its_output(client):
    create_run(client)
    send(client, [output(0, "old")])
    client.delete("/api/runs/tiny-1")
    create_run(client)
    assert client.get("/api/runs/tiny-1/output").json()["lines"] == []


# Queued Slurm jobs (`soliton sbatch`) ---------------------------------------------

QUEUED_SLURM = {"jobId": "555", "jobName": "tiny", "state": "PENDING", "reason": "Priority",
                "submitTime": "2026-11-12T08:30:00Z", "cpus": "4", "memory": "16G"}


def queue_job(client, run_id="queued-555", **slurm):
    response = client.put(f"/api/runs/{run_id}", json={
        "name": "tiny", "project": "tests", "host": "Sherlock", "queued": True,
        "startedAt": "2026-11-12T08:30:00Z", "system": {"slurm": {**QUEUED_SLURM, **slurm}},
    })
    assert response.status_code == 200, response.text
    return response.json()


def test_a_queued_job_waits_without_going_stale(app, client, clock):
    run = queue_job(client)
    assert (run["status"], run["startedAt"], run["endedAt"]) == ("queued", "2026-11-12T08:30:00Z", None)
    assert run["system"]["slurm"]["reason"] == "Priority"
    clock.advance(hours=3)
    assert app.state.store.mark_stale(app.state.settings.stale_after) == []
    assert app.state.store.warn_time_limits() == []
    assert client.get("/api/runs/queued-555").json()["status"] == "queued"


def test_soliton_queue_updates_what_slurm_says_of_a_waiting_job(client):
    queue_job(client)
    run = queue_job(client, reason="Resources", expectedStart="2026-11-12T10:00:00Z")
    assert run["status"] == "queued"
    assert run["system"]["slurm"]["reason"] == "Resources"
    assert run["system"]["slurm"]["expectedStart"] == "2026-11-12T10:00:00Z"


def test_a_run_starting_in_a_queued_job_takes_its_place(client, notifications):
    queue_job(client)
    queue_job(client, "queued-556", jobId="556")
    create_run(client, system={"slurm": {"jobId": "555", "submitTime": "2026-11-12T08:30:00Z"}})
    assert client.get("/api/runs/queued-555").status_code == 404
    assert client.get("/api/runs/queued-556").json()["status"] == "queued", "another job"
    assert ("queued-555", "deleted") in [(c.run_id, c.event) for c in notifications]
    assert client.get("/api/runs/tiny-1").json()["status"] == "live"


def test_a_queued_job_with_the_runs_own_id_becomes_the_run(client, notifications):
    """`soliton sbatch --id tiny-1` for a script that calls init(id="tiny-1")."""
    queue_job(client, "tiny-1")
    run = create_run(client, startedAt="2026-11-12T09:00:00Z", system={"slurm": {"jobId": "555"}})
    assert (run["status"], run["startedAt"]) == ("live", "2026-11-12T09:00:00Z")
    assert run["hyperparameters"] == HYPERPARAMETERS
    assert "started" in [c.event for c in notifications]
    assert queue_job(client, "tiny-1")["status"] == "live", "a late `soliton queue` changes nothing"


def started_alerts(notifications):
    return [(c.run_id, c.message) for c in notifications if c.event == "job-started"]


def test_a_queued_job_that_starts_alerts_with_its_wait(client, notifications):
    queue_job(client)
    create_run(client, system={"slurm": {"jobId": "555", "submitTime": "2026-11-12T06:45:00Z"}})
    assert started_alerts(notifications) == [("tiny-1", "Started after 2 h 15 min in the queue.")]


def test_a_queued_job_with_the_runs_own_id_alerts_when_it_starts(client, notifications):
    queue_job(client, "tiny-1")
    create_run(client, startedAt="2026-11-12T09:00:00Z", system={"slurm": {"jobId": "555"}})
    assert started_alerts(notifications) == [("tiny-1", "Its job started.")]


def test_any_slurm_job_that_waited_long_alerts_when_it_starts(client, notifications):
    create_run(client, "waited", system={"slurm": {"jobId": "7", "submitTime": "2026-11-12T08:20:00Z"}})
    create_run(client, "quick", system={"slurm": {"jobId": "8", "submitTime": "2026-11-12T08:58:00Z"}})
    create_run(client, "laptop")
    assert started_alerts(notifications) == [("waited", "Started after 40 min in the queue.")]


def test_a_run_uploaded_long_after_its_job_started_doesnt_alert(client, notifications):
    create_run(client, startedAt="2026-11-10T09:00:00Z",
               system={"slurm": {"jobId": "7", "submitTime": "2026-11-10T06:00:00Z"}})
    assert started_alerts(notifications) == []


def health(kind="nan", step=120, message="train/loss is NaN at step 120"):
    return {"type": "health", "kind": kind, "step": step, "message": message}


def test_a_training_problem_alerts_once_and_shows_on_the_run(client, notifications):
    create_run(client)
    send(client, [metrics(120, train__loss="NaN"), health()])
    send(client, [health()])  # Sent again (a retried upload): no second alert.
    send(client, [health("gradient", 300, "optim/grad_norm blew up")])
    alerts = [(c.run_id, c.message) for c in notifications if c.event == "health"]
    assert alerts == [("tiny-1", "train/loss is NaN at step 120"), ("tiny-1", "optim/grad_norm blew up")]
    shown = client.get("/api/runs/tiny-1").json()["health"]
    assert [(h["kind"], h["step"]) for h in shown] == [("gradient", 300), ("nan", 120)]
    assert shown[1]["message"] == "train/loss is NaN at step 120"


def test_a_training_problem_of_an_ended_run_is_kept_without_an_alert(client, notifications):
    create_run(client)
    send(client, [{"type": "status", "status": "finished"}])
    send(client, [health()])
    assert [c for c in notifications if c.event == "health"] == []
    assert len(client.get("/api/runs/tiny-1").json()["health"]) == 1


def test_an_unknown_kind_of_training_problem_is_refused(client):
    create_run(client)
    response = client.post("/api/runs/tiny-1/events", json={"events": [health("bored")]})
    assert response.status_code == 422


def test_deleting_a_run_deletes_its_training_problems(client):
    create_run(client)
    send(client, [health()])
    client.delete("/api/runs/tiny-1")
    create_run(client)
    assert client.get("/api/runs/tiny-1").json()["health"] == []


def test_a_job_continuing_an_ended_run_queues_it_and_keeps_what_it_logged(client):
    create_run(client)
    send(client, [metrics(500, train__loss=0.5),
                  {"type": "status", "status": "crashed", "message": "Time limit"}])
    run = queue_job(client, "tiny-1", jobId="557")
    assert (run["status"], run["statusMessage"], run["endedAt"]) == ("queued", None, None)
    assert run["hyperparameters"] == HYPERPARAMETERS and run["currentStep"] == 500
    assert run["system"]["slurm"]["jobId"] == "557"


def test_a_job_that_leaves_the_queue_without_starting_ends(client):
    queue_job(client)
    send(client, [{"type": "status", "status": "crashed", "message": "Cancelled before it started"}],
         run_id="queued-555")
    run = client.get("/api/runs/queued-555").json()
    assert (run["status"], run["statusMessage"]) == ("crashed", "Cancelled before it started")



# The job token (Settings → Advanced security in the app) ----------------------

def job_client(app, token):
    return TestClient(app, headers={"Authorization": f"Bearer {token}"})


def test_a_job_token_can_only_add_runs_and_data(app, client):
    assert client.get("/api/session").json()["jobToken"] is False
    token = client.post("/api/job-token").json()["token"]
    assert client.get("/api/session").json()["jobToken"] is True
    create_run(client, "other")
    with job_client(app, token) as job:
        # What a job's logger does, and `soliton queue`:
        create_run(job)
        send(job, [metrics(1, train__loss=1.0)])
        assert job.put("/api/datasets/ns2d", json={"name": "ns2d"}).status_code == 200
        assert job.get("/api/runs", params={"status": "queued"}).status_code == 200
        # Everything else is refused, with why.
        for method, path in [
            ("GET", "/api/runs"), ("GET", "/api/runs/other"), ("GET", "/api/runs/other/metrics"),
            ("GET", "/api/runs/other/output"), ("GET", "/api/datasets"),
            ("GET", "/api/runs/other/metrics/points?name=train/loss"),
            ("GET", "/api/runs/other/metrics/summary"),
            ("PATCH", "/api/runs/other"), ("DELETE", "/api/runs/other"),
            ("DELETE", "/api/datasets/ns2d"), ("GET", "/api/session"),
            ("POST", "/api/job-token"), ("DELETE", "/api/job-token"),
        ]:
            response = job.request(method, path, json={"notes": "x"} if method == "PATCH" else None)
            assert response.status_code == 403, (method, path, response.status_code)
            assert "job token" in response.json()["detail"]
        with pytest.raises(Exception):
            with job.websocket_connect("/api/live") as ws:
                ws.send_json({"type": "auth", "token": token})
                assert ws.receive_json()["type"] == "error"
                ws.receive_json()
    assert client.get("/api/runs/tiny-1").json()["currentStep"] == 1


def test_a_new_job_token_replaces_the_old_and_turning_it_off_refuses_it(app, client):
    old = client.post("/api/job-token").json()["token"]
    new = client.post("/api/job-token").json()["token"]
    with job_client(app, old) as job:
        assert job.put("/api/runs/x", json={"name": "x"}).status_code == 401
    with job_client(app, new) as job:
        assert job.put("/api/runs/x", json={"name": "x"}).status_code == 200
    assert client.delete("/api/job-token").status_code == 204
    assert client.get("/api/session").json()["jobToken"] is False
    with job_client(app, new) as job:
        assert job.put("/api/runs/y", json={"name": "y"}).status_code == 401


def test_the_job_token_survives_a_restart_and_only_its_hash_is_kept(app, client):
    from soliton_server.app import create_app

    token = client.post("/api/job-token").json()["token"]
    assert token not in str(app.state.store.setting("jobTokenHash"))
    restarted = create_app(app.state.settings, stale_check_seconds=0)
    with job_client(restarted, token) as job:
        assert job.put("/api/runs/z", json={"name": "z"}).status_code == 200


def test_runs_can_be_listed_by_status(client):
    create_run(client)
    queue_job(client)
    assert [r["id"] for r in client.get("/api/runs", params={"status": "queued"}).json()] == ["queued-555"]
    assert len(client.get("/api/runs").json()) == 2
    assert client.get("/api/runs", params={"status": "nope"}).status_code == 422


def test_a_continued_run_is_paced_from_where_it_resumed(app, client, clock):
    """Steps from an earlier job don't make the new one look fast."""
    create_run(client)  # 1,000 steps.
    send(client, [metrics(500, train__loss=0.5),
                  {"type": "status", "status": "crashed", "message": "Time limit"}])
    clock.advance(hours=2)
    restart = "2026-11-12T11:00:00Z"
    run = create_run(client, startedAt=restart,
                     system={"slurm": {"jobId": "9", "timeLimitAt": "2026-11-12T11:30:00Z"}})
    assert (run["status"], run["resumedAtStep"]) == ("live", 500)
    clock.advance(minutes=20)
    send(client, [metrics(600, train__loss=0.4)])  # 100 steps in 20 minutes: 400 left, 80 minutes.
    [change] = app.state.store.warn_time_limits()
    assert change.message.startswith("At this pace it needs about 1h 20m more")


def test_a_queued_job_you_cancelled_ends_without_an_alert(client, notifications):
    queue_job(client)
    send(client, [{"type": "status", "status": "crashed", "message": "Cancelled before it started.",
                   "notify": False}], run_id="queued-555")
    [change] = [c for c in notifications if c.event == "crashed"]
    assert change.notify is False and change.to_json()["notify"] is False
    from soliton_server.notify import NtfyNotifier
    assert NtfyNotifier("https://ntfy.sh/topic").message_for(change) is None


def test_each_series_has_its_mean_over_every_point(client):
    create_run(client)
    send(client, [metrics(step, system__cpu=10.0 if step % 10 else 90.0) for step in range(100)])
    series = {s["name"]: s for s in client.get("/api/runs/tiny-1/metrics", params={"maxPoints": 10}).json()}
    assert series["system/cpu"]["mean"] == pytest.approx(18.0), "not (10 + 90) / 2 as the points suggest"


# Rotating the main token -------------------------------------------------------

def test_rotating_the_main_token_retires_the_old_one(app, client):
    new = client.post("/api/token/rotate").json()["token"]
    assert client.get("/api/runs").status_code == 401, "the old token stops working at once"
    with job_client(app, new) as fresh:
        assert fresh.get("/api/runs").status_code == 200


def test_a_rotated_token_survives_a_restart_even_with_the_old_one_still_configured(app, client):
    from soliton_server.app import create_app

    new = client.post("/api/token/rotate").json()["token"]
    restarted = create_app(app.state.settings, stale_check_seconds=0)  # Still configured: the old one.
    with job_client(restarted, TOKEN) as old, job_client(restarted, new) as fresh:
        assert old.get("/api/runs").status_code == 401
        assert fresh.get("/api/runs").status_code == 200


def test_a_token_the_admin_sets_on_purpose_replaces_a_rotated_one(app, client):
    from dataclasses import replace as with_fields

    from soliton_server.app import create_app

    rotated = client.post("/api/token/rotate").json()["token"]
    chosen = create_app(with_fields(app.state.settings, token="set-by-hand-0123456789"), stale_check_seconds=0)
    with job_client(chosen, "set-by-hand-0123456789") as by_hand, job_client(chosen, rotated) as old:
        assert by_hand.get("/api/runs").status_code == 200
        assert old.get("/api/runs").status_code == 401


def test_rotating_rewrites_the_token_file_privately(app, client, tmp_path):
    import os
    import stat
    from dataclasses import replace as with_fields

    from soliton_server.app import create_app

    token_file = tmp_path / "token"
    token_file.write_text(TOKEN + "\n")
    served = create_app(with_fields(app.state.settings, token_file=token_file), stale_check_seconds=0)
    with TestClient(served, headers=AUTH) as c:
        new = c.post("/api/token/rotate").json()["token"]
    assert token_file.read_text().strip() == new
    assert stat.S_IMODE(os.stat(token_file).st_mode) == 0o600


def test_live_connections_made_with_the_old_token_are_closed(client):
    with client.websocket_connect("/api/live") as ws:
        ws.send_json({"type": "auth", "token": TOKEN})
        assert ws.receive_json()["type"] == "ready"
        client.post("/api/token/rotate")
        assert ws.receive_json() == {"type": "error", "message": "The token changed"}


def test_the_job_token_cannot_rotate_the_main_token(app, client):
    job = client.post("/api/job-token").json()["token"]
    with job_client(app, job) as c:
        assert c.post("/api/token/rotate").status_code == 403


# Stopping a run from the app ---------------------------------------------------

def test_a_stop_from_the_app_reaches_the_logger_until_the_run_ends(app, client, clock):
    create_run(client)
    assert "stop" not in send(client, [metrics(1, train__loss=1.0)])
    run = client.post("/api/runs/tiny-1/stop").json()
    assert run["stopRequestedAt"] == "2026-11-12T09:00:00Z"
    assert send(client, [metrics(2, train__loss=0.9)])["stop"] is True
    send(client, [{"type": "status", "status": "finished", "message": "Stopped from the app"}])
    assert client.get("/api/runs/tiny-1").json()["stopRequestedAt"] is None
    assert client.post("/api/runs/tiny-1/stop").status_code == 409, "only a live run"
    # A later job continuing it starts without the old request.
    clock.advance(minutes=5)
    run = create_run(client, startedAt="2026-11-12T09:05:00Z")
    assert run["status"] == "live" and run["stopRequestedAt"] is None


def test_only_the_main_token_can_stop_a_run(app, client):
    create_run(client)
    job = client.post("/api/job-token").json()["token"]
    with job_client(app, job) as c:
        assert c.post("/api/runs/tiny-1/stop").status_code == 403


def test_a_refresh_doesnt_bring_back_a_queued_job_that_started(client):
    """`soliton queue` (or a job refreshing the queue) only updates."""
    response = client.put("/api/runs/queued-999", json={
        "name": "x", "queued": True, "updateOnly": True, "system": {"slurm": {"jobId": "999"}},
    })
    assert response.status_code == 404


# Runs continued over several jobs ----------------------------------------------

def test_a_run_continued_over_jobs_keeps_each_jobs_history(client, clock):
    create_run(client, system={"slurm": {"jobId": "101", "submitTime": "2026-11-12T08:40:00Z"}})
    send(client, [metrics(500, train__loss=0.5),
                  {"type": "status", "status": "crashed", "message": "Stopped by its Slurm time limit"}])
    clock.advance(hours=2)
    create_run(client, startedAt="2026-11-12T11:00:00Z",
               system={"slurm": {"jobId": "102", "submitTime": "2026-11-12T10:30:00Z"}})
    send(client, [metrics(800, train__loss=0.3), {"type": "status", "status": "finished"}])
    jobs = client.get("/api/runs/tiny-1").json()["jobs"]
    assert [(j["jobId"], j["startStep"], j["endStep"], j["status"]) for j in jobs] == [
        ("101", 0, 500, "crashed"), ("102", 500, 800, "finished"),
    ]
    assert jobs[0]["message"] == "Stopped by its Slurm time limit"
    assert (jobs[1]["submittedAt"], jobs[1]["startedAt"]) == ("2026-11-12T10:30:00Z", "2026-11-12T11:00:00Z")


def test_a_job_that_died_without_a_word_is_closed_when_the_next_takes_over(client, clock):
    create_run(client, system={"slurm": {"jobId": "201"}})
    send(client, [metrics(100, train__loss=0.5)])
    clock.advance(minutes=3)  # Killed, and continued before the server noticed.
    create_run(client, startedAt="2026-11-12T09:03:00Z", system={"slurm": {"jobId": "202"}})
    first, second = client.get("/api/runs/tiny-1").json()["jobs"]
    assert (first["jobId"], first["status"], first["endStep"]) == ("201", "crashed", 100)
    assert first["message"].startswith("Ended without a word")
    assert (second["jobId"], second["startStep"], second["endedAt"]) == ("202", 100, None)
    # The same process sending its description again isn't a new job.
    create_run(client, startedAt="2026-11-12T09:03:00Z", system={"slurm": {"jobId": "202"}})
    assert len(client.get("/api/runs/tiny-1").json()["jobs"]) == 2


def test_a_run_gone_quiet_ends_its_job(app, client, clock):
    create_run(client, system={"slurm": {"jobId": "301"}})
    send(client, [metrics(10, train__loss=0.5)])
    clock.advance(minutes=11)
    app.state.store.mark_stale(app.state.settings.stale_after)
    [job] = client.get("/api/runs/tiny-1").json()["jobs"]
    assert (job["status"], job["endStep"]) == ("crashed", 10)
    assert job["message"].startswith("Lost contact")


def test_wrong_tokens_from_one_address_are_throttled(app):
    from soliton_server.app import AUTH_FAILURES_ALLOWED

    with TestClient(app) as anonymous:
        assert anonymous.get("/api/runs").status_code == 401  # No token: not counted.
        for _ in range(AUTH_FAILURES_ALLOWED):
            wrong = anonymous.get("/api/runs", headers={"Authorization": "Bearer guess-0123456789"})
            assert wrong.status_code == 401
        # Then even the right token gets 429: a guesser can't tell it found one.
        throttled = anonymous.get("/api/runs", headers=AUTH)
        assert throttled.status_code == 429
        assert throttled.headers["Retry-After"] == "60"
        assert anonymous.get("/api/health").status_code == 200


def test_an_empty_bearer_token_is_never_accepted(client):
    assert client.get("/api/runs", headers={"Authorization": "Bearer "}).status_code == 401
    assert client.get("/api/runs", headers={"Authorization": ""}).status_code == 401


def test_oversized_bodies_are_refused(app):
    from dataclasses import replace as with_fields

    from soliton_server.app import create_app

    small = create_app(with_fields(app.state.settings, max_body_bytes=1000), stale_check_seconds=0)
    with TestClient(small, headers=AUTH) as c:
        body = {"name": "x", "notes": "n" * 2000}
        assert c.put("/api/runs/big", json=body).status_code == 413

        def chunks():  # No Content-Length: cut off as it arrives.
            yield b'{"name": "x", "notes": "'
            for _ in range(10):
                yield b"n" * 500
            yield b'"}'

        assert c.put("/api/runs/big", content=chunks(),
                     headers={"Content-Type": "application/json"}).status_code == 413
        assert c.put("/api/runs/small", json={"name": "x"}).status_code == 200


def test_with_the_job_token_a_run_changes_only_with_its_key(app, client):
    token = client.post("/api/job-token").json()["token"]
    mine, theirs = {"X-Run-Key": "key-of-mine-0123456789"}, {"X-Run-Key": "someone-else-0123456789"}
    body = {"name": "tiny"}
    events = {"events": [metrics(1, train__loss=1.0)]}
    with job_client(app, token) as job:
        assert job.put("/api/runs/keyed", json=body, headers=mine).status_code == 200
        assert job.post("/api/runs/keyed/events", json=events, headers=mine).status_code == 200
        # A leaked job token, without the key or with another: refused, with why.
        for headers in ({}, theirs):
            refused = job.put("/api/runs/keyed", json={"name": "hijacked"}, headers=headers)
            assert refused.status_code == 403 and "run key" in refused.json()["detail"]
            assert job.post("/api/runs/keyed/events", json=events, headers=headers).status_code == 403
    assert client.get("/api/runs/keyed").json()["name"] == "tiny"
    # The main token may change any run.
    assert client.put("/api/runs/keyed", json={"name": "renamed"}).status_code == 200


def test_runs_from_before_keys_stay_writable_only_while_running(app, client):
    token = client.post("/api/job-token").json()["token"]
    create_run(client, "old-live")  # No key: an older logger.
    create_run(client, "old-done")
    send(client, [{"type": "status", "status": "finished"}], run_id="old-done")
    key = {"X-Run-Key": "first-key-sent-0123456789"}
    with job_client(app, token) as job:
        # Still running: its (older) logger keeps going; a first key claims it.
        assert job.post("/api/runs/old-live/events", json={"events": [metrics(1, train__loss=1.0)]}).status_code == 200
        assert job.put("/api/runs/old-live", json={"name": "tiny"}, headers=key).status_code == 200
        assert job.put("/api/runs/old-live", json={"name": "tiny"}).status_code == 403
        # Ended: only the main token can change it.
        assert job.put("/api/runs/old-done", json={"name": "x"}, headers=key).status_code == 403


def test_soliton_queue_updates_queued_jobs_without_their_keys(app, client):
    token = client.post("/api/job-token").json()["token"]
    queued = {"name": "waiting", "queued": True, "system": {"slurm": {"jobId": "42"}}}
    key = {"X-Run-Key": "sbatch-made-this-0123456789"}
    with job_client(app, token) as job:
        assert job.put("/api/runs/q", json=queued, headers=key).status_code == 200
        refresh = {**queued, "updateOnly": True, "system": {"slurm": {"jobId": "42", "reason": "Priority"}}}
        assert job.put("/api/runs/q", json=refresh).status_code == 200
        cancelled = {"events": [{"type": "status", "status": "crashed", "message": "Cancelled"}]}
        assert job.post("/api/runs/q/events", json=cancelled).status_code == 200
        # But not the description itself, nor once it ended.
        assert job.put("/api/runs/q", json={"name": "x"}).status_code == 403
