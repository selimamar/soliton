"""The HTTP and WebSocket API. See server/README.md for the endpoints."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import pathlib
import secrets
import logging
import tempfile
import threading
import time
from collections import deque
from collections.abc import Callable, Iterable
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from typing import Annotated, Literal, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Path, Query, Request, WebSocket
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.websockets import WebSocketDisconnect

from . import __version__
from .backup import BackupError, back_up_engine, backup_name, remove_stale, sqlite_file
from .config import Settings, check_token, replace_private
from .db import make_engine, make_sessionmaker
from .live import Broadcaster
from .notify import NtfyNotifier
from .schemas import RUN_ID_PATTERN, BoardCardIn, DatasetIn, EventsIn, RunIn, RunNotesIn
from .store import (
    Change,
    DatasetNotFound,
    FieldNotFound,
    ImageNotFound,
    RUN_KEY_REFUSED,
    RunKeyRefused,
    RunNotFound,
    RunNotEnded,
    RunNotLive,
    Store,
    utcnow,
)

log = logging.getLogger(__name__)

RunId = Annotated[str, Path(pattern=RUN_ID_PATTERN)]
# A page served from this computer (Settings.cors_local).
LOCAL_ORIGIN = r"http://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?"
MaxPoints = Annotated[int, Query(ge=4, le=20_000)]
THIN_CHECK = timedelta(hours=1)  # How often automatic thinning looks for old runs.
# Full-resolution reads (`soliton.runs()`), a page at a time.
PageSize = Annotated[int, Query(ge=1, le=50_000)]
# The key a logger made for its run (see Store._check_writer).
RunKey = Annotated[Optional[str], Header(alias="X-Run-Key", max_length=200)]

JOB_TOKEN_KEY = "jobTokenHash"
MAIN_TOKEN_KEY = "mainTokenHash"
RETIRED_TOKENS_KEY = "retiredTokenHashes"
JOB_TOKEN_REFUSED = (
    "This is the job token: it can only add and update runs and data. "
    "Use the server's main token here."
)

_AUTH_TIMEOUT = 5  # Seconds a WebSocket client has to send its token.

# Wrong tokens allowed from one address per window; past that, everything
# from it gets 429 until the window has passed (even a right token, so a
# guesser can't tell when it found one).
AUTH_FAILURES_ALLOWED = 20
AUTH_FAILURE_WINDOW = 60.0


class AuthFailures:
    """Wrong tokens per client address, over the last [window] seconds."""

    def __init__(self, allowed: int = AUTH_FAILURES_ALLOWED, window: float = AUTH_FAILURE_WINDOW,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self._allowed, self._window, self._clock = allowed, window, clock
        self._failures: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def _recent(self, address: str, now: float) -> deque[float]:
        times = self._failures.get(address)
        if times is None:
            return deque()
        while times and times[0] <= now - self._window:
            times.popleft()
        if not times:
            del self._failures[address]
        return times

    def blocked(self, address: str) -> bool:
        with self._lock:
            return len(self._recent(address, self._clock())) >= self._allowed

    def record(self, address: str) -> None:
        with self._lock:
            now = self._clock()
            times = self._recent(address, now)
            if address not in self._failures:
                if len(self._failures) > 10_000:  # Many addresses: forget the oldest.
                    self._failures.pop(next(iter(self._failures)))
                self._failures[address] = times
            times.append(now)


class BodyLimit:
    """Refuses request bodies over [max_bytes] with 413: at once when the
    client gives their size (Content-Length), else as soon as more arrives."""

    def __init__(self, app, max_bytes: int) -> None:
        self.app, self.max_bytes = app, max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers") or [])
        length = headers.get(b"content-length")
        if length is not None and (not length.isdigit() or int(length) > self.max_bytes):
            return await JSONResponse(status_code=413, content={"detail": "Request too large"})(
                scope, receive, send)
        received = 0
        exceeded = started = False

        async def limited_receive():
            nonlocal received, exceeded
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    exceeded = True
                    raise _TooLarge()
            return message

        async def tracking_send(message):
            nonlocal started
            if exceeded:  # FastAPI answers 400 for a body it couldn't read: ours instead.
                return
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            await self.app(scope, limited_receive, tracking_send)
        except _TooLarge:
            pass
        if exceeded and not started:
            await JSONResponse(status_code=413, content={"detail": "Request too large"})(
                scope, receive, send)


class _TooLarge(Exception):
    pass


def _client_address(connection) -> str:
    client = getattr(connection, "client", None)
    return client.host if client is not None else "?"
_PING_INTERVAL = 25  # Keeps idle connections open through proxies.


def create_app(
    settings: Optional[Settings] = None,
    *,
    notifier: Optional[Callable[[Change], None]] = None,
    clock: Callable[[], datetime] = utcnow,
    stale_check_seconds: float = 30,
) -> FastAPI:
    settings = settings or Settings.from_env()
    check_token(settings.token)
    engine = make_engine(settings.database_url)
    store = Store(make_sessionmaker(engine), clock)
    broadcaster = Broadcaster()
    if notifier is None and settings.ntfy_url:
        notifier = NtfyNotifier(settings.ntfy_url, settings.ntfy_token, settings.notify_on,
                                details=settings.ntfy_details)

    def publish(changes: Iterable[Change]) -> None:
        for change in changes:
            broadcaster.publish(change.to_json())
            if notifier is not None:
                try:
                    notifier(change)
                except Exception:
                    log.exception("Notification failed")

    next_thin = [clock()]  # Automatic thinning (SOLITON_THIN_AFTER_DAYS), hourly.

    async def check_stale_runs() -> None:
        while True:
            await asyncio.sleep(stale_check_seconds)
            try:
                publish(await run_in_threadpool(store.mark_stale, settings.stale_after))
                publish(await run_in_threadpool(store.warn_time_limits))
                if settings.thin_after is not None and clock() >= next_thin[0]:
                    next_thin[0] = clock() + THIN_CHECK
                    _, _, changes = await run_in_threadpool(store.thin_older, settings.thin_after)
                    publish(changes)
            except Exception:
                log.exception("Checking for stale runs failed")

    database_file = sqlite_file(settings.database_url)
    backup_folder = database_file.parent if database_file else pathlib.Path(tempfile.gettempdir())

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        broadcaster.bind(asyncio.get_running_loop())
        if database_file is not None:
            remove_stale(backup_folder)
        task = asyncio.create_task(check_stale_runs()) if stale_check_seconds > 0 else None
        yield
        if task is not None:
            task.cancel()
        engine.dispose()

    app = FastAPI(title="Soliton server", version=__version__, lifespan=lifespan)
    app.state.store = store
    app.state.settings = settings
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.cors_origins),
        allow_origin_regex=LOCAL_ORIGIN if settings.cors_local else None,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.add_middleware(BodyLimit, max_bytes=settings.max_body_bytes)

    failures = AuthFailures()

    # The main token: the configured one (SOLITON_TOKEN or the token file),
    # unless it was rotated from the app since. Only hashes are kept: the
    # current one, and every token rotated away (never accepted again, even
    # if a config still holds it). A configured token that is neither is one
    # the admin set on purpose, and replaces a rotated one.
    retired = set(json.loads(store.setting(RETIRED_TOKENS_KEY) or "[]"))
    rotated, configured = store.setting(MAIN_TOKEN_KEY), _token_hash(settings.token)
    if rotated is not None and rotated != configured and configured not in retired:
        store.set_setting(MAIN_TOKEN_KEY, None)
        rotated = None
    elif rotated is not None and rotated != configured:
        log.warning("The main token was rotated from the app; the configured one is no "
                    "longer accepted (update SOLITON_TOKEN or the token file).")
    main_token = {"hash": rotated or configured, "generation": 0}

    def token_ok(candidate: object) -> bool:
        # Never an empty token: it is what a request without one sends.
        return isinstance(candidate, str) and bool(candidate) and hmac.compare_digest(
            _token_hash(candidate), main_token["hash"]
        )

    # The optional job token (the app's Settings → Advanced security): for
    # jobs on clusters, it can do what a logger does (create and update
    # runs, send their events, describe datasets) and list queued jobs
    # (`soliton queue`): not read what was logged, change tags and notes,
    # delete anything or follow live updates. A run that exists it can only
    # change with that run's key (X-Run-Key), which the logger that started
    # it made (Store._check_writer). Only its hash is kept.
    job_token = {"hash": store.setting(JOB_TOKEN_KEY)}

    def is_job_token(candidate: str) -> bool:
        expected = job_token["hash"]
        return bool(candidate) and expected is not None and hmac.compare_digest(
            _token_hash(candidate), expected
        )

    def bearer(authorization: Optional[str]) -> str:
        scheme, _, token = (authorization or "").partition(" ")
        return token.strip() if scheme.lower() == "bearer" else ""

    def unauthorized() -> HTTPException:
        return HTTPException(status_code=401, detail="Missing or wrong token",
                             headers={"WWW-Authenticate": "Bearer"})

    def throttle(address: str) -> None:
        if failures.blocked(address):
            raise HTTPException(status_code=429, detail="Too many wrong tokens; try again in a minute",
                                headers={"Retry-After": str(int(AUTH_FAILURE_WINDOW))})

    def refuse(address: str, token: str) -> HTTPException:
        if token:  # No token at all isn't a guess (e.g. a first visit).
            failures.record(address)
        return unauthorized()

    def require_token(request: Request,
                      authorization: Annotated[Optional[str], Header()] = None) -> None:
        """The server's main token (the app's)."""
        address = _client_address(request)
        throttle(address)
        token = bearer(authorization)
        if token_ok(token):
            return
        if token and is_job_token(token):
            raise HTTPException(status_code=403, detail=JOB_TOKEN_REFUSED)
        raise refuse(address, token)

    def require_writer(request: Request,
                       authorization: Annotated[Optional[str], Header()] = None) -> str:
        """The main token or the job token: "main" or "job"."""
        address = _client_address(request)
        throttle(address)
        token = bearer(authorization)
        if token_ok(token):
            return "main"
        if token and is_job_token(token):
            return "job"
        raise refuse(address, token)

    auth = [Depends(require_token)]
    writers = [Depends(require_writer)]

    @app.exception_handler(RunNotFound)
    async def run_not_found(_, error: RunNotFound):
        return JSONResponse(status_code=404, content={"detail": f"No run with id '{error.args[0]}'"})

    @app.exception_handler(RunKeyRefused)
    async def run_key_refused(_, error: RunKeyRefused):
        return JSONResponse(status_code=403, content={"detail": RUN_KEY_REFUSED})

    @app.exception_handler(DatasetNotFound)
    async def dataset_not_found(_, error: DatasetNotFound):
        return JSONResponse(status_code=404,
                            content={"detail": f"No dataset with id '{error.args[0]}'"})

    @app.exception_handler(ImageNotFound)
    async def image_not_found(_, error: ImageNotFound):
        return JSONResponse(status_code=404, content={"detail": f"No image '{error.args[0]}'"})

    @app.exception_handler(FieldNotFound)
    async def field_not_found(_, error: FieldNotFound):
        return JSONResponse(status_code=404, content={"detail": f"No field '{error.args[0]}'"})

    @app.get("/api/health")
    def health():
        """Public: for uptime checks."""
        return {"status": "ok", "version": __version__}

    @app.get("/api/session", dependencies=auth)
    def session():
        """Checks a token (the app's "Connect" button), and says whether a
        job token is set."""
        return {"ok": True, "version": __version__, "jobToken": job_token["hash"] is not None}

    @app.post("/api/token/rotate", dependencies=auth)
    def rotate_token():
        """A new main token, shown this once; the current one stops working,
        and live connections made with it are closed."""
        token = secrets.token_urlsafe(32)
        retired.add(main_token["hash"])
        store.set_setting(RETIRED_TOKENS_KEY, json.dumps(sorted(retired)))
        store.set_setting(MAIN_TOKEN_KEY, _token_hash(token))
        main_token["hash"] = _token_hash(token)
        main_token["generation"] += 1
        if settings.token_file is not None and settings.token_file.exists():
            replace_private(settings.token_file, token + "\n")
        broadcaster.publish({"type": "ping"})  # Wakes live connections, to close old ones.
        return {"token": token}

    @app.post("/api/job-token", dependencies=auth)
    def create_job_token():
        """A new job token, replacing any earlier one: shown this once."""
        token = secrets.token_urlsafe(32)
        store.set_setting(JOB_TOKEN_KEY, _token_hash(token))
        job_token["hash"] = _token_hash(token)
        return {"token": token}

    @app.delete("/api/job-token", dependencies=auth)
    def delete_job_token():
        """Jobs need the main token again."""
        store.set_setting(JOB_TOKEN_KEY, None)
        job_token["hash"] = None
        return Response(status_code=204)

    @app.get("/api/runs")
    def list_runs(
        status: Optional[Literal["queued", "live", "finished", "crashed"]] = None,
        # A default, not Annotated: annotations are strings here, and a
        # closure's name can't be resolved from one.
        role: str = Depends(require_writer),
    ):
        if role == "job" and status != "queued":
            raise HTTPException(status_code=403, detail=JOB_TOKEN_REFUSED)
        return store.list_runs(status)

    @app.get("/api/runs/{run_id}", dependencies=auth)
    def get_run(run_id: RunId):
        return store.get_run(run_id)

    @app.put("/api/runs/{run_id}")
    def put_run(run_id: RunId, body: RunIn, role: str = Depends(require_writer),
                x_run_key: RunKey = None):
        """With the job token, an existing run only with its key (X-Run-Key)."""
        run, changes = store.put_run(run_id, body, role, x_run_key)
        publish(changes)
        if any(change.event == "deleted" for change in changes):
            # The run took the place of its queued job, whose board links
            # now point at it: have the app reload the board.
            broadcaster.publish({"type": "board", "event": "updated"})
        return run

    @app.patch("/api/runs/{run_id}", dependencies=auth)
    def update_run_notes(run_id: RunId, body: RunNotesIn):
        """Tags and notes, edited in the app."""
        run, change = store.update_notes(run_id, body)
        publish([change])
        return run

    @app.post("/api/runs/{run_id}/stop", dependencies=auth)
    def stop_run(run_id: RunId):
        """Asks a live run to stop (the app's Stop button): its logger hears
        of it on its next upload, through run.should_stop()."""
        try:
            run, change = store.request_stop(run_id)
        except RunNotLive:
            raise HTTPException(status_code=409, detail="Only a live run can be stopped")
        publish([change])
        return run

    @app.post("/api/runs/{run_id}/thin", dependencies=auth)
    def thin_run(run_id: RunId, maxPoints: MaxPoints = 1000):
        """Thins out an ended run to save space (Store.thin_run)."""
        try:
            run, freed, change = store.thin_run(run_id, maxPoints)
        except RunNotEnded:
            raise HTTPException(status_code=409, detail="Only a run that has ended can be thinned")
        publish([change])
        return {"run": run, "freed": freed}

    @app.get("/api/storage", dependencies=auth)
    def storage():
        return store.storage()

    @app.post("/api/storage/thin", dependencies=auth)
    def thin_older(olderThanDays: Annotated[float, Query(ge=0, le=36_500)],
                   maxPoints: MaxPoints = 1000):
        """Thins every run that ended more than olderThanDays ago."""
        count, freed, changes = store.thin_older(timedelta(days=olderThanDays), maxPoints)
        publish(changes)
        return {"thinned": count, "freed": freed}

    @app.post("/api/storage/compact", dependencies=auth)
    async def compact():
        return await run_in_threadpool(store.compact)

    # Backups (the app's "Download a backup"): the copy is made next to the
    # database, opened, then removed from the disk at once (it is read from
    # the open file), so nothing is left behind even if the download stops.
    backing_up = threading.Lock()  # One copy at a time.

    @app.get("/api/storage/backup", dependencies=auth)
    async def download_backup():
        """A consistent copy of the whole (SQLite) database, as a file."""
        if not backing_up.acquire(blocking=False):
            raise HTTPException(status_code=409, detail="A backup is already being made")
        try:
            path = await run_in_threadpool(back_up_engine, engine, backup_folder)
        except BackupError as error:
            raise HTTPException(status_code=409, detail=str(error))
        finally:
            backing_up.release()
        file = open(path, "rb")
        size = os.fstat(file.fileno()).st_size
        try:
            path.unlink()
            removed = True
        except OSError:  # Windows can't remove an open file: removed after.
            removed = False
        log.info("Sending a backup of the database (%d bytes)", size)

        def chunks():
            try:
                while chunk := file.read(1024 * 1024):
                    yield chunk
            finally:
                file.close()
                if not removed:
                    path.unlink(missing_ok=True)

        return StreamingResponse(chunks(), media_type="application/vnd.sqlite3", headers={
            "Content-Length": str(size),
            "Content-Disposition": f'attachment; filename="{backup_name()}"',
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        })

    @app.delete("/api/runs/{run_id}", dependencies=auth)
    def delete_run(run_id: RunId):
        publish([store.delete_run(run_id)])
        return Response(status_code=204)

    @app.post("/api/runs/{run_id}/events")
    def post_events(run_id: RunId, body: EventsIn, role: str = Depends(require_writer),
                    x_run_key: RunKey = None):
        publish(store.ingest(run_id, body.events, role, x_run_key))
        # The logger's cue for run.should_stop().
        stop = store.stop_requested(run_id)
        return {"accepted": len(body.events), **({"stop": True} if stop else {})}

    @app.get("/api/runs/{run_id}/metrics", dependencies=auth)
    def metrics(run_id: RunId, maxPoints: MaxPoints = 1000):
        return store.metrics(run_id, maxPoints)

    @app.get("/api/runs/{run_id}/metrics/points", dependencies=auth)
    def metric_points(run_id: RunId, name: Annotated[str, Query(min_length=1, max_length=200)],
                      after: Annotated[int, Query(ge=-1)] = -1, limit: PageSize = 10_000):
        return store.metric_points(run_id, name, after, limit)

    @app.get("/api/runs/{run_id}/metrics/summary", dependencies=auth)
    def metric_summary(run_id: RunId):
        return store.metric_summary(run_id)

    @app.get("/api/runs/{run_id}/layers", dependencies=auth)
    def layers(run_id: RunId, maxPoints: MaxPoints = 500):
        return store.layers(run_id, maxPoints)

    @app.get("/api/runs/{run_id}/grad-norms", dependencies=auth)
    def grad_norms(run_id: RunId):
        return store.grad_norms(run_id)

    @app.get("/api/runs/{run_id}/images", dependencies=auth)
    def images(run_id: RunId):
        return store.images(run_id)

    @app.get("/api/runs/{run_id}/images/snapshot", dependencies=auth)
    def image(run_id: RunId, name: Annotated[str, Query(min_length=1, max_length=200)],
              step: Annotated[Optional[int], Query(ge=0)] = None):
        return store.image(run_id, name, step)

    @app.get("/api/runs/{run_id}/fields", dependencies=auth)
    def fields(run_id: RunId):
        """The logged fields and their steps (no data)."""
        return store.fields(run_id)

    @app.get("/api/runs/{run_id}/fields/snapshot", dependencies=auth)
    def field_snapshot(
        run_id: RunId,
        name: Annotated[str, Query(min_length=1, max_length=200)],
        step: Annotated[Optional[int], Query(ge=0)] = None,
    ):
        """One snapshot of a field (the latest without [step])."""
        return store.field_snapshot(run_id, name, step)

    @app.get("/api/runs/{run_id}/evals", dependencies=auth)
    def evals(run_id: RunId):
        """Validation-set summaries (run.log_eval), per name and step."""
        return store.items(run_id, "eval")

    @app.get("/api/runs/{run_id}/output", dependencies=auth)
    def output(run_id: RunId):
        """The latest lines the run's script printed (its output and errors)."""
        return store.output(run_id)

    @app.get("/api/runs/{run_id}/curves", dependencies=auth)
    def curves(run_id: RunId):
        """Curves (run.log_curve), per name and step."""
        return store.items(run_id, "curve")

    def dataset_changed(dataset_id: str, event: str) -> None:
        broadcaster.publish({"type": "dataset", "event": event, "datasetId": dataset_id})

    @app.get("/api/datasets", dependencies=auth)
    def list_datasets():
        """Every dataset, most recently updated first (without previews)."""
        return store.list_datasets()

    @app.get("/api/datasets/{dataset_id}", dependencies=auth)
    def get_dataset(dataset_id: RunId):
        return store.get_dataset(dataset_id)

    @app.put("/api/datasets/{dataset_id}", dependencies=writers)
    def put_dataset(dataset_id: RunId, body: DatasetIn):
        dataset = store.put_dataset(dataset_id, body)
        dataset_changed(dataset_id, "updated")
        return dataset

    @app.delete("/api/datasets/{dataset_id}", dependencies=auth)
    def delete_dataset(dataset_id: RunId):
        store.delete_dataset(dataset_id)
        dataset_changed(dataset_id, "deleted")
        return Response(status_code=204)

    # The board: the app's to-do cards. The app pools every server's cards
    # into one board; each card lives on one server. Main token only.

    def card_changed(card_id: str, event: str) -> None:
        broadcaster.publish({"type": "board", "event": event, "cardId": card_id})

    @app.get("/api/board", dependencies=auth)
    def list_board():
        """Every card on this server, by project, column and position."""
        return store.list_board()

    @app.put("/api/board/{card_id}", dependencies=auth)
    def put_board_card(card_id: RunId, body: BoardCardIn):
        """Adds a card or replaces it whole (the app makes its id)."""
        card = store.put_board_card(card_id, body)
        card_changed(card_id, "updated")
        return card

    @app.delete("/api/board/{card_id}", dependencies=auth)
    def delete_board_card(card_id: RunId):
        store.delete_board_card(card_id)
        card_changed(card_id, "deleted")
        return Response(status_code=204)

    @app.get("/api/metrics/latest", dependencies=auth)
    def latest_metrics(names: Annotated[str, Query(min_length=1, max_length=2000)]):
        """For sweeps: {run id: {metric: {latest, min}}} for the
        comma-separated metric [names] (at most 20)."""
        wanted = [n.strip() for n in names.split(",") if n.strip()][:20]
        return store.latest_metrics(wanted)

    @app.websocket("/api/live")
    async def live(websocket: WebSocket):
        """Pushes a message for every change to any run.

        The first message from the client must be {"type": "auth", "token":
        "..."}: browsers can't set headers on WebSockets, and a token in the
        URL would end up in logs.
        """
        address = _client_address(websocket)
        if failures.blocked(address):
            await websocket.close(code=4429)
            return
        await websocket.accept()
        try:
            hello = await asyncio.wait_for(websocket.receive_json(), timeout=_AUTH_TIMEOUT)
        except Exception:
            await websocket.close(code=4401)
            return
        if not (isinstance(hello, dict) and hello.get("type") == "auth" and token_ok(hello.get("token"))):
            failures.record(address)
            await websocket.send_json({"type": "error", "message": "Missing or wrong token"})
            await websocket.close(code=4401)
            return
        await websocket.send_json({"type": "ready", "version": __version__})
        generation = main_token["generation"]

        with broadcaster.subscribe() as queue:
            reader = asyncio.create_task(_read_until_closed(websocket))
            try:
                while not reader.done():
                    getter = asyncio.ensure_future(queue.get())
                    done, _ = await asyncio.wait(
                        {getter, reader}, timeout=_PING_INTERVAL, return_when=asyncio.FIRST_COMPLETED
                    )
                    if main_token["generation"] != generation:  # The token was rotated.
                        getter.cancel()
                        await websocket.send_json({"type": "error", "message": "The token changed"})
                        await websocket.close(code=4401)
                        return
                    if getter in done:
                        await websocket.send_json(getter.result())
                        continue
                    getter.cancel()
                    if not reader.done():
                        await websocket.send_json({"type": "ping"})
            except (WebSocketDisconnect, RuntimeError):
                pass
            finally:
                reader.cancel()

    return app


async def _read_until_closed(websocket: WebSocket) -> None:
    """Reads (and ignores) client messages until the client disconnects."""
    try:
        while True:
            await websocket.receive_text()
    except (WebSocketDisconnect, RuntimeError):
        return


def _token_hash(token: str) -> str:
    """SHA-256 of a long random token: enough, without a slow password hash."""
    return hashlib.sha256(token.encode()).hexdigest()
