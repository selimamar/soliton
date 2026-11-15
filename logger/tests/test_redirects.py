"""The token never follows a redirect: urllib would send it to wherever one
points (another host, plain http), so the logger refuses them."""

from __future__ import annotations

import http.server
import threading

import pytest

from soliton._read import _Reader
from soliton._setup import REDIRECTED, check_token
from soliton._upload import ApiClient, UploadError


@pytest.fixture
def servers():
    seen: list = []

    class Elsewhere(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.headers.get("Authorization"))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok": true}')

        do_POST = do_GET

        def log_message(self, *args):
            pass

    elsewhere = http.server.HTTPServer(("127.0.0.1", 0), Elsewhere)

    class Redirects(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{elsewhere.server_port}/steal")
            self.end_headers()

        do_POST = do_PUT = do_GET

        def log_message(self, *args):
            pass

    redirects = http.server.HTTPServer(("127.0.0.1", 0), Redirects)
    for server in (elsewhere, redirects):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://localhost:{redirects.server_port}", seen
    for server in (elsewhere, redirects):
        server.shutdown()


def test_uploads_dont_follow_redirects(servers):
    address, seen = servers
    with pytest.raises(UploadError, match="redirects to"):
        ApiClient(address, "secret-token-0123456789").post_events("r1", [], None)
    assert seen == []


def test_setup_doesnt_follow_redirects(servers):
    address, seen = servers
    kind, where = check_token(address, "secret-token-0123456789")
    assert kind == REDIRECTED and where.endswith("/steal")
    assert seen == []


def test_reading_doesnt_follow_redirects(servers):
    address, seen = servers
    with pytest.raises(RuntimeError, match="redirects to"):
        _Reader(address, "secret-token-0123456789").get("/api/runs")
    assert seen == []
