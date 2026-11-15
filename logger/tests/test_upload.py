from __future__ import annotations

import numpy as np

from soliton import _upload
from soliton._upload import CORE_TYPES, RunFiles, UploadError, upload_pending

from test_logger import offline


class OlderServer:
    """Refuses (422) any batch with record types it doesn't know, as a server
    from before training health and pictures would."""

    def __init__(self, knows=CORE_TYPES):
        self.server = "http://older.example"
        self.knows = knows
        self.received: list = []

    def put_run(self, run_id, body, run_key=None):
        pass

    def post_events(self, run_id, events, run_key=None):
        unknown = {e["type"] for e in events} - self.knows
        if unknown:
            raise UploadError(f"HTTP 422: unknown event type {sorted(unknown)}")
        self.received += events
        return {}


def logged_run(tmp_path):
    run = offline(tmp_path)
    run.log({"train/loss": 1.0}, step=0)
    run.log({"train/loss": float("nan")}, step=1)          # a health record
    run.log_image("picture", np.zeros((2, 2)), step=1)    # an image record
    run.log({"train/loss": 0.5}, step=2)
    run.finish()
    return RunFiles(run.directory)


def test_an_older_server_still_gets_the_metrics(tmp_path, monkeypatch):
    monkeypatch.setattr(_upload, "_warned_older", set())
    server, warnings = OlderServer(), []
    upload_pending(logged_run(tmp_path), server, warnings.append)
    types = [e["type"] for e in server.received]
    assert types.count("metrics") == 3 and "status" in types
    assert "health" not in types and "image" not in types
    assert len(warnings) == 1 and "older than this logger" in warnings[0]
    assert "health, image" in warnings[0]


def test_it_says_so_once_per_server(tmp_path, monkeypatch):
    monkeypatch.setattr(_upload, "_warned_older", set())
    warnings = []
    upload_pending(logged_run(tmp_path / "a"), OlderServer(), warnings.append)
    upload_pending(logged_run(tmp_path / "b"), OlderServer(), warnings.append)
    assert len(warnings) == 1


def test_a_batch_refused_for_another_reason_is_still_skipped(tmp_path, monkeypatch):
    monkeypatch.setattr(_upload, "_warned_older", set())
    server, warnings = OlderServer(knows=frozenset()), []  # Refuses everything.
    upload_pending(logged_run(tmp_path), server, warnings.append)
    assert server.received == []
    assert any(w.startswith("skipped") for w in warnings)
