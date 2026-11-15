"""`soliton-server`: starts the server."""

from __future__ import annotations

import argparse
import os
import sys

from . import __version__
from .config import Settings, TokenTooWeak, database_url_from_env, secure_data_dir


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="soliton-server",
        description="Stores training runs sent by the soliton logger and serves them to the app.",
        epilog="Settings come from environment variables; see server/README.md.",
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("SOLITON_LISTEN_HOST", "127.0.0.1"),
        help="Address to listen on (default: 127.0.0.1, this computer only; "
        "0.0.0.0 to accept connections from other devices).",
    )
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("PORT", "8000")), help="Default: 8000."
    )
    parser.add_argument(
        "--show-token", action="store_true", help="Print the API token and exit."
    )
    parser.add_argument(
        "--backup", metavar="PATH",
        help="Copy the database to PATH (a folder, for a dated file name, or a new file) "
        "and exit. Safe while the server runs. SQLite only: use pg_dump for PostgreSQL.",
    )
    parser.add_argument(
        "--tls-cert", default=os.environ.get("SOLITON_TLS_CERT"),
        help="Serve https with this certificate (PEM; default: $SOLITON_TLS_CERT).",
    )
    parser.add_argument(
        "--tls-key", default=os.environ.get("SOLITON_TLS_KEY"),
        help="The certificate's private key (default: $SOLITON_TLS_KEY).",
    )
    args = parser.parse_args(argv)
    if bool(args.tls_cert) != bool(args.tls_key):
        sys.exit("soliton-server: --tls-cert and --tls-key go together")

    # Everything the server writes (the database, its journal, the token)
    # is readable by you only: it holds everything the runs logged.
    os.umask(0o077)
    if args.backup is not None:
        sys.exit(backup(args.backup))
    try:
        settings = Settings.from_env()
    except TokenTooWeak as error:
        sys.exit(f"soliton-server: {error}")
    if settings.data_dir is not None and settings.data_dir.is_dir():
        secure_data_dir(settings.data_dir)
    if args.show_token:
        print(settings.token)
        return

    import uvicorn

    from .app import create_app

    database = settings.database_url.split("@")[-1]  # Hide any password.
    print(f"Soliton server {__version__}", file=sys.stderr)
    scheme = "https" if args.tls_cert else "http"
    print(f"  Address:  {scheme}://{args.host}:{args.port}", file=sys.stderr)
    if scheme == "http" and args.host not in ("127.0.0.1", "localhost", "::1"):
        print("  Warning:  plain http on a shared network: the token and the data travel "
              "unencrypted (see --tls-cert)", file=sys.stderr)
    print(f"  Database: {database}", file=sys.stderr)
    warning = cors_warning()
    if warning:
        print(f"  Note:     {warning}", file=sys.stderr)
    if os.environ.get("SOLITON_TOKEN"):
        print("  Token:    from SOLITON_TOKEN", file=sys.stderr)
    else:
        print("  Token:    soliton-server --show-token", file=sys.stderr)
    if settings.ntfy_url:
        print("  Push notifications: on (ntfy)", file=sys.stderr)
    uvicorn.run(create_app(settings), host=args.host, port=args.port, log_level="info",
                ssl_certfile=args.tls_cert, ssl_keyfile=args.tls_key)


def cors_warning(env=os.environ) -> str | None:
    """A word at startup while any website may read the API's answers
    (SOLITON_CORS_ORIGINS unset, so "*"). Not a hole: the token is a header
    a browser never adds by itself. But only the web app needs CORS, from one
    address. Setting the variable, even to "*", is a choice: no note then."""
    if (env.get("SOLITON_CORS_ORIGINS") or "").strip():
        return None
    return ("any website may read this server's answers (CORS). Set SOLITON_CORS_ORIGINS "
            "to the web app's address, e.g. https://soliton.example.com, or to "
            "https://none.invalid if you only use the phone and desktop apps")


def backup(destination: str) -> int:
    """`--backup`: copies the database; the exit status."""
    from .backup import BackupError, back_up_file, sqlite_file

    url = database_url_from_env()
    database = sqlite_file(url)
    if database is None:
        print("soliton-server: this server keeps its data in PostgreSQL: back it up with "
              "pg_dump (see the server README)", file=sys.stderr)
        return 1
    try:
        path, size = back_up_file(database, destination)
    except BackupError as error:
        print(f"soliton-server: {error}", file=sys.stderr)
        return 1
    print(f"Backed up {database} to {path} ({_size(size)}).")
    print("It holds everything the runs logged and is readable by you only: keep it that way.")
    return 0


def _size(size: int) -> str:
    for unit in ("bytes", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "bytes" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size} bytes"


if __name__ == "__main__":
    main()
