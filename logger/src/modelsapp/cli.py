"""`modelsapp` command: upload saved runs, or run a demo training."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import List, Optional

from ._upload import EVENTS_FILE, ApiClient, RetryLater, RunFiles, UploadError, upload_pending


def _run_folders(paths: List[str]) -> List[Path]:
    """Run folders in [paths]: each path is a run folder or contains some."""
    folders = []
    for raw in paths:
        path = Path(raw)
        if (path / EVENTS_FILE).exists():
            folders.append(path)
        elif path.is_dir():
            folders.extend(sorted(p.parent for p in path.glob(f"*/{EVENTS_FILE}")))
        else:
            print(f"modelsapp: {path}: not found", file=sys.stderr)
    return folders


def _client(args) -> ApiClient:
    server = args.server or os.environ.get("MODELSAPP_SERVER")
    token = args.token or os.environ.get("MODELSAPP_TOKEN")
    if not server or not token:
        sys.exit("modelsapp: set MODELSAPP_SERVER and MODELSAPP_TOKEN (or pass --server and --token)")
    return ApiClient(server, token)


def sync(args) -> int:
    client = _client(args)
    folders = _run_folders(args.paths or [os.environ.get("MODELSAPP_DIR") or "modelsapp-runs"])
    if not folders:
        print("modelsapp: no saved runs found")
        return 0
    failures = 0
    for folder in folders:
        files = RunFiles(folder)
        try:
            sent = upload_pending(files, client, lambda m: print(f"  {m}", file=sys.stderr))
        except (RetryLater, UploadError) as error:
            print(f"{folder.name}: failed: {error}", file=sys.stderr)
            failures += 1
            continue
        print(f"{folder.name}: " + (f"uploaded {sent:,} records" if sent else "up to date"))
    return 1 if failures else 0


def demo(args) -> int:
    from ._demo import train

    train(steps=args.steps, delay=args.delay, crash_at=args.crash_at, name=args.name)
    return 0


def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="modelsapp", description="ModelsApp training logger.")
    commands = parser.add_subparsers(dest="command", required=True)

    sync_parser = commands.add_parser(
        "sync",
        help="upload runs that were saved offline (or while the server was unreachable)",
    )
    sync_parser.add_argument(
        "paths", nargs="*",
        help="run folders, or folders containing them (default: $MODELSAPP_DIR or ./modelsapp-runs)",
    )
    sync_parser.add_argument("--server", help="default: $MODELSAPP_SERVER")
    sync_parser.add_argument("--token", help="default: $MODELSAPP_TOKEN")
    sync_parser.set_defaults(handler=sync)

    demo_parser = commands.add_parser(
        "demo", help="train a small model on random data, to try the app (needs PyTorch)"
    )
    demo_parser.add_argument("--name", default="demo-mlp")
    demo_parser.add_argument("--steps", type=int, default=3000)
    demo_parser.add_argument(
        "--delay", type=float, default=0.02, help="seconds to wait per step, so charts move"
    )
    demo_parser.add_argument("--crash-at", type=int, help="make the loss NaN at this step, then crash")
    demo_parser.set_defaults(handler=demo)

    args = parser.parse_args(argv)
    sys.exit(args.handler(args))


if __name__ == "__main__":
    main()
