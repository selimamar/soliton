"""The job's output: what the script prints, kept to show with the run.

Python's sys.stdout and sys.stderr are wrapped: everything still goes where
it went (the terminal, Slurm's .out file), and the lines are also sent to
the server every [interval] seconds, numbered so a resent batch replaces
itself. Output written below Python (a C library, a subprocess) isn't seen.
"""

from __future__ import annotations

import re
import sys
import threading
from typing import Callable, List, Optional, Tuple

MAX_LINE = 1000  # Characters kept of one line.
MAX_PENDING = 500  # Lines kept between two sends; older ones are dropped.

# Colours and cursor moves (e.g. from a progress bar or a coloured logger).
_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-_]")


def _clean(line: str) -> str:
    """A line as it ends up on screen: after the last carriage return (a
    progress bar redrawn in place), without escape codes."""
    segments = [s for s in line.split("\r") if s.strip()]
    line = segments[-1] if segments else ""
    line = _ESCAPE.sub("", line).rstrip()
    return line if len(line) <= MAX_LINE else line[:MAX_LINE] + " …"


class OutputCapture:
    """Collects what is printed; [on_lines] gets them, numbered from 0,
    every [interval] seconds (and on `flush`)."""

    def __init__(self, on_lines: Callable[[int, List[str]], None], interval: float = 30) -> None:
        self._on_lines = on_lines
        self._interval = interval
        self._lock = threading.Lock()
        self._pending: List[str] = []
        self._dropped = 0
        self._next = 0  # Number of the next line sent.
        self._partial = {"stdout": "", "stderr": ""}
        self._tees: List[_Tee] = []
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        for name in ("stdout", "stderr"):
            stream = getattr(sys, name)
            if stream is None:  # e.g. pythonw
                continue
            tee = _Tee(stream, self, name)
            setattr(sys, name, tee)
            self._tees.append(tee)
        self._thread = threading.Thread(target=self._loop, name="soliton-output", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        """Sends what's left, then lets the streams be."""
        if self._stop.is_set():
            return
        self._stop.set()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(timeout=5)  # Its batch goes first: lines stay in order.
        self.flush(partial=True)
        for tee in self._tees:
            tee.capture = None
            # Put the stream back, unless something wrapped it since.
            if getattr(sys, tee.name) is tee:
                setattr(sys, tee.name, tee.stream)
        self._tees = []

    def add(self, lines: List[str]) -> None:
        """Adds lines of its own, e.g. a traceback not printed yet."""
        with self._lock:
            for line in lines:
                self._keep(_clean(line))

    def feed(self, name: str, text: str) -> None:
        with self._lock:
            text = self._partial[name] + text
            *lines, partial = text.split("\n")
            if "\r" in partial:  # Only the latest frame of a progress bar.
                partial = partial.rsplit("\r", 1)[-1] or partial.rstrip("\r")
            self._partial[name] = partial[-4 * MAX_LINE:]
            for line in lines:
                self._keep(_clean(line))

    def _keep(self, line: str) -> None:
        self._pending.append(line)
        if len(self._pending) > MAX_PENDING:
            del self._pending[0]
            self._dropped += 1

    def flush(self, partial: bool = False) -> None:
        start, lines = self._take(partial)
        if lines:
            self._on_lines(start, lines)

    def _take(self, partial: bool) -> Tuple[int, List[str]]:
        with self._lock:
            if partial:
                for name, text in self._partial.items():
                    if _clean(text):
                        self._keep(_clean(text))
                    self._partial[name] = ""
            lines = self._pending
            if self._dropped:
                lines = [f"… {self._dropped:,} lines not kept (too much output at once) …",
                         *lines]
            self._pending, self._dropped = [], 0
            start = self._next
            self._next += len(lines)
            return start, lines

    def _loop(self) -> None:
        while not self._stop.wait(self._interval):
            try:
                self.flush()
            except Exception:  # Never break the script over its own output.
                pass


class _Tee:
    """A stream that writes through to [stream] and shows the text to
    [capture]. Everything else (encoding, fileno, isatty, ...) is the
    stream's."""

    def __init__(self, stream, capture: OutputCapture, name: str) -> None:
        self.stream = stream
        self.capture: Optional[OutputCapture] = capture
        self.name = name

    def write(self, text):
        written = self.stream.write(text)
        capture = self.capture
        if capture is not None and isinstance(text, str):
            try:
                capture.feed(self.name, text)
            except Exception:
                pass
        return written

    def writelines(self, lines) -> None:
        for line in lines:
            self.write(line)

    def flush(self) -> None:
        self.stream.flush()

    def __getattr__(self, name):
        return getattr(self.stream, name)
