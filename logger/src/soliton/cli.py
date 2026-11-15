"""`soliton` command: save the server and token for jobs (setup), upload saved
runs, register datasets, submit Slurm jobs that show while queued, or run a
demo training."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import List, Optional

from ._datasets import FORMATS, OTHER_FORMATS, saved_datasets
from ._datasets import describe as describe_dataset
from ._datasets import upload as upload_dataset
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
            print(f"soliton: {path}: not found", file=sys.stderr)
    return folders


def _client(args) -> ApiClient:
    server = args.server or os.environ.get("SOLITON_SERVER")
    token = _token(args)
    if not server or not token:
        sys.exit("soliton: set SOLITON_SERVER and SOLITON_TOKEN (or pass --server and --token)")
    return ApiClient(server, token)


def sync(args) -> int:
    client = _client(args)
    roots = args.paths or [os.environ.get("SOLITON_DIR") or "soliton-runs"]
    failures = 0
    # Datasets first: runs name them.
    for root in roots:
        for dataset_id, description, file in saved_datasets(Path(root)):
            try:
                client.put_dataset(dataset_id, description)
            except (RetryLater, UploadError) as error:
                print(f"dataset {dataset_id}: failed: {error}", file=sys.stderr)
                failures += 1
                continue
            file.unlink()
            print(f"dataset {dataset_id}: uploaded")
    folders = _run_folders(roots)
    if not folders:
        print("soliton: no saved runs found")
        return 1 if failures else 0
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


def data(args) -> int:
    """Registers datasets: one path (`add`), or every data file and folder
    of data files in a folder (`scan`)."""
    server = args.server or os.environ.get("SOLITON_SERVER")
    token = _token(args)
    if args.action == "add":
        targets = [Path(args.path)]
    else:
        root = Path(args.path)
        if not root.is_dir():
            sys.exit(f"soliton: {root}: not a folder")
        targets = sorted(p for p in root.iterdir()
                         if p.suffix.lower() in FORMATS or (p.is_dir() and _has_data(p)))
        if not targets:
            print(f"soliton: no data files in {root}")
            return 0
    failures = 0
    for target in targets:
        try:
            dataset = describe_dataset(
                target, name=args.name if args.action == "add" else None,
                version=args.version or "", source=args.source or "",
                description=args.description or "",
            )
        except (OSError, ValueError) as error:
            print(f"{target}: {error}", file=sys.stderr)
            failures += 1
            continue
        try:
            sent = upload_dataset(dataset, server, token)
        except UploadError as error:
            print(f"{dataset.id}: failed: {error}", file=sys.stderr)
            failures += 1
            continue
        size = dataset.description.get("sizeBytes", 0) / 1e9
        samples = dataset.description.get("samples")
        print(f"{dataset.id}: {size:,.2f} GB" + (f", {samples:,} samples" if samples else "")
              + ("" if sent else " (saved, not uploaded)"))
    return 1 if failures else 0


def _has_data(folder: Path) -> bool:
    known = set(FORMATS) | set(OTHER_FORMATS)
    return any(p.suffix.lower() in known for p in folder.rglob("*"))


def _token(args) -> Optional[str]:
    """--token, else SOLITON_TOKEN. A token on the command line shows in
    `ps` to everyone on a shared login node, so --token gets a warning."""
    if getattr(args, "token", None):
        print("soliton: warning: --token is visible to other users (e.g. in `ps`); "
              "prefer setting SOLITON_TOKEN", file=sys.stderr)
        return args.token
    return os.environ.get("SOLITON_TOKEN")


def sbatch(argv: List[str]) -> int:
    """`soliton sbatch [--name N] [--project P] [--id ID] SBATCH_ARGS...`."""
    from ._queue import sbatch_main, split_sbatch_args

    try:
        own, rest = split_sbatch_args(argv)
    except ValueError as error:
        sys.exit(f"soliton sbatch: {error}")
    if not rest or rest[0] in ("-h", "--help"):
        print(SBATCH_HELP)
        return 0 if rest else 2
    args = argparse.Namespace(sbatch_args=rest, name=own.get("name"), project=own.get("project"),
                              id=own.get("id"), server=own.get("server"), token=own.get("token"))
    server = args.server or os.environ.get("SOLITON_SERVER")
    token = _token(args)
    client = ApiClient(server, token) if server and token else None
    return sbatch_main(args, client)


SBATCH_HELP = """usage: soliton sbatch [--name NAME] [--project PROJECT] [--id RUN_ID] SBATCH_ARGS...

