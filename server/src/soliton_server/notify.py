"""Push notifications through ntfy (https://ntfy.sh).

ntfy delivers real push notifications to its iOS and Android apps without
an Apple or Google developer account: subscribe to your topic in the ntfy
app, and set SOLITON_NTFY_URL to the same topic on the server. Anyone who
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
    def __init__(self, topic_url: str, token: str | None = None,
                 events=("finished", "crashed", "time-limit"), details: bool = True):
        parts = urlsplit(topic_url.rstrip("/"))
        base_path, _, topic = parts.path.rpartition("/")
        if not topic:
            raise ValueError(f"SOLITON_NTFY_URL needs a topic, e.g. https://ntfy.sh/my-topic: {topic_url}")
        # JSON is posted to the server root, so titles may contain any text.
        self._endpoint = urlunsplit((parts.scheme, parts.netloc, base_path or "/", "", ""))
        self._topic = topic
        self._token = token
        self._events = frozenset(events)
        # Off (SOLITON_NTFY_DETAILS=0): no run name or error text leaves the
        # server, for a topic on a public ntfy server.
        self._details = details

    def message_for(self, change: Change) -> dict | None:
        if change.event not in self._events or not change.notify:
            return None
        if not self._details:
            return self._brief(change)
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
        if change.event == "time-limit":
            return {
                "topic": self._topic,
                "title": f"{change.name} won't finish before its time limit",
                "message": change.message or "At this pace, Slurm will stop it first.",
                "tags": ["hourglass_flowing_sand"],
                "priority": 4,
            }
        return None

    def _brief(self, change: Change) -> dict | None:
        """Says what happened, not to which run or why."""
        brief = {
            "finished": ("A run finished", "Open Soliton for details.", ["white_check_mark"], None),
            "crashed": ("A run crashed", "Open Soliton for details.", ["rotating_light"], 4),
            "time-limit": ("A run won't finish before its time limit",
                           "Open Soliton for details.", ["hourglass_flowing_sand"], 4),
        }.get(change.event)
        if brief is None:
            return None
        title, message, tags, priority = brief
        return {"topic": self._topic, "title": title, "message": message, "tags": tags,
                **({"priority": priority} if priority else {})}

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
