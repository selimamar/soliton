"""Server settings, read from environment variables."""

from __future__ import annotations

import logging
import os
import secrets
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path

log = logging.getLogger(__name__)

MIN_TOKEN_LENGTH = 16
"""Shorter tokens are refused: the server doesn't slow down guessing beyond
a per-address limit, so a token must be too long to guess."""


class TokenTooWeak(ValueError):
    """SOLITON_TOKEN (or the token file) is empty or too short."""


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
        default_factory=lambda: frozenset({"finished", "crashed", "time-limit", "health", "job-started"})
    )

    ntfy_details: bool = True
    """Whether notifications name the run and quote its error. Off: only
    "A run crashed" and the like, for a topic others may read."""

    data_dir: Path | None = None
    """The folder of the SQLite database and the token file, kept readable
    by its owner only."""

    max_body_bytes: int = 128 * 1024 * 1024
    """Larger request bodies are refused (413)."""

    thin_after: timedelta | None = None
    """Thin out runs this long after they end (see Store.thin_run), checked
    hourly; None (the default) never does it by itself."""

    def __post_init__(self) -> None:
        check_token(self.token)

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> Settings:
        data_dir = Path(env.get("SOLITON_DATA_DIR") or "soliton-data")
        url = env.get("SOLITON_DATABASE_URL") or env.get("DATABASE_URL")
        if url:
            url = normalize_database_url(url)
        else:
            data_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            url = f"sqlite:///{(data_dir / 'soliton.db').resolve()}"
        configured = (env.get("SOLITON_TOKEN") or "").strip()
        token = configured or load_or_create_token(data_dir)
        token_file = None if configured else data_dir / "token"
        origins = tuple(
            o.strip() for o in env.get("SOLITON_CORS_ORIGINS", "*").split(",") if o.strip()
        )
        notify_on = frozenset(
            e.strip()
            for e in env.get("SOLITON_NOTIFY_ON", "finished,crashed,time-limit,health,job-started").split(",")
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
            ntfy_details=env.get("SOLITON_NTFY_DETAILS", "1").strip().lower()
            not in ("0", "false", "no", "off"),
            data_dir=data_dir,
            max_body_bytes=int(float(env.get("SOLITON_MAX_BODY_MB", "128")) * 1024 * 1024),
            thin_after=(timedelta(days=float(env["SOLITON_THIN_AFTER_DAYS"]))
                        if env.get("SOLITON_THIN_AFTER_DAYS", "").strip() else None),
        )


def check_token(token: str) -> None:
    """Refuses an empty or short token: with one, the API would be open (an
    empty token matches a request without one) or easy to guess."""
    if len(token.strip()) < MIN_TOKEN_LENGTH:
        raise TokenTooWeak(
            f"The API token must be at least {MIN_TOKEN_LENGTH} characters (it has "
            f"{len(token.strip())}). Set SOLITON_TOKEN to a long random string, e.g. "
            "python3 -c 'import secrets; print(secrets.token_urlsafe(32))', or delete "
            "the data folder's token file to have a new one made."
        )


def secure_data_dir(data_dir: Path) -> None:
    """Makes [data_dir] and the files in it readable by their owner only
    (the database holds everything the runs logged). New files are private
    too: see the umask set in cli.py."""
    try:
        os.chmod(data_dir, 0o700)
        for path in data_dir.iterdir():
            if path.is_file() and not path.is_symlink():
                os.chmod(path, 0o600)
    except OSError as error:
        log.warning("Could not make %s private: %s", data_dir, error)


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
        saved = path.read_text().strip()
        if saved:
            return saved
        # Empty (e.g. the disk filled up as it was written): a token "" would
        # match requests without any, so make a new one.
        token = secrets.token_urlsafe(32)
        replace_private(path, token + "\n")
        log.warning("The token file %s was empty: it now holds a new token.", path)
        return token
    data_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
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
