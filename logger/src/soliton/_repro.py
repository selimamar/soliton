"""What it takes to run a computation again, recorded when it starts: the
code's git commit (and whether it had uncommitted changes), the command
line, the working directory, the Slurm job script, and the Python packages.

Standard library only. Values that look like secrets are replaced by "***"
(see `redact`): options and variables named like a token, password, secret
or key, credentials in URLs, and Authorization headers. The full diff of
uncommitted changes is never sent: only which files changed. Turn it all
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

# Names whose values are secrets: HF_TOKEN, --password, AWS_SECRET_ACCESS_KEY,
# OPENAI_KEY, --api-key, GITHUB_PAT, SOLITON_NTFY_URL (the topic is the
# secret), --auth...
_SECRET = re.compile(
    r"token|passw|secret|credential|cookie|bearer|private[-_]?key|access[-_]?key"
    r"|api[-_]?key|(?:^|[-_])(?:key|pat|pw|auth|authorization|dsn)$|ntfy[-_]?(?:url|topic)",
    re.IGNORECASE,
)
# NAME=value, in a script or on a command line.
_ASSIGNMENT = re.compile(r"(?<![\w-])([A-Za-z_][\w-]*)=(\"[^\"]*\"|'[^']*'|[^\s;&|]+)")
# --name value or --name=value (also across a line continuation).
_OPTION = re.compile(r"(?<![\w-])(--?[A-Za-z][\w-]*)((?:[ \t]|\\\n)+|=)(\"[^\"]*\"|'[^']*'|[^\s\\;&|-][^\s;&|]*)")
# user:password@ (or a token@) in any URL.
_URL_CREDENTIALS = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]+@")
# Authorization: Bearer xyz, Basic xyz, token xyz; or a bare "Bearer xyz".
_AUTH_HEADER = re.compile(r"((?:authorization|x-api-key|api-key)\s*[:=]\s*(?:(?:bearer|basic|token)\s+)?|\bbearer\s+)[^\s\"']+",
                          re.IGNORECASE)


def secret_name(name: str) -> bool:
    """Whether a variable or option named [name] holds a secret."""
    return bool(_SECRET.search(name.lstrip("-")))


def redact(text: str) -> str:
    """[text] with what looks like a secret replaced by "***": values of
    secret-looking variables and options, credentials in URLs, and
    Authorization headers. A guess: it can't catch a secret that looks like
    any other word."""
    text = _URL_CREDENTIALS.sub(r"\1***@", text)
    text = _AUTH_HEADER.sub(lambda m: m.group(1) + "***", text)
    text = _ASSIGNMENT.sub(
        lambda m: f"{m.group(1)}=***" if secret_name(m.group(1)) else m.group(0), text)
    return _OPTION.sub(
        lambda m: f"{m.group(1)}{m.group(2)}***" if secret_name(m.group(1)) else m.group(0), text)


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
        if hide_next and not word.startswith("-"):
            words.append("***")
            hide_next = False
            continue
        hide_next = False
        name, eq, _ = word.partition("=")
        if eq and secret_name(name):
            words.append(f"{name}=***")
        elif word.startswith("-") and secret_name(name):
            words.append(word)
            hide_next = True
        else:
            words.append(redact(word))
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
    """The script with its secrets hidden (see `redact`): `export
    SOLITON_TOKEN=x` becomes `export SOLITON_TOKEN=***`, `--api-key x`
    becomes `--api-key ***`."""
    return redact(text)


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
    """"https://user:token@github.com/a/b?access_token=x" ->
    "https://github.com/a/b": no credentials, no query."""
    parts = urlsplit(url)
    if parts.scheme:
        return urlunsplit((parts.scheme, parts.netloc.rsplit("@", 1)[-1], parts.path, "", ""))
    return url
