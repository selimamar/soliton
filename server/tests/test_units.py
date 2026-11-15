from __future__ import annotations

import math
import os
import stat

import pytest

from soliton_server.config import Settings, load_or_create_token, normalize_database_url
from soliton_server.floats import decode_float, downsample, encode_float, from_columns, to_columns
from soliton_server.notify import NtfyNotifier
from soliton_server.store import Change


@pytest.mark.parametrize("value", [1.5, 0.0, -2.0, math.inf, -math.inf])
def test_floats_survive_storage(value):
    assert from_columns(*to_columns(value)) == value
    assert decode_float(encode_float(value)) == value


def test_nan_survives_storage():
    assert math.isnan(from_columns(*to_columns(math.nan)))
    assert encode_float(math.nan) == "NaN"


@pytest.mark.parametrize("bad", ["abc", None, True, [1]])
def test_decode_float_rejects_non_numbers(bad):
    with pytest.raises(ValueError):
        decode_float(bad)


def test_downsample_keeps_spikes_nan_and_the_ends():
    values = [1.0] * 1000
    values[400] = 50.0
    values[700] = math.nan
    sampled = downsample(list(enumerate(values)), 50, lambda p: p[1])
    assert len(sampled) <= 50
    steps = [s for s, _ in sampled]
    assert steps[0] == 0 and steps[-1] == 999
    assert 400 in steps and 700 in steps
    assert steps == sorted(steps)


def test_short_series_are_left_alone():
    points = [(0, 1.0), (1, 2.0)]
    assert downsample(points, 10, lambda p: p[1]) == points


def test_hosting_providers_postgres_urls_get_a_driver():
    assert normalize_database_url("postgres://u:p@h/db") == "postgresql+psycopg://u:p@h/db"
    assert normalize_database_url("postgresql://u@h/db") == "postgresql+psycopg://u@h/db"
    assert normalize_database_url("sqlite:///x.db") == "sqlite:///x.db"


def test_a_generated_token_is_saved_privately(tmp_path):
    token = load_or_create_token(tmp_path)
    assert len(token) >= 30
    assert load_or_create_token(tmp_path) == token
    assert stat.S_IMODE((tmp_path / "token").stat().st_mode) == 0o600


def test_a_private_file_is_never_readable_by_others(tmp_path, monkeypatch):
    """Created with mode 600, not chmodded after: no moment when others can read it."""
    from soliton_server.config import write_private

    os.umask(0o022)
    write_private(tmp_path / "secret", "x")
    assert stat.S_IMODE((tmp_path / "secret").stat().st_mode) == 0o600
    with pytest.raises(FileExistsError):
        write_private(tmp_path / "secret", "y")


def test_settings_from_env(tmp_path):
    settings = Settings.from_env({
        "SOLITON_DATA_DIR": str(tmp_path),
        "SOLITON_TOKEN": "  abcdefghijklmnop-qrstuvwxyz \n",
        "SOLITON_STALE_MINUTES": "2.5",
        "SOLITON_CORS_ORIGINS": "https://a.example, https://b.example",
        "SOLITON_NOTIFY_ON": "crashed",
    })
    assert settings.database_url == f"sqlite:///{(tmp_path / 'soliton.db').resolve()}"
    assert settings.token == "abcdefghijklmnop-qrstuvwxyz"
    assert settings.stale_after.total_seconds() == 150
    assert settings.cors_origins == ("https://a.example", "https://b.example")
    assert not settings.cors_local, "the list says every page allowed"
    assert settings.notify_on == {"crashed"}


def test_ntfy_messages():
    notifier = NtfyNotifier("https://ntfy.sh/my-topic", events=("finished", "crashed"))
    assert notifier._endpoint == "https://ntfy.sh/"
    finished = notifier.message_for(Change("r", "resnet", "finished", "finished", current_step=12000))
    assert finished["topic"] == "my-topic"
    assert finished["title"] == "resnet finished"
    assert finished["message"] == "Finished after 12,000 steps."
    crashed = notifier.message_for(Change("r", "résnet", "crashed", "crashed", message="CUDA OOM"))
    assert crashed["title"] == "résnet crashed"
    assert crashed["message"] == "CUDA OOM"
    assert crashed["priority"] == 4
    assert notifier.message_for(Change("r", "resnet", "updated", "live")) is None
    assert notifier.message_for(Change("r", "resnet", "time-limit", "live")) is None, "not asked for"


def test_ntfy_time_limit_messages_are_on_by_default():
    notifier = NtfyNotifier("https://ntfy.sh/my-topic")
    message = notifier.message_for(
        Change("r", "resnet", "time-limit", "live", message="At this pace it needs about 3h more")
    )
    assert message["title"] == "resnet won't finish before its time limit"
    assert message["message"].startswith("At this pace")
    assert message["priority"] == 4


def test_ntfy_health_and_job_started_messages_are_on_by_default():
    notifier = NtfyNotifier("https://ntfy.sh/my-topic")
    health = notifier.message_for(Change("r", "fno", "health", "live", message="train/loss is NaN at step 120"))
    assert (health["title"], health["message"], health["priority"]) == (
        "fno needs a look", "train/loss is NaN at step 120", 4)
    started = notifier.message_for(Change("r", "fno", "job-started", "live",
                                          message="Started after 2 h in the queue."))
    assert (started["title"], started["message"]) == ("fno started", "Started after 2 h in the queue.")
    assert "priority" not in started
    brief = NtfyNotifier("https://ntfy.sh/my-topic", details=False)
    assert brief.message_for(Change("r", "fno", "health", "live", message="x"))["title"] == "A run needs a look"
    assert brief.message_for(Change("r", "fno", "job-started", "live"))["title"] == "A queued job started"


