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
    "datasets",
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


def test_deleting_a_run_deletes_its_output(client):
    create_run(client)
    send(client, [output(0, "old")])
    client.delete("/api/runs/tiny-1")
    create_run(client)
    assert client.get("/api/runs/tiny-1/output").json()["lines"] == []
