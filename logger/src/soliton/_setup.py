"""`soliton setup`: saves the server's address and a token where jobs read
them (~/.soliton_env), asking for the token without showing it, so it never
goes on a command line, in shell history, or through an agent.

    soliton setup --server https://runs.example.com

Copy the token from the app first (Settings → Advanced security → the job
token, for clusters; or the server's main token), and paste it at the
prompt. The token is checked with the server before anything is saved.
The file is readable by you only; other lines in it are kept. Job scripts
then `source ~/.soliton_env`.
"""

from __future__ import annotations

import getpass
import json
import os
import shlex
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, List, Optional, Tuple

DEFAULT_FILE = "~/.soliton_env"

# What the server says of a token (see check_token).
MAIN, JOB, WRONG, THROTTLED, UNREACHABLE, NOT_SOLITON = (
    "main", "job", "wrong", "throttled", "unreachable", "not-soliton",
)


_LOCAL = ("localhost", "127.0.0.1", "[::1]")


def normalize_server(address: str) -> str:
    """"runs.example.com/" -> "https://runs.example.com"; a local address
    without a scheme ("localhost:8000") gets http://, as local servers use."""
    address = address.strip().rstrip("/")
    if address and "://" not in address:
        host = address.split("/", 1)[0].rsplit(":", 1)[0] if not address.startswith("[") else address.split("]")[0] + "]"
        address = ("http://" if host in _LOCAL else "https://") + address
    return address


def check_token(server: str, token: str, timeout: float = 15) -> Tuple[str, str]:
    """Which kind of token the server takes [token] for, and a detail:
    MAIN, JOB, WRONG, THROTTLED, UNREACHABLE or NOT_SOLITON. The session
    endpoint takes only the main token, and names the job token when it
    refuses it."""
    request = urllib.request.Request(
        server + "/api/session",
        headers={"Authorization": f"Bearer {token}", "User-Agent": "soliton-logger"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read() or b"{}")
            return (MAIN, "") if isinstance(body, dict) and body.get("ok") else (NOT_SOLITON, "")
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        if error.code == 403 and "job token" in detail:
            return JOB, ""
        if error.code == 401:
            return WRONG, ""
        if error.code == 429:
            return THROTTLED, ""
        return NOT_SOLITON, f"HTTP {error.code}"
    except (urllib.error.URLError, OSError, ValueError) as error:
        return UNREACHABLE, str(getattr(error, "reason", error))


def env_lines(existing: str, server: str, token: str) -> str:
    """[existing] (a ~/.soliton_env) with its SOLITON_SERVER and
    SOLITON_TOKEN replaced by these; other lines kept."""
    keep = [
        line for line in existing.splitlines()
        if not _sets(line, "SOLITON_SERVER") and not _sets(line, "SOLITON_TOKEN")
    ]
    while keep and not keep[-1].strip():
        keep.pop()
    return "\n".join([*keep, f"export SOLITON_SERVER={shlex.quote(server)}",
                      f"export SOLITON_TOKEN={shlex.quote(token)}"]) + "\n"


def _sets(line: str, name: str) -> bool:
    words = line.strip().split(None, 1)
    rest = words[1] if words and words[0] == "export" and len(words) > 1 else line.strip()
    return rest.startswith(name + "=")


def write_private(path: Path, text: str) -> None:
    """Replaces [path] with [text], readable by its owner only from the
    first byte (a temporary file, renamed over it)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "w") as file:
            file.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def run_setup(server: Optional[str], file: str = DEFAULT_FILE, check: bool = True,
              ask: Callable[[str], str] = input,
              ask_secret: Callable[[str], str] = getpass.getpass,
              say: Callable[[str], None] = print,
              checker: Callable[[str, str], Tuple[str, str]] = check_token,
              stdin_token: Optional[str] = None) -> int:
    """`soliton setup`. Returns the exit code."""
    server = normalize_server(server or ask("Soliton server address (e.g. https://runs.example.com): "))
    if not server:
        say("soliton setup: no server address given")
        return 2
    say("Copy the token from the app: Settings → Advanced security → Separate token for jobs\n"
        "(for clusters), or the server's main token. Nothing shows while you paste.")
    token = (stdin_token if stdin_token is not None else ask_secret("Paste the Soliton token: ")).strip()
    if not token:
        say("soliton setup: no token given; nothing saved")
        return 2
    kind, detail = (MAIN, "") if not check else checker(server, token)
    messages = {
        WRONG: "The server rejected this token: copy it again from the app. Nothing saved.",
        THROTTLED: "The server is refusing tokens from here for a minute (too many wrong ones). "
                   "Try again shortly. Nothing saved.",
        UNREACHABLE: f"Can't reach {server} ({detail}). "
                     + ("It may serve plain http://: try that address. " if "SSL" in detail else "")
                     + "Check the address, or run this where the server can be reached "
                     "(add --no-check to save it anyway). Nothing saved.",
        NOT_SOLITON: f"{server} answered, but not as a Soliton server{f' ({detail})' if detail else ''}. "
                     "Nothing saved.",
    }
    if kind in messages:
        say(messages[kind])
        return 1
    path = Path(os.path.expanduser(file))
    existing = path.read_text() if path.exists() else ""
    write_private(path, env_lines(existing, server, token))
    shown = file if file.startswith("~") else str(path)
    if not check:
        say(f"Saved {shown} (not checked with the server).")
    elif kind == JOB:
        say(f"Job token: works. Saved {shown}.\n"
            "Jobs can add runs and update their own; your app keeps the main token.")
    else:
        say(f"Main token: works. Saved {shown}.\n"
            "It can do everything. On a shared cluster, the app's job token is safer "
            "(Settings → Advanced security).")
    say(f"In job scripts: source {shown}")
    return 0


def main(args) -> int:
    stdin_token = None
    if not sys.stdin.isatty():  # Piped in, e.g. from a password manager.
        stdin_token = sys.stdin.readline()
    return run_setup(args.server, args.file, check=not args.no_check, stdin_token=stdin_token)
