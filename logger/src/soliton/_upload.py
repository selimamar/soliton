"""Saving a run to disk and uploading it.

Every record is first appended to the run's events.jsonl, then uploaded from
there. So nothing is lost when the network is down (or a cluster's compute
nodes have no internet): `soliton sync` uploads the rest later. The server
ignores duplicates, so uploading a record twice is harmless.
"""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, List, Optional, Tuple

from ._util import dumps

EVENTS_FILE = "events.jsonl"
STATE_FILE = "upload.json"
_BATCH_EVENTS = 500
_BATCH_BYTES = 2_000_000


class UploadError(Exception):
    """The server rejected a request for good (e.g. a wrong token)."""


class RetryLater(Exception):
    """The server is unreachable or busy."""


class ApiClient:
    def __init__(self, server: str, token: str, timeout: float = 30) -> None:
        self.server = server.rstrip("/")
        self._token = token
        self._timeout = timeout

    def put_run(self, run_id: str, body: dict) -> None:
        self._request("PUT", f"/api/runs/{run_id}", body)

    def put_dataset(self, dataset_id: str, body: dict) -> None:
        self._request("PUT", f"/api/datasets/{dataset_id}", body)

    def post_events(self, run_id: str, events: List[dict]) -> Optional[dict]:
        """Sends events; returns the server's reply (e.g. {"stop": true}
        when the run was asked from the app to stop)."""
        reply = self._request("POST", f"/api/runs/{run_id}/events", {"events": events})
        return reply if isinstance(reply, dict) else None

    def get_runs(self, status: Optional[str] = None) -> list:
        """The server's runs; with [status], only those (a job token may only
        list queued ones)."""
        return self._request("GET", "/api/runs" + (f"?status={status}" if status else ""))

    def _request(self, method: str, path: str, body: Optional[dict] = None):
        request = urllib.request.Request(
            self.server + path,
            data=None if body is None else dumps(body).encode(),
            method=method,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._token}",
                "User-Agent": "soliton-logger",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                data = response.read()
            if not data:
                return None
            try:
                return json.loads(data)
            except ValueError:
                return None
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:300]
            if error.code in (408, 425, 429) or error.code >= 500:
                raise RetryLater(f"HTTP {error.code}") from error
            if error.code == 404:
                raise LookupError(detail) from error
            raise UploadError(f"HTTP {error.code}: {detail}") from error
        except (urllib.error.URLError, OSError) as error:  # No network, refused, timeout
            raise RetryLater(str(getattr(error, "reason", error))) from error


