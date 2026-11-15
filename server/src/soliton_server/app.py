"""The HTTP and WebSocket API. See server/README.md for the endpoints."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import secrets
import logging
from collections.abc import Callable, Iterable
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated, Literal, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Path, Query, WebSocket
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from starlette.websockets import WebSocketDisconnect

from . import __version__
from .config import Settings, replace_private
from .db import make_engine, make_sessionmaker
from .live import Broadcaster
from .notify import NtfyNotifier
from .schemas import RUN_ID_PATTERN, DatasetIn, EventsIn, RunIn, RunNotesIn
from .store import (
    Change,
    DatasetNotFound,
    FieldNotFound,
    RunNotFound,
    RunNotLive,
    Store,
    utcnow,
)

log = logging.getLogger(__name__)

RunId = Annotated[str, Path(pattern=RUN_ID_PATTERN)]
MaxPoints = Annotated[int, Query(ge=4, le=20_000)]

JOB_TOKEN_KEY = "jobTokenHash"
MAIN_TOKEN_KEY = "mainTokenHash"
RETIRED_TOKENS_KEY = "retiredTokenHashes"
JOB_TOKEN_REFUSED = (
    "This is the job token: it can only add and update runs and data. "
    "Use the server's main token here."
)

_AUTH_TIMEOUT = 10  # Seconds a WebSocket client has to send its token.
_PING_INTERVAL = 25  # Keeps idle connections open through proxies.


def create_app(
    settings: Optional[Settings] = None,
    *,
    notifier: Optional[Callable[[Change], None]] = None,
    clock: Callable[[], datetime] = utcnow,
    stale_check_seconds: float = 30,
) -> FastAPI:
    settings = settings or Settings.from_env()
    engine = make_engine(settings.database_url)
    store = Store(make_sessionmaker(engine), clock)
    broadcaster = Broadcaster()
    if notifier is None and settings.ntfy_url:
        notifier = NtfyNotifier(settings.ntfy_url, settings.ntfy_token, settings.notify_on)

    def publish(changes: Iterable[Change]) -> None:
        for change in changes:
            broadcaster.publish(change.to_json())
            if notifier is not None:
                try:
                    notifier(change)
                except Exception:
                    log.exception("Notification failed")

    async def check_stale_runs() -> None:
        while True:
            await asyncio.sleep(stale_check_seconds)
            try:
                publish(await run_in_threadpool(store.mark_stale, settings.stale_after))
                publish(await run_in_threadpool(store.warn_time_limits))
            except Exception:
                log.exception("Checking for stale runs failed")

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        broadcaster.bind(asyncio.get_running_loop())
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
        allow_methods=["*"],
        allow_headers=["*"],
    )

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
        return isinstance(candidate, str) and hmac.compare_digest(
            _token_hash(candidate), main_token["hash"]
        )

    # The optional job token (the app's Settings → Advanced security): for
    # jobs on clusters, it can do what a logger does (create and update
    # runs, send their events, describe datasets) and list queued jobs
    # (`soliton queue`): not read what was logged, change tags and notes,
    # delete anything or follow live updates. It can still overwrite a run
    # whose id it knows: loggers update their own runs, and the server can't
    # tell whose a run is. Only its hash is kept.
    job_token = {"hash": store.setting(JOB_TOKEN_KEY)}

    def is_job_token(candidate: str) -> bool:
        expected = job_token["hash"]
        return expected is not None and hmac.compare_digest(_token_hash(candidate), expected)

    def bearer(authorization: Optional[str]) -> str:
        scheme, _, token = (authorization or "").partition(" ")
        return token.strip() if scheme.lower() == "bearer" else ""

    def unauthorized() -> HTTPException:
        return HTTPException(status_code=401, detail="Missing or wrong token",
                             headers={"WWW-Authenticate": "Bearer"})

    def require_token(authorization: Annotated[Optional[str], Header()] = None) -> None:
        """The server's main token (the app's)."""
        token = bearer(authorization)
        if token_ok(token):
            return
        if token and is_job_token(token):
            raise HTTPException(status_code=403, detail=JOB_TOKEN_REFUSED)
        raise unauthorized()

    def require_writer(authorization: Annotated[Optional[str], Header()] = None) -> str:
        """The main token or the job token: "main" or "job"."""
        token = bearer(authorization)
        if token_ok(token):
            return "main"
        if token and is_job_token(token):
            return "job"
        raise unauthorized()

    auth = [Depends(require_token)]
    writers = [Depends(require_writer)]

    @app.exception_handler(RunNotFound)
    async def run_not_found(_, error: RunNotFound):
        return JSONResponse(status_code=404, content={"detail": f"No run with id '{error.args[0]}'"})

    @app.exception_handler(DatasetNotFound)
    async def dataset_not_found(_, error: DatasetNotFound):
        return JSONResponse(status_code=404,
                            content={"detail": f"No dataset with id '{error.args[0]}'"})

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

    @app.put("/api/runs/{run_id}", dependencies=writers)
    def put_run(run_id: RunId, body: RunIn):
        run, changes = store.put_run(run_id, body)
        publish(changes)
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

    @app.delete("/api/runs/{run_id}", dependencies=auth)
    def delete_run(run_id: RunId):
        publish([store.delete_run(run_id)])
        return Response(status_code=204)

    @app.post("/api/runs/{run_id}/events", dependencies=writers)
    def post_events(run_id: RunId, body: EventsIn):
        publish(store.ingest(run_id, body.events))
        # The logger's cue for run.should_stop().
        stop = store.stop_requested(run_id)
        return {"accepted": len(body.events), **({"stop": True} if stop else {})}

    @app.get("/api/runs/{run_id}/metrics", dependencies=auth)
    def metrics(run_id: RunId, maxPoints: MaxPoints = 1000):
        return store.metrics(run_id, maxPoints)

    @app.get("/api/runs/{run_id}/layers", dependencies=auth)
    def layers(run_id: RunId, maxPoints: MaxPoints = 500):
        return store.layers(run_id, maxPoints)

    @app.get("/api/runs/{run_id}/grad-norms", dependencies=auth)
    def grad_norms(run_id: RunId):
        return store.grad_norms(run_id)

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
        await websocket.accept()
        try:
            hello = await asyncio.wait_for(websocket.receive_json(), timeout=_AUTH_TIMEOUT)
        except Exception:
            await websocket.close(code=4401)
            return
        if not (isinstance(hello, dict) and hello.get("type") == "auth" and token_ok(hello.get("token"))):
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
