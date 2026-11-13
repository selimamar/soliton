"""The HTTP and WebSocket API. See server/README.md for the endpoints."""

from __future__ import annotations

import asyncio
import hmac
import logging
from collections.abc import Callable, Iterable
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Annotated, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Path, Query, WebSocket
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from starlette.websockets import WebSocketDisconnect

from . import __version__
from .config import Settings
from .db import make_engine, make_sessionmaker
from .live import Broadcaster
from .notify import NtfyNotifier
from .schemas import RUN_ID_PATTERN, EventsIn, RunIn
from .store import Change, RunNotFound, Store, utcnow

log = logging.getLogger(__name__)

RunId = Annotated[str, Path(pattern=RUN_ID_PATTERN)]
MaxPoints = Annotated[int, Query(ge=4, le=20_000)]

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

    app = FastAPI(title="ModelsApp server", version=__version__, lifespan=lifespan)
    app.state.store = store
    app.state.settings = settings
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.cors_origins),
        allow_methods=["*"],
        allow_headers=["*"],
    )

    def token_ok(candidate: object) -> bool:
        return isinstance(candidate, str) and hmac.compare_digest(
            candidate.encode(), settings.token.encode()
        )

    def require_token(authorization: Annotated[Optional[str], Header()] = None) -> None:
        scheme, _, token = (authorization or "").partition(" ")
        if scheme.lower() != "bearer" or not token_ok(token.strip()):
            raise HTTPException(
                status_code=401,
                detail="Missing or wrong token",
                headers={"WWW-Authenticate": "Bearer"},
            )

    auth = [Depends(require_token)]

    @app.exception_handler(RunNotFound)
    async def run_not_found(_, error: RunNotFound):
        return JSONResponse(status_code=404, content={"detail": f"No run with id '{error.args[0]}'"})

    @app.get("/api/health")
    def health():
        """Public: for uptime checks."""
        return {"status": "ok", "version": __version__}

    @app.get("/api/session", dependencies=auth)
    def session():
        """Checks a token (the app's "Connect" button)."""
        return {"ok": True, "version": __version__}

    @app.get("/api/runs", dependencies=auth)
    def list_runs():
        return store.list_runs()

    @app.get("/api/runs/{run_id}", dependencies=auth)
    def get_run(run_id: RunId):
        return store.get_run(run_id)

    @app.put("/api/runs/{run_id}", dependencies=auth)
    def put_run(run_id: RunId, body: RunIn):
        run, change = store.put_run(run_id, body)
        publish([change])
        return run

    @app.delete("/api/runs/{run_id}", dependencies=auth)
    def delete_run(run_id: RunId):
        publish([store.delete_run(run_id)])
        return Response(status_code=204)

    @app.post("/api/runs/{run_id}/events", dependencies=auth)
    def post_events(run_id: RunId, body: EventsIn):
        publish(store.ingest(run_id, body.events))
        return {"accepted": len(body.events)}

    @app.get("/api/runs/{run_id}/metrics", dependencies=auth)
    def metrics(run_id: RunId, maxPoints: MaxPoints = 1000):
        return store.metrics(run_id, maxPoints)

    @app.get("/api/runs/{run_id}/layers", dependencies=auth)
    def layers(run_id: RunId, maxPoints: MaxPoints = 500):
        return store.layers(run_id, maxPoints)

    @app.get("/api/runs/{run_id}/grad-norms", dependencies=auth)
    def grad_norms(run_id: RunId):
        return store.grad_norms(run_id)

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

        with broadcaster.subscribe() as queue:
            reader = asyncio.create_task(_read_until_closed(websocket))
            try:
                while not reader.done():
                    getter = asyncio.ensure_future(queue.get())
                    done, _ = await asyncio.wait(
                        {getter, reader}, timeout=_PING_INTERVAL, return_when=asyncio.FIRST_COMPLETED
                    )
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
