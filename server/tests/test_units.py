from __future__ import annotations

import math
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


def test_settings_from_env(tmp_path):
    settings = Settings.from_env({
        "SOLITON_DATA_DIR": str(tmp_path),
        "SOLITON_TOKEN": "abc",
        "SOLITON_STALE_MINUTES": "2.5",
        "SOLITON_CORS_ORIGINS": "https://a.example, https://b.example",
        "SOLITON_NOTIFY_ON": "crashed",
    })
    assert settings.database_url == f"sqlite:///{(tmp_path / 'soliton.db').resolve()}"
    assert settings.token == "abc"
    assert settings.stale_after.total_seconds() == 150
    assert settings.cors_origins == ("https://a.example", "https://b.example")
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


def test_ntfy_needs_a_topic():
    with pytest.raises(ValueError):
        NtfyNotifier("https://ntfy.sh/")


def test_self_hosted_ntfy_under_a_path():
    notifier = NtfyNotifier("https://example.com/ntfy/topic")
    assert notifier._endpoint == "https://example.com/ntfy"
    assert notifier.message_for(Change("r", "n", "crashed", "crashed"))["topic"] == "topic"
