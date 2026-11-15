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
