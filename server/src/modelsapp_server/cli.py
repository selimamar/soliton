"""`modelsapp-server`: starts the server."""

from __future__ import annotations

import argparse
import os
import sys

from . import __version__
from .config import Settings


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="modelsapp-server",
        description="Stores training runs sent by the modelsapp logger and serves them to the app.",
        epilog="Settings come from environment variables; see server/README.md.",
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("MODELSAPP_LISTEN_HOST", "127.0.0.1"),
        help="Address to listen on (default: 127.0.0.1, this computer only; "
        "0.0.0.0 to accept connections from other devices).",
    )
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("PORT", "8000")), help="Default: 8000."
    )
    parser.add_argument(
        "--show-token", action="store_true", help="Print the API token and exit."
    )
    args = parser.parse_args(argv)

    settings = Settings.from_env()
    if args.show_token:
        print(settings.token)
        return

    import uvicorn

    from .app import create_app

    database = settings.database_url.split("@")[-1]  # Hide any password.
    print(f"ModelsApp server {__version__}", file=sys.stderr)
    print(f"  Address:  http://{args.host}:{args.port}", file=sys.stderr)
    print(f"  Database: {database}", file=sys.stderr)
    if os.environ.get("MODELSAPP_TOKEN"):
        print("  Token:    from MODELSAPP_TOKEN", file=sys.stderr)
    else:
        print("  Token:    modelsapp-server --show-token", file=sys.stderr)
    if settings.ntfy_url:
        print("  Push notifications: on (ntfy)", file=sys.stderr)
    uvicorn.run(create_app(settings), host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
