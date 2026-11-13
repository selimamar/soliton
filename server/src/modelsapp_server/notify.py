"""Push notifications through ntfy (https://ntfy.sh).

ntfy delivers real push notifications to its iOS and Android apps without
an Apple or Google developer account: subscribe to your topic in the ntfy
app, and set MODELSAPP_NTFY_URL to the same topic on the server. Anyone who
knows a topic on the public ntfy.sh server can read it, so pick a long
random name, or run your own ntfy server with an access token.
"""

from __future__ import annotations

import json
import logging
import threading
import urllib.request
from urllib.parse import urlsplit, urlunsplit

from .store import Change

log = logging.getLogger(__name__)


class NtfyNotifier:
    def __init__(self, topic_url: str, token: str | None = None, events=("finished", "crashed")):
        parts = urlsplit(topic_url.rstrip("/"))
        base_path, _, topic = parts.path.rpartition("/")
        if not topic:
            raise ValueError(f"MODELSAPP_NTFY_URL needs a topic, e.g. https://ntfy.sh/my-topic: {topic_url}")
        # JSON is posted to the server root, so titles may contain any text.
        self._endpoint = urlunsplit((parts.scheme, parts.netloc, base_path or "/", "", ""))
        self._topic = topic
        self._token = token
        self._events = frozenset(events)

    def message_for(self, change: Change) -> dict | None:
        if change.event not in self._events:
            return None
        if change.event == "finished":
            return {
                "topic": self._topic,
                "title": f"{change.name} finished",
                "message": change.message or f"Finished after {change.current_step:,} steps.",
                "tags": ["white_check_mark"],
            }
        if change.event == "crashed":
            return {
                "topic": self._topic,
                "title": f"{change.name} crashed",
                "message": change.message or f"Crashed at step {change.current_step:,}.",
                "tags": ["rotating_light"],
                "priority": 4,
            }
        return None

    def __call__(self, change: Change) -> None:
        message = self.message_for(change)
        if message is not None:
            threading.Thread(target=self._send, args=(message,), daemon=True).start()

    def _send(self, message: dict) -> None:
        request = urllib.request.Request(
            self._endpoint,
            data=json.dumps(message).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        if self._token:
            request.add_header("Authorization", f"Bearer {self._token}")
        try:
            with urllib.request.urlopen(request, timeout=10):
                pass
        except OSError as error:
            log.warning("Push notification failed: %s", error)
