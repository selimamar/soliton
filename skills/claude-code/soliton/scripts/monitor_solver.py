#!/usr/bin/env python3
"""Run any program (a compiled solver, an MPI launch, a shell script) and
report it to Soliton as a simulation, without changing the program.

    python3 monitor_solver.py --name channel-re180 --project cfd --t-end 50 \\
        --table 'run/diagnostics.dat,t=2,energy=3,residual=5' \\
        --stdout 't=(?P<t>[0-9.eE+-]+)\\s+cfl=(?P<cfl>[0-9.eE+-]+)' \\
        -- srun ./solver input.cfg

It starts the command, passes its output (stdout and stderr, merged)
through to the job's log and to the app's Output panel, and every
--interval seconds reads the values the program writes:

  --table 'GLOB,t=COL,name=COL,...'   text files of whitespace-separated
        numbers, one row per output time (e.g. a diagnostics or scalars
        file). Columns are 1-based, and the time needn't be the first one;
        lines starting with '#' and blank lines are skipped. GLOB may match
        files that appear later, and several files (one per restart
        directory: out-0000/..., out-0001/...); a file reached twice through
        a symlinked directory is read once.
  --h5 'GLOB,dataset=NAME,t=COL,name=COL,...[,legend=ATTR]'   HDF5 files
        with a dataset of one row per output time. COL is a 1-based number
        or a column name: a field of a compound dataset, or a name listed in
        an attribute of the dataset (legend=ATTR; by default "Legend",
        "legend", "columns", "column_names" or "names"). Files and datasets
        that don't exist yet are waited for. Read-only, without HDF5 file
        locking, so the program writing them is never blocked. Needs h5py.
  --stdout 'REGEX'   a regular expression applied to each output line
        (stderr too). Each named group becomes a value of that name, except
        "t", the simulated time.
  --derive 'NAME=EXPR'   a value computed from the others at the same time:
        Python arithmetic with sqrt, hypot, exp, log, log10, sin, cos, tan,
        atan2, pi, abs, min, max, e.g. 'separation=hypot(x1-x2, y1-y2)'.
  --error 'REGEX'    an output line matching it (stderr too) marks the run
        as crashed even if the program exits with 0 (some programs do).
  --continue-code CODE   an exit code that means "stopped to continue in a
        later job" (e.g. after writing a checkpoint): the run ends finished,
        not crashed, and the next job's --id continues it.

Specs are split at commas, then each NAME=COL at its first "="; spaces
around names are trimmed, spaces inside kept (t=Minimum time step works).
A column name containing a comma must be given by number instead.

Rows from all sources are merged by simulated time: values at the same time
become one record (--time-tolerance DT treats times within DT as the same,
for a source that prints the time with fewer digits: 3 decimals -> 0.0005).
A record waits until every source that is still reporting has reached its
time, but never longer than --hold seconds, so a source that stops (or
reports rarely) doesn't hold the others back; its late rows are logged when
they come, at their own time. Rows a source rewrites at or before a time it
already gave, or that an earlier job of the same --id logged, are skipped.
The last row of an HDF5 table is read only once a newer one exists (or the
program has ended), in case it's still being written. Each read logs at
most --max-rows rows, evenly spread. Without --t-end (a run
that ends on an event rather than a time) there's no progress bar or time
left, only the values.

--id ID makes every job of a simulation one run (jobs restarted from
checkpoints): give the same ID from the first job on; later jobs continue
where the earlier ones stopped (step count and simulated time, as saved in
SOLITON_DIR: keep that the same for every job), and a run that had ended
turns live again. IDs are letters, digits, ".", "_" and "-" (use "-"
instead of "/").

The run ends finished if the program exits with 0 (and no --error line was
seen), else crashed with the exit code and its last output line. The first
NaN or infinity logged marks it as diverged. The script exits with the
program's exit code. SIGTERM (a Slurm time limit, scancel) is passed on to
the program and the run is marked as stopped.

Server, token and the local copy come from SOLITON_SERVER, SOLITON_TOKEN,
SOLITON_DIR and SOLITON_MODE, as for any soliton run. Needs Python 3.9+ and
the soliton logger (on PYTHONPATH or installed); h5py only for --h5.
"""

import argparse
import bisect
import glob
import json
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time
from typing import Dict, List, Optional, Tuple

import soliton

Row = Tuple[float, Dict[str, float]]


def matching_files(pattern: str) -> List[str]:
    """Files matching [pattern], each once: a folder reached through a
    symlink as well (e.g. "out-0001" and "out-active" -> "out-0001") isn't
    read twice."""
    seen, files = set(), []
    for path in sorted(glob.glob(pattern)):
        real = os.path.realpath(path)
        if real not in seen and os.path.isfile(real):
            seen.add(real)
            files.append(real)
    return files