Submits a job with sbatch (everything after soliton's own options goes to
sbatch, e.g. `soliton sbatch -p gpu -G 1 train.sbatch`) and shows it in the
app as queued: how long it has waited, why, and when Slurm expects to start
it. When the job's script calls soliton.init(), its run takes the queued
one's place. `soliton queue` updates what Slurm says of queued jobs.

  --name NAME        shown in the app (default: the job's name)
  --project PROJECT  shown in the app
  --id RUN_ID        the run id the job's script passes to soliton.init(id=...)
                     (e.g. a job continuing a run): that run shows as queued
  --server, --token  default: $SOLITON_SERVER, $SOLITON_TOKEN"""


def setup(args) -> int:
    from ._setup import main as setup_main

    return setup_main(args)


def queue(args) -> int:
    from ._queue import refresh

    try:
        refresh(_client(args))
    except (RetryLater, UploadError, OSError) as error:
        print(f"soliton queue: {error}", file=sys.stderr)
        return 1
    return 0


def demo(args) -> int:
    from ._demo import train

    train(steps=args.steps, delay=args.delay, crash_at=args.crash_at, name=args.name)
    return 0


def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="soliton", description="Soliton training logger.")
    commands = parser.add_subparsers(dest="command", required=True)

    sync_parser = commands.add_parser(
        "sync",
        help="upload runs that were saved offline (or while the server was unreachable)",
    )
    sync_parser.add_argument(
        "paths", nargs="*",
        help="run folders, or folders containing them (default: $SOLITON_DIR or ./soliton-runs)",
    )
    sync_parser.add_argument("--server", help="default: $SOLITON_SERVER")
    sync_parser.add_argument("--token", help="default: $SOLITON_TOKEN (preferred: --token shows in ps)")
    sync_parser.set_defaults(handler=sync)

    data_parser = commands.add_parser(
        "data", help="register datasets with the server (their description, not the data)"
    )
    data_parser.add_argument("action", choices=["add", "scan"],
                             help="add: one file or folder; scan: each data file or folder in a folder")
    data_parser.add_argument("path")
    data_parser.add_argument("--name", help="add only; default: the file's name")
    data_parser.add_argument("--version")
    data_parser.add_argument("--source", help='how it was obtained, e.g. "Simulated", "Experiment"')
    data_parser.add_argument("--description")
    data_parser.add_argument("--server", help="default: $SOLITON_SERVER")
    data_parser.add_argument("--token", help="default: $SOLITON_TOKEN (preferred: --token shows in ps)")
    data_parser.set_defaults(handler=data)

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

    setup_parser = commands.add_parser(
        "setup",
        help="save the server's address and a token in ~/.soliton_env for jobs (asks for the token)",
    )
    setup_parser.add_argument("--server", help="the server's address (asked if not given)")
    setup_parser.add_argument("--file", default="~/.soliton_env", help="default: ~/.soliton_env")
    setup_parser.add_argument("--no-check", action="store_true",
                              help="save without checking the token with the server")
    setup_parser.set_defaults(handler=setup)

    queue_parser = commands.add_parser(
        "queue", help="update what Slurm says of the jobs the app shows as queued (from soliton sbatch)"
    )
    queue_parser.add_argument("--server", help="default: $SOLITON_SERVER")
    queue_parser.add_argument("--token", help="default: $SOLITON_TOKEN (preferred: --token shows in ps)")
    queue_parser.set_defaults(handler=queue)
    commands.add_parser(
        "sbatch", help="submit a Slurm job and show it in the app while it waits (soliton sbatch -h)",
        add_help=False,
    )

    argv = sys.argv[1:] if argv is None else argv
    # sbatch's own arguments aren't soliton's: pass them on untouched.
    if argv[:1] == ["sbatch"]:
        sys.exit(sbatch(argv[1:]))
    args = parser.parse_args(argv)
    sys.exit(args.handler(args))


if __name__ == "__main__":
    main()