class RunFiles:
    """A run's folder: events.jsonl, plus how much of it a server has."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.events = directory / EVENTS_FILE
        self._state = directory / STATE_FILE
        self._lock = threading.Lock()
        self._file = None

    def append(self, record: dict) -> None:
        line = dumps(record) + "\n"
        with self._lock:
            if self._file is None:
                self.directory.mkdir(parents=True, exist_ok=True)
                self._file = open(self.events, "a", encoding="utf-8")
            self._file.write(line)
            self._file.flush()

    def close(self) -> None:
        with self._lock:
            if self._file is not None:
                self._file.close()
                self._file = None

    def size(self) -> int:
        try:
            return self.events.stat().st_size
        except FileNotFoundError:
            return 0

    def uploaded(self, server: str) -> int:
        """Bytes of events.jsonl that [server] already has."""
        try:
            state = json.loads(self._state.read_text())
        except (FileNotFoundError, ValueError):
            return 0
        return int(state.get("offset", 0)) if state.get("server") == server else 0

    def set_uploaded(self, server: str, offset: int) -> None:
        temporary = self._state.with_suffix(".tmp")
        temporary.write_text(json.dumps({"server": server, "offset": offset}))
        os.replace(temporary, self._state)

    def read_from(self, offset: int) -> List[Tuple[int, dict]]:
        """Complete records after [offset], each with the offset after it."""
        records = []
        with open(self.events, "rb") as file:
            file.seek(offset)
            position = offset
            for line in file:
                if not line.endswith(b"\n"):
                    break  # Still being written.
                position += len(line)
                if line.strip():
                    records.append((position, json.loads(line)))
        return records


def upload_pending(files: RunFiles, client: ApiClient, warn: Callable[[str], None],
                   on_reply: Optional[Callable[[dict], None]] = None) -> int:
    """Uploads what the server doesn't have yet. Returns the records sent.
    [on_reply] gets the server's reply to each batch of events.

    Raises RetryLater (try again later) or UploadError (give up).
    """
    offset = files.uploaded(client.server)
    if files.size() <= offset:
        return 0
    records = files.read_from(offset)
    # The first record describes the run; needed to recreate it if the
    # server lost it, even when resuming halfway through the file.
    first = files.read_from(0)[0][1] if offset > 0 else records[0][1]
    run_id = first["id"]
    run_body = _run_body(first)
    sent = 0
    batch: List[dict] = []
    batch_bytes = 0
    batch_end = offset

    def send_batch() -> None:
        nonlocal batch, batch_bytes, sent
        if not batch:
            return
        reply = None
        try:
            reply = client.post_events(run_id, batch)
        except LookupError:
            # The server doesn't know the run (e.g. it was deleted): recreate it.
            client.put_run(run_id, run_body)
            reply = client.post_events(run_id, batch)
        except UploadError as error:
            if "HTTP 422" not in str(error):
                raise
            warn(f"skipped {len(batch)} records the server rejected: {error}")
        if on_reply is not None and reply:
            on_reply(reply)
        sent += len(batch)
        files.set_uploaded(client.server, batch_end)
        batch, batch_bytes = [], 0

    for end, record in records:
        if record.get("type") == "run":  # First record, or a resumed run.
            send_batch()
            run_body = _run_body(record)
            try:
                client.put_run(run_id, run_body)
            except UploadError as error:
                if "HTTP 422" not in str(error):
                    raise
                warn(f"the server rejected the run's description: {error}")
                client.put_run(run_id, {"name": run_body.get("name") or run_id})
            sent += 1
            files.set_uploaded(client.server, end)
            continue
        batch.append(record)
        batch_bytes += len(dumps(record))
        batch_end = end
        if len(batch) >= _BATCH_EVENTS or batch_bytes >= _BATCH_BYTES:
            send_batch()
    send_batch()
    return sent


def _run_body(record: dict) -> dict:
    return {k: v for k, v in record.items() if k not in ("type", "id")}


class Uploader(threading.Thread):
    """Uploads a run's new records every few seconds, in the background."""

    def __init__(
        self,
        files: RunFiles,
        client: ApiClient,
        warn: Callable[[str], None],
        interval: float = 2.0,
        on_reply: Optional[Callable[[dict], None]] = None,
    ) -> None:
        super().__init__(name="soliton-uploader", daemon=True)
        self._files = files
        self._client = client
        self._warn = warn
        self._on_reply = on_reply
        self._interval = interval
        self._wake = threading.Event()
        self._stopping = threading.Event()
        self._idle = threading.Condition()
        self._failed: Optional[str] = None
        self._reported_offline = False

    @property
    def gave_up(self) -> Optional[str]:
        return self._failed

    def pending_bytes(self) -> int:
        return max(0, self._files.size() - self._files.uploaded(self._client.server))

    def run(self) -> None:
        delay = self._interval
        while not self._stopping.is_set():
            self._wake.wait(delay)
            self._wake.clear()
            try:
                upload_pending(self._files, self._client, self._warn, self._on_reply)
                delay = self._interval
                if self._reported_offline:
                    self._warn("connection to the server is back; uploading")
                    self._reported_offline = False
            except RetryLater as error:
                if not self._reported_offline:
                    self._warn(f"server unreachable ({error}); saving locally and retrying")
                    self._reported_offline = True
                delay = min(max(delay * 2, self._interval), 60)
            except UploadError as error:
                self._failed = str(error)
                self._warn(f"upload stopped: {error}. The run is saved locally; upload it "
                           "later with `soliton sync`.")
                return
            finally:
                with self._idle:
                    self._idle.notify_all()

    def flush(self, timeout: float) -> bool:
        """Uploads everything now. False if that didn't finish in time."""
        deadline = time.monotonic() + timeout
        while self.pending_bytes() > 0 and self._failed is None and self.is_alive():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            self._wake.set()
            with self._idle:
                self._idle.wait(min(remaining, 1.0))
        return self.pending_bytes() == 0

    def stop(self) -> None:
        self._stopping.set()
        self._wake.set()