class TableSource:
    """New rows of whitespace-separated text files matching a glob."""

    def __init__(self, spec: str):
        parts = [p.strip() for p in spec.split(",")]
        self.pattern = parts[0]
        columns = dict(_pair(p, spec) for p in parts[1:])
        if "t" not in columns:
            raise SystemExit(f"--table {spec!r}: needs t=COLUMN")
        self.t_col = int(columns.pop("t")) - 1
        self.columns = {name: int(col) - 1 for name, col in columns.items()}
        self.offsets: Dict[str, int] = {}

    def read(self, final: bool = False) -> List[Row]:  # Whole lines only, so final changes nothing.
        rows = []
        for path in matching_files(self.pattern):
            try:
                with open(path, "rb") as f:
                    f.seek(self.offsets.get(path, 0))
                    data = f.read()
            except OSError:
                continue
            end = data.rfind(b"\n") + 1  # Only whole lines; the rest next time.
            self.offsets[path] = self.offsets.get(path, 0) + end
            for line in data[:end].decode(errors="replace").splitlines():
                fields = line.split()
                if not fields or line.lstrip().startswith("#"):
                    continue
                try:
                    t = float(fields[self.t_col])
                    values = {name: float(fields[col]) for name, col in self.columns.items()
                              if col < len(fields)}
                except (ValueError, IndexError):
                    continue
                rows.append((t, values))
        return rows


class H5Source:
    """New rows of an HDF5 table: a dataset with one row per output time.

    Columns are named in the spec by number (1-based) or by name: the
    field names of a compound dataset, or the names listed in an attribute
    of the dataset (`legend=ATTR`; by default the first of "Legend",
    "legend", "columns", "column_names" or "names" that exists)."""

    NAME_ATTRIBUTES = ("Legend", "legend", "columns", "column_names", "names")

    def __init__(self, spec: str):
        parts = [p.strip() for p in spec.split(",")]
        self.path = parts[0]
        columns = dict(_pair(p, spec) for p in parts[1:])
        self.dataset = columns.pop("dataset", None)
        self.legend = columns.pop("legend", None)
        self.t_col = columns.pop("t", None)
        if not self.dataset or not self.t_col:
            raise SystemExit(f"--h5 {spec!r}: needs dataset=NAME and t=COLUMN")
        self.columns = columns  # value name -> column (number or name)
        self.seen: Dict[str, int] = {}  # rows read, per file
        os.environ.setdefault("HDF5_USE_FILE_LOCKING", "FALSE")  # The program has it open.

    def read(self, final: bool = False) -> List[Row]:
        rows: List[Row] = []
        for path in matching_files(self.path):
            rows += self._read(path, final)
        return rows

    def _read(self, path: str, final: bool) -> List[Row]:
        # Read-only, without HDF5's file locking (set before h5py is first
        # imported), so the program writing the file is never blocked; a
        # half-written file just fails here and is read again next time.
        try:
            import h5py

            with h5py.File(path, "r") as f:
                table = f[self.dataset]
                fields = list(table.dtype.names or ())
                names = fields or self._attribute_names(table)
                # The last row may still be being written (half of it could
                # read as zeros or NaN): it's read once a newer one exists,
                # or when the program has ended.
                end = len(table) if final else len(table) - 1
                new = table[self.seen.get(path, 0):max(end, self.seen.get(path, 0))]
        except Exception:  # Not there yet, or mid-write: try again next time.
            return []
        self.seen[path] = self.seen.get(path, 0) + len(new)

        def getter(column: str):
            if column.isdigit():  # 1-based column number
                index = int(column) - 1
                return (lambda r: r[fields[index]]) if fields else (lambda r: r[index])
            if column not in names:
                return None
            return (lambda r: r[column]) if fields else (lambda r: r[names.index(column)])

        get_t = getter(self.t_col)
        if get_t is None:
            return []
        getters = {name: g for name, g in ((n, getter(c)) for n, c in self.columns.items())
                   if g is not None}
        return [(float(get_t(r)), {name: float(g(r)) for name, g in getters.items()})
                for r in new]

    def _attribute_names(self, table) -> List[str]:
        for key in ([self.legend] if self.legend else self.NAME_ATTRIBUTES):
            if key in table.attrs:
                return [x.decode() if isinstance(x, bytes) else str(x) for x in table.attrs[key]]
        return []


