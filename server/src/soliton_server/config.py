"""Server settings, read from environment variables."""

from __future__ import annotations

import os
import secrets
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    database_url: str
    """SQLAlchemy URL. SQLite for local use, PostgreSQL for a real server."""

    token: str
    """API token. The logger and the app both send it as a bearer token."""
    token_file: Path | None = None
    """The file the token was read from (None: SOLITON_TOKEN). Rotating the
    token from the app rewrites it, so `--show-token` stays right."""

    stale_after: timedelta = timedelta(minutes=10)
    """A live run that sends nothing for this long is marked as crashed
    ("lost contact"), e.g. a job killed by a time limit. It comes back to
    life if data arrives again."""

    cors_origins: tuple[str, ...] = ("*",)
    """Origins allowed to call the API from a browser (the web app)."""

    ntfy_url: str | None = None
    """Optional push notifications through ntfy (https://ntfy.sh), e.g.
    "https://ntfy.sh/my-secret-topic". Install the ntfy app on your phone and
    subscribe to the same topic."""

    ntfy_token: str | None = None
    """Access token, for a protected (e.g. self-hosted) ntfy topic."""

    notify_on: frozenset[str] = field(
        default_factory=lambda: frozenset({"finished", "crashed", "time-limit"})
    )

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> Settings:
        data_dir = Path(env.get("SOLITON_DATA_DIR") or "soliton-data")
        url = env.get("SOLITON_DATABASE_URL") or env.get("DATABASE_URL")
        if url:
            url = normalize_database_url(url)
        else:
            data_dir.mkdir(parents=True, exist_ok=True)
            url = f"sqlite:///{(data_dir / 'soliton.db').resolve()}"
        token = env.get("SOLITON_TOKEN") or load_or_create_token(data_dir)
        token_file = None if env.get("SOLITON_TOKEN") else data_dir / "token"
        origins = tuple(
            o.strip() for o in env.get("SOLITON_CORS_ORIGINS", "*").split(",") if o.strip()
        )
        notify_on = frozenset(
            e.strip()
            for e in env.get("SOLITON_NOTIFY_ON", "finished,crashed,time-limit").split(",")
            if e.strip()
        )
        return cls(
            database_url=url,
            token=token,
            token_file=token_file,
            stale_after=timedelta(minutes=float(env.get("SOLITON_STALE_MINUTES", "10"))),
            cors_origins=origins,
            ntfy_url=env.get("SOLITON_NTFY_URL") or None,
            ntfy_token=env.get("SOLITON_NTFY_TOKEN") or None,
            notify_on=notify_on,
        )


def normalize_database_url(url: str) -> str:
    """Hosting providers hand out "postgres://" URLs; SQLAlchemy needs the
    driver name."""
    for prefix in ("postgres://", "postgresql://"):
        if url.startswith(prefix):
            return "postgresql+psycopg://" + url[len(prefix) :]
    return url


def load_or_create_token(data_dir: Path) -> str:
    """The token saved in [data_dir], or a new random one (saved there)."""
    path = data_dir / "token"
    if path.exists():
        return path.read_text().strip()
    data_dir.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(24)
    try:
        write_private(path, token + "\n")
    except FileExistsError:  # Another server process made it just now.
        return path.read_text().strip()
    return token


def replace_private(path: Path, text: str) -> None:
    """Replaces [path]'s contents in one step, with a file readable by its
    owner only from the start."""
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(4)}")
    write_private(temporary, text)
    os.replace(temporary, path)


def write_private(path: Path, text: str) -> None:
    """Creates [path] (it mustn't exist) readable by its owner only from the
    start: writing it, then restricting it, would leave it readable by others
    in between."""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as file:
        file.write(text)
