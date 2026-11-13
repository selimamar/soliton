"""Live updates: every change to a run is pushed to connected apps."""

from __future__ import annotations

import asyncio
from collections.abc import Iterator
from contextlib import contextmanager

_QUEUE_SIZE = 256


class Broadcaster:
    """Fans messages out to WebSocket subscribers.

    [publish] may be called from any thread (the API's endpoints run in a
    thread pool); delivery happens on the server's event loop.
    """

    def __init__(self) -> None:
        self._subscribers: set[asyncio.Queue] = set()
        self._loop: asyncio.AbstractEventLoop | None = None

    def bind(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop

    def publish(self, message: dict) -> None:
        loop = self._loop
        if loop is not None and not loop.is_closed():
            loop.call_soon_threadsafe(self._fan_out, message)

    def _fan_out(self, message: dict) -> None:
        for queue in list(self._subscribers):
            if queue.full():
                queue.get_nowait()  # A slow client loses its oldest update.
            queue.put_nowait(message)

    @contextmanager
    def subscribe(self) -> Iterator[asyncio.Queue]:
        queue: asyncio.Queue = asyncio.Queue(maxsize=_QUEUE_SIZE)
        self._subscribers.add(queue)
        try:
            yield queue
        finally:
            self._subscribers.discard(queue)