class Derived:
    """A value computed from others in the same row: --derive 'NAME=EXPR'."""

    FUNCTIONS = {name: getattr(math, name) for name in (
        "sqrt", "hypot", "exp", "log", "log10", "sin", "cos", "tan", "atan2", "pi", "isnan")}
    FUNCTIONS.update(abs=abs, min=min, max=max)

    def __init__(self, spec: str):
        self.name, expression = _pair(spec, "--derive")
        try:
            self.code = compile(expression, "--derive", "eval")
        except SyntaxError as error:
            raise SystemExit(f"--derive {spec!r}: {error.msg}")
        self.needs = [n for n in self.code.co_names if n not in self.FUNCTIONS]

    def add_to(self, values: Dict[str, float]) -> None:
        if all(n in values for n in self.needs):
            try:
                values[self.name] = float(eval(self.code, {"__builtins__": {}},
                                               {**self.FUNCTIONS, **values}))
            except (ArithmeticError, ValueError, TypeError):
                pass


def _pair(text: str, spec: str) -> Tuple[str, str]:
    name, sep, value = text.partition("=")
    if not sep or not name.strip():
        raise SystemExit(f"{spec!r}: expected NAME=VALUE, got {text!r}")
    return name.strip(), value.strip()


def previous_progress(run_id: str) -> Tuple[int, float]:
    """The last step and simulated time an earlier job of run [run_id] saved
    locally, or (-1, -inf)."""
    path = os.path.join(os.environ.get("SOLITON_DIR") or "soliton-runs", run_id, "events.jsonl")
    last_step, last_t = -1, -math.inf
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if '"metrics"' not in line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                last_step = max(last_step, int(record.get("step", -1)))
                t = record.get("values", {}).get("sim/t")
                if isinstance(t, (int, float)):
                    last_t = max(last_t, float(t))
    except OSError:
        pass
    return last_step, last_t


