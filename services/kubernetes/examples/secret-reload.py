#!/usr/bin/env python3
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading


class ReloadingServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, secret_file):
        super().__init__(address, Handler)
        self.secret_file = Path(secret_file)
        self.lock = threading.Lock()
        self.value = None
        self.reloads = 0
        self.stopped = threading.Event()
        self.loader = threading.Thread(target=self.refresh, daemon=True)
        self.loader.start()

    def refresh(self):
        while not self.stopped.is_set():
            try:
                with self.secret_file.open('rb') as source:
                    value = source.read(65537)
                if len(value) <= 65536:
                    with self.lock:
                        if value != self.value:
                            self.value = value
                            self.reloads += 1
            except OSError:
                pass
            self.stopped.wait(1)

    def server_close(self):
        self.stopped.set()
        self.loader.join(timeout=2)
        super().server_close()


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, format, *args):
        pass

    def respond(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != '/ready':
            self.respond(404, {})
            return
        with self.server.lock:
            ready = self.server.value is not None
        self.respond(200 if ready else 503, {'ready': ready})

    def do_POST(self):
        if self.path != '/verify':
            self.respond(404, {})
            return
        try:
            length = int(self.headers.get('Content-Length', '-1'))
        except ValueError:
            self.respond(400, {})
            return
        if not 0 <= length <= 65536:
            self.respond(413, {})
            return
        expected = self.rfile.read(length)
        with self.server.lock:
            if self.server.value is None:
                self.respond(503, {})
                return
            result = {'matches': hmac.compare_digest(self.server.value, expected), 'reloads': self.server.reloads}
        self.respond(200, result)


if __name__ == '__main__':
    with ReloadingServer(('0.0.0.0', 8080), '/secrets/value') as server:
        server.serve_forever()
