"""Tiny read-only HTTP endpoint that publishes the scaler's last observation.

The trigger app's /stats reads this instead of scraping a worker pod directly,
because a host `kubectl port-forward svc/kestra-worker-metrics` only ever
connects to ONE worker pod — so the app would show a single-worker sample and
never see the replica count change. The scaler already sums across every worker
pod and reads the real Deployment replica count, so it is the authoritative
source.

stdlib only. One daemon thread, GET-only, no state of its own.
"""
from __future__ import annotations

import json
import logging
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

_log = logging.getLogger("scaler.state")


def start(port: int, get_state: Callable[[], dict | None]) -> None:
    """Serve `get_state()` as JSON at GET /state (and /). Non-blocking.

    `get_state` returns the latest state dict, or None before the first tick.
    port <= 0 disables the server.
    """
    if port <= 0:
        _log.info("state endpoint disabled (STATE_HTTP_PORT=%d)", port)
        return

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib naming
            if self.path.rstrip("/") in ("", "/state"):
                body = get_state()
                code = 200 if body is not None else 503   # 503 until the first tick
                payload = json.dumps(body if body is not None else {"error": "no data yet"}).encode()
                self.send_response(code)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, *_args) -> None:  # silence per-request access logging
            pass

    srv = ThreadingHTTPServer(("", port), Handler)
    threading.Thread(target=srv.serve_forever, name="state-http", daemon=True).start()
    _log.info("state endpoint on :%d/state", port)