def thin(rows: List[Row], limit: int) -> List[Row]:
    """At most [limit] rows, evenly spread, always the last."""
    if len(rows) <= limit:
        return rows
    step = len(rows) / limit
    picked = [rows[int(i * step)] for i in range(limit - 1)]
    return picked + [rows[-1]]


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Everything after -- is the command to run.")
    parser.add_argument("--name", required=True, help="shown in the app")
    parser.add_argument("--project", default="")
    parser.add_argument("--t-end", type=float, help="simulated time it runs to (progress, time left)")
    parser.add_argument("--max-iterations", type=int, default=0,
                        help="for a steady solve without simulated time")
    parser.add_argument("--monitor", help="the value drawn on its card, e.g. energy")
    parser.add_argument("--cfl-limit", type=float)
    parser.add_argument("--setup", action="append", default=[], metavar="KEY=VALUE",
                        help="how it is set up, shown on its Overview (repeat)")
    parser.add_argument("--tag", action="append", default=[], dest="tags")
    parser.add_argument("--notes", default="")
    parser.add_argument("--id", help="continue this earlier simulation (see above)")
    parser.add_argument("--table", action="append", default=[], metavar="SPEC")
    parser.add_argument("--h5", action="append", default=[], metavar="SPEC")
    parser.add_argument("--stdout", action="append", default=[], metavar="REGEX")
    parser.add_argument("--error", metavar="REGEX")
    parser.add_argument("--derive", action="append", default=[], metavar="NAME=EXPR",
                        help="a value computed from others at the same time, e.g. "
                             "'separation=hypot(x1-x2, y1-y2)' (repeat)")
    parser.add_argument("--continue-code", action="append", default=[], type=int,
                        metavar="CODE",
                        help="an exit code that means stopped to continue in a later job "
                             "(e.g. after writing a checkpoint): finished, not crashed")
    parser.add_argument("--interval", type=float, default=15, help="seconds between reads")
    parser.add_argument("--time-tolerance", type=float, default=0.0, metavar="DT",
                        help="times this close count as the same output time, e.g. 0.0005 "
                             "when one source prints the time with 3 decimals (default: exact)")
    parser.add_argument("--hold", type=float, metavar="SECONDS",
                        help="longest a row waits for slower sources before it is logged "
                             "(default: twice --interval, at least 30)")
    parser.add_argument("--max-rows", type=int, default=200,
                        help="most rows logged per read (evenly spread)")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("give the command to run after --")

    sources = [TableSource(s) for s in args.table] + [H5Source(s) for s in args.h5]
    patterns = [re.compile(p) for p in args.stdout]
    error = re.compile(args.error) if args.error else None
    derived = [Derived(d) for d in args.derive]

    sim = soliton.simulate(
        args.name, project=args.project, t_end=args.t_end, max_iterations=args.max_iterations,
        monitor=args.monitor, cfl_limit=args.cfl_limit, tags=args.tags, notes=args.notes,
        setup={**dict(_pair(s, "--setup") for s in args.setup), "command": " ".join(command)},
        id=args.id,
    )
    last_step, last_t = previous_progress(args.id) if args.id else (-1, -math.inf)
    lock = threading.Lock()
    state = {"step": last_step, "last_line": "", "error": None}

    def log_at_next_step(values: Dict[str, float], t: Optional[float] = None) -> None:
        state["step"] += 1
        sim.log(values, t=t, step=state["step"])

    # Rows from every source are merged by simulated time (times within
    # --time-tolerance count as one) and wait until every source that is
    # still reporting has reached that time, or --hold seconds at most: a file
    # read every --interval seconds lags behind the output lines, and a source
    # that stops (or reports rarely) mustn't hold the others back. A late row
    # is logged when it comes, at its own time.
    tolerance = args.time_tolerance
    hold = args.hold if args.hold is not None else max(30.0, 2 * args.interval)
    keys: List[float] = []                    # pending times, sorted
    pending: Dict[float, Dict[str, float]] = {}
    added: Dict[float, float] = {}            # pending time -> when it came (monotonic)
    latest: Dict[str, Tuple[float, float]] = {}   # source -> (latest time, when it advanced)
    source_last: Dict[str, float] = {}        # source -> last time taken from it

    def add_rows(source: str, rows: List[Row]) -> None:
        with lock:
            now = time.monotonic()
            for t, values in rows:
                # Logged by an earlier job (--id), or rewritten after a restart.
                if t <= last_t or t <= source_last.get(source, -math.inf):
                    continue
                source_last[source] = t
                i = bisect.bisect_left(keys, t - tolerance)
                if i < len(keys) and keys[i] <= t + tolerance:
                    key = keys[i]
                else:
                    key = t
                    keys.insert(i, key)
                    pending[key], added[key] = {}, now
                pending[key].update(values)
                if source not in latest or t > latest[source][0]:
                    latest[source] = (t, now)

    def flush(final: bool = False) -> None:
        with lock:
            now = time.monotonic()
            active = [t for t, since in latest.values() if now - since <= hold]
            reached = math.inf if final or not active else min(active) + tolerance
            ready = [k for k in keys if k <= reached or now - added[k] >= hold]
            rows = [(k, pending.pop(k)) for k in ready]
            for k in ready:
                keys.remove(k)
                del added[k]
            for t, values in thin(rows, args.max_rows):
                for d in derived:
                    d.add_to(values)
                log_at_next_step(values, t)  # The time alone moves the progress bar.

    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, errors="replace", bufsize=1)

    # Slurm's SIGTERM (time limit, scancel) reaches this script: pass it on,
    # then let the logger mark the run as stopped (its handler, set by
    # simulate(), ends this process).
    logger_handler = signal.getsignal(signal.SIGTERM)

    def on_sigterm(signum, frame):
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
        if callable(logger_handler):
            logger_handler(signum, frame)
        else:
            sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, on_sigterm)

    def pump_output() -> None:
        assert process.stdout is not None
        for line in process.stdout:
            line = line.rstrip("\n")
            print(line, flush=True)  # Captured for the app, and still in the job's log.
            if line.strip():
                state["last_line"] = line.strip()
            if error is not None and state["error"] is None and error.search(line):
                state["error"] = line.strip()
            for pattern in patterns:
                match = pattern.search(line)
                if not match:
                    continue
                groups = {k: v for k, v in match.groupdict().items() if v is not None}
                try:
                    values = {k: float(v) for k, v in groups.items()}
                except ValueError:
                    continue
                t = values.pop("t", None)
                if t is None:
                    with lock:
                        if values:
                            log_at_next_step(values)
                else:
                    add_rows(f"stdout {pattern.pattern}", [(t, values)])

    reader = threading.Thread(target=pump_output, daemon=True)
    reader.start()
    while process.poll() is None:
        time.sleep(min(args.interval, 1.0) if not sources else args.interval)
        for i, source in enumerate(sources):
            add_rows(f"file {i}", source.read())
        flush()
    reader.join(timeout=30)
    for i, source in enumerate(sources):  # What it wrote last.
        add_rows(f"file {i}", source.read(final=True))
    flush(final=True)

    code = process.returncode
    if code in args.continue_code:
        sim.finish("finished", f"Stopped with exit code {code}, to continue in a later job")
    elif code != 0:
        why = f"{os.path.basename(command[0])} exited with code {code}"
        sim.finish("crashed", f"{why}: {state['last_line']}" if state["last_line"] else why)
    elif state["error"]:
        sim.finish("crashed", state["error"])
    else:
        sim.finish()
    return code


if __name__ == "__main__":
    sys.exit(main())
