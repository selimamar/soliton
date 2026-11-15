"""What the logger records to run a computation again (_repro.py)."""

import subprocess

from soliton._repro import (
    capture_code, command_line, git_info, job_script, redact_script, reproducibility_info,
)


def test_the_command_line_hides_secret_looking_values():
    command = command_line(["train.py", "--lr", "3e-4", "--token", "abc", "--api-key=xyz", "--epochs=5"])
    assert command.endswith("train.py --lr 3e-4 --token '***' '--api-key=***' --epochs=5")
    assert "abc" not in command and "xyz" not in command
    assert command_line(["-c"]) == ""


def test_job_scripts_hide_secret_looking_variables():
    script = "#!/bin/bash\n#SBATCH -G 1\nexport SOLITON_TOKEN=abc123\nexport LR=3e-4\nWANDB_API_KEY='k'\n"
    redacted = redact_script(script)
    assert "abc123" not in redacted and "'k'" not in redacted
    assert "export SOLITON_TOKEN=***" in redacted and "export LR=3e-4" in redacted
    assert "#SBATCH -G 1" in redacted


def fake_git(outputs):
    def run(command, capture_output=True, text=True, timeout=5):
        key = " ".join(command[3:])
        if key in outputs:
            return subprocess.CompletedProcess(command, 0, outputs[key], "")
        return subprocess.CompletedProcess(command, 128, "", "not a git repository")
    return run


def test_git_commit_branch_remote_and_changed_files():
    info = git_info("/repo", fake_git({
        "rev-parse HEAD": "045e08c302bf\n",
        "rev-parse --abbrev-ref HEAD": "main\n",
        "config --get remote.origin.url": "https://me:secret@github.com/lab/fno.git\n",
        "status --porcelain": " M train.py\n?? notes.txt\n",
    }))
    assert info == {
        "commit": "045e08c302bf", "branch": "main",
        "remote": "https://github.com/lab/fno.git",  # No credentials.
        "dirty": ["train.py", "notes.txt"],  # The first line keeps its leading space.
    }
    assert git_info("/not-a-repo", fake_git({})) == {}


def test_the_slurm_job_script_is_read_from_scontrol(monkeypatch):
    import soliton._repro as repro

    monkeypatch.setattr(repro.shutil, "which", lambda name: "/usr/bin/" + name)
    seen = []

    def run(command, capture_output=True, text=True, timeout=5):
        seen.append(command)
        return subprocess.CompletedProcess(command, 0, "#!/bin/bash\nexport SOLITON_TOKEN=x\n", "")

    assert job_script({"SLURM_JOB_ID": "77"}, run) == "#!/bin/bash\nexport SOLITON_TOKEN=***\n"
    assert seen == [["scontrol", "write", "batch_script", "77", "-"]]
    assert job_script({}, run) == ""


def test_it_can_be_turned_off():
    assert capture_code(None, {}) is True
    assert capture_code(None, {"SOLITON_CAPTURE_CODE": "0"}) is False
    assert capture_code(False, {}) is False


def test_everything_together(tmp_path):
    info = reproducibility_info(env={}, argv=["train.py", "--lr", "1"], cwd=str(tmp_path),
                                run=fake_git({}))
    assert info["cwd"] == str(tmp_path)
    assert info["command"].endswith("train.py --lr 1")
    assert "git" not in info and "jobScript" not in info
    assert any(p.startswith("pytest==") for p in info["packages"])


def test_common_secrets_in_a_job_script_are_hidden():
    script = (
        "export OPENAI_KEY=s1 GITHUB_PAT=s2 LR=3e-4\n"
        "export DATABASE_URL=postgres://me:s3@db/x\n"
        "export SOLITON_NTFY_URL=https://ntfy.sh/s4-topic\n"
        "python train.py --api-key=s5 --wandb-key s6 --token s7 --keep 3 --path /data \\\n"
        "    --hf-token \\\n    s8 --epochs=5\n"
        'curl -H "Authorization: Bearer s9" https://x\n'
    )
    redacted = redact_script(script)
    for secret in ("s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9"):
        assert secret not in redacted, secret
    assert "LR=3e-4" in redacted and "--keep 3" in redacted and "--path /data" in redacted
    assert "--epochs=5" in redacted and "postgres://***@db/x" in redacted


def test_the_command_line_hides_more_secret_looking_values():
    command = command_line(["train.py", "--key", "x1", "--auth=x2", "--db", "postgres://u:x3@h",
                            "--token", "--verbose", "--lr", "3e-4"])
    assert not any(s in command for s in ("x1", "x2", "x3"))
    assert "--token --verbose" in command, "a flag after a secret option isn't its value"
    assert "--lr 3e-4" in command


def test_a_git_remote_keeps_no_credentials_or_query():
    from soliton._repro import _without_credentials

    assert _without_credentials("https://t@github.com/a/b?access_token=x") == "https://github.com/a/b"
    assert _without_credentials("git@github.com:a/b.git") == "git@github.com:a/b.git"


def test_printed_secrets_are_hidden_in_the_captured_output():
    from soliton._output import _clean

    line = _clean("using HF_TOKEN=hf_abc and Authorization: Bearer xyz, loss=0.3")
    assert "hf_abc" not in line and "xyz" not in line and "loss=0.3" in line
