"""Stub DevScope API for hook tests.

    python3 stub_server.py PORT DIR

Answers every request with the body in DIR/resp (sleeping 5 s first if
DIR/slow exists), appends one byte per request to DIR/hits, and writes the
last request's path, API key and JSON body to DIR/last. POSTs without the
x-requested-with header get 403, like the backend's CSRF middleware.
"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

port, d = int(sys.argv[1]), sys.argv[2]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def handle_any(self, method):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        if method == "POST" and self.headers.get("x-requested-with") != "devscope-cli":
            return self.reply(403, '{"error":"Missing x-requested-with header"}')
        open(os.path.join(d, "hits"), "a").write("x")
        with open(os.path.join(d, "last"), "w") as f:
            json.dump({"method": method, "path": self.path, "key": self.headers.get("x-api-key"),
                       "body": json.loads(raw) if raw else None}, f)
        if os.path.exists(os.path.join(d, "slow")):
            time.sleep(5)
        self.reply(200, open(os.path.join(d, "resp")).read())

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


HTTPServer(("127.0.0.1", port), H).serve_forever()
