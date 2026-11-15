"""`soliton setup`: the token is checked, then saved privately for jobs."""

import os
import stat
import subprocess

from soliton._setup import (
    JOB, MAIN, UNREACHABLE, WRONG, env_lines, normalize_server, run_setup,
)


def setup(tmp_path, kind=MAIN, token="tok-123", server="runs.example.com", **options):
    said = []
    code = run_setup(server, file=str(tmp_path / "env"), ask=lambda _: "",
                     ask_secret=lambda _: token, say=said.append,
                     checker=lambda s, t: (kind, "connection refused"), **options)
    return code, said


def test_a_working_token_is_saved_privately_and_can_be_sourced(tmp_path):
    code, said = setup(tmp_path, token="a b'c")  # Shell quoting matters.
    assert code == 0
    assert any(line.startswith("Main token: works") for line in said)
    path = tmp_path / "env"
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    out = subprocess.run(["bash", "-c", f"source {path}; echo \"$SOLITON_SERVER|$SOLITON_TOKEN\""],
                         capture_output=True, text=True).stdout.strip()
    assert out == "https://runs.example.com|a b'c"


def test_a_job_token_says_so(tmp_path):
    code, said = setup(tmp_path, kind=JOB)
    assert code == 0 and said[1].startswith("Job token: works")


def test_a_wrong_or_unreachable_token_saves_nothing(tmp_path):
    for kind in (WRONG, UNREACHABLE):
        code, said = setup(tmp_path, kind=kind)
        assert code == 1
        assert "Nothing saved" in said[-1]
        assert not (tmp_path / "env").exists()


def test_no_check_saves_anyway(tmp_path):
    code, said = setup(tmp_path, kind=UNREACHABLE, check=False)
    assert code == 0 and "not checked" in said[1]


def test_other_lines_are_kept_and_the_old_token_replaced():
    existing = ("# mine\nexport SOLITON_PRICE_PER_HOUR=0\nexport SOLITON_TOKEN=old\n"
                "SOLITON_SERVER=https://old.example.com\n\n")
    assert env_lines(existing, "https://new.example.com", "new") == (
        "# mine\nexport SOLITON_PRICE_PER_HOUR=0\n"
        "export SOLITON_SERVER=https://new.example.com\nexport SOLITON_TOKEN=new\n"
    )


def test_server_addresses_are_tidied():
    assert normalize_server(" runs.example.com/ ") == "https://runs.example.com"
    assert normalize_server("http://127.0.0.1:8000") == "http://127.0.0.1:8000"
    assert normalize_server("localhost:8001") == "http://localhost:8001", "local servers use http"
    assert normalize_server("127.0.0.1:8000/") == "http://127.0.0.1:8000"


def test_an_empty_token_or_address_saves_nothing(tmp_path):
    assert setup(tmp_path, token="  ")[0] == 2
    assert setup(tmp_path, server="")[0] == 2
    assert not (tmp_path / "env").exists()