def test_queue_waits_read_naturally():
    from datetime import timedelta

    from soliton_server.store import _duration

    assert [_duration(timedelta(minutes=m)) for m in (0, 25, 60, 134, 24 * 60, 24 * 60 + 245)] == [
        "0 min", "25 min", "1 h", "2 h 14 min", "1 d", "1 d 4 h"]


def test_ntfy_needs_a_topic():
    with pytest.raises(ValueError):
        NtfyNotifier("https://ntfy.sh/")


def test_self_hosted_ntfy_under_a_path():
    notifier = NtfyNotifier("https://example.com/ntfy/topic")
    assert notifier._endpoint == "https://example.com/ntfy"
    assert notifier.message_for(Change("r", "n", "crashed", "crashed"))["topic"] == "topic"


def test_an_empty_token_file_is_replaced_not_used(tmp_path):
    """An empty token would match requests that send none."""
    (tmp_path / "token").write_text("\n")
    token = load_or_create_token(tmp_path)
    assert len(token) >= 30
    assert (tmp_path / "token").read_text().strip() == token
    assert stat.S_IMODE((tmp_path / "token").stat().st_mode) == 0o600


@pytest.mark.parametrize("token", ["", "   ", "short-token"])
def test_empty_or_short_tokens_are_refused(tmp_path, token):
    from soliton_server.config import TokenTooWeak

    with pytest.raises(TokenTooWeak):
        Settings(database_url="sqlite://", token=token)
    (tmp_path / "token").write_text(token + "\n")
    with pytest.raises(TokenTooWeak):
        Settings.from_env({"SOLITON_DATA_DIR": str(tmp_path), "SOLITON_TOKEN": "short-token"})


def test_the_data_folder_is_made_private(tmp_path):
    from soliton_server.config import secure_data_dir

    data = tmp_path / "data"
    Settings.from_env({"SOLITON_DATA_DIR": str(data)})
    assert stat.S_IMODE(data.stat().st_mode) == 0o700
    (data / "soliton.db").write_text("")
    os.chmod(data / "soliton.db", 0o644)
    os.chmod(data, 0o755)
    secure_data_dir(data)
    assert stat.S_IMODE(data.stat().st_mode) == 0o700
    assert stat.S_IMODE((data / "soliton.db").stat().st_mode) == 0o600


def test_brief_ntfy_messages_name_no_run_and_quote_no_error():
    notifier = NtfyNotifier("https://ntfy.sh/my-topic", details=False)
    crashed = notifier.message_for(Change("r", "secret-project", "crashed", "crashed",
                                          message="KeyError: /home/me/patients.csv"))
    assert crashed["title"] == "A run crashed"
    assert "secret" not in str(crashed) and "patients" not in str(crashed)
    assert crashed["priority"] == 4
    assert notifier.message_for(Change("r", "x", "updated", "live")) is None


def test_auth_failures_block_an_address_for_a_window():
    from soliton_server.app import AuthFailures

    now = [0.0]
    failures = AuthFailures(allowed=3, window=60, clock=lambda: now[0])
    for _ in range(3):
        assert not failures.blocked("1.2.3.4")
        failures.record("1.2.3.4")
    assert failures.blocked("1.2.3.4")
    assert not failures.blocked("5.6.7.8"), "per address"
    now[0] = 61
    assert not failures.blocked("1.2.3.4")


def test_big_hyperparameters_and_architectures_are_cut_not_refused():
    from soliton_server.schemas import ARCHITECTURE_MAX, HYPERPARAMETERS_KEPT, RunIn

    run = RunIn(name="x", hyperparameters={f"k{i}": "v" * 20_000 for i in range(2000)},
                architecture={"name": "m", "children": ["x" * (ARCHITECTURE_MAX + 1)]})
    assert len(run.hyperparameters) == HYPERPARAMETERS_KEPT
    assert all(len(v) < 10_010 for v in run.hyperparameters.values())
    assert run.architecture is None


def test_startup_says_which_web_pages_may_read_the_api():
    from soliton_server.cli import cors_note

    assert "only from this computer" in cors_note({})
    assert "only from this computer" in cors_note({"SOLITON_CORS_ORIGINS": " "})
    assert cors_note({"SOLITON_CORS_ORIGINS": "https://soliton.example.com"}).endswith(
        "from https://soliton.example.com")
    assert "any website" in cors_note({"SOLITON_CORS_ORIGINS": "*"})


def test_which_web_pages_may_read_the_api(tmp_path):
    """By default, pages from this computer (the web app while developing),
    never a website; SOLITON_CORS_ORIGINS lists the allowed ones instead."""
    from fastapi.testclient import TestClient

    from soliton_server.app import create_app

    def allowed(env, origin):
        settings = Settings.from_env({"SOLITON_DATA_DIR": str(tmp_path),
                                      "SOLITON_TOKEN": "test-token-0123456789", **env})
        with TestClient(create_app(settings, stale_check_seconds=0)) as client:
            headers = client.get("/api/health", headers={"Origin": origin}).headers
            return headers.get("access-control-allow-origin")

    assert allowed({}, "https://evil.example") is None
    assert allowed({}, "http://localhost:8787") == "http://localhost:8787"
    assert allowed({}, "http://127.0.0.1:3000") == "http://127.0.0.1:3000"
    assert allowed({}, "http://localhost.evil.example") is None
    assert allowed({}, "https://localhost:8787") is None, "a local page is plain http"
    site = {"SOLITON_CORS_ORIGINS": "https://soliton.example.com"}
    assert allowed(site, "https://soliton.example.com") == "https://soliton.example.com"
    assert allowed(site, "http://localhost:8787") is None, "the list replaces the default"
    assert allowed({"SOLITON_CORS_ORIGINS": "*"}, "https://evil.example") == "*"
