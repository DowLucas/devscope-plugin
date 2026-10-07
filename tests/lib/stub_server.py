"""Stub DevScope API for hook tests.

    python3 stub_server.py PORT DIR

Answers every request with the body in DIR/resp (sleeping 5 s first if
DIR/slow exists), appends one byte per request to DIR/hits, and writes the
last request's path, API key and JSON body to DIR/last (and per path to
DIR/last<path with / as _>), and appends each path to DIR/paths. DIR/status and DIR/ctype, when present, override the
response status (200) and content type (application/json). POSTs without the
x-requested-with header get 403, like the backend's CSRF middleware (which
exempts /api/events).
"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

port, d = int(sys.argv[1]), sys.argv[2]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, body, ctype="application/json"):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def handle_any(self, method):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        # Like the backend's csrfMiddleware: event ingestion is exempt.
        if method == "POST" and self.path != "/api/events" and self.headers.get("x-requested-with") != "devscope-cli":
            return self.reply(403, '{"error":"Missing x-requested-with header"}')
        open(os.path.join(d, "hits"), "a").write("x")
        open(os.path.join(d, "paths"), "a").write(self.path + "\n")
        req = {"method": method, "path": self.path, "key": self.headers.get("x-api-key"),
               "body": json.loads(raw) if raw else None}
        for name in ("last", "last" + self.path.split("?")[0].replace("/", "_")):
            with open(os.path.join(d, name), "w") as f:
                json.dump(req, f)
        if os.path.exists(os.path.join(d, "slow")):
            time.sleep(5)
        status = int(open(os.path.join(d, "status")).read()) if os.path.exists(os.path.join(d, "status")) else 200
        ctype = open(os.path.join(d, "ctype")).read().strip() if os.path.exists(os.path.join(d, "ctype")) else "application/json"
        self.reply(status, open(os.path.join(d, "resp"), "rb").read(), ctype)

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


HTTPServer(("127.0.0.1", port), H).serve_forever()
