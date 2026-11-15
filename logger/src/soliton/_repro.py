"""What it takes to run a computation again, recorded when it starts: the
code's git commit (and whether it had uncommitted changes), the command
line, the working directory, the Slurm job script, and the Python packages.

Standard library only. Values that look like secrets are replaced by "***"
(command-line options and job-script variables named like a token,
password, secret or key; credentials in a git remote's URL). The full diff
of uncommitted changes is never sent: only which files changed. Turn it all
off with SOLITON_CAPTURE_CODE=0 (or `init(capture_code=False)`).
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable, Dict, List, Mapping, Optional
from urllib.parse import urlsplit, urlunsplit

Runner = Callable[..., "subprocess.CompletedProcess[str]"]

# Kept small: it travels with the run's description (the server takes up to
# 20,000 characters for all of the machine's).
MAX_SCRIPT = 6_000
MAX_PACKAGES = 150
MAX_DIRTY = 30

_SECRET = re.compile(r"token|passw|secret|api[-_]?key|private[-_]?key|credential", re.IGNORECASE)


def capture_code(value: Optional[bool], env: Mapping[str, str] = os.environ) -> bool:
    if value is not None:
        return value
    return env.get("SOLITON_CAPTURE_CODE", "").strip().lower() not in ("0", "false", "no", "off")


def reproducibility_info(env: Mapping[str, str] = os.environ, argv: Optional[List[str]] = None,
                         cwd: Optional[str] = None, run: Runner = subprocess.run) -> Dict[str, object]:
    """Everything below that could be found; never raises."""
    argv = list(sys.argv if argv is None else argv)
    cwd = cwd or os.getcwd()
    info: Dict[str, object] = {"cwd": cwd}
    command = command_line(argv)
    if command:
        info["command"] = command
    git = git_info(_script_dir(argv, cwd), run)
    if git:
        info["git"] = git
    script = job_script(env, run)
    if script:
        info["jobScript"] = script
    packages = installed_packages()
    if packages:
        info["packages"] = packages
    return info


def command_line(argv: List[str]) -> str:
    """"python3 train.py --lr 3e-4", with the values of secret-looking
    options replaced by "***"."""
    if not argv or argv[0] in ("", "-c"):
        return ""
    words: List[str] = [Path(sys.executable).name or "python3"]
    hide_next = False
    for word in argv:
        if hide_next:
            words.append("***")
            hide_next = False
            continue
        name, eq, _ = word.partition("=")
        if word.startswith("-") and _SECRET.search(name):
            if eq:
                words.append(f"{name}=***")
            else:
                words.append(word)
                hide_next = True
            continue
        words.append(word)
    return shlex.join(words)


def git_info(directory: str, run: Runner = subprocess.run) -> Dict[str, object]:
    """The commit, branch and remote of the repository [directory] is in,
    and the files with uncommitted changes; {} outside a repository."""
    if shutil.which("git") is None:
        return {}

    def git(*args: str, strip: bool = True) -> Optional[str]:
        try:
            result = run(["git", "-C", directory, *args], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return None
        if result.returncode != 0:
            return None
        return result.stdout.strip() if strip else result.stdout

    commit = git("rev-parse", "HEAD")
    if not commit:
        return {}
    info: Dict[str, object] = {"commit": commit}
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if branch and branch != "HEAD":
        info["branch"] = branch
    remote = git("config", "--get", "remote.origin.url")
    if remote:
        info["remote"] = _without_credentials(remote)
    # Not stripped: each line starts with two status columns, often a space.
    status = git("status", "--porcelain", strip=False)
    if status and status.strip():
        changed = [line[3:] for line in status.splitlines() if len(line) > 3]
        info["dirty"] = changed[:MAX_DIRTY]
        if len(changed) > MAX_DIRTY:
            info["dirtyCount"] = len(changed)
    return info


def job_script(env: Mapping[str, str], run: Runner = subprocess.run) -> str:
    """The Slurm job's batch script (secret-looking variables hidden), or ""."""
    job = env.get("SLURM_JOB_ID")
    if not job or shutil.which("scontrol") is None:
        return ""
    try:
        result = run(["scontrol", "write", "batch_script", job, "-"],
                     capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    script = redact_script(result.stdout)
    return script if len(script) <= MAX_SCRIPT else script[:MAX_SCRIPT] + "\n# … (cut)\n"


def redact_script(text: str) -> str:
    """Hides the values of secret-looking variables: `export SOLITON_TOKEN=x`
    becomes `export SOLITON_TOKEN=***`."""
    def hide(match: re.Match) -> str:
        return f"{match.group(1)}=***" if _SECRET.search(match.group(1)) else match.group(0)

    return re.sub(r"([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"]*\"|'[^']*'|\S+)", hide, text)


def installed_packages() -> List[str]:
    """"numpy==2.1.0", ... for the packages Python can see, sorted."""
    try:
        from importlib.metadata import distributions
    except ImportError:
        return []
    seen = {}
    try:
        for dist in distributions():
            name = (dist.metadata.get("Name") or "").strip()
            if name and name.lower() not in seen:
                seen[name.lower()] = f"{name}=={dist.version}"
    except Exception:
        return []
    return [seen[k] for k in sorted(seen)][:MAX_PACKAGES]


def _script_dir(argv: List[str], cwd: str) -> str:
    script = argv[0] if argv else ""
    if script and script not in ("-c", "-m") and os.path.exists(script):
        return os.path.dirname(os.path.abspath(script)) or cwd
    return cwd


def _without_credentials(url: str) -> str:
    """"https://user:token@github.com/a/b" -> "https://github.com/a/b"."""
    parts = urlsplit(url)
    if parts.scheme and "@" in parts.netloc:
        return urlunsplit((parts.scheme, parts.netloc.rsplit("@", 1)[1], parts.path, parts.query, ""))
    return url
